import AVFoundation
import Foundation
import Metal
import TVECore

// MARK: - Timeline Composition Engine

/// Engine for composing multi-scene timeline with transitions.
/// Manages scene resources, video budget, and frame resolution.
///
/// Replaces TimelinePlaybackCoordinator for timeline runtime path.
/// Scene Edit mode continues to use single-scene path.
@MainActor
public final class TimelineCompositionEngine {

    // MARK: - Dependencies

    /// Timeline math for compressed positions and transitions.
    public private(set) var transitionMath: TimelineTransitionMath?

    /// Video budget coordinator.
    public let budgetCoordinator: GlobalVideoBudgetCoordinator

    /// Scene type resources cache (shared across instances of same type).
    public let resourcesCache: SceneTypeResourcesCache

    /// Metal device.
    public let device: MTLDevice

    /// Metal command queue.
    public let commandQueue: MTLCommandQueue

    /// Frame rate (v1: always 30).
    public let fps: Int

    /// Template-level canvas size (from SceneLibrarySnapshot.canvas).
    /// Source of truth for canvas - not derived from runtime.
    public private(set) var templateCanvas: CanvasConfig?

    // MARK: - State

    /// Current timeline.
    public private(set) var timeline: CanonicalTimeline?

    /// Scene states by instance ID.
    public private(set) var sceneStates: [UUID: SceneState] = [:]

    /// Loaded scene runtimes by instance ID.
    private var instanceRuntimes: [UUID: SceneInstanceRuntime] = [:]

    /// Generation counter for scrub cancellation.
    /// Incremented on each playhead change to invalidate stale async results.
    private var scrubGeneration: UInt64 = 0

    /// TT-02: Factory for creating SceneInstanceRuntime. Non-optional.
    /// Public init provides production closure, internal init for tests.
    private let runtimeFactory: (UUID, SceneTypeResourcesCache.Resources, MTLDevice, MTLCommandQueue) -> SceneInstanceRuntime

    /// Diagnostics sink for runtime events (test-only, nil in production).
    internal private(set) var runtimeDiagnosticsSink: RuntimeDiagnosticsSink?

    /// Diagnostics sink for render events (test-only, nil in production).
    internal private(set) var renderDiagnosticsSink: RenderDiagnosticsSink?

    // MARK: - Init

    public init(
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        fps: Int = 30,
        maxActiveDecoders: Int = 3
    ) {
        self.device = device
        self.commandQueue = commandQueue
        self.fps = fps
        self.budgetCoordinator = GlobalVideoBudgetCoordinator(maxActiveDecoders: maxActiveDecoders)
        self.resourcesCache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        self.runtimeDiagnosticsSink = nil
        self.renderDiagnosticsSink = nil
        // TT-02: Production factory
        self.runtimeFactory = { instanceId, resources, dev, queue in
            SceneInstanceRuntime(
                sceneInstanceId: instanceId,
                resources: resources,
                device: dev,
                commandQueue: queue
            )
        }
    }

    /// TT-02: Internal init for tests with injected runtime factory.
    init(
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        fps: Int = 30,
        maxActiveDecoders: Int = 3,
        resourcesCache: SceneTypeResourcesCache,
        runtimeFactory: @escaping (UUID, SceneTypeResourcesCache.Resources, MTLDevice, MTLCommandQueue) -> SceneInstanceRuntime,
        runtimeDiagnosticsSink: RuntimeDiagnosticsSink? = nil,
        renderDiagnosticsSink: RenderDiagnosticsSink? = nil
    ) {
        self.device = device
        self.commandQueue = commandQueue
        self.fps = fps
        self.budgetCoordinator = GlobalVideoBudgetCoordinator(maxActiveDecoders: maxActiveDecoders)
        self.resourcesCache = resourcesCache
        self.runtimeFactory = runtimeFactory
        self.runtimeDiagnosticsSink = runtimeDiagnosticsSink
        self.renderDiagnosticsSink = renderDiagnosticsSink
    }

    // MARK: - Configuration

    /// Sets the template canvas (from SceneLibrarySnapshot).
    /// Must be called before timeline export.
    public func setTemplateCanvas(_ canvas: CanvasConfig) {
        self.templateCanvas = canvas
    }

    /// Sets the timeline and scene states.
    /// Call this when timeline changes (scene add/remove/reorder).
    public func setTimeline(
        _ timeline: CanonicalTimeline,
        sceneStates: [UUID: SceneState]
    ) {
        let previousSceneIds = Set(self.timeline?.sceneItems.map(\.id) ?? [])
        let newSceneIds = Set(timeline.sceneItems.map(\.id))

        self.timeline = timeline
        self.sceneStates = sceneStates

        // Rebuild transition math
        self.transitionMath = TimelineTransitionMath(
            sceneItems: timeline.sceneItems,
            boundaryTransitions: timeline.boundaryTransitions,
            fps: fps
        )

        // Evict orphaned runtimes (scenes that were removed)
        let orphanedIds = previousSceneIds.subtracting(newSceneIds)
        for orphanId in orphanedIds {
            if let runtime = instanceRuntimes.removeValue(forKey: orphanId) {
                runtime.pause()
                #if DEBUG
                print("[TimelineCompositionEngine] Evicted orphaned runtime: \(orphanId)")
                #endif
            }
        }
    }

    /// Updates scene state for a specific instance.
    /// If runtime is already loaded, state is also re-applied to the runtime.
    public func updateSceneState(_ state: SceneState, for instanceId: UUID) async {
        sceneStates[instanceId] = state

        // If runtime already loaded, re-apply state
        if let runtime = instanceRuntimes[instanceId] {
            await runtime.reloadState(state)
            #if DEBUG
            print("[TimelineCompositionEngine] Re-applied state to loaded runtime: \(instanceId)")
            #endif
        }
    }

    /// Increments generation counter to invalidate stale async results.
    /// Call this when playhead changes to ensure fast scrub works correctly.
    public func invalidateScrub() {
        scrubGeneration &+= 1
    }

    /// Returns current scrub generation for validation.
    public var currentScrubGeneration: UInt64 {
        scrubGeneration
    }

    // MARK: - Frame Resolution

    /// Compressed duration in frames.
    public var compressedDurationFrames: Int {
        transitionMath?.compressedDurationFrames ?? 0
    }

    /// Compressed duration in microseconds.
    public var compressedDurationUs: TimeUs {
        TimeUs(compressedDurationFrames) * 1_000_000 / TimeUs(fps)
    }

    /// TT-02: Resolves render context for a compressed frame.
    /// - Parameters:
    ///   - compressedFrame: Frame index in compressed timeline.
    ///   - generation: Optional generation token to validate against (for scrub cancellation).
    ///   - policy: Resolution policy (.presentation or .export).
    /// - Returns: Resolution result (resolved, hold, staleGeneration, or failed).
    public func resolveFrame(
        _ compressedFrame: Int,
        generation: UInt64? = nil,
        policy: TimelineResolvePolicy = .presentation
    ) async -> TimelineFrameResolution {
        guard let math = transitionMath else {
            return .failed(.invalidTimeline)
        }

        // Check generation BEFORE any work
        if let gen = generation, gen != scrubGeneration {
            return .staleGeneration
        }

        // TT-03: Budget refresh for presentation policy only
        // Export policy skips budget refresh and eviction
        if policy == .presentation {
            refreshBudgetWindow(compressedFrame: compressedFrame, math: math)
        }

        // Get render mode (nil for empty timeline)
        guard let mode = math.renderMode(for: compressedFrame) else {
            return .failed(.invalidTimeline)
        }

        switch mode {
        case .single(let sceneIndex, let localFrame):
            return await resolveSingleFrame(
                math: math,
                sceneIndex: sceneIndex,
                localFrame: localFrame,
                generation: generation,
                policy: policy
            )

        case .transition(let aIndex, let frameA, let bIndex, let frameB, let transition, let progress):
            return await resolveTransitionFrame(
                math: math,
                aIndex: aIndex, frameA: frameA,
                bIndex: bIndex, frameB: frameB,
                transition: transition,
                progress: progress,
                generation: generation,
                policy: policy
            )
        }
    }

    /// TT-02: Resolves single scene frame with explicit state branching.
    private func resolveSingleFrame(
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
        if let gen = generation, gen != scrubGeneration {
            return .staleGeneration
        }

        switch policy {
        case .presentation:
            // Explicit state branching
            switch runtime.readinessState {
            case .created:
                runtime.startPreparingForPresentation(at: localFrame)
                // Check generation before returning hold
                if let gen = generation, gen != scrubGeneration {
                    return .staleGeneration
                }
                return .hold

            case .preparing:
                if let gen = generation, gen != scrubGeneration {
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

            // Check generation after async wait
            if let gen = generation, gen != scrubGeneration {
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
                // Contract violation
                return .failed(.dependencyTimedOut(instanceId))
            }
        }
    }

    /// TT-02: Resolves transition frame - both scenes must be ready.
    private func resolveTransitionFrame(
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
        if let gen = generation, gen != scrubGeneration {
            return .staleGeneration
        }

        switch policy {
        case .presentation:
            // Check both states, collect results
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

            // Check if both ready (re-check state after potential startPreparing)
            guard case .ready = runtimeA.readinessState,
                  case .ready = runtimeB.readinessState else {
                // At least one is created/preparing
                if let gen = generation, gen != scrubGeneration {
                    return .staleGeneration
                }
                return .hold
            }

            // Both ready
            runtimeDiagnosticsSink?.receive(.transitionPartnerReady(instanceIdA: instanceIdA, instanceIdB: instanceIdB))
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

            // Check generation after async wait
            if let gen = generation, gen != scrubGeneration {
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

    /// TT-02: Gets or creates a runtime for the given instance ID.
    /// Does NOT wait for readiness - caller controls readiness via policy.
    private func getOrCreateRuntime(for instanceId: UUID) async -> SceneInstanceRuntime? {
        // Already loaded?
        if let existing = instanceRuntimes[instanceId] {
            return existing
        }

        // Need to load - find timeline item by instance ID, then get payload
        guard let timeline = timeline,
              let item = timeline.sceneItems.first(where: { $0.id == instanceId }),
              let timelinePayload = timeline.payloads[item.payloadId] else {
            #if DEBUG
            print("[TimelineCompositionEngine] Failed to find item or payload for instanceId: \(instanceId)")
            #endif
            return nil
        }

        // Extract ScenePayload via pattern match (TimelinePayload is an enum)
        guard case .scene(let scenePayload) = timelinePayload else {
            #if DEBUG
            print("[TimelineCompositionEngine] Payload is not a scene for instanceId: \(instanceId)")
            #endif
            return nil
        }

        let sceneTypeId = scenePayload.sceneTypeId

        // Get resources from cache, or preload if not cached
        let resources: SceneTypeResourcesCache.Resources
        if let cached = resourcesCache.resources(for: sceneTypeId) {
            resources = cached
        } else {
            // Preload fallback - load resources if not cached
            runtimeDiagnosticsSink?.receive(.sceneTypePreloadStarted(sceneTypeId: sceneTypeId))
            do {
                resources = try await resourcesCache.preload(sceneTypeId: sceneTypeId)
                runtimeDiagnosticsSink?.receive(.sceneTypePreloadCompleted(sceneTypeId: sceneTypeId))
            } catch {
                runtimeDiagnosticsSink?.receive(.sceneTypePreloadFailed(sceneTypeId: sceneTypeId, error: error.localizedDescription))
                #if DEBUG
                print("[TimelineCompositionEngine] Failed to preload resources for \(sceneTypeId): \(error.localizedDescription)")
                #endif
                return nil
            }
        }

        // TT-02: Create instance runtime via factory
        let runtime = runtimeFactory(instanceId, resources, device, commandQueue)

        // Propagate diagnostics sink to runtime
        runtime.runtimeDiagnosticsSink = runtimeDiagnosticsSink

        // Wire video selection persistence callback
        runtime.userMediaService.onVideoSelectionChanged = { [weak self] blockId, persisted in
            guard let self else { return }
            var state = self.sceneStates[instanceId] ?? .empty
            var selections = state.videoSelections ?? [:]
            selections[blockId] = persisted
            state.videoSelections = selections
            self.sceneStates[instanceId] = state
        }

        // Apply state if available
        if let state = sceneStates[instanceId] {
            await runtime.applyState(state)
        }

        // TT-02: NO readiness wait here - caller controls via policy

        // Cache it
        instanceRuntimes[instanceId] = runtime

        return runtime
    }

    // MARK: - TT-03 Budget Enforcement

    /// Evicts non-resident runtimes based on budget coordinator state.
    /// Only evicts `.evictable` tier runtimes; pinned and warm remain resident.
    /// - Parameter math: Timeline transition math for scene items.
    private func evictNonResidentRuntimes(math: TimelineTransitionMath) {
        let loadedIds = Set(instanceRuntimes.keys)
        let toEvict = budgetCoordinator.instancesToEvictOrdered(
            from: loadedIds,
            sceneItems: math.sceneItems
        )

        for instanceId in toEvict {
            if let runtime = instanceRuntimes.removeValue(forKey: instanceId) {
                runtime.pause()
                runtimeDiagnosticsSink?.receive(.evictionDecision(instanceId: instanceId, tier: "evictable"))
                #if DEBUG
                print("[TimelineCompositionEngine] TT-03: Evicted non-resident runtime: \(instanceId)")
                #endif
            }
        }
        // Note: sceneStates NOT touched - preserved for recreate
    }

    /// Refreshes budget window: updates coordinator and evicts non-resident runtimes.
    /// Called for `.presentation` policy only.
    /// - Parameters:
    ///   - compressedFrame: Current compressed frame.
    ///   - math: Timeline transition math.
    private func refreshBudgetWindow(compressedFrame: Int, math: TimelineTransitionMath) {
        budgetCoordinator.update(transitionMath: math, compressedFrame: compressedFrame)
        evictNonResidentRuntimes(math: math)
    }

    /// Returns boundary-aligned local frames for warm scenes around the current render mode.
    /// Previous warm scenes prepare at their last frame, next warm scenes at frame 0.
    private func warmPresentationTargets(
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

    /// Returns local frames for every scene eligible for decoder allocation.
    /// Includes pinned scenes from the current render mode and warm scenes at their boundary frames.
    private func decoderAllocationLocalFrames(
        math: TimelineTransitionMath,
        mode: TimelineTransitionMath.RenderMode
    ) -> [UUID: Int] {
        var localFrames = warmPresentationTargets(math: math, mode: mode)

        switch mode {
        case .single(let sceneIndex, let localFrame):
            guard sceneIndex < math.sceneItems.count else { return localFrames }
            localFrames[math.sceneItems[sceneIndex].id] = localFrame

        case .transition(let aIndex, let frameA, let bIndex, let frameB, _, _):
            guard aIndex < math.sceneItems.count,
                  bIndex < math.sceneItems.count else { return localFrames }
            localFrames[math.sceneItems[aIndex].id] = frameA
            localFrames[math.sceneItems[bIndex].id] = frameB
        }

        return localFrames
    }

    /// Computes playback budget grants for all decoder-allocation participants.
    /// Returns mapping of instanceId -> granted blockIds.
    /// - Parameters:
    ///   - math: Timeline transition math.
    ///   - mode: Current render mode (single or transition).
    /// - Returns: Dictionary mapping instance ID to granted block IDs.
    private func playbackBudgetGrants(
        math: TimelineTransitionMath,
        mode: TimelineTransitionMath.RenderMode
    ) -> [UUID: Set<String>] {
        let localFramesByInstanceId = decoderAllocationLocalFrames(math: math, mode: mode)
        let allocationInstanceIds = localFramesByInstanceId.keys.filter {
            budgetCoordinator.shouldHaveActiveDecoders(for: $0)
        }

        guard !allocationInstanceIds.isEmpty else {
            return [:]
        }

        // 1. Get scene rank for prioritization
        let sceneRank: [UUID: Int] = {
            let prioritized = budgetCoordinator.prioritizedInstances(
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
            guard let runtime = instanceRuntimes[instanceId] else { continue }
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

        // 3. Sort globally: isVisible desc → area desc → zIndex desc → sceneRank asc → instanceId asc → blockId asc
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

        // 4. Take prefix(maxActiveDecoders)
        let granted = flatCandidates.prefix(budgetCoordinator.maxActiveDecoders)

        // 5. Group back into [UUID: Set<String>]
        var result: [UUID: Set<String>] = [:]

        // Initialize all eligible instances with empty sets
        for instanceId in allocationInstanceIds {
            result[instanceId] = []
        }

        // Fill with granted blocks
        for candidate in granted {
            result[candidate.instanceId, default: []].insert(candidate.blockId)
        }

        return result
    }

    // MARK: - Playback Video Sync

    /// TT-03 Completion: Applies playback budget to all resident runtimes.
    ///
    /// This is the core fix for the active->warm decoder leak:
    /// - Active runtimes receive budget-aware playback calls
    /// - Non-active resident runtimes (warm) receive deactivation calls
    ///
    /// - Parameters:
    ///   - mode: Current render mode (single or transition)
    ///   - math: Timeline math for scene items lookup
    ///   - grants: Pre-computed budget grants per instance
    ///   - isStart: true for startPlayback, false for syncPlaybackTick
    private func applyPlaybackBudget(
        mode: TimelineTransitionMath.RenderMode,
        math: TimelineTransitionMath,
        grants: [UUID: Set<String>],
        isStart: Bool
    ) {
        // Step 1: Compute active instance IDs from current render mode
        var activeInstanceIds: Set<UUID> = []
        let localFramesByInstanceId = decoderAllocationLocalFrames(math: math, mode: mode)
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
        let residentIds = Set(instanceRuntimes.keys).intersection(
            budgetCoordinator.pinnedInstanceIds.union(budgetCoordinator.warmInstanceIds)
        )

        // Step 3: Update active scenes and warm scenes that actually received spare grants.
        var syncedInstanceIds: Set<UUID> = []
        for instanceId in residentIds {
            guard let localFrame = localFramesByInstanceId[instanceId] else { continue }
            let grantedBlockIds = grants[instanceId] ?? []
            let shouldSync = activeInstanceIds.contains(instanceId) || !grantedBlockIds.isEmpty
            guard shouldSync else { continue }

            if isStart {
                instanceRuntimes[instanceId]?.startPlayback(at: localFrame, grantedBlockIds: grantedBlockIds)
            } else {
                instanceRuntimes[instanceId]?.syncPlaybackTick(localFrame, grantedBlockIds: grantedBlockIds)
            }
            syncedInstanceIds.insert(instanceId)
        }

        // Step 4: Resident runtimes without active grants keep last texture but release decoder slots.
        for instanceId in residentIds
        where !activeInstanceIds.contains(instanceId) && !syncedInstanceIds.contains(instanceId) {
            instanceRuntimes[instanceId]?.deactivatePlaybackPreservingTextures()
        }
    }

    /// Syncs video frames for playback tick (called from displayLinkFired).
    /// Uses playback-gated video update (30Hz gate) instead of scrub-mode seeking.
    /// TT-03: Uses budget-aware sync with engine-owned grants.
    /// TT-03 Completion: Deactivates warm runtimes that were previously active.
    /// - Parameter compressedFrame: Current compressed frame index.
    public func syncPlaybackTick(_ compressedFrame: Int) {
        guard let math = transitionMath,
              let mode = math.renderMode(for: compressedFrame) else { return }

        // TT-03: Update budget and evict non-resident runtimes
        budgetCoordinator.update(transitionMath: math, compressedFrame: compressedFrame)
        evictNonResidentRuntimes(math: math)

        // TT-03: Compute budget grants
        let grants = playbackBudgetGrants(math: math, mode: mode)

        // TT-03 Completion: Apply budget to all resident runtimes
        applyPlaybackBudget(mode: mode, math: math, grants: grants, isStart: false)
    }

    /// Starts playback at the given compressed frame.
    /// Determines active render mode and starts playback for active runtimes.
    /// TT-03: Uses budget-aware start with engine-owned grants.
    /// TT-03 Completion: Deactivates warm runtimes that were previously active.
    /// - Parameter compressedFrame: Current compressed frame index.
    public func startPlayback(at compressedFrame: Int) {
        guard let math = transitionMath,
              let mode = math.renderMode(for: compressedFrame) else { return }

        // TT-03: Update budget and evict non-resident runtimes
        budgetCoordinator.update(transitionMath: math, compressedFrame: compressedFrame)
        evictNonResidentRuntimes(math: math)

        // TT-03: Compute budget grants
        let grants = playbackBudgetGrants(math: math, mode: mode)

        // TT-03 Completion: Apply budget to all resident runtimes
        applyPlaybackBudget(mode: mode, math: math, grants: grants, isStart: true)
    }

    /// PR-G: Stops playback for all loaded runtimes.
    public func stopPlayback() {
        for runtime in instanceRuntimes.values {
            runtime.pause()
        }
    }

    // MARK: - Scene Query

    /// Returns scene instance ID at given compressed frame.
    public func sceneInstanceId(at compressedFrame: Int) -> UUID? {
        guard let math = transitionMath,
              let mapping = math.frameMapping(for: compressedFrame) else { return nil }
        guard mapping.sceneIndex < math.sceneItems.count else { return nil }
        return math.sceneItems[mapping.sceneIndex].id
    }

    /// Returns whether the given compressed frame is in a transition.
    public func isInTransition(at compressedFrame: Int) -> Bool {
        transitionMath?.transitionWindow(at: compressedFrame) != nil
    }

    /// Returns transition window at given compressed frame, if any.
    public func transitionWindow(at compressedFrame: Int) -> TimelineTransitionMath.TransitionWindow? {
        transitionMath?.transitionWindow(at: compressedFrame)
    }

    // MARK: - Resource Management

    /// TT-02: Prepares scene resources for playback.
    /// PHASE 1: Awaits exact readiness for active mode (single or both transition scenes).
    /// PHASE 2: Awaits warm-scene readiness at boundary-aligned frames.
    public func prepareForPlayback(startingAt compressedFrame: Int = 0) async {
        guard let math = transitionMath else { return }

        budgetCoordinator.update(transitionMath: math, compressedFrame: compressedFrame)

        guard let renderMode = math.renderMode(for: compressedFrame) else { return }

        // PHASE 1: Await exact readiness for active mode
        switch renderMode {
        case .single(let sceneIndex, let localFrame):
            guard sceneIndex < math.sceneItems.count else { return }
            let instanceId = math.sceneItems[sceneIndex].id
            if let runtime = await getOrCreateRuntime(for: instanceId) {
                _ = await runtime.waitUntilReadyForPresentation(at: localFrame)
            }

        case .transition(let aIndex, let frameA, let bIndex, let frameB, _, _):
            guard aIndex < math.sceneItems.count,
                  bIndex < math.sceneItems.count else { return }
            let instanceIdA = math.sceneItems[aIndex].id
            let instanceIdB = math.sceneItems[bIndex].id

            // Create both runtimes in parallel
            async let runtimeATask = getOrCreateRuntime(for: instanceIdA)
            async let runtimeBTask = getOrCreateRuntime(for: instanceIdB)

            let runtimeA = await runtimeATask
            let runtimeB = await runtimeBTask

            // Wait for both readiness in parallel
            async let stateATask = runtimeA?.waitUntilReadyForPresentation(at: frameA)
            async let stateBTask = runtimeB?.waitUntilReadyForPresentation(at: frameB)

            _ = await stateATask
            _ = await stateBTask
        }

        // PHASE 2: Warm scenes must be ready before they can satisfy the first-correct-frame contract.
        let warmTargets = warmPresentationTargets(math: math, mode: renderMode)
        let orderedWarmIds = budgetCoordinator.prioritizedInstances(
            from: budgetCoordinator.warmInstanceIds,
            sceneItems: math.sceneItems
        )
        for instanceId in orderedWarmIds {
            guard let targetFrame = warmTargets[instanceId] else { continue }
            if let runtime = await getOrCreateRuntime(for: instanceId) {
                _ = await runtime.waitUntilReadyForPresentation(at: targetFrame)
            }
        }

        // TT-03: PHASE 3: Evict non-resident runtimes
        evictNonResidentRuntimes(math: math)
    }

    /// Releases all scene resources.
    public func releaseResources() {
        for runtime in instanceRuntimes.values {
            runtime.pause()
        }
        instanceRuntimes.removeAll()
    }

    /// Releases scene runtimes for export — frees GPU memory from preview.
    ///
    /// Preserves `transitionMath` (needed for buildExportSession) and
    /// `sceneStates` (needed for mediaAssignments).
    public func releaseForExport() {
        for runtime in instanceRuntimes.values {
            runtime.pause()
        }
        instanceRuntimes.removeAll()
    }

    /// Returns runtime for given instance ID, if loaded.
    public func runtime(for instanceId: UUID) -> SceneInstanceRuntime? {
        instanceRuntimes[instanceId]
    }

    /// Adds resources to cache manually (for preloading).
    public func addResourcesToCache(_ resources: SceneTypeResourcesCache.Resources) {
        resourcesCache.addToCache(resources)
    }

    /// Returns canvas size from template (source of truth).
    /// Does not depend on loaded runtimes.
    public var canvasSize: SizeD {
        guard let canvas = templateCanvas else {
            return .zero
        }
        return SizeD(width: Double(canvas.width), height: Double(canvas.height))
    }

    // MARK: - Test-Only Budget Probe

    /// Test-only snapshot of playback budget state.
    internal struct PlaybackBudgetSnapshot {
        let mode: TimelineTransitionMath.RenderMode
        let pinnedInstanceIds: Set<UUID>
        let warmInstanceIds: Set<UUID>
        let grantsByInstance: [UUID: Set<String>]
        let activeInstanceIdsUsedForGrantComputation: [UUID]
    }

    /// Test-only: returns a snapshot of the budget state at the given compressed frame
    /// without mutating any runtime state (no side effects on runtimes).
    /// - Parameter compressedFrame: Compressed timeline frame.
    /// - Returns: Budget snapshot, or nil if no timeline/math.
    internal func debugPlaybackBudgetSnapshot(at compressedFrame: Int) -> PlaybackBudgetSnapshot? {
        guard let math = transitionMath,
              let renderMode = math.renderMode(for: compressedFrame) else { return nil }

        // Update budget coordinator (determines pinned/warm sets)
        budgetCoordinator.update(transitionMath: math, compressedFrame: compressedFrame)

        // Compute grants using existing method (read-only w.r.t. runtimes)
        let grants = playbackBudgetGrants(math: math, mode: renderMode)

        let activeIds = budgetCoordinator.prioritizedInstances(
            from: Set(
                decoderAllocationLocalFrames(math: math, mode: renderMode).keys.filter {
                    budgetCoordinator.shouldHaveActiveDecoders(for: $0)
                }
            ),
            sceneItems: math.sceneItems
        )

        return PlaybackBudgetSnapshot(
            mode: renderMode,
            pinnedInstanceIds: budgetCoordinator.pinnedInstanceIds,
            warmInstanceIds: budgetCoordinator.warmInstanceIds,
            grantsByInstance: grants,
            activeInstanceIdsUsedForGrantComputation: activeIds
        )
    }

    // MARK: - Export Support

    /// Data needed for audio export of a single scene.
    public struct SceneAudioExportData {
        /// Index of this scene in timeline (0-based).
        public let sceneIndex: Int
        /// Compiled runtime for audio timing.
        public let runtime: SceneRuntime
        /// Video selections snapshot (blockId -> VideoSelection).
        public let videoSelections: [String: VideoSelection]
    }

    /// Compatibility helper — timeline export after TT-05 uses session.audioSceneData instead.
    // MARK: - TT-05 Export Session

    /// Error when building an immutable export session.
    internal enum TimelineExportSessionBuildError: Error, Sendable, Equatable {
        case noTimeline
        case missingRuntime(UUID)
    }

    /// Immutable snapshot of a single scene for export.
    ///
    /// Contains lightweight media descriptors instead of live GPU textures.
    /// The `TimelineExportResidencyController` creates GPU resources on demand.
    internal struct TimelineExportSceneSnapshot {
        let sceneIndex: Int
        let instanceId: UUID
        let runtime: SceneRuntime
        let renderState: SceneRenderStateSnapshot
        let videoSelections: [String: VideoSelection]
        let mediaSnapshot: ExportMediaSnapshot
        let assetIndex: AssetIndexIR
        let resolver: CompositeAssetResolver
        let bindingAssetIds: Set<String>
        let pathRegistry: PathRegistry
        let assetSizes: [String: AssetSize]
        let sceneCanvasSize: SizeD
    }

    /// Immutable export session built once before the export loop.
    internal struct TimelineExportSession {
        let transitionMath: TimelineTransitionMath
        let canvasSize: SizeD
        let fps: Int
        let scenesByInstanceId: [UUID: TimelineExportSceneSnapshot]
        let audioSceneData: [SceneAudioExportData]
    }

    /// TT-05: Builds an immutable export session from current engine state.
    /// Must be called on MainActor. Does NOT call resolveFrame, prepareForPlayback,
    /// or touch TT-03 budget/eviction path.
    internal func buildExportSession() async throws -> TimelineExportSession {
        guard let math = transitionMath, templateCanvas != nil,
              let timeline = timeline else {
            throw TimelineExportSessionBuildError.noTimeline
        }

        var scenesByInstanceId: [UUID: TimelineExportSceneSnapshot] = [:]
        var audioSceneData: [SceneAudioExportData] = []

        for (index, item) in math.sceneItems.enumerated() {
            let instanceId = item.id

            // 1. Resolve sceneTypeId from timeline payload (no runtime needed)
            guard let tlItem = timeline.sceneItems.first(where: { $0.id == instanceId }),
                  let payload = timeline.payloads[tlItem.payloadId],
                  case .scene(let scenePayload) = payload else {
                throw TimelineExportSessionBuildError.missingRuntime(instanceId)
            }
            let sceneTypeId = scenePayload.sceneTypeId

            // 2. Resources: full cache if warm, metadata-only preload if cold.
            //    NEVER calls full preload() or getOrCreateRuntime() for cold scenes.
            let resources: SceneTypeResourcesCache.Resources
            if let cached = resourcesCache.resources(for: sceneTypeId) {
                resources = cached
            } else {
                resources = try await resourcesCache.preloadMetadata(sceneTypeId: sceneTypeId)
            }

            // 3. Video selections: warm runtime > persisted state > empty
            let state = sceneStates[instanceId] ?? .empty
            let videoSelections: [String: VideoSelection]
            if let warmRuntime = instanceRuntimes[instanceId] {
                // Warm runtime has in-flight edits — authoritative source
                videoSelections = warmRuntime.userMediaService.exportVideoSelectionsSnapshot()
            } else {
                // Cold scene: assemble from PersistedVideoSelection + MediaRef URLs
                videoSelections = try await Self.assembleVideoSelections(from: state)
            }

            // 4. Render state from sceneStates (no runtime needed)
            let renderState = SceneRenderStateSnapshot(
                userTransforms: state.userTransforms,
                variantOverrides: state.variantOverrides,
                userMediaPresent: state.userMediaPresent ?? [:],
                layerToggleState: state.layerToggles
            )

            // 5. Build snapshot from cache resources
            let compiled = resources.compiled
            let mediaAssignments = state.mediaAssignments ?? [:]
            let mediaSnapshot = try ExportMediaSnapshot.build(
                compiledScene: compiled,
                mediaAssignments: mediaAssignments,
                projectStore: ProjectStore.shared,
                videoSelections: videoSelections,
                runtime: compiled.runtime
            )

            let snapshot = TimelineExportSceneSnapshot(
                sceneIndex: index,
                instanceId: instanceId,
                runtime: compiled.runtime,
                renderState: renderState,
                videoSelections: videoSelections,
                mediaSnapshot: mediaSnapshot,
                assetIndex: compiled.mergedAssetIndex,
                resolver: resources.resolver,
                bindingAssetIds: compiled.bindingAssetIds,
                pathRegistry: resources.pathRegistry,
                assetSizes: resources.assetSizes,
                sceneCanvasSize: resources.canvasSize
            )
            scenesByInstanceId[instanceId] = snapshot

            audioSceneData.append(SceneAudioExportData(
                sceneIndex: index,
                runtime: compiled.runtime,
                videoSelections: videoSelections
            ))
        }

        return TimelineExportSession(
            transitionMath: math,
            canvasSize: canvasSize,
            fps: fps,
            scenesByInstanceId: scenesByInstanceId,
            audioSceneData: audioSceneData
        )
    }

    /// Assembles runtime VideoSelections from persisted PersistedVideoSelection + MediaRef URLs.
    /// Handles legacy drafts (videoSelections == nil) by synthesizing defaults from file duration.
    /// Throws typed error for assigned-but-missing video files (consistent with photo contract).
    /// Duration probing runs off MainActor to avoid main-thread file I/O.
    private static func assembleVideoSelections(from state: SceneState) async throws -> [String: VideoSelection] {
        let mediaAssignments = state.mediaAssignments ?? [:]
        let persisted = state.videoSelections ?? [:]

        // Collect all video blockIds from mediaAssignments
        var videoEntries: [(blockId: String, mediaRef: MediaRef)] = []
        for (blockId, mediaRef) in mediaAssignments where mediaRef.mediaKind == .video {
            videoEntries.append((blockId, mediaRef))
        }
        guard !videoEntries.isEmpty else { return [:] }

        // Fast path: all video entries have persisted selections (no duration probing needed)
        var needsLegacyProbing = false
        var fastResult: [String: VideoSelection] = [:]
        for (blockId, mediaRef) in videoEntries {
            guard let url = try? ProjectStore.shared.absoluteURL(for: mediaRef) else {
                throw ExportMediaError.missingPersistedVideo(blockId: blockId)
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ExportMediaError.missingPersistedVideo(blockId: blockId)
            }

            if let pvs = persisted[blockId] {
                fastResult[blockId] = pvs.toVideoSelection(url: url)
            } else {
                needsLegacyProbing = true
                break
            }
        }

        // If all entries resolved from persisted state, return without async work
        guard needsLegacyProbing else { return fastResult }

        // Slow path: legacy draft needs AVURLAsset.duration probing off MainActor
        let resolved = try await Task.detached(priority: .userInitiated) {
            var result: [String: VideoSelection] = [:]
            for (blockId, mediaRef) in videoEntries {
                guard let url = try? ProjectStore.shared.absoluteURL(for: mediaRef) else {
                    throw ExportMediaError.missingPersistedVideo(blockId: blockId)
                }
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw ExportMediaError.missingPersistedVideo(blockId: blockId)
                }

                if let pvs = persisted[blockId] {
                    result[blockId] = pvs.toVideoSelection(url: url)
                } else {
                    // Legacy draft: synthesize default from file duration
                    let asset = AVURLAsset(url: url)
                    let durationSeconds = CMTimeGetSeconds(asset.duration)
                    guard durationSeconds > 0, durationSeconds.isFinite else {
                        throw ExportMediaError.missingPersistedVideo(blockId: blockId)
                    }
                    result[blockId] = VideoSelection(url: url, duration: durationSeconds)
                }
            }
            return result
        }.value

        return resolved
    }
}
