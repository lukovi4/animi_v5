import Foundation

// MARK: - Video Trim Session

/// Controller-local state for an active inline video trim operation.
/// No store dispatch happens during drag — only on Done.
/// mediaState in UserMediaService is NOT mutated with draft values during drag.
struct VideoTrimSession {

    /// Scene instance ID being edited.
    let instanceId: UUID

    /// Block ID of the video being trimmed.
    let blockId: String

    /// Actual video file duration in seconds.
    let actualDuration: Double

    /// Selection at the time trim mode was entered (for cancel-revert).
    let originalSelection: PersistedVideoSelection

    /// Current draft selection (modified by handle drags, NOT committed to store).
    var draftSelection: PersistedVideoSelection

    /// Current preview time within the draft range (for cursor scrub).
    /// Defaults to draftSelection.trimStart.
    var currentPreviewTime: Double

    // MARK: - Init

    /// Creates a trim session.
    /// - Parameters:
    ///   - instanceId: Scene instance ID
    ///   - blockId: Block ID being trimmed
    ///   - actualDuration: Full video duration
    ///   - selection: Current persisted selection
    ///   - currentVideoTime: Current playhead video time (if inside trim range, used as initial preview; otherwise falls back to trimStart)
    init(instanceId: UUID, blockId: String, actualDuration: Double, selection: PersistedVideoSelection, currentVideoTime: Double? = nil) {
        self.instanceId = instanceId
        self.blockId = blockId
        self.actualDuration = actualDuration
        self.originalSelection = selection
        self.draftSelection = selection

        // If the current playhead is inside the trim range, open on that frame
        if let t = currentVideoTime, t >= selection.trimStart, t <= selection.trimEnd {
            self.currentPreviewTime = t
        } else {
            self.currentPreviewTime = selection.trimStart
        }
    }

    // MARK: - Computed

    /// Whether the draft differs from the original.
    var hasChanges: Bool {
        draftSelection != originalSelection
    }

    /// Draft trim start as fraction of total duration [0..1].
    var trimStartFraction: Double {
        guard actualDuration > 0 else { return 0 }
        return draftSelection.trimStart / actualDuration
    }

    /// Draft trim end as fraction of total duration [0..1].
    var trimEndFraction: Double {
        guard actualDuration > 0 else { return 1 }
        return draftSelection.trimEnd / actualDuration
    }

    /// Current preview time as fraction of total duration [0..1].
    var cursorFraction: Double {
        guard actualDuration > 0 else { return 0 }
        return currentPreviewTime / actualDuration
    }
}
