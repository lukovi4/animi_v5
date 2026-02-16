import AVFoundation

// MARK: - Audio Writer Pump

/// Pumps audio from AVAssetReader to AVAssetWriterInput (PR-E4).
///
/// Reads mixed audio from composition and writes to writer's audio input.
/// Runs on writerQueue for synchronization with video appends.
///
/// Usage:
/// ```swift
/// let pump = AudioWriterPump()
/// pump.start(
///     composition: pipeline.composition,
///     audioMix: pipeline.audioMix,
///     audioInput: audioInput,
///     writerQueue: writerQueue,
///     backpressureTimeout: 3.0,
///     cancelCheck: { self.isCancelled() },
///     errorCheck: { self.exportError() },
///     setExportErrorOnce: { self.setExportErrorOnce($0) },
///     completion: { audioGroup.leave() }
/// )
/// ```
public final class AudioWriterPump {
    // MARK: - State

    private var reader: AVAssetReader?
    private var output: AVAssetReaderAudioMixOutput?
    private var isRunning = false

    // MARK: - Init

    public init() {}

    // MARK: - Start

    /// Starts the audio pump.
    ///
    /// Reads from composition, writes to audioInput on writerQueue.
    /// Calls completion when done (success or error).
    ///
    /// - Parameters:
    ///   - composition: Audio composition to read from
    ///   - audioMix: Optional audio mix for volume control
    ///   - audioInput: Writer input to append samples to
    ///   - writerQueue: Serial queue for all append operations
    ///   - backpressureTimeout: Timeout for isReadyForMoreMediaData wait
    ///   - cancelCheck: Returns true if export is cancelled
    ///   - errorCheck: Returns current export error (if any)
    ///   - setExportErrorOnce: Sets export error (first error wins)
    ///   - completion: Called when pump finishes (on writerQueue)
    public func start(
        composition: AVComposition,
        audioMix: AVAudioMix?,
        audioInput: AVAssetWriterInput,
        writerQueue: DispatchQueue,
        backpressureTimeout: Double,
        cancelCheck: @escaping () -> Bool,
        errorCheck: @escaping () -> Error?,
        setExportErrorOnce: @escaping (Error) -> Void,
        completion: @escaping () -> Void
    ) {
        // Create reader
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: composition)
        } catch {
            setExportErrorOnce(VideoExportError.audioReaderStartFailed(error))
            completion()
            return
        }

        // Create audio mix output
        let audioTracks = composition.tracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            // No audio tracks - nothing to pump
            completion()
            return
        }

        // Output settings for PCM (let writer encode to AAC)
        let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: nil)
        output.audioMix = audioMix

        guard reader.canAdd(output) else {
            setExportErrorOnce(VideoExportError.audioReaderStartFailed(nil))
            completion()
            return
        }
        reader.add(output)

        guard reader.startReading() else {
            setExportErrorOnce(VideoExportError.audioReaderStartFailed(reader.error))
            completion()
            return
        }

        self.reader = reader
        self.output = output
        self.isRunning = true

        // Run pump loop on writerQueue
        writerQueue.async { [weak self] in
            self?.pumpLoop(
                reader: reader,
                output: output,
                audioInput: audioInput,
                backpressureTimeout: backpressureTimeout,
                cancelCheck: cancelCheck,
                errorCheck: errorCheck,
                setExportErrorOnce: setExportErrorOnce,
                completion: completion
            )
        }
    }

    // MARK: - Cancel

    /// Cancels the pump.
    public func cancel() {
        reader?.cancelReading()
        reader = nil
        output = nil
        isRunning = false
    }

    // MARK: - Private: Pump Loop

    private func pumpLoop(
        reader: AVAssetReader,
        output: AVAssetReaderAudioMixOutput,
        audioInput: AVAssetWriterInput,
        backpressureTimeout: Double,
        cancelCheck: @escaping () -> Bool,
        errorCheck: @escaping () -> Error?,
        setExportErrorOnce: @escaping (Error) -> Void,
        completion: @escaping () -> Void
    ) {
        defer {
            self.reader = nil
            self.output = nil
            self.isRunning = false
            completion()
        }

        while true {
            // Check cancellation
            if cancelCheck() { return }

            // Check for existing error
            if errorCheck() != nil { return }

            // Bounded wait for isReadyForMoreMediaData
            let deadline = Date().addingTimeInterval(backpressureTimeout)
            while !audioInput.isReadyForMoreMediaData {
                if cancelCheck() { return }
                if errorCheck() != nil { return }
                if Date() > deadline {
                    setExportErrorOnce(VideoExportError.audioBackpressureTimeout)
                    return
                }
                Thread.sleep(forTimeInterval: 0.002)
            }

            // Read next sample
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                // Check reader status
                if reader.status == .completed {
                    // Normal completion
                    audioInput.markAsFinished()
                    return
                } else {
                    // Error
                    setExportErrorOnce(VideoExportError.audioReaderStartFailed(reader.error))
                    return
                }
            }

            // Append sample
            let ok = audioInput.append(sampleBuffer)
            if !ok {
                setExportErrorOnce(VideoExportError.audioAppendFailed(nil))
                return
            }
        }
    }
}
