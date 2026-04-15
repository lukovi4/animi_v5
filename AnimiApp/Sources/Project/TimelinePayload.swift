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

// MARK: - Audio Payload

/// Payload for audio clip items.
/// V1 (PR8): project-level music track with trim + volume.
public struct AudioPayload: Codable, Equatable, Sendable {
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

    public init(
        assetRef: AudioAssetRef? = nil,
        sourceDurationUs: TimeUs = 0,
        trimStartUs: TimeUs = 0,
        trimEndUs: TimeUs = 0,
        volume: Float = 1.0
    ) {
        self.assetRef = assetRef
        self.sourceDurationUs = sourceDurationUs
        self.trimStartUs = trimStartUs
        self.trimEndUs = trimEndUs
        self.volume = volume
    }
}

/// Reference to audio asset.
public enum AudioAssetRef: Codable, Equatable, Sendable {
    /// Bundled sound effect by ID.
    case bundled(id: String)

    /// Imported audio file identified by logical asset ID.
    case imported(assetId: ProjectAssetID)
}

// MARK: - Sticker Payload

/// Payload for sticker overlay items.
/// Placeholder in PR1 (Core). Implemented in PR6 (Stickers V1).
public struct StickerPayload: Codable, Equatable, Sendable {
    /// Bundled sticker ID (V1: bundled pack only).
    public var stickerId: String?

    public init(stickerId: String? = nil) {
        self.stickerId = stickerId
    }
}

// MARK: - Text Payload

/// Payload for text overlay items.
/// PR9: Shipped with canvas-normalized positioning (centerX/centerY).
public struct TextPayload: Codable, Equatable, Sendable {
    /// Text content.
    public var text: String

    /// Font family name.
    public var fontFamily: String?

    /// Font size in points.
    public var fontSize: CGFloat?

    /// Text color as hex string (e.g., "#FF0000").
    public var colorHex: String?

    /// Canvas-normalized X position (0..1, default 0.5 = center).
    public var centerX: CGFloat

    /// Canvas-normalized Y position (0..1, default 0.5 = center).
    public var centerY: CGFloat

    public init(
        text: String = "",
        fontFamily: String? = nil,
        fontSize: CGFloat? = nil,
        colorHex: String? = nil,
        centerX: CGFloat = 0.5,
        centerY: CGFloat = 0.5
    ) {
        self.text = text
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.colorHex = colorHex
        self.centerX = centerX
        self.centerY = centerY
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
