/// Slice-004 Stage E — the immutable, callback-visible realtime state snapshot (ADR-012 §5, ADR-006 §8).
///
/// The realtime audio callback may read only **preallocated, lock-free, immutable** state published
/// from outside the callback. `RealtimeSafeState` is that snapshot: a pure value of canonical integer
/// facts (active epoch/revision, the last scheduled chunk's sample range, and bounded counters). It
/// holds **no** samples, **no** audio-framework type, no floating-point value, no `Date`/`UUID`/
/// randomness, and nothing that would require a lock or allocation to read. It is genuinely `Sendable` (no
/// `@unchecked`): every field is a value type. The graph builds a new snapshot off the callback and
/// publishes it; the callback only reads the latest one.
public struct RealtimeSafeState: Sendable, Equatable {

    /// The active playback epoch the callback is rendering for. A buffer from any other epoch must
    /// never be scheduled (ADR-005 §8) — the callback can compare against this without a lock.
    public let epoch: PlaybackEpoch

    /// The active project revision (ADR-005 §8).
    public let revision: ProjectRevision

    /// The half-open 48 kHz sample range of the most recently scheduled chunk for this epoch, or
    /// `nil` before the first chunk. Bounded; never the whole project.
    public let lastScheduledRange: AudioSampleRange?

    /// Count of chunks scheduled so far in this epoch (bounded diagnostics, never unbounded history).
    public let scheduledChunkCount: Int

    /// Count of chunks rejected by admission (stale epoch/revision) so far (bounded diagnostics).
    public let rejectedChunkCount: Int

    public init(
        epoch: PlaybackEpoch,
        revision: ProjectRevision,
        lastScheduledRange: AudioSampleRange?,
        scheduledChunkCount: Int,
        rejectedChunkCount: Int
    ) {
        self.epoch = epoch
        self.revision = revision
        self.lastScheduledRange = lastScheduledRange
        self.scheduledChunkCount = scheduledChunkCount
        self.rejectedChunkCount = rejectedChunkCount
    }

    /// The initial snapshot for a freshly prepared epoch: no chunks scheduled yet.
    public static func initial(epoch: PlaybackEpoch, revision: ProjectRevision) -> RealtimeSafeState {
        RealtimeSafeState(
            epoch: epoch,
            revision: revision,
            lastScheduledRange: nil,
            scheduledChunkCount: 0,
            rejectedChunkCount: 0
        )
    }

    /// A new snapshot after one more chunk was scheduled (published off the callback). Pure; returns a
    /// fresh value, never mutates in place.
    public func advancing(toScheduled range: AudioSampleRange) -> RealtimeSafeState {
        RealtimeSafeState(
            epoch: epoch,
            revision: revision,
            lastScheduledRange: range,
            scheduledChunkCount: scheduledChunkCount + 1,
            rejectedChunkCount: rejectedChunkCount
        )
    }

    /// A new snapshot after one more chunk was rejected by admission.
    public func advancingRejected() -> RealtimeSafeState {
        RealtimeSafeState(
            epoch: epoch,
            revision: revision,
            lastScheduledRange: lastScheduledRange,
            scheduledChunkCount: scheduledChunkCount,
            rejectedChunkCount: rejectedChunkCount + 1
        )
    }
}
