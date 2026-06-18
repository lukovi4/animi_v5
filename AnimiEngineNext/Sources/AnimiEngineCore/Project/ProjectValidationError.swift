/// Cross-object **semantic** validation errors (Task-002 plan, §15.3).
///
/// These are distinct from ``ProjectDecodingError`` (malformed JSON / shape errors) and from
/// ``TimeError`` (arithmetic). A document can be perfectly well-formed JSON and still be an invalid
/// project — that is what this enum captures.
public enum ProjectValidationError: Error, Equatable, Sendable {
    case emptyIdentifier
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case emptyProject
    case invalidSceneDuration(scene: String)
    case invalidPostRollCapability(scene: String)
    case transitionCountMismatch(expected: Int, actual: Int)
    case cutWithNonZeroDuration
    case animatedEffectWithZeroDuration
    case unsupportedEffect(effectID: String)
    case missingTransitionParameter(effectID: String, key: String)
    case extraTransitionParameter(effectID: String, key: String)
    case duplicateTransitionParameter(key: String)
    case wrongTypeTransitionParameter(effectID: String, key: String)
    case invalidEasing
    case duplicateStructuralID(scope: String, id: String)
    case duplicateStableOrdinal(scope: String, ordinal: Int)
    case invalidRange(field: String)
    case invalidAuthoredAnimationDuration
    case overlayOutsideProject(overlay: String)
    case missingPayload(kind: String, id: String)
    case inconsistentPayload(kind: String, id: String)
    case unexpectedPayload(kind: String, id: String)
    case duplicatePayload(kind: String, id: String)
    case insufficientVideoMaterial(role: String, layer: String)
    case unavailableAnimationContinuation(layer: String)
    case insufficientOutgoingPostRoll(boundaryIndex: Int)
    case insufficientIncomingDuration(boundaryIndex: Int)
    case insufficientOutgoingDuration(boundaryIndex: Int)
    case adjacentTransitionsRequireThreeScenes(middleSceneIndex: Int)
    case invalidEvaluationWindowCoverage
    case timeError(TimeError)
}

extension ProjectValidationError {
    /// Wraps a thrown ``TimeError`` as a validation error where appropriate.
    static func wrap(_ error: Error) -> ProjectValidationError {
        if let validation = error as? ProjectValidationError { return validation }
        if let time = error as? TimeError { return .timeError(time) }
        return .invalidRange(field: "unknown")
    }
}
