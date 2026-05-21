@preconcurrency import AVFoundation

// MARK: - Preview Audio Readiness

enum PreviewAudioReadiness: Equatable {
    case idle       // no pipeline loaded
    case preparing  // pipeline loaded, AVPlayerItem not yet ready
    case ready      // AVPlayerItem ready, preroll not done
    case prerolling // preroll(atRate:) in flight
    case primed     // preroll complete, ready for instant playback
    case failed     // AVPlayerItem.status == .failed
}

// MARK: - Preview Audio Failure Reason

enum PreviewAudioFailureReason: Equatable {
    case itemFailed(error: String?)
    case startOnFailedItem
    case playerFailed(error: String?)
    case renderFailed(error: String?)
}

// MARK: - Preview Audio Preroll Result

enum PreviewAudioPrerollResult: Equatable {
    case primed
    case readyFallback
    case deferredPlayerNotReady
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
    /// Callback fired when the item fails after being ready, or when startPlayback detects a failed item.
    var onFailure: (@MainActor (PreviewAudioFailureReason) -> Void)? { get set }
    /// Callback fired when preroll completes or cannot start.
    var onPrerollFinished: (@MainActor (PreviewAudioPrerollResult) -> Void)? { get set }
    /// Initiates AVPlayer.preroll(atRate:) to prime for instant playback.
    func prepareForImmediatePlayback()
}

// MARK: - Production Implementation

@MainActor
final class PreviewAudioPlaybackController: PreviewAudioControlling {
    private static let seekDriftThreshold: Double = 0.15 // seconds

    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private(set) var readiness: PreviewAudioReadiness = .idle
    var onReady: (@MainActor () -> Void)?
    var onFailure: (@MainActor (PreviewAudioFailureReason) -> Void)?
    var onPrerollFinished: (@MainActor (PreviewAudioPrerollResult) -> Void)?
    private var statusObservation: NSKeyValueObservation?
    private var readinessToken: UInt = 0
    private var playbackStartToken: UInt = 0
    private var prerollToken: UInt = 0

    #if DEBUG
    var onSchedulePlayback: ((Float, CMTime, CMTime) -> Void)?
    var onPlayImmediately: ((Float) -> Void)?
    var onSeek: ((CMTime, @escaping (Bool) -> Void) -> Void)?
    var onCancelPendingSeeks: (() -> Void)?
    var onCancelPendingPrerolls: (() -> Void)?
    var onPreroll: ((Float, @escaping (Bool) -> Void) -> Void)?
    private var debugObservations: [NSKeyValueObservation] = []
    private var debugNotificationObservers: [Any] = []
    private var debugStartSequence: UInt = 0
    #endif

    var hasActivePipeline: Bool { player != nil }

    // MARK: - Failure Transition

    /// Centralized terminal failure transition. All failure paths must use this.
    private func transitionToFailed(_ reason: PreviewAudioFailureReason) {
        guard readiness != .failed else { return }
        cancelPendingPrerollAndInvalidate()
        readiness = .failed
        statusObservation = nil
        onReady = nil
        onPrerollFinished = nil
        onFailure?(reason)
    }

    /// Validates the current item is startable. If not, transitions to failed.
    /// Returns true only when item is non-nil, `.readyToPlay`, and has no error.
    private func validateCurrentItemForStart() -> Bool {
        guard let item = playerItem, item.status == .readyToPlay, item.error == nil else {
            #if DEBUG
            MemoryDiagnostics.event("preview.audio.startPlayback.itemInvalid", "readiness=\(readiness) itemStatus=\(playerItem?.status.rawValue ?? -1) error=\(playerItem?.error?.localizedDescription ?? "none")")
            #endif
            transitionToFailed(.startOnFailedItem)
            return false
        }
        return true
    }

    #if DEBUG
    /// Test seam: invalidates the current playerItem (nils it) so
    /// validateCurrentItemForStart returns false. Only available in DEBUG.
    func invalidateCurrentItemForTesting() {
        playerItem = nil
    }
    #endif

    /// Internal reset: clears player, item, KVO — but preserves onReady.
    /// Used inside replacePipeline so the incoming onReady survives the reset.
    private func resetPlayer() {
        cancelPendingPrerollAndInvalidate()
        statusObservation = nil
        #if DEBUG
        debugObservations.removeAll()
        for observer in debugNotificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        debugNotificationObservers.removeAll()
        #endif
        player?.pause()
        player = nil
        playerItem = nil
        readiness = .idle
    }

    func replacePipeline(_ pipeline: BuiltAudioPipeline) {
        #if DEBUG
        let tracks = pipeline.composition.tracks(withMediaType: .audio).count
        let hasMix = pipeline.audioMix != nil
        let mixInputs = pipeline.audioMix?.inputParameters.count ?? 0
        let dur = CMTimeGetSeconds(pipeline.composition.duration)
        MemoryDiagnostics.event("preview.audio.replacePipeline", "tracks=\(tracks) hasMix=\(hasMix ? 1 : 0) mixInputs=\(mixInputs) duration=\(dur)")
        #endif
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

        #if DEBUG
        debugObservations.append(p.observe(\.rate, options: [.new, .old]) { player, change in
            let old = change.oldValue ?? -1
            let new = change.newValue ?? -1
            MemoryDiagnostics.event("preview.audio.player.rate", "old=\(old) new=\(new)")
        })
        debugObservations.append(p.observe(\.timeControlStatus, options: [.new]) { player, _ in
            MemoryDiagnostics.event("preview.audio.player.timeControl", "status=\(player.timeControlStatus.rawValue)")
        })
        let nc = NotificationCenter.default
        debugNotificationObservers.append(nc.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { _ in
            MemoryDiagnostics.event("preview.audio.player.stalled", "")
        })
        debugNotificationObservers.append(nc.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { note in
            let err = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "none"
            MemoryDiagnostics.event("preview.audio.player.failedToEnd", "error=\(err)")
        })
        #endif

        statusObservation = item.observe(\.status, options: [.new]) {
            [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                guard token == self.readinessToken else { return }
                guard let currentItem = self.playerItem else { return }
                switch currentItem.status {
                case .readyToPlay:
                    guard self.readiness == .preparing else { return }
                    #if DEBUG
                    MemoryDiagnostics.event("preview.audio.playerReady", "token=\(token) via=kvo")
                    #endif
                    self.readiness = .ready
                    // Keep statusObservation alive to catch post-ready failures
                    let cb = self.onReady
                    self.onReady = nil
                    cb?()
                case .failed:
                    #if DEBUG
                    MemoryDiagnostics.event("preview.audio.playerFailed", "token=\(token) via=kvo error=\(currentItem.error?.localizedDescription ?? "none")")
                    #endif
                    self.transitionToFailed(.itemFailed(error: currentItem.error?.localizedDescription))
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
            guard readiness == .preparing else { break }
            #if DEBUG
            MemoryDiagnostics.event("preview.audio.playerReady", "token=\(token) via=sync")
            #endif
            readiness = .ready
            // Keep statusObservation alive to catch post-ready failures
            let cb = onReady
            onReady = nil
            cb?()
        case .failed:
            #if DEBUG
            MemoryDiagnostics.event("preview.audio.playerFailed", "token=\(token) via=sync error=\(item.error?.localizedDescription ?? "none")")
            #endif
            transitionToFailed(.itemFailed(error: item.error?.localizedDescription))
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    // MARK: - Preroll

    func prepareForImmediatePlayback() {
        guard let p = player else { return }
        guard readiness == .ready else { return }
        guard validateCurrentItemForStart() else { return }

        switch p.status {
        case .readyToPlay:
            break
        case .failed:
            #if DEBUG
            MemoryDiagnostics.event("preview.audio.preroll.playerFailed", "error=\(p.error?.localizedDescription ?? "none")")
            #endif
            transitionToFailed(.playerFailed(error: p.error?.localizedDescription))
            return
        case .unknown:
            // Player not ready for preroll yet — stay in .ready, signal coordinator.
            #if DEBUG
            MemoryDiagnostics.event("preview.audio.preroll.playerNotReady", "playerStatus=\(p.status.rawValue)")
            #endif
            let cb = onPrerollFinished
            onPrerollFinished = nil
            cb?(.deferredPlayerNotReady)
            return
        @unknown default:
            #if DEBUG
            MemoryDiagnostics.event("preview.audio.preroll.unknownPlayerStatus", "playerStatus=\(p.status.rawValue)")
            #endif
            let cb = onPrerollFinished
            onPrerollFinished = nil
            cb?(.deferredPlayerNotReady)
            return
        }

        cancelPendingPrerollAndInvalidate()
        let token = prerollToken
        readiness = .prerolling

        #if DEBUG
        MemoryDiagnostics.event("preview.audio.preroll.begin", "token=\(token)")
        if let onPreroll {
            onPreroll(1.0) { [weak self] finished in
                self?.handlePrerollCompletion(finished: finished, token: token)
            }
            return
        }
        #endif

        p.preroll(atRate: 1.0) { [weak self] finished in
            DispatchQueue.main.async {
                self?.handlePrerollCompletion(finished: finished, token: token)
            }
        }
    }

    private func cancelPendingPrerollAndInvalidate() {
        prerollToken &+= 1
        #if DEBUG
        if let onCancelPendingPrerolls {
            onCancelPendingPrerolls()
            return
        }
        #endif
        player?.cancelPendingPrerolls()
    }

    private func handlePrerollCompletion(finished: Bool, token: UInt) {
        guard prerollToken == token else {
            #if DEBUG
            MemoryDiagnostics.event("preview.audio.preroll.stale", "token=\(token) currentToken=\(prerollToken)")
            #endif
            return
        }
        guard readiness == .prerolling else { return }

        #if DEBUG
        MemoryDiagnostics.event("preview.audio.preroll.end", "token=\(token) finished=\(finished ? 1 : 0) itemStatus=\(playerItem?.status.rawValue ?? -1) error=\(playerItem?.error?.localizedDescription ?? "none")")
        #endif

        if finished {
            guard validateCurrentItemForStart() else { return }
            readiness = .primed
            let cb = onPrerollFinished
            onPrerollFinished = nil
            cb?(.primed)
        } else {
            guard let item = playerItem, item.status == .readyToPlay, item.error == nil else {
                transitionToFailed(.startOnFailedItem)
                return
            }
            readiness = .ready
            let cb = onPrerollFinished
            onPrerollFinished = nil
            cb?(.readyFallback)
        }
    }

    #if DEBUG
    private func playerSnapshot() -> String {
        guard let p = player else { return "hasPlayer=0" }
        let item = p.currentItem
        let itemStatus: String = {
            switch item?.status {
            case .readyToPlay: return "readyToPlay"
            case .failed: return "failed"
            case .unknown: return "unknown"
            case .none: return "nil"
            @unknown default: return "other"
            }
        }()
        let current = CMTimeGetSeconds(p.currentTime())
        let dur = item.map { CMTimeGetSeconds($0.duration) } ?? -1
        let err = item?.error?.localizedDescription ?? "none"
        return "hasPlayer=1 readiness=\(readiness) itemStatus=\(itemStatus) rate=\(p.rate) timeControl=\(p.timeControlStatus.rawValue) current=\(current) duration=\(dur) volume=\(p.volume) muted=\(p.isMuted ? 1 : 0) error=\(err)"
    }
    #endif

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

    // MARK: - Immediate Playback

    private enum PlaybackStartMode {
        case scheduled
        case immediatePrimed
    }

    private var resolvedStartMode: PlaybackStartMode {
        readiness == .primed ? .immediatePrimed : .scheduled
    }

    /// Single choke-point for immediate playback start (primed path).
    /// All code paths that use playImmediately(atRate:) MUST use this.
    private func startPlaybackNow(_ player: AVPlayer, rate: Float) {
        #if DEBUG
        if let onPlayImmediately {
            onPlayImmediately(rate)
            return
        }
        #endif
        player.playImmediately(atRate: rate)
    }

    /// Cancels any in-flight seek on the current player item.
    /// Called before new seeks, on pause, and on teardown.
    private func cancelPendingSeeks() {
        #if DEBUG
        if let onCancelPendingSeeks {
            onCancelPendingSeeks()
            return
        }
        #endif
        playerItem?.cancelPendingSeeks()
    }

    /// Single choke-point for seek operations.
    /// All code paths that need seek MUST use this.
    private func seek(_ player: AVPlayer, to time: CMTime, completion: @escaping @Sendable (Bool) -> Void) {
        #if DEBUG
        if let onSeek {
            onSeek(time, completion)
            return
        }
        #endif
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: completion)
    }

    func startPlayback(fromSeconds: Double, hostTime: CFTimeInterval) {
        guard let p = player else {
            #if DEBUG
            MemoryDiagnostics.event("preview.audio.startPlayback.noPlayer", "")
            #endif
            return
        }
        guard readiness == .ready || readiness == .primed else {
            #if DEBUG
            MemoryDiagnostics.event("preview.audio.startPlayback.notReady", "readiness=\(String(describing: readiness))")
            #endif
            return
        }
        guard validateCurrentItemForStart() else { return }

        playbackStartToken &+= 1
        let startToken = playbackStartToken
        cancelPendingPrerollAndInvalidate()
        cancelPendingSeeks()

        #if DEBUG
        debugStartSequence &+= 1
        let startId = debugStartSequence
        let nowMedia = CACurrentMediaTime()
        let hostDeltaMs = (nowMedia - hostTime) * 1000
        MemoryDiagnostics.event("preview.audio.startPlayback.begin", "startId=\(startId) \(playerSnapshot()) seconds=\(fromSeconds) transportHost=\(hostTime) nowMedia=\(nowMedia) hostDeltaMs=\(hostDeltaMs) target=\(fromSeconds)")
        #endif

        let targetTime = CMTime(seconds: fromSeconds, preferredTimescale: 44100)
        let hostClockTime = VideoFrameProvider.scheduledHostClockTime(
            forTransportHostTime: hostTime
        )

        let currentSeconds = p.currentTime().seconds
        let drift = currentSeconds.isNaN ? .infinity : abs(currentSeconds - fromSeconds)

        #if DEBUG
        let driftMs = drift * 1000
        let thresholdMs = Self.seekDriftThreshold * 1000
        let path = drift <= Self.seekDriftThreshold ? "direct" : "seek"
        MemoryDiagnostics.event("preview.audio.startPlayback.drift", "startId=\(startId) current=\(currentSeconds) target=\(fromSeconds) driftMs=\(driftMs) thresholdMs=\(thresholdMs) path=\(path)")
        #endif

        if drift <= Self.seekDriftThreshold {
            // Direct path — player is close enough
            switch resolvedStartMode {
            case .immediatePrimed:
                #if DEBUG
                MemoryDiagnostics.event("preview.audio.startPlayback.schedule", "startId=\(startId) mode=playImmediatelyPrimed target=\(fromSeconds)")
                #endif

                startPlaybackNow(p, rate: 1.0)

                #if DEBUG
                MemoryDiagnostics.event("preview.audio.startPlayback.scheduled", "startId=\(startId) \(playerSnapshot())")
                scheduleDebugProbes(startId: startId, player: p, target: fromSeconds)
                #endif

            case .scheduled:
                #if DEBUG
                let hostClockNow = CMClockGetTime(CMClockGetHostTimeClock())
                let hostLeadMs = (CMTimeGetSeconds(hostClockTime) - CMTimeGetSeconds(hostClockNow)) * 1000
                MemoryDiagnostics.event("preview.audio.startPlayback.schedule", "startId=\(startId) mode=setRateAtHostTime target=\(fromSeconds) hostClock=\(CMTimeGetSeconds(hostClockTime)) hostLeadMs=\(hostLeadMs)")
                #endif

                schedulePlayback(p, rate: 1.0, time: targetTime, hostTime: hostClockTime)

                #if DEBUG
                MemoryDiagnostics.event("preview.audio.startPlayback.scheduled", "startId=\(startId) \(playerSnapshot())")
                scheduleDebugProbes(startId: startId, player: p, target: fromSeconds)
                #endif
            }
        } else {
            // Seek path — player too far from target
            let capturedReadinessToken = readinessToken
            let capturedPlayer = p
            #if DEBUG
            MemoryDiagnostics.event("preview.audio.startPlayback.seek.begin", "startId=\(startId) current=\(currentSeconds) target=\(fromSeconds) driftMs=\(driftMs)")
            #endif

            seek(p, to: targetTime) { [weak self] finished in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard finished else {
                        #if DEBUG
                        MemoryDiagnostics.event("preview.audio.startPlayback.seek.cancelled", "startId=\(startId)")
                        #endif
                        return
                    }
                    // Production stale guard: newer startPlayback supersedes this seek
                    guard self.playbackStartToken == startToken else {
                        #if DEBUG
                        MemoryDiagnostics.event("preview.audio.startPlayback.seek.stale", "startId=\(startId) reason=startToken expected=\(startToken) actual=\(self.playbackStartToken)")
                        #endif
                        return
                    }
                    guard self.readinessToken == capturedReadinessToken,
                          self.player === capturedPlayer,
                          (self.readiness == .ready || self.readiness == .primed) else {
                        #if DEBUG
                        MemoryDiagnostics.event("preview.audio.startPlayback.seek.stale", "startId=\(startId) reason=readinessOrPlayer")
                        #endif
                        return
                    }
                    guard self.validateCurrentItemForStart() else { return }

                    #if DEBUG
                    let postSeekCurrent = capturedPlayer.currentTime().seconds
                    let postSeekDrift = abs(postSeekCurrent - fromSeconds)
                    MemoryDiagnostics.event("preview.audio.startPlayback.seek.end", "startId=\(startId) postSeekCurrent=\(postSeekCurrent) target=\(fromSeconds) postSeekDriftMs=\(postSeekDrift * 1000) finished=\(finished)")
                    #endif

                    switch self.resolvedStartMode {
                    case .immediatePrimed:
                        #if DEBUG
                        MemoryDiagnostics.event("preview.audio.startPlayback.schedule", "startId=\(startId) mode=playImmediatelyAfterSeek target=\(fromSeconds)")
                        #endif

                        self.startPlaybackNow(capturedPlayer, rate: 1.0)

                    case .scheduled:
                        let freshHostClockTime = VideoFrameProvider.scheduledHostClockTime(
                            forTransportHostTime: CACurrentMediaTime()
                        )
                        self.schedulePlayback(capturedPlayer, rate: 1.0, time: targetTime, hostTime: freshHostClockTime)
                    }

                    #if DEBUG
                    MemoryDiagnostics.event("preview.audio.startPlayback.scheduled", "startId=\(startId) \(self.playerSnapshot())")
                    self.scheduleDebugProbes(startId: startId, player: capturedPlayer, target: fromSeconds)
                    #endif
                }
            }
        }
    }

    #if DEBUG
    private func scheduleDebugProbes(startId: UInt, player probePlayer: AVPlayer, target probeTarget: Double) {
        let probeToken = readinessToken
        for delayMs in [100, 500, 1000, 2000] {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
                guard let self,
                      self.readinessToken == probeToken,
                      self.debugStartSequence == startId,
                      self.player === probePlayer else { return }
                let current = CMTimeGetSeconds(probePlayer.currentTime())
                let advanced = current - probeTarget
                let item = probePlayer.currentItem
                let itemStatus: String = {
                    switch item?.status {
                    case .readyToPlay: return "readyToPlay"
                    case .failed: return "failed"
                    case .unknown: return "unknown"
                    case .none: return "nil"
                    @unknown default: return "other"
                    }
                }()
                let err = item?.error?.localizedDescription ?? "none"
                MemoryDiagnostics.event("preview.audio.startPlayback.probe", "startId=\(startId) afterMs=\(delayMs) rate=\(probePlayer.rate) timeControl=\(probePlayer.timeControlStatus.rawValue) current=\(current) advancedMs=\(advanced * 1000) itemStatus=\(itemStatus) error=\(err)")
            }
        }
    }
    #endif

    func pause() {
        playbackStartToken &+= 1
        cancelPendingPrerollAndInvalidate()
        cancelPendingSeeks()
        #if DEBUG
        if let p = player {
            MemoryDiagnostics.event("preview.audio.pause", "rate=\(p.rate) timeControl=\(p.timeControlStatus.rawValue) current=\(CMTimeGetSeconds(p.currentTime())) itemStatus=\(p.currentItem?.status.rawValue ?? -1)")
        }
        #endif
        player?.pause()
    }

    func teardown() {
        playbackStartToken &+= 1
        cancelPendingSeeks()
        #if DEBUG
        if let p = player {
            MemoryDiagnostics.event("preview.audio.controller.teardown", "hasPlayer=1 rate=\(p.rate) timeControl=\(p.timeControlStatus.rawValue) current=\(CMTimeGetSeconds(p.currentTime())) readiness=\(readiness) itemStatus=\(p.currentItem?.status.rawValue ?? -1)")
        } else {
            MemoryDiagnostics.event("preview.audio.controller.teardown", "hasPlayer=0")
        }
        #endif
        resetPlayer()
        onReady = nil
        onPrerollFinished = nil
        onFailure = nil
    }

    #if DEBUG
    var hasActiveStatusObservation: Bool { statusObservation != nil }
    #endif
}
