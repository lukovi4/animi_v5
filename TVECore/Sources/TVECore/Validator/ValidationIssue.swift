import Foundation

/// Represents a single validation issue found during scene validation
public struct ValidationIssue: Equatable, Sendable {
    /// Severity level of the validation issue
    public enum Severity: String, Sendable {
        case error
        case warning
    }

    /// Stable error code for programmatic handling
    public let code: String

    /// Severity level (error or warning)
    public let severity: Severity

    /// JSON path to the problematic element (e.g., "$.mediaBlocks[0].rect.width")
    public let path: String

    /// Human-readable description of the issue
    public let message: String

    public init(code: String, severity: Severity, path: String, message: String) {
        self.code = code
        self.severity = severity
        self.path = path
        self.message = message
    }
}
