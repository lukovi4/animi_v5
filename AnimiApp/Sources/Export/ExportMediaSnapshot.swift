import AVFoundation
import Foundation
import TVECore

// MARK: - Export Media Error

/// Errors during export media snapshot construction.
public enum ExportMediaError: Error, LocalizedError {
    case missingPersistedPhoto(blockId: String, assetId: String)
    case missingPersistedVideo(blockId: String)
    case missingVideoWindow(blockId: String)
    case invalidVideoSelection(blockId: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .missingPersistedPhoto(let blockId, let assetId):
            return "Missing persisted photo for block '\(blockId)', assetId '\(assetId)'"
        case .missingPersistedVideo(let blockId):
            return "Missing persisted video for block '\(blockId)'"
        case .missingVideoWindow(let blockId):
            return "Missing video window for block '\(blockId)'"
        case .invalidVideoSelection(let blockId, let reason):
            return "Invalid video selection for block '\(blockId)': \(reason)"
        }
    }
}

// MARK: - Export Media Snapshot

/// Lightweight export-safe descriptor for **user media only**.
///
/// Contains URLs and metadata — NO live MTLTextures.
/// Built from persisted scene media slots plus an injected registry-backed media locator.
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

        /// Video selection with trim/audio parameters
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
    /// resolved via the injected registry-backed `ProjectMediaLocator`.
    ///
    /// - Parameters:
    ///   - compiledScene: Compiled scene with asset index
    ///   - mediaSlots: Unified media slots (blockId -> SceneMediaSlot) from EditorStore
    ///   - mediaLocator: Registry-backed locator for URL resolution
    ///   - assetRegistry: Project's asset registry snapshot, passed explicitly so
    ///     export resolves via `assetId` → descriptor → `storagePath`.
    ///   - runtime: Scene runtime for block/variant binding info
    /// - Returns: Snapshot with resolved user media references
    /// - Throws: `ExportMediaError` if a visible media slot has missing/invalid data
    static func build(
        compiledScene: CompiledScene,
        mediaSlots: [String: SceneMediaSlot],
        mediaLocator: any ProjectMediaLocator,
        assetRegistry: ProjectAssetRegistry,
        runtime: SceneRuntime
    ) async throws -> ExportMediaSnapshot {
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
                guard let url = try? await mediaLocator.absoluteURL(for: slot.mediaRef, registry: assetRegistry),
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
                guard let videoWindow = slot.videoWindow else {
                    throw ExportMediaError.missingVideoWindow(blockId: blockId)
                }
                guard let url = try? await mediaLocator.absoluteURL(for: slot.mediaRef, registry: assetRegistry),
                      FileManager.default.fileExists(atPath: url.path) else {
                    throw ExportMediaError.missingPersistedVideo(blockId: blockId)
                }

                // Probe actual duration for strict validation
                let asset = AVURLAsset(url: url)
                let durationSeconds: Double
                do {
                    let duration = try await asset.load(.duration)
                    durationSeconds = CMTimeGetSeconds(duration)
                } catch {
                    throw ExportMediaError.invalidVideoSelection(
                        blockId: blockId,
                        reason: "Failed to load video duration: \(error.localizedDescription)"
                    )
                }

                let selection: VideoSelection
                do {
                    selection = try VideoWindowValidator.validate(
                        selection: videoWindow,
                        url: url,
                        actualDuration: durationSeconds,
                        blockId: blockId
                    )
                } catch let validationError {
                    throw ExportMediaError.invalidVideoSelection(
                        blockId: blockId,
                        reason: validationError.localizedDescription
                    )
                }

                videoRefs.append(VideoRef(
                    blockId: blockId,
                    selection: selection,
                    bindingAssetIds: bindingAssetIds
                ))

            case .audio:
                // Audio media kind is not used in scene media slots — skip
                break
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
}
