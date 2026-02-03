import Foundation

// MARK: - RenderCommand Structural Validator (PR-22 safety net)

/// Static validator for `RenderCommand` sequences.
/// Checks that push/pop stacks (transforms, clips) are balanced within
/// each mask and matte scope boundary — catches cross-boundary issues
/// at AnimIR emission time rather than at render time.
enum RenderCommandValidator {

    /// Controls whether validation failures trigger assertionFailure in DEBUG.
    /// Set to `false` in tests that deliberately pass invalid command sequences
    /// to verify renderer error handling (e.g. testStacksBalanced_invalidPopThrows).
    static var assertOnFailure: Bool = true

    struct ValidationError: CustomStringConvertible {
        let index: Int
        let message: String

        var description: String { "[\(index)] \(message)" }
    }

    /// Validates that transform and clip stacks are balanced within each
    /// mask (`beginMask`/`endMask`) and matte (`beginMatte`/`endMatte`) scope.
    ///
    /// Returns an empty array if the command sequence is structurally valid.
    /// In DEBUG builds, prints a diagnostic window around each error.
    static func validateScopeBalance(_ commands: [RenderCommand]) -> [ValidationError] {
        var errors: [ValidationError] = []

        var transformDepth = 0
        var clipDepth = 0
        var groupDepth = 0

        // Stack of (kind, transformDepth, clipDepth, commandIndex) at scope entry
        var scopeStack: [(kind: String, transformDepth: Int, clipDepth: Int, index: Int)] = []

        for (i, cmd) in commands.enumerated() {
            switch cmd {
            // --- Transform stack ---
            case .pushTransform:
                transformDepth += 1
            case .popTransform:
                transformDepth -= 1
                if transformDepth < 0 {
                    errors.append(ValidationError(index: i, message: "popTransform below zero (depth: \(transformDepth))"))
                }

            // --- Clip stack ---
            case .pushClipRect:
                clipDepth += 1
            case .popClipRect:
                clipDepth -= 1
                if clipDepth < 0 {
                    errors.append(ValidationError(index: i, message: "popClipRect below zero (depth: \(clipDepth))"))
                }

            // --- Group depth ---
            case .beginGroup:
                groupDepth += 1
            case .endGroup:
                groupDepth -= 1
                if groupDepth < 0 {
                    errors.append(ValidationError(index: i, message: "endGroup below zero (depth: \(groupDepth))"))
                }

            // --- Mask scope ---
            case .beginMask:
                scopeStack.append(("mask", transformDepth, clipDepth, i))
            case .endMask:
                if let scope = scopeStack.last, scope.kind == "mask" {
                    if transformDepth != scope.transformDepth {
                        let err = ValidationError(
                            index: i,
                            message: "Cross-boundary transforms in mask scope: began at [\(scope.index)] depth=\(scope.transformDepth), endMask depth=\(transformDepth)"
                        )
                        errors.append(err)
                        #if DEBUG
                        printDiagnosticWindow(commands, around: i, error: err)
                        #endif
                    }
                    if clipDepth != scope.clipDepth {
                        let err = ValidationError(
                            index: i,
                            message: "Cross-boundary clips in mask scope: began at [\(scope.index)] depth=\(scope.clipDepth), endMask depth=\(clipDepth)"
                        )
                        errors.append(err)
                        #if DEBUG
                        printDiagnosticWindow(commands, around: i, error: err)
                        #endif
                    }
                    scopeStack.removeLast()
                } else {
                    errors.append(ValidationError(index: i, message: "endMask without matching beginMask"))
                }

            // --- Matte scope ---
            case .beginMatte:
                scopeStack.append(("matte", transformDepth, clipDepth, i))
            case .endMatte:
                if let scope = scopeStack.last, scope.kind == "matte" {
                    if transformDepth != scope.transformDepth {
                        let err = ValidationError(
                            index: i,
                            message: "Cross-boundary transforms in matte scope: began at [\(scope.index)] depth=\(scope.transformDepth), endMatte depth=\(transformDepth)"
                        )
                        errors.append(err)
                        #if DEBUG
                        printDiagnosticWindow(commands, around: i, error: err)
                        #endif
                    }
                    if clipDepth != scope.clipDepth {
                        let err = ValidationError(
                            index: i,
                            message: "Cross-boundary clips in matte scope: began at [\(scope.index)] depth=\(scope.clipDepth), endMatte depth=\(clipDepth)"
                        )
                        errors.append(err)
                        #if DEBUG
                        printDiagnosticWindow(commands, around: i, error: err)
                        #endif
                    }
                    scopeStack.removeLast()
                } else {
                    errors.append(ValidationError(index: i, message: "endMatte without matching beginMatte"))
                }

            default:
                break
            }
        }

        // Final balance check
        if transformDepth != 0 {
            errors.append(ValidationError(index: commands.count, message: "Final transform depth: \(transformDepth) (expected 0)"))
        }
        if clipDepth != 0 {
            errors.append(ValidationError(index: commands.count, message: "Final clip depth: \(clipDepth) (expected 0)"))
        }
        if groupDepth != 0 {
            errors.append(ValidationError(index: commands.count, message: "Final group depth: \(groupDepth) (expected 0)"))
        }
        if !scopeStack.isEmpty {
            errors.append(ValidationError(index: commands.count, message: "\(scopeStack.count) unclosed scope(s)"))
        }

        return errors
    }

    // MARK: - Diagnostics

    #if DEBUG
    /// Prints a window of commands around the error index for debugging.
    private static func printDiagnosticWindow(_ commands: [RenderCommand], around index: Int, error: ValidationError, windowSize: Int = 5) {
        let start = max(0, index - windowSize)
        let end = min(commands.count, index + windowSize + 1)

        print("[TVECore] \u{26a0}\u{fe0f} RenderCommandValidator: \(error.message)")
        print("  Command window [\(start)..\(end - 1)]:")
        for i in start..<end {
            let marker = (i == index) ? " >>> " : "     "
            print("\(marker)[\(i)] \(commands[i])")
        }
    }
    #endif
}
