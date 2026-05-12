import Foundation
import AVFoundation

// MARK: - Video Prepare Pipeline

/// Validates a persisted video file and extracts duration.
/// Single-copy persist happens upstream (PickerAssetAdapter → MediaAssetStore).
/// Poster extraction is delegated to VideoPosterCache (derived artifact).
public enum VideoPreparePipeline {

    // MARK: - Errors

    public enum VideoPreparePipelineError: Error, LocalizedError {
        case fileNotReadable
        case invalidDuration(Double)
        case metadataLoadFailed(Error)

        public var errorDescription: String? {
            switch self {
            case .fileNotReadable:
                return "Video file is not readable"
            case .invalidDuration(let value):
                return "Video has invalid duration: \(value)"
            case .metadataLoadFailed(let error):
                return "Failed to load video metadata: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Validation

    /// Validates a persisted video file and returns a default video selection.
    ///
    /// - Parameter url: Absolute URL of the persisted video file
    /// - Returns: `PersistedVideoSelection` with trimStart=0, trimEnd=duration
    /// - Throws: `VideoPreparePipelineError` if the file is unreadable or has invalid duration
    public static func validatePersistedVideo(at url: URL) async throws -> PersistedVideoSelection {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw VideoPreparePipelineError.fileNotReadable
        }

        let asset = AVURLAsset(url: url)
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            throw VideoPreparePipelineError.metadataLoadFailed(error)
        }

        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0.001 else {
            throw VideoPreparePipelineError.invalidDuration(seconds)
        }

        return PersistedVideoSelection(trimStart: 0, trimEnd: seconds, isMuted: VideoAudioPolicy.defaultIsMuted, volume: VideoAudioPolicy.defaultVolume)
    }
}
