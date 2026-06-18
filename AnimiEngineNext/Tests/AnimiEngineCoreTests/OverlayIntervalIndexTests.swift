import XCTest
@testable import AnimiEngineCore

/// Augmented interval-tree tests (Task-002 plan, §10.1, §18).
final class OverlayIntervalIndexTests: XCTestCase {

    private func entry(_ id: String, _ start: Int64, _ end: Int64, z: Int, ord: Int) throws -> OverlayManifestEntry {
        OverlayManifestEntry(
            id: try OverlayID(id), payloadID: try OverlayPayloadID("\(id)-p"),
            timeRange: try ProjectTimeRange(start: try ProjectTime(ticks: start), end: try ProjectTime(ticks: end)),
            zIndex: z, stableOrdinal: ord
        )
    }

    func testStabbingQueryReturnsAllOverlaps() throws {
        let index = OverlayIntervalIndex(overlays: [
            try entry("a", 0, 100, z: 0, ord: 0),
            try entry("b", 50, 150, z: 1, ord: 1),
            try entry("c", 200, 300, z: 2, ord: 2)
        ])
        let at75 = index.overlays(containing: 75).map(\.overlayID.raw)
        XCTAssertEqual(at75, ["a", "b"])
        let at250 = index.overlays(containing: 250).map(\.overlayID.raw)
        XCTAssertEqual(at250, ["c"])
        // Half-open: at exactly 100, "a" (ends 100) is excluded.
        XCTAssertEqual(index.overlays(containing: 100).map(\.overlayID.raw), ["b"])
    }

    func testDeterministicOrderByZThenOrdinal() throws {
        let index = OverlayIntervalIndex(overlays: [
            try entry("hi", 0, 100, z: 5, ord: 0),
            try entry("lo", 0, 100, z: 1, ord: 0),
            try entry("mid", 0, 100, z: 1, ord: 9)
        ])
        // z ascending; within equal z, stableOrdinal ascending.
        XCTAssertEqual(index.overlays(containing: 50).map(\.overlayID.raw), ["lo", "mid", "hi"])
    }

    func testRangeIntersectionQuery() throws {
        let index = OverlayIntervalIndex(overlays: [
            try entry("a", 0, 100, z: 0, ord: 0),
            try entry("b", 100, 200, z: 1, ord: 1),
            try entry("c", 300, 400, z: 2, ord: 2)
        ])
        let hits = index.intervals(intersecting: 50, 150).map(\.overlayID.raw)
        XCTAssertEqual(hits, ["a", "b"])
        XCTAssertEqual(index.intervals(intersecting: 250, 260).map(\.overlayID.raw), [])
    }

    func testEmptyIndex() {
        let index = OverlayIntervalIndex(overlays: [])
        XCTAssertEqual(index.overlays(containing: 0).count, 0)
        XCTAssertEqual(index.intervals(intersecting: 0, 100).count, 0)
    }

    func testManyOverlaysQueryReturnsAllContaining() throws {
        // 50 overlapping intervals all covering tick 500.
        var entries: [OverlayManifestEntry] = []
        for i in 0..<50 {
            entries.append(try entry("o\(i)", 0, 1000, z: i, ord: i))
        }
        let index = OverlayIntervalIndex(overlays: entries)
        XCTAssertEqual(index.overlays(containing: 500).count, 50)
    }

    // MARK: - C-8: deterministic key order + documented O(log n + k log k)

    func testResultsAreInDeterministicKeyOrder() throws {
        // Supplied out of order; result must be (zIndex, stableOrdinal, overlayID)-ordered.
        let index = OverlayIntervalIndex(overlays: [
            try entry("b", 0, 100, z: 1, ord: 1),
            try entry("a", 0, 100, z: 0, ord: 0),
            try entry("c", 0, 100, z: 1, ord: 0)
        ])
        XCTAssertEqual(index.overlays(containing: 50).map(\.overlayID.raw), ["a", "c", "b"])
    }

    func testTraversalVisitsAreLogarithmicPlusK() throws {
        // n disjoint-ish intervals; a stabbing query visits O(log n + k) nodes (the traversal part of
        // the O(log n + k log k) bound). Use single-point coverage so k is tiny.
        for n in [1, 16, 256, 4096] {
            var entries: [OverlayManifestEntry] = []
            for i in 0..<n {
                let start = Int64(i) * 100
                entries.append(try entry("o\(i)", start, start + 50, z: i, ord: i))   // non-overlapping
            }
            let index = OverlayIntervalIndex(overlays: entries)
            // Stab a tick inside exactly one interval (k = 1).
            let (result, diag) = index.overlaysWithDiagnostics(containing: 25)
            XCTAssertEqual(result.count, 1)
            let bound = 4 * Int(ceil(log2(Double(max(n, 2))))) + result.count + 2
            XCTAssertLessThanOrEqual(diag.visited, bound, "n=\(n) visited=\(diag.visited)")
            XCTAssertLessThan(diag.visited, max(n, 2) + 1)   // never visits all n for large n
        }
    }
}
