import Foundation

// MARK: - Audio Export Plan (PR3)

/// A single audio item's export configuration.
public struct AudioExportItemPlan: Sendable {
    public let itemId: UUID
    public let role: AudioRole
    public let url: URL
    public let startTimeSeconds: Double
    public let volume: Float
    public let trimStartSeconds: Double?
    public let trimEndSeconds: Double?
    public let loopToFit: Bool

    public init(
        itemId: UUID,
        role: AudioRole,
        url: URL,
        startTimeSeconds: Double,
        volume: Float,
        trimStartSeconds: Double? = nil,
        trimEndSeconds: Double? = nil,
        loopToFit: Bool = false
    ) {
        self.itemId = itemId
        self.role = role
        self.url = url
        self.startTimeSeconds = startTimeSeconds
        self.volume = volume
        self.trimStartSeconds = trimStartSeconds
        self.trimEndSeconds = trimEndSeconds
        self.loopToFit = loopToFit
    }
}

/// Production audio export contract (PR3).
/// Replaces `AudioExportConfig` as the owner of audio domain in export path.
public struct AudioExportPlan: Sendable {
    public let items: [AudioExportItemPlan]
    public let includeOriginalFromVideoSlots: Bool
    public let originalDefaultVolume: Float

    public init(
        items: [AudioExportItemPlan] = [],
        includeOriginalFromVideoSlots: Bool = true,
        originalDefaultVolume: Float = 1.0
    ) {
        self.items = items
        self.includeOriginalFromVideoSlots = includeOriginalFromVideoSlots
        self.originalDefaultVolume = originalDefaultVolume
    }
}

// MARK: - Bridging Helpers

extension AudioExportItemPlan {
    func toTrackConfig() -> AudioTrackConfig {
        AudioTrackConfig(
            url: url,
            startTimeSeconds: startTimeSeconds,
            volume: volume,
            trimStartSeconds: trimStartSeconds,
            trimEndSeconds: trimEndSeconds,
            loopToFit: loopToFit
        )
    }
}

extension AudioExportPlan {
    /// Legacy bridge: takes first .music and first .voiceover only.
    func toLegacyConfig() -> AudioExportConfig {
        AudioExportConfig(
            music: items.first { $0.role == .music }?.toTrackConfig(),
            voiceover: items.first { $0.role == .voiceover }?.toTrackConfig(),
            includeOriginalFromVideoSlots: includeOriginalFromVideoSlots,
            originalDefaultVolume: originalDefaultVolume
        )
    }
}
