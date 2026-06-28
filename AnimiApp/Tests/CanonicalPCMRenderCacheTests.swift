import XCTest
import AnimiEngineCore
@testable import AnimiApp

/// Stage 1 — `CanonicalPCMRenderCache` (+ key/chunk) deterministic behaviour.
///
/// Eviction policy under test: **LRU** (see `CanonicalPCMRenderCache` doc). Coalescing, invalidation
/// (including the critical stale-in-flight case), and "failures are never cached" are all covered.
/// All fixtures are decode-free: public allocators + a deterministic fake renderer (no AVFoundation,
/// no real media, no sleeping in the hot paths — the coalescing test gates with a continuation).
final class CanonicalPCMRenderCacheTests: XCTestCase {

    // MARK: - Fixtures

    /// One bounded sample range of `samples` 48 kHz samples starting at `startTicks`-derived sample 0.
    private static func range(samples: Int64) throws -> AudioSampleRange {
        try AudioSampleRange.from(projectTicks:
            ProjectTimeRange(start: .zero,
                             end: try ProjectTime(ticks: samples * AudioSampleGrid.ticksPerSample)))
    }

    private static func revision(_ raw: Int64) -> ProjectRevision {
        var a = MonotonicRevisionAllocator(start: raw); return a.next()
    }
    private static func epoch(_ raw: Int64) -> PlaybackEpoch {
        var a = MonotonicEpochAllocator(start: raw); return a.next()
    }

    private static func key(
        revision rev: Int64 = 1, epoch ep: Int64 = 1,
        planIdentity: String = "plan-A", samples: Int64 = 8
    ) throws -> CanonicalPCMRenderKey {
        try CanonicalPCMRenderKey(
            revision: revision(rev), epoch: epoch(ep),
            planIdentity: planIdentity, range: try range(samples: samples))
    }

    /// A `PreviewMixSource` whose buffer covers exactly `range`.
    private static func source(range: AudioSampleRange, identity: String = "stream-0") throws -> PreviewMixSource {
        var reqAlloc = MonotonicRequestIDAllocator()
        let buffer = try PreparedAudioBuffer(
            revision: revision(1), epoch: epoch(1),
            request: reqAlloc.nextAudioRequest(),
            sourceID: try AudioSourceID("s0"),
            chunkRange: range,
            streamIdentity: try AudioStreamIdentity(identity),
            sourceSampleRate: 48_000, channelLayout: .mono,
            isMuted: false, gain: .unity,
            payload: try PreparedAudioPayloadHandle(identifier: "fixture:\(identity)"))
        return PreviewMixSource(buffer: buffer, samples: Array(repeating: 0.25, count: Int(range.sampleCount)))
    }

    /// Prefix used to embed the requested `planIdentity` into the plan's clip id, so a faithful renderer can
    /// recover the EXACT requested key from `request` alone (production requests carry no `planIdentity`
    /// field). The renderers below echo this — they never invent a fixed identity.
    private static let clipPrefix = "clip-plan:"

    /// A non-empty `AudioPlan` matching `range`, carrying `planIdentity` inside the segment clip id so the
    /// renderer can reconstruct the requested cache key (see `requestedKey(from:)`).
    private static func plan(range: AudioSampleRange, planIdentity: String) throws -> AudioPlan {
        let seg = AudioSegmentPlan(
            clipID: try AudioClipID("\(clipPrefix)\(planIdentity)"),
            sourceID: try AudioSourceID("s0"), trackID: try AudioTrackID("t0"),
            role: .music, destinationSamples: range, sourceStart: .zero,
            sourceEnd: try RationalSourceTime(numerator: 1, denominator: 1),
            effectiveTrim: try RationalSourceRange(start: .zero, end: try RationalSourceTime(numerator: 1, denominator: 1)),
            isMuted: false, gain: .unity, sourceSampleRate: 48_000, channelLayout: .mono,
            streamIdentity: try AudioStreamIdentity("stream-0"), sceneID: nil)
        return AudioPlan(sampleInterval: range, segments: [seg])
    }

    private static func request(for key: CanonicalPCMRenderKey) throws -> CanonicalAudioRenderRequest {
        CanonicalAudioRenderRequest(
            plan: try plan(range: key.range, planIdentity: key.planIdentity),
            revision: key.revision, epoch: key.epoch,
            anchor: PreviewAudioScheduleAnchor(
                revision: key.revision, epoch: key.epoch, projectSample: 0, outputSampleTime: 0),
            range: key.range,
            resolvedSourcesByID: [:])
    }

    /// Reconstruct the EXACT requested key from a request: revision/epoch/range from the request, and
    /// `planIdentity` recovered from the embedded clip id. A faithful renderer uses this so `chunk.key ==
    /// requestedKey`.
    private static func requestedKey(from request: CanonicalAudioRenderRequest) throws -> CanonicalPCMRenderKey {
        let raw = request.plan.segments.first?.clipID.raw ?? ""
        let planIdentity = raw.hasPrefix(clipPrefix) ? String(raw.dropFirst(clipPrefix.count)) : raw
        return try CanonicalPCMRenderKey(
            revision: request.revision, epoch: request.epoch,
            planIdentity: planIdentity, range: request.range)
    }

    // MARK: - Fake renderers (actors — no NSLock-in-async; `calls` is actor-isolated, read via `await`)

    /// Counts calls; echoes the EXACT requested key (recovered from the request) so `chunk.key == requestedKey`.
    private actor CountingRenderer: CanonicalPCMRenderer {
        private(set) var calls = 0
        func render(_ request: CanonicalAudioRenderRequest) async throws -> CanonicalPCMChunk {
            calls += 1
            let key = try CanonicalPCMRenderCacheTests.requestedKey(from: request)
            let src = try CanonicalPCMRenderCacheTests.source(range: key.range)
            return try CanonicalPCMChunk(key: key, sources: [src])
        }
    }

    /// Throws on the first N calls, then succeeds (echoing the requested key). Counts calls.
    private actor FlakyRenderer: CanonicalPCMRenderer {
        private(set) var calls = 0
        private let failFirst: Int
        init(failFirst: Int) { self.failFirst = failFirst }
        func render(_ request: CanonicalAudioRenderRequest) async throws -> CanonicalPCMChunk {
            calls += 1
            if calls <= failFirst {
                throw AppRealtimeAudioIntegrationError.pcmRenderFailed(reason: "induced failure #\(calls)")
            }
            let key = try CanonicalPCMRenderCacheTests.requestedKey(from: request)
            let src = try CanonicalPCMRenderCacheTests.source(range: key.range)
            return try CanonicalPCMChunk(key: key, sources: [src])
        }
    }

    /// Returns a chunk whose key DELIBERATELY mismatches the requested key (different planIdentity), to drive
    /// the fail-closed identity gate. Counts calls.
    private actor MismatchingRenderer: CanonicalPCMRenderer {
        private(set) var calls = 0
        func render(_ request: CanonicalAudioRenderRequest) async throws -> CanonicalPCMChunk {
            calls += 1
            let requested = try CanonicalPCMRenderCacheTests.requestedKey(from: request)
            // Build a chunk for a DIFFERENT identity (wrong planIdentity) than requested.
            let wrongKey = try CanonicalPCMRenderKey(
                revision: requested.revision, epoch: requested.epoch,
                planIdentity: "WRONG-\(requested.planIdentity)", range: requested.range)
            let src = try CanonicalPCMRenderCacheTests.source(range: wrongKey.range)
            return try CanonicalPCMChunk(key: wrongKey, sources: [src])
        }
    }

    /// Blocks inside `render` on a gate until `release()` is called, so renders overlap deterministically
    /// (no sleeping). `release()` is a LATCH: once opened it stays open, so a later render is not parked
    /// (lets test 13 do a second render without re-coordinating the gate). `waitUntilEntered()` resumes once
    /// the next render enters. Echoes the requested key. Counts calls. As an actor, all state is async-safe.
    private actor GatedRenderer: CanonicalPCMRenderer {
        private(set) var calls = 0
        private var parked: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false
        private var enteredWaiter: CheckedContinuation<Void, Never>?

        /// Await until the next render enters (parking if the gate is closed). Re-arms each call.
        func waitUntilEntered() async {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                enteredWaiter = cont
            }
        }

        /// Open the gate (latch) and resume everything currently parked.
        func release() {
            isOpen = true
            let conts = parked; parked.removeAll()
            for c in conts { c.resume() }
        }

        func render(_ request: CanonicalAudioRenderRequest) async throws -> CanonicalPCMChunk {
            calls += 1
            let entered = enteredWaiter; enteredWaiter = nil
            entered?.resume()   // signal "a render has entered"

            if !isOpen {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    parked.append(cont)
                }
            }
            let key = try CanonicalPCMRenderCacheTests.requestedKey(from: request)
            let src = try CanonicalPCMRenderCacheTests.source(range: key.range)
            return try CanonicalPCMChunk(key: key, sources: [src])
        }
    }

    // MARK: - 1. Key rejects empty planIdentity

    func testKeyRejectsEmptyPlanIdentity() throws {
        XCTAssertThrowsError(try CanonicalPCMRenderKey(
            revision: Self.revision(1), epoch: Self.epoch(1),
            planIdentity: "", range: try Self.range(samples: 8))) { error in
            guard case AppRealtimeAudioIntegrationError.invalidPCMRenderPlanIdentity = error else {
                return XCTFail("expected .invalidPCMRenderPlanIdentity, got \(error)")
            }
        }
    }

    // MARK: - 2. Key equality uses revision + epoch + planIdentity + range

    func testKeyEqualityUsesRevisionEpochPlanIdentityAndRange() throws {
        let base = try Self.key()
        let same = try Self.key()
        XCTAssertEqual(base, same)
        XCTAssertEqual(base.hashValue, same.hashValue)

        XCTAssertNotEqual(base, try Self.key(revision: 2))
        XCTAssertNotEqual(base, try Self.key(epoch: 2))
        XCTAssertNotEqual(base, try Self.key(planIdentity: "plan-B"))
        XCTAssertNotEqual(base, try Self.key(samples: 16))
    }

    // MARK: - 3. Chunk rejects a source outside the exact key range

    func testChunkRejectsSourceOutsideExactRange() throws {
        let key = try Self.key(samples: 8)
        let wrong = try Self.source(range: try Self.range(samples: 16))   // 16 != 8
        XCTAssertThrowsError(try CanonicalPCMChunk(key: key, sources: [wrong])) { error in
            guard case AppRealtimeAudioIntegrationError.pcmRenderFailed = error else {
                return XCTFail("expected .pcmRenderFailed, got \(error)")
            }
        }
    }

    // MARK: - 4. Chunk accepts exact-range sources

    func testChunkAcceptsExactRangeSources() throws {
        let key = try Self.key(samples: 8)
        let src = try Self.source(range: key.range)
        let chunk = try CanonicalPCMChunk(key: key, sources: [src])
        XCTAssertEqual(chunk.range, key.range)
        XCTAssertEqual(chunk.sources.count, 1)
        XCTAssertEqual(chunk.sources[0].buffer.chunkRange, key.range)
    }

    // MARK: - 5. Cache rejects invalid capacity

    func testCacheRejectsInvalidCapacity() throws {
        let renderer = CountingRenderer()
        XCTAssertThrowsError(try CanonicalPCMRenderCache.make(capacity: 0, renderer: renderer)) { error in
            guard case AppRealtimeAudioIntegrationError.invalidPCMRenderCacheCapacity(0) = error else {
                return XCTFail("expected .invalidPCMRenderCacheCapacity(0), got \(error)")
            }
        }
        XCTAssertThrowsError(try CanonicalPCMRenderCache.make(capacity: -3, renderer: renderer)) { error in
            guard case AppRealtimeAudioIntegrationError.invalidPCMRenderCacheCapacity(-3) = error else {
                return XCTFail("expected .invalidPCMRenderCacheCapacity(-3), got \(error)")
            }
        }
    }

    // MARK: - 6. Miss renders + stores; second call is a hit

    func testChunkMissRendersStoresAndReturns() async throws {
        let renderer = CountingRenderer()
        let cache = try CanonicalPCMRenderCache.make(capacity: 4, renderer: renderer)
        let key = try Self.key()
        let req = try Self.request(for: key)

        let first = try await cache.chunk(for: req, key: key)
        XCTAssertEqual(first.range, key.range)
        XCTAssertEqual(first.key, key, "rendered chunk identity matches requested key")
        var calls = await renderer.calls
        XCTAssertEqual(calls, 1)
        let stored = await cache.count
        XCTAssertEqual(stored, 1)

        let second = try await cache.chunk(for: req, key: key)
        XCTAssertEqual(second.range, key.range)
        calls = await renderer.calls
        XCTAssertEqual(calls, 1, "second call must be a cache hit (no extra render)")
    }

    // MARK: - 7. Every identity field affects cache identity (all miss)

    func testDifferentEpochRevisionRangePlanIdentityMiss() async throws {
        // Each variant request carries its OWN planIdentity (embedded in the plan), and the renderer echoes
        // the exact requested key — so `chunk.key == requestedKey` for every variant (no reliance on the
        // chunk's internal key being independent of the cache key; that masked the P0 bug).
        let renderer = CountingRenderer()
        let cache = try CanonicalPCMRenderCache.make(capacity: 16, renderer: renderer)

        let variants = [
            try Self.key(),
            try Self.key(revision: 2),
            try Self.key(epoch: 2),
            try Self.key(planIdentity: "plan-B"),
            try Self.key(samples: 16),
        ]
        for (i, k) in variants.enumerated() {
            let chunk = try await cache.chunk(for: try Self.request(for: k), key: k)
            XCTAssertEqual(chunk.key, k, "rendered chunk identity matches requested key for variant \(i)")
            let calls = await renderer.calls
            XCTAssertEqual(calls, i + 1, "each distinct key must miss and render once")
        }
        let stored = await cache.count
        XCTAssertEqual(stored, variants.count)
    }

    // MARK: - 8. invalidate(revision:) removes matching chunks only

    func testInvalidateRevisionRemovesMatchingChunks() async throws {
        let renderer = CountingRenderer()
        let cache = try CanonicalPCMRenderCache.make(capacity: 8, renderer: renderer)
        let kRev1 = try Self.key(revision: 1)
        let kRev2 = try Self.key(revision: 2)
        _ = try await cache.chunk(for: try Self.request(for: kRev1), key: kRev1)
        _ = try await cache.chunk(for: try Self.request(for: kRev2), key: kRev2)
        var calls = await renderer.calls
        XCTAssertEqual(calls, 2)

        await cache.invalidate(revision: kRev1.revision)

        // rev1 now misses (re-renders); rev2 still a hit.
        _ = try await cache.chunk(for: try Self.request(for: kRev1), key: kRev1)
        calls = await renderer.calls
        XCTAssertEqual(calls, 3, "invalidated revision must re-render")
        _ = try await cache.chunk(for: try Self.request(for: kRev2), key: kRev2)
        calls = await renderer.calls
        XCTAssertEqual(calls, 3, "other revision must remain cached")
    }

    // MARK: - 9. invalidate(epoch:) removes matching chunks only

    func testInvalidateEpochRemovesMatchingChunks() async throws {
        let renderer = CountingRenderer()
        let cache = try CanonicalPCMRenderCache.make(capacity: 8, renderer: renderer)
        let kEp1 = try Self.key(epoch: 1)
        let kEp2 = try Self.key(epoch: 2)
        _ = try await cache.chunk(for: try Self.request(for: kEp1), key: kEp1)
        _ = try await cache.chunk(for: try Self.request(for: kEp2), key: kEp2)
        var calls = await renderer.calls
        XCTAssertEqual(calls, 2)

        await cache.invalidate(epoch: kEp1.epoch)

        _ = try await cache.chunk(for: try Self.request(for: kEp1), key: kEp1)
        calls = await renderer.calls
        XCTAssertEqual(calls, 3, "invalidated epoch must re-render")
        _ = try await cache.chunk(for: try Self.request(for: kEp2), key: kEp2)
        calls = await renderer.calls
        XCTAssertEqual(calls, 3, "other epoch must remain cached")
    }

    // MARK: - 10. Deterministic capacity eviction (LRU)

    /// POLICY: **LRU**. Capacity 2. Insert A, B (both stored). Touch A (hit → A most-recent). Insert C →
    /// over capacity → evict least-recently-used = B. So A and C remain; B re-renders.
    func testCapacityEvictionDeterministic() async throws {
        let renderer = CountingRenderer()
        let cache = try CanonicalPCMRenderCache.make(capacity: 2, renderer: renderer)
        let a = try Self.key(planIdentity: "A")
        let b = try Self.key(planIdentity: "B")
        let c = try Self.key(planIdentity: "C")

        _ = try await cache.chunk(for: try Self.request(for: a), key: a)   // store A
        _ = try await cache.chunk(for: try Self.request(for: b), key: b)   // store B
        _ = try await cache.chunk(for: try Self.request(for: a), key: a)   // HIT A → A most-recent
        var calls = await renderer.calls
        XCTAssertEqual(calls, 2, "A hit, no render")

        _ = try await cache.chunk(for: try Self.request(for: c), key: c)   // store C → evict LRU = B
        calls = await renderer.calls
        XCTAssertEqual(calls, 3)
        let stored = await cache.count
        XCTAssertEqual(stored, 2)

        // A is still cached (hit, no render).
        _ = try await cache.chunk(for: try Self.request(for: a), key: a)
        calls = await renderer.calls
        XCTAssertEqual(calls, 3, "A must still be cached")
        // C is still cached.
        _ = try await cache.chunk(for: try Self.request(for: c), key: c)
        calls = await renderer.calls
        XCTAssertEqual(calls, 3, "C must still be cached")
        // B was evicted → re-renders.
        _ = try await cache.chunk(for: try Self.request(for: b), key: b)
        calls = await renderer.calls
        XCTAssertEqual(calls, 4, "B (LRU) must have been evicted")
    }

    // MARK: - 11. Concurrent same-key coalesces to one render

    func testConcurrentSameKeyCoalescesRender() async throws {
        let renderer = GatedRenderer()
        let cache = try CanonicalPCMRenderCache.make(capacity: 4, renderer: renderer)
        let key = try Self.key()
        let req = try Self.request(for: key)

        async let first = cache.chunk(for: req, key: key)
        // Wait until the first render has actually entered the renderer (so the in-flight entry exists)…
        await renderer.waitUntilEntered()
        // …then start the second concurrent request for the same key; it must coalesce onto the in-flight task.
        async let second = cache.chunk(for: req, key: key)

        // Give the second request a chance to reach the cache + coalesce, then release the gated render.
        await Task.yield()
        await renderer.release()

        let c1 = try await first
        let c2 = try await second
        let calls = await renderer.calls
        XCTAssertEqual(calls, 1, "concurrent same-key requests must coalesce to ONE render")
        XCTAssertEqual(c1.key, key)
        XCTAssertEqual(c2.key, key)
        XCTAssertEqual(c1.range, c2.range)
    }

    // MARK: - 12. Renderer failure is not cached

    func testRendererFailureIsNotCached() async throws {
        let renderer = FlakyRenderer(failFirst: 1)
        let cache = try CanonicalPCMRenderCache.make(capacity: 4, renderer: renderer)
        let key = try Self.key()
        let req = try Self.request(for: key)

        do {
            _ = try await cache.chunk(for: req, key: key)
            XCTFail("first render must throw")
        } catch let error as AppRealtimeAudioIntegrationError {
            guard case .pcmRenderFailed = error else { return XCTFail("expected .pcmRenderFailed, got \(error)") }
        }
        var stored = await cache.count
        XCTAssertEqual(stored, 0, "a failed render must NOT be cached")

        // Second call succeeds and stores.
        let chunk = try await cache.chunk(for: req, key: key)
        XCTAssertEqual(chunk.range, key.range)
        let calls = await renderer.calls
        XCTAssertEqual(calls, 2, "renderer called twice (fail then success)")
        stored = await cache.count
        XCTAssertEqual(stored, 1, "success stored only after success")
    }

    // MARK: - 13. CRITICAL: invalidate while in-flight drops the stale completion

    func testInvalidateWhileRenderInFlightDropsStaleCompletion() async throws {
        let renderer = GatedRenderer()
        let cache = try CanonicalPCMRenderCache.make(capacity: 4, renderer: renderer)
        let key = try Self.key()
        let req = try Self.request(for: key)

        // Start a render and wait until it is in-flight inside the renderer (parked on the gate).
        async let inflight = cache.chunk(for: req, key: key)
        await renderer.waitUntilEntered()

        // Invalidate the matching epoch+revision BEFORE the renderer completes → drops the in-flight entry.
        await cache.invalidate(epoch: key.epoch)
        await cache.invalidate(revision: key.revision)

        // Let the (now stale) render finish. Its caller still gets the value, but the cache must store nothing.
        await renderer.release()
        _ = try await inflight
        let storedAfter = await cache.count
        XCTAssertEqual(storedAfter, 0, "stale in-flight completion after invalidation must NOT be stored")

        // Next call must render AGAIN (no stale chunk returned). The gate latch is already open from the
        // release() above, so this second render runs straight through without re-coordinating the gate.
        let again = try await cache.chunk(for: req, key: key)
        XCTAssertEqual(again.range, key.range)
        let calls = await renderer.calls
        XCTAssertEqual(calls, 2, "post-invalidation call must render again, not return stale chunk")
    }

    // MARK: - 14. Prewarm stores on success

    func testPrewarmStoresOnSuccess() async throws {
        let renderer = CountingRenderer()
        let cache = try CanonicalPCMRenderCache.make(capacity: 4, renderer: renderer)
        let key = try Self.key()
        let req = try Self.request(for: key)

        await cache.prewarm(req, key: key)
        var calls = await renderer.calls
        XCTAssertEqual(calls, 1)
        let stored = await cache.count
        XCTAssertEqual(stored, 1, "prewarm must store on success")

        let chunk = try await cache.chunk(for: req, key: key)
        XCTAssertEqual(chunk.range, key.range)
        calls = await renderer.calls
        XCTAssertEqual(calls, 1, "chunk after prewarm must be a cache hit (no extra render)")
    }

    // MARK: - 15. Prewarm does not store on failure

    func testPrewarmDoesNotStoreFailure() async throws {
        let renderer = FlakyRenderer(failFirst: 1)
        let cache = try CanonicalPCMRenderCache.make(capacity: 4, renderer: renderer)
        let key = try Self.key()
        let req = try Self.request(for: key)

        await cache.prewarm(req, key: key)   // fails internally, must not throw, must not store
        var calls = await renderer.calls
        XCTAssertEqual(calls, 1)
        let stored = await cache.count
        XCTAssertEqual(stored, 0, "prewarm must NOT store a failed render")

        // Later chunk call renders again (and now succeeds).
        let chunk = try await cache.chunk(for: req, key: key)
        XCTAssertEqual(chunk.range, key.range)
        calls = await renderer.calls
        XCTAssertEqual(calls, 2, "chunk after failed prewarm must render again")
    }

    // MARK: - 16. P0 REGRESSION: a renderer returning a mismatched-identity chunk fails closed (not cached)

    func testRendererReturningMismatchedKeyFailsClosedAndIsNotCached() async throws {
        // First a renderer that ALWAYS returns a chunk for the wrong key.
        let badRenderer = MismatchingRenderer()
        let cache = try CanonicalPCMRenderCache.make(capacity: 4, renderer: badRenderer)
        let key = try Self.key(planIdentity: "plan-A")
        let req = try Self.request(for: key)

        do {
            _ = try await cache.chunk(for: req, key: key)
            XCTFail("a chunk whose key != requested key must fail closed")
        } catch let error as AppRealtimeAudioIntegrationError {
            guard case .pcmRenderFailed = error else {
                return XCTFail("expected .pcmRenderFailed for mismatched chunk key, got \(error)")
            }
        }
        let badCalls = await badRenderer.calls
        XCTAssertEqual(badCalls, 1, "renderer was invoked")
        let storedAfterMismatch = await cache.count
        XCTAssertEqual(storedAfterMismatch, 0, "a mismatched-identity chunk must NOT be cached")

        // A later CORRECT render for the same key (faithful renderer) renders again and stores successfully.
        let goodRenderer = CountingRenderer()
        let goodCache = try CanonicalPCMRenderCache.make(capacity: 4, renderer: goodRenderer)
        let chunk = try await goodCache.chunk(for: req, key: key)
        XCTAssertEqual(chunk.key, key, "faithful render stores the chunk under the requested key")
        let goodStored = await goodCache.count
        XCTAssertEqual(goodStored, 1)
        let goodCalls = await goodRenderer.calls
        XCTAssertEqual(goodCalls, 1, "correct render happens once and is cached")
    }
}
