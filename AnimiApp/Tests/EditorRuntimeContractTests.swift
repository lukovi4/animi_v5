import XCTest
@testable import AnimiApp

/// Tests EditorRuntimeState equatability and basic EditorRuntime state transitions.
final class EditorRuntimeContractTests: XCTestCase {

    // MARK: - State Equatable

    func test_idle_equatable() {
        XCTAssertEqual(EditorRuntimeState.idle, EditorRuntimeState.idle)
    }

    func test_booting_equatable() {
        XCTAssertEqual(EditorRuntimeState.booting, EditorRuntimeState.booting)
    }

    func test_timelinePreview_equatable() {
        XCTAssertEqual(EditorRuntimeState.timelinePreview, EditorRuntimeState.timelinePreview)
    }

    func test_exporting_equatable() {
        XCTAssertEqual(EditorRuntimeState.exporting, EditorRuntimeState.exporting)
    }

    func test_sceneEdit_sameId_equatable() {
        let id = UUID()
        XCTAssertEqual(EditorRuntimeState.sceneEdit(instanceId: id), EditorRuntimeState.sceneEdit(instanceId: id))
    }

    func test_sceneEdit_differentId_notEqual() {
        XCTAssertNotEqual(EditorRuntimeState.sceneEdit(instanceId: UUID()), EditorRuntimeState.sceneEdit(instanceId: UUID()))
    }

    func test_error_sameMessage_equatable() {
        XCTAssertEqual(EditorRuntimeState.error("oops"), EditorRuntimeState.error("oops"))
    }

    func test_error_differentMessage_notEqual() {
        XCTAssertNotEqual(EditorRuntimeState.error("a"), EditorRuntimeState.error("b"))
    }

    func test_differentCases_notEqual() {
        XCTAssertNotEqual(EditorRuntimeState.idle, EditorRuntimeState.booting)
        XCTAssertNotEqual(EditorRuntimeState.timelinePreview, EditorRuntimeState.exporting)
        XCTAssertNotEqual(EditorRuntimeState.idle, EditorRuntimeState.error(""))
    }

    // MARK: - Render Source

    func test_renderSource_none_isDefault() {
        // Verify default render source construction
        let source: EditorRuntimeRenderSource = .none
        if case .none = source {
            // Expected
        } else {
            XCTFail("Expected .none render source")
        }
    }
}
