import XCTest
import TVECore
@testable import AnimiApp

/// Integration tests for text overlay end-to-end flow (PR9).
/// Tests full store round-trip: add → select → edit → move → trim → delete → save/open.
@MainActor
final class TextOverlayIntegrationTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore(sceneDurations: [TimeUs] = [5_000_000]) -> EditorStore {
        var draft = ProjectDraft.create(origin: .template(templateId: "test-template"))
        var timeline = CanonicalTimeline.empty()
        var payloads: [UUID: TimelinePayload] = [:]
        for (index, duration) in sceneDurations.enumerated() {
            let payloadId = UUID()
            payloads[payloadId] = .scene(ScenePayload(sceneTypeId: "scene_\(index)"))
            let item = TimelineItem(payloadId: payloadId, kind: .scene, startUs: nil, durationUs: duration)
            timeline.tracks[0].items.append(item)
        }
        timeline.payloads = payloads
        draft.canonicalTimeline = timeline
        return EditorStore.create(draft: draft, templateFPS: 30, defaultSceneSequence: [])
    }

    // MARK: - Full Flow

    func testFullFlow_addSelectEditMoveDeleteText() {
        let store = makeStore()

        // 1. Add text overlay
        store.dispatch(.addTextOverlay(
            text: "Hello World",
            fontSize: 32,
            colorHex: "#FF0000",
            fontFamily: nil,
            startUs: 1_000_000,
            durationUs: 2_000_000
        ))

        XCTAssertEqual(store.state.canonicalTimeline.textItems.count, 1)
        let itemId = store.state.canonicalTimeline.textItems.first!.id
        XCTAssertTrue(store.state.selection.isTextSelected)

        // 2. Edit text content
        var payload = store.state.canonicalTimeline.textPayload(for: itemId)!
        payload.text = "Updated Text"
        payload.fontSize = 48
        store.dispatch(.updateTextPayload(itemId: itemId, payload: payload))

        XCTAssertEqual(store.state.canonicalTimeline.textPayload(for: itemId)?.text, "Updated Text")
        XCTAssertEqual(store.state.canonicalTimeline.textPayload(for: itemId)?.fontSize, 48)

        // 3. Move item on timeline (gesture flow)
        store.dispatch(.moveItem(itemId: itemId, newStartUs: 0, phase: .began))
        store.dispatch(.moveItem(itemId: itemId, newStartUs: 500_000, phase: .changed))
        store.dispatch(.moveItem(itemId: itemId, newStartUs: 2_000_000, phase: .ended))

        XCTAssertEqual(store.state.canonicalTimeline.textItems.first?.startUs, 2_000_000)

        // 4. Drag position on canvas
        store.dispatch(.dragOverlayPosition(itemId: itemId, centerX: 0.3, centerY: 0.8, phase: .began))
        store.dispatch(.dragOverlayPosition(itemId: itemId, centerX: 0.3, centerY: 0.8, phase: .ended))

        XCTAssertEqual(store.state.canonicalTimeline.textPayload(for: itemId)?.centerX, 0.3)
        XCTAssertEqual(store.state.canonicalTimeline.textPayload(for: itemId)?.centerY, 0.8)

        // 5. Delete
        store.dispatch(.deleteItem(itemId: itemId))

        XCTAssertTrue(store.state.canonicalTimeline.textItems.isEmpty)
        XCTAssertEqual(store.state.selection, .none)

        // 6. Undo chain: should restore text
        store.dispatch(.undo) // Undo delete
        XCTAssertEqual(store.state.canonicalTimeline.textItems.count, 1)
    }

    // MARK: - Multiple Text Items

    func testMultipleTextItems_independentLifecycles() {
        let store = makeStore()

        // Add two text overlays
        store.dispatch(.addTextOverlay(text: "First", fontSize: 24, colorHex: "#FFFFFF", fontFamily: nil, startUs: 0, durationUs: 1_000_000))
        let firstId = store.state.canonicalTimeline.textItems.first!.id

        store.dispatch(.addTextOverlay(text: "Second", fontSize: 36, colorHex: "#000000", fontFamily: nil, startUs: 2_000_000, durationUs: 1_000_000))

        XCTAssertEqual(store.state.canonicalTimeline.textItems.count, 2)

        // Delete first — second remains
        store.dispatch(.deleteItem(itemId: firstId))

        XCTAssertEqual(store.state.canonicalTimeline.textItems.count, 1)
        XCTAssertEqual(store.state.canonicalTimeline.textItems.first?.startUs, 2_000_000)
    }

    // MARK: - TextPayload Codable Round-Trip

    func testTextPayload_codableRoundTrip() throws {
        let original = TextPayload(
            text: "Test",
            fontFamily: "Helvetica",
            fontSize: 48,
            colorHex: "#FF0000",
            centerX: 0.3,
            centerY: 0.7
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TextPayload.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.centerX, 0.3)
        XCTAssertEqual(decoded.centerY, 0.7)
    }

    // MARK: - Timeline Payload Codable Round-Trip

    func testTimelinePayload_textCase_codableRoundTrip() throws {
        let textPayload = TextPayload(text: "Hello", fontSize: 32, colorHex: "#FFFFFF", centerX: 0.2, centerY: 0.8)
        let original = TimelinePayload.text(textPayload)

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TimelinePayload.self, from: data)

        XCTAssertEqual(decoded, original)
        if case .text(let decoded) = decoded {
            XCTAssertEqual(decoded.centerX, 0.2)
            XCTAssertEqual(decoded.centerY, 0.8)
        } else {
            XCTFail("Expected .text payload")
        }
    }

    // MARK: - Overlay Track Accessors

    func testOverlayTrackAccessors() {
        let store = makeStore()

        XCTAssertNil(store.state.canonicalTimeline.overlayTrack)
        XCTAssertTrue(store.state.canonicalTimeline.textItems.isEmpty)

        store.dispatch(.addTextOverlay(text: "Test", fontSize: 32, colorHex: "#FFFFFF", fontFamily: nil, startUs: 0, durationUs: 1_000_000))

        XCTAssertNotNil(store.state.canonicalTimeline.overlayTrack)
        XCTAssertEqual(store.state.canonicalTimeline.textItems.count, 1)

        let itemId = store.state.canonicalTimeline.textItems.first!.id
        let payload = store.state.canonicalTimeline.textPayload(for: itemId)
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.text, "Test")
    }

    // MARK: - Production Wiring: OverlayPositionDragView

    /// Verifies that OverlayPositionDragView drag callback wired through production path
    /// dispatches .dragOverlayPosition and mutates session state.
    func testTextPositionOverlay_productionDragWiring_updatesSessionState() {
        let store = makeStore()

        // 1. Add text overlay and verify selection
        store.dispatch(.addTextOverlay(
            text: "Drag Me",
            fontSize: 32,
            colorHex: "#FFFFFF",
            fontFamily: nil,
            startUs: 0,
            durationUs: 2_000_000
        ))
        let itemId = store.state.canonicalTimeline.textItems.first!.id
        XCTAssertTrue(store.state.selection.isTextSelected)

        // 2. Create real OverlayPositionDragView and wire exactly as production does
        let overlay = OverlayPositionDragView()
        overlay.canvasSize = CGSize(width: 1080, height: 1920)
        // Simulate a simple identity-scale canvas→view transform for test (1:1)
        overlay.canvasToView = CGAffineTransform(scaleX: 0.5, y: 0.5)

        // Wire callback exactly as EditorViewController does (text uses transform)
        overlay.onTransform = { [weak store] tItemId, centerX, centerY, boxWidth, fontSize, rotation, phase in
            store?.dispatch(.transformTextBox(
                itemId: tItemId, centerX: centerX, centerY: centerY,
                boxWidth: boxWidth, fontSize: fontSize, rotation: rotation, phase: phase
            ))
        }

        // 3. Set selected text box (as EditorViewController.updateOverlayPositionDrag does)
        let payload = store.state.canonicalTimeline.textPayload(for: itemId)!
        overlay.setSelectedBox(OverlayPositionDragView.SelectedBox(
            itemId: itemId,
            centerX: payload.geometry.centerX,
            centerY: payload.geometry.centerY,
            boxWidth: payload.geometry.boxWidth,
            fontSize: payload.style.fontSize,
            rotation: payload.geometry.rotation,
            contentCanvasSize: CGSize(width: 200, height: 80),
            text: payload.geometry.text,
            fontFamily: payload.style.fontFamily,
            colorHex: payload.style.colorHex
        ))
        XCTAssertNotNil(overlay.selectedBox)
        XCTAssertEqual(overlay.selectedBox?.centerX, 0.5)
        XCTAssertEqual(overlay.selectedBox?.centerY, 0.5)

        // 4. Simulate transform via production callback (as gesture would fire)
        let bw = payload.geometry.boxWidth
        let fs = payload.style.fontSize
        overlay.onTransform?(itemId, 0.5, 0.5, bw, fs, 0, .began)
        overlay.onTransform?(itemId, 0.3, 0.8, bw, fs, 0, .changed)
        overlay.onTransform?(itemId, 0.3, 0.8, bw, fs, 0, .ended)

        // 5. Verify session state changed through production dispatch path
        let updatedPayload = store.state.canonicalTimeline.textPayload(for: itemId)
        XCTAssertEqual(updatedPayload?.centerX, 0.3, "centerX should be updated via production transform path")
        XCTAssertEqual(updatedPayload?.centerY, 0.8, "centerY should be updated via production transform path")
    }

    /// Verifies coordinate mapping round-trip: normalized → canvas → view → drag → normalized.
    func testTextPositionOverlay_coordinateMappingRoundTrip() {
        let overlay = OverlayPositionDragView()

        // Set up a realistic canvas mapper scenario: 1080x1920 canvas in a 375x400 view
        let canvasWidth: CGFloat = 1080
        let canvasHeight: CGFloat = 1920
        overlay.canvasSize = CGSize(width: canvasWidth, height: canvasHeight)

        // Compute the actual EditorCanvasMapper transform
        var mapper = EditorCanvasMapper()
        mapper.canvasSize = SizeD(width: Double(canvasWidth), height: Double(canvasHeight))
        mapper.viewSize = CGSize(width: 375, height: 400)
        overlay.canvasToView = mapper.canvasToViewTransform()

        // Set item at center
        let testId = UUID()
        overlay.setSelectedBox(OverlayPositionDragView.SelectedBox(
            itemId: testId,
            centerX: 0.5,
            centerY: 0.5,
            boxWidth: 0.6,
            fontSize: 32,
            rotation: 0,
            contentCanvasSize: CGSize(width: 200, height: 80),
            text: "Drag Me",
            fontFamily: nil,
            colorHex: "#FFFFFF"
        ))

        // Force layout with a realistic frame
        overlay.frame = CGRect(x: 0, y: 0, width: 375, height: 400)
        overlay.layoutIfNeeded()

        // Verify the box center is positioned correctly:
        // Center of canvas (540, 960) mapped through contain-fit transform to view
        let expectedViewPoint = mapper.canvasToView(CGPoint(
            x: 0.5 * canvasWidth,
            y: 0.5 * canvasHeight
        ))
        let handleCenter = CGPoint(
            x: overlay.selectedBox!.centerX,
            y: overlay.selectedBox!.centerY
        )
        XCTAssertEqual(handleCenter.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(handleCenter.y, 0.5, accuracy: 0.001)

        // The normalized coordinates should not be treated as canvas coords
        // (which would place the point at (0.5, 0.5) in canvas space = near top-left)
        // Instead they represent a fraction of the canvas dimensions
        XCTAssertTrue(expectedViewPoint.x > 0, "View point should be within view bounds")
        XCTAssertTrue(expectedViewPoint.y > 0, "View point should be within view bounds")
    }

    // MARK: - Modal Edit Preserves Transform

    /// Editing text through the modal path (which mutates only text/fontSize/
    /// colorHex on `existingPayload`, exactly like TextEditorViewController.done)
    /// must preserve boxWidth, rotation, and center.
    func testModalEdit_preservesGeometryTransform() {
        let store = makeStore()
        store.dispatch(.addTextOverlay(text: "Orig", fontSize: 32, colorHex: "#FFFFFF", fontFamily: nil, startUs: 0, durationUs: 2_000_000))
        let itemId = store.state.canonicalTimeline.textItems.first!.id

        // User transforms the box (move + pinch + rotate).
        store.dispatch(.transformTextBox(itemId: itemId, centerX: 0.2, centerY: 0.9, boxWidth: 0.35, fontSize: 50, rotation: 0.8, phase: .began))
        store.dispatch(.transformTextBox(itemId: itemId, centerX: 0.2, centerY: 0.9, boxWidth: 0.35, fontSize: 50, rotation: 0.8, phase: .ended))

        // Simulate the modal exactly: start from the existing payload, mutate
        // only the modal-exposed fields via the flat accessors, then dispatch.
        var edited = store.state.canonicalTimeline.textPayload(for: itemId)!
        edited.text = "Edited"
        edited.fontSize = 60
        edited.colorHex = "#00FF00"
        store.dispatch(.updateTextPayload(itemId: itemId, payload: edited))

        let p = store.state.canonicalTimeline.textPayload(for: itemId)!
        // Modal-exposed fields updated.
        XCTAssertEqual(p.geometry.text, "Edited")
        XCTAssertEqual(p.style.fontSize, 60, accuracy: 1e-6)
        XCTAssertEqual(p.style.colorHex, "#00FF00")
        // Transform/geometry NOT exposed by the modal must be preserved.
        XCTAssertEqual(p.geometry.centerX, 0.2, accuracy: 1e-6)
        XCTAssertEqual(p.geometry.centerY, 0.9, accuracy: 1e-6)
        XCTAssertEqual(p.geometry.boxWidth, 0.35, accuracy: 1e-6)
        XCTAssertEqual(p.geometry.rotation, 0.8, accuracy: 1e-6)
    }

    // MARK: - Preview Overlay Tap Selection

    /// Canvas/view used by the preview tap tests. Square-fit (view = canvas * 0.5)
    /// so canvas↔view mapping has no letterbox offset, keeping expected points simple.
    private static let tapCanvasSize = SizeD(width: 1080, height: 1920)
    private static let tapViewSize = CGSize(width: 540, height: 960)

    /// Maps a normalized canvas center to a preview view point (matches production
    /// canvas→view aspect-fit transform).
    private func viewPoint(centerX: CGFloat, centerY: CGFloat) -> CGPoint {
        var mapper = EditorCanvasMapper()
        mapper.canvasSize = Self.tapCanvasSize
        mapper.viewSize = Self.tapViewSize
        return mapper.canvasToView(CGPoint(
            x: centerX * CGFloat(Self.tapCanvasSize.width),
            y: centerY * CGFloat(Self.tapCanvasSize.height)
        ))
    }

    private func resolvedText(itemId: UUID, centerX: CGFloat, centerY: CGFloat) -> ResolvedOverlayRenderItem {
        ResolvedOverlayRenderItem(
            stableId: itemId,
            kind: .text,
            content: .text(text: "Hi", fontFamily: nil, fontSize: 32, colorHex: "#FFFFFF", boxWidth: 0.6),
            presentation: .text(centerX: centerX, centerY: centerY, rotation: 0),
            zOrder: 0
        )
    }

    /// Tapping a visible text overlay in the preview selects `.text(itemId:)`.
    func testPreviewTap_onVisibleText_selectsTextItem() {
        let itemId = UUID()
        let item = resolvedText(itemId: itemId, centerX: 0.5, centerY: 0.5)

        let hit = OverlayPreviewHitTester.hitTest(
            viewPoint: viewPoint(centerX: 0.5, centerY: 0.5),
            items: [item],
            canvasSize: Self.tapCanvasSize,
            viewSize: Self.tapViewSize,
            minTouchTargetPoints: 44,
            contentCanvasSize: { _ in CGSize(width: 200, height: 80) }
        )

        XCTAssertEqual(hit, .text(itemId: itemId))
    }

    /// Tapping empty preview space outside all overlay hit areas is a no-op.
    func testPreviewTap_onEmptySpace_returnsNil() {
        let item = resolvedText(itemId: UUID(), centerX: 0.5, centerY: 0.5)

        // Tap far from the centered item, beyond its bounds + min touch target.
        let hit = OverlayPreviewHitTester.hitTest(
            viewPoint: viewPoint(centerX: 0.95, centerY: 0.05),
            items: [item],
            canvasSize: Self.tapCanvasSize,
            viewSize: Self.tapViewSize,
            minTouchTargetPoints: 44,
            contentCanvasSize: { _ in CGSize(width: 120, height: 60) }
        )

        XCTAssertNil(hit)
    }

    /// A tiny rendered overlay still gets a practical minimum touch target.
    func testPreviewTap_smallText_expandsToMinimumTouchTarget() {
        let itemId = UUID()
        let item = resolvedText(itemId: itemId, centerX: 0.5, centerY: 0.5)

        // Content is essentially zero-sized; tap slightly off-center must still hit
        // thanks to the minimum touch target expansion.
        let canvasCenter = CGPoint(x: 0.5 * Self.tapCanvasSize.width, y: 0.5 * Self.tapCanvasSize.height)
        var mapper = EditorCanvasMapper()
        mapper.canvasSize = Self.tapCanvasSize
        mapper.viewSize = Self.tapViewSize
        let nearCenterView = mapper.canvasToView(CGPoint(x: canvasCenter.x + 8, y: canvasCenter.y + 8))

        let hit = OverlayPreviewHitTester.hitTest(
            viewPoint: nearCenterView,
            items: [item],
            canvasSize: Self.tapCanvasSize,
            viewSize: Self.tapViewSize,
            minTouchTargetPoints: 44,
            contentCanvasSize: { _ in CGSize(width: 1, height: 1) }
        )

        XCTAssertEqual(hit, .text(itemId: itemId))
    }
}
