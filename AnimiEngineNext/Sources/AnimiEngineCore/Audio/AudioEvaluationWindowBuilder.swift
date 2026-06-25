/// Builds an immutable ``AudioEvaluationWindow`` from the canonical manifest, an
/// ``EvaluationWindowRequirement``, the already-loaded scene payloads, and the already-resolved
/// audio source descriptors (Slice-002 Stage C; ADR-012 §1.0b).
///
/// I/O-free and free of any audio-framework dependency: it consumes already-resolved descriptors and never opens an
/// `AVAsset`. It resolves each clip's source to **exactly one** descriptor and copies each
/// video-layer clip's `VideoBinding.sourceMapping` into the resolved binding, so the pure
/// ``AudioEvaluator`` performs no payload lookup and no source resolution. It does **not** re-run the
/// full `ProjectValidator` (Slice-1 already validated the document); it performs only the defensive
/// builder-boundary checks needed to mint a self-consistent window.
public enum AudioEvaluationWindowBuilder {

    public static func build(
        manifest: CanonicalProjectManifest,
        requirement: EvaluationWindowRequirement,
        scenes: [ResolvedScenePayload],
        sourceDescriptors: [ResolvedAudioSourceDescriptor]
    ) throws -> AudioEvaluationWindow {
        let audio = manifest.audio

        // Scene payloads: exact payload-id correspondence with the requirement (mirrors
        // EvaluationWindowBuilder), so video-layer resolution is over the authoritative loaded set.
        var scenePayloadByID: [ScenePayloadID: ResolvedScenePayload] = [:]
        for payload in scenes {
            guard scenePayloadByID[payload.payloadID] == nil else {
                throw ProjectValidationError.duplicatePayload(kind: "scene", id: payload.payloadID.raw)
            }
            scenePayloadByID[payload.payloadID] = payload
        }
        let requiredPayloadIDs = Set(requirement.sceneSpans.map(\.payloadID))
        for id in scenePayloadByID.keys where !requiredPayloadIDs.contains(id) {
            throw ProjectValidationError.unexpectedPayload(kind: "scene", id: id.raw)
        }
        // Resolve sceneID -> payload through the requirement spans (which carry both ids).
        var payloadBySceneID: [SceneInstanceID: ResolvedScenePayload] = [:]
        for span in requirement.sceneSpans {
            guard let payload = scenePayloadByID[span.payloadID] else {
                throw ProjectValidationError.missingPayload(kind: "scene", id: span.payloadID.raw)
            }
            guard payload.sceneID == span.sceneID else {
                throw ProjectValidationError.inconsistentPayload(kind: "scene", id: span.payloadID.raw)
            }
            payloadBySceneID[span.sceneID] = payload
        }

        // Per-scene following boundary/transition from the requirement transitions.
        var followingByScene: [SceneInstanceID: (boundary: ProjectTime, transition: SceneTransition)] = [:]
        for boundary in requirement.transitions {
            followingByScene[boundary.outgoingSceneID] = (boundary.boundary, boundary.transition)
        }
        var windowScenes: [AudioWindowScene] = []
        for span in requirement.sceneSpans {
            let following = followingByScene[span.sceneID]
            windowScenes.append(AudioWindowScene(
                sceneID: span.sceneID,
                sceneStart: span.sceneStart,
                nominalDuration: span.nominalDuration,
                timelineSpan: span.timelineSpan,
                followingBoundary: following?.boundary,
                followingTransition: following?.transition
            ))
        }

        // Resolve each referenced source to EXACTLY ONE descriptor. A source is "referenced" iff a clip
        // names it; a silent video (no clip) requires no descriptor (legitimate silence, not an error).
        var descriptorsBySource: [AudioSourceID: [ResolvedAudioSourceDescriptor]] = [:]
        for descriptor in sourceDescriptors {
            descriptorsBySource[descriptor.sourceID, default: []].append(descriptor)
        }
        let sourceByID = Dictionary(uniqueKeysWithValues: audio.sources.map { ($0.id, $0) })

        var resolvedDescriptorByClipSource: [AudioSourceID: ResolvedAudioSourceDescriptor] = [:]
        let referencedSources = Set(audio.clips.map(\.sourceID))
        for sourceID in referencedSources {
            let candidates = descriptorsBySource[sourceID] ?? []
            // Stable-identity selection: independent of input order. Zero/multiple → typed failure.
            switch candidates.count {
            case 0:
                throw AudioEvaluationError.unresolvedAudioSource(sourceID: sourceID.raw)
            case 1:
                resolvedDescriptorByClipSource[sourceID] = candidates[0]
            default:
                // Multiple descriptors for the same referenced source (ambiguous stream).
                throw AudioEvaluationError.ambiguousAudioSource(sourceID: sourceID.raw)
            }
        }

        // Materialise canonical track order: sorted by AudioTrackID (ADR-012 §1.1/§3).
        let orderedTracks = audio.tracks.sorted { $0.id < $1.id }
        var resolvedTracks: [ResolvedAudioTrack] = []
        for (order, track) in orderedTracks.enumerated() {
            resolvedTracks.append(ResolvedAudioTrack(trackID: track.id, role: track.role, order: order))
        }

        // Resolve each clip's binding.
        var resolvedClips: [ResolvedAudioClip] = []
        for clip in audio.clips {
            guard let source = sourceByID[clip.sourceID] else {
                // A clip references a non-existent source (Slice-1 would have rejected this; defensive).
                throw AudioEvaluationError.unresolvedAudioSource(sourceID: clip.sourceID.raw)
            }
            let binding = try resolveBinding(clip: clip, source: source, payloadBySceneID: payloadBySceneID)
            // The exactly-one descriptor resolved above (referenced sources all have one or we threw).
            guard let descriptor = resolvedDescriptorByClipSource[clip.sourceID] else {
                throw AudioEvaluationError.unresolvedAudioSource(sourceID: clip.sourceID.raw)
            }
            // Fail-closed role: a clip whose track is missing has no canonical role → typed error.
            let role = try roleForTrack(clip.trackID, tracks: audio.tracks, clipID: clip.id)
            resolvedClips.append(ResolvedAudioClip(
                clipID: clip.id, trackID: clip.trackID, sourceID: clip.sourceID,
                role: role,
                isMuted: clip.isMuted, gain: clip.gain, destination: clip.destination,
                sourceTrim: clip.sourceTrim, playbackPolicy: clip.playbackPolicy, binding: binding,
                sourceDescriptor: descriptor
            ))
        }

        return AudioEvaluationWindow(
            coverage: requirement.coverage,
            projectDuration: requirement.projectDuration,
            scenes: windowScenes,
            tracks: resolvedTracks,
            clips: resolvedClips
        )
    }

    /// Resolves a clip's binding from its asset reference. Global → `.global`. Video-layer → resolve
    /// the scene payload + layer, require `.video`, and copy the layer's exact `sourceMapping`.
    private static func resolveBinding(
        clip: AudioClipEntry,
        source: AudioSourceEntry,
        payloadBySceneID: [SceneInstanceID: ResolvedScenePayload]
    ) throws -> AudioClipBinding {
        switch source.asset {
        case .globalAudio:
            // Global audio carries no video layer; a videoLayer reference on a global clip is inconsistent.
            if clip.videoLayer != nil {
                throw AudioEvaluationError.inconsistentResolvedBinding(clipID: clip.id.raw)
            }
            return .global
        case .videoLayerMedia(let media):
            guard let ref = clip.videoLayer else {
                throw AudioEvaluationError.inconsistentResolvedBinding(clipID: clip.id.raw)
            }
            guard let payload = payloadBySceneID[ref.sceneID] else {
                throw AudioEvaluationError.unknownAudioWindowScene(sceneID: ref.sceneID.raw)
            }
            guard let layer = payload.layers.first(where: { $0.id == ref.layerID }) else {
                throw AudioEvaluationError.inconsistentResolvedBinding(clipID: clip.id.raw)
            }
            guard case .video(let videoBinding) = layer.content else {
                throw AudioEvaluationError.inconsistentResolvedBinding(clipID: clip.id.raw)
            }
            // Defensive: asset media must equal the layer's video media (Slice-1 already validated).
            guard videoBinding.media == media else {
                throw AudioEvaluationError.inconsistentResolvedBinding(clipID: clip.id.raw)
            }
            return .videoLayer(sceneID: ref.sceneID, sourceMapping: videoBinding.sourceMapping)
        }
    }

    /// The role for a clip, taken from its owning track (the canonical role carrier). Fail-closed: a
    /// clip whose `trackID` has no matching track has no canonical role — typed error, never a fallback.
    private static func roleForTrack(
        _ trackID: AudioTrackID, tracks: [AudioTrackEntry], clipID: AudioClipID
    ) throws -> AudioSourceRole {
        guard let track = tracks.first(where: { $0.id == trackID }) else {
            throw AudioEvaluationError.inconsistentResolvedBinding(clipID: clipID.raw)
        }
        return track.role
    }
}
