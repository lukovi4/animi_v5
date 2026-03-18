import XCTest
import Metal
@testable import AnimiApp
@testable import TVECore

/// TT-02: Tests for VideoExporter timeline resolution mapping.
final class VideoExporterTimelineResolutionTests: XCTestCase {

    // MARK: - mapResolutionToExportError Tests

    /// TT-02: .resolved returns nil (no error)
    @MainActor
    func testResolvedReturnsNil() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device not available")
        }

        // Create minimal render context for test
        let context = SceneRenderContext(
            commands: [],
            textureProvider: EmptyTestTextureProvider(),
            pathRegistry: PathRegistry(),
            assetSizes: [:],
            localFrame: 0,
            canvasSize: SizeD(width: 1080, height: 1920),
            sceneInstanceId: UUID()
        )

        let resolution = TimelineFrameResolution.resolved(.single(context))
        let error = VideoExporter.mapResolutionToExportError(resolution, frameIndex: 10)

        XCTAssertNil(error, ".resolved should not produce an error")
    }

    /// TT-02: .hold returns frameHoldNotAllowed
    func testHoldReturnsFrameHoldNotAllowed() {
        let resolution = TimelineFrameResolution.hold
        let error = VideoExporter.mapResolutionToExportError(resolution, frameIndex: 42)

        guard case .frameHoldNotAllowed(let frame) = error else {
            XCTFail("Expected frameHoldNotAllowed, got \(String(describing: error))")
            return
        }
        XCTAssertEqual(frame, 42)
    }

    /// TT-02: .staleGeneration returns frameResolutionFailed with stale_generation reason
    func testStaleGenerationReturnsFrameResolutionFailed() {
        let resolution = TimelineFrameResolution.staleGeneration
        let error = VideoExporter.mapResolutionToExportError(resolution, frameIndex: 100)

        guard case .frameResolutionFailed(let frame, let reason) = error else {
            XCTFail("Expected frameResolutionFailed, got \(String(describing: error))")
            return
        }
        XCTAssertEqual(frame, 100)
        XCTAssertEqual(reason, "stale_generation")
    }

    /// TT-02: .failed(.invalidTimeline) returns readable reason
    func testFailedInvalidTimelineReturnsReason() {
        let resolution = TimelineFrameResolution.failed(.invalidTimeline)
        let error = VideoExporter.mapResolutionToExportError(resolution, frameIndex: 0)

        guard case .frameResolutionFailed(let frame, let reason) = error else {
            XCTFail("Expected frameResolutionFailed, got \(String(describing: error))")
            return
        }
        XCTAssertEqual(frame, 0)
        XCTAssertEqual(reason, "invalid_timeline")
    }

    /// TT-02: .failed(.missingDependency) returns readable reason with UUID
    func testFailedMissingDependencyReturnsReason() {
        let testId = UUID()
        let resolution = TimelineFrameResolution.failed(.missingDependency(testId))
        let error = VideoExporter.mapResolutionToExportError(resolution, frameIndex: 5)

        guard case .frameResolutionFailed(let frame, let reason) = error else {
            XCTFail("Expected frameResolutionFailed, got \(String(describing: error))")
            return
        }
        XCTAssertEqual(frame, 5)
        XCTAssertTrue(reason.contains("missing_dependency"))
        XCTAssertTrue(reason.contains(testId.uuidString))
    }

    /// TT-02: .failed(.dependencyFailed) returns readable reason with UUID and inner reason
    func testFailedDependencyFailedReturnsReason() {
        let testId = UUID()
        let resolution = TimelineFrameResolution.failed(.dependencyFailed(testId, reason: "media_error"))
        let error = VideoExporter.mapResolutionToExportError(resolution, frameIndex: 10)

        guard case .frameResolutionFailed(let frame, let reason) = error else {
            XCTFail("Expected frameResolutionFailed, got \(String(describing: error))")
            return
        }
        XCTAssertEqual(frame, 10)
        XCTAssertTrue(reason.contains("dependency_failed"))
        XCTAssertTrue(reason.contains(testId.uuidString))
        XCTAssertTrue(reason.contains("media_error"))
    }

    /// TT-02: .failed(.dependencyTimedOut) returns readable reason with UUID
    func testFailedDependencyTimedOutReturnsReason() {
        let testId = UUID()
        let resolution = TimelineFrameResolution.failed(.dependencyTimedOut(testId))
        let error = VideoExporter.mapResolutionToExportError(resolution, frameIndex: 15)

        guard case .frameResolutionFailed(let frame, let reason) = error else {
            XCTFail("Expected frameResolutionFailed, got \(String(describing: error))")
            return
        }
        XCTAssertEqual(frame, 15)
        XCTAssertTrue(reason.contains("dependency_timeout"))
        XCTAssertTrue(reason.contains(testId.uuidString))
    }

    // MARK: - TimelineExportError Description Tests

    /// TT-02: frameHoldNotAllowed has readable description
    func testFrameHoldNotAllowedDescription() {
        let error = TimelineExportError.frameHoldNotAllowed(50)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("50") ?? false)
        XCTAssertTrue(error.errorDescription?.contains("hold") ?? false)
    }

    /// TT-02: frameResolutionFailed has readable description with reason
    func testFrameResolutionFailedDescription() {
        let error = TimelineExportError.frameResolutionFailed(frame: 25, reason: "test_reason")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("25") ?? false)
        XCTAssertTrue(error.errorDescription?.contains("test_reason") ?? false)
    }
}

// MARK: - Test Helpers

/// Empty texture provider for tests
private final class EmptyTestTextureProvider: TextureProvider {
    func texture(for assetId: String) -> MTLTexture? {
        nil
    }
}
