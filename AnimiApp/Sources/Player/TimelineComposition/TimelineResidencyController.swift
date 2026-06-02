import Foundation
import TVECore

/// Manages residency window: eviction of non-resident runtimes,
/// warm scene targets, active playback frames, and playback grants.
///
/// Internal implementation detail of `TimelineCompositionEngine`.
@MainActor
internal final class TimelineResidencyController {

    unowned let engine: TimelineCompositionEngine

    init(engine: TimelineCompositionEngine) {
        self.engine = engine
    }

    // MARK: - Residency Window

    /// Refreshes residency window: updates coordinator and evicts non-resident runtimes.
    func refreshResidencyWindow(compressedFrame: Int, math: TimelineTransitionMath) {
        engine.residencyCoordinator.update(transitionMath: math, compressedFrame: compressedFrame)
        evictNonResidentRuntimes(math: math)
    }

    /// Evicts non-resident runtimes based on residency coordinator state.
    func evictNonResidentRuntimes(math: TimelineTransitionMath) {
        let loadedIds = Set(engine.instanceRuntimes.keys)
        let toEvict = engine.residencyCoordinator.instancesToEvictOrdered(
            from: loadedIds,
            sceneItems: math.sceneItems
        )

        // Cancel in-flight creation tasks for evicted instances
        engine.cancelRuntimeCreationTasks(for: Set(toEvict))

        for instanceId in toEvict {
            if let runtime = engine.instanceRuntimes.removeValue(forKey: instanceId) {
                runtime.evictFromTimeline()
                engine.runtimeDiagnosticsSink?.receive(.evictionDecision(instanceId: instanceId, tier: "evictable"))
                #if DEBUG
                print("[TimelineCompositionEngine] TT-03: Evicted non-resident runtime: \(instanceId)")
                #endif
            }
        }
    }

    // MARK: - Warm Targets

    /// Returns boundary-aligned local frames for warm scenes around the current render mode.
    func warmPresentationTargets(
        math: TimelineTransitionMath,
        mode: TimelineTransitionMath.RenderMode
    ) -> [UUID: Int] {
        var targets: [UUID: Int] = [:]

        switch mode {
        case .single(let sceneIndex, _):
            if sceneIndex > 0 {
                let prevIndex = sceneIndex - 1
                targets[math.sceneItems[prevIndex].id] = max(0, math.durationFrames(forSceneAt: prevIndex) - 1)
            }
            if sceneIndex < math.sceneItems.count - 1 {
                let nextIndex = sceneIndex + 1
                targets[math.sceneItems[nextIndex].id] = 0
            }

        case .transition(let aIndex, _, let bIndex, _, _, _):
            let minIndex = min(aIndex, bIndex)
            let maxIndex = max(aIndex, bIndex)
            if minIndex > 0 {
                let prevIndex = minIndex - 1
                targets[math.sceneItems[prevIndex].id] = max(0, math.durationFrames(forSceneAt: prevIndex) - 1)
            }
            if maxIndex < math.sceneItems.count - 1 {
                let nextIndex = maxIndex + 1
                targets[math.sceneItems[nextIndex].id] = 0
            }
        }

        return targets
    }

    // MARK: - Active Playback Frames

    /// Returns local frames for only the active render participants (no warm scenes).
    func activePlaybackLocalFrames(
        math: TimelineTransitionMath,
        mode: TimelineTransitionMath.RenderMode
    ) -> [UUID: Int] {
        switch mode {
        case .single(let sceneIndex, let localFrame):
            guard sceneIndex < math.sceneItems.count else { return [:] }
            return [math.sceneItems[sceneIndex].id: localFrame]

        case .transition(let aIndex, let frameA, let bIndex, let frameB, _, _):
            guard aIndex < math.sceneItems.count,
                  bIndex < math.sceneItems.count else { return [:] }
            return [
                math.sceneItems[aIndex].id: frameA,
                math.sceneItems[bIndex].id: frameB
            ]
        }
    }

    // MARK: - Playback Grants

    /// Computes playback grants for the active render participants.
    ///
    /// Every visible video candidate of an active (pinned) participant is granted.
    /// Warm/evictable scenes are excluded before candidate collection. Quality/performance
    /// degradation, if needed, is the responsibility of explicit knobs (e.g. update cadence),
    /// never a hidden cap here.
    func playbackGrants(
        math: TimelineTransitionMath,
        mode: TimelineTransitionMath.RenderMode,
        localFramesByInstanceId: [UUID: Int]
    ) -> [UUID: Set<String>] {
        let allocationInstanceIds = localFramesByInstanceId.keys.filter {
            engine.residencyCoordinator.shouldRunActivePlayback(for: $0)
        }

        guard !allocationInstanceIds.isEmpty else {
            return [:]
        }

        // 1. Get scene rank for prioritization
        let sceneRank: [UUID: Int] = {
            let prioritized = engine.residencyCoordinator.prioritizedInstances(
                from: Set(allocationInstanceIds),
                sceneItems: math.sceneItems
            )
            var rank: [UUID: Int] = [:]
            for (idx, id) in prioritized.enumerated() {
                rank[id] = idx
            }
            return rank
        }()

        // 2. Collect candidates from all eligible runtimes
        struct FlatCandidate {
            let instanceId: UUID
            let blockId: String
            let priority: BlockPriorityInfo
            let sceneRank: Int
        }

        var flatCandidates: [FlatCandidate] = []

        for instanceId in allocationInstanceIds {
            guard let localFrame = localFramesByInstanceId[instanceId] else { continue }
            guard let runtime = engine.instanceRuntimes[instanceId] else { continue }
            let candidates = runtime.playbackCandidates(at: localFrame)
            let rank = sceneRank[instanceId] ?? 0

            for candidate in candidates {
                flatCandidates.append(FlatCandidate(
                    instanceId: instanceId,
                    blockId: candidate.blockId,
                    priority: candidate.priority,
                    sceneRank: rank
                ))
            }
        }

        // 3. Sort globally for deterministic ordering: isVisible desc → area desc →
        //    zIndex desc → sceneRank asc → instanceId asc → blockId asc.
        //    The sort is now only an ordering aid for diagnostics/determinism — it is
        //    no longer used to select a capped subset.
        flatCandidates.sort { a, b in
            if a.priority.isVisible != b.priority.isVisible {
                return a.priority.isVisible
            }
            if a.priority.area != b.priority.area {
                return a.priority.area > b.priority.area
            }
            if a.priority.zIndex != b.priority.zIndex {
                return a.priority.zIndex > b.priority.zIndex
            }
            if a.sceneRank != b.sceneRank {
                return a.sceneRank < b.sceneRank
            }
            if a.instanceId != b.instanceId {
                return a.instanceId.uuidString < b.instanceId.uuidString
            }
            return a.blockId < b.blockId
        }

        // 4. Grant every candidate of the active render participants.
        //    No fixed decoder-count cap: each visible video block in an active scene
        //    must remain a real playback source. Per-block visibility/timing gating
        //    still happens downstream in UserMediaService; residency (pinned/warm/evict)
        //    already limited candidates to pinned participants above.
        let granted = flatCandidates

        // 5. Group back into [UUID: Set<String>]
        var result: [UUID: Set<String>] = [:]

        for instanceId in allocationInstanceIds {
            result[instanceId] = []
        }

        for candidate in granted {
            result[candidate.instanceId, default: []].insert(candidate.blockId)
        }

        return result
    }
}
