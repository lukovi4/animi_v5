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

    /// Start time offset
    public let startTime: Double

    public init(inPoint: Double, outPoint: Double, startTime: Double) {
        self.inPoint = inPoint
        self.outPoint = outPoint
        self.startTime = startTime
    }

    /// Creates timing from Lottie layer values with defaults
    public init(ip: Double?, op: Double?, st: Double?, fallbackOp: Double) { // swiftlint:disable:this identifier_name
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

// MARK: - Shape Group (for matte source layers)

/// Simplified shape group for matte source layers
/// Full shape rendering is not needed in Part 1 - shapes are used only as matte sources
public struct ShapeGroup: Sendable, Equatable {
    /// Combined path from all shapes in the group
    public let path: BezierPath?

    /// Fill color (RGBA, 0-1)
    public let fillColor: [Double]?

    /// Fill opacity (0-100)
    public let fillOpacity: Double

    public init(path: BezierPath? = nil, fillColor: [Double]? = nil, fillOpacity: Double = 100) {
        self.path = path
        self.fillColor = fillColor
        self.fillOpacity = fillOpacity
    }
}

// MARK: - Matte Mode

/// Track matte types supported in Part 1
public enum MatteMode: Int, Sendable, Equatable {
    case alpha = 1         // tt=1: Alpha matte
    case alphaInverted = 2 // tt=2: Alpha inverted matte

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

/// Mask modes supported in Part 1 (only add)
public enum MaskMode: String, Sendable, Equatable {
    case add = "a"

    /// Creates MaskMode from Lottie mode string
    public init?(lottieMode: String?) {
        guard let mode = lottieMode else { return nil }
        self.init(rawValue: mode)
    }
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

// MARK: - Asset Index IR

/// IR-specific asset index (decoupled from Lottie types)
public struct AssetIndexIR: Sendable, Equatable {
    /// Mapping from asset ID to relative file path
    public let byId: [String: String]

    public init(byId: [String: String] = [:]) {
        self.byId = byId
    }

    /// Creates from PR3 AssetIndex
    public init(from assetIndex: AssetIndex) {
        self.byId = assetIndex.byId
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
