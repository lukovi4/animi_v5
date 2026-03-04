import Foundation
import TVECore

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

    // MARK: - Initialization

    public init(
        variantOverrides: [String: String] = [:],
        userTransforms: [String: Matrix2D] = [:],
        layerToggles: [String: [String: Bool]] = [:],
        mediaAssignments: [String: MediaRef]? = nil,
        userMediaPresent: [String: Bool]? = nil
    ) {
        self.variantOverrides = variantOverrides
        self.userTransforms = userTransforms
        self.layerToggles = layerToggles
        self.mediaAssignments = mediaAssignments
        self.userMediaPresent = userMediaPresent
    }

    /// Empty state with all defaults.
    public static let empty = SceneState()
}
