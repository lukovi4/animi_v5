/// The project→source mapping a resolved audio clip uses (ADR-012 §1.0a item 3/4). Either strict
/// global 1/1, or a video-layer clip that inherits its referenced layer's `VideoBinding.sourceMapping`
/// verbatim (the audio never builds its own mapping). The `sourceMapping` is a resolved copy, so the
/// evaluator never touches a payload.
public enum AudioClipBinding: Equatable, Sendable {
    /// Global audio (`music`/`voiceover`/`soundEffect`): strict 1/1 (§1.0a item 3).
    case global
    /// Video-layer audio: the referenced scene plus that layer's exact source mapping (§1.0a item 4).
    case videoLayer(sceneID: SceneInstanceID, sourceMapping: SourceTimeMapping)
}

/// A fully resolved audio clip inside an `AudioEvaluationWindow`. All fields are exact values copied
/// from the canonical manifest plus the resolved binding — no payload lookup remains for the evaluator.
public struct ResolvedAudioClip: Equatable, Sendable {
    public let clipID: AudioClipID
    public let trackID: AudioTrackID
    public let sourceID: AudioSourceID
    public let role: AudioSourceRole
    public let isMuted: Bool
    public let gain: AudioGain
    public let destination: ProjectTimeRange
    public let sourceTrim: RationalSourceRange
    public let playbackPolicy: AudioPlaybackPolicy
    public let binding: AudioClipBinding
    /// The exactly-one resolved source descriptor for this clip's source (ADR-012 §1.0b). Carried so
    /// the evaluator copies real `sampleRate`/`channelLayout`/`streamIdentity` into each segment rather
    /// than synthesizing them.
    public let sourceDescriptor: ResolvedAudioSourceDescriptor

    public init(
        clipID: AudioClipID,
        trackID: AudioTrackID,
        sourceID: AudioSourceID,
        role: AudioSourceRole,
        isMuted: Bool,
        gain: AudioGain,
        destination: ProjectTimeRange,
        sourceTrim: RationalSourceRange,
        playbackPolicy: AudioPlaybackPolicy,
        binding: AudioClipBinding,
        sourceDescriptor: ResolvedAudioSourceDescriptor
    ) {
        self.clipID = clipID
        self.trackID = trackID
        self.sourceID = sourceID
        self.role = role
        self.isMuted = isMuted
        self.gain = gain
        self.destination = destination
        self.sourceTrim = sourceTrim
        self.playbackPolicy = playbackPolicy
        self.binding = binding
        self.sourceDescriptor = sourceDescriptor
    }
}

/// A resolved audio track with its canonical evaluation order materialised once (ADR-012 §3). The
/// `order` is the primary stable sort key for segments — never dictionary iteration or completion order.
public struct ResolvedAudioTrack: Equatable, Sendable {
    public let trackID: AudioTrackID
    public let role: AudioSourceRole
    public let order: Int

    public init(trackID: AudioTrackID, role: AudioSourceRole, order: Int) {
        self.trackID = trackID
        self.role = role
        self.order = order
    }
}

/// Per-scene facts the shared `SceneMediaClock` needs to derive `sceneMediaTime` and the media-active
/// domain — no payload, no layers (ADR-012 §1.0a item 4, §1.0b). The following boundary/transition are
/// `nil` for the final scene.
public struct AudioWindowScene: Equatable, Sendable {
    public let sceneID: SceneInstanceID
    public let sceneStart: ProjectTime
    public let nominalDuration: TickDuration
    public let timelineSpan: TickDuration
    public let followingBoundary: ProjectTime?
    public let followingTransition: SceneTransition?

    public init(
        sceneID: SceneInstanceID,
        sceneStart: ProjectTime,
        nominalDuration: TickDuration,
        timelineSpan: TickDuration,
        followingBoundary: ProjectTime?,
        followingTransition: SceneTransition?
    ) {
        self.sceneID = sceneID
        self.sceneStart = sceneStart
        self.nominalDuration = nominalDuration
        self.timelineSpan = timelineSpan
        self.followingBoundary = followingBoundary
        self.followingTransition = followingTransition
    }
}

/// An immutable, self-contained audio evaluation window (ADR-012 §1.0b). The pure `AudioEvaluator`
/// (Stage C) operates only on this window: no `CanonicalProjectManifest`, no payload table, no I/O.
/// Mirrors the video `EvaluationWindow` split. Stage B defines the value type; Stage C mints it.
public struct AudioEvaluationWindow: Equatable, Sendable {
    public let coverage: ProjectTimeRange
    public let projectDuration: TickDuration
    public let scenes: [AudioWindowScene]
    public let tracks: [ResolvedAudioTrack]
    public let clips: [ResolvedAudioClip]

    public init(
        coverage: ProjectTimeRange,
        projectDuration: TickDuration,
        scenes: [AudioWindowScene],
        tracks: [ResolvedAudioTrack],
        clips: [ResolvedAudioClip]
    ) {
        self.coverage = coverage
        self.projectDuration = projectDuration
        self.scenes = scenes
        self.tracks = tracks
        self.clips = clips
    }
}
