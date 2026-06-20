#if DEBUG
import Foundation
import TVECore

// MARK: - CP6: AnimiEngineNext export input builder (DEBUG only)
//
// Assembles `NextBridgeInputs` (single-scene) / `NextBridgeTimelineInputs` (timeline) for the
// AnimiEngineNext VIDEO EXPORT path, mirroring the preview assembly in `EditorViewController`
// (`makeNextSingleSceneInputs` / `makeNextTimelineInputs`) but sourced from EXPORT context:
//
//  - Single-scene: photo URLs come from the already-resolved `ExportMediaSnapshot` (NOT the async
//    preview URL cache); placement / variantOverrides / sceneTypeId come from the live `SceneState`
//    (single-scene export has no immutable session, and the controller captures these before any
//    teardown).
//  - Timeline: EVERYTHING comes from the immutable `TimelineExportSession` — photo URLs from each
//    scene's `mediaSnapshot`, raw placement from `rawPlacements`, variantOverrides from
//    `renderState.variantOverrides`, sceneTypeId from the captured `sceneTypeId`, and boundary
//    transitions from `transitionMath`. Live editor state is NOT read after the session is built.
//
// Photo + VIDEO (CP7) scope. Any other media kind, hidden block, missing media, unresolved URL, or
// missing scene folder FAILS CLOSED with a typed `NextBridgeError` — never a silent fallback. Video
// blocks carry their validated trim window from the export snapshot's `videoRefs`.
enum NextExportInputsBuilder {

    // MARK: - Single-scene

    /// Build single-scene Next inputs from the resolved export media snapshot + live scene state.
    /// `mediaSnapshot.imageRefs`/`videoRefs` already carry resolved URLs + validated trim (sync), so
    /// we do not re-resolve.
    @MainActor
    static func makeSingleScene(
        sceneTypeId: String,
        sceneFolderURL: URL,
        sceneState: SceneState,
        mediaSnapshot: ExportMediaSnapshot,
        frameIndex: Int,
        timelineDurationFrames: Int? = nil
    ) throws -> NextBridgeInputs {
        let slots = sceneState.mediaSlotsByBlockId ?? [:]
        guard !slots.isEmpty else { throw NextBridgeError.noMediaBound(blockID: "(none)") }

        // Resolved photo URL per block from the export snapshot (single source of truth for URLs).
        let urlByBlock: [String: URL] = mediaSnapshot.imageRefs.reduce(into: [:]) { result, ref in
            result[ref.blockId] = ref.url
        }
        // Resolved + validated video selection per block (URL + winStart/winEnd live inside).
        let videoByBlock: [String: VideoSelection] = mediaSnapshot.videoRefs.reduce(into: [:]) { result, ref in
            result[ref.blockId] = ref.selection
        }

        let blocks = try makeBlocks(slots: slots, urlByBlock: urlByBlock, videoByBlock: videoByBlock)
        return NextBridgeInputs(
            sceneTypeId: sceneTypeId,
            sceneFolderURL: sceneFolderURL,
            variantOverrides: sceneState.variantOverrides,
            blocks: blocks,
            frameIndex: frameIndex,
            timelineDurationFrames: timelineDurationFrames)
    }

    // MARK: - Single-scene from an immutable timeline snapshot (CP7: 1-scene timeline export)

    /// Build single-scene Next inputs from ONE immutable `TimelineExportSceneSnapshot`. Used when the
    /// export route is "timeline" (the timeline engine is active) but the project has exactly ONE
    /// scene — that must go through the single-scene Next path, not the >= 2-scene timeline bridge.
    @MainActor
    static func makeSingleScene(
        snapshot snap: TimelineCompositionEngine.TimelineExportSceneSnapshot,
        sceneFolderURL: URL,
        frameIndex: Int,
        timelineDurationFrames: Int? = nil
    ) throws -> NextBridgeInputs {
        let imageRefs = snap.mediaSnapshot.imageRefs
        let videoRefs = snap.mediaSnapshot.videoRefs
        guard !imageRefs.isEmpty || !videoRefs.isEmpty else {
            throw NextBridgeError.noMediaBound(blockID: "(none)")
        }
        let urlByBlock: [String: URL] = imageRefs.reduce(into: [:]) { $0[$1.blockId] = $1.url }
        let videoByBlock: [String: VideoSelection] = videoRefs.reduce(into: [:]) { $0[$1.blockId] = $1.selection }
        let blocks = try makeBlocks(placements: snap.rawPlacements, urlByBlock: urlByBlock, videoByBlock: videoByBlock)
        return NextBridgeInputs(
            sceneTypeId: snap.sceneTypeId,
            sceneFolderURL: sceneFolderURL,
            variantOverrides: snap.renderState.variantOverrides,
            blocks: blocks,
            frameIndex: frameIndex,
            timelineDurationFrames: timelineDurationFrames)
    }

    // MARK: - Timeline

    /// Build timeline Next inputs PURELY from the immutable export session (snapshot-stable). The
    /// caller supplies a scene-folder resolver (the only piece not captured in the session) and a
    /// nominal project frame for evaluation. Boundary transitions come from `transitionMath`.
    @MainActor
    static func makeTimeline(
        session: TimelineCompositionEngine.TimelineExportSession,
        sceneFolderURL: (_ sceneTypeId: String) -> URL?,
        nominalFrameIndex: Int
    ) throws -> NextBridgeTimelineInputs {
        let math = session.transitionMath
        let sceneItems = math.sceneItems
        guard sceneItems.count >= 2 else {
            // Single-scene timelines must use the single-scene path (matches CP5 preview contract).
            throw NextBridgeError.multiSceneUnsupported(sceneItemCount: sceneItems.count)
        }

        var scenes: [NextBridgeTimelineScene] = []
        for i in sceneItems.indices {
            let item = sceneItems[i]
            guard let snap = session.scenesByInstanceId[item.id] else {
                throw NextBridgeError.noScene
            }
            guard let folderURL = sceneFolderURL(snap.sceneTypeId) else {
                throw NextBridgeError.sceneFolderMissing(sceneTypeId: snap.sceneTypeId)
            }

            let imageRefs = snap.mediaSnapshot.imageRefs
            let videoRefs = snap.mediaSnapshot.videoRefs
            guard !imageRefs.isEmpty || !videoRefs.isEmpty else {
                throw NextBridgeError.noMediaBound(blockID: "(none)")
            }
            let urlByBlock: [String: URL] = imageRefs.reduce(into: [:]) { result, ref in
                result[ref.blockId] = ref.url
            }
            let videoByBlock: [String: VideoSelection] = videoRefs.reduce(into: [:]) { result, ref in
                result[ref.blockId] = ref.selection
            }

            // Raw placement + variant come from the immutable snapshot (not live state).
            let blocks = try makeBlocks(placements: snap.rawPlacements, urlByBlock: urlByBlock, videoByBlock: videoByBlock)
            // CP7 stretch guard: this scene's timeline span in frames (from the immutable session).
            let timelineFrames = Int((item.durationUs &* Int64(math.fps)) / 1_000_000)
            let single = NextBridgeInputs(
                sceneTypeId: snap.sceneTypeId,
                sceneFolderURL: folderURL,
                variantOverrides: snap.renderState.variantOverrides,
                blocks: blocks,
                frameIndex: 0,
                timelineDurationFrames: timelineFrames)

            // Boundary transition from THIS scene to the next (nil for the last scene / cut).
            var transitionToNext: NextBridgeTransition? = nil
            if i < sceneItems.count - 1 {
                let key = SceneBoundaryKey(item.id, sceneItems[i + 1].id)
                if let appT = math.boundaryTransitions[key], appT.type != .none {
                    transitionToNext = Self.makeTransition(appT)
                }
            }
            scenes.append(NextBridgeTimelineScene(scene: single, transitionToNext: transitionToNext))
        }

        return NextBridgeTimelineInputs(scenes: scenes, nominalFrameIndex: nominalFrameIndex, fps: math.fps)
    }

    // MARK: - Shared block assembly

    /// Build media blocks from live `SceneMediaSlot`s (single-scene path). Photo blocks resolve their
    /// URL from `urlByBlock`; VIDEO blocks resolve URL + trim from `videoByBlock` (CP7). Fails closed
    /// on audio kind, hidden slot, or a block whose resolved media is missing.
    private static func makeBlocks(
        slots: [String: SceneMediaSlot],
        urlByBlock: [String: URL],
        videoByBlock: [String: VideoSelection]
    ) throws -> [NextBridgeBlock] {
        var blocks: [NextBridgeBlock] = []
        for (blockID, slot) in slots.sorted(by: { $0.key < $1.key }) {
            guard slot.visibility else {
                throw NextBridgeError.blockHidden(blockID: blockID)
            }
            switch slot.mediaRef.mediaKind {
            case .photo:
                guard let url = urlByBlock[blockID] else {
                    throw NextBridgeError.mediaResolveFailed("no resolved export URL for block \(blockID)")
                }
                blocks.append(NextBridgeBlock(blockID: blockID, mediaURL: url, placement: mapPlacement(slot.placement)))
            case .video:
                guard let sel = videoByBlock[blockID] else {
                    throw NextBridgeError.mediaResolveFailed("no resolved export video for block \(blockID)")
                }
                blocks.append(NextBridgeBlock(
                    blockID: blockID, mediaURL: sel.url, placement: mapPlacement(slot.placement),
                    video: NextBridgeVideo(winStart: sel.winStart, winEnd: sel.winEnd)))
            case .audio:
                throw NextBridgeError.unsupportedMediaKind(blockID: blockID, kind: slot.mediaRef.mediaKind.rawValue)
            }
        }
        return blocks
    }

    /// Build media blocks from raw placement map (timeline immutable-session path). Every entry in
    /// `urlByBlock` is a visible photo and every entry in `videoByBlock` is a visible video (the
    /// snapshot only includes visible media). A media entry without a raw placement fails closed.
    private static func makeBlocks(
        placements: [String: MediaPlacementState],
        urlByBlock: [String: URL],
        videoByBlock: [String: VideoSelection]
    ) throws -> [NextBridgeBlock] {
        var blocks: [NextBridgeBlock] = []
        for (blockID, url) in urlByBlock.sorted(by: { $0.key < $1.key }) {
            guard let placement = placements[blockID] else {
                throw NextBridgeError.mediaResolveFailed("no raw placement for block \(blockID)")
            }
            blocks.append(NextBridgeBlock(blockID: blockID, mediaURL: url, placement: mapPlacement(placement)))
        }
        for (blockID, sel) in videoByBlock.sorted(by: { $0.key < $1.key }) {
            guard let placement = placements[blockID] else {
                throw NextBridgeError.mediaResolveFailed("no raw placement for video block \(blockID)")
            }
            blocks.append(NextBridgeBlock(
                blockID: blockID, mediaURL: sel.url, placement: mapPlacement(placement),
                video: NextBridgeVideo(winStart: sel.winStart, winEnd: sel.winEnd)))
        }
        return blocks
    }

    /// Map an app `MediaPlacementState` to the bridge's `NextBridgePlacement` (raw fit/offset/scale/
    /// rotation; the bridge derives its own fixed-point geometry). Mirrors the preview assembly.
    private static func mapPlacement(_ p: MediaPlacementState) -> NextBridgePlacement {
        NextBridgePlacement(
            fitModeRaw: p.fitMode.rawValue,
            offsetX: p.offsetX,
            offsetY: p.offsetY,
            userScale: p.userScale,
            rotationDegrees: p.rotationDegrees)
    }

    /// Map an app `SceneTransition` to the bridge transition descriptor. Carries the v1 set through
    /// verbatim; `NextTransitionMapping` later fails closed on any unknown type. Mirrors the preview
    /// `EditorViewController.makeNextTransition`.
    private static func makeTransition(_ t: SceneTransition) -> NextBridgeTransition {
        let typeRaw: String
        var direction: String? = nil
        switch t.type {
        case .none: typeRaw = "none"
        case .fade: typeRaw = "fade"
        case .slide(let d): typeRaw = "slide"; direction = d.rawValue
        case .push(let d): typeRaw = "push"; direction = d.rawValue
        case .dipToBlack: typeRaw = "dipToBlack"
        case .dipToWhite: typeRaw = "dipToWhite"
        }
        return NextBridgeTransition(
            typeRaw: typeRaw, direction: direction,
            durationFrames: t.durationFrames, easingRaw: t.easingPreset.rawValue)
    }
}
#endif
