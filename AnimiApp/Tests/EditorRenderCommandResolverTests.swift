import XCTest
import TVECore
@testable import AnimiApp

/// Unit tests for EditorRenderCommandResolver.
/// Tests cover:
/// - Mode selection based on EditorUIMode
/// - Coordinator-first resolution
/// - ScenePlayer fallback with correct mode
/// - Frame index selection
/// - Nil return when no valid commands
final class EditorRenderCommandResolverTests: XCTestCase {

    // MARK: - Test Data

    private let testCommands: [RenderCommand] = [
        .beginGroup(name: "test"),
        .endGroup
    ]

    // MARK: - Mode Selection Tests

    func testTimelineUsesPreviewMode() {
        var receivedMode: TemplateMode?

        let result = EditorRenderCommandResolver.resolve(
            uiMode: .timeline,
            coordinatorLocalFrame: 10,
            currentFrameIndex: 0,
            coordinatorCommands: { mode in
                receivedMode = mode
                return self.testCommands
            },
            scenePlayerCommands: { _, _ in nil }
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(receivedMode, .preview)
        XCTAssertEqual(result?.mode, .preview)
    }

    func testSceneEditUsesEditMode() {
        var receivedMode: TemplateMode?
        let sceneId = UUID()

        let result = EditorRenderCommandResolver.resolve(
            uiMode: .sceneEdit(sceneInstanceId: sceneId),
            coordinatorLocalFrame: 10,
            currentFrameIndex: 0,
            coordinatorCommands: { mode in
                receivedMode = mode
                return self.testCommands
            },
            scenePlayerCommands: { _, _ in nil }
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(receivedMode, .edit)
        XCTAssertEqual(result?.mode, .edit)
    }

    // MARK: - Resolution Priority Tests

    func testCoordinatorCommandsFirst() {
        let coordinatorCommands: [RenderCommand] = [.beginGroup(name: "coordinator")]
        let scenePlayerCommands: [RenderCommand] = [.beginGroup(name: "scenePlayer")]

        var coordinatorCalled = false
        var scenePlayerCalled = false

        let result = EditorRenderCommandResolver.resolve(
            uiMode: .timeline,
            coordinatorLocalFrame: 10,
            currentFrameIndex: 0,
            coordinatorCommands: { _ in
                coordinatorCalled = true
                return coordinatorCommands
            },
            scenePlayerCommands: { _, _ in
                scenePlayerCalled = true
                return scenePlayerCommands
            }
        )

        XCTAssertTrue(coordinatorCalled)
        XCTAssertFalse(scenePlayerCalled, "ScenePlayer should not be called when coordinator returns commands")
        XCTAssertEqual(result?.commands, coordinatorCommands)
    }

    // MARK: - Fallback Tests with Correct Mode

    func testScenePlayerFallbackInTimelineUsesPreviewMode() {
        var receivedMode: TemplateMode?
        var receivedFrame: Int?

        let result = EditorRenderCommandResolver.resolve(
            uiMode: .timeline,
            coordinatorLocalFrame: 15,
            currentFrameIndex: 0,
            coordinatorCommands: { _ in nil },
            scenePlayerCommands: { mode, frame in
                receivedMode = mode
                receivedFrame = frame
                return self.testCommands
            }
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(receivedMode, .preview, "Fallback in timeline must use .preview mode")
        XCTAssertEqual(receivedFrame, 15)
        XCTAssertEqual(result?.mode, .preview)
    }

    func testScenePlayerFallbackInSceneEditUsesEditMode() {
        var receivedMode: TemplateMode?
        var receivedFrame: Int?
        let sceneId = UUID()

        let result = EditorRenderCommandResolver.resolve(
            uiMode: .sceneEdit(sceneInstanceId: sceneId),
            coordinatorLocalFrame: 20,
            currentFrameIndex: 0,
            coordinatorCommands: { _ in nil },
            scenePlayerCommands: { mode, frame in
                receivedMode = mode
                receivedFrame = frame
                return self.testCommands
            }
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(receivedMode, .edit, "Fallback in sceneEdit must use .edit mode")
        XCTAssertEqual(receivedFrame, 20)
        XCTAssertEqual(result?.mode, .edit)
    }

    // MARK: - Nil Return Tests

    func testReturnsNilWhenNoValidCommands() {
        let result = EditorRenderCommandResolver.resolve(
            uiMode: .timeline,
            coordinatorLocalFrame: 10,
            currentFrameIndex: 0,
            coordinatorCommands: { _ in nil },
            scenePlayerCommands: { _, _ in nil }
        )

        XCTAssertNil(result)
    }

    func testReturnsNilWhenCoordinatorReturnsEmptyCommands() {
        let result = EditorRenderCommandResolver.resolve(
            uiMode: .timeline,
            coordinatorLocalFrame: 10,
            currentFrameIndex: 0,
            coordinatorCommands: { _ in [] },
            scenePlayerCommands: { _, _ in nil }
        )

        XCTAssertNil(result)
    }

    func testReturnsNilWhenBothReturnEmptyCommands() {
        let result = EditorRenderCommandResolver.resolve(
            uiMode: .timeline,
            coordinatorLocalFrame: 10,
            currentFrameIndex: 0,
            coordinatorCommands: { _ in [] },
            scenePlayerCommands: { _, _ in [] }
        )

        XCTAssertNil(result)
    }

    // MARK: - Frame Index Tests

    func testUsesCoordinatorLocalFrameWhenAvailable() {
        var receivedFrame: Int?

        _ = EditorRenderCommandResolver.resolve(
            uiMode: .timeline,
            coordinatorLocalFrame: 42,
            currentFrameIndex: 10,
            coordinatorCommands: { _ in nil },
            scenePlayerCommands: { _, frame in
                receivedFrame = frame
                return self.testCommands
            }
        )

        XCTAssertEqual(receivedFrame, 42)
    }

    func testFallsBackToCurrentFrameIndex() {
        var receivedFrame: Int?

        _ = EditorRenderCommandResolver.resolve(
            uiMode: .timeline,
            coordinatorLocalFrame: nil,
            currentFrameIndex: 25,
            coordinatorCommands: { _ in nil },
            scenePlayerCommands: { _, frame in
                receivedFrame = frame
                return self.testCommands
            }
        )

        XCTAssertEqual(receivedFrame, 25)
    }

    func testResultContainsCorrectFrameIndex() {
        let result = EditorRenderCommandResolver.resolve(
            uiMode: .timeline,
            coordinatorLocalFrame: 33,
            currentFrameIndex: 0,
            coordinatorCommands: { _ in self.testCommands },
            scenePlayerCommands: { _, _ in nil }
        )

        XCTAssertEqual(result?.frameIndex, 33)
    }
}
