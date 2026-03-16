import Foundation

// MARK: - Timeline Transition Validator

/// Pure helper for validating and normalizing boundary transitions.
/// Called by EditorReducer after timeline mutations.
public enum TimelineTransitionValidator {

    // MARK: - Validation

    /// Validation issue types.
    public enum ValidationIssue: Equatable, Sendable {
        /// Scene is too short for its adjacent transitions.
        case sceneTooShort(sceneId: UUID, requiredFrames: Int, actualFrames: Int)
        /// Boundary references non-existent or non-adjacent scenes.
        case invalidBoundary(key: SceneBoundaryKey)
        /// Transition window would overlap with another transition.
        case overlappingTransitions(boundary1: SceneBoundaryKey, boundary2: SceneBoundaryKey)
    }

    /// Validates transitions in timeline.
    /// - Parameters:
    ///   - timeline: The canonical timeline to validate.
    ///   - fps: Frames per second for duration conversion.
    /// - Returns: Array of validation issues (empty if valid).
    public static func validate(
        timeline: CanonicalTimeline,
        fps: Int
    ) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let sceneItems = timeline.sceneItems

        // Build set of valid adjacent boundaries
        var validBoundaries: Set<SceneBoundaryKey> = []
        // Guard: need at least 2 scenes for boundaries
        if sceneItems.count > 1 {
            for i in 0..<(sceneItems.count - 1) {
                validBoundaries.insert(SceneBoundaryKey(sceneItems[i].id, sceneItems[i + 1].id))
            }
        }

        // Check each boundary transition
        for (key, _) in timeline.boundaryTransitions {
            if !validBoundaries.contains(key) {
                issues.append(.invalidBoundary(key: key))
            }
        }

        // Check scene durations vs adjacent transitions
        for i in 0..<sceneItems.count {
            let scene = sceneItems[i]
            let sceneDurationFrames = Int((scene.durationUs * Int64(fps)) / 1_000_000)

            var requiredFrames = 0

            // Check transition from previous scene
            if i > 0 {
                let prevKey = SceneBoundaryKey(sceneItems[i - 1].id, scene.id)
                if let transition = timeline.boundaryTransitions[prevKey], transition.type != .none {
                    requiredFrames += transition.durationFrames
                }
            }

            // Check transition to next scene
            if i < sceneItems.count - 1 {
                let nextKey = SceneBoundaryKey(scene.id, sceneItems[i + 1].id)
                if let transition = timeline.boundaryTransitions[nextKey], transition.type != .none {
                    requiredFrames += transition.durationFrames
                }
            }

            if sceneDurationFrames < requiredFrames {
                issues.append(.sceneTooShort(
                    sceneId: scene.id,
                    requiredFrames: requiredFrames,
                    actualFrames: sceneDurationFrames
                ))
            }
        }

        return issues
    }

    // MARK: - Normalization

    /// Result of normalization.
    public struct NormalizationResult: Sendable {
        /// Normalized boundary transitions.
        public let boundaryTransitions: [SceneBoundaryKey: SceneTransition]
        /// Boundaries that were reset to none.
        public let resetBoundaries: [SceneBoundaryKey]
    }

    /// Normalizes boundary transitions by removing invalid ones.
    /// - Parameters:
    ///   - timeline: The canonical timeline to normalize.
    ///   - fps: Frames per second for duration conversion.
    /// - Returns: Normalized transitions and list of reset boundaries.
    public static func normalize(
        timeline: CanonicalTimeline,
        fps: Int
    ) -> NormalizationResult {
        let sceneItems = timeline.sceneItems
        var normalized = timeline.boundaryTransitions
        var resetBoundaries: [SceneBoundaryKey] = []

        // Build set of valid adjacent boundaries
        var validBoundaries: Set<SceneBoundaryKey> = []
        // Guard: need at least 2 scenes for boundaries
        if sceneItems.count > 1 {
            for i in 0..<(sceneItems.count - 1) {
                validBoundaries.insert(SceneBoundaryKey(sceneItems[i].id, sceneItems[i + 1].id))
            }
        }

        // Remove boundaries that are no longer valid (non-adjacent or missing scenes)
        for key in normalized.keys {
            if !validBoundaries.contains(key) {
                normalized.removeValue(forKey: key)
                resetBoundaries.append(key)
            }
        }

        // Check each scene's duration vs its adjacent transitions
        // Process from end to start so we can reset incrementally
        for i in (0..<sceneItems.count).reversed() {
            let scene = sceneItems[i]
            let sceneDurationFrames = Int((scene.durationUs * Int64(fps)) / 1_000_000)

            // Calculate required frames from adjacent transitions
            var requiredFromPrev = 0
            var requiredToNext = 0
            var prevKey: SceneBoundaryKey?
            var nextKey: SceneBoundaryKey?

            if i > 0 {
                prevKey = SceneBoundaryKey(sceneItems[i - 1].id, scene.id)
                if let transition = normalized[prevKey!], transition.type != .none {
                    requiredFromPrev = transition.durationFrames
                }
            }

            if i < sceneItems.count - 1 {
                nextKey = SceneBoundaryKey(scene.id, sceneItems[i + 1].id)
                if let transition = normalized[nextKey!], transition.type != .none {
                    requiredToNext = transition.durationFrames
                }
            }

            let totalRequired = requiredFromPrev + requiredToNext

            // If scene is too short, reset transitions (prefer keeping earlier transitions)
            if sceneDurationFrames < totalRequired {
                // Reset the transition to next scene first (keep prev)
                if let key = nextKey, normalized[key]?.type != .none {
                    normalized.removeValue(forKey: key)
                    resetBoundaries.append(key)
                }

                // If still too short, reset prev transition too
                if sceneDurationFrames < requiredFromPrev {
                    if let key = prevKey, normalized[key]?.type != .none {
                        normalized.removeValue(forKey: key)
                        resetBoundaries.append(key)
                    }
                }
            }
        }

        return NormalizationResult(
            boundaryTransitions: normalized,
            resetBoundaries: resetBoundaries
        )
    }

    // MARK: - Minimum Scene Duration

    /// Calculates minimum allowed duration for a scene given its adjacent transitions.
    /// - Parameters:
    ///   - sceneId: ID of the scene.
    ///   - timeline: The canonical timeline.
    /// - Returns: Minimum duration in microseconds.
    public static func minimumDurationUs(
        forSceneId sceneId: UUID,
        in timeline: CanonicalTimeline,
        fps: Int
    ) -> TimeUs {
        let sceneItems = timeline.sceneItems
        guard let index = sceneItems.firstIndex(where: { $0.id == sceneId }) else {
            return ProjectDraft.minSceneDurationUs
        }

        var requiredFrames = 0

        // Check transition from previous scene
        if index > 0 {
            let prevKey = SceneBoundaryKey(sceneItems[index - 1].id, sceneId)
            if let transition = timeline.boundaryTransitions[prevKey], transition.type != .none {
                requiredFrames += transition.durationFrames
            }
        }

        // Check transition to next scene
        if index < sceneItems.count - 1 {
            let nextKey = SceneBoundaryKey(sceneId, sceneItems[index + 1].id)
            if let transition = timeline.boundaryTransitions[nextKey], transition.type != .none {
                requiredFrames += transition.durationFrames
            }
        }

        // Convert frames to microseconds
        let minFromTransitions = TimeUs(requiredFrames) * 1_000_000 / TimeUs(fps)

        return max(minFromTransitions, ProjectDraft.minSceneDurationUs)
    }
}

// MARK: - SceneBoundaryKey Equatable

extension SceneBoundaryKey: Equatable {
    public static func == (lhs: SceneBoundaryKey, rhs: SceneBoundaryKey) -> Bool {
        lhs.fromSceneInstanceId == rhs.fromSceneInstanceId &&
        lhs.toSceneInstanceId == rhs.toSceneInstanceId
    }
}
