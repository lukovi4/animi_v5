import AVFoundation

// MARK: - Audio Writer Pump

/// Pumps audio from AVAssetReader to AVAssetWriterInput using requestMediaDataWhenReady.
///
/// Owns its own dispatch queue. Does not block any external queue.
/// Audio pump owns markAsFinished() — calls it on EOF.
final class AudioWriterPump {

    // MARK: - State

    private var reader: AVAssetReader?
    private var output: AVAssetReaderAudioMixOutput?
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var isFinished = false
    private var completionCalled = false
    private var completionBlock: (() -> Void)?

    // MARK: - Init

    init(queue: DispatchQueue = DispatchQueue(label: "com.animi.audiowriterpump")) {
        self.queue = queue
    }

    // MARK: - Start

    /// Starts the audio pump.
    ///
    /// Reads from composition, writes to audioInput on pump's own queue via requestMediaDataWhenReady.
    /// Calls completion exactly once when done (success, error, or cancel).
    ///
    /// - Parameters:
    ///   - composition: Audio composition to read from
    ///   - audioMix: Optional audio mix for volume control
    ///   - audioInput: Writer input to append samples to (protocol for testability)
    ///   - onError: Error callback (first-error-wins in pipeline)
    ///   - completion: Called exactly once when pump finishes
    func start(
        composition: AVComposition,
        audioMix: AVAudioMix?,
        audioInput: WriterInputScheduling,
        onError: @escaping (Error) -> Void,
        completion: @escaping () -> Void
    ) {
        // Create reader
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: composition)
        } catch {
            onError(VideoExportError.audioReaderStartFailed(error))
            completion()
            return
        }

        // Create audio mix output
        let audioTracks = composition.tracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            completion()
            return
        }

        let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: nil)
        output.audioMix = audioMix

        guard reader.canAdd(output) else {
            onError(VideoExportError.audioReaderStartFailed(nil))
            completion()
            return
        }
        reader.add(output)

        guard reader.startReading() else {
            onError(VideoExportError.audioReaderStartFailed(reader.error))
            completion()
            return
        }

        self.reader = reader
        self.output = output

        lock.lock()
        self.completionBlock = completion
        lock.unlock()

        // Register readiness-driven callback on pump's own queue
        audioInput.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard let self else { return }

            while audioInput.isReadyForMoreMediaData {
                // Check if cancelled
                self.lock.lock()
                let finished = self.isFinished
                self.lock.unlock()
                if finished { return }

                // Read next sample
                guard let sampleBuffer = output.copyNextSampleBuffer() else {
                    // EOF or error
                    if reader.status == .completed {
                        audioInput.markAsFinished()
                    } else {
                        onError(VideoExportError.audioReaderStartFailed(reader.error))
                    }
                    self.callCompletion()
                    return
                }

                // Append sample
                let ok = audioInput.append(sampleBuffer)
                if !ok {
                    onError(VideoExportError.audioAppendFailed(nil))
                    self.callCompletion()
                    return
                }
            }
        }
    }

    // MARK: - Cancel

    /// Cancels the pump. Completion is called if not yet called.
    func cancel() {
        lock.lock()
        isFinished = true
        lock.unlock()

        reader?.cancelReading()
        reader = nil
        output = nil
        callCompletion()
    }

    // MARK: - Private

    private func callCompletion() {
        lock.lock()
        let shouldCall = !completionCalled
        completionCalled = true
        isFinished = true
        let cb = completionBlock
        completionBlock = nil
        lock.unlock()

        if shouldCall {
            cb?()
        }
    }
}
