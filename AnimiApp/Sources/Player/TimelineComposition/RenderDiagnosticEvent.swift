import Foundation

// MARK: - Render Diagnostic Events

/// Typed diagnostic events for timeline render executor observability.
/// Internal/test-only — does not affect production semantics.
public enum RenderDiagnosticEvent: Sendable, Equatable {
    /// First composited frame rendered with the given tag.
    case firstCompositedFrame(frameTag: Int)

    /// Compositor encode time for a transition (in seconds).
    case compositorEncodeTime(seconds: Double)

    /// Offscreen scene A rendered during transition.
    case offscreenRenderA(instanceId: UUID)

    /// Offscreen scene B rendered during transition.
    case offscreenRenderB(instanceId: UUID)
}
