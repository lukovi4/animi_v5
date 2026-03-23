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
        // 1. AVAssetWriter
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

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

        // 4. Audio input (optional)
        var audioWriterInput: AVAssetWriterInput?
        var audioPumpInstance: AudioWriterPump?
        var numPumps = 1
        var storedComposition: AVComposition?
        var storedMix: AVAudioMix?

        if let audioConfig = audio {
            let hasAudioTracks = !audioConfig.composition.tracks(withMediaType: .audio).isEmpty
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
                    throw VideoExportError.cannotAddAudioInput
                }
                writer.add(aInput)
                audioWriterInput = aInput
                audioPumpInstance = AudioWriterPump()
                numPumps = 2
                storedComposition = audioConfig.composition
                storedMix = audioConfig.audioMix
            }
        }

        // Store all properties before creating videoPump (which needs self for onError)
        self.writer = writer
        self.videoInput = videoInput
        self.adaptor = adaptor
        self.audioInput = audioWriterInput
        self.audioPump = audioPumpInstance
        self.expectedPumps = numPumps
        self.audioComposition = storedComposition
        self.audioMix = storedMix

        // 5. Video pump — onError wired to self.setError
        let videoQueue = DispatchQueue(label: "com.animi.videowriterpump")
        self.videoPump = VideoWriterPump(
            input: videoInput,
            adaptor: adaptor,
            queue: videoQueue,
            onError: { [unowned self] error in
                self.setError(error)
            }
        )
    }

    // MARK: - Public API

    /// Start writing session and both pumps.
    func startWriting() throws {
        guard writer.startWriting() else {
            throw VideoExportError.writerStartFailed(writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        videoPump.start()

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
        if _firstError == nil {
            _firstError = error
        }
        errorLock.unlock()
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
                if let error = self.firstError {
                    self.writer.cancelWriting()
                    try? FileManager.default.removeItem(at: outputURL)
                    completion(.failure(error))
                    return
                }

                self.writer.finishWriting {
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

    /// Cancel: stop pumps, cancel writer, delete file.
    func cancel() {
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
        if let callback = callback {
            allPumpsCallback = callback
        }
        let done = pumpsFinished >= expectedPumps
        let cb = done ? allPumpsCallback : nil
        if done { allPumpsCallback = nil }
        completionLock.unlock()

        if done {
            cb?()
        }
    }
}
