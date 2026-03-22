import Foundation

// MARK: - Runtime Diagnostics Sink

/// Protocol for receiving runtime diagnostic events.
/// Implementations must be Sendable for thread-safe event delivery.
/// Internal/test-only — production code passes nil.
@MainActor
public protocol RuntimeDiagnosticsSink: AnyObject, Sendable {
    func receive(_ event: RuntimeDiagnosticEvent)
}
