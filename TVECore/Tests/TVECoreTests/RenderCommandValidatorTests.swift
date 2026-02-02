import XCTest
@testable import TVECore

final class RenderCommandValidatorTests: XCTestCase {

    // MARK: - Valid sequences (no errors expected)

    func testValidator_balancedScope_noErrors() {
        // Simple mask scope with balanced transforms inside
        let commands: [RenderCommand] = [
            .pushTransform(.identity),
            .beginMask(mode: .add, inverted: false, pathId: PathID(1), opacity: 1.0, frame: 0),
            .pushTransform(.identity),
            .drawImage(assetId: "test", opacity: 1.0),
            .popTransform,
            .endMask,
            .popTransform
        ]

        let errors = RenderCommandValidator.validateScopeBalance(commands)
        XCTAssertTrue(errors.isEmpty, "Balanced scope should have no errors, got: \(errors)")
    }

    func testValidator_pr22InputClipPattern_noErrors() {
        // PR-22 canonical pattern: pushTransform(world) → beginMask →
        //   pushTransform(inverse) → pushTransform(media) → content →
        //   popTransform(media) → popTransform(inverse) → endMask → popTransform(world)
        let commands: [RenderCommand] = [
            .beginGroup(name: "Layer:test(inputClip)"),
            .pushTransform(.identity),                   // inputLayerWorld (outside scope)
            .beginMask(mode: .intersect, inverted: false, pathId: PathID(1), opacity: 1.0, frame: 0),
            .pushTransform(.identity),                   // inverse compensation (inside scope)
            .pushTransform(.identity),                   // mediaWorldWithUser (inside scope)
            .drawImage(assetId: "content", opacity: 1.0),
            .popTransform,                               // media
            .popTransform,                               // inverse compensation
            .endMask,                                    // inputClip end
            .popTransform,                               // inputLayerWorld (outside scope)
            .endGroup
        ]

        let errors = RenderCommandValidator.validateScopeBalance(commands)
        XCTAssertTrue(errors.isEmpty, "PR-22 inputClip pattern should be valid, got: \(errors)")
    }

    func testValidator_pr22WithNestedLayerMasks_noErrors() {
        // PR-22 pattern with nested layer masks inside the inputClip scope
        let commands: [RenderCommand] = [
            .beginGroup(name: "Layer:test(inputClip)"),
            .pushTransform(.identity),                   // inputLayerWorld
            .beginMask(mode: .intersect, inverted: false, pathId: PathID(1), opacity: 1.0, frame: 0), // inputClip
            .pushTransform(.identity),                   // inverse compensation
            .pushTransform(.identity),                   // mediaWorld
            // Nested layer mask
            .beginMask(mode: .add, inverted: false, pathId: PathID(2), opacity: 1.0, frame: 0),
            .drawImage(assetId: "content", opacity: 1.0),
            .endMask,                                    // layer mask end
            .popTransform,                               // media
            .popTransform,                               // inverse
            .endMask,                                    // inputClip end
            .popTransform,                               // inputLayerWorld
            .endGroup
        ]

        let errors = RenderCommandValidator.validateScopeBalance(commands)
        XCTAssertTrue(errors.isEmpty, "PR-22 with nested layer masks should be valid, got: \(errors)")
    }

    func testValidator_nestedMaskBalanced_noErrors() {
        // Container mask → nested inputClip mask, all balanced
        let commands: [RenderCommand] = [
            .beginMask(mode: .add, inverted: false, pathId: PathID(1), opacity: 1.0, frame: 0),
            .pushTransform(.identity),
            .beginMask(mode: .intersect, inverted: false, pathId: PathID(2), opacity: 1.0, frame: 0),
            .drawImage(assetId: "test", opacity: 1.0),
            .endMask,
            .popTransform,
            .endMask
        ]

        let errors = RenderCommandValidator.validateScopeBalance(commands)
        XCTAssertTrue(errors.isEmpty, "Nested balanced masks should have no errors, got: \(errors)")
    }

    func testValidator_matteScope_balanced_noErrors() {
        let commands: [RenderCommand] = [
            .beginMatte(mode: .alpha),
            .pushTransform(.identity),
            .drawImage(assetId: "matte", opacity: 1.0),
            .popTransform,
            .endMatte
        ]

        let errors = RenderCommandValidator.validateScopeBalance(commands)
        XCTAssertTrue(errors.isEmpty, "Balanced matte scope should have no errors, got: \(errors)")
    }

    // MARK: - Invalid sequences (errors expected)

    func testValidator_crossBoundaryTransform_detectsError() {
        // Old-style inputClip: pushTransform BEFORE beginMask, popTransform INSIDE — cross-boundary!
        let commands: [RenderCommand] = [
            .pushTransform(.identity),    // outside scope
            .beginMask(mode: .intersect, inverted: false, pathId: PathID(1), opacity: 1.0, frame: 0),
            .popTransform,                // INSIDE scope — closes outer push!
            .pushTransform(.identity),    // media transform
            .drawImage(assetId: "test", opacity: 1.0),
            .popTransform,                // media
            .endMask
        ]

        let errors = RenderCommandValidator.validateScopeBalance(commands)
        XCTAssertFalse(errors.isEmpty, "Cross-boundary popTransform should be detected")

        // Should detect transform depth mismatch at endMask
        let hasCrossBoundary = errors.contains { $0.message.contains("Cross-boundary transforms in mask scope") }
        XCTAssertTrue(hasCrossBoundary, "Should report cross-boundary transform error, got: \(errors)")
    }

    func testValidator_crossBoundaryClip_detectsError() {
        let commands: [RenderCommand] = [
            .pushClipRect(RectD(x: 0, y: 0, width: 100, height: 100)),
            .beginMask(mode: .add, inverted: false, pathId: PathID(1), opacity: 1.0, frame: 0),
            .popClipRect,                 // cross-boundary!
            .endMask
        ]

        let errors = RenderCommandValidator.validateScopeBalance(commands)
        XCTAssertFalse(errors.isEmpty, "Cross-boundary clip should be detected")
        let hasCrossBoundary = errors.contains { $0.message.contains("Cross-boundary clips") }
        XCTAssertTrue(hasCrossBoundary, "Should report cross-boundary clip error, got: \(errors)")
    }

    func testValidator_unbalancedFinal_detectsError() {
        // Push without matching pop
        let commands: [RenderCommand] = [
            .pushTransform(.identity),
            .drawImage(assetId: "test", opacity: 1.0)
            // Missing popTransform
        ]

        let errors = RenderCommandValidator.validateScopeBalance(commands)
        XCTAssertFalse(errors.isEmpty, "Unbalanced final transform should be detected")
        let hasFinalError = errors.contains { $0.message.contains("Final transform depth") }
        XCTAssertTrue(hasFinalError, "Should report final depth error, got: \(errors)")
    }

    func testValidator_unmatchedEndMask_detectsError() {
        let commands: [RenderCommand] = [
            .drawImage(assetId: "test", opacity: 1.0),
            .endMask  // no matching beginMask
        ]

        let errors = RenderCommandValidator.validateScopeBalance(commands)
        XCTAssertFalse(errors.isEmpty, "Unmatched endMask should be detected")
        let hasUnmatched = errors.contains { $0.message.contains("endMask without matching beginMask") }
        XCTAssertTrue(hasUnmatched, "Should report unmatched endMask, got: \(errors)")
    }

    func testValidator_unmatchedEndMatte_detectsError() {
        let commands: [RenderCommand] = [
            .drawImage(assetId: "test", opacity: 1.0),
            .endMatte  // no matching beginMatte
        ]

        let errors = RenderCommandValidator.validateScopeBalance(commands)
        XCTAssertFalse(errors.isEmpty, "Unmatched endMatte should be detected")
        let hasUnmatched = errors.contains { $0.message.contains("endMatte without matching beginMatte") }
        XCTAssertTrue(hasUnmatched, "Should report unmatched endMatte, got: \(errors)")
    }

    func testValidator_unclosedScope_detectsError() {
        let commands: [RenderCommand] = [
            .beginMask(mode: .add, inverted: false, pathId: PathID(1), opacity: 1.0, frame: 0),
            .drawImage(assetId: "test", opacity: 1.0)
            // Missing endMask
        ]

        let errors = RenderCommandValidator.validateScopeBalance(commands)
        XCTAssertFalse(errors.isEmpty, "Unclosed scope should be detected")
        let hasUnclosed = errors.contains { $0.message.contains("unclosed scope") }
        XCTAssertTrue(hasUnclosed, "Should report unclosed scope, got: \(errors)")
    }

    func testValidator_popBelowZero_detectsError() {
        let commands: [RenderCommand] = [
            .popTransform  // nothing to pop
        ]

        let errors = RenderCommandValidator.validateScopeBalance(commands)
        XCTAssertFalse(errors.isEmpty, "Pop below zero should be detected")
        let hasBelowZero = errors.contains { $0.message.contains("below zero") }
        XCTAssertTrue(hasBelowZero, "Should report below zero error, got: \(errors)")
    }

    // MARK: - Group depth tracking

    func testValidator_balancedGroups_noErrors() {
        let commands: [RenderCommand] = [
            .beginGroup(name: "outer"),
            .beginGroup(name: "inner"),
            .drawImage(assetId: "test", opacity: 1.0),
            .endGroup,
            .endGroup
        ]

        let errors = RenderCommandValidator.validateScopeBalance(commands)
        XCTAssertTrue(errors.isEmpty, "Balanced groups should have no errors, got: \(errors)")
    }

    func testValidator_unbalancedGroups_detectsError() {
        let commands: [RenderCommand] = [
            .beginGroup(name: "orphan"),
            .drawImage(assetId: "test", opacity: 1.0)
            // Missing endGroup
        ]

        let errors = RenderCommandValidator.validateScopeBalance(commands)
        XCTAssertFalse(errors.isEmpty, "Unbalanced group should be detected")
        let hasGroupError = errors.contains { $0.message.contains("Final group depth") }
        XCTAssertTrue(hasGroupError, "Should report group depth error, got: \(errors)")
    }

    func testValidator_endGroupBelowZero_detectsError() {
        let commands: [RenderCommand] = [
            .endGroup  // nothing to close
        ]

        let errors = RenderCommandValidator.validateScopeBalance(commands)
        XCTAssertFalse(errors.isEmpty, "endGroup below zero should be detected")
        let hasBelowZero = errors.contains { $0.message.contains("endGroup below zero") }
        XCTAssertTrue(hasBelowZero, "Should report endGroup below zero, got: \(errors)")
    }
}
