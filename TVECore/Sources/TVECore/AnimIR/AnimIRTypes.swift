import Foundation

// MARK: - Type Aliases

/// Stable layer identifier (from Lottie `ind` or deterministically assigned)
public typealias LayerID = Int

/// Composition identifier ("__root__" for root, asset.id for precomps)
public typealias CompID = String

// MARK: - Layer Type

/// Supported layer types in Part 1 subset
public enum LayerType: Int, Sendable, Equatable {
    case precomp = 0    // ty=0: Precomposition reference
    case image = 2      // ty=2: Image layer
    case null = 3       // ty=3: Null/transform layer
    case shapeMatte = 4 // ty=4: Shape layer (used as matte source in Part 1)

    /// Creates LayerType from Lottie type value
    public init?(lottieType: Int) {
        self.init(rawValue: lottieType)
    }
}

// MARK: - Layer Timing

/// Timing information for a layer (in frames)
public struct LayerTiming: Sendable, Equatable {
    /// In point - frame when layer becomes visible
    public let inPoint: Double

    /// Out point - frame when layer becomes invisible
    public let outPoint: Double

    /// Lottie `st` (start time offset).
    /// Used to map parent frame to child comp frame: childFrame = frame - st.
    public let startTime: Double

    public init(inPoint: Double, outPoint: Double, startTime: Double) {
        self.inPoint = inPoint
        self.outPoint = outPoint
        self.startTime = startTime
    }

    /// Creates timing from Lottie layer values with defaults
    public init(ip: Double?, op: Double?, st: Double?, fallbackOp: Double) {
        self.inPoint = ip ?? 0
        self.outPoint = op ?? fallbackOp
        self.startTime = st ?? 0
    }
}

// MARK: - Layer Content

/// Content payload for different layer types
public enum LayerContent: Sendable, Equatable {
    /// Image layer content - references an image asset
    case image(assetId: String)

    /// Precomp layer content - references a composition
    case precomp(compId: CompID)

    /// Shape layer content - contains shape data (for matte sources)
    case shapes(ShapeGroup)

    /// Null layer - no visual content, used for transforms/parenting
    case none
}

// MARK: - Group Transform (PR-11)

/// Transform for shape groups (tr inside gr)
/// Supports both static and animated position/anchor/scale/rotation/opacity
/// Applied at render time, NOT baked into path vertices
public struct GroupTransform: Sendable, Equatable {
    /// Position (default: (0, 0))
    public let position: AnimTrack<Vec2D>

    /// Anchor point (default: (0, 0))
    public let anchor: AnimTrack<Vec2D>

    /// Scale in percentage (default: (100, 100))
    public let scale: AnimTrack<Vec2D>

    /// Rotation in degrees (default: 0)
    public let rotation: AnimTrack<Double>

    /// Opacity normalized 0...1 (default: 1.0)
    public let opacity: AnimTrack<Double>

    public init(
        position: AnimTrack<Vec2D> = .static(Vec2D(x: 0, y: 0)),
        anchor: AnimTrack<Vec2D> = .static(Vec2D(x: 0, y: 0)),
        scale: AnimTrack<Vec2D> = .static(Vec2D(x: 100, y: 100)),
        rotation: AnimTrack<Double> = .static(0),
        opacity: AnimTrack<Double> = .static(1.0)
    ) {
        self.position = position
        self.anchor = anchor
        self.scale = scale
        self.rotation = rotation
        self.opacity = opacity
    }

    /// Identity transform (no transformation)
    public static let identity = GroupTransform()

    /// Computes the transformation matrix at the given frame
    /// Formula: T(position) * R(rotation) * S(scale) * T(-anchor)
    public func matrix(at frame: Double) -> Matrix2D {
        let pos = position.sample(frame: frame)
        let anc = anchor.sample(frame: frame)
        let scl = scale.sample(frame: frame)
        let rot = rotation.sample(frame: frame)

        // Normalize scale from percentage (100 = 1.0)
        let scaleX = scl.x / 100.0
        let scaleY = scl.y / 100.0

        // Build matrix: T(position) * R(rotation) * S(scale) * T(-anchor)
        return Matrix2D.translation(x: pos.x, y: pos.y)
            .concatenating(.rotationDegrees(rot))
            .concatenating(.scale(x: scaleX, y: scaleY))
            .concatenating(.translation(x: -anc.x, y: -anc.y))
    }

    /// Computes the opacity at the given frame (already normalized 0...1)
    public func opacityValue(at frame: Double) -> Double {
        opacity.sample(frame: frame)
    }

    /// Returns true if any transform property is animated
    public var isAnimated: Bool {
        position.isAnimated || anchor.isAnimated || scale.isAnimated ||
        rotation.isAnimated || opacity.isAnimated
    }

}

// MARK: - Stroke Style

/// Stroke rendering style for shape layers (PR-10)
/// Contains all parameters needed to render a stroke
public struct StrokeStyle: Sendable, Equatable {
    /// Stroke color RGB (0...1 per component)
    public let color: [Double]

    /// Stroke opacity (0...1)
    public let opacity: Double

    /// Stroke width (static or animated)
    public let width: AnimTrack<Double>

    /// Line cap: 1 = butt, 2 = round, 3 = square
    public let lineCap: Int

    /// Line join: 1 = miter, 2 = round, 3 = bevel
    public let lineJoin: Int

    /// Miter limit for miter joins
    public let miterLimit: Double

    public init(
        color: [Double],
        opacity: Double,
        width: AnimTrack<Double>,
        lineCap: Int,
        lineJoin: Int,
        miterLimit: Double
    ) {
        self.color = color
        self.opacity = opacity
        self.width = width
        self.lineCap = lineCap
        self.lineJoin = lineJoin
        self.miterLimit = miterLimit
    }
}

// MARK: - Shape Group (for matte source layers)

/// Simplified shape group for matte source layers
/// Full shape rendering is not needed in Part 1 - shapes are used only as matte sources
public struct ShapeGroup: Sendable, Equatable {
    /// Combined path from all shapes (supports static and animated paths)
    /// Path is in LOCAL coordinates - NOT transformed by group transform
    public let animPath: AnimPath?

    /// Fill color (RGBA, 0-1)
    public let fillColor: [Double]?

    /// Fill opacity (0-100)
    public let fillOpacity: Double

    /// Stroke style (PR-10) - optional, nil if no stroke
    public let stroke: StrokeStyle?

    /// Group transform stack (PR-11) - list of transforms from nested groups
    /// Each GroupTransform is sampled and multiplied at render time: M = M[0] * M[1] * ... * M[n]
    /// Empty array means identity transform (no group transform)
    public let groupTransforms: [GroupTransform]

    /// Path ID in PathRegistry (set during compilation)
    public var pathId: PathID?

    /// Convenience accessor for static path (backwards compatibility)
    public var path: BezierPath? {
        animPath?.staticPath
    }

    public init(
        animPath: AnimPath? = nil,
        fillColor: [Double]? = nil,
        fillOpacity: Double = 100,
        stroke: StrokeStyle? = nil,
        groupTransforms: [GroupTransform] = [],
        pathId: PathID? = nil
    ) {
        self.animPath = animPath
        self.fillColor = fillColor
        self.fillOpacity = fillOpacity
        self.stroke = stroke
        self.groupTransforms = groupTransforms
        self.pathId = pathId
    }

    /// Backwards-compatible initializer
    public init(path: BezierPath? = nil, fillColor: [Double]? = nil, fillOpacity: Double = 100) {
        self.animPath = path.map { .staticBezier($0) }
        self.fillColor = fillColor
        self.fillOpacity = fillOpacity
        self.stroke = nil
        self.groupTransforms = []
        self.pathId = nil
    }
}

// MARK: - Matte Mode

/// Track matte types - maps directly to Lottie tt values
public enum MatteMode: Int, Sendable, Equatable {
    case alpha = 1         // tt=1: Alpha matte
    case alphaInverted = 2 // tt=2: Alpha inverted matte
    case luma = 3          // tt=3: Luma matte
    case lumaInverted = 4  // tt=4: Luma inverted matte

    /// Creates MatteMode from Lottie tt value
    public init?(trackMatteType: Int) {
        self.init(rawValue: trackMatteType)
    }
}

// MARK: - Matte Info

/// Matte relationship information stored on consumer layer
public struct MatteInfo: Sendable, Equatable {
    /// Matte mode (alpha or alpha inverted)
    public let mode: MatteMode

    /// ID of the matte source layer
    public let sourceLayerId: LayerID

    public init(mode: MatteMode, sourceLayerId: LayerID) {
        self.mode = mode
        self.sourceLayerId = sourceLayerId
    }
}

// MARK: - Mask Mode

/// Mask boolean operation modes matching AE/Lottie mask operations.
/// Used for GPU mask accumulation: each mode defines how coverage
/// is combined with the accumulator texture.
public enum MaskMode: String, Sendable, Equatable {
    /// Additive mask: result = max(accumulator, coverage)
    case add = "a"
    /// Subtractive mask: result = accumulator * (1 - coverage)
    case subtract = "s"
    /// Intersect mask: result = min(accumulator, coverage)
    case intersect = "i"
}

// MARK: - Layer

/// IR representation of a Lottie layer
public struct Layer: Sendable, Equatable {
    /// Unique layer identifier within composition
    public let id: LayerID

    /// Layer name
    public let name: String

    /// Layer type
    public let type: LayerType

    /// Timing information (ip/op/st)
    public let timing: LayerTiming

    /// Parent layer ID for transform inheritance
    public let parent: LayerID?

    /// Transform track (position, scale, rotation, opacity, anchor)
    public let transform: TransformTrack

    /// Masks applied to this layer
    public let masks: [Mask]

    /// Matte information (if this layer uses a matte)
    public let matte: MatteInfo?

    /// Layer content (image ref, precomp ref, shapes, or none)
    public let content: LayerContent

    /// Flag indicating this layer is a matte source (td=1)
    public let isMatteSource: Bool

    public init(
        id: LayerID,
        name: String,
        type: LayerType,
        timing: LayerTiming,
        parent: LayerID?,
        transform: TransformTrack,
        masks: [Mask],
        matte: MatteInfo?,
        content: LayerContent,
        isMatteSource: Bool
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.timing = timing
        self.parent = parent
        self.transform = transform
        self.masks = masks
        self.matte = matte
        self.content = content
        self.isMatteSource = isMatteSource
    }
}

// MARK: - Composition

/// IR representation of a Lottie composition (root or precomp)
public struct Composition: Sendable, Equatable {
    /// Composition identifier
    public let id: CompID

    /// Composition size
    public let size: SizeD

    /// Layers in rendering order (as in JSON)
    public let layers: [Layer]

    public init(id: CompID, size: SizeD, layers: [Layer]) {
        self.id = id
        self.size = size
        self.layers = layers
    }
}

// MARK: - Binding Info

/// Information about the replaceable image layer binding
public struct BindingInfo: Sendable, Equatable {
    /// Binding key (layer name to match)
    public let bindingKey: String

    /// ID of the bound layer
    public let boundLayerId: LayerID

    /// ID of the bound image asset
    public let boundAssetId: String

    /// Composition ID where the bound layer resides
    public let boundCompId: CompID

    public init(bindingKey: String, boundLayerId: LayerID, boundAssetId: String, boundCompId: CompID) {
        self.bindingKey = bindingKey
        self.boundLayerId = boundLayerId
        self.boundAssetId = boundAssetId
        self.boundCompId = boundCompId
    }
}

// MARK: - Asset Size

/// Asset size in Lottie coordinates
public struct AssetSize: Sendable, Equatable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

// MARK: - Asset Index IR

/// IR-specific asset index (decoupled from Lottie types)
public struct AssetIndexIR: Sendable, Equatable {
    /// Mapping from asset ID to relative file path
    public let byId: [String: String]

    /// Mapping from asset ID to asset size (from Lottie w/h)
    public let sizeById: [String: AssetSize]

    public init(byId: [String: String] = [:], sizeById: [String: AssetSize] = [:]) {
        self.byId = byId
        self.sizeById = sizeById
    }

    /// Creates from PR3 AssetIndex (legacy, no sizes)
    public init(from assetIndex: AssetIndex) {
        self.byId = assetIndex.byId
        self.sizeById = [:]
    }
}

// MARK: - Meta

/// Animation metadata
public struct Meta: Sendable, Equatable {
    /// Animation width
    public let width: Double

    /// Animation height
    public let height: Double

    /// Frame rate (fps)
    public let fps: Double

    /// In point (first frame)
    public let inPoint: Double

    /// Out point (last frame, exclusive)
    public let outPoint: Double

    /// Source animation reference (for debug/error paths)
    public let sourceAnimRef: String

    public init(
        width: Double,
        height: Double,
        fps: Double,
        inPoint: Double,
        outPoint: Double,
        sourceAnimRef: String
    ) {
        self.width = width
        self.height = height
        self.fps = fps
        self.inPoint = inPoint
        self.outPoint = outPoint
        self.sourceAnimRef = sourceAnimRef
    }

    /// Animation size as SizeD
    public var size: SizeD {
        SizeD(width: width, height: height)
    }

    /// Total frame count
    public var frameCount: Int {
        Int(outPoint - inPoint)
    }
}
