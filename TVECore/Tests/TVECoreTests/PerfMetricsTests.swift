import XCTest
@testable import TVECore
@testable import TVECompilerCore

#if DEBUG

/// Tests for PR-14C: PerfMetrics
/// Verifies counters, phase timing, JSON determinism, and derived metrics.
final class PerfMetricsTests: XCTestCase {

    // MARK: - Counters

    func testCounters_initiallyZero() {
        let perf = PerfMetrics()
        perf.beginFrame(index: 0)
        let report = perf.endFrame()

        XCTAssertEqual(report.counters.pathSamplingCallsTotal, 0)
        XCTAssertEqual(report.counters.shapeCacheFillHit, 0)
        XCTAssertEqual(report.counters.commandsTotal, 0)
        XCTAssertEqual(report.counters.maskCountTotal, 0)
        XCTAssertEqual(report.counters.mattePairsTotal, 0)
    }

    func testCounters_pathSamplingOutcomes() {
        let perf = PerfMetrics()
        perf.beginFrame(index: 0)

        let key1 = PathSampleKey(generationId: 0, pathId: PathID(0), quantizedFrame: 100)
        let key2 = PathSampleKey(generationId: 0, pathId: PathID(1), quantizedFrame: 100)

        perf.recordPathSampling(outcome: .hitFrameMemo, key: key1)
        perf.recordPathSampling(outcome: .hitLRU, key: key1)
        perf.recordPathSampling(outcome: .miss, key: key2)
        perf.recordPathSampling(outcome: .missNil, key: key2)

        let report = perf.endFrame()

        XCTAssertEqual(report.counters.pathSamplingCallsTotal, 4)
        XCTAssertEqual(report.counters.pathSamplingHitFrameMemo, 1)
        XCTAssertEqual(report.counters.pathSamplingHitLRU, 1)
        XCTAssertEqual(report.counters.pathSamplingMiss, 2)
        XCTAssertEqual(report.counters.pathSamplingProducerCalls, 2)
        XCTAssertEqual(report.counters.pathSamplingNilResults, 1)
        XCTAssertEqual(report.counters.pathSamplingUniqueKeysFrame, 2, "Two distinct keys should be counted")
    }

    func testCounters_shapeCacheFillAndStroke() {
        let perf = PerfMetrics()
        perf.beginFrame(index: 0)

        perf.recordShapeFill(outcome: .hit)
        perf.recordShapeFill(outcome: .miss)
        perf.recordShapeFill(outcome: .missEvicted)

        perf.recordShapeStroke(outcome: .hit)
        perf.recordShapeStroke(outcome: .miss)

        let report = perf.endFrame()

        XCTAssertEqual(report.counters.shapeCacheFillHit, 1)
        XCTAssertEqual(report.counters.shapeCacheFillMiss, 2)
        XCTAssertEqual(report.counters.shapeCacheStrokeHit, 1)
        XCTAssertEqual(report.counters.shapeCacheStrokeMiss, 1)
        XCTAssertEqual(report.counters.shapeCacheEvictions, 1, "Only missEvicted should increment evictions")
    }

    func testCounters_renderCommands() {
        let perf = PerfMetrics()
        perf.beginFrame(index: 0)

        perf.recordCommand(.drawImage(assetId: "a", opacity: 1.0))
        perf.recordCommand(.drawShape(pathId: PathID(0), fillColor: [1, 0, 0], fillOpacity: 100, layerOpacity: 1, frame: 0))
        perf.recordCommand(.drawStroke(pathId: PathID(0), strokeColor: [0, 1, 0], strokeOpacity: 1, strokeWidth: 2, lineCap: 2, lineJoin: 2, miterLimit: 4, layerOpacity: 1, frame: 0))
        perf.recordCommand(.pushTransform(.identity))
        perf.recordCommand(.popTransform)
        perf.recordCommand(.beginGroup(name: "g1"))
        perf.recordCommand(.endGroup)
        perf.recordCommand(.pushClipRect(RectD(x: 0, y: 0, width: 100, height: 100)))
        perf.recordCommand(.popClipRect)

        let report = perf.endFrame()

        XCTAssertEqual(report.counters.commandsTotal, 9)
        XCTAssertEqual(report.counters.commandsDrawImage, 1)
        XCTAssertEqual(report.counters.commandsDrawShape, 1)
        XCTAssertEqual(report.counters.commandsDrawStroke, 1)
        XCTAssertEqual(report.counters.commandsPushTransform, 1)
        XCTAssertEqual(report.counters.commandsPopTransform, 1)
        XCTAssertEqual(report.counters.commandsBeginGroup, 1)
        XCTAssertEqual(report.counters.commandsEndGroup, 1)
        XCTAssertEqual(report.counters.commandsPushClipRect, 1)
        XCTAssertEqual(report.counters.commandsPopClipRect, 1)
    }

    func testCounters_masksAndMattes() {
        let perf = PerfMetrics()
        perf.beginFrame(index: 0)

        perf.recordMask()
        perf.recordMask()
        perf.recordMatte()

        let report = perf.endFrame()

        XCTAssertEqual(report.counters.maskCountTotal, 2)
        XCTAssertEqual(report.counters.mattePairsTotal, 1)
    }

    // MARK: - Frame Lifecycle

    func testBeginFrame_resetsCounters() {
        let perf = PerfMetrics()

        // Frame 0: accumulate some counters
        perf.beginFrame(index: 0)
        perf.recordMask()
        perf.recordMatte()
        let key = PathSampleKey(generationId: 0, pathId: PathID(0), quantizedFrame: 0)
        perf.recordPathSampling(outcome: .miss, key: key)
        let r0 = perf.endFrame()
        XCTAssertEqual(r0.counters.maskCountTotal, 1)
        XCTAssertEqual(r0.counters.pathSamplingCallsTotal, 1)

        // Frame 1: counters should be reset
        perf.beginFrame(index: 1)
        let r1 = perf.endFrame()
        XCTAssertEqual(r1.frameIndex, 1)
        XCTAssertEqual(r1.counters.maskCountTotal, 0)
        XCTAssertEqual(r1.counters.pathSamplingCallsTotal, 0)
        XCTAssertEqual(r1.counters.commandsTotal, 0)
    }

    func testEndFrame_producesReport() {
        let perf = PerfMetrics()
        perf.beginFrame(index: 42)
        let report = perf.endFrame()

        XCTAssertEqual(report.frameIndex, 42)
        XCTAssertNotNil(perf.lastReport)
        XCTAssertEqual(perf.lastReport?.frameIndex, 42)
    }

    // MARK: - Phase Timing

    func testPhaseTiming_producesNonZeroDuration() {
        let perf = PerfMetrics()
        perf.beginFrame(index: 0)

        perf.beginPhase(.frameTotal)
        // Small busy-wait to ensure measurable duration
        var sum = 0
        for i in 0..<10_000 { sum += i }
        _ = sum // prevent optimization
        perf.endPhase(.frameTotal)

        let report = perf.endFrame()
        let frameTotalNs = report.timingsNs[.frameTotal] ?? 0
        XCTAssertGreaterThan(frameTotalNs, 0, "Phase timing should produce non-zero nanoseconds")
    }

    func testPhaseTiming_accumulatesMultipleCalls() {
        let perf = PerfMetrics()
        perf.beginFrame(index: 0)

        // Two separate measurements of same phase
        perf.beginPhase(.executeFillTotal)
        var sum = 0
        for i in 0..<5_000 { sum += i }
        _ = sum
        perf.endPhase(.executeFillTotal)

        perf.beginPhase(.executeFillTotal)
        for i in 0..<5_000 { sum += i }
        _ = sum
        perf.endPhase(.executeFillTotal)

        let report = perf.endFrame()
        let fillNs = report.timingsNs[.executeFillTotal] ?? 0
        XCTAssertGreaterThan(fillNs, 0, "Accumulated phase timing should be positive")
    }

    func testPhaseTiming_resetOnBeginFrame() {
        let perf = PerfMetrics()

        perf.beginFrame(index: 0)
        perf.beginPhase(.frameTotal)
        var sum = 0
        for i in 0..<10_000 { sum += i }
        _ = sum
        perf.endPhase(.frameTotal)
        let r0 = perf.endFrame()
        XCTAssertGreaterThan(r0.timingsNs[.frameTotal] ?? 0, 0)

        // New frame: timings should reset
        perf.beginFrame(index: 1)
        let r1 = perf.endFrame()
        XCTAssertEqual(r1.timingsNs[.frameTotal] ?? 0, 0, "Phase timings should reset on new frame")
    }

    // MARK: - Derived Metrics

    func testDerivedMetrics_pathSamplingHitRate() {
        let perf = PerfMetrics()
        perf.beginFrame(index: 0)

        let key = PathSampleKey(generationId: 0, pathId: PathID(0), quantizedFrame: 0)
        perf.recordPathSampling(outcome: .hitFrameMemo, key: key)
        perf.recordPathSampling(outcome: .hitLRU, key: key)
        perf.recordPathSampling(outcome: .miss, key: key)
        perf.recordPathSampling(outcome: .missNil, key: key)

        let report = perf.endFrame()
        // 2 hits out of 4 total = 50%
        XCTAssertEqual(report.pathSamplingHitRate, 0.5, accuracy: 0.001)
    }

    func testDerivedMetrics_shapeCacheHitRates() {
        let perf = PerfMetrics()
        perf.beginFrame(index: 0)

        // Fill: 3 hits, 1 miss = 75%
        perf.recordShapeFill(outcome: .hit)
        perf.recordShapeFill(outcome: .hit)
        perf.recordShapeFill(outcome: .hit)
        perf.recordShapeFill(outcome: .miss)

        // Stroke: 1 hit, 1 miss = 50%
        perf.recordShapeStroke(outcome: .hit)
        perf.recordShapeStroke(outcome: .miss)

        let report = perf.endFrame()
        XCTAssertEqual(report.shapeCacheFillHitRate, 0.75, accuracy: 0.001)
        XCTAssertEqual(report.shapeCacheStrokeHitRate, 0.5, accuracy: 0.001)
    }

    func testDerivedMetrics_duplicationFactor() {
        let perf = PerfMetrics()
        perf.beginFrame(index: 0)

        // 4 calls, but only 2 unique keys → factor = 2.0
        let key1 = PathSampleKey(generationId: 0, pathId: PathID(0), quantizedFrame: 0)
        let key2 = PathSampleKey(generationId: 0, pathId: PathID(1), quantizedFrame: 0)

        perf.recordPathSampling(outcome: .miss, key: key1)
        perf.recordPathSampling(outcome: .hitFrameMemo, key: key1)
        perf.recordPathSampling(outcome: .miss, key: key2)
        perf.recordPathSampling(outcome: .hitFrameMemo, key: key2)

        let report = perf.endFrame()
        XCTAssertEqual(report.pathSamplingDuplicationFactor, 2.0, accuracy: 0.001)
    }

    func testDerivedMetrics_zeroTotalReturnsZero() {
        let perf = PerfMetrics()
        perf.beginFrame(index: 0)
        let report = perf.endFrame()

        XCTAssertEqual(report.pathSamplingHitRate, 0)
        XCTAssertEqual(report.shapeCacheFillHitRate, 0)
        XCTAssertEqual(report.shapeCacheStrokeHitRate, 0)
        XCTAssertEqual(report.pathSamplingDuplicationFactor, 0)
    }

    // MARK: - JSON Serialization

    func testJSON_determinisicKeyOrder() {
        let perf = PerfMetrics()
        perf.beginFrame(index: 7)
        perf.recordMask()
        let key = PathSampleKey(generationId: 0, pathId: PathID(0), quantizedFrame: 0)
        perf.recordPathSampling(outcome: .miss, key: key)
        let report = perf.endFrame()

        let json1 = report.toJSON()
        let json2 = report.toJSON()

        XCTAssertEqual(json1, json2, "JSON must be deterministic across calls")
        XCTAssertTrue(json1.contains("\"frameIndex\": 7"), "JSON should contain frameIndex")
        XCTAssertTrue(json1.contains("\"mask_count_total\": 1"), "JSON should contain mask count")
        XCTAssertTrue(json1.contains("\"pathSampling_calls_total\": 1"), "JSON should contain path sampling calls")
    }

    func testJSON_containsAllExpectedSections() {
        let perf = PerfMetrics()
        perf.beginFrame(index: 0)
        let report = perf.endFrame()
        let json = report.toJSON()

        XCTAssertTrue(json.contains("\"timingsNs\""))
        XCTAssertTrue(json.contains("\"counters\""))
        XCTAssertTrue(json.contains("\"derived\""))
        XCTAssertTrue(json.contains("\"pathSampling_hit_rate\""))
        XCTAssertTrue(json.contains("\"shapeCache_fill_hit_rate\""))
        XCTAssertTrue(json.contains("\"shapeCache_stroke_hit_rate\""))
        XCTAssertTrue(json.contains("\"pathSampling_duplication_factor\""))
    }

    func testJSON_fixedPhaseOrder() {
        let perf = PerfMetrics()
        perf.beginFrame(index: 0)
        let report = perf.endFrame()
        let json = report.toJSON()

        // Verify phases appear in enum declaration order
        let frameIdx = json.range(of: "frame_total")!.lowerBound
        let executeIdx = json.range(of: "execute_commands_total")!.lowerBound
        let fillIdx = json.range(of: "execute_fill_total")!.lowerBound
        let strokeIdx = json.range(of: "execute_stroke_total")!.lowerBound
        let masksIdx = json.range(of: "execute_masks_total")!.lowerBound
        let mattesIdx = json.range(of: "execute_mattes_total")!.lowerBound
        let pathIdx = json.range(of: "path_sampling_total")!.lowerBound
        let shapeIdx = json.range(of: "shape_cache_total")!.lowerBound

        XCTAssertLessThan(frameIdx, executeIdx)
        XCTAssertLessThan(executeIdx, fillIdx)
        XCTAssertLessThan(fillIdx, strokeIdx)
        XCTAssertLessThan(strokeIdx, masksIdx)
        XCTAssertLessThan(masksIdx, mattesIdx)
        XCTAssertLessThan(mattesIdx, pathIdx)
        XCTAssertLessThan(pathIdx, shapeIdx)
    }

    // MARK: - Summary Line

    func testSummaryLine_containsKeyInfo() {
        let perf = PerfMetrics()
        perf.beginFrame(index: 3)
        perf.recordCommand(.drawShape(pathId: PathID(0), fillColor: [1, 0, 0], fillOpacity: 100, layerOpacity: 1, frame: 0))
        perf.recordMask()
        let report = perf.endFrame()

        let line = report.summaryLine()
        XCTAssertTrue(line.hasPrefix("[PERF]"), "Summary should start with [PERF]")
        XCTAssertTrue(line.contains("f3"), "Summary should include frame index")
        XCTAssertTrue(line.contains("cmds=1"), "Summary should include command count")
        XCTAssertTrue(line.contains("fills=1"), "Summary should include fill count")
        XCTAssertTrue(line.contains("masks=1"), "Summary should include mask count")
    }

    // MARK: - Aggregate Report

    func testAggregateReport_combinesMultipleFrames() {
        let perf = PerfMetrics()

        // Frame 0
        perf.beginFrame(index: 0)
        perf.beginPhase(.frameTotal)
        perf.recordMask()
        perf.recordCommand(.drawImage(assetId: "a", opacity: 1))
        perf.endPhase(.frameTotal)
        let r0 = perf.endFrame()

        // Frame 1
        perf.beginFrame(index: 1)
        perf.beginPhase(.frameTotal)
        perf.recordMask()
        perf.recordMask()
        perf.recordCommand(.drawImage(assetId: "b", opacity: 1))
        perf.recordCommand(.drawImage(assetId: "c", opacity: 1))
        perf.endPhase(.frameTotal)
        let r1 = perf.endFrame()

        let agg = PerfAggregateReport.aggregate([r0, r1])

        XCTAssertEqual(agg.frameCount, 2)
        XCTAssertEqual(agg.totalCounters.maskCountTotal, 3)
        XCTAssertEqual(agg.totalCounters.commandsTotal, 3)
        XCTAssertEqual(agg.totalCounters.commandsDrawImage, 3)
        XCTAssertEqual(agg.frameTimingsNs.count, 2)
        XCTAssertGreaterThanOrEqual(agg.maxFrameNs, agg.minFrameNs)
    }

    func testAggregateReport_emptyInput() {
        let agg = PerfAggregateReport.aggregate([])

        XCTAssertEqual(agg.frameCount, 0)
        XCTAssertEqual(agg.minFrameNs, 0)
        XCTAssertEqual(agg.maxFrameNs, 0)
        XCTAssertEqual(agg.avgFrameNs, 0)
        XCTAssertEqual(agg.p95FrameNs, 0)
    }

    func testAggregateReport_hitRates() {
        let perf = PerfMetrics()

        // Frame with all hits
        perf.beginFrame(index: 0)
        let key = PathSampleKey(generationId: 0, pathId: PathID(0), quantizedFrame: 0)
        perf.recordPathSampling(outcome: .hitFrameMemo, key: key)
        perf.recordPathSampling(outcome: .hitLRU, key: key)
        perf.recordShapeFill(outcome: .hit)
        perf.recordShapeStroke(outcome: .hit)
        let r0 = perf.endFrame()

        // Frame with all misses
        perf.beginFrame(index: 1)
        perf.recordPathSampling(outcome: .miss, key: key)
        perf.recordPathSampling(outcome: .missNil, key: key)
        perf.recordShapeFill(outcome: .miss)
        perf.recordShapeStroke(outcome: .miss)
        let r1 = perf.endFrame()

        let agg = PerfAggregateReport.aggregate([r0, r1])

        // 2 hits out of 4 total
        XCTAssertEqual(agg.pathSamplingHitRate, 0.5, accuracy: 0.001)
        // 1 hit out of 2 total
        XCTAssertEqual(agg.shapeCacheFillHitRate, 0.5, accuracy: 0.001)
        XCTAssertEqual(agg.shapeCacheStrokeHitRate, 0.5, accuracy: 0.001)
    }

    // MARK: - PerfPhase

    func testPerfPhase_allCasesCount() {
        XCTAssertEqual(PerfPhase.allCases.count, 8, "Should have 8 named phases")
    }

    func testPerfPhase_rawValues_areSnakeCase() {
        for phase in PerfPhase.allCases {
            XCTAssertFalse(phase.rawValue.contains(" "), "Phase rawValue should not contain spaces: \(phase.rawValue)")
            XCTAssertTrue(phase.rawValue.contains("_"), "Phase rawValue should use underscores: \(phase.rawValue)")
        }
    }
}

#endif
