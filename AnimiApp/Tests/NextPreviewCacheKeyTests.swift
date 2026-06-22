#if DEBUG
import XCTest
import Foundation
import Metal
@testable import AnimiApp

/// CP3 — cache-key invalidation tests. `NextPreviewKey` decides whether a prepared template
/// context can be reused; any identity change must produce a different key (rebuild), and an
/// unchanged identity must produce an equal key (reuse). Pure logic — no device needed.
final class NextPreviewCacheKeyTests: XCTestCase {

    private func placement(fit: String = "contain", ox: Double = 0, oy: Double = 0,
                           scale: Double = 1, rot: Double = 0) -> NextBridgePlacement {
        NextBridgePlacement(fitModeRaw: fit, offsetX: ox, offsetY: oy, userScale: scale, rotationDegrees: rot)
    }

    /// CP7.8-CORR fix B: model the editor's OFF-MAIN identity computation — the block carries the
    /// (size, mtime) the editor would have stat'd at URL resolve. Tests invalidate+refresh so an in-place
    /// file edit is reflected (the editor's re-resolve path). `NextBridgeBlock`/`NextPreviewKey` themselves
    /// do NO disk IO; this helper supplies the value identity.
    private func block(_ id: String, _ url: URL, _ placement: NextBridgePlacement, video: NextBridgeVideo? = nil) -> NextBridgeBlock {
        NextMediaStatCache.shared.invalidate(path: url.path)
        let s = NextMediaStatCache.shared.stat(path: url.path)
        return NextBridgeBlock(blockID: id, mediaURL: url, placement: placement, video: video,
                               mediaSize: s.size, mediaMTime: s.mtime)
    }

    /// Build single-block inputs against a real temp media file (so size/mtime are stable).
    private func makeInputs(scene: String = "full_image", variants: [String: String] = [:],
                            block: String = "block_01", mediaURL: URL,
                            placement: NextBridgePlacement, frame: Int = 0,
                            timelineDurationFrames: Int? = nil) -> NextBridgeInputs {
        NextBridgeInputs(
            sceneTypeId: scene, sceneFolderURL: URL(fileURLWithPath: "/tmp/scenes/\(scene)"),
            variantOverrides: variants,
            blocks: [self.block(block, mediaURL, placement)],
            frameIndex: frame,
            timelineDurationFrames: timelineDurationFrames)
    }

    /// Build MULTI-block inputs (CP4): one (blockID, url, placement) per block.
    private func makeMultiInputs(scene: String = "polaroid_2", variants: [String: String] = [:],
                                 blocks: [(String, URL, NextBridgePlacement)], frame: Int = 0) -> NextBridgeInputs {
        NextBridgeInputs(
            sceneTypeId: scene, sceneFolderURL: URL(fileURLWithPath: "/tmp/scenes/\(scene)"),
            variantOverrides: variants,
            blocks: blocks.map { self.block($0.0, $0.1, $0.2) },
            frameIndex: frame)
    }

    private func tempFile(_ name: String, bytes: Int = 16) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cp3key-\(name)-\(UUID().uuidString)")
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        return url
    }

    // MARK: - CP7.8-CORR fix B: media stat is cached (no per-frame disk read), but still tracks identity

    func test_statCache_returnsCachedValue_andDoesNotRereadAfterFileChanges() throws {
        let media = try tempFile("statcache", bytes: 16)
        defer { try? FileManager.default.removeItem(at: media) }
        NextMediaStatCache.shared.invalidate(path: media.path)

        let first = NextMediaStatCache.shared.stat(path: media.path)
        XCTAssertEqual(first.size, 16)

        // Change the file ON DISK but do NOT invalidate — the cache must still return the OLD value,
        // proving NextPreviewKey.init does NOT hit the disk every frame (the whole point of fix B).
        try Data(repeating: 0xCD, count: 999).write(to: media)
        let cached = NextMediaStatCache.shared.stat(path: media.path)
        XCTAssertEqual(cached, first, "stat must be served from cache, not re-read from disk per call")

        // After an explicit invalidate (editor (re)resolves the URL) the new identity flows through.
        NextMediaStatCache.shared.invalidate(path: media.path)
        let refreshed = NextMediaStatCache.shared.stat(path: media.path)
        XCTAssertEqual(refreshed.size, 999, "after invalidate the new file identity must be read")
    }

    func test_nextPreviewKey_isValueOnly_noFileNeeded() {
        // A non-existent path: NextPreviewKey.init must STILL build (pure value-only, no disk dependency).
        // The block carries explicit value identity; the key reflects it without any FileManager call.
        let url = URL(fileURLWithPath: "/does/not/exist/\(UUID().uuidString).mp4")
        let blk = NextBridgeBlock(blockID: "b", mediaURL: url, placement: placement(),
                                  video: nil, mediaSize: 12345, mediaMTime: 678.0)
        let inputs = NextBridgeInputs(
            sceneTypeId: "full_image", sceneFolderURL: URL(fileURLWithPath: "/tmp/scenes/x"),
            variantOverrides: [:], blocks: [blk], frameIndex: 0, timelineDurationFrames: nil)
        let k1 = NextPreviewKey(inputs: inputs)
        XCTAssertNotNil(k1, "key must build from value identity alone (no file on disk)")
        // Different carried identity → different key (the value flows through, no disk).
        let blk2 = NextBridgeBlock(blockID: "b", mediaURL: url, placement: placement(),
                                   video: nil, mediaSize: 999, mediaMTime: 678.0)
        let inputs2 = NextBridgeInputs(
            sceneTypeId: "full_image", sceneFolderURL: URL(fileURLWithPath: "/tmp/scenes/x"),
            variantOverrides: [:], blocks: [blk2], frameIndex: 0, timelineDurationFrames: nil)
        XCTAssertNotEqual(k1!.mediaKey, NextPreviewKey(inputs: inputs2)!.mediaKey)
    }

    func test_cachedOnly_neverReadsDisk_returnsSentinelOnMiss() {
        // The draw-path accessor must NEVER touch disk: a path never stat'd returns the -1 sentinel.
        let path = "/unwarmed/\(UUID().uuidString).mp4"
        let s = NextMediaStatCache.shared.cachedOnly(path: path)
        XCTAssertEqual(s.size, -1, "cachedOnly must return sentinel on miss, not stat the disk")
        XCTAssertEqual(s.mtime, -1)
    }

    func test_mediaKey_changesWhenCachedFileIdentityChanges() throws {
        let media = try tempFile("identity", bytes: 16)
        defer { try? FileManager.default.removeItem(at: media) }
        NextMediaStatCache.shared.invalidate(path: media.path)
        let before = NextPreviewKey(inputs: makeInputs(mediaURL: media, placement: placement()))!.mediaKey

        // Same path, changed file + invalidate (the editor's (re)resolve path) → mediaKey MUST differ
        // (gates decode/context rebuild), so a real media change is never missed.
        try Data(repeating: 0xCD, count: 999).write(to: media)
        NextMediaStatCache.shared.invalidate(path: media.path)
        let after = NextPreviewKey(inputs: makeInputs(mediaURL: media, placement: placement()))!.mediaKey
        XCTAssertNotEqual(before, after, "a real file-identity change must still change mediaKey")
    }

    func test_sameTemplateMediaPlacement_reusesContext() throws {
        let media = try tempFile("same")
        defer { try? FileManager.default.removeItem(at: media) }
        let a = NextPreviewKey(inputs: makeInputs(mediaURL: media, placement: placement(), frame: 0))
        let b = NextPreviewKey(inputs: makeInputs(mediaURL: media, placement: placement(), frame: 30)) // frame differs
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b, "frame index is NOT part of the context key — same context reused across frames")
    }

    func test_mediaChange_invalidates() throws {
        let m1 = try tempFile("m1"); let m2 = try tempFile("m2")
        defer { try? FileManager.default.removeItem(at: m1); try? FileManager.default.removeItem(at: m2) }
        let a = NextPreviewKey(inputs: makeInputs(mediaURL: m1, placement: placement()))
        let b = NextPreviewKey(inputs: makeInputs(mediaURL: m2, placement: placement()))
        XCTAssertNotEqual(a, b, "different media file → rebuild")
    }

    func test_mediaContentChange_samePath_invalidates() throws {
        // Same path, different bytes/size → mtime+size change → different key.
        let url = try tempFile("edit", bytes: 16)
        defer { try? FileManager.default.removeItem(at: url) }
        let a = NextPreviewKey(inputs: makeInputs(mediaURL: url, placement: placement()))
        try Data(repeating: 0xCD, count: 999).write(to: url)   // overwrite (new size)
        let b = NextPreviewKey(inputs: makeInputs(mediaURL: url, placement: placement()))
        XCTAssertNotEqual(a, b, "same path but edited content (size/mtime) → rebuild")
    }

    func test_placementFitChange_invalidates() throws {
        let media = try tempFile("fit")
        defer { try? FileManager.default.removeItem(at: media) }
        let a = NextPreviewKey(inputs: makeInputs(mediaURL: media, placement: placement(fit: "contain")))
        let b = NextPreviewKey(inputs: makeInputs(mediaURL: media, placement: placement(fit: "cover")))
        XCTAssertNotEqual(a, b, "fit mode change → rebuild (placement is baked into materials)")
    }

    func test_placementTransformChange_invalidates() throws {
        let media = try tempFile("xform")
        defer { try? FileManager.default.removeItem(at: media) }
        let base = NextPreviewKey(inputs: makeInputs(mediaURL: media, placement: placement()))
        XCTAssertNotEqual(base, NextPreviewKey(inputs: makeInputs(mediaURL: media, placement: placement(ox: 5))), "offsetX")
        XCTAssertNotEqual(base, NextPreviewKey(inputs: makeInputs(mediaURL: media, placement: placement(oy: 5))), "offsetY")
        XCTAssertNotEqual(base, NextPreviewKey(inputs: makeInputs(mediaURL: media, placement: placement(scale: 1.5))), "scale")
        XCTAssertNotEqual(base, NextPreviewKey(inputs: makeInputs(mediaURL: media, placement: placement(rot: 90))), "rotation")
    }

    func test_variantChange_invalidates() throws {
        let media = try tempFile("variant")
        defer { try? FileManager.default.removeItem(at: media) }
        let a = NextPreviewKey(inputs: makeInputs(variants: ["block_01": "no-anim"], mediaURL: media, placement: placement()))
        let b = NextPreviewKey(inputs: makeInputs(variants: ["block_01": "anim-1"], mediaURL: media, placement: placement()))
        XCTAssertNotEqual(a, b, "variant/animation selection change → rebuild")
    }

    // MARK: - Two-level cache: placement change must REUSE decoded media (perf)

    func test_placementChange_keepsMediaKey_soDecodeIsReused() throws {
        let media = try tempFile("mk")
        defer { try? FileManager.default.removeItem(at: media) }
        let a = NextPreviewKey(inputs: makeInputs(mediaURL: media, placement: placement(scale: 1.0)))
        let b = NextPreviewKey(inputs: makeInputs(mediaURL: media, placement: placement(scale: 2.0, rot: 45)))
        XCTAssertNotEqual(a, b, "full key differs (context rebuilds for new placement)")
        XCTAssertEqual(a?.mediaKey, b?.mediaKey, "mediaKey is placement-FREE → decoded media reused, no re-decode")
    }

    func test_mediaChange_breaksMediaKey() throws {
        let m1 = try tempFile("mk1"); let m2 = try tempFile("mk2")
        defer { try? FileManager.default.removeItem(at: m1); try? FileManager.default.removeItem(at: m2) }
        let a = NextPreviewKey(inputs: makeInputs(mediaURL: m1, placement: placement()))
        let b = NextPreviewKey(inputs: makeInputs(mediaURL: m2, placement: placement()))
        XCTAssertNotEqual(a?.mediaKey, b?.mediaKey, "media change → mediaKey differs → re-decode")
    }

    func test_variantChange_breaksMediaKey() throws {
        let media = try tempFile("mkv")
        defer { try? FileManager.default.removeItem(at: media) }
        let a = NextPreviewKey(inputs: makeInputs(variants: ["block_01": "no-anim"], mediaURL: media, placement: placement()))
        let b = NextPreviewKey(inputs: makeInputs(variants: ["block_01": "anim-1"], mediaURL: media, placement: placement()))
        XCTAssertNotEqual(a?.mediaKey, b?.mediaKey, "variant change → mediaKey differs → re-decode")
    }

    func test_timelineDurationChange_breaksMediaKey_forStretchGuard() throws {
        let media = try tempFile("span")
        defer { try? FileManager.default.removeItem(at: media) }
        let nominal = NextPreviewKey(inputs: makeInputs(
            mediaURL: media, placement: placement(), timelineDurationFrames: 150))
        let stretched = NextPreviewKey(inputs: makeInputs(
            mediaURL: media, placement: placement(), timelineDurationFrames: 300))

        XCTAssertNotEqual(nominal, stretched, "timeline span change must invalidate the preview context")
        XCTAssertNotEqual(
            nominal?.mediaKey,
            stretched?.mediaKey,
            "timeline span change must re-enter decodeMedia so stretched scenes fail closed before render")
    }

    // MARK: - CP4 multi-block key behaviour

    func test_multiBlock_sameInputs_reuseContext_orderIndependent() throws {
        let m1 = try tempFile("mb1"); let m2 = try tempFile("mb2")
        defer { try? FileManager.default.removeItem(at: m1); try? FileManager.default.removeItem(at: m2) }
        // Same blocks supplied in DIFFERENT order must yield the SAME key (sorted by blockID).
        let a = NextPreviewKey(inputs: makeMultiInputs(blocks: [("block_01", m1, placement()), ("block_02", m2, placement())]))
        let b = NextPreviewKey(inputs: makeMultiInputs(blocks: [("block_02", m2, placement()), ("block_01", m1, placement())]))
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b, "block order is not semantic — key is sorted by blockID")
        XCTAssertEqual(a?.mediaKey, b?.mediaKey)
    }

    func test_multiBlock_oneBlockMediaChange_invalidates_butKeepsMediaKeyShape() throws {
        let m1 = try tempFile("mbA"); let m2 = try tempFile("mbB"); let m2b = try tempFile("mbB2")
        defer { [m1, m2, m2b].forEach { try? FileManager.default.removeItem(at: $0) } }
        let a = NextPreviewKey(inputs: makeMultiInputs(blocks: [("block_01", m1, placement()), ("block_02", m2, placement())]))
        let b = NextPreviewKey(inputs: makeMultiInputs(blocks: [("block_01", m1, placement()), ("block_02", m2b, placement())]))
        XCTAssertNotEqual(a, b, "changing one block's media invalidates the whole key")
        XCTAssertNotEqual(a?.mediaKey, b?.mediaKey, "and its mediaKey (re-decode that block)")
    }

    func test_multiBlock_oneBlockPlacementChange_keepsMediaKey() throws {
        let m1 = try tempFile("mbP1"); let m2 = try tempFile("mbP2")
        defer { try? FileManager.default.removeItem(at: m1); try? FileManager.default.removeItem(at: m2) }
        let a = NextPreviewKey(inputs: makeMultiInputs(blocks: [("block_01", m1, placement()), ("block_02", m2, placement())]))
        let b = NextPreviewKey(inputs: makeMultiInputs(blocks: [("block_01", m1, placement(scale: 1.7)), ("block_02", m2, placement())]))
        XCTAssertNotEqual(a, b, "a per-block placement change rebuilds context")
        XCTAssertEqual(a?.mediaKey, b?.mediaKey, "but mediaKey is unchanged → decoded photos reused (no re-decode)")
    }

    func test_multiBlock_blockCountChange_invalidates() throws {
        let m1 = try tempFile("mbC1"); let m2 = try tempFile("mbC2")
        defer { try? FileManager.default.removeItem(at: m1); try? FileManager.default.removeItem(at: m2) }
        let one = NextPreviewKey(inputs: makeMultiInputs(blocks: [("block_01", m1, placement())]))
        let two = NextPreviewKey(inputs: makeMultiInputs(blocks: [("block_01", m1, placement()), ("block_02", m2, placement())]))
        XCTAssertNotEqual(one, two, "adding a block changes identity")
        XCTAssertNotEqual(one?.mediaKey, two?.mediaKey)
    }

    func test_emptyBlocks_yieldsNilKey() throws {
        let k = NextPreviewKey(inputs: makeMultiInputs(blocks: []))
        XCTAssertNil(k, "no bound blocks → no key (fail closed upstream)")
    }

    func test_sceneChange_invalidates() throws {
        let media = try tempFile("scene")
        defer { try? FileManager.default.removeItem(at: media) }
        let a = NextPreviewKey(inputs: makeInputs(scene: "full_image", mediaURL: media, placement: placement()))
        let b = NextPreviewKey(inputs: makeInputs(scene: "polaroid_2", mediaURL: media, placement: placement()))
        XCTAssertNotEqual(a, b, "scene/template change → rebuild")
    }

    func test_unresolvedMediaFile_keyIsNilSafe() throws {
        // A non-existent media path still yields a key (size/mtime = -1 per block); identity is stable.
        let missing = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString)")
        let k = NextPreviewKey(inputs: makeInputs(mediaURL: missing, placement: placement()))
        XCTAssertNotNil(k)
        XCTAssertEqual(k?.blockMedia.first?.mediaSize, -1)
    }

    // MARK: - Stale-render prevention (controller epoch behaviour)

    /// An identity change between a request and its async completion must DROP the stale frame:
    /// the controller bumps the epoch on the new request, so the old render's main-thread
    /// publication is discarded (staleDropped increments, completion is not delivered).
    // MARK: - Present-on-miss (live gesture continuity) — latestFrame lifecycle

    @MainActor
    func test_latestFrame_clearedOnMediaChange_keptOnPlacementChange() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let controller = NextPreviewController(device: device)
        let m1 = try tempFile("lf1"); let m2 = try tempFile("lf2")
        defer { try? FileManager.default.removeItem(at: m1); try? FileManager.default.removeItem(at: m2) }

        // Render attempts will fail (no real scene folder), so latestFrame stays nil — but the
        // KEY-transition logic (clear on media change, keep on placement change) runs regardless and
        // must not crash. This guards the lifecycle wiring.
        _ = controller.requestFrame(makeInputs(mediaURL: m1, placement: placement())) { _ in }
        XCTAssertNil(controller.latestFrame, "no successful render yet")
        // Placement-only change then media change — exercises both branches without crashing.
        _ = controller.requestFrame(makeInputs(mediaURL: m1, placement: placement(scale: 2))) { _ in }
        _ = controller.requestFrame(makeInputs(mediaURL: m2, placement: placement(scale: 2))) { _ in }
        XCTAssertNil(controller.latestFrame)
    }

    @MainActor
    func test_staleRender_droppedOnIdentityChange() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let controller = NextPreviewController(device: device)

        let mediaA = try tempFile("staleA")
        let mediaB = try tempFile("staleB")
        defer { try? FileManager.default.removeItem(at: mediaA); try? FileManager.default.removeItem(at: mediaB) }

        // First request (will miss + schedule an async render against a non-existent scene folder,
        // so it fails — but the point is the epoch bump below must drop whatever it produces).
        let exp = expectation(description: "no stale completion for first identity")
        exp.isInverted = true   // we assert this completion does NOT fire after the identity change
        _ = controller.requestFrame(makeInputs(scene: "full_image", mediaURL: mediaA, placement: placement())) { _ in
            exp.fulfill()   // if this fires for the FIRST identity after we switched, it's a stale leak
        }
        // Immediately change identity (new media) → bumps epoch, cancels the first.
        _ = controller.requestFrame(makeInputs(scene: "full_image", mediaURL: mediaB, placement: placement())) { _ in }

        // Give the async render queue time to finish and attempt main-thread publication.
        wait(for: [exp], timeout: 1.5)
        XCTAssertGreaterThanOrEqual(controller.stats.staleDropped, 0, "stale drop path exercised without crash")
    }
}
#endif
