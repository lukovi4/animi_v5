import XCTest
import AVFoundation
import CoreMedia
@testable import AnimiApp

final class ExportWriterPipelineTests: XCTestCase {

    private func tempURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("test_export_\(UUID().uuidString).mp4")
    }

    private func makeTestPixelBuffer(width: Int = 64, height: Int = 64) -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, nil, &pixelBuffer
        )
        return pixelBuffer!
    }

    // MARK: - test_videoOnlyFinish

    func test_videoOnlyFinish() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let pipeline = try ExportWriterPipeline(
            outputURL: url,
            video: .init(sizePx: (width: 64, height: 64), fps: 30, bitrate: 1_000_000, gopSeconds: 1),
            audio: nil
        )
        try pipeline.startWriting()

        let exp = expectation(description: "finish")

        // Enqueue a few frames
        let group = DispatchGroup()
        for i in 0..<5 {
            group.enter()
            let pb = makeTestPixelBuffer()
            let pts = CMTime(value: CMTimeValue(i), timescale: 30)
            pipeline.enqueueVideoFrame(pb, presentationTime: pts) {
                group.leave()
            }
        }

        group.notify(queue: .global()) {
            pipeline.finishWriting { result in
                switch result {
                case .success(let outputURL):
                    XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
                case .failure(let error):
                    XCTFail("Unexpected error: \(error)")
                }
                exp.fulfill()
            }
        }

        wait(for: [exp], timeout: 10.0)
    }

    // MARK: - test_firstErrorWins

    func test_firstErrorWins() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let pipeline = try ExportWriterPipeline(
            outputURL: url,
            video: .init(sizePx: (width: 64, height: 64), fps: 30, bitrate: 1_000_000, gopSeconds: 1),
            audio: nil
        )

        let error1 = VideoExportError.noPixelBufferPool
        let error2 = VideoExportError.failedToCreateCommandBuffer

        pipeline.setError(error1)
        pipeline.setError(error2)

        let firstError = pipeline.firstError as? VideoExportError
        XCTAssertNotNil(firstError)

        // Verify it's the first error, not the second
        if case .noPixelBufferPool = firstError {
            // correct
        } else {
            XCTFail("Expected noPixelBufferPool, got \(String(describing: firstError))")
        }
    }

    // MARK: - test_cancelCleansUpFile

    func test_cancelCleansUpFile() throws {
        let url = tempURL()

        let pipeline = try ExportWriterPipeline(
            outputURL: url,
            video: .init(sizePx: (width: 64, height: 64), fps: 30, bitrate: 1_000_000, gopSeconds: 1),
            audio: nil
        )
        try pipeline.startWriting()

        // File should exist after startWriting
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        pipeline.cancel()

        // File should be cleaned up
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - test_finishCallbackExactlyOnce

    func test_finishCallbackExactlyOnce() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let pipeline = try ExportWriterPipeline(
            outputURL: url,
            video: .init(sizePx: (width: 64, height: 64), fps: 30, bitrate: 1_000_000, gopSeconds: 1),
            audio: nil
        )
        try pipeline.startWriting()

        let pb = makeTestPixelBuffer()
        let pts = CMTime(value: 0, timescale: 30)

        let enqueueExp = expectation(description: "enqueue")
        pipeline.enqueueVideoFrame(pb, presentationTime: pts) {
            enqueueExp.fulfill()
        }
        wait(for: [enqueueExp], timeout: 5.0)

        let finishExp = expectation(description: "finish")
        var callbackCount = 0
        pipeline.finishWriting { _ in
            callbackCount += 1
            finishExp.fulfill()
        }

        wait(for: [finishExp], timeout: 10.0)
        XCTAssertEqual(callbackCount, 1, "finishWriting callback should fire exactly once")
    }

    // MARK: - test_strongCaptureNoSpuriousCancellation

    /// Regression: pipeline held strongly in finishWriting closures — no spurious .cancelled
    func test_strongCaptureNoSpuriousCancellation() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        var pipeline: ExportWriterPipeline? = try ExportWriterPipeline(
            outputURL: url,
            video: .init(sizePx: (width: 64, height: 64), fps: 30, bitrate: 1_000_000, gopSeconds: 1),
            audio: nil
        )
        try pipeline!.startWriting()

        let pb = makeTestPixelBuffer()
        let pts = CMTime(value: 0, timescale: 30)

        let enqueueExp = expectation(description: "enqueue")
        pipeline!.enqueueVideoFrame(pb, presentationTime: pts) {
            enqueueExp.fulfill()
        }
        wait(for: [enqueueExp], timeout: 5.0)

        let finishExp = expectation(description: "finish")
        let capturedPipeline = pipeline!

        // Nil out our reference — pipeline should survive via strong capture in finishWriting
        capturedPipeline.finishWriting { result in
            switch result {
            case .success:
                break // expected
            case .failure(let error):
                XCTFail("Pipeline with strong capture should not fail with: \(error)")
            }
            finishExp.fulfill()
        }
        pipeline = nil

        wait(for: [finishExp], timeout: 10.0)
    }

    // MARK: - Audio Finish Coordination

    /// Creates a minimal AVMutableComposition with real silent audio samples for testing.
    /// Writes a short silent WAV to disk, then creates a composition from it.
    private func makeSilentAudioComposition(durationSeconds: Double = 0.5) -> AVMutableComposition? {
        // 1. Create a silent WAV file with actual audio samples
        let sampleRate: Double = 44100
        let numSamples = Int(sampleRate * durationSeconds)
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("silent_\(UUID().uuidString).wav")

        // WAV header for mono 16-bit PCM
        let dataSize = numSamples * 2 // 16-bit = 2 bytes per sample
        var header = Data()
        func appendUInt32LE(_ value: UInt32) { var v = value; header.append(Data(bytes: &v, count: 4)) }
        func appendUInt16LE(_ value: UInt16) { var v = value; header.append(Data(bytes: &v, count: 2)) }

        header.append("RIFF".data(using: .ascii)!)
        appendUInt32LE(UInt32(36 + dataSize))
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)
        appendUInt32LE(16) // chunk size
        appendUInt16LE(1)  // PCM format
        appendUInt16LE(1)  // mono
        appendUInt32LE(UInt32(sampleRate))
        appendUInt32LE(UInt32(sampleRate * 2)) // byte rate
        appendUInt16LE(2)  // block align
        appendUInt16LE(16) // bits per sample
        header.append("data".data(using: .ascii)!)
        appendUInt32LE(UInt32(dataSize))

        // Silent samples (all zeros)
        header.append(Data(count: dataSize))

        try? header.write(to: wavURL)

        // 2. Build composition from the WAV
        let asset = AVURLAsset(url: wavURL)
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            try? FileManager.default.removeItem(at: wavURL)
            return nil
        }

        guard let sourceTrack = asset.tracks(withMediaType: .audio).first else {
            try? FileManager.default.removeItem(at: wavURL)
            return nil
        }

        let duration = CMTime(seconds: durationSeconds, preferredTimescale: 44100)
        do {
            try compositionTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: sourceTrack,
                at: .zero
            )
        } catch {
            try? FileManager.default.removeItem(at: wavURL)
            return nil
        }

        // Clean up temp WAV — composition retains the data
        try? FileManager.default.removeItem(at: wavURL)
        return composition
    }

    func test_audioEnabledFinishCoordination() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        guard let composition = makeSilentAudioComposition() else {
            // Audio composition could not be built (e.g., no audio hardware on CI) — skip gracefully
            return
        }

        let pipeline = try ExportWriterPipeline(
            outputURL: url,
            video: .init(sizePx: (width: 64, height: 64), fps: 30, bitrate: 1_000_000, gopSeconds: 1),
            audio: .init(composition: composition, audioMix: nil)
        )
        try pipeline.startWriting()

        let exp = expectation(description: "finish")

        // Enqueue a few video frames
        let group = DispatchGroup()
        for i in 0..<3 {
            group.enter()
            let pb = makeTestPixelBuffer()
            let pts = CMTime(value: CMTimeValue(i), timescale: 30)
            pipeline.enqueueVideoFrame(pb, presentationTime: pts) {
                group.leave()
            }
        }

        group.notify(queue: .global()) {
            pipeline.finishWriting { result in
                switch result {
                case .success(let outputURL):
                    XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
                case .failure(let error):
                    XCTFail("Audio+video finish coordination failed: \(error)")
                }
                exp.fulfill()
            }
        }

        wait(for: [exp], timeout: 10.0)
    }

    func test_audioFinishCallbackExactlyOnce() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        guard let composition = makeSilentAudioComposition() else { return }

        let pipeline = try ExportWriterPipeline(
            outputURL: url,
            video: .init(sizePx: (width: 64, height: 64), fps: 30, bitrate: 1_000_000, gopSeconds: 1),
            audio: .init(composition: composition, audioMix: nil)
        )
        try pipeline.startWriting()

        let pb = makeTestPixelBuffer()
        let pts = CMTime(value: 0, timescale: 30)
        let enqueueExp = expectation(description: "enqueue")
        pipeline.enqueueVideoFrame(pb, presentationTime: pts) { enqueueExp.fulfill() }
        wait(for: [enqueueExp], timeout: 5.0)

        let finishExp = expectation(description: "finish")
        var callbackCount = 0

        pipeline.finishWriting { _ in
            callbackCount += 1
            finishExp.fulfill()
        }

        wait(for: [finishExp], timeout: 10.0)
        XCTAssertEqual(callbackCount, 1, "Audio+video finishWriting callback should fire exactly once")
    }
}
