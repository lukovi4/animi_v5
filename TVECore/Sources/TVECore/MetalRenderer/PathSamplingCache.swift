import Foundation

// MARK: - Path Sample Key (PR-14B)

/// Cache key for path sampling results.
///
/// Combines registry generation, path identity, and quantized frame to produce
/// a unique, deterministic key for in-memory caching.
///
/// - Important: **Process-local only.** Uses Swift's `Hasher` (random-seeded per launch).
///   Do not persist to disk.
struct PathSampleKey: Hashable {
    /// PathRegistry generation (prevents collisions across recompilations)
    let generationId: Int
    /// Path identifier within the registry
    let pathId: PathID
    /// Frame quantized to integer via `AnimConstants.frameQuantStep`
    let quantizedFrame: Int
}

// MARK: - Path Sampling Cache Result (PR-14C)

/// Outcome of a PathSamplingCache lookup.
/// Used by PerfMetrics to record hit/miss without the cache storing counters.
enum PathSampleResult {
    case hitFrameMemo(BezierPath)
    case hitLRU(BezierPath)
    case miss(BezierPath)
    case missNil
}

// MARK: - Path Sampling Cache (PR-14B)

/// Two-level cache for `samplePath(resource:, frame:)` results.
///
/// Eliminates redundant BezierPath sampling during rendering:
/// - **FrameMemo** (Level 1): per-frame dictionary, cleared at each `beginFrame()`.
///   Catches fill + stroke sampling of the same path within a single draw call.
/// - **SamplingLRU** (Level 2): bounded multi-frame cache with LRU eviction.
///   Catches repeated frames during playback (looping, scrubbing back).
///
/// Lookup order: FrameMemo → LRU → producer closure (actual sampling).
/// On miss, the result is stored in both levels.
///
/// PR-14C: No internal counters. Returns `PathSampleResult` so the caller
/// (MetalRenderer + PerfMetrics) can record outcomes externally.
///
/// Owned by `MetalRenderer`, lives alongside `ShapeCache`.
/// Not a global singleton — freed when renderer is deallocated.
final class PathSamplingCache {
    // MARK: - Frame Memo (per-frame, Level 1)

    private var frameMemo: [PathSampleKey: BezierPath] = [:]

    // MARK: - LRU Cache (multi-frame, Level 2)

    private var lruCache: [PathSampleKey: BezierPath] = [:]
    private var lruAccessOrder: [PathSampleKey] = []
    private let maxLRUEntries: Int

    // MARK: - Init

    /// Creates a path sampling cache.
    /// - Parameter maxLRUEntries: Maximum entries in the LRU cache (default: 1024).
    ///   Frame memo is unbounded per-frame but reset every `beginFrame()`.
    init(maxLRUEntries: Int = 1024) {
        self.maxLRUEntries = maxLRUEntries
    }

    // MARK: - Frame Lifecycle

    /// Clears the per-frame memo. Call at the start of each `draw()`.
    /// The LRU cache is preserved across frames.
    func beginFrame() {
        frameMemo.removeAll(keepingCapacity: true)
    }

    // MARK: - Sampling

    /// Retrieves a cached BezierPath or computes it via the producer closure.
    /// Returns a `PathSampleResult` indicating the cache outcome.
    ///
    /// - Parameters:
    ///   - generationId: `PathRegistry.generationId` (prevents cross-compilation collisions)
    ///   - pathId: Path identifier from RenderCommand
    ///   - frame: Animation frame (quantized internally via `AnimConstants.frameQuantStep`)
    ///   - producer: Closure that performs the actual `samplePath(resource:, frame:)`.
    ///              Called only on cache miss.
    /// - Returns: `PathSampleResult` with the sampled path (or nil) and outcome type.
    func sample(
        generationId: Int,
        pathId: PathID,
        frame: Double,
        producer: () -> BezierPath?
    ) -> PathSampleResult {
        let key = PathSampleKey(
            generationId: generationId,
            pathId: pathId,
            quantizedFrame: Quantization.quantizedInt(frame, step: AnimConstants.frameQuantStep)
        )

        // Level 1: Frame memo (same-frame dedup — fill + stroke)
        if let cached = frameMemo[key] {
            return .hitFrameMemo(cached)
        }

        // Level 2: LRU (cross-frame reuse — loops, scrubbing)
        if let cached = lruCache[key] {
            frameMemo[key] = cached
            updateLRUAccessOrder(key)
            return .hitLRU(cached)
        }

        // Miss: compute via producer
        guard let result = producer() else {
            return .missNil
        }

        // Store in both levels
        frameMemo[key] = result
        storeLRU(key: key, value: result)

        return .miss(result)
    }

    // MARK: - Cache Management

    /// Clears all cached data (both frame memo and LRU).
    func clear() {
        frameMemo.removeAll()
        lruCache.removeAll()
        lruAccessOrder.removeAll()
    }

    /// Number of entries in the LRU cache.
    var lruCount: Int { lruCache.count }

    /// Number of entries in the current frame memo.
    var frameMemoCount: Int { frameMemo.count }

    // MARK: - LRU Internals

    private func storeLRU(key: PathSampleKey, value: BezierPath) {
        // Evict oldest if at capacity
        while lruCache.count >= maxLRUEntries, let oldest = lruAccessOrder.first {
            lruAccessOrder.removeFirst()
            lruCache.removeValue(forKey: oldest)
        }

        lruCache[key] = value
        lruAccessOrder.append(key)
    }

    private func updateLRUAccessOrder(_ key: PathSampleKey) {
        if let index = lruAccessOrder.firstIndex(of: key) {
            lruAccessOrder.remove(at: index)
            lruAccessOrder.append(key)
        }
    }
}
