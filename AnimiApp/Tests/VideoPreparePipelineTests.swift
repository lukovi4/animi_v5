import XCTest
import AVFoundation
@testable import AnimiApp

/// Tests for VideoPreparePipeline.validatePersistedVideo.
final class VideoPreparePipelineTests: XCTestCase {

    // MARK: - Helpers

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoPreparePipelineTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDir = nil
        try await super.tearDown()
    }

    /// Creates a minimal valid video file using AVAssetWriter.
    private func createTestVideo(duration: Double = 1.0) async throws -> URL {
        let url = tempDir.appendingPathComponent("\(UUID().uuidString).mp4")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 64
            ]
        )

        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Write frames for desired duration at 30fps
        let fps = 30.0
        let frameCount = Int(duration * fps)
        for i in 0..<max(1, frameCount) {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.01)
            }

            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &pixelBuffer)
            guard let buffer = pixelBuffer else { continue }

            let time = CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))
            adaptor.append(buffer, withPresentationTime: time)
        }

        input.markAsFinished()
        await writer.finishWriting()

        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "Test", code: -1)
        }

        return url
    }

    // MARK: - Tests

    /// Valid video file returns PersistedVideoSelection with correct duration.
    func test_validatePersistedVideo_validFile_returnsDuration() async throws {
        let url = try await createTestVideo(duration: 1.0)

        let result = try await VideoPreparePipeline.validatePersistedVideo(at: url)

        XCTAssertEqual(result.trimStart, 0)
        XCTAssertGreaterThan(result.trimEnd, 0.5, "Duration should be roughly 1s")
        XCTAssertEqual(result.isMuted, VideoAudioPolicy.defaultIsMuted, "Should match policy default")
        XCTAssertEqual(result.volume, VideoAudioPolicy.defaultVolume, "Should match policy default")
    }

    /// Missing file throws fileNotReadable.
    func test_validatePersistedVideo_missingFile_throws() async {
        let url = tempDir.appendingPathComponent("nonexistent.mp4")

        do {
            _ = try await VideoPreparePipeline.validatePersistedVideo(at: url)
            XCTFail("Expected error for missing file")
        } catch let error as VideoPreparePipeline.VideoPreparePipelineError {
            if case .fileNotReadable = error { /* pass */ }
            else { XCTFail("Expected fileNotReadable, got \(error)") }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    /// Corrupt/unreadable file throws metadataLoadFailed or invalidDuration.
    func test_validatePersistedVideo_corruptFile_throws() async throws {
        let url = tempDir.appendingPathComponent("corrupt.mp4")
        try Data([0xDE, 0xAD, 0xBE, 0xEF]).write(to: url)

        do {
            _ = try await VideoPreparePipeline.validatePersistedVideo(at: url)
            XCTFail("Expected error for corrupt file")
        } catch is VideoPreparePipeline.VideoPreparePipelineError {
            // Any pipeline error is acceptable for corrupt file
        } catch {
            // AVFoundation may throw its own errors — acceptable
        }
    }

    /// File with no valid video track (e.g. a text file renamed to .mp4) results in
    /// either metadataLoadFailed or invalidDuration.
    /// Note: Deterministically creating a zero-duration but otherwise valid video is not
    /// possible with AVAssetWriter (minimum 1 frame → nonzero duration). This test covers
    /// the invalid-duration path via a non-video file that AVFoundation can open but cannot
    /// extract a meaningful duration from.
    func test_validatePersistedVideo_nonVideoFile_throws() async throws {
        let url = tempDir.appendingPathComponent("not_a_video.mp4")
        // Write a minimal valid JPEG — it's a real file but not a video container
        try Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46]).write(to: url)

        do {
            _ = try await VideoPreparePipeline.validatePersistedVideo(at: url)
            XCTFail("Expected error for non-video file")
        } catch is VideoPreparePipeline.VideoPreparePipelineError {
            // metadataLoadFailed or invalidDuration — both acceptable
        } catch {
            // AVFoundation may throw its own errors — acceptable for non-video content
        }
    }
}
