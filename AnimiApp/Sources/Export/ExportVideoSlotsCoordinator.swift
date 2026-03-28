import AVFoundation
import CoreVideo
import Metal
import TVECore

// MARK: - Export Video Slots Coordinator

/// Coordinates video slot providers for export (PR-E3).
///
/// Creates and manages `ExportVideoFrameProvider` instances for all video blocks.
/// On each frame, updates textures in `ExportTextureProvider` for all binding asset IDs.
///
/// B1: Visibility gating — only decodes frames for blocks that are visible
/// at the current scene frame (with prefetch margin for decode latency).
///
/// Usage:
/// ```swift
/// let coordinator = ExportVideoSlotsCoordinator(
///     device: device,
///     textureCache: cache,
///     commandQueue: queue,
///     runtime: compiledScene.runtime,
///     sceneFPS: 30,
///     exportTextureProvider: textureProvider
/// )
/// coordinator.configure(videoSelectionsByBlockId: selections)
///
/// for frame in 0..<totalFrames {
///     coordinator.updateTextures(forSceneFrameIndex: frame)
///     // render frame...
/// }
///
/// coordinator.finish()
/// ```
public final class ExportVideoSlotsCoordinator {
    // MARK: - Constants

    /// B1: Prefetch margin in frames for visibility gating.
    /// Providers start decoding this many frames before block becomes visible.
    /// Configured via ExportResourceBudget.videoPrefetchFrames (default ~1s worth of frames).
    private let videoPrefetchFrames: Int

    // MARK: - Types

    /// Internal state for a video slot
    private struct VideoSlot {
        let blockId: String
        let provider: ExportVideoFrameProvider
        let bindingAssetIds: [String]
        let startFrame: Int
        let endFrame: Int
        var isPrepared: Bool = false
    }

    // MARK: - Properties

    private let device: MTLDevice
    private let textureCache: CVMetalTextureCache
    private let commandQueue: MTLCommandQueue
    private let runtime: SceneRuntime
    private let sceneFPS: Double
    private let exportTextureProvider: MutableTextureProvider

    /// Video slots indexed by blockId
    private var slots: [String: VideoSlot] = [:]

    /// Binding asset IDs by blockId (built once at configure)
    private var bindingAssetIdsByBlockId: [String: [String]] = [:]

    /// Maximum active providers (from budget)
    private let maxActiveProviders: Int

    /// Whether coordinator has been configured
    private var isConfigured = false

    /// First provider error encountered (for propagation to VideoExporter)
    private(set) var providerError: ExportVideoFrameProviderError?

    // MARK: - Initialization

    /// Creates a video slots coordinator.
    ///
    /// - Parameters:
    ///   - device: Metal device
    ///   - textureCache: Shared CVMetalTextureCache (from VideoExporter)
    ///   - commandQueue: Metal command queue (plumbed for PR 6 blend pass)
    ///   - runtime: Scene runtime (for block timing and binding info)
    ///   - sceneFPS: Scene FPS
    ///   - exportTextureProvider: Mutable texture provider for injection
    ///   - videoPrefetchFrames: Number of frames to prefetch (from ExportResourceBudget)
    public init(
        device: MTLDevice,
        textureCache: CVMetalTextureCache,
        commandQueue: MTLCommandQueue,
        runtime: SceneRuntime,
        sceneFPS: Double,
        exportTextureProvider: MutableTextureProvider,
        videoPrefetchFrames: Int = 30,
        maxActiveProviders: Int = 4
    ) {
        self.device = device
        self.textureCache = textureCache
        self.commandQueue = commandQueue
        self.runtime = runtime
        self.sceneFPS = sceneFPS
        self.exportTextureProvider = exportTextureProvider
        self.videoPrefetchFrames = videoPrefetchFrames
        self.maxActiveProviders = maxActiveProviders

        // Build binding asset IDs map once (from runtime.blocks)
        buildBindingAssetIdsMap()
    }

    // MARK: - Configuration

    /// Configures the coordinator with video selections.
    ///
    /// Creates `ExportVideoFrameProvider` for each video block.
    ///
    /// - Parameter videoSelectionsByBlockId: Map of blockId → VideoSelection
    public func configure(videoSelectionsByBlockId: [String: VideoSelection]) {
        // Clear existing slots
        slots.removeAll()

        // Create provider for each video selection
        for (blockId, selection) in videoSelectionsByBlockId {
            // Skip invalid selections
            guard selection.isValid else {
                continue
            }

            // Get block timing from runtime
            guard let block = runtime.blocks.first(where: { $0.blockId == blockId }) else {
                continue
            }

            // Get binding asset IDs for this block
            guard let assetIds = bindingAssetIdsByBlockId[blockId], !assetIds.isEmpty else {
                continue
            }

            // Create config (time mapping now owned by coordinator)
            let config = ExportVideoFrameProvider.Config(selection: selection)

            // Create provider
            let provider = ExportVideoFrameProvider(
                device: device,
                textureCache: textureCache,
                commandQueue: commandQueue,
                config: config
            )

            // Store slot with block timing for visibility gating (B1)
            slots[blockId] = VideoSlot(
                blockId: blockId,
                provider: provider,
                bindingAssetIds: assetIds,
                startFrame: block.timing.startFrame,
                endFrame: block.timing.endFrame
            )
        }

        isConfigured = true
    }

    /// Releases all providers' decoded state while keeping configuration.
    /// Used by residency controller during scene eviction.
    public func releaseProviders() {
        for (_, slot) in slots {
            slot.provider.releaseDecodedState()
        }
    }

    // MARK: - Frame Update

    /// Updates textures for all video slots at the given scene frame.
    ///
    /// B1: Visibility gating — only processes slots that are visible at the current frame
    /// (with prefetch margin for decode latency).
    ///
    /// For each visible video block:
    /// 1. Gets texture from provider
    /// 2. Checks for provider errors (P0 #2 fix)
    /// 3. Injects texture into all binding asset IDs
    ///
    /// - Parameter sceneFrameIndex: Scene frame index
    public func updateTextures(forSceneFrameIndex sceneFrameIndex: Int) {
        let prefetchFrames = videoPrefetchFrames
        let suspendMargin = prefetchFrames * 2

        // Collect visible and far-away slots
        var visibleBlockIds: [String] = []

        for (blockId, slot) in slots {
            let visibilityStart = max(0, slot.startFrame - prefetchFrames)
            let isVisible = sceneFrameIndex >= visibilityStart && sceneFrameIndex < slot.endFrame

            if isVisible {
                visibleBlockIds.append(blockId)

                // Lazy prepare on visibility hit
                if !slot.isPrepared {
                    do {
                        try slot.provider.prepareIfNeeded()
                        slots[blockId]?.isPrepared = true

                        // Inject presentation info once after prepare
                        if let info = slot.provider.presentationInfo {
                            for assetId in slot.bindingAssetIds {
                                (exportTextureProvider as? MutableAssetPresentationInfoProvider)?
                                    .setPresentationInfo(info, for: assetId)
                            }
                        }
                    } catch {
                        if providerError == nil {
                            providerError = error as? ExportVideoFrameProviderError
                        }
                        continue
                    }
                }

                // Check for provider error
                if let error = slot.provider.providerError, providerError == nil {
                    providerError = error
                }

                // Coordinator owns time mapping via shared mapper
                let mapped = VideoTimelineTimeMapper.targetVideoTime(
                    sceneFrameIndex: sceneFrameIndex,
                    blockStartFrame: slot.startFrame,
                    sceneFPS: sceneFPS,
                    selection: slot.provider.config.selection
                )
                guard let texture = slot.provider.texture(
                    forTargetVideoTime: mapped.targetVideoTimeSeconds
                ) else {
                    continue
                }

                for assetId in slot.bindingAssetIds {
                    exportTextureProvider.setTexture(texture, for: assetId)
                }
            } else if slot.isPrepared {
                // Suspend providers that are far from current frame
                let distanceFromEnd = sceneFrameIndex - slot.endFrame
                let distanceFromStart = slot.startFrame - sceneFrameIndex
                let distance = max(distanceFromEnd, distanceFromStart)

                if distance > suspendMargin {
                    slot.provider.suspend()
                    slots[blockId]?.isPrepared = false
                }
            }
        }

        // Enforce maxActiveProviders: suspend furthest if over limit
        let preparedSlots = slots.filter { $0.value.isPrepared }
        if preparedSlots.count > maxActiveProviders {
            let sorted = preparedSlots.sorted { a, b in
                let distA = abs(sceneFrameIndex - (a.value.startFrame + a.value.endFrame) / 2)
                let distB = abs(sceneFrameIndex - (b.value.startFrame + b.value.endFrame) / 2)
                return distA > distB
            }
            for (blockId, slot) in sorted.prefix(preparedSlots.count - maxActiveProviders) {
                slot.provider.suspend()
                slots[blockId]?.isPrepared = false
            }
        }
    }

    // MARK: - Lifecycle

    /// Finishes all providers and releases resources.
    public func finish() {
        for (_, slot) in slots {
            slot.provider.finish()
        }
        slots.removeAll()
        isConfigured = false
    }

    /// Cancels all providers immediately.
    public func cancel() {
        for (_, slot) in slots {
            slot.provider.cancel()
        }
        slots.removeAll()
        isConfigured = false
    }

    // MARK: - Private

    /// Builds binding asset IDs map from runtime blocks (once).
    ///
    /// For each block, collects all variant binding asset IDs.
    /// This matches `ScenePlayer.bindingAssetIdsByVariant` but without @MainActor dependency.
    private func buildBindingAssetIdsMap() {
        for block in runtime.blocks {
            var assetIds: [String] = []
            for variant in block.variants {
                let assetId = variant.animIR.binding.boundAssetId
                if !assetIds.contains(assetId) {
                    assetIds.append(assetId)
                }
            }
            bindingAssetIdsByBlockId[block.blockId] = assetIds
        }
    }
}
