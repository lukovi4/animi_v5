/// One resolved audio segment in an `AudioPlan` (ADR-012 §3). Each segment identifies its canonical
/// source/clip/track, its exact destination sample interval, the audible source sub-window (after the
/// trim + `.once` gate), gain/mute, the conversion metadata the mixer needs, and provenance. The
/// evaluator never folds gain or applies mute — it carries them; muted segments are kept (lead
/// decision) so preview/export know a source is intentionally silent.
public struct AudioSegmentPlan: Equatable, Sendable {
    public let clipID: AudioClipID
    public let sourceID: AudioSourceID
    public let trackID: AudioTrackID
    public let role: AudioSourceRole
    /// The destination interval on the 48 kHz grid (half-open).
    public let destinationSamples: AudioSampleRange
    /// The audible source sub-window after trim + `.once` gating (exact rational).
    public let sourceStart: RationalSourceTime
    public let sourceEnd: RationalSourceTime
    /// The effective trim window applied (a sub-range of the clip's `sourceTrim`).
    public let effectiveTrim: RationalSourceRange
    public let isMuted: Bool
    public let gain: AudioGain
    /// Conversion metadata (carried, not applied — the mixer adapter converts).
    public let sourceSampleRate: Int64
    public let channelLayout: AudioChannelLayoutDescriptor
    /// Provenance for diagnostics / cache validation.
    public let streamIdentity: AudioStreamIdentity
    /// Originating scene for video-layer audio; `nil` for global audio.
    public let sceneID: SceneInstanceID?

    public init(
        clipID: AudioClipID,
        sourceID: AudioSourceID,
        trackID: AudioTrackID,
        role: AudioSourceRole,
        destinationSamples: AudioSampleRange,
        sourceStart: RationalSourceTime,
        sourceEnd: RationalSourceTime,
        effectiveTrim: RationalSourceRange,
        isMuted: Bool,
        gain: AudioGain,
        sourceSampleRate: Int64,
        channelLayout: AudioChannelLayoutDescriptor,
        streamIdentity: AudioStreamIdentity,
        sceneID: SceneInstanceID?
    ) {
        self.clipID = clipID
        self.sourceID = sourceID
        self.trackID = trackID
        self.role = role
        self.destinationSamples = destinationSamples
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.effectiveTrim = effectiveTrim
        self.isMuted = isMuted
        self.gain = gain
        self.sourceSampleRate = sourceSampleRate
        self.channelLayout = channelLayout
        self.streamIdentity = streamIdentity
        self.sceneID = sceneID
    }
}

/// A deterministic, immutable audio plan for one requested project sample interval (ADR-012 §3).
/// A stable ordered collection of segment plans; an EMPTY `segments` list is valid (legitimate
/// silence or an empty/non-overlapping requested interval — not an error). Preview and export consume
/// the same plan. Stage B defines the value type; the Stage-C evaluator produces it.
public struct AudioPlan: Equatable, Sendable {
    public let sampleInterval: AudioSampleRange
    public let segments: [AudioSegmentPlan]

    public init(sampleInterval: AudioSampleRange, segments: [AudioSegmentPlan]) {
        self.sampleInterval = sampleInterval
        self.segments = segments
    }
}
