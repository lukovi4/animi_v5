import XCTest
@testable import AnimiEngineCore

/// Transition-effect parameter envelope tests (Task-002 plan, §7.1, §18).
final class TransitionEffectTests: XCTestCase {

    private func animated(_ effectID: String, _ params: [TransitionParameter], duration: Int64 = 120_000) throws -> SceneTransition {
        SceneTransition(
            kind: .animated(TransitionEffect(effectID: try TransitionEffectID(effectID), parameters: try TransitionParameterSet(params))),
            duration: try TickDuration(ticks: duration), easing: try EasingReference("linear")
        )
    }

    func testFadeExactEmptyParameterSetAccepted() throws {
        XCTAssertNoThrow(try SupportedTransitionEffect.validate(try animated("fade", [])))
    }

    func testFadeRejectsExtraParameter() throws {
        XCTAssertThrowsError(try SupportedTransitionEffect.validate(
            try animated("fade", [TransitionParameter(key: "x", value: .integer(1))])
        )) {
            XCTAssertEqual($0 as? ProjectValidationError, .extraTransitionParameter(effectID: "fade", key: "x"))
        }
    }

    func testSlideValidDirectionsAccepted() throws {
        for dir in ["left", "right", "up", "down"] {
            XCTAssertNoThrow(try SupportedTransitionEffect.validate(
                try animated("slide", [TransitionParameter(key: "direction", value: .identifier(dir))])
            ), "direction \(dir)")
        }
    }

    func testSlideMissingDirectionRejected() throws {
        XCTAssertThrowsError(try SupportedTransitionEffect.validate(try animated("slide", []))) {
            XCTAssertEqual($0 as? ProjectValidationError, .missingTransitionParameter(effectID: "slide", key: "direction"))
        }
    }

    func testSlideWrongTypeDirectionRejected() throws {
        XCTAssertThrowsError(try SupportedTransitionEffect.validate(
            try animated("slide", [TransitionParameter(key: "direction", value: .integer(1))])
        )) {
            XCTAssertEqual($0 as? ProjectValidationError, .wrongTypeTransitionParameter(effectID: "slide", key: "direction"))
        }
    }

    func testSlideInvalidDirectionValueRejected() throws {
        XCTAssertThrowsError(try SupportedTransitionEffect.validate(
            try animated("slide", [TransitionParameter(key: "direction", value: .identifier("sideways"))])
        ))
    }

    func testSlideExtraParameterRejected() throws {
        XCTAssertThrowsError(try SupportedTransitionEffect.validate(
            try animated("slide", [
                TransitionParameter(key: "direction", value: .identifier("left")),
                TransitionParameter(key: "speed", value: .integer(2))
            ])
        )) {
            XCTAssertEqual($0 as? ProjectValidationError, .extraTransitionParameter(effectID: "slide", key: "speed"))
        }
    }

    func testUnsupportedEffectRejected() throws {
        XCTAssertThrowsError(try SupportedTransitionEffect.validate(try animated("wipe", []))) {
            XCTAssertEqual($0 as? ProjectValidationError, .unsupportedEffect(effectID: "wipe"))
        }
    }

    func testDuplicateParameterRejectedAtConstruction() {
        XCTAssertThrowsError(try TransitionParameterSet([
            TransitionParameter(key: "direction", value: .identifier("left")),
            TransitionParameter(key: "direction", value: .identifier("right"))
        ])) {
            XCTAssertEqual($0 as? ProjectValidationError, .duplicateTransitionParameter(key: "direction"))
        }
    }

    func testSeveralDifferentDurationsCoexist() throws {
        // Different boundary durations are independently valid.
        XCTAssertNoThrow(try SupportedTransitionEffect.validate(try animated("fade", [], duration: 8_000)))
        XCTAssertNoThrow(try SupportedTransitionEffect.validate(try animated("fade", [], duration: 240_000)))
        XCTAssertNoThrow(try SupportedTransitionEffect.validate(try animated("fade", [], duration: 999_999)))
    }
}
