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

    #endif
}
