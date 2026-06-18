/// A pure diagnostic counter returned by the search core (corrective plan C-2).
///
/// **Internal**, never public. It is returned **by value** from the `...WithDiagnostics` search
/// methods so tests can assert operation-count bounds without any mutable static state or `#if DEBUG`
/// divergence. Production and test execute the identical code path; the value semantics make it
/// concurrency-safe.
struct SearchDiagnostics: Equatable, Sendable {
    let comparisons: Int
    let visited: Int

    static let zero = SearchDiagnostics(comparisons: 0, visited: 0)
}

/// An immutable index of **animated** transition windows, sorted by window start (corrective plan C-2).
///
/// Animated windows are disjoint (adjacency validation guarantees
/// `postHalf(prev) + preHalf(next) <= d_middle`), so a point query is a binary search + a single
/// containment check, and a range query is a binary search to the first candidate plus a scan over the
/// intersecting run only. Cut boundaries never produce a window and are excluded.
public struct TransitionWindowIndex: Equatable, Sendable {

    struct AnimatedWindow: Equatable, Sendable {
        let boundaryIndex: Int
        let boundary: ProjectTime
        let transition: SceneTransition
        let window: ProjectTimeRange
        let outgoingSceneID: SceneInstanceID
        let incomingSceneID: SceneInstanceID
    }

    let windows: [AnimatedWindow]      // sorted by window.start, disjoint

    /// Builds the index from the per-boundary transitions, their boundary positions, and the scene
    /// manifest entries. Only animated boundaries are indexed.
    init(transitions: [SceneTransition], boundaryPositions: [Int64], scenes: [SceneManifestEntry]) throws {
        var built: [AnimatedWindow] = []
        for (index, transition) in transitions.enumerated() {
            guard case .animated = transition.kind else { continue }
            let boundary = try ProjectTime(ticks: boundaryPositions[index])
            let window = try TransitionMath.window(boundary: boundary, duration: transition.duration)
            built.append(AnimatedWindow(
                boundaryIndex: index,
                boundary: boundary,
                transition: transition,
                window: window,
                outgoingSceneID: scenes[index].id,
                incomingSceneID: scenes[index + 1].id
            ))
        }
        // The input boundaries are already chronological: boundary positions are cumulative scene
        // ends (strictly increasing), and the windows are centered on them. So we do NOT sort —
        // instead we validate the chronological invariant during construction (corrective pass):
        // each window's start is strictly after the previous window's start, and windows are disjoint
        // (`previous.end <= current.start`). Any violation is a typed error. The array is kept in
        // boundary-index order, which equals chronological order.
        if built.count >= 2 {
            for i in 1..<built.count {
                guard built[i - 1].window.start.ticks < built[i].window.start.ticks else {
                    throw ProjectValidationError.invalidRange(field: "TransitionWindowIndex.startOrder")
                }
                guard built[i - 1].window.end.ticks <= built[i].window.start.ticks else {
                    throw ProjectValidationError.invalidRange(field: "TransitionWindowIndex.overlap")
                }
            }
        }
        self.windows = built
    }

    // MARK: - Point lookup

    /// The active boundary whose window contains `time`, or `nil`. Binary search; no scan.
    public func activeBoundary(at time: ProjectTime) -> ActiveBoundaryReference? {
        activeBoundaryWithDiagnostics(at: time).result
    }

    func activeBoundaryWithDiagnostics(at time: ProjectTime) -> (result: ActiveBoundaryReference?, diagnostics: SearchDiagnostics) {
        var comparisons = 0
        let tick = time.ticks
        // Largest i with windows[i].window.start <= tick.
        var low = 0
        var high = windows.count - 1
        var candidate = -1
        while low <= high {
            comparisons += 1
            let mid = (low + high) / 2
            if windows[mid].window.start.ticks <= tick {
                candidate = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard candidate >= 0 else {
            return (nil, SearchDiagnostics(comparisons: comparisons, visited: 0))
        }
        // Disjointness ⇒ only this candidate can contain `tick`.
        let w = windows[candidate]
        if w.window.contains(time) {
            return (reference(w), SearchDiagnostics(comparisons: comparisons, visited: 1))
        }
        return (nil, SearchDiagnostics(comparisons: comparisons, visited: 1))
    }

    // MARK: - Range lookup

    /// All animated boundaries whose window intersects `coverage`, in boundary-index order.
    /// Binary search to the first candidate, then a scan over the intersecting run only.
    public func boundaries(intersecting coverage: ProjectTimeRange) -> [RequiredBoundary] {
        boundariesWithDiagnostics(intersecting: coverage).result
    }

    func boundariesWithDiagnostics(intersecting coverage: ProjectTimeRange) -> (result: [RequiredBoundary], diagnostics: SearchDiagnostics) {
        var comparisons = 0
        var visited = 0
        guard !windows.isEmpty else { return ([], .zero) }
        // First index whose window.end > coverage.start (a candidate to intersect). Because windows
        // are disjoint and chronological (validated at construction), end is strictly increasing, so
        // binary search is valid.
        var low = 0
        var high = windows.count
        while low < high {
            comparisons += 1
            let mid = (low + high) / 2
            if windows[mid].window.end.ticks > coverage.start.ticks {
                high = mid
            } else {
                low = mid + 1
            }
        }
        // `windows` is stored in chronological order, which equals boundary-index order (validated at
        // construction). The scan therefore appends in boundary-index order — no sort needed, so the
        // query stays O(log m + k) (corrective pass: removed `results.sort`).
        var results: [RequiredBoundary] = []
        var i = low
        while i < windows.count {
            visited += 1
            let w = windows[i]
            // Stop once windows start at/after coverage end (no further intersection possible).
            if w.window.start.ticks >= coverage.end.ticks { break }
            if w.window.end.ticks > coverage.start.ticks {
                results.append(requiredBoundary(w))
            }
            i += 1
        }
        return (results, SearchDiagnostics(comparisons: comparisons, visited: visited))
    }

    // MARK: - Conversions

    private func reference(_ w: AnimatedWindow) -> ActiveBoundaryReference {
        ActiveBoundaryReference(
            boundaryIndex: w.boundaryIndex, boundary: w.boundary,
            transition: w.transition, window: w.window
        )
    }

    private func requiredBoundary(_ w: AnimatedWindow) -> RequiredBoundary {
        RequiredBoundary(
            boundaryIndex: w.boundaryIndex,
            boundary: w.boundary,
            transition: w.transition,
            window: w.window,
            outgoingSceneID: w.outgoingSceneID,
            incomingSceneID: w.incomingSceneID
        )
    }
}
