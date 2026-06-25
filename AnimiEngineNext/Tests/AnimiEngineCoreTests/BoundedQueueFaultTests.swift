import XCTest
@testable import AnimiEngineCore

/// Slice-003 Stage F — bounded queues + global-skip behavior under deterministic fault injection
/// (ADR-006 §6, §9, §10).
///
/// Proves: capacity must be positive (fail-closed); depth never exceeds capacity; obsolete elements are
/// evicted first; a full queue with nothing obsolete rejects; an over-capacity burst is deterministic;
/// a missed workset keeps the previous COMPLETE composition (global skip), never a per-layer substitute.
final class BoundedQueueFaultTests: XCTestCase {

    // MARK: - capacity validity

    func testPositiveCapacityConstructs() throws {
        let q = try BoundedQueue<Int>(capacity: 3)
        XCTAssertEqual(q.capacity, 3)
        XCTAssertTrue(q.isEmpty)
    }

    func testInvalidCapacityRejected() {
        XCTAssertThrowsError(try BoundedQueue<Int>(capacity: 0)) {
            XCTAssertEqual($0 as? BoundedQueueError, .invalidCapacity(0))
        }
        XCTAssertThrowsError(try BoundedQueue<Int>(capacity: -5)) {
            XCTAssertEqual($0 as? BoundedQueueError, .invalidCapacity(-5))
        }
    }

    // MARK: - depth never exceeds capacity

    func testDepthNeverExceedsCapacity() throws {
        var q = try BoundedQueue<Int>(capacity: 2)
        _ = q.admit(1) { _ in false }
        _ = q.admit(2) { _ in false }
        _ = q.admit(3) { _ in false }   // full, nothing obsolete → rejected
        XCTAssertEqual(q.count, 2)
        XCTAssertLessThanOrEqual(q.count, q.capacity)
    }

    // MARK: - obsolete-first eviction

    func testObsoleteFirstEviction() throws {
        var q = try BoundedQueue<Int>(capacity: 3)
        _ = q.admit(10) { _ in false }
        _ = q.admit(20) { _ in false }
        _ = q.admit(30) { _ in false }
        // Full. Admit 40, treating even numbers as obsolete → the FIRST obsolete (10) is evicted.
        let result = q.admit(40) { $0 == 10 }
        guard case .success(.evictedObsolete(let evicted)) = result else { return XCTFail("expected eviction") }
        XCTAssertEqual(evicted, 10)
        XCTAssertEqual(q.elements, [20, 30, 40])
        XCTAssertEqual(q.count, 3)
    }

    func testEvictsFirstObsoleteInFIFOOrder() throws {
        var q = try BoundedQueue<Int>(capacity: 3)
        _ = q.admit(1) { _ in false }
        _ = q.admit(2) { _ in false }
        _ = q.admit(3) { _ in false }
        // Both 2 and 3 are obsolete; the FIRST (oldest) obsolete, 2, is evicted, not 3.
        let result = q.admit(4) { $0 == 2 || $0 == 3 }
        guard case .success(.evictedObsolete(let evicted)) = result else { return XCTFail("expected eviction") }
        XCTAssertEqual(evicted, 2)
        XCTAssertEqual(q.elements, [1, 3, 4])
    }

    // MARK: - full queue with nothing obsolete rejects

    func testFullQueueWithoutObsoleteRejects() throws {
        var q = try BoundedQueue<Int>(capacity: 2)
        _ = q.admit(1) { _ in false }
        _ = q.admit(2) { _ in false }
        let result = q.admit(3) { _ in false }   // nothing obsolete
        XCTAssertEqual(result, .failure(.rejectedFull))
        XCTAssertEqual(q.elements, [1, 2])
    }

    // MARK: - over-capacity burst is deterministic

    func testOverCapacityBurstIsDeterministic() throws {
        func run() throws -> [Int] {
            var q = try BoundedQueue<Int>(capacity: 3)
            for n in 1...10 { _ = q.admit(n) { _ in false } }  // nothing obsolete → first 3 stay
            return q.elements
        }
        let a = try run()
        let b = try run()
        XCTAssertEqual(a, [1, 2, 3])   // deterministic: the first three admitted survive
        XCTAssertEqual(a, b)
    }

    func testOverCapacityBurstWithObsoleteIsDeterministic() throws {
        // Same burst, but every already-queued element is obsolete → newest-wins, deterministically.
        var q = try BoundedQueue<Int>(capacity: 3)
        for n in 1...10 { _ = q.admit(n) { _ in true } }
        XCTAssertEqual(q.elements, [8, 9, 10])
    }

    // MARK: - global skip keeps previous complete composition (never per-layer)

    func testGlobalSkipKeepsPreviousCompleteComposition() throws {
        // A late workset that missed its deadline is obsolete (wrong epoch). It is dropped, and the
        // presentation policy keeps the PREVIOUS complete frame — a single whole-frame verdict, never a
        // per-layer substitute. Modelled via the scrub/settle presentation (global only).
        let latest = ScrubTarget(time: try ProjectTime(ticks: 240_000), frameRequest: FrameRequestID(raw: 2))
        let decision = ScrubSettlePolicy.presentation(latest: latest, latestCompleteFrameAvailable: false)
        XCTAssertEqual(decision, .keepPreviousComplete)
        // There is no per-layer case in the type — a global skip cannot substitute one layer.
        switch decision {
        case .keepPreviousComplete, .presentLatest:
            break   // exhaustive: no per-layer / lastGood option exists
        }
    }
}
