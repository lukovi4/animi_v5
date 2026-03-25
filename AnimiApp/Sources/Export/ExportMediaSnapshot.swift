import Foundation
import TVECore

// MARK: - Export Media Error

/// Errors during export media snapshot construction.
public enum ExportMediaError: Error, LocalizedError {
    case missingPersistedPhoto(blockId: String, assetId: String)
    case missingPersistedVideo(blockId: String)

    public var errorDescription: String? {
        switch self {
        case .missingPersistedPhoto(let blockId, let assetId):
            return "Missing persisted photo for block '\(blockId)', assetId '\(assetId)'"
        case .missingPersistedVideo(let blockId):
            return "Missing persisted video for block '\(blockId)'"
        }
    }
}

// MARK: - Export Media Snapshot

/// Lightweight export-safe descriptor for **user media only**.
///
/// Contains URLs and metadata — NO live MTLTextures.
/// Built from persisted `mediaAssignments` (EditorStore) + `ProjectStore`.
///
/// Background media is handled separately via `ExportBackgroundSnapshot`.
public struct ExportMediaSnapshot: Sendable {

    // MARK: - Image Reference

    /// Reference to a user photo for export.
    public struct ImageRef: Sendable, Equatable {
        /// Block ID that owns this photo
        public let blockId: String

        /// All variant binding asset IDs for this block
        public let bindingAssetIds: [String]

        /// Resolved file URL
        public let url: URL
    }

    // MARK: - Video Reference

    /// Reference to a user video for export.
    public struct VideoRef: Sendable {
        /// Block ID that owns this video
        public let blockId: String

        /// Video selection with trim/offset parameters
        public let selection: VideoSelection

        /// Binding asset IDs that this video injects into
        public let bindingAssetIds: [String]
    }

    // MARK: - Properties

    /// All user photo references (binding assets with resolved URLs)
    public let imageRefs: [ImageRef]

    /// All user video references
    public let videoRefs: [VideoRef]

    /// All asset IDs from the template asset index (for warm loading)
    public let allAssetIds: Set<String>

    // MARK: - Factory (unified media slots)

    /// Builds an ExportMediaSnapshot from persisted SceneMediaSlots.
    ///
    /// Source of truth: `editorStore.state.draft.sceneInstanceStates[instanceId].mediaSlotsByBlockId`
    /// resolved via `ProjectStore.absoluteURL(for:)`.
    ///
    /// - Parameters:
    ///   - compiledScene: Compiled scene with asset index
    ///   - mediaSlots: Unified media slots (blockId -> SceneMediaSlot) from EditorStore
    ///   - projectStore: Project store for URL resolution
    ///   - runtime: Scene runtime for block/variant binding info
    /// - Returns: Snapshot with resolved user media references
    /// - Throws: `ExportMediaError.missingPersistedPhoto` if a photo file is not found
    public static func build(
        compiledScene: CompiledScene,
        mediaSlots: [String: SceneMediaSlot],
        projectStore: ProjectStore,
        runtime: SceneRuntime
    ) throws -> ExportMediaSnapshot {
        var imageRefs: [ImageRef] = []
        var videoRefs: [VideoRef] = []

        for (blockId, slot) in mediaSlots {
            // Skip hidden slots
            guard slot.visibility else { continue }

            // Collect ALL binding asset IDs for this block from runtime
            var bindingAssetIds: [String] = []
            if let block = runtime.blocks.first(where: { $0.blockId == blockId }) {
                for variant in block.variants {
                    let assetId = variant.animIR.binding.boundAssetId
                    if !bindingAssetIds.contains(assetId) {
                        bindingAssetIds.append(assetId)
                    }
                }
            }

            switch slot.mediaRef.mediaKind {
            case .photo:
                guard let url = try? projectStore.absoluteURL(for: slot.mediaRef),
                      FileManager.default.fileExists(atPath: url.path) else {
                    let assetId = bindingAssetIds.first ?? "unknown"
                    throw ExportMediaError.missingPersistedPhoto(blockId: blockId, assetId: assetId)
                }
                imageRefs.append(ImageRef(
                    blockId: blockId,
                    bindingAssetIds: bindingAssetIds,
                    url: url
                ))

            case .video:
                guard let videoWindow = slot.videoWindow else { continue }
                guard let url = try? projectStore.absoluteURL(for: slot.mediaRef),
                      FileManager.default.fileExists(atPath: url.path) else {
                    throw ExportMediaError.missingPersistedVideo(blockId: blockId)
                }
                let selection = videoWindow.toVideoSelection(url: url)
                guard selection.isValid else { continue }

                videoRefs.append(VideoRef(
                    blockId: blockId,
                    selection: selection,
                    bindingAssetIds: bindingAssetIds
                ))
            }
        }

        // Template asset IDs only (user photos are injected separately)
        let allAssetIds = Set(compiledScene.mergedAssetIndex.basenameById.keys)

        return ExportMediaSnapshot(
            imageRefs: imageRefs,
            videoRefs: videoRefs,
            allAssetIds: allAssetIds
        )
    }

    // MARK: - Legacy Factory (CompositeAssetResolver)

    /// Legacy factory for backward compatibility.
    /// Uses CompositeAssetResolver instead of persisted mediaAssignments.
    public static func build(
        from compiled: CompiledScene,
        resolver: CompositeAssetResolver,
        videoSelections: [String: VideoSelection],
        runtime: SceneRuntime
    ) -> ExportMediaSnapshot {
        // Collect image refs for binding assets that have user photos
        var imageRefs: [ImageRef] = []
        for assetId in compiled.bindingAssetIds {
            if let basename = compiled.mergedAssetIndex.basenameById[assetId],
               let url = try? resolver.resolveURL(forKey: basename) {
                imageRefs.append(ImageRef(
                    blockId: assetId,
                    bindingAssetIds: [assetId],
                    url: url
                ))
            }
        }

        // Collect video refs
        var videoRefs: [VideoRef] = []
        for (blockId, selection) in videoSelections {
            guard selection.isValid else { continue }

            var bindingAssetIds: [String] = []
            if let block = runtime.blocks.first(where: { $0.blockId == blockId }) {
                for variant in block.variants {
                    let assetId = variant.animIR.binding.boundAssetId
                    if !bindingAssetIds.contains(assetId) {
                        bindingAssetIds.append(assetId)
                    }
                }
            }

            videoRefs.append(VideoRef(
                blockId: blockId,
                selection: selection,
                bindingAssetIds: bindingAssetIds
            ))
        }

        let allAssetIds = Set(compiled.mergedAssetIndex.basenameById.keys)

        return ExportMediaSnapshot(
            imageRefs: imageRefs,
            videoRefs: videoRefs,
            allAssetIds: allAssetIds
        )
    }
}
