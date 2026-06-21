/// Cross-object **semantic** validation of a canonical project document (Task-002 plan, §11.2 step 5,
/// §15.3).
///
/// Structural well-formedness (JSON shape, unknown fields, enum tags) is the codec's job; this
/// validator runs only after a document has decoded into typed values. It checks invariants that
/// span multiple objects: project non-emptiness, scene timing, transition count and validity,
/// duplicate identifiers and ordinals, overlay containment, transition adjacency, and the
/// manifest↔payload correspondence.
///
/// Material/animation availability (video trim coverage, scene-layer and global-overlay animation
/// continuation — Task-002 plan §8) is validated up front by **`ProjectValidator`** (full-document
/// path, via ``MaterialAvailabilityValidator/validateDocument(_:sceneSpanIndex:)``) and by
/// **`EvaluationWindowBuilder`** (lazy-payload path, on the loaded payloads). It is **never** checked
/// by `TimelineEvaluator` — playback never discovers a material error (corrective plan C-1).
/// Static project-level transition availability (post-roll/duration/adjacency) is checked here too.
public enum ProjectValidator {
    /// Validates **manifest-only** invariants — everything derivable without payloads
    /// (corrective plan C-5). `TimelineIndex.init` calls this so an index can never be built from an
    /// invalid manifest, while still not requiring payloads.
    public static func validateManifest(_ manifest: CanonicalProjectManifest) throws {
        // 0. Supported schema version. CP7.5: accept v1 (uplifted on decode) and v2.
        guard CanonicalProjectManifest.acceptedSchemaVersions.contains(manifest.schemaVersion) else {
            throw ProjectValidationError.unsupportedSchemaVersion(
                found: manifest.schemaVersion,
                supported: CanonicalProjectManifest.supportedSchemaVersion
            )
        }

        // 1. Empty project.
        guard !manifest.scenes.isEmpty else { throw ProjectValidationError.emptyProject }

        // 2. Scene durations, post-roll capability, and timeline span.
        for scene in manifest.scenes {
            guard scene.nominalDuration.ticks > 0 else {
                throw ProjectValidationError.invalidSceneDuration(scene: scene.id.raw)
            }
            // CP7.5: timelineSpan must be >= nominalDuration (a scene can be stretched, never shrunk).
            guard scene.timelineSpan.ticks >= scene.nominalDuration.ticks else {
                throw ProjectValidationError.invalidTimelineSpan(scene: scene.id.raw)
            }
            // postRollCapability is a TickDuration (>= 0 by construction); nothing further required.
        }

        // 3. Transition count: exactly scenes.count - 1 boundaries.
        let expectedBoundaries = manifest.scenes.count - 1
        guard manifest.boundaryTransitions.count == expectedBoundaries else {
            throw ProjectValidationError.transitionCountMismatch(
                expected: expectedBoundaries,
                actual: manifest.boundaryTransitions.count
            )
        }

        // 4. Per-transition kind/duration/parameter validity.
        for transition in manifest.boundaryTransitions {
            try SupportedTransitionEffect.validate(transition)
        }

        // 5. Duplicate scene ids / payload ids across scenes.
        try requireUnique(manifest.scenes.map(\.id.raw), scope: "scene.id")
        try requireUnique(manifest.scenes.map(\.payloadID.raw), scope: "scene.payloadID")

        // 7. Overlay duplicate ids / ordinals and containment within the project.
        try requireUnique(manifest.overlays.map(\.id.raw), scope: "overlay.id")
        try requireUnique(manifest.overlays.map(\.payloadID.raw), scope: "overlay.payloadID")
        try requireUniqueOrdinals(manifest.overlays.map(\.stableOrdinal), scope: "overlay")
        let projectDuration = try manifest.projectDuration()
        let projectEnd = try ProjectTime.zero.adding(projectDuration)
        for overlay in manifest.overlays {
            guard overlay.timeRange.start >= ProjectTime.zero,
                  overlay.timeRange.end <= projectEnd else {
                throw ProjectValidationError.overlayOutsideProject(overlay: overlay.id.raw)
            }
        }

        // 8. Static transition availability: post-roll, incoming/outgoing duration, adjacency.
        try validateTransitionAvailability(manifest)
    }

    /// Full-document validation: manifest invariants, per-payload structure, manifest↔payload
    /// correspondence, and **complete scene + overlay material availability** (corrective plan C-1).
    public static func validate(_ document: CanonicalProjectDocument) throws {
        let manifest = document.manifest

        // Manifest-only invariants (schema, durations, transitions, ids, overlays, adjacency).
        try validateManifest(manifest)

        // 6. Per-scene layer uniqueness (ids and stable ordinals within the scene scope).
        try validateScenePayloads(document)

        // 9. Manifest ↔ payload correspondence.
        try validatePayloadCorrespondence(document)

        // 10. Complete scene + overlay material availability (corrective plan C-1, full-document site).
        let sceneSpanIndex = try SceneSpanIndex(scenes: manifest.scenes)
        try MaterialAvailabilityValidator.validateDocument(document, sceneSpanIndex: sceneSpanIndex)
    }

    // MARK: - Scene payloads

    private static func validateScenePayloads(_ document: CanonicalProjectDocument) throws {
        for payload in document.scenePayloads {
            try requireUnique(payload.layers.map(\.id.raw), scope: "layer.id[\(payload.payloadID.raw)]")
            try requireUniqueOrdinals(
                payload.layers.map(\.stableOrdinal),
                scope: "layer[\(payload.payloadID.raw)]"
            )
        }
    }

    // MARK: - Transition availability (static; window-independent)

    private static func validateTransitionAvailability(_ manifest: CanonicalProjectManifest) throws {
        let scenes = manifest.scenes
        // preHalf/postHalf per boundary for adjacency checks.
        var preHalves: [Int64] = []
        var postHalves: [Int64] = []

        for (index, transition) in manifest.boundaryTransitions.enumerated() {
            let outgoing = scenes[index]
            let incoming = scenes[index + 1]
            switch transition.kind {
            case .cut:
                preHalves.append(0)
                postHalves.append(0)
            case .animated:
                let halves = TransitionHalves(duration: transition.duration)
                let preHalf = halves.preHalf
                let postHalf = halves.postHalf
                preHalves.append(preHalf)
                postHalves.append(postHalf)
                // outgoing nominal duration >= preHalf
                guard outgoing.nominalDuration.ticks >= preHalf else {
                    throw ProjectValidationError.insufficientOutgoingDuration(boundaryIndex: index)
                }
                // outgoing post-roll capability >= postHalf
                guard outgoing.postRollCapability.ticks >= postHalf else {
                    throw ProjectValidationError.insufficientOutgoingPostRoll(boundaryIndex: index)
                }
                // incoming nominal duration >= postHalf
                guard incoming.nominalDuration.ticks >= postHalf else {
                    throw ProjectValidationError.insufficientIncomingDuration(boundaryIndex: index)
                }
            }
        }

        // Adjacency: for a middle scene m (1 <= m <= n-2), it sits between boundary m-1 and m.
        // Require postHalf(prevBoundary) + preHalf(nextBoundary) <= scene m nominal duration.
        guard scenes.count >= 3 else { return }
        for middle in 1...(scenes.count - 2) {
            let prevBoundary = middle - 1
            let nextBoundary = middle
            let post = postHalves[prevBoundary]
            let pre = preHalves[nextBoundary]
            let sum = try CheckedInt64.add(post, pre, "adjacency")
            guard sum <= scenes[middle].nominalDuration.ticks else {
                throw ProjectValidationError.adjacentTransitionsRequireThreeScenes(middleSceneIndex: middle)
            }
        }
    }

    // MARK: - Payload correspondence

    private static func validatePayloadCorrespondence(_ document: CanonicalProjectDocument) throws {
        let manifest = document.manifest

        // Scenes: every manifest scene payloadID present exactly once; no extra payloads.
        var scenePayloadByID: [String: ResolvedScenePayload] = [:]
        for payload in document.scenePayloads {
            guard scenePayloadByID[payload.payloadID.raw] == nil else {
                throw ProjectValidationError.duplicatePayload(kind: "scene", id: payload.payloadID.raw)
            }
            scenePayloadByID[payload.payloadID.raw] = payload
        }
        var expectedScenePayloadIDs = Set<String>()
        for scene in manifest.scenes {
            guard let payload = scenePayloadByID[scene.payloadID.raw] else {
                throw ProjectValidationError.missingPayload(kind: "scene", id: scene.payloadID.raw)
            }
            // The payload's declared sceneID must match the manifest entry.
            guard payload.sceneID == scene.id else {
                throw ProjectValidationError.inconsistentPayload(kind: "scene", id: scene.payloadID.raw)
            }
            expectedScenePayloadIDs.insert(scene.payloadID.raw)
        }
        for payload in document.scenePayloads where !expectedScenePayloadIDs.contains(payload.payloadID.raw) {
            throw ProjectValidationError.unexpectedPayload(kind: "scene", id: payload.payloadID.raw)
        }

        // Overlays: same correspondence.
        var overlayPayloadByID: [String: ResolvedOverlayPayload] = [:]
        for payload in document.overlayPayloads {
            guard overlayPayloadByID[payload.payloadID.raw] == nil else {
                throw ProjectValidationError.duplicatePayload(kind: "overlay", id: payload.payloadID.raw)
            }
            overlayPayloadByID[payload.payloadID.raw] = payload
        }
        var expectedOverlayPayloadIDs = Set<String>()
        for overlay in manifest.overlays {
            guard let payload = overlayPayloadByID[overlay.payloadID.raw] else {
                throw ProjectValidationError.missingPayload(kind: "overlay", id: overlay.payloadID.raw)
            }
            guard payload.overlayID == overlay.id else {
                throw ProjectValidationError.inconsistentPayload(kind: "overlay", id: overlay.payloadID.raw)
            }
            expectedOverlayPayloadIDs.insert(overlay.payloadID.raw)
        }
        for payload in document.overlayPayloads where !expectedOverlayPayloadIDs.contains(payload.payloadID.raw) {
            throw ProjectValidationError.unexpectedPayload(kind: "overlay", id: payload.payloadID.raw)
        }
    }

    // MARK: - Helpers

    private static func requireUnique(_ values: [String], scope: String) throws {
        var seen = Set<String>()
        for value in values where !seen.insert(value).inserted {
            throw ProjectValidationError.duplicateStructuralID(scope: scope, id: value)
        }
    }

    private static func requireUniqueOrdinals(_ values: [Int], scope: String) throws {
        var seen = Set<Int>()
        for value in values where !seen.insert(value).inserted {
            throw ProjectValidationError.duplicateStableOrdinal(scope: scope, ordinal: value)
        }
    }
}

/// The centered-window split of an animated transition duration (Task-002 plan, §7.2).
///
///     preHalf  = floor(D / 2)
///     postHalf = D - preHalf   // the extra odd tick belongs after B
public struct TransitionHalves: Equatable, Sendable {
    public let duration: TickDuration
    public let preHalf: Int64
    public let postHalf: Int64

    public init(duration: TickDuration) {
        self.duration = duration
        let d = duration.ticks
        self.preHalf = d / 2
        self.postHalf = d - (d / 2)
    }
}
