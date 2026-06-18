import AnimiEngineCore
import AnimiEngineRenderModel

/// Mutable accumulator for the compiler (§17 step 9 corrective): collects command payloads in order,
/// tracks declared resources/surfaces (deduplicating by id), and assigns dense ordinals at the end.
/// Pure value type — no IO, no global state.
struct CompileContext {
    let input: ResolvedFrameInput
    let configuration: RenderConfiguration

    private var payloads: [RenderCommandPayload] = []
    private var declaredPixelIDs: Set<String> = []
    private var declaredSurfaceIDs: Set<String> = []
    /// Declared offscreen-surface descriptors by id, so an isolation surface can clone its target's
    /// width/height/profile/storage (Rev-4 §5.1).
    private var surfaceDescriptorsByID: [String: RenderResourceDescriptor] = [:]
    /// Declaration commands (resources/surfaces) are emitted up front, before the body, in a stable
    /// order so the graph hash is deterministic.
    private var declarations: [RenderCommandPayload] = []
    /// A monotonically increasing ordinal that disambiguates mask/matte isolation scopes deterministically
    /// (not a UUID or random hash; Rev-4 §5.2). Increases in compile (emit) order.
    private var nextScopeOrdinal: Int = 0

    init(input: ResolvedFrameInput, configuration: RenderConfiguration) {
        self.input = input
        self.configuration = configuration
    }

    mutating func emit(_ payload: RenderCommandPayload) { payloads.append(payload) }

    /// Allocates the next deterministic isolation-scope ordinal (Rev-4 §5.2).
    mutating func allocateScopeOrdinal() -> Int {
        defer { nextScopeOrdinal += 1 }
        return nextScopeOrdinal
    }

    /// Declares a pixel-input resource once (idempotent by id). Carries the owned bytes (corrective #1).
    mutating func declarePixelResource(_ pixels: ResolvedPixelInput) {
        guard declaredPixelIDs.insert(pixels.id.rawValue).inserted else { return }
        declarations.append(.declareResource(RenderResourceDescriptor(
            pixelInputID: pixels.id.rawValue, pixels: pixels, colorContract: configuration.colorContract)))
    }

    /// Declares an intermediate offscreen surface (linear canvas / scene / transition / matte) using the
    /// configuration's intermediate profile (corrective #6). Idempotent by id.
    mutating func declareIntermediateSurface(_ id: String, width: Int64, height: Int64, configuration: RenderConfiguration) {
        guard declaredSurfaceIDs.insert(id).inserted else { return }
        let descriptor = RenderResourceDescriptor(
            offscreenID: id, width: width, height: height,
            profile: .intermediate(configuration.intermediateProfile), colorContract: configuration.colorContract)
        surfaceDescriptorsByID[id] = descriptor
        declarations.append(.offscreenSurface(descriptor))
    }

    /// Declares the final sRGB output surface (corrective #6). Idempotent by id.
    mutating func declareFinalSRGBSurface(_ id: String, width: Int64, height: Int64, configuration: RenderConfiguration) {
        guard declaredSurfaceIDs.insert(id).inserted else { return }
        let descriptor = RenderResourceDescriptor(
            offscreenID: id, width: width, height: height,
            profile: .finalSRGB, colorContract: configuration.colorContract)
        surfaceDescriptorsByID[id] = descriptor
        declarations.append(.offscreenSurface(descriptor))
    }

    /// A context-unique matte-source surface id (corrective #3): includes scene/role/material-layer plus
    /// the comp + source-layer so two mattes in different scenes/programs cannot collide.
    func matteSurfaceID(scene: String, role: String, layerID: String, comp: String, sourceLayerID: Int) -> String {
        "surface\u{1F}matte\u{1F}\(scene)\u{1F}\(role)\u{1F}\(layerID)\u{1F}\(comp)\u{1F}\(sourceLayerID)"
    }

    /// A context-unique matte-consumer surface id (Rev-4 §2.9 / §5.4): the consumer subtree is isolated
    /// here before the link composites it into target.
    func matteConsumerSurfaceID(scene: String, role: String, layerID: String, comp: String, consumerLayerID: Int) -> String {
        "surface\u{1F}matteConsumer\u{1F}\(scene)\u{1F}\(role)\u{1F}\(layerID)\u{1F}\(comp)\u{1F}\(consumerLayerID)"
    }

    /// A context-unique mask-content surface id (Rev-4 §2.8 / §5.2): the masked layer's content is
    /// isolated here, then `endMask` applies the aggregate mask once into target. The deterministic
    /// `scopeOrdinal` distinguishes nested/sibling mask groups of the same layer.
    func maskContentSurfaceID(scene: String, role: String, layerID: String, comp: String, maskLayerID: Int, scopeOrdinal: Int) -> String {
        "surface\u{1F}maskContent\u{1F}\(scene)\u{1F}\(role)\u{1F}\(layerID)\u{1F}\(comp)\u{1F}\(maskLayerID)\u{1F}\(scopeOrdinal)"
    }

    /// Rev-4 §5.1 — declare an isolation surface that **clones the real target descriptor** exactly
    /// (width/height/profile/storage). Mask-content and matte source/consumer surfaces must clone their
    /// destination target, never a precomp's own dimensions. A missing/aliasing target is a typed error.
    mutating func declareIntermediateSurfaceLike(newID: String, targetSurfaceID: String) throws {
        guard newID != targetSurfaceID else {
            throw RenderGraphError.validatorSurfaceAlias(resourceID: newID)
        }
        guard let target = surfaceDescriptorsByID[targetSurfaceID] else {
            throw RenderGraphError.validatorInvalidSurfaceDependency(
                detail: "isolation surface \(newID) targets undeclared surface \(targetSurfaceID)")
        }
        guard let profile = target.surfaceProfile else {
            throw RenderGraphError.validatorInvalidSurfaceDependency(
                detail: "target \(targetSurfaceID) is not an offscreen surface")
        }
        guard declaredSurfaceIDs.insert(newID).inserted else { return }
        let descriptor = RenderResourceDescriptor(
            offscreenID: newID, width: target.width, height: target.height,
            profile: profile, colorContract: target.colorContract)
        surfaceDescriptorsByID[newID] = descriptor
        declarations.append(.offscreenSurface(descriptor))
    }

    /// The complete ordered command list: **all resource/surface declarations first** (so every
    /// resource is declared before its first use, corrective #5), then the body payloads (whose first
    /// payload is `clearBackground` — the first non-declaration command). This satisfies both the
    /// declaration-before-use rule and the "first non-declaration command clears the linear canvas"
    /// rule, verified in the validator's single sequential pass.
    func commands() throws -> [RenderCommand] {
        var ordered: [RenderCommandPayload] = []
        ordered.append(contentsOf: declarations)
        ordered.append(contentsOf: payloads)
        return try ordered.enumerated().map { try RenderCommand(ordinal: $0.offset, payload: $0.element) }
    }
}

/// Immutable per-scene-layer compilation frame: the resolved program/input and the fixed block→canvas
/// context used while expanding the program's composition tree.
struct LayerFrame {
    let program: RenderMaterialProgram
    let input: ResolvedFrameInput
    let key: ResolvedLayerKey
    let sceneID: SceneInstanceID
    let layerID: LayerID
    let roleRaw: String
    let target: String
    let blockToCanvas: FixedAffineTransform2D
    let mediaPlacement: ResolvedMediaPlacement
    let userPixelID: PixelInputID
    let userContentIsVideo: Bool
    /// Rev-4 §3.1 — the actual path resources by id (not only their id set), so masks/shapes can sample
    /// the producer-flattened mesh through `PathResourceSampler`.
    let pathResourcesByID: [Int: RenderPathResource]
}
