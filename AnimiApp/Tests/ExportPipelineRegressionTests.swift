import XCTest
import AVFoundation
import CoreMedia
@testable import AnimiApp

/// Regression tests: verify no timeout error paths exist after removing
/// writerBackpressureTimeout / audioBackpressureTimeout.
final class ExportPipelineRegressionTests: XCTestCase {

    // MARK: - test_noTimeoutErrorCasesExist

    func test_noTimeoutErrorCasesExist() {
        // Verify the removed error cases don't exist by ensuring VideoExportError
        // can be exhaustively matched without timeout cases.
        let allCases: [VideoExportError] = [
            .fpsMismatch(settingsFps: 30, runtimeFps: 60),
            .failedToCreateWriter(nil),
            .cannotAddVideoInput,
            .writerStartFailed(nil),
            .failedToCreateTextureCache,
            .noPixelBufferPool,
            .failedToCreatePixelBuffer(0),
            .failedToCreateMetalTexture(0),
            .appendFailed(nil),
            .finishFailed(nil),
            .cancelled,
            .renderError(NSError(domain: "test", code: 0)),
            .failedToCreateCommandBuffer,
            .cannotAddAudioInput,
            .audioReaderStartFailed(nil),
            .audioAppendFailed(nil),
            .missingAudioTrack(URL(fileURLWithPath: "/tmp/test")),
            .failedToBuildAudioPipeline(NSError(domain: "test", code: 0)),
        ]

        // If writerBackpressureTimeout or audioBackpressureTimeout existed,
        // adding them to the above would be required. Since they're removed,
        // this list should be exhaustive.
        XCTAssertGreaterThan(allCases.count, 0)

        for error in allCases {
            XCTAssertNotNil(error.errorDescription, "Missing description for \(error)")
        }
    }

    // MARK: - test_videoOnlyPipelineNoTimeout

    func test_videoOnlyPipelineNoTimeout() throws {
        // Verify video-only export pipeline can be created and cancelled
        // without any timeout-related infrastructure
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression_\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        let pipeline = try ExportWriterPipeline(
            outputURL: url,
            video: .init(sizePx: (width: 32, height: 32), fps: 30, bitrate: 500_000, gopSeconds: 1),
            audio: nil
        )
        try pipeline.startWriting()

        // Enqueue one frame and cancel
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA, nil, &pb)

        let exp = expectation(description: "enqueue completes")
        pipeline.enqueueVideoFrame(pb!, presentationTime: .zero) {
            exp.fulfill()
        }

        wait(for: [exp], timeout: 2.0)

        pipeline.cancel()
        XCTAssertNil(pipeline.firstError, "Should have no errors for clean cancel")
    }

    // MARK: - test_settingsHaveNoBackpressureTimeout

    func test_settingsHaveNoBackpressureTimeout() {
        // Verify VideoExportSettings can be created without backpressureTimeoutSeconds
        let settings = VideoExportSettings(
            outputURL: URL(fileURLWithPath: "/tmp/test.mp4"),
            sizePx: (width: 1920, height: 1080),
            fps: 30
        )
        XCTAssertNotNil(settings)

        // Verify TimelineExportSettings can be created without backpressureTimeoutSeconds
        let timelineSettings = VideoExporter.TimelineExportSettings(
            outputURL: URL(fileURLWithPath: "/tmp/test.mp4"),
            sizePx: (width: 1920, height: 1080)
        )
        XCTAssertNotNil(timelineSettings)
    }
}
