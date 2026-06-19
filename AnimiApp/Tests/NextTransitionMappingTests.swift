#if DEBUG
import XCTest
import Foundation
@testable import AnimiApp
import AnimiEngineCore

/// CP5 — app→canonical transition mapping. Only cut/fade/slide are supported; push/dipToBlack/
/// dipToWhite fail closed with a typed error (owner decision: no silent map, no schema change).
/// Timing is exact integer ticks; the canonical evaluator owns the window + rational progress.
final class NextTransitionMappingTests: XCTestCase {

    private func t(_ type: String, dir: String? = nil, frames: Int = 14, easing: String = "easeInOut") -> NextBridgeTransition {
        NextBridgeTransition(typeRaw: type, direction: dir, durationFrames: frames, easingRaw: easing)
    }

    // MARK: - ticks-per-frame

    func test_ticksPerFrame_fps30_is8000() throws {
        XCTAssertEqual(try NextTransitionMapping.ticksPerFrame(fps: 30), 8_000, "240000/30")
    }

    func test_ticksPerFrame_rejectsInexactFps() {
        // 7 does not divide 240000 evenly → fail closed.
        XCTAssertThrowsError(try NextTransitionMapping.ticksPerFrame(fps: 7))
        XCTAssertThrowsError(try NextTransitionMapping.ticksPerFrame(fps: 0))
    }

    // MARK: - cut

    func test_cut_isZeroDurationNoneEasing() throws {
        let mapped = try NextTransitionMapping.map(t("none", frames: 0, easing: "linear"), fps: 30)
        XCTAssertEqual(mapped.kind, .cut)
        XCTAssertEqual(mapped.duration.ticks, 0)
        XCTAssertEqual(mapped.easing.raw, "none")
        // Canonical validation must accept it.
        XCTAssertNoThrow(try SupportedTransitionEffect.validate(mapped))
    }

    func test_cut_zeroPostRoll() throws {
        XCTAssertEqual(try NextTransitionMapping.postRollTicks(t("none", frames: 0), fps: 30).ticks, 0)
    }

    // MARK: - fade

    func test_fade_animatedEmptyParams_exactDuration() throws {
        let mapped = try NextTransitionMapping.map(t("fade", frames: 14, easing: "linear"), fps: 30)
        guard case let .animated(effect) = mapped.kind else { return XCTFail("expected animated") }
        XCTAssertEqual(effect.effectID.raw, "fade")
        XCTAssertTrue(effect.parameters.sortedUniqueParameters.isEmpty, "fade takes no params")
        XCTAssertEqual(mapped.duration.ticks, 14 * 8_000, "exact ticks, 14 frames @ 30fps")
        XCTAssertEqual(mapped.easing.raw, "linear")
        XCTAssertNoThrow(try SupportedTransitionEffect.validate(mapped))
    }

    func test_fade_easeInOutAccepted() throws {
        let mapped = try NextTransitionMapping.map(t("fade", easing: "easeInOut"), fps: 30)
        XCTAssertEqual(mapped.easing.raw, "easeInOut")
        XCTAssertNoThrow(try SupportedTransitionEffect.validate(mapped))
    }

    func test_fade_zeroDurationFailsClosed() {
        XCTAssertThrowsError(try NextTransitionMapping.map(t("fade", frames: 0), fps: 30)) { err in
            guard case NextTransitionMappingError.nonPositiveAnimatedDuration = err else {
                return XCTFail("expected nonPositiveAnimatedDuration, got \(err)")
            }
        }
    }

    func test_fade_postRollIsHalfDuration() throws {
        // 14 frames → floor(14/2)=7 frames → 7*8000 ticks.
        XCTAssertEqual(try NextTransitionMapping.postRollTicks(t("fade", frames: 14), fps: 30).ticks, 7 * 8_000)
        // Odd duration floors.
        XCTAssertEqual(try NextTransitionMapping.postRollTicks(t("fade", frames: 15), fps: 30).ticks, 7 * 8_000)
    }

    // MARK: - slide

    func test_slide_directionParam_allFour() throws {
        for dir in ["left", "right", "up", "down"] {
            let mapped = try NextTransitionMapping.map(t("slide", dir: dir), fps: 30)
            guard case let .animated(effect) = mapped.kind else { return XCTFail("expected animated") }
            XCTAssertEqual(effect.effectID.raw, "slide")
            guard case let .identifier(value)? = effect.parameters.value(for: "direction") else {
                return XCTFail("missing direction identifier")
            }
            XCTAssertEqual(value, dir)
            XCTAssertNoThrow(try SupportedTransitionEffect.validate(mapped), "canonical accepts slide \(dir)")
        }
    }

    func test_slide_missingDirectionFailsClosed() {
        XCTAssertThrowsError(try NextTransitionMapping.map(t("slide", dir: nil), fps: 30)) { err in
            guard case NextTransitionMappingError.missingSlideDirection = err else {
                return XCTFail("expected missingSlideDirection, got \(err)")
            }
        }
    }

    func test_slide_invalidDirectionFailsClosed() {
        XCTAssertThrowsError(try NextTransitionMapping.map(t("slide", dir: "diagonal"), fps: 30)) { err in
            guard case NextTransitionMappingError.invalidSlideDirection = err else {
                return XCTFail("expected invalidSlideDirection, got \(err)")
            }
        }
    }

    // MARK: - unsupported types fail closed (NO silent map to fade/slide)

    func test_push_failsClosed() {
        XCTAssertThrowsError(try NextTransitionMapping.map(t("push", dir: "left"), fps: 30)) { err in
            guard case NextTransitionMappingError.unsupportedTransitionType(let r) = err else {
                return XCTFail("expected unsupportedTransitionType, got \(err)")
            }
            XCTAssertEqual(r, "push")
        }
    }

    func test_dipToBlack_failsClosed() {
        XCTAssertThrowsError(try NextTransitionMapping.map(t("dipToBlack"), fps: 30)) { err in
            guard case NextTransitionMappingError.unsupportedTransitionType = err else {
                return XCTFail("expected unsupportedTransitionType, got \(err)")
            }
        }
    }

    func test_dipToWhite_failsClosed() {
        XCTAssertThrowsError(try NextTransitionMapping.map(t("dipToWhite"), fps: 30)) { err in
            guard case NextTransitionMappingError.unsupportedTransitionType = err else {
                return XCTFail("expected unsupportedTransitionType, got \(err)")
            }
        }
    }

    // MARK: - easing

    func test_unsupportedEasing_failsClosed() {
        XCTAssertThrowsError(try NextTransitionMapping.map(t("fade", easing: "bounce"), fps: 30)) { err in
            guard case NextTransitionMappingError.unsupportedEasing = err else {
                return XCTFail("expected unsupportedEasing, got \(err)")
            }
        }
    }
}
#endif
