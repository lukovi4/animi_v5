import Foundation

// MARK: - Editor Configuration

/// Compile-time configuration constants for the visual editor.
/// Values can be changed here in one place for easy tuning.
public enum EditorConfig {

    // MARK: - Timeline Zoom

    /// Base pixels per second at 100% zoom (default: 20 px/s)
    public static let basePxPerSecond: Double = 20

    /// Maximum zoom multiplier (4.0 = 400% = 80 px/s at fps=30)
    public static let zoomMax: Double = 4.0

    // MARK: - Duration Limits

    /// Minimum project duration in seconds
    public static let minDurationSeconds: Int = 4

    /// Maximum project duration in seconds
    public static let maxDurationSeconds: Int = 60

    // MARK: - Snap

    /// Snap step in seconds for duration drag (0.5 = snap to half-seconds)
    public static let snapStepSeconds: Double = 0.5

    // MARK: - Undo/Redo

    /// Maximum number of operations in undo stack
    public static let undoStackLimit: Int = 50

    // MARK: - Editor Layout (PR2)

    /// Navigation bar height in points
    public static let navBarHeight: CGFloat = 60

    /// Preview menu strip height in points (overlay at bottom of preview)
    public static let previewMenuHeight: CGFloat = 48

    /// Time ruler height in points
    public static let rulerHeight: CGFloat = 32

    /// Timeline canvas height in points (fixed, internal vertical scroll for tracks)
    public static let timelineHeight: CGFloat = 260

    /// Bottom bar height in points (excludes safe area inset)
    public static let bottomBarHeight: CGFloat = 72

    // MARK: - Debug (PR2.1)

    #if DEBUG
    /// Number of extra stub tracks to add for testing vertical scroll (0 = no stubs)
    public static let debugExtraTracksCount: Int = 0
    #endif
}
