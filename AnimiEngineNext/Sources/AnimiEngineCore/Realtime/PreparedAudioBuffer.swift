/// Slice-004 Stage C — the immutable metadata of one bounded prepared PCM chunk (ADR-005 §8,
/// ADR-006 §5/§9, ADR-012 §5).
///
/// This is **metadata only**. It carries the ADR-005 §8 identity tuple a decoded range needs to be
/// admitted into a preview source buffer, plus the segment descriptor facts the mixer needs — but it
/// holds **no raw samples**: the decoded PCM is referenced through an opaque, injected
/// `PreparedAudioPayloadHandle`, never an in-model raw sample array. Stage C defines the value
/// and the cutting contract; the realtime callback, decode, conversion, and output stage are later
/// stages. No audio framework import, no fractional/floating-point numeric type for canonical values.

// MARK: - Typed errors at the Stage-C preparation boundary

/// Typed failures when cutting a bounded prepared chunk (Slice-004 Stage C). Distinct from the
/// Stage-A `RealtimeAudioBoundaryError` (device/session boundary) and the pure `AudioEvaluationError`.
public enum AudioChunkPreparationError: Error, Equatable, Sendable {
    /// A `PreparedAudioPayloadHandle` was constructed from an empty identifier.
    case invalidPreparedPayload
    /// A non-positive injected maximum chunk size (`maxChunkSamples <= 0`).
    case invalidMaxChunkSize(Int64)
    /// A `PreparedAudioBuffer` was constructed with a non-positive `sourceSampleRate` (`<= 0`).
    case invalidPreparedSourceSampleRate(Int64)
    /// The requested chunk range is empty (`start == end`) — a prepared chunk must be non-empty.
    case emptyChunkRange
    /// The requested chunk range is inverted (`end < start`).
    case invertedChunkRange
    /// The requested chunk range is not fully inside the segment destination range (fail-closed; the
    /// contract does not clip — out-of-range or partially-out-of-range requests are rejected).
    case chunkOutsideSegmentDestination
    /// The requested chunk exceeds the injected bounded maximum (`sampleCount > maxChunkSamples`).
    case chunkExceedsMaxSize(requested: Int64, max: Int64)
}

// MARK: - Opaque PCM payload reference

/// An opaque, injected reference to the decoded PCM backing a prepared chunk (ADR-012 §5: decode and
/// preparation happen on bounded workers; the realtime callback consumes preallocated data). Stage C
/// never allocates or inspects samples — it only carries this token so the canonical model stays free
/// of raw sample arrays. A non-empty identifier; emptiness is rejected (fail-closed value model,
/// mirroring `AudioStreamIdentity`).
public struct PreparedAudioPayloadHandle: Hashable, Sendable {
    public let identifier: String

    public init(identifier: String) throws {
        guard !identifier.isEmpty else { throw AudioChunkPreparationError.invalidPreparedPayload }
        self.identifier = identifier
    }
}

// MARK: - Prepared audio buffer (metadata)

/// Immutable metadata for one bounded prepared PCM chunk cut from an `AudioSegmentPlan`.
///
/// Carries the ADR-005 §8 identity tuple (`revision + epoch + AudioRequestID + AudioSourceID + exact
/// 48 kHz sample range`) so it can bridge to the existing `DecodedAudioRangeDescriptor` for admission,
/// plus the segment descriptor facts (stream identity, source sample rate, channel layout, mute, gain)
/// needed to preserve `AudioSegmentPlan` semantics through preview/export. `chunkRange` is the bounded
/// half-open sub-range of the segment destination this buffer covers; `frameCount` is its sample count.
public struct PreparedAudioBuffer: Equatable, Sendable {

    // ADR-005 §8 identity tuple
    public let revision: ProjectRevision
    public let epoch: PlaybackEpoch
    public let request: AudioRequestID
    public let sourceID: AudioSourceID
    /// The bounded half-open 48 kHz range this chunk covers (a sub-range of the segment destination).
    public let chunkRange: AudioSampleRange

    // Descriptor metadata (preserves AudioSegmentPlan semantics; carried, not applied)
    public let streamIdentity: AudioStreamIdentity
    public let sourceSampleRate: Int64
    public let channelLayout: AudioChannelLayoutDescriptor
    public let isMuted: Bool
    public let gain: AudioGain

    /// Opaque reference to the decoded PCM for this chunk (no samples in the canonical model).
    public let payload: PreparedAudioPayloadHandle

    /// The exact 48 kHz sample count of this chunk (`chunkRange.sampleCount`, always `>= 1` because the
    /// throwing init rejects empty and inverted ranges — a prepared chunk is non-empty by construction).
    public var frameCount: Int64 { chunkRange.sampleCount }

    /// Fail-closed initializer enforcing the buffer's **self-contained** invariants (the ones provable
    /// without the originating segment): `chunkRange` is non-inverted and non-empty, and
    /// `sourceSampleRate` is positive. `payload` is already validated by its own init. Destination
    /// containment and the injected max-chunk bound are NOT checked here — they need the segment and
    /// remain owned by `AudioChunkBounds.validate`. This closes the hole where a public construction
    /// could mint an invalid buffer directly, bypassing `AudioChunkBounds`.
    public init(
        revision: ProjectRevision,
        epoch: PlaybackEpoch,
        request: AudioRequestID,
        sourceID: AudioSourceID,
        chunkRange: AudioSampleRange,
        streamIdentity: AudioStreamIdentity,
        sourceSampleRate: Int64,
        channelLayout: AudioChannelLayoutDescriptor,
        isMuted: Bool,
        gain: AudioGain,
        payload: PreparedAudioPayloadHandle
    ) throws {
        guard chunkRange.end >= chunkRange.start else {
            throw AudioChunkPreparationError.invertedChunkRange
        }
        guard !chunkRange.isEmpty else {
            throw AudioChunkPreparationError.emptyChunkRange
        }
        guard sourceSampleRate > 0 else {
            throw AudioChunkPreparationError.invalidPreparedSourceSampleRate(sourceSampleRate)
        }
        self.revision = revision
        self.epoch = epoch
        self.request = request
        self.sourceID = sourceID
        self.chunkRange = chunkRange
        self.streamIdentity = streamIdentity
        self.sourceSampleRate = sourceSampleRate
        self.channelLayout = channelLayout
        self.isMuted = isMuted
        self.gain = gain
        self.payload = payload
    }

    /// Bridges to the existing ADR-005 §8 admission descriptor (`AudioRangeAdmission`). The identity
    /// tuple is carried verbatim; the chunk range is the sample range validated against the snapshot.
    public var rangeDescriptor: DecodedAudioRangeDescriptor {
        DecodedAudioRangeDescriptor(
            revision: revision,
            epoch: epoch,
            request: request,
            source: sourceID,
            sampleRange: chunkRange
        )
    }
}
