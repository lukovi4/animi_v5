/// Slice-003 Stage D — the complete-frame workset (ADR-006 §6, ADR-005 §5).
///
/// One `FrameWorkset` is one exact `ProjectTime`'s complete unit of work: the `RequestIdentity` that
/// tags it and the immutable `FramePlan` it must realise. Every required render input (each video/image
/// scene layer, each transition input, each overlay) is **derived from the `FramePlan`** — never
/// invented by hand — so the required-input set cannot drift from what evaluation produced. Because a
/// `FramePlan` is render-complete for exactly one `projectTime`, the whole workset is intrinsically
/// single-time: there is no place to mix two project times within one workset.
public struct FrameWorkset: Sendable, Equatable {
    public let identity: RequestIdentity
    public let plan: FramePlan

    public init(identity: RequestIdentity, plan: FramePlan) {
        self.identity = identity
        self.plan = plan
    }

    /// The exact project time this workset composes — taken from the plan, and required by contract to
    /// equal the request identity's time (see ``isInternallyConsistent``).
    public var projectTime: ProjectTime { plan.projectTime }

    /// The complete set of required render inputs, derived from the `FramePlan` body + overlays. Stable,
    /// deterministic order: body inputs first (single scene, or outgoing-then-incoming for a transition),
    /// then overlays. Every input is anchored to this workset's single `projectTime`.
    public var requiredInputs: [RequiredInput] {
        var inputs: [RequiredInput] = []
        switch plan.body {
        case let .single(subplan):
            inputs.append(contentsOf: subplan.requiredInputs())
        case let .transition(transition):
            inputs.append(contentsOf: transition.outgoing.requiredInputs())
            inputs.append(contentsOf: transition.incoming.requiredInputs())
        }
        for overlay in plan.overlays {
            inputs.append(.overlay(overlayID: overlay.overlayID))
        }
        return inputs
    }

    /// The workset is internally consistent only when the plan's time equals the request identity's
    /// time. A mismatch would be a mixed-time workset and is rejected by the publication gate.
    public var isInternallyConsistent: Bool {
        plan.projectTime == identity.time
    }
}

/// One required render input derived from a `FramePlan`. Identifies WHAT must resolve for the frame to
/// be complete (a scene layer's media, or an overlay), keyed by stable identity — no pixels, no media
/// payload. Used by the publication gate to verify completeness and single-time/single-epoch coherence.
public enum RequiredInput: Sendable, Equatable, Hashable {
    case sceneLayer(sceneID: SceneInstanceID, layerID: LayerID, kind: SceneLayerInputKind)
    case overlay(overlayID: OverlayID)
}

public enum SceneLayerInputKind: Sendable, Equatable, Hashable {
    case video
    case image
}

extension SceneSubplan {
    /// The required inputs contributed by this scene subplan's active layers, in their stable
    /// composition order. Anchored implicitly to the enclosing frame plan's single project time.
    func requiredInputs() -> [RequiredInput] {
        layers.map { layer in
            let kind: SceneLayerInputKind
            switch layer.content {
            case .video: kind = .video
            case .image: kind = .image
            }
            return .sceneLayer(sceneID: sceneID, layerID: layer.layerID, kind: kind)
        }
    }
}
