import XCTest
import TVECore
@testable import AnimiApp

/// Unit tests for EditorRenderContract.
/// Tests cover:
/// - templateMode mapping (EditorUIMode -> TemplateMode)
/// - isPlaybackAllowed rules
final class EditorRenderContractTests: XCTestCase {

    // MARK: - templateMode Tests

    func testTimelineModeReturnsPreview() {
        let mode = EditorRenderContract.templateMode(for: .timeline)
        XCTAssertEqual(mode, .preview)
    }

    func testSceneEditModeReturnsEdit() {
        let sceneId = UUID()
        let mode = EditorRenderContract.templateMode(for: .sceneEdit(sceneInstanceId: sceneId))
        XCTAssertEqual(mode, .edit)
    }

    // MARK: - isPlaybackAllowed Tests

    func testPlaybackAllowedInTimeline() {
        let allowed = EditorRenderContract.isPlaybackAllowed(in: .timeline)
        XCTAssertTrue(allowed)
    }

    func testPlaybackNotAllowedInSceneEdit() {
        let sceneId = UUID()
        let allowed = EditorRenderContract.isPlaybackAllowed(in: .sceneEdit(sceneInstanceId: sceneId))
        XCTAssertFalse(allowed)
    }
}
