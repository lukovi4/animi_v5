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

    // MARK: - Media Assignments (Placeholder for future)

    /// Per-block media slot assignments.
    /// Key: blockId, Value: MediaRef to assigned media.
    /// Not used in P0 — placeholder for future persistence.
    public var mediaAssignments: [String: MediaRef]?

    // MARK: - Initialization

    public init(
        variantOverrides: [String: String] = [:],
        userTransforms: [String: Matrix2D] = [:],
        layerToggles: [String: [String: Bool]] = [:],
        mediaAssignments: [String: MediaRef]? = nil
    ) {
        self.variantOverrides = variantOverrides
        self.userTransforms = userTransforms
        self.layerToggles = layerToggles
        self.mediaAssignments = mediaAssignments
    }

    /// Empty state with all defaults.
    public static let empty = SceneState()
}
