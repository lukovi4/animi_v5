import AVFoundation
import CoreVideo
import Metal
import TVECore

// MARK: - Audio Track Config (PR-E4)

/// Configuration for a single audio track (music or voiceover).
public struct AudioTrackConfig: Sendable {
    /// Audio file URL
    public let url: URL

    /// Start time on project timeline in seconds
    public let startTimeSeconds: Double

    /// Volume (0...1)
    public let volume: Float

    /// Optional trim start in source audio (seconds)
    public let trimStartSeconds: Double?

    /// Optional trim end in source audio (seconds)
    public let trimEndSeconds: Double?

    /// Whether to loop audio to fill project duration (v1: false)
    public let loopToFit: Bool

    public init(
        url: URL,
        startTimeSeconds: Double = 0,
        volume: Float = 1.0,
        trimStartSeconds: Double? = nil,
        trimEndSeconds: Double? = nil,
        loopToFit: Bool = false
    ) {
        self.url = url
        self.startTimeSeconds = startTimeSeconds
        self.volume = volume
        self.trimStartSeconds = trimStartSeconds
        self.trimEndSeconds = trimEndSeconds
        self.loopToFit = loopToFit
    }
}

// MARK: - Audio Export Config (PR-E4)

/// Configuration for audio export.
public struct AudioExportConfig: Sendable {
    /// Background music track (optional)
    public let music: AudioTrackConfig?

    /// Voiceover track (optional)
    public let voiceover: AudioTrackConfig?

    /// Whether to include original audio from video slots
    public let includeOriginalFromVideoSlots: Bool

    /// Default volume for original audio if not specified in VideoSelection
    public let originalDefaultVolume: Float

    public init(
        music: AudioTrackConfig? = nil,
        voiceover: AudioTrackConfig? = nil,
        includeOriginalFromVideoSlots: Bool = true,
        originalDefaultVolume: Float = 1.0
    ) {
        self.music = music
        self.voiceover = voiceover
        self.includeOriginalFromVideoSlots = includeOriginalFromVideoSlots
        self.originalDefaultVolume = originalDefaultVolume
    }
}

// MARK: - Video Quality Preset (B2)

/// Preset quality levels for video export.
///
/// Maps to target bitrate based on canvas resolution.
/// Use `.custom(bitrate:)` for explicit bitrate control.
public enum VideoQualityPreset: Sendable {
    /// Low quality: ~4 Mbps for 1080p (scaled by resolution)
    case low

    /// Medium quality: ~10 Mbps for 1080p (scaled by resolution)
    case medium

    /// High quality: ~15 Mbps for 1080p (scaled by resolution)
    case high

    /// Maximum quality: ~25 Mbps for 1080p (scaled by resolution)
    case max

    /// Custom bitrate (explicit override)
    case custom(bitrate: Int)

    /// Calculates bitrate for the given canvas size.
    ///
    /// Bitrate is scaled proportionally to pixel count relative to 1080p (1920x1080).
    ///
    /// - Parameter canvasSize: Canvas size in pixels
    /// - Returns: Target bitrate in bits per second
    public func bitrate(for canvasSize: (width: Int, height: Int)) -> Int {
        let pixels = canvasSize.width * canvasSize.height
        let referencePixels = 1920 * 1080  // 1080p baseline

        let baseBitrate: Int
        switch self {
        case .low:
            baseBitrate = 4_000_000      // 4 Mbps for 1080p
        case .medium:
            baseBitrate = 10_000_000     // 10 Mbps for 1080p
        case .high:
            baseBitrate = 15_000_000     // 15 Mbps for 1080p
        case .max:
            baseBitrate = 25_000_000     // 25 Mbps for 1080p
        case .custom(let bitrate):
            return bitrate
        }

        // Scale by pixel count, clamp to reasonable range
        let scaledBitrate = baseBitrate * pixels / referencePixels
        return Swift.max(2_000_000, Swift.min(50_000_000, scaledBitrate))
    }
}

// MARK: - Video Export Settings

/// Configuration for video export (PR-E2).
///
/// H.264 MP4 export, SDR + Rec.709 (sRGB), no alpha.
public struct VideoExportSettings: Sendable {
    /// Output file URL
    public let outputURL: URL

    /// Output size in pixels
    public let sizePx: (width: Int, height: Int)

    /// Frame rate (must match scene runtime fps)
    public let fps: Int

    /// Target average bitrate in bps
    public let bitrate: Int

    /// GOP length in seconds (default: 2)
    public let gopSeconds: Int

    /// Clear color for each frame (default: opaqueBlack for H.264)
    public let clearColor: ClearColor

    /// Audio export configuration (PR-E4). nil = video-only export.
    public let audio: AudioExportConfig?

    public init(
        outputURL: URL,
        sizePx: (width: Int, height: Int),
        fps: Int,
        bitrate: Int = 10_000_000,
        gopSeconds: Int = 2,
        clearColor: ClearColor = .opaqueBlack,
        audio: AudioExportConfig? = nil
    ) {
        self.outputURL = outputURL
        self.sizePx = sizePx
        self.fps = fps
        self.bitrate = bitrate
        self.gopSeconds = gopSeconds
        self.clearColor = clearColor
        self.audio = audio
    }
}

// MARK: - Video Export Error

/// Errors that can occur during video export (PR-E2).
public enum VideoExportError: Error, Sendable {
    /// FPS mismatch between settings and scene runtime
    case fpsMismatch(settingsFps: Int, runtimeFps: Int)

    /// Failed to create AVAssetWriter
    case failedToCreateWriter(Error?)

    /// Cannot add video input to writer
    case cannotAddVideoInput

    /// Writer failed to start
    case writerStartFailed(Error?)

    /// Failed to create CVMetalTextureCache
    case failedToCreateTextureCache

    /// No pixel buffer pool available
    case noPixelBufferPool

    /// Failed to create pixel buffer from pool
    case failedToCreatePixelBuffer(CVReturn)

    /// Failed to create Metal texture from pixel buffer
    case failedToCreateMetalTexture(CVReturn)

    /// Append failed
    case appendFailed(Error?)

    /// Finish writing failed
    case finishFailed(Error?)

    /// Export was cancelled
    case cancelled

    /// Render error
    case renderError(Error)

    /// Failed to create command buffer
    case failedToCreateCommandBuffer

    // MARK: - Audio Errors (PR-E4)

    /// Cannot add audio input to writer
    case cannotAddAudioInput

    /// Audio reader failed to start
    case audioReaderStartFailed(Error?)

    /// Audio append failed
    case audioAppendFailed(Error?)

    /// Missing audio track in source file
    case missingAudioTrack(URL)

    /// Failed to build audio pipeline
    case failedToBuildAudioPipeline(Error)
}

extension VideoExportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .fpsMismatch(let settingsFps, let runtimeFps):
            return "FPS mismatch: settings=\(settingsFps), runtime=\(runtimeFps)"
        case .failedToCreateWriter(let error):
            return "Failed to create AVAssetWriter: \(error?.localizedDescription ?? "unknown")"
        case .cannotAddVideoInput:
            return "Cannot add video input to writer"
        case .writerStartFailed(let error):
            return "Writer failed to start: \(error?.localizedDescription ?? "unknown")"
        case .failedToCreateTextureCache:
            return "Failed to create CVMetalTextureCache"
        case .noPixelBufferPool:
            return "No pixel buffer pool available"
        case .failedToCreatePixelBuffer(let status):
            return "Failed to create pixel buffer: CVReturn \(status)"
        case .failedToCreateMetalTexture(let status):
            return "Failed to create Metal texture: CVReturn \(status)"
        case .appendFailed(let error):
            return "Append failed: \(error?.localizedDescription ?? "unknown")"
        case .finishFailed(let error):
            return "Finish writing failed: \(error?.localizedDescription ?? "unknown")"
        case .cancelled:
            return "Export was cancelled"
        case .renderError(let error):
            return "Render error: \(error.localizedDescription)"
        case .failedToCreateCommandBuffer:
            return "Failed to create Metal command buffer"
        case .cannotAddAudioInput:
            return "Cannot add audio input to writer"
        case .audioReaderStartFailed(let error):
            return "Audio reader failed to start: \(error?.localizedDescription ?? "unknown")"
        case .audioAppendFailed(let error):
            return "Audio append failed: \(error?.localizedDescription ?? "unknown")"
        case .missingAudioTrack(let url):
            return "Missing audio track in: \(url.lastPathComponent)"
        case .failedToBuildAudioPipeline(let error):
            return "Failed to build audio pipeline: \(error.localizedDescription)"
        }
    }

    /// True if this error represents a user-initiated cancellation.
    public var isCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }
}

// MARK: - Timeline Export Settings (v6 Schema)

/// Settings for timeline export with transitions.
public struct TimelineExportSettings: Sendable {
    /// Output file URL
    public let outputURL: URL

    /// Output size in pixels
    public let sizePx: (width: Int, height: Int)

    /// Frame rate
    public let fps: Int

    /// Target average bitrate in bps
    public let bitrate: Int

    /// GOP length in seconds
    public let gopSeconds: Int

    /// Clear color for each frame
    public let clearColor: ClearColor

    /// Audio export configuration
    public let audio: AudioExportConfig?

    public init(
        outputURL: URL,
        sizePx: (width: Int, height: Int),
        fps: Int = 30,
        bitrate: Int = 10_000_000,
        gopSeconds: Int = 2,
        clearColor: ClearColor = .opaqueBlack,
        audio: AudioExportConfig? = nil
    ) {
        self.outputURL = outputURL
        self.sizePx = sizePx
        self.fps = fps
        self.bitrate = bitrate
        self.gopSeconds = gopSeconds
        self.clearColor = clearColor
        self.audio = audio
    }
}
