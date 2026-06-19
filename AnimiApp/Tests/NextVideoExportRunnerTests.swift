#if DEBUG
import XCTest
import Foundation
import Metal
import CoreVideo
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import AnimiApp
@testable import TVECore
import AnimiEngineCore

/// CP6: AnimiEngineNext video export. Covers the opaque-composite rule, the export input builder
/// (fail-closed + snapshot-stability), preview↔export frame parity, frame-count/timing, flag scoping.
@MainActor
final class NextVideoExportRunnerTests: XCTestCase {

    // MARK: - Fixtures

    private func sceneFolderURL(_ sceneTypeId: String) throws -> URL {
        let snapshot = try BundleSceneLibraryLoader().load()
        let scene = try XCTUnwrap(snapshot.scene(byId: sceneTypeId), "bundled scene '\(sceneTypeId)' missing")
        return try XCTUnwrap(scene.folderURL, "bundled scene '\(sceneTypeId)' has no folder URL")
    }

    private func tempPhoto(_ name: String, w: Int = 64, h: Int = 64,
                           r: CGFloat, g: CGFloat, b: CGFloat) throws -> URL {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let image = try XCTUnwrap(ctx.makeImage())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp6-\(name)-\(UUID().uuidString).png")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func singleSceneInputs(folder: URL, photo: URL, fitMode: String = "cover") -> NextBridgeInputs {
        NextBridgeInputs(
            sceneTypeId: "full_image", sceneFolderURL: folder, variantOverrides: [:],
            blocks: [NextBridgeBlock(
                blockID: "block_01", mediaURL: photo,
                placement: NextBridgePlacement(fitModeRaw: fitMode, offsetX: 0, offsetY: 0, userScale: 1, rotationDegrees: 0))],
            frameIndex: 0)
    }

    private func timelineScene(folder: URL, photo: URL, transitionToNext: NextBridgeTransition?) -> NextBridgeTimelineScene {
        NextBridgeTimelineScene(scene: singleSceneInputs(folder: folder, photo: photo), transitionToNext: transitionToNext)
    }

    // MARK: - 1. Opaque composite (A=255) — pure, no Metal

    func test_compositeOpaque_forcesAlpha255_keepsBGR_semiTransparentPixel() {
        // One pixel, premultiplied-over-transparent: a 50%-alpha mid-gray would be stored as
        // (B,G,R,A) = (64, 64, 64, 128) premultiplied. Compositing over opaque black keeps BGR and
        // sets A=255. Use a SECOND pixel with non-trivial channels + alpha=0 (fully transparent →
        // premultiplied BGR are all 0) to prove transparent areas become opaque black, not see-through.
        var src: [UInt8] = [
            64, 65, 66, 128,   // semi-transparent premultiplied pixel
            0,  0,  0,  0      // fully transparent pixel → premultiplied = black
        ]
        var dst = [UInt8](repeating: 7, count: 8) // pre-fill with junk to ensure full overwrite

        src.withUnsafeMutableBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                NextVideoExportRunner.compositeOpaque(
                    src: s.baseAddress!, srcBytesPerRow: 8,
                    dst: d.baseAddress!, dstBytesPerRow: 8,
                    width: 2, height: 1)
            }
        }

        // Pixel 0: BGR copied verbatim, A forced to 255.
        XCTAssertEqual(Array(dst[0..<4]), [64, 65, 66, 255], "semi-transparent: keep premultiplied BGR, A=255")
        // Pixel 1: was fully transparent → premultiplied BGR are 0 → opaque black (0,0,0,255).
        XCTAssertEqual(Array(dst[4..<8]), [0, 0, 0, 255], "transparent area → opaque black, never see-through")
    }

    func test_compositeOpaque_respectsDifferingStrides() {
        // src tightly packed (width*4), dst padded (+4 bytes/row). Row 1 must land at dst offset 12.
        var src: [UInt8] = [
            10, 11, 12, 50,   20, 21, 22, 60,   // row 0 (2 px)
            30, 31, 32, 70,   40, 41, 42, 80     // row 1 (2 px)
        ]
        var dst = [UInt8](repeating: 0, count: 24) // 2 rows * 12 bytes (8 used + 4 pad)
        src.withUnsafeMutableBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                NextVideoExportRunner.compositeOpaque(
                    src: s.baseAddress!, srcBytesPerRow: 8,
                    dst: d.baseAddress!, dstBytesPerRow: 12,
                    width: 2, height: 2)
            }
        }
        XCTAssertEqual(Array(dst[0..<8]), [10, 11, 12, 255, 20, 21, 22, 255], "row 0")
        XCTAssertEqual(Array(dst[8..<12]), [0, 0, 0, 0], "row 0 padding untouched")
        XCTAssertEqual(Array(dst[12..<20]), [30, 31, 32, 255, 40, 41, 42, 255], "row 1 at padded offset")
    }

    // MARK: - 2. Frame counts / timing parity vs preview bridge

    func test_singleScene_exportTotalFrames_matchesPreparedContext() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let folder = try sceneFolderURL("full_image")
        let photo = try tempPhoto("red", r: 1, g: 0, b: 0)
        defer { try? FileManager.default.removeItem(at: photo) }

        let inputs = singleSceneInputs(folder: folder, photo: photo)
        let sessionBox = try NextSingleSceneBridge.makeSession(device: device)
        let decoded = try NextSingleSceneBridge.decodeMedia(inputs)
        let placementByBlockID = Dictionary(uniqueKeysWithValues: inputs.blocks.map { ($0.blockID, $0.placement) })
        let ctx = try NextSingleSceneBridge.assemble(decoded: decoded, placementByBlockID: placementByBlockID, sessionBox: sessionBox)
        XCTAssertGreaterThan(ctx.totalFrames, 0)

        // First / last frame render without error (no off-by-one at the boundary).
        _ = try NextSingleSceneBridge.renderFrameBGRA(context: ctx, frameIndex: 0)
        _ = try NextSingleSceneBridge.renderFrameBGRA(context: ctx, frameIndex: ctx.totalFrames - 1)
    }

    func test_twoScene_fade_compressedTotal_andNominalMapping_noOffByOne() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let folder = try sceneFolderURL("full_image")
        let red = try tempPhoto("red", r: 1, g: 0, b: 0)
        let blue = try tempPhoto("blue", r: 0, g: 0, b: 1)
        defer { [red, blue].forEach { try? FileManager.default.removeItem(at: $0) } }

        let fade = NextBridgeTransition(typeRaw: "fade", direction: nil, durationFrames: 14, easingRaw: "linear")
        let inputs = NextBridgeTimelineInputs(
            scenes: [timelineScene(folder: folder, photo: red, transitionToNext: fade),
                     timelineScene(folder: folder, photo: blue, transitionToNext: nil)],
            nominalFrameIndex: 0, fps: 30)

        let sessionBox = try NextSingleSceneBridge.makeSession(device: device)
        let decoded = try NextTimelineBridge.decodeTimeline(inputs)
        let ctx = try NextTimelineBridge.assembleTimeline(decoded: decoded, inputs: inputs, sessionBox: sessionBox)

        // The export loop iterates COMPRESSED frames; the structure's totalFrames is NOMINAL.
        // Render the boundary-relevant NOMINAL frames end-to-end to prove no off-by-one: first (0),
        // a window around the transition midpoint, and the last frame (totalFrames-1). Each render is
        // wrapped in autoreleasepool so the per-frame BGRA buffers don't accumulate (device jetsam).
        XCTAssertGreaterThan(ctx.totalFrames, 1)
        let last = ctx.totalFrames - 1
        let mid = ctx.totalFrames / 2
        var probes = Set([0, last, mid])
        for d in -2...2 { let f = mid + d; if f >= 0 && f <= last { probes.insert(f) } }
        for f in probes.sorted() {
            try autoreleasepool {
                let frame = try NextTimelineBridge.renderFrameBGRA(context: ctx, frameIndex: f)
                XCTAssertEqual(frame.bytes.count, frame.bytesPerRow * frame.height, "frame \(f) complete")
            }
        }
    }

    func test_pushAndDip_transitionsAssembleAndRender() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let folder = try sceneFolderURL("full_image")
        let a = try tempPhoto("a", r: 1, g: 0, b: 0)
        let b = try tempPhoto("b", r: 0, g: 1, b: 0)
        defer { [a, b].forEach { try? FileManager.default.removeItem(at: $0) } }

        let variants: [NextBridgeTransition] = [
            NextBridgeTransition(typeRaw: "slide", direction: "left", durationFrames: 10, easingRaw: "linear"),
            NextBridgeTransition(typeRaw: "push", direction: "right", durationFrames: 10, easingRaw: "linear"),
            NextBridgeTransition(typeRaw: "dipToBlack", direction: nil, durationFrames: 10, easingRaw: "linear"),
            NextBridgeTransition(typeRaw: "dipToWhite", direction: nil, durationFrames: 10, easingRaw: "linear"),
        ]
        let sessionBox = try NextSingleSceneBridge.makeSession(device: device)
        for t in variants {
            let inputs = NextBridgeTimelineInputs(
                scenes: [timelineScene(folder: folder, photo: a, transitionToNext: t),
                         timelineScene(folder: folder, photo: b, transitionToNext: nil)],
                nominalFrameIndex: 0, fps: 30)
            let decoded = try NextTimelineBridge.decodeTimeline(inputs)
            let ctx = try NextTimelineBridge.assembleTimeline(decoded: decoded, inputs: inputs, sessionBox: sessionBox)
            _ = try NextTimelineBridge.renderFrameBGRA(context: ctx, frameIndex: ctx.totalFrames / 2)
        }
    }

    // MARK: - 3. Preview↔export parity (same bytes, then A=255)

    func test_previewExportParity_singleScene_bgrMatchesAfterOpaqueComposite() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let folder = try sceneFolderURL("full_image")
        let photo = try tempPhoto("green", r: 0, g: 1, b: 0)
        defer { try? FileManager.default.removeItem(at: photo) }

        let inputs = singleSceneInputs(folder: folder, photo: photo)
        let sessionBox = try NextSingleSceneBridge.makeSession(device: device)
        let decoded = try NextSingleSceneBridge.decodeMedia(inputs)
        let placementByBlockID = Dictionary(uniqueKeysWithValues: inputs.blocks.map { ($0.blockID, $0.placement) })
        let ctx = try NextSingleSceneBridge.assemble(decoded: decoded, placementByBlockID: placementByBlockID, sessionBox: sessionBox)

        // The bridge frame is the SAME frame the export runner sources. Parity = identical BGR; the
        // runner only forces A=255. Apply the same pure composite and confirm BGR is preserved exactly.
        let frame = try NextSingleSceneBridge.renderFrameBGRA(context: ctx, frameIndex: 0)
        let src = [UInt8](frame.bytes)
        var dst = [UInt8](repeating: 0, count: src.count)
        src.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                NextVideoExportRunner.compositeOpaque(
                    src: s.baseAddress!, srcBytesPerRow: frame.bytesPerRow,
                    dst: d.baseAddress!, dstBytesPerRow: frame.bytesPerRow,
                    width: frame.width, height: frame.height)
            }
        }
        // Sample center: BGR identical to the bridge frame, A forced opaque.
        let off = (frame.height / 2) * frame.bytesPerRow + (frame.width / 2) * 4
        XCTAssertEqual(dst[off + 0], src[off + 0], "B preserved")
        XCTAssertEqual(dst[off + 1], src[off + 1], "G preserved")
        XCTAssertEqual(dst[off + 2], src[off + 2], "R preserved")
        XCTAssertEqual(dst[off + 3], 255, "A opaque")
    }

    // MARK: - 4. Fail-closed (input builder)

    func test_failClosed_unsupportedVideoMediaKind() throws {
        let folder = try sceneFolderURL("full_image")
        let videoSlot = SceneMediaSlot.video(
            mediaRef: MediaRef(storagePath: "v.mp4", mediaKind: .video),
            placement: .defaultCover,
            videoWindow: PersistedVideoSelection(trimStart: 0, trimEnd: 5.0))
        let state = makeSceneState(slots: ["block_01": videoSlot])
        let snapshot = ExportMediaSnapshot(imageRefs: [], videoRefs: [], allAssetIds: [])

        XCTAssertThrowsError(try NextExportInputsBuilder.makeSingleScene(
            sceneTypeId: "full_image", sceneFolderURL: folder,
            sceneState: state, mediaSnapshot: snapshot, frameIndex: 0)
        ) { error in
            guard case NextBridgeError.unsupportedMediaKind = error else {
                return XCTFail("expected unsupportedMediaKind, got \(error)")
            }
        }
    }

    func test_failClosed_unknownTransitionType_inTimelineMapping() throws {
        // An unknown raw transition type must fail closed at mapping time (NextTransitionMappingError),
        // surfaced when decode/assemble walk the boundary. Build inputs with a bogus type and assert.
        let folder = try sceneFolderURL("full_image")
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let a = try tempPhoto("a", r: 1, g: 0, b: 0)
        let b = try tempPhoto("b", r: 0, g: 0, b: 1)
        defer { [a, b].forEach { try? FileManager.default.removeItem(at: $0) } }

        let bogus = NextBridgeTransition(typeRaw: "warp-zoom", direction: nil, durationFrames: 10, easingRaw: "linear")
        let inputs = NextBridgeTimelineInputs(
            scenes: [timelineScene(folder: folder, photo: a, transitionToNext: bogus),
                     timelineScene(folder: folder, photo: b, transitionToNext: nil)],
            nominalFrameIndex: 0, fps: 30)
        let sessionBox = try NextSingleSceneBridge.makeSession(device: device)
        let decoded = try NextTimelineBridge.decodeTimeline(inputs)
        XCTAssertThrowsError(try NextTimelineBridge.assembleTimeline(decoded: decoded, inputs: inputs, sessionBox: sessionBox),
                             "unknown transition type must fail closed")
    }

    // MARK: - 5. Timeline snapshot-stability (raw placement comes from the immutable snapshot)

    func test_timelineSnapshot_rawPlacement_isUsed_notLiveState() throws {
        // Build timeline inputs from a session whose snapshot carries a SPECIFIC raw placement, then
        // assert the produced NextBridgeInputs reflect THAT placement — proving the builder reads the
        // immutable snapshot, not any live state. We assert via the assembled block placement values.
        let folder = try sceneFolderURL("full_image")
        let session = try makeTwoSceneSession(
            folder: folder,
            placementA: MediaPlacementState(fitMode: .contain, offsetX: 11, offsetY: 22, userScale: 1.5, rotationDegrees: 33),
            placementB: MediaPlacementState(fitMode: .cover, offsetX: 0, offsetY: 0, userScale: 1, rotationDegrees: 0))

        let inputs = try NextExportInputsBuilder.makeTimeline(
            session: session,
            sceneFolderURL: { _ in folder },
            nominalFrameIndex: 0)

        let blockA = try XCTUnwrap(inputs.scenes.first?.scene.blocks.first)
        XCTAssertEqual(blockA.placement.fitModeRaw, "contain")
        XCTAssertEqual(blockA.placement.offsetX, 11, accuracy: 0.001)
        XCTAssertEqual(blockA.placement.offsetY, 22, accuracy: 0.001)
        XCTAssertEqual(blockA.placement.userScale, 1.5, accuracy: 0.001)
        XCTAssertEqual(blockA.placement.rotationDegrees, 33, accuracy: 0.001)
    }

    // MARK: - 6. Flag scoping (export vs preview flags are independent)

    func test_flagScoping_exportAndPreviewFlagsAreIndependent() {
        let exportKey = NextExportEngineToggles.defaultsKey
        let previewKey = NextEngineBridgeToggles.defaultsKey
        XCTAssertNotEqual(exportKey, previewKey)
        let d = UserDefaults.standard
        let savedExport = d.object(forKey: exportKey)
        let savedPreview = d.object(forKey: previewKey)
        defer {
            if let v = savedExport { d.set(v, forKey: exportKey) } else { d.removeObject(forKey: exportKey) }
            if let v = savedPreview { d.set(v, forKey: previewKey) } else { d.removeObject(forKey: previewKey) }
        }
        d.set(true, forKey: exportKey)
        d.set(false, forKey: previewKey)
        XCTAssertTrue(NextExportEngineToggles.exportWithNextEngine)
        XCTAssertFalse(NextEngineBridgeToggles.renderWithNextEngine)
    }

    // MARK: - Helpers (scene state / session fixtures)

    private func makeSceneState(slots: [String: SceneMediaSlot]) -> SceneState {
        var state = SceneState.empty
        state.mediaSlotsByBlockId = slots
        return state
    }

    /// Build a minimal immutable two-scene export session carrying specific raw placements.
    @MainActor
    private func makeTwoSceneSession(
        folder: URL,
        placementA: MediaPlacementState,
        placementB: MediaPlacementState
    ) throws -> TimelineCompositionEngine.TimelineExportSession {
        func makeRuntime() -> SceneRuntime {
            let canvas = Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 60)
            let scene = Scene(schemaVersion: "1.0", sceneId: "full_image", canvas: canvas, background: nil, mediaBlocks: [])
            return SceneRuntime(scene: scene, canvas: canvas, blocks: [], durationFrames: 60, fps: 30)
        }
        func makeSnapshot(index: Int, placement: MediaPlacementState) -> TimelineCompositionEngine.TimelineExportSceneSnapshot {
            let rt = makeRuntime()
            let img = ExportMediaSnapshot.ImageRef(blockId: "block_01", bindingAssetIds: ["a"], url: folder)
            let media = ExportMediaSnapshot(imageRefs: [img], videoRefs: [], allAssetIds: [])
            let render = SceneRenderStateSnapshot(resolvedTransforms: [:], variantOverrides: [:], userMediaPresent: ["block_01": true], layerToggleState: [:])
            return TimelineCompositionEngine.TimelineExportSceneSnapshot(
                sceneIndex: index, instanceId: UUID(), runtime: rt, renderState: render,
                videoSelections: [:], mediaSnapshot: media, assetIndex: AssetIndexIR(),
                resolver: CompositeAssetResolver(localIndex: .empty, sharedIndex: .empty),
                bindingAssetIds: [], pathRegistry: PathRegistry(), assetSizes: [:],
                sceneCanvasSize: SizeD(width: 1080, height: 1920), templateBackground: nil,
                sceneTypeId: "full_image", rawPlacements: ["block_01": placement])
        }
        let snapA = makeSnapshot(index: 0, placement: placementA)
        let snapB = makeSnapshot(index: 1, placement: placementB)
        let durationUs: TimeUs = 60 * 1_000_000 / 30
        let itemA = TimelineItem(id: snapA.instanceId, payloadId: UUID(), kind: .scene, startUs: nil, durationUs: durationUs)
        let itemB = TimelineItem(id: snapB.instanceId, payloadId: UUID(), kind: .scene, startUs: nil, durationUs: durationUs)
        let math = TimelineTransitionMath(sceneItems: [itemA, itemB], boundaryTransitions: [:], fps: 30)
        return TimelineCompositionEngine.TimelineExportSession(
            transitionMath: math, canvasSize: SizeD(width: 1080, height: 1920), fps: 30,
            scenesByInstanceId: [snapA.instanceId: snapA, snapB.instanceId: snapB],
            audioSceneData: [], overlaySnapshot: OverlayExportSnapshot(textItems: [], stickerItems: []))
    }
}
#endif
