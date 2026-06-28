import Foundation
import AVFoundation
import AnimiEngineCore

// =============================================================================================
//  Slice-005 Stage 3 / Stage-6 Candidate A — the ONLY production file allowed to import AVFoundation
//  and use AVURLAsset / AVAssetReader / AVAssetReaderTrackOutput / copyNextSampleBuffer / cancelReading.
//
//  It implements the real `CanonicalPCMAssetDecoder` with a HARD WATCHDOG: a decode owns one
//  AVAssetReader, runs the read loop OFF the main actor, and a SEPARATE timeout/cancel path calls
//  `reader.cancelReading()` to forcibly unblock a parked `copyNextSampleBuffer()`. Decode resolves
//  EXACTLY once — full bounded buffer OR typed throw — and never leaves a hidden blocked task that can
//  store success late. Non-empty audio failures THROW; they never become [].
//
//  STAGE-6 CANDIDATE A — BOUNDED SOURCE-WINDOW/SESSION:
//  The interior-chunk device blocker was caused by opening a NEW `AVAssetReader` at a NON-ZERO
//  `timeRange.start` for EVERY consecutive chunk: each re-seek over a compressed source re-primed the
//  decoder and dropped ~2285–2501 frames that a per-chunk guard-band could not recover. Candidate A
//  removes the per-chunk re-seek for the common (continuous-playback) case: one bounded `AVAssetReader`
//  SESSION is opened once over a BOUNDED source window and read SEQUENTIALLY FORWARD; consecutive,
//  exactly-contiguous chunk requests are served from the live reader with NO new reader and NO re-seek.
//
//  Strict invariants (Stage-6 plan-change §5 Candidate A, §8 STOP):
//   - one `AVAssetReader` session only, for a BOUNDED source window (never whole-source / whole-project,
//     never a temp CAF);
//   - exact-rational source time preserved end to end (the session cursor is a `RationalSourceTime`);
//   - external `CanonicalPCMAssetDecoder` contract unchanged (exactly `frameCount` samples or a throw);
//   - a non-contiguous / backward / different-source / window-exhausted request is NOT served from the
//     live session — the session is torn down and a NEW bounded session is opened (fail-closed split);
//     the decoder NEVER silently reuses a wrong session;
//   - no tolerance increase (`maxBoundaryShortfallFrames` unchanged) and no further guard-band growth.
// =============================================================================================

// MARK: - Reader seam (makes the watchdog unit-testable without real compressed media)

/// A bounded mono-48k-Float32 PCM reader for ONE decode. The watchdog loop drives it; a test spy can stand
/// in for the real `AVAssetReader`-backed reader to prove timeout/cancel behavior without AVFoundation.
///
/// `readNextChunk()` returns the next decoded sample batch, or `nil` at end-of-stream. It MAY block (the
/// real `copyNextSampleBuffer()` blocks inside AVFoundation). `cancel()` is the HARD interrupt — it must
/// unblock a parked `readNextChunk()` (the real impl calls `AVAssetReader.cancelReading()`).
protocol BoundedPCMReader: Sendable {
    func readNextChunk() throws -> [Float32]?
    func cancel()
}

/// Typed reader-seam failures distinct from the app-level error (kept internal to the decode boundary).
enum BoundedPCMReaderError: Error, Equatable, Sendable {
    case cancelled
    case readerFailed(String)
}

// MARK: - Watchdog decode loop (pure, testable; no AVFoundation)

/// Drives a `BoundedPCMReader` to produce exactly `frameCount` frames under a HARD watchdog.
///
/// Guarantees (the P0 contract):
///   - the read loop runs OFF the main actor (the caller awaits this from a non-main context; the loop
///     itself asserts it is not on the main thread);
///   - a separate deadline path calls `reader.cancel()` on timeout, which unblocks a parked read;
///   - structured cancellation of the enclosing task also calls `reader.cancel()`;
///   - resolves EXACTLY once: the full `[Float32]` of length `frameCount`, or a thrown error — never a
///     partial/late buffer, never `[]` for audible content.
enum WatchdogPCMDecodeLoop {

    /// Run the bounded read under the watchdog. `nowNanos`/`deadlineNanos` are injectable so tests can drive
    /// the timeout deterministically; production passes a real monotonic clock + computed deadline.
    static func run(
        reader: BoundedPCMReader,
        frameCount: Int,
        timeoutNanos: UInt64,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) async throws -> [Float32] {
        // External cancellation HARD-interrupts the reader IMMEDIATELY (does not wait for the read loop to
        // reach `Task.isCancelled` between reads, nor for the timeout): `onCancel` calls `reader.cancel()` the
        // instant the enclosing task is cancelled, unblocking a parked `copyNextSampleBuffer()`.
        return try await withTaskCancellationHandler {
            try await runGroup(reader: reader, frameCount: frameCount, timeoutNanos: timeoutNanos, sleep: sleep)
        } onCancel: {
            reader.cancel()
        }
    }

    private static func runGroup(
        reader: BoundedPCMReader,
        frameCount: Int,
        timeoutNanos: UInt64,
        sleep: @escaping @Sendable (UInt64) async throws -> Void
    ) async throws -> [Float32] {
        // Race the off-main reader task against a deadline task. Whichever finishes first wins; the loser is
        // cancelled, and the reader is HARD-cancelled so a parked read cannot keep running and resolve late.
        return try await withThrowingTaskGroup(of: ReadOutcome.self) { group in
            // Reader task — runs the (possibly blocking) read loop off the main actor.
            group.addTask {
                // PROVE off-main at runtime (behavioral guard, not just compile-level): a MainActor hop here
                // would crash the test rather than silently re-introduce the device hang.
                dispatchPrecondition(condition: .notOnQueue(.main))
                do {
                    var out = [Float32]()
                    out.reserveCapacity(frameCount)
                    while out.count < frameCount {
                        if Task.isCancelled { reader.cancel(); throw CancellationError() }
                        guard let chunk = try reader.readNextChunk() else { break }  // nil = end of stream
                        out.append(contentsOf: chunk)
                    }
                    return .read(out)
                } catch let e as BoundedPCMReaderError {
                    if case .cancelled = e { throw CancellationError() }
                    throw e
                }
            }
            // Deadline task — the HARD watchdog. On expiry it cancels the reader (unblocking a parked read).
            group.addTask {
                try await sleep(timeoutNanos)
                return .timedOut
            }

            defer { group.cancelAll() }
            // First outcome decides everything; the group's cancellation + the reader.cancel() below stop the
            // other task. There is no path where the loser resolves late into a stored success.
            while let outcome = try await group.next() {
                switch outcome {
                case .read(let samples):
                    reader.cancel()   // ensure the reader is torn down; no late delivery possible
                    return try reconcileFrameCount(samples, frameCount: frameCount)
                case .timedOut:
                    reader.cancel()   // HARD interrupt: unblocks a parked copyNextSampleBuffer()
                    throw AppRealtimeAudioIntegrationError.pcmRenderFailed(
                        reason: "decode timeout after \(timeoutNanos) ns")
                }
            }
            // Unreachable: the group always yields at least one outcome. Fail closed if it ever does not.
            reader.cancel()
            throw AppRealtimeAudioIntegrationError.pcmRenderFailed(reason: "decode produced no outcome")
        }
    }

    private enum ReadOutcome: Sendable {
        case read([Float32])
        case timedOut
    }

    /// Maximum allowed boundary frame shortfall before fail-closed (Stage-5 device blocker R2). Compressed
    /// sources (AAC/MP3) carry encoder priming / gapless padding, so `AVAssetReader` over an exact
    /// `CMTimeRange` can return a HANDFUL fewer frames at the boundary (observed: 47948 vs 48000 → 52 short).
    /// We zero-pad up to this small tolerance (the missing tail is genuine boundary silence — inaudible) and
    /// STILL fail closed for a larger shortfall (a real decode fault, not boundary trim). NOT a silent
    /// substitution for audible content: the decoded body is intact; only the bounded-chunk tail is padded.
    /// 1024 frames ≈ 21 ms @ 48 kHz — comfortably above any priming tail, far below "lost audio".
    /// STAGE-6 CANDIDATE A: this tolerance is UNCHANGED. Candidate A removes the interior re-seek that caused
    /// the LARGE (2285–2501-frame) interior shortfall; it does NOT widen this boundary tolerance.
    static let maxBoundaryShortfallFrames = 1024

    /// Reconcile the decoded count to EXACTLY `frameCount`:
    ///   - exact → return as-is;
    ///   - over-read (rare) → trim to `frameCount` (extra boundary frames dropped);
    ///   - short by ≤ tolerance AND non-empty → zero-pad the tail to `frameCount` (boundary priming/padding);
    ///   - short by > tolerance, or empty for a non-empty request → fail closed `.pcmRenderFailed`.
    static func reconcileFrameCount(_ samples: [Float32], frameCount: Int) throws -> [Float32] {
        if samples.count == frameCount { return samples }
        if samples.count > frameCount { return Array(samples.prefix(frameCount)) }
        let shortfall = frameCount - samples.count
        guard !samples.isEmpty, shortfall <= maxBoundaryShortfallFrames else {
            throw AppRealtimeAudioIntegrationError.pcmRenderFailed(
                reason: "decode produced \(samples.count) frames, expected \(frameCount) (shortfall \(shortfall) > tolerance \(maxBoundaryShortfallFrames))")
        }
        return samples + [Float32](repeating: 0, count: shortfall)
    }
}

// MARK: - Real AVAssetReader-backed bounded reader

/// Wraps one `AVAssetReader` + `AVAssetReaderTrackOutput` for a bounded mono-48k-Float32 read. Owns the
/// reader lifetime; `cancel()` calls `AVAssetReader.cancelReading()` — the hard interrupt for a parked read.
///
/// STAGE-6 CANDIDATE A: this reader now backs a long-lived SESSION. It reads SEQUENTIALLY FORWARD over its
/// bounded `timeRange`. `readForward(frameCount:)` pulls exactly that many frames from the SAME open reader
/// without re-seeking, buffering any over-read tail for the next call. `cancel()` still hard-interrupts and
/// tears down the reader (end of session). It is driven only by the off-main session loop + the watchdog's
/// `cancel()`, and `cancelReading()` is documented thread-safe — hence `@unchecked Sendable`.
final class AVAssetReaderBoundedPCMReader: BoundedPCMReader, @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var started = false
    private let lock = NSLock()
    /// Frames decoded past a previous `readForward` request (the tail of an over-read CMSampleBuffer), kept so
    /// the NEXT forward read consumes them first — sequential, no re-seek, no dropped samples.
    private var carry: [Float32] = []
    /// True once the underlying reader has reached end-of-range (no more samples will ever come).
    private var ended = false

    /// Fail-closed throwing init (no force-try). An `AVAssetReader(asset:)` failure or a refused output is a
    /// typed error (`sourceIDRaw` carried for diagnostics) — never a crash.
    init(asset: AVURLAsset, audioTrack: AVAssetTrack, timeRange: CMTimeRange, sourceIDRaw: String) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: AudioSampleGrid.samplesPerSecond,
        ]
        do {
            self.reader = try AVAssetReader(asset: asset)
        } catch {
            throw AppRealtimeAudioIntegrationError.mediaCorrupt(
                sourceRaw: sourceIDRaw, detail: "AVAssetReader init failed: \(error.localizedDescription)")
        }
        self.reader.timeRange = timeRange
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        // Fail closed: a refused output must NOT silently proceed (it would yield an empty/garbage read).
        guard self.reader.canAdd(output) else {
            throw AppRealtimeAudioIntegrationError.mediaUnsupported(
                sourceRaw: sourceIDRaw, detail: "AVAssetReader cannot add the mono-48k-Float32 PCM output")
        }
        self.reader.add(output)
        self.output = output
    }

    func readNextChunk() throws -> [Float32]? {
        lock.lock()
        if !started {
            guard reader.startReading() else {
                lock.unlock()
                throw BoundedPCMReaderError.readerFailed("startReading failed: \(reader.status.rawValue)")
            }
            started = true
        }
        lock.unlock()

        guard let sampleBuffer = output.copyNextSampleBuffer() else {
            // nil = end-of-range OR cancellation/failure. Distinguish via status.
            switch reader.status {
            case .completed, .reading: return nil       // end of bounded range
            case .cancelled: throw BoundedPCMReaderError.cancelled
            case .failed: throw BoundedPCMReaderError.readerFailed(reader.error?.localizedDescription ?? "reader failed")
            default: return nil
            }
        }
        defer { CMSampleBufferInvalidate(sampleBuffer) }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return []   // no data in this buffer; loop continues
        }
        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let dataPointer else {
            throw BoundedPCMReaderError.readerFailed("CMBlockBufferGetDataPointer status \(status)")
        }
        let floatCount = totalLength / MemoryLayout<Float32>.size
        let samples = dataPointer.withMemoryRebound(to: Float32.self, capacity: floatCount) { ptr in
            Array(UnsafeBufferPointer(start: ptr, count: floatCount))
        }
        return samples
    }

    /// SESSION read: pull EXACTLY `frameCount` frames forward from the SAME open reader (no re-seek), drawing
    /// first from the carry-over of a previous over-read, then from fresh `readNextChunk()` batches. Returns
    /// the frames actually available (≤ `frameCount` only at genuine end-of-range); any over-read tail is
    /// retained in `carry` for the next forward read. Throws on a reader fault/cancel (typed) — never silently
    /// short. The caller (session loop) runs this OFF the main actor under the watchdog.
    func readForward(frameCount: Int) throws -> [Float32] {
        precondition(frameCount >= 0, "readForward frameCount must be non-negative")
        var out: [Float32] = []
        out.reserveCapacity(frameCount)
        // Drain carry first.
        if !carry.isEmpty {
            let take = min(frameCount, carry.count)
            out.append(contentsOf: carry[0..<take])
            carry.removeFirst(take)
        }
        while out.count < frameCount, !ended {
            guard let batch = try readNextChunk() else {
                // nil from a started reader means end-of-range; mark ended so we stop pulling.
                if started { ended = true }
                break
            }
            if batch.isEmpty { continue }  // a data-less buffer; keep pulling
            let need = frameCount - out.count
            if batch.count <= need {
                out.append(contentsOf: batch)
            } else {
                out.append(contentsOf: batch[0..<need])
                carry.append(contentsOf: batch[need...])   // retain the over-read tail for next time
            }
        }
        return out
    }

    func cancel() {
        // HARD interrupt: unblocks a parked copyNextSampleBuffer() and tears the reader down. End of session.
        reader.cancelReading()
    }
}

// MARK: - Bounded source-session policy (PURE; no AVFoundation; unit-testable)

/// Stage-6 Candidate A — the PURE decision for whether a new decode request can be served by the live
/// bounded source session (sequential forward read, no re-seek) or requires opening a NEW bounded session.
///
/// This carries NO AVFoundation and NO I/O — it is exact-rational arithmetic only, so the contiguity / split
/// / fail-closed contract is fully unit-testable. The actor decoder owns the real reader; this owns the math.
enum BoundedSourceSessionPolicy {

    /// The decision for one decode request against the current session state.
    enum Decision: Equatable {
        /// Serve `frameCount` frames forward from the LIVE session (no new reader, no re-seek). The request's
        /// source URL matched and its `sourceStart` is EXACTLY the session cursor, and the bounded window has
        /// room.
        case serveContiguous(frameCount: Int)
        /// Open a NEW bounded session: the live session (if any) must be torn down first (fail-closed split).
        /// Carries the bounded read window for the new session.
        case openNewSession(window: AVFoundationPCMAssetDecoder.ReadWindow)
    }

    /// Immutable description of the live session for the decision (URL + exact cursor + remaining window).
    struct SessionState: Equatable {
        let url: URL
        /// The exact rational source time the live reader will next produce (advances by frameCount/48000).
        let cursorSourceTime: RationalSourceTime
        /// Frames still readable within the session's BOUNDED window before it is exhausted.
        let framesRemainingInWindow: Int
    }

    /// Decide how to serve `request`. `live` is `nil` when no session is open. Pure / fail-closed:
    ///   - contiguous (same URL, `sourceStart == cursor`, and `frameCount ≤ remaining`) → `serveContiguous`;
    ///   - otherwise (no session / different URL / non-contiguous / backward / window exhausted) →
    ///     `openNewSession` with a freshly-computed bounded window (the actor tears the old reader down).
    /// Never returns "reuse the live session for a non-contiguous range" — that would silently serve the
    /// wrong audio.
    static func decide(
        request: CanonicalPCMAssetDecodeRequest, live: SessionState?
    ) throws -> Decision {
        if let live,
           live.url == request.source.url,
           live.cursorSourceTime == request.sourceStart,        // EXACT rational contiguity (no Double, no floor)
           request.frameCount <= live.framesRemainingInWindow {
            return .serveContiguous(frameCount: request.frameCount)
        }
        // Open a fresh bounded session window for this (possibly interior) start.
        let window = try AVFoundationPCMAssetDecoder.boundedReadWindow(
            sourceStart: request.sourceStart, frameCount: request.frameCount, sourceIDRaw: request.sourceIDRaw)
        return .openNewSession(window: window)
    }
}

// MARK: - The real decoder (actor: owns ONE bounded source session)

/// The production `CanonicalPCMAssetDecoder`. Loads the asset's audio track async/off-main and serves bounded
/// mono-48k-Float32 chunks. STAGE-6 CANDIDATE A: it is now an `actor` that holds ONE bounded `AVAssetReader`
/// SESSION and reads it SEQUENTIALLY FORWARD. Consecutive, exactly-contiguous requests are served from the
/// live reader (no re-seek — the device blocker fix); a non-contiguous request tears the session down and
/// opens a new BOUNDED one (fail-closed split). Never `@MainActor`; the read loop runs off-main under the
/// watchdog.
actor AVFoundationPCMAssetDecoder: CanonicalPCMAssetDecoder {

    /// Hard per-decode timeout. Bounded chunks are ≤ ~1 s of audio; this is a generous ceiling that still
    /// guarantees the read can never hang indefinitely.
    let timeoutNanos: UInt64

    /// The BOUNDED source-session window length, in frames. The session's `AVAssetReader` is opened over at
    /// most this many frames from `readStart`, so it is never a whole-source / whole-project read. Sized so a
    /// run of consecutive ~1 s chunks (the continuous-playback case) is served from ONE reader without
    /// re-seek, while staying bounded in memory and time. 480_000 frames = 10 s @ 48 kHz.
    nonisolated static let sessionWindowFrames: Int = 480_000

    init(timeoutNanos: UInt64 = 5_000_000_000) {   // 5 s
        self.timeoutNanos = timeoutNanos
    }

    // MARK: Live session state (actor-isolated)

    /// The single live bounded session, or `nil` when none is open. Holds the open reader, the exact cursor,
    /// and the remaining bounded-window budget. Actor isolation serializes all reads against it.
    private struct LiveSession {
        let url: URL
        let reader: AVAssetReaderBoundedPCMReader
        /// The exact rational source time the reader will next PRODUCE (after the margin prefix was dropped).
        var cursorSourceTime: RationalSourceTime
        /// Frames still readable within the bounded window before it is exhausted.
        var framesRemainingInWindow: Int
    }
    private var session: LiveSession?

    /// Extra frames decoded BEFORE an interior chunk's real start so the reader's compressed-source seek +
    /// decoder priming settle ahead of the chunk; the prefix is dropped after decode. 4800 frames = 100 ms @
    /// 48 kHz. STAGE-6 CANDIDATE A: this guard-band is applied ONLY when a NEW session is opened at an
    /// interior start (priming once), NOT per chunk — contiguous chunks need no margin because the reader is
    /// already running forward. This value is UNCHANGED (no further guard-band tuning).
    static let interiorSeekMarginFrames: Int64 = 4800

    /// The bounded read window for one session open: an EXACT rational `readStart` (no floor onto the 48 kHz
    /// grid), the number of frames to read (chunk + guard-band prefix), and the prefix-frame count to drop.
    struct ReadWindow: Equatable {
        let readStart: RationalSourceTime   // exact rational seconds; reader opens here
        let readFrameCount: Int             // request.frameCount + marginFrames
        let marginFrames: Int               // exact prefix frames to drop after decode
    }

    /// Compute the guard-band read window from the EXACT rational `sourceStart` (Stage-6 requirement: never
    /// floor `sourceStart` onto the frame grid as the source position). `readStart = max(0, sourceStart −
    /// margin/48000)`; the guard-band prefix is the EXACT integer frame distance from `readStart` to
    /// `sourceStart`. Fail-closed (`.sourceStartNotRepresentable`) if that distance is not an exact integer
    /// (no silent drift) or any rational op overflows. Pure — no AVFoundation, fully unit-testable.
    static func boundedReadWindow(
        sourceStart: RationalSourceTime, frameCount: Int, sourceIDRaw: String
    ) throws -> ReadWindow {
        let sr = AudioSampleGrid.samplesPerSecond
        let marginRational = try RationalSourceTime(numerator: Self.interiorSeekMarginFrames, denominator: sr)
        let readStart: RationalSourceTime
        if sourceStart < marginRational {
            // Not enough room before the chunk for the full margin → clamp to 0; the prefix becomes the exact
            // distance from 0 to sourceStart (i.e. sourceStart itself, in frames).
            readStart = .zero
        } else {
            do { readStart = try sourceStart.subtracting(marginRational) }
            catch { throw AppRealtimeAudioIntegrationError.sourceStartNotRepresentable(
                detail: "source \(sourceIDRaw): readStart = \(sourceStart.numerator)/\(sourceStart.denominator) - margin overflowed") }
        }
        // EXACT prefix frames = (sourceStart - readStart) * 48000, which MUST be a whole integer.
        let delta: RationalSourceTime
        do { delta = try sourceStart.subtracting(readStart) }
        catch { throw AppRealtimeAudioIntegrationError.sourceStartNotRepresentable(
            detail: "source \(sourceIDRaw): margin delta overflowed") }
        guard let marginFrames = exactFrames(delta, sampleRate: sr) else {
            throw AppRealtimeAudioIntegrationError.sourceStartNotRepresentable(
                detail: "source \(sourceIDRaw): guard-band margin \(delta.numerator)/\(delta.denominator)s is not an exact frame count")
        }
        return ReadWindow(
            readStart: readStart, readFrameCount: frameCount + Int(marginFrames), marginFrames: Int(marginFrames))
    }

    /// Exact integer frame count for a non-negative rational seconds value, or `nil` if it is not a whole
    /// number of frames (`num * 48000` must be divisible by `den`). No `Double`, no rounding.
    static func exactFrames(_ t: RationalSourceTime, sampleRate sr: Int64) -> Int64? {
        guard t.numerator >= 0, t.denominator > 0 else { return nil }
        // frames = num * sr / den, must divide evenly.
        guard t.numerator <= Int64.max / sr else { return nil }   // overflow guard
        let scaled = t.numerator * sr
        guard scaled % t.denominator == 0 else { return nil }
        return scaled / t.denominator
    }

    /// Advance an exact rational source time by `frames` 48 kHz frames. Fail-closed on overflow.
    private static func advance(_ t: RationalSourceTime, byFrames frames: Int) throws -> RationalSourceTime {
        let step = try RationalSourceTime(numerator: Int64(frames), denominator: AudioSampleGrid.samplesPerSecond)
        return try t.adding(step)
    }

    func decodeMono48kFloat32(_ request: CanonicalPCMAssetDecodeRequest) async throws -> [Float32] {
        // 1. PURE-VALUE fail-closed validation FIRST — before any I/O (same contract as before Candidate A).
        let den = request.sourceStart.denominator
        guard den > 0, den <= Int64(Int32.max) else {
            throw AppRealtimeAudioIntegrationError.sourceStartNotRepresentable(
                detail: "source \(request.sourceIDRaw): denominator \(den) is not a representable CMTimeScale")
        }
        guard request.sourceStart.numerator >= 0 else {
            throw AppRealtimeAudioIntegrationError.sourceStartNotRepresentable(
                detail: "source \(request.sourceIDRaw): negative source start \(request.sourceStart.numerator)/\(den)")
        }
        guard request.frameCount >= 0 else {
            throw AppRealtimeAudioIntegrationError.sourceStartNotRepresentable(
                detail: "source \(request.sourceIDRaw): negative frameCount \(request.frameCount)")
        }
        if request.frameCount == 0 { return [] }

        // 2. SESSION DECISION (pure): serve from the live reader if exactly contiguous; else open a new
        //    bounded session. A non-contiguous decision tears the old session down BEFORE opening a new one.
        let liveState = session.map {
            BoundedSourceSessionPolicy.SessionState(
                url: $0.url, cursorSourceTime: $0.cursorSourceTime,
                framesRemainingInWindow: $0.framesRemainingInWindow)
        }
        let decision = try BoundedSourceSessionPolicy.decide(request: request, live: liveState)

        switch decision {
        case .serveContiguous(let frameCount):
            return try await serveContiguous(request: request, frameCount: frameCount)
        case .openNewSession(let window):
            // Fail-closed split: never reuse the wrong session — tear the live reader down first.
            teardownSession()
            return try await openSessionAndServe(request: request, window: window)
        }
    }

    // MARK: Session serving

    /// Read `frameCount` frames forward from the LIVE session (no new reader, no re-seek), under the watchdog.
    private func serveContiguous(request: CanonicalPCMAssetDecodeRequest, frameCount: Int) async throws -> [Float32] {
        guard var live = session else {
            // Should not happen — the decision said contiguous only when a session exists. Fail closed.
            throw AppRealtimeAudioIntegrationError.pcmRenderFailed(
                reason: "source \(request.sourceIDRaw): contiguous serve with no live session")
        }
        let reader = live.reader
        let frames: [Float32]
        do {
            frames = try await Self.runForward(reader: reader, frameCount: frameCount, timeoutNanos: timeoutNanos)
        } catch let e as BoundedPCMReaderError {
            teardownSession()
            throw Self.mapReaderError(e, sourceIDRaw: request.sourceIDRaw)
        } catch {
            teardownSession()
            throw error
        }
        let reconciled: [Float32]
        do {
            reconciled = try WatchdogPCMDecodeLoop.reconcileFrameCount(frames, frameCount: frameCount)
        } catch {
            #if DEBUG
            // Slice-005 Stage-7 S8 decoder-internal value-capture (DEBUG-only). Live-session (contiguous) path:
            // log the session cursor + remaining window + actual decoded count so the short-read is recomputable
            // with the actor-private values the renderer cannot see. No behavior change. Marker:
            // `preview.audio.stage7.s8.shortReadProbe`.
            MemoryDiagnostics.event("preview.audio.stage7.s8.shortReadProbe",
                "path=serveContiguous source=\(request.sourceIDRaw) "
                + "reqSourceStart=\(request.sourceStart.numerator)/\(request.sourceStart.denominator) "
                + "requestedFrameCount=\(frameCount) decodedFrames=\(frames.count) "
                + "sessionCursor=\(live.cursorSourceTime.numerator)/\(live.cursorSourceTime.denominator) "
                + "framesRemainingInWindow=\(live.framesRemainingInWindow) error=\(error)")
            #endif
            throw error
        }
        // Advance the cursor + shrink the bounded window. If exhausted/at end, close the session.
        live.cursorSourceTime = try Self.advance(live.cursorSourceTime, byFrames: frameCount)
        live.framesRemainingInWindow -= frameCount
        if live.framesRemainingInWindow <= 0 {
            teardownSession()
        } else {
            session = live
        }
        return reconciled
    }

    /// Open ONE bounded session at `window.readStart`, drop the guard-band margin prefix, serve `request`, and
    /// keep the reader open (cursor at the end of the served range) for the next contiguous request.
    private func openSessionAndServe(
        request: CanonicalPCMAssetDecodeRequest, window: ReadWindow
    ) async throws -> [Float32] {
        // Bounded session window: read AT MOST `sessionWindowFrames` from readStart (never whole-source). The
        // first served chunk consumes `marginFrames + frameCount`; the rest of the window is available for the
        // following contiguous chunks. Clamp the window so it is at least large enough for THIS request.
        let minWindow = window.readFrameCount
        let sessionReadFrames = max(minWindow, Self.sessionWindowFrames)

        // CMTime from the EXACT rational readStart (denominator must fit CMTimeScale; else fail closed).
        let rden = window.readStart.denominator
        guard rden > 0, rden <= Int64(Int32.max) else {
            throw AppRealtimeAudioIntegrationError.sourceStartNotRepresentable(
                detail: "source \(request.sourceIDRaw): readStart denominator \(rden) is not a representable CMTimeScale")
        }
        let readStartTime = CMTime(value: window.readStart.numerator, timescale: CMTimeScale(rden))
        let duration = CMTime(
            value: Int64(sessionReadFrames), timescale: CMTimeScale(AudioSampleGrid.samplesPerSecond))
        guard readStartTime.isValid, duration.isValid else {
            throw AppRealtimeAudioIntegrationError.sourceStartNotRepresentable(
                detail: "source \(request.sourceIDRaw): CMTime conversion invalid")
        }
        let timeRange = CMTimeRange(start: readStartTime, duration: duration)

        // Async property/track loading (NO synchronous main-thread `tracks`/`statusOfValue`).
        let asset = AVURLAsset(url: request.source.url)
        let audioTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw AppRealtimeAudioIntegrationError.mediaCorrupt(
                sourceRaw: request.sourceIDRaw, detail: "track load failed: \(error.localizedDescription)")
        }
        guard let audioTrack = audioTracks.first else {
            throw AppRealtimeAudioIntegrationError.mediaUnsupported(
                sourceRaw: request.sourceIDRaw, detail: "no audio track")
        }

        // Build the bounded reader (throwing init — no force-try, fail-closed on canAdd == false).
        let reader = try AVAssetReaderBoundedPCMReader(
            asset: asset, audioTrack: audioTrack, timeRange: timeRange, sourceIDRaw: request.sourceIDRaw)

        // Drop the guard-band margin prefix once (priming settles), then read this request's frames. Both come
        // from the SAME reader in ONE forward pass — no re-seek between prefix and body.
        let marginFrames = window.marginFrames
        let firstReadFrames = marginFrames + request.frameCount
        let wide: [Float32]
        do {
            wide = try await Self.runForward(reader: reader, frameCount: firstReadFrames, timeoutNanos: timeoutNanos)
        } catch let e as BoundedPCMReaderError {
            reader.cancel()
            throw Self.mapReaderError(e, sourceIDRaw: request.sourceIDRaw)
        } catch {
            reader.cancel()
            throw error
        }
        guard wide.count >= marginFrames else {
            reader.cancel()
            throw AppRealtimeAudioIntegrationError.pcmRenderFailed(
                reason: "source \(request.sourceIDRaw): decoded \(wide.count) < guard-band margin \(marginFrames)")
        }
        let body = Array(wide[marginFrames..<min(wide.count, marginFrames + request.frameCount)])
        let reconciled: [Float32]
        do {
            reconciled = try WatchdogPCMDecodeLoop.reconcileFrameCount(body, frameCount: request.frameCount)
        } catch {
            #if DEBUG
            // Slice-005 Stage-7 S8 decoder-internal value-capture (DEBUG-only). New-session (openSessionAndServe)
            // path: log readStart, margin, bounded session window, wide/body decoded counts so the short-read is
            // recomputable. No behavior change. Marker: `preview.audio.stage7.s8.shortReadProbe`.
            MemoryDiagnostics.event("preview.audio.stage7.s8.shortReadProbe",
                "path=openSessionAndServe source=\(request.sourceIDRaw) "
                + "reqSourceStart=\(request.sourceStart.numerator)/\(request.sourceStart.denominator) "
                + "readStart=\(window.readStart.numerator)/\(window.readStart.denominator) "
                + "marginFrames=\(marginFrames) sessionReadFrames=\(sessionReadFrames) "
                + "requestedFrameCount=\(request.frameCount) firstReadFrames=\(firstReadFrames) "
                + "wideDecoded=\(wide.count) bodyDecoded=\(body.count) error=\(error)")
            #endif
            throw error
        }

        // Keep the reader OPEN as the live session: cursor at the end of the served range, remaining window =
        // sessionReadFrames − (margin + frameCount). If nothing remains, close it now.
        let consumed = marginFrames + request.frameCount
        let remaining = sessionReadFrames - consumed
        if remaining > 0 {
            let cursor = try Self.advance(request.sourceStart, byFrames: request.frameCount)
            session = LiveSession(
                url: request.source.url, reader: reader,
                cursorSourceTime: cursor, framesRemainingInWindow: remaining)
        } else {
            reader.cancel()
            session = nil
        }
        return reconciled
    }

    /// Tear down the live session's reader (hard-cancel) and clear it. Safe to call with no session.
    private func teardownSession() {
        session?.reader.cancel()
        session = nil
    }

    /// Run `reader.readForward(frameCount:)` OFF the main actor under the HARD watchdog, WITHOUT cancelling the
    /// reader on success (the session stays open). On timeout / external cancellation the reader IS cancelled
    /// (the session is then torn down by the caller). Mirrors `WatchdogPCMDecodeLoop.run`'s guarantees but
    /// preserves the open reader across a successful read.
    private static func runForward(
        reader: AVAssetReaderBoundedPCMReader, frameCount: Int, timeoutNanos: UInt64,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) async throws -> [Float32] {
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: ForwardOutcome.self) { group in
                group.addTask {
                    dispatchPrecondition(condition: .notOnQueue(.main))
                    do {
                        return .read(try reader.readForward(frameCount: frameCount))
                    } catch let e as BoundedPCMReaderError {
                        if case .cancelled = e { throw CancellationError() }
                        throw e
                    }
                }
                group.addTask {
                    try await sleep(timeoutNanos)
                    return .timedOut
                }
                defer { group.cancelAll() }
                while let outcome = try await group.next() {
                    switch outcome {
                    case .read(let samples):
                        return samples                         // reader stays OPEN — session continues
                    case .timedOut:
                        reader.cancel()                        // HARD interrupt; caller tears the session down
                        throw AppRealtimeAudioIntegrationError.pcmRenderFailed(
                            reason: "decode timeout after \(timeoutNanos) ns")
                    }
                }
                reader.cancel()
                throw AppRealtimeAudioIntegrationError.pcmRenderFailed(reason: "decode produced no outcome")
            }
        } onCancel: {
            reader.cancel()
        }
    }

    private enum ForwardOutcome: Sendable {
        case read([Float32])
        case timedOut
    }

    private static func mapReaderError(_ e: BoundedPCMReaderError, sourceIDRaw: String) -> Error {
        switch e {
        case .cancelled: return CancellationError()
        case .readerFailed(let detail):
            return AppRealtimeAudioIntegrationError.mediaCorrupt(sourceRaw: sourceIDRaw, detail: detail)
        }
    }
}
