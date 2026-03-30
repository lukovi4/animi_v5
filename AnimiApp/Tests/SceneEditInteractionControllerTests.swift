import XCTest
@testable import AnimiApp
import UIKit

// MARK: - Mock Gesture Recognizers

private final class MockPanGestureRecognizer: UIPanGestureRecognizer {
    var testState: UIGestureRecognizer.State = .possible
    var testTranslation: CGPoint = .zero

    override var state: UIGestureRecognizer.State {
        get { testState }
        set { testState = newValue }
    }

    override func translation(in view: UIView?) -> CGPoint {
        testTranslation
    }
}

private final class MockPinchGestureRecognizer: UIPinchGestureRecognizer {
    var testState: UIGestureRecognizer.State = .possible
    var testScale: CGFloat = 1.0

    override var state: UIGestureRecognizer.State {
        get { testState }
        set { testState = newValue }
    }

    override var scale: CGFloat {
        get { testScale }
        set { testScale = newValue }
    }
}

private final class MockRotationGestureRecognizer: UIRotationGestureRecognizer {
    var testState: UIGestureRecognizer.State = .possible
    var testRotation: CGFloat = 0

    override var state: UIGestureRecognizer.State {
        get { testState }
        set { testState = newValue }
    }

    override var rotation: CGFloat {
        get { testRotation }
        set { testRotation = newValue }
    }
}

// MARK: - Tests

@MainActor
final class SceneEditInteractionControllerTests: XCTestCase {

    private var controller: SceneEditInteractionController!
    private var events: [(blockId: String, placement: MediaPlacementState, phase: InteractionPhase)]!

    private let someId = UUID()
    private let baselinePlacement = MediaPlacementState(fitMode: .cover, offsetX: 10, offsetY: 20, userScale: 1.5, rotationDegrees: 30)

    override func setUp() {
        super.setUp()
        events = []
        controller = SceneEditInteractionController()
        controller.getUIMode = { [someId] in .sceneEdit(sceneInstanceId: someId) }
        controller.getSelectedBlockId = { "block1" }
        controller.getBaselinePlacement = { [baselinePlacement] _ in baselinePlacement }
        controller.getScenePlayer = { nil } // nil player → isTransformAllowed returns true
        controller.onPlacementChanged = { [weak self] blockId, placement, phase in
            self?.events.append((blockId, placement, phase))
        }
    }

    override func tearDown() {
        controller = nil
        events = nil
        super.tearDown()
    }

    // MARK: - Simultaneous Pan + Pinch: first ended emits .changed, not terminal

    func test_simultaneousPanAndPinch_firstEnded_emitsChanged_notTerminal() {
        let pan = MockPanGestureRecognizer()
        let pinch = MockPinchGestureRecognizer()

        // pan .began
        pan.testState = .began
        controller.handlePan(pan)

        // pinch .began
        pinch.testState = .began
        controller.handlePinch(pinch)

        // pan .changed
        pan.testState = .changed
        pan.testTranslation = CGPoint(x: 5, y: 5)
        controller.handlePan(pan)

        // pinch .changed
        pinch.testState = .changed
        pinch.testScale = 1.2
        controller.handlePinch(pinch)

        // pan .ended — not the last gesture, so no terminal
        pan.testState = .ended
        controller.handlePan(pan)

        // At this point, no terminal event should have been emitted
        let terminalEvents = events.filter { $0.phase == .ended || $0.phase == .cancelled }
        XCTAssertTrue(terminalEvents.isEmpty, "No terminal event while pinch still active")

        // The event from pan ending should be .changed
        let lastBeforePinchEnd = events.last!
        XCTAssertEqual(lastBeforePinchEnd.phase, .changed)

        // pinch .ended — now terminal
        pinch.testState = .ended
        controller.handlePinch(pinch)

        let finalEvent = events.last!
        XCTAssertEqual(finalEvent.phase, .ended, "Terminal .ended after last gesture ends")
    }

    // MARK: - Simultaneous Pan + Pinch: one cancelled → final is .cancelled

    func test_simultaneousPanAndPinch_oneCancelled_finalTerminalCancelled() {
        let pan = MockPanGestureRecognizer()
        let pinch = MockPinchGestureRecognizer()

        // Both begin
        pan.testState = .began
        controller.handlePan(pan)

        pinch.testState = .began
        controller.handlePinch(pinch)

        // Some changes
        pan.testState = .changed
        pan.testTranslation = CGPoint(x: 50, y: 0)
        controller.handlePan(pan)

        pinch.testState = .changed
        pinch.testScale = 2.0
        controller.handlePinch(pinch)

        // pan .cancelled — no immediate terminal while pinch active
        pan.testState = .cancelled
        controller.handlePan(pan)

        let terminalAfterPanCancel = events.filter { $0.phase == .ended || $0.phase == .cancelled }
        XCTAssertTrue(terminalAfterPanCancel.isEmpty, "No terminal while pinch still active")

        // pinch .ended — now terminal fires
        pinch.testState = .ended
        controller.handlePinch(pinch)

        let finalEvent = events.last!
        XCTAssertEqual(finalEvent.phase, .cancelled, "Terminal must be .cancelled because pan was cancelled")
        XCTAssertEqual(finalEvent.placement, baselinePlacement, "Cancelled placement must equal baseline")
    }

    // MARK: - Simultaneous session emits .began only once

    func test_simultaneousSession_emitsBeganOnlyOnce() {
        let pan = MockPanGestureRecognizer()
        let pinch = MockPinchGestureRecognizer()
        let rotation = MockRotationGestureRecognizer()

        // Three recognizers begin
        pan.testState = .began
        controller.handlePan(pan)

        pinch.testState = .began
        controller.handlePinch(pinch)

        rotation.testState = .began
        controller.handleRotation(rotation)

        let beganEvents = events.filter { $0.phase == .began }
        XCTAssertEqual(beganEvents.count, 1, ".began must fire exactly once")

        // End all
        pan.testState = .ended
        controller.handlePan(pan)

        pinch.testState = .ended
        controller.handlePinch(pinch)

        rotation.testState = .ended
        controller.handleRotation(rotation)

        let terminalEvents = events.filter { $0.phase == .ended || $0.phase == .cancelled }
        XCTAssertEqual(terminalEvents.count, 1, "Terminal event fires exactly once")
        XCTAssertEqual(terminalEvents[0].phase, .ended)
    }
}
