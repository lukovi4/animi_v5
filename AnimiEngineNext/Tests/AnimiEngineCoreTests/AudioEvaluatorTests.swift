import XCTest
@testable import AnimiEngineCore

/// Slice-002 Stage C — the pure `AudioEvaluator`. Builds `AudioEvaluationWindow`s directly (full
/// control of destinations/trims) and asserts exact segment math, gating, ordering, and silence.
final class AudioEvaluatorTests: XCTestCase {

    // MARK: - Builders

    private func window(
        coverage: (Int64, Int64) = (0, 240_000),
        projectDuration: Int64 = 240_000,
        scenes: [AudioWindowScene] = [],
        tracks: [ResolvedAudioTrack],
        clips: [ResolvedAudioClip]
    ) throws -> AudioEvaluationWindow {
        AudioEvaluationWindow(
            coverage: try range(coverage.0, coverage.1),
            projectDuration: try TickDuration(ticks: projectDuration),
            scenes: scenes, tracks: tracks, clips: clips
        )
    }

    private func track(_ id: String, _ role: AudioSourceRole, order: Int) throws -> ResolvedAudioTrack {
        ResolvedAudioTrack(trackID: try AudioTrackID(id), role: role, order: order)
    }

    private func descriptor(
        _ sourceID: String, identity: String = "stream", sampleRate: Int64 = 48_000,
        layout: AudioChannelLayoutDescriptor = .stereo
    ) throws -> ResolvedAudioSourceDescriptor {
        ResolvedAudioSourceDescriptor(
            sourceID: try AudioSourceID(sourceID), streamIdentity: try AudioStreamIdentity(identity),
            sourceDuration: try RationalSourceTime(numerator: 600, denominator: 1),
            sampleRate: sampleRate, channelLayout: layout
        )
    }

    private func globalClip(
        _ id: String, track: String = "t1", source: String = "s1",
        dest: (Int64, Int64), trimEndSeconds: Int64 = 600, muted: Bool = false, gainRaw: Int64 = 1_000_000,
        descriptor: ResolvedAudioSourceDescriptor? = nil
    ) throws -> ResolvedAudioClip {
        ResolvedAudioClip(
            clipID: try AudioClipID(id), trackID: try AudioTrackID(track), sourceID: try AudioSourceID(source),
            role: .music, isMuted: muted, gain: try AudioGain(raw: gainRaw),
            destination: try range(dest.0, dest.1), sourceTrim: try trim(0, trimEndSeconds),
            playbackPolicy: .once, binding: .global,
            sourceDescriptor: try descriptor ?? self.descriptor(source)
        )
    }

    private func videoClip(
        _ id: String, track: String = "t1", source: String = "s1", sceneID: String,
        dest: (Int64, Int64), trimEndSeconds: Int64 = 600, rate: (Int64, Int64) = (1, 1)
    ) throws -> ResolvedAudioClip {
        let mapping = SourceTimeMapping(
            trimRange: try trim(0, 600),
            nativeTimescale: try SourceTimescale(unitsPerSecond: 600),
            rate: try PlaybackRate(numerator: rate.0, denominator: rate.1)
        )
        return ResolvedAudioClip(
            clipID: try AudioClipID(id), trackID: try AudioTrackID(track), sourceID: try AudioSourceID(source),
            role: .videoLayer, isMuted: false, gain: .unity,
            destination: try range(dest.0, dest.1), sourceTrim: try trim(0, trimEndSeconds),
            playbackPolicy: .once,
            binding: .videoLayer(sceneID: try SceneInstanceID(sceneID), sourceMapping: mapping),
            sourceDescriptor: try descriptor(source)
        )
    }

    private func scene(_ id: String, start: Int64, span: Int64, boundary: Int64? = nil) throws -> AudioWindowScene {
        AudioWindowScene(
            sceneID: try SceneInstanceID(id), sceneStart: try ProjectTime(ticks: start),
            nominalDuration: try TickDuration(ticks: span), timelineSpan: try TickDuration(ticks: span),
            followingBoundary: try boundary.map { try ProjectTime(ticks: $0) }, followingTransition: nil
        )
    }

    // MARK: - Coverage / empty

    func testRangeOutsideCoverageRejected() throws {
        let w = try window(tracks: [try track("t1", .music, order: 0)],
                           clips: [try globalClip("c1", dest: (0, 240_000))])
        XCTAssertThrowsError(try AudioEvaluator.evaluate(window: w, range: try range(0, 240_001))) {
            XCTAssertEqual($0 as? AudioEvaluationError, .audioWindowCoverageViolation)
        }
    }

    func testEmptySampleRangeYieldsZeroSegments() throws {
        // A project range whose endpoints ceil to the same 48 kHz sample → empty sample interval.
        // ticks 1..4 both ceilDiv5 to 1 → empty.
        let w = try window(tracks: [try track("t1", .music, order: 0)],
                           clips: [try globalClip("c1", dest: (0, 240_000))])
        let plan = try AudioEvaluator.evaluate(window: w, range: try range(1, 4))
        XCTAssertTrue(plan.sampleInterval.isEmpty)
        XCTAssertTrue(plan.segments.isEmpty)
    }

    func testEmptyDestinationIntersectionYieldsZeroSegments() throws {
        // Clip destination [0, 1000); request [100_000, 200_000) → no intersection.
        let w = try window(tracks: [try track("t1", .music, order: 0)],
                           clips: [try globalClip("c1", dest: (0, 1000))])
        let plan = try AudioEvaluator.evaluate(window: w, range: try range(100_000, 200_000))
        XCTAssertTrue(plan.segments.isEmpty)
    }

    func testLegitimateSilenceEmptyPlan() throws {
        let w = try window(tracks: [], clips: [])
        let plan = try AudioEvaluator.evaluate(window: w, range: try range(0, 240_000))
        XCTAssertTrue(plan.segments.isEmpty)
    }

    // MARK: - Global 1/1 timing

    func testGlobalStrictOneToOne() throws {
        // dest [48_000, 96_000) ticks; trim start 0. At dest.start the source = 0; at dest.end source =
        // (96_000 − 48_000)/240_000 = 48_000/240_000 = 1/5 second.
        let w = try window(tracks: [try track("t1", .music, order: 0)],
                           clips: [try globalClip("c1", dest: (48_000, 96_000))])
        let plan = try AudioEvaluator.evaluate(window: w, range: try range(0, 240_000))
        XCTAssertEqual(plan.segments.count, 1)
        let seg = plan.segments[0]
        XCTAssertEqual(seg.sourceStart, try RationalSourceTime(numerator: 0, denominator: 1))
        XCTAssertEqual(seg.sourceEnd, try RationalSourceTime(numerator: 1, denominator: 5))
        // Destination samples: ceilDiv5(48_000)=9_600 .. ceilDiv5(96_000)=19_200.
        XCTAssertEqual(seg.destinationSamples.start, 9_600)
        XCTAssertEqual(seg.destinationSamples.end, 19_200)
    }

    // MARK: - Video-layer timing equals SceneMediaClock + SourceTimeMapping.target

    func testVideoLayerTimingMatchesSharedClockAndMapping() throws {
        let sceneStart: Int64 = 0
        let s = try scene("sceneA", start: sceneStart, span: 240_000)
        let clip = try videoClip("c1", sceneID: "sceneA", dest: (0, 120_000))
        let w = try window(scenes: [s], tracks: [try track("t1", .videoLayer, order: 0)], clips: [clip])
        let plan = try AudioEvaluator.evaluate(window: w, range: try range(0, 240_000))
        XCTAssertEqual(plan.segments.count, 1)
        let seg = plan.segments[0]

        // Independently compute the expected source at dest endpoints via the SHARED clock + mapping.
        guard case .videoLayer(_, let mapping) = clip.binding else { return XCTFail() }
        let mediaStart = try SceneMediaClock.sceneMediaTime(role: .sole, at: try ProjectTime(ticks: 0), sceneStart: try ProjectTime(ticks: sceneStart), boundary: nil)
        let mediaEnd = try SceneMediaClock.sceneMediaTime(role: .sole, at: try ProjectTime(ticks: 120_000), sceneStart: try ProjectTime(ticks: sceneStart), boundary: nil)
        XCTAssertEqual(seg.sourceStart, try mapping.target(for: mediaStart))
        XCTAssertEqual(seg.sourceEnd, try mapping.target(for: mediaEnd))
        XCTAssertEqual(seg.sceneID, try SceneInstanceID("sceneA"))
    }

    // MARK: - Trim gate / .once stop

    func testTrimGateClipsSegment() throws {
        // dest [0, 240_000) (1 second), but trim end = 1/2 second → audible only first half.
        // source reaches 1/2 at tick = 0 + (1/2)·240_000 = 120_000.
        let clip = ResolvedAudioClip(
            clipID: try AudioClipID("c1"), trackID: try AudioTrackID("t1"), sourceID: try AudioSourceID("s1"),
            role: .music, isMuted: false, gain: .unity,
            destination: try range(0, 240_000),
            sourceTrim: try RationalSourceRange(start: try RationalSourceTime(numerator: 0, denominator: 1),
                                                end: try RationalSourceTime(numerator: 1, denominator: 2)),
            playbackPolicy: .once, binding: .global, sourceDescriptor: try descriptor("s1")
        )
        let w = try window(tracks: [try track("t1", .music, order: 0)], clips: [clip])
        let plan = try AudioEvaluator.evaluate(window: w, range: try range(0, 240_000))
        XCTAssertEqual(plan.segments.count, 1)
        let seg = plan.segments[0]
        // .once stops at the trim end (120_000 ticks → ceilDiv5 = 24_000 samples).
        XCTAssertEqual(seg.destinationSamples.start, 0)
        XCTAssertEqual(seg.destinationSamples.end, 24_000)
        XCTAssertEqual(seg.sourceEnd, try RationalSourceTime(numerator: 1, denominator: 2))
    }

    func testOnceStopsNoLoopNoStretch() throws {
        // Trim end 1/4s; dest is 2 seconds. Audible only first 1/4s; no loop/extension past the stop.
        let clip = ResolvedAudioClip(
            clipID: try AudioClipID("c1"), trackID: try AudioTrackID("t1"), sourceID: try AudioSourceID("s1"),
            role: .music, isMuted: false, gain: .unity,
            destination: try range(0, 480_000),
            sourceTrim: try RationalSourceRange(start: try RationalSourceTime(numerator: 0, denominator: 1),
                                                end: try RationalSourceTime(numerator: 1, denominator: 4)),
            playbackPolicy: .once, binding: .global, sourceDescriptor: try descriptor("s1")
        )
        let w = try window(coverage: (0, 480_000), projectDuration: 480_000,
                           tracks: [try track("t1", .music, order: 0)], clips: [clip])
        let plan = try AudioEvaluator.evaluate(window: w, range: try range(0, 480_000))
        let seg = plan.segments[0]
        // Stop at tick (1/4)·240_000 = 60_000 → ceilDiv5 = 12_000 samples; never the full 96_000.
        XCTAssertEqual(seg.destinationSamples.end, 12_000)
        XCTAssertEqual(seg.sourceEnd, try RationalSourceTime(numerator: 1, denominator: 4))
    }

    // MARK: - Mute / gain preserved

    func testMutedSegmentPreserved() throws {
        let w = try window(tracks: [try track("t1", .music, order: 0)],
                           clips: [try globalClip("c1", dest: (0, 240_000), muted: true)])
        let plan = try AudioEvaluator.evaluate(window: w, range: try range(0, 240_000))
        XCTAssertEqual(plan.segments.count, 1)
        XCTAssertTrue(plan.segments[0].isMuted)
    }

    func testGainPreserved() throws {
        let w = try window(tracks: [try track("t1", .music, order: 0)],
                           clips: [try globalClip("c1", dest: (0, 240_000), gainRaw: 250_000)])
        let plan = try AudioEvaluator.evaluate(window: w, range: try range(0, 240_000))
        XCTAssertEqual(plan.segments[0].gain, try AudioGain(raw: 250_000))
    }

    // MARK: - Deterministic ordering

    func testDeterministicOrderingWithShuffledInputs() throws {
        // Three clips on three tracks; ordering must be by (track.order, destStart, clipID, sourceID).
        let tracks = [try track("t2", .music, order: 1), try track("t0", .voiceover, order: 0), try track("t1", .soundEffect, order: 2)]
        let clips = [
            try globalClip("cB", track: "t1", source: "sB", dest: (0, 240_000)),
            try globalClip("cA", track: "t0", source: "sA", dest: (0, 240_000)),
            try globalClip("cC", track: "t2", source: "sC", dest: (0, 240_000))
        ]
        let w = try window(tracks: tracks, clips: clips)
        let plan = try AudioEvaluator.evaluate(window: w, range: try range(0, 240_000))
        // Expected track order: t0(0) → t2(1) → t1(2).
        XCTAssertEqual(plan.segments.map { $0.trackID.raw }, ["t0", "t2", "t1"])
    }

    // MARK: - Transition overlap

    func testTransitionOverlapEmitsOutgoingAndIncoming() throws {
        // Two scenes; outgoing "A" [0,240k), incoming "B" [240k,480k), boundary at 240k.
        // Outgoing audio dest [120k, 260k) (continues into post-roll past 240k);
        // Incoming audio dest [240k, 360k) (starts at boundary). Both should emit.
        let sceneA = try scene("A", start: 0, span: 240_000, boundary: 240_000)
        let sceneB = try scene("B", start: 240_000, span: 240_000)
        let outgoing = try videoClip("cOut", track: "t1", source: "sA", sceneID: "A", dest: (120_000, 260_000))
        let incoming = try videoClip("cIn", track: "t2", source: "sB", sceneID: "B", dest: (240_000, 360_000))
        let w = try window(
            coverage: (0, 480_000), projectDuration: 480_000, scenes: [sceneA, sceneB],
            tracks: [try track("t1", .videoLayer, order: 0), try track("t2", .videoLayer, order: 1)],
            clips: [outgoing, incoming]
        )
        let plan = try AudioEvaluator.evaluate(window: w, range: try range(0, 480_000))
        let ids = Set(plan.segments.map { $0.clipID.raw })
        XCTAssertTrue(ids.contains("cOut"), "outgoing post-roll segment must be emitted")
        XCTAssertTrue(ids.contains("cIn"), "incoming segment must be emitted")
    }

    func testIncomingPreBoundaryEmitsNoSegmentWhenSilent() throws {
        // Incoming scene B starts at 240k. An incoming clip whose destination is entirely BEFORE the
        // boundary maps to held source time 0 → no audible advance → no segment.
        // (This mirrors the canonical pre-boundary silence; we model it via a video clip on B whose
        //  destination sits before B, which the evaluator renders silent because sceneMediaTime holds 0
        //  and the source window collapses.)
        let sceneB = try scene("B", start: 240_000, span: 240_000, boundary: nil)
        // dest [120_000, 240_000) is before B's start; sceneMediaTime(.sole) = T − 240_000 < 0 region is
        // clamped: the source window [src(120k), src(240k)) collapses because local ticks are negative →
        // mapping yields a non-advancing window. Expect no segment.
        let clip = try videoClip("cIn", sceneID: "B", dest: (120_000, 240_000))
        let w = try window(coverage: (0, 480_000), projectDuration: 480_000, scenes: [sceneB],
                           tracks: [try track("t1", .videoLayer, order: 0)], clips: [clip])
        let plan = try AudioEvaluator.evaluate(window: w, range: try range(0, 480_000))
        XCTAssertTrue(plan.segments.filter { $0.clipID.raw == "cIn" }.isEmpty)
    }

    func testOutgoingPostRollEmitsWhenTrimAllows() throws {
        // Outgoing scene A [0,240k); clip dest extends to 300k (post-roll). Trim is generous (600s),
        // so the post-roll continues and a segment is emitted covering the whole dest.
        let sceneA = try scene("A", start: 0, span: 240_000, boundary: 240_000)
        let clip = try videoClip("cOut", sceneID: "A", dest: (60_000, 300_000))
        let w = try window(coverage: (0, 480_000), projectDuration: 480_000, scenes: [sceneA],
                           tracks: [try track("t1", .videoLayer, order: 0)], clips: [clip])
        let plan = try AudioEvaluator.evaluate(window: w, range: try range(0, 480_000))
        let seg = plan.segments.first { $0.clipID.raw == "cOut" }
        XCTAssertNotNil(seg)
        // Post-roll continues past nominal: destination end maps to 300_000 ticks → ceilDiv5 = 60_000.
        XCTAssertEqual(seg?.destinationSamples.end, 60_000)
    }

    // MARK: - Descriptor metadata preserved (NOT synthesized)

    func testSegmentPreservesDescriptorMetadataExactly() throws {
        // A descriptor with NON-default rate/layout/identity must flow verbatim into the segment.
        let desc = try descriptor("s1", identity: "provenance-XYZ", sampleRate: 44_100,
                                  layout: try AudioChannelLayoutDescriptor.discrete(count: 6))
        let clip = try globalClip("c1", dest: (0, 240_000), descriptor: desc)
        let w = try window(tracks: [try track("t1", .music, order: 0)], clips: [clip])
        let plan = try AudioEvaluator.evaluate(window: w, range: try range(0, 240_000))
        let seg = plan.segments[0]
        XCTAssertEqual(seg.sourceSampleRate, 44_100)
        XCTAssertEqual(seg.channelLayout, try AudioChannelLayoutDescriptor.discrete(count: 6))
        XCTAssertEqual(seg.streamIdentity, try AudioStreamIdentity("provenance-XYZ"))
        // Explicitly NOT synthesized to the mix grid / sourceID.
        XCTAssertNotEqual(seg.sourceSampleRate, AudioSampleGrid.samplesPerSecond)
        XCTAssertNotEqual(seg.channelLayout, .stereo)
        XCTAssertNotEqual(seg.streamIdentity, try AudioStreamIdentity("s1"))
    }

    // MARK: - Inverse math is fail-closed (no clamp/wrap/truncate)

    func testInverseMathOverflowFailsClosed() throws {
        // Force the inversion's `factor = rd · 240000` to overflow UInt64 by using a video-layer mapping
        // with a near-Int64.max rate denominator. The source still advances by a tiny positive amount
        // over the destination (rate > 0), so the audible window is non-empty and the evaluator reaches
        // `firstProjectTick`, where `rd · 240000` overflows → fail-closed `audioTimeMathOverflow`
        // (NOT a wrap, clamp, or truncation).
        let mapping = SourceTimeMapping(
            trimRange: try trim(0, 600),
            nativeTimescale: try SourceTimescale(unitsPerSecond: 600),
            rate: try PlaybackRate(numerator: 1, denominator: Int64.max)
        )
        let clip = ResolvedAudioClip(
            clipID: try AudioClipID("c1"), trackID: try AudioTrackID("t1"), sourceID: try AudioSourceID("s1"),
            role: .videoLayer, isMuted: false, gain: .unity,
            destination: try range(0, 240_000),
            sourceTrim: try RationalSourceRange(start: try RationalSourceTime(numerator: 0, denominator: 1),
                                                end: try RationalSourceTime(numerator: 1, denominator: 2)),
            playbackPolicy: .once,
            binding: .videoLayer(sceneID: try SceneInstanceID("A"), sourceMapping: mapping),
            sourceDescriptor: try descriptor("s1")
        )
        let scene = try scene("A", start: 0, span: 240_000)
        let w = AudioEvaluationWindow(
            coverage: try range(0, 240_000), projectDuration: try TickDuration(ticks: 240_000),
            scenes: [scene], tracks: [try track("t1", .videoLayer, order: 0)], clips: [clip]
        )
        XCTAssertThrowsError(try AudioEvaluator.evaluate(window: w, range: try range(0, 240_000))) {
            XCTAssertEqual($0 as? AudioEvaluationError, .audioTimeMathOverflow, "actual: \($0)")
        }
    }

    // MARK: - No Float/Double/Decimal and no AVFoundation in Audio sources

    func testNoFloatingPointOrAVFoundationInAudioSources() throws {
        let thisFile = URL(fileURLWithPath: #filePath)
        let packageRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let audioDir = packageRoot.appendingPathComponent("Sources/AnimiEngineCore/Audio", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for banned in ["Float", "Double", "Decimal", "import AVFoundation", "import AVFAudio"] {
                XCTAssertFalse(text.contains(banned), "\(file.lastPathComponent) must not reference \(banned)")
            }
        }
    }

    // MARK: - Stage-9.2: source-duration clamps the audible source window

    /// `descriptor.sourceDuration` (3 s) is shorter than the trim end (600 s) AND the destination/project
    /// range (5 s). The evaluated segment must STOP at `sourceDuration` (3 s): `sourceEnd == 3 s`, and the
    /// destination is clipped to the project tick where the source reaches 3 s. (Global map is 1/1, so source
    /// seconds == project seconds.) Guards the S9.2 stretched-video-original short-read.
    func test_S92_sourceDurationClampsSourceEndAndDestination() throws {
        let shortDesc = try descriptor("s1")   // base
        let clampedDesc = ResolvedAudioSourceDescriptor(
            sourceID: try AudioSourceID("s1"), streamIdentity: try AudioStreamIdentity("stream"),
            sourceDuration: try RationalSourceTime(numerator: 3, denominator: 1),   // REAL track = 3 s
            sampleRate: shortDesc.sampleRate, channelLayout: shortDesc.channelLayout)
        // dest [0, 5 s) = [0, 1_200_000) ticks; trim end 600 s; coverage/project 5 s.
        let w = try window(
            coverage: (0, 1_200_000), projectDuration: 1_200_000,
            tracks: [try track("t1", .music, order: 0)],
            clips: [try globalClip("c1", dest: (0, 1_200_000), trimEndSeconds: 600, descriptor: clampedDesc)])
        let plan = try AudioEvaluator.evaluate(window: w, range: try range(0, 1_200_000))
        XCTAssertEqual(plan.segments.count, 1)
        let seg = plan.segments[0]
        XCTAssertEqual(seg.sourceEnd, try RationalSourceTime(numerator: 3, denominator: 1),
                       "sourceEnd clamped to the real sourceDuration (3 s), not trim end / mapped 5 s")
        // No segment's sourceEnd may exceed the descriptor's sourceDuration.
        for s in plan.segments {
            XCTAssertFalse(try RationalSourceTime(numerator: 3, denominator: 1) < s.sourceEnd,
                           "no segment.sourceEnd may exceed sourceDuration")
        }
        // Destination is clipped to the project tick where source reaches 3 s → 3 s = 720_000 ticks.
        XCTAssertEqual(seg.destinationSamples.end,
                       try AudioSampleRange.from(projectTicks: try range(0, 720_000)).end,
                       "destination clipped to where the source reaches sourceDuration")
    }

    /// A requested range that starts AFTER `sourceDuration` yields ZERO segments (empty audible window),
    /// not an error and not a segment past the real track.
    func test_S92_requestedRangeAfterSourceDurationYieldsZeroSegments() throws {
        let clampedDesc = ResolvedAudioSourceDescriptor(
            sourceID: try AudioSourceID("s1"), streamIdentity: try AudioStreamIdentity("stream"),
            sourceDuration: try RationalSourceTime(numerator: 2, denominator: 1),   // REAL track = 2 s
            sampleRate: 48_000, channelLayout: .stereo)
        // Clip dest [0, 5 s); but evaluate ONLY the [3 s, 5 s) range — entirely past the 2 s source.
        let w = try window(
            coverage: (0, 1_200_000), projectDuration: 1_200_000,
            tracks: [try track("t1", .music, order: 0)],
            clips: [try globalClip("c1", dest: (0, 1_200_000), trimEndSeconds: 600, descriptor: clampedDesc)])
        let plan = try AudioEvaluator.evaluate(window: w, range: try range(720_000, 1_200_000))  // [3 s, 5 s)
        XCTAssertTrue(plan.segments.isEmpty,
                      "a range entirely past sourceDuration produces zero segments (nil, not error)")
    }

    // MARK: - Helpers

    private func range(_ s: Int64, _ e: Int64) throws -> ProjectTimeRange {
        try ProjectTimeRange(start: try ProjectTime(ticks: s), end: try ProjectTime(ticks: e))
    }
    private func trim(_ startSeconds: Int64, _ endSeconds: Int64) throws -> RationalSourceRange {
        try RationalSourceRange(
            start: try RationalSourceTime(numerator: startSeconds, denominator: 1),
            end: try RationalSourceTime(numerator: endSeconds, denominator: 1)
        )
    }
}
