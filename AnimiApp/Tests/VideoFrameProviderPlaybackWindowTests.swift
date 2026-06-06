import XCTest
import AVFoundation
@testable import AnimiApp

final class VideoFrameProviderPlaybackWindowTests: XCTestCase {

    private let eps = VideoWindowValidator.epsilon

    // MARK: - clampedPlaybackTime

    func testPlaybackTime_beyondTrimEnd_clampsToTrimEndMinusEpsilon() {
        let result = VideoFrameProvider.clampedPlaybackTime(
            9.0, fileDuration: 15.0, windowStart: 2.0, windowEnd: 8.0)
        XCTAssertEqual(result, 8.0 - eps, accuracy: 1e-12)
    }

    func testPlaybackTime_beforeTrimStart_clampsToTrimStart() {
        let result = VideoFrameProvider.clampedPlaybackTime(
            1.0, fileDuration: 15.0, windowStart: 2.0, windowEnd: 8.0)
        XCTAssertEqual(result, 2.0, accuracy: 1e-12)
    }

    func testPlaybackTime_withinWindow_passesThrough() {
        let result = VideoFrameProvider.clampedPlaybackTime(
            5.0, fileDuration: 15.0, windowStart: 2.0, windowEnd: 8.0)
        XCTAssertEqual(result, 5.0, accuracy: 1e-12)
    }

    func testPlaybackTime_noWindow_clampsToFileDuration() {
        let result = VideoFrameProvider.clampedPlaybackTime(
            20.0, fileDuration: 15.0, windowStart: nil, windowEnd: nil)
        XCTAssertEqual(result, 15.0 - eps, accuracy: 1e-12)
    }

    func testPlaybackTime_trimEndExceedsFile_clampsToFileCeiling() {
        let result = VideoFrameProvider.clampedPlaybackTime(
            18.0, fileDuration: 15.0, windowStart: 0.0, windowEnd: 20.0)
        XCTAssertEqual(result, 15.0 - eps, accuracy: 1e-12)
    }

    func testPlaybackTime_veryShortTrim_hiGuardPreventsInversion() {
        let result = VideoFrameProvider.clampedPlaybackTime(
            5.0, fileDuration: 15.0, windowStart: 5.0, windowEnd: 5.0 + eps * 0.5)
        XCTAssertEqual(result, 5.0, accuracy: 1e-12)
    }

    // MARK: - clampedFileTime

    func testFileTime_notAffectedByTrimWindow() {
        let result = VideoFrameProvider.clampedFileTime(5.0, fileDuration: 15.0)
        XCTAssertEqual(result, 5.0, accuracy: 1e-12)
    }

    func testFileTime_beyondDuration_clampsToFileEnd() {
        let result = VideoFrameProvider.clampedFileTime(20.0, fileDuration: 15.0)
        XCTAssertEqual(result, 15.0 - eps, accuracy: 1e-12)
    }

    func testFileTime_negative_clampsToZero() {
        let result = VideoFrameProvider.clampedFileTime(-1.0, fileDuration: 15.0)
        XCTAssertEqual(result, 0.0, accuracy: 1e-12)
    }

    // MARK: - Contract: interactive trim draft != committed playback window

    func testFileTime_draftBeyondCommittedWindow_passesThrough() {
        let result = VideoFrameProvider.clampedFileTime(5.0, fileDuration: 15.0)
        XCTAssertEqual(result, 5.0, accuracy: 1e-12,
            "Draft preview time beyond committed window must NOT be clamped by fileTime")
    }

    // MARK: - shouldHoldPlayback

    func testShouldHoldPlayback_beforeTrimEnd_false() {
        let result = VideoFrameProvider.shouldHoldPlayback(
            expectedSeconds: 5.0, fileDuration: 15.0, windowEnd: 8.0)
        XCTAssertFalse(result)
    }

    func testShouldHoldPlayback_atTrimEnd_true() {
        let holdTime = 8.0 - eps
        let result = VideoFrameProvider.shouldHoldPlayback(
            expectedSeconds: holdTime, fileDuration: 15.0, windowEnd: 8.0)
        XCTAssertTrue(result)
    }

    func testShouldHoldPlayback_beyondTrimEnd_true() {
        let result = VideoFrameProvider.shouldHoldPlayback(
            expectedSeconds: 9.0, fileDuration: 15.0, windowEnd: 8.0)
        XCTAssertTrue(result)
    }

    func testShouldHoldPlayback_withoutWindow_false() {
        let result = VideoFrameProvider.shouldHoldPlayback(
            expectedSeconds: 9.0, fileDuration: 15.0, windowEnd: nil)
        XCTAssertFalse(result)
    }

    // MARK: - playbackHoldEndTime

    func testPlaybackHoldEndTime_noWindow_returnsNil() {
        let result = VideoFrameProvider.playbackHoldEndTime(fileDuration: 15.0, windowEnd: nil)
        XCTAssertNil(result)
    }

    func testPlaybackHoldEndTime_windowWithinFile_returnsWindowEndMinusEpsilon() {
        let result = VideoFrameProvider.playbackHoldEndTime(fileDuration: 15.0, windowEnd: 8.0)
        XCTAssertEqual(result!, 8.0 - eps, accuracy: 1e-12)
    }

    func testPlaybackHoldEndTime_windowExceedsFile_clampsToFileCeiling() {
        let result = VideoFrameProvider.playbackHoldEndTime(fileDuration: 15.0, windowEnd: 20.0)
        XCTAssertEqual(result!, 15.0 - eps, accuracy: 1e-12)
    }

    // MARK: - First-Buffer Acceptance Gate (RAW item time vs expected)
    //
    // Root cause proven by device traces: after a discontinuous Play start,
    // `AVPlayerItemVideoOutput` can return a non-nil buffer whose RAW item time is NOT
    // the expected timeline time (file time 0 on cold start, stale future/previous on
    // resume). The provider must reject such outputs for binding while awaiting the first
    // accepted buffer, instead of overwriting the exact start still.
    //
    // Repair #6 correction: the acceptance predicate compares RAW item time to the
    // expected playback time. Repair #5 compared the trim-CLAMPED output, which masked a
    // raw file-zero into `trimStart` for trimmed blocks and falsely accepted it. Tolerance
    // is one scene-frame duration + epsilon. The trim-clamped time is still used for the
    // actual copyPixelBuffer request, not for acceptance.

    func testFirstBufferTolerance_30fps_isOneFramePlusEpsilon() {
        let tolerance = VideoFrameProvider.firstBufferAcceptanceToleranceSeconds(sceneFPS: 30.0)
        XCTAssertEqual(tolerance, (1.0 / 30.0) + eps, accuracy: 1e-12)
    }

    func testFirstBufferTolerance_nonPositiveFPS_fallsBackTo30() {
        let tolerance = VideoFrameProvider.firstBufferAcceptanceToleranceSeconds(sceneFPS: 0.0)
        XCTAssertEqual(tolerance, (1.0 / 30.0) + eps, accuracy: 1e-12)
    }

    /// REPAIR #6 KEY CASE: the exact captured repair #5 trim false-accept.
    /// Trimmed `block_05`: raw `itemTime=0.000000`, expected `3.343333`,
    /// trimStart `3.311538`. Repair #5 compared trim-clamped output `3.310000` to expected
    /// and wrongly accepted; raw item time 0 vs expected 3.343333 is ~3.34 s off and MUST
    /// reject.
    func testFirstBufferAcceptance_rawFileZeroAtNonzeroTrimStart_rejected() {
        XCTAssertFalse(VideoFrameProvider.isFirstPlaybackBufferAcceptable(
            rawOutputSeconds: 0.000000,
            expectedSeconds: 3.343333,
            sceneFPS: 30.0),
            "Raw file-zero must reject even when trim clamp would map it to trimStart")
    }

    /// Untrimmed start: raw `itemTime=0.000000`, expected ~`0.033333` (one frame in).
    /// Must remain ACCEPTABLE — this is the normal cold start at the file beginning.
    func testFirstBufferAcceptance_rawFileZeroAtUntrimmedStart_accepted() {
        XCTAssertTrue(VideoFrameProvider.isFirstPlaybackBufferAcceptable(
            rawOutputSeconds: 0.000000,
            expectedSeconds: 0.033333,
            sceneFPS: 30.0),
            "Untrimmed cold start (raw 0 vs expected ~one frame) must remain acceptable")
    }

    /// Captured GOOD raw deltas (~9–22 ms from expected) must be ACCEPTED.
    func testFirstBufferAcceptance_capturedGoodRawDeltas_accepted() {
        // ~9 ms past a trimmed expected
        XCTAssertTrue(VideoFrameProvider.isFirstPlaybackBufferAcceptable(
            rawOutputSeconds: 3.343333 + 0.009,
            expectedSeconds: 3.343333,
            sceneFPS: 30.0))
        // ~22 ms
        XCTAssertTrue(VideoFrameProvider.isFirstPlaybackBufferAcceptable(
            rawOutputSeconds: 7.466000 + 0.022,
            expectedSeconds: 7.466000,
            sceneFPS: 30.0))
        // exactly at expected
        XCTAssertTrue(VideoFrameProvider.isFirstPlaybackBufferAcceptable(
            rawOutputSeconds: 3.343333,
            expectedSeconds: 3.343333,
            sceneFPS: 30.0))
    }

    /// Captured BAD raw deltas must be REJECTED:
    /// - resume future: expected 3.844872, raw item time 5.925620 (~2.08 s).
    /// - saved-frame jump: expected ~7.466, raw item ~1.5 (~6 s).
    func testFirstBufferAcceptance_capturedBadRawDeltas_rejected() {
        // resume future: ~2.08 s off
        XCTAssertFalse(VideoFrameProvider.isFirstPlaybackBufferAcceptable(
            rawOutputSeconds: 5.925620,
            expectedSeconds: 3.844872,
            sceneFPS: 30.0))
        // saved-frame jump: ~6 s off
        XCTAssertFalse(VideoFrameProvider.isFirstPlaybackBufferAcceptable(
            rawOutputSeconds: 1.500000,
            expectedSeconds: 7.466000,
            sceneFPS: 30.0))
    }

    /// Boundary: just inside / just outside one-frame tolerance at 30 fps.
    func testFirstBufferAcceptance_boundary() {
        let frame = 1.0 / 30.0
        // just inside (frame - 1ms)
        XCTAssertTrue(VideoFrameProvider.isFirstPlaybackBufferAcceptable(
            rawOutputSeconds: 5.0 + (frame - 0.001),
            expectedSeconds: 5.0,
            sceneFPS: 30.0))
        // just outside (frame + 2ms, beyond frame+epsilon)
        XCTAssertFalse(VideoFrameProvider.isFirstPlaybackBufferAcceptable(
            rawOutputSeconds: 5.0 + (frame + 0.002),
            expectedSeconds: 5.0,
            sceneFPS: 30.0))
    }

    // MARK: - Real provider state regression (AVPlayer)

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaybackWindowTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir = tempDir { try? FileManager.default.removeItem(at: dir) }
        tempDir = nil
        try await super.tearDown()
    }

    private func createTestVideo(duration: Double = 2.0) async throws -> URL {
        let url = tempDir.appendingPathComponent("\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
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
        let fps = 30.0
        for i in 0..<max(1, Int(duration * fps)) {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
            var buf: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &buf)
            guard let buffer = buf else { continue }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? NSError(domain: "Test", code: -1) }
        return url
    }

    private func makeReadyProvider(duration: Double = 2.0) async throws -> VideoFrameProvider {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("No Metal device available")
        }
        let videoURL = try await createTestVideo(duration: duration)
        let provider = VideoFrameProvider(device: device, commandQueue: queue, url: videoURL)
        for _ in 0..<50 {
            if provider.isReady { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(provider.isReady)
        return provider
    }

    #if DEBUG

    /// At trim-end, provider enters hold without deactivating playback.
    func testFrameTextureForPlayback_atTrimEnd_entersHoldWithoutDeactivatingPlayback() async throws {
        let provider = try await makeReadyProvider()
        provider.setPlaybackWindow(start: 0, end: 1.0)
        provider.startPlayback(atVideoTime: 0.0)
        XCTAssertTrue(provider.isPlaybackActive)

        let holdTime = 1.0 - eps
        _ = provider.frameTextureForPlayback(expectedVideoTime: holdTime)

        XCTAssertTrue(provider.isPlaybackActive,
            "isPlaybackActive must remain true during hold")
        XCTAssertEqual(provider.debugPlayerRate, 0,
            "AVPlayer rate must be 0 during hold")
        XCTAssertTrue(provider.debugIsPlaybackHolding || provider.debugIsPlaybackHoldLoading,
            "Provider should enter hold state at trimEnd")

        provider.release()
    }

    /// Device regression: when trimEnd is not aligned to CMTime timescale 600, the
    /// provider must still enter hold at the mapper's raw trimEnd-epsilon time.
    func testFrameTextureForPlayback_nonTimescaleAlignedTrimEnd_entersHold() async throws {
        let provider = try await makeReadyProvider(duration: 8.0)
        let trimEnd = 6.522137
        provider.setPlaybackWindow(start: 0, end: trimEnd)
        provider.startPlayback(atVideoTime: 0.0)
        XCTAssertTrue(provider.isPlaybackActive)

        _ = provider.frameTextureForPlayback(expectedVideoTime: trimEnd - eps)

        XCTAssertTrue(provider.isPlaybackActive,
            "isPlaybackActive must remain true during hold")
        XCTAssertEqual(provider.debugPlayerRate, 0,
            "AVPlayer rate must be 0 during hold even when trimEnd is not timescale-aligned")
        XCTAssertTrue(provider.debugIsPlaybackHolding || provider.debugIsPlaybackHoldLoading,
            "Provider must enter hold at non-timescale-aligned trimEnd")

        provider.release()
    }

    /// After entering hold, no AVPlayerItemVideoOutput reads happen on subsequent ticks.
    func testTrimEndHold_doesNotReadAVPlayerOutputAfterEntry() async throws {
        let provider = try await makeReadyProvider()
        provider.setPlaybackWindow(start: 0, end: 1.0)
        provider.startPlayback(atVideoTime: 0.0)

        // Trigger hold entry
        _ = provider.frameTextureForPlayback(expectedVideoTime: 1.0)
        let copyCountAfterEntry = provider.debugPlaybackOutputCopyCount

        // Subsequent ticks past trimEnd must NOT read AVPlayerItemVideoOutput
        _ = provider.frameTextureForPlayback(expectedVideoTime: 1.5)
        _ = provider.frameTextureForPlayback(expectedVideoTime: 2.0)
        _ = provider.frameTextureForPlayback(expectedVideoTime: 3.0)

        XCTAssertEqual(provider.debugPlaybackOutputCopyCount, copyCountAfterEntry,
            "Hold must not read AVPlayerItemVideoOutput after entry")
        XCTAssertTrue(provider.isPlaybackActive)

        provider.release()
    }

    /// Repeated ticks past trimEnd request exact still only once.
    func testTrimEndHold_repeatedTicksRequestExactStillOnlyOnce() async throws {
        let provider = try await makeReadyProvider()
        provider.setPlaybackWindow(start: 0, end: 1.0)
        provider.startPlayback(atVideoTime: 0.0)

        _ = provider.frameTextureForPlayback(expectedVideoTime: 1.0)
        _ = provider.frameTextureForPlayback(expectedVideoTime: 1.5)
        _ = provider.frameTextureForPlayback(expectedVideoTime: 2.0)

        XCTAssertEqual(provider.debugHoldStillRequestCount, 1,
            "Exact still must be requested only once, not per tick")

        provider.release()
    }

    /// Exit hold when expected time returns inside trim window.
    func testTrimEndHold_exitsWhenExpectedTimeReturnsInsideWindow() async throws {
        let provider = try await makeReadyProvider()
        provider.setPlaybackWindow(start: 0, end: 1.0)
        provider.startPlayback(atVideoTime: 0.0)

        // Enter hold
        _ = provider.frameTextureForPlayback(expectedVideoTime: 1.0)
        XCTAssertTrue(provider.debugIsPlaybackHolding || provider.debugIsPlaybackHoldLoading)

        // Return inside window
        _ = provider.frameTextureForPlayback(expectedVideoTime: 0.5)

        XCTAssertFalse(provider.debugIsPlaybackHolding,
            "Hold state must clear when returning inside window")
        XCTAssertFalse(provider.debugIsPlaybackHoldLoading,
            "Hold loading must clear when returning inside window")

        for _ in 0..<10 where provider.debugPlayerRate != 1.0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(provider.debugPlayerRate, 1.0,
            "AVPlayer must resume at rate=1 after exiting hold")

        provider.release()
    }

    /// After async still load completes, hold is locked with exact texture.
    func testTrimEndHold_asyncStillLoadLocksExactTexture() async throws {
        let provider = try await makeReadyProvider()
        provider.setPlaybackWindow(start: 0, end: 1.0)
        provider.startPlayback(atVideoTime: 0.0)

        // Enter hold
        _ = provider.frameTextureForPlayback(expectedVideoTime: 1.0)
        XCTAssertEqual(provider.debugHoldStillRequestCount, 1)

        // Wait for async still task to complete (up to 3s)
        for _ in 0..<30 {
            if provider.debugIsPlaybackHolding { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTAssertTrue(provider.debugIsPlaybackHolding,
            "Hold must reach .holding after async still load")
        XCTAssertTrue(provider.debugHasHoldPlaybackTexture,
            "Exact hold texture must be loaded")
        XCTAssertTrue(provider.isPlaybackActive,
            "isPlaybackActive must remain true during hold")

        provider.release()
    }

    // MARK: - Scrub-to-Play Stale Texture Handoff

    /// A discontinuous `startPlayback` arms stale-cache suppression so the first
    /// ticks cannot return the previous position's cached playback texture.
    func testStartPlayback_armsStaleBufferSuppression() async throws {
        let provider = try await makeReadyProvider(duration: 2.0)
        provider.setPlaybackWindow(start: 0, end: 2.0)

        provider.startPlayback(atVideoTime: 1.0)

        XCTAssertTrue(provider.debugAwaitingFirstPlaybackBuffer,
            "Discontinuous startPlayback must suppress stale playback-cache reuse until first real buffer")

        provider.release()
    }

    /// Regression for the scrub-to-play flash: after a discontinuous start, a tick
    /// that produces no new pixel buffer must NOT return the stale cached texture —
    /// it returns nil so the caller keeps the current scrub still. Once a real
    /// buffer is produced, suppression lifts and normal fallback resumes.
    func testScrubToPlay_doesNotReturnStalePlaybackTexture() async throws {
        let provider = try await makeReadyProvider(duration: 3.0)
        provider.setPlaybackWindow(start: 0, end: 3.0)

        // First playback session warms lastPlaybackTexture near t=0.
        provider.startPlayback(atVideoTime: 0.0)
        var warmTexture: MTLTexture?
        for _ in 0..<30 {
            warmTexture = provider.frameTextureForPlayback(expectedVideoTime: 0.0)
            if warmTexture != nil && !provider.debugAwaitingFirstPlaybackBuffer { break }
            try await Task.sleep(nanoseconds: 33_000_000)
        }
        XCTAssertNotNil(warmTexture, "Expected a real playback texture in the first session")
        XCTAssertFalse(provider.debugAwaitingFirstPlaybackBuffer,
            "Suppression should lift once a real buffer is produced")

        // Simulate scrub-to-play: discontinuous restart at a far position.
        provider.startPlayback(atVideoTime: 2.5)
        XCTAssertTrue(provider.debugAwaitingFirstPlaybackBuffer,
            "Restart must re-arm suppression")

        // A tick immediately after restart, before AVPlayer produces a buffer for
        // the new position, must not hand back the stale cached texture.
        let immediate = provider.frameTextureForPlayback(expectedVideoTime: 2.5)
        if immediate != nil {
            // Acceptable only if a real buffer was already produced (suppression lifted).
            XCTAssertFalse(provider.debugAwaitingFirstPlaybackBuffer,
                "A non-nil texture right after restart is only valid once a real buffer arrived (suppression lifted)")
        } else {
            XCTAssertTrue(provider.debugAwaitingFirstPlaybackBuffer,
                "While awaiting the first real buffer, the provider returns nil (caller holds the scrub still)")
        }

        provider.release()
    }

    /// Pausing playback clears stale-buffer suppression state.
    func testStopPlayback_clearsStaleBufferSuppression() async throws {
        let provider = try await makeReadyProvider(duration: 2.0)
        provider.setPlaybackWindow(start: 0, end: 2.0)
        provider.startPlayback(atVideoTime: 1.0)
        XCTAssertTrue(provider.debugAwaitingFirstPlaybackBuffer)

        provider.stopPlayback(flush: true)
        XCTAssertFalse(provider.debugAwaitingFirstPlaybackBuffer,
            "stopPlayback must clear stale-buffer suppression")

        provider.release()
    }

    // MARK: - First-Buffer Acceptance Gate (integration)

    /// Integration regression for the proven defect: right after a discontinuous Play
    /// start at a far position, the first AVPlayer output is for a wrong (near-zero,
    /// cold-start) item time. The acceptance gate must REJECT it for binding — the tick
    /// returns nil, `awaitingFirstPlaybackBuffer` stays armed, and no playback texture
    /// is written — so `UserMediaService` keeps the exact start still bound. The
    /// suppression only lifts once a within-tolerance buffer for the expected position
    /// is produced.
    func testFirstBufferGate_wrongTimeColdStart_rejectedAndStillSuppressing() async throws {
        let provider = try await makeReadyProvider(duration: 3.0)
        provider.setPlaybackWindow(start: 0, end: 3.0)

        // Discontinuous start far from file zero; expected playback time is ~2.5s while
        // the first AVPlayer output after setRate is near file time 0.
        provider.startPlayback(atVideoTime: 2.5)
        XCTAssertTrue(provider.debugAwaitingFirstPlaybackBuffer,
            "Discontinuous start must arm first-buffer suppression")

        // Immediate tick at the expected far position, before AVPlayer can produce a
        // buffer for ~2.5s. The output is wrong-time and must be rejected.
        let immediate = provider.frameTextureForPlayback(expectedVideoTime: 2.5)

        if provider.debugAwaitingFirstPlaybackBuffer {
            // Still awaiting: the gate rejected (or there was no buffer). Either way the
            // contract holds — no stale/wrong texture was handed back for binding.
            XCTAssertNil(immediate,
                "While awaiting the first accepted buffer, a wrong-time output must not be returned for binding")
            // If the gate evaluated this tick, it must have been a rejection.
            if let decision = provider.debugLastFirstBufferAccepted {
                XCTAssertFalse(decision,
                    "A wrong-time first output must be a rejection, not an acceptance")
            }
        } else {
            // Suppression lifted only if a within-tolerance buffer for ~2.5s actually
            // arrived this fast (acceptance) — then a real texture is valid.
            XCTAssertEqual(provider.debugLastFirstBufferAccepted, true,
                "Suppression may only lift via an accepted within-tolerance buffer")
        }

        provider.release()
    }

    /// The gate must not interfere with continuous playback: once the first buffer is
    /// accepted (suppression lifted), later ticks bypass the gate entirely.
    func testFirstBufferGate_afterAcceptance_continuousPlaybackUngated() async throws {
        let provider = try await makeReadyProvider(duration: 3.0)
        provider.setPlaybackWindow(start: 0, end: 3.0)

        // Warm from t=0 where the first output is genuinely near the expected time, so
        // the gate accepts and lifts suppression.
        provider.startPlayback(atVideoTime: 0.0)
        var warm: MTLTexture?
        for _ in 0..<30 {
            warm = provider.frameTextureForPlayback(expectedVideoTime: 0.0)
            if warm != nil && !provider.debugAwaitingFirstPlaybackBuffer { break }
            try await Task.sleep(nanoseconds: 33_000_000)
        }
        XCTAssertNotNil(warm, "First session should accept a real near-zero buffer")
        XCTAssertFalse(provider.debugAwaitingFirstPlaybackBuffer,
            "Suppression should lift after the first accepted buffer")

        // A subsequent tick is not gated (awaitingFirstPlaybackBuffer == false), so the
        // gate decision is not evaluated this tick.
        _ = provider.frameTextureForPlayback(expectedVideoTime: 0.1)
        XCTAssertNil(provider.debugLastFirstBufferAccepted,
            "Continuous playback ticks must not evaluate the first-buffer gate")

        provider.release()
    }

    #endif
}
