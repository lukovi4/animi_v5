import XCTest
import CoreMedia
@testable import AnimiApp

final class VideoTimelineTimeMapperTests: XCTestCase {

    // MARK: - Helpers

    private let dummyURL = URL(fileURLWithPath: "/dev/null")
    private let fps: Double = 30.0
    private let epsilon = VideoTimelineTimeMapper.epsilon

    private func makeSelection(
        trimStart: Double = 0,
        trimEnd: Double = 10,
        offset: Double = 0
    ) -> VideoSelection {
        VideoSelection(url: dummyURL, trimStart: trimStart, trimEnd: trimEnd, offset: offset)
    }

    // MARK: - Tests

    /// 1. Block start offset — sceneFrameIndex == blockStartFrame → targetVideoTime == winStart
    func testBlockStartReturnsWinStart() {
        let sel = makeSelection(trimStart: 2, trimEnd: 8)
        let result = VideoTimelineTimeMapper.targetVideoTime(
            sceneFrameIndex: 10,
            blockStartFrame: 10,
            sceneFPS: fps,
            selection: sel
        )
        XCTAssertEqual(result.blockTimeSeconds, 0.0, accuracy: 1e-12)
        XCTAssertEqual(result.targetVideoTimeSeconds, sel.winStart, accuracy: 1e-12)
    }

    /// 2. Mid-block — sceneFrameIndex in the middle of the block → correct tVideo
    func testMidBlock() {
        let sel = makeSelection(trimStart: 1, trimEnd: 5)
        // 15 frames into block at 30fps = 0.5s
        let result = VideoTimelineTimeMapper.targetVideoTime(
            sceneFrameIndex: 15,
            blockStartFrame: 0,
            sceneFPS: fps,
            selection: sel
        )
        XCTAssertEqual(result.blockTimeSeconds, 0.5, accuracy: 1e-12)
        XCTAssertEqual(result.targetVideoTimeSeconds, 1.5, accuracy: 1e-12)
    }

    /// 3. Trim window — trimStart > 0 → result starts at winStart, not 0
    func testTrimWindowOffset() {
        let sel = makeSelection(trimStart: 3, trimEnd: 7)
        let result = VideoTimelineTimeMapper.targetVideoTime(
            sceneFrameIndex: 0,
            blockStartFrame: 0,
            sceneFPS: fps,
            selection: sel
        )
        // tBlock = 0, tVideo = winStart = 3
        XCTAssertEqual(result.targetVideoTimeSeconds, 3.0, accuracy: 1e-12)
    }

    /// 4. Offset — offset != 0 → winStart = trimStart + offset is correctly reflected
    func testOffsetShiftsWindow() {
        let sel = makeSelection(trimStart: 2, trimEnd: 6, offset: 1)
        // winStart = 2 + 1 = 3, winEnd = 6 + 1 = 7
        let result = VideoTimelineTimeMapper.targetVideoTime(
            sceneFrameIndex: 0,
            blockStartFrame: 0,
            sceneFPS: fps,
            selection: sel
        )
        XCTAssertEqual(result.targetVideoTimeSeconds, 3.0, accuracy: 1e-12)
    }

    /// 5. End hold clamp — sceneFrameIndex far beyond window → targetVideoTime == winEnd - epsilon
    func testEndHoldClamp() {
        let sel = makeSelection(trimStart: 0, trimEnd: 2)
        // 300 frames at 30fps = 10s, way past winEnd=2
        let result = VideoTimelineTimeMapper.targetVideoTime(
            sceneFrameIndex: 300,
            blockStartFrame: 0,
            sceneFPS: fps,
            selection: sel
        )
        XCTAssertEqual(result.targetVideoTimeSeconds, sel.winEnd - epsilon, accuracy: 1e-12)
    }

    /// 6. Before block start — sceneFrameIndex < blockStartFrame → tBlock == 0, targetVideoTime == winStart
    func testBeforeBlockStartClampsToZero() {
        let sel = makeSelection(trimStart: 1, trimEnd: 5)
        let result = VideoTimelineTimeMapper.targetVideoTime(
            sceneFrameIndex: 5,
            blockStartFrame: 10,
            sceneFPS: fps,
            selection: sel
        )
        XCTAssertEqual(result.blockTimeSeconds, 0.0, accuracy: 1e-12)
        XCTAssertEqual(result.targetVideoTimeSeconds, sel.winStart, accuracy: 1e-12)
    }

    /// 7. Preview/export parity — both caller wrappers derive from the same mapper output.
    ///
    /// Preview path: mapper → targetVideoTimeSeconds → Int((t * fps).rounded(.down))
    /// Export path:  mapper → targetVideoTimeSeconds → CMTime(seconds:t, preferredTimescale:600)
    /// This test verifies both conversions are consistent for a non-trivial input.
    func testPreviewExportParityConversions() {
        let sel = makeSelection(trimStart: 1.5, trimEnd: 4.5, offset: 0.5)
        let mapped = VideoTimelineTimeMapper.targetVideoTime(
            sceneFrameIndex: 20,
            blockStartFrame: 5,
            sceneFPS: fps,
            selection: sel
        )

        // Preview conversion (matches UserMediaService.computeSyntheticSceneFrame)
        let syntheticFrame = Int((mapped.targetVideoTimeSeconds * fps).rounded(.down))

        // Export conversion (matches ExportVideoFrameProvider.texture(forTargetVideoTime:))
        let timescale: CMTimeScale = 600
        let cmTime = CMTime(seconds: mapped.targetVideoTimeSeconds, preferredTimescale: timescale)

        // Both must agree on the underlying time
        let previewTime = Double(syntheticFrame) / fps
        let exportTime = cmTime.seconds

        // Preview rounds down to frame boundary, so previewTime <= exportTime
        XCTAssertLessThanOrEqual(previewTime, exportTime + 1e-12)
        // And the gap must be less than one frame (1/fps)
        XCTAssertLessThan(exportTime - previewTime, 1.0 / fps)
        // Export CMTime must be within 1 timescale tick of the Double value
        XCTAssertEqual(cmTime.seconds, mapped.targetVideoTimeSeconds, accuracy: 1.0 / Double(timescale))
    }

    /// 8. Epsilon value — matches canonical 1/600
    func testEpsilonValue() {
        XCTAssertEqual(VideoTimelineTimeMapper.epsilon, 1.0 / 600.0)
    }
}
