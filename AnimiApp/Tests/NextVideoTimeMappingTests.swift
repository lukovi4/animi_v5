#if DEBUG
import XCTest
import CoreMedia
@testable import AnimiApp

/// CP7: prove the Next video-time mapping (`NextVideoTimeMapping`, used by the Next bridge's video
/// resolver) stays byte-identical to the production `VideoTimelineTimeMapper` that preview + export
/// already share. If these ever diverge, video frames in the Next path would desync from the rest of
/// the app — this suite is the lockstep guard the owner required ("if exact mapping not proven by
/// code — STOP").
final class NextVideoTimeMappingTests: XCTestCase {

    private let fps = 30.0

    private func sel(winStart: Double, winEnd: Double) -> VideoSelection {
        VideoSelection(url: URL(fileURLWithPath: "/dev/null"), trimStart: winStart, trimEnd: winEnd, isMuted: false, volume: 1)
    }

    // MARK: - Epsilon pin

    func test_epsilon_matchesProductionOwner() {
        XCTAssertEqual(NextVideoTimeMapping.epsilon, VideoWindowValidator.epsilon, accuracy: 0)
        XCTAssertEqual(NextVideoTimeMapping.epsilon, 1.0 / 600.0, accuracy: 0)
    }

    // MARK: - Frame 0 / mid / last vs production mapper

    func test_frame0_matchesProductionMapper() {
        let s = sel(winStart: 0, winEnd: 5)
        let prod = VideoTimelineTimeMapper.targetVideoTime(sceneFrameIndex: 0, blockStartFrame: 0, sceneFPS: fps, selection: s).targetVideoTimeSeconds
        let next = NextVideoTimeMapping.targetVideoTime(sceneFrameIndex: 0, blockStartFrame: 0, sceneFPS: fps, winStart: s.winStart, winEnd: s.winEnd)
        XCTAssertEqual(next, prod, accuracy: 1e-12)
        XCTAssertEqual(next, 0.0, accuracy: 1e-12)
    }

    func test_middleFrame_matchesProductionMapper() {
        let s = sel(winStart: 0, winEnd: 5)
        // Frame 45 @30fps == 1.5s into block.
        let prod = VideoTimelineTimeMapper.targetVideoTime(sceneFrameIndex: 45, blockStartFrame: 0, sceneFPS: fps, selection: s).targetVideoTimeSeconds
        let next = NextVideoTimeMapping.targetVideoTime(sceneFrameIndex: 45, blockStartFrame: 0, sceneFPS: fps, winStart: s.winStart, winEnd: s.winEnd)
        XCTAssertEqual(next, prod, accuracy: 1e-12)
        XCTAssertEqual(next, 1.5, accuracy: 1e-12)
    }

    func test_lastRepresentableFrame_clampsToWinEndMinusEpsilon_matchesProduction() {
        let s = sel(winStart: 0, winEnd: 5)
        // A frame far past the window: both clamp to winEnd - epsilon.
        let prod = VideoTimelineTimeMapper.targetVideoTime(sceneFrameIndex: 100_000, blockStartFrame: 0, sceneFPS: fps, selection: s).targetVideoTimeSeconds
        let next = NextVideoTimeMapping.targetVideoTime(sceneFrameIndex: 100_000, blockStartFrame: 0, sceneFPS: fps, winStart: s.winStart, winEnd: s.winEnd)
        XCTAssertEqual(next, prod, accuracy: 1e-12)
        XCTAssertEqual(next, 5.0 - NextVideoTimeMapping.epsilon, accuracy: 1e-12)
    }

    // MARK: - Trim in/out offset

    func test_trimIn_offsetApplied_matchesProduction() {
        let s = sel(winStart: 2.0, winEnd: 8.0)
        // Frame 30 @30fps == 1s into block → 2.0 + 1.0 = 3.0.
        let prod = VideoTimelineTimeMapper.targetVideoTime(sceneFrameIndex: 30, blockStartFrame: 0, sceneFPS: fps, selection: s).targetVideoTimeSeconds
        let next = NextVideoTimeMapping.targetVideoTime(sceneFrameIndex: 30, blockStartFrame: 0, sceneFPS: fps, winStart: s.winStart, winEnd: s.winEnd)
        XCTAssertEqual(next, prod, accuracy: 1e-12)
        XCTAssertEqual(next, 3.0, accuracy: 1e-12)
    }

    func test_trimOut_clampHonored_matchesProduction() {
        let s = sel(winStart: 2.0, winEnd: 4.0)
        // Frame past trim end clamps to winEnd - epsilon.
        let prod = VideoTimelineTimeMapper.targetVideoTime(sceneFrameIndex: 9999, blockStartFrame: 0, sceneFPS: fps, selection: s).targetVideoTimeSeconds
        let next = NextVideoTimeMapping.targetVideoTime(sceneFrameIndex: 9999, blockStartFrame: 0, sceneFPS: fps, winStart: s.winStart, winEnd: s.winEnd)
        XCTAssertEqual(next, prod, accuracy: 1e-12)
        XCTAssertEqual(next, 4.0 - NextVideoTimeMapping.epsilon, accuracy: 1e-12)
    }

    // MARK: - Before block start clamps to winStart (no negative video time)

    func test_beforeBlockStart_clampsToWinStart_matchesProduction() {
        let s = sel(winStart: 1.0, winEnd: 6.0)
        let prod = VideoTimelineTimeMapper.targetVideoTime(sceneFrameIndex: 0, blockStartFrame: 30, sceneFPS: fps, selection: s).targetVideoTimeSeconds
        let next = NextVideoTimeMapping.targetVideoTime(sceneFrameIndex: 0, blockStartFrame: 30, sceneFPS: fps, winStart: s.winStart, winEnd: s.winEnd)
        XCTAssertEqual(next, prod, accuracy: 1e-12)
        XCTAssertEqual(next, 1.0, accuracy: 1e-12) // clamped to winStart, not negative
    }

    // MARK: - Scene-local seconds form equals the frame form (the form the bridge actually uses)

    func test_sceneSecondsForm_equalsFrameForm() {
        let s = sel(winStart: 0.5, winEnd: 9.0)
        for frame in [0, 1, 15, 45, 150, 270] {
            let frameForm = NextVideoTimeMapping.targetVideoTime(
                sceneFrameIndex: frame, blockStartFrame: 0, sceneFPS: fps, winStart: s.winStart, winEnd: s.winEnd)
            let seconds = Double(frame) / fps
            let secondsForm = NextVideoTimeMapping.targetVideoTime(
                scenePlaybackSeconds: seconds, winStart: s.winStart, winEnd: s.winEnd)
            XCTAssertEqual(frameForm, secondsForm, accuracy: 1e-12, "frame \(frame)")
        }
    }

    // MARK: - Transition scene-local times (outgoing vs incoming sample different video times)

    func test_transitionScenes_sampleDistinctVideoTimes() {
        // During a transition the outgoing scene is near its end while the incoming scene is near its
        // start — their scene-local times differ, so the same video bound to each samples different
        // frames. Use the seconds form (the bridge feeds each subplan's ScenePlaybackTime seconds).
        let outgoing = sel(winStart: 0, winEnd: 5)
        let incoming = sel(winStart: 0, winEnd: 5)
        let outgoingSceneSeconds = 4.8   // late in the outgoing scene
        let incomingSceneSeconds = 0.1   // early in the incoming scene
        let outT = NextVideoTimeMapping.targetVideoTime(scenePlaybackSeconds: outgoingSceneSeconds, winStart: outgoing.winStart, winEnd: outgoing.winEnd)
        let inT = NextVideoTimeMapping.targetVideoTime(scenePlaybackSeconds: incomingSceneSeconds, winStart: incoming.winStart, winEnd: incoming.winEnd)
        XCTAssertEqual(outT, 4.8, accuracy: 1e-9)
        XCTAssertEqual(inT, 0.1, accuracy: 1e-9)
        XCTAssertNotEqual(outT, inT, "transition scenes must sample distinct video times")
    }

    // MARK: - Broad parity sweep across windows + frames

    func test_paritySweep_matchesProductionMapperEverywhere() {
        let windows: [(Double, Double)] = [(0, 5), (0.5, 9), (2, 4), (1.0, 6.0), (0, 0.5)]
        for (ws, we) in windows {
            let s = sel(winStart: ws, winEnd: we)
            for frame in stride(from: 0, through: 600, by: 7) {
                for blockStart in [0, 5, 30] {
                    let prod = VideoTimelineTimeMapper.targetVideoTime(
                        sceneFrameIndex: frame, blockStartFrame: blockStart, sceneFPS: fps, selection: s).targetVideoTimeSeconds
                    let next = NextVideoTimeMapping.targetVideoTime(
                        sceneFrameIndex: frame, blockStartFrame: blockStart, sceneFPS: fps, winStart: ws, winEnd: we)
                    XCTAssertEqual(next, prod, accuracy: 1e-12, "win[\(ws),\(we)] frame \(frame) blockStart \(blockStart)")
                }
            }
        }
    }
}
#endif
