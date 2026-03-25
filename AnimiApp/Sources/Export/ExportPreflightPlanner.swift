import Foundation

// MARK: - Export Preflight Result

/// Result of export preflight planning.
public enum ExportPreflightResult: Sendable {
    /// Safe to proceed with the computed budget.
    case safe(ExportResourceBudget)

    /// Export may exceed memory — suggest a lower preset.
    case recommendLowerPreset(
        budget: ExportResourceBudget,
        suggestedPreset: VideoQualityPreset,
        suggestedSizePx: (width: Int, height: Int)
    )

    /// The budget regardless of recommendation.
    public var budget: ExportResourceBudget {
        switch self {
        case .safe(let budget): return budget
        case .recommendLowerPreset(let budget, _, _): return budget
        }
    }
}

// MARK: - Export Preflight Planner

/// Computes an `ExportResourceBudget` from device capabilities and project parameters.
///
/// Uses `os_proc_available_memory()` (current available) and `ProcessInfo.physicalMemory`
/// (total device RAM) to determine safe resource limits.
public enum ExportPreflightPlanner {

    // MARK: - Tunable Constants

    /// Minimum memory floor in MB below which we recommend lower quality.
    private static let safeFloorMB: Int = 200

    /// Estimated MB per scene texture set (template assets loaded into GPU).
    private static let perSceneTextureMB: Int = 80

    /// Estimated MB per active video provider (reader + decoded frames).
    private static let perVideoProviderMB: Int = 30

    /// Estimated MB per background region image.
    private static let perBackgroundRegionMB: Int = 20

    /// Physical memory threshold for high-quality textures (6GB+).
    private static let highMemoryDeviceBytes: UInt64 = 6 * 1024 * 1024 * 1024

    /// Physical memory threshold for medium-quality textures (4GB+).
    private static let mediumMemoryDeviceBytes: UInt64 = 4 * 1024 * 1024 * 1024

    // MARK: - Public API

    /// Plans export resource budget based on device capabilities and project parameters.
    ///
    /// - Parameters:
    ///   - sceneCount: Number of scenes in the project
    ///   - canvasSize: Canvas size in pixels (width, height)
    ///   - videoSlotCount: Total number of video slots across all scenes
    ///   - backgroundRegionCount: Number of background images
    ///   - currentPreset: Current quality preset (used to compute suggested lower preset)
    ///   - fps: Export frame rate
    /// - Returns: Preflight result with budget and optional recommendation
    public static func plan(
        sceneCount: Int,
        canvasSize: (width: Int, height: Int),
        videoSlotCount: Int,
        backgroundRegionCount: Int = 0,
        currentPreset: VideoQualityPreset = .high,
        fps: Int
    ) -> ExportPreflightResult {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        let availableMemory = availableMemoryMB()

        // Determine target image dimension based on device class
        let deviceClassMaxDimensionPx: Int
        if physicalMemory >= highMemoryDeviceBytes {
            deviceClassMaxDimensionPx = 4096
        } else if physicalMemory >= mediumMemoryDeviceBytes {
            deviceClassMaxDimensionPx = 3072
        } else {
            deviceClassMaxDimensionPx = 2048
        }

        // Cap to 2x export canvas — no benefit loading 4096px images for 720p output
        let maxExportDimension = max(canvasSize.width, canvasSize.height)
        let targetImageMaxDimensionPx = min(deviceClassMaxDimensionPx, maxExportDimension * 2)

        // Compute prefetch frames (scale with FPS, ~1s worth)
        let videoPrefetchFrames = fps

        // Max frames in flight: conservative on low-memory devices
        let maxFramesInFlight: Int
        if availableMemory < safeFloorMB * 2 {
            maxFramesInFlight = 2
        } else {
            maxFramesInFlight = 3
        }

        // Max active video providers
        let maxActiveVideoProviders = min(videoSlotCount, physicalMemory >= mediumMemoryDeviceBytes ? 4 : 2)

        let budget = ExportResourceBudget(
            maxResidentScenes: sceneCount > 1 ? 2 : 1,
            maxActiveVideoProviders: maxActiveVideoProviders,
            videoPrefetchFrames: videoPrefetchFrames,
            maxFramesInFlight: maxFramesInFlight,
            targetImageMaxDimensionPx: targetImageMaxDimensionPx
        )

        // Estimate total memory needed
        let estimatedMB = sceneCount * perSceneTextureMB
            + videoSlotCount * perVideoProviderMB
            + backgroundRegionCount * perBackgroundRegionMB
            + (canvasSize.width * canvasSize.height * 4 * maxFramesInFlight) / (1024 * 1024)

        if availableMemory < safeFloorMB || estimatedMB > availableMemory {
            let suggested = computeSuggestedLowerPreset(
                canvasSize: canvasSize,
                currentPreset: currentPreset,
                targetImageMaxDimensionPx: targetImageMaxDimensionPx
            )
            return .recommendLowerPreset(
                budget: budget,
                suggestedPreset: suggested.preset,
                suggestedSizePx: suggested.sizePx
            )
        }

        return .safe(budget)
    }

    // MARK: - Private

    /// Computes suggested lower preset and size.
    private static func computeSuggestedLowerPreset(
        canvasSize: (width: Int, height: Int),
        currentPreset: VideoQualityPreset,
        targetImageMaxDimensionPx: Int
    ) -> (preset: VideoQualityPreset, sizePx: (width: Int, height: Int)) {
        // Scale down to 720p if canvas >= 1080p
        let maxDim = max(canvasSize.width, canvasSize.height)
        let suggestedSizePx: (width: Int, height: Int)
        if maxDim > 1280 {
            let scale = 1280.0 / Double(maxDim)
            suggestedSizePx = (
                width: Int(Double(canvasSize.width) * scale) & ~1,
                height: Int(Double(canvasSize.height) * scale) & ~1
            )
        } else {
            suggestedSizePx = canvasSize
        }

        // Step down preset
        let suggestedPreset: VideoQualityPreset
        switch currentPreset {
        case .max: suggestedPreset = .high
        case .high: suggestedPreset = .medium
        case .medium: suggestedPreset = .low
        case .low: suggestedPreset = .low
        case .custom: suggestedPreset = .medium
        }

        return (preset: suggestedPreset, sizePx: suggestedSizePx)
    }

    /// Returns available memory in MB using os_proc_available_memory().
    private static func availableMemoryMB() -> Int {
        Int(os_proc_available_memory()) / (1024 * 1024)
    }
}
