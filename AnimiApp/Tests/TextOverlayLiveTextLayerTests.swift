import XCTest
import TVECore
@testable import AnimiApp

/// The transient live text layer must size its content through the SAME shared
/// `TextOverlayLayout` contract that the committed Metal render / selection
/// border use, so committing back to Metal produces no visible jump.
@MainActor
final class TextOverlayLiveTextLayerTests: XCTestCase {

    private let canvas = SizeD(width: 1080, height: 1920)

    private func content(text: String, fontSize: CGFloat, boxWidth: CGFloat) -> TextOverlayLiveTextLayer.Content {
        TextOverlayLiveTextLayer.Content(
            text: text,
            fontFamily: nil,
            fontSize: fontSize,
            colorHex: "#FFFFFF",
            boxWidth: boxWidth
        )
    }

    /// The layer's content size equals the shared layout's canvas-unit content
    /// size (the same value `makeSelectedBox` derives for the border).
    func testContentCanvasSize_matchesSharedLayout() {
        let c = content(text: "Hello live layer", fontSize: 40, boxWidth: 0.6)
        let pixelWidth = max(1, Int(canvas.width.rounded()))
        let layout = TextOverlayLayout.layout(
            input: TextOverlayLayout.Input(
                text: c.text, fontFamily: c.fontFamily, fontSize: c.fontSize,
                colorHex: c.colorHex, boxWidth: c.boxWidth
            ),
            canvasSize: canvas,
            canvasPixelWidth: pixelWidth
        )
        let expected = TextOverlayLayout.contentCanvasSize(
            pixelWidth: layout.pixelWidth, pixelHeight: layout.pixelHeight,
            canvasSize: canvas, canvasPixelWidth: pixelWidth
        )

        let actual = TextOverlayLiveTextLayer.contentCanvasSize(content: c, canvasSize: canvas)
        XCTAssertNotNil(actual)
        XCTAssertNotNil(expected)
        XCTAssertEqual(actual!.width, expected!.width, accuracy: 1e-6)
        XCTAssertEqual(actual!.height, expected!.height, accuracy: 1e-6)
    }

    /// A narrower box wraps to more lines, so its content is taller — proving the
    /// layer reflows through the shared wrapping algorithm, not a fixed size.
    func testNarrowerBox_isTaller_viaSharedWrapping() {
        let wide = TextOverlayLiveTextLayer.contentCanvasSize(
            content: content(text: "wrap this sentence across lines", fontSize: 40, boxWidth: 0.9),
            canvasSize: canvas
        )
        let narrow = TextOverlayLiveTextLayer.contentCanvasSize(
            content: content(text: "wrap this sentence across lines", fontSize: 40, boxWidth: 0.3),
            canvasSize: canvas
        )
        XCTAssertNotNil(wide)
        XCTAssertNotNil(narrow)
        XCTAssertGreaterThan(narrow!.height, wide!.height, "narrower box reflows to more lines")
    }

    func testZeroCanvas_returnsNil() {
        let actual = TextOverlayLiveTextLayer.contentCanvasSize(
            content: content(text: "x", fontSize: 40, boxWidth: 0.6),
            canvasSize: SizeD(width: 0, height: 0)
        )
        XCTAssertNil(actual)
    }
}
