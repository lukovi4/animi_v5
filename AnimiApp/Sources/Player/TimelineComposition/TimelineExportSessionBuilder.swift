import AVFoundation
import Foundation
import TVECore

// MARK: - Timeline Export Session Builder

/// Stateless builder that assembles a `TimelineExportSession` from engine state.
/// Extracted from `TimelineCompositionEngine` to isolate export-only assembly logic.
@MainActor
internal enum TimelineExportSessionBuilder {

    // MARK: - Input Context

    /// Everything the builder needs from the engine facade.
    struct Context {
        let transitionMath: TimelineTransitionMath
        let timeline: CanonicalTimeline
        let sceneStates: [UUID: SceneState]
        let currentAssetRegistry: ProjectAssetRegistry
        let resourcesCache: SceneTypeResourcesCache
        let mediaLocator: any ProjectMediaLocator
        let stickerProvider: StickerProviding?
        let fps: Int
        let canvasSize: SizeD
    }

    // MARK: - Build

    static func build(context: Context) async throws -> TimelineCompositionEngine.TimelineExportSession {
        let math = context.transitionMath
        let timeline = context.timeline

        var scenesByInstanceId: [UUID: TimelineCompositionEngine.TimelineExportSceneSnapshot] = [:]
        var audioSceneData: [TimelineCompositionEngine.SceneAudioExportData] = []

        for (index, item) in math.sceneItems.enumerated() {
            let instanceId = item.id

            // 1. Resolve sceneTypeId from timeline payload (no runtime needed)
            guard let tlItem = timeline.sceneItems.first(where: { $0.id == instanceId }),
                  let payload = timeline.payloads[tlItem.payloadId],
                  case .scene(let scenePayload) = payload else {
                throw TimelineCompositionEngine.TimelineExportSessionBuildError.missingRuntime(instanceId)
            }
            let sceneTypeId = scenePayload.sceneTypeId

            // 2. Resources: full cache if warm, metadata-only preload if cold.
            //    NEVER calls full preload() or getOrCreateRuntime() for cold scenes.
            let resources: SceneTypeResourcesCache.Resources
            if let cached = context.resourcesCache.resources(for: sceneTypeId) {
                resources = cached
            } else {
                resources = try await context.resourcesCache.preloadMetadata(sceneTypeId: sceneTypeId)
            }

            // 3. Persisted-only: state and media slots (already hydrated at project-load time)
            let state = context.sceneStates[instanceId] ?? .empty
            let mediaSlots = state.mediaSlotsByBlockId ?? [:]

            // 4. Build media snapshot first (async — probes video duration, resolves URLs)
            let compiled = resources.compiled
            let mediaSnapshot = try await ExportMediaSnapshot.build(
                compiledScene: compiled,
                mediaSlots: mediaSlots,
                mediaLocator: context.mediaLocator,
                assetRegistry: context.currentAssetRegistry,
                runtime: compiled.runtime
            )

            // 5. Render state from sceneStates (no runtime needed)
            let userMediaPresent: [String: Bool] = mediaSlots.reduce(into: [:]) { result, entry in
                result[entry.key] = entry.value.visibility
            }

            // PR4: Resolve placement → Matrix2D for export parity with preview.
            let resolvedTransforms = await resolveTransformsForExport(
                state: state,
                compiled: compiled,
                mediaSnapshot: mediaSnapshot
            )

            let renderState = SceneRenderStateSnapshot(
                resolvedTransforms: resolvedTransforms,
                variantOverrides: state.variantOverrides,
                userMediaPresent: userMediaPresent,
                layerToggleState: state.layerToggles
            )

            // Derive videoSelections from validated mediaSnapshot.videoRefs
            var videoSelections: [String: VideoSelection] = [:]
            for ref in mediaSnapshot.videoRefs {
                videoSelections[ref.blockId] = ref.selection
            }

            let snapshot = TimelineCompositionEngine.TimelineExportSceneSnapshot(
                sceneIndex: index,
                instanceId: instanceId,
                runtime: compiled.runtime,
                renderState: renderState,
                videoSelections: videoSelections,
                mediaSnapshot: mediaSnapshot,
                assetIndex: compiled.mergedAssetIndex,
                resolver: resources.resolver,
                bindingAssetIds: compiled.bindingAssetIds,
                pathRegistry: resources.pathRegistry,
                assetSizes: resources.assetSizes,
                sceneCanvasSize: resources.canvasSize,
                templateBackground: compiled.runtime.scene.background
            )
            scenesByInstanceId[instanceId] = snapshot

            audioSceneData.append(TimelineCompositionEngine.SceneAudioExportData(
                sceneIndex: index,
                runtime: compiled.runtime,
                videoSelections: videoSelections
            ))
        }

        // Build unified overlay snapshot from timeline + sticker provider
        let textOverlayTuples: [(item: TimelineItem, payload: TextPayload)] =
            (timeline.overlayTrack?.items ?? []).compactMap { item in
                guard item.kind == .text,
                      let payload = timeline.payloads[item.payloadId],
                      case .text(let textPayload) = payload else { return nil }
                return (item: item, payload: textPayload)
            }

        let stickerOverlayTuples: [(item: TimelineItem, payload: StickerPayload, imageURL: URL)] =
            (timeline.overlayTrack?.items ?? []).compactMap { item in
                guard item.kind == .sticker,
                      let payload = timeline.payloads[item.payloadId],
                      case .sticker(let stickerPayload) = payload,
                      let imageURL = context.stickerProvider?.resourceURL(for: stickerPayload.stickerId) else { return nil }
                return (item: item, payload: stickerPayload, imageURL: imageURL)
            }

        let overlaySnapshot = OverlayExportSnapshot.build(
            textOverlayItems: textOverlayTuples,
            stickerOverlayItems: stickerOverlayTuples
        )

        return TimelineCompositionEngine.TimelineExportSession(
            transitionMath: math,
            canvasSize: context.canvasSize,
            fps: context.fps,
            scenesByInstanceId: scenesByInstanceId,
            audioSceneData: audioSceneData,
            overlaySnapshot: overlaySnapshot
        )
    }

    // MARK: - Export-Only Helpers

    /// Resolves placement-based transforms for export.
    /// Uses actual media dimensions from ExportMediaSnapshot for correct cover/contain/fill.
    private static func resolveTransformsForExport(
        state: SceneState,
        compiled: CompiledScene,
        mediaSnapshot: ExportMediaSnapshot
    ) async -> [String: Matrix2D] {
        var transforms: [String: Matrix2D] = [:]

        // Build media size lookup from snapshot
        var mediaSizes: [String: (Double, Double)] = [:]
        for ref in mediaSnapshot.imageRefs {
            if let size = probeImageSize(url: ref.url) {
                mediaSizes[ref.blockId] = size
            }
        }
        for ref in mediaSnapshot.videoRefs {
            if let size = await probeVideoSize(url: ref.selection.url) {
                mediaSizes[ref.blockId] = size
            }
        }

        if let slots = state.mediaSlotsByBlockId {
            let blocks = compiled.runtime.blocks
            for (blockId, slot) in slots {
                let placement = slot.asset.placement
                guard let block = blocks.first(where: { $0.blockId == blockId }) else { continue }

                let baselineRect = block.bindingBaseline.contentRectLocal
                let mediaW: Double
                let mediaH: Double
                if let size = mediaSizes[blockId] {
                    mediaW = size.0
                    mediaH = size.1
                } else {
                    mediaW = baselineRect.width
                    mediaH = baselineRect.height
                }

                let geometry = MediaPlacementResolver.SlotGeometry(
                    baselineRectLocal: baselineRect,
                    mediaWidth: mediaW,
                    mediaHeight: mediaH
                )
                transforms[blockId] = MediaPlacementResolver.resolve(
                    placement: placement,
                    geometry: geometry
                )
            }
        }

        return transforms
    }

    /// Probes image dimensions from file URL (synchronous, lightweight via ImageIO).
    static func probeImageSize(url: URL) -> (Double, Double)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        guard let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double else { return nil }

        // Apply EXIF orientation
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        if orientation >= 5 && orientation <= 8 {
            return (height, width) // rotated 90/270
        }
        return (width, height)
    }

    /// Probes video oriented size from file URL via AVURLAsset.
    static func probeVideoSize(url: URL) async -> (Double, Double)? {
        let asset = AVURLAsset(url: url)
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else { return nil }
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let oriented = CGRect(origin: .zero, size: size).applying(transform).standardized.size
            return (Double(oriented.width), Double(oriented.height))
        } catch {
            return nil
        }
    }
}
