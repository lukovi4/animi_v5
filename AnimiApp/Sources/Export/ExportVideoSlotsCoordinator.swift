import AVFoundation
import CoreVideo
import Metal
import TVECore

// MARK: - Export Video Slots Coordinator

/// Coordinates video slot providers for export (PR-E3).
///
/// Stores slot metadata and creates providers lazily for visible/prefetch windows.
/// On each frame, updates textures in `ExportTextureProvider` for all binding asset IDs.
///
/// PR5-Fix: Lazy provider residency — providers exist only while their block is visible/prefetch.
/// Visible providers are never evicted. Budget only limits prefetch capacity.
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
///     coordinator.updateTextures(visibilityFrameIndex: frame, mediaFrameIndex: frame)
///     // render frame...
/// }
///
/// coordinator.finish()
/// ```
public final class ExportVideoSlotsCoordinator {
    // MARK: - Constants

    /// Prefetch margin in frames for visibility gating.
    /// Providers start decoding this many frames before block becomes visible.
    /// Configured via ExportResourceBudget.videoPrefetchFrames (default: half-FPS, min 12).
    private let videoPrefetchFrames: Int

    // MARK: - Types

    /// Internal state for a video slot
    private struct VideoSlot {
        let blockId: String
        let config: ExportVideoFrameProvider.Config
        let bindingAssetIds: [String]
        let startFrame: Int
        let endFrame: Int
        var provider: ExportVideoFrameProviding?
        var isPrepared: Bool = false
    }

    // MARK: - Properties

    private let device: MTLDevice
    private let textureCache: CVMetalTextureCache
    private let commandQueue: MTLCommandQueue
    private let runtime: SceneRuntime?
    private let sceneFPS: Double
    private let exportTextureProvider: MutableTextureProvider
    private let providerFactory: (String, ExportVideoFrameProvider.Config) -> ExportVideoFrameProviding

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
    ///   - maxActiveProviders: Maximum active providers (from budget)
    ///   - providerFactory: Optional factory for creating providers (test seam)
    public init(
        device: MTLDevice,
        textureCache: CVMetalTextureCache,
        commandQueue: MTLCommandQueue,
        runtime: SceneRuntime,
        sceneFPS: Double,
        exportTextureProvider: MutableTextureProvider,
        videoPrefetchFrames: Int = 15,
        maxActiveProviders: Int = 4,
        providerFactory: ((String, ExportVideoFrameProvider.Config) -> ExportVideoFrameProviding)? = nil
    ) {
        self.device = device
        self.textureCache = textureCache
        self.commandQueue = commandQueue
        self.runtime = runtime
        self.sceneFPS = sceneFPS
        self.exportTextureProvider = exportTextureProvider
        self.videoPrefetchFrames = videoPrefetchFrames
        self.maxActiveProviders = maxActiveProviders
        self.providerFactory = providerFactory ?? { _, config in
            ExportVideoFrameProvider(
                device: device,
                textureCache: textureCache,
                commandQueue: commandQueue,
                config: config
            )
        }

        buildBindingAssetIdsMap()
    }

    /// Test-only init without runtime.
    internal init(
        device: MTLDevice,
        textureCache: CVMetalTextureCache,
        commandQueue: MTLCommandQueue,
        sceneFPS: Double,
        exportTextureProvider: MutableTextureProvider,
        videoPrefetchFrames: Int = 15,
        maxActiveProviders: Int = 4,
        providerFactory: @escaping (String, ExportVideoFrameProvider.Config) -> ExportVideoFrameProviding
    ) {
        self.device = device
        self.textureCache = textureCache
        self.commandQueue = commandQueue
        self.runtime = nil
        self.sceneFPS = sceneFPS
        self.exportTextureProvider = exportTextureProvider
        self.videoPrefetchFrames = videoPrefetchFrames
        self.maxActiveProviders = maxActiveProviders
        self.providerFactory = providerFactory
    }

    // MARK: - Configuration

    /// Configures the coordinator with video selections.
    ///
    /// Stores metadata only — providers are created lazily on visibility.
    ///
    /// - Parameter videoSelectionsByBlockId: Map of blockId → VideoSelection
    public func configure(videoSelectionsByBlockId: [String: VideoSelection]) {
        guard let runtime = runtime else { return }

        // Clear existing slots
        slots.removeAll()

        // Store metadata for each video selection — no provider creation
        for (blockId, selection) in videoSelectionsByBlockId {
            guard selection.isValid else { continue }
            guard let block = runtime.blocks.first(where: { $0.blockId == blockId }) else { continue }
            guard let assetIds = bindingAssetIdsByBlockId[blockId], !assetIds.isEmpty else { continue }

            let config = ExportVideoFrameProvider.Config(selection: selection)

            slots[blockId] = VideoSlot(
                blockId: blockId,
                config: config,
                bindingAssetIds: assetIds,
                startFrame: block.timing.startFrame,
                endFrame: block.timing.endFrame
            )
        }

        isConfigured = true
    }

    /// Test seam: configure slots directly without runtime.
    internal func configureSlots(_ testSlots: [(blockId: String, config: ExportVideoFrameProvider.Config, bindingAssetIds: [String], startFrame: Int, endFrame: Int)]) {
        slots.removeAll()
        for s in testSlots {
            slots[s.blockId] = VideoSlot(blockId: s.blockId, config: s.config, bindingAssetIds: s.bindingAssetIds, startFrame: s.startFrame, endFrame: s.endFrame)
        }
        isConfigured = true
    }

    /// Releases all providers while keeping slot metadata.
    public func releaseProviders() {
        let blockIds = Array(slots.keys)
        for blockId in blockIds {
            teardownSlot(blockId: blockId)
        }
    }

    // MARK: - Frame Update

    /// Updates textures for all video slots at the given scene frame.
    ///
    /// 3-phase classify-then-mutate:
    /// 1. Visible — always create+prepare, get texture, inject. Never evicted.
    /// 2. Prefetch — remaining capacity only, no texture injection.
    /// 3. Far — terminal teardown (finish provider, clear textures).
    ///
    /// - Parameters:
    ///   - visibilityFrameIndex: Scene frame for visibility classification
    ///   - mediaFrameIndex: Scene frame for time mapping
    public func updateTextures(visibilityFrameIndex: Int, mediaFrameIndex: Int) {
        let sceneFrameIndex = visibilityFrameIndex
        let prefetchFrames = videoPrefetchFrames

        // --- Classify (read-only snapshot) ---
        let slotSnapshot = Array(slots.values)
        var visibleIds: [String] = []
        var prefetchOnly: [(blockId: String, distance: Int)] = []
        var farIds: [String] = []

        for slot in slotSnapshot {
            let isVisible = sceneFrameIndex >= slot.startFrame && sceneFrameIndex < slot.endFrame
            let prefetchStart = max(0, slot.startFrame - prefetchFrames)
            let isInPrefetch = sceneFrameIndex >= prefetchStart && sceneFrameIndex < slot.startFrame

            if isVisible {
                visibleIds.append(slot.blockId)
            } else if isInPrefetch {
                prefetchOnly.append((slot.blockId, slot.startFrame - sceneFrameIndex))
            } else {
                farIds.append(slot.blockId)
            }
        }

        // --- Phase 1: Visible — always create+prepare, get texture, inject. Never evict. ---
        for blockId in visibleIds {
            processVisibleSlot(blockId: blockId, mediaFrameIndex: mediaFrameIndex)
        }

        // --- Phase 2: Prefetch — remaining capacity only, NO texture injection ---
        let prefetchCapacity = max(0, maxActiveProviders - visibleIds.count)
        let sortedPrefetch = prefetchOnly.sorted { $0.distance < $1.distance }

        for (i, entry) in sortedPrefetch.enumerated() {
            if i < prefetchCapacity {
                processPrefetchSlot(blockId: entry.blockId)
            } else {
                teardownSlot(blockId: entry.blockId)
            }
        }

        // --- Phase 3: Far — terminal teardown ---
        for blockId in farIds {
            teardownSlot(blockId: blockId)
        }
    }

    // MARK: - Lifecycle

    /// Finishes all providers and releases resources.
    public func finish() {
        #if DEBUG
        MemoryDiagnostics.event("ExportVideoSlots.finish", "slots=\(slots.count)")
        #endif
        let blockIds = Array(slots.keys)
        for blockId in blockIds {
            teardownSlot(blockId: blockId)
        }
        slots.removeAll()
        isConfigured = false
    }

    /// Cancels all providers immediately.
    public func cancel() {
        #if DEBUG
        MemoryDiagnostics.event("ExportVideoSlots.cancel")
        #endif
        let blockIds = Array(slots.keys)
        for blockId in blockIds {
            guard var slot = slots[blockId] else { continue }
            slot.provider?.cancel()
            slot.provider = nil
            slot.isPrepared = false
            slots[blockId] = slot
            for assetId in slot.bindingAssetIds {
                exportTextureProvider.removeTexture(for: assetId)
                (exportTextureProvider as? MutableAssetPresentationInfoProvider)?
                    .removePresentationInfo(for: assetId)
            }
        }
        slots.removeAll()
        isConfigured = false
    }

    // MARK: - Private Helpers

    private func processVisibleSlot(blockId: String, mediaFrameIndex: Int) {
        guard var slot = slots[blockId] else { return }

        // Lazy provider creation
        if slot.provider == nil {
            slot.provider = providerFactory(blockId, slot.config)
            slots[blockId] = slot
        }

        // Lazy prepare
        if !slot.isPrepared {
            do {
                try slot.provider?.prepareIfNeeded()
                slot.isPrepared = true
                slots[blockId] = slot

                if let info = slot.provider?.presentationInfo {
                    for assetId in slot.bindingAssetIds {
                        (exportTextureProvider as? MutableAssetPresentationInfoProvider)?
                            .setPresentationInfo(info, for: assetId)
                    }
                }
            } catch {
                if providerError == nil {
                    providerError = error as? ExportVideoFrameProviderError
                }
                teardownSlot(blockId: blockId)
                return
            }
        }

        // Error check
        if let error = slot.provider?.providerError, providerError == nil {
            providerError = error
        }

        // Get texture and inject
        let mapped = VideoTimelineTimeMapper.targetVideoTime(
            sceneFrameIndex: mediaFrameIndex,
            blockStartFrame: slot.startFrame,
            sceneFPS: sceneFPS,
            selection: slot.config.selection
        )
        guard let texture = slot.provider?.texture(forTargetVideoTime: mapped.targetVideoTimeSeconds) else {
            return
        }
        for assetId in slot.bindingAssetIds {
            exportTextureProvider.setTexture(texture, for: assetId)
        }
    }

    private func processPrefetchSlot(blockId: String) {
        guard var slot = slots[blockId] else { return }

        if slot.provider == nil {
            slot.provider = providerFactory(blockId, slot.config)
            slots[blockId] = slot
        }

        if !slot.isPrepared {
            do {
                try slot.provider?.prepareIfNeeded()
                slot.isPrepared = true
                slots[blockId] = slot

                if let info = slot.provider?.presentationInfo {
                    for assetId in slot.bindingAssetIds {
                        (exportTextureProvider as? MutableAssetPresentationInfoProvider)?
                            .setPresentationInfo(info, for: assetId)
                    }
                }
            } catch {
                if providerError == nil {
                    providerError = error as? ExportVideoFrameProviderError
                }
                teardownSlot(blockId: blockId)
            }
        }
    }

    private func teardownSlot(blockId: String) {
        guard var slot = slots[blockId] else { return }

        slot.provider?.finish()
        slot.provider = nil
        slot.isPrepared = false
        slots[blockId] = slot

        // Always remove injected textures and presentation info
        for assetId in slot.bindingAssetIds {
            exportTextureProvider.removeTexture(for: assetId)
            (exportTextureProvider as? MutableAssetPresentationInfoProvider)?
                .removePresentationInfo(for: assetId)
        }
    }

    private func buildBindingAssetIdsMap() {
        guard let runtime = runtime else { return }
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

    // MARK: - Debug

    #if DEBUG
    struct DebugSlotSnapshot {
        let blockId: String
        let hasProvider: Bool
        let isPrepared: Bool
    }

    func debugSlotSnapshot() -> [DebugSlotSnapshot] {
        slots.values
            .map { DebugSlotSnapshot(blockId: $0.blockId, hasProvider: $0.provider != nil, isPrepared: $0.isPrepared) }
            .sorted { $0.blockId < $1.blockId }
    }
    #endif
}
