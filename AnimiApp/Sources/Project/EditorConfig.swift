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
}
