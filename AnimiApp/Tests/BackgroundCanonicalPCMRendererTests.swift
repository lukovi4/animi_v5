import XCTest
import AnimiEngineCore
@testable import AnimiApp

/// Slice-005 Stage 3 — `BackgroundCanonicalPCMRenderer` contract, driven by a TEST-ONLY fixture decoder
/// (no AVFoundation, no real media). Proves bounded/exact segment→source math, exact source-time, the
/// chunk identity gate, gain/mute carry-not-apply, off-main callability, and fail-closed errors.
final class BackgroundCanonicalPCMRendererTests: XCTestCase {

    // MARK: - Fixtures

    private static func range(samples: Int64, from startSamples: Int64 = 0) throws -> AudioSampleRange {
        let startTicks = startSamples * AudioSampleGrid.ticksPerSample
        let endTicks = (startSamples + samples) * AudioSampleGrid.ticksPerSample
        return try AudioSampleRange.from(projectTicks:
            ProjectTimeRange(start: try ProjectTime(ticks: startTicks), end: try ProjectTime(ticks: endTicks)))
    }
    private static func revision(_ raw: Int64) -> ProjectRevision { var a = MonotonicRevisionAllocator(start: raw); return a.next() }
    private static func epoch(_ raw: Int64) -> PlaybackEpoch { var a = MonotonicEpochAllocator(start: raw); return a.next() }

    private static func resolved(_ name: String) -> CanonicalResolvedAudioSource {
        CanonicalResolvedAudioSource(url: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    /// A segment over a destination sub-range, with controllable source/clip ids, source-start, gain/mute.
    private static func segment(
        clip: String = "c0", source: String = "s0", role: AudioSourceRole = .music,
        destStartSamples: Int64 = 0, destSamples: Int64 = 8,
        sourceStart: RationalSourceTime = .zero, muted: Bool = false, gainRaw: Int64 = AudioGain.unityRaw,
        scene: String? = nil
    ) throws -> AudioSegmentPlan {
        let dest = try range(samples: destSamples, from: destStartSamples)
        return AudioSegmentPlan(
            clipID: try AudioClipID(clip), sourceID: try AudioSourceID(source), trackID: try AudioTrackID("t0"),
            role: role, destinationSamples: dest, sourceStart: sourceStart,
            sourceEnd: try RationalSourceTime(numerator: 1, denominator: 1),
            effectiveTrim: try RationalSourceRange(start: .zero, end: try RationalSourceTime(numerator: 1, denominator: 1)),
            isMuted: muted, gain: try AudioGain(raw: gainRaw), sourceSampleRate: 48_000, channelLayout: .mono,
            streamIdentity: try AudioStreamIdentity("stream-\(source)"),
            sceneID: scene.map { try! SceneInstanceID($0) })
    }

    private static func request(
        revision rev: Int64 = 1, epoch ep: Int64 = 1,
        rangeSamples: Int64 = 8, rangeStart: Int64 = 0,
        segments: [AudioSegmentPlan], sources: [String]
    ) throws -> CanonicalAudioRenderRequest {
        let r = try range(samples: rangeSamples, from: rangeStart)
        var map: [String: CanonicalResolvedAudioSource] = [:]
        for s in sources { map[s] = resolved(s) }
        return CanonicalAudioRenderRequest(
            plan: AudioPlan(sampleInterval: r, segments: segments),
            revision: revision(rev), epoch: epoch(ep),
            anchor: PreviewAudioScheduleAnchor(revision: revision(rev), epoch: epoch(ep), projectSample: 0, outputSampleTime: 0),
            range: r, resolvedSourcesByID: map)
    }

    private static func pipelineKey(for request: CanonicalAudioRenderRequest) throws -> CanonicalPCMRenderKey {
        try CanonicalPCMRenderKey(
            revision: request.revision, epoch: request.epoch,
            planIdentity: CanonicalAudioPlanIdentity.string(for: request.plan), range: request.range)
    }

    // MARK: - Fixture decoder (TEST-ONLY actor; records what it was asked for)

    private actor FixtureDecoder: CanonicalPCMAssetDecoder {
        enum Mode: Sendable { case ramp, wrongCount(Int), throwUnsupported, throwCorrupt }
        private let mode: Mode
        private(set) var requests: [CanonicalPCMAssetDecodeRequest] = []
        init(mode: Mode = .ramp) { self.mode = mode }

        func decodeMono48kFloat32(_ request: CanonicalPCMAssetDecodeRequest) async throws -> [Float32] {
            requests.append(request)
            switch mode {
            case .ramp:
                // Deterministic non-zero ramp so "decoded inside, zero outside" is observable.
                return (0..<request.frameCount).map { Float32($0 + 1) }
            case .wrongCount(let n):
                return [Float32](repeating: 1, count: n)
            case .throwUnsupported:
                throw AppRealtimeAudioIntegrationError.mediaUnsupported(sourceRaw: request.sourceIDRaw, detail: "fixture")
            case .throwCorrupt:
                throw AppRealtimeAudioIntegrationError.mediaCorrupt(sourceRaw: request.sourceIDRaw, detail: "fixture")
            }
        }
    }

    // MARK: - 1. Missing source

    func testRendererRejectsMissingSource() async throws {
        let decoder = FixtureDecoder()
        let renderer = BackgroundCanonicalPCMRenderer(decoder: decoder)
        // Segment references "s0" but resolvedSourcesByID is empty.
        let req = try Self.request(segments: [try Self.segment()], sources: [])
        do {
            _ = try await renderer.render(req)
            XCTFail("missing source must throw")
        } catch let e as AppRealtimeAudioIntegrationError {
            guard case .mediaUnavailable(let raw) = e else { return XCTFail("expected .mediaUnavailable, got \(e)") }
            XCTAssertEqual(raw, "s0")
        }
    }

    // MARK: - 2. Unsupported source propagates typed

    func testRendererPropagatesUnsupportedSource() async throws {
        let decoder = FixtureDecoder(mode: .throwUnsupported)
        let renderer = BackgroundCanonicalPCMRenderer(decoder: decoder)
        let req = try Self.request(segments: [try Self.segment()], sources: ["s0"])
        do {
            _ = try await renderer.render(req)
            XCTFail("unsupported source must throw")
        } catch let e as AppRealtimeAudioIntegrationError {
            guard case .mediaUnsupported = e else { return XCTFail("expected .mediaUnsupported, got \(e)") }
        }
    }

    // MARK: - 3. Exact frame count

    func testRendererReturnsExactFrameCount() async throws {
        let decoder = FixtureDecoder()
        let renderer = BackgroundCanonicalPCMRenderer(decoder: decoder)
        let req = try Self.request(rangeSamples: 8, segments: [try Self.segment(destSamples: 8)], sources: ["s0"])
        let chunk = try await renderer.render(req)
        XCTAssertEqual(chunk.sources.count, 1)
        XCTAssertEqual(chunk.sources[0].samples.count, 8)
        XCTAssertEqual(chunk.sources[0].buffer.chunkRange, req.range)
    }

    // MARK: - 4. chunk.key == requested key

    func testRendererReturnsChunkKeyEqualToRequestedKey() async throws {
        let renderer = BackgroundCanonicalPCMRenderer(decoder: FixtureDecoder())
        let req = try Self.request(segments: [try Self.segment()], sources: ["s0"])
        let chunk = try await renderer.render(req)
        XCTAssertEqual(chunk.key, try Self.pipelineKey(for: req))
    }

    // MARK: - 5. Bounded intersection only (no whole-project)

    func testRendererDecodesOnlyBoundedIntersection_notWholeProject() async throws {
        let decoder = FixtureDecoder()
        let renderer = BackgroundCanonicalPCMRenderer(decoder: decoder)
        // Segment destination [0,100) but requested chunk is [0,8): decoder must be asked for 8, not 100.
        let req = try Self.request(rangeSamples: 8, segments: [try Self.segment(destSamples: 100)], sources: ["s0"])
        _ = try await renderer.render(req)
        let asked = await decoder.requests
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked[0].frameCount, 8, "decoder must be asked only for the bounded intersection, not the whole segment")
    }

    // MARK: - 6/7/8. Source count mapping

    func testMusicOnlyRendersOneSource() async throws {
        let renderer = BackgroundCanonicalPCMRenderer(decoder: FixtureDecoder())
        let req = try Self.request(segments: [try Self.segment(source: "music")], sources: ["music"])
        let chunk = try await renderer.render(req)
        XCTAssertEqual(chunk.sources.count, 1)
    }

    func testVideoOriginalRendersOneSource() async throws {
        let renderer = BackgroundCanonicalPCMRenderer(decoder: FixtureDecoder())
        let seg = try Self.segment(source: "vid", role: .videoLayer, scene: "scene-0")
        let req = try Self.request(segments: [seg], sources: ["vid"])
        let chunk = try await renderer.render(req)
        XCTAssertEqual(chunk.sources.count, 1)
    }

    func testMusicPlusVideoRendersTwoSources() async throws {
        let renderer = BackgroundCanonicalPCMRenderer(decoder: FixtureDecoder())
        let music = try Self.segment(clip: "cm", source: "music")
        let video = try Self.segment(clip: "cv", source: "vid", role: .videoLayer, scene: "scene-0")
        let req = try Self.request(segments: [music, video], sources: ["music", "vid"])
        let chunk = try await renderer.render(req)
        XCTAssertEqual(chunk.sources.count, 2)
    }

    // MARK: - 9. Source start at segment start is exact (== segment.sourceStart)

    func testSourceStartAtSegmentStartIsExact() async throws {
        let decoder = FixtureDecoder()
        let renderer = BackgroundCanonicalPCMRenderer(decoder: decoder)
        // Chunk == segment destination starting at the same sample → delta is zero → source start unchanged.
        let segStart = try RationalSourceTime(numerator: 3, denominator: 2)   // arbitrary exact rational
        let seg = try Self.segment(destStartSamples: 0, destSamples: 8, sourceStart: segStart)
        let req = try Self.request(rangeSamples: 8, rangeStart: 0, segments: [seg], sources: ["s0"])
        _ = try await renderer.render(req)
        let asked = await decoder.requests
        XCTAssertEqual(asked[0].sourceStart, segStart, "no offset → exact segment.sourceStart, no Double drift")
    }

    // MARK: - 10. Interior offset is exact rational

    func testInteriorOffsetIsExactRational() async throws {
        let decoder = FixtureDecoder()
        let renderer = BackgroundCanonicalPCMRenderer(decoder: decoder)
        // Segment destination [0,16), chunk [4,12): intersection starts 4 samples into the segment.
        // Expected source start = 0 + 4/48000 seconds, exact.
        let seg = try Self.segment(destStartSamples: 0, destSamples: 16, sourceStart: .zero)
        let req = try Self.request(rangeSamples: 8, rangeStart: 4, segments: [seg], sources: ["s0"])
        _ = try await renderer.render(req)
        let asked = await decoder.requests
        let expected = try RationalSourceTime(numerator: 4, denominator: 48_000)
        XCTAssertEqual(asked[0].sourceStart, expected, "interior offset must be exact 4/48000, not truncated")
        XCTAssertEqual(asked[0].frameCount, 8)
    }

    // MARK: - 11. Partial overlap → zero outside intersection

    func testPartialOverlapZeroFramesOutsideSegment() async throws {
        let decoder = FixtureDecoder()   // ramp: 1,2,3,... inside the decoded region
        let renderer = BackgroundCanonicalPCMRenderer(decoder: decoder)
        // Chunk [0,8); segment destination [4,8) → intersection [4,8): frames 0..3 zero, 4..7 decoded ramp.
        let seg = try Self.segment(destStartSamples: 4, destSamples: 4, sourceStart: .zero)
        let req = try Self.request(rangeSamples: 8, rangeStart: 0, segments: [seg], sources: ["s0"])
        let chunk = try await renderer.render(req)
        let samples = chunk.sources[0].samples
        XCTAssertEqual(samples.count, 8)
        XCTAssertEqual(Array(samples[0..<4]), [0, 0, 0, 0], "zero outside the intersection")
        XCTAssertEqual(Array(samples[4..<8]), [1, 2, 3, 4], "decoded ramp inside the intersection, correctly offset")
    }

    // MARK: - 12. Short decode buffer fails closed

    func testShortDecodeBufferFailsClosed() async throws {
        let decoder = FixtureDecoder(mode: .wrongCount(3))   // chunk wants 8
        let renderer = BackgroundCanonicalPCMRenderer(decoder: decoder)
        let req = try Self.request(rangeSamples: 8, segments: [try Self.segment(destSamples: 8)], sources: ["s0"])
        do {
            _ = try await renderer.render(req)
            XCTFail("wrong frame count must fail closed")
        } catch let e as AppRealtimeAudioIntegrationError {
            guard case .pcmRenderFailed = e else { return XCTFail("expected .pcmRenderFailed, got \(e)") }
        }
    }

    // MARK: - 13. Gain/mute carried, not applied

    func testGainMuteCarriedNotApplied() async throws {
        let decoder = FixtureDecoder()   // ramp 1,2,3,... regardless of gain/mute
        let renderer = BackgroundCanonicalPCMRenderer(decoder: decoder)
        let seg = try Self.segment(destSamples: 8, muted: true, gainRaw: 500_000)   // half gain, muted
        let req = try Self.request(rangeSamples: 8, segments: [seg], sources: ["s0"])
        let chunk = try await renderer.render(req)
        let src = chunk.sources[0]
        XCTAssertTrue(src.buffer.isMuted, "mute carried as metadata")
        XCTAssertEqual(src.buffer.gain.raw, 500_000, "gain carried as metadata")
        // Samples are RAW ramp — NOT scaled by gain, NOT zeroed by mute.
        XCTAssertEqual(Array(src.samples), [1, 2, 3, 4, 5, 6, 7, 8], "renderer must not pre-apply gain/mute")
    }

    // MARK: - 14. Callable off the main actor

    func testRendererCallableOffMainActor() async throws {
        let renderer = BackgroundCanonicalPCMRenderer(decoder: FixtureDecoder())
        let req = try Self.request(segments: [try Self.segment()], sources: ["s0"])
        // Run on a detached (non-main) task; assert it is genuinely off-main at call time, then render.
        let count: Int = try await Task.detached {
            dispatchPrecondition(condition: .notOnQueue(.main))
            let chunk = try await renderer.render(req)
            return chunk.sources.count
        }.value
        XCTAssertEqual(count, 1)
    }

    // MARK: - Empty plan → empty-sources chunk (defensive; Stage-2 short-circuits earlier)

    func testEmptyPlanReturnsEmptySourcesChunk() async throws {
        let renderer = BackgroundCanonicalPCMRenderer(decoder: FixtureDecoder())
        let r = try Self.range(samples: 8)
        let req = CanonicalAudioRenderRequest(
            plan: AudioPlan(sampleInterval: r, segments: []),
            revision: Self.revision(1), epoch: Self.epoch(1),
            anchor: PreviewAudioScheduleAnchor(revision: Self.revision(1), epoch: Self.epoch(1), projectSample: 0, outputSampleTime: 0),
            range: r, resolvedSourcesByID: [:])
        let chunk = try await renderer.render(req)
        XCTAssertTrue(chunk.sources.isEmpty)
        XCTAssertEqual(chunk.key, try Self.pipelineKey(for: req))
    }
}
