@preconcurrency import AVFoundation

// MARK: - Preview Audio Readiness

enum PreviewAudioReadiness: Equatable {
    case idle       // no pipeline loaded
    case preparing  // pipeline loaded, AVPlayerItem not yet ready
    case ready      // AVPlayerItem.status == .readyToPlay
    case failed     // AVPlayerItem.status == .failed
}

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
    /// Current readiness state of the underlying AVPlayerItem.
    var readiness: PreviewAudioReadiness { get }
    /// Callback fired (at most once) when readiness transitions to `.ready`.
    var onReady: (@MainActor () -> Void)? { get set }
}

// MARK: - Production Implementation

@MainActor
final class PreviewAudioPlaybackController: PreviewAudioControlling {
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private(set) var readiness: PreviewAudioReadiness = .idle
    var onReady: (@MainActor () -> Void)?
    private var statusObservation: NSKeyValueObservation?
    private var readinessToken: UInt = 0

    #if DEBUG
    var onSchedulePlayback: ((Float, CMTime, CMTime) -> Void)?
    var onSeek: ((CMTime) -> Void)?
    #endif

    var hasActivePipeline: Bool { player != nil }

    /// Internal reset: clears player, item, KVO — but preserves onReady.
    /// Used inside replacePipeline so the incoming onReady survives the reset.
    private func resetPlayer() {
        statusObservation = nil
        player?.pause()
        player = nil
        playerItem = nil
        readiness = .idle
    }

    func replacePipeline(_ pipeline: BuiltAudioPipeline) {
        resetPlayer()
        readinessToken &+= 1
        let token = readinessToken

        let item = AVPlayerItem(asset: pipeline.composition)
        if let mix = pipeline.audioMix { item.audioMix = mix }
        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = false
        self.player = p
        self.playerItem = item
        self.readiness = .preparing

        statusObservation = item.observe(\.status, options: [.new]) {
            [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                guard token == self.readinessToken else { return }
                guard self.readiness == .preparing else { return }
                guard let currentItem = self.playerItem else { return }
                switch currentItem.status {
                case .readyToPlay:
                    self.readiness = .ready
                    self.statusObservation = nil
                    let cb = self.onReady
                    self.onReady = nil
                    cb?()
                case .failed:
                    self.readiness = .failed
                    self.statusObservation = nil
                    self.onReady = nil
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }

        // Synchronous post-observe check: handle immediate readiness or failure.
        // With .new (no .initial), KVO won't fire for the current value.
        // Some items (cached/short compositions) may already be in terminal state.
        switch item.status {
        case .readyToPlay:
            readiness = .ready
            statusObservation = nil
            let cb = onReady
            onReady = nil
            cb?()
        case .failed:
            readiness = .failed
            statusObservation = nil
            onReady = nil
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    // MARK: - AVPlayer Operation Helpers

    /// Single choke-point for scheduled playback start.
    /// All code paths that need setRate(_:time:atHostTime:) MUST use this.
    private func schedulePlayback(_ player: AVPlayer, rate: Float, time: CMTime, hostTime: CMTime) {
        #if DEBUG
        if let onSchedulePlayback {
            onSchedulePlayback(rate, time, hostTime)
            return
        }
        #endif
        player.setRate(rate, time: time, atHostTime: hostTime)
    }

    /// Single choke-point for seek operations.
    /// All code paths that need seek MUST use this.
    private func seek(_ player: AVPlayer, to time: CMTime) {
        #if DEBUG
        if let onSeek {
            onSeek(time)
            return
        }
        #endif
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func startPlayback(fromSeconds: Double, hostTime: CFTimeInterval) {
        guard let p = player else { return }
        guard readiness == .ready else { return }
        let targetTime = CMTime(seconds: fromSeconds, preferredTimescale: 44100)
        let hostClockTime = VideoFrameProvider.scheduledHostClockTime(
            forTransportHostTime: hostTime
        )
        schedulePlayback(p, rate: 1.0, time: targetTime, hostTime: hostClockTime)
    }

    func pause() { player?.pause() }

    func teardown() {
        resetPlayer()
        onReady = nil
    }
}
