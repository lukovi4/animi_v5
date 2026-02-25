import Foundation

// MARK: - Scene Track Snapshot (PR4)

/// Data snapshot for SceneTrackView.
/// Contains all data needed to configure track clips.
/// Does NOT contain layout parameters (pxPerSecond, leftPadding).
struct SceneTrackSnapshot {
    /// Array of scenes to display
    let scenes: [SceneDraft]

    /// Currently selected scene ID (nil if no selection)
    let selectedSceneId: UUID?

    /// Minimum scene duration for trim clamp (model constraint)
    let minDurationUs: TimeUs
}
