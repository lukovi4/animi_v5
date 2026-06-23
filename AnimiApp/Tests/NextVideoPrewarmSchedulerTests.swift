#if DEBUG
import XCTest
import Foundation
import Metal
@testable import AnimiApp
import AnimiEngineRenderModel
import AnimiEngineMetalRender

/// CP7.9 Phase 3A — unit tests for the `NextVideoPrewarmScheduler` skeleton against a FAKE provider.
/// Pins the contracts that make the scheduler safe before any integration:
///   - `readyFrame` is non-blocking and NEVER calls `provider.resolveExact`;
///   - per-video serial execution (no concurrent decode into one provider);
///   - global concurrency cap is never exceeded;
///   - latest-target-wins coalescing; superseded results don't become visible;
///   - epoch invalidation drops in-flight/old results;
///   - snapshot returns exact / lastGood / missing correctly.
/// Needs a Metal device only to fabricate a tiny `NextVideoFrame` payload → skips if unavailable.
final class NextVideoPrewarmSchedulerTests: XCTestCase {

    private var device: MTLDevice!

    override func setUpWithError() throws {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        device = d
    }

    // MARK: - Fake provider

    /// A controllable `NextVideoFrameProvider`. Records resolve calls + the thread/queue they ran on,
    /// can be made slow (to exercise concurrency), and fabricates a distinct frame per target.
    private final class FakeProvider: NextVideoFrameProvider {
        let ref: String
        let device: MTLDevice
        let decodeDelay: TimeInterval
        private let lock = NSLock()
        private(set) var resolveCount = 0
        private(set) var concurrentNow = 0
        private(set) var maxConcurrent = 0
        private(set) var resolveThreadWasMain = false
        private(set) var lastGoodFrame: NextVideoFrame?

        init(ref: String, device: MTLDevice, decodeDelay: TimeInterval = 0) {
            self.ref = ref; self.device = device; self.decodeDelay = decodeDelay
        }

        var lastCachedFrame: NextVideoFrame? { lock.lock(); defer { lock.unlock() }; return lastGoodFrame }

        func wouldColdDecode(scenePlaybackSeconds: Double) -> Bool { true }

        func resolveExact(scenePlaybackSeconds: Double) throws -> NextVideoFrame {
            lock.lock()
            resolveCount += 1
            concurrentNow += 1
            maxConcurrent = max(maxConcurrent, concurrentNow)
            if Thread.isMainThread { resolveThreadWasMain = true }
            lock.unlock()
            if decodeDelay > 0 { Thread.sleep(forTimeInterval: decodeDelay) }
            let frame = try Self.makeFrame(ref: ref, target: scenePlaybackSeconds, device: device)
            lock.lock(); concurrentNow -= 1; lastGoodFrame = frame; lock.unlock()
            return frame
        }

        static func makeFrame(ref: String, target: Double, device: MTLDevice) throws -> NextVideoFrame {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 2, height: 2, mipmapped: false)
            td.usage = [.shaderRead]; td.storageMode = .shared
            let tex = try XCTUnwrap(device.makeTexture(descriptor: td))
            let id = try PixelInputID("\(ref)@\(Int((target * 600).rounded()))/600")
            let desc = try ResolvedDynamicTextureInput(
                id: id, width: 2, height: 2, bytesFormat: .bgra8, orientation: .up, orientationQuarterTurns: 0)
            return NextVideoFrame(descriptor: desc, handle: RuntimeTextureHandle(texture: tex, retain: []))
        }
    }

    private func descID(_ a: NextVideoFrameAvailability) -> String? {
        switch a {
        case .exact(let f): return f.descriptor.id.rawValue
        case .lastGood(let f): return f.descriptor.id.rawValue
        case .missing: return nil
        }
    }
    private func isExact(_ a: NextVideoFrameAvailability) -> Bool { if case .exact = a { return true }; return false }
    private func isMissing(_ a: NextVideoFrameAvailability) -> Bool { if case .missing = a { return true }; return false }
    private func isLastGood(_ a: NextVideoFrameAvailability) -> Bool { if case .lastGood = a { return true }; return false }

    // MARK: - readyFrame is non-blocking + never calls resolveExact

    func test_readyFrame_missOnFirstCall_doesNotCallResolveExactSynchronously() throws {
        let p = FakeProvider(ref: "v", device: device, decodeDelay: 0.05)
        let s = NextVideoPrewarmScheduler(providers: ["v": p], maxConcurrentDecodes: 2)
        let a = s.readyFrame(ref: "v", target: 0.0, epoch: 0, mode: .scrub)
        XCTAssertTrue(isMissing(a), "first readyFrame must return .missing immediately (no decode yet)")
        XCTAssertEqual(p.resolveCount, 0, "readyFrame must NOT call resolveExact synchronously")
        XCTAssertFalse(p.resolveThreadWasMain, "resolveExact must never run on the calling/main thread")
        s.drainForTesting()
    }

    func test_readyFrame_afterDecode_returnsExact_andNeverDecodedOnMain() throws {
        let p = FakeProvider(ref: "v", device: device)
        let s = NextVideoPrewarmScheduler(providers: ["v": p], maxConcurrentDecodes: 2)
        _ = s.readyFrame(ref: "v", target: 0.0, epoch: 0, mode: .scrub)   // schedules
        s.drainForTesting()
        let a = s.readyFrame(ref: "v", target: 0.0, epoch: 0, mode: .scrub)
        XCTAssertTrue(isExact(a), "after the scheduled decode completes, the target must be exact")
        XCTAssertFalse(p.resolveThreadWasMain, "decode must run off-main (per-video executor)")
        XCTAssertGreaterThanOrEqual(p.resolveCount, 1)
        s.drainForTesting()
    }

    func test_readyFrame_otherTargetReady_returnsLastGood_andSchedulesExact() throws {
        let p = FakeProvider(ref: "v", device: device)
        let s = NextVideoPrewarmScheduler(providers: ["v": p], maxConcurrentDecodes: 2)
        _ = s.readyFrame(ref: "v", target: 0.0, epoch: 0, mode: .scrub); s.drainForTesting()  // 0.0 ready
        let before = p.resolveCount
        let a = s.readyFrame(ref: "v", target: 1.0, epoch: 0, mode: .scrub)                   // 1.0 not ready
        XCTAssertTrue(isLastGood(a), "a different ready frame must serve as last-good while 1.0 decodes")
        s.drainForTesting()
        XCTAssertGreaterThan(p.resolveCount, before, "the missing exact target must have been scheduled")
        XCTAssertTrue(isExact(s.readyFrame(ref: "v", target: 1.0, epoch: 0, mode: .scrub)))
        s.drainForTesting()
    }

    // MARK: - Per-video serial guarantee

    func test_perVideoSerial_neverConcurrentIntoOneProvider() throws {
        let p = FakeProvider(ref: "v", device: device, decodeDelay: 0.05)
        let s = NextVideoPrewarmScheduler(providers: ["v": p], maxConcurrentDecodes: 4)
        // Fire several distinct targets for the SAME ref rapidly.
        for i in 0..<6 { s.schedule(ref: "v", target: Double(i) * 0.1, epoch: 0, priority: .currentPlayhead) }
        s.drainForTesting()
        XCTAssertEqual(p.maxConcurrent, 1, "one provider must never decode concurrently (serial per video)")
    }

    // MARK: - Global concurrency cap

    func test_globalConcurrencyCap_neverExceeded() throws {
        let cap = 2
        let providers: [String: NextVideoFrameProvider] =
            Dictionary(uniqueKeysWithValues: (0..<6).map { ("v\($0)", FakeProvider(ref: "v\($0)", device: device, decodeDelay: 0.05)) })
        let s = NextVideoPrewarmScheduler(providers: providers, maxConcurrentDecodes: cap)
        for i in 0..<6 { s.schedule(ref: "v\(i)", target: 0.0, epoch: 0, priority: .currentPlayhead) }
        s.drainForTesting()
        XCTAssertLessThanOrEqual(s.maxConcurrentForTesting(), cap, "global concurrent decodes must not exceed the cap")
        XCTAssertGreaterThan(s.maxConcurrentForTesting(), 0)
    }

    // MARK: - Coalescing: latest target wins

    func test_coalescing_latestTargetWins_supersededDoesNotBecomeVisible() throws {
        let p = FakeProvider(ref: "v", device: device, decodeDelay: 0.04)
        let s = NextVideoPrewarmScheduler(providers: ["v": p], maxConcurrentDecodes: 1)
        // Rapid scrub: 0.0 starts decoding; 0.1, 0.2 supersede while it runs.
        s.schedule(ref: "v", target: 0.0, epoch: 0, priority: .currentPlayhead)
        s.schedule(ref: "v", target: 0.1, epoch: 0, priority: .currentPlayhead)
        s.schedule(ref: "v", target: 0.2, epoch: 0, priority: .currentPlayhead)
        s.drainForTesting()
        // The latest target (0.2) must end up exact-ready.
        XCTAssertTrue(isExact(s.readyFrame(ref: "v", target: 0.2, epoch: 0, mode: .scrub)),
                      "latest target must win and be ready")
        s.drainForTesting()
    }

    // MARK: - Epoch invalidation

    func test_epochInvalidation_dropsStaleResult() throws {
        let p = FakeProvider(ref: "v", device: device, decodeDelay: 0.06)
        let s = NextVideoPrewarmScheduler(providers: ["v": p], maxConcurrentDecodes: 1)
        s.schedule(ref: "v", target: 0.0, epoch: 0, priority: .currentPlayhead)  // starts decoding under epoch 0
        // Invalidate to epoch 1 while the decode is in flight.
        s.invalidate(newEpoch: 1)
        s.drainForTesting()
        // The epoch-0 result must NOT be visible under epoch 1 (snapshot cleared + completion discarded).
        XCTAssertTrue(isMissing(s.readyFrame(ref: "v", target: 0.0, epoch: 1, mode: .scrub)),
                      "a decode finishing after invalidation must not become visible")
        XCTAssertGreaterThanOrEqual(s.discardedStaleForTesting(), 1)
        s.drainForTesting()
    }

    // MARK: - notifyPlayback / notifyScrubSettled schedule exact

    func test_notifyScrubSettled_schedulesExactForVisibleRefs() throws {
        let p0 = FakeProvider(ref: "a", device: device); let p1 = FakeProvider(ref: "b", device: device)
        let s = NextVideoPrewarmScheduler(providers: ["a": p0, "b": p1], maxConcurrentDecodes: 2)
        s.notifyScrubSettled(visibleRefs: ["a", "b"], target: 0.5, epoch: 0)
        s.drainForTesting()
        XCTAssertTrue(isExact(s.readyFrame(ref: "a", target: 0.5, epoch: 0, mode: .settled)))
        XCTAssertTrue(isExact(s.readyFrame(ref: "b", target: 0.5, epoch: 0, mode: .settled)))
        s.drainForTesting()
    }

    // MARK: - CP7.9-CORR fix 2: completion queued around invalidate must NOT publish under the new epoch

    func test_corr_completionAfterInvalidate_notVisibleInNewEpoch() throws {
        // A slow decode is in flight under epoch 0; we invalidate to epoch 1 BEFORE it finishes. The
        // epoch-0 result must never appear under epoch 1 (snapshot cleared atomically + completion discarded).
        let p = FakeProvider(ref: "v", device: device, decodeDelay: 0.08)
        let s = NextVideoPrewarmScheduler(providers: ["v": p], maxConcurrentDecodes: 1)
        s.schedule(ref: "v", target: 0.0, epoch: 0, priority: .currentPlayhead)
        s.invalidate(newEpoch: 1)
        s.drainForTesting()
        XCTAssertTrue(isMissing(s.readyFrame(ref: "v", target: 0.0, epoch: 1, mode: .scrub)),
                      "epoch-0 completion must not be visible under epoch 1")
        // Even re-querying under the OLD epoch must miss (snapshot was cleared).
        XCTAssertTrue(isMissing(s.readyFrame(ref: "v", target: 0.0, epoch: 0, mode: .scrub)),
                      "old-epoch snapshot must have been cleared by invalidate")
        XCTAssertGreaterThanOrEqual(s.discardedStaleForTesting(), 1)
        s.drainForTesting()
    }

    func test_corr_alreadyReadyFrame_invalidatedAway_notVisibleInNewEpoch() throws {
        // Frame becomes ready under epoch 0, THEN invalidate. The ready frame must vanish for epoch 1.
        let p = FakeProvider(ref: "v", device: device)
        let s = NextVideoPrewarmScheduler(providers: ["v": p], maxConcurrentDecodes: 1)
        _ = s.readyFrame(ref: "v", target: 0.0, epoch: 0, mode: .settled); s.drainForTesting()
        XCTAssertTrue(isExact(s.readyFrame(ref: "v", target: 0.0, epoch: 0, mode: .settled)))
        s.invalidate(newEpoch: 1)
        s.syncControlForTesting()   // ensure the invalidate block ran (epoch bump + snapshot clear)
        // No new schedule; query epoch 1 → the old ready frame must not leak across epochs.
        let a = s.readyFrame(ref: "v", target: 0.0, epoch: 1, mode: .settled)
        // (readyFrame on a miss schedules under epoch 1; the immediate read must still be missing.)
        XCTAssertTrue(isMissing(a), "ready frame from epoch 0 must not be visible under epoch 1")
        s.drainForTesting()
    }

    // MARK: - CP7.9-CORR fix 3: priority semantics (both directions)

    func test_corr_priority_nearFutureDoesNotSupersedeCurrentPlayhead() throws {
        // currentPlayhead at 0.0 is pending; a lower-priority nearFuture at 1.0 must NOT replace it.
        let p = FakeProvider(ref: "v", device: device, decodeDelay: 0.05)
        let s = NextVideoPrewarmScheduler(providers: ["v": p], maxConcurrentDecodes: 1)
        s.schedule(ref: "v", target: 0.0, epoch: 0, priority: .currentPlayhead)   // starts decoding 0.0
        s.schedule(ref: "v", target: 1.0, epoch: 0, priority: .nearFuture)        // must NOT supersede
        s.drainForTesting()
        XCTAssertTrue(isExact(s.readyFrame(ref: "v", target: 0.0, epoch: 0, mode: .settled)),
                      "currentPlayhead target must survive a lower-priority nearFuture request")
        // 1.0 was never adopted as the desired target → it should not be exact-ready.
        let a = s.readyFrame(ref: "v", target: 1.0, epoch: 0, mode: .settled)
        XCTAssertFalse(isExact(a), "lower-priority nearFuture target must not have superseded/decoded")
        s.drainForTesting()
    }

    func test_corr_priority_currentPlayheadSupersedesNearFuture() throws {
        // A pending nearFuture at 1.0 must be replaced by a currentPlayhead at 0.0.
        let p = FakeProvider(ref: "v", device: device, decodeDelay: 0.05)
        let s = NextVideoPrewarmScheduler(providers: ["v": p], maxConcurrentDecodes: 1)
        s.schedule(ref: "v", target: 1.0, epoch: 0, priority: .nearFuture)        // starts decoding 1.0
        s.schedule(ref: "v", target: 0.0, epoch: 0, priority: .currentPlayhead)   // supersedes → chased
        s.drainForTesting()
        XCTAssertTrue(isExact(s.readyFrame(ref: "v", target: 0.0, epoch: 0, mode: .settled)),
                      "currentPlayhead must supersede a pending nearFuture and become ready")
        s.drainForTesting()
    }

    // MARK: - CP7.9-CORR2 fix 1: playback readyFrame current target is currentPlayhead

    func test_corr2_playbackReadyFrame_currentTarget_notSupersededByNearFuture() throws {
        // A near-future lookahead is pending; then a PLAYBACK readyFrame for a different current target must
        // win (currentPlayhead > nearFuture), because readyFrame schedules the current target at currentPlayhead.
        let p = FakeProvider(ref: "v", device: device, decodeDelay: 0.05)
        let s = NextVideoPrewarmScheduler(providers: ["v": p], maxConcurrentDecodes: 1)
        s.notifyPlayback(visibleRefs: ["v"], target: 1.0, epoch: 0)            // nearFuture 1.0 starts decoding
        _ = s.readyFrame(ref: "v", target: 0.0, epoch: 0, mode: .playback)    // current 0.0 @ currentPlayhead
        s.drainForTesting()
        XCTAssertTrue(isExact(s.readyFrame(ref: "v", target: 0.0, epoch: 0, mode: .playback)),
                      "playback current target (currentPlayhead) must supersede a pending nearFuture lookahead")
        s.drainForTesting()
    }

    func test_corr2_playbackCurrentTarget_notEvictedByLaterNearFuture() throws {
        // currentPlayhead current target pending; a subsequent nearFuture lookahead must NOT supersede it.
        let p = FakeProvider(ref: "v", device: device, decodeDelay: 0.05)
        let s = NextVideoPrewarmScheduler(providers: ["v": p], maxConcurrentDecodes: 1)
        _ = s.readyFrame(ref: "v", target: 0.0, epoch: 0, mode: .playback)    // current 0.0 @ currentPlayhead
        s.notifyPlayback(visibleRefs: ["v"], target: 1.0, epoch: 0)           // nearFuture 1.0 must not win
        s.drainForTesting()
        XCTAssertTrue(isExact(s.readyFrame(ref: "v", target: 0.0, epoch: 0, mode: .playback)),
                      "a lower-priority nearFuture must not evict the pending playback current target")
        s.drainForTesting()
    }

    // MARK: - CP7.9-CORR2 fix 2: post-invalidate, stale completion must auto-start the new-epoch desired

    func test_corr2_postInvalidate_sameKeyDesired_startsAutomatically() throws {
        // epoch-0 decode in flight; invalidate to epoch 1; readyFrame(epoch 1, SAME key) records desired
        // while old inFlight is still true. The old completion is discarded AND must auto-start the epoch-1
        // decode — with NO second readyFrame call. Eventually exact under epoch 1.
        let p = FakeProvider(ref: "v", device: device, decodeDelay: 0.06)
        let s = NextVideoPrewarmScheduler(providers: ["v": p], maxConcurrentDecodes: 1)
        s.schedule(ref: "v", target: 0.0, epoch: 0, priority: .currentPlayhead)  // epoch-0 decode begins
        s.invalidate(newEpoch: 1)
        s.syncControlForTesting()                                                  // invalidate applied
        _ = s.readyFrame(ref: "v", target: 0.0, epoch: 1, mode: .scrub)           // record epoch-1 desired
        s.drainForTesting()
        XCTAssertTrue(isExact(s.readyFrame(ref: "v", target: 0.0, epoch: 1, mode: .scrub)),
                      "epoch-1 desired (same key) must auto-start after the stale completion clears inFlight")
        XCTAssertGreaterThanOrEqual(s.discardedStaleForTesting(), 1, "the epoch-0 result must be discarded")
        s.drainForTesting()
    }

    func test_corr2_postInvalidate_differentKeyDesired_startsAutomatically() throws {
        let p = FakeProvider(ref: "v", device: device, decodeDelay: 0.06)
        let s = NextVideoPrewarmScheduler(providers: ["v": p], maxConcurrentDecodes: 1)
        s.schedule(ref: "v", target: 0.0, epoch: 0, priority: .currentPlayhead)  // epoch-0 decode begins
        s.invalidate(newEpoch: 1)
        s.syncControlForTesting()
        _ = s.readyFrame(ref: "v", target: 2.0, epoch: 1, mode: .scrub)           // DIFFERENT key, epoch 1
        s.drainForTesting()
        XCTAssertTrue(isExact(s.readyFrame(ref: "v", target: 2.0, epoch: 1, mode: .scrub)),
                      "epoch-1 desired (different key) must auto-start without a second readyFrame call")
        // The stale epoch-0 target (0.0) must NOT be an exact frame under epoch 1. (It may serve as
        // last-good via the epoch-1 frame decoded for 2.0 — that's fine; what must not happen is a real
        // exact 0.0 frame surviving the epoch change.)
        XCTAssertFalse(isExact(s.readyFrame(ref: "v", target: 0.0, epoch: 1, mode: .scrub)),
                       "the stale epoch-0 target must not be exact under epoch 1")
        s.drainForTesting()
    }

    // MARK: - CP7.9-CORR3 fix 1+2: ref-only admission waiters (pump re-reads CURRENT desired)

    func test_corr3_parkedRefSuperseded_admitsLatestDesired_notStale() throws {
        // cap=1. Ref "a" occupies the only slot with a slow decode. Ref "b" schedules 0.0 → parks. While
        // parked, "b" is superseded to 1.0. When "a" frees the slot, the pump must admit "b"@1.0 (latest),
        // never the stale 0.0 it parked with.
        let pa = FakeProvider(ref: "a", device: device, decodeDelay: 0.10)
        let pb = FakeProvider(ref: "b", device: device, decodeDelay: 0.02)
        let s = NextVideoPrewarmScheduler(providers: ["a": pa, "b": pb], maxConcurrentDecodes: 1)
        s.schedule(ref: "a", target: 0.0, epoch: 0, priority: .currentPlayhead)   // takes the slot (slow)
        s.schedule(ref: "b", target: 0.0, epoch: 0, priority: .currentPlayhead)   // parks (cap full)
        s.schedule(ref: "b", target: 1.0, epoch: 0, priority: .currentPlayhead)   // supersede while parked
        s.drainForTesting()
        XCTAssertTrue(isExact(s.readyFrame(ref: "b", target: 1.0, epoch: 0, mode: .settled)),
                      "pump must admit the parked ref's CURRENT desired target (1.0)")
        XCTAssertFalse(isExact(s.readyFrame(ref: "b", target: 0.0, epoch: 0, mode: .settled)),
                       "the stale parked target (0.0) must never have been decoded")
        s.drainForTesting()
    }

    func test_corr3_parkedRefAppearsAtMostOnce_underRepeatedSchedule() throws {
        // cap=1, "a" holds the slot; "b" is scheduled MANY times while parked → it must appear once.
        let pa = FakeProvider(ref: "a", device: device, decodeDelay: 0.15)
        let pb = FakeProvider(ref: "b", device: device, decodeDelay: 0.02)
        let s = NextVideoPrewarmScheduler(providers: ["a": pa, "b": pb], maxConcurrentDecodes: 1)
        s.schedule(ref: "a", target: 0.0, epoch: 0, priority: .currentPlayhead)
        for i in 0..<8 {
            s.schedule(ref: "b", target: Double(i) * 0.1, epoch: 0, priority: .currentPlayhead)
            _ = s.readyFrame(ref: "b", target: Double(i) * 0.1, epoch: 0, mode: .scrub)
        }
        // While "a" is still decoding, "b" must be parked exactly once (dedup).
        XCTAssertEqual(s.waitingCountForTesting("b"), 1, "a parked ref must appear at most once in the FIFO")
        s.drainForTesting()
    }

    func test_corr3_globalCapRespected_withParking() throws {
        // 6 refs, cap=2: parking must never let more than 2 decode concurrently.
        let cap = 2
        let providers: [String: NextVideoFrameProvider] =
            Dictionary(uniqueKeysWithValues: (0..<6).map { ("v\($0)", FakeProvider(ref: "v\($0)", device: device, decodeDelay: 0.04)) })
        let s = NextVideoPrewarmScheduler(providers: providers, maxConcurrentDecodes: cap)
        for i in 0..<6 { s.schedule(ref: "v\(i)", target: 0.0, epoch: 0, priority: .currentPlayhead) }
        s.drainForTesting()
        XCTAssertLessThanOrEqual(s.maxConcurrentForTesting(), cap, "parking must not exceed the global cap")
        XCTAssertGreaterThan(s.maxConcurrentForTesting(), 0)
        for i in 0..<6 { XCTAssertTrue(isExact(s.readyFrame(ref: "v\(i)", target: 0.0, epoch: 0, mode: .settled))) }
        s.drainForTesting()
    }

    func test_corr3_noDuplicateConcurrentDecode_forSameRefAfterParkedSupersede() throws {
        // A parked-then-superseded ref must still decode SERIALLY (never two concurrent decodes into it).
        let pa = FakeProvider(ref: "a", device: device, decodeDelay: 0.06)
        let pb = FakeProvider(ref: "b", device: device, decodeDelay: 0.06)
        let s = NextVideoPrewarmScheduler(providers: ["a": pa, "b": pb], maxConcurrentDecodes: 1)
        s.schedule(ref: "a", target: 0.0, epoch: 0, priority: .currentPlayhead)   // slot
        s.schedule(ref: "b", target: 0.0, epoch: 0, priority: .currentPlayhead)   // park
        s.schedule(ref: "b", target: 1.0, epoch: 0, priority: .currentPlayhead)   // supersede while parked
        s.schedule(ref: "b", target: 2.0, epoch: 0, priority: .currentPlayhead)   // supersede again
        s.drainForTesting()
        XCTAssertEqual(pb.maxConcurrent, 1, "the parked-then-admitted ref must never decode concurrently")
        XCTAssertTrue(isExact(s.readyFrame(ref: "b", target: 2.0, epoch: 0, mode: .settled)))
        s.drainForTesting()
    }

    func test_corr3_invalidateWhileParked_dropsWaiter_noStaleDecode_andQuiesces() throws {
        // "a" holds the slot; "b" parks under epoch 0; invalidate → "b" must be dropped (no stale decode),
        // its inFlight claim released, and the scheduler must quiesce (drain returns).
        let pa = FakeProvider(ref: "a", device: device, decodeDelay: 0.10)
        let pb = FakeProvider(ref: "b", device: device, decodeDelay: 0.02)
        let s = NextVideoPrewarmScheduler(providers: ["a": pa, "b": pb], maxConcurrentDecodes: 1)
        s.schedule(ref: "a", target: 0.0, epoch: 0, priority: .currentPlayhead)
        s.schedule(ref: "b", target: 0.0, epoch: 0, priority: .currentPlayhead)   // parks
        XCTAssertEqual(s.waitingCountForTesting("b"), 1)
        let bResolvesBefore = pb.resolveCount
        s.invalidate(newEpoch: 1)
        s.syncControlForTesting()
        XCTAssertEqual(s.waitingCountForTesting("b"), 0, "invalidate must drop the parked waiter")
        XCTAssertFalse(s.isInFlightForTesting("b"), "dropped parked ref must release its inFlight claim")
        s.drainForTesting()   // must return (quiescence), proving no orphaned inFlight
        XCTAssertEqual(pb.resolveCount, bResolvesBefore, "the dropped parked ref must never have decoded")
        s.drainForTesting()
    }

    // MARK: - CP7.9-CORR fix 4: stable quantized key (near-equivalent seconds → same exact key)

    func test_corr_stableKey_nearEquivalentSecondsShareExactFrame() throws {
        // 0.500000 and 0.500_0001 both quantize to the same 600-tick → decoding one satisfies the other.
        let p = FakeProvider(ref: "v", device: device)
        let s = NextVideoPrewarmScheduler(providers: ["v": p], maxConcurrentDecodes: 1)
        _ = s.readyFrame(ref: "v", target: 0.5, epoch: 0, mode: .settled); s.drainForTesting()
        let before = p.resolveCount
        // A near-equivalent target must read as EXACT without scheduling a new decode.
        let a = s.readyFrame(ref: "v", target: 0.5 + (0.4 / 600.0), epoch: 0, mode: .settled)
        XCTAssertTrue(isExact(a), "near-equivalent seconds must hit the same quantized exact key")
        s.drainForTesting()
        XCTAssertEqual(p.resolveCount, before, "no extra decode for a sub-tick-different target")
    }

    // MARK: - CP7.9-CORR fix 5: bounded snapshot (per-ref MRU cap respected)

    func test_corr_snapshotCap_evictsOldestBeyondCap() throws {
        let cap = 3
        let p = FakeProvider(ref: "v", device: device)
        let s = NextVideoPrewarmScheduler(providers: ["v": p], maxConcurrentDecodes: 1,
                                          maxSnapshotFramesPerRef: cap)
        // Decode 5 distinct targets (each a distinct tick) serially.
        let targets = [0.0, 1.0, 2.0, 3.0, 4.0]
        for t in targets { _ = s.readyFrame(ref: "v", target: t, epoch: 0, mode: .settled); s.drainForTesting() }
        // The newest `cap` targets must still be exact; older ones evicted (missing, then re-scheduled).
        XCTAssertTrue(isExact(s.readyFrame(ref: "v", target: 4.0, epoch: 0, mode: .settled)))
        XCTAssertTrue(isExact(s.readyFrame(ref: "v", target: 3.0, epoch: 0, mode: .settled)))
        XCTAssertTrue(isExact(s.readyFrame(ref: "v", target: 2.0, epoch: 0, mode: .settled)))
        // 0.0 and 1.0 were the two oldest → evicted beyond the cap of 3.
        let oldest = s.readyFrame(ref: "v", target: 0.0, epoch: 0, mode: .settled)
        XCTAssertFalse(isExact(oldest), "oldest target beyond the per-ref cap must have been evicted")
        s.drainForTesting()
    }
}
#endif
