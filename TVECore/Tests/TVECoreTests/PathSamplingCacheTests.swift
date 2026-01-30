import XCTest
@testable import TVECore

/// Tests for PR-14B: PathSamplingCache
/// Verifies two-level caching (FrameMemo + LRU) for samplePath results.
///
/// PR-14C: Updated to use `PathSampleResult` enum return type.
/// Debug counters removed from cache — metrics now collected by PerfMetrics externally.
final class PathSamplingCacheTests: XCTestCase {
    // MARK: - Test Helpers

    /// Creates a simple triangle BezierPath for testing.
    private func makeTriangle(scale: Double = 1.0) -> BezierPath {
        BezierPath(
            vertices: [
                Vec2D(x: 0, y: 0),
                Vec2D(x: 100 * scale, y: 0),
                Vec2D(x: 50 * scale, y: 100 * scale)
            ],
            inTangents: [Vec2D.zero, Vec2D.zero, Vec2D.zero],
            outTangents: [Vec2D.zero, Vec2D.zero, Vec2D.zero],
            closed: true
        )
    }

    /// Creates a simple rectangle BezierPath for testing.
    private func makeRect() -> BezierPath {
        BezierPath(
            vertices: [
                Vec2D(x: 0, y: 0),
                Vec2D(x: 100, y: 0),
                Vec2D(x: 100, y: 100),
                Vec2D(x: 0, y: 100)
            ],
            inTangents: [Vec2D.zero, Vec2D.zero, Vec2D.zero, Vec2D.zero],
            outTangents: [Vec2D.zero, Vec2D.zero, Vec2D.zero, Vec2D.zero],
            closed: true
        )
    }

    /// Extracts BezierPath from PathSampleResult, or nil for .missNil.
    private func extractPath(_ result: PathSampleResult) -> BezierPath? {
        switch result {
        case .hitFrameMemo(let p): return p
        case .hitLRU(let p): return p
        case .miss(let p): return p
        case .missNil: return nil
        }
    }

    /// Asserts that a PathSampleResult is a .hitFrameMemo case.
    private func assertIsFrameMemoHit(_ result: PathSampleResult, file: StaticString = #filePath, line: UInt = #line) {
        if case .hitFrameMemo = result { return }
        XCTFail("Expected .hitFrameMemo, got \(result)", file: file, line: line)
    }

    /// Asserts that a PathSampleResult is a .hitLRU case.
    private func assertIsLRUHit(_ result: PathSampleResult, file: StaticString = #filePath, line: UInt = #line) {
        if case .hitLRU = result { return }
        XCTFail("Expected .hitLRU, got \(result)", file: file, line: line)
    }

    /// Asserts that a PathSampleResult is a .miss case.
    private func assertIsMiss(_ result: PathSampleResult, file: StaticString = #filePath, line: UInt = #line) {
        if case .miss = result { return }
        XCTFail("Expected .miss, got \(result)", file: file, line: line)
    }

    /// Asserts that a PathSampleResult is a .missNil case.
    private func assertIsMissNil(_ result: PathSampleResult, file: StaticString = #filePath, line: UInt = #line) {
        if case .missNil = result { return }
        XCTFail("Expected .missNil, got \(result)", file: file, line: line)
    }

    // MARK: - T1: Fill + Stroke same frame → 1 producer call

    func testFillAndStroke_sameFrame_callsProducerOnce() {
        let cache = PathSamplingCache()
        cache.beginFrame()

        let triangle = makeTriangle()
        var producerCallCount = 0

        // First call (fill): producer should be called
        let result1 = cache.sample(
            generationId: 0,
            pathId: PathID(0),
            frame: 10.0,
            producer: {
                producerCallCount += 1
                return triangle
            }
        )

        // Second call (stroke): same pathId + frame → FrameMemo hit
        let result2 = cache.sample(
            generationId: 0,
            pathId: PathID(0),
            frame: 10.0,
            producer: {
                producerCallCount += 1
                return triangle
            }
        )

        XCTAssertEqual(producerCallCount, 1, "Producer should be called exactly once for fill+stroke")
        assertIsMiss(result1)
        assertIsFrameMemoHit(result2)
        XCTAssertEqual(extractPath(result1), triangle)
        XCTAssertEqual(extractPath(result2), triangle)
    }

    // MARK: - T2: Frame quantization (close frames → same key)

    func testFrameQuantization_closeFrames_sameKey() {
        let cache = PathSamplingCache()
        cache.beginFrame()

        let triangle = makeTriangle()
        var producerCallCount = 0

        // Frame 10.0
        _ = cache.sample(
            generationId: 0,
            pathId: PathID(0),
            frame: 10.0,
            producer: {
                producerCallCount += 1
                return triangle
            }
        )

        // Frame 10.0 + tiny noise (within 1/1000 step)
        _ = cache.sample(
            generationId: 0,
            pathId: PathID(0),
            frame: 10.0 + 1e-12,
            producer: {
                producerCallCount += 1
                return triangle
            }
        )

        XCTAssertEqual(producerCallCount, 1, "Frames differing by 1e-12 should map to same quantized key")
    }

    func testFrameQuantization_differentFrames_differentKeys() {
        let cache = PathSamplingCache()
        cache.beginFrame()

        let triangle = makeTriangle()
        var producerCallCount = 0

        // Frame 10.0
        _ = cache.sample(
            generationId: 0,
            pathId: PathID(0),
            frame: 10.0,
            producer: {
                producerCallCount += 1
                return triangle
            }
        )

        // Frame 11.0 — different quantized key
        _ = cache.sample(
            generationId: 0,
            pathId: PathID(0),
            frame: 11.0,
            producer: {
                producerCallCount += 1
                return triangle
            }
        )

        XCTAssertEqual(producerCallCount, 2, "Different frames should call producer separately")
    }

    // MARK: - T3: LRU eviction

    func testLRU_evictsOldestEntries() {
        let maxEntries = 4
        let cache = PathSamplingCache(maxLRUEntries: maxEntries)
        cache.beginFrame()

        let triangle = makeTriangle()

        // Fill LRU with 4 entries (frames 0,1,2,3)
        for frame in 0..<maxEntries {
            _ = cache.sample(
                generationId: 0,
                pathId: PathID(0),
                frame: Double(frame),
                producer: { triangle }
            )
        }

        XCTAssertEqual(cache.lruCount, maxEntries, "LRU should have \(maxEntries) entries")

        // Add one more (frame 4) → should evict frame 0
        _ = cache.sample(
            generationId: 0,
            pathId: PathID(0),
            frame: Double(maxEntries),
            producer: { triangle }
        )

        XCTAssertEqual(cache.lruCount, maxEntries, "LRU should stay at capacity after eviction")

        // New frame: verify frame 0 was evicted (needs producer), frame 3 still cached
        // After eviction, LRU contains: [1, 2, 3, 4]
        cache.beginFrame()

        var producerCalls = 0

        // Frame 0 should be evicted → miss
        let r0 = cache.sample(
            generationId: 0,
            pathId: PathID(0),
            frame: 0.0,
            producer: {
                producerCalls += 1
                return triangle
            }
        )

        XCTAssertEqual(producerCalls, 1, "Frame 0 was evicted → producer should be called")
        assertIsMiss(r0)

        // Frame 3 should still be in LRU → hit
        // (Re-inserting frame 0 above evicts frame 1, but frame 3 remains)
        let r3 = cache.sample(
            generationId: 0,
            pathId: PathID(0),
            frame: 3.0,
            producer: {
                producerCalls += 1
                return triangle
            }
        )

        XCTAssertEqual(producerCalls, 1, "Frame 3 retained in LRU (hit), frame 0 was miss")
        assertIsLRUHit(r3)
    }

    // MARK: - T4: Generation ID isolation

    func testGenerationId_differentGenerations_noCacheCollision() {
        let cache = PathSamplingCache()
        cache.beginFrame()

        let triangle = makeTriangle()
        let rect = makeRect()

        // Generation 0: pathId 0 → triangle
        let result1 = cache.sample(
            generationId: 0,
            pathId: PathID(0),
            frame: 10.0,
            producer: { triangle }
        )

        // Generation 1: same pathId 0 → rect (different scene compilation)
        let result2 = cache.sample(
            generationId: 1,
            pathId: PathID(0),
            frame: 10.0,
            producer: { rect }
        )

        XCTAssertEqual(extractPath(result1), triangle)
        XCTAssertEqual(extractPath(result2), rect)
        XCTAssertNotEqual(extractPath(result1), extractPath(result2), "Different generationIds must not collide")
    }

    // MARK: - T5: LRU cross-frame reuse (loop / scrub back)

    func testLRU_crossFrameReuse_hitsOnRevisit() {
        let cache = PathSamplingCache()

        let triangle = makeTriangle()
        var producerCalls = 0

        // Frame A: populate LRU
        cache.beginFrame()
        _ = cache.sample(
            generationId: 0,
            pathId: PathID(0),
            frame: 10.0,
            producer: {
                producerCalls += 1
                return triangle
            }
        )

        // Frame B: different frame clears memo, but LRU persists
        cache.beginFrame()

        // Revisit frame 10.0 → should be LRU hit (no producer call)
        let result = cache.sample(
            generationId: 0,
            pathId: PathID(0),
            frame: 10.0,
            producer: {
                producerCalls += 1
                return triangle
            }
        )

        XCTAssertEqual(producerCalls, 1, "Revisiting same frame should be LRU hit, not producer call")
        assertIsLRUHit(result)
        XCTAssertEqual(extractPath(result), triangle)
    }

    // MARK: - FrameMemo cleared on beginFrame

    func testBeginFrame_clearsFrameMemo() {
        let cache = PathSamplingCache()

        let triangle = makeTriangle()
        var producerCalls = 0

        // Frame 1: populate
        cache.beginFrame()
        _ = cache.sample(
            generationId: 0,
            pathId: PathID(0),
            frame: 10.0,
            producer: {
                producerCalls += 1
                return triangle
            }
        )

        XCTAssertEqual(cache.frameMemoCount, 1)

        // Frame 2: memo cleared
        cache.beginFrame()
        XCTAssertEqual(cache.frameMemoCount, 0, "beginFrame must clear frame memo")

        // But LRU still has it (so producer won't be called again)
        let result = cache.sample(
            generationId: 0,
            pathId: PathID(0),
            frame: 10.0,
            producer: {
                producerCalls += 1
                return triangle
            }
        )

        XCTAssertEqual(producerCalls, 1, "LRU hit should prevent producer call after memo clear")
        assertIsLRUHit(result)
        XCTAssertEqual(cache.frameMemoCount, 1, "LRU hit should promote into frame memo")
    }

    // MARK: - Nil producer

    func testNilProducer_returnsNilWithoutCaching() {
        let cache = PathSamplingCache()
        cache.beginFrame()

        var producerCalls = 0

        let result1 = cache.sample(
            generationId: 0,
            pathId: PathID(0),
            frame: 10.0,
            producer: {
                producerCalls += 1
                return nil
            }
        )

        assertIsMissNil(result1)
        XCTAssertNil(extractPath(result1))

        // Second call: nil was not cached, so producer is called again
        let triangle = makeTriangle()
        let result2 = cache.sample(
            generationId: 0,
            pathId: PathID(0),
            frame: 10.0,
            producer: {
                producerCalls += 1
                return triangle
            }
        )

        XCTAssertEqual(producerCalls, 2, "nil result should not be cached")
        assertIsMiss(result2)
        XCTAssertEqual(extractPath(result2), triangle, "Second call with non-nil producer should succeed")
    }

    // MARK: - Clear

    func testClear_removesAllEntries() {
        let cache = PathSamplingCache()
        cache.beginFrame()

        let triangle = makeTriangle()

        // Populate both levels
        _ = cache.sample(
            generationId: 0,
            pathId: PathID(0),
            frame: 10.0,
            producer: { triangle }
        )

        XCTAssertEqual(cache.frameMemoCount, 1)
        XCTAssertEqual(cache.lruCount, 1)

        cache.clear()

        XCTAssertEqual(cache.frameMemoCount, 0, "clear() must empty frame memo")
        XCTAssertEqual(cache.lruCount, 0, "clear() must empty LRU")
    }

    // MARK: - Different pathIds → different cache entries

    func testDifferentPathIds_separateCacheEntries() {
        let cache = PathSamplingCache()
        cache.beginFrame()

        let triangle = makeTriangle()
        let rect = makeRect()
        var producerCalls = 0

        let result1 = cache.sample(
            generationId: 0,
            pathId: PathID(0),
            frame: 10.0,
            producer: {
                producerCalls += 1
                return triangle
            }
        )

        let result2 = cache.sample(
            generationId: 0,
            pathId: PathID(1),
            frame: 10.0,
            producer: {
                producerCalls += 1
                return rect
            }
        )

        XCTAssertEqual(producerCalls, 2, "Different pathIds should produce separate entries")
        XCTAssertEqual(extractPath(result1), triangle)
        XCTAssertEqual(extractPath(result2), rect)
    }

    // MARK: - LRU access order updates on hit

    func testLRU_accessOrderUpdatesOnHit() {
        // With capacity 3, verify that accessing an older entry prevents its eviction
        let cache = PathSamplingCache(maxLRUEntries: 3)
        cache.beginFrame()

        let triangle = makeTriangle()

        // Fill LRU: frames 0, 1, 2
        for frame in 0..<3 {
            _ = cache.sample(
                generationId: 0,
                pathId: PathID(0),
                frame: Double(frame),
                producer: { triangle }
            )
        }

        // Access frame 0 again → moves to end of LRU order
        cache.beginFrame()
        _ = cache.sample(
            generationId: 0,
            pathId: PathID(0),
            frame: 0.0,
            producer: { triangle }
        )

        // Add frame 3 → should evict frame 1 (oldest not recently accessed)
        _ = cache.sample(
            generationId: 0,
            pathId: PathID(0),
            frame: 3.0,
            producer: { triangle }
        )

        XCTAssertEqual(cache.lruCount, 3, "LRU should be at capacity")

        // Frame 0 should still be in LRU (was recently accessed)
        cache.beginFrame()
        var producerCalls = 0

        let r0 = cache.sample(
            generationId: 0,
            pathId: PathID(0),
            frame: 0.0,
            producer: {
                producerCalls += 1
                return triangle
            }
        )
        assertIsLRUHit(r0)

        // Frame 1 should be evicted
        let r1 = cache.sample(
            generationId: 0,
            pathId: PathID(0),
            frame: 1.0,
            producer: {
                producerCalls += 1
                return triangle
            }
        )
        assertIsMiss(r1)

        XCTAssertEqual(producerCalls, 1, "Frame 0 retained (LRU hit), frame 1 evicted (miss)")
    }

    // MARK: - PathSampleResult enum cases

    func testPathSampleResult_enumCases() {
        let cache = PathSamplingCache()
        cache.beginFrame()

        let triangle = makeTriangle()

        // First call: miss
        let r1 = cache.sample(
            generationId: 0,
            pathId: PathID(0),
            frame: 10.0,
            producer: { triangle }
        )
        assertIsMiss(r1)

        // Same key in same frame: frameMemo hit
        let r2 = cache.sample(
            generationId: 0,
            pathId: PathID(0),
            frame: 10.0,
            producer: { triangle }
        )
        assertIsFrameMemoHit(r2)

        // New frame: LRU hit
        cache.beginFrame()
        let r3 = cache.sample(
            generationId: 0,
            pathId: PathID(0),
            frame: 10.0,
            producer: { triangle }
        )
        assertIsLRUHit(r3)

        // Nil producer: missNil
        let r4 = cache.sample(
            generationId: 0,
            pathId: PathID(99),
            frame: 10.0,
            producer: { nil }
        )
        assertIsMissNil(r4)
    }

    // MARK: - PathSampleKey Hashable conformance

    func testPathSampleKey_equalKeys_sameHash() {
        let key1 = PathSampleKey(generationId: 0, pathId: PathID(5), quantizedFrame: 1000)
        let key2 = PathSampleKey(generationId: 0, pathId: PathID(5), quantizedFrame: 1000)

        XCTAssertEqual(key1, key2)
        XCTAssertEqual(key1.hashValue, key2.hashValue)
    }

    func testPathSampleKey_differentGenerationId_notEqual() {
        let key1 = PathSampleKey(generationId: 0, pathId: PathID(5), quantizedFrame: 1000)
        let key2 = PathSampleKey(generationId: 1, pathId: PathID(5), quantizedFrame: 1000)

        XCTAssertNotEqual(key1, key2)
    }

    func testPathSampleKey_differentPathId_notEqual() {
        let key1 = PathSampleKey(generationId: 0, pathId: PathID(5), quantizedFrame: 1000)
        let key2 = PathSampleKey(generationId: 0, pathId: PathID(6), quantizedFrame: 1000)

        XCTAssertNotEqual(key1, key2)
    }

    func testPathSampleKey_differentFrame_notEqual() {
        let key1 = PathSampleKey(generationId: 0, pathId: PathID(5), quantizedFrame: 1000)
        let key2 = PathSampleKey(generationId: 0, pathId: PathID(5), quantizedFrame: 1001)

        XCTAssertNotEqual(key1, key2)
    }

    // MARK: - PathRegistry generationId

    func testPathRegistry_generationId_isUnique() {
        let reg1 = PathRegistry()
        let reg2 = PathRegistry()
        let reg3 = PathRegistry()

        XCTAssertNotEqual(reg1.generationId, reg2.generationId, "Each registry should get unique generationId")
        XCTAssertNotEqual(reg2.generationId, reg3.generationId)
        // Monotonically increasing
        XCTAssertGreaterThan(reg2.generationId, reg1.generationId)
        XCTAssertGreaterThan(reg3.generationId, reg2.generationId)
    }

    func testPathRegistry_equatable_ignoresGenerationId() {
        let reg1 = PathRegistry()
        let reg2 = PathRegistry()

        // Different generationId but same paths (empty) → should be equal
        XCTAssertEqual(reg1, reg2, "Equatable should compare paths only, not generationId")
        XCTAssertNotEqual(reg1.generationId, reg2.generationId)
    }

    // MARK: - AnimConstants.frameQuantStep

    func testAnimConstants_frameQuantStep_value() {
        XCTAssertEqual(AnimConstants.frameQuantStep, 1.0 / 1000.0)
    }
}
