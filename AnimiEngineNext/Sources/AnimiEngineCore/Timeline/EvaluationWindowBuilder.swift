/// Builds a validated ``EvaluationWindow`` from a requirement plus exactly the loaded payloads
/// (Task-002 plan, §10.3).
///
/// Validation (all typed errors):
/// - supplied payload ids exactly match the requirement (no missing, no unexpected, no duplicate);
/// - referenced structural ids match;
/// - scene spans and transitions match the index metadata carried by the requirement;
/// - coverage is non-empty and inside project duration.
public enum EvaluationWindowBuilder {
    /// Builds a validated window from the authoritative requirement plus the loaded payloads
    /// (corrective plan C-4). `output` and `projectDuration` are **derived from the requirement**, not
    /// accepted as independent parameters, so they can never disagree with the minting index.
    public static func build(
        requirement: EvaluationWindowRequirement,
        scenes: [ResolvedScenePayload],
        overlays: [ResolvedOverlayPayload]
    ) throws -> EvaluationWindow {
        let output = requirement.output
        let projectDuration = requirement.projectDuration

        // Coverage inside project duration.
        let projectEnd = try ProjectTime.zero.adding(projectDuration)
        guard requirement.coverage.start >= ProjectTime.zero,
              requirement.coverage.end <= projectEnd,
              requirement.coverage.end > requirement.coverage.start else {
            throw ProjectValidationError.invalidEvaluationWindowCoverage
        }

        // Scenes: exact payload-id correspondence with the requirement.
        var scenePayloadByID: [String: ResolvedScenePayload] = [:]
        for payload in scenes {
            guard scenePayloadByID[payload.payloadID.raw] == nil else {
                throw ProjectValidationError.duplicatePayload(kind: "scene", id: payload.payloadID.raw)
            }
            scenePayloadByID[payload.payloadID.raw] = payload
        }
        let requiredScenePayloadIDs = Set(requirement.sceneSpans.map(\.payloadID.raw))
        for id in scenePayloadByID.keys where !requiredScenePayloadIDs.contains(id) {
            throw ProjectValidationError.unexpectedPayload(kind: "scene", id: id)
        }

        var windowScenes: [WindowScene] = []
        for span in requirement.sceneSpans {
            guard let payload = scenePayloadByID[span.payloadID.raw] else {
                throw ProjectValidationError.missingPayload(kind: "scene", id: span.payloadID.raw)
            }
            guard payload.sceneID == span.sceneID else {
                throw ProjectValidationError.inconsistentPayload(kind: "scene", id: span.payloadID.raw)
            }
            windowScenes.append(WindowScene(span: span, payload: payload))
        }

        // Overlays: exact payload-id correspondence with the requirement.
        var overlayPayloadByID: [String: ResolvedOverlayPayload] = [:]
        for payload in overlays {
            guard overlayPayloadByID[payload.payloadID.raw] == nil else {
                throw ProjectValidationError.duplicatePayload(kind: "overlay", id: payload.payloadID.raw)
            }
            overlayPayloadByID[payload.payloadID.raw] = payload
        }
        let requiredOverlayPayloadIDs = Set(requirement.overlayEntries.map(\.payloadID.raw))
        for id in overlayPayloadByID.keys where !requiredOverlayPayloadIDs.contains(id) {
            throw ProjectValidationError.unexpectedPayload(kind: "overlay", id: id)
        }

        var windowOverlays: [WindowOverlay] = []
        for entry in requirement.overlayEntries {
            guard let payload = overlayPayloadByID[entry.payloadID.raw] else {
                throw ProjectValidationError.missingPayload(kind: "overlay", id: entry.payloadID.raw)
            }
            guard payload.overlayID == entry.overlayID else {
                throw ProjectValidationError.inconsistentPayload(kind: "overlay", id: entry.payloadID.raw)
            }
            windowOverlays.append(WindowOverlay(entry: entry, payload: payload))
        }

        let windowTransitions = requirement.transitions.map { WindowTransition(boundary: $0) }

        // Lazy-payload material validation (corrective plan C-1, Revision 3): validate the **loaded**
        // scene and overlay payloads against the authoritative requirement before publishing the
        // window. This defeats matching-ID/different-content payloads (a payload with the right id but a
        // shorter trim or an overlay animation that no longer covers its active interval).
        try MaterialAvailabilityValidator.validateWindowPayloads(
            requirement: requirement,
            scenes: windowScenes,
            transitions: windowTransitions,
            overlays: windowOverlays
        )

        return EvaluationWindow(
            coverage: requirement.coverage,
            output: output,
            projectDuration: projectDuration,
            scenes: windowScenes,
            transitions: windowTransitions,
            overlays: windowOverlays
        )
    }
}
