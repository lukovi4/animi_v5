import XCTest
@testable import AnimiEngineCore
import AnimiEngineTestSupport

/// Binary-search transition-window-index tests, including deterministic op-count complexity bounds
/// asserted via the pure `SearchDiagnostics` counter (corrective plan C-2).
final class TransitionWindowIndexTests: XCTestCase {

    /// Builds an `n`-scene project where every boundary is an animated fade, returning the index.
    /// Scenes are 240,000 ticks; fade duration 120,000 (preHalf=postHalf=60,000), post-roll 60,000.
    private func index(sceneCount n: Int) throws -> (TimelineIndex, CanonicalProjectManifest) {
        var scenes: [SceneManifestEntry] = []
        for i in 0..<n {
            scenes.append(SceneManifestEntry(
                id: try SceneInstanceID("s\(i)"), payloadID: try ScenePayloadID("p\(i)"),
                nominalDuration: try TickDuration(ticks: 240_000),
                postRollCapability: try TickDuration(ticks: 120_000)
            ))
        }
        let transitions = try (0..<(n - 1)).map { _ in try CanonicalProjectFixtures.fadeTransition(durationTicks: 120_000) }
        let manifest = CanonicalProjectManifest(
            schemaVersion: 1, output: try CanonicalProjectFixtures.output(),
            scenes: scenes, boundaryTransitions: transitions, overlays: []
        )
        return (try TimelineIndex(manifest: manifest), manifest)
    }

    /// Brute-force linear reference for active-boundary lookup.
    private func linearActive(_ idx: TransitionWindowIndex, at time: ProjectTime) -> Int? {
        idx.windows.first { $0.window.contains(time) }?.boundaryIndex
    }

    func testActiveBoundaryPointLookupMatchesLinearReference() throws {
        let (timeline, _) = try index(sceneCount: 64)
        let twi = timeline.transitionWindowIndex
        // Probe at boundaries, window edges ±1, and midpoints.
        for w in twi.windows {
            let probes = [w.window.start.ticks, w.window.start.ticks - 1, w.boundary.ticks,
                          w.window.end.ticks - 1, w.window.end.ticks]
            for p in probes where p >= 0 && p < timeline.projectDuration.ticks {
                let time = try ProjectTime(ticks: p)
                XCTAssertEqual(twi.activeBoundary(at: time)?.boundaryIndex, linearActive(twi, at: time), "tick \(p)")
            }
        }
    }

    func testRangeLookupMatchesLinearReference() throws {
        let (timeline, _) = try index(sceneCount: 32)
        let twi = timeline.transitionWindowIndex
        // Several coverage ranges; compare against a linear filter.
        let ranges: [(Int64, Int64)] = [(0, 240_000), (200_000, 760_000), (0, timeline.projectDuration.ticks)]
        for (lo, hi) in ranges {
            let coverage = try ProjectTimeRange(start: try ProjectTime(ticks: lo), end: try ProjectTime(ticks: hi))
            // Compare arrays WITHOUT sorting either side: the index must return boundaries already in
            // boundary-index (== chronological) order, and the linear reference preserves that order
            // because `twi.windows` is stored chronologically (corrective pass).
            let got = twi.boundaries(intersecting: coverage).map(\.boundaryIndex)
            let expected = twi.windows
                .filter { $0.window.start.ticks < hi && $0.window.end.ticks > lo }
                .map(\.boundaryIndex)
            XCTAssertEqual(got, expected, "range [\(lo),\(hi)) — order must match without sorting")
        }
    }

    func testFullRangeReturnsAllBoundariesInBoundaryIndexOrder() throws {
        let (timeline, _) = try index(sceneCount: 16)
        let twi = timeline.transitionWindowIndex
        let coverage = try ProjectTimeRange(start: .zero, end: try ProjectTime(ticks: timeline.projectDuration.ticks))
        let got = twi.boundaries(intersecting: coverage).map(\.boundaryIndex)
        // Every animated boundary (all of them here) must be present, exactly once, ascending — and the
        // array must already be in that order with no post-sort.
        let expected = Array(0..<(16 - 1))
        XCTAssertEqual(got, expected)
        XCTAssertEqual(got, got.sorted(), "result is already ascending without sorting")
    }

    func testActiveLookupVisitsLogarithmicNodes() throws {
        // The op-count (binary-search comparisons) is O(log m) across growing m; never linear.
        for n in [2, 17, 257, 4097] {     // m = n - 1 animated boundaries
            let (timeline, _) = try index(sceneCount: n)
            let twi = timeline.transitionWindowIndex
            let m = twi.windows.count
            let mid = try ProjectTime(ticks: timeline.projectDuration.ticks / 2)
            let diag = twi.activeBoundaryWithDiagnostics(at: mid).diagnostics
            let bound = 3 * Int(ceil(log2(Double(max(m, 2))))) + 1   // C·⌈log2 m⌉ + 1
            XCTAssertLessThanOrEqual(diag.comparisons, bound, "m=\(m) comparisons=\(diag.comparisons)")
            XCTAssertLessThanOrEqual(diag.visited, 1)               // at most one window checked
        }
    }

    func testRangeLookupIsOutputSensitive() throws {
        // A narrow coverage over 4096 scenes touches O(log m) + O(k) windows, not all m.
        let (timeline, _) = try index(sceneCount: 4096)
        let twi = timeline.transitionWindowIndex
        let coverage = try ProjectTimeRange(start: try ProjectTime(ticks: 0), end: try ProjectTime(ticks: 240_000))
        let (result, diag) = twi.boundariesWithDiagnostics(intersecting: coverage)
        let m = twi.windows.count
        // visited is bounded by (k results) + a small constant for the boundary stop-check.
        XCTAssertLessThanOrEqual(diag.visited, result.count + 2)
        XCTAssertLessThanOrEqual(diag.comparisons, 3 * Int(ceil(log2(Double(max(m, 2))))) + 1)
        XCTAssertLessThan(diag.visited, m)                          // never scans all windows
    }

    func testDisjointnessRejectedWhenViolated() throws {
        // Two overlapping animated windows (bypassing adjacency validation) must throw at construction.
        let scenes = (0..<3).map { i in
            SceneManifestEntry(id: try! SceneInstanceID("s\(i)"), payloadID: try! ScenePayloadID("p\(i)"),
                               nominalDuration: try! TickDuration(ticks: 100_000),
                               postRollCapability: try! TickDuration(ticks: 200_000))
        }
        // Boundaries at 300000 and 350000; fade 240000 ⇒ windows [180000,420000) and [230000,470000)
        // overlap heavily. (Positions are well above 0 so no window start goes negative.)
        let transitions = try (0..<2).map { _ in try CanonicalProjectFixtures.fadeTransition(durationTicks: 240_000) }
        let positions: [Int64] = [300_000, 350_000]
        XCTAssertThrowsError(try TransitionWindowIndex(transitions: transitions, boundaryPositions: positions, scenes: scenes)) {
            XCTAssertEqual($0 as? ProjectValidationError, .invalidRange(field: "TransitionWindowIndex.overlap"))
        }
    }
}
