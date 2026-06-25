/// Slice-003 Stage A — typed runtime identities (ADR-005 §1–§2).
///
/// Each identity is a **distinct** value type. They are deliberately NOT interchangeable and NOT
/// public aliases of a shared raw integer: a `ProjectRevision` cannot be passed where a
/// `PlaybackEpoch` is expected, even though both wrap an `Int64` internally. The raw storage is
/// `internal` so it can be minted by the deterministic allocators in `IdentityAllocators.swift`
/// without leaking a raw-integer public surface (ADR-005 §1).
///
/// No `Date()`, `UUID()`, randomness, or wall clock is used anywhere: all numeric identities are
/// minted by monotonic allocators; the string-backed identities are caller-supplied.

// MARK: - Monotonic numeric identities

/// One immutable semantic project snapshot. Any edit that can change evaluation, media selection,
/// trim, placement, audio, text, transition, output, or export result mints a new value (ADR-005 §1).
public struct ProjectRevision: Hashable, Sendable {
    let raw: Int64
    init(raw: Int64) { self.raw = raw }
}

/// One uninterrupted transport interpretation. Play, pause, seek, scrub start, scrub settle,
/// project-revision change, interruption, route change, and recovery each mint a new value before any
/// new work is admitted (ADR-005 §1, §4).
public struct PlaybackEpoch: Hashable, Sendable {
    let raw: Int64
    init(raw: Int64) { self.raw = raw }
}

/// One requested complete composed frame at one exact project time (ADR-005 §1).
public struct FrameRequestID: Hashable, Sendable {
    let raw: Int64
    init(raw: Int64) { self.raw = raw }
}

/// One timestamped request to one visual media source (ADR-005 §1).
public struct MediaRequestID: Hashable, Sendable {
    let raw: Int64
    init(raw: Int64) { self.raw = raw }
}

/// One requested PCM source range for one audio source (ADR-005 §1).
public struct AudioRequestID: Hashable, Sendable {
    let raw: Int64
    init(raw: Int64) { self.raw = raw }
}

/// One isolated offline export operation (ADR-005 §1).
public struct ExportJobID: Hashable, Sendable {
    let raw: Int64
    init(raw: Int64) { self.raw = raw }
}

// MARK: - String-backed identities

/// One reproducible evidence run, as defined by ADR-014 (ADR-005 §1). Caller-supplied, non-empty.
public struct BenchmarkRunID: Hashable, Sendable {
    public let raw: String
    public init(_ raw: String) throws {
        guard !raw.isEmpty else { throw RuntimeIdentityError.emptyBenchmarkRunID }
        self.raw = raw
    }
}

/// A preview quality profile selector (spatial quality / proxy level). Caller-supplied, non-empty.
/// It is part of cache identity (ADR-005 §3) but never makes equal content different on its own.
public struct QualityProfileID: Hashable, Sendable {
    public let raw: String
    public init(_ raw: String) throws {
        guard !raw.isEmpty else { throw RuntimeIdentityError.emptyQualityProfileID }
        self.raw = raw
    }
}

// MARK: - Identity tuples (ADR-005 §2)

/// The identity carried by every asynchronous **preview** request and completion (ADR-005 §2). A
/// completion is admissible only when this tuple still matches the scheduler's current state; the
/// admission logic itself is Stage E, not Stage A.
public struct RequestIdentity: Hashable, Sendable {
    public let revision: ProjectRevision
    public let epoch: PlaybackEpoch
    public let frameRequest: FrameRequestID
    public let time: ProjectTime
    public let quality: QualityProfileID

    public init(
        revision: ProjectRevision,
        epoch: PlaybackEpoch,
        frameRequest: FrameRequestID,
        time: ProjectTime,
        quality: QualityProfileID
    ) {
        self.revision = revision
        self.epoch = epoch
        self.frameRequest = frameRequest
        self.time = time
        self.quality = quality
    }
}

/// The identity carried by **export** work (ADR-005 §2). Export carries `ProjectRevision + ExportJobID`
/// and **never** reuses a preview `PlaybackEpoch` — there is intentionally no epoch field here.
public struct ExportIdentity: Hashable, Sendable {
    public let revision: ProjectRevision
    public let job: ExportJobID

    public init(revision: ProjectRevision, job: ExportJobID) {
        self.revision = revision
        self.job = job
    }
}

// MARK: - Errors

public enum RuntimeIdentityError: Error, Equatable, Sendable {
    case emptyBenchmarkRunID
    case emptyQualityProfileID
    case emptyCacheDependencyDigest
    case emptyTransportFailureReason
    case emptyComposedFrameHandle
}
