/// Slice-004 Stage C — the injected bounded-PCM preparation contract (ADR-005 §8, ADR-006 §5/§9,
/// ADR-012 §5).
///
/// `AudioChunkPreparer` turns one `AudioSegmentPlan` plus the ADR-005 §8 identity coordinates and a
/// requested bounded sample range into one `PreparedAudioBuffer` (metadata only). It is an **injected
/// contract**: decode and source-rate/channel conversion are the conforming implementation's concern,
/// behind this protocol. Stage C performs **no** file I/O, **no** AVFoundation, and **no** decode —
/// the fake in tests returns a buffer with an opaque payload handle and no samples.
///
/// Boundedness is explicit and fail-closed (ADR-005 §8 *"bounded scheduling horizons … never enqueue
/// unbounded future audio"*, ADR-006 §9 *"every queue is bounded"*): the requested chunk range must be
/// non-empty, non-inverted, fully inside the segment destination, and no larger than an **injected**
/// maximum (never a hardcoded constant — ADR-006 §9). A whole-project-sized range is therefore not
/// accepted as one unbounded chunk. No whole-project render, no temp file, no loop, no implicit ramp.

/// One bounded request to prepare a chunk: which segment, the ADR-005 §8 identity, the requested 48 kHz
/// sub-range, and the injected bound. A pure value so a fake preparer needs no I/O.
public struct AudioChunkRequest: Equatable, Sendable {
    public let segment: AudioSegmentPlan
    public let revision: ProjectRevision
    public let epoch: PlaybackEpoch
    public let request: AudioRequestID
    /// The requested half-open 48 kHz sub-range to prepare (must be bounded inside the segment).
    public let chunkRange: AudioSampleRange
    /// Injected maximum chunk size in samples (runtime config; never a hardcoded constant).
    public let maxChunkSamples: Int64

    public init(
        segment: AudioSegmentPlan,
        revision: ProjectRevision,
        epoch: PlaybackEpoch,
        request: AudioRequestID,
        chunkRange: AudioSampleRange,
        maxChunkSamples: Int64
    ) {
        self.segment = segment
        self.revision = revision
        self.epoch = epoch
        self.request = request
        self.chunkRange = chunkRange
        self.maxChunkSamples = maxChunkSamples
    }
}

/// Shared, pure boundedness validation reused by every conforming preparer (and the test fake), so the
/// fail-closed rules are defined once (ADR-005 §8, ADR-006 §9). No samples, no I/O, no device.
public enum AudioChunkBounds {

    /// Validates a chunk request's range against the segment destination and the injected bound.
    /// Fail-closed: throws a typed `AudioChunkPreparationError` and never clips a partially-out-of-range
    /// request. Returns the validated `chunkRange` on success.
    public static func validate(_ request: AudioChunkRequest) throws -> AudioSampleRange {
        guard request.maxChunkSamples > 0 else {
            throw AudioChunkPreparationError.invalidMaxChunkSize(request.maxChunkSamples)
        }
        let chunk = request.chunkRange
        // AudioSampleRange forbids end < start at construction, but a chunk request may still be empty
        // or (defensively) inverted; reject both explicitly.
        guard chunk.end >= chunk.start else { throw AudioChunkPreparationError.invertedChunkRange }
        guard !chunk.isEmpty else { throw AudioChunkPreparationError.emptyChunkRange }

        let dest = request.segment.destinationSamples
        // Fully inside the destination: [chunk.start, chunk.end) ⊆ [dest.start, dest.end).
        guard chunk.start >= dest.start, chunk.end <= dest.end else {
            throw AudioChunkPreparationError.chunkOutsideSegmentDestination
        }

        guard chunk.sampleCount <= request.maxChunkSamples else {
            throw AudioChunkPreparationError.chunkExceedsMaxSize(
                requested: chunk.sampleCount, max: request.maxChunkSamples)
        }
        return chunk
    }
}

/// The injected preparation contract. A conforming type decodes/converts behind this boundary and
/// returns immutable `PreparedAudioBuffer` metadata; Stage C ships only the contract and a pure
/// validator. The realtime callback, output stage, and graph are later stages.
public protocol AudioChunkPreparer: Sendable {
    /// Prepare one bounded chunk for the request. Must fail closed (throw a typed
    /// `AudioChunkPreparationError`) on an invalid/empty/inverted/out-of-range/over-max request, using
    /// the shared `AudioChunkBounds.validate`. Returns metadata referencing an opaque PCM payload.
    func prepare(_ request: AudioChunkRequest) throws -> PreparedAudioBuffer
}
