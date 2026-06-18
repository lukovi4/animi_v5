import AnimiEngineCore

/// Task-003 plan §17 step 7 (Stage-6 corrected) — the **complete immutable selected-AnimIR program**
/// carried by `RenderMaterialTable`, expressed entirely in RenderModel fixed-point / rational value
/// types.
///
/// It preserves every authored AnimIR feature — compositions, layers and their order, layer timing,
/// transforms, animated value tracks, keyframes and tangents, masks, mattes, bezier paths, the
/// referenced scene-level path resources, the asset index, the binding, input geometry, meta, the
/// render-required media geometry, and toggle state — with **no `Double`, no DTO, no file path, no
/// URL, no pixel buffer**, and **no dependency on the template adapter**.
///
/// Numeric semantics (Stage-6 correction item 2):
///   * position / anchor / path / stroke width → `CanvasScalar` (65,536 per point);
///   * scale → `ScaleScalar` (1,000,000 per 1.0; authored 100% → 1,000,000);
///   * layer / mask / fill opacity → `OpacityScalar` (authored `0...100` ÷ 100);
///   * stroke opacity → `OpacityScalar` (authored `0...1` directly);
///   * rotation → `RotationScalar`;
///   * easing tangents → `EasingScalar`; miter limit → `MiterScalar` (dimensionless, 1,000,000/unit);
///   * keyframe / meta / path times → exact `RationalSourceTime` (no decimal quantization).

// MARK: - Structured identity

/// A structured, collision-safe identity for a selected render material (Stage-6 correction item 4):
/// the `compiledTemplateHash` of the source bytes, the `blockID`, and the `variantID`. The raw value
/// joins them so identical block/variant ids across *different* templates never collide.
public struct RenderMaterialID: Hashable, Sendable, Comparable {
    public let compiledTemplateHash: String
    public let blockID: String
    public let variantID: String
    public let rawValue: String

    public init(compiledTemplateHash: String, blockID: String, variantID: String) throws {
        guard !compiledTemplateHash.isEmpty else { throw RenderModelError.emptyIdentifier(field: "RenderMaterialID.compiledTemplateHash") }
        guard !blockID.isEmpty else { throw RenderModelError.emptyIdentifier(field: "RenderMaterialID.blockID") }
        guard !variantID.isEmpty else { throw RenderModelError.emptyIdentifier(field: "RenderMaterialID.variantID") }
        self.compiledTemplateHash = compiledTemplateHash
        self.blockID = blockID
        self.variantID = variantID
        // Length-prefixed join so distinct field splits cannot alias to one raw string.
        self.rawValue = "\(compiledTemplateHash.count):\(compiledTemplateHash)|\(blockID.count):\(blockID)|\(variantID.count):\(variantID)"
    }

    public static func < (lhs: RenderMaterialID, rhs: RenderMaterialID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A scene-layer binding key (Stage-6 correction item 4): a `SceneInstanceID` + `LayerID`. The
/// material table maps this to a `RenderMaterialID`, so a later `RenderInputResolver` can resolve a
/// FramePlan layer from only `SceneSubplan.sceneID` + `ActiveLayer.layerID`, without importing the
/// template adapter.
public struct SceneMaterialBindingKey: Hashable, Sendable, Comparable {
    public let sceneID: SceneInstanceID
    public let layerID: LayerID

    public init(sceneID: SceneInstanceID, layerID: LayerID) {
        self.sceneID = sceneID
        self.layerID = layerID
    }

    public static func < (lhs: SceneMaterialBindingKey, rhs: SceneMaterialBindingKey) -> Bool {
        if lhs.sceneID != rhs.sceneID { return lhs.sceneID < rhs.sceneID }
        return lhs.layerID < rhs.layerID
    }
}

// MARK: - Leaf value types

/// A 2-D fixed-point vector in canvas units (coordinates, tangents).
public struct RenderVec2: Hashable, Sendable {
    public let x: CanvasScalar
    public let y: CanvasScalar
    public init(x: CanvasScalar, y: CanvasScalar) { self.x = x; self.y = y }
    func canonicalValue() -> RenderCanonicalEncoding.Value { .object([("x", .int(x.rawValue)), ("y", .int(y.rawValue))]) }
}

/// A 2-D scale vector in fixed-point scale units (1,000,000 per 1.0).
public struct RenderScaleVec2: Hashable, Sendable {
    public let x: ScaleScalar
    public let y: ScaleScalar
    public init(x: ScaleScalar, y: ScaleScalar) { self.x = x; self.y = y }
    func canonicalValue() -> RenderCanonicalEncoding.Value { .object([("x", .int(x.rawValue)), ("y", .int(y.rawValue))]) }
}

/// A 2-D **easing-control** vector (Lottie keyframe tangents), dimensionless (1,000,000 per 1.0). It
/// is *not* a canvas coordinate (Stage-6 correction item 2): keyframe `inTangent`/`outTangent` are
/// easing handles, so they use `EasingScalar`, never `CanvasScalar`.
public struct RenderEasingVec2: Hashable, Sendable {
    public let x: EasingScalar
    public let y: EasingScalar
    public init(x: EasingScalar, y: EasingScalar) { self.x = x; self.y = y }
    func canonicalValue() -> RenderCanonicalEncoding.Value { .object([("x", .int(x.rawValue)), ("y", .int(y.rawValue))]) }
}

/// An RGBA colour with each component fixed-point in `[0, 1]`.
public struct RenderColor: Hashable, Sendable {
    public let components: [NormalizedColorComponent]
    public init(components: [NormalizedColorComponent]) { self.components = components }
    func canonicalValue() -> RenderCanonicalEncoding.Value { .array(components.map { .int($0.rawValue) }) }
}

private func rationalValue(_ r: RationalSourceTime) -> RenderCanonicalEncoding.Value {
    .object([("den", .int(r.denominator)), ("num", .int(r.numerator))])
}

/// One animated keyframe of a value of type `V`. The `inTangent`/`outTangent` are Lottie easing
/// controls (`RenderEasingVec2`), not canvas coordinates (item 2).
public struct RenderKeyframe<V: Hashable & Sendable>: Hashable, Sendable {
    public let time: RationalSourceTime
    public let value: V
    public let hold: Bool
    public let inTangent: RenderEasingVec2?
    public let outTangent: RenderEasingVec2?

    public init(time: RationalSourceTime, value: V, hold: Bool, inTangent: RenderEasingVec2?, outTangent: RenderEasingVec2?) {
        self.time = time; self.value = value; self.hold = hold
        self.inTangent = inTangent; self.outTangent = outTangent
    }

    func canonicalValue(_ encodeValue: (V) -> RenderCanonicalEncoding.Value) -> RenderCanonicalEncoding.Value {
        var pairs: [(String, RenderCanonicalEncoding.Value)] = [
            ("hold", .bool(hold)), ("time", rationalValue(time)), ("value", encodeValue(value))
        ]
        if let inTangent { pairs.append(("inTangent", inTangent.canonicalValue())) }
        if let outTangent { pairs.append(("outTangent", outTangent.canonicalValue())) }
        return .object(pairs)
    }
}

/// A scalar (canvas-unit) animated track (e.g. stroke width).
public enum RenderScalarTrack: Hashable, Sendable {
    case `static`(CanvasScalar)
    case keyframed([RenderKeyframe<CanvasScalar>])
    func canonicalValue() -> RenderCanonicalEncoding.Value {
        switch self {
        case .static(let v): return .object([("static", .int(v.rawValue))])
        case .keyframed(let ks): return .object([("keyframed", .array(ks.map { $0.canonicalValue { .int($0.rawValue) } }))])
        }
    }
}

/// A vector (canvas-unit) animated track (position/anchor).
public enum RenderVectorTrack: Hashable, Sendable {
    case `static`(RenderVec2)
    case keyframed([RenderKeyframe<RenderVec2>])
    func canonicalValue() -> RenderCanonicalEncoding.Value {
        switch self {
        case .static(let v): return .object([("static", v.canonicalValue())])
        case .keyframed(let ks): return .object([("keyframed", .array(ks.map { $0.canonicalValue { $0.canonicalValue() } }))])
        }
    }
}

/// A scale (scale-unit) animated track.
public enum RenderScaleTrack: Hashable, Sendable {
    case `static`(RenderScaleVec2)
    case keyframed([RenderKeyframe<RenderScaleVec2>])
    func canonicalValue() -> RenderCanonicalEncoding.Value {
        switch self {
        case .static(let v): return .object([("static", v.canonicalValue())])
        case .keyframed(let ks): return .object([("keyframed", .array(ks.map { $0.canonicalValue { $0.canonicalValue() } }))])
        }
    }
}

/// An opacity (`[0,1]` opacity-unit) animated track.
public enum RenderOpacityTrack: Hashable, Sendable {
    case `static`(OpacityScalar)
    case keyframed([RenderKeyframe<OpacityScalar>])
    func canonicalValue() -> RenderCanonicalEncoding.Value {
        switch self {
        case .static(let v): return .object([("static", .int(v.rawValue))])
        case .keyframed(let ks): return .object([("keyframed", .array(ks.map { $0.canonicalValue { .int($0.rawValue) } }))])
        }
    }
}

/// A rotation (degrees) animated track.
public enum RenderRotationTrack: Hashable, Sendable {
    case `static`(RotationScalar)
    case keyframed([RenderKeyframe<RotationScalar>])
    func canonicalValue() -> RenderCanonicalEncoding.Value {
        switch self {
        case .static(let v): return .object([("static", .int(v.rawValue))])
        case .keyframed(let ks): return .object([("keyframed", .array(ks.map { $0.canonicalValue { .int($0.rawValue) } }))])
        }
    }
}

/// A bezier path value.
public struct RenderBezier: Hashable, Sendable {
    public let vertices: [RenderVec2]
    public let inTangents: [RenderVec2]
    public let outTangents: [RenderVec2]
    public let closed: Bool
    public init(vertices: [RenderVec2], inTangents: [RenderVec2], outTangents: [RenderVec2], closed: Bool) {
        self.vertices = vertices; self.inTangents = inTangents; self.outTangents = outTangents; self.closed = closed
    }
    func canonicalValue() -> RenderCanonicalEncoding.Value {
        .object([
            ("closed", .bool(closed)),
            ("inTangents", .array(inTangents.map { $0.canonicalValue() })),
            ("outTangents", .array(outTangents.map { $0.canonicalValue() })),
            ("vertices", .array(vertices.map { $0.canonicalValue() }))
        ])
    }
}

/// An animated bezier path track.
public enum RenderAnimatedPath: Hashable, Sendable {
    case `static`(RenderBezier)
    case keyframed([RenderKeyframe<RenderBezier>])
    func canonicalValue() -> RenderCanonicalEncoding.Value {
        switch self {
        case .static(let b): return .object([("staticBezier", b.canonicalValue())])
        case .keyframed(let ks): return .object([("keyframedBezier", .array(ks.map { $0.canonicalValue { $0.canonicalValue() } }))])
        }
    }
}

// MARK: - Transform / shape structures

/// A full layer transform.
public struct RenderTransform: Hashable, Sendable {
    public let position: RenderVectorTrack
    public let scale: RenderScaleTrack
    public let rotation: RenderRotationTrack
    public let opacity: RenderOpacityTrack
    public let anchor: RenderVectorTrack
    public init(position: RenderVectorTrack, scale: RenderScaleTrack, rotation: RenderRotationTrack,
                opacity: RenderOpacityTrack, anchor: RenderVectorTrack) {
        self.position = position; self.scale = scale; self.rotation = rotation
        self.opacity = opacity; self.anchor = anchor
    }
    func canonicalValue() -> RenderCanonicalEncoding.Value {
        .object([
            ("anchor", anchor.canonicalValue()), ("opacity", opacity.canonicalValue()),
            ("position", position.canonicalValue()), ("rotation", rotation.canonicalValue()),
            ("scale", scale.canonicalValue())
        ])
    }
}

/// A stroke style.
public struct RenderStroke: Hashable, Sendable {
    public let color: RenderColor
    public let opacity: OpacityScalar
    public let width: RenderScalarTrack
    public let lineCap: Int
    public let lineJoin: Int
    public let miterLimit: MiterScalar
    public init(color: RenderColor, opacity: OpacityScalar, width: RenderScalarTrack,
                lineCap: Int, lineJoin: Int, miterLimit: MiterScalar) {
        self.color = color; self.opacity = opacity; self.width = width
        self.lineCap = lineCap; self.lineJoin = lineJoin; self.miterLimit = miterLimit
    }
    func canonicalValue() -> RenderCanonicalEncoding.Value {
        .object([
            ("color", color.canonicalValue()), ("lineCap", .int(Int64(lineCap))),
            ("lineJoin", .int(Int64(lineJoin))), ("miterLimit", .int(miterLimit.rawValue)),
            ("opacity", .int(opacity.rawValue)), ("width", width.canonicalValue())
        ])
    }
}

/// A group transform inside a shape group.
public struct RenderGroupTransform: Hashable, Sendable {
    public let position: RenderVectorTrack
    public let anchor: RenderVectorTrack
    public let scale: RenderScaleTrack
    public let rotation: RenderRotationTrack
    public let opacity: RenderOpacityTrack
    public init(position: RenderVectorTrack, anchor: RenderVectorTrack, scale: RenderScaleTrack,
                rotation: RenderRotationTrack, opacity: RenderOpacityTrack) {
        self.position = position; self.anchor = anchor; self.scale = scale
        self.rotation = rotation; self.opacity = opacity
    }
    func canonicalValue() -> RenderCanonicalEncoding.Value {
        .object([
            ("anchor", anchor.canonicalValue()), ("opacity", opacity.canonicalValue()),
            ("position", position.canonicalValue()), ("rotation", rotation.canonicalValue()),
            ("scale", scale.canonicalValue())
        ])
    }
}

/// A shape group.
public struct RenderShapeGroup: Hashable, Sendable {
    public let animPath: RenderAnimatedPath?
    public let fillColor: RenderColor?
    public let fillOpacity: OpacityScalar
    public let stroke: RenderStroke?
    public let groupTransforms: [RenderGroupTransform]
    public let pathID: Int?
    public init(animPath: RenderAnimatedPath?, fillColor: RenderColor?, fillOpacity: OpacityScalar,
                stroke: RenderStroke?, groupTransforms: [RenderGroupTransform], pathID: Int?) {
        self.animPath = animPath; self.fillColor = fillColor; self.fillOpacity = fillOpacity
        self.stroke = stroke; self.groupTransforms = groupTransforms; self.pathID = pathID
    }
    func canonicalValue() -> RenderCanonicalEncoding.Value {
        var pairs: [(String, RenderCanonicalEncoding.Value)] = [
            ("fillOpacity", .int(fillOpacity.rawValue)),
            ("groupTransforms", .array(groupTransforms.map { $0.canonicalValue() }))
        ]
        if let animPath { pairs.append(("animPath", animPath.canonicalValue())) }
        if let fillColor { pairs.append(("fillColor", fillColor.canonicalValue())) }
        if let stroke { pairs.append(("stroke", stroke.canonicalValue())) }
        if let pathID { pairs.append(("pathID", .int(Int64(pathID)))) }
        return .object(pairs)
    }
}

// MARK: - Layer content / masks / matte

/// The content kind of a layer.
public enum RenderLayerContent: Hashable, Sendable {
    case image(assetID: String)
    case precomp(compID: String)
    case shapes(RenderShapeGroup)
    case none
    func canonicalValue() -> RenderCanonicalEncoding.Value {
        switch self {
        case .image(let a): return .object([("image", .object([("assetID", .string(a))]))])
        case .precomp(let c): return .object([("precomp", .object([("compID", .string(c))]))])
        case .shapes(let g): return .object([("shapes", g.canonicalValue())])
        case .none: return .object([("none", .object([]))])
        }
    }
}

/// A layer mask.
public struct RenderMask: Hashable, Sendable {
    public let mode: String
    public let inverted: Bool
    public let opacity: OpacityScalar
    public let path: RenderAnimatedPath
    public let pathID: Int?
    public init(mode: String, inverted: Bool, opacity: OpacityScalar, path: RenderAnimatedPath, pathID: Int?) {
        self.mode = mode; self.inverted = inverted; self.opacity = opacity; self.path = path; self.pathID = pathID
    }
    func canonicalValue() -> RenderCanonicalEncoding.Value {
        var pairs: [(String, RenderCanonicalEncoding.Value)] = [
            ("inverted", .bool(inverted)), ("mode", .string(mode)),
            ("opacity", .int(opacity.rawValue)), ("path", path.canonicalValue())
        ]
        if let pathID { pairs.append(("pathID", .int(Int64(pathID)))) }
        return .object(pairs)
    }
}

/// A matte reference.
public struct RenderMatte: Hashable, Sendable {
    public let mode: Int
    public let sourceLayerID: Int
    public init(mode: Int, sourceLayerID: Int) { self.mode = mode; self.sourceLayerID = sourceLayerID }
    func canonicalValue() -> RenderCanonicalEncoding.Value {
        .object([("mode", .int(Int64(mode))), ("sourceLayerID", .int(Int64(sourceLayerID)))])
    }
}

/// Layer-local timing, exact rational.
public struct RenderLayerTiming: Hashable, Sendable {
    public let inPoint: RationalSourceTime
    public let outPoint: RationalSourceTime
    public let startTime: RationalSourceTime
    public init(inPoint: RationalSourceTime, outPoint: RationalSourceTime, startTime: RationalSourceTime) {
        self.inPoint = inPoint; self.outPoint = outPoint; self.startTime = startTime
    }
    func canonicalValue() -> RenderCanonicalEncoding.Value {
        .object([("inPoint", rationalValue(inPoint)), ("outPoint", rationalValue(outPoint)), ("startTime", rationalValue(startTime))])
    }
}

// MARK: - Layer / composition

/// One AnimIR layer, fully converted.
public struct RenderLayer: Hashable, Sendable {
    public let id: Int
    public let name: String
    public let type: Int
    public let timing: RenderLayerTiming
    public let parentLayerID: Int?
    public let transform: RenderTransform
    public let masks: [RenderMask]
    public let matte: RenderMatte?
    public let content: RenderLayerContent
    public let isMatteSource: Bool
    public let isHidden: Bool
    public let toggleID: String?

    public init(id: Int, name: String, type: Int, timing: RenderLayerTiming, parentLayerID: Int?,
                transform: RenderTransform, masks: [RenderMask], matte: RenderMatte?,
                content: RenderLayerContent, isMatteSource: Bool, isHidden: Bool, toggleID: String?) {
        self.id = id; self.name = name; self.type = type; self.timing = timing
        self.parentLayerID = parentLayerID; self.transform = transform; self.masks = masks
        self.matte = matte; self.content = content; self.isMatteSource = isMatteSource
        self.isHidden = isHidden; self.toggleID = toggleID
    }

    func canonicalValue() -> RenderCanonicalEncoding.Value {
        var pairs: [(String, RenderCanonicalEncoding.Value)] = [
            ("content", content.canonicalValue()), ("id", .int(Int64(id))),
            ("isHidden", .bool(isHidden)), ("isMatteSource", .bool(isMatteSource)),
            ("masks", .array(masks.map { $0.canonicalValue() })), ("name", .string(name)),
            ("timing", timing.canonicalValue()), ("transform", transform.canonicalValue()),
            ("type", .int(Int64(type)))
        ]
        if let parentLayerID { pairs.append(("parentLayerID", .int(Int64(parentLayerID)))) }
        if let matte { pairs.append(("matte", matte.canonicalValue())) }
        if let toggleID { pairs.append(("toggleID", .string(toggleID))) }
        return .object(pairs)
    }
}

/// One AnimIR composition.
public struct RenderComposition: Hashable, Sendable {
    public let id: String
    public let width: CanvasScalar
    public let height: CanvasScalar
    public let layers: [RenderLayer]
    public init(id: String, width: CanvasScalar, height: CanvasScalar, layers: [RenderLayer]) {
        self.id = id; self.width = width; self.height = height; self.layers = layers
    }
    func canonicalValue() -> RenderCanonicalEncoding.Value {
        .object([
            ("height", .int(height.rawValue)), ("id", .string(id)),
            ("layers", .array(layers.map { $0.canonicalValue() })), ("width", .int(width.rawValue))
        ])
    }
}

// MARK: - Asset index / binding / input geometry / media geometry / meta

/// One asset-index entry.
public struct RenderAsset: Hashable, Sendable {
    public let id: String
    public let resolvedID: String
    public let basename: String
    public let width: CanvasScalar
    public let height: CanvasScalar
    public init(id: String, resolvedID: String, basename: String, width: CanvasScalar, height: CanvasScalar) {
        self.id = id; self.resolvedID = resolvedID; self.basename = basename; self.width = width; self.height = height
    }
    func canonicalValue() -> RenderCanonicalEncoding.Value {
        .object([
            ("basename", .string(basename)), ("height", .int(height.rawValue)),
            ("id", .string(id)), ("resolvedID", .string(resolvedID)), ("width", .int(width.rawValue))
        ])
    }
}

/// The AnimIR binding.
public struct RenderBinding: Hashable, Sendable {
    public let bindingKey: String
    public let boundAssetID: String
    public let boundCompID: String
    public let boundLayerID: Int
    public init(bindingKey: String, boundAssetID: String, boundCompID: String, boundLayerID: Int) {
        self.bindingKey = bindingKey; self.boundAssetID = boundAssetID
        self.boundCompID = boundCompID; self.boundLayerID = boundLayerID
    }
    func canonicalValue() -> RenderCanonicalEncoding.Value {
        .object([
            ("bindingKey", .string(bindingKey)), ("boundAssetID", .string(boundAssetID)),
            ("boundCompID", .string(boundCompID)), ("boundLayerID", .int(Int64(boundLayerID)))
        ])
    }
}

/// AnimIR input geometry (optional).
public struct RenderInputGeometry: Hashable, Sendable {
    public let layerID: Int
    public let pathID: Int
    public let animPath: RenderAnimatedPath
    public let compID: String
    public init(layerID: Int, pathID: Int, animPath: RenderAnimatedPath, compID: String) {
        self.layerID = layerID; self.pathID = pathID; self.animPath = animPath; self.compID = compID
    }
    func canonicalValue() -> RenderCanonicalEncoding.Value {
        .object([
            ("animPath", animPath.canonicalValue()), ("compID", .string(compID)),
            ("layerID", .int(Int64(layerID))), ("pathID", .int(Int64(pathID)))
        ])
    }
}

/// The render-required media geometry of a block. Step-8 corrective (issue #2) pins the distinct
/// coordinate roles, matching the TVECore compatibility oracle:
///   * `contentRect` (binding baseline, local placeholder space, always `(0,0,w,h)`) — the **fit
///     baseline** for cover/contain/fill;
///   * `blockRectCanvas` (the block's canvas rectangle, `block.rect`) — the **slotRect container clip**
///     (`SceneRenderPlan.pushClipRect(block.rectCanvas)`);
///   * `placementRect` (media-input aperture geometry) — a **separate** entity for input geometry,
///     hit-test and mask; it is **not** the fit baseline and **not** the clip.
/// No UI hit-testing behaviour is performed here.
public struct RenderMediaGeometry: Hashable, Sendable {
    public let contentSizeWidth: CanvasScalar
    public let contentSizeHeight: CanvasScalar
    /// Binding-baseline content rect in local placeholder space — the fit baseline.
    public let contentRect: FixedRect
    /// Media-input aperture rect (local) — separate from the fit baseline and the clip.
    public let placementRect: FixedRect
    /// The block's canvas rect — the `slotRect` container clip target (oracle: `block.rectCanvas`).
    public let blockRectCanvas: FixedRect
    /// Container clip policy: "slotRect", "slotRectAfterSettle", "none" (the pinned producer tags).
    public let containerClip: String

    public init(contentSizeWidth: CanvasScalar, contentSizeHeight: CanvasScalar,
                contentRect: FixedRect, placementRect: FixedRect, blockRectCanvas: FixedRect,
                containerClip: String) {
        self.contentSizeWidth = contentSizeWidth
        self.contentSizeHeight = contentSizeHeight
        self.contentRect = contentRect
        self.placementRect = placementRect
        self.blockRectCanvas = blockRectCanvas
        self.containerClip = containerClip
    }

    private static func rect(_ r: FixedRect) -> RenderCanonicalEncoding.Value {
        .object([("height", .int(r.height.rawValue)), ("width", .int(r.width.rawValue)),
                 ("x", .int(r.x.rawValue)), ("y", .int(r.y.rawValue))])
    }
    func canonicalValue() -> RenderCanonicalEncoding.Value {
        .object([
            ("blockRectCanvas", Self.rect(blockRectCanvas)),
            ("containerClip", .string(containerClip)),
            ("contentRect", Self.rect(contentRect)),
            ("contentSizeHeight", .int(contentSizeHeight.rawValue)),
            ("contentSizeWidth", .int(contentSizeWidth.rawValue)),
            ("placementRect", Self.rect(placementRect))
        ])
    }
}

/// AnimIR meta, exact rational where temporal.
public struct RenderProgramMeta: Hashable, Sendable {
    public let width: CanvasScalar
    public let height: CanvasScalar
    public let fps: RationalSourceTime
    public let inPoint: RationalSourceTime
    public let outPoint: RationalSourceTime
    public let sourceAnimRef: String
    public init(width: CanvasScalar, height: CanvasScalar, fps: RationalSourceTime,
                inPoint: RationalSourceTime, outPoint: RationalSourceTime, sourceAnimRef: String) {
        self.width = width; self.height = height; self.fps = fps
        self.inPoint = inPoint; self.outPoint = outPoint; self.sourceAnimRef = sourceAnimRef
    }
    func canonicalValue() -> RenderCanonicalEncoding.Value {
        .object([
            ("fps", rationalValue(fps)), ("height", .int(height.rawValue)),
            ("inPoint", rationalValue(inPoint)), ("outPoint", rationalValue(outPoint)),
            ("sourceAnimRef", .string(sourceAnimRef)), ("width", .int(width.rawValue))
        ])
    }
}

// MARK: - The complete program

/// The complete immutable selected-AnimIR program for one block's selected variant (item 2).
public struct RenderMaterialProgram: Hashable, Sendable {
    public let id: RenderMaterialID
    public let blockID: String
    public let variantID: String
    public let animationRef: String
    /// The selected variant's AnimIR binding bound-asset id (item 3 — from the AnimIR binding).
    public let boundAssetID: String
    /// The render-required media geometry, kept explicitly separate from the bound asset (item 3, 5).
    public let mediaGeometry: RenderMediaGeometry
    public let rootCompID: String
    public let compositions: [RenderComposition]
    public let assets: [RenderAsset]
    public let binding: RenderBinding
    public let inputGeometry: RenderInputGeometry?
    public let meta: RenderProgramMeta
    /// The scene-level path resources referenced by this selected AnimIR, sorted by pathID, each once.
    public let pathResources: [RenderPathResource]
    /// The toggle ids present in this variant's AnimIR (sorted for determinism).
    public let toggleIDs: [String]

    public init(
        id: RenderMaterialID, blockID: String, variantID: String, animationRef: String,
        boundAssetID: String, mediaGeometry: RenderMediaGeometry, rootCompID: String,
        compositions: [RenderComposition], assets: [RenderAsset], binding: RenderBinding,
        inputGeometry: RenderInputGeometry?, meta: RenderProgramMeta,
        pathResources: [RenderPathResource], toggleIDs: [String]
    ) throws {
        guard !blockID.isEmpty else { throw RenderModelError.emptyIdentifier(field: "RenderMaterialProgram.blockID") }
        guard !variantID.isEmpty else { throw RenderModelError.emptyIdentifier(field: "RenderMaterialProgram.variantID") }
        guard !animationRef.isEmpty else { throw RenderModelError.emptyIdentifier(field: "RenderMaterialProgram.animationRef") }
        guard !boundAssetID.isEmpty else { throw RenderModelError.emptyIdentifier(field: "RenderMaterialProgram.boundAssetID") }
        guard !rootCompID.isEmpty else { throw RenderModelError.emptyIdentifier(field: "RenderMaterialProgram.rootCompID") }
        // Path resources must be sorted by pathID and unique (each referenced pathID resolves once).
        var seen = Set<Int>()
        var previous: Int? = nil
        for resource in pathResources {
            guard seen.insert(resource.pathID).inserted else {
                throw RenderModelError.duplicateIdentity(
                    field: "RenderMaterialProgram.pathResources", value: String(resource.pathID))
            }
            if let p = previous, resource.pathID < p {
                throw RenderModelError.unsupportedValue(
                    field: "RenderMaterialProgram.pathResources", value: "unsorted at \(resource.pathID)")
            }
            previous = resource.pathID
        }
        self.id = id; self.blockID = blockID; self.variantID = variantID; self.animationRef = animationRef
        self.boundAssetID = boundAssetID; self.mediaGeometry = mediaGeometry; self.rootCompID = rootCompID
        self.compositions = compositions; self.assets = assets; self.binding = binding
        self.inputGeometry = inputGeometry; self.meta = meta
        self.pathResources = pathResources; self.toggleIDs = toggleIDs
    }

    func canonicalValue() -> RenderCanonicalEncoding.Value {
        var pairs: [(String, RenderCanonicalEncoding.Value)] = [
            ("animationRef", .string(animationRef)),
            ("assets", .array(assets.map { $0.canonicalValue() })),
            ("binding", binding.canonicalValue()),
            ("blockID", .string(blockID)),
            ("boundAssetID", .string(boundAssetID)),
            ("compositions", .array(compositions.map { $0.canonicalValue() })),
            ("id", .string(id.rawValue)),
            ("mediaGeometry", mediaGeometry.canonicalValue()),
            ("meta", meta.canonicalValue()),
            ("pathResources", .array(pathResources.map { $0.canonicalValue() })),
            ("rootCompID", .string(rootCompID)),
            ("toggleIDs", .array(toggleIDs.map { .string($0) })),
            ("variantID", .string(variantID))
        ]
        if let inputGeometry { pairs.append(("inputGeometry", inputGeometry.canonicalValue())) }
        return .object(pairs)
    }
}
