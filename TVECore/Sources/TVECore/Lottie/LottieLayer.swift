import Foundation

/// Layer definition in Lottie animation
/// Supports layer types: 0 (precomp), 2 (image), 3 (null), 4 (shape)
public struct LottieLayer: Decodable, Equatable, Sendable {
    /// Layer type: 0=precomp, 1=solid, 2=image, 3=null, 4=shape, 5=text, etc.
    public let type: Int

    /// Layer name
    public let name: String?

    /// Layer index
    public let index: Int?

    /// Reference ID (for precomp/image layers)
    public let refId: String?

    /// Transform properties
    public let transform: LottieTransform?

    /// In point (start frame)
    public let inPoint: Double?

    /// Out point (end frame)
    public let outPoint: Double?

    /// Start time offset
    public let startTime: Double?

    /// Parent layer index
    public let parent: Int?

    /// 3D flag
    public let is3D: Int?

    /// Has mask flag
    public let hasMask: Bool?

    /// Mask properties
    public let masksProperties: [LottieMask]?

    /// Track matte type: 1=alpha, 2=alpha inverted, 3=luma, 4=luma inverted
    public let trackMatteType: Int?

    /// Track matte definition flag (1 = this layer is a matte source)
    public let isMatteSource: Int?

    /// Track matte layer index (points to matte source)
    public let matteTarget: Int?

    /// Shapes (for shape layers, ty=4)
    public let shapes: [ShapeItem]?

    /// Precomp width
    public let width: Double?

    /// Precomp height
    public let height: Double?

    /// Blend mode
    public let blendMode: Int?

    /// Auto-orient flag
    public let autoOrient: Int?

    /// Stretch factor
    public let stretch: Double?

    /// Class name
    public let className: String?

    /// Collapse transform
    public let collapseTransform: Int?

    public init(
        type: Int,
        name: String? = nil,
        index: Int? = nil,
        refId: String? = nil,
        transform: LottieTransform? = nil,
        inPoint: Double? = nil,
        outPoint: Double? = nil,
        startTime: Double? = nil,
        parent: Int? = nil,
        is3D: Int? = nil,
        hasMask: Bool? = nil,
        masksProperties: [LottieMask]? = nil,
        trackMatteType: Int? = nil,
        isMatteSource: Int? = nil,
        matteTarget: Int? = nil,
        shapes: [ShapeItem]? = nil,
        width: Double? = nil,
        height: Double? = nil,
        blendMode: Int? = nil,
        autoOrient: Int? = nil,
        stretch: Double? = nil,
        className: String? = nil,
        collapseTransform: Int? = nil
    ) {
        self.type = type
        self.name = name
        self.index = index
        self.refId = refId
        self.transform = transform
        self.inPoint = inPoint
        self.outPoint = outPoint
        self.startTime = startTime
        self.parent = parent
        self.is3D = is3D
        self.hasMask = hasMask
        self.masksProperties = masksProperties
        self.trackMatteType = trackMatteType
        self.isMatteSource = isMatteSource
        self.matteTarget = matteTarget
        self.shapes = shapes
        self.width = width
        self.height = height
        self.blendMode = blendMode
        self.autoOrient = autoOrient
        self.stretch = stretch
        self.className = className
        self.collapseTransform = collapseTransform
    }

    private enum CodingKeys: String, CodingKey {
        case type = "ty"
        case name = "nm"
        case index = "ind"
        case refId
        case transform = "ks"
        case inPoint = "ip"
        case outPoint = "op"
        case startTime = "st"
        case parent
        case is3D = "ddd"
        case hasMask
        case masksProperties
        case trackMatteType = "tt"
        case isMatteSource = "td"
        case matteTarget = "tp"
        case shapes
        case width = "w"
        case height = "h"
        case blendMode = "bm"
        case autoOrient = "ao"
        case stretch = "sr"
        case className = "cl"
        case collapseTransform = "ct"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        type = try container.decodeIfPresent(Int.self, forKey: .type) ?? 0
        name = try container.decodeIfPresent(String.self, forKey: .name)
        index = try container.decodeIfPresent(Int.self, forKey: .index)
        refId = try container.decodeIfPresent(String.self, forKey: .refId)
        transform = try container.decodeIfPresent(LottieTransform.self, forKey: .transform)
        inPoint = try container.decodeIfPresent(Double.self, forKey: .inPoint)
        outPoint = try container.decodeIfPresent(Double.self, forKey: .outPoint)
        startTime = try container.decodeIfPresent(Double.self, forKey: .startTime)
        parent = try container.decodeIfPresent(Int.self, forKey: .parent)
        is3D = try container.decodeIfPresent(Int.self, forKey: .is3D)
        hasMask = try container.decodeIfPresent(Bool.self, forKey: .hasMask)
        masksProperties = try container.decodeIfPresent([LottieMask].self, forKey: .masksProperties)
        trackMatteType = try container.decodeIfPresent(Int.self, forKey: .trackMatteType)
        isMatteSource = try container.decodeIfPresent(Int.self, forKey: .isMatteSource)
        matteTarget = try container.decodeIfPresent(Int.self, forKey: .matteTarget)
        shapes = try container.decodeIfPresent([ShapeItem].self, forKey: .shapes)
        width = try container.decodeIfPresent(Double.self, forKey: .width)
        height = try container.decodeIfPresent(Double.self, forKey: .height)
        blendMode = try container.decodeIfPresent(Int.self, forKey: .blendMode)
        autoOrient = try container.decodeIfPresent(Int.self, forKey: .autoOrient)
        stretch = try container.decodeIfPresent(Double.self, forKey: .stretch)
        className = try container.decodeIfPresent(String.self, forKey: .className)
        collapseTransform = try container.decodeIfPresent(Int.self, forKey: .collapseTransform)
    }
}
