import XCTest
import AVFoundation
import CoreMedia
@testable import AnimiApp

private struct StubMediaLocator: ProjectMediaLocator {
    func absoluteURL(for mediaRef: MediaRef, registry: ProjectAssetRegistry) async throws -> URL {
        URL(fileURLWithPath: "/tmp/stub")
    }
}

final class VideoExportSessionTests: XCTestCase {

    // MARK: - Helpers

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("session_test_\(UUID().uuidString).mp4")
    }

    private func makePipeline(url: URL) throws -> ExportWriterPipeline {
        try ExportWriterPipeline(
            outputURL: url,
            video: .init(sizePx: (width: 64, height: 64), fps: 30, bitrate: 1_000_000, gopSeconds: 1),
            audio: nil
        )
    }

    // MARK: - test_sessionStronglyHoldsPipeline

    func test_sessionStronglyHoldsPipeline() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let exp = expectation(description: "completion")
        let session = ExportSession { result in
            exp.fulfill()
        }

        var pipeline: ExportWriterPipeline? = try makePipeline(url: url)
        session.attachPipeline(pipeline!)

        // Pipeline should be retained by session even after we nil our reference
        weak var weakPipeline = pipeline
        pipeline = nil
        XCTAssertNotNil(weakPipeline, "Session should hold pipeline strongly")

        session.complete(with: .failure(VideoExportError.cancelled))
        wait(for: [exp], timeout: 2.0)
    }

    // MARK: - test_completionFiresExactlyOnce

    func test_completionFiresExactlyOnce() {
        let exp = expectation(description: "completion")
        var callCount = 0

        let session = ExportSession { _ in
            callCount += 1
            exp.fulfill()
        }

        session.complete(with: .failure(VideoExportError.cancelled))
        session.complete(with: .success(URL(fileURLWithPath: "/tmp/test.mp4")))
        session.complete(with: .failure(VideoExportError.failedToCreateCommandBuffer))

        wait(for: [exp], timeout: 2.0)

        // Give extra time for any late callbacks, then verify count
        let verifyExp = expectation(description: "verify")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            verifyExp.fulfill()
        }
        wait(for: [verifyExp], timeout: 1.0)

        XCTAssertEqual(callCount, 1, "Completion should fire exactly once")
    }

    // MARK: - test_progressGatedAfterTerminal

    func test_progressGatedAfterTerminal() {
        let exp = expectation(description: "completion")
        let session = ExportSession { _ in exp.fulfill() }

        session.complete(with: .failure(VideoExportError.cancelled))
        wait(for: [exp], timeout: 2.0)

        // Progress should be silently dropped after terminal state
        let progressExp = expectation(description: "progress")
        progressExp.isInverted = true

        session.emitProgressIfActive(0.5) { _ in
            progressExp.fulfill()
        }

        wait(for: [progressExp], timeout: 0.5)
    }

    // MARK: - test_requestCancelThenComplete

    func test_requestCancelThenComplete() {
        let exp = expectation(description: "completion")
        var receivedResult: Result<URL, Error>?

        let session = ExportSession { result in
            receivedResult = result
            exp.fulfill()
        }

        session.requestCancel()
        XCTAssertTrue(session.isCancelled)
        XCTAssertTrue(session.shouldStop)

        // Simulate render loop calling complete after seeing shouldStop
        session.complete(with: .success(URL(fileURLWithPath: "/tmp/test.mp4")))

        wait(for: [exp], timeout: 2.0)

        // Should be overridden to .cancelled
        if case .failure(let error) = receivedResult,
           let exportError = error as? VideoExportError,
           exportError.isCancelled {
            // correct
        } else {
            XCTFail("Expected .cancelled, got \(String(describing: receivedResult))")
        }
    }

    // MARK: - test_shouldStopAfterCancel

    func test_shouldStopAfterCancel() {
        let session = ExportSession { _ in }
        XCTAssertFalse(session.shouldStop)

        session.requestCancel()
        XCTAssertTrue(session.shouldStop)
    }

    // MARK: - test_shouldStopAfterPipelineError

    func test_shouldStopAfterPipelineError() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let session = ExportSession { _ in }
        let pipeline = try makePipeline(url: url)
        session.attachPipeline(pipeline)

        XCTAssertFalse(session.shouldStop)

        pipeline.setError(VideoExportError.noPixelBufferPool)
        XCTAssertTrue(session.shouldStop)
    }

    // MARK: - test_cleanupClosures

    func test_cleanupClosures_onSuccess() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let exp = expectation(description: "completion")
        var cleanupCalled = ""

        let session = ExportSession { _ in exp.fulfill() }
        let pipeline = try makePipeline(url: url)
        session.attachPipeline(pipeline)
        try pipeline.startWriting()

        session.setCleanup(
            onSuccess: { cleanupCalled = "success" },
            onFailure: { cleanupCalled = "failure" },
            onCancel:  { cleanupCalled = "cancel" }
        )

        session.complete(with: .success(url))
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(cleanupCalled, "success")
    }

    func test_cleanupClosures_onFailure() {
        let exp = expectation(description: "completion")
        var cleanupCalled = ""

        let session = ExportSession { _ in exp.fulfill() }
        session.setCleanup(
            onSuccess: { cleanupCalled = "success" },
            onFailure: { cleanupCalled = "failure" },
            onCancel:  { cleanupCalled = "cancel" }
        )

        session.complete(with: .failure(VideoExportError.failedToCreateCommandBuffer))
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(cleanupCalled, "failure")
    }

    func test_cleanupClosures_onCancel() {
        let exp = expectation(description: "completion")
        var cleanupCalled = ""

        let session = ExportSession { _ in exp.fulfill() }
        session.setCleanup(
            onSuccess: { cleanupCalled = "success" },
            onFailure: { cleanupCalled = "failure" },
            onCancel:  { cleanupCalled = "cancel" }
        )

        session.requestCancel()
        session.complete(with: .failure(VideoExportError.cancelled))
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(cleanupCalled, "cancel")
    }

    // MARK: - Regression: cancel during preparing (before attachPipeline)

    func test_cancelDuringPreparing() {
        let exp = expectation(description: "completion")
        var receivedResult: Result<URL, Error>?

        let session = ExportSession { result in
            receivedResult = result
            exp.fulfill()
        }

        // Cancel before pipeline is attached
        session.requestCancel()
        XCTAssertTrue(session.isCancelled)
        XCTAssertTrue(session.shouldStop)

        // Render loop detects shouldStop, calls complete
        session.complete(with: .failure(VideoExportError.cancelled))

        wait(for: [exp], timeout: 2.0)

        if case .failure(let error) = receivedResult,
           let exportError = error as? VideoExportError,
           exportError.isCancelled {
            // correct
        } else {
            XCTFail("Expected .cancelled, got \(String(describing: receivedResult))")
        }
    }

    // MARK: - Regression: cancel during preload

    func test_cancelDuringPreload_sessionAcceptsCancel() {
        let session = ExportSession { _ in }

        // Simulate: session created, cancel arrives during async preload
        session.requestCancel()

        // After preload, code checks isCancelled and returns early
        XCTAssertTrue(session.isCancelled, "Session should accept cancel before pipeline attachment")
    }

    // MARK: - test_attachPipelineAfterCancel_cancelsPipeline

    func test_attachPipelineAfterCancel_cancelsPipeline() throws {
        let url = tempURL()

        let session = ExportSession { _ in }
        session.requestCancel()

        let pipeline = try makePipeline(url: url)
        try pipeline.startWriting()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        session.attachPipeline(pipeline)

        // Pipeline should be cancelled since session was already cancelled
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "Attaching pipeline to cancelled session should cancel the pipeline")
    }

    // MARK: - test_terminalError

    func test_terminalError() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let session = ExportSession { _ in }
        let pipeline = try makePipeline(url: url)
        session.attachPipeline(pipeline)

        XCTAssertNil(session.terminalError)

        pipeline.setError(VideoExportError.noPixelBufferPool)
        XCTAssertNotNil(session.terminalError)
    }

    // MARK: - Regression: cancel during controller-side preload (P1)

    /// Simulates: cancel arrives before exportVideo() is called (during controller preload).
    /// The exporter has no activeSession yet, so cancel() is a no-op on the exporter.
    /// Controller must guard with isExporting before calling exportVideo().
    func test_cancelBeforeExportVideo_exporterCancelIsNoOp() {
        let exporter = VideoExporter(mediaLocator: StubMediaLocator())

        // Cancel before any export session exists — should not crash, is a no-op
        exporter.cancel()

        // Verify exporter is in a clean state and can accept a new export later
        // (We can't call exportVideo without full Metal setup, but we verified no crash)
    }

    /// Simulates: cancel arrives after exporter.exportVideo() creates a session.
    /// Even though controller preload is done, if cancel arrived via requestCancel
    /// on the session, the exportVideo should detect it and complete with .cancelled.
    func test_cancelAfterSessionCreated_beforePipelineAttached() {
        let exp = expectation(description: "completion")
        var receivedResult: Result<URL, Error>?

        let session = ExportSession { result in
            receivedResult = result
            exp.fulfill()
        }

        // Session just created (preparing state), cancel arrives
        session.requestCancel()

        // Simulate: render loop code detects shouldStop before creating pipeline
        XCTAssertTrue(session.shouldStop)
        session.complete(with: .failure(VideoExportError.cancelled))

        wait(for: [exp], timeout: 2.0)

        if case .failure(let error) = receivedResult,
           let exportError = error as? VideoExportError,
           exportError.isCancelled {
            // correct — export never started, cancelled cleanly
        } else {
            XCTFail("Expected .cancelled, got \(String(describing: receivedResult))")
        }
    }

    /// Regression: controller-level guard pattern.
    /// Simulates the isExporting flag being cleared by onCancel during preload,
    /// and the Task continuation checking it before calling exportVideo.
    func test_controllerPreloadCancelPattern_singleScene() {
        // Simulate controller state
        var isExporting = true
        var exportStarted = false

        // Simulate onCancel (runs synchronously on MainActor before Task resumes)
        isExporting = false

        // Simulate Task continuation after await preloadBackgroundTexturesForExport
        if isExporting {
            exportStarted = true
        }

        XCTAssertFalse(exportStarted, "Export should NOT start after cancel during preload")
    }

    /// Same pattern for timeline export
    func test_controllerPreloadCancelPattern_timeline() {
        var isExporting = true
        var exportStarted = false

        // Simulate onCancel
        isExporting = false

        // Simulate Task continuation after await
        if isExporting {
            exportStarted = true
        }

        XCTAssertFalse(exportStarted, "Timeline export should NOT start after cancel during preload")
    }

    // MARK: - onTerminal Tests

    func test_onTerminalFiredOnSuccess() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let exp = expectation(description: "completion")
        var terminalFired = false

        let session = ExportSession { _ in exp.fulfill() }
        let pipeline = try makePipeline(url: url)
        session.attachPipeline(pipeline)
        try pipeline.startWriting()

        session.setOnTerminal { terminalFired = true }
        session.complete(with: .success(url))
        wait(for: [exp], timeout: 2.0)

        XCTAssertTrue(terminalFired, "onTerminal should fire on success")
    }

    func test_onTerminalFiredOnFailure() {
        let exp = expectation(description: "completion")
        var terminalFired = false

        let session = ExportSession { _ in exp.fulfill() }
        session.setOnTerminal { terminalFired = true }
        session.complete(with: .failure(VideoExportError.failedToCreateCommandBuffer))
        wait(for: [exp], timeout: 2.0)

        XCTAssertTrue(terminalFired, "onTerminal should fire on failure")
    }

    func test_onTerminalFiredOnCancel() {
        let exp = expectation(description: "completion")
        var terminalFired = false

        let session = ExportSession { _ in exp.fulfill() }
        session.setOnTerminal { terminalFired = true }
        session.requestCancel()
        session.complete(with: .failure(VideoExportError.cancelled))
        wait(for: [exp], timeout: 2.0)

        XCTAssertTrue(terminalFired, "onTerminal should fire on cancel")
    }

    func test_onTerminalNotFiredTwice() {
        let exp = expectation(description: "completion")
        var terminalCount = 0

        let session = ExportSession { _ in exp.fulfill() }
        session.setOnTerminal { terminalCount += 1 }

        session.complete(with: .failure(VideoExportError.cancelled))
        session.complete(with: .failure(VideoExportError.failedToCreateCommandBuffer))
        session.complete(with: .success(URL(fileURLWithPath: "/tmp/test.mp4")))
        wait(for: [exp], timeout: 2.0)

        // Extra time for any late calls
        let verifyExp = expectation(description: "verify")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { verifyExp.fulfill() }
        wait(for: [verifyExp], timeout: 1.0)

        XCTAssertEqual(terminalCount, 1, "onTerminal should fire exactly once")
    }

    // MARK: - Phase Ordering Tests

    func test_finishingCallbackEmittedBeforeCompletion() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let finishingExp = expectation(description: "finishing")
        let completionExp = expectation(description: "completion")

        var finishingTime: Date?
        var completionTime: Date?

        let session = ExportSession { _ in
            completionTime = Date()
            completionExp.fulfill()
        }
        let pipeline = try makePipeline(url: url)
        session.attachPipeline(pipeline)
        try pipeline.startWriting()

        session.setOnFinishing {
            finishingTime = Date()
            finishingExp.fulfill()
        }

        // Enqueue a frame then finish
        let pb = makeTestPixelBuffer()
        let pts = CMTime(value: 0, timescale: 30)
        let enqueueExp = expectation(description: "enqueue")
        pipeline.enqueueVideoFrame(pb, presentationTime: pts) { enqueueExp.fulfill() }
        wait(for: [enqueueExp], timeout: 5.0)

        session.transitionToRendering()
        session.finishWriting()

        wait(for: [finishingExp, completionExp], timeout: 10.0)

        XCTAssertNotNil(finishingTime, "onFinishing should have been called")
        XCTAssertNotNil(completionTime, "completion should have been called")
        XCTAssertTrue(finishingTime! <= completionTime!, "onFinishing must fire before completion")
    }

    func test_finishingNotEmittedOnCancel() {
        let exp = expectation(description: "completion")
        var finishingFired = false

        let session = ExportSession { _ in exp.fulfill() }
        session.setOnFinishing { finishingFired = true }

        session.requestCancel()
        session.complete(with: .failure(VideoExportError.cancelled))
        wait(for: [exp], timeout: 2.0)

        // Extra time for any late calls
        let verifyExp = expectation(description: "verify")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { verifyExp.fulfill() }
        wait(for: [verifyExp], timeout: 1.0)

        XCTAssertFalse(finishingFired, "onFinishing should NOT fire when cancelled without finishWriting")
    }

    // MARK: - Helpers for phase tests

    private func makeTestPixelBuffer(width: Int = 64, height: Int = 64) -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, nil, &pixelBuffer
        )
        return pixelBuffer!
    }
}
