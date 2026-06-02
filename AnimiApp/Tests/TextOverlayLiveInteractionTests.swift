import XCTest
import TVECore
@testable import AnimiApp

/// Integration coverage for the two P1 repair findings on the live text-box
/// interaction view:
///   1. Live bounds must reflow through the shared `TextOverlayLayout`, NOT by
///      proportionally scaling the cached content size (pinch changes wrapping).
///   2. The canvas clip mask must live on the full-bounds host layer, in the
///      correct coordinate space — not on the transformed live text layer.
@MainActor
final class TextOverlayLiveInteractionTests: XCTestCase {

    private let canvasW: CGFloat = 1080
    private let canvasH: CGFloat = 1920
    // Long enough that narrowing the box changes the number of wrapped lines.
    private let longText = "The quick brown fox jumps over the lazy dog repeatedly"

    private func makeOverlay() -> OverlayPositionDragView {
        let overlay = OverlayPositionDragView()
        overlay.canvasSize = CGSize(width: canvasW, height: canvasH)
        var mapper = EditorCanvasMapper()
        mapper.canvasSize = SizeD(width: Double(canvasW), height: Double(canvasH))
        mapper.viewSize = CGSize(width: 375, height: 667)
        overlay.canvasToView = mapper.canvasToViewTransform()
        overlay.frame = CGRect(x: 0, y: 0, width: 375, height: 667)
        return overlay
    }

    private func sharedContentSize(boxWidth: CGFloat, fontSize: CGFloat) -> CGSize {
        TextOverlayLiveTextLayer.contentCanvasSize(
            content: TextOverlayLiveTextLayer.Content(
                text: longText, fontFamily: nil, fontSize: fontSize, colorHex: "#FFFFFF", boxWidth: boxWidth
            ),
            canvasSize: SizeD(width: Double(canvasW), height: Double(canvasH))
        )!
    }

    private func selectBox(_ overlay: OverlayPositionDragView, boxWidth: CGFloat, fontSize: CGFloat) -> UUID {
        let id = UUID()
        let size = sharedContentSize(boxWidth: boxWidth, fontSize: fontSize)
        overlay.setSelectedBox(OverlayPositionDragView.SelectedBox(
            itemId: id,
            centerX: 0.5, centerY: 0.5,
            boxWidth: boxWidth, fontSize: fontSize, rotation: 0,
            contentCanvasSize: size,
            text: longText, fontFamily: nil, colorHex: "#FFFFFF"
        ))
        overlay.layoutIfNeeded()
        return id
    }

    // MARK: - P1-1: live bounds reflow through shared layout

    /// After a pinch (smaller box width + larger font), the live box content size
    /// must equal the shared-layout result for the new box/font, and must NOT be
    /// the old size scaled proportionally by the width ratio.
    func testLivePinch_reflowsThroughSharedLayout_notProportionalScale() {
        let overlay = makeOverlay()
        let startBoxWidth: CGFloat = 0.8
        let startFont: CGFloat = 40
        _ = selectBox(overlay, boxWidth: startBoxWidth, fontSize: startFont)
        overlay.beginLiveInteractionForTesting()

        let startSize = overlay.selectedBox!.contentCanvasSize

        // Pinch: narrower box, larger glyphs → more wrapped lines, taller content.
        let newBoxWidth: CGFloat = 0.4
        let newFont: CGFloat = 60
        overlay.applyTransformResultForTesting(TextOverlayTransformSession.Result(
            centerX: 0.5, centerY: 0.5, boxWidth: newBoxWidth, fontSize: newFont, rotation: 0
        ))

        let liveSize = overlay.selectedBox!.contentCanvasSize
        let expected = sharedContentSize(boxWidth: newBoxWidth, fontSize: newFont)
        XCTAssertEqual(liveSize.width, expected.width, accuracy: 1e-6, "live width must follow shared layout")
        XCTAssertEqual(liveSize.height, expected.height, accuracy: 1e-6, "live height must follow shared layout")

        // The rejected proportional-scaling path would have produced this instead.
        let widthRatio = newBoxWidth / startBoxWidth
        let proportional = CGSize(width: startSize.width * widthRatio, height: startSize.height * widthRatio)
        XCTAssertNotEqual(liveSize.height, proportional.height, accuracy: 0.5,
                          "reflow must differ from proportional scaling when wrapping changes")
    }

    // MARK: - P1-2: clip mask coordinate space

    /// The canvas clip mask must be installed on the full-bounds host layer
    /// (frame == view bounds), and the transformed live text layer itself must
    /// carry no mask — otherwise off-canvas clipping is wrong.
    func testLiveClipMask_isOnFullBoundsHost_notOnTransformedLayer() {
        let overlay = makeOverlay()
        _ = selectBox(overlay, boxWidth: 0.6, fontSize: 40)
        overlay.beginLiveInteractionForTesting()
        overlay.applyTransformResultForTesting(TextOverlayTransformSession.Result(
            centerX: 0.5, centerY: 0.5, boxWidth: 0.6, fontSize: 40, rotation: 0.3
        ))

        let host = overlay.liveTextHostForTesting
        let live = overlay.liveTextLayerForTesting

        XCTAssertNotNil(host.mask, "canvas clip mask must be on the host layer")
        XCTAssertNil(live.mask, "the transformed live text layer must not carry the mask itself")
        XCTAssertEqual(host.frame, overlay.bounds, "host must fill the view bounds (mask coordinate space)")
    }

    /// Moving the box far off-canvas keeps the mask on the host with the host
    /// still at full bounds (so clipping happens at the template edge regardless
    /// of how far the live layer is translated).
    func testLiveOffCanvas_hostStillFullBounds_maskPresent() {
        let overlay = makeOverlay()
        _ = selectBox(overlay, boxWidth: 0.6, fontSize: 40)
        overlay.beginLiveInteractionForTesting()
        overlay.applyTransformResultForTesting(TextOverlayTransformSession.Result(
            centerX: 1.4, centerY: -0.3, boxWidth: 0.6, fontSize: 40, rotation: 0
        ))

        let host = overlay.liveTextHostForTesting
        XCTAssertNotNil(host.mask)
        XCTAssertEqual(host.frame, overlay.bounds)
    }
}
