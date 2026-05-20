import Foundation

// MARK: - Export Resource Budget

/// Memory-budget-driven resource limits for video export.
///
/// Controls how many scenes, video providers, and textures can be resident
/// simultaneously during export to prevent OOM/jetsam crashes on real devices.
///
/// Created by `ExportPreflightPlanner` based on device capabilities.
public struct ExportResourceBudget: Sendable, Equatable {

    /// Maximum number of scenes with loaded textures.
    /// 1 for normal rendering, 2 during transitions.
    public let maxResidentScenes: Int

    /// Maximum number of active video frame providers.
    public let maxActiveVideoProviders: Int

    /// Number of frames to prefetch for video visibility gating.
    /// Replaces the hardcoded 1.0s margin in ExportVideoSlotsCoordinator.
    public let videoPrefetchFrames: Int

    /// Maximum number of frames in the GPU rendering pipeline.
    /// Fed to renderer + semaphore.
    public let maxFramesInFlight: Int

    /// Maximum image dimension in pixels for downsampled loading.
    /// e.g. 2048 on 3GB devices, 4096 on 6GB+ devices.
    public let targetImageMaxDimensionPx: Int

    public init(
        maxResidentScenes: Int = 2,
        maxActiveVideoProviders: Int = 4,
        videoPrefetchFrames: Int = 15,
        maxFramesInFlight: Int = 3,
        targetImageMaxDimensionPx: Int = 2048
    ) {
        self.maxResidentScenes = maxResidentScenes
        self.maxActiveVideoProviders = maxActiveVideoProviders
        self.videoPrefetchFrames = videoPrefetchFrames
        self.maxFramesInFlight = maxFramesInFlight
        self.targetImageMaxDimensionPx = targetImageMaxDimensionPx
    }

    /// Default budget for when preflight is not available.
    /// Conservative values safe for 3GB devices.
    public static let `default` = ExportResourceBudget()
}
