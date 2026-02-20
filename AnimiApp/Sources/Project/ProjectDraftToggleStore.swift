import Foundation
import TVECore

// MARK: - Project Draft Toggle Store

/// Adapter that implements LayerToggleStore by reading/writing to ProjectDraft.sceneState.
/// Does not directly persist — relies on external code to save the draft when needed.
///
/// - Important: This class is marked `@unchecked Sendable` but the closures it captures
///   typically access mutable UI state. **All access must happen on the main thread.**
///   The ScenePlayer (which uses LayerToggleStore) is already `@MainActor`, so this
///   constraint is naturally satisfied when used as intended.
///
/// Usage:
/// 1. Create with a mutable reference to ProjectDraft (main thread only)
/// 2. Pass to ScenePlayer as toggleStore
/// 3. Call saveDraftIfDirty() after changes to persist
public final class ProjectDraftToggleStore: LayerToggleStore, @unchecked Sendable {

    // MARK: - Properties

    /// Callback to get/set layer toggles in the draft's sceneState.
    /// Using closures to avoid reference cycle issues and allow flexibility.
    private let getToggles: () -> [String: [String: Bool]]
    private let setToggles: ([String: [String: Bool]]) -> Void

    /// Callback invoked when state changes (for dirty tracking).
    private let onStateChanged: (() -> Void)?

    // MARK: - Initialization

    /// Creates a toggle store backed by ProjectDraft.
    /// - Parameters:
    ///   - getToggles: Closure to read layerToggles from draft
    ///   - setToggles: Closure to write layerToggles to draft
    ///   - onStateChanged: Optional callback when state changes (for dirty tracking)
    public init(
        getToggles: @escaping () -> [String: [String: Bool]],
        setToggles: @escaping ([String: [String: Bool]]) -> Void,
        onStateChanged: (() -> Void)? = nil
    ) {
        self.getToggles = getToggles
        self.setToggles = setToggles
        self.onStateChanged = onStateChanged
    }

    // MARK: - LayerToggleStore Protocol

    /// Loads the saved toggle state for a specific toggle.
    /// - Parameters:
    ///   - templateId: The scene's unique identifier (not used in this implementation)
    ///   - blockId: The media block's identifier
    ///   - toggleId: The toggle's identifier
    /// - Returns: The saved enabled state, or nil if no saved value exists
    public func load(templateId: String, blockId: String, toggleId: String) -> Bool? {
        let toggles = getToggles()
        return toggles[blockId]?[toggleId]
    }

    /// Saves the toggle state.
    /// - Parameters:
    ///   - templateId: The scene's unique identifier (not used in this implementation)
    ///   - blockId: The media block's identifier
    ///   - toggleId: The toggle's identifier
    ///   - value: The enabled state to save
    public func save(templateId: String, blockId: String, toggleId: String, value: Bool) {
        var toggles = getToggles()

        if toggles[blockId] == nil {
            toggles[blockId] = [:]
        }
        toggles[blockId]?[toggleId] = value

        setToggles(toggles)
        onStateChanged?()
    }
}

// MARK: - Convenience Initializer

public extension ProjectDraftToggleStore {

    /// Creates a toggle store that directly mutates a ProjectDraft reference.
    /// - Parameters:
    ///   - draft: Binding to the ProjectDraft (using inout semantics via closure)
    ///   - onStateChanged: Callback when state changes
    /// - Returns: Configured ProjectDraftToggleStore
    ///
    /// Example usage:
    /// ```swift
    /// var draft = ProjectDraft(...)
    /// let store = ProjectDraftToggleStore.create(
    ///     draft: { draft },
    ///     updateDraft: { draft = $0 },
    ///     onStateChanged: { saveCrashDraft() }
    /// )
    /// ```
    static func create(
        draft: @escaping () -> ProjectDraft,
        updateDraft: @escaping (ProjectDraft) -> Void,
        onStateChanged: (() -> Void)? = nil
    ) -> ProjectDraftToggleStore {
        ProjectDraftToggleStore(
            getToggles: { draft().sceneState.layerToggles },
            setToggles: { newToggles in
                var currentDraft = draft()
                currentDraft.sceneState.layerToggles = newToggles
                currentDraft.updatedAt = Date()
                updateDraft(currentDraft)
            },
            onStateChanged: onStateChanged
        )
    }
}
