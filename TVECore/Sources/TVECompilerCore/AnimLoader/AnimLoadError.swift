import Foundation
import TVECore

/// Errors that can occur during animation loading
public enum AnimLoadError: Error, Equatable, Sendable {
    /// Failed to read animation JSON file
    case animJSONReadFailed(animRef: String, reason: String)

    /// Failed to decode animation JSON
    case animJSONDecodeFailed(animRef: String, reason: String)
}

extension AnimLoadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .animJSONReadFailed(animRef, reason):
            return "Failed to read animation '\(animRef)': \(reason)"
        case let .animJSONDecodeFailed(animRef, reason):
            return "Failed to decode animation '\(animRef)': \(reason)"
        }
    }
}
