import AVFoundation
import CoreVideo

/// Owns AVAssetWriter lifecycle, both pumps, and serves as the sole error aggregator
/// for the export pipeline. Replaces scattered writer setup and `_exportError` in VideoExporter.
final class ExportWriterPipeline {

    struct VideoConfig {
        let sizePx: (width: Int, height: Int)
        let fps: Int
        let bitrate: Int
        let gopSeconds: Int
    }

    struct AudioConfig {
        let composition: AVComposition
        let audioMix: AVAudioMix?
    }

    // MARK: - Owned Resources

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var videoPump: VideoWriterPump!
    private let audioInput: AVAssetWriterInput?
    private let audioPump: AudioWriterPump?
    private let audioComposition: AVComposition?
    private let audioMix: AVAudioMix?

    // MARK: - Writer Start Diagnostics

    #if DEBUG
    private let videoConfig: VideoConfig
    private static var writerStartCounter = 0
    private static let writerStartLock = NSLock()
    #endif

    // MARK: - Error Aggregator (first-error-wins)

    private let errorLock = NSLock()
    private var _firstError: Error?

    // MARK: - Pump Completion Tracking

    private let completionLock = NSLock()
    private var pumpsFinished = 0
    private let expectedPumps: Int
    private var allPumpsCallback: (() -> Void)?

    // MARK: - Init

    /// Creates writer, inputs, adaptor, and pumps. Does NOT start writing.
    init(outputURL: URL, video: VideoConfig, audio: AudioConfig?) throws {
        #if DEBUG
        let initStartNs = DispatchTime.now().uptimeNanoseconds
        #endif

        // 1. AVAssetWriter
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        #if DEBUG
        let writerCreateNs = DispatchTime.now().uptimeNanoseconds
        #endif

        // 2. Video input
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: video.sizePx.width,
            AVVideoHeightKey: video.sizePx.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: video.bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: video.fps * video.gopSeconds,
                AVVideoExpectedSourceFrameRateKey: video.fps
            ]
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false

        guard writer.canAdd(videoInput) else {
            throw VideoExportError.cannotAddVideoInput
        }
        writer.add(videoInput)

        #if DEBUG
        let videoInputNs = DispatchTime.now().uptimeNanoseconds
        #endif

        // 3. Pixel buffer adaptor
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: video.sizePx.width,
            kCVPixelBufferHeightKey as String: video.sizePx.height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )

        #if DEBUG
        let adaptorNs = DispatchTime.now().uptimeNanoseconds
        #endif

        // 4. Audio input (optional)
        var audioWriterInput: AVAssetWriterInput?
        var audioPumpInstance: AudioWriterPump?
        var numPumps = 1
        var storedComposition: AVComposition?
        var storedMix: AVAudioMix?

        if let audioConfig = audio {
            let hasAudioTracks = !audioConfig.composition.tracks(withMediaType: .audio).isEmpty
            #if DEBUG
            let audioTrackCount = audioConfig.composition.tracks(withMediaType: .audio).count
            let audioDuration = audioConfig.composition.duration.seconds
            let audioMixInputCount = audioConfig.audioMix?.inputParameters.count ?? 0
            MemoryDiagnostics.event("export.writer.audioConfig", "requested=1 tracks=\(audioTrackCount) duration=\(String(format: "%.2f", audioDuration)) mixInputs=\(audioMixInputCount) expectedAudio=\(hasAudioTracks ? 1 : 0)")
            #endif
            if hasAudioTracks {
                let aacSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 128000
                ]

                let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
                aInput.expectsMediaDataInRealTime = false

                guard writer.canAdd(aInput) else {
                    #if DEBUG
                    MemoryDiagnostics.event("export.writer.audioInput.canAddFail", "")
                    #endif
                    throw VideoExportError.cannotAddAudioInput
                }
                writer.add(aInput)
                audioWriterInput = aInput
                audioPumpInstance = AudioWriterPump()
                numPumps = 2
                storedComposition = audioConfig.composition
                storedMix = audioConfig.audioMix
                #if DEBUG
                MemoryDiagnostics.event("export.writer.audioInput", "added=1")
                #endif
            } else {
                #if DEBUG
                MemoryDiagnostics.event("export.writer.audioInput", "added=0 reason=noTracks")
                #endif
            }
        } else {
            #if DEBUG
            MemoryDiagnostics.event("export.writer.audioConfig", "requested=0 tracks=0 duration=0 mixInputs=0 expectedAudio=0")
            #endif
        }

        #if DEBUG
        let audioInputNs = DispatchTime.now().uptimeNanoseconds
        #endif

        // Store all properties before creating videoPump (which needs self for onError)
        self.writer = writer
        self.videoInput = videoInput
        self.adaptor = adaptor
        self.audioInput = audioWriterInput
        self.audioPump = audioPumpInstance
        self.expectedPumps = numPumps
        self.audioComposition = storedComposition
        self.audioMix = storedMix
        #if DEBUG
        self.videoConfig = video
        #endif

        // 5. Video pump — onError wired to self.setError
        let videoQueue = DispatchQueue(label: "com.animi.videowriterpump")
        self.videoPump = VideoWriterPump(
            input: videoInput,
            adaptor: adaptor,
            queue: videoQueue,
            onError: { [weak self] error in
                self?.setError(error)
            }
        )

        #if DEBUG
        let initEndNs = DispatchTime.now().uptimeNanoseconds
        MemoryDiagnostics.event(
            "export.writer.init.summary",
            String(format: "writerCreate=%.2fs videoInput=%.2fs adaptor=%.2fs audioInput=%.2fs pump=%.2fs total=%.2fs",
                   Double(writerCreateNs - initStartNs) / 1e9,
                   Double(videoInputNs - writerCreateNs) / 1e9,
                   Double(adaptorNs - videoInputNs) / 1e9,
                   Double(audioInputNs - adaptorNs) / 1e9,
                   Double(initEndNs - audioInputNs) / 1e9,
                   Double(initEndNs - initStartNs) / 1e9)
        )
        #endif
    }

    // MARK: - Public API

    /// Start writing session and both pumps.
    func startWriting() throws {
        #if DEBUG
        let startNs = DispatchTime.now().uptimeNanoseconds

        let writerStartIndex: Int
        let firstWriterInProcess: Bool
        Self.writerStartLock.lock()
        writerStartIndex = Self.writerStartCounter
        firstWriterInProcess = Self.writerStartCounter == 0
        Self.writerStartCounter += 1
        Self.writerStartLock.unlock()

        let outputExists = FileManager.default.fileExists(atPath: writer.outputURL.path)
        MemoryDiagnostics.event(
            "export.writer.startWriting.begin",
            String(format: "writerStartIndex=%d firstWriterInProcess=%d outputExists=%d size=%dx%d fps=%d bitrate=%d hasAudio=%d writerStatus=%ld",
                   writerStartIndex,
                   firstWriterInProcess ? 1 : 0,
                   outputExists ? 1 : 0,
                   videoConfig.sizePx.width, videoConfig.sizePx.height,
                   videoConfig.fps,
                   videoConfig.bitrate,
                   audioPump != nil ? 1 : 0,
                   writer.status.rawValue)
        )
        #endif

        guard writer.startWriting() else {
            #if DEBUG
            MemoryDiagnostics.event(
                "export.writer.startWriting.end",
                String(format: "writerStartIndex=%d duration=%.3fs writerStatus=%ld error=%@",
                       writerStartIndex,
                       Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1e9,
                       writer.status.rawValue,
                       writer.error?.localizedDescription ?? "none")
            )
            #endif
            throw VideoExportError.writerStartFailed(writer.error)
        }

        #if DEBUG
        let writerStartNs = DispatchTime.now().uptimeNanoseconds
        MemoryDiagnostics.event(
            "export.writer.startWriting.end",
            String(format: "writerStartIndex=%d duration=%.3fs writerStatus=%ld error=none",
                   writerStartIndex,
                   Double(writerStartNs - startNs) / 1e9,
                   writer.status.rawValue)
        )
        #endif

        writer.startSession(atSourceTime: .zero)

        #if DEBUG
        let sessionNs = DispatchTime.now().uptimeNanoseconds
        #endif

        videoPump.start()

        #if DEBUG
        let videoPumpNs = DispatchTime.now().uptimeNanoseconds
        #endif

        if let audioPump = audioPump,
           let audioInput = audioInput,
           let composition = audioComposition {
            audioPump.start(
                composition: composition,
                audioMix: audioMix,
                audioInput: audioInput,
                onError: { [weak self] error in self?.setError(error) },
                completion: { [weak self] in self?.onPumpFinished() }
            )
        }

        #if DEBUG
        let endNs = DispatchTime.now().uptimeNanoseconds
        MemoryDiagnostics.event(
            "export.writer.start.summary",
            String(format: "writerStart=%.2fs session=%.2fs videoPump=%.2fs audioPump=%.2fs total=%.2fs",
                   Double(writerStartNs - startNs) / 1e9,
                   Double(sessionNs - writerStartNs) / 1e9,
                   Double(videoPumpNs - sessionNs) / 1e9,
                   Double(endNs - videoPumpNs) / 1e9,
                   Double(endNs - startNs) / 1e9)
        )
        #endif
    }

    /// Pixel buffer pool (available after startWriting).
    var pixelBufferPool: CVPixelBufferPool? {
        adaptor.pixelBufferPool
    }

    /// Enqueue video frame. Completion called after append.
    /// Accepts ONLY CVPixelBuffer + CMTime — no InFlightFrame, no CVMetalTexture.
    func enqueueVideoFrame(
        _ pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime,
        completion: @escaping () -> Void
    ) {
        videoPump.enqueue(pixelBuffer, presentationTime: presentationTime, completion: completion)
    }

    /// Report error (from render loop, pump, or coordinator). First-error-wins.
    func setError(_ error: Error) {
        errorLock.lock()
        let isFirst = _firstError == nil
        if isFirst {
            _firstError = error
        }
        errorLock.unlock()
        #if DEBUG
        MemoryDiagnostics.event("export.pipeline.error", "first=\(isFirst ? 1 : 0) error=\(error.localizedDescription)")
        #endif
    }

    /// Current first error. Thread-safe read.
    var firstError: Error? {
        errorLock.lock()
        defer { errorLock.unlock() }
        return _firstError
    }

    /// Finish: signal video done -> wait both pumps -> finishWriting.
    func finishWriting(completion: @escaping (Result<URL, Error>) -> Void) {
        let outputURL = writer.outputURL

        videoPump.finishEnqueuing { [self] in
            self.onPumpFinished { [self] in
                #if DEBUG
                MemoryDiagnostics.event("export.pipeline.finish.begin", "firstError=\(self.firstError?.localizedDescription ?? "none")")
                #endif

                if let error = self.firstError {
                    self.writer.cancelWriting()
                    try? FileManager.default.removeItem(at: outputURL)
                    completion(.failure(error))
                    return
                }

                self.writer.finishWriting {
                    #if DEBUG
                    MemoryDiagnostics.event("export.pipeline.finish.end", "ok=\(self.writer.status == .completed ? 1 : 0) writerStatus=\(self.writer.status.rawValue) error=\(self.writer.error?.localizedDescription ?? "none")")
                    #endif
                    if self.writer.status == .completed {
                        completion(.success(outputURL))
                    } else {
                        try? FileManager.default.removeItem(at: outputURL)
                        completion(.failure(VideoExportError.finishFailed(self.writer.error)))
                    }
                }
            }
        }
    }

    deinit {
        #if DEBUG
        MemoryDiagnostics.event("ExportWriterPipeline.deinit", "obj=\(ObjectIdentifier(self).hashValue)")
        #endif
    }

    /// Cancel: stop pumps, cancel writer, delete file.
    func cancel() {
        #if DEBUG
        MemoryDiagnostics.event("ExportWriterPipeline.cancel", "obj=\(ObjectIdentifier(self).hashValue)")
        #endif
        let outputURL = writer.outputURL
        videoPump.cancel()
        audioPump?.cancel()
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: outputURL)
    }

    // MARK: - Private

    /// Called when a pump finishes. When all pumps are done, fires the allPumpsCallback.
    private func onPumpFinished(callback: (() -> Void)? = nil) {
        completionLock.lock()
        pumpsFinished += 1
        let currentCount = pumpsFinished
        if let callback = callback {
            allPumpsCallback = callback
        }
        let done = pumpsFinished >= expectedPumps
        let cb = done ? allPumpsCallback : nil
        if done { allPumpsCallback = nil }
        completionLock.unlock()

        #if DEBUG
        MemoryDiagnostics.event("export.pipeline.pumpFinished", "count=\(currentCount)/\(expectedPumps)")
        #endif

        if done {
            cb?()
        }
    }
}
