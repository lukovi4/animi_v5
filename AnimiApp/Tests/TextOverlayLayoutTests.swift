import XCTest
import TVECore
@testable import AnimiApp

/// Unit tests for the shared `TextOverlayLayout`: wrapping to box width, stable
/// bounds, canvas-unit conversion, and rotated point containment. This is the
/// single algorithm shared by preview raster, export raster, hit testing, and
/// the selection border, so these properties underpin preview/export parity.
final class TextOverlayLayoutTests: XCTestCase {

    private let canvas = SizeD(width: 1080, height: 1920)

    private func input(text: String, boxWidth: CGFloat = 0.6, fontSize: CGFloat = 32) -> TextOverlayLayout.Input {
        TextOverlayLayout.Input(
            text: text, fontFamily: nil, fontSize: fontSize, colorHex: "#FFFFFF", boxWidth: boxWidth
        )
    }

    func testLayout_isDeterministic() {
        let a = TextOverlayLayout.layout(input: input(text: "Hello World"), canvasSize: canvas, canvasPixelWidth: 1080)
        let b = TextOverlayLayout.layout(input: input(text: "Hello World"), canvasSize: canvas, canvasPixelWidth: 1080)
        XCTAssertEqual(a.pixelWidth, b.pixelWidth)
        XCTAssertEqual(a.pixelHeight, b.pixelHeight)
    }

    func testLayout_widthDoesNotExceedBox() {
        let boxWidth: CGFloat = 0.5
        let layout = TextOverlayLayout.layout(
            input: input(text: "A reasonably long piece of wrapping text content", boxWidth: boxWidth),
            canvasSize: canvas, canvasPixelWidth: 1080
        )
        let boxPixels = TextOverlayLayout.boxPixelWidth(boxWidth: boxWidth, canvasSize: canvas, canvasPixelWidth: 1080)
        // Allow for the small edge padding added by the layout.
        XCTAssertLessThanOrEqual(CGFloat(layout.pixelWidth), boxPixels + TextOverlayLayout.edgePaddingPoints * 2 + 2)
    }

    func testLayout_narrowerBoxWraps_increasesHeight() {
        let wide = TextOverlayLayout.layout(
            input: input(text: "one two three four five six seven", boxWidth: 0.9),
            canvasSize: canvas, canvasPixelWidth: 1080
        )
        let narrow = TextOverlayLayout.layout(
            input: input(text: "one two three four five six seven", boxWidth: 0.3),
            canvasSize: canvas, canvasPixelWidth: 1080
        )
        XCTAssertGreaterThan(narrow.pixelHeight, wide.pixelHeight, "Narrower box should wrap to more lines (taller)")
    }

    func testContentCanvasSize_convertsPixelsToCanvasUnits() {
        // 1 pixel == 1 canvas unit when canvasPixelWidth == canvas.width.
        let size = TextOverlayLayout.contentCanvasSize(
            pixelWidth: 200, pixelHeight: 80, canvasSize: canvas, canvasPixelWidth: Int(canvas.width)
        )
        XCTAssertEqual(size?.width ?? 0, 200, accuracy: 1e-6)
        XCTAssertEqual(size?.height ?? 0, 80, accuracy: 1e-6)
    }

    func testContains_unrotated() {
        let center = CGPoint(x: 100, y: 100)
        let size = CGSize(width: 80, height: 40)
        XCTAssertTrue(TextOverlayLayout.contains(point: CGPoint(x: 130, y: 110), center: center, size: size, rotation: 0))
        XCTAssertFalse(TextOverlayLayout.contains(point: CGPoint(x: 160, y: 110), center: center, size: size, rotation: 0))
    }

    func testContains_rotated90_swapsEffectiveExtents() {
        let center = CGPoint(x: 0, y: 0)
        let size = CGSize(width: 100, height: 20) // wide + short
        let rot = CGFloat.pi / 2 // 90°: now tall + narrow in world space

        // A point 40 above center: inside only after rotation (was outside vertically).
        XCTAssertFalse(TextOverlayLayout.contains(point: CGPoint(x: 0, y: 40), center: center, size: size, rotation: 0))
        XCTAssertTrue(TextOverlayLayout.contains(point: CGPoint(x: 0, y: 40), center: center, size: size, rotation: rot))

        // A point 40 to the right: inside unrotated, outside once rotated 90°.
        XCTAssertTrue(TextOverlayLayout.contains(point: CGPoint(x: 40, y: 0), center: center, size: size, rotation: 0))
        XCTAssertFalse(TextOverlayLayout.contains(point: CGPoint(x: 40, y: 0), center: center, size: size, rotation: rot))
    }

    func testRotatedCorners_count_and_centerInvariance() {
        let corners = TextOverlayLayout.rotatedCorners(
            center: CGPoint(x: 10, y: 20), size: CGSize(width: 100, height: 40), rotation: 0.7
        )
        XCTAssertEqual(corners.count, 4)
        // Centroid of the 4 corners equals the center regardless of rotation.
        let cx = corners.map(\.x).reduce(0, +) / 4
        let cy = corners.map(\.y).reduce(0, +) / 4
        XCTAssertEqual(cx, 10, accuracy: 1e-6)
        XCTAssertEqual(cy, 20, accuracy: 1e-6)
    }

    /// Rotation parity: the selection-border corners (rotatedCorners) must follow
    /// the SAME rotation convention the renderer (Matrix2D.rotation) applies, so
    /// text and box rotate as one object. Regression for the opposite-direction bug.
    func testRotatedCorners_matchMatrix2DRenderConvention() {
        let rotation = 0.6
        let size = CGSize(width: 120, height: 40)
        let center = CGPoint(x: 0, y: 0)
        let corners = TextOverlayLayout.rotatedCorners(center: center, size: size, rotation: CGFloat(rotation))

        // Render maps a local corner via Matrix2D.rotation about the center.
        let m = Matrix2D.rotation(rotation)
        let hw = size.width / 2, hh = size.height / 2
        let localCorners = [
            Vec2D(x: -Double(hw), y: -Double(hh)),
            Vec2D(x: Double(hw), y: -Double(hh)),
            Vec2D(x: Double(hw), y: Double(hh)),
            Vec2D(x: -Double(hw), y: Double(hh)),
        ]
        for (i, lc) in localCorners.enumerated() {
            let expected = m.apply(to: lc)
            XCTAssertEqual(Double(corners[i].x), expected.x, accuracy: 1e-6, "corner \(i).x parity with render")
            XCTAssertEqual(Double(corners[i].y), expected.y, accuracy: 1e-6, "corner \(i).y parity with render")
        }
    }

    /// `contains` is the exact inverse of `rotatedCorners`' forward map: a point
    /// just inside a corner hits, just outside misses, at the same rotation.
    func testContains_isInverseOfRotatedCorners() {
        let rotation: CGFloat = 0.9
        let size = CGSize(width: 200, height: 60)
        let center = CGPoint(x: 50, y: 70)
        let corners = TextOverlayLayout.rotatedCorners(center: center, size: size, rotation: rotation)
        // Midpoint of an edge is on the boundary; nudge inward toward center.
        let edgeMid = CGPoint(x: (corners[0].x + corners[1].x) / 2, y: (corners[0].y + corners[1].y) / 2)
        let inward = CGPoint(x: edgeMid.x + (center.x - edgeMid.x) * 0.05,
                             y: edgeMid.y + (center.y - edgeMid.y) * 0.05)
        let outward = CGPoint(x: edgeMid.x - (center.x - edgeMid.x) * 0.05,
                              y: edgeMid.y - (center.y - edgeMid.y) * 0.05)
        XCTAssertTrue(TextOverlayLayout.contains(point: inward, center: center, size: size, rotation: rotation))
        XCTAssertFalse(TextOverlayLayout.contains(point: outward, center: center, size: size, rotation: rotation))
    }
}
