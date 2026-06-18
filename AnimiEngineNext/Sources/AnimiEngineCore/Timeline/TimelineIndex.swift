/// A binary-search scene span index built from cumulative scene durations (Task-002 plan, §10.1).
///
/// `starts[i]` is the project-time tick where scene `i` begins; `ends[i]` is its nominal end. All
/// prefix sums are overflow-checked at construction.
public struct SceneSpanIndex: Equatable, Sendable {
    public let starts: [Int64]      // scene start ticks, ascending
    public let ends: [Int64]        // scene nominal end ticks (== next start)

    init(scenes: [SceneManifestEntry]) throws {
        var starts: [Int64] = []
        var ends: [Int64] = []
        var cursor: Int64 = 0
        for scene in scenes {
            starts.append(cursor)
            cursor = try CheckedInt64.add(cursor, scene.nominalDuration.ticks, "SceneSpanIndex.prefix")
            ends.append(cursor)
        }
        self.starts = starts
        self.ends = ends
    }

    /// Binary search for the scene whose half-open span `[start, end)` contains `tick`.
    ///
    /// Returns `nil` if `tick` is outside `[0, projectDuration)`.
    public func sceneIndex(containing tick: Int64) -> Int? {
        sceneIndexWithDiagnostics(containing: tick).result
    }

    /// Binary search with a pure operation-count diagnostic (corrective plan C-2). The public method
    /// discards the diagnostics; tests inspect them. Identical code path in both cases.
    func sceneIndexWithDiagnostics(containing tick: Int64) -> (result: Int?, diagnostics: SearchDiagnostics) {
        var comparisons = 0
        guard !starts.isEmpty, tick >= starts[0], tick < ends[ends.count - 1] else {
            return (nil, SearchDiagnostics(comparisons: comparisons, visited: 0))
        }
        var low = 0
        var high = starts.count - 1
        while low <= high {
            comparisons += 1
            let mid = (low + high) / 2
            if tick < starts[mid] {
                high = mid - 1
            } else if tick >= ends[mid] {
                low = mid + 1
            } else {
                return (mid, SearchDiagnostics(comparisons: comparisons, visited: 1))
            }
        }
        return (nil, SearchDiagnostics(comparisons: comparisons, visited: 0))
    }
}

/// A boundary index: the project-time position of each scene boundary (Task-002 plan, §10.1).
public struct BoundaryIndex: Equatable, Sendable {
    /// `positions[i]` is the boundary between scene `i` and scene `i+1` (== `sceneSpanIndex.ends[i]`).
    public let positions: [Int64]

    init(sceneSpanIndex: SceneSpanIndex) {
        // For n scenes there are n-1 boundaries, each at scene i's nominal end.
        if sceneSpanIndex.ends.count <= 1 {
            self.positions = []
        } else {
            self.positions = Array(sceneSpanIndex.ends.dropLast())
        }
    }
}

/// The lazy, immutable project timeline index (Task-002 plan, §10.1).
///
/// Scene lookup and active-transition lookup are `O(log n)` (binary search via ``SceneSpanIndex`` and
/// ``TransitionWindowIndex``); active-overlay lookup is `O(log n + k log k)` (augmented interval tree
/// traversal `O(log n + k)` plus the deterministic ordering sort `O(k log k)` — corrective plan C-8,
/// Option B). The index is built once from the manifest; payloads are loaded separately and only as
/// required.
public struct TimelineIndex: Equatable, Sendable {
    public let output: OutputContext
    public let projectDuration: TickDuration
    public let sceneIndex: SceneSpanIndex
    public let boundaryIndex: BoundaryIndex
    public let overlayIndex: OverlayIntervalIndex
    public let transitionWindowIndex: TransitionWindowIndex

    private let scenes: [SceneManifestEntry]
    private let transitions: [SceneTransition]

    public init(manifest: CanonicalProjectManifest) throws {
        // An index can never be built from an invalid manifest (corrective plan C-5).
        try ProjectValidator.validateManifest(manifest)
        self.output = manifest.output
        self.projectDuration = try manifest.projectDuration()
        let spanIndex = try SceneSpanIndex(scenes: manifest.scenes)
        self.sceneIndex = spanIndex
        let boundaries = BoundaryIndex(sceneSpanIndex: spanIndex)
        self.boundaryIndex = boundaries
        self.overlayIndex = OverlayIntervalIndex(overlays: manifest.overlays)
        // Binary-search transition index over animated windows (corrective plan C-2).
        self.transitionWindowIndex = try TransitionWindowIndex(
            transitions: manifest.boundaryTransitions,
            boundaryPositions: boundaries.positions,
            scenes: manifest.scenes
        )
        self.scenes = manifest.scenes
        self.transitions = manifest.boundaryTransitions
    }

    // MARK: - Lookup

    /// Looks up the active scene(s), transition, and overlays at `time` (Task-002 plan, §10.1).
    public func lookup(at time: ProjectTime) throws -> TimelineLookupResult {
        let tick = time.ticks
        guard let sceneIdx = sceneIndex.sceneIndex(containing: tick) else {
            throw ProjectValidationError.invalidRange(field: "TimelineIndex.lookup.outsideProject")
        }

        let active = activeBoundary(at: time)
        let requiredSceneIndices: [Int]
        if let active {
            requiredSceneIndices = [active.boundaryIndex, active.boundaryIndex + 1]
        } else {
            requiredSceneIndices = [sceneIdx]
        }
        let requiredSceneIDs = requiredSceneIndices.map { scenes[$0].id }
        let requiredScenePayloadIDs = requiredSceneIndices.map { scenes[$0].payloadID }

        let overlayHits = overlayIndex.overlays(containing: tick)
        let activeOverlayIDs = overlayHits.map(\.overlayID)
        let activeOverlayPayloadIDs = overlayHits.map(\.payloadID)

        return TimelineLookupResult(
            requiredSceneIDs: requiredSceneIDs,
            requiredScenePayloadIDs: requiredScenePayloadIDs,
            transition: active,
            activeOverlayIDs: activeOverlayIDs,
            activeOverlayPayloadIDs: activeOverlayPayloadIDs
        )
    }

    /// Determines whether `time` falls inside an animated transition window, returning a reference.
    ///
    /// Binary search via ``TransitionWindowIndex`` — no scan over every transition (corrective plan C-2).
    private func activeBoundary(at time: ProjectTime) -> ActiveBoundaryReference? {
        transitionWindowIndex.activeBoundary(at: time)
    }

    // MARK: - Requirements

    /// Computes the authoritative evaluation-window requirement for a coverage range
    /// (Task-002 plan, §10.2).
    ///
    /// `coverage` must be non-empty and inside `[0, projectDuration)`. The requirement gathers every
    /// scene span, transition boundary, and overlay that any time in `coverage` could need.
    public func requirements(for coverage: ProjectTimeRange) throws -> EvaluationWindowRequirement {
        let projectEnd = try ProjectTime.zero.adding(projectDuration)
        guard coverage.start >= ProjectTime.zero, coverage.end <= projectEnd else {
            throw ProjectValidationError.invalidEvaluationWindowCoverage
        }
        // Last representable tick inside coverage (half-open).
        let lastTick = coverage.end.ticks - 1
        guard lastTick >= coverage.start.ticks else {
            throw ProjectValidationError.invalidEvaluationWindowCoverage
        }

        // Transition boundaries intersecting coverage — binary search, results-only (corrective plan C-2).
        let boundaries = transitionWindowIndex.boundaries(intersecting: coverage)

        // Required scene indices.
        var sceneIndices = Set<Int>()
        // Each intersecting animated boundary requires its outgoing+incoming scene pair.
        for boundary in boundaries {
            sceneIndices.insert(boundary.boundaryIndex)
            sceneIndices.insert(boundary.boundaryIndex + 1)
        }
        // Base scenes intersecting coverage are the **contiguous index interval**
        // [sceneIndex(coverage.start) ... sceneIndex(lastTick)] — scene spans are contiguous on the
        // timeline, so binary search at both ends bounds the run; no full-array scan (corrective plan C-2).
        if let firstScene = sceneIndex.sceneIndex(containing: coverage.start.ticks),
           let lastScene = sceneIndex.sceneIndex(containing: lastTick) {
            for i in firstScene...lastScene { sceneIndices.insert(i) }
        }

        let sceneSpans = try sceneIndices.sorted().map { i -> RequiredSceneSpan in
            RequiredSceneSpan(
                sceneID: scenes[i].id,
                payloadID: scenes[i].payloadID,
                sceneStart: try ProjectTime(ticks: sceneIndex.starts[i]),
                nominalDuration: scenes[i].nominalDuration,
                postRollCapability: scenes[i].postRollCapability
            )
        }

        // Overlays: any whose interval intersects coverage. The interval ticks come from the manifest
        // (validated `end > start`), but the range is built through the checked initializer and any
        // failure is propagated as a typed error — no `try?`/force-unwrap (corrective plan C-6).
        let overlayEntries: [RequiredOverlayEntry] = try overlayIndex
            .intervals(intersecting: coverage.start.ticks, coverage.end.ticks)
            .map { interval in
                let timeRange: ProjectTimeRange
                do {
                    timeRange = try ProjectTimeRange(
                        start: ProjectTime(uncheckedTicks: interval.start),
                        end: ProjectTime(uncheckedTicks: interval.end)
                    )
                } catch {
                    throw ProjectValidationError.invalidRange(field: "overlay.timeRange")
                }
                return RequiredOverlayEntry(
                    overlayID: interval.overlayID,
                    payloadID: interval.payloadID,
                    timeRange: timeRange,
                    zIndex: interval.zIndex,
                    stableOrdinal: interval.stableOrdinal
                )
            }

        // `boundaries` is already in boundary-index order from the transition window index.
        return EvaluationWindowRequirement(
            coverage: coverage,
            output: output,
            projectDuration: projectDuration,
            sceneSpans: sceneSpans,
            transitions: boundaries,
            overlayEntries: overlayEntries
        )
    }
}
