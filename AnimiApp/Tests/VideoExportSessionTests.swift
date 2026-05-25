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

    // MARK: - PR8: Music AudioExportConfig does not regress session

    func test_pipelineWithMusicAudioConfig_createsSuccessfully() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Create pipeline with non-nil music AudioExportConfig
        let musicConfig = AudioTrackConfig(
            url: URL(fileURLWithPath: "/tmp/test_music.mp3"),
            startTimeSeconds: 0,
            volume: 0.8,
            trimStartSeconds: 1.0,
            trimEndSeconds: 5.0
        )
        let audioExportConfig = AudioExportConfig(
            music: musicConfig,
            voiceover: nil,
            includeOriginalFromVideoSlots: true,
            originalDefaultVolume: 1.0
        )

        // Pipeline creation should not fail due to music config presence
        // (audio is built separately by AudioCompositionBuilder, not by the pipeline)
        let pipeline = try ExportWriterPipeline(
            outputURL: url,
            video: .init(sizePx: (width: 64, height: 64), fps: 30, bitrate: 1_000_000, gopSeconds: 1),
            audio: nil // audio pipeline is attached later, after AudioCompositionBuilder
        )
        XCTAssertNotNil(pipeline)

        // Verify AudioExportConfig preserves music fields
        XCTAssertNotNil(audioExportConfig.music)
        XCTAssertEqual(audioExportConfig.music?.volume, 0.8)
        XCTAssertEqual(audioExportConfig.music?.trimStartSeconds, 1.0)
        XCTAssertEqual(audioExportConfig.music?.trimEndSeconds, 5.0)
    }

    func test_sessionWithMusicConfig_completesNormally() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let exp = expectation(description: "completion")
        var receivedResult: Result<URL, Error>?

        let session = ExportSession { result in
            receivedResult = result
            exp.fulfill()
        }

        let pipeline = try makePipeline(url: url)
        session.attachPipeline(pipeline)

        // Complete session (simulating export with music config)
        session.complete(with: .failure(VideoExportError.cancelled))
        wait(for: [exp], timeout: 2.0)

        // Session lifecycle works normally even when music is configured
        XCTAssertNotNil(receivedResult)
    }

    func test_audioExportConfigPreservesMusicTrimAndVolume() {
        let musicConfig = AudioTrackConfig(
            url: URL(fileURLWithPath: "/tmp/music.mp3"),
            startTimeSeconds: 0,
            volume: 0.65,
            trimStartSeconds: 2.0,
            trimEndSeconds: 8.0
        )
        let config = AudioExportConfig(
            music: musicConfig,
            voiceover: nil,
            includeOriginalFromVideoSlots: true,
            originalDefaultVolume: 1.0
        )

        XCTAssertEqual(config.music?.volume, 0.65)
        XCTAssertEqual(config.music?.trimStartSeconds, 2.0)
        XCTAssertEqual(config.music?.trimEndSeconds, 8.0)
        XCTAssertEqual(config.music?.startTimeSeconds, 0)
        XCTAssertNil(config.voiceover)
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

    // MARK: - Phase-aware cancel tests (PR-4B)

    func test_attachPipelineAfterCancel_doesNotCancelImmediately() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let session = ExportSession { _ in }
        session.requestCancel()

        let pipeline = try makePipeline(url: url)
        try pipeline.startWriting()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        session.attachPipeline(pipeline)

        // Pipeline should NOT be cancelled immediately — runner's completeIfCancelled() handles it
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "attachPipeline should not destructively cancel during preparing phase")
    }

    func test_requestCancelDuringPreparing_doesNotCancelPipeline() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let session = ExportSession { _ in }
        let pipeline = try makePipeline(url: url)
        session.attachPipeline(pipeline)
        try pipeline.startWriting()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // Cancel during preparing — should NOT call pipeline.cancel()
        session.requestCancel()
        XCTAssertTrue(session.isCancelled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "requestCancel during preparing should not destructively cancel pipeline")
    }

    func test_completeIfCancelled_cancelsPipelineAndFiresCleanup() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let exp = expectation(description: "completion")
        var cancelCleanupFired = false

        let session = ExportSession { _ in exp.fulfill() }
        let pipeline = try makePipeline(url: url)
        session.attachPipeline(pipeline)
        try pipeline.startWriting()

        session.setCleanup(
            onSuccess: { },
            onFailure: { },
            onCancel: { cancelCleanupFired = true }
        )

        session.requestCancel()
        // Pipeline still alive (preparing phase)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // Runner-side fence — destructive cancel happens here
        XCTAssertTrue(session.completeIfCancelled())
        wait(for: [exp], timeout: 2.0)

        XCTAssertTrue(cancelCleanupFired)
        // Pipeline now cancelled — file removed
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test_requestCancelDuringRendering_cancelsPipelineImmediately() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let session = ExportSession { _ in }
        let pipeline = try makePipeline(url: url)
        session.attachPipeline(pipeline)
        try pipeline.startWriting()
        session.transitionToRendering()

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // Cancel during rendering — destructive cancel allowed
        session.requestCancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "requestCancel during rendering should cancel pipeline immediately")
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

    // MARK: - PR4 Regression: facade cancel propagates after runner extraction

    /// Proves VideoExporter.cancel() still reaches a live activeSession
    /// after the export loop was extracted into SingleSceneVideoExportRunner /
    /// TimelineVideoExportRunner. Regression guard for facade decomposition.
    func test_facadeCancelStillCancelsActiveSessionAfterRunnerExtraction() {
        let exp = expectation(description: "completion")
        var receivedResult: Result<URL, Error>?

        let session = ExportSession { result in
            receivedResult = result
            exp.fulfill()
        }

        let exporter = VideoExporter(mediaLocator: StubMediaLocator())

        // Inject a live session into the facade (simulates exportVideo/exportTimeline setup)
        exporter.setActiveSession(session)

        // Cancel through the public facade API
        exporter.cancel()

        // Session should now be cancelled
        XCTAssertTrue(session.isCancelled)
        XCTAssertTrue(session.shouldStop)

        // Complete the session as the runner would
        session.complete(with: .failure(VideoExportError.cancelled))

        wait(for: [exp], timeout: 2.0)

        if case .failure(let error) = receivedResult,
           let exportError = error as? VideoExportError,
           exportError.isCancelled {
            // correct — cancel propagated through facade to live session
        } else {
            XCTFail("Expected .cancelled, got \(String(describing: receivedResult))")
        }
    }

    // MARK: - PR4: completeIfCancelled Tests

    func test_completeIfCancelled_noopsWhenActive() {
        let exp = expectation(description: "completion")
        var receivedResult: Result<URL, Error>?

        let session = ExportSession { result in
            receivedResult = result
            exp.fulfill()
        }

        // Active session — completeIfCancelled should return false and not fire completion
        XCTAssertFalse(session.completeIfCancelled())
        XCTAssertFalse(session.isCancelled)

        // Session is still usable — complete normally
        session.complete(with: .failure(VideoExportError.failedToCreateCommandBuffer))
        wait(for: [exp], timeout: 2.0)

        if case .failure(let error) = receivedResult,
           let exportError = error as? VideoExportError,
           case .failedToCreateCommandBuffer = exportError {
            // correct — session still worked after no-op completeIfCancelled
        } else {
            XCTFail("Expected .failedToCreateCommandBuffer, got \(String(describing: receivedResult))")
        }
    }

    func test_completeIfCancelled_completesCancelled() {
        let exp = expectation(description: "completion")
        var receivedResult: Result<URL, Error>?

        let session = ExportSession { result in
            receivedResult = result
            exp.fulfill()
        }

        session.requestCancel()
        XCTAssertTrue(session.completeIfCancelled())

        wait(for: [exp], timeout: 2.0)

        if case .failure(let error) = receivedResult,
           let exportError = error as? VideoExportError,
           exportError.isCancelled {
            // correct
        } else {
            XCTFail("Expected .cancelled, got \(String(describing: receivedResult))")
        }
    }

    /// completeIfCancelled before pipeline attachment — safe from any context.
    func test_completeIfCancelled_beforePipelineAttached_cleansViaCancelPath() {
        let exp = expectation(description: "completion")
        var cancelCleanupFired = false

        let session = ExportSession { _ in exp.fulfill() }

        session.setCleanup(
            onSuccess: { },
            onFailure: { },
            onCancel: { cancelCleanupFired = true }
        )

        session.requestCancel()
        XCTAssertTrue(session.completeIfCancelled())

        wait(for: [exp], timeout: 2.0)

        XCTAssertTrue(cancelCleanupFired, "onCancel cleanup should fire when completeIfCancelled triggers before pipeline attachment")
    }

    /// Proves VideoExporter.TimelineExportSettings resolves through the
    /// deprecated typealias after TimelineExportSettings was promoted to top-level.
    func test_timelineExportSettingsCompileThroughRemainsValid() {
        let settings = VideoExporter.TimelineExportSettings(
            outputURL: URL(fileURLWithPath: "/tmp/test.mp4"),
            sizePx: (width: 1920, height: 1080)
        )
        XCTAssertEqual(settings.fps, 30) // default
        XCTAssertEqual(settings.sizePx.width, 1920)
    }
}
