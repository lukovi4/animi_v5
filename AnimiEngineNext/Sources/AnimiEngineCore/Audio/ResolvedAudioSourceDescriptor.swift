/// A stable, opaque audio-stream provenance identity (ADR-012 §1.0b). Typed so a stream identity can
/// never be confused with a raw string at a call site. Emptiness is rejected at construction.
///
/// Stream selection is by this stable identity, never by incidental `AVAsset` track ordering — the
/// identity is resolved upstream (Stage-C builder input) and carried through the plan unchanged.
public struct AudioStreamIdentity: Hashable, Sendable {
    public let raw: String

    public init(_ raw: String) throws {
        guard !raw.isEmpty else { throw AudioEvaluationError.invalidAudioStreamIdentity }
        self.raw = raw
    }
}

/// The canonical audio channel layout for the v1 mix (ADR-012 §1.0b, §4). Integer-only; no
/// platform audio-framework layout type.
///
/// Fail-closed value model: the only initializer is private, so an invalid `.discrete` channel count
/// (`<= 0`) is **unrepresentable** through the public API. `mono`/`stereo` are ergonomic statics;
/// `discrete(count:)` is the sole way to build a discrete layout and rejects non-positive counts.
public struct AudioChannelLayoutDescriptor: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case mono
        case stereo
        case discrete
    }

    public let kind: Kind
    public let channelCount: Int

    /// The only initializer — private, so callers cannot construct an invalid discrete count.
    private init(kind: Kind, channelCount: Int) {
        self.kind = kind
        self.channelCount = channelCount
    }

    public static let mono = AudioChannelLayoutDescriptor(kind: .mono, channelCount: 1)
    public static let stereo = AudioChannelLayoutDescriptor(kind: .stereo, channelCount: 2)

    /// Builds a discrete layout, rejecting `count <= 0` (`mono`/`stereo` are the ergonomic statics).
    public static func discrete(count: Int) throws -> AudioChannelLayoutDescriptor {
        guard count > 0 else { throw AudioEvaluationError.invalidAudioChannelLayout }
        return AudioChannelLayoutDescriptor(kind: .discrete, channelCount: count)
    }
}

/// A fully resolved audio source: the single logical stream backing an `AudioAssetReference`
/// (ADR-012 §1.0b). A value type carrying only integer/rational facts — no I/O, no `AVAsset`.
/// Produced upstream and consumed by the Stage-C builder; the evaluator never resolves sources.
public struct ResolvedAudioSourceDescriptor: Equatable, Sendable {
    public let sourceID: AudioSourceID
    public let streamIdentity: AudioStreamIdentity
    /// Exact source duration as canonical rational seconds.
    public let sourceDuration: RationalSourceTime
    /// Source sample rate (Hz), integer.
    public let sampleRate: Int64
    public let channelLayout: AudioChannelLayoutDescriptor

    public init(
        sourceID: AudioSourceID,
        streamIdentity: AudioStreamIdentity,
        sourceDuration: RationalSourceTime,
        sampleRate: Int64,
        channelLayout: AudioChannelLayoutDescriptor
    ) {
        self.sourceID = sourceID
        self.streamIdentity = streamIdentity
        self.sourceDuration = sourceDuration
        self.sampleRate = sampleRate
        self.channelLayout = channelLayout
    }
}
