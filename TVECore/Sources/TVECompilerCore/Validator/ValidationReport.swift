import Foundation
import TVECore

/// Report containing all validation issues found during scene validation
public struct ValidationReport: Equatable, Sendable {
    /// All validation issues (both errors and warnings)
    public let issues: [ValidationIssue]

    /// Filters issues to only errors
    public var errors: [ValidationIssue] {
        issues.filter { $0.severity == .error }
    }

    /// Filters issues to only warnings
    public var warnings: [ValidationIssue] {
        issues.filter { $0.severity == .warning }
    }

    /// Returns true if there are any errors (not just warnings)
    public var hasErrors: Bool {
        issues.contains { $0.severity == .error }
    }

    public init(issues: [ValidationIssue]) {
        self.issues = issues
    }
}
