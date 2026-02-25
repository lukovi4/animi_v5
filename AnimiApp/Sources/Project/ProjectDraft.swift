import Foundation

// MARK: - Project Draft (Release v1)

/// User project based on a template recipe.
/// Stored in `<projectId>.json` in Application Support.
/// Contains all user customizations: background, timeline, per-instance scene state.
public struct ProjectDraft: Codable, Equatable, Sendable {

    // MARK: - Constants

    /// Current schema version (release v1 - no legacy migrations).
    public static let currentSchemaVersion: Int = 5

    /// Minimum scene duration in microseconds (0.1 seconds).
    public static let minSceneDurationUs: TimeUs = 100_000

    // MARK: - Schema

    /// Schema version of this draft (for future migrations).
    public var schemaVersion: Int

    // MARK: - Identification

    /// Unique project identifier.
    public var id: UUID

    /// Template identifier this project is based on.
    public var templateId: String

    /// User-defined project name (nil until first Save/Export).
    public var name: String?

    // MARK: - Timestamps

    /// Creation timestamp.
    public var createdAt: Date

    /// Last modification timestamp.
    public var updatedAt: Date

    // MARK: - Background

    /// User's background customization.
    public var background: ProjectBackgroundOverride

    // MARK: - Canonical Timeline

    /// Canonical microseconds-based timeline.
    /// Single source of truth for all timeline data.
    public var canonicalTimeline: CanonicalTimeline

    // MARK: - Per-Instance Scene State

    /// Per-instance scene state (variants, transforms, toggles).
    /// Key: TimelineItem.id (scene instance ID).
    /// Value: SceneState for that instance.
    public var sceneInstanceStates: [UUID: SceneState]

    // MARK: - Initialization

    public init(
        schemaVersion: Int = ProjectDraft.currentSchemaVersion,
        id: UUID = UUID(),
        templateId: String,
        name: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        background: ProjectBackgroundOverride = .empty,
        canonicalTimeline: CanonicalTimeline = .empty(),
        sceneInstanceStates: [UUID: SceneState] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.templateId = templateId
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.background = background
        self.canonicalTimeline = canonicalTimeline
        self.sceneInstanceStates = sceneInstanceStates
    }

    // MARK: - Factory

    /// Creates an empty draft for a template.
    /// Timeline will be populated from recipe when loadProject is called.
    /// - Parameters:
    ///   - templateId: Template identifier
    ///   - projectId: Optional pre-generated project ID
    /// - Returns: New empty ProjectDraft
    public static func create(
        for templateId: String,
        projectId: UUID = UUID()
    ) -> ProjectDraft {
        ProjectDraft(
            id: projectId,
            templateId: templateId,
            canonicalTimeline: .empty(),
            sceneInstanceStates: [:]
        )
    }
}

// MARK: - Convenience Extensions

public extension ProjectDraft {
    /// Total project duration from canonical timeline.
    var projectDurationUs: TimeUs {
        canonicalTimeline.totalDurationUs
    }

    /// Scene items from canonical timeline.
    var sceneItems: [TimelineItem] {
        canonicalTimeline.sceneItems
    }

    /// Returns SceneState for a specific scene instance.
    /// Returns empty state if not found.
    func sceneState(for instanceId: UUID) -> SceneState {
        sceneInstanceStates[instanceId] ?? .empty
    }

    /// Updates SceneState for a specific scene instance.
    mutating func setSceneState(_ state: SceneState, for instanceId: UUID) {
        sceneInstanceStates[instanceId] = state
        updatedAt = Date()
    }
}

// MARK: - Schema Fallback

public extension ProjectDraft {
    /// Checks if the draft is valid (schema matches current).
    /// Returns false for legacy/incompatible drafts.
    var isValid: Bool {
        schemaVersion == ProjectDraft.currentSchemaVersion
    }
}
