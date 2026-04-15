import Foundation
@preconcurrency import TVECore

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

// MARK: - Resolved Text Overlay (PR9)

/// Resolved text overlay for rendering.
/// Used by both preview and export render paths.
public struct ResolvedTextOverlay: Sendable {
    public let text: String
    public let fontFamily: String?
    public let fontSize: CGFloat
    public let colorHex: String
    public let centerX: CGFloat
    public let centerY: CGFloat

    public init(text: String, fontFamily: String?, fontSize: CGFloat, colorHex: String, centerX: CGFloat, centerY: CGFloat) {
        self.text = text
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.colorHex = colorHex
        self.centerX = centerX
        self.centerY = centerY
    }
}

// MARK: - TT-02: Timeline Resolution Policy

/// TT-02: Policy for resolving timeline frames.
/// Determines blocking vs non-blocking readiness behavior.
public enum TimelineResolvePolicy: Sendable {
    /// Preview/playback mode: returns .hold if not ready, no blocking wait.
    case presentation
    /// Export mode: blocks until ready or terminal failure, never returns .hold.
    case export
}

// MARK: - TT-02: Timeline Frame Resolution Failure

/// TT-02: Failure reasons for frame resolution.
public enum TimelineFrameResolutionFailure: Equatable, Sendable {
    /// Timeline is invalid (no transitionMath or invalid renderMode).
    case invalidTimeline
    /// Required scene runtime could not be created.
    case missingDependency(UUID)
    /// Scene runtime failed during preparation.
    case dependencyFailed(UUID, reason: String)
    /// Scene runtime timed out during preparation.
    case dependencyTimedOut(UUID)
}

// MARK: - TT-02: Timeline Frame Resolution

/// TT-02: Result of resolving a timeline frame.
/// Replaces optional return type with explicit result enum.
public enum TimelineFrameResolution: Sendable {
    /// Frame successfully resolved with render context.
    case resolved(ResolvedTimelineFrame)
    /// Frame not ready yet; caller should hold last presented frame (presentation only).
    case hold
    /// Generation mismatch; this resolve request is stale.
    case staleGeneration
    /// Resolution failed with specific reason.
    case failed(TimelineFrameResolutionFailure)
}
