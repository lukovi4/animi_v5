import Foundation

// MARK: - Global Video Budget Coordinator

/// Coordinates video decoder allocation across multiple scene instances.
/// Ensures that the total number of active video decoders stays within budget.
///
/// Policy:
/// - pin: current scene + transition partner (highest priority)
/// - warm: previous + next scenes (medium priority)
/// - evict: farthest scenes first (lowest priority)
@MainActor
public final class GlobalVideoBudgetCoordinator {

    // MARK: - Configuration

    /// Maximum number of active video decoders across all scenes.
    /// Default: 3 (same as single-scene budget in UserMediaService).
    public let maxActiveDecoders: Int

    // MARK: - State

    /// Currently pinned scene instance IDs (current + transition partner).
    public private(set) var pinnedInstanceIds: Set<UUID> = []

    /// Warm scene instance IDs (prev + next).
    public private(set) var warmInstanceIds: Set<UUID> = []

    /// Current scene index in timeline.
    public private(set) var currentSceneIndex: Int = 0

    // MARK: - Init

    public init(maxActiveDecoders: Int = 3) {
        self.maxActiveDecoders = maxActiveDecoders
    }

    // MARK: - Update

    /// Updates coordinator state based on current playhead position.
    /// - Parameters:
    ///   - transitionMath: Timeline math for computing scene positions.
    ///   - compressedFrame: Current playhead position in compressed frames.
    public func update(
        transitionMath: TimelineTransitionMath,
        compressedFrame: Int
    ) {
        let sceneItems = transitionMath.sceneItems
        guard !sceneItems.isEmpty,
              let mode = transitionMath.renderMode(for: compressedFrame) else {
            pinnedInstanceIds = []
            warmInstanceIds = []
            return
        }

        // Determine render mode to find current/partner scenes
        switch mode {
        case .single(let sceneIndex, _):
            currentSceneIndex = sceneIndex
            pinnedInstanceIds = Set([sceneItems[sceneIndex].id])

            // Warm = prev + next
            var warm: Set<UUID> = []
            if sceneIndex > 0 {
                warm.insert(sceneItems[sceneIndex - 1].id)
            }
            if sceneIndex < sceneItems.count - 1 {
                warm.insert(sceneItems[sceneIndex + 1].id)
            }
            warmInstanceIds = warm

        case .transition(let aIndex, _, let bIndex, _, _, _):
            currentSceneIndex = aIndex
            pinnedInstanceIds = Set([sceneItems[aIndex].id, sceneItems[bIndex].id])

            // Warm = scenes adjacent to transition pair
            var warm: Set<UUID> = []
            let minIdx = min(aIndex, bIndex)
            let maxIdx = max(aIndex, bIndex)
            if minIdx > 0 {
                warm.insert(sceneItems[minIdx - 1].id)
            }
            if maxIdx < sceneItems.count - 1 {
                warm.insert(sceneItems[maxIdx + 1].id)
            }
            warmInstanceIds = warm
        }
    }

    // MARK: - Allocation Query

    /// Allocation tier for a scene instance.
    public enum AllocationTier: Int, Comparable {
        case pinned = 0    // Highest priority
        case warm = 1      // Medium priority
        case evictable = 2 // Lowest priority

        public static func < (lhs: AllocationTier, rhs: AllocationTier) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Returns allocation tier for a scene instance.
    public func allocationTier(for instanceId: UUID) -> AllocationTier {
        if pinnedInstanceIds.contains(instanceId) {
            return .pinned
        } else if warmInstanceIds.contains(instanceId) {
            return .warm
        } else {
            return .evictable
        }
    }

    /// Returns whether a scene instance participates in decoder allocation.
    /// Pinned scenes are considered first; warm scenes receive spare capacity only if budget allows.
    public func shouldHaveActiveDecoders(for instanceId: UUID) -> Bool {
        pinnedInstanceIds.contains(instanceId) || warmInstanceIds.contains(instanceId)
    }

    /// Returns ordered list of scene instances to evict.
    /// Only includes evictable instances, sorted by: distance desc → sceneIndex asc → UUID.uuidString asc
    /// - Parameters:
    ///   - allInstanceIds: All currently loaded scene instance IDs.
    ///   - sceneItems: Timeline scene items for index lookup.
    /// - Returns: Ordered array of evictable instance IDs (farthest first).
    public func instancesToEvictOrdered(
        from allInstanceIds: Set<UUID>,
        sceneItems: [TimelineItem]
    ) -> [UUID] {
        // Build index map
        var indexMap: [UUID: Int] = [:]
        for (index, item) in sceneItems.enumerated() {
            indexMap[item.id] = index
        }

        // Filter to only evictable instances
        let evictableIds = allInstanceIds.filter { instanceId in
            allocationTier(for: instanceId) == .evictable
        }

        // Sort by: distance desc → sceneIndex asc → UUID.uuidString asc
        return evictableIds.sorted { a, b in
            // Distance descending (farther scenes first)
            let distA = abs((indexMap[a] ?? 0) - currentSceneIndex)
            let distB = abs((indexMap[b] ?? 0) - currentSceneIndex)
            if distA != distB {
                return distA > distB  // desc
            }

            // Same distance - sort by sceneIndex ascending
            let indexA = indexMap[a] ?? 0
            let indexB = indexMap[b] ?? 0
            if indexA != indexB {
                return indexA < indexB
            }

            // All else equal - sort by UUID string
            return a.uuidString < b.uuidString
        }
    }

    /// Returns prioritized list of scene instances for decoder allocation.
    /// Sort order: tier asc → distance asc → sceneIndex asc → UUID.uuidString asc
    public func prioritizedInstances(
        from availableInstanceIds: Set<UUID>,
        sceneItems: [TimelineItem]
    ) -> [UUID] {
        // Build index map
        var indexMap: [UUID: Int] = [:]
        for (index, item) in sceneItems.enumerated() {
            indexMap[item.id] = index
        }

        // Sort by: tier asc → distance asc → sceneIndex asc → UUID.uuidString asc
        return availableInstanceIds.sorted { a, b in
            let tierA = allocationTier(for: a)
            let tierB = allocationTier(for: b)
            if tierA != tierB {
                return tierA < tierB
            }

            // Same tier - sort by distance from current (ascending)
            let distA = abs((indexMap[a] ?? 0) - currentSceneIndex)
            let distB = abs((indexMap[b] ?? 0) - currentSceneIndex)
            if distA != distB {
                return distA < distB
            }

            // Same distance - sort by sceneIndex ascending
            let indexA = indexMap[a] ?? 0
            let indexB = indexMap[b] ?? 0
            if indexA != indexB {
                return indexA < indexB
            }

            // All else equal - sort by UUID string for determinism
            return a.uuidString < b.uuidString
        }
    }
}
