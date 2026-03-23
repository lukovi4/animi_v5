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

/// Factory for creating video coordinators from scene snapshots.
internal typealias TimelineExportCoordinatorFactory =
    (TimelineCompositionEngine.TimelineExportSceneSnapshot, CVMetalTextureCache, Int) throws -> TimelineExportVideoCoordinating?

// MARK: - TT-05: Timeline Export Runtime

/// Pure export-side resolver that works entirely on exportQueue.
/// After buildExportSession(), per-frame loop never touches engine/runtime.
internal final class TimelineExportRuntime {

    let session: TimelineCompositionEngine.TimelineExportSession
    private var videoCoordinatorsByInstanceId: [UUID: TimelineExportVideoCoordinating]

    init(
        session: TimelineCompositionEngine.TimelineExportSession,
        textureCache: CVMetalTextureCache,
        coordinatorFactory: @escaping TimelineExportCoordinatorFactory
    ) throws {
        self.session = session
        self.videoCoordinatorsByInstanceId = [:]

        for (instanceId, snapshot) in session.scenesByInstanceId {
            if let coordinator = try coordinatorFactory(snapshot, textureCache, session.fps) {
                videoCoordinatorsByInstanceId[instanceId] = coordinator
            }
        }
    }

    /// Default factory that creates ExportVideoSlotsCoordinator when video selections exist.
    static func makeDefaultFactory(device: MTLDevice) -> TimelineExportCoordinatorFactory {
        return { snapshot, textureCache, fps in
            guard !snapshot.videoSelections.isEmpty else { return nil }

            let coordinator = ExportVideoSlotsCoordinator(
                device: device,
                textureCache: textureCache,
                runtime: snapshot.runtime,
                sceneFPS: Double(fps),
                exportTextureProvider: snapshot.textureProvider
            )
            coordinator.configure(videoSelectionsByBlockId: snapshot.videoSelections)
            try coordinator.prepareAll()
            return coordinator
        }
    }

    func resolveFrame(_ compressedFrame: Int) throws -> ResolvedTimelineFrame {
        guard let mode = session.transitionMath.renderMode(for: compressedFrame) else {
            throw TimelineExportError.frameResolutionFailed(frame: compressedFrame, reason: "no_render_mode")
        }

        switch mode {
        case .single(let sceneIndex, let localFrame):
            return try resolveSingle(sceneIndex: sceneIndex, localFrame: localFrame, compressedFrame: compressedFrame)

        case .transition(let aIndex, let frameA, let bIndex, let frameB, let transition, let progress):
            return try resolveTransition(
                aIndex: aIndex, frameA: frameA,
                bIndex: bIndex, frameB: frameB,
                transition: transition, progress: progress,
                compressedFrame: compressedFrame
            )
        }
    }

    func finish() {
        for coordinator in videoCoordinatorsByInstanceId.values {
            coordinator.finish()
        }
    }

    func cancel() {
        for coordinator in videoCoordinatorsByInstanceId.values {
            coordinator.cancel()
        }
    }

    // MARK: - Private

    private func resolveSingle(sceneIndex: Int, localFrame: Int, compressedFrame: Int) throws -> ResolvedTimelineFrame {
        let math = session.transitionMath
        guard sceneIndex < math.sceneItems.count else {
            throw TimelineExportError.frameResolutionFailed(frame: compressedFrame, reason: "invalid_scene_index")
        }

        let instanceId = math.sceneItems[sceneIndex].id
        guard let snapshot = session.scenesByInstanceId[instanceId] else {
            throw TimelineExportError.frameResolutionFailed(frame: compressedFrame, reason: "missing_snapshot:\(instanceId)")
        }

        // Update video coordinator if present
        if let coordinator = videoCoordinatorsByInstanceId[instanceId] {
            coordinator.updateTextures(forSceneFrameIndex: localFrame)
            if let error = coordinator.providerError {
                throw error
            }
        }

        let context = makeRenderContext(snapshot: snapshot, localFrame: localFrame)
        return .single(context)
    }

    private func resolveTransition(
        aIndex: Int, frameA: Int,
        bIndex: Int, frameB: Int,
        transition: SceneTransition,
        progress: Double,
        compressedFrame: Int
    ) throws -> ResolvedTimelineFrame {
        let math = session.transitionMath
        guard aIndex < math.sceneItems.count, bIndex < math.sceneItems.count else {
            throw TimelineExportError.frameResolutionFailed(frame: compressedFrame, reason: "invalid_scene_index")
        }

        let instanceIdA = math.sceneItems[aIndex].id
        let instanceIdB = math.sceneItems[bIndex].id

        guard let snapshotA = session.scenesByInstanceId[instanceIdA] else {
            throw TimelineExportError.frameResolutionFailed(frame: compressedFrame, reason: "missing_snapshot:\(instanceIdA)")
        }
        guard let snapshotB = session.scenesByInstanceId[instanceIdB] else {
            throw TimelineExportError.frameResolutionFailed(frame: compressedFrame, reason: "missing_snapshot:\(instanceIdB)")
        }

        // Update coordinators
        if let coordA = videoCoordinatorsByInstanceId[instanceIdA] {
            coordA.updateTextures(forSceneFrameIndex: frameA)
            if let error = coordA.providerError {
                throw error
            }
        }
        if let coordB = videoCoordinatorsByInstanceId[instanceIdB] {
            coordB.updateTextures(forSceneFrameIndex: frameB)
            if let error = coordB.providerError {
                throw error
            }
        }

        let contextA = makeRenderContext(snapshot: snapshotA, localFrame: frameA)
        let contextB = makeRenderContext(snapshot: snapshotB, localFrame: frameB)

        return .transition(TransitionRenderContext(
            sceneA: contextA,
            sceneB: contextB,
            transition: transition,
            progress: progress
        ))
    }

    private func makeRenderContext(
        snapshot: TimelineCompositionEngine.TimelineExportSceneSnapshot,
        localFrame: Int
    ) -> SceneRenderContext {
        let commands = SceneRenderPlan.renderCommands(
            for: snapshot.runtime,
            sceneFrameIndex: localFrame,
            userTransforms: snapshot.renderState.userTransforms,
            variantOverrides: snapshot.renderState.variantOverrides,
            userMediaPresent: snapshot.renderState.userMediaPresent,
            layerToggleState: snapshot.renderState.layerToggleState
        )

        return SceneRenderContext(
            commands: commands,
            textureProvider: snapshot.textureProvider,
            pathRegistry: snapshot.pathRegistry,
            assetSizes: snapshot.assetSizes,
            localFrame: localFrame,
            canvasSize: snapshot.sceneCanvasSize,
            sceneInstanceId: snapshot.instanceId
        )
    }
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
