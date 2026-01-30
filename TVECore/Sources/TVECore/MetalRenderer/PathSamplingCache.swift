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
/// Owned by `MetalRenderer`, lives alongside `ShapeCache`.
/// Not a global singleton — freed when renderer is deallocated.
final class PathSamplingCache {
    // MARK: - Frame Memo (per-frame, Level 1)

    private var frameMemo: [PathSampleKey: BezierPath] = [:]

    // MARK: - LRU Cache (multi-frame, Level 2)

    private var lruCache: [PathSampleKey: BezierPath] = [:]
    private var lruAccessOrder: [PathSampleKey] = []
    private let maxLRUEntries: Int

    // MARK: - Debug Counters

    #if DEBUG
    /// Number of frame memo hits since last `resetDebugCounters()`.
    private(set) var debugFrameMemoHits: Int = 0
    /// Number of LRU hits since last `resetDebugCounters()`.
    private(set) var debugLRUHits: Int = 0
    /// Number of cache misses (producer calls) since last `resetDebugCounters()`.
    private(set) var debugMisses: Int = 0
    #endif

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
    ///
    /// - Parameters:
    ///   - generationId: `PathRegistry.generationId` (prevents cross-compilation collisions)
    ///   - pathId: Path identifier from RenderCommand
    ///   - frame: Animation frame (quantized internally via `AnimConstants.frameQuantStep`)
    ///   - producer: Closure that performs the actual `samplePath(resource:, frame:)`.
    ///              Called only on cache miss.
    /// - Returns: Sampled `BezierPath`, or `nil` if producer returns `nil`.
    func sample(
        generationId: Int,
        pathId: PathID,
        frame: Double,
        producer: () -> BezierPath?
    ) -> BezierPath? {
        let key = PathSampleKey(
            generationId: generationId,
            pathId: pathId,
            quantizedFrame: Quantization.quantizedInt(frame, step: AnimConstants.frameQuantStep)
        )

        // Level 1: Frame memo (same-frame dedup — fill + stroke)
        if let cached = frameMemo[key] {
            #if DEBUG
            debugFrameMemoHits += 1
            #endif
            return cached
        }

        // Level 2: LRU (cross-frame reuse — loops, scrubbing)
        if let cached = lruCache[key] {
            frameMemo[key] = cached
            updateLRUAccessOrder(key)
            #if DEBUG
            debugLRUHits += 1
            #endif
            return cached
        }

        // Miss: compute via producer
        #if DEBUG
        debugMisses += 1
        #endif

        guard let result = producer() else {
            return nil
        }

        // Store in both levels
        frameMemo[key] = result
        storeLRU(key: key, value: result)

        return result
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

    #if DEBUG
    /// Resets debug hit/miss counters.
    func resetDebugCounters() {
        debugFrameMemoHits = 0
        debugLRUHits = 0
        debugMisses = 0
    }
    #endif

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
