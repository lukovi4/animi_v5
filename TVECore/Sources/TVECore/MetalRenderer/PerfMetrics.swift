import Foundation

// MARK: - PR-14C: Performance Metrics

// All profiling code is compiled only in DEBUG builds.
// Even in DEBUG, metrics collection is disabled by default —
// enable via `MetalRendererOptions.enablePerfMetrics = true`.

#if DEBUG

// MARK: - Perf Phase

/// Named phases for frame-level timing.
/// Each phase can be measured independently via `beginPhase` / `endPhase`.
enum PerfPhase: String, CaseIterable {
    case frameTotal = "frame_total"
    case executeCommandsTotal = "execute_commands_total"
    case executeFillTotal = "execute_fill_total"
    case executeStrokeTotal = "execute_stroke_total"
    case executeMasksTotal = "execute_masks_total"
    case executeMattesTotal = "execute_mattes_total"
    case pathSamplingTotal = "path_sampling_total"
    case shapeCacheTotal = "shape_cache_total"
}

// MARK: - Cache Result

/// Outcome of a cache lookup — used by both ShapeCache and PathSamplingCache
/// to report hit/miss without storing counters internally.
enum CacheOutcome {
    case hit
    case miss
    case missEvicted
}

// MARK: - Path Sampling Result

/// Outcome of a PathSamplingCache lookup.
enum PathSamplingOutcome {
    case hitFrameMemo
    case hitLRU
    case miss
    case missNil
}

// MARK: - Perf Counters

/// Accumulates per-frame operation counts. No allocations — plain integer fields.
/// All fields are zeroed at `beginFrame()`.
struct PerfCounters {
    // -- Path sampling cache --
    var pathSamplingCallsTotal: Int = 0
    var pathSamplingHitFrameMemo: Int = 0
    var pathSamplingHitLRU: Int = 0
    var pathSamplingMiss: Int = 0
    var pathSamplingProducerCalls: Int = 0
    var pathSamplingNilResults: Int = 0
    var pathSamplingUniqueKeysFrame: Int = 0

    // -- Shape cache --
    var shapeCacheFillHit: Int = 0
    var shapeCacheFillMiss: Int = 0
    var shapeCacheStrokeHit: Int = 0
    var shapeCacheStrokeMiss: Int = 0
    var shapeCacheEvictions: Int = 0

    // -- Render commands --
    var commandsTotal: Int = 0
    var commandsDrawImage: Int = 0
    var commandsDrawShape: Int = 0
    var commandsDrawStroke: Int = 0
    var commandsPushTransform: Int = 0
    var commandsPopTransform: Int = 0
    var commandsBeginGroup: Int = 0
    var commandsEndGroup: Int = 0
    var commandsPushClipRect: Int = 0
    var commandsPopClipRect: Int = 0

    // -- Masks / Mattes --
    var maskCountTotal: Int = 0
    var mattePairsTotal: Int = 0
}

// MARK: - Perf Report

/// Immutable snapshot of one frame's metrics.
/// Created at `endFrame()` for aggregation or serialization.
struct PerfReport {
    let frameIndex: Int
    let counters: PerfCounters
    let timingsNs: [PerfPhase: UInt64]

    // MARK: - Derived Metrics

    var pathSamplingHitRate: Double {
        let total = counters.pathSamplingCallsTotal
        guard total > 0 else { return 0 }
        let hits = counters.pathSamplingHitFrameMemo + counters.pathSamplingHitLRU
        return Double(hits) / Double(total)
    }

    var shapeCacheFillHitRate: Double {
        let total = counters.shapeCacheFillHit + counters.shapeCacheFillMiss
        guard total > 0 else { return 0 }
        return Double(counters.shapeCacheFillHit) / Double(total)
    }

    var shapeCacheStrokeHitRate: Double {
        let total = counters.shapeCacheStrokeHit + counters.shapeCacheStrokeMiss
        guard total > 0 else { return 0 }
        return Double(counters.shapeCacheStrokeHit) / Double(total)
    }

    var pathSamplingDuplicationFactor: Double {
        guard counters.pathSamplingUniqueKeysFrame > 0 else { return 0 }
        return Double(counters.pathSamplingCallsTotal) / Double(counters.pathSamplingUniqueKeysFrame)
    }

    // MARK: - JSON Serialization (deterministic key order)

    /// Fixed locale for numeric formatting — guarantees dot decimal separator
    /// regardless of device/CI locale (e.g. German locale would produce commas).
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    /// Produces a JSON string with fixed key order for deterministic diffs.
    /// All floating-point values use `en_US_POSIX` locale for cross-device determinism.
    /// Call only at end of frame/run — never in hot path.
    func toJSON() -> String {
        var lines: [String] = []
        lines.append("{")
        lines.append("  \"frameIndex\": \(frameIndex),")

        // Timings (sorted by enum declaration order)
        lines.append("  \"timingsNs\": {")
        let phases = PerfPhase.allCases
        for (idx, phase) in phases.enumerated() {
            let value = timingsNs[phase] ?? 0
            let comma = idx < phases.count - 1 ? "," : ""
            lines.append("    \"\(phase.rawValue)\": \(value)\(comma)")
        }
        lines.append("  },")

        // Counters (fixed order)
        lines.append("  \"counters\": {")
        let counterFields: [(String, Int)] = [
            ("pathSampling_calls_total", counters.pathSamplingCallsTotal),
            ("pathSampling_cache_hit_frameMemo", counters.pathSamplingHitFrameMemo),
            ("pathSampling_cache_hit_lru", counters.pathSamplingHitLRU),
            ("pathSampling_cache_miss", counters.pathSamplingMiss),
            ("pathSampling_producer_calls", counters.pathSamplingProducerCalls),
            ("pathSampling_nil_results", counters.pathSamplingNilResults),
            ("pathSampling_uniqueKeys_frame", counters.pathSamplingUniqueKeysFrame),
            ("shapeCache_fill_hit", counters.shapeCacheFillHit),
            ("shapeCache_fill_miss", counters.shapeCacheFillMiss),
            ("shapeCache_stroke_hit", counters.shapeCacheStrokeHit),
            ("shapeCache_stroke_miss", counters.shapeCacheStrokeMiss),
            ("shapeCache_evictions", counters.shapeCacheEvictions),
            ("commands_total", counters.commandsTotal),
            ("commands_drawImage", counters.commandsDrawImage),
            ("commands_drawShape", counters.commandsDrawShape),
            ("commands_drawStroke", counters.commandsDrawStroke),
            ("commands_pushTransform", counters.commandsPushTransform),
            ("commands_popTransform", counters.commandsPopTransform),
            ("mask_count_total", counters.maskCountTotal),
            ("matte_pairs_total", counters.mattePairsTotal)
        ]
        for (idx, field) in counterFields.enumerated() {
            let comma = idx < counterFields.count - 1 ? "," : ""
            lines.append("    \"\(field.0)\": \(field.1)\(comma)")
        }
        lines.append("  },")

        // Derived
        lines.append("  \"derived\": {")
        let loc = Self.posixLocale
        lines.append("    \"pathSampling_hit_rate\": \(String(format: "%.4f", locale: loc, pathSamplingHitRate)),")
        lines.append("    \"shapeCache_fill_hit_rate\": \(String(format: "%.4f", locale: loc, shapeCacheFillHitRate)),")
        lines.append("    \"shapeCache_stroke_hit_rate\": \(String(format: "%.4f", locale: loc, shapeCacheStrokeHitRate)),")
        lines.append("    \"pathSampling_duplication_factor\": \(String(format: "%.4f", locale: loc, pathSamplingDuplicationFactor))")
        lines.append("  }")

        lines.append("}")
        return lines.joined(separator: "\n")
    }

    /// Compact one-line summary for debug console output.
    func summaryLine() -> String {
        let loc = Self.posixLocale
        let frameMs = String(format: "%.2f", locale: loc, Double(timingsNs[.frameTotal] ?? 0) / 1_000_000)
        let pathMs = String(format: "%.2f", locale: loc, Double(timingsNs[.pathSamplingTotal] ?? 0) / 1_000_000)
        let shapeMs = String(format: "%.2f", locale: loc, Double(timingsNs[.shapeCacheTotal] ?? 0) / 1_000_000)
        let hitRate = String(format: "%.0f", locale: loc, pathSamplingHitRate * 100)
        return "[PERF] f\(frameIndex) total=\(frameMs)ms path=\(pathMs)ms shape=\(shapeMs)ms " +
               "cmds=\(counters.commandsTotal) pathHit=\(hitRate)% " +
               "fills=\(counters.commandsDrawShape) strokes=\(counters.commandsDrawStroke) " +
               "masks=\(counters.maskCountTotal) mattes=\(counters.mattePairsTotal)"
    }
}

// MARK: - Perf Metrics (Collector)

/// Collects per-frame performance metrics.
///
/// Owned by `MetalRenderer`. Created only when `enablePerfMetrics` is true.
/// All timing uses `ContinuousClock` for monotonic, suspend-aware measurement.
/// No allocations in hot path — counters are plain integers, timings are preallocated.
///
/// Usage:
/// ```
/// perf?.beginFrame(index: frameIndex)
/// perf?.beginPhase(.frameTotal)
/// ... render ...
/// perf?.endPhase(.frameTotal)
/// let report = perf?.endFrame()
/// ```
final class PerfMetrics {
    private var counters = PerfCounters()
    private var frameIndex: Int = 0
    private let clock = ContinuousClock()

    // Phase timing: start instants stored per-phase (preallocated dict capacity)
    private var phaseStarts: [PerfPhase: ContinuousClock.Instant] = [:]
    private var phaseAccumNs: [PerfPhase: UInt64] = [:]

    // Unique keys tracking for pathSampling_uniqueKeys_frame
    private var seenPathKeys: Set<PathSampleKey> = []

    /// Latest completed report (available after `endFrame()`).
    private(set) var lastReport: PerfReport?

    init() {
        // Preallocate dictionary capacity
        phaseStarts.reserveCapacity(PerfPhase.allCases.count)
        phaseAccumNs.reserveCapacity(PerfPhase.allCases.count)
    }

    // MARK: - Frame Lifecycle

    /// Begins a new frame. Resets all counters and timings.
    func beginFrame(index: Int) {
        frameIndex = index
        counters = PerfCounters()
        phaseStarts.removeAll(keepingCapacity: true)
        phaseAccumNs.removeAll(keepingCapacity: true)
        seenPathKeys.removeAll(keepingCapacity: true)
    }

    /// Ends the current frame and produces a `PerfReport` snapshot.
    @discardableResult
    func endFrame() -> PerfReport {
        counters.pathSamplingUniqueKeysFrame = seenPathKeys.count
        let report = PerfReport(
            frameIndex: frameIndex,
            counters: counters,
            timingsNs: phaseAccumNs
        )
        lastReport = report
        return report
    }

    // MARK: - Phase Timing

    /// Begins timing a phase. Nestable: multiple calls accumulate.
    func beginPhase(_ phase: PerfPhase) {
        phaseStarts[phase] = clock.now
    }

    /// Ends timing a phase. Accumulates into total for this frame.
    func endPhase(_ phase: PerfPhase) {
        guard let start = phaseStarts.removeValue(forKey: phase) else { return }
        let elapsed = clock.now - start
        let ns = UInt64(elapsed.components.seconds) * 1_000_000_000
             + UInt64(elapsed.components.attoseconds / 1_000_000_000)
        phaseAccumNs[phase, default: 0] += ns
    }

    // MARK: - Counter Increments

    /// Records a path sampling call outcome.
    func recordPathSampling(outcome: PathSamplingOutcome, key: PathSampleKey) {
        counters.pathSamplingCallsTotal += 1
        seenPathKeys.insert(key)
        switch outcome {
        case .hitFrameMemo:
            counters.pathSamplingHitFrameMemo += 1
        case .hitLRU:
            counters.pathSamplingHitLRU += 1
        case .miss:
            counters.pathSamplingMiss += 1
            counters.pathSamplingProducerCalls += 1
        case .missNil:
            counters.pathSamplingMiss += 1
            counters.pathSamplingProducerCalls += 1
            counters.pathSamplingNilResults += 1
        }
    }

    /// Records a shape cache fill lookup result.
    func recordShapeFill(outcome: CacheOutcome) {
        switch outcome {
        case .hit:
            counters.shapeCacheFillHit += 1
        case .miss:
            counters.shapeCacheFillMiss += 1
        case .missEvicted:
            counters.shapeCacheFillMiss += 1
            counters.shapeCacheEvictions += 1
        }
    }

    /// Records a shape cache stroke lookup result.
    func recordShapeStroke(outcome: CacheOutcome) {
        switch outcome {
        case .hit:
            counters.shapeCacheStrokeHit += 1
        case .miss:
            counters.shapeCacheStrokeMiss += 1
        case .missEvicted:
            counters.shapeCacheStrokeMiss += 1
            counters.shapeCacheEvictions += 1
        }
    }

    /// Records a render command execution by type.
    func recordCommand(_ command: RenderCommand) {
        counters.commandsTotal += 1
        switch command {
        case .drawImage: counters.commandsDrawImage += 1
        case .drawShape: counters.commandsDrawShape += 1
        case .drawStroke: counters.commandsDrawStroke += 1
        case .pushTransform: counters.commandsPushTransform += 1
        case .popTransform: counters.commandsPopTransform += 1
        case .beginGroup: counters.commandsBeginGroup += 1
        case .endGroup: counters.commandsEndGroup += 1
        case .pushClipRect: counters.commandsPushClipRect += 1
        case .popClipRect: counters.commandsPopClipRect += 1
        case .beginMask: break // counted separately
        case .endMask: break
        case .beginMatte: break // counted separately
        case .endMatte: break
        }
    }

    /// Records a mask scope execution.
    func recordMask() {
        counters.maskCountTotal += 1
    }

    /// Records a matte pair execution.
    func recordMatte() {
        counters.mattePairsTotal += 1
    }
}

// MARK: - Aggregate Report

/// Aggregated metrics across multiple frames (for PerfSmokeRunner).
struct PerfAggregateReport {
    let frameCount: Int
    let totalCounters: PerfCounters
    let frameTimingsNs: [UInt64]  // frame_total per frame

    var minFrameNs: UInt64 { frameTimingsNs.min() ?? 0 }
    var maxFrameNs: UInt64 { frameTimingsNs.max() ?? 0 }

    var avgFrameNs: UInt64 {
        guard !frameTimingsNs.isEmpty else { return 0 }
        return frameTimingsNs.reduce(0, +) / UInt64(frameTimingsNs.count)
    }

    var p95FrameNs: UInt64 {
        guard !frameTimingsNs.isEmpty else { return 0 }
        let sorted = frameTimingsNs.sorted()
        let idx = Int(Double(sorted.count) * 0.95)
        return sorted[min(idx, sorted.count - 1)]
    }

    var pathSamplingHitRate: Double {
        let total = totalCounters.pathSamplingCallsTotal
        guard total > 0 else { return 0 }
        let hits = totalCounters.pathSamplingHitFrameMemo + totalCounters.pathSamplingHitLRU
        return Double(hits) / Double(total)
    }

    var shapeCacheFillHitRate: Double {
        let total = totalCounters.shapeCacheFillHit + totalCounters.shapeCacheFillMiss
        guard total > 0 else { return 0 }
        return Double(totalCounters.shapeCacheFillHit) / Double(total)
    }

    var shapeCacheStrokeHitRate: Double {
        let total = totalCounters.shapeCacheStrokeHit + totalCounters.shapeCacheStrokeMiss
        guard total > 0 else { return 0 }
        return Double(totalCounters.shapeCacheStrokeHit) / Double(total)
    }

    /// Accumulates reports from individual frames.
    static func aggregate(_ reports: [PerfReport]) -> PerfAggregateReport {
        var total = PerfCounters()
        var frameTimes: [UInt64] = []
        frameTimes.reserveCapacity(reports.count)

        for r in reports {
            let c = r.counters
            total.pathSamplingCallsTotal += c.pathSamplingCallsTotal
            total.pathSamplingHitFrameMemo += c.pathSamplingHitFrameMemo
            total.pathSamplingHitLRU += c.pathSamplingHitLRU
            total.pathSamplingMiss += c.pathSamplingMiss
            total.pathSamplingProducerCalls += c.pathSamplingProducerCalls
            total.pathSamplingNilResults += c.pathSamplingNilResults
            total.pathSamplingUniqueKeysFrame += c.pathSamplingUniqueKeysFrame
            total.shapeCacheFillHit += c.shapeCacheFillHit
            total.shapeCacheFillMiss += c.shapeCacheFillMiss
            total.shapeCacheStrokeHit += c.shapeCacheStrokeHit
            total.shapeCacheStrokeMiss += c.shapeCacheStrokeMiss
            total.shapeCacheEvictions += c.shapeCacheEvictions
            total.commandsTotal += c.commandsTotal
            total.commandsDrawImage += c.commandsDrawImage
            total.commandsDrawShape += c.commandsDrawShape
            total.commandsDrawStroke += c.commandsDrawStroke
            total.commandsPushTransform += c.commandsPushTransform
            total.commandsPopTransform += c.commandsPopTransform
            total.commandsBeginGroup += c.commandsBeginGroup
            total.commandsEndGroup += c.commandsEndGroup
            total.commandsPushClipRect += c.commandsPushClipRect
            total.commandsPopClipRect += c.commandsPopClipRect
            total.maskCountTotal += c.maskCountTotal
            total.mattePairsTotal += c.mattePairsTotal

            frameTimes.append(r.timingsNs[.frameTotal] ?? 0)
        }

        return PerfAggregateReport(
            frameCount: reports.count,
            totalCounters: total,
            frameTimingsNs: frameTimes
        )
    }
}

#endif
