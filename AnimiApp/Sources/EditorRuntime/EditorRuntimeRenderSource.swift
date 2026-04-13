import Foundation
import TVECore

/// Unified render source that replaces the `session.state?.uiMode` branching in `draw(in:)`.
///
/// The runtime updates this value; the controller's `draw(in:)` switches on it
/// without consulting session state.
enum EditorRuntimeRenderSource {
    case timeline(TimelineRenderSourcePayload)
    case sceneEdit(SceneEditRenderSourcePayload)
    case none
}

/// Payload for timeline mode rendering — wraps a resolved timeline frame
/// plus background state needed by the render executor.
struct TimelineRenderSourcePayload {
    let resolvedFrame: ResolvedTimelineFrame
    let backgroundState: EffectiveBackgroundState?
    let backgroundTextureProvider: (any TextureProvider)?
    let diagnosticFrameTag: Int?
}

/// Payload for scene-edit mode rendering — wraps resolved commands
/// plus all resources needed by the `drawWithParams` path.
struct SceneEditRenderSourcePayload {
    let commands: [RenderCommand]
    let textureProvider: any TextureProvider
    let pathRegistry: PathRegistry
    let assetSizes: [String: AssetSize]
    let canvasSize: SizeD
    let backgroundState: EffectiveBackgroundState?
    let backgroundTextureProvider: (any TextureProvider)?
}
