import XCTest
import AnimiEngineCore
@testable import AnimiApp

/// Slice-005 Stage 2 — `CachedCanonicalAudioRenderPipeline`: routes an evaluated `AudioPlan` through the
/// deterministic `CanonicalPCMRenderCache` (NO real decode). Covers cache hit/miss, empty-plan silence,
/// fail-closed errors, the mismatched-chunk-key gate, and the deterministic plan-identity contract.
///
/// All fixtures are decode-free: public allocators + actor fake renderers that echo the key the PIPELINE
/// computes (`CanonicalPCMRenderKey` from revision/epoch/`CanonicalAudioPlanIdentity`/range), so the cache's
/// `chunk.key == requestedKey` gate is satisfied on the happy path.
final class CachedCanonicalAudioRenderPipelineTests: XCTestCase {

    // MARK: - Fixtures

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

    /// A `PreviewMixSource` covering exactly `range`.
    private static func source(range: AudioSampleRange, identity: String = "stream-0", fill: Float32 = 0.25) throws -> PreviewMixSource {
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
        return PreviewMixSource(buffer: buffer, samples: Array(repeating: fill, count: Int(range.sampleCount)))
    }

    /// One music segment over `range` with a controllable `clipID` (so we can vary plan content).
    private static func segment(range: AudioSampleRange, clip: String = "c0", muted: Bool = false) throws -> AudioSegmentPlan {
        AudioSegmentPlan(
            clipID: try AudioClipID(clip), sourceID: try AudioSourceID("s0"), trackID: try AudioTrackID("t0"),
            role: .music, destinationSamples: range, sourceStart: .zero,
            sourceEnd: try RationalSourceTime(numerator: 1, denominator: 1),
            effectiveTrim: try RationalSourceRange(start: .zero, end: try RationalSourceTime(numerator: 1, denominator: 1)),
            isMuted: muted, gain: .unity, sourceSampleRate: 48_000, channelLayout: .mono,
            streamIdentity: try AudioStreamIdentity("stream-0"), sceneID: nil)
    }

    private static func plan(range: AudioSampleRange, clip: String = "c0", muted: Bool = false) throws -> AudioPlan {
        AudioPlan(sampleInterval: range, segments: [try segment(range: range, clip: clip, muted: muted)])
    }

    /// A single-segment plan with explicit `clip`/`source` ids (used by the collision regression tests).
    private static func planWithIDs(range: AudioSampleRange, clip: String, source: String) throws -> AudioPlan {
        let seg = AudioSegmentPlan(
            clipID: try AudioClipID(clip), sourceID: try AudioSourceID(source), trackID: try AudioTrackID("t0"),
            role: .music, destinationSamples: range, sourceStart: .zero,
            sourceEnd: try RationalSourceTime(numerator: 1, denominator: 1),
            effectiveTrim: try RationalSourceRange(start: .zero, end: try RationalSourceTime(numerator: 1, denominator: 1)),
            isMuted: false, gain: .unity, sourceSampleRate: 48_000, channelLayout: .mono,
            streamIdentity: try AudioStreamIdentity("stream-0"), sceneID: nil)
        return AudioPlan(sampleInterval: range, segments: [seg])
    }

    private static func emptyPlan(range: AudioSampleRange) -> AudioPlan {
        AudioPlan(sampleInterval: range, segments: [])
    }

    private static func request(
        revision rev: Int64 = 1, epoch ep: Int64 = 1, samples: Int64 = 8,
        clip: String = "c0", muted: Bool = false, empty: Bool = false
    ) throws -> CanonicalAudioRenderRequest {
        let r = try range(samples: samples)
        let p = empty ? emptyPlan(range: r) : try plan(range: r, clip: clip, muted: muted)
        return CanonicalAudioRenderRequest(
            plan: p, revision: revision(rev), epoch: epoch(ep),
            anchor: PreviewAudioScheduleAnchor(
                revision: revision(rev), epoch: epoch(ep), projectSample: 0, outputSampleTime: 0),
            range: r, resolvedSourcesByID: [:])
    }

    /// The EXACT key the pipeline will build for `request` (revision/epoch/range + deterministic identity).
    private static func pipelineKey(for request: CanonicalAudioRenderRequest) throws -> CanonicalPCMRenderKey {
        try CanonicalPCMRenderKey(
            revision: request.revision, epoch: request.epoch,
            planIdentity: CanonicalAudioPlanIdentity.string(for: request.plan),
            range: request.range)
    }

    // MARK: - Fake renderers (actors — async-safe; echo the pipeline's key)

    /// Echoes the key the PIPELINE computes (same identity), so the cache identity gate passes. Counts calls.
    private actor EchoRenderer: CanonicalPCMRenderer {
        private(set) var calls = 0
        func render(_ request: CanonicalAudioRenderRequest) async throws -> CanonicalPCMChunk {
            calls += 1
            let key = try CachedCanonicalAudioRenderPipelineTests.pipelineKey(for: request)
            let src = try CachedCanonicalAudioRenderPipelineTests.source(range: key.range)
            return try CanonicalPCMChunk(key: key, sources: [src])
        }
    }

    /// Throws on the first N calls, then echoes the pipeline key. Counts calls.
    private actor FlakyRenderer: CanonicalPCMRenderer {
        private(set) var calls = 0
        private let failFirst: Int
        init(failFirst: Int) { self.failFirst = failFirst }
        func render(_ request: CanonicalAudioRenderRequest) async throws -> CanonicalPCMChunk {
            calls += 1
            if calls <= failFirst {
                throw AppRealtimeAudioIntegrationError.pcmRenderFailed(reason: "induced #\(calls)")
            }
            let key = try CachedCanonicalAudioRenderPipelineTests.pipelineKey(for: request)
            let src = try CachedCanonicalAudioRenderPipelineTests.source(range: key.range)
            return try CanonicalPCMChunk(key: key, sources: [src])
        }
    }

    /// Returns a chunk for a DIFFERENT key (wrong planIdentity) than the pipeline requested. Counts calls.
    private actor MismatchingRenderer: CanonicalPCMRenderer {
        private(set) var calls = 0
        func render(_ request: CanonicalAudioRenderRequest) async throws -> CanonicalPCMChunk {
            calls += 1
            let requested = try CachedCanonicalAudioRenderPipelineTests.pipelineKey(for: request)
            let wrong = try CanonicalPCMRenderKey(
                revision: requested.revision, epoch: requested.epoch,
                planIdentity: "WRONG-\(requested.planIdentity)", range: requested.range)
            let src = try CachedCanonicalAudioRenderPipelineTests.source(range: wrong.range)
            return try CanonicalPCMChunk(key: wrong, sources: [src])
        }
    }

    /// Never invoked in the empty-plan test — its invocation would fail the test.
    private actor NeverRenderer: CanonicalPCMRenderer {
        private(set) var calls = 0
        func render(_ request: CanonicalAudioRenderRequest) async throws -> CanonicalPCMChunk {
            calls += 1
            throw AppRealtimeAudioIntegrationError.pcmRenderFailed(reason: "renderer must NOT be called for empty plan")
        }
    }

    // MARK: - 1. Non-empty plan renders through the cache and returns sources

    func testNonEmptyPlanRendersThroughCacheAndReturnsSources() async throws {
        let renderer = EchoRenderer()
        let cache = try CanonicalPCMRenderCache.make(capacity: 4, renderer: renderer)
        let pipeline = CachedCanonicalAudioRenderPipeline(cache: cache)
        let req = try Self.request()

        let sources = try await pipeline.prepareInitialPreroll(req, onDiagnostic: nil)
        XCTAssertEqual(sources.count, 1, "pipeline returns the chunk's sources")
        XCTAssertEqual(sources[0].buffer.chunkRange, req.range)
        let calls = await renderer.calls
        XCTAssertEqual(calls, 1, "renderer invoked once on a cold miss")
        let stored = await cache.count
        XCTAssertEqual(stored, 1, "rendered chunk is cached")
    }

    // MARK: - 2. Second identical request is served from the cache

    func testSecondCallWithSameRequestUsesCache() async throws {
        let renderer = EchoRenderer()
        let cache = try CanonicalPCMRenderCache.make(capacity: 4, renderer: renderer)
        let pipeline = CachedCanonicalAudioRenderPipeline(cache: cache)
        let req = try Self.request()

        _ = try await pipeline.prepareInitialPreroll(req, onDiagnostic: nil)
        _ = try await pipeline.prepareInitialPreroll(req, onDiagnostic: nil)
        let calls = await renderer.calls
        XCTAssertEqual(calls, 1, "second identical request is a cache hit (no extra render)")
    }

    // MARK: - 3. Distinct revision/epoch/range/planIdentity all miss

    func testDifferentRevisionEpochRangeOrPlanIdentityMisses() async throws {
        let renderer = EchoRenderer()
        let cache = try CanonicalPCMRenderCache.make(capacity: 16, renderer: renderer)
        let pipeline = CachedCanonicalAudioRenderPipeline(cache: cache)

        let requests = [
            try Self.request(),                          // base
            try Self.request(revision: 2),               // different revision
            try Self.request(epoch: 2),                  // different epoch
            try Self.request(samples: 16),               // different range
            try Self.request(clip: "c1"),                // different planIdentity (segment clip id changed)
        ]
        for (i, r) in requests.enumerated() {
            _ = try await pipeline.prepareInitialPreroll(r, onDiagnostic: nil)
            let calls = await renderer.calls
            XCTAssertEqual(calls, i + 1, "request #\(i) must miss and render once (distinct cache key)")
        }
        let stored = await cache.count
        XCTAssertEqual(stored, requests.count)
    }

    // MARK: - 4. Empty plan → [] without touching the renderer (chosen behavior)

    func testEmptyPlanReturnsSilenceWithoutRenderer() async throws {
        let renderer = NeverRenderer()
        let cache = try CanonicalPCMRenderCache.make(capacity: 4, renderer: renderer)
        let pipeline = CachedCanonicalAudioRenderPipeline(cache: cache)
        let req = try Self.request(empty: true)

        let sources = try await pipeline.prepareInitialPreroll(req, onDiagnostic: nil)
        XCTAssertTrue(sources.isEmpty, "empty plan is legitimate silence → []")
        let calls = await renderer.calls
        XCTAssertEqual(calls, 0, "empty plan must NOT invoke the renderer")
        let stored = await cache.count
        XCTAssertEqual(stored, 0, "empty plan stores nothing")
    }

    // MARK: - 5. Renderer failure propagates and is not cached

    func testRendererFailurePropagatesAndIsNotCached() async throws {
        let renderer = FlakyRenderer(failFirst: 1)
        let cache = try CanonicalPCMRenderCache.make(capacity: 4, renderer: renderer)
        let pipeline = CachedCanonicalAudioRenderPipeline(cache: cache)
        let req = try Self.request()

        do {
            _ = try await pipeline.prepareInitialPreroll(req, onDiagnostic: nil)
            XCTFail("first render must throw (non-empty plan never becomes silence)")
        } catch let error as AppRealtimeAudioIntegrationError {
            guard case .pcmRenderFailed = error else { return XCTFail("expected .pcmRenderFailed, got \(error)") }
        }
        var stored = await cache.count
        XCTAssertEqual(stored, 0, "a failed render is not cached")

        // Retry succeeds and caches.
        let sources = try await pipeline.prepareInitialPreroll(req, onDiagnostic: nil)
        XCTAssertEqual(sources.count, 1)
        let calls = await renderer.calls
        XCTAssertEqual(calls, 2, "renderer retried after failure")
        stored = await cache.count
        XCTAssertEqual(stored, 1)
    }

    // MARK: - 6. Renderer returns a mismatched-key chunk → fail closed, no sources

    func testMismatchedChunkKeyFromRendererFailsClosed() async throws {
        let renderer = MismatchingRenderer()
        let cache = try CanonicalPCMRenderCache.make(capacity: 4, renderer: renderer)
        let pipeline = CachedCanonicalAudioRenderPipeline(cache: cache)
        let req = try Self.request()

        do {
            _ = try await pipeline.prepareInitialPreroll(req, onDiagnostic: nil)
            XCTFail("a chunk whose key != requested key must fail closed")
        } catch let error as AppRealtimeAudioIntegrationError {
            guard case .pcmRenderFailed = error else {
                return XCTFail("expected .pcmRenderFailed for mismatched chunk key, got \(error)")
            }
        }
        let stored = await cache.count
        XCTAssertEqual(stored, 0, "mismatched-identity chunk is not cached")
    }

    // MARK: - 7. Plan identity is deterministic and content-sensitive

    func testPlanIdentityIsDeterministicAndChangesWhenPlanContentChanges() throws {
        let r = try Self.range(samples: 8)
        let planA1 = try Self.plan(range: r, clip: "c0")
        let planA2 = try Self.plan(range: r, clip: "c0")
        // Determinism: same content → identical identity.
        XCTAssertEqual(
            CanonicalAudioPlanIdentity.string(for: planA1),
            CanonicalAudioPlanIdentity.string(for: planA2),
            "identical plan content must produce identical identity")

        // Content sensitivity: change a meaningful segment field (clipID) → different identity.
        let planB = try Self.plan(range: r, clip: "c1")
        XCTAssertNotEqual(
            CanonicalAudioPlanIdentity.string(for: planA1),
            CanonicalAudioPlanIdentity.string(for: planB),
            "changing a meaningful segment field must change the identity")

        // Another meaningful field (mute) → different identity.
        let planMuted = try Self.plan(range: r, clip: "c0", muted: true)
        XCTAssertNotEqual(
            CanonicalAudioPlanIdentity.string(for: planA1),
            CanonicalAudioPlanIdentity.string(for: planMuted),
            "changing isMuted must change the identity")

        // Different requested interval → different identity.
        let planWideInterval = AudioPlan(
            sampleInterval: try Self.range(samples: 16),
            segments: planA1.segments)
        XCTAssertNotEqual(
            CanonicalAudioPlanIdentity.string(for: planA1),
            CanonicalAudioPlanIdentity.string(for: planWideInterval),
            "changing the sample interval must change the identity")

        // Non-empty result for a non-empty plan.
        XCTAssertFalse(CanonicalAudioPlanIdentity.string(for: planA1).isEmpty)
    }

    // MARK: - 7b. P0 REGRESSION: ids containing the markup separators must NOT collide (TAB)

    /// On the OLD tab/newline-delimited encoding these two plans produced an IDENTICAL identity string:
    ///   A.segment → "...clip=a\tsource=b\tsource=c\t..."
    ///   B.segment → "...clip=a\tsource=b\tsource=c\t..."   (same bytes — collision)
    /// The length-prefixed encoding frames each id by exact UTF-8 byte count, so they differ.
    func testPlanIdentityDoesNotCollideWhenIDsContainSeparators() throws {
        let r = try Self.range(samples: 8)
        let planA = try Self.planWithIDs(range: r, clip: "a\tsource=b", source: "c")
        let planB = try Self.planWithIDs(range: r, clip: "a", source: "b\tsource=c")

        XCTAssertNotEqual(planA, planB, "precondition: the two plans are genuinely different")
        XCTAssertNotEqual(
            CanonicalAudioPlanIdentity.string(for: planA),
            CanonicalAudioPlanIdentity.string(for: planB),
            "ids containing a TAB separator must not forge field boundaries / collide")
    }

    // MARK: - 7c. P0 REGRESSION: ids containing a NEWLINE must NOT collide

    func testPlanIdentityDoesNotCollideWhenIDsContainNewlines() throws {
        let r = try Self.range(samples: 8)
        // On the OLD newline-record-joined encoding, a newline embedded in an id could forge a record break.
        let planA = try Self.planWithIDs(range: r, clip: "a\nsource=b", source: "c")
        let planB = try Self.planWithIDs(range: r, clip: "a", source: "b\nsource=c")

        XCTAssertNotEqual(planA, planB, "precondition: the two plans are genuinely different")
        XCTAssertNotEqual(
            CanonicalAudioPlanIdentity.string(for: planA),
            CanonicalAudioPlanIdentity.string(for: planB),
            "ids containing a NEWLINE separator must not forge record boundaries / collide")
    }

    // MARK: - 8. No live-decoder symbols in the pipeline source

    func testNoLiveDecoderSymbolsInPipelineSource() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()       // .../AnimiApp/Tests
            .deletingLastPathComponent()       // .../AnimiApp
            .appendingPathComponent("Sources/EditorRuntime/Realtime/CachedCanonicalAudioRenderPipeline.swift")
            .standardizedFileURL
        let raw = try String(contentsOf: url, encoding: .utf8)
        let stripped = Self.stripSwiftComments(raw)
        for token in [
            "AVAssetReader", "copyNextSampleBuffer", "PCMDecoder", "AVAssetReaderPCMDecoder",
            "AppAudioChunkPreparer", "import AVFoundation", "import AVFAudio"
        ] {
            XCTAssertFalse(stripped.contains(token),
                "pipeline source must not reference '\(token)' (after comment-strip)")
        }
        // Positive: it IS the cache-backed canonical pipeline.
        XCTAssertTrue(stripped.contains("CanonicalAudioRenderPipeline"))
        XCTAssertTrue(stripped.contains("CanonicalPCMRenderCache") || stripped.contains("cache.chunk"))
    }

    /// Strip Swift line + block comments (so prose mentioning a forbidden symbol does not false-positive).
    private static func stripSwiftComments(_ source: String) -> String {
        var out = String(); out.reserveCapacity(source.count)
        var inLine = false, inBlock = false
        let chars = Array(source); var i = 0
        while i < chars.count {
            let c = chars[i]; let n: Character? = (i + 1) < chars.count ? chars[i + 1] : nil
            if inLine { if c == "\n" { inLine = false; out.append(c) }; i += 1; continue }
            if inBlock { if c == "*", n == "/" { inBlock = false; i += 2; continue }; if c == "\n" { out.append(c) }; i += 1; continue }
            if c == "/", n == "/" { inLine = true; i += 2; continue }
            if c == "/", n == "*" { inBlock = true; i += 2; continue }
            out.append(c); i += 1
        }
        return out
    }
}
