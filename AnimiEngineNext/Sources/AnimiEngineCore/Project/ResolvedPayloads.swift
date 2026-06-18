/// An immutable, fully-resolved scene payload (Task-002 plan, §6.1).
///
/// Resolved payloads are loaded by a later IO/scheduler layer. They carry the scene's layers and
/// template reference; the manifest carries timing.
public struct ResolvedScenePayload: Equatable, Sendable {
    public let payloadID: ScenePayloadID
    public let sceneID: SceneInstanceID
    public let templateRef: TemplateReference
    public let layers: [SceneLayer]

    public init(
        payloadID: ScenePayloadID,
        sceneID: SceneInstanceID,
        templateRef: TemplateReference,
        layers: [SceneLayer]
    ) {
        self.payloadID = payloadID
        self.sceneID = sceneID
        self.templateRef = templateRef
        self.layers = layers
    }
}

/// An immutable, fully-resolved overlay payload (Task-002 plan, §6.1).
public struct ResolvedOverlayPayload: Equatable, Sendable {
    public let payloadID: OverlayPayloadID
    public let overlayID: OverlayID
    public let content: OverlayContent
    public let placement: Placement
    public let animation: AnimationReference?

    public init(
        payloadID: OverlayPayloadID,
        overlayID: OverlayID,
        content: OverlayContent,
        placement: Placement,
        animation: AnimationReference?
    ) {
        self.payloadID = payloadID
        self.overlayID = overlayID
        self.content = content
        self.placement = placement
        self.animation = animation
    }
}
