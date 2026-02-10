import Foundation

/// Describes a toggleable layer within a media block.
///
/// Toggle layers are decorative elements (frames, overlays, stickers) that users
/// can enable/disable at runtime. The toggle state is persisted across sessions.
///
/// - Note: Toggle IDs must match between `scene.json` metadata and Lottie layer names
///   using the `toggle:<id>` naming convention.
public struct LayerToggle: Codable, Equatable, Sendable {
    /// Unique toggle identifier within the block.
    /// Must match the `<id>` portion of Lottie layer names: `toggle:<id>`
    public let id: String

    /// User-facing display title for the toggle
    public let title: String

    /// Optional grouping for UI organization (nil = no group)
    public let group: String?

    /// Default enabled state when no persisted value exists
    public let defaultOn: Bool

    public init(id: String, title: String, group: String? = nil, defaultOn: Bool) {
        self.id = id
        self.title = title
        self.group = group
        self.defaultOn = defaultOn
    }
}
