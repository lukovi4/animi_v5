import AVFoundation
import Metal
import TVECore

// MARK: - TT-05: Timeline Export Video Coordinating Protocol

/// Testability seam for video slot coordination in timeline export.
internal protocol TimelineExportVideoCoordinating: AnyObject {
    var providerError: ExportVideoFrameProviderError? { get }
    func updateTextures(forSceneFrameIndex: Int)
    func finish()
    func cancel()
}

extension ExportVideoSlotsCoordinator: TimelineExportVideoCoordinating {}

/// Factory for creating video coordinators from scene snapshots (test seam).
internal typealias TimelineExportCoordinatorFactory =
    (TimelineCompositionEngine.TimelineExportSceneSnapshot, CVMetalTextureCache, Int) throws -> TimelineExportVideoCoordinating?

// MARK: - TT-05: Timeline Export Runtime

/// Pure export-side resolver that works entirely on exportQueue.
///
/// Two modes of operation:
/// - **Residency mode** (production): Uses `TimelineExportResidencyController` to load/evict
///   scene resources on demand, preventing OOM on large projects.
/// - **Legacy mode** (tests): Uses pre-built coordinators and snapshot texture providers.
///
/// After buildExportSession(), per-frame loop never touches engine/runtime.
internal final class TimelineExportRuntime {

    let session: TimelineCompositionEngine.TimelineExportSession

    // Production path: residency-based
    private let residencyController: TimelineExportResidencyController?

    // Legacy/test path: pre-built coordinators
    private var videoCoordinatorsByInstanceId: [UUID: TimelineExportVideoCoordinating]

    // MARK: - Production Init (Residency)

    /// Creates a runtime with residency-based resource management.
    init(
        session: TimelineCompositionEngine.TimelineExportSession,
        residencyController: TimelineExportResidencyController
    ) {
        self.session = session
        self.residencyController = residencyController
        self.videoCoordinatorsByInstanceId = [:]
    }

    // MARK: - Legacy Init (Test Compatibility)

    /// Creates a runtime with eagerly-built coordinators (test seam).
    init(
        session: TimelineCompositionEngine.TimelineExportSession,
        textureCache: CVMetalTextureCache,
        coordinatorFactory: @escaping TimelineExportCoordinatorFactory
    ) throws {
        self.session = session
        self.residencyController = nil
        self.videoCoordinatorsByInstanceId = [:]

        for (instanceId, snapshot) in session.scenesByInstanceId {
            if let coordinator = try coordinatorFactory(snapshot, textureCache, session.fps) {
                videoCoordinatorsByInstanceId[instanceId] = coordinator
            }
        }
    }

    // MARK: - Frame Resolution

    func resolveFrame(_ compressedFrame: Int) throws -> ResolvedTimelineFrame {
        // If using residency controller, delegate to it
        if let residencyController {
            return try resolveFrameWithResidency(compressedFrame, controller: residencyController)
        }

        // Legacy path: use pre-built coordinators + snapshot texture providers
        return try resolveFrameLegacy(compressedFrame)
    }

    func finish() {
        if let residencyController {
            residencyController.finish()
        } else {
            for coordinator in videoCoordinatorsByInstanceId.values {
                coordinator.finish()
            }
        }
    }

    func cancel() {
        if let residencyController {
            residencyController.cancel()
        } else {
            for coordinator in videoCoordinatorsByInstanceId.values {
                coordinator.cancel()
            }
        }
    }

    // MARK: - Residency-Based Resolution

    private func resolveFrameWithResidency(
        _ compressedFrame: Int,
        controller: TimelineExportResidencyController
    ) throws -> ResolvedTimelineFrame {
        let residency = try controller.ensureResidency(for: compressedFrame)

        guard let mode = session.transitionMath.renderMode(for: compressedFrame) else {
            throw TimelineExportError.frameResolutionFailed(frame: compressedFrame, reason: "no_render_mode")
        }

        switch mode {
        case .single(let sceneIndex, let localFrame):
            let instanceId = session.transitionMath.sceneItems[sceneIndex].id
            guard let snapshot = session.scenesByInstanceId[instanceId] else {
                throw TimelineExportError.frameResolutionFailed(frame: compressedFrame, reason: "missing_snapshot:\(instanceId)")
            }

            if let coordinator = residency.primary.videoCoordinator {
                coordinator.updateTextures(forSceneFrameIndex: localFrame)
                if let error = coordinator.providerError { throw error }
            }

            let context = makeRenderContext(snapshot: snapshot, textureProvider: residency.primary.textureProvider, localFrame: localFrame)
            return .single(context)

        case .transition(let aIndex, let frameA, let bIndex, let frameB, let transition, let progress):
            guard let secondary = residency.secondary else {
                throw TimelineExportError.frameResolutionFailed(frame: compressedFrame, reason: "missing_secondary_scene")
            }

            let instanceIdA = session.transitionMath.sceneItems[aIndex].id
            let instanceIdB = session.transitionMath.sceneItems[bIndex].id
            guard let snapshotA = session.scenesByInstanceId[instanceIdA],
                  let snapshotB = session.scenesByInstanceId[instanceIdB] else {
                throw TimelineExportError.frameResolutionFailed(frame: compressedFrame, reason: "missing_snapshot")
            }

            if let coordA = residency.primary.videoCoordinator {
                coordA.updateTextures(forSceneFrameIndex: frameA)
                if let error = coordA.providerError { throw error }
            }
            if let coordB = secondary.videoCoordinator {
                coordB.updateTextures(forSceneFrameIndex: frameB)
                if let error = coordB.providerError { throw error }
            }

            let contextA = makeRenderContext(snapshot: snapshotA, textureProvider: residency.primary.textureProvider, localFrame: frameA)
            let contextB = makeRenderContext(snapshot: snapshotB, textureProvider: secondary.textureProvider, localFrame: frameB)

            return .transition(TransitionRenderContext(
                sceneA: contextA, sceneB: contextB,
                transition: transition, progress: progress
            ))
        }
    }

    // MARK: - Legacy Resolution (Test Path)

    private func resolveFrameLegacy(_ compressedFrame: Int) throws -> ResolvedTimelineFrame {
        guard let mode = session.transitionMath.renderMode(for: compressedFrame) else {
            throw TimelineExportError.frameResolutionFailed(frame: compressedFrame, reason: "no_render_mode")
        }

        switch mode {
        case .single(let sceneIndex, let localFrame):
            return try resolveSingleLegacy(sceneIndex: sceneIndex, localFrame: localFrame, compressedFrame: compressedFrame)
        case .transition(let aIndex, let frameA, let bIndex, let frameB, let transition, let progress):
            return try resolveTransitionLegacy(
                aIndex: aIndex, frameA: frameA, bIndex: bIndex, frameB: frameB,
                transition: transition, progress: progress, compressedFrame: compressedFrame
            )
        }
    }

    private func resolveSingleLegacy(sceneIndex: Int, localFrame: Int, compressedFrame: Int) throws -> ResolvedTimelineFrame {
        let math = session.transitionMath
        guard sceneIndex < math.sceneItems.count else {
            throw TimelineExportError.frameResolutionFailed(frame: compressedFrame, reason: "invalid_scene_index")
        }

        let instanceId = math.sceneItems[sceneIndex].id
        guard let snapshot = session.scenesByInstanceId[instanceId] else {
            throw TimelineExportError.frameResolutionFailed(frame: compressedFrame, reason: "missing_snapshot:\(instanceId)")
        }

        if let coordinator = videoCoordinatorsByInstanceId[instanceId] {
            coordinator.updateTextures(forSceneFrameIndex: localFrame)
            if let error = coordinator.providerError { throw error }
        }

        let context = makeRenderContextLegacy(snapshot: snapshot, localFrame: localFrame)
        return .single(context)
    }

    private func resolveTransitionLegacy(
        aIndex: Int, frameA: Int, bIndex: Int, frameB: Int,
        transition: SceneTransition, progress: Double, compressedFrame: Int
    ) throws -> ResolvedTimelineFrame {
        let math = session.transitionMath
        guard aIndex < math.sceneItems.count, bIndex < math.sceneItems.count else {
            throw TimelineExportError.frameResolutionFailed(frame: compressedFrame, reason: "invalid_scene_index")
        }

        let instanceIdA = math.sceneItems[aIndex].id
        let instanceIdB = math.sceneItems[bIndex].id

        guard let snapshotA = session.scenesByInstanceId[instanceIdA],
              let snapshotB = session.scenesByInstanceId[instanceIdB] else {
            throw TimelineExportError.frameResolutionFailed(frame: compressedFrame, reason: "missing_snapshot")
        }

        if let coordA = videoCoordinatorsByInstanceId[instanceIdA] {
            coordA.updateTextures(forSceneFrameIndex: frameA)
            if let error = coordA.providerError { throw error }
        }
        if let coordB = videoCoordinatorsByInstanceId[instanceIdB] {
            coordB.updateTextures(forSceneFrameIndex: frameB)
            if let error = coordB.providerError { throw error }
        }

        let contextA = makeRenderContextLegacy(snapshot: snapshotA, localFrame: frameA)
        let contextB = makeRenderContextLegacy(snapshot: snapshotB, localFrame: frameB)

        return .transition(TransitionRenderContext(
            sceneA: contextA, sceneB: contextB,
            transition: transition, progress: progress
        ))
    }

    // MARK: - Render Context Builders

    private func makeRenderContext(
        snapshot: TimelineCompositionEngine.TimelineExportSceneSnapshot,
        textureProvider: ExportTextureProvider,
        localFrame: Int
    ) -> SceneRenderContext {
        let commands = SceneRenderPlan.renderCommands(
            for: snapshot.runtime,
            sceneFrameIndex: localFrame,
            resolvedTransforms: snapshot.renderState.resolvedTransforms,
            variantOverrides: snapshot.renderState.variantOverrides,
            userMediaPresent: snapshot.renderState.userMediaPresent,
            layerToggleState: snapshot.renderState.layerToggleState
        )

        return SceneRenderContext(
            commands: commands,
            textureProvider: textureProvider,
            pathRegistry: snapshot.pathRegistry,
            assetSizes: snapshot.assetSizes,
            localFrame: localFrame,
            canvasSize: snapshot.sceneCanvasSize,
            sceneInstanceId: snapshot.instanceId
        )
    }

    /// Legacy render context — uses an empty texture provider since tests don't render.
    private func makeRenderContextLegacy(
        snapshot: TimelineCompositionEngine.TimelineExportSceneSnapshot,
        localFrame: Int
    ) -> SceneRenderContext {
        let commands = SceneRenderPlan.renderCommands(
            for: snapshot.runtime,
            sceneFrameIndex: localFrame,
            resolvedTransforms: snapshot.renderState.resolvedTransforms,
            variantOverrides: snapshot.renderState.variantOverrides,
            userMediaPresent: snapshot.renderState.userMediaPresent,
            layerToggleState: snapshot.renderState.layerToggleState
        )

        return SceneRenderContext(
            commands: commands,
            textureProvider: EmptyTestTextureProvider(),
            pathRegistry: snapshot.pathRegistry,
            assetSizes: snapshot.assetSizes,
            localFrame: localFrame,
            canvasSize: snapshot.sceneCanvasSize,
            sceneInstanceId: snapshot.instanceId
        )
    }
}

/// Empty texture provider for legacy test path.
private final class EmptyTestTextureProvider: TextureProvider {
    func texture(for assetId: String) -> MTLTexture? { nil }
}

// MARK: - Timeline Export Errors

public enum TimelineExportError: Error, LocalizedError {
    case noTimeline
    /// TT-02: Frame resolution failed with reason
    case frameResolutionFailed(frame: Int, reason: String)
    /// TT-02: Hold is not allowed in export mode
    case frameHoldNotAllowed(Int)
    case failedToAcquireOffscreenTexture

    public var errorDescription: String? {
        switch self {
        case .noTimeline:
            return "No timeline configured in composition engine"
        case .frameResolutionFailed(let frame, let reason):
            return "Failed to resolve frame \(frame): \(reason)"
        case .frameHoldNotAllowed(let frame):
            return "Frame \(frame) returned hold, which is not allowed in export"
        case .failedToAcquireOffscreenTexture:
            return "Failed to acquire offscreen texture from pool"
        }
    }
}
