import Foundation
import TVECore

/// Applies playback budget grants to resident runtimes,
/// coordinating start/sync and deactivation of warm scenes.
///
/// Internal implementation detail of `TimelineCompositionEngine`.
@MainActor
internal final class TimelinePlaybackSyncController {

    unowned let engine: TimelineCompositionEngine

    init(engine: TimelineCompositionEngine) {
        self.engine = engine
    }

    /// Applies playback budget to all resident runtimes.
    ///
    /// Active runtimes receive budget-aware playback calls.
    /// Non-active resident runtimes (warm) receive deactivation calls.
    func applyPlaybackBudget(
        mode: TimelineTransitionMath.RenderMode,
        math: TimelineTransitionMath,
        localFramesByInstanceId: [UUID: Int],
        grants: [UUID: Set<String>],
        isStart: Bool,
        hostTime: CFTimeInterval?
    ) {
        // Step 1: Compute active instance IDs from current render mode
        var activeInstanceIds: Set<UUID> = []
        switch mode {
        case .single(let sceneIndex, _):
            guard sceneIndex < math.sceneItems.count else { return }
            activeInstanceIds.insert(math.sceneItems[sceneIndex].id)

        case .transition(let aIndex, _, let bIndex, _, _, _):
            guard aIndex < math.sceneItems.count,
                  bIndex < math.sceneItems.count else { return }
            activeInstanceIds.insert(math.sceneItems[aIndex].id)
            activeInstanceIds.insert(math.sceneItems[bIndex].id)
        }

        // Step 2: Compute resident loaded set = loaded runtimes ∩ (pinned ∪ warm)
        let residentIds = Set(engine.instanceRuntimes.keys).intersection(
            engine.budgetCoordinator.pinnedInstanceIds.union(engine.budgetCoordinator.warmInstanceIds)
        )

        // Step 3: Update active scenes and warm scenes that actually received spare grants.
        var syncedInstanceIds: Set<UUID> = []
        for instanceId in residentIds {
            guard let localFrame = localFramesByInstanceId[instanceId] else { continue }
            let grantedBlockIds = grants[instanceId] ?? []
            let shouldSync = activeInstanceIds.contains(instanceId) || !grantedBlockIds.isEmpty
            guard shouldSync else { continue }

            if isStart {
                engine.instanceRuntimes[instanceId]?.startPlayback(at: localFrame, grantedBlockIds: grantedBlockIds, hostTime: hostTime)
            } else {
                engine.instanceRuntimes[instanceId]?.syncPlaybackTick(localFrame, grantedBlockIds: grantedBlockIds, hostTime: hostTime)
            }
            syncedInstanceIds.insert(instanceId)
        }

        // Step 4: Resident runtimes without active grants keep last texture but release decoder slots.
        for instanceId in residentIds
        where !activeInstanceIds.contains(instanceId) && !syncedInstanceIds.contains(instanceId) {
            engine.instanceRuntimes[instanceId]?.deactivatePlaybackPreservingTextures()
        }
    }
}
