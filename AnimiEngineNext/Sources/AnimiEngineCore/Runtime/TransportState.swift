/// Slice-003 Stage C — the transport state machine (ADR-006 §2, control portion only).
///
/// One serialized transport interpretation at a time. There is no independent play/pause/scrub state
/// inside individual sources (ADR-006 §2); every state below carries the exact canonical `ProjectTime`
/// or `PlaybackEpoch` it governs. `ProjectTime` is the only timeline coordinate. This slice holds NO
/// scheduler/workset/queue state — only the explicit states and the pure reducer over them.
public enum TransportState: Sendable, Equatable {
    /// Held at an exact project time; no progressing master clock.
    case paused(at: ProjectTime)

    /// The playback start barrier (ADR-006 §5): a fresh epoch resolving its anchor + first complete
    /// frame before time advances. Carries the epoch it is preparing and the project time it starts from.
    case preparing(from: ProjectTime, epoch: PlaybackEpoch)

    /// Time is advancing under the epoch's selected master clock.
    case playing(epoch: PlaybackEpoch)

    /// Silent scrub (ADR-006 §7): a held explicit target; latest target wins.
    case scrubbing(target: ProjectTime, epoch: PlaybackEpoch)

    /// The settle barrier (ADR-006 §7): resolving exactly the final scrub target. Stays paused there
    /// after settle — playback resumes only after an explicit `play()`.
    case settling(target: ProjectTime, epoch: PlaybackEpoch)

    /// Paused by an audio interruption / relevant route change at the last confirmed project time
    /// (ADR-006 §11). Never auto-resumes.
    case interrupted(at: ProjectTime)

    /// The transport reached the end of the project at an exact project time.
    case ended(at: ProjectTime)

    /// A typed transport failure (e.g. prepare-barrier timeout). Never advances time.
    case failed(TransportFailure)
}

/// A typed transport failure. Carries enough to diagnose without strings-as-logic; bounded value type.
public enum TransportFailure: Sendable, Equatable {
    /// The playback start barrier (ADR-006 §5) exceeded its bounded timeout while preparing `epoch`.
    case prepareTimedOut(epoch: PlaybackEpoch, from: ProjectTime)

    /// A bounded, caller-classified preparation/runtime failure. Non-empty reason; this slice does not
    /// interpret the reason beyond carrying it (no string-as-control-flow).
    case prepareFailed(epoch: PlaybackEpoch, reason: TransportFailureReason)

    /// A caller-supplied failure not tied to a specific epoch (e.g. an external fault injected by a test
    /// or a host signal). Non-empty reason.
    case external(reason: TransportFailureReason)
}

/// A non-empty, opaque failure reason. The transport never branches on its contents.
public struct TransportFailureReason: Hashable, Sendable {
    public let raw: String
    public init(_ raw: String) throws {
        guard !raw.isEmpty else { throw RuntimeIdentityError.emptyTransportFailureReason }
        self.raw = raw
    }
}
