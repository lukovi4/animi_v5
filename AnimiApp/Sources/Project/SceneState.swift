import Foundation
import TVECore

// MARK: - Persisted Video Selection

/// Persisted video trim/audio parameters.
/// URL-less — the video file reference lives in `MediaRef` (mediaAssignments).
/// Assembled into runtime `VideoSelection` at restore/export time via `toVideoSelection(url:)`.
public struct PersistedVideoSelection: Codable, Equatable, Sendable {
    public var trimStart: Double
    public var trimEnd: Double
    public var isMuted: Bool
    public var volume: Float

    public init(
        trimStart: Double = 0,
        trimEnd: Double,
        isMuted: Bool = false,
        volume: Float = 1.0
    ) {
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.isMuted = isMuted
        self.volume = volume
    }

    /// Extracts persisted params from a runtime VideoSelection.
    public init(from selection: VideoSelection) {
        self.trimStart = selection.trimStart
        self.trimEnd = selection.trimEnd
        self.isMuted = selection.isMuted
        self.volume = selection.volume
    }

    /// Assembles a runtime VideoSelection from persisted params + resolved URL.
    public func toVideoSelection(url: URL) -> VideoSelection {
        VideoSelection(
            url: url,
            trimStart: trimStart,
            trimEnd: trimEnd,
            isMuted: isMuted,
            volume: volume
        )
    }

}

// MARK: - Scene State

/// Persisted state of the base scene (variants, transforms, toggles).
/// Separated from Timeline to keep "when" (timeline) distinct from "how it looks" (sceneState).
public struct SceneState: Codable, Equatable, Sendable {

    // MARK: - Variant Overrides

    /// Per-block variant selection overrides.
    /// Key: blockId, Value: selected variantId.
    /// Blocks without entry use compilation default.
    public var variantOverrides: [String: String]

    // MARK: - Layer Toggles

    /// Per-block layer toggle states.
    /// Key: blockId, Value: dictionary of (toggleId → enabled).
    /// Blocks without entry use defaults from scene.json.
    public var layerToggles: [String: [String: Bool]]

    // MARK: - Media Slots (v7)

    /// Unified per-block media slots.
    /// Key: blockId, Value: SceneMediaSlot containing mediaRef + visibility + videoWindow.
    /// nil = no media assigned to any block.
    public var mediaSlotsByBlockId: [String: SceneMediaSlot]?

    // MARK: - Initialization

    public init(
        variantOverrides: [String: String] = [:],
        layerToggles: [String: [String: Bool]] = [:],
        mediaSlotsByBlockId: [String: SceneMediaSlot]? = nil
    ) {
        self.variantOverrides = variantOverrides
        self.layerToggles = layerToggles
        self.mediaSlotsByBlockId = mediaSlotsByBlockId
    }

    /// Empty state with all defaults.
    public static let empty = SceneState()
}
