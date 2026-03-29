import XCTest
@testable import AnimiApp

/// Pure value-type tests for VideoTrimSession.
/// Verifies init logic, hasChanges, and fraction computations.
final class VideoTrimSessionTests: XCTestCase {

    // MARK: - Init: currentPreviewTime

    func test_init_defaultsToTrimStart() {
        let selection = PersistedVideoSelection(trimStart: 2.0, trimEnd: 8.0)
        let session = VideoTrimSession(
            instanceId: UUID(),
            blockId: "block_01",
            actualDuration: 10.0,
            selection: selection
        )
        XCTAssertEqual(session.currentPreviewTime, 2.0, "Should default to trimStart when no currentVideoTime")
    }

    func test_init_usesCurrentVideoTime_whenInsideRange() {
        let selection = PersistedVideoSelection(trimStart: 2.0, trimEnd: 8.0)
        let session = VideoTrimSession(
            instanceId: UUID(),
            blockId: "block_01",
            actualDuration: 10.0,
            selection: selection,
            currentVideoTime: 5.0
        )
        XCTAssertEqual(session.currentPreviewTime, 5.0, "Should use currentVideoTime when inside [trimStart, trimEnd]")
    }

    func test_init_fallsBackToTrimStart_whenOutsideRange() {
        let selection = PersistedVideoSelection(trimStart: 2.0, trimEnd: 8.0)
        let session = VideoTrimSession(
            instanceId: UUID(),
            blockId: "block_01",
            actualDuration: 10.0,
            selection: selection,
            currentVideoTime: 9.0
        )
        XCTAssertEqual(session.currentPreviewTime, 2.0, "Should fall back to trimStart when currentVideoTime outside range")
    }

    func test_init_fallsBackToTrimStart_whenNil() {
        let selection = PersistedVideoSelection(trimStart: 3.0, trimEnd: 7.0)
        let session = VideoTrimSession(
            instanceId: UUID(),
            blockId: "block_01",
            actualDuration: 10.0,
            selection: selection,
            currentVideoTime: nil
        )
        XCTAssertEqual(session.currentPreviewTime, 3.0, "Should fall back to trimStart when currentVideoTime is nil")
    }

    // MARK: - hasChanges

    func test_hasChanges_falseWhenUnmodified() {
        let selection = PersistedVideoSelection(trimStart: 1.0, trimEnd: 9.0)
        let session = VideoTrimSession(
            instanceId: UUID(),
            blockId: "block_01",
            actualDuration: 10.0,
            selection: selection
        )
        XCTAssertFalse(session.hasChanges, "Should be false when draftSelection == originalSelection")
    }

    func test_hasChanges_trueWhenTrimStartChanged() {
        let selection = PersistedVideoSelection(trimStart: 1.0, trimEnd: 9.0)
        var session = VideoTrimSession(
            instanceId: UUID(),
            blockId: "block_01",
            actualDuration: 10.0,
            selection: selection
        )
        session.draftSelection = PersistedVideoSelection(trimStart: 2.0, trimEnd: 9.0)
        XCTAssertTrue(session.hasChanges, "Should be true when trimStart changed")
    }

    func test_hasChanges_trueWhenTrimEndChanged() {
        let selection = PersistedVideoSelection(trimStart: 1.0, trimEnd: 9.0)
        var session = VideoTrimSession(
            instanceId: UUID(),
            blockId: "block_01",
            actualDuration: 10.0,
            selection: selection
        )
        session.draftSelection = PersistedVideoSelection(trimStart: 1.0, trimEnd: 7.0)
        XCTAssertTrue(session.hasChanges, "Should be true when trimEnd changed")
    }

    // MARK: - Fractions

    func test_fractions_computeCorrectly() {
        let selection = PersistedVideoSelection(trimStart: 2.0, trimEnd: 8.0)
        var session = VideoTrimSession(
            instanceId: UUID(),
            blockId: "block_01",
            actualDuration: 10.0,
            selection: selection,
            currentVideoTime: 5.0
        )
        // draftSelection is same as selection initially
        XCTAssertEqual(session.trimStartFraction, 0.2, accuracy: 1e-9)
        XCTAssertEqual(session.trimEndFraction, 0.8, accuracy: 1e-9)
        XCTAssertEqual(session.cursorFraction, 0.5, accuracy: 1e-9)

        // Modify draft
        session.draftSelection = PersistedVideoSelection(trimStart: 3.0, trimEnd: 7.0)
        XCTAssertEqual(session.trimStartFraction, 0.3, accuracy: 1e-9)
        XCTAssertEqual(session.trimEndFraction, 0.7, accuracy: 1e-9)
    }

    func test_fractions_zeroDuration() {
        let selection = PersistedVideoSelection(trimStart: 0, trimEnd: 0)
        let session = VideoTrimSession(
            instanceId: UUID(),
            blockId: "block_01",
            actualDuration: 0,
            selection: selection
        )
        XCTAssertEqual(session.trimStartFraction, 0, "Zero duration → trimStartFraction == 0")
        XCTAssertEqual(session.trimEndFraction, 1, "Zero duration → trimEndFraction == 1")
        XCTAssertEqual(session.cursorFraction, 0, "Zero duration → cursorFraction == 0")
    }
}
