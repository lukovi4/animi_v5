import Foundation

// MARK: - Video Window Validation Error

/// Errors from video window validation.
/// Module-neutral — usable by both UserMediaService (runtime) and ExportMediaSnapshot (export).
enum VideoWindowValidationError: Error, LocalizedError {
    case durationTooShort(blockId: String, duration: Double)
    case negativeWindowStart(blockId: String, winStart: Double)
    case windowExceedsDuration(blockId: String, winEnd: Double, duration: Double)
    case emptyWindow(blockId: String, winStart: Double, winEnd: Double)

    var errorDescription: String? {
        switch self {
        case .durationTooShort(let blockId, let duration):
            return "Video duration too short (\(duration)s) for block '\(blockId)'"
        case .negativeWindowStart(let blockId, let winStart):
            return "Effective winStart (\(winStart)) is negative for block '\(blockId)'"
        case .windowExceedsDuration(let blockId, let winEnd, let duration):
            return "Effective winEnd (\(winEnd)) exceeds duration (\(duration)) for block '\(blockId)'"
        case .emptyWindow(let blockId, let winStart, let winEnd):
            return "Invalid selection (winEnd \(winEnd) <= winStart \(winStart)) for block '\(blockId)'"
        }
    }
}

// MARK: - Video Window Validator

/// Shared strict validator for video window parameters.
/// Canonical owner of the validation epsilon constant (1 tick in timescale 600).
enum VideoWindowValidator {

    /// Validation epsilon: 1 tick in timescale 600.
    static let epsilon: Double = 1.0 / 600.0

    /// Validates a persisted video selection against actual file duration.
    ///
    /// Rules (verbatim from Phase 3 runtime contract):
    /// 1. `actualDuration > epsilon`
    /// 2. Build `VideoSelection` via `selection.toVideoSelection(url:)`
    /// 3. `winStart >= 0`
    /// 4. `winEnd <= actualDuration + epsilon`
    /// 5. `winEnd > winStart`
    ///
    /// - Parameters:
    ///   - selection: Persisted video selection (URL-less trim/audio params)
    ///   - url: Resolved video file URL
    ///   - actualDuration: Probed video file duration in seconds
    ///   - blockId: Block ID for error context
    /// - Returns: Validated `VideoSelection`
    /// - Throws: `VideoWindowValidationError` on any validation failure
    static func validate(
        selection: PersistedVideoSelection,
        url: URL,
        actualDuration: Double,
        blockId: String
    ) throws -> VideoSelection {
        guard actualDuration > epsilon else {
            throw VideoWindowValidationError.durationTooShort(blockId: blockId, duration: actualDuration)
        }

        let videoSelection = selection.toVideoSelection(url: url)

        guard videoSelection.winStart >= 0 else {
            throw VideoWindowValidationError.negativeWindowStart(blockId: blockId, winStart: videoSelection.winStart)
        }

        guard videoSelection.winEnd <= actualDuration + epsilon else {
            throw VideoWindowValidationError.windowExceedsDuration(blockId: blockId, winEnd: videoSelection.winEnd, duration: actualDuration)
        }

        guard videoSelection.winEnd > videoSelection.winStart else {
            throw VideoWindowValidationError.emptyWindow(blockId: blockId, winStart: videoSelection.winStart, winEnd: videoSelection.winEnd)
        }

        return videoSelection
    }
}
