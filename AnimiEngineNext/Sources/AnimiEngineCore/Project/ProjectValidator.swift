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

        // 9. Slice 001 Stage D: manifest-level audio semantics (no payloads required).
        try validateAudioManifest(manifest)
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

        // 11. Slice 001 Stage D: payload-dependent audio semantics (scene-layer resolution).
        try validateAudioDocument(document)
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

    // MARK: - Slice 001 Stage D: audio validation (manifest-level)

    /// Manifest-only audio invariants (plan §7). No payloads required; the `.empty` manifest passes
    /// every check vacuously. Table order is non-semantic — every check iterates sets/maps, never
    /// positions.
    private static func validateAudioManifest(_ manifest: CanonicalProjectManifest) throws {
        let audio = manifest.audio
        if audio.isEmpty { return }   // empty manifest is consistent by construction

        // Unique ids per table.
        try requireUniqueAudio(audio.sources.map(\.id.raw), scope: "audio.source")
        try requireUniqueAudio(audio.tracks.map(\.id.raw), scope: "audio.track")
        try requireUniqueAudio(audio.clips.map(\.id.raw), scope: "audio.clip")

        // Lookup maps for dangling/role/asset resolution.
        let sourceByID = Dictionary(uniqueKeysWithValues: audio.sources.map { ($0.id, $0) })
        let trackByID = Dictionary(uniqueKeysWithValues: audio.tracks.map { ($0.id, $0) })
        let sceneIDs = Set(manifest.scenes.map(\.id))
        let projectDuration = try manifest.projectDuration()
        let projectEnd = try ProjectTime.zero.adding(projectDuration)

        // Referenced source/track ids (for orphan detection); built while resolving clips.
        var referencedSources = Set<AudioSourceID>()
        var referencedTracks = Set<AudioTrackID>()

        for clip in audio.clips {
            // Dangling references.
            guard let source = sourceByID[clip.sourceID] else {
                throw ProjectValidationError.danglingAudioReference(kind: "source", id: clip.sourceID.raw)
            }
            guard let track = trackByID[clip.trackID] else {
                throw ProjectValidationError.danglingAudioReference(kind: "track", id: clip.trackID.raw)
            }
            referencedSources.insert(clip.sourceID)
            referencedTracks.insert(clip.trackID)

            // Role drives both `videoLayer` presence and asset kind.
            let role = track.role
            let isVideoLayerRole = (role == .videoLayer)

            // role ↔ videoLayer presence.
            if isVideoLayerRole {
                guard clip.videoLayer != nil else {
                    throw ProjectValidationError.audioRoleLayerMismatch(clip: clip.id.raw)
                }
            } else {
                guard clip.videoLayer == nil else {
                    throw ProjectValidationError.audioRoleLayerMismatch(clip: clip.id.raw)
                }
            }

            // role ↔ asset kind.
            switch (isVideoLayerRole, source.asset) {
            case (true, .videoLayerMedia), (false, .globalAudio):
                break
            default:
                throw ProjectValidationError.audioRoleAssetMismatch(clip: clip.id.raw)
            }

            // destination ⊆ project duration.
            guard clip.destination.start >= ProjectTime.zero,
                  clip.destination.end <= projectEnd else {
                throw ProjectValidationError.audioDestinationOutsideProject(clip: clip.id.raw)
            }

            // Video-layer clips: scene exists + destination inside the scene media-active domain.
            if let ref = clip.videoLayer {
                guard sceneIDs.contains(ref.sceneID) else {
                    throw ProjectValidationError.unknownAudioScene(clip: clip.id.raw)
                }
                let domain = try mediaActiveDomain(forScene: ref.sceneID, manifest: manifest)
                // Pre-boundary audio forbidden: destination begins before the scene start.
                guard clip.destination.start >= domain.start else {
                    throw ProjectValidationError.incomingAudioBeforeBoundary(clip: clip.id.raw)
                }
                // Entire destination must lie inside the media-active domain (outgoing post-roll
                // allowed; visual activeRange/opacity never gate audio).
                guard clip.destination.end <= domain.end else {
                    throw ProjectValidationError.audioDestinationOutsideMediaActiveDomain(clip: clip.id.raw)
                }
            }

            // Defense-in-depth re-asserts (value invariants already hold by construction).
            guard clip.gain.raw >= 0, clip.gain.raw <= AudioGain.unityRaw else {
                throw ProjectValidationError.invalidAudioGain(value: clip.gain.raw)
            }
        }

        // Orphan sources/tracks: every defined entry must be referenced by >= 1 clip.
        for source in audio.sources where !referencedSources.contains(source.id) {
            throw ProjectValidationError.orphanAudioSource(id: source.id.raw)
        }
        for track in audio.tracks where !referencedTracks.contains(track.id) {
            throw ProjectValidationError.orphanAudioTrack(id: track.id.raw)
        }
    }

    /// The half-open media-active domain `[start, end)` of a scene on the project timeline (plan §7,
    /// ADR-012 §1.0b). Resolves the scene index, then delegates the derivation to the single shared
    /// `SceneMediaClock.mediaActiveDomain` (Slice-002 Stage A) so validation and the evaluator share
    /// one definition and cannot drift.
    private static func mediaActiveDomain(
        forScene sceneID: SceneInstanceID, manifest: CanonicalProjectManifest
    ) throws -> (start: ProjectTime, end: ProjectTime) {
        guard let index = manifest.scenes.firstIndex(where: { $0.id == sceneID }) else {
            // Caller already verified existence; treat as unknown defensively.
            throw ProjectValidationError.unknownAudioScene(clip: sceneID.raw)
        }
        return try SceneMediaClock.mediaActiveDomain(
            sceneIndex: index,
            scenes: manifest.scenes,
            boundaryTransitions: manifest.boundaryTransitions
        )
    }

    // MARK: - Slice 001 Stage D: audio validation (document-level)

    /// Payload-dependent audio invariants (plan §7). Resolves each video-layer clip's
    /// `SceneLayerReference` through `sceneID → payloadID → ResolvedScenePayload`, then the layer,
    /// then the video binding. A video layer WITHOUT an audio clip is legitimate silence — only clips
    /// that exist are validated. One source may back many clips.
    private static func validateAudioDocument(_ document: CanonicalProjectDocument) throws {
        let manifest = document.manifest
        let audio = manifest.audio
        if audio.isEmpty { return }

        // sceneID → payloadID (manifest), payloadID → payload (document).
        let payloadIDByScene = Dictionary(uniqueKeysWithValues: manifest.scenes.map { ($0.id, $0.payloadID) })
        let payloadByID = Dictionary(uniqueKeysWithValues: document.scenePayloads.map { ($0.payloadID, $0) })
        let sourceByID = Dictionary(uniqueKeysWithValues: audio.sources.map { ($0.id, $0) })

        var seenLayerRefs = Set<SceneLayerReference>()

        for clip in audio.clips {
            guard let ref = clip.videoLayer else { continue }   // global clips: no payload resolution

            // No two video-audio clips for the same scene-layer reference.
            guard seenLayerRefs.insert(ref).inserted else {
                throw ProjectValidationError.duplicateVideoAudioClip(layer: "\(ref.sceneID.raw)/\(ref.layerID.raw)")
            }

            // Resolve sceneID → payloadID → payload. (Same LayerID in two scenes resolves distinctly
            // because resolution is keyed by sceneID first.)
            guard let payloadID = payloadIDByScene[ref.sceneID], let payload = payloadByID[payloadID] else {
                throw ProjectValidationError.unknownAudioScene(clip: clip.id.raw)
            }
            // Layer exists in that scene payload.
            guard let layer = payload.layers.first(where: { $0.id == ref.layerID }) else {
                throw ProjectValidationError.audioLayerNotFound(clip: clip.id.raw)
            }
            // Layer content must be video (image rejected).
            guard case .video(let binding) = layer.content else {
                throw ProjectValidationError.audioLayerNotVideo(clip: clip.id.raw)
            }
            // Asset media must equal the layer's video media.
            guard let source = sourceByID[clip.sourceID],
                  case .videoLayerMedia(let media) = source.asset else {
                // Role/asset agreement is a manifest check; a mismatch here is an asset disagreement.
                throw ProjectValidationError.audioRoleAssetMismatch(clip: clip.id.raw)
            }
            guard media == binding.media else {
                throw ProjectValidationError.audioMediaMismatch(clip: clip.id.raw)
            }
            // sourceTrim ⊆ binding.sourceMapping.trimRange (half-open endpoint containment).
            let trim = binding.sourceMapping.trimRange
            guard clip.sourceTrim.start >= trim.start, clip.sourceTrim.end <= trim.end else {
                throw ProjectValidationError.audioTrimNotContained(clip: clip.id.raw)
            }
        }
    }

    // MARK: - Helpers

    private static func requireUniqueAudio(_ values: [String], scope: String) throws {
        var seen = Set<String>()
        for value in values where !seen.insert(value).inserted {
            throw ProjectValidationError.duplicateAudioID(scope: scope, id: value)
        }
    }

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
