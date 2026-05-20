import Foundation
import Metal
import TVECore
import os.log

/// Resolves single and transition frames by creating/fetching runtimes
/// and checking readiness state according to the resolve policy.
///
/// Internal implementation detail of `TimelineCompositionEngine`.
@MainActor
internal final class TimelineFrameResolver {

    unowned let engine: TimelineCompositionEngine

    init(engine: TimelineCompositionEngine) {
        self.engine = engine
    }

    // MARK: - Single-Flight Runtime Creation

    private struct RuntimeCreationEntry {
        let token: UUID
        let task: Task<SceneInstanceRuntime?, Never>
    }

    private var runtimeCreationTasks: [UUID: RuntimeCreationEntry] = [:]

    /// Gets or creates a runtime for the given instance ID.
    /// Does NOT wait for readiness - caller controls readiness via policy.
    func getOrCreateRuntime(for instanceId: UUID) async -> SceneInstanceRuntime? {
        // Already loaded?
        if let existing = engine.instanceRuntimes[instanceId] {
            #if DEBUG
            if MemoryDiagnostics.isVerboseRuntimeEnabled {
                MemoryDiagnostics.event("Runtime.cacheHit", "id=\(instanceId) total=\(engine.instanceRuntimes.count)")
            }
            #endif
            return existing
        }

        // Join in-flight creation if one exists
        if let inflight = runtimeCreationTasks[instanceId] {
            #if DEBUG
            MemoryDiagnostics.event("Runtime.create.join", "id=\(instanceId)")
            #endif
            return await inflight.task.value
        }

        // Resolve timeline item synchronously before any suspension
        guard let timeline = engine.timeline,
              let item = timeline.sceneItems.first(where: { $0.id == instanceId }),
              let timelinePayload = timeline.payloads[item.payloadId] else {
            #if DEBUG
            print("[TimelineCompositionEngine] Failed to find item or payload for instanceId: \(instanceId)")
            #endif
            return nil
        }

        guard case .scene(let scenePayload) = timelinePayload else {
            #if DEBUG
            print("[TimelineCompositionEngine] Payload is not a scene for instanceId: \(instanceId)")
            #endif
            return nil
        }

        let sceneTypeId = scenePayload.sceneTypeId
        let token = UUID()

        #if DEBUG
        MemoryDiagnostics.event("Runtime.create.start", "id=\(instanceId) sceneType=\(sceneTypeId)")
        #endif

        let task = Task<SceneInstanceRuntime?, Never> { @MainActor [weak self, weak engine] in
            guard let engine else { return nil }

            // Early cancellation guard before expensive preload
            if Task.isCancelled {
                #if DEBUG
                MemoryDiagnostics.event("Runtime.create.complete", "id=\(instanceId) outcome=cancelled")
                #endif
                return nil
            }

            // Preload resources
            let resources: SceneTypeResourcesCache.Resources
            if let cached = engine.resourcesCache.resources(for: sceneTypeId) {
                resources = cached
            } else {
                engine.runtimeDiagnosticsSink?.receive(.sceneTypePreloadStarted(sceneTypeId: sceneTypeId))
                do {
                    resources = try await engine.resourcesCache.preload(sceneTypeId: sceneTypeId)
                    engine.runtimeDiagnosticsSink?.receive(.sceneTypePreloadCompleted(sceneTypeId: sceneTypeId))
                } catch {
                    engine.runtimeDiagnosticsSink?.receive(.sceneTypePreloadFailed(sceneTypeId: sceneTypeId, error: error.localizedDescription))
                    #if DEBUG
                    MemoryDiagnostics.event("Runtime.create.complete", "id=\(instanceId) outcome=failed")
                    #endif
                    return nil
                }
            }

            // Post-await cancellation check
            if Task.isCancelled {
                #if DEBUG
                MemoryDiagnostics.event("Runtime.create.complete", "id=\(instanceId) outcome=cancelled")
                #endif
                return nil
            }

            // Late-race guard: another path may have populated the runtime
            if let existing = engine.instanceRuntimes[instanceId] {
                #if DEBUG
                MemoryDiagnostics.event("Runtime.create.complete", "id=\(instanceId) outcome=late-race-hit")
                #endif
                return existing
            }

            // Check timeline still contains this instance
            guard let currentTimeline = engine.timeline,
                  currentTimeline.sceneItems.contains(where: { $0.id == instanceId }) else {
                #if DEBUG
                MemoryDiagnostics.event("Runtime.create.complete", "id=\(instanceId) outcome=stale-timeline")
                #endif
                return nil
            }

            // Create instance runtime via factory
            let runtime = engine.runtimeFactory(instanceId, resources, engine.device, engine.commandQueue)

            // Propagate diagnostics sink to runtime
            runtime.runtimeDiagnosticsSink = engine.runtimeDiagnosticsSink

            // Forward runtime redraw requests to engine callback
            runtime.onNeedsRedraw = { [weak engine] in
                engine?.onNeedsRedraw?()
            }

            // Apply state if available
            if let state = engine.sceneStates[instanceId] {
                await runtime.applyState(state, assetRegistry: engine.currentAssetRegistry)
            }

            // Post-applyState cancellation check
            if Task.isCancelled {
                #if DEBUG
                MemoryDiagnostics.event("Runtime.create.complete", "id=\(instanceId) outcome=cancelled")
                #endif
                return nil
            }

            // Active-token guard: if our token was removed (e.g. by cancelCreationTasks),
            // another creation may be in progress — do not store a stale runtime.
            guard self?.runtimeCreationTasks[instanceId]?.token == token else {
                #if DEBUG
                MemoryDiagnostics.event("Runtime.create.complete", "id=\(instanceId) outcome=token-mismatch")
                #endif
                return nil
            }

            // Store in cache
            engine.instanceRuntimes[instanceId] = runtime
            #if DEBUG
            MemoryDiagnostics.event("Runtime.create.complete", "id=\(instanceId) outcome=success total=\(engine.instanceRuntimes.count)")
            #endif

            return runtime
        }

        runtimeCreationTasks[instanceId] = RuntimeCreationEntry(token: token, task: task)

        let result = await task.value

        // Cleanup only if our token still matches (prevents removing a newer entry)
        if runtimeCreationTasks[instanceId]?.token == token {
            runtimeCreationTasks[instanceId] = nil
        }

        return result
    }

    // MARK: - Creation Task Cancellation

    /// Cancels in-flight creation tasks for the given instance IDs.
    func cancelCreationTasks(for ids: Set<UUID>) {
        for id in ids {
            if let entry = runtimeCreationTasks.removeValue(forKey: id) {
                entry.task.cancel()
            }
        }
    }

    /// Cancels all in-flight creation tasks.
    func cancelAllCreationTasks() {
        for (_, entry) in runtimeCreationTasks {
            entry.task.cancel()
        }
        runtimeCreationTasks.removeAll()
    }

    // MARK: - Frame Resolution

    /// Resolves single scene frame with explicit state branching.
    func resolveSingleFrame(
        math: TimelineTransitionMath,
        sceneIndex: Int,
        localFrame: Int,
        generation: UInt64?,
        policy: TimelineResolvePolicy
    ) async -> TimelineFrameResolution {
        guard sceneIndex < math.sceneItems.count else {
            return .failed(.invalidTimeline)
        }

        let instanceId = math.sceneItems[sceneIndex].id

        guard let runtime = await getOrCreateRuntime(for: instanceId) else {
            return .failed(.missingDependency(instanceId))
        }

        // Check generation after async create
        if let gen = generation, gen != engine.scrubGeneration {
            return .staleGeneration
        }

        switch policy {
        case .presentation:
            switch runtime.readinessState {
            case .created:
                runtime.startPreparingForPresentation(at: localFrame)
                if let gen = generation, gen != engine.scrubGeneration {
                    return .staleGeneration
                }
                return .hold

            case .preparing:
                if let gen = generation, gen != engine.scrubGeneration {
                    return .staleGeneration
                }
                return .hold

            case .ready:
                let context = runtime.makeRenderContext(localFrame: localFrame)
                return .resolved(.single(context))

            case .failed(let reason):
                return .failed(.dependencyFailed(instanceId, reason: reason))

            case .timedOut:
                return .failed(.dependencyTimedOut(instanceId))
            }

        case .export:
            let state = await runtime.waitUntilReadyForPresentation(at: localFrame)

            if let gen = generation, gen != engine.scrubGeneration {
                return .staleGeneration
            }

            switch state {
            case .ready:
                let context = runtime.makeRenderContext(localFrame: localFrame)
                return .resolved(.single(context))
            case .failed(let reason):
                return .failed(.dependencyFailed(instanceId, reason: reason))
            case .timedOut:
                return .failed(.dependencyTimedOut(instanceId))
            case .created, .preparing:
                return .failed(.dependencyTimedOut(instanceId))
            }
        }
    }

    /// Resolves transition frame - both scenes must be ready.
    func resolveTransitionFrame(
        math: TimelineTransitionMath,
        aIndex: Int, frameA: Int,
        bIndex: Int, frameB: Int,
        transition: SceneTransition,
        progress: Double,
        generation: UInt64?,
        policy: TimelineResolvePolicy
    ) async -> TimelineFrameResolution {
        guard aIndex < math.sceneItems.count,
              bIndex < math.sceneItems.count else {
            return .failed(.invalidTimeline)
        }

        let instanceIdA = math.sceneItems[aIndex].id
        let instanceIdB = math.sceneItems[bIndex].id

        // Create both runtimes in parallel
        async let runtimeATask = getOrCreateRuntime(for: instanceIdA)
        async let runtimeBTask = getOrCreateRuntime(for: instanceIdB)

        guard let runtimeA = await runtimeATask else {
            return .failed(.missingDependency(instanceIdA))
        }
        guard let runtimeB = await runtimeBTask else {
            return .failed(.missingDependency(instanceIdB))
        }

        // Check generation after async create
        if let gen = generation, gen != engine.scrubGeneration {
            return .staleGeneration
        }

        switch policy {
        case .presentation:
            let stateA = runtimeA.readinessState
            let stateB = runtimeB.readinessState

            // Start preparing if needed
            if case .created = stateA {
                runtimeA.startPreparingForPresentation(at: frameA)
            }
            if case .created = stateB {
                runtimeB.startPreparingForPresentation(at: frameB)
            }

            // Check for terminal failures first
            if case .failed(let reason) = stateA {
                return .failed(.dependencyFailed(instanceIdA, reason: reason))
            }
            if case .failed(let reason) = stateB {
                return .failed(.dependencyFailed(instanceIdB, reason: reason))
            }
            if case .timedOut = stateA {
                return .failed(.dependencyTimedOut(instanceIdA))
            }
            if case .timedOut = stateB {
                return .failed(.dependencyTimedOut(instanceIdB))
            }

            // Check if both ready
            guard case .ready = runtimeA.readinessState,
                  case .ready = runtimeB.readinessState else {
                if let gen = generation, gen != engine.scrubGeneration {
                    return .staleGeneration
                }
                return .hold
            }

            // Both ready
            engine.runtimeDiagnosticsSink?.receive(.transitionPartnerReady(instanceIdA: instanceIdA, instanceIdB: instanceIdB))
            let contextA = runtimeA.makeRenderContext(localFrame: frameA)
            let contextB = runtimeB.makeRenderContext(localFrame: frameB)
            let transitionContext = TransitionRenderContext(
                sceneA: contextA,
                sceneB: contextB,
                transition: transition,
                progress: progress
            )
            return .resolved(.transition(transitionContext))

        case .export:
            // Wait for both in parallel
            async let stateATask = runtimeA.waitUntilReadyForPresentation(at: frameA)
            async let stateBTask = runtimeB.waitUntilReadyForPresentation(at: frameB)

            let resultA = await stateATask
            let resultB = await stateBTask

            if let gen = generation, gen != engine.scrubGeneration {
                return .staleGeneration
            }

            // Check A
            switch resultA {
            case .ready:
                break
            case .failed(let reason):
                return .failed(.dependencyFailed(instanceIdA, reason: reason))
            case .timedOut:
                return .failed(.dependencyTimedOut(instanceIdA))
            case .created, .preparing:
                return .failed(.dependencyTimedOut(instanceIdA))
            }

            // Check B
            switch resultB {
            case .ready:
                break
            case .failed(let reason):
                return .failed(.dependencyFailed(instanceIdB, reason: reason))
            case .timedOut:
                return .failed(.dependencyTimedOut(instanceIdB))
            case .created, .preparing:
                return .failed(.dependencyTimedOut(instanceIdB))
            }

            let contextA = runtimeA.makeRenderContext(localFrame: frameA)
            let contextB = runtimeB.makeRenderContext(localFrame: frameB)
            let transitionContext = TransitionRenderContext(
                sceneA: contextA,
                sceneB: contextB,
                transition: transition,
                progress: progress
            )
            return .resolved(.transition(transitionContext))
        }
    }
}
