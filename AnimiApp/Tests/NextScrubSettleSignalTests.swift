#if DEBUG
import XCTest
@testable import AnimiApp

/// CP7.9 Phase 3D.3 — the SETTLE-transition decision that drives `notifyScrubSettled`/`.settled` mode.
/// Pins the pure edge-detection used by `EditorViewController.renderWithNextEngineBridge` so the controller
/// fires the settle exactly once on `scrub active true → false` while not playing — derived from the
/// EXISTING `EditorRuntime.isScrubInteractionActive` state (no new gesture pipeline).
final class NextScrubSettleSignalTests: XCTestCase {

    // active stays true → still scrubbing → NOT a settle.
    func test_activeScrub_doesNotSettle() {
        XCTAssertFalse(EditorViewController.didScrubSettle(previousActive: true, currentActive: true, isPlaying: false))
    }

    // true → false while not playing → exactly a settle.
    func test_trueToFalse_notPlaying_settlesOnce() {
        XCTAssertTrue(EditorViewController.didScrubSettle(previousActive: true, currentActive: false, isPlaying: false))
    }

    // false → false → no scrub in progress → no settle (no duplicate after the edge already fired).
    func test_falseToFalse_noSettle() {
        XCTAssertFalse(EditorViewController.didScrubSettle(previousActive: false, currentActive: false, isPlaying: false))
    }

    // The edge fires once: the tick AFTER settle has previous=false → no second fire.
    func test_settle_isSingleEdge_noDuplicateNextTick() {
        // tick 1: true→false ⇒ settle
        XCTAssertTrue(EditorViewController.didScrubSettle(previousActive: true, currentActive: false, isPlaying: false))
        // tick 2: false→false ⇒ no settle (caller stored current=false as the new previous)
        XCTAssertFalse(EditorViewController.didScrubSettle(previousActive: false, currentActive: false, isPlaying: false))
    }

    // While playing, a true→false transition is NOT a scrub-settle (playback owns its own path).
    func test_whilePlaying_noScrubSettle() {
        XCTAssertFalse(EditorViewController.didScrubSettle(previousActive: true, currentActive: false, isPlaying: true))
        XCTAssertFalse(EditorViewController.didScrubSettle(previousActive: true, currentActive: true, isPlaying: true))
    }

    // false → true (scrub just BEGAN) is not a settle.
    func test_scrubBegan_noSettle() {
        XCTAssertFalse(EditorViewController.didScrubSettle(previousActive: false, currentActive: true, isPlaying: false))
    }

    // MARK: - CORR: pending re-fire preserves didSettle, and the strategy mode follows it

    // A settle stored while a render is in flight survives a later NON-settle request coalescing on top.
    func test_pendingCoalesce_settleNotDroppedByLaterNonSettle() {
        // 1st request (the in-flight one finishes; a settle then arrives and is stored as pending):
        let afterSettleStored = NextPreviewController.coalesceDidSettle(newDidSettle: true, pendingDidSettle: nil)
        XCTAssertTrue(afterSettleStored, "settle must be stored in the pending slot")
        // 2nd request (a plain scrub tick) coalesces on top BEFORE the re-fire — settle must STICK.
        let afterNonSettle = NextPreviewController.coalesceDidSettle(newDidSettle: false, pendingDidSettle: afterSettleStored)
        XCTAssertTrue(afterNonSettle, "a later non-settle request must NOT drop a pending settle")
    }

    // Without any settle, coalescing stays false (no spurious settle).
    func test_pendingCoalesce_noSettle_staysFalse() {
        XCTAssertFalse(NextPreviewController.coalesceDidSettle(newDidSettle: false, pendingDidSettle: nil))
        XCTAssertFalse(NextPreviewController.coalesceDidSettle(newDidSettle: false, pendingDidSettle: false))
    }

    // The re-fire's didSettle drives the resolved scheduler mode → `.settled` (exact catch-up).
    func test_pendingRefire_settleResolvesSettledMode() {
        let coalesced = NextPreviewController.coalesceDidSettle(newDidSettle: true, pendingDidSettle: nil)
        XCTAssertEqual(NextPreviewController.previewMode(isPlaying: false, didSettle: coalesced), .settled,
                       "a re-fired settle (not playing) must resolve the .settled strategy mode")
        // A non-settle scrub re-fire resolves `.scrub`; playing always `.playback`.
        XCTAssertEqual(NextPreviewController.previewMode(isPlaying: false, didSettle: false), .scrub)
        XCTAssertEqual(NextPreviewController.previewMode(isPlaying: true, didSettle: true), .playback)
    }
}
#endif
