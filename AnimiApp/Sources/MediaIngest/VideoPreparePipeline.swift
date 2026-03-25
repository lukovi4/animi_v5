import Foundation
import AVFoundation
import UIKit

// MARK: - Video Prepare Pipeline

/// File-based video preparation pipeline.
/// Single-copy persist of the video file.
/// Poster extraction is delegated to VideoPosterCache (derived artifact).
public enum VideoPreparePipeline {

    /// Prepares a video file for persistence.
    /// The source file is ready to be copied via MediaAssetStore (no transcoding needed).
    ///
    /// - Parameter sourceURL: Source video file URL (from PHPicker temp copy)
    /// - Returns: The same URL (video files are persisted as-is via single copy)
    public static func prepare(sourceURL: URL) -> URL {
        // Videos are persisted as-is — no transcoding.
        // The single copy happens in MediaAssetStore.saveMedia.
        return sourceURL
    }

    /// Extracts video duration from a file.
    ///
    /// - Parameter url: Video file URL
    /// - Returns: Duration in seconds
    public static func videoDuration(at url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            return duration.seconds
        } catch {
            return 0
        }
    }
}
