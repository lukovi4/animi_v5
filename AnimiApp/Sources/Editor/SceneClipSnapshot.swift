import Foundation

// MARK: - Scene Clip Snapshot (PR4)

/// Data snapshot for SceneClipView.
/// Contains all data needed to configure a single clip.
/// Does NOT contain layout parameters (pxPerSecond).
struct SceneClipSnapshot {
    /// Duration of this scene in microseconds
    let durationUs: TimeUs

    /// Whether this clip is currently selected
    let isSelected: Bool

    /// Minimum duration for trim clamp (model constraint)
    let minDurationUs: TimeUs
}
