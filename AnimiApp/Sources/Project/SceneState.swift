import Foundation
import TVECore

// MARK: - Persisted Video Selection

/// Persisted video trim/offset/audio parameters.
/// URL-less — the video file reference lives in `MediaRef` (mediaAssignments).
/// Assembled into runtime `VideoSelection` at restore/export time via `toVideoSelection(url:)`.
public struct PersistedVideoSelection: Codable, Equatable, Sendable {
    public var trimStart: Double
    public var trimEnd: Double
    public var offset: Double
    public var isMuted: Bool
    public var volume: Float

    public init(
        trimStart: Double = 0,
        trimEnd: Double,
        offset: Double = 0,
        isMuted: Bool = false,
        volume: Float = 1.0
    ) {
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.offset = offset
        self.isMuted = isMuted
        self.volume = volume
    }

    /// Extracts persisted params from a runtime VideoSelection.
    public init(from selection: VideoSelection) {
        self.trimStart = selection.trimStart
        self.trimEnd = selection.trimEnd
        self.offset = selection.offset
        self.isMuted = selection.isMuted
        self.volume = selection.volume
    }

    /// Assembles a runtime VideoSelection from persisted params + resolved URL.
    public func toVideoSelection(url: URL) -> VideoSelection {
        VideoSelection(
            url: url,
            trimStart: trimStart,
            trimEnd: trimEnd,
            offset: offset,
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

    // MARK: - User Transforms

    /// Per-block user transforms (pan/zoom/rotate from editor).
    /// Key: blockId, Value: Matrix2D transform.
    /// Blocks without entry default to `.identity`.
    public var userTransforms: [String: Matrix2D]

    // MARK: - Layer Toggles

    /// Per-block layer toggle states.
    /// Key: blockId, Value: dictionary of (toggleId → enabled).
    /// Blocks without entry use defaults from scene.json.
    public var layerToggles: [String: [String: Bool]]

    // MARK: - Media Assignments

    /// Per-block media slot assignments.
    /// Key: blockId, Value: MediaRef to assigned media.
    public var mediaAssignments: [String: MediaRef]?

    // MARK: - User Media Presence (PR-A: Scene Edit)

    /// Per-block visibility flag for binding layer.
    /// Key: blockId, Value: whether to render the binding layer.
    /// nil treated as [:] (empty dictionary).
    ///
    /// Semantics:
    /// - `userMediaPresent[blockId] = true` → render binding layer
    /// - `userMediaPresent[blockId] = false` → hide binding layer (media still assigned)
    /// - key absent → follows automatic logic from UserMediaService
    ///
    /// Default in SceneRenderPlan: `userMediaPresent[blockId] ?? false`
    /// This is correct because UserMediaService.setPhoto/setVideo automatically
    /// sets `present = true` when media is added.
    public var userMediaPresent: [String: Bool]?

    // MARK: - Video Selections

    /// Per-block video selection parameters (trim/offset/audio).
    /// Key: blockId. URL-less — video file ref lives in mediaAssignments.
    /// nil = no video selections persisted (all defaults).
    public var videoSelections: [String: PersistedVideoSelection]?

    // MARK: - Initialization

    public init(
        variantOverrides: [String: String] = [:],
        userTransforms: [String: Matrix2D] = [:],
        layerToggles: [String: [String: Bool]] = [:],
        mediaAssignments: [String: MediaRef]? = nil,
        userMediaPresent: [String: Bool]? = nil,
        videoSelections: [String: PersistedVideoSelection]? = nil
    ) {
        self.variantOverrides = variantOverrides
        self.userTransforms = userTransforms
        self.layerToggles = layerToggles
        self.mediaAssignments = mediaAssignments
        self.userMediaPresent = userMediaPresent
        self.videoSelections = videoSelections
    }

    /// Empty state with all defaults.
    public static let empty = SceneState()
}
