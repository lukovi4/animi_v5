import Foundation
import CoreMedia
import TVECore

/// Shared source of truth for scene-frame → target-video-time mapping.
///
/// Used by both preview (`UserMediaService`) and export (`ExportVideoFrameProvider`)
/// to ensure identical time calculation from scene frame index.
enum VideoTimelineTimeMapper {

    static let epsilon: Double = VideoWindowValidator.epsilon  // 1/600

    struct Result {
        let blockTimeSeconds: Double
        let targetVideoTimeSeconds: Double
    }

    /// Maps a scene frame index to the target video time within a selection window.
    ///
    /// Formula:
    /// 1. `tBlock = max(0, (sceneFrameIndex - blockStartFrame) / sceneFPS)`
    /// 2. `tVideo = winStart + tBlock`
    /// 3. `tVideoClamped = clamp(tVideo, winStart, winEnd - epsilon)`
    static func targetVideoTime(
        sceneFrameIndex: Int,
        blockStartFrame: Int,
        sceneFPS: Double,
        selection: VideoSelection
    ) -> Result {
        let framesIntoBlock = sceneFrameIndex - blockStartFrame
        let tBlock = max(0.0, Double(framesIntoBlock) / sceneFPS)
        let tVideo = selection.winStart + tBlock
        let tVideoClamped = min(max(tVideo, selection.winStart), selection.winEnd - epsilon)
        return Result(
            blockTimeSeconds: tBlock,
            targetVideoTimeSeconds: tVideoClamped
        )
    }
}
