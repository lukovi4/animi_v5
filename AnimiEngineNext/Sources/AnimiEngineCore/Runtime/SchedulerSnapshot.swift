/// Slice-003 Stage D — the immutable scheduler view the publication gate validates against.
///
/// This slice does NOT build the scheduler owner (Stage F). `SchedulerSnapshot` is only the minimal,
/// immutable set of "what is current" facts a gate needs: the active revision/epoch, the current
/// coverage, the latest explicit target (for supersession), and the identity of the last published
/// complete frame (for late-after-newer). It is a pure value; nothing here mutates or publishes.
public struct SchedulerSnapshot: Sendable, Equatable {
    /// The active immutable project revision. A candidate from any other revision is stale.
    public let revision: ProjectRevision

    /// The active playback epoch. A candidate from any other epoch is stale.
    public let epoch: PlaybackEpoch

    /// The current evaluation coverage. A candidate whose time falls outside this is out of coverage.
    public let coverage: ProjectTimeRange

    /// The latest explicit target the transport currently wants published, for this epoch. Used for
    /// supersession: a candidate for a different target/frame-request is superseded.
    public let currentTarget: CurrentTarget

    /// The identity of the last published complete frame, if any. A candidate older than this (same
    /// epoch, earlier time) is a late-after-newer frame.
    public let lastPublished: PublishedIdentitySummary?

    public init(
        revision: ProjectRevision,
        epoch: PlaybackEpoch,
        coverage: ProjectTimeRange,
        currentTarget: CurrentTarget,
        lastPublished: PublishedIdentitySummary?
    ) {
        self.revision = revision
        self.epoch = epoch
        self.coverage = coverage
        self.currentTarget = currentTarget
        self.lastPublished = lastPublished
    }
}

/// The latest explicit target the scheduler currently wants, identified by its exact time and the
/// frame request that owns it. A candidate matches only when BOTH agree (ADR-005 §7).
public struct CurrentTarget: Sendable, Equatable {
    public let time: ProjectTime
    public let frameRequest: FrameRequestID

    public init(time: ProjectTime, frameRequest: FrameRequestID) {
        self.time = time
        self.frameRequest = frameRequest
    }
}

/// A compact summary of a previously published frame for the late-after-newer check (ADR-005 §6).
public struct PublishedIdentitySummary: Sendable, Equatable {
    public let epoch: PlaybackEpoch
    public let time: ProjectTime
    public let frameRequest: FrameRequestID

    public init(epoch: PlaybackEpoch, time: ProjectTime, frameRequest: FrameRequestID) {
        self.epoch = epoch
        self.time = time
        self.frameRequest = frameRequest
    }
}
