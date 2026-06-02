import CoreGraphics
import Foundation

/// Pure value type tracking a text-box transform gesture across simultaneous
/// pan/pinch/rotation recognizers. Mirrors `PlacementGestureSession`: created on
/// the first recognizer that begins, destroyed when the last one ends. All
/// deltas are cumulative from gesture start; `current()` applies them to the
/// baseline. No UIKit, so it is unit-testable in isolation.
struct TextOverlayTransformSession {

    /// Text item being transformed.
    let itemId: UUID

    // Baseline (captured at gesture start, normalized geometry + font size).
    let baselineCenterX: CGFloat
    let baselineCenterY: CGFloat
    let baselineBoxWidth: CGFloat
    let baselineFontSize: CGFloat
    let baselineRotation: CGFloat

    /// Cumulative normalized translation of the box center from gesture start.
    var translationDelta: (x: CGFloat, y: CGFloat) = (0, 0)

    /// Pinch scale multiplier (1.0 = no change). Applied to BOTH boxWidth and
    /// fontSize from a shared baseline so wrapping and glyph size scale together.
    var scaleDelta: CGFloat = 1.0

    /// Rotation delta in radians from gesture start.
    var rotationDelta: CGFloat = 0

    /// Minimum normalized box width (avoids zero-width boxes).
    static let minBoxWidth: CGFloat = 0.05
    /// Maximum normalized box width (full canvas).
    static let maxBoxWidth: CGFloat = 1.0
    /// Font size clamp (points), matching the editor slider range envelope.
    static let minFontSize: CGFloat = 8
    static let maxFontSize: CGFloat = 400

    struct Result {
        let centerX: CGFloat
        let centerY: CGFloat
        let boxWidth: CGFloat
        let fontSize: CGFloat
        let rotation: CGFloat
    }

    /// How far (normalized) a text-box center may travel beyond the canvas edge.
    /// Off-canvas placement is allowed (visual output is clipped to the canvas),
    /// but a generous bound keeps the box recoverable rather than lost at infinity.
    static let centerOffCanvasBound: CGFloat = 0.5

    /// Baseline + cumulative deltas, clamped.
    func current() -> Result {
        // Center is NOT clamped to 0...1: text boxes may sit partly/fully off the
        // canvas edge. Render and selection are clipped to the canvas separately.
        let lo = -Self.centerOffCanvasBound
        let hi = 1 + Self.centerOffCanvasBound
        let cx = min(hi, max(lo, baselineCenterX + translationDelta.x))
        let cy = min(hi, max(lo, baselineCenterY + translationDelta.y))
        let boxWidth = min(Self.maxBoxWidth, max(Self.minBoxWidth, baselineBoxWidth * scaleDelta))
        let fontSize = min(Self.maxFontSize, max(Self.minFontSize, baselineFontSize * scaleDelta))
        return Result(
            centerX: cx,
            centerY: cy,
            boxWidth: boxWidth,
            fontSize: fontSize,
            rotation: baselineRotation + rotationDelta
        )
    }

    /// The baseline as a `Result`, used to emit the `.began` snapshot and to
    /// restore on cancellation.
    func baseline() -> Result {
        Result(
            centerX: baselineCenterX,
            centerY: baselineCenterY,
            boxWidth: baselineBoxWidth,
            fontSize: baselineFontSize,
            rotation: baselineRotation
        )
    }
}
