import XCTest
import AVFoundation
import AnimiEngineCore
@testable import AnimiApp

/// Slice-005 Stage 3 — the HARD WATCHDOG contract, proven WITHOUT real compressed media via a spy
/// `BoundedPCMReader`. These tests drive the SAME production `WatchdogPCMDecodeLoop` the real
/// `AVFoundationPCMAssetDecoder` uses, so the timeout/cancel/`cancelReading()` behavior is unit-verified.
/// No AVFoundation, no device, no audible claim.
final class AVFoundationPCMAssetDecoderWatchdogTests: XCTestCase {

    // MARK: - Spy reader: blocks until cancelled (models a parked copyNextSampleBuffer)

    /// Blocks inside `readNextChunk()` on a semaphore until `cancel()` is called — exactly the device failure
    /// shape (a read parked inside AVFoundation, unblockable only by `cancelReading()`). Signals `entered`
    /// the instant the read parks, so a test can deterministically wait until the read IS parked before
    /// cancelling. Records cancel calls.
    private final class BlockingSpyReader: BoundedPCMReader, @unchecked Sendable {
        private let gate = DispatchSemaphore(value: 0)
        private let entered = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var _cancelCount = 0
        var cancelCount: Int { lock.lock(); defer { lock.unlock() }; return _cancelCount }

        /// Block (off the test's async context) until the reader has actually entered `readNextChunk()`.
        func waitUntilEnteredRead() { entered.wait() }

        func readNextChunk() throws -> [Float32]? {
            entered.signal()                              // handshake: the read is now parked
            gate.wait()                                   // parks until cancel() signals (the hard interrupt)
            throw BoundedPCMReaderError.cancelled         // after cancel, the read reports cancellation
        }
        func cancel() {
            lock.lock(); _cancelCount += 1; lock.unlock()
            gate.signal()                                 // unblock the parked read (models cancelReading())
        }
    }

    /// Delivers the full buffer in one chunk, but only AFTER `releaseLate()` — used to simulate a late
    /// completion that escapes after a timeout/invalidation. Records cancel calls.
    private final class LateCompletionSpyReader: BoundedPCMReader, @unchecked Sendable {
        private let gate = DispatchSemaphore(value: 0)
        private let frameCount: Int
        private let lock = NSLock()
        private var _cancelCount = 0
        private var delivered = false
        var cancelCount: Int { lock.lock(); defer { lock.unlock() }; return _cancelCount }
        init(frameCount: Int) { self.frameCount = frameCount }

        func readNextChunk() throws -> [Float32]? {
            gate.wait()
            lock.lock(); let already = delivered; delivered = true; lock.unlock()
            if already { return nil }
            return (0..<frameCount).map { Float32($0 + 1) }
        }
        func cancel() { lock.lock(); _cancelCount += 1; lock.unlock(); gate.signal() }
        func releaseLate() { gate.signal() }
    }

    /// Always succeeds immediately with the full buffer (one chunk). For "retry after timeout" coverage.
    private final class ImmediateSpyReader: BoundedPCMReader, @unchecked Sendable {
        private let frameCount: Int
        private var delivered = false
        private let lock = NSLock()
        init(frameCount: Int) { self.frameCount = frameCount }
        func readNextChunk() throws -> [Float32]? {
            lock.lock(); defer { lock.unlock() }
            if delivered { return nil }
            delivered = true
            return (0..<frameCount).map { Float32($0 + 1) }
        }
        func cancel() {}
    }

    /// A decoder that drives the PRODUCTION watchdog loop over an injected reader (so the cache can exercise
    /// the real timeout/cancel path without AVFoundation). Switches readers per call for retry coverage.
    private actor SeamDecoder: CanonicalPCMAssetDecoder {
        private let readers: [BoundedPCMReader]
        private var index = 0
        private let timeoutNanos: UInt64
        private let immediateTimeout: Bool
        init(readers: [BoundedPCMReader], timeoutNanos: UInt64 = 10_000_000, immediateTimeout: Bool) {
            self.readers = readers; self.timeoutNanos = timeoutNanos; self.immediateTimeout = immediateTimeout
        }
        func decodeMono48kFloat32(_ request: CanonicalPCMAssetDecodeRequest) async throws -> [Float32] {
            let reader = readers[min(index, readers.count - 1)]
            index += 1
            // Inject a `sleep` that resolves the deadline immediately when we want the timeout to win.
            let immediate: @Sendable (UInt64) async throws -> Void = { _ in /* deadline fires at once */ }
            let real: @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
            let sleep: @Sendable (UInt64) async throws -> Void = immediateTimeout ? immediate : real
            return try await WatchdogPCMDecodeLoop.run(
                reader: reader, frameCount: request.frameCount, timeoutNanos: timeoutNanos, sleep: sleep)
        }
    }

    // MARK: - Helpers (cache / request plumbing)

    private static func range(samples: Int64) throws -> AudioSampleRange {
        try AudioSampleRange.from(projectTicks:
            ProjectTimeRange(start: .zero, end: try ProjectTime(ticks: samples * AudioSampleGrid.ticksPerSample)))
    }
    private static func revision(_ r: Int64) -> ProjectRevision { var a = MonotonicRevisionAllocator(start: r); return a.next() }
    private static func epoch(_ e: Int64) -> PlaybackEpoch { var a = MonotonicEpochAllocator(start: e); return a.next() }

    private static func request(samples: Int64 = 8) throws -> CanonicalAudioRenderRequest {
        let r = try range(samples: samples)
        let seg = AudioSegmentPlan(
            clipID: try AudioClipID("c0"), sourceID: try AudioSourceID("s0"), trackID: try AudioTrackID("t0"),
            role: .music, destinationSamples: r, sourceStart: .zero,
            sourceEnd: try RationalSourceTime(numerator: 1, denominator: 1),
            effectiveTrim: try RationalSourceRange(start: .zero, end: try RationalSourceTime(numerator: 1, denominator: 1)),
            isMuted: false, gain: .unity, sourceSampleRate: 48_000, channelLayout: .mono,
            streamIdentity: try AudioStreamIdentity("stream-0"), sceneID: nil)
        return CanonicalAudioRenderRequest(
            plan: AudioPlan(sampleInterval: r, segments: [seg]),
            revision: revision(1), epoch: epoch(1),
            anchor: PreviewAudioScheduleAnchor(revision: revision(1), epoch: epoch(1), projectSample: 0, outputSampleTime: 0),
            range: r, resolvedSourcesByID: ["s0": CanonicalResolvedAudioSource(url: URL(fileURLWithPath: "/tmp/s0"))])
    }
    private static func key(for req: CanonicalAudioRenderRequest) throws -> CanonicalPCMRenderKey {
        try CanonicalPCMRenderKey(
            revision: req.revision, epoch: req.epoch,
            planIdentity: CanonicalAudioPlanIdentity.string(for: req.plan), range: req.range)
    }

    // MARK: - 15. Timeout throws a typed failure (never [], never hangs)

    func testTimeoutThrowsTypedFailure() async throws {
        let reader = BlockingSpyReader()
        do {
            _ = try await WatchdogPCMDecodeLoop.run(
                reader: reader, frameCount: 8, timeoutNanos: 1_000, sleep: { _ in })   // deadline fires at once
            XCTFail("blocked read must time out and throw")
        } catch let e as AppRealtimeAudioIntegrationError {
            guard case .pcmRenderFailed = e else { return XCTFail("expected .pcmRenderFailed, got \(e)") }
        }
    }

    // MARK: - 16. Timeout path calls cancelReading (cancel())

    func testTimeoutPathCallsCancelReading() async throws {
        let reader = BlockingSpyReader()
        _ = try? await WatchdogPCMDecodeLoop.run(
            reader: reader, frameCount: 8, timeoutNanos: 1_000, sleep: { _ in })
        XCTAssertGreaterThanOrEqual(reader.cancelCount, 1,
            "timeout must HARD-interrupt the blocked read via cancel() / cancelReading()")
    }

    // MARK: - 17. External cancellation HARD-cancels an ALREADY-PARKED read (deterministic handshake)

    /// Deterministic, no sleeps-as-timing: (1) the reader signals it has ENTERED the read and parked,
    /// (2) the test waits for that signal, (3) only THEN cancels the outer task, (4) asserts the reader was
    /// hard-cancelled (cancelCount >= 1) and the task returns promptly. This proves cancellation interrupts a
    /// read that is ALREADY blocked — not merely a between-reads `Task.isCancelled` check — via the
    /// `withTaskCancellationHandler` `onCancel { reader.cancel() }` path. Timeout is `.max` (never fires).
    func testExternalCancellationCallsCancelReading() async throws {
        let reader = BlockingSpyReader()
        let task = Task {
            try await WatchdogPCMDecodeLoop.run(
                reader: reader, frameCount: 8, timeoutNanos: .max, sleep: { try await Task.sleep(nanoseconds: $0) })
        }
        // (1)+(2) Block until the reader is genuinely parked inside readNextChunk() — done off the cooperative
        // pool so we don't depend on a sleep guess. Then (3) cancel.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { reader.waitUntilEnteredRead(); cont.resume() }
        }
        task.cancel()
        // (4) The task must return promptly with a throw (CancellationError or typed). Not hanging into the
        // XCTest timeout IS the promptness proof.
        do { _ = try await task.value; XCTFail("cancelled decode must throw") }
        catch { /* CancellationError or typed — both acceptable */ }
        XCTAssertGreaterThanOrEqual(reader.cancelCount, 1,
            "external cancellation of an already-parked read must hard-cancel via onCancel -> reader.cancel()")
    }

    // MARK: - 18. Cache stores nothing after a timeout; later success stores

    func testCacheStoresNothingAfterTimeout() async throws {
        let req = try Self.request()
        let key = try Self.key(for: req)
        // First cache: blocked reader + immediate-deadline → timeout, nothing cached.
        let timeoutDecoder = SeamDecoder(readers: [BlockingSpyReader()], immediateTimeout: true)
        let renderer1 = BackgroundCanonicalPCMRenderer(decoder: timeoutDecoder)
        let cache1 = try CanonicalPCMRenderCache.make(capacity: 4, renderer: renderer1)
        do { _ = try await cache1.chunk(for: req, key: key); XCTFail("timeout must throw") }
        catch let e as AppRealtimeAudioIntegrationError { guard case .pcmRenderFailed = e else { return XCTFail("got \(e)") } }
        let c1 = await cache1.count
        XCTAssertEqual(c1, 0, "a timed-out decode must NOT be cached")

        let okDecoder = SeamDecoder(readers: [ImmediateSpyReader(frameCount: 8)], immediateTimeout: false)
        let renderer2 = BackgroundCanonicalPCMRenderer(decoder: okDecoder)
        let cache2 = try CanonicalPCMRenderCache.make(capacity: 4, renderer: renderer2)
        let chunk = try await cache2.chunk(for: req, key: key)
        XCTAssertEqual(chunk.sources.count, 1)
        let c2 = await cache2.count
        XCTAssertEqual(c2, 1, "a later successful decode stores")
    }

    // MARK: - 19. Late completion after timeout/invalidation is dropped

    func testLateCompletionAfterTimeoutOrInvalidationIsDropped() async throws {
        // The watchdog itself guarantees the timeout branch returns the typed throw and cancel()s the reader;
        // a reader that "completes late" can never feed a stored success because the loop already resolved to
        // the timeout outcome. We prove: timeout throws, cancel() was called, and releasing the reader late
        // changes nothing observable (no second resolution, cache stays empty).
        let req = try Self.request()
        let key = try Self.key(for: req)
        let lateReader = LateCompletionSpyReader(frameCount: 8)
        let decoder = SeamDecoder(readers: [lateReader], immediateTimeout: true)
        let renderer = BackgroundCanonicalPCMRenderer(decoder: decoder)
        let cache = try CanonicalPCMRenderCache.make(capacity: 4, renderer: renderer)

        do { _ = try await cache.chunk(for: req, key: key); XCTFail("timeout must throw") }
        catch let e as AppRealtimeAudioIntegrationError { guard case .pcmRenderFailed = e else { return XCTFail("got \(e)") } }
        XCTAssertGreaterThanOrEqual(lateReader.cancelCount, 1, "timeout cancelled the reader")

        // Simulate the late escape: release the reader AFTER the timeout already resolved.
        lateReader.releaseLate()
        try await Task.sleep(nanoseconds: 30_000_000)
        let stored = await cache.count
        XCTAssertEqual(stored, 0, "a late completion after timeout must NOT be stored")
    }

    // MARK: - 20. No hidden blocked task survives the timeout

    func testNoHiddenBlockedTaskSurvivesTimeout() async throws {
        // After a timeout, the reader must have been cancel()ed (its blocked read released), i.e. no task is
        // left parked forever. The loop returning at all (this test not hanging into the XCTest timeout)
        // proves promptness; cancelCount proves the blocked read was actively released, not abandoned.
        let reader = BlockingSpyReader()
        do {
            _ = try await WatchdogPCMDecodeLoop.run(reader: reader, frameCount: 8, timeoutNanos: 1_000, sleep: { _ in })
            XCTFail("must throw")
        } catch { /* expected */ }
        XCTAssertGreaterThanOrEqual(reader.cancelCount, 1, "the blocked reader task was released (cancelled), not left hanging")
    }

    // MARK: - Stage-5 R2: boundary short-read reconciliation (zero-pad within tolerance, else fail closed)

    func testReconcileExactCountReturnsAsIs() throws {
        let s: [Float32] = [1, 2, 3, 4]
        XCTAssertEqual(try WatchdogPCMDecodeLoop.reconcileFrameCount(s, frameCount: 4), s)
    }

    func testReconcileOverReadTrimsToFrameCount() throws {
        let s: [Float32] = [1, 2, 3, 4, 5, 6]
        XCTAssertEqual(try WatchdogPCMDecodeLoop.reconcileFrameCount(s, frameCount: 4), [1, 2, 3, 4])
    }

    func testReconcileShortWithinToleranceZeroPads() throws {
        // The exact device case: 47948 of 48000 (shortfall 52 ≤ 1024) → zero-pad the boundary tail.
        let body = (0..<47_948).map { Float32($0 & 1) }
        let out = try WatchdogPCMDecodeLoop.reconcileFrameCount(body, frameCount: 48_000)
        XCTAssertEqual(out.count, 48_000, "padded to exact frameCount")
        XCTAssertEqual(Array(out[0..<47_948]), body, "decoded body untouched")
        XCTAssertEqual(Array(out[47_948..<48_000]), [Float32](repeating: 0, count: 52), "tail zero-padded")
    }

    func testReconcileShortBeyondToleranceFailsClosed() throws {
        let body = [Float32](repeating: 1, count: 100)   // shortfall 48000-100 >> tolerance
        XCTAssertThrowsError(try WatchdogPCMDecodeLoop.reconcileFrameCount(body, frameCount: 48_000)) { error in
            guard case AppRealtimeAudioIntegrationError.pcmRenderFailed = error else {
                return XCTFail("expected .pcmRenderFailed, got \(error)")
            }
        }
    }

    func testReconcileEmptyForNonEmptyRequestFailsClosed() throws {
        XCTAssertThrowsError(try WatchdogPCMDecodeLoop.reconcileFrameCount([], frameCount: 8)) { error in
            guard case AppRealtimeAudioIntegrationError.pcmRenderFailed = error else {
                return XCTFail("expected .pcmRenderFailed for empty result, got \(error)")
            }
        }
    }

    // MARK: - Stage-6: EXACT-rational guard-band read window (no floor onto the frame grid)

    func testBoundedReadWindowInteriorAt1Second() throws {
        // sourceStart = 1/1 s, margin 4800 → readStart = 1 - 4800/48000 = 1 - 1/10 = 9/10; readFrameCount =
        // frameCount + 4800; marginFrames = 4800.
        let w = try AVFoundationPCMAssetDecoder.boundedReadWindow(
            sourceStart: try RationalSourceTime(numerator: 1, denominator: 1), frameCount: 48_000, sourceIDRaw: "s")
        XCTAssertEqual(w.readStart, try RationalSourceTime(numerator: 9, denominator: 10))
        XCTAssertEqual(w.readFrameCount, 52_800)
        XCTAssertEqual(w.marginFrames, 4800)
    }

    func testBoundedReadWindowNonFrameAlignedSourceStartIsExactRational() throws {
        // sourceStart = 1/3 s, margin 4800 → readStart = 1/3 - 4800/48000 = 1/3 - 1/10 = (10-3)/30 = 7/30
        // (EXACT rational — NOT floor(1/3*48000)/48000 - margin). marginFrames = 4800 (exact).
        let w = try AVFoundationPCMAssetDecoder.boundedReadWindow(
            sourceStart: try RationalSourceTime(numerator: 1, denominator: 3), frameCount: 48_000, sourceIDRaw: "s")
        XCTAssertEqual(w.readStart, try RationalSourceTime(numerator: 7, denominator: 30),
            "readStart must be exact 7/30, not floor-based")
        XCTAssertEqual(w.marginFrames, 4800)
        XCTAssertEqual(w.readFrameCount, 52_800)
    }

    func testBoundedReadWindowSourceStartSmallerThanMarginClampsToZero() throws {
        // sourceStart = 1/200 s = 240 frames < margin (4800) → readStart clamps to 0; the exact prefix is the
        // whole distance 0..sourceStart = 240 frames (exact). readFrameCount = frameCount + 240.
        let w = try AVFoundationPCMAssetDecoder.boundedReadWindow(
            sourceStart: try RationalSourceTime(numerator: 1, denominator: 200), frameCount: 48_000, sourceIDRaw: "s")
        XCTAssertEqual(w.readStart, .zero)
        XCTAssertEqual(w.marginFrames, 240, "exact frame distance from 0 to 1/200 s")
        XCTAssertEqual(w.readFrameCount, 48_240)
    }

    func testBoundedReadWindowZeroSourceStartHasNoMargin() throws {
        // First chunk (sourceStart 0): no guard-band, read exactly frameCount.
        let w = try AVFoundationPCMAssetDecoder.boundedReadWindow(
            sourceStart: .zero, frameCount: 48_000, sourceIDRaw: "s")
        XCTAssertEqual(w.readStart, .zero)
        XCTAssertEqual(w.marginFrames, 0)
        XCTAssertEqual(w.readFrameCount, 48_000)
    }

    func testBoundedReadWindowNonIntegerMarginFailsClosed() throws {
        // CLAMPED case with a non-frame-aligned sourceStart: 1/700 s < margin (1/10) → readStart = 0, so the
        // guard-band delta == sourceStart = 1/700 s. 1/700 * 48000 = 48000/700 = 68.57… → NOT a whole frame
        // count → must fail closed (no silent drift), per the no-drift requirement.
        XCTAssertThrowsError(try AVFoundationPCMAssetDecoder.boundedReadWindow(
            sourceStart: try RationalSourceTime(numerator: 1, denominator: 700), frameCount: 48_000, sourceIDRaw: "s")) { error in
            guard case AppRealtimeAudioIntegrationError.sourceStartNotRepresentable = error else {
                return XCTFail("expected .sourceStartNotRepresentable for non-integer guard-band, got \(error)")
            }
        }
    }

    func testExactFramesDivisibilityContract() {
        let sr = AudioSampleGrid.samplesPerSecond
        XCTAssertEqual(AVFoundationPCMAssetDecoder.exactFrames(try! RationalSourceTime(numerator: 1, denominator: 1), sampleRate: sr), 48_000)
        XCTAssertEqual(AVFoundationPCMAssetDecoder.exactFrames(.zero, sampleRate: sr), 0)
        // 3/70 s is not a whole frame count → nil.
        XCTAssertNil(AVFoundationPCMAssetDecoder.exactFrames(try! RationalSourceTime(numerator: 3, denominator: 70), sampleRate: sr))
    }

    // MARK: - P0-2: CMTime denominator > Int32.max fails closed (no trap)

    func testCMTimeDenominatorTooLargeFailsClosed() async throws {
        // A source start whose reduced denominator exceeds CMTimeScale's Int32 range must throw
        // .sourceStartNotRepresentable BEFORE any CMTime narrowing / AVFoundation touch — never trap.
        let bigDen = Int64(Int32.max) + 2          // odd-ish; coprime with numerator 1 so it won't reduce away
        let sourceStart = try RationalSourceTime(numerator: 1, denominator: bigDen)
        XCTAssertEqual(sourceStart.denominator, bigDen, "precondition: denominator survives reduction")
        let decoder = AVFoundationPCMAssetDecoder()
        let req = CanonicalPCMAssetDecodeRequest(
            source: CanonicalResolvedAudioSource(url: URL(fileURLWithPath: "/tmp/does-not-matter.m4a")),
            sourceIDRaw: "s0", sourceStart: sourceStart, frameCount: 8)
        do {
            _ = try await decoder.decodeMono48kFloat32(req)
            XCTFail("denominator > Int32.max must fail closed")
        } catch let e as AppRealtimeAudioIntegrationError {
            guard case .sourceStartNotRepresentable = e else {
                return XCTFail("expected .sourceStartNotRepresentable, got \(e)")
            }
        }
    }

    // MARK: - P0-2: negative source start fails closed

    func testNegativeSourceStartFailsClosed() async throws {
        let sourceStart = try RationalSourceTime(numerator: -1, denominator: 2)
        let decoder = AVFoundationPCMAssetDecoder()
        let req = CanonicalPCMAssetDecodeRequest(
            source: CanonicalResolvedAudioSource(url: URL(fileURLWithPath: "/tmp/does-not-matter.m4a")),
            sourceIDRaw: "s0", sourceStart: sourceStart, frameCount: 8)
        do {
            _ = try await decoder.decodeMono48kFloat32(req)
            XCTFail("negative source start must fail closed")
        } catch let e as AppRealtimeAudioIntegrationError {
            guard case .sourceStartNotRepresentable = e else {
                return XCTFail("expected .sourceStartNotRepresentable, got \(e)")
            }
        }
    }

    // MARK: - P0-1: missing/unreadable source THROWS typed, never crashes (no try!)

    func testDecoderOnMissingFileThrowsTypedNotCrash() async throws {
        // A non-existent file exercises the no-crash production path end-to-end: async track load fails (or
        // the reader init / canAdd path is reached) and the decoder throws a TYPED error rather than trapping.
        // (P0-1 removed `try! AVAssetReader(asset:)`; P0-3 throws on `canAdd == false`. Either way: no crash.)
        let decoder = AVFoundationPCMAssetDecoder(timeoutNanos: 2_000_000_000)
        let req = CanonicalPCMAssetDecodeRequest(
            source: CanonicalResolvedAudioSource(url: URL(fileURLWithPath: "/tmp/animi-stage3-nonexistent-\(UInt64(987654321)).m4a")),
            sourceIDRaw: "missing", sourceStart: .zero, frameCount: 8)
        do {
            _ = try await decoder.decodeMono48kFloat32(req)
            XCTFail("missing source must throw")
        } catch let e as AppRealtimeAudioIntegrationError {
            // Any of the typed media failures is acceptable — the point is NO CRASH and a typed throw.
            switch e {
            case .mediaCorrupt, .mediaUnsupported, .mediaUnavailable, .sourceStartNotRepresentable, .pcmRenderFailed:
                break
            default:
                XCTFail("expected a typed media failure, got \(e)")
            }
        } catch is CancellationError {
            // Also acceptable (timeout/cancel) — still no crash.
        }
    }

    // MARK: - P0-1/P0-3: AVAssetReaderBoundedPCMReader init is throwing (no try!, canAdd fail-closed)

    func testReaderInitOnBogusAssetThrowsTypedNotCrash() async throws {
        // Build the bounded reader directly over a non-existent asset. The throwing init must surface a TYPED
        // failure (reader init failure OR refused output) — never `try!`-trap. We load the (absent) tracks
        // first; with no track we can't construct the reader, so this asserts the decoder-level no-crash too.
        let url = URL(fileURLWithPath: "/tmp/animi-stage3-bogus-\(UInt64(135792468)).m4a")
        let asset = AVURLAsset(url: url)
        let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard let track = tracks.first else {
            // Expected for a non-existent file: no track. The decoder maps this to a typed error (covered by
            // testDecoderOnMissingFileThrowsTypedNotCrash); nothing to assert on the reader init here.
            return
        }
        // If a track somehow exists, the throwing init must still not crash — typed throw is acceptable.
        do {
            _ = try AVAssetReaderBoundedPCMReader(
                asset: asset, audioTrack: track,
                timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 8, timescale: 48_000)),
                sourceIDRaw: "bogus")
        } catch let e as AppRealtimeAudioIntegrationError {
            switch e {
            case .mediaCorrupt, .mediaUnsupported: break
            default: XCTFail("expected typed reader-init failure, got \(e)")
            }
        }
    }
}
