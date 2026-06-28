import XCTest
import AVFoundation
import AnimiEngineCore
@testable import AnimiApp

/// Slice-005 Stage-6 Candidate A — the bounded source-window/session decoder.
///
/// These tests prove the PURE session decision (`BoundedSourceSessionPolicy`) WITHOUT real compressed media:
/// contiguous serve vs fail-closed split, exact-rational contiguity (no Double / no floor), backward /
/// different-source / window-exhausted → new bounded session. They also assert the session never silently
/// reuses a wrong session. No AVFoundation decode, no device, no audible claim here — the device run is the
/// separate PASS gate.
final class BoundedSourceSessionDecoderTests: XCTestCase {

    private static let url0 = URL(fileURLWithPath: "/tmp/source-0.m4a")
    private static let url1 = URL(fileURLWithPath: "/tmp/source-1.m4a")

    private static func request(
        url: URL = url0, sourceStart: RationalSourceTime, frameCount: Int, sourceID: String = "s0"
    ) -> CanonicalPCMAssetDecodeRequest {
        CanonicalPCMAssetDecodeRequest(
            source: CanonicalResolvedAudioSource(url: url),
            sourceIDRaw: sourceID, sourceStart: sourceStart, frameCount: frameCount)
    }

    private static func live(
        url: URL = url0, cursor: RationalSourceTime, remaining: Int
    ) -> BoundedSourceSessionPolicy.SessionState {
        BoundedSourceSessionPolicy.SessionState(url: url, cursorSourceTime: cursor, framesRemainingInWindow: remaining)
    }

    // MARK: - No live session → always open a new bounded session

    func testNoLiveSessionOpensNewSession() throws {
        let req = Self.request(sourceStart: .zero, frameCount: 48_000)
        let decision = try BoundedSourceSessionPolicy.decide(request: req, live: nil)
        guard case .openNewSession(let window) = decision else {
            return XCTFail("no session must open a new one, got \(decision)")
        }
        XCTAssertEqual(window.readStart, .zero, "first chunk at 0 → no guard-band")
        XCTAssertEqual(window.marginFrames, 0)
        XCTAssertEqual(window.readFrameCount, 48_000)
    }

    // MARK: - Exactly contiguous request → serve from the LIVE session (no re-seek)

    func testExactlyContiguousServesFromLiveSession() throws {
        // Live cursor at 1 s; next chunk starts EXACTLY at 1 s, fits the remaining window → serve contiguous.
        let cursor = try RationalSourceTime(numerator: 1, denominator: 1)
        let req = Self.request(sourceStart: cursor, frameCount: 48_000)
        let decision = try BoundedSourceSessionPolicy.decide(
            request: req, live: Self.live(cursor: cursor, remaining: 96_000))
        XCTAssertEqual(decision, .serveContiguous(frameCount: 48_000),
            "an exactly-contiguous request within the window must be served from the live session")
    }

    func testContiguityIsExactRationalNotFloored() throws {
        // Cursor at 1/3 s (a NON-frame-aligned rational). A request at EXACTLY 1/3 s is contiguous; the same
        // numeric value expressed reduced (e.g. 2/6 reduces to 1/3) is equal by the type, so still contiguous.
        let cursor = try RationalSourceTime(numerator: 1, denominator: 3)
        let sameReduced = try RationalSourceTime(numerator: 2, denominator: 6)   // reduces to 1/3
        XCTAssertEqual(cursor, sameReduced, "precondition: equal exact rationals")
        let req = Self.request(sourceStart: sameReduced, frameCount: 1_000)
        let decision = try BoundedSourceSessionPolicy.decide(
            request: req, live: Self.live(cursor: cursor, remaining: 10_000))
        XCTAssertEqual(decision, .serveContiguous(frameCount: 1_000))
    }

    // MARK: - Non-contiguous (gap) → fail-closed split (new bounded session), NEVER reuse the live one

    func testForwardGapDoesNotReuseSessionAndSplits() throws {
        // Cursor at 1 s but the request starts at 2 s (a forward GAP, not contiguous). Must NOT serve from the
        // live session (that would replay the wrong audio) — open a NEW bounded session at 2 s.
        let cursor = try RationalSourceTime(numerator: 1, denominator: 1)
        let gapStart = try RationalSourceTime(numerator: 2, denominator: 1)
        let req = Self.request(sourceStart: gapStart, frameCount: 48_000)
        let decision = try BoundedSourceSessionPolicy.decide(
            request: req, live: Self.live(cursor: cursor, remaining: 480_000))
        guard case .openNewSession(let window) = decision else {
            return XCTFail("a forward gap must split into a new session, got \(decision)")
        }
        // New session opens a guard-band earlier than 2 s (interior start → priming margin once).
        XCTAssertEqual(window.marginFrames, 4800)
        XCTAssertEqual(window.readStart, try RationalSourceTime(numerator: 19, denominator: 10), "2 - 1/10 = 19/10")
    }

    // MARK: - Backward seek → fail-closed split, never reuse

    func testBackwardSeekSplits() throws {
        let cursor = try RationalSourceTime(numerator: 2, denominator: 1)
        let backStart = try RationalSourceTime(numerator: 1, denominator: 1)   // earlier than the cursor
        let req = Self.request(sourceStart: backStart, frameCount: 48_000)
        let decision = try BoundedSourceSessionPolicy.decide(
            request: req, live: Self.live(cursor: cursor, remaining: 480_000))
        guard case .openNewSession = decision else {
            return XCTFail("a backward seek must split into a new session, got \(decision)")
        }
    }

    // MARK: - Different source URL → fail-closed split, never reuse another source's reader

    func testDifferentSourceSplits() throws {
        let cursor = try RationalSourceTime(numerator: 1, denominator: 1)
        // Same cursor value but a DIFFERENT url → must not serve from the live (wrong-file) session.
        let req = Self.request(url: Self.url1, sourceStart: cursor, frameCount: 48_000, sourceID: "s1")
        let decision = try BoundedSourceSessionPolicy.decide(
            request: req, live: Self.live(url: Self.url0, cursor: cursor, remaining: 480_000))
        guard case .openNewSession = decision else {
            return XCTFail("a different source URL must split into a new session, got \(decision)")
        }
    }

    // MARK: - Window exhausted → fail-closed split even when contiguous

    func testWindowExhaustedSplitsEvenWhenContiguous() throws {
        // Contiguous start, but the request needs more frames than remain in the bounded window → split.
        let cursor = try RationalSourceTime(numerator: 1, denominator: 1)
        let req = Self.request(sourceStart: cursor, frameCount: 48_000)
        let decision = try BoundedSourceSessionPolicy.decide(
            request: req, live: Self.live(cursor: cursor, remaining: 10_000))   // only 10k < 48k
        guard case .openNewSession = decision else {
            return XCTFail("an exhausted window must split into a new bounded session, got \(decision)")
        }
    }

    // MARK: - Exactly-fitting window is still contiguous (boundary)

    func testRequestExactlyFillsRemainingWindowIsContiguous() throws {
        let cursor = try RationalSourceTime(numerator: 1, denominator: 1)
        let req = Self.request(sourceStart: cursor, frameCount: 48_000)
        let decision = try BoundedSourceSessionPolicy.decide(
            request: req, live: Self.live(cursor: cursor, remaining: 48_000))   // exactly enough
        XCTAssertEqual(decision, .serveContiguous(frameCount: 48_000))
    }

    // MARK: - The bounded session window is bounded (never whole-source)

    func testSessionWindowIsBounded() {
        // The configured session window is a fixed, finite bound (10 s @ 48 kHz), not "the whole source".
        XCTAssertEqual(AVFoundationPCMAssetDecoder.sessionWindowFrames, 480_000)
        XCTAssertLessThan(AVFoundationPCMAssetDecoder.sessionWindowFrames, Int.max,
            "the session window must be a finite bound, never unbounded/whole-source")
    }

    // MARK: - Tolerance is unchanged (no guard-band/tolerance tuning in Candidate A)

    func testToleranceUnchanged() {
        XCTAssertEqual(WatchdogPCMDecodeLoop.maxBoundaryShortfallFrames, 1024,
            "Candidate A must not raise the boundary tolerance")
        XCTAssertEqual(AVFoundationPCMAssetDecoder.interiorSeekMarginFrames, 4800,
            "Candidate A must not widen the guard-band")
    }

    // MARK: - Actor decode still fails closed on a bad rational (regression guard for struct→actor change)

    func testActorDecoderNegativeStartFailsClosed() async throws {
        let decoder = AVFoundationPCMAssetDecoder()
        let req = Self.request(sourceStart: try RationalSourceTime(numerator: -1, denominator: 2), frameCount: 8)
        do {
            _ = try await decoder.decodeMono48kFloat32(req)
            XCTFail("negative start must fail closed")
        } catch let e as AppRealtimeAudioIntegrationError {
            guard case .sourceStartNotRepresentable = e else { return XCTFail("got \(e)") }
        }
    }

    // MARK: - Zero-frame request returns [] without opening a session

    func testZeroFrameRequestReturnsEmpty() async throws {
        let decoder = AVFoundationPCMAssetDecoder()
        let req = Self.request(sourceStart: .zero, frameCount: 0)
        let out = try await decoder.decodeMono48kFloat32(req)
        XCTAssertEqual(out, [], "a zero-frame request is empty silence and opens no reader")
    }
}
