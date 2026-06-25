/// Slice-003 Stage G — bounded, typed scheduler diagnostics (ADR-005 §9, ADR-006 "Required
/// diagnostics").
///
/// Diagnostics are pure value events appended to an injected sink. They record the request lifecycle and
/// the scheduler's identity/queue/skip decisions WITHOUT performing work on any realtime path (this
/// slice has none) and without `Date`/`UUID`/randomness — every event carries the exact identities and
/// reasons the scheduler already holds. The events are a read-only mirror of decisions made by
/// `TransportReducer` / `AdmissionController` / `PublicationGate`; emitting them never changes runtime
/// behavior.

/// One typed lifecycle event (ADR-005 §9). Bounded value; no free-form strings as control flow.
public enum SchedulerDiagnosticEvent: Sendable, Equatable {
    /// A complete-frame workset was requested for an exact target.
    case requested(RequestIdentity)
    /// A completion was admitted against the active snapshot.
    case admitted(RequestIdentity)
    /// A completion was rejected, with the typed reason (stale revision/epoch, superseded, missing
    /// dependency, out of coverage, …).
    case rejected(reason: RejectionReason, time: ProjectTime, epoch: PlaybackEpoch)
    /// A complete frame was atomically published, carrying the previous and new published identities.
    case published(previous: PublishedIdentitySummary?, new: PublishedIdentitySummary)
    /// A candidate kept the previous complete composition instead of publishing (global skip / hold),
    /// with the reason. Never a per-layer substitution.
    case keptPrevious(reason: RejectionReason)
    /// The accepting epoch transitioned (a discontinuity minted a fresh epoch).
    case epochTransition(from: PlaybackEpoch?, to: PlaybackEpoch)
    /// Bounded-queue occupancy after an admission decision, for backpressure visibility.
    case queueOccupancy(queue: DiagnosticQueue, count: Int, capacity: Int)
    /// A decoded audio range was admitted or rejected (ADR-005 §8).
    case audioRange(reason: RejectionReason?, epoch: PlaybackEpoch, request: AudioRequestID)
    /// Not-yet-rendered ranges were flushed from a superseded epoch.
    case audioFlushed(count: Int, supersededInto: PlaybackEpoch)
}

/// Which bounded queue an occupancy event refers to.
public enum DiagnosticQueue: Sendable, Equatable {
    case workset
    case audioRange
}

/// A sink that receives diagnostic events. Implementations must be bounded and side-effect-light; the
/// scheduler appends synchronously. The default in-memory sink keeps a bounded ring of recent events.
public protocol SchedulerDiagnosticsSink: Sendable {
    mutating func record(_ event: SchedulerDiagnosticEvent)
}

/// A bounded in-memory diagnostics sink: keeps at most `capacity` most-recent events (oldest dropped).
/// Deterministic; no allocation beyond the ring; no `Date`/`UUID`. Used by tests and by an owner that
/// wants a recent-event window without unbounded growth.
public struct BoundedDiagnosticsSink: SchedulerDiagnosticsSink {
    public let capacity: Int
    public private(set) var events: [SchedulerDiagnosticEvent]
    /// The total number of events ever recorded (including dropped ones), so callers can detect drops.
    public private(set) var recordedCount: Int

    public init(capacity: Int) throws {
        guard capacity > 0 else { throw SchedulerDiagnosticsError.invalidCapacity(capacity) }
        self.capacity = capacity
        self.events = []
        self.recordedCount = 0
    }

    public mutating func record(_ event: SchedulerDiagnosticEvent) {
        recordedCount += 1
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
    }
}

public enum SchedulerDiagnosticsError: Error, Equatable, Sendable {
    case invalidCapacity(Int)
}
