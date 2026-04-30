@preconcurrency import AVFoundation

// MARK: - Preview Audio Controlling Protocol

@MainActor
protocol PreviewAudioControlling: AnyObject {
    /// Replace the current audio pipeline. Does not start playback.
    func replacePipeline(_ pipeline: BuiltAudioPipeline)
    /// Start (or resume) playback from the given time, synchronized to transport host time.
    func startPlayback(fromSeconds: Double, hostTime: CFTimeInterval)
    /// Pause playback without discarding the pipeline.
    func pause()
    /// Tear down player entirely (discard pipeline).
    func teardown()
    /// Whether the controller currently holds a pipeline.
    var hasActivePipeline: Bool { get }
}

// MARK: - Production Implementation

@MainActor
final class PreviewAudioPlaybackController: PreviewAudioControlling {
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?

    var hasActivePipeline: Bool { player != nil }

    func replacePipeline(_ pipeline: BuiltAudioPipeline) {
        teardown()
        let item = AVPlayerItem(asset: pipeline.composition)
        if let mix = pipeline.audioMix { item.audioMix = mix }
        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = false
        self.player = p
        self.playerItem = item
    }

    func startPlayback(fromSeconds: Double, hostTime: CFTimeInterval) {
        guard let p = player else { return }
        let seekTime = CMTime(seconds: fromSeconds, preferredTimescale: 44100)
        p.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak p] _ in
            guard let p else { return }
            let hostCMTime = VideoFrameProvider.scheduledHostClockTime(
                forTransportHostTime: hostTime
            )
            p.setRate(1.0, time: seekTime, atHostTime: hostCMTime)
        }
    }

    func pause() { player?.pause() }

    func teardown() {
        player?.pause()
        player = nil
        playerItem = nil
    }
}
