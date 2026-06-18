/// An immutable **augmented interval tree** over global-overlay project-time ranges
/// (Task-002 plan, §10.1).
///
/// Active-overlay lookup is **`O(log n + k log k)`** where `k` is the number of returned overlays
/// (corrective plan C-8, Option B — APPROVED). The augmented-tree traversal collects matches in
/// `O(log n + k)`; the deterministic `(zIndex, stableOrdinal, overlayID)` sort applied to the result
/// adds the `O(k log k)` term. This is an **approved deviation** from §10.1's original `O(log n + k)`
/// wording — see ADR-002 and the decision register. Each node stores its own half-open interval, a
/// deterministic ordering key, and the subtree's maximum end so a stabbing query can prune branches.
public struct OverlayIntervalIndex: Equatable, Sendable {

    /// One indexed overlay interval with its deterministic ordering key. Public so callers can read
    /// the active set returned by ``overlays(containing:)``.
    public struct Interval: Equatable, Sendable {
        public let overlayID: OverlayID
        public let payloadID: OverlayPayloadID
        public let start: Int64           // inclusive
        public let end: Int64             // exclusive
        public let zIndex: Int
        public let stableOrdinal: Int
    }

    /// An immutable balanced-by-construction node. The tree is built from intervals sorted by
    /// `start`, recursively choosing the median — this yields an `O(log n)` height deterministically
    /// without any randomness.
    struct Node: Equatable, Sendable {
        let interval: Interval
        let subtreeMaxEnd: Int64
        let left: Int?             // node index, or nil
        let right: Int?            // node index, or nil
    }

    private let nodes: [Node]
    private let rootIndex: Int?

    /// Builds the index from manifest overlay entries.
    public init(overlays: [OverlayManifestEntry]) {
        var intervals = overlays.map { entry in
            Interval(
                overlayID: entry.id,
                payloadID: entry.payloadID,
                start: entry.timeRange.start.ticks,
                end: entry.timeRange.end.ticks,
                zIndex: entry.zIndex,
                stableOrdinal: entry.stableOrdinal
            )
        }
        // Sort by start (then by ordering key) so median selection is deterministic.
        intervals.sort { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.zIndex != rhs.zIndex { return lhs.zIndex < rhs.zIndex }
            return lhs.stableOrdinal < rhs.stableOrdinal
        }
        var builder = [Node]()
        let root = OverlayIntervalIndex.buildSubtree(intervals[...], into: &builder)
        self.nodes = builder
        self.rootIndex = root
    }

    /// Recursively builds a balanced subtree from a start-sorted slice, returning its node index.
    private static func buildSubtree(_ slice: ArraySlice<Interval>, into nodes: inout [Node]) -> Int? {
        guard !slice.isEmpty else { return nil }
        let mid = slice.startIndex + slice.count / 2
        let leftSlice = slice[slice.startIndex..<mid]
        let rightSlice = slice[(mid + 1)..<slice.endIndex]
        let leftIndex = buildSubtree(leftSlice, into: &nodes)
        let rightIndex = buildSubtree(rightSlice, into: &nodes)
        let interval = slice[mid]
        var maxEnd = interval.end
        if let l = leftIndex { maxEnd = Swift.max(maxEnd, nodes[l].subtreeMaxEnd) }
        if let r = rightIndex { maxEnd = Swift.max(maxEnd, nodes[r].subtreeMaxEnd) }
        let node = Node(interval: interval, subtreeMaxEnd: maxEnd, left: leftIndex, right: rightIndex)
        nodes.append(node)
        return nodes.count - 1
    }

    /// All overlays whose half-open interval contains `tick`, deterministically ordered by
    /// `(zIndex, stableOrdinal)` then overlay id (Task-002 plan, §10.1).
    ///
    /// `O(log n + k log k)` (corrective plan C-8, Option B): the traversal collects in `O(log n + k)`,
    /// then the deterministic sort adds `O(k log k)`.
    public func overlays(containing tick: Int64) -> [Interval] {
        overlaysWithDiagnostics(containing: tick).result
    }

    /// Diagnostic variant returning the traversal node-visit count (corrective plan C-2 mechanism,
    /// reused for C-8). `comparisons`/`visited` count the **tree traversal** (the `O(log n + k)` part);
    /// the subsequent sort is the documented `O(k log k)` term. Internal so tests can inspect it.
    func overlaysWithDiagnostics(containing tick: Int64) -> (result: [Interval], diagnostics: SearchDiagnostics) {
        var results: [Interval] = []
        var visited = 0
        stab(rootIndex, tick: tick, into: &results, visited: &visited)
        results.sort { lhs, rhs in
            if lhs.zIndex != rhs.zIndex { return lhs.zIndex < rhs.zIndex }
            if lhs.stableOrdinal != rhs.stableOrdinal { return lhs.stableOrdinal < rhs.stableOrdinal }
            return lhs.overlayID.raw < rhs.overlayID.raw
        }
        return (results, SearchDiagnostics(comparisons: visited, visited: visited))
    }

    /// All overlays whose half-open interval intersects `[start, end)`, deterministically ordered by
    /// `(zIndex, stableOrdinal)` then overlay id. Used to build evaluation-window requirements.
    ///
    /// `O(log n + k log k)` (corrective plan C-8, Option B): traversal `O(log n + k)` plus the
    /// deterministic sort `O(k log k)`.
    public func intervals(intersecting start: Int64, _ end: Int64) -> [Interval] {
        var results: [Interval] = []
        rangeStab(rootIndex, start: start, end: end, into: &results)
        results.sort { lhs, rhs in
            if lhs.zIndex != rhs.zIndex { return lhs.zIndex < rhs.zIndex }
            if lhs.stableOrdinal != rhs.stableOrdinal { return lhs.stableOrdinal < rhs.stableOrdinal }
            return lhs.overlayID.raw < rhs.overlayID.raw
        }
        return results
    }

    private func rangeStab(_ index: Int?, start: Int64, end: Int64, into results: inout [Interval]) {
        guard let index else { return }
        let node = nodes[index]
        if node.subtreeMaxEnd <= start { return }       // whole subtree ends before the query
        rangeStab(node.left, start: start, end: end, into: &results)
        // Half-open intersection: interval.start < end && interval.end > start.
        if node.interval.start < end && node.interval.end > start {
            results.append(node.interval)
        }
        if node.interval.start < end {
            rangeStab(node.right, start: start, end: end, into: &results)
        }
    }

    private func stab(_ index: Int?, tick: Int64, into results: inout [Interval], visited: inout Int) {
        guard let index else { return }
        visited += 1
        let node = nodes[index]
        // Prune: if the whole subtree ends at or before tick, nothing here contains it.
        if node.subtreeMaxEnd <= tick { return }
        // Left subtree may contain matches (its starts are <= this node's start region).
        stab(node.left, tick: tick, into: &results, visited: &visited)
        // This node: half-open containment.
        if node.interval.start <= tick && tick < node.interval.end {
            results.append(node.interval)
        }
        // Right subtree only if tick is at/after this node's start.
        if node.interval.start <= tick {
            stab(node.right, tick: tick, into: &results, visited: &visited)
        }
    }
}
