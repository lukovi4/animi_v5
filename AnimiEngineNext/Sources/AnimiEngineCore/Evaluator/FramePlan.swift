/// The role a scene plays within a frame body (Task-002 plan, §12).
public enum SceneRole: Equatable, Sendable {
    case sole
    case outgoing
    case incoming
}

/// Render-ready content for an active scene layer (Task-002 plan, §12).
public enum ActiveSceneContent: Equatable, Sendable {
    case video(SourceRequest)
    case image(ImageReference)
}

/// A single active scene layer in a frame plan (Task-002 plan, §12).
public struct ActiveLayer: Equatable, Sendable {
    public let layerID: LayerID
    public let zIndex: Int
    public let stableOrdinal: Int
    /// Dense local composition order (0-based) within this scene subplan, after stable ordering.
    public let localCompositionOrder: Int
    public let placement: Placement
    /// The authored media placement carried from `SceneLayer` (step-8 corrective, issue #1).
    public let mediaPlacement: MediaPlacement
    public let content: ActiveSceneContent
    public let animationReference: AnimationReference?
    public let animationRequest: AnimationRequest?

    public init(
        layerID: LayerID,
        zIndex: Int,
        stableOrdinal: Int,
        localCompositionOrder: Int,
        placement: Placement,
        mediaPlacement: MediaPlacement,
        content: ActiveSceneContent,
        animationReference: AnimationReference?,
        animationRequest: AnimationRequest?
    ) {
        self.layerID = layerID
        self.zIndex = zIndex
        self.stableOrdinal = stableOrdinal
        self.localCompositionOrder = localCompositionOrder
        self.placement = placement
        self.mediaPlacement = mediaPlacement
        self.content = content
        self.animationReference = animationReference
        self.animationRequest = animationRequest
    }
}

/// A completed scene subplan: the ordered active layers of one scene at one effective scene time
/// (Task-002 plan, §12).
public struct SceneSubplan: Equatable, Sendable {
    public let sceneID: SceneInstanceID
    public let role: SceneRole
    /// CP7.5 TWO-CLOCK — VISUAL/template clock: scene-local time for template/layer animation and
    /// `activeRange` visibility. CLAMPED/held at `nominalDuration - 1 tick` when the scene is
    /// stretched, so animation freezes on the last native frame. Equals `mediaPlaybackTime` for an
    /// unstretched scene (and inside its native span).
    public let visualPlaybackTime: ScenePlaybackTime
    /// CP7.5 TWO-CLOCK — MEDIA clock: scene-local time for user video `SourceRequest` target.
    /// CONTINUES across the full timeline span (never clamped to nominal). For an animated transition
    /// the outgoing scene's media time continues past its nominal end at normal speed. (This is the
    /// former `scenePlaybackTime`, renamed for clarity — D2.)
    public let mediaPlaybackTime: ScenePlaybackTime
    /// Present only for a scene participating in an animated transition.
    public let transitionRelativeTime: TransitionRelativeTime?
    public let layers: [ActiveLayer]

    public init(
        sceneID: SceneInstanceID,
        role: SceneRole,
        visualPlaybackTime: ScenePlaybackTime,
        mediaPlaybackTime: ScenePlaybackTime,
        transitionRelativeTime: TransitionRelativeTime?,
        layers: [ActiveLayer]
    ) {
        self.sceneID = sceneID
        self.role = role
        self.visualPlaybackTime = visualPlaybackTime
        self.mediaPlaybackTime = mediaPlaybackTime
        self.transitionRelativeTime = transitionRelativeTime
        self.layers = layers
    }
}

/// A transition body combining two completed scene subplans (Task-002 plan, §12).
///
/// Progress is an exact rational `progressNumerator / progressDenominator` with
/// `0 <= progress < 1`; `progress == 1` is never emitted (the window is half-open).
public struct TransitionPlan: Equatable, Sendable {
    public let effectID: TransitionEffectID
    public let parameters: TransitionParameterSet
    public let easing: EasingReference
    public let progressNumerator: Int64
    public let progressDenominator: Int64
    public let outgoing: SceneSubplan
    public let incoming: SceneSubplan

    public init(
        effectID: TransitionEffectID,
        parameters: TransitionParameterSet,
        easing: EasingReference,
        progressNumerator: Int64,
        progressDenominator: Int64,
        outgoing: SceneSubplan,
        incoming: SceneSubplan
    ) {
        self.effectID = effectID
        self.parameters = parameters
        self.easing = easing
        self.progressNumerator = progressNumerator
        self.progressDenominator = progressDenominator
        self.outgoing = outgoing
        self.incoming = incoming
    }
}

/// The body of a frame: a single scene or a transition (Task-002 plan, §12).
public enum FrameBody: Equatable, Sendable {
    case single(SceneSubplan)
    case transition(TransitionPlan)
}

/// A single active global overlay in a frame plan (Task-002 plan, §12).
public struct ActiveOverlay: Equatable, Sendable {
    public let overlayID: OverlayID
    public let zIndex: Int
    public let stableOrdinal: Int
    /// Dense composition order (0-based) among active overlays, after stable ordering.
    public let compositionOrder: Int
    public let placement: Placement
    public let content: OverlayContent
    public let animationReference: AnimationReference?
    public let animationRequest: AnimationRequest?
    public let playbackTime: OverlayPlaybackTime

    public init(
        overlayID: OverlayID,
        zIndex: Int,
        stableOrdinal: Int,
        compositionOrder: Int,
        placement: Placement,
        content: OverlayContent,
        animationReference: AnimationReference?,
        animationRequest: AnimationRequest?,
        playbackTime: OverlayPlaybackTime
    ) {
        self.overlayID = overlayID
        self.zIndex = zIndex
        self.stableOrdinal = stableOrdinal
        self.compositionOrder = compositionOrder
        self.placement = placement
        self.content = content
        self.animationReference = animationReference
        self.animationRequest = animationRequest
        self.playbackTime = playbackTime
    }
}

/// The immutable, render-complete plan for one exact project time (Task-002 plan, §12).
///
/// The renderer never needs to read mutable project state to interpret a `FramePlan`.
public struct FramePlan: Equatable, Sendable {
    public let output: OutputContext
    public let projectTime: ProjectTime
    public let body: FrameBody
    public let overlays: [ActiveOverlay]

    public init(
        output: OutputContext,
        projectTime: ProjectTime,
        body: FrameBody,
        overlays: [ActiveOverlay]
    ) {
        self.output = output
        self.projectTime = projectTime
        self.body = body
        self.overlays = overlays
    }
}
