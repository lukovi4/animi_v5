import Foundation
import TVECore

// MARK: - Resolved Timeline Frame

/// Output of TimelineCompositionEngine.resolveFrame().
/// Represents what needs to be rendered for a given compressed frame.
public enum ResolvedTimelineFrame: Sendable {
    /// Single scene rendering (no transition).
    case single(SceneRenderContext)

    /// Transition rendering (two scenes blended).
    case transition(TransitionRenderContext)
}

// MARK: - Scene Render Context

/// Context for rendering a single scene.
public struct SceneRenderContext: Sendable {
    /// Render commands for this scene.
    public let commands: [RenderCommand]

    /// Texture provider for this scene.
    public let textureProvider: TextureProvider

    /// Path registry for this scene.
    public let pathRegistry: PathRegistry

    /// Asset sizes for this scene.
    public let assetSizes: [String: AssetSize]

    /// Local frame index within the scene.
    public let localFrame: Int

    /// Canvas size for this scene.
    public let canvasSize: SizeD

    /// Scene instance ID.
    public let sceneInstanceId: UUID

    public init(
        commands: [RenderCommand],
        textureProvider: TextureProvider,
        pathRegistry: PathRegistry,
        assetSizes: [String: AssetSize],
        localFrame: Int,
        canvasSize: SizeD,
        sceneInstanceId: UUID
    ) {
        self.commands = commands
        self.textureProvider = textureProvider
        self.pathRegistry = pathRegistry
        self.assetSizes = assetSizes
        self.localFrame = localFrame
        self.canvasSize = canvasSize
        self.sceneInstanceId = sceneInstanceId
    }
}

// MARK: - Transition Render Context

/// Context for rendering a transition between two scenes.
public struct TransitionRenderContext: Sendable {
    /// Context for outgoing scene (A).
    public let sceneA: SceneRenderContext

    /// Context for incoming scene (B).
    public let sceneB: SceneRenderContext

    /// Transition parameters.
    public let transition: SceneTransition

    /// Progress through transition (0.0 to 1.0).
    public let progress: Double

    public init(
        sceneA: SceneRenderContext,
        sceneB: SceneRenderContext,
        transition: SceneTransition,
        progress: Double
    ) {
        self.sceneA = sceneA
        self.sceneB = sceneB
        self.transition = transition
        self.progress = progress
    }
}
