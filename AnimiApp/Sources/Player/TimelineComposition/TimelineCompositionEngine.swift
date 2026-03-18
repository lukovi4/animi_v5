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
        runtimeFactory: @escaping (UUID, SceneTypeResourcesCache.Resources, MTLDevice, MTLCommandQueue) -> SceneInstanceRuntime
    ) {
        self.device = device
        self.commandQueue = commandQueue
        self.fps = fps
        self.budgetCoordinator = GlobalVideoBudgetCoordinator(maxActiveDecoders: maxActiveDecoders)
        self.resourcesCache = resourcesCache
        self.runtimeFactory = runtimeFactory
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
            do {
                resources = try await resourcesCache.preload(sceneTypeId: sceneTypeId)
            } catch {
                #if DEBUG
                print("[TimelineCompositionEngine] Failed to preload resources for \(sceneTypeId): \(error.localizedDescription)")
                #endif
                return nil
            }
        }

        // TT-02: Create instance runtime via factory
        let runtime = runtimeFactory(instanceId, resources, device, commandQueue)

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

    /// Computes playback budget grants for active runtime(s).
    /// Returns mapping of instanceId -> granted blockIds.
    /// - Parameters:
    ///   - compressedFrame: Current compressed frame.
    ///   - math: Timeline transition math.
    ///   - mode: Current render mode (single or transition).
    /// - Returns: Dictionary mapping instance ID to granted block IDs.
    private func playbackBudgetGrants(
        compressedFrame: Int,
        math: TimelineTransitionMath,
        mode: TimelineTransitionMath.RenderMode
    ) -> [UUID: Set<String>] {
        // 1. Determine active instance IDs
        var activeInstanceIds: [(id: UUID, localFrame: Int)] = []

        switch mode {
        case .single(let sceneIndex, let localFrame):
            guard sceneIndex < math.sceneItems.count else { return [:] }
            let instanceId = math.sceneItems[sceneIndex].id
            if budgetCoordinator.shouldHaveActiveDecoders(for: instanceId) {
                activeInstanceIds.append((instanceId, localFrame))
            }

        case .transition(let aIndex, let frameA, let bIndex, let frameB, _, _):
            guard aIndex < math.sceneItems.count,
                  bIndex < math.sceneItems.count else { return [:] }
            let idA = math.sceneItems[aIndex].id
            let idB = math.sceneItems[bIndex].id

            if budgetCoordinator.shouldHaveActiveDecoders(for: idA) {
                activeInstanceIds.append((idA, frameA))
            }
            if budgetCoordinator.shouldHaveActiveDecoders(for: idB) {
                activeInstanceIds.append((idB, frameB))
            }
        }

        // 2. If no active instances, return empty grants for all
        guard !activeInstanceIds.isEmpty else {
            return [:]
        }

        // 3. Get scene rank for prioritization
        let sceneRank: [UUID: Int] = {
            let prioritized = budgetCoordinator.prioritizedInstances(
                from: Set(activeInstanceIds.map(\.id)),
                sceneItems: math.sceneItems
            )
            var rank: [UUID: Int] = [:]
            for (idx, id) in prioritized.enumerated() {
                rank[id] = idx
            }
            return rank
        }()

        // 4. Collect candidates from all active runtimes
        struct FlatCandidate {
            let instanceId: UUID
            let blockId: String
            let priority: BlockPriorityInfo
            let sceneRank: Int
        }

        var flatCandidates: [FlatCandidate] = []

        for (instanceId, localFrame) in activeInstanceIds {
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

        // 5. Sort globally: isVisible desc → area desc → zIndex desc → sceneRank asc → instanceId asc → blockId asc
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

        // 6. Take prefix(maxActiveDecoders)
        let granted = flatCandidates.prefix(budgetCoordinator.maxActiveDecoders)

        // 7. Group back into [UUID: Set<String>]
        var result: [UUID: Set<String>] = [:]

        // Initialize all active instances with empty sets
        for (instanceId, _) in activeInstanceIds {
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

        // Step 3: For active runtimes - apply budget-aware playback
        switch mode {
        case .single(let sceneIndex, let localFrame):
            let instanceId = math.sceneItems[sceneIndex].id
            if isStart {
                instanceRuntimes[instanceId]?.startPlayback(at: localFrame, grantedBlockIds: grants[instanceId] ?? [])
            } else {
                instanceRuntimes[instanceId]?.syncPlaybackTick(localFrame, grantedBlockIds: grants[instanceId] ?? [])
            }

        case .transition(let aIndex, let frameA, let bIndex, let frameB, _, _):
            let instanceIdA = math.sceneItems[aIndex].id
            let instanceIdB = math.sceneItems[bIndex].id
            if isStart {
                instanceRuntimes[instanceIdA]?.startPlayback(at: frameA, grantedBlockIds: grants[instanceIdA] ?? [])
                instanceRuntimes[instanceIdB]?.startPlayback(at: frameB, grantedBlockIds: grants[instanceIdB] ?? [])
            } else {
                instanceRuntimes[instanceIdA]?.syncPlaybackTick(frameA, grantedBlockIds: grants[instanceIdA] ?? [])
                instanceRuntimes[instanceIdB]?.syncPlaybackTick(frameB, grantedBlockIds: grants[instanceIdB] ?? [])
            }
        }

        // Step 4: For resident non-active runtimes - deactivate preserving textures
        // This is the critical fix: warm runtimes that were previously active
        // must be soft-stopped to release decoder slots while keeping textures
        for instanceId in residentIds where !activeInstanceIds.contains(instanceId) {
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
        let grants = playbackBudgetGrants(compressedFrame: compressedFrame, math: math, mode: mode)

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
        let grants = playbackBudgetGrants(compressedFrame: compressedFrame, math: math, mode: mode)

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
    /// PHASE 2: Opportunistic create for warm scenes (no readiness wait).
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

        // PHASE 2: Opportunistic create for warm scenes (no await readiness)
        // Failures not surfaced here - will come through resolveFrame
        for instanceId in budgetCoordinator.warmInstanceIds {
            _ = await getOrCreateRuntime(for: instanceId)
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
    public func prepareAudioExportData() async -> [SceneAudioExportData] {
        guard let math = transitionMath else { return [] }

        var result: [SceneAudioExportData] = []

        for (index, item) in math.sceneItems.enumerated() {
            // TT-02: Use getOrCreateRuntime (readiness managed separately)
            guard let instanceRuntime = await getOrCreateRuntime(for: item.id) else {
                #if DEBUG
                print("[TimelineCompositionEngine] WARNING: No runtime for scene at index \(index)")
                #endif
                continue
            }

            let data = SceneAudioExportData(
                sceneIndex: index,
                runtime: instanceRuntime.resources.compiled.runtime,
                videoSelections: instanceRuntime.userMediaService.exportVideoSelectionsSnapshot()
            )
            result.append(data)
        }

        return result
    }

    // MARK: - TT-05 Export Session

    /// Error when building an immutable export session.
    internal enum TimelineExportSessionBuildError: Error, Sendable, Equatable {
        case noTimeline
        case missingRuntime(UUID)
    }

    /// Immutable snapshot of a single scene for export.
    internal struct TimelineExportSceneSnapshot {
        let sceneIndex: Int
        let instanceId: UUID
        let runtime: SceneRuntime
        let renderState: SceneRenderStateSnapshot
        let videoSelections: [String: VideoSelection]
        let textureProvider: ExportTextureProvider
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
        guard let math = transitionMath, templateCanvas != nil else {
            throw TimelineExportSessionBuildError.noTimeline
        }

        var scenesByInstanceId: [UUID: TimelineExportSceneSnapshot] = [:]
        var audioSceneData: [SceneAudioExportData] = []

        for (index, item) in math.sceneItems.enumerated() {
            let instanceId = item.id

            guard let instanceRuntime = await getOrCreateRuntime(for: instanceId) else {
                throw TimelineExportSessionBuildError.missingRuntime(instanceId)
            }

            // Build render state snapshot from sceneStates
            let state = sceneStates[instanceId] ?? .empty
            let renderState = SceneRenderStateSnapshot(
                userTransforms: state.userTransforms,
                variantOverrides: state.variantOverrides,
                userMediaPresent: state.userMediaPresent ?? [:],
                layerToggleState: state.layerToggles
            )

            // Freeze video selections
            let videoSelections = instanceRuntime.userMediaService.exportVideoSelectionsSnapshot()

            // Create export-safe texture provider
            let compiled = instanceRuntime.resources.compiled
            let exportTP = ExportTextureProvider(
                device: device,
                assetIndex: compiled.mergedAssetIndex,
                resolver: instanceRuntime.resources.resolver,
                bindingAssetIds: compiled.bindingAssetIds
            )
            exportTP.preloadAll(commandQueue: commandQueue)

            // Inject current binding textures from live provider
            exportTP.injectTextures(
                from: instanceRuntime.layeredTextureProvider,
                for: compiled.bindingAssetIds
            )

            let snapshot = TimelineExportSceneSnapshot(
                sceneIndex: index,
                instanceId: instanceId,
                runtime: compiled.runtime,
                renderState: renderState,
                videoSelections: videoSelections,
                textureProvider: exportTP,
                pathRegistry: instanceRuntime.resources.pathRegistry,
                assetSizes: instanceRuntime.resources.assetSizes,
                sceneCanvasSize: instanceRuntime.resources.canvasSize
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
}
