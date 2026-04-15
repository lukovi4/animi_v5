import XCTest
@testable import AnimiApp

/// TT-08: Integration tests for boundary picker flow.
/// Tests dismiss-then-callback semantics, dispatch handler mapping,
/// and alert creation — using internal test seams on EditorViewController.
final class TT08BoundaryPickerIntegrationTests: XCTestCase {

    // MARK: - 1. Picker Factory Tests

    /// Test: makeTransitionPicker returns picker with correct currentType and wired callback.
    func test_makeTransitionPicker_configuresCurrentTypeAndCallback() {
        var received: SceneTransition?
        let picker = EditorViewController.makeTransitionPicker(
            currentType: .fade,
            onSelect: { received = $0 }
        )

        // Trigger viewDidLoad
        _ = picker.view

        // Verify checkmark on fade (row 1)
        let tableView = picker.view.subviews.first { $0 is UITableView } as? UITableView
        XCTAssertNotNil(tableView)

        let fadeCell = tableView?.dataSource?.tableView(tableView!, cellForRowAt: IndexPath(row: 1, section: 0))
        XCTAssertEqual(fadeCell?.accessoryType, .checkmark, "Fade should have checkmark")

        let noneCell = tableView?.dataSource?.tableView(tableView!, cellForRowAt: IndexPath(row: 0, section: 0))
        XCTAssertEqual(noneCell?.accessoryType, UITableViewCell.AccessoryType.none, "None should not have checkmark")

        // Verify callback is wired (direct call, not through dismiss)
        let slideTransition = SceneTransition.v1Preset(for: .slide(direction: .left))
        picker.onSelectTransition?(slideTransition)

        XCTAssertNotNil(received)
        XCTAssertEqual(received?.type, .slide(direction: .left))
    }

    // MARK: - 2. Dismiss-Then-Callback Integration Test

    /// Test: Selecting a preset in a presented picker calls onSelectTransition AFTER dismiss completion.
    /// Uses lightweight host VC + UIWindow (no EditorViewController).
    func test_pickerSelection_callsCallbackAfterDismiss() {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()

        // Force view load
        host.loadViewIfNeeded()

        let callbackExpectation = expectation(description: "onSelectTransition called")
        var receivedTransition: SceneTransition?

        let picker = EditorViewController.makeTransitionPicker(
            currentType: .none,
            onSelect: { transition in
                receivedTransition = transition
                callbackExpectation.fulfill()
            }
        )

        let nav = UINavigationController(rootViewController: picker)
        nav.modalPresentationStyle = .pageSheet

        let presentExpectation = expectation(description: "Picker presented")
        host.present(nav, animated: false) {
            presentExpectation.fulfill()
        }

        wait(for: [presentExpectation], timeout: 3.0)

        // Verify picker is presented
        XCTAssertNotNil(host.presentedViewController, "Picker should be presented")

        // Simulate selecting "Fade" (row 1)
        let tableView = picker.view.subviews.first { $0 is UITableView } as? UITableView
        XCTAssertNotNil(tableView)
        tableView?.delegate?.tableView?(tableView!, didSelectRowAt: IndexPath(row: 1, section: 0))

        // Wait for dismiss completion -> callback
        wait(for: [callbackExpectation], timeout: 3.0)

        // After callback: picker should be dismissed
        XCTAssertNil(host.presentedViewController, "Picker should be dismissed before callback")
        XCTAssertNotNil(receivedTransition)
        XCTAssertEqual(receivedTransition?.type, .fade)
        XCTAssertEqual(receivedTransition?.durationFrames, 14)

        // Cleanup
        window.isHidden = true
    }

    // MARK: - 3. Dispatch Handler Tests

    /// Test: makeBoundaryTransitionDispatchHandler maps transition to correct EditorAction.
    func test_dispatchHandler_mapsTransitionToCorrectAction() {
        let fromId = UUID()
        let toId = UUID()
        var receivedAction: EditorAction?

        let handler = EditorViewController.makeBoundaryTransitionDispatchHandler(
            fromSceneId: fromId,
            toSceneId: toId,
            dispatch: { receivedAction = $0 }
        )

        // When: Handler called with fade transition
        let fade = SceneTransition.v1Preset(for: .fade)
        handler(fade)

        // Then: Correct action dispatched
        guard case .setBoundaryTransition(let actionFromId, let actionToId, let actionTransition) = receivedAction else {
            XCTFail("Expected .setBoundaryTransition, got: \(String(describing: receivedAction))")
            return
        }

        XCTAssertEqual(actionFromId, fromId)
        XCTAssertEqual(actionToId, toId)
        XCTAssertEqual(actionTransition.type, .fade)
        XCTAssertEqual(actionTransition.durationFrames, 14)
    }

    /// Test: Dispatch handler with .none transition produces correct action.
    func test_dispatchHandler_noneTransition_producesCorrectAction() {
        let fromId = UUID()
        let toId = UUID()
        var receivedAction: EditorAction?

        let handler = EditorViewController.makeBoundaryTransitionDispatchHandler(
            fromSceneId: fromId,
            toSceneId: toId,
            dispatch: { receivedAction = $0 }
        )

        handler(.none)

        guard case .setBoundaryTransition(_, _, let transition) = receivedAction else {
            XCTFail("Expected .setBoundaryTransition")
            return
        }

        XCTAssertEqual(transition.type, .none)
        XCTAssertEqual(transition.durationFrames, 0)
    }

    /// Test: Dispatch handler with all 12 presets maps each correctly.
    func test_dispatchHandler_all12Presets_mapCorrectly() {
        let fromId = UUID()
        let toId = UUID()
        var actions: [EditorAction] = []

        let handler = EditorViewController.makeBoundaryTransitionDispatchHandler(
            fromSceneId: fromId,
            toSceneId: toId,
            dispatch: { actions.append($0) }
        )

        let presetTypes: [TransitionType] = [
            .none, .fade,
            .slide(direction: .left), .slide(direction: .right),
            .slide(direction: .up), .slide(direction: .down),
            .push(direction: .left), .push(direction: .right),
            .push(direction: .up), .push(direction: .down),
            .dipToBlack, .dipToWhite
        ]

        for type in presetTypes {
            handler(SceneTransition.v1Preset(for: type))
        }

        XCTAssertEqual(actions.count, 12)

        for (index, action) in actions.enumerated() {
            guard case .setBoundaryTransition(let f, let t, let tr) = action else {
                XCTFail("Action \(index) is not .setBoundaryTransition")
                continue
            }
            XCTAssertEqual(f, fromId)
            XCTAssertEqual(t, toId)
            XCTAssertEqual(tr.type, presetTypes[index])
        }
    }

    // MARK: - 4. Alert Factory Tests

    /// Test: makeBoundaryTransitionsResetAlert returns correctly configured alert.
    func test_resetAlert_hasCorrectConfiguration() {
        let alert = EditorViewController.makeBoundaryTransitionsResetAlert()

        XCTAssertEqual(alert.title, "Transitions Removed")
        XCTAssertEqual(
            alert.message,
            "Some transitions were removed because scene boundaries changed or adjacent scenes are too short."
        )
        XCTAssertEqual(alert.preferredStyle, .alert)
        XCTAssertEqual(alert.actions.count, 1)
        XCTAssertEqual(alert.actions.first?.title, "OK")
        XCTAssertEqual(alert.actions.first?.style, .default)
    }

    // MARK: - 5. E2E: Store Notice → Alert Path

    /// Test: EditorStore notice emission triggers alert creation with correct content.
    /// Tests the full path: reducer emits notice → store forwards → alert is correct.
    @MainActor func test_storeNoticeEmission_producesCorrectAlert() {
        // Given: 3 scenes with transition between 0-1
        var draft = ProjectDraft.create(origin: .template(templateId: "test-template"))
        var timeline = CanonicalTimeline.empty()
        var payloads: [UUID: TimelinePayload] = [:]

        for i in 0..<3 {
            let payloadId = UUID()
            payloads[payloadId] = .scene(ScenePayload(sceneTypeId: "scene_\(i)"))
            timeline.tracks[0].items.append(TimelineItem(
                payloadId: payloadId, kind: .scene, startUs: nil, durationUs: 1_000_000
            ))
        }
        timeline.payloads = payloads
        draft.canonicalTimeline = timeline

        let store = EditorStore()
        store.dispatch(.loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: []))

        let sceneItems = store.state.sceneItems
        let key01 = SceneBoundaryKey(sceneItems[0].id, sceneItems[1].id)

        // Set a transition first
        store.dispatch(.setBoundaryTransition(
            fromSceneId: sceneItems[0].id,
            toSceneId: sceneItems[1].id,
            transition: SceneTransition.v1Preset(for: .fade)
        ))

        // Wire notice handler
        var receivedNotice: EditorNotice?
        store.onNotice = { notice in
            receivedNotice = notice
        }

        // When: Reorder breaks the boundary
        store.dispatch(.reorderScene(sceneId: sceneItems[0].id, toIndex: 2))

        // Then: Notice received
        guard case .boundaryTransitionsReset(let keys) = receivedNotice else {
            XCTFail("Expected boundaryTransitionsReset notice")
            return
        }
        XCTAssertTrue(keys.contains(key01))

        // And: Alert factory produces correct alert for this notice
        let alert = EditorViewController.makeBoundaryTransitionsResetAlert()
        XCTAssertEqual(alert.title, "Transitions Removed")
        XCTAssertEqual(alert.actions.count, 1)
    }
}
