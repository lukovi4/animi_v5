/// Slice-003 Stage A — content-derived cache identity (ADR-005 §3).
///
/// `CacheArtifactID` identifies a **reusable** cache artifact by its content dependencies only, so an
/// equal artifact remains reusable across different playback epochs and request generations. It is
/// therefore composed strictly of content-derived inputs and **must not** carry `ProjectRevision`,
/// `PlaybackEpoch`, or any frame/media/audio request ID — those prevent stale publication; they do not
/// make equal content different (ADR-005 §3).
///
/// Tech-lead decision for this slice: the semantic dependency descriptor required by ADR-005 §3
/// (dependency hash, render-semantics version, color configuration) is carried as an **opaque,
/// caller-supplied** `CacheDependencyDigest`. This slice does NOT invent render-semantics or color
/// concepts; the caller folds those into the digest in a later slice.

/// An opaque, caller-supplied content-dependency digest. It stands in for the dependency hash plus the
/// render-semantics version and color configuration named by ADR-005 §3, none of which this slice
/// defines. Non-empty.
public struct CacheDependencyDigest: Hashable, Sendable {
    public let raw: String
    public init(_ raw: String) throws {
        guard !raw.isEmpty else { throw RuntimeIdentityError.emptyCacheDependencyDigest }
        self.raw = raw
    }
}

/// A reusable, content-derived cache-artifact identity (ADR-005 §3). Two artifacts are the same cache
/// identity iff their `dependencyDigest`, `timeRange`, and `quality` are equal — independent of which
/// epoch or request produced them.
///
/// `ProjectTimeRange` is `Equatable, Sendable` but not `Hashable`, so `Hashable`/`Equatable` are
/// implemented by hand over the content components (both `ProjectTime` endpoints are `Hashable`). This
/// keeps the identity content-derived without widening the `ProjectTimeRange` API.
public struct CacheArtifactID: Hashable, Sendable {
    public let dependencyDigest: CacheDependencyDigest
    public let timeRange: ProjectTimeRange
    public let quality: QualityProfileID

    public init(dependencyDigest: CacheDependencyDigest, timeRange: ProjectTimeRange, quality: QualityProfileID) {
        self.dependencyDigest = dependencyDigest
        self.timeRange = timeRange
        self.quality = quality
    }

    public static func == (lhs: CacheArtifactID, rhs: CacheArtifactID) -> Bool {
        lhs.dependencyDigest == rhs.dependencyDigest
            && lhs.timeRange.start == rhs.timeRange.start
            && lhs.timeRange.end == rhs.timeRange.end
            && lhs.quality == rhs.quality
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(dependencyDigest)
        hasher.combine(timeRange.start)
        hasher.combine(timeRange.end)
        hasher.combine(quality)
    }
}
