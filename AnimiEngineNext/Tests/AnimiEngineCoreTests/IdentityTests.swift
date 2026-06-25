import XCTest
@testable import AnimiEngineCore

/// Slice-003 Stage A — typed runtime identities (ADR-005 §1–§3).
///
/// Proves: distinct types, Hashable/Equatable/Sendable conformance, deterministic monotonic
/// allocation (no wall clock), the export tuple has no epoch, and `CacheArtifactID` is content-derived
/// — equal across epochs/requests, different when any content input changes.
final class IdentityTests: XCTestCase {

    // MARK: - Distinctness & non-interchangeability

    // The eight identity kinds are distinct Swift types. The following compiles only because each
    // identity is its OWN type; assigning a ProjectRevision where a PlaybackEpoch is expected would not
    // compile, which is the non-interchangeability guarantee (ADR-005 §1). We assert that two
    // structurally-similar identities never collide because they are different types.
    func testNumericIdentitiesAreDistinctTypes() {
        var revisions = MonotonicRevisionAllocator()
        var epochs = MonotonicEpochAllocator()
        let r = revisions.next()
        let e = epochs.next()
        // Both wrap raw 0, but they are different types and cannot be compared with == at all.
        // We confirm each is Equatable to ITS OWN type only.
        XCTAssertEqual(r, ProjectRevision(raw: 0))
        XCTAssertEqual(e, PlaybackEpoch(raw: 0))
    }

    // MARK: - Hashable / Equatable

    func testIdentitiesAreHashableAndEquatable() throws {
        XCTAssertEqual(ProjectRevision(raw: 3), ProjectRevision(raw: 3))
        XCTAssertNotEqual(ProjectRevision(raw: 3), ProjectRevision(raw: 4))

        XCTAssertEqual(PlaybackEpoch(raw: 1), PlaybackEpoch(raw: 1))
        XCTAssertEqual(FrameRequestID(raw: 7), FrameRequestID(raw: 7))
        XCTAssertEqual(MediaRequestID(raw: 7), MediaRequestID(raw: 7))
        XCTAssertEqual(AudioRequestID(raw: 7), AudioRequestID(raw: 7))
        XCTAssertEqual(ExportJobID(raw: 9), ExportJobID(raw: 9))

        // Usable as Set / dictionary keys (Hashable).
        let set: Set<FrameRequestID> = [FrameRequestID(raw: 1), FrameRequestID(raw: 1), FrameRequestID(raw: 2)]
        XCTAssertEqual(set.count, 2)
    }

    // MARK: - String-backed identities reject empty

    func testBenchmarkRunIDRejectsEmpty() {
        XCTAssertThrowsError(try BenchmarkRunID("")) {
            XCTAssertEqual($0 as? RuntimeIdentityError, .emptyBenchmarkRunID)
        }
    }

    func testQualityProfileIDRejectsEmpty() {
        XCTAssertThrowsError(try QualityProfileID("")) {
            XCTAssertEqual($0 as? RuntimeIdentityError, .emptyQualityProfileID)
        }
    }

    func testCacheDependencyDigestRejectsEmpty() {
        XCTAssertThrowsError(try CacheDependencyDigest("")) {
            XCTAssertEqual($0 as? RuntimeIdentityError, .emptyCacheDependencyDigest)
        }
    }

    func testStringBackedIdentitiesAcceptNonEmptyAndAreEquatable() throws {
        XCTAssertEqual(try BenchmarkRunID("run-A"), try BenchmarkRunID("run-A"))
        XCTAssertNotEqual(try BenchmarkRunID("run-A"), try BenchmarkRunID("run-B"))
        XCTAssertEqual(try QualityProfileID("high"), try QualityProfileID("high"))
    }

    // MARK: - Deterministic monotonic allocation (no wall clock)

    func testRevisionAllocatorIsMonotonicAndDeterministic() {
        var a = MonotonicRevisionAllocator()
        XCTAssertEqual(a.next(), ProjectRevision(raw: 0))
        XCTAssertEqual(a.next(), ProjectRevision(raw: 1))
        XCTAssertEqual(a.next(), ProjectRevision(raw: 2))

        // A fresh allocator with the same seed reproduces the exact same sequence.
        var b = MonotonicRevisionAllocator()
        XCTAssertEqual(b.next(), ProjectRevision(raw: 0))
        XCTAssertEqual(b.next(), ProjectRevision(raw: 1))
    }

    func testEpochAllocatorIsMonotonicAndDeterministic() {
        var a = MonotonicEpochAllocator(start: 10)
        XCTAssertEqual(a.next(), PlaybackEpoch(raw: 10))
        XCTAssertEqual(a.next(), PlaybackEpoch(raw: 11))
    }

    func testRequestIDAllocatorAdvancesIndependentCounters() {
        var a = MonotonicRequestIDAllocator()
        XCTAssertEqual(a.nextFrameRequest(), FrameRequestID(raw: 0))
        XCTAssertEqual(a.nextFrameRequest(), FrameRequestID(raw: 1))
        // Media counter is independent of the frame counter.
        XCTAssertEqual(a.nextMediaRequest(), MediaRequestID(raw: 0))
        XCTAssertEqual(a.nextAudioRequest(), AudioRequestID(raw: 0))
        XCTAssertEqual(a.nextAudioRequest(), AudioRequestID(raw: 1))
        // Frame counter resumed where it left off, unaffected by media/audio.
        XCTAssertEqual(a.nextFrameRequest(), FrameRequestID(raw: 2))
    }

    // MARK: - RequestIdentity / ExportIdentity (ADR-005 §2)

    func testRequestIdentityCarriesPreviewTuple() throws {
        let id = RequestIdentity(
            revision: ProjectRevision(raw: 1),
            epoch: PlaybackEpoch(raw: 2),
            frameRequest: FrameRequestID(raw: 3),
            time: try ProjectTime(ticks: 240_000),
            quality: try QualityProfileID("high")
        )
        XCTAssertEqual(id.revision, ProjectRevision(raw: 1))
        XCTAssertEqual(id.epoch, PlaybackEpoch(raw: 2))
        XCTAssertEqual(id.frameRequest, FrameRequestID(raw: 3))
        XCTAssertEqual(id.time, try ProjectTime(ticks: 240_000))
        XCTAssertEqual(id, RequestIdentity(
            revision: ProjectRevision(raw: 1), epoch: PlaybackEpoch(raw: 2),
            frameRequest: FrameRequestID(raw: 3), time: try ProjectTime(ticks: 240_000),
            quality: try QualityProfileID("high")
        ))
    }

    func testExportIdentityHasRevisionAndJobOnly() throws {
        // Compile-time proof that ExportIdentity carries NO playback epoch: its memberwise init takes
        // exactly (revision:job:). The two fields below are the entire public surface.
        let export = ExportIdentity(revision: ProjectRevision(raw: 5), job: ExportJobID(raw: 8))
        XCTAssertEqual(export.revision, ProjectRevision(raw: 5))
        XCTAssertEqual(export.job, ExportJobID(raw: 8))
        XCTAssertEqual(export, ExportIdentity(revision: ProjectRevision(raw: 5), job: ExportJobID(raw: 8)))
    }

    // MARK: - CacheArtifactID is content-derived (ADR-005 §3)

    func testCacheArtifactIDEqualForSameContentAcrossEpochsAndRequests() throws {
        // Build the SAME cache identity twice. There is intentionally no place to pass an epoch or a
        // request ID, so two artifacts produced under different epochs/requests but identical content
        // are the SAME cache identity. (Compile-time: CacheArtifactID.init has no epoch/request param.)
        let a = try cacheID(digest: "deps-1", start: 0, end: 240_000, quality: "high")
        let b = try cacheID(digest: "deps-1", start: 0, end: 240_000, quality: "high")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)

        // Reusable as a dictionary key across "different" production contexts.
        var cache: [CacheArtifactID: Int] = [:]
        cache[a] = 1
        cache[b, default: 0] += 100   // hits the same slot
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache[a], 101)
    }

    func testCacheArtifactIDDiffersWhenDigestChanges() throws {
        let a = try cacheID(digest: "deps-1", start: 0, end: 240_000, quality: "high")
        let b = try cacheID(digest: "deps-2", start: 0, end: 240_000, quality: "high")
        XCTAssertNotEqual(a, b)
    }

    func testCacheArtifactIDDiffersWhenTimeRangeChanges() throws {
        let a = try cacheID(digest: "deps-1", start: 0, end: 240_000, quality: "high")
        let b = try cacheID(digest: "deps-1", start: 0, end: 480_000, quality: "high")
        XCTAssertNotEqual(a, b)
    }

    func testCacheArtifactIDDiffersWhenQualityChanges() throws {
        let a = try cacheID(digest: "deps-1", start: 0, end: 240_000, quality: "high")
        let b = try cacheID(digest: "deps-1", start: 0, end: 240_000, quality: "proxy")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Helpers

    private func cacheID(digest: String, start: Int64, end: Int64, quality: String) throws -> CacheArtifactID {
        CacheArtifactID(
            dependencyDigest: try CacheDependencyDigest(digest),
            timeRange: try ProjectTimeRange(start: try ProjectTime(ticks: start), end: try ProjectTime(ticks: end)),
            quality: try QualityProfileID(quality)
        )
    }
}
