import UIKit
import TVECore

/// Transient Core Animation layer that draws the selected text overlay during a
/// live transform gesture. It is NOT persisted and is NOT used for export — it
/// exists only between gesture begin and end so the text moves/rotates/reflows
/// in hardware at display rate while the committed Metal copy is hidden.
///
/// Layout parity: this draws the SAME `NSAttributedString` (same font, word
/// wrapping, centering, 2px edge padding) that `OverlayRenderResourceCache`
/// rasterizes for the Metal preview/export, sized through the SAME
/// `TextOverlayLayout` contract. The only difference is the coordinate space:
/// the Metal texture works in pixels (`pixelScale`), this layer works in view
/// points (`pointsPerCanvasUnit`). Because both derive the box from the same
/// wrapped layout, committing back to Metal produces no visible jump.
final class TextOverlayLiveTextLayer: CALayer {

    /// Resolved text style/content for the current frame of the gesture.
    struct Content {
        var text: String
        var fontFamily: String?
        /// Canvas-relative font size in points (NOT yet scaled to the view).
        var fontSize: CGFloat
        var colorHex: String
        /// Canvas-normalized box width (0..1 of canvas width).
        var boxWidth: CGFloat
    }

    private var content: Content?
    /// View points per canvas unit (uniform scale of the canvas→view transform).
    private var pointsPerCanvasUnit: CGFloat = 1
    private var canvasSize: SizeD = SizeD(width: 0, height: 0)

    override init() {
        super.init()
        commonInit()
    }

    override init(layer: Any) {
        super.init(layer: layer)
        commonInit()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func commonInit() {
        // The layer is redrawn on demand (content/size changes), not animated.
        needsDisplayOnBoundsChange = true
        contentsScale = UIScreen.main.scale
        isOpaque = false
    }

    /// Updates the resolved content/style and the canvas→view scale. Returns the
    /// wrapped content size in canvas units (matching the Metal texture's content
    /// size) so the caller can size/position this layer identically to the
    /// committed render. Nil if the layout could not be computed.
    @discardableResult
    func update(
        content: Content,
        pointsPerCanvasUnit: CGFloat,
        canvasSize: SizeD
    ) -> CGSize? {
        self.content = content
        self.pointsPerCanvasUnit = pointsPerCanvasUnit
        self.canvasSize = canvasSize
        setNeedsDisplay()
        return Self.contentCanvasSize(content: content, canvasSize: canvasSize)
    }

    /// Wrapped content size in canvas units for the given content, using the
    /// shared layout. `canvasPixelWidth` is taken as the integer canvas width so
    /// `pixelScale == 1` and the layout result is already canvas-unit sized — the
    /// same convention `EditorTimelineController.makeSelectedBox` uses for the
    /// selection border, keeping live layer + border + committed render in sync.
    static func contentCanvasSize(content: Content, canvasSize: SizeD) -> CGSize? {
        guard canvasSize.width > 0 else { return nil }
        let pixelWidth = max(1, Int(canvasSize.width.rounded()))
        let input = TextOverlayLayout.Input(
            text: content.text,
            fontFamily: content.fontFamily,
            fontSize: content.fontSize,
            colorHex: content.colorHex,
            boxWidth: content.boxWidth
        )
        let layout = TextOverlayLayout.layout(
            input: input, canvasSize: canvasSize, canvasPixelWidth: pixelWidth
        )
        return TextOverlayLayout.contentCanvasSize(
            pixelWidth: layout.pixelWidth,
            pixelHeight: layout.pixelHeight,
            canvasSize: canvasSize,
            canvasPixelWidth: pixelWidth
        )
    }

    // MARK: - Drawing

    override func draw(in ctx: CGContext) {
        guard let content else { return }

        // Glyphs are drawn at canvas-point font size scaled into view points, so
        // the on-screen text matches the Metal texture (which scales by pixels).
        let scaledFontSize = content.fontSize * pointsPerCanvasUnit
        let font = TextOverlayLayout.font(fontFamily: content.fontFamily, scaledFontSize: scaledFontSize)
        let color = UIColor(overlayHexString: content.colorHex) ?? .white
        let attributes = TextOverlayLayout.attributes(font: font, color: color)

        // The same 2px edge padding the texture rasterizer insets by, scaled into
        // view points so the wrapped text occupies the same fraction of the box.
        let pad = TextOverlayLayout.edgePaddingPoints * pointsPerCanvasUnit
        let drawRect = CGRect(
            x: pad,
            y: pad,
            width: max(0, bounds.width - pad * 2),
            height: max(0, bounds.height - pad * 2)
        )

        UIGraphicsPushContext(ctx)
        (content.text as NSString).draw(
            with: drawRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
        UIGraphicsPopContext()
    }

    /// Suppress implicit animations for every property change driven by the
    /// gesture — position/transform/bounds must track the finger with no
    /// rubber-banding lag.
    override func action(forKey event: String) -> CAAction? {
        NSNull()
    }
}
