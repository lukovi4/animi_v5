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
/// Minimal in PR1 (Core). Contains slot for future per-scene state override.
public struct ScenePayload: Codable, Equatable, Sendable {
    /// Reserved for future: reference to per-scene state override.
    /// When nil, scene inherits global SceneState from ProjectDraft.
    /// Not used in PR1 (Timeline Core).
    public var stateOverrideRef: UUID?

    public init(stateOverrideRef: UUID? = nil) {
        self.stateOverrideRef = stateOverrideRef
    }
}

// MARK: - Audio Payload

/// Payload for audio clip items.
/// Placeholder in PR1 (Core). Implemented in PR5 (Audio V1).
public struct AudioPayload: Codable, Equatable, Sendable {
    /// Audio asset reference (implemented in PR5).
    public var assetRef: AudioAssetRef?

    /// Volume level 0.0 - 1.0 (default: 1.0).
    public var volume: Float

    public init(assetRef: AudioAssetRef? = nil, volume: Float = 1.0) {
        self.assetRef = assetRef
        self.volume = volume
    }
}

/// Reference to audio asset.
public enum AudioAssetRef: Codable, Equatable, Sendable {
    /// Bundled sound effect by ID.
    case bundled(id: String)

    /// Imported audio file (relative path under project folder).
    case imported(relativePath: String)
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
/// Placeholder in PR1 (Core). Implemented in PR7 (Text V1).
public struct TextPayload: Codable, Equatable, Sendable {
    /// Text content.
    public var text: String

    /// Font family name.
    public var fontFamily: String?

    /// Font size in points.
    public var fontSize: CGFloat?

    /// Text color as hex string (e.g., "#FF0000").
    public var colorHex: String?

    public init(
        text: String = "",
        fontFamily: String? = nil,
        fontSize: CGFloat? = nil,
        colorHex: String? = nil
    ) {
        self.text = text
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.colorHex = colorHex
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
