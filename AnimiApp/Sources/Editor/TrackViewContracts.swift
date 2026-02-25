import UIKit

// MARK: - Track View Contract (PR4)

/// Minimal contract for track views (Scene, Audio, Text, etc).
/// Separates data updates (applySnapshot) from layout (layoutItems).
protocol TrackViewContract: UIView {
    /// Associated snapshot type for this track
    associatedtype Snapshot

    /// Applies data snapshot (creates/removes clips, updates data properties).
    /// Called when scenes/clips change, NOT during scroll/zoom.
    func applySnapshot(_ snapshot: Snapshot)

    /// Performs layout-only update (frames, positions).
    /// Called during scroll/zoom, must NOT trigger data updates.
    func layoutItems(_ context: TimelineLayoutContext)
}

// MARK: - Clip View Contract (PR4)

/// Minimal contract for clip views (SceneClip, AudioClip, etc).
/// Separates data updates (applySnapshot) from layout (applyLayout).
protocol ClipViewContract: UIView {
    /// Associated snapshot type for this clip
    associatedtype Snapshot

    /// Applies data snapshot (duration, selection, constraints).
    /// Called when clip data changes, NOT during scroll/zoom.
    func applySnapshot(_ snapshot: Snapshot)

    /// Applies layout parameters (pxPerSecond for gesture calculations).
    /// Called during layout pass.
    func applyLayout(pxPerSecond: CGFloat)
}
