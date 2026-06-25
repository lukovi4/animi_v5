/// Slice-003 Stage E — latest-wins scrub coalescing + exact settle barrier (ADR-005 §7, ADR-006 §7).
///
/// Pure value helpers — no queues, no scheduler owner, no publication. They answer two questions:
///  • during a scrub, which target is currently publishable and which is superseded (latest wins), and
///    whether the previously published complete composition must be kept until the exact target frame
///    exists;
///  • at settle, whether a candidate frame is exactly the final settle target (no nearby substitution),
///    and that the settled result is held/paused (never auto-play).

/// A scrub target: the exact project time and the frame request that owns it.
public struct ScrubTarget: Sendable, Equatable {
    public let time: ProjectTime
    public let frameRequest: FrameRequestID

    public init(time: ProjectTime, frameRequest: FrameRequestID) {
        self.time = time
        self.frameRequest = frameRequest
    }
}

/// What the scheduler should do with the currently-published frame given a scrub state and the latest
/// target (ADR-005 §7).
public enum ScrubPresentation: Sendable, Equatable {
    /// The latest target's exact complete frame is available → present it.
    case presentLatest(ScrubTarget)
    /// The latest target's frame is not yet complete → keep the previous complete composition. Never a
    /// per-layer or temporal substitution.
    case keepPreviousComplete
}

/// Whether a completion is publishable during a scrub, relative to the latest target (ADR-005 §7).
public enum ScrubAdmission: Sendable, Equatable {
    case currentTarget
    case superseded
}

public enum ScrubSettlePolicy {

    // MARK: - Latest-wins scrub coalescing

    /// Coalesce an incoming scrub update against the current target: the incoming target always wins
    /// (latest-wins), and the previous current target becomes superseded. Returns the new current target.
    /// This is a state-level decision; older in-flight work for `previous` is now inadmissible by
    /// identity (see ``classify``).
    public static func coalesce(current previous: ScrubTarget, update incoming: ScrubTarget) -> ScrubTarget {
        // Latest wins unconditionally — the newest explicit target is the only publishable one.
        incoming
    }

    /// Classify a completion's target against the latest scrub target: only the exact latest target
    /// (time AND frame request) is current; everything else is superseded (ADR-005 §7).
    public static func classify(completion target: ScrubTarget, latest: ScrubTarget) -> ScrubAdmission {
        (target == latest) ? .currentTarget : .superseded
    }

    /// Decide what to present during a scrub: present the latest target only if its exact complete frame
    /// is available; otherwise keep the previous complete composition (ADR-005 §7, ADR-006 §7).
    public static func presentation(latest: ScrubTarget, latestCompleteFrameAvailable: Bool) -> ScrubPresentation {
        latestCompleteFrameAvailable ? .presentLatest(latest) : .keepPreviousComplete
    }

    // MARK: - Exact settle barrier

    /// The result of resolving a settle candidate against the exact final settle target (ADR-006 §7).
    public enum SettleOutcome: Sendable, Equatable {
        /// The candidate is exactly the final settle target → publish it, then remain paused/held.
        case publishExact(ScrubTarget)
        /// The candidate is a nearby/other target → rejected as superseded; the settle is NOT satisfied
        /// by a nearby target, and the previous complete composition is kept.
        case rejectedSuperseded
    }

    /// The settle barrier admits only the EXACT final target (time AND frame request). A nearby earlier
    /// or later target is rejected — settle is a barrier, not a latest-wins approximation. The settled
    /// frame is held; settle never auto-resumes playback (no `enterPlaying` is implied by this helper).
    public static func settle(candidate target: ScrubTarget, finalTarget: ScrubTarget) -> SettleOutcome {
        (target == finalTarget) ? .publishExact(target) : .rejectedSuperseded
    }

    /// Settle is always silent and held: resolving the exact final target leaves the transport paused at
    /// that target. This helper makes the "no auto-play" contract explicit and testable — it returns the
    /// held paused time and emits no play/enterPlaying decision.
    public static func settledHoldTime(finalTarget: ScrubTarget) -> ProjectTime {
        finalTarget.time
    }
}
