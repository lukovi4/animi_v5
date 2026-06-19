#if DEBUG
import XCTest
import Foundation
@testable import AnimiApp

/// CP5 — multi-scene timeline cache-key invalidation. `NextTimelineKey` decides whether a prepared
/// multi-scene context can be reused; any identity change (scene set, per-scene media/placement/
/// variant, or a boundary transition) must rebuild, and a placement-only change must keep the
/// placement-FREE `mediaKey` so per-scene decode is reused. Pure logic — no device needed.
final class NextTimelineKeyTests: XCTestCase {

    private func placement(scale: Double = 1) -> NextBridgePlacement {
        NextBridgePlacement(fitModeRaw: "contain", offsetX: 0, offsetY: 0, userScale: scale, rotationDegrees: 0)
    }

    private func tempFile(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cp5key-\(name)-\(UUID().uuidString)")
        try Data(repeating: 0xAB, count: 16).write(to: url)
        return url
    }

    private func sceneInputs(scene: String, block: String, url: URL, placement: NextBridgePlacement) -> NextBridgeInputs {
        NextBridgeInputs(
            sceneTypeId: scene, sceneFolderURL: URL(fileURLWithPath: "/tmp/scenes/\(scene)"),
            variantOverrides: [:],
            blocks: [NextBridgeBlock(blockID: block, mediaURL: url, placement: placement)],
            frameIndex: 0)
    }

    private func transition(_ type: String, dir: String? = nil, frames: Int = 14, easing: String = "easeInOut") -> NextBridgeTransition {
        NextBridgeTransition(typeRaw: type, direction: dir, durationFrames: frames, easingRaw: easing)
    }

    private func twoScene(
        m1: URL, m2: URL, p1: NextBridgePlacement, p2: NextBridgePlacement,
        transition: NextBridgeTransition?, frame: Int = 0
    ) -> NextBridgeTimelineInputs {
        NextBridgeTimelineInputs(
            scenes: [
                NextBridgeTimelineScene(scene: sceneInputs(scene: "full_image", block: "block_01", url: m1, placement: p1),
                                        transitionToNext: transition),
                NextBridgeTimelineScene(scene: sceneInputs(scene: "full_image", block: "block_01", url: m2, placement: p2),
                                        transitionToNext: nil)
            ],
            nominalFrameIndex: frame, fps: 30)
    }

    // MARK: - basic identity

    func test_sameTimeline_reusesContext_acrossFrames() throws {
        let m1 = try tempFile("a1"); let m2 = try tempFile("a2")
        defer { [m1, m2].forEach { try? FileManager.default.removeItem(at: $0) } }
        let a = NextTimelineKey(inputs: twoScene(m1: m1, m2: m2, p1: placement(), p2: placement(), transition: transition("fade"), frame: 0))
        let b = NextTimelineKey(inputs: twoScene(m1: m1, m2: m2, p1: placement(), p2: placement(), transition: transition("fade"), frame: 60))
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b, "nominal frame is NOT part of the context key — same context across frames")
    }

    func test_singleScene_yieldsNilTimelineKey() throws {
        let m1 = try tempFile("solo")
        defer { try? FileManager.default.removeItem(at: m1) }
        let inputs = NextBridgeTimelineInputs(
            scenes: [NextBridgeTimelineScene(scene: sceneInputs(scene: "full_image", block: "block_01", url: m1, placement: placement()), transitionToNext: nil)],
            nominalFrameIndex: 0, fps: 30)
        XCTAssertNil(NextTimelineKey(inputs: inputs), "a single scene is not a timeline (use CP4 single-scene path)")
    }

    // MARK: - invalidation

    func test_transitionTypeChange_invalidates() throws {
        let m1 = try tempFile("t1"); let m2 = try tempFile("t2")
        defer { [m1, m2].forEach { try? FileManager.default.removeItem(at: $0) } }
        let fade = NextTimelineKey(inputs: twoScene(m1: m1, m2: m2, p1: placement(), p2: placement(), transition: transition("fade")))
        let slide = NextTimelineKey(inputs: twoScene(m1: m1, m2: m2, p1: placement(), p2: placement(), transition: transition("slide", dir: "left")))
        XCTAssertNotEqual(fade, slide, "fade → slide changes identity (rebuild)")
        XCTAssertNotEqual(fade?.mediaKey, slide?.mediaKey, "transition is part of the media key (window changes)")
    }

    func test_transitionDurationChange_invalidates() throws {
        let m1 = try tempFile("d1"); let m2 = try tempFile("d2")
        defer { [m1, m2].forEach { try? FileManager.default.removeItem(at: $0) } }
        let a = NextTimelineKey(inputs: twoScene(m1: m1, m2: m2, p1: placement(), p2: placement(), transition: transition("fade", frames: 14)))
        let b = NextTimelineKey(inputs: twoScene(m1: m1, m2: m2, p1: placement(), p2: placement(), transition: transition("fade", frames: 20)))
        XCTAssertNotEqual(a, b, "duration change → rebuild (window + post-roll differ)")
    }

    func test_slideDirectionChange_invalidates() throws {
        let m1 = try tempFile("s1"); let m2 = try tempFile("s2")
        defer { [m1, m2].forEach { try? FileManager.default.removeItem(at: $0) } }
        let left = NextTimelineKey(inputs: twoScene(m1: m1, m2: m2, p1: placement(), p2: placement(), transition: transition("slide", dir: "left")))
        let right = NextTimelineKey(inputs: twoScene(m1: m1, m2: m2, p1: placement(), p2: placement(), transition: transition("slide", dir: "right")))
        XCTAssertNotEqual(left, right, "slide direction change → rebuild")
    }

    func test_oneSceneMediaChange_invalidates() throws {
        let m1 = try tempFile("ma"); let m2 = try tempFile("mb"); let m2b = try tempFile("mb2")
        defer { [m1, m2, m2b].forEach { try? FileManager.default.removeItem(at: $0) } }
        let a = NextTimelineKey(inputs: twoScene(m1: m1, m2: m2, p1: placement(), p2: placement(), transition: transition("fade")))
        let b = NextTimelineKey(inputs: twoScene(m1: m1, m2: m2b, p1: placement(), p2: placement(), transition: transition("fade")))
        XCTAssertNotEqual(a, b, "second scene media change invalidates whole timeline")
        XCTAssertNotEqual(a?.mediaKey, b?.mediaKey, "and its media key → re-decode that scene")
    }

    // MARK: - placement-free media key (perf)

    func test_oneScenePlacementChange_keepsMediaKey() throws {
        let m1 = try tempFile("pa"); let m2 = try tempFile("pb")
        defer { [m1, m2].forEach { try? FileManager.default.removeItem(at: $0) } }
        let a = NextTimelineKey(inputs: twoScene(m1: m1, m2: m2, p1: placement(scale: 1.0), p2: placement(), transition: transition("fade")))
        let b = NextTimelineKey(inputs: twoScene(m1: m1, m2: m2, p1: placement(scale: 2.5), p2: placement(), transition: transition("fade")))
        XCTAssertNotEqual(a, b, "placement change rebuilds context")
        XCTAssertEqual(a?.mediaKey, b?.mediaKey, "but media key is placement-FREE → decoded photos reused")
    }
}
#endif
