import AVFoundation
import CoreVideo
import Metal
import TVECore

// MARK: - Resident Scene

/// A scene with loaded GPU resources, ready for rendering.
internal struct ResidentScene {
    let instanceId: UUID
    let textureProvider: ExportTextureProvider
    let videoCoordinator: TimelineExportVideoCoordinating?
}

// MARK: - Timeline Export Residency Controller

/// Manages which scenes are "resident" (GPU resources loaded) during timeline export.
///
/// Instead of loading ALL scene resources upfront (which causes OOM on large projects),
/// this controller loads scene resources on demand and evicts stale scenes to stay
/// within the memory budget.
///
/// Usage:
/// ```swift
/// let controller = TimelineExportResidencyController(
///     session: exportSession,
///     budget: budget,
///     device: device,
///     commandQueue: commandQueue,
///     textureCache: textureCache
/// )
///
/// // In frame loop:
/// let residency = try controller.ensureResidency(for: frameIndex)
/// // Use residency.primary (and .secondary during transitions) for rendering
/// ```
internal final class TimelineExportResidencyController {

    // MARK: - Properties

    private let session: TimelineCompositionEngine.TimelineExportSession
    private let budget: ExportResourceBudget
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache

    /// Currently resident scenes, keyed by instance ID
    private var residentScenes: [UUID: ResidentScene] = [:]

    /// LRU tracking: last accessed frame per instance for deterministic eviction
    private var lastAccessFrame: [UUID: Int] = [:]

    /// Current frame index (for LRU tracking)
    private var currentFrame: Int = 0

    // MARK: - Initialization

    /// Creates a residency controller.
    ///
    /// - Parameters:
    ///   - session: Immutable export session with scene snapshots (includes media snapshots)
    ///   - budget: Resource budget from preflight planner
    ///   - device: Metal device
    ///   - commandQueue: Command queue for texture loading
    ///   - textureCache: CVMetalTextureCache for video frame providers
    init(
        session: TimelineCompositionEngine.TimelineExportSession,
        budget: ExportResourceBudget,
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        textureCache: CVMetalTextureCache
    ) {
        self.session = session
        self.budget = budget
        self.device = device
        self.commandQueue = commandQueue
        self.textureCache = textureCache
    }

    // MARK: - Residency

    /// Ensures the required scenes are resident for the given frame.
    ///
    /// Synchronous call — loads textures and creates video coordinators on demand.
    /// Evicts scenes that are no longer needed to stay within budget.
    ///
    /// - Parameter frameIndex: Compressed timeline frame index
    /// - Returns: Primary scene (always present) and optional secondary (during transitions)
    /// - Throws: If frame resolution or resource loading fails
    func ensureResidency(for frameIndex: Int) throws -> (primary: ResidentScene, secondary: ResidentScene?) {
        currentFrame = frameIndex

        guard let mode = session.transitionMath.renderMode(for: frameIndex) else {
            throw TimelineExportError.frameResolutionFailed(frame: frameIndex, reason: "no_render_mode")
        }

        switch mode {
        case .single(let sceneIndex, _):
            let instanceId = session.transitionMath.sceneItems[sceneIndex].id
            let primary = try ensureResident(instanceId: instanceId)
            lastAccessFrame[instanceId] = frameIndex

            evictExcept(keep: [instanceId])

            return (primary: primary, secondary: nil)

        case .transition(let aIndex, _, let bIndex, _, _, _):
            let instanceIdA = session.transitionMath.sceneItems[aIndex].id
            let instanceIdB = session.transitionMath.sceneItems[bIndex].id

            let primary = try ensureResident(instanceId: instanceIdA)
            let secondary = try ensureResident(instanceId: instanceIdB)
            lastAccessFrame[instanceIdA] = frameIndex
            lastAccessFrame[instanceIdB] = frameIndex

            evictExcept(keep: [instanceIdA, instanceIdB])

            return (primary: primary, secondary: secondary)
        }
    }

    /// Finishes all resident scenes and releases resources.
    func finish() {
        for (_, scene) in residentScenes {
            scene.textureProvider.clearAll()
            scene.videoCoordinator?.finish()
        }
        residentScenes.removeAll()
    }

    /// Cancels all resident scenes.
    func cancel() {
        for (_, scene) in residentScenes {
            scene.videoCoordinator?.cancel()
        }
        residentScenes.removeAll()
    }

    // MARK: - Private

    /// Ensures a scene is resident, loading resources if needed.
    private func ensureResident(instanceId: UUID) throws -> ResidentScene {
        if let existing = residentScenes[instanceId] {
            return existing
        }

        guard let snapshot = session.scenesByInstanceId[instanceId] else {
            throw TimelineExportError.frameResolutionFailed(frame: -1, reason: "missing_snapshot:\(instanceId)")
        }

        // Create and populate texture provider from snapshot metadata
        let textureProvider = ExportTextureProvider(
            device: device,
            assetIndex: snapshot.assetIndex,
            resolver: snapshot.resolver,
            bindingAssetIds: snapshot.bindingAssetIds
        )

        // Warm all template textures for this scene
        let assetIds = Set(snapshot.assetIndex.basenameById.keys)
        textureProvider.warm(assetIds: assetIds, commandQueue: commandQueue)

        // Load user photos via DownsampledImageLoader — inject into ALL binding asset IDs
        let mediaSnapshot = snapshot.mediaSnapshot
        for imageRef in mediaSnapshot.imageRefs {
            if let texture = try? DownsampledImageLoader.loadTexture(
                from: imageRef.url,
                device: device,
                commandQueue: commandQueue,
                maxDimensionPx: budget.targetImageMaxDimensionPx
            ) {
                for assetId in imageRef.bindingAssetIds {
                    textureProvider.setTexture(texture, for: assetId)
                }
            }
        }

        // Create video coordinator if needed
        var videoCoordinator: TimelineExportVideoCoordinating?
        if !snapshot.videoSelections.isEmpty {
            let coordinator = ExportVideoSlotsCoordinator(
                device: device,
                textureCache: textureCache,
                runtime: snapshot.runtime,
                sceneFPS: Double(session.fps),
                exportTextureProvider: textureProvider,
                videoPrefetchFrames: budget.videoPrefetchFrames,
                maxActiveProviders: budget.maxActiveVideoProviders
            )
            coordinator.configure(videoSelectionsByBlockId: snapshot.videoSelections)
            videoCoordinator = coordinator
        }

        let resident = ResidentScene(
            instanceId: instanceId,
            textureProvider: textureProvider,
            videoCoordinator: videoCoordinator
        )

        residentScenes[instanceId] = resident
        return resident
    }

    /// Evicts scenes not in the keep set, then enforces hard budget cap via LRU.
    private func evictExcept(keep: Set<UUID>) {
        // 1. Evict scenes not in keep set
        let toEvict = residentScenes.keys.filter { !keep.contains($0) }
        for instanceId in toEvict {
            evictScene(instanceId)
        }

        // 2. Hard cap: if still over budget, evict by LRU (oldest access first)
        while residentScenes.count > budget.maxResidentScenes {
            let evictable = residentScenes.keys
                .filter { !keep.contains($0) }
                .sorted { (lastAccessFrame[$0] ?? 0) < (lastAccessFrame[$1] ?? 0) }
            guard let oldest = evictable.first else { break }
            evictScene(oldest)
        }
    }

    private func evictScene(_ instanceId: UUID) {
        if let scene = residentScenes.removeValue(forKey: instanceId) {
            scene.textureProvider.clearAll()
            scene.videoCoordinator?.finish()
        }
        lastAccessFrame.removeValue(forKey: instanceId)
    }
}
