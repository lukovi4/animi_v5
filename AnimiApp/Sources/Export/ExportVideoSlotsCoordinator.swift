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
/// Usage:
/// ```swift
/// let coordinator = ExportVideoSlotsCoordinator(
///     device: device,
///     textureCache: cache,
///     runtime: compiledScene.runtime,
///     sceneFPS: 30,
///     exportTextureProvider: textureProvider
/// )
/// coordinator.configure(videoSelectionsByBlockId: selections)
/// try coordinator.prepareAll()
///
/// for frame in 0..<totalFrames {
///     coordinator.updateTextures(forSceneFrameIndex: frame)
///     // render frame...
/// }
///
/// coordinator.finish()
/// ```
public final class ExportVideoSlotsCoordinator {
    // MARK: - Types

    /// Internal state for a video slot
    private struct VideoSlot {
        let blockId: String
        let provider: ExportVideoFrameProvider
        let bindingAssetIds: [String]
    }

    // MARK: - Properties

    private let device: MTLDevice
    private let textureCache: CVMetalTextureCache
    private let runtime: SceneRuntime
    private let sceneFPS: Double
    private let exportTextureProvider: MutableTextureProvider

    /// Video slots indexed by blockId
    private var slots: [String: VideoSlot] = [:]

    /// Binding asset IDs by blockId (built once at configure)
    private var bindingAssetIdsByBlockId: [String: [String]] = [:]

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
    ///   - runtime: Scene runtime (for block timing and binding info)
    ///   - sceneFPS: Scene FPS
    ///   - exportTextureProvider: Mutable texture provider for injection
    public init(
        device: MTLDevice,
        textureCache: CVMetalTextureCache,
        runtime: SceneRuntime,
        sceneFPS: Double,
        exportTextureProvider: MutableTextureProvider
    ) {
        self.device = device
        self.textureCache = textureCache
        self.runtime = runtime
        self.sceneFPS = sceneFPS
        self.exportTextureProvider = exportTextureProvider

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

            // Create config
            let config = ExportVideoFrameProvider.Config(
                selection: selection,
                blockTiming: block.timing,
                sceneFPS: sceneFPS
            )

            // Create provider
            let provider = ExportVideoFrameProvider(
                device: device,
                textureCache: textureCache,
                config: config
            )

            // Store slot
            slots[blockId] = VideoSlot(
                blockId: blockId,
                provider: provider,
                bindingAssetIds: assetIds
            )
        }

        isConfigured = true
    }

    /// Prepares all providers for reading.
    ///
    /// Must be called after `configure` and before `updateTextures`.
    public func prepareAll() throws {
        for (_, slot) in slots {
            try slot.provider.prepare()
        }
    }

    // MARK: - Frame Update

    /// Updates textures for all video slots at the given scene frame.
    ///
    /// For each video block:
    /// 1. Gets texture from provider
    /// 2. Checks for provider errors (P0 #2 fix)
    /// 3. Injects texture into all binding asset IDs
    ///
    /// - Parameter sceneFrameIndex: Scene frame index
    public func updateTextures(forSceneFrameIndex sceneFrameIndex: Int) {
        for (_, slot) in slots {
            // P0 #2: Check for provider error and capture first one
            if let error = slot.provider.providerError, providerError == nil {
                providerError = error
            }

            guard let texture = slot.provider.texture(forSceneFrameIndex: sceneFrameIndex) else {
                continue
            }

            // Inject texture into all binding asset IDs for this block
            for assetId in slot.bindingAssetIds {
                exportTextureProvider.setTexture(texture, for: assetId)
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
