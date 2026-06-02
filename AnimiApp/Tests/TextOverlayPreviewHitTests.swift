import XCTest
import TVECore
@testable import AnimiApp

/// Tests that preview hit testing honors the real ROTATED text-box bounds while
/// stickers stay axis-aligned (no regression).
final class TextOverlayPreviewHitTests: XCTestCase {

    private let canvas = SizeD(width: 1080, height: 1920)
    private let viewSize = CGSize(width: 540, height: 960) // square-fit, no letterbox

    private func mapper() -> EditorCanvasMapper {
        var m = EditorCanvasMapper()
        m.canvasSize = canvas
        m.viewSize = viewSize
        return m
    }

    private func viewPoint(canvasX: CGFloat, canvasY: CGFloat) -> CGPoint {
        mapper().canvasToView(CGPoint(x: canvasX, y: canvasY))
    }

    private func textItem(rotation: CGFloat, centerX: CGFloat = 0.5, centerY: CGFloat = 0.5) -> ResolvedOverlayRenderItem {
        ResolvedOverlayRenderItem(
            stableId: UUID(),
            kind: .text,
            content: .text(text: "Hi", fontFamily: nil, fontSize: 32, colorHex: "#FFFFFF", boxWidth: 0.6),
            presentation: .text(centerX: centerX, centerY: centerY, rotation: rotation),
            zOrder: 0
        )
    }

    /// A wide, short box rotated 90° becomes tall+narrow. A tap above center
    /// (outside the unrotated box) should hit only the rotated box.
    func testRotatedText_hitFollowsRotation() {
        // Content: wide (600) and short (120) in canvas units.
        let contentSize = CGSize(width: 600, height: 120)
        let pointAbove = viewPoint(canvasX: 0.5 * canvas.width, canvasY: 0.5 * canvas.height - 200)

        let unrotated = textItem(rotation: 0)
        let hitUnrotated = OverlayPreviewHitTester.hitTest(
            viewPoint: pointAbove, items: [unrotated], canvasSize: canvas, viewSize: viewSize,
            minTouchTargetPoints: 0, contentCanvasSize: { _ in contentSize }
        )
        XCTAssertNil(hitUnrotated, "200 above center is outside a 120-tall unrotated box")

        let rotated = textItem(rotation: .pi / 2)
        let hitRotated = OverlayPreviewHitTester.hitTest(
            viewPoint: pointAbove, items: [rotated], canvasSize: canvas, viewSize: viewSize,
            minTouchTargetPoints: 0, contentCanvasSize: { _ in contentSize }
        )
        XCTAssertEqual(hitRotated, .text(itemId: rotated.stableId), "Rotated 90°, the 600-wide extent now covers vertical space")
    }

    func testCenterTap_hitsRegardlessOfRotation() {
        let item = textItem(rotation: 0.8)
        let center = viewPoint(canvasX: 0.5 * canvas.width, canvasY: 0.5 * canvas.height)
        let hit = OverlayPreviewHitTester.hitTest(
            viewPoint: center, items: [item], canvasSize: canvas, viewSize: viewSize,
            minTouchTargetPoints: 44, contentCanvasSize: { _ in CGSize(width: 200, height: 80) }
        )
        XCTAssertEqual(hit, .text(itemId: item.stableId))
    }

    func testSticker_remainsAxisAligned() {
        let sticker = ResolvedOverlayRenderItem(
            stableId: UUID(),
            kind: .sticker,
            content: .sticker(stickerId: "star", imageURL: URL(fileURLWithPath: "/dev/null")),
            presentation: .default(centerX: 0.5, centerY: 0.5),
            zOrder: 0
        )
        // Corner-ish tap that an axis-aligned 200x200 box still excludes when far enough.
        let farPoint = viewPoint(canvasX: 0.5 * canvas.width + 400, canvasY: 0.5 * canvas.height)
        let hit = OverlayPreviewHitTester.hitTest(
            viewPoint: farPoint, items: [sticker], canvasSize: canvas, viewSize: viewSize,
            minTouchTargetPoints: 44, contentCanvasSize: { _ in CGSize(width: 200, height: 200) }
        )
        XCTAssertNil(hit)
    }
}
