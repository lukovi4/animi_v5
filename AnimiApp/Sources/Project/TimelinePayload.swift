import Foundation

// MARK: - Timeline Payload (v4 Schema)

/// Payload data for timeline items.
/// Uses discriminator-based Codable: {"type": "scene", "payload": {...}}
public enum TimelinePayload: Equatable, Sendable {
    case scene(ScenePayload)
    case audio(AudioPayload)
    case sticker(StickerPayload)
    case text(TextPayload)
}

// MARK: - Codable (Discriminator Pattern)

extension TimelinePayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case payload
    }

    private enum PayloadType: String, Codable {
        case scene
        case audio
        case sticker
        case text
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(PayloadType.self, forKey: .type)

        switch type {
        case .scene:
            let payload = try container.decode(ScenePayload.self, forKey: .payload)
            self = .scene(payload)
        case .audio:
            let payload = try container.decode(AudioPayload.self, forKey: .payload)
            self = .audio(payload)
        case .sticker:
            let payload = try container.decode(StickerPayload.self, forKey: .payload)
            self = .sticker(payload)
        case .text:
            let payload = try container.decode(TextPayload.self, forKey: .payload)
            self = .text(payload)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .scene(let payload):
            try container.encode(PayloadType.scene, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .audio(let payload):
            try container.encode(PayloadType.audio, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .sticker(let payload):
            try container.encode(PayloadType.sticker, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .text(let payload):
            try container.encode(PayloadType.text, forKey: .type)
            try container.encode(payload, forKey: .payload)
        }
    }
}

// MARK: - Scene Payload

/// Payload for scene items.
/// Contains the scene type ID that links to the SceneLibrary.
public struct ScenePayload: Codable, Equatable, Sendable {
    /// Scene type identifier (refers to SceneLibrary).
    public var sceneTypeId: String

    public init(sceneTypeId: String) {
        self.sceneTypeId = sceneTypeId
    }
}

// MARK: - Audio Role (PR3)

/// Role of an audio item in the project timeline.
public enum AudioRole: String, Codable, Sendable {
    case music
    case voiceover
    case sfx
}

// MARK: - Audio Payload

/// Payload for audio clip items.
/// V1 (PR8): project-level music track with trim + volume.
/// PR3: Added `role` field for multi-role audio support.
public struct AudioPayload: Equatable, Sendable {
    /// Audio asset reference.
    public var assetRef: AudioAssetRef?

    /// Full source file duration in microseconds.
    public var sourceDurationUs: TimeUs

    /// In-source trim start (0 = beginning).
    public var trimStartUs: TimeUs

    /// In-source trim end (= sourceDurationUs for full length).
    public var trimEndUs: TimeUs

    /// Volume level 0.0 - 1.0 (default: 1.0).
    public var volume: Float

    /// Audio role (music, voiceover, sfx). Default: .music for backward compatibility.
    public var role: AudioRole

    public init(
        assetRef: AudioAssetRef? = nil,
        sourceDurationUs: TimeUs = 0,
        trimStartUs: TimeUs = 0,
        trimEndUs: TimeUs = 0,
        volume: Float = 1.0,
        role: AudioRole = .music
    ) {
        self.assetRef = assetRef
        self.sourceDurationUs = sourceDurationUs
        self.trimStartUs = trimStartUs
        self.trimEndUs = trimEndUs
        self.volume = volume
        self.role = role
    }
}

// MARK: - AudioPayload Codable (backward-compatible)

extension AudioPayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case assetRef, sourceDurationUs, trimStartUs, trimEndUs, volume, role
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        assetRef = try container.decodeIfPresent(AudioAssetRef.self, forKey: .assetRef)
        sourceDurationUs = try container.decode(TimeUs.self, forKey: .sourceDurationUs)
        trimStartUs = try container.decode(TimeUs.self, forKey: .trimStartUs)
        trimEndUs = try container.decode(TimeUs.self, forKey: .trimEndUs)
        volume = try container.decode(Float.self, forKey: .volume)
        role = try container.decodeIfPresent(AudioRole.self, forKey: .role) ?? .music
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(assetRef, forKey: .assetRef)
        try container.encode(sourceDurationUs, forKey: .sourceDurationUs)
        try container.encode(trimStartUs, forKey: .trimStartUs)
        try container.encode(trimEndUs, forKey: .trimEndUs)
        try container.encode(volume, forKey: .volume)
        try container.encode(role, forKey: .role)
    }
}

/// Reference to audio asset.
public enum AudioAssetRef: Equatable, Sendable {
    /// Bundled sound effect by ID.
    case bundled(id: String)

    /// Imported audio file identified by logical asset ID, with content-side
    /// recovery path so stale/missing registry entries can be self-healed.
    case imported(assetId: ProjectAssetID, storagePath: String)

    /// Backward-compatible convenience for older call sites/tests that only
    /// care about identity, not recovery data.
    public static func imported(assetId: ProjectAssetID) -> AudioAssetRef {
        .imported(assetId: assetId, storagePath: "")
    }
}

// MARK: - AudioAssetRef Codable (backward-compatible)

extension AudioAssetRef: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, id, assetId, storagePath
    }

    private enum LegacyCaseKeys: String, CodingKey {
        case bundled, imported
    }

    private enum RefType: String, Codable {
        case bundled, imported
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let type = try container.decodeIfPresent(RefType.self, forKey: .type) {
            switch type {
            case .bundled:
                let id = try container.decode(String.self, forKey: .id)
                self = .bundled(id: id)
            case .imported:
                let assetId = try container.decode(ProjectAssetID.self, forKey: .assetId)
                let storagePath = try container.decodeIfPresent(String.self, forKey: .storagePath) ?? ""
                self = .imported(assetId: assetId, storagePath: storagePath)
            }
            return
        }

        let legacyContainer = try decoder.container(keyedBy: LegacyCaseKeys.self)
        if legacyContainer.contains(.bundled) {
            let nested = try legacyContainer.nestedContainer(keyedBy: CodingKeys.self, forKey: .bundled)
            let id = try nested.decode(String.self, forKey: .id)
            self = .bundled(id: id)
        } else if legacyContainer.contains(.imported) {
            let nested = try legacyContainer.nestedContainer(keyedBy: CodingKeys.self, forKey: .imported)
            let assetId = try nested.decode(ProjectAssetID.self, forKey: .assetId)
            self = .imported(assetId: assetId, storagePath: "")
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown AudioAssetRef format")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bundled(let id):
            try container.encode(RefType.bundled, forKey: .type)
            try container.encode(id, forKey: .id)
        case .imported(let assetId, let storagePath):
            try container.encode(RefType.imported, forKey: .type)
            try container.encode(assetId, forKey: .assetId)
            try container.encode(storagePath, forKey: .storagePath)
        }
    }
}

// MARK: - Sticker Payload

/// Payload for sticker overlay items.
/// PR10: Shipped with positioning (centerX/centerY) and required stickerId.
public struct StickerPayload: Codable, Equatable, Sendable {
    /// Bundled sticker ID (must resolve to a catalog entry).
    public var stickerId: String

    /// Canvas-normalized X position (0..1, default 0.5 = center).
    public var centerX: CGFloat

    /// Canvas-normalized Y position (0..1, default 0.5 = center).
    public var centerY: CGFloat

    public init(stickerId: String, centerX: CGFloat = 0.5, centerY: CGFloat = 0.5) {
        self.stickerId = stickerId
        self.centerX = centerX
        self.centerY = centerY
    }
}

// MARK: - Text Box Geometry

/// Geometry + content for a text overlay box.
///
/// One persisted source of truth for the text-box placement and the text
/// content itself. Derived height is NOT stored — it is computed by the shared
/// text-box layout from `boxWidth` + style. `boxWidth` is canvas-normalized so
/// the box reflows consistently across canvas sizes, preview, and export.
public struct TextBoxGeometry: Codable, Equatable, Sendable {
    /// Text content.
    public var text: String

    /// Canvas-normalized X position of the box center (0..1, default 0.5).
    public var centerX: CGFloat

    /// Canvas-normalized Y position of the box center (0..1, default 0.5).
    public var centerY: CGFloat

    /// Canvas-normalized box width (0..1 of canvas width) used for wrapping.
    /// Default `Self.defaultBoxWidth`.
    public var boxWidth: CGFloat

    /// Rotation about the box center, in radians (0 = upright).
    public var rotation: CGFloat

    /// Default canvas-normalized box width for newly created text boxes.
    public static let defaultBoxWidth: CGFloat = 0.6

    public init(
        text: String = "",
        centerX: CGFloat = 0.5,
        centerY: CGFloat = 0.5,
        boxWidth: CGFloat = TextBoxGeometry.defaultBoxWidth,
        rotation: CGFloat = 0
    ) {
        self.text = text
        self.centerX = centerX
        self.centerY = centerY
        self.boxWidth = boxWidth
        self.rotation = rotation
    }
}

// MARK: - Text Style

/// Visual style for a text overlay. Extensible: new typography/layout fields
/// (line height, letter spacing, alignment, padding) can be added here and they
/// flow through the shared layout to preview, hit testing, bounds, and export
/// without introducing a parallel styling path.
public struct TextStyle: Codable, Equatable, Sendable {
    /// Font family name (nil = system bold default).
    public var fontFamily: String?

    /// Font size in points (canvas-relative; scaled per canvas at raster time).
    public var fontSize: CGFloat

    /// Text color as hex string (e.g., "#FF0000").
    public var colorHex: String

    /// Default font size for newly created text.
    public static let defaultFontSize: CGFloat = 32

    /// Default text color for newly created text.
    public static let defaultColorHex: String = "#FFFFFF"

    public init(
        fontFamily: String? = nil,
        fontSize: CGFloat = TextStyle.defaultFontSize,
        colorHex: String = TextStyle.defaultColorHex
    ) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.colorHex = colorHex
    }
}

// MARK: - Text Payload

/// Payload for text overlay items.
///
/// Holds separated `geometry` (placement + content) and `style` so all
/// renderers/editors share one persisted model. The flat convenience accessors
/// and initializer below forward into the nested model — they are NOT a second
/// source of truth, just ergonomics for existing call sites.
public struct TextPayload: Codable, Equatable, Sendable {
    /// Box geometry + text content.
    public var geometry: TextBoxGeometry

    /// Text style.
    public var style: TextStyle

    public init(geometry: TextBoxGeometry = TextBoxGeometry(), style: TextStyle = TextStyle()) {
        self.geometry = geometry
        self.style = style
    }

    /// Convenience flat initializer. Forwards flat fields into the nested
    /// geometry/style model — it is NOT a second source of truth and adds no
    /// old-payload migration. `fontSize`/`colorHex` fall back to style defaults
    /// when nil so call sites that pass only a subset behave predictably.
    public init(
        text: String = "",
        fontFamily: String? = nil,
        fontSize: CGFloat? = nil,
        colorHex: String? = nil,
        centerX: CGFloat = 0.5,
        centerY: CGFloat = 0.5
    ) {
        self.geometry = TextBoxGeometry(text: text, centerX: centerX, centerY: centerY)
        self.style = TextStyle(
            fontFamily: fontFamily,
            fontSize: fontSize ?? TextStyle.defaultFontSize,
            colorHex: colorHex ?? TextStyle.defaultColorHex
        )
    }

    // MARK: Flat convenience accessors (forward to nested model)

    public var text: String {
        get { geometry.text }
        set { geometry.text = newValue }
    }

    public var fontFamily: String? {
        get { style.fontFamily }
        set { style.fontFamily = newValue }
    }

    public var fontSize: CGFloat? {
        get { style.fontSize }
        set { style.fontSize = newValue ?? TextStyle.defaultFontSize }
    }

    public var colorHex: String? {
        get { style.colorHex }
        set { style.colorHex = newValue ?? TextStyle.defaultColorHex }
    }

    public var centerX: CGFloat {
        get { geometry.centerX }
        set { geometry.centerX = newValue }
    }

    public var centerY: CGFloat {
        get { geometry.centerY }
        set { geometry.centerY = newValue }
    }

    public var boxWidth: CGFloat {
        get { geometry.boxWidth }
        set { geometry.boxWidth = newValue }
    }

    public var rotation: CGFloat {
        get { geometry.rotation }
        set { geometry.rotation = newValue }
    }
}

// MARK: - Payload Type Checking

public extension TimelinePayload {
    /// Returns the ItemKind this payload corresponds to.
    var itemKind: ItemKind {
        switch self {
        case .scene:
            return .scene
        case .audio:
            return .audioClip
        case .sticker:
            return .sticker
        case .text:
            return .text
        }
    }

    /// Checks if this payload is valid for the given item kind.
    func isValid(for kind: ItemKind) -> Bool {
        itemKind == kind
    }
}
