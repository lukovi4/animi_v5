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
    /// CP7.5: a scene's `timelineSpan` is smaller than its `nominalDuration` (a scene may be
    /// stretched, never shrunk below its native duration).
    case invalidTimelineSpan(scene: String)
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
    /// Slice 001 Stage B value-model: ``AudioGain`` raw value is outside the integer linear scale
    /// `0 ... 1_000_000`. Never clamped — out of range is a typed failure.
    case invalidAudioGain(value: Int64)

    // MARK: - Slice 001 Stage D: semantic audio validation (plan §7)

    /// Two audio source/track/clip entries share an id (`scope` names the table).
    case duplicateAudioID(scope: String, id: String)
    /// A clip references a `sourceID`/`trackID` that no entry defines (`kind` names which).
    case danglingAudioReference(kind: String, id: String)
    /// An audio source is defined but referenced by no clip.
    case orphanAudioSource(id: String)
    /// An audio track is defined but referenced by no clip.
    case orphanAudioTrack(id: String)
    /// A clip's role and `videoLayer` presence disagree (`.videoLayer`⇒present; global⇒absent).
    case audioRoleLayerMismatch(clip: String)
    /// A clip's role and asset kind disagree (`.videoLayer`⇒`.videoLayerMedia`; global⇒`.globalAudio`).
    case audioRoleAssetMismatch(clip: String)
    /// A video-layer clip's `videoLayer.sceneID` is not a scene in the manifest.
    case unknownAudioScene(clip: String)
    /// A clip's `destination` is not fully inside the project duration.
    case audioDestinationOutsideProject(clip: String)
    /// A video-layer clip's referenced `layerID` does not exist in the resolved scene payload.
    case audioLayerNotFound(clip: String)
    /// A video-layer clip references a layer whose content is not `.video` (e.g. an image).
    case audioLayerNotVideo(clip: String)
    /// A video-layer clip's `.videoLayerMedia` differs from the layer's `VideoBinding.media`.
    case audioMediaMismatch(clip: String)
    /// A video-layer clip's `sourceTrim` is not contained in the video's `sourceMapping.trimRange`.
    case audioTrimNotContained(clip: String)
    /// Two video-layer clips reference the same `SceneLayerReference`.
    case duplicateVideoAudioClip(layer: String)
    /// An incoming-side video clip's `destination.start` precedes its scene start (pre-boundary audio
    /// is forbidden — the incoming media clock is held at 0 while `T < B`).
    case incomingAudioBeforeBoundary(clip: String)
    /// A video-layer clip's `destination` extends outside the scene's media-active domain.
    case audioDestinationOutsideMediaActiveDomain(clip: String)

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
