import Foundation

/// Events emitted from EditorRuntime to the controller.
///
/// The controller presents UI driven by these events but never makes runtime decisions.
enum EditorRuntimeOutput {
    // Render
    case renderSourceUpdated

    // Export lifecycle
    case exportStarted
    case exportPreflightRecommendation(ExportPreflightResult)
    case exportProgress(Float)
    case exportFinishing
    case exportRenderSucceeded(URL)
    case exportRenderFailed(Error)
    case exportCancelled
    case exportDeliveryShareHandoff(URL)
    case exportDeliveryCompleted(ExportDeliveryOutcome)

    // Playback
    case playbackStateChanged(isPlaying: Bool)

    // Scene edit
    case sceneEditActivated(instanceId: UUID)
    case sceneEditDeactivated

    // Boot
    case runtimeReady
    case runtimeFailed(String)

    // Errors
    case presentError(String)
}
