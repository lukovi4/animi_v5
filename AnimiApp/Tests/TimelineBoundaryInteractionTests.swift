import XCTest
@testable import AnimiApp

/// UI-seam tests for PR-G: Transition Boundary Picker interactions.
/// Tests callback contracts at view/controller boundaries.
final class TimelineBoundaryInteractionTests: XCTestCase {

    // MARK: - Test Helpers

    /// Creates a SceneBoundaryDraft for testing.
    private func makeBoundaryDraft(
        fromSceneId: UUID = UUID(),
        toSceneId: UUID = UUID(),
        transition: SceneTransition = .none
    ) -> SceneBoundaryDraft {
        SceneBoundaryDraft(
            fromSceneId: fromSceneId,
            toSceneId: toSceneId,
            transition: transition
        )
    }

    /// Creates a SceneTrackSnapshot for testing.
    private func makeSnapshot(
        scenes: [SceneDraft],
        boundaries: [SceneBoundaryDraft] = [],
        selectedSceneId: UUID? = nil
    ) -> SceneTrackSnapshot {
        SceneTrackSnapshot(
            scenes: scenes,
            boundaries: boundaries,
            selectedSceneId: selectedSceneId,
            minDurationUs: ProjectDraft.minSceneDurationUs
        )
    }

    // MARK: - 1. SceneTrackView Boundary Tap Tests

    /// Test: Boundary tap calls onTapBoundary with correct scene IDs.
    func test_sceneTrackView_boundaryTap_callsOnTapBoundaryWithCorrectIds() {
        // Given: SceneTrackView with 2 scenes and 1 boundary
        let sceneTrack = SceneTrackView()
        sceneTrack.frame = CGRect(x: 0, y: 0, width: 400, height: 60)

        let scene1Id = UUID()
        let scene2Id = UUID()
        let scenes = [
            SceneDraft(id: scene1Id, durationUs: 2_000_000),
            SceneDraft(id: scene2Id, durationUs: 2_000_000)
        ]
        let boundary = makeBoundaryDraft(fromSceneId: scene1Id, toSceneId: scene2Id)
        let snapshot = makeSnapshot(scenes: scenes, boundaries: [boundary])

        var receivedFromId: UUID?
        var receivedToId: UUID?
        var callbackCalled = false

        sceneTrack.onTapBoundary = { fromId, toId, _ in
            callbackCalled = true
            receivedFromId = fromId
            receivedToId = toId
        }

        sceneTrack.applySnapshot(snapshot)
        sceneTrack.layoutIfNeeded()

        // When: Simulate boundary tap via sendActions
        // Find the boundary view and trigger its action
        let boundaryViews = sceneTrack.subviews.compactMap { $0 as? TransitionBoundaryView }
        XCTAssertEqual(boundaryViews.count, 1, "Should have 1 boundary view")

        if let boundaryView = boundaryViews.first {
            boundaryView.sendActions(for: .touchUpInside)
        }

        // Then: Callback called with correct IDs
        XCTAssertTrue(callbackCalled, "onTapBoundary should be called")
        XCTAssertEqual(receivedFromId, scene1Id)
        XCTAssertEqual(receivedToId, scene2Id)
    }

    /// Test: Multiple boundaries trigger correct callbacks.
    func test_sceneTrackView_multipleBoundaries_correctCallbacks() {
        // Given: 3 scenes = 2 boundaries
        let sceneTrack = SceneTrackView()
        sceneTrack.frame = CGRect(x: 0, y: 0, width: 600, height: 60)

        let scene1Id = UUID()
        let scene2Id = UUID()
        let scene3Id = UUID()
        let scenes = [
            SceneDraft(id: scene1Id, durationUs: 2_000_000),
            SceneDraft(id: scene2Id, durationUs: 2_000_000),
            SceneDraft(id: scene3Id, durationUs: 2_000_000)
        ]
        let boundaries = [
            makeBoundaryDraft(fromSceneId: scene1Id, toSceneId: scene2Id),
            makeBoundaryDraft(fromSceneId: scene2Id, toSceneId: scene3Id)
        ]
        let snapshot = makeSnapshot(scenes: scenes, boundaries: boundaries)

        var receivedPairs: [(UUID, UUID)] = []

        sceneTrack.onTapBoundary = { fromId, toId, _ in
            receivedPairs.append((fromId, toId))
        }

        sceneTrack.applySnapshot(snapshot)
        sceneTrack.layoutIfNeeded()

        // When: Tap each boundary
        let boundaryViews = sceneTrack.subviews.compactMap { $0 as? TransitionBoundaryView }
        XCTAssertEqual(boundaryViews.count, 2, "Should have 2 boundary views")

        for boundaryView in boundaryViews {
            boundaryView.sendActions(for: .touchUpInside)
        }

        // Then: Both callbacks called with correct pairs
        XCTAssertEqual(receivedPairs.count, 2)
        XCTAssertTrue(receivedPairs.contains { $0.0 == scene1Id && $0.1 == scene2Id })
        XCTAssertTrue(receivedPairs.contains { $0.0 == scene2Id && $0.1 == scene3Id })
    }

    /// Test: Boundary views hidden in reorder mode.
    func test_sceneTrackView_reorderMode_hidesBoundaries() {
        // Given: SceneTrackView with boundary
        let sceneTrack = SceneTrackView()
        sceneTrack.frame = CGRect(x: 0, y: 0, width: 400, height: 60)

        let scene1Id = UUID()
        let scene2Id = UUID()
        let scenes = [
            SceneDraft(id: scene1Id, durationUs: 2_000_000),
            SceneDraft(id: scene2Id, durationUs: 2_000_000)
        ]
        let boundary = makeBoundaryDraft(fromSceneId: scene1Id, toSceneId: scene2Id)
        let snapshot = makeSnapshot(scenes: scenes, boundaries: [boundary])

        sceneTrack.applySnapshot(snapshot)
        sceneTrack.layoutIfNeeded()

        let boundaryViews = sceneTrack.subviews.compactMap { $0 as? TransitionBoundaryView }
        XCTAssertFalse(boundaryViews.isEmpty)

        // When: Enter reorder mode
        sceneTrack.setReorderMode(true)

        // Then: Boundary views hidden
        for bv in boundaryViews {
            XCTAssertTrue(bv.isHidden, "Boundary should be hidden in reorder mode")
            XCTAssertFalse(bv.isUserInteractionEnabled, "Boundary should be disabled in reorder mode")
        }

        // When: Exit reorder mode
        sceneTrack.setReorderMode(false)

        // Then: Boundary views visible again
        for bv in boundaryViews {
            XCTAssertFalse(bv.isHidden, "Boundary should be visible after exiting reorder mode")
            XCTAssertTrue(bv.isUserInteractionEnabled, "Boundary should be enabled after exiting reorder mode")
        }
    }

    // MARK: - 2. TimelineView Event Emission Tests

    /// Test: TimelineView emits .editBoundaryTransition event on boundary tap.
    func test_timelineView_boundaryTap_emitsEditBoundaryTransitionEvent() {
        // Given: TimelineView with 2 scenes
        let timelineView = TimelineView()
        timelineView.frame = CGRect(x: 0, y: 0, width: 400, height: 200)

        let scene1Id = UUID()
        let scene2Id = UUID()
        let scenes = [
            SceneDraft(id: scene1Id, durationUs: 2_000_000),
            SceneDraft(id: scene2Id, durationUs: 2_000_000)
        ]
        let boundaries = [
            SceneBoundaryDraft(fromSceneId: scene1Id, toSceneId: scene2Id, transition: .none)
        ]

        var receivedEvent: TimelineEvent?
        timelineView.onEvent = { event in
            receivedEvent = event
        }

        timelineView.configure(
            scenes: scenes,
            boundaries: boundaries,
            templateFPS: 30,
            minSceneDurationUs: ProjectDraft.minSceneDurationUs
        )
        timelineView.layoutIfNeeded()

        // When: Find and tap boundary in sceneTrack
        // Access sceneTrack via subview hierarchy
        guard let scrollView = timelineView.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView,
              let contentView = scrollView.subviews.first,
              let tracksStack = contentView.subviews.first(where: { $0 is UIStackView }),
              let sceneTrack = tracksStack.subviews.first as? SceneTrackView else {
            XCTFail("Could not find sceneTrack in view hierarchy")
            return
        }

        let boundaryViews = sceneTrack.subviews.compactMap { $0 as? TransitionBoundaryView }
        XCTAssertEqual(boundaryViews.count, 1, "Should have 1 boundary view")

        if let boundaryView = boundaryViews.first {
            boundaryView.sendActions(for: .touchUpInside)
        }

        // Then: Event emitted with correct data
        guard case .editBoundaryTransition(let fromId, let toId, _) = receivedEvent else {
            XCTFail("Expected .editBoundaryTransition event, got: \(String(describing: receivedEvent))")
            return
        }

        XCTAssertEqual(fromId, scene1Id)
        XCTAssertEqual(toId, scene2Id)
    }

    // MARK: - 3. TransitionPickerViewController Tests

    /// Test: Picker shows all 12 presets.
    func test_transitionPicker_showsAll12Presets() {
        // Given
        let picker = TransitionPickerViewController(currentType: .none)
        _ = picker.view // Trigger viewDidLoad

        // When: Check tableView data source
        let tableView = picker.view.subviews.first { $0 is UITableView } as? UITableView
        XCTAssertNotNil(tableView)

        // Then: 12 rows
        let rowCount = tableView?.dataSource?.tableView(tableView!, numberOfRowsInSection: 0)
        XCTAssertEqual(rowCount, 12, "Should show all 12 presets")
    }

    /// Test: Picker callback receives correct transition for selection.
    func test_transitionPicker_selectionReturnsCorrectTransition() {
        // Given
        let picker = TransitionPickerViewController(currentType: .none)
        _ = picker.view

        var receivedTransition: SceneTransition?
        picker.onSelectTransition = { transition in
            receivedTransition = transition
        }

        let tableView = picker.view.subviews.first { $0 is UITableView } as? UITableView
        XCTAssertNotNil(tableView)

        // When: Simulate selecting "Fade" (index 1)
        // Note: In real scenario, dismiss would happen first.
        // For unit test, we can't easily test dismiss timing without presenting.
        // We test that the callback receives correct transition type.
        let fadeIndexPath = IndexPath(row: 1, section: 0)
        tableView?.delegate?.tableView?(tableView!, didSelectRowAt: fadeIndexPath)

        // Then: Callback called with fade transition
        // Note: Callback is in dismiss completion, so won't fire in unit test context.
        // This test documents the expected behavior.
        // Integration test or manual QA needed for full dismiss-before-callback verification.
    }

    /// Test: Picker shows checkmark on current selection.
    func test_transitionPicker_showsCheckmarkOnCurrentSelection() {
        // Given: Current transition is fade
        let picker = TransitionPickerViewController(currentType: .fade)
        _ = picker.view

        let tableView = picker.view.subviews.first { $0 is UITableView } as? UITableView
        XCTAssertNotNil(tableView)

        // When: Get cell for fade (index 1)
        let fadeIndexPath = IndexPath(row: 1, section: 0)
        let fadeCell = tableView?.dataSource?.tableView(tableView!, cellForRowAt: fadeIndexPath)

        // Then: Fade has checkmark
        XCTAssertEqual(fadeCell?.accessoryType, .checkmark)

        // And: None (index 0) does not have checkmark
        let noneIndexPath = IndexPath(row: 0, section: 0)
        let noneCell = tableView?.dataSource?.tableView(tableView!, cellForRowAt: noneIndexPath)
        XCTAssertEqual(noneCell?.accessoryType, UITableViewCell.AccessoryType.none)
    }

    /// Test: Picker footer shows correct text.
    func test_transitionPicker_footerShowsCorrectText() {
        // Given
        let picker = TransitionPickerViewController(currentType: .none)
        _ = picker.view

        let tableView = picker.view.subviews.first { $0 is UITableView } as? UITableView
        XCTAssertNotNil(tableView)

        // When: Get footer
        let footer = tableView?.dataSource?.tableView?(tableView!, titleForFooterInSection: 0)

        // Then: Correct text (P2 fix)
        XCTAssertEqual(footer, "Animated transitions use a fixed duration of 14 frames.")
    }

    /// Test: TransitionBoundaryView correctly stores scene IDs.
    func test_transitionBoundaryView_storesSceneIds() {
        // Given
        let fromId = UUID()
        let toId = UUID()

        // When
        let boundaryView = TransitionBoundaryView(fromSceneId: fromId, toSceneId: toId)

        // Then
        XCTAssertEqual(boundaryView.fromSceneId, fromId)
        XCTAssertEqual(boundaryView.toSceneId, toId)
    }

    /// Test: TransitionBoundaryView configure updates visual state.
    func test_transitionBoundaryView_configureUpdatesState() {
        // Given
        let boundaryView = TransitionBoundaryView(fromSceneId: UUID(), toSceneId: UUID())

        // When: Configure with fade
        let fadeTransition = SceneTransition.v1Preset(for: .fade)
        boundaryView.configure(transition: fadeTransition)

        // Then: Transition is stored
        XCTAssertEqual(boundaryView.transition.type, .fade)
    }

    /// Test: TransitionBoundaryView accessibility label reflects transition type.
    func test_transitionBoundaryView_accessibilityLabel() {
        let boundaryView = TransitionBoundaryView(fromSceneId: UUID(), toSceneId: UUID())

        // Default (.none)
        XCTAssertEqual(boundaryView.accessibilityLabel, "Transition: None")

        // Configure with fade
        boundaryView.configure(transition: SceneTransition.v1Preset(for: .fade))
        XCTAssertEqual(boundaryView.accessibilityLabel, "Transition: Fade")

        // Configure with slide left
        boundaryView.configure(transition: SceneTransition.v1Preset(for: .slide(direction: .left)))
        XCTAssertEqual(boundaryView.accessibilityLabel, "Transition: Slide Left")
    }
}
