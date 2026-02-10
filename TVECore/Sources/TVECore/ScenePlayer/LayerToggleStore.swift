import Foundation

/// Protocol for persisting layer toggle states across sessions.
///
/// Implementations can use UserDefaults, file storage, or any other persistence mechanism.
/// The store is optional in ScenePlayer — if not provided, only in-memory state is used.
///
/// - Note: Toggle state is keyed by (templateId, blockId, toggleId) triple.
public protocol LayerToggleStore: Sendable {
    /// Loads the saved toggle state for a specific toggle.
    ///
    /// - Parameters:
    ///   - templateId: The scene's unique identifier (`scene.sceneId`)
    ///   - blockId: The media block's identifier
    ///   - toggleId: The toggle's identifier (from `toggle:<id>` layer name)
    /// - Returns: The saved enabled state, or `nil` if no saved value exists
    func load(templateId: String, blockId: String, toggleId: String) -> Bool?

    /// Saves the toggle state.
    ///
    /// - Parameters:
    ///   - templateId: The scene's unique identifier (`scene.sceneId`)
    ///   - blockId: The media block's identifier
    ///   - toggleId: The toggle's identifier
    ///   - value: The enabled state to save
    func save(templateId: String, blockId: String, toggleId: String, value: Bool)
}
