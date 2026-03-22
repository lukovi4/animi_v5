import Foundation

// MARK: - Render Diagnostics Sink

/// Protocol for receiving render diagnostic events.
/// Implementations must be Sendable for thread-safe event delivery.
/// Internal/test-only — production code passes nil.
public protocol RenderDiagnosticsSink: AnyObject, Sendable {
    func receive(_ event: RenderDiagnosticEvent)
}
