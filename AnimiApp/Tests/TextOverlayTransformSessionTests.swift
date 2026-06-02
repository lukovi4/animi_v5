import XCTest
@testable import AnimiApp

/// Unit tests for the pure `TextOverlayTransformSession` baseline+delta model:
/// move, pinch (boxWidth + fontSize together), rotation, clamping, and the
/// baseline/cancel semantics.
final class TextOverlayTransformSessionTests: XCTestCase {

    private func makeSession(
        boxWidth: CGFloat = 0.6,
        fontSize: CGFloat = 32,
        rotation: CGFloat = 0,
        centerX: CGFloat = 0.5,
        centerY: CGFloat = 0.5
    ) -> TextOverlayTransformSession {
        TextOverlayTransformSession(
            itemId: UUID(),
            baselineCenterX: centerX,
            baselineCenterY: centerY,
            baselineBoxWidth: boxWidth,
            baselineFontSize: fontSize,
            baselineRotation: rotation
        )
    }

    func testBaseline_returnsUnchangedValues() {
        let s = makeSession()
        let b = s.baseline()
        XCTAssertEqual(b.centerX, 0.5)
        XCTAssertEqual(b.centerY, 0.5)
        XCTAssertEqual(b.boxWidth, 0.6)
        XCTAssertEqual(b.fontSize, 32)
        XCTAssertEqual(b.rotation, 0)
    }

    func testTranslation_movesCenter() {
        var s = makeSession()
        s.translationDelta = (0.1, -0.2)
        let r = s.current()
        XCTAssertEqual(r.centerX, 0.6, accuracy: 1e-6)
        XCTAssertEqual(r.centerY, 0.3, accuracy: 1e-6)
    }

    func testTranslation_clampsToCanvas() {
        // Center may move OFF-canvas (output is clipped separately): a move that
        // pushes past the canvas edge is NOT clamped to 0...1, only to the
        // generous off-canvas bound.
        var s = makeSession(centerX: 0.9, centerY: 0.1)
        s.translationDelta = (0.5, -0.5)
        let r = s.current()
        XCTAssertEqual(r.centerX, 1.4, accuracy: 1e-6, "off-canvas allowed, not clamped to 1.0")
        XCTAssertEqual(r.centerY, -0.4, accuracy: 1e-6, "off-canvas allowed, not clamped to 0.0")
    }

    func testTranslation_clampsToOffCanvasBound() {
        var s = makeSession(centerX: 0.5, centerY: 0.5)
        s.translationDelta = (100, -100)
        let r = s.current()
        let bound = TextOverlayTransformSession.centerOffCanvasBound
        XCTAssertEqual(r.centerX, 1 + bound, accuracy: 1e-6)
        XCTAssertEqual(r.centerY, -bound, accuracy: 1e-6)
    }

    func testFontSizeBound_exceeds72_noStaleModalCap() {
        // Regression for the removed 72pt modal cap: the shared font-size ceiling
        // must allow text well beyond 72pt.
        XCTAssertGreaterThan(TextOverlayTransformSession.maxFontSize, 72)
        var s = makeSession(boxWidth: 0.5, fontSize: 60)
        s.scaleDelta = 2.0 // 120pt
        XCTAssertEqual(s.current().fontSize, 120, accuracy: 1e-6)
    }

    func testPinch_scalesBoxWidthAndFontSizeTogether() {
        var s = makeSession(boxWidth: 0.5, fontSize: 30)
        s.scaleDelta = 1.5
        let r = s.current()
        XCTAssertEqual(r.boxWidth, 0.75, accuracy: 1e-6)
        XCTAssertEqual(r.fontSize, 45, accuracy: 1e-6)
    }

    func testPinch_clampsBoxWidthAndFontSize() {
        var shrink = makeSession(boxWidth: 0.5, fontSize: 30)
        shrink.scaleDelta = 0.0001
        let rs = shrink.current()
        XCTAssertEqual(rs.boxWidth, TextOverlayTransformSession.minBoxWidth, accuracy: 1e-6)
        XCTAssertEqual(rs.fontSize, TextOverlayTransformSession.minFontSize, accuracy: 1e-6)

        var grow = makeSession(boxWidth: 0.9, fontSize: 380)
        grow.scaleDelta = 10
        let rg = grow.current()
        XCTAssertEqual(rg.boxWidth, TextOverlayTransformSession.maxBoxWidth, accuracy: 1e-6)
        XCTAssertEqual(rg.fontSize, TextOverlayTransformSession.maxFontSize, accuracy: 1e-6)
    }

    func testRotation_addsToBaseline() {
        var s = makeSession(rotation: 0.5)
        s.rotationDelta = 0.25
        XCTAssertEqual(s.current().rotation, 0.75, accuracy: 1e-6)
    }

    func testCombined_pinchAndRotation_applySimultaneously() {
        var s = makeSession(boxWidth: 0.4, fontSize: 20, rotation: 0)
        s.scaleDelta = 2.0
        s.rotationDelta = 1.0
        s.translationDelta = (0.05, 0.05)
        let r = s.current()
        XCTAssertEqual(r.boxWidth, 0.8, accuracy: 1e-6)
        XCTAssertEqual(r.fontSize, 40, accuracy: 1e-6)
        XCTAssertEqual(r.rotation, 1.0, accuracy: 1e-6)
        XCTAssertEqual(r.centerX, 0.55, accuracy: 1e-6)
    }
}
