import AnimiEngineCore

/// Task-003 plan §7 — the immutable RenderGraph command set, with the **field-level payloads** the
/// graph compiler (§17 step 9) emits and the Metal executor (§17 step 10) consumes.
///
/// §7 fixes the closed *category* set and the *order* invariants (§7.1). This file attaches each
/// category's execution-relevant payload (resource ids, sampled transforms/opacity, clip/mask/matte
/// scopes, transition parameters, overlay placement, final conversion/output) as an immutable value.
/// Every payload is pure fixed point (no `Float`/`Double`) and canonically encodable, so the graph hash
/// covers all execution-relevant data and dictionary iteration order never affects it (item 9).

/// The closed set of command categories (§7).
public enum RenderCommandCategory: String, Hashable, Sendable, CaseIterable {
    case clearBackground
    case declareResource
    case beginScene
    case endScene
    case drawImage
    case drawVideoFrame
    case drawShape
    case beginClip
    case endClip
    case beginMask
    case endMask
    case matteLink
    case offscreenSurface
    case fadeTransition
    case slideTransition
    case overlay
    case finalLinearToSRGB
    case finalOutput
}

// MARK: - Shared payload value types

/// The kind of a declared immutable resource (§7 "immutable resource descriptors").
public enum RenderResourceKind: String, Hashable, Sendable, CaseIterable {
    /// A resolved pixel input (image / still-frame video / overlay), uploaded before encoding.
    case pixelInput
    /// An offscreen surface (a scene/transition intermediate), allocated by the executor.
    case offscreen
}

/// An immutable resource descriptor declared by a `declareResource`/`offscreenSurface` command.
///
/// Corrective #1: a `pixelInput` resource **retains the owned `ResolvedPixelInput`** — the bytes and
/// the complete format/orientation/colour metadata — so `MetalRenderSession.execute(graph)` is
/// self-contained and needs no external provider, cache, URL or lookup to obtain the pixels. The
/// canonical *identity* still uses the content hash + dimensions (not the raw bytes), so the graph hash
/// stays compact and deterministic while execution has the real bytes available.
/// The render profile of an offscreen surface (corrective #6/#8): an **intermediate** compositing
/// surface (linear canvas / scene / transition / matte) uses the configuration's intermediate profile;
/// the **final sRGB** output surface uses the pinned BGRA8/sRGB output profile. A pixel-input resource
/// carries no surface profile.
public enum RenderSurfaceProfile: Hashable, Sendable {
    case intermediate(IntermediateProfile)
    case finalSRGB

    var canonical: String {
        switch self {
        case .intermediate(let p): return "intermediate:\(p.rawValue)"
        case .finalSRGB: return "finalSRGB"
        }
    }

    /// The unambiguous storage format implied by this profile (final corrective #5): the executor
    /// allocates `rgba16FloatLinear` surfaces as 16-bit float linear and `bgra8SRGB` surfaces as 8-bit
    /// sRGB. A surface is **never** mislabelled as BGRA8 when it is actually 16-bit float.
    public var storageFormat: RenderSurfaceStorageFormat {
        switch self {
        case .intermediate(.rgba16FloatLinear): return .rgba16FloatLinear
        case .intermediate(.bgra8SRGB): return .bgra8SRGB
        case .finalSRGB: return .bgra8SRGB
        }
    }
}

/// The unambiguous physical storage format of a render surface (final corrective #5): a 16-bit-float
/// linear surface and an 8-bit sRGB surface are distinct and must never be conflated. This is separate
/// from a pixel-input's input `PixelByteFormat`.
public enum RenderSurfaceStorageFormat: String, Hashable, Sendable, CaseIterable {
    case bgra8SRGB
    case rgba16FloatLinear
}

public struct RenderResourceDescriptor: Hashable, Sendable {
    public let resourceID: String
    public let kind: RenderResourceKind
    public let width: Int64
    public let height: Int64
    /// The pixel byte format of this resource. Present **only** for a `pixelInput` resource, where it
    /// describes the owned input bytes. `nil` for an `offscreen` surface, which has no input byte
    /// format — an offscreen is described unambiguously by `surfaceProfile` + `surfaceStorage` alone,
    /// so a 16-bit-float linear surface is never mislabelled with a BGRA8 byte format (final
    /// micro-correction #1).
    public let pixelFormat: PixelByteFormat?
    /// The colour contract the resource is interpreted under.
    public let colorContract: RenderColorContract
    /// For a `pixelInput`, the owned pixels (bytes + descriptor + hash). `nil` for an `offscreen`
    /// surface, which the executor allocates.
    public let pixels: ResolvedPixelInput?
    /// For an `offscreen` surface, its render profile (intermediate vs final sRGB). `nil` for a
    /// `pixelInput` resource (whose `format` describes its input pixels, corrective #6).
    public let surfaceProfile: RenderSurfaceProfile?
    /// For an `offscreen` surface, its unambiguous physical storage format (final corrective #5).
    /// `nil` for a `pixelInput` resource.
    public let surfaceStorage: RenderSurfaceStorageFormat?

    /// A pixel-input resource carrying its owned bytes (corrective #1). Its `pixelFormat` is the
    /// **input** byte format, kept separate from any render-surface profile (corrective #6).
    public init(pixelInputID: String, pixels: ResolvedPixelInput, colorContract: RenderColorContract) {
        self.resourceID = pixelInputID
        self.kind = .pixelInput
        self.width = Int64(pixels.dimensions.width)
        self.height = Int64(pixels.dimensions.height)
        self.pixelFormat = pixels.dimensions.format
        self.colorContract = colorContract
        self.pixels = pixels
        self.surfaceProfile = nil
        self.surfaceStorage = nil
    }

    /// An offscreen-surface resource (no bytes; the executor allocates it). It carries **only** an
    /// explicit render profile and the unambiguous physical storage format the profile implies
    /// (final micro-correction #1). It has **no** `pixelFormat` — a 16-bit-float linear surface is
    /// never described with a BGRA8 byte format.
    public init(offscreenID: String, width: Int64, height: Int64, profile: RenderSurfaceProfile, colorContract: RenderColorContract) {
        self.resourceID = offscreenID
        self.kind = .offscreen
        self.width = width
        self.height = height
        self.pixelFormat = nil
        self.colorContract = colorContract
        self.pixels = nil
        self.surfaceProfile = profile
        self.surfaceStorage = profile.storageFormat
    }

    /// The content-addressed hash of the bound pixels (`""` for an offscreen surface).
    public var pixelContentHash: String { pixels?.contentHash ?? "" }

    func canonicalValue() throws -> RenderCanonicalEncoding.Value {
        // Identity by hash + dims + (input pixel format | surface profile/storage) + contract, not raw
        // bytes, so the graph hash is compact. An offscreen encodes `pixelFormat: "n/a"` — it carries no
        // byte format — while a pixel input encodes its actual input byte format (final micro-correction #1).
        try RenderCanonicalEncoding.object([
            ("alphaStorage", .string(colorContract.alphaStorage.rawValue)),
            ("colorSpace", .string(colorContract.colorSpace.rawValue)),
            ("dynamicRange", .string(colorContract.dynamicRange.rawValue)),
            ("height", .int(height)),
            ("kind", .string(kind.rawValue)),
            ("orientation", .string(pixels?.dimensions.orientation.rawValue ?? "n/a")),
            ("outputFormat", .string(colorContract.outputFormat.rawValue)),
            ("pixelContentHash", .string(pixelContentHash)),
            ("pixelFormat", .string(pixelFormat?.rawValue ?? "n/a")),
            ("resourceID", .string(resourceID)),
            ("surfaceProfile", .string(surfaceProfile?.canonical ?? "n/a")),
            ("surfaceStorage", .string(surfaceStorage?.rawValue ?? "n/a")),
            ("width", .int(width))
        ])
    }
}

// The scene role in a command payload reuses `ResolvedSceneRole` (already defined in
// ResolvedFrameInput), so the render model has a single role enum and no parallel duplicate.

/// A typed mask mode (§7.4 — the validator rejects anything outside this set). Raw values are the
/// producer `MaskMode` strings.
public enum RenderMaskMode: String, Hashable, Sendable, CaseIterable {
    case add = "a"
    case subtract = "s"
    case intersect = "i"
}

/// A typed matte mode (§7.4). Raw values are the producer `MatteMode` integers.
public enum RenderMatteMode: Int, Hashable, Sendable, CaseIterable {
    case alpha = 1
    case alphaInverted = 2
    case luma = 3
    case lumaInverted = 4
}

/// A slide direction (§7.3), the typed `direction` transition parameter.
public enum RenderSlideDirection: String, Hashable, Sendable, CaseIterable {
    case left, right, up, down
}

/// Well-known render-target surface identifiers (corrective #2). The flow is fully explicit — every
/// pass names where it writes and reads; there is no implicit "current surface" state.
public enum RenderSurface {
    /// The linear-light composition surface the body and overlays write to.
    public static let linearCanvas = "surface\u{1F}linearCanvas"
    /// The sRGB surface the final conversion writes to and the final output reads from.
    public static let sRGBSurface = "surface\u{1F}sRGB"
}

/// A path's bezier geometry sampled at an exact frame (corrective #5): the graph carries the actual
/// vertices/tangents, not only a path id, so the executor needs no further sampling. Coordinates are
/// `CanvasScalar` raw units.
///
/// Step-11 (Rev-4 §1.1): `SampledBezier` is **control-path** data — authored anchors with in/out
/// tangents. Its `vertices` are NOT the producer-flattened triangulation vertices, and producer
/// triangle indices must never be attached to it. Fills and masks use a separately sampled
/// ``SampledPathMesh``; strokes use the sampled producer polyline.
public struct SampledBezier: Hashable, Sendable {
    public let vertices: [Int64]      // flat (x,y) pairs
    public let inTangents: [Int64]
    public let outTangents: [Int64]
    public let closed: Bool
    public let pathID: Int?           // optional scene-resource id, for identity/ownership validation

    public init(vertices: [Int64], inTangents: [Int64], outTangents: [Int64], closed: Bool, pathID: Int?) {
        self.vertices = vertices
        self.inTangents = inTangents
        self.outTangents = outTangents
        self.closed = closed
        self.pathID = pathID
    }

    func canonicalValue() -> RenderCanonicalEncoding.Value {
        .object([
            ("closed", .bool(closed)),
            ("inTangents", .array(inTangents.map { .int($0) })),
            ("outTangents", .array(outTangents.map { .int($0) })),
            ("pathID", pathID.map { .int(Int64($0)) } ?? .string("none")),
            ("vertices", .array(vertices.map { .int($0) }))
        ])
    }
}

// MARK: - Step-11 (Rev-4 §2) execution-ready geometry / colour value types

/// Rev-4 §2.1 — a producer-flattened path mesh sampled at an exact frame: the **flattened**
/// `keyframePositions` plus the authoritative producer triangle `indices`. Fills and masks consume
/// this; the producer indices address `positions`, never ``SampledBezier`` control vertices.
/// `positions` are path-local `[x0, y0, x1, y1, ...]` in `CanvasScalar`.
public struct SampledPathMesh: Hashable, Sendable {
    public let pathID: Int
    public let positions: [CanvasScalar]
    public let indices: [Int]
    public let closed: Bool

    public init(pathID: Int, positions: [CanvasScalar], indices: [Int], closed: Bool) throws {
        guard pathID >= 0 else {
            throw RenderModelError.valueOutOfRange(
                field: "SampledPathMesh.pathID", value: Int64(pathID), lowerBound: 0, upperBound: Int64.max)
        }
        guard positions.count >= 6 else {
            throw RenderModelError.unsupportedValue(
                field: "SampledPathMesh.positions", value: "count \(positions.count) < 6")
        }
        guard positions.count % 2 == 0 else {
            throw RenderModelError.unsupportedValue(
                field: "SampledPathMesh.positions", value: "count \(positions.count) is odd")
        }
        try SampledMeshValidation.validateIndices(
            indices, vertexCount: positions.count / 2, field: "SampledPathMesh.indices")
        self.pathID = pathID
        self.positions = positions
        self.indices = indices
        self.closed = closed
    }

    func canonicalValue() -> RenderCanonicalEncoding.Value {
        .object([
            ("closed", .bool(closed)),
            ("indices", .array(indices.map { .int(Int64($0)) })),
            ("pathID", .int(Int64(pathID))),
            ("positions", .array(positions.map { .int($0.rawValue) }))
        ])
    }
}

/// Rev-4 §2.2 — generated stroke triangles, execution-ready. Same even-position / triangle-index
/// validation as ``SampledPathMesh``. Metal never constructs stroke geometry.
public struct SampledTriangleMesh: Hashable, Sendable {
    public let positions: [CanvasScalar]
    public let indices: [Int]

    public init(positions: [CanvasScalar], indices: [Int]) throws {
        guard positions.count >= 6 else {
            throw RenderModelError.unsupportedValue(
                field: "SampledTriangleMesh.positions", value: "count \(positions.count) < 6")
        }
        guard positions.count % 2 == 0 else {
            throw RenderModelError.unsupportedValue(
                field: "SampledTriangleMesh.positions", value: "count \(positions.count) is odd")
        }
        try SampledMeshValidation.validateIndices(
            indices, vertexCount: positions.count / 2, field: "SampledTriangleMesh.indices")
        self.positions = positions
        self.indices = indices
    }

    func canonicalValue() -> RenderCanonicalEncoding.Value {
        .object([
            ("indices", .array(indices.map { .int(Int64($0)) })),
            ("positions", .array(positions.map { .int($0.rawValue) }))
        ])
    }
}

/// Shared triangle-index validation for the Step-11 mesh value types.
public enum SampledMeshValidation {
    public static func validateIndices(_ indices: [Int], vertexCount: Int, field: String) throws {
        guard !indices.isEmpty else {
            throw RenderModelError.unsupportedValue(field: field, value: "empty")
        }
        guard indices.count % 3 == 0 else {
            throw RenderModelError.unsupportedValue(
                field: field, value: "count \(indices.count) not a multiple of 3")
        }
        for (i, index) in indices.enumerated() {
            guard index >= 0, index < vertexCount else {
                throw RenderModelError.valueOutOfRange(
                    field: "\(field)[\(i)]", value: Int64(index),
                    lowerBound: 0, upperBound: Int64(vertexCount - 1))
            }
        }
    }
}

/// Rev-4 §2.3 — typed stroke line cap. Raw values are the producer 1-based DTO values.
public enum RenderStrokeLineCap: Int, Hashable, Sendable, CaseIterable {
    case butt = 1
    case round = 2
    case square = 3
}

/// Rev-4 §2.3 — typed stroke line join. Raw values are the producer 1-based DTO values.
public enum RenderStrokeLineJoin: Int, Hashable, Sendable, CaseIterable {
    case miter = 1
    case round = 2
    case bevel = 3
}

/// Rev-4 §2.4 — authored straight-alpha sRGB RGBA (not premultiplied linear). The Metal boundary
/// decodes sRGB→linear, folds effective alpha, premultiplies, and composites once.
public struct SampledSRGBAColor: Hashable, Sendable {
    public let red: NormalizedColorComponent
    public let green: NormalizedColorComponent
    public let blue: NormalizedColorComponent
    public let alpha: NormalizedColorComponent

    /// Construction from exactly four explicit straight-sRGB components `[r, g, b, a]`. RenderModel
    /// performs NO RGB→RGBA coercion, fallback, or implicit-alpha synthesis: any count other than four
    /// is a typed `RenderModelError.unsupportedValue`. Arity reconciliation (the producer fill is RGBA(4)
    /// and the producer stroke is RGB(3)) is the adapter's responsibility, where the stroke converter
    /// sets alpha=.one explicitly before constructing this value.
    public init(components: [NormalizedColorComponent]) throws {
        guard components.count == 4 else {
            throw RenderModelError.unsupportedValue(
                field: "SampledSRGBAColor.components", value: "count \(components.count) != 4")
        }
        self.red = components[0]
        self.green = components[1]
        self.blue = components[2]
        self.alpha = components[3]
    }

    func canonicalValue() -> RenderCanonicalEncoding.Value {
        .object([
            ("a", .int(alpha.rawValue)), ("b", .int(blue.rawValue)),
            ("g", .int(green.rawValue)), ("r", .int(red.rawValue))
        ])
    }
}

/// Rev-4 §2.5 — a shape stroke whose triangle mesh is already execution-ready (built by
/// `StrokeMeshBuilder` in the graph). Metal must not construct stroke geometry.
public struct SampledStroke: Hashable, Sendable {
    public let sourcePathID: Int
    public let mesh: SampledTriangleMesh
    public let color: SampledSRGBAColor
    public let opacity: OpacityScalar
    public let width: CanvasScalar
    public let lineCap: RenderStrokeLineCap
    public let lineJoin: RenderStrokeLineJoin
    public let miterLimit: MiterScalar

    public init(sourcePathID: Int, mesh: SampledTriangleMesh, color: SampledSRGBAColor,
                opacity: OpacityScalar, width: CanvasScalar,
                lineCap: RenderStrokeLineCap, lineJoin: RenderStrokeLineJoin, miterLimit: MiterScalar) {
        self.sourcePathID = sourcePathID; self.mesh = mesh; self.color = color
        self.opacity = opacity; self.width = width
        self.lineCap = lineCap; self.lineJoin = lineJoin; self.miterLimit = miterLimit
    }

    func canonicalValue() -> RenderCanonicalEncoding.Value {
        .object([
            ("color", color.canonicalValue()),
            ("lineCap", .int(Int64(lineCap.rawValue))),
            ("lineJoin", .int(Int64(lineJoin.rawValue))),
            ("mesh", mesh.canonicalValue()),
            ("miterLimit", .int(miterLimit.rawValue)),
            ("opacity", .int(opacity.rawValue)),
            ("sourcePathID", .int(Int64(sourcePathID))),
            ("width", .int(width.rawValue))
        ])
    }
}

/// Rev-4 §2.6 — a shape group sampled at an exact frame: execution-ready fill mesh + colour, stroke,
/// and the group opacity. At least one of fill or stroke must exist; `fillMesh`/`fillColor` are both
/// present or both absent. Fill colour/opacity and group opacity each apply once (§2.6).
public struct SampledShape: Hashable, Sendable {
    public let fillMesh: SampledPathMesh?
    public let fillColor: SampledSRGBAColor?
    public let fillOpacity: OpacityScalar
    public let stroke: SampledStroke?
    public let groupOpacity: OpacityScalar

    public init(fillMesh: SampledPathMesh?, fillColor: SampledSRGBAColor?, fillOpacity: OpacityScalar,
                stroke: SampledStroke?, groupOpacity: OpacityScalar) throws {
        let hasFill = fillMesh != nil
        guard hasFill == (fillColor != nil) else {
            throw RenderModelError.unsupportedValue(
                field: "SampledShape.fill", value: "fillMesh and fillColor must both be present or both absent")
        }
        guard hasFill || stroke != nil else {
            throw RenderModelError.unsupportedValue(
                field: "SampledShape", value: "neither fill nor stroke present")
        }
        self.fillMesh = fillMesh; self.fillColor = fillColor
        self.fillOpacity = fillOpacity; self.stroke = stroke; self.groupOpacity = groupOpacity
    }

    func canonicalValue() -> RenderCanonicalEncoding.Value {
        .object([
            ("fillColor", fillColor?.canonicalValue() ?? .string("none")),
            ("fillMesh", fillMesh?.canonicalValue() ?? .string("none")),
            ("fillOpacity", .int(fillOpacity.rawValue)),
            ("groupOpacity", .int(groupOpacity.rawValue)),
            ("stroke", stroke?.canonicalValue() ?? .string("none"))
        ])
    }
}

/// Rev-4 §2.7 — one authored mask operation, in authored `RenderLayer.masks` order. The operation
/// array order is semantically significant in canonical bytes and graph hashes.
public struct SampledMaskOperation: Hashable, Sendable {
    public let mode: RenderMaskMode
    public let inverted: Bool
    public let opacity: OpacityScalar
    public let mesh: SampledPathMesh
    public let pathToTarget: FixedAffineTransform2D

    public init(mode: RenderMaskMode, inverted: Bool, opacity: OpacityScalar,
                mesh: SampledPathMesh, pathToTarget: FixedAffineTransform2D) {
        self.mode = mode; self.inverted = inverted; self.opacity = opacity
        self.mesh = mesh; self.pathToTarget = pathToTarget
    }

    func canonicalValue() throws -> RenderCanonicalEncoding.Value {
        .object([
            ("inverted", .bool(inverted)),
            ("mesh", mesh.canonicalValue()),
            ("mode", .string(mode.rawValue)),
            ("opacity", .int(opacity.rawValue)),
            ("pathToTarget", try pathToTarget.canonicalValue())
        ])
    }
}

// MARK: - Per-category command payload

/// The field-level, immutable payload of one graph command, one case per category. The case **is** the
/// category (see `RenderCommand.category`), so the two can never disagree.
public enum RenderCommandPayload: Hashable, Sendable {
    /// Clear `targetSurfaceID` to the cleared background (premultiplied transparent black).
    case clearBackground(color: PremultipliedColor, targetSurfaceID: String)
    /// Declare an immutable pixel-input resource (carries its owned bytes, corrective #1).
    case declareResource(RenderResourceDescriptor)
    /// Allocate/declare an offscreen surface used as a scene/transition/matte intermediate.
    case offscreenSurface(RenderResourceDescriptor)
    /// Begin an ordered scene subgraph that writes to `targetSurfaceID`.
    case beginScene(sceneID: String, role: ResolvedSceneRole, targetSurfaceID: String)
    case endScene(sceneID: String, role: ResolvedSceneRole, targetSurfaceID: String)
    /// Draw an image layer onto `targetSurfaceID`: source resource, composed transform, opacity.
    case drawImage(resourceID: String, transform: FixedAffineTransform2D, opacity: OpacityScalar, targetSurfaceID: String)
    /// Draw a still-frame video layer onto `targetSurfaceID`.
    case drawVideoFrame(resourceID: String, transform: FixedAffineTransform2D, opacity: OpacityScalar, targetSurfaceID: String)
    /// Draw a sampled shape (path/fill/stroke) onto `targetSurfaceID` (corrective #1).
    case drawShape(shape: SampledShape, transform: FixedAffineTransform2D, opacity: OpacityScalar, targetSurfaceID: String)
    /// Begin a clip-path scope to a destination-space rect.
    case beginClip(rect: FixedRect)
    case endClip
    /// Begin one explicit mask group for a masked layer contribution (Rev-4 §2.8): the authored-order
    /// operation list, the isolated content surface the inner content writes to, and the destination
    /// the masked result composites into. `contentSurfaceID != targetSurfaceID`.
    case beginMask(operations: [SampledMaskOperation], contentSurfaceID: String, targetSurfaceID: String)
    /// End the mask group: read `contentSurfaceID`, apply the aggregate mask once, source-over into
    /// `targetSurfaceID`. IDs match the paired `beginMask`.
    case endMask(contentSurfaceID: String, targetSurfaceID: String)
    /// Link a fully-rendered matte source + consumer to a destination (Rev-4 §2.9). Source, consumer,
    /// and target IDs are pairwise distinct; source and consumer are rendered before the link.
    case matteLink(mode: RenderMatteMode, sourceLayerID: Int, consumerLayerID: Int,
                   sourceSurfaceID: String, consumerSurfaceID: String, targetSurfaceID: String)
    /// A fade transition: composite the incoming over the outgoing surface at the eased progress, into
    /// `targetSurfaceID`.
    case fadeTransition(easedProgress: UnitInterval, outgoingSurfaceID: String, incomingSurfaceID: String, targetSurfaceID: String)
    /// A slide transition: translate the incoming surface by `(offsetX, offsetY)` in the typed
    /// direction at the eased progress, compositing into `targetSurfaceID`; the outgoing surface is read.
    case slideTransition(direction: RenderSlideDirection, easedProgress: UnitInterval,
                         offsetX: Int64, offsetY: Int64, outgoingSurfaceID: String, incomingSurfaceID: String, targetSurfaceID: String)
    /// Composite a pre-resolved global overlay above the body, into `targetSurfaceID`.
    case overlay(resourceID: String, transform: FixedAffineTransform2D, opacity: OpacityScalar, compositionOrder: Int, targetSurfaceID: String)
    /// Convert the linear intermediate `sourceSurfaceID` to sRGB in `targetSurfaceID`.
    case finalLinearToSRGB(sourceSurfaceID: String, targetSurfaceID: String)
    /// Emit the final BGRA8 output read from `sourceSurfaceID`.
    case finalOutput(sourceSurfaceID: String)

    /// The category this payload belongs to (single source of truth).
    public var category: RenderCommandCategory {
        switch self {
        case .clearBackground: return .clearBackground
        case .declareResource: return .declareResource
        case .offscreenSurface: return .offscreenSurface
        case .beginScene: return .beginScene
        case .endScene: return .endScene
        case .drawImage: return .drawImage
        case .drawVideoFrame: return .drawVideoFrame
        case .drawShape: return .drawShape
        case .beginClip: return .beginClip
        case .endClip: return .endClip
        case .beginMask: return .beginMask
        case .endMask: return .endMask
        case .matteLink: return .matteLink
        case .fadeTransition: return .fadeTransition
        case .slideTransition: return .slideTransition
        case .overlay: return .overlay
        case .finalLinearToSRGB: return .finalLinearToSRGB
        case .finalOutput: return .finalOutput
        }
    }

    func canonicalFields() throws -> [(String, RenderCanonicalEncoding.Value)] {
        switch self {
        case let .clearBackground(color, target):
            return [("color", colorValue(color)), ("target", .string(target))]
        case .declareResource(let d), .offscreenSurface(let d):
            return [("resource", try d.canonicalValue())]
        case let .beginScene(sceneID, role, target), let .endScene(sceneID, role, target):
            return [("role", .string(role.rawValue)), ("sceneID", .string(sceneID)), ("target", .string(target))]
        case let .drawImage(resourceID, transform, opacity, target),
             let .drawVideoFrame(resourceID, transform, opacity, target):
            return [("opacity", .int(opacity.rawValue)), ("resourceID", .string(resourceID)),
                    ("target", .string(target)), ("transform", try transform.canonicalValue())]
        case let .drawShape(shape, transform, opacity, target):
            return [("opacity", .int(opacity.rawValue)), ("shape", shape.canonicalValue()),
                    ("target", .string(target)), ("transform", try transform.canonicalValue())]
        case .beginClip(let rect):
            return [("rect", rectValue(rect))]
        case .endClip:
            return []
        case let .beginMask(operations, contentSurfaceID, targetSurfaceID):
            // Operation order is semantic (authored order) — preserved as an ordered array.
            return [("contentSurfaceID", .string(contentSurfaceID)),
                    ("operations", .array(try operations.map { try $0.canonicalValue() })),
                    ("targetSurfaceID", .string(targetSurfaceID))]
        case let .endMask(contentSurfaceID, targetSurfaceID):
            return [("contentSurfaceID", .string(contentSurfaceID)), ("targetSurfaceID", .string(targetSurfaceID))]
        case let .matteLink(mode, sourceLayerID, consumerLayerID, sourceSurfaceID, consumerSurfaceID, targetSurfaceID):
            return [("consumerLayerID", .int(Int64(consumerLayerID))),
                    ("consumerSurfaceID", .string(consumerSurfaceID)),
                    ("mode", .int(Int64(mode.rawValue))),
                    ("sourceLayerID", .int(Int64(sourceLayerID))),
                    ("sourceSurfaceID", .string(sourceSurfaceID)),
                    ("targetSurfaceID", .string(targetSurfaceID))]
        case let .fadeTransition(easedProgress, outgoing, incoming, target):
            return [("easedProgress", .int(easedProgress.rawValue)), ("incomingSurfaceID", .string(incoming)),
                    ("outgoingSurfaceID", .string(outgoing)), ("target", .string(target))]
        case let .slideTransition(direction, easedProgress, offsetX, offsetY, outgoing, incoming, target):
            return [("direction", .string(direction.rawValue)), ("easedProgress", .int(easedProgress.rawValue)),
                    ("incomingSurfaceID", .string(incoming)), ("offsetX", .int(offsetX)),
                    ("offsetY", .int(offsetY)), ("outgoingSurfaceID", .string(outgoing)), ("target", .string(target))]
        case let .overlay(resourceID, transform, opacity, compositionOrder, target):
            return [("compositionOrder", .int(Int64(compositionOrder))), ("opacity", .int(opacity.rawValue)),
                    ("resourceID", .string(resourceID)), ("target", .string(target)), ("transform", try transform.canonicalValue())]
        case let .finalLinearToSRGB(source, target):
            return [("source", .string(source)), ("target", .string(target))]
        case let .finalOutput(source):
            return [("source", .string(source))]
        }
    }

    private func colorValue(_ c: PremultipliedColor) -> RenderCanonicalEncoding.Value {
        .object([("a", .int(c.alpha.rawValue)), ("b", .int(c.blue.rawValue)),
                 ("g", .int(c.green.rawValue)), ("r", .int(c.red.rawValue))])
    }
    private func rectValue(_ r: FixedRect) -> RenderCanonicalEncoding.Value {
        .object([("height", .int(r.height.rawValue)), ("width", .int(r.width.rawValue)),
                 ("x", .int(r.x.rawValue)), ("y", .int(r.y.rawValue))])
    }
}

/// A single immutable graph command: an ordinal (its position in the ordered list, §7.1) plus its
/// field-level payload. Two commands are equal iff ordinal and payload match; the category is derived
/// from the payload, so a command list is order-significant and deterministically encodable.
public struct RenderCommand: Hashable, Sendable {
    public let ordinal: Int
    public let payload: RenderCommandPayload

    public var category: RenderCommandCategory { payload.category }

    public init(ordinal: Int, payload: RenderCommandPayload) throws {
        guard ordinal >= 0 else {
            throw RenderModelError.valueOutOfRange(
                field: "RenderCommand.ordinal", value: Int64(ordinal), lowerBound: 0, upperBound: Int64.max)
        }
        self.ordinal = ordinal
        self.payload = payload
    }

    public func canonicalValue() throws -> RenderCanonicalEncoding.Value {
        var fields: [(String, RenderCanonicalEncoding.Value)] = [
            ("category", .string(category.rawValue)),
            ("ordinal", .int(Int64(ordinal)))
        ]
        fields.append(contentsOf: try payload.canonicalFields())
        return try RenderCanonicalEncoding.object(fields)
    }
}
