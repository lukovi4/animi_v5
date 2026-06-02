import CoreGraphics
import Foundation
import TVECore
import UIKit

/// Shared, deterministic text-box layout used by ALL text overlay consumers:
/// preview rasterization, export rasterization, preview hit testing, and the
/// selection-border overlay. Keeping a single algorithm here is what guarantees
/// preview/export parity — there is no separate approximation anywhere else.
///
/// Pure and GPU-free: given a resolved text box + a canvas/pixel scale it wraps
/// the text to the box width and reports the wrapped content size and the
/// rotated bounds. No Metal, no caches, so it is unit-testable in isolation.
internal enum TextOverlayLayout {

    /// Inset (in pixels, pre-scale baseline) added around the wrapped glyph run
    /// so ascenders/descenders are not clipped. Matches the legacy 2px padding
    /// on each edge.
    static let edgePaddingPoints: CGFloat = 2

    /// Resolved inputs for laying out a text box. All values come from the
    /// persisted `TextBoxGeometry`/`TextStyle` via the resolver, so preview and
    /// export feed identical inputs.
    struct Input: Hashable, Sendable {
        let text: String
        let fontFamily: String?
        /// Canvas-relative font size in points (NOT yet scaled to pixels).
        let fontSize: CGFloat
        let colorHex: String
        /// Canvas-normalized box width (0..1 of canvas width).
        let boxWidth: CGFloat
    }

    /// Result of laying out a text box in pixel space for a given canvas.
    struct Layout {
        /// Wrapped content width in pixels (includes edge padding).
        let pixelWidth: Int
        /// Wrapped content height in pixels (includes edge padding).
        let pixelHeight: Int
    }

    // MARK: - Font

    /// Builds the UIFont for the given style at a pixel-scaled size.
    static func font(fontFamily: String?, scaledFontSize: CGFloat) -> UIFont {
        if let family = fontFamily, let f = UIFont(name: family, size: scaledFontSize) {
            return f
        }
        return .boldSystemFont(ofSize: scaledFontSize)
    }

    /// Attributes for wrapping/drawing. Uses word wrapping so lines reflow to
    /// the box width identically wherever this is called.
    static func attributes(font: UIFont, color: UIColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = .center
        return [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
    }

    // MARK: - Pixel scale

    /// Pixels per canvas unit for a target texture of `canvasPixelWidth` pixels.
    static func pixelScale(canvasSize: SizeD, canvasPixelWidth: Int) -> CGFloat {
        guard canvasSize.width > 0 else { return 1 }
        return CGFloat(canvasPixelWidth) / CGFloat(canvasSize.width)
    }

    /// Box width in pixels for the given normalized box width.
    static func boxPixelWidth(boxWidth: CGFloat, canvasSize: SizeD, canvasPixelWidth: Int) -> CGFloat {
        let clamped = max(0.01, min(1, boxWidth))
        return clamped * CGFloat(canvasPixelWidth)
    }

    // MARK: - Layout

    /// Lays out the text wrapped to the box width, returning pixel dimensions of
    /// the wrapped content (including edge padding). Deterministic for identical
    /// inputs — this is the single wrapping algorithm shared by raster + bounds.
    static func layout(
        input: Input,
        canvasSize: SizeD,
        canvasPixelWidth: Int
    ) -> Layout {
        let scale = pixelScale(canvasSize: canvasSize, canvasPixelWidth: canvasPixelWidth)
        let scaledFontSize = input.fontSize * scale
        let font = font(fontFamily: input.fontFamily, scaledFontSize: scaledFontSize)
        let color = UIColor(overlayHexString: input.colorHex) ?? .white
        let attrs = attributes(font: font, color: color)

        let maxWidth = boxPixelWidth(
            boxWidth: input.boxWidth,
            canvasSize: canvasSize,
            canvasPixelWidth: canvasPixelWidth
        )

        let attributed = NSAttributedString(string: input.text, attributes: attrs)
        let bounding = attributed.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )

        let pad = edgePaddingPoints * 2
        let w = max(1, Int(ceil(bounding.width)) + Int(ceil(pad)))
        let h = max(1, Int(ceil(bounding.height)) + Int(ceil(pad)))
        return Layout(pixelWidth: w, pixelHeight: h)
    }

    // MARK: - Canvas-unit content size

    /// Wrapped content size converted to canvas units. Used by the compositor
    /// (draw quad sizing) and by hit testing / selection bounds so all three
    /// agree on the unrotated box rectangle.
    static func contentCanvasSize(
        pixelWidth: Int,
        pixelHeight: Int,
        canvasSize: SizeD,
        canvasPixelWidth: Int
    ) -> CGSize? {
        guard pixelWidth > 0, pixelHeight > 0, canvasPixelWidth > 0, canvasSize.width > 0 else { return nil }
        let pixelToCanvas = canvasSize.width / Double(canvasPixelWidth)
        return CGSize(
            width: Double(pixelWidth) * pixelToCanvas,
            height: Double(pixelHeight) * pixelToCanvas
        )
    }

    // MARK: - Rotated bounds

    /// The four corners of the unrotated, then center-rotated content rectangle,
    /// in the same coordinate space as `center`. Order: TL, TR, BR, BL.
    /// Used for rotated hit testing and to draw the selection border.
    static func rotatedCorners(
        center: CGPoint,
        size: CGSize,
        rotation: CGFloat
    ) -> [CGPoint] {
        let hw = size.width / 2
        let hh = size.height / 2
        let local = [
            CGPoint(x: -hw, y: -hh),
            CGPoint(x: hw, y: -hh),
            CGPoint(x: hw, y: hh),
            CGPoint(x: -hw, y: hh),
        ]
        // Render convention parity: matches `Matrix2D.rotation` as applied by
        // OverlayCompositor (forward map local→world is
        // dx = lx·cos + ly·sin, dy = -lx·sin + ly·cos). Keeping this identical
        // to the render math is what makes the selection border and the drawn
        // text rotate as one object.
        let cosR = cos(rotation)
        let sinR = sin(rotation)
        return local.map { p in
            CGPoint(
                x: center.x + p.x * cosR + p.y * sinR,
                y: center.y - p.x * sinR + p.y * cosR
            )
        }
    }

    /// Point-in-rotated-rect test. Transforms `point` into the box's local
    /// unrotated frame (inverse of `rotatedCorners`' forward map) and tests
    /// against the half-extents. Same rotation convention as the render.
    static func contains(
        point: CGPoint,
        center: CGPoint,
        size: CGSize,
        rotation: CGFloat
    ) -> Bool {
        let dx = point.x - center.x
        let dy = point.y - center.y
        // Inverse of the forward map above (transpose of the rotation block).
        let cosR = cos(rotation)
        let sinR = sin(rotation)
        let localX = dx * cosR - dy * sinR
        let localY = dx * sinR + dy * cosR
        return abs(localX) <= size.width / 2 && abs(localY) <= size.height / 2
    }
}
