import CoreGraphics

/// Per-frame presentation state for an overlay item.
/// Describes where and how the item appears on the canvas.
internal struct OverlayPresentationState: Sendable {
    /// Canvas-normalized center X (0..1).
    let centerX: CGFloat
    /// Canvas-normalized center Y (0..1).
    let centerY: CGFloat
    /// Scale relative to natural content size (1.0 = no scaling).
    let scale: CGFloat
    /// Rotation in radians (0 = no rotation).
    let rotation: CGFloat
    /// Opacity (0..1, 1.0 = fully opaque).
    let opacity: CGFloat

    static func `default`(centerX: CGFloat, centerY: CGFloat) -> Self {
        Self(centerX: centerX, centerY: centerY, scale: 1.0, rotation: 0, opacity: 1.0)
    }
}
