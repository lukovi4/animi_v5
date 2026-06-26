import XCTest
@testable import AnimiEngineCore

/// Slice-004 Stage E — `PreviewAudioGraph` (bounded software mix) + `RealtimeSafeState` contract tests.
///
/// The graph owns the canonical mix: per-source gain/mute → sum → `OutputOverloadStage` (post-mix) →
/// one final mixed mono buffer at an explicit anchor-derived output sample time. A fake session adapter
/// and a fake output sink keep everything device-free.
final class PreviewAudioGraphContractTests: XCTestCase {

    // MARK: - Fakes (no AVFoundation)

    private final class FakeSession: AudioSessionAdapter, @unchecked Sendable {
        private(set) var isActive = false
        private let q: AudioOutputQuery
        init(query: AudioOutputQuery) { self.q = query }
        func activate() throws { isActive = true }
        func deactivate() throws { isActive = false }
        func queryActualOutput() throws -> AudioOutputQuery {
            guard isActive else { throw RealtimeAudioBoundaryError.queryBeforeActivation }
            return q
        }
    }

    private final class FakeSink: PreviewAudioOutputSink, @unchecked Sendable {
        var configuredFormat: AudioOutputFormat?
        var configuredRoute: AudioOutputRoute?
        var scheduled: [(range: AudioSampleRange, samples: [Float32], at: Int64)] = []
        func configure(outputFormat: AudioOutputFormat, route: AudioOutputRoute) throws {
            configuredFormat = outputFormat
            configuredRoute = route
        }
        func scheduleMixed(range: AudioSampleRange, samples: [Float32], at outputSampleTime: Int64) throws {
            scheduled.append((range, samples, outputSampleTime))
        }
    }

    // MARK: - Builders

    private func query(
        sampleRate: Int64 = 48_000, layout: AudioChannelLayoutDescriptor = .stereo,
        route: String = "built-in-speaker"
    ) throws -> AudioOutputQuery {
        AudioOutputQuery(
            format: try AudioOutputFormat(sampleRate: sampleRate, channelLayout: layout),
            route: try AudioOutputRoute(identifier: route))
    }

    private func buffer(
        revision: Int64 = 1, epoch: Int64 = 1, requestID: Int64 = 1,
        chunkStart: Int64 = 0, chunkEnd: Int64 = 2, sourceID: String = "s1",
        muted: Bool = false, gain: AudioGain = .unity
    ) throws -> PreparedAudioBuffer {
        try PreparedAudioBuffer(
            revision: ProjectRevision(raw: revision),
            epoch: PlaybackEpoch(raw: epoch),
            request: AudioRequestID(raw: requestID),
            sourceID: try AudioSourceID(sourceID),
            chunkRange: AudioSampleRange(uncheckedStart: chunkStart, end: chunkEnd),
            streamIdentity: try AudioStreamIdentity("stream-\(sourceID)"),
            sourceSampleRate: 48_000,
            channelLayout: .stereo,
            isMuted: muted,
            gain: gain,
            payload: try PreparedAudioPayloadHandle(identifier: "pcm:\(sourceID):\(chunkStart)-\(chunkEnd)"))
    }

    private func source(
        sourceID: String, samples: [Float32], muted: Bool = false, gain: AudioGain = .unity,
        revision: Int64 = 1, epoch: Int64 = 1, chunkStart: Int64 = 0, chunkEnd: Int64 = 2
    ) throws -> PreviewMixSource {
        PreviewMixSource(
            buffer: try buffer(
                revision: revision, epoch: epoch, chunkStart: chunkStart, chunkEnd: chunkEnd,
                sourceID: sourceID, muted: muted, gain: gain),
            samples: samples)
    }

    private func snapshot(revision: Int64 = 1, epoch: Int64 = 1) throws -> SchedulerSnapshot {
        SchedulerSnapshot(
            revision: ProjectRevision(raw: revision),
            epoch: PlaybackEpoch(raw: epoch),
            coverage: try ProjectTimeRange(start: try ProjectTime(ticks: 0), end: try ProjectTime(ticks: 1_000_000)),
            currentTarget: CurrentTarget(time: try ProjectTime(ticks: 0), frameRequest: FrameRequestID(raw: 1)),
            lastPublished: nil)
    }

    private func anchor(
        revision: Int64 = 1, epoch: Int64 = 1, projectSample: Int64 = 0, outputSampleTime: Int64 = 0
    ) -> PreviewAudioScheduleAnchor {
        PreviewAudioScheduleAnchor(
            revision: ProjectRevision(raw: revision), epoch: PlaybackEpoch(raw: epoch),
            projectSample: projectSample, outputSampleTime: outputSampleTime)
    }

    private func makeGraph(
        session: FakeSession, sink: FakeSink, epoch: Int64 = 1, revision: Int64 = 1, maxChunkSamples: Int64 = 1_024
    ) throws -> PreviewAudioGraph {
        try PreviewAudioGraph(
            session: session, sink: sink,
            epoch: PlaybackEpoch(raw: epoch), revision: ProjectRevision(raw: revision),
            maxChunkSamples: maxChunkSamples)
    }

    /// Activated + output-configured + anchor-configured graph, ready to mix.
    private func activatedGraph(
        maxChunkSamples: Int64 = 1_024, epoch: Int64 = 1, revision: Int64 = 1,
        anchorProjectSample: Int64 = 0, anchorOutputSampleTime: Int64 = 0
    ) throws -> (PreviewAudioGraph, FakeSink) {
        let session = FakeSession(query: try query())
        let sink = FakeSink()
        let graph = try makeGraph(
            session: session, sink: sink, epoch: epoch, revision: revision, maxChunkSamples: maxChunkSamples)
        try session.activate()
        try graph.configureOutput()
        graph.configureAnchor(anchor(
            revision: revision, epoch: epoch,
            projectSample: anchorProjectSample, outputSampleTime: anchorOutputSampleTime))
        return (graph, sink)
    }

    private func range(_ start: Int64, _ end: Int64) -> AudioSampleRange {
        AudioSampleRange(uncheckedStart: start, end: end)
    }

    // MARK: - Construction & configuration

    func testGraphConstructsWithFakesWithoutDeviceAudio() throws {
        let graph = try makeGraph(session: FakeSession(query: try query()), sink: FakeSink())
        XCTAssertNil(graph.actualOutputFormat)
        XCTAssertNil(graph.scheduleAnchor)
        XCTAssertEqual(graph.publishedState.scheduledChunkCount, 0)
    }

    func testGraphRejectsInvalidBoundedMax() {
        XCTAssertThrowsError(
            try makeGraph(session: FakeSession(query: try! query()), sink: FakeSink(), maxChunkSamples: 0)) { error in
            XCTAssertEqual(error as? PreviewAudioGraphError, .invalidBoundedMax(0))
        }
    }

    func testConfigureOutputRequiresActivatedAdapter() throws {
        let graph = try makeGraph(session: FakeSession(query: try query()), sink: FakeSink())
        XCTAssertThrowsError(try graph.configureOutput()) { error in
            XCTAssertEqual(error as? PreviewAudioGraphError, .outputConfiguredBeforeActivation)
        }
    }

    func testConfigureOutputUsesActualFormatAndRoute() throws {
        let session = FakeSession(query: try query(sampleRate: 44_100, layout: .mono, route: "headphones"))
        let sink = FakeSink()
        let graph = try makeGraph(session: session, sink: sink)
        try session.activate()
        try graph.configureOutput()
        XCTAssertEqual(graph.actualOutputFormat?.sampleRate, 44_100)
        XCTAssertEqual(graph.actualOutputFormat?.channelLayout, .mono)
        XCTAssertEqual(graph.actualOutputRoute?.identifier, "headphones")
        XCTAssertEqual(sink.configuredFormat?.sampleRate, 44_100)
        XCTAssertEqual(sink.configuredRoute?.identifier, "headphones")
    }

    // MARK: - Preconditions

    func testMixBeforeConfigureFailsClosed() throws {
        let session = FakeSession(query: try query())
        let graph = try makeGraph(session: session, sink: FakeSink())
        try session.activate()
        XCTAssertThrowsError(
            try graph.scheduleMix(range: range(0, 2),
                sources: [try source(sourceID: "s1", samples: [0, 0])], against: try snapshot())) { error in
            XCTAssertEqual(error as? PreviewAudioGraphError, .scheduledBeforeOutputConfigured)
        }
    }

    func testMixWithoutAnchorFailsClosed() throws {
        let session = FakeSession(query: try query())
        let sink = FakeSink()
        let graph = try makeGraph(session: session, sink: sink)
        try session.activate()
        try graph.configureOutput()
        XCTAssertThrowsError(
            try graph.scheduleMix(range: range(0, 2),
                sources: [try source(sourceID: "s1", samples: [0, 0])], against: try snapshot())) { error in
            XCTAssertEqual(error as? PreviewAudioGraphError, .scheduledBeforeAnchorConfigured)
        }
        XCTAssertTrue(sink.scheduled.isEmpty)
    }

    // MARK: - D-213 #1: final limiter AFTER mix

    func testFinalLimiterAppliedAfterMix() throws {
        // A [0.75, 0.75] + B [0.75, 0.75] = 1.5 → clamp → [1.0, 1.0]. ONE mixed buffer, not two.
        let (graph, sink) = try activatedGraph()
        let outcome = try graph.scheduleMix(
            range: range(0, 2),
            sources: [
                try source(sourceID: "A", samples: [0.75, 0.75]),
                try source(sourceID: "B", samples: [0.75, 0.75]),
            ],
            against: try snapshot())
        XCTAssertEqual(outcome, .scheduled)
        XCTAssertEqual(sink.scheduled.count, 1, "exactly ONE final mixed buffer")
        XCTAssertEqual(sink.scheduled[0].samples, [1.0, 1.0])
    }

    func testBelowThresholdSumStaysTransparent() throws {
        let (graph, sink) = try activatedGraph()
        try graph.scheduleMix(
            range: range(0, 1),
            sources: [
                try source(sourceID: "A", samples: [0.25], chunkStart: 0, chunkEnd: 1),
                try source(sourceID: "B", samples: [0.25], chunkStart: 0, chunkEnd: 1),
            ],
            against: try snapshot())
        XCTAssertEqual(sink.scheduled[0].samples, [0.5])
    }

    func testNegativeSumClamps() throws {
        let (graph, sink) = try activatedGraph()
        try graph.scheduleMix(
            range: range(0, 1),
            sources: [
                try source(sourceID: "A", samples: [-0.75], chunkStart: 0, chunkEnd: 1),
                try source(sourceID: "B", samples: [-0.75], chunkStart: 0, chunkEnd: 1),
            ],
            against: try snapshot())
        XCTAssertEqual(sink.scheduled[0].samples, [-1.0])
    }

    // MARK: - D-213 #4/#5: mute & gain applied

    func testMutedSourceContributesSilence() throws {
        let (graph, sink) = try activatedGraph()
        // A audible 0.5, B muted (samples would be 0.9 but must not contribute).
        try graph.scheduleMix(
            range: range(0, 1),
            sources: [
                try source(sourceID: "A", samples: [0.5], chunkStart: 0, chunkEnd: 1),
                try source(sourceID: "B", samples: [0.9], muted: true, chunkStart: 0, chunkEnd: 1),
            ],
            against: try snapshot())
        XCTAssertEqual(sink.scheduled[0].samples, [0.5], "muted source must not be audible")
    }

    func testGainAppliedBeforeSummation() throws {
        let (graph, sink) = try activatedGraph()
        // gain 250_000 == 0.25x: source sample 0.8 → 0.2 contribution.
        try graph.scheduleMix(
            range: range(0, 1),
            sources: [try source(sourceID: "A", samples: [0.8], gain: try AudioGain(raw: 250_000), chunkStart: 0, chunkEnd: 1)],
            against: try snapshot())
        XCTAssertEqual(sink.scheduled[0].samples[0], 0.2, accuracy: 1e-6)
    }

    func testUnityGainIsTransparent() throws {
        let (graph, sink) = try activatedGraph()
        try graph.scheduleMix(
            range: range(0, 1),
            sources: [try source(sourceID: "A", samples: [0.5], gain: .unity, chunkStart: 0, chunkEnd: 1)],
            against: try snapshot())
        XCTAssertEqual(sink.scheduled[0].samples, [0.5])
    }

    // MARK: - D-213 #6: non-finite fails closed

    func testNonFiniteInAnySourceFailsClosed() throws {
        let (graph, sink) = try activatedGraph()
        XCTAssertThrowsError(
            try graph.scheduleMix(
                range: range(0, 2),
                sources: [
                    try source(sourceID: "A", samples: [0.1, 0.1]),
                    try source(sourceID: "B", samples: [Float32.nan, 0.1]),
                ],
                against: try snapshot())) { error in
            XCTAssertEqual(error as? OutputOverloadStageError, .nonFiniteSample)
        }
        XCTAssertTrue(sink.scheduled.isEmpty, "non-finite mix must not reach the sink")
    }

    func testInfinityInSourceFailsClosed() throws {
        let (graph, sink) = try activatedGraph()
        XCTAssertThrowsError(
            try graph.scheduleMix(
                range: range(0, 1),
                sources: [try source(sourceID: "A", samples: [Float32.infinity], chunkStart: 0, chunkEnd: 1)],
                against: try snapshot()))
        XCTAssertTrue(sink.scheduled.isEmpty)
    }

    // MARK: - Admission / identity

    func testStaleEpochSourceRejectsWholeMix() throws {
        let (graph, sink) = try activatedGraph(epoch: 5, revision: 1)
        let outcome = try graph.scheduleMix(
            range: range(0, 2),
            sources: [try source(sourceID: "A", samples: [0, 0], epoch: 4)],   // epoch 4 vs active 5
            against: try snapshot(revision: 1, epoch: 5))
        XCTAssertEqual(outcome, .rejected(.staleEpoch))
        XCTAssertTrue(sink.scheduled.isEmpty)
        XCTAssertEqual(graph.publishedState.rejectedChunkCount, 1)
    }

    func testStaleRevisionSourceRejectsWholeMix() throws {
        let (graph, sink) = try activatedGraph(epoch: 1, revision: 7)
        let outcome = try graph.scheduleMix(
            range: range(0, 2),
            sources: [try source(sourceID: "A", samples: [0, 0], revision: 6)],
            against: try snapshot(revision: 7, epoch: 1))
        XCTAssertEqual(outcome, .rejected(.staleRevision))
        XCTAssertTrue(sink.scheduled.isEmpty)
    }

    func testAnchorEpochMismatchFailsClosed() throws {
        let session = FakeSession(query: try query())
        let sink = FakeSink()
        let graph = try makeGraph(session: session, sink: sink, epoch: 1, revision: 1)
        try session.activate(); try graph.configureOutput()
        graph.configureAnchor(anchor(revision: 1, epoch: 1))
        // chunk/snapshot epoch 2 → admission passes, anchor (epoch 1) mismatches.
        XCTAssertThrowsError(
            try graph.scheduleMix(range: range(0, 2),
                sources: [try source(sourceID: "A", samples: [0, 0], epoch: 2)],
                against: try snapshot(revision: 1, epoch: 2))) { error in
            XCTAssertEqual(error as? PreviewAudioGraphError, .anchorIdentityMismatch)
        }
    }

    func testSourceRangeMismatchFailsClosed() throws {
        let (graph, _) = try activatedGraph()
        // mix range [0,4) but source covers [0,2).
        XCTAssertThrowsError(
            try graph.scheduleMix(range: range(0, 4),
                sources: [try source(sourceID: "A", samples: [0, 0], chunkStart: 0, chunkEnd: 2)],
                against: try snapshot())) { error in
            XCTAssertEqual(error as? PreviewAudioGraphError, .sourceRangeMismatch)
        }
    }

    func testSampleCountMismatchFailsClosed() throws {
        let (graph, _) = try activatedGraph()
        XCTAssertThrowsError(
            try graph.scheduleMix(range: range(0, 4),
                sources: [try source(sourceID: "A", samples: [0, 0], chunkStart: 0, chunkEnd: 4)],
                against: try snapshot())) { error in
            XCTAssertEqual(error as? PreviewAudioGraphError, .sampleCountMismatch(expected: 4, got: 2))
        }
    }

    // MARK: - Boundedness

    func testWholeProjectMixNotAcceptedBounded() throws {
        let (graph, sink) = try activatedGraph(maxChunkSamples: 1_024)
        XCTAssertThrowsError(
            try graph.scheduleMix(range: range(0, 48_000 * 600), sources: [], against: try snapshot())) { error in
            guard case .mixExceedsBoundedMax(let requested, let max)? = error as? PreviewAudioGraphError else {
                return XCTFail("expected mixExceedsBoundedMax, got \(error)")
            }
            XCTAssertEqual(requested, 48_000 * 600)
            XCTAssertEqual(max, 1_024)
        }
        XCTAssertTrue(sink.scheduled.isEmpty)
    }

    func testEmptyMixRangeFailsClosed() throws {
        let (graph, _) = try activatedGraph()
        XCTAssertThrowsError(
            try graph.scheduleMix(range: range(5, 5), sources: [], against: try snapshot())) { error in
            XCTAssertEqual(error as? PreviewAudioGraphError, .emptyMixRange)
        }
    }

    // MARK: - Anchor / explicit output sample time

    func testExactOutputSampleTimeFormula() throws {
        // anchor: projectSample 1000 @ output 5000; mix starts at projectSample 1240 → 5240.
        let (graph, sink) = try activatedGraph(anchorProjectSample: 1_000, anchorOutputSampleTime: 5_000)
        try graph.scheduleMix(
            range: range(1_240, 1_244),
            sources: [try source(sourceID: "A", samples: [0, 0, 0, 0], chunkStart: 1_240, chunkEnd: 1_244)],
            against: try snapshot())
        XCTAssertEqual(sink.scheduled.count, 1)
        XCTAssertEqual(sink.scheduled[0].at, 5_240)
        XCTAssertEqual(sink.scheduled[0].range, range(1_240, 1_244))
    }

    func testAnchorFormulaDirectly() throws {
        let a = anchor(projectSample: 100, outputSampleTime: 700)
        XCTAssertEqual(try a.scheduledOutputSampleTime(forMixStart: 100), 700)
        XCTAssertEqual(try a.scheduledOutputSampleTime(forMixStart: 150), 750)
    }

    func testMixBeforeAnchorFailsClosed() throws {
        let (graph, _) = try activatedGraph(anchorProjectSample: 1_000, anchorOutputSampleTime: 0)
        XCTAssertThrowsError(
            try graph.scheduleMix(range: range(500, 502),
                sources: [try source(sourceID: "A", samples: [0, 0], chunkStart: 500, chunkEnd: 502)],
                against: try snapshot())) { error in
            XCTAssertEqual(
                error as? PreviewAudioGraphError, .mixBeforeAnchor(projectSample: 500, anchorProjectSample: 1_000))
        }
    }

    func testNegativeOutputSampleTimeFailsClosed() {
        let a = anchor(projectSample: 0, outputSampleTime: -10)
        XCTAssertThrowsError(try a.scheduledOutputSampleTime(forMixStart: 0)) { error in
            XCTAssertEqual(error as? PreviewAudioGraphError, .negativeOutputSampleTime(-10))
        }
    }

    func testScheduleTimeOverflowFailsClosed() {
        let a = anchor(projectSample: 0, outputSampleTime: Int64.max - 2)
        XCTAssertThrowsError(try a.scheduledOutputSampleTime(forMixStart: 10)) { error in
            XCTAssertEqual(error as? PreviewAudioGraphError, .scheduleTimeOverflow)
        }
    }

    // MARK: - Overlapping sources mixed into ONE buffer (not serialized)

    func testTwoOverlappingSourcesMixedIntoOneBuffer() throws {
        let (graph, sink) = try activatedGraph(anchorProjectSample: 0, anchorOutputSampleTime: 0)
        try graph.scheduleMix(
            range: range(100, 102),
            sources: [
                try source(sourceID: "A", samples: [0.3, 0.3], chunkStart: 100, chunkEnd: 102),
                try source(sourceID: "B", samples: [0.2, 0.2], chunkStart: 100, chunkEnd: 102),
            ],
            against: try snapshot())
        // ONE mixed buffer (summed), not two independent schedules.
        XCTAssertEqual(sink.scheduled.count, 1)
        XCTAssertEqual(sink.scheduled[0].samples[0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(sink.scheduled[0].at, 100)
        XCTAssertEqual(graph.publishedState.scheduledChunkCount, 1)
    }

    // MARK: - No implicit `at: nil`

    func testNoImplicitNilScheduleTimeInSource() throws {
        let code = strippingLineComments(try sourceText("PreviewAudioGraph.swift"))
        XCTAssertFalse(code.contains("at: nil"), "PreviewAudioGraph.swift must not schedule with `at: nil`")
    }

    // MARK: - Proof: output stage is post-mix (structural)

    func testOutputStageIsAppliedToSummedAccumulatorStructural() throws {
        let code = strippingLineComments(try sourceText("PreviewAudioGraph.swift"))
        // The output stage must be applied to the `accumulator` (the summed mix), not to a raw source
        // chunk: assert `OutputOverloadStage.process` appears inside the accumulator loop region.
        XCTAssertTrue(code.contains("for s in accumulator"), "expected a loop over the summed accumulator")
        XCTAssertTrue(code.contains("OutputOverloadStage.process"), "expected the output stage call")
        // and there is no per-source pre-mix output stage call (no process inside the per-source loop).
        XCTAssertFalse(code.contains("source.samples[i]")
                       && code.contains("OutputOverloadStage.process(source"),
                       "output stage must NOT run per source before mixing")
    }

    // MARK: - RealtimeSafeState

    func testRealtimeSafeStateIsSendableAndImmutableSnapshot() {
        func requireSendable<T: Sendable>(_ type: T.Type) {}
        requireSendable(RealtimeSafeState.self)
        let s0 = RealtimeSafeState.initial(epoch: PlaybackEpoch(raw: 1), revision: ProjectRevision(raw: 1))
        let s1 = s0.advancing(toScheduled: range(0, 4))
        XCTAssertEqual(s0.scheduledChunkCount, 0)   // original unchanged
        XCTAssertEqual(s1.scheduledChunkCount, 1)
        XCTAssertEqual(s1.lastScheduledRange, range(0, 4))
    }

    // MARK: - Structural helpers

    private func sourceText(_ fileName: String) throws -> String {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AnimiEngineCore/Realtime", isDirectory: true)
        return try String(contentsOf: dir.appendingPathComponent(fileName), encoding: .utf8)
    }

    private func strippingLineComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if let r = line.range(of: "//") { return String(line[line.startIndex..<r.lowerBound]) }
            return String(line)
        }.joined(separator: "\n")
    }

    // MARK: - Structural: realtime callback purity

    func testRealtimeCallbackPurityStructural() throws {
        let text = strippingLineComments(try sourceText("PreviewAudioGraph.swift"))
        for banned in [
            "Date(", "UUID(", ".random", "arc4random", "NSLog", "print(", "os_log",
            "NSLock", "DispatchQueue", "pthread_mutex",
            "FileManager", "write(to", "Data(contentsOf",
            ".loops", "AVMutableComposition", ".caf", ".wav",
        ] {
            XCTAssertFalse(text.contains(banned),
                "PreviewAudioGraph.swift must not reference \(banned) (realtime-safety / no-render rule)")
        }
    }

    // MARK: - Structural: Stage F types do not leak into Stage-E (and earlier) sources

    /// The Stage-F barrier/session types live ONLY in their own two Stage-F files; they must not leak
    /// into the Stage-E preview-graph layer (or any earlier Realtime source). The two Stage-F files are
    /// the legitimate definition sites and are excluded from this scan.
    func testStageFTypesDoNotLeakIntoStageESources() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AnimiEngineCore/Realtime", isDirectory: true)
        let stageFFiles: Set<String> = ["PlaybackStartBarrier.swift", "AudioMasterPreviewSession.swift"]
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && !stageFFiles.contains($0.lastPathComponent) }
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("PlaybackStartBarrier"),
                "\(file.lastPathComponent): Stage F type must not leak into Stage-E layer")
            XCTAssertFalse(text.contains("AudioMasterPreviewSession"),
                "\(file.lastPathComponent): Stage F type must not leak into Stage-E layer")
        }
    }
}
