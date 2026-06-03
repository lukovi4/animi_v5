@preconcurrency import AVFoundation

// MARK: - Engine Preview Audio Playback Controller

/// `PreviewAudioControlling` implementation using AVAudioEngine + AVAudioPlayerNode.
///
/// Offline-renders the composition to a PCM file via AVAssetReader, then plays
/// with AVAudioPlayerNode for sub-ms start latency. Export path stays unchanged.
@MainActor
final class EnginePreviewAudioPlaybackController: PreviewAudioControlling {

    // MARK: - State

    private(set) var readiness: PreviewAudioReadiness = .idle
    var onReady: (@MainActor () -> Void)?
    var onFailure: (@MainActor (PreviewAudioFailureReason) -> Void)?
    var onPrepareFinished: (@MainActor (PreviewAudioPrepareResult) -> Void)?

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioFile: AVAudioFile?
    private var cacheFileURL: URL?
    private var renderTask: Task<Void, Never>?
    private var readinessToken: UInt = 0

    #if DEBUG
    var onRenderComplete: ((URL) -> Void)?
    var onEngineStart: (() -> Void)?
    var onScheduleSegment: ((AVAudioFramePosition, AVAudioFrameCount) -> Void)?
    var onPlayerPlay: (() -> Void)?
    var onProbe: ((Int) -> Void)?
    private var probeToken: UInt = 0
    private var lastTargetHostTime: CFTimeInterval = 0
    #endif

    var hasActivePipeline: Bool { audioFile != nil || renderTask != nil }

    // MARK: - Render Format

    private static let renderSampleRate: Double = 44100.0
    private static let renderChannels: AVAudioChannelCount = 2

    private nonisolated static var renderFormat: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: renderSampleRate,
            channels: renderChannels,
            interleaved: true
        )!
    }

    private nonisolated static var readerOutputSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: renderSampleRate,
            AVNumberOfChannelsKey: renderChannels,
        ]
    }

    // MARK: - Failure Transition

    private func transitionToFailed(_ reason: PreviewAudioFailureReason) {
        guard readiness != .failed else { return }
        readiness = .failed
        #if DEBUG
        MemoryDiagnostics.event("preview.audio.engine.failure", "reason=\(reason)")
        #endif
        onReady = nil
        onPrepareFinished = nil
        onFailure?(reason)
    }

    // MARK: - Replace Pipeline

    func replacePipeline(_ pipeline: BuiltAudioPipeline) {
        renderTask?.cancel()
        renderTask = nil
        deleteCacheFile()
        engine?.stop()
        engine = nil
        playerNode = nil
        audioFile = nil
        readiness = .preparing

        readinessToken &+= 1
        let token = readinessToken
        let comp = pipeline.composition as AVComposition
        let mix = pipeline.audioMix

        #if DEBUG
        let tracks = pipeline.composition.tracks(withMediaType: .audio).count
        let dur = CMTimeGetSeconds(pipeline.composition.duration)
        MemoryDiagnostics.event("preview.audio.engine.render.begin", "generation=\(token) tracks=\(tracks) duration=\(dur)")
        #endif

        renderTask = Task.detached { [weak self] in
            let fileURL: URL
            do {
                fileURL = try Self.renderToFile(composition: comp, audioMix: mix)
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    guard let self, self.readinessToken == token else { return }
                    self.renderTask = nil
                    #if DEBUG
                    MemoryDiagnostics.event("preview.audio.engine.render.cancelled", "")
                    #endif
                }
                return
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.readinessToken == token else { return }
                    self.renderTask = nil
                    #if DEBUG
                    MemoryDiagnostics.event("preview.audio.engine.render.failed", "error=\(error.localizedDescription)")
                    #endif
                    self.transitionToFailed(.renderFailed(error: error.localizedDescription))
                }
                return
            }
            await MainActor.run { [weak self] in
                guard let self, self.readinessToken == token else {
                    try? FileManager.default.removeItem(at: fileURL)
                    return
                }
                self.renderTask = nil
                self.cacheFileURL = fileURL

                #if DEBUG
                self.onRenderComplete?(fileURL)
                #endif

                do {
                    let file = try AVAudioFile(forReading: fileURL)
                    self.audioFile = file
                    #if DEBUG
                    let frames = file.length
                    let sr = file.processingFormat.sampleRate
                    let ch = file.processingFormat.channelCount
                    MemoryDiagnostics.event("preview.audio.engine.render.end", "durationMs=\(Double(frames) / sr * 1000) frames=\(frames) sampleRate=\(sr) channels=\(ch)")
                    MemoryDiagnostics.event("preview.audio.engine.ready", "generation=\(token)")
                    #endif
                    self.readiness = .ready
                    let cb = self.onReady
                    self.onReady = nil
                    cb?()
                } catch {
                    #if DEBUG
                    MemoryDiagnostics.event("preview.audio.engine.render.failed", "error=\(error.localizedDescription)")
                    #endif
                    self.transitionToFailed(.renderFailed(error: error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Prepare for Immediate Playback

    func prepareForImmediatePlayback() {
        guard readiness == .ready else { return }
        guard let file = audioFile else { return }

        let eng = AVAudioEngine()
        let node = AVAudioPlayerNode()
        eng.attach(node)
        eng.connect(node, to: eng.mainMixerNode, format: file.processingFormat)
        eng.prepare()

        self.engine = eng
        self.playerNode = node

        #if DEBUG
        MemoryDiagnostics.event("preview.audio.engine.prepare", "nodeAttached=1")
        #endif

        readiness = .primed
        let cb = onPrepareFinished
        onPrepareFinished = nil
        cb?(.primed)
    }

    // MARK: - Start Playback

    func startPlayback(fromSeconds: Double, hostTime: CFTimeInterval) {
        guard readiness == .primed else {
            #if DEBUG
            MemoryDiagnostics.event("preview.audio.engine.startPlayback.notPrimed", "readiness=\(readiness)")
            #endif
            return
        }
        guard let eng = engine, let node = playerNode, let file = audioFile else { return }

        // Start engine if not running (requires active audio session)
        if !eng.isRunning {
            #if DEBUG
            let startTime = CACurrentMediaTime()
            MemoryDiagnostics.event("preview.audio.engine.start.begin", "")
            #endif
            do {
                try eng.start()
                #if DEBUG
                let durationMs = (CACurrentMediaTime() - startTime) * 1000
                MemoryDiagnostics.event("preview.audio.engine.start.end", "durationMs=\(durationMs) ok=1")
                onEngineStart?()
                #endif
            } catch {
                #if DEBUG
                let durationMs = (CACurrentMediaTime() - startTime) * 1000
                MemoryDiagnostics.event("preview.audio.engine.start.end", "durationMs=\(durationMs) ok=0 error=\(error.localizedDescription)")
                #endif
                transitionToFailed(.playerFailed(error: error.localizedDescription))
                return
            }
        }

        node.stop()

        let sampleRate = file.processingFormat.sampleRate
        let totalFrames = file.length
        let now = CACurrentMediaTime()

        guard let timing = Self.makePlaybackTiming(
            fromSeconds: fromSeconds,
            anchorHostTime: hostTime,
            now: now,
            sampleRate: sampleRate,
            totalFrames: totalFrames
        ) else { return }

        #if DEBUG
        MemoryDiagnostics.event("preview.audio.engine.scheduleSegment", "target=\(fromSeconds) frame=\(timing.startFrame) remaining=\(timing.remainingFrames) catchUpMs=\(timing.catchUpSeconds * 1000) effectiveStart=\(timing.effectiveStartSeconds)")
        onScheduleSegment?(timing.startFrame, timing.remainingFrames)
        #endif

        node.scheduleSegment(file, startingFrame: timing.startFrame, frameCount: timing.remainingFrames, at: nil)

        let playTime = AVAudioTime(hostTime: timing.playHostTime)
        node.play(at: playTime)

        #if DEBUG
        lastTargetHostTime = timing.targetHostTime
        MemoryDiagnostics.event("preview.audio.engine.play", "startFrame=\(timing.startFrame) targetHostTime=\(timing.targetHostTime) catchUpMs=\(timing.catchUpSeconds * 1000)")
        onPlayerPlay?()
        scheduleDebugProbes(startFrame: timing.startFrame, sampleRate: sampleRate, node: node)
        #endif
    }

    // MARK: - Debug Probes

    #if DEBUG
    private func scheduleDebugProbes(startFrame: AVAudioFramePosition, sampleRate: Double, node: AVAudioPlayerNode) {
        probeToken &+= 1
        let token = probeToken
        let capturedReadinessToken = readinessToken
        for delayMs in [100, 500, 1000, 2000] {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
                guard let self,
                      self.probeToken == token,
                      self.readinessToken == capturedReadinessToken,
                      self.playerNode === node else { return }
                if let nodeTime = node.lastRenderTime,
                   let playerTime = node.playerTime(forNodeTime: nodeTime),
                   playerTime.isSampleTimeValid {
                    let advancedMs = Double(playerTime.sampleTime) / playerTime.sampleRate * 1000
                    let expectedMs = max(0, CACurrentMediaTime() - self.lastTargetHostTime) * 1000
                    let driftMs = advancedMs - expectedMs
                    MemoryDiagnostics.event("preview.audio.engine.probe", "afterMs=\(delayMs) advancedMs=\(advancedMs) expectedMs=\(expectedMs) driftMs=\(driftMs) sampleTime=\(playerTime.sampleTime) startFrame=\(startFrame) rate=\(playerTime.sampleRate)")
                } else {
                    MemoryDiagnostics.event("preview.audio.engine.probe", "afterMs=\(delayMs) advancedMs=n/a sampleTime=n/a rate=n/a")
                }
                self.onProbe?(delayMs)
            }
        }
    }
    #endif

    // MARK: - Reprepare for Route Change

    func reprepareForRouteChange() {
        guard readiness == .primed || readiness == .ready else { return }
        guard let file = audioFile else { return }

        // Tear down old engine graph
        playerNode?.stop()
        engine?.stop()
        engine = nil
        playerNode = nil

        // Rebuild fresh engine + player node
        let eng = AVAudioEngine()
        let node = AVAudioPlayerNode()
        eng.attach(node)
        eng.connect(node, to: eng.mainMixerNode, format: file.processingFormat)
        eng.prepare()

        self.engine = eng
        self.playerNode = node
        readiness = .primed

        #if DEBUG
        MemoryDiagnostics.event("preview.audio.engine.reprepareForRouteChange", "nodeAttached=1")
        #endif
    }

    // MARK: - Pause

    /// Warm interactive pause for the `Pause` / `scrub .began` handoff. Silences
    /// output quickly WITHOUT tearing down the audio HAL: pauses the player node
    /// and the engine (Apple `AVAudioEngine.pause()` keeps prepared resources, so
    /// resume is fast). Readiness stays `.primed`; the next `startPlayback` reuses
    /// the engine. This is a pause, NOT a teardown — no `stop()` here.
    func pausePlaybackImmediately() {
        playerNode?.pause()
        engine?.pause()
        #if DEBUG
        probeToken &+= 1
        MemoryDiagnostics.event("preview.audio.engine.pauseImmediate", "warm=1")
        #endif
    }

    /// Teardown-style pause: stops the player node and the engine, releasing
    /// prepared engine resources. Reserved for idle reclaim / teardown paths
    /// (NOT the immediate Pause/scrub handoff). Graph/file/cache stay alive and
    /// readiness stays `.primed`; the next `startPlayback` re-`start()`s the engine.
    func pause() {
        let wasRunning = engine?.isRunning == true
        playerNode?.stop()
        engine?.stop()
        #if DEBUG
        probeToken &+= 1
        MemoryDiagnostics.event("preview.audio.engine.pause", "engineWasRunning=\(wasRunning ? 1 : 0)")
        #endif
        // graph/file/cache stay alive; readiness stays .primed
        // next startPlayback() will call engine.start() after session activation
    }

    // MARK: - Teardown

    func teardown() {
        readinessToken &+= 1
        #if DEBUG
        probeToken &+= 1
        MemoryDiagnostics.event("preview.audio.engine.teardown", "")
        #endif
        playerNode?.stop()
        engine?.stop()
        engine = nil
        playerNode = nil
        audioFile = nil
        renderTask?.cancel()
        renderTask = nil
        deleteCacheFile()
        readiness = .idle
        onReady = nil
        onPrepareFinished = nil
        onFailure = nil
    }

    // MARK: - Offline Render

    private nonisolated static func renderToFile(
        composition: AVComposition,
        audioMix: AVAudioMix?
    ) throws -> URL {
        let reader = try AVAssetReader(asset: composition)

        let audioTracks = composition.tracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw NSError(domain: "EnginePreviewAudio", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No audio tracks in composition",
            ])
        }

        let output = AVAssetReaderAudioMixOutput(
            audioTracks: audioTracks,
            audioSettings: readerOutputSettings
        )
        output.audioMix = audioMix

        guard reader.canAdd(output) else {
            throw NSError(domain: "EnginePreviewAudio", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Cannot add audio mix output to reader",
            ])
        }
        reader.add(output)

        guard reader.startReading() else {
            throw NSError(domain: "EnginePreviewAudio", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Reader failed to start: \(reader.error?.localizedDescription ?? "unknown")",
            ])
        }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine_preview_\(UUID().uuidString).caf")

        let format = renderFormat
        let audioFile = try AVAudioFile(
            forWriting: fileURL,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: true
        )

        while reader.status == .reading {
            guard !Task.isCancelled else {
                reader.cancelReading()
                try? FileManager.default.removeItem(at: fileURL)
                throw CancellationError()
            }

            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                break
            }

            let pcmBuffer = try convertToPCMBuffer(sampleBuffer, format: format)
            try audioFile.write(from: pcmBuffer)
        }

        if reader.status == .failed {
            try? FileManager.default.removeItem(at: fileURL)
            throw NSError(domain: "EnginePreviewAudio", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Reader failed: \(reader.error?.localizedDescription ?? "unknown")",
            ])
        }

        return fileURL
    }

    // MARK: - CMSampleBuffer → AVAudioPCMBuffer

    private nonisolated static func convertToPCMBuffer(
        _ sampleBuffer: CMSampleBuffer,
        format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            throw NSError(domain: "EnginePreviewAudio", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create AVAudioPCMBuffer",
            ])
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        try sampleBuffer.withAudioBufferList(
            flags: .audioBufferListAssure16ByteAlignment
        ) { srcBufferList, blockBuffer in
            try withExtendedLifetime(blockBuffer) {
                try copyAudioBufferList(srcBufferList, to: pcmBuffer)
            }
        }

        return pcmBuffer
    }

    /// Copies audio data from source AudioBufferList into destination AVAudioPCMBuffer.
    /// Validates buffer counts and sizes before copying.
    nonisolated static func copyAudioBufferList(
        _ sourceList: UnsafeMutableAudioBufferListPointer,
        to pcmBuffer: AVAudioPCMBuffer
    ) throws {
        let dst = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)

        guard sourceList.count == dst.count else {
            throw NSError(domain: "EnginePreviewAudio", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "Buffer count mismatch: source \(sourceList.count) vs destination \(dst.count)",
            ])
        }

        for i in 0..<sourceList.count {
            guard let srcData = sourceList[i].mData, let dstData = dst[i].mData else {
                throw NSError(domain: "EnginePreviewAudio", code: 8, userInfo: [
                    NSLocalizedDescriptionKey: "Nil mData at buffer index \(i)",
                ])
            }
            guard sourceList[i].mDataByteSize <= dst[i].mDataByteSize else {
                throw NSError(domain: "EnginePreviewAudio", code: 9, userInfo: [
                    NSLocalizedDescriptionKey: "Source buffer[\(i)] size \(sourceList[i].mDataByteSize) exceeds destination \(dst[i].mDataByteSize)",
                ])
            }
            memcpy(dstData, srcData, Int(sourceList[i].mDataByteSize))
            dst[i].mDataByteSize = sourceList[i].mDataByteSize
        }
    }

    // MARK: - Playback Timing

    struct PlaybackTiming {
        let startFrame: AVAudioFramePosition
        let remainingFrames: AVAudioFrameCount
        let playHostTime: UInt64
        let targetHostTime: CFTimeInterval
        let effectiveStartSeconds: Double
        let catchUpSeconds: Double
    }

    static func makePlaybackTiming(
        fromSeconds: Double,
        anchorHostTime: CFTimeInterval,
        now: CFTimeInterval,
        sampleRate: Double,
        totalFrames: AVAudioFramePosition,
        scheduleLeadTime: CFTimeInterval = 0.02
    ) -> PlaybackTiming? {
        let targetHostTime = max(anchorHostTime, now + scheduleLeadTime)
        let catchUpSeconds = max(0, targetHostTime - anchorHostTime)
        let effectiveStartSeconds = fromSeconds + catchUpSeconds

        let rawFrame = AVAudioFramePosition(effectiveStartSeconds * sampleRate)
        guard rawFrame >= 0, rawFrame < totalFrames else { return nil }
        let remaining = totalFrames - rawFrame

        let playHostTime = AVAudioTime.hostTime(forSeconds: targetHostTime)

        return PlaybackTiming(
            startFrame: rawFrame,
            remainingFrames: AVAudioFrameCount(remaining),
            playHostTime: playHostTime,
            targetHostTime: targetHostTime,
            effectiveStartSeconds: effectiveStartSeconds,
            catchUpSeconds: catchUpSeconds
        )
    }

    // MARK: - Cache File

    private func deleteCacheFile() {
        if let url = cacheFileURL {
            try? FileManager.default.removeItem(at: url)
            cacheFileURL = nil
        }
    }
}
