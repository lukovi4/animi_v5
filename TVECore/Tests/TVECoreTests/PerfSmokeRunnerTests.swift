import XCTest
@testable import TVECore
@testable import TVECompilerCore

#if DEBUG

/// PR-14C: CPU-only smoke tests for PerfMetrics integration.
///
/// Tests the metrics pipeline without Metal (no MTLDevice required):
/// - PathSamplingCache + PerfMetrics recording
/// - Multi-frame playback simulation (play, scrub, loop)
/// - Cache hit rate verification
/// - Aggregate report generation
///
/// Uses mock producer closures instead of real GPU path sampling.
final class PerfSmokeRunnerTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a BezierPath triangle for testing.
    private func makeTriangle() -> BezierPath {
        BezierPath(
            vertices: [
                Vec2D(x: 0, y: 0),
                Vec2D(x: 100, y: 0),
                Vec2D(x: 50, y: 100)
            ],
            inTangents: [Vec2D.zero, Vec2D.zero, Vec2D.zero],
            outTangents: [Vec2D.zero, Vec2D.zero, Vec2D.zero],
            closed: true
        )
    }

    /// Simulates samplePathCached + perf recording (mirrors MetalRenderer logic).
    private func simulateSamplePathCached(
        cache: PathSamplingCache,
        perf: PerfMetrics,
        generationId: Int,
        pathId: PathID,
        frame: Double,
        producer: () -> BezierPath?
    ) -> BezierPath? {
        perf.beginPhase(.pathSamplingTotal)

        let result = cache.sample(
            generationId: generationId,
            pathId: pathId,
            frame: frame,
            producer: producer
        )

        perf.endPhase(.pathSamplingTotal)

        let key = PathSampleKey(
            generationId: generationId,
            pathId: pathId,
            quantizedFrame: Quantization.quantizedInt(frame, step: AnimConstants.frameQuantStep)
        )

        switch result {
        case .hitFrameMemo:
            perf.recordPathSampling(outcome: .hitFrameMemo, key: key)
        case .hitLRU:
            perf.recordPathSampling(outcome: .hitLRU, key: key)
        case .miss:
            perf.recordPathSampling(outcome: .miss, key: key)
        case .missNil:
            perf.recordPathSampling(outcome: .missNil, key: key)
        }

        switch result {
        case .hitFrameMemo(let p): return p
        case .hitLRU(let p): return p
        case .miss(let p): return p
        case .missNil: return nil
        }
    }

    // MARK: - T1: Fill + Stroke dedup (single frame)

    func testFillStrokeDedup_singleFrame() {
        let cache = PathSamplingCache()
        let perf = PerfMetrics()
        let triangle = makeTriangle()

        perf.beginFrame(index: 0)
        cache.beginFrame()

        // Fill: miss
        _ = simulateSamplePathCached(
            cache: cache, perf: perf,
            generationId: 0, pathId: PathID(0), frame: 10.0,
            producer: { triangle }
        )
        perf.recordCommand(.drawShape(pathId: PathID(0), fillColor: [1, 0, 0], fillOpacity: 100, layerOpacity: 1, frame: 10))

        // Stroke: frameMemo hit (same pathId + frame)
        _ = simulateSamplePathCached(
            cache: cache, perf: perf,
            generationId: 0, pathId: PathID(0), frame: 10.0,
            producer: { triangle }
        )
        perf.recordCommand(.drawStroke(pathId: PathID(0), strokeColor: [0, 1, 0], strokeOpacity: 1, strokeWidth: 2, lineCap: 2, lineJoin: 2, miterLimit: 4, layerOpacity: 1, frame: 10))

        let report = perf.endFrame()

        XCTAssertEqual(report.counters.pathSamplingCallsTotal, 2)
        XCTAssertEqual(report.counters.pathSamplingHitFrameMemo, 1, "Stroke should hit frameMemo from fill")
        XCTAssertEqual(report.counters.pathSamplingMiss, 1, "Fill should be a miss")
        XCTAssertEqual(report.counters.commandsDrawShape, 1)
        XCTAssertEqual(report.counters.commandsDrawStroke, 1)
        XCTAssertEqual(report.pathSamplingHitRate, 0.5, accuracy: 0.001)
        XCTAssertEqual(report.counters.pathSamplingUniqueKeysFrame, 1, "Same key accessed twice")
        XCTAssertEqual(report.pathSamplingDuplicationFactor, 2.0, accuracy: 0.001)
    }

    // MARK: - T2: Multi-frame playback (sequential)

    func testMultiFramePlayback_sequential() {
        let cache = PathSamplingCache()
        let perf = PerfMetrics()
        let triangle = makeTriangle()
        var reports: [PerfReport] = []

        // Simulate 5 sequential frames (each has 2 paths: fill + stroke)
        for frameIdx in 0..<5 {
            perf.beginFrame(index: frameIdx)
            cache.beginFrame()

            let frame = Double(frameIdx)

            // Path 0: fill
            _ = simulateSamplePathCached(
                cache: cache, perf: perf,
                generationId: 0, pathId: PathID(0), frame: frame,
                producer: { triangle }
            )

            // Path 0: stroke (same frame → frameMemo hit)
            _ = simulateSamplePathCached(
                cache: cache, perf: perf,
                generationId: 0, pathId: PathID(0), frame: frame,
                producer: { triangle }
            )

            reports.append(perf.endFrame())
        }

        // Each frame: 1 miss + 1 frameMemo hit = 50% hit rate
        for report in reports {
            XCTAssertEqual(report.counters.pathSamplingCallsTotal, 2)
            XCTAssertEqual(report.counters.pathSamplingHitFrameMemo, 1)
            XCTAssertEqual(report.counters.pathSamplingMiss, 1)
        }

        let agg = PerfAggregateReport.aggregate(reports)
        XCTAssertEqual(agg.frameCount, 5)
        XCTAssertEqual(agg.totalCounters.pathSamplingCallsTotal, 10)
        XCTAssertEqual(agg.totalCounters.pathSamplingHitFrameMemo, 5)
        XCTAssertEqual(agg.pathSamplingHitRate, 0.5, accuracy: 0.001)
    }

    // MARK: - T3: Loop playback (LRU cross-frame reuse)

    func testLoopPlayback_lruReuse() {
        let cache = PathSamplingCache(maxLRUEntries: 64)
        let perf = PerfMetrics()
        let triangle = makeTriangle()
        var reports: [PerfReport] = []

        // 3 frames of animation content
        let frameCount = 3
        // Play 2 full loops
        let totalFrames = frameCount * 2

        for idx in 0..<totalFrames {
            perf.beginFrame(index: idx)
            cache.beginFrame()

            let frame = Double(idx % frameCount) // loops: 0,1,2,0,1,2

            _ = simulateSamplePathCached(
                cache: cache, perf: perf,
                generationId: 0, pathId: PathID(0), frame: frame,
                producer: { triangle }
            )

            reports.append(perf.endFrame())
        }

        // First loop (frames 0-2): all misses
        for i in 0..<3 {
            XCTAssertEqual(reports[i].counters.pathSamplingMiss, 1, "First loop frame \(i) should be miss")
        }

        // Second loop (frames 3-5): all LRU hits (same frames revisited)
        for i in 3..<6 {
            XCTAssertEqual(reports[i].counters.pathSamplingHitLRU, 1, "Second loop frame \(i) should be LRU hit")
        }

        let agg = PerfAggregateReport.aggregate(reports)
        XCTAssertEqual(agg.totalCounters.pathSamplingCallsTotal, 6)
        XCTAssertEqual(agg.totalCounters.pathSamplingHitLRU, 3)
        XCTAssertEqual(agg.totalCounters.pathSamplingMiss, 3)
        XCTAssertEqual(agg.pathSamplingHitRate, 0.5, accuracy: 0.001)
    }

    // MARK: - T4: Scrub playback (revisit + new frames)

    func testScrubPlayback_mixedHitsAndMisses() {
        let cache = PathSamplingCache(maxLRUEntries: 64)
        let perf = PerfMetrics()
        let triangle = makeTriangle()
        var reports: [PerfReport] = []

        // Scrub pattern: 0, 1, 2, 1, 0, 3
        let scrubFrames: [Double] = [0, 1, 2, 1, 0, 3]

        for (idx, frame) in scrubFrames.enumerated() {
            perf.beginFrame(index: idx)
            cache.beginFrame()

            _ = simulateSamplePathCached(
                cache: cache, perf: perf,
                generationId: 0, pathId: PathID(0), frame: frame,
                producer: { triangle }
            )

            reports.append(perf.endFrame())
        }

        // Frame 0: miss (new)
        XCTAssertEqual(reports[0].counters.pathSamplingMiss, 1)
        // Frame 1: miss (new)
        XCTAssertEqual(reports[1].counters.pathSamplingMiss, 1)
        // Frame 2: miss (new)
        XCTAssertEqual(reports[2].counters.pathSamplingMiss, 1)
        // Frame 1 revisited: LRU hit
        XCTAssertEqual(reports[3].counters.pathSamplingHitLRU, 1)
        // Frame 0 revisited: LRU hit
        XCTAssertEqual(reports[4].counters.pathSamplingHitLRU, 1)
        // Frame 3: miss (new)
        XCTAssertEqual(reports[5].counters.pathSamplingMiss, 1)

        let agg = PerfAggregateReport.aggregate(reports)
        // 4 misses + 2 LRU hits out of 6
        XCTAssertEqual(agg.totalCounters.pathSamplingMiss, 4)
        XCTAssertEqual(agg.totalCounters.pathSamplingHitLRU, 2)
        XCTAssertEqual(agg.pathSamplingHitRate, 2.0 / 6.0, accuracy: 0.001)
    }

    // MARK: - T5: Multiple paths per frame

    func testMultiplePaths_perFrame() {
        let cache = PathSamplingCache()
        let perf = PerfMetrics()
        let triangle = makeTriangle()

        perf.beginFrame(index: 0)
        cache.beginFrame()

        // 3 different paths, each with fill + stroke
        for pathIdx in 0..<3 {
            let pid = PathID(pathIdx)

            // Fill (miss)
            _ = simulateSamplePathCached(
                cache: cache, perf: perf,
                generationId: 0, pathId: pid, frame: 0.0,
                producer: { triangle }
            )

            // Stroke (frameMemo hit)
            _ = simulateSamplePathCached(
                cache: cache, perf: perf,
                generationId: 0, pathId: pid, frame: 0.0,
                producer: { triangle }
            )
        }

        let report = perf.endFrame()

        XCTAssertEqual(report.counters.pathSamplingCallsTotal, 6)
        XCTAssertEqual(report.counters.pathSamplingMiss, 3, "3 fills should be misses")
        XCTAssertEqual(report.counters.pathSamplingHitFrameMemo, 3, "3 strokes should be frameMemo hits")
        XCTAssertEqual(report.counters.pathSamplingUniqueKeysFrame, 3, "3 unique path keys")
        XCTAssertEqual(report.pathSamplingDuplicationFactor, 2.0, accuracy: 0.001, "Each key accessed twice")
        XCTAssertEqual(report.pathSamplingHitRate, 0.5, accuracy: 0.001)
    }

    // MARK: - T6: Aggregate report correctness

    func testAggregateReport_p95Calculation() {
        let perf = PerfMetrics()
        var reports: [PerfReport] = []

        // Generate 20 frames with varying load
        for i in 0..<20 {
            perf.beginFrame(index: i)
            perf.beginPhase(.frameTotal)
            // Simulate varying work
            var sum = 0
            let iterations = (i == 19) ? 100_000 : 1_000 // Last frame is slower
            for j in 0..<iterations { sum += j }
            _ = sum
            perf.endPhase(.frameTotal)
            reports.append(perf.endFrame())
        }

        let agg = PerfAggregateReport.aggregate(reports)

        XCTAssertEqual(agg.frameCount, 20)
        XCTAssertGreaterThanOrEqual(agg.maxFrameNs, agg.p95FrameNs)
        XCTAssertGreaterThanOrEqual(agg.p95FrameNs, agg.avgFrameNs)
        XCTAssertGreaterThanOrEqual(agg.avgFrameNs, agg.minFrameNs)
    }

    // MARK: - T7: Command counting in smoke scenario

    func testCommandCounting_smokeScenario() {
        let perf = PerfMetrics()
        perf.beginFrame(index: 0)

        // Simulate a typical frame command sequence
        let commands: [RenderCommand] = [
            .beginGroup(name: "root"),
            .pushTransform(.identity),
            .pushClipRect(RectD(x: 0, y: 0, width: 500, height: 500)),
            .drawImage(assetId: "bg", opacity: 1.0),
            .drawShape(pathId: PathID(0), fillColor: [1, 0, 0], fillOpacity: 100, layerOpacity: 1, frame: 0),
            .drawStroke(pathId: PathID(0), strokeColor: [0, 0, 0], strokeOpacity: 1, strokeWidth: 2, lineCap: 2, lineJoin: 2, miterLimit: 4, layerOpacity: 1, frame: 0),
            .popClipRect,
            .popTransform,
            .endGroup
        ]

        for cmd in commands {
            perf.recordCommand(cmd)
        }
        perf.recordMask()
        perf.recordMatte()

        let report = perf.endFrame()

        XCTAssertEqual(report.counters.commandsTotal, 9)
        XCTAssertEqual(report.counters.commandsDrawImage, 1)
        XCTAssertEqual(report.counters.commandsDrawShape, 1)
        XCTAssertEqual(report.counters.commandsDrawStroke, 1)
        XCTAssertEqual(report.counters.commandsBeginGroup, 1)
        XCTAssertEqual(report.counters.commandsEndGroup, 1)
        XCTAssertEqual(report.counters.commandsPushTransform, 1)
        XCTAssertEqual(report.counters.commandsPopTransform, 1)
        XCTAssertEqual(report.counters.commandsPushClipRect, 1)
        XCTAssertEqual(report.counters.commandsPopClipRect, 1)
        XCTAssertEqual(report.counters.maskCountTotal, 1)
        XCTAssertEqual(report.counters.mattePairsTotal, 1)
    }
}

#endif
