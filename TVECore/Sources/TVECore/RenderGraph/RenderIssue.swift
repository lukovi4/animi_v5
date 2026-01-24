import Foundation

/// Issue encountered during render command generation
public struct RenderIssue: Equatable, Sendable {
    /// Severity level of the issue
    public enum Severity: String, Sendable {
        case warning
        case error
    }

    /// Issue severity
    public let severity: Severity

    /// Issue code (e.g., "PARENT_NOT_FOUND", "PARENT_CYCLE")
    public let code: String

    /// Path to the problematic element (e.g., "anim(test.json).layers[id=5]")
    public let path: String

    /// Human-readable description of the issue
    public let message: String

    /// Scene frame index where the issue occurred
    public let frameIndex: Int

    public init(
        severity: Severity,
        code: String,
        path: String,
        message: String,
        frameIndex: Int
    ) {
        self.severity = severity
        self.code = code
        self.path = path
        self.message = message
        self.frameIndex = frameIndex
    }
}

// MARK: - Issue Codes

extension RenderIssue {
    /// Parent layer referenced by `parent` field was not found in composition
    public static let codeParentNotFound = "PARENT_NOT_FOUND"

    /// Cycle detected in parent chain (layer references itself or creates loop)
    public static let codeParentCycle = "PARENT_CYCLE"

    /// Cycle detected in precomp reference chain (comp_A -> comp_B -> comp_A)
    public static let codePrecompCycle = "PRECOMP_CYCLE"

    /// Precomp asset referenced by refId not found in compositions
    public static let codePrecompAssetNotFound = "PRECOMP_ASSET_NOT_FOUND"
}

// MARK: - Debug Description

extension RenderIssue: CustomDebugStringConvertible {
    public var debugDescription: String {
        "[\(severity.rawValue.uppercased())] \(code) \(path) — \(message) (frame \(frameIndex))"
    }
}
