import AVFoundation
import TVECore

// MARK: - Audio Build Error

/// Errors that can occur during audio composition building (PR-E4).
public enum AudioBuildError: Error, Sendable {
    /// Missing audio track in source file
    case missingAudioTrack(URL)

    /// Failed to insert audio segment
    case insertFailed(URL, Error)

    /// Invalid time range
    case invalidTimeRange(URL, String)
}

extension AudioBuildError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingAudioTrack(let url):
            return "Missing audio track in: \(url.lastPathComponent)"
        case .insertFailed(let url, let error):
            return "Failed to insert audio from \(url.lastPathComponent): \(error.localizedDescription)"
        case .invalidTimeRange(let url, let details):
            return "Invalid time range for \(url.lastPathComponent): \(details)"
        }
    }
}

// MARK: - Built Audio Pipeline

/// Result of audio composition building.
public struct BuiltAudioPipeline: Sendable {
    /// The composed audio timeline
    public let composition: AVMutableComposition

    /// Audio mix for volume control (optional)
    public let audioMix: AVAudioMix?

    public init(composition: AVMutableComposition, audioMix: AVAudioMix?) {
        self.composition = composition
        self.audioMix = audioMix
    }
}

// MARK: - Audio Composition Builder

/// Builds AVMutableComposition + AVMutableAudioMix for export (PR-E4).
///
/// Creates audio timeline from:
/// - Music track (background)
/// - Voiceover track
/// - Original audio from video slots (using VideoSelection parameters)
///
/// Usage:
/// ```swift
/// let builder = AudioCompositionBuilder()
/// let pipeline = try builder.build(
///     runtime: compiledScene.runtime,
///     fps: 30,
///     videoSelectionsByBlockId: selections,
///     config: audioConfig
/// )
/// ```
public final class AudioCompositionBuilder {
    // MARK: - Constants

    /// Preferred timescale for audio operations
    private static let timescale: CMTimeScale = 44100

    // MARK: - Init

    public init() {}

    // MARK: - Build

    /// Builds audio composition from configuration.
    ///
    /// - Parameters:
    ///   - runtime: Scene runtime (for duration and block timing)
    ///   - fps: Scene FPS
    ///   - videoSelectionsByBlockId: Video selections snapshot (for original audio)
    ///   - config: Audio export configuration
    ///   - transitionMath: Timeline transition math for multi-scene export (optional)
    ///   - sceneIndex: Index of this scene in timeline (required if transitionMath provided)
    /// - Returns: Built audio pipeline with composition and optional mix
    public func build(
        runtime: SceneRuntime,
        fps: Int,
        videoSelectionsByBlockId: [String: VideoSelection],
        config: AudioExportConfig,
        transitionMath: TimelineTransitionMath? = nil,
        sceneIndex: Int = 0
    ) throws -> BuiltAudioPipeline {
        let composition = AVMutableComposition()
        var mixParameters: [AVMutableAudioMixInputParameters] = []

        // For multi-scene export with transitions, use compressed duration
        let projectDuration: Double
        if let math = transitionMath {
            projectDuration = Double(math.compressedDurationFrames) / Double(fps)
        } else {
            projectDuration = Double(runtime.durationFrames) / Double(fps)
        }
        let projectDurationTime = CMTime(seconds: projectDuration, preferredTimescale: Self.timescale)

        // 1. Add music track (if configured)
        if let musicConfig = config.music {
            let params = try insertAudioTrack(
                config: musicConfig,
                into: composition,
                projectDuration: projectDuration,
                label: "music"
            )
            if let params { mixParameters.append(params) }
        }

        // 2. Add voiceover track (if configured)
        if let voiceoverConfig = config.voiceover {
            let params = try insertAudioTrack(
                config: voiceoverConfig,
                into: composition,
                projectDuration: projectDuration,
                label: "voiceover"
            )
            if let params { mixParameters.append(params) }
        }

        // 3. Add original audio from video slots (if enabled)
        if config.includeOriginalFromVideoSlots {
            for block in runtime.blocks {
                guard let selection = videoSelectionsByBlockId[block.blockId] else { continue }
                guard selection.isValid else { continue }
                guard !selection.isMuted else { continue }

                let params = try insertVideoSlotAudio(
                    selection: selection,
                    block: block,
                    into: composition,
                    fps: fps,
                    projectDuration: projectDuration,
                    defaultVolume: config.originalDefaultVolume,
                    transitionMath: transitionMath,
                    sceneIndex: sceneIndex
                )
                if let params { mixParameters.append(params) }
            }
        }

        // 4. Build audio mix (if we have any volume parameters)
        var audioMix: AVAudioMix?
        if !mixParameters.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = mixParameters
            audioMix = mix
        }

        return BuiltAudioPipeline(composition: composition, audioMix: audioMix)
    }

    // MARK: - Private: Insert Audio Track

    /// Inserts a configured audio track (music/voiceover) into composition.
    private func insertAudioTrack(
        config: AudioTrackConfig,
        into composition: AVMutableComposition,
        projectDuration: Double,
        label: String
    ) throws -> AVMutableAudioMixInputParameters? {
        let asset = AVURLAsset(url: config.url)

        // Get audio track
        guard let sourceTrack = asset.tracks(withMediaType: .audio).first else {
            throw AudioBuildError.missingAudioTrack(config.url)
        }

        // Create composition track
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw AudioBuildError.insertFailed(config.url, NSError(domain: "AudioCompositionBuilder", code: -1))
        }

        // Calculate source time range
        let sourceDuration = asset.duration.seconds
        let trimStart = config.trimStartSeconds ?? 0
        let trimEnd = config.trimEndSeconds ?? sourceDuration
        let trimmedDuration = max(0, trimEnd - trimStart)

        // Calculate insert parameters
        let insertAt = config.startTimeSeconds
        let availableProjectTime = max(0, projectDuration - insertAt)
        let insertDuration = min(trimmedDuration, availableProjectTime)

        guard insertDuration > 0 else { return nil }

        // Source time range
        let sourceStartTime = CMTime(seconds: trimStart, preferredTimescale: Self.timescale)
        let sourceDurationTime = CMTime(seconds: insertDuration, preferredTimescale: Self.timescale)
        let sourceTimeRange = CMTimeRange(start: sourceStartTime, duration: sourceDurationTime)

        // Destination time
        let destinationTime = CMTime(seconds: insertAt, preferredTimescale: Self.timescale)

        // Insert
        do {
            try compositionTrack.insertTimeRange(sourceTimeRange, of: sourceTrack, at: destinationTime)
        } catch {
            throw AudioBuildError.insertFailed(config.url, error)
        }

        // Volume parameters
        let params = AVMutableAudioMixInputParameters(track: compositionTrack)
        params.setVolume(config.volume, at: .zero)

        return params
    }

    // MARK: - Private: Insert Video Slot Audio

    /// Inserts original audio from a video slot into composition.
    ///
    /// Uses the canonical formula:
    /// - sourceStart = selection.winStart
    /// - insertAt = blockStartTime (compressed if transitionMath provided)
    /// - insertDuration = min(windowDuration, availableProject, blockVisibility)
    ///
    /// For multi-scene export with transitions:
    /// - blockStartTime is computed using TimelineTransitionMath.compressedFrame()
    /// - This ensures audio is placed at correct position in compressed timeline
    private func insertVideoSlotAudio(
        selection: VideoSelection,
        block: BlockRuntime,
        into composition: AVMutableComposition,
        fps: Int,
        projectDuration: Double,
        defaultVolume: Float,
        transitionMath: TimelineTransitionMath? = nil,
        sceneIndex: Int = 0
    ) throws -> AVMutableAudioMixInputParameters? {
        let asset = AVURLAsset(url: selection.url)

        // Get audio track (video might not have audio - skip with DEBUG warning)
        guard let sourceTrack = asset.tracks(withMediaType: .audio).first else {
            #if DEBUG
            print("[AudioCompositionBuilder] WARNING: blockId=\(block.blockId), file=\(selection.url.lastPathComponent) - no audio track, skipping original audio")
            #endif
            return nil
        }

        // Create composition track
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            return nil
        }

        // Calculate timing using canonical formula
        // For multi-scene: use compressed frame mapping
        let blockStartTime: Double
        if let math = transitionMath {
            // Convert scene-local frame to compressed global frame
            let compressedFrame = math.compressedFrame(
                forUncompressedFrame: block.timing.startFrame,
                inSceneAt: sceneIndex
            )
            blockStartTime = Double(compressedFrame) / Double(fps)
        } else {
            // Single-scene: use local frame directly
            blockStartTime = Double(block.timing.startFrame) / Double(fps)
        }
        let blockVisibility = Double(block.timing.endFrame - block.timing.startFrame) / Double(fps)
        let windowDuration = max(0, selection.winEnd - selection.winStart)
        let availableProject = max(0, projectDuration - blockStartTime)

        // insertDuration = min(windowDuration, availableProject, blockVisibility)
        let insertDuration = min(windowDuration, availableProject, blockVisibility)

        guard insertDuration > 0 else { return nil }

        // Source time range (starts at winStart, which already includes offset)
        let sourceStartTime = CMTime(seconds: selection.winStart, preferredTimescale: Self.timescale)
        let sourceDurationTime = CMTime(seconds: insertDuration, preferredTimescale: Self.timescale)
        let sourceTimeRange = CMTimeRange(start: sourceStartTime, duration: sourceDurationTime)

        // Destination time (block start on project timeline)
        let destinationTime = CMTime(seconds: blockStartTime, preferredTimescale: Self.timescale)

        // Insert
        do {
            try compositionTrack.insertTimeRange(sourceTimeRange, of: sourceTrack, at: destinationTime)
        } catch {
            // Video slot audio insert failure is non-fatal (video might not have audio)
            return nil
        }

        // Volume parameters
        let volume = selection.volume > 0 ? selection.volume : defaultVolume
        let params = AVMutableAudioMixInputParameters(track: compositionTrack)
        params.setVolume(volume, at: .zero)

        return params
    }

    // MARK: - Timeline Build (Multi-Scene)

    /// Builds audio composition for multi-scene timeline export.
    ///
    /// Uses hard-cut semantics (no audio crossfade during transitions).
    /// Each scene's audio is placed at its compressed start time.
    ///
    /// - Parameters:
    ///   - sceneData: Audio export data for each scene (from TimelineCompositionEngine)
    ///   - transitionMath: Timeline transition math for compressed timing
    ///   - fps: Timeline FPS
    ///   - config: Audio export configuration
    /// - Returns: Built audio pipeline with composition and optional mix
    public func buildTimeline(
        sceneData: [TimelineCompositionEngine.SceneAudioExportData],
        transitionMath: TimelineTransitionMath,
        fps: Int,
        config: AudioExportConfig
    ) throws -> BuiltAudioPipeline {
        let composition = AVMutableComposition()
        var mixParameters: [AVMutableAudioMixInputParameters] = []

        let projectDuration = Double(transitionMath.compressedDurationFrames) / Double(fps)
        let projectDurationTime = CMTime(seconds: projectDuration, preferredTimescale: Self.timescale)

        // 1. Add music track (if configured) - spans entire project
        if let musicConfig = config.music {
            let params = try insertAudioTrack(
                config: musicConfig,
                into: composition,
                projectDuration: projectDuration,
                label: "music"
            )
            if let params { mixParameters.append(params) }
        }

        // 2. Add voiceover track (if configured) - spans entire project
        if let voiceoverConfig = config.voiceover {
            let params = try insertAudioTrack(
                config: voiceoverConfig,
                into: composition,
                projectDuration: projectDuration,
                label: "voiceover"
            )
            if let params { mixParameters.append(params) }
        }

        // 3. Add original audio from video slots for each scene (if enabled)
        if config.includeOriginalFromVideoSlots {
            for data in sceneData {
                // Process each block in this scene
                for block in data.runtime.blocks {
                    guard let selection = data.videoSelections[block.blockId] else { continue }
                    guard selection.isValid else { continue }
                    guard !selection.isMuted else { continue }

                    let params = try insertVideoSlotAudio(
                        selection: selection,
                        block: block,
                        into: composition,
                        fps: fps,
                        projectDuration: projectDuration,
                        defaultVolume: config.originalDefaultVolume,
                        transitionMath: transitionMath,
                        sceneIndex: data.sceneIndex
                    )
                    if let params { mixParameters.append(params) }
                }
            }
        }

        // 4. Build audio mix (if we have any volume parameters)
        var audioMix: AVAudioMix?
        if !mixParameters.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = mixParameters
            audioMix = mix
        }

        return BuiltAudioPipeline(composition: composition, audioMix: audioMix)
    }
}
