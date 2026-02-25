import CoreGraphics

// MARK: - Timeline Layout Context (PR4)

/// Layout-only parameters for timeline rendering.
/// Used by Track and Clip views during layout pass.
/// Does NOT contain data parameters (minDurationUs, selection, etc).
struct TimelineLayoutContext {
    /// Pixels per second (zoom-dependent)
    let pxPerSecond: CGFloat

    /// Left padding where time=0 starts
    let leftPadding: CGFloat
}
