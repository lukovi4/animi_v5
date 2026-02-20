import Foundation

// MARK: - Project Draft

/// User project based on a single template.
/// Stored in `<projectId>.json` in Application Support.
/// Contains all user customizations: duration, background, scene state, timeline.
public struct ProjectDraft: Codable, Equatable, Sendable {

    // MARK: - Schema Version

    /// Current schema version for migration support.
    public static let currentSchemaVersion: Int = 1

    /// Schema version of this draft (for migration).
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

    // MARK: - Duration

    /// Project duration in frames (nil = use template's Canvas.durationFrames).
    /// When non-nil, represents user's explicit duration override.
    public var projectDurationFrames: Int?

    // MARK: - Background

    /// User's background customization.
    public var background: ProjectBackgroundOverride

    // MARK: - Timeline

    /// Timeline with layer items (optional in P0).
    /// When nil or empty, `.sceneBase` layer is computed virtually.
    public var timeline: Timeline?

    // MARK: - Scene State

    /// State of the base scene (variants, transforms, toggles).
    public var sceneState: SceneState

    // MARK: - Initialization

    public init(
        schemaVersion: Int = ProjectDraft.currentSchemaVersion,
        id: UUID = UUID(),
        templateId: String,
        name: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        projectDurationFrames: Int? = nil,
        background: ProjectBackgroundOverride = .empty,
        timeline: Timeline? = nil,
        sceneState: SceneState = .empty
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.templateId = templateId
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.projectDurationFrames = projectDurationFrames
        self.background = background
        self.timeline = timeline
        self.sceneState = sceneState
    }

    // MARK: - Factory

    /// Creates a new draft for a template with default values.
    /// - Parameters:
    ///   - templateId: Template identifier
    ///   - projectId: Optional pre-generated project ID
    /// - Returns: New ProjectDraft instance
    public static func create(
        for templateId: String,
        projectId: UUID = UUID()
    ) -> ProjectDraft {
        ProjectDraft(
            id: projectId,
            templateId: templateId
        )
    }

    /// Creates a draft from legacy ProjectBackgroundOverride (migration).
    /// - Parameters:
    ///   - legacy: Legacy background override
    ///   - templateId: Template identifier
    ///   - projectId: Project ID
    /// - Returns: Migrated ProjectDraft
    public static func migrate(
        from legacy: ProjectBackgroundOverride,
        templateId: String,
        projectId: UUID
    ) -> ProjectDraft {
        ProjectDraft(
            id: projectId,
            templateId: templateId,
            background: legacy
        )
    }
}

// MARK: - Effective Duration Helper

public extension ProjectDraft {
    /// Returns the effective duration in frames.
    /// Uses `projectDurationFrames` if set, otherwise falls back to template default.
    /// - Parameter templateDurationFrames: Default duration from template's Canvas.durationFrames
    /// - Returns: Effective duration in frames
    func effectiveDurationFrames(templateDefault: Int) -> Int {
        projectDurationFrames ?? templateDefault
    }
}
