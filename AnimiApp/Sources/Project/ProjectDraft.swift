import Foundation

// MARK: - Project Draft

/// User project based on a single template.
/// Stored in `<projectId>.json` in Application Support.
/// Contains all user customizations: duration, background, scene state, timeline.
public struct ProjectDraft: Codable, Equatable, Sendable {

    // MARK: - Schema Version

    /// Current schema version for migration support.
    /// v1: Initial schema with projectDurationFrames
    /// v2: Added projectDurationUs for fractional duration support
    public static let currentSchemaVersion: Int = 2

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

    /// Project duration in frames (LEGACY - v1 schema).
    /// Kept for migration from v1 projects. Use `projectDurationUs` for new code.
    /// When non-nil, represents user's explicit duration override in frames.
    public var projectDurationFrames: Int?

    /// Project duration in microseconds (v2 schema - source of truth).
    /// Supports fractional durations like 10.4 seconds.
    /// When non-nil, represents user's explicit duration override.
    public var projectDurationUs: Int64?

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
        projectDurationUs: Int64? = nil,
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
        self.projectDurationUs = projectDurationUs
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
    /// Returns the effective duration in frames (LEGACY).
    /// Uses `projectDurationFrames` if set, otherwise falls back to template default.
    /// - Parameter templateDurationFrames: Default duration from template's Canvas.durationFrames
    /// - Returns: Effective duration in frames
    func effectiveDurationFrames(templateDefault: Int) -> Int {
        projectDurationFrames ?? templateDefault
    }

    /// Returns the effective duration in microseconds.
    /// Uses `projectDurationUs` if set, otherwise falls back to template default.
    /// - Parameter templateDefaultUs: Default duration from template in microseconds
    /// - Returns: Effective duration in microseconds
    func effectiveDurationUs(templateDefaultUs: Int64) -> Int64 {
        projectDurationUs ?? templateDefaultUs
    }
}

// MARK: - Duration Migration (v1 → v2)

public extension ProjectDraft {
    /// Migrates legacy `projectDurationFrames` to `projectDurationUs` if needed.
    /// Call this once when loading a v1 project with access to template FPS.
    ///
    /// Migration rules:
    /// - If `projectDurationUs` is already set → no-op (returns false)
    /// - If `projectDurationFrames` is set → convert to microseconds and store (returns true)
    /// - If neither is set → no-op (returns false)
    ///
    /// - Parameter templateFPS: Template's frame rate for conversion
    /// - Returns: `true` if migration was performed, `false` if no migration needed
    @discardableResult
    mutating func migrateDurationFramesToUsIfNeeded(templateFPS: Int) -> Bool {
        // Already migrated or no legacy value
        guard projectDurationUs == nil, let frames = projectDurationFrames, templateFPS > 0 else {
            return false
        }

        // Convert frames to microseconds: frames * 1_000_000 / fps
        projectDurationUs = Int64(frames) * 1_000_000 / Int64(templateFPS)

        // Update schema version to indicate migration
        schemaVersion = ProjectDraft.currentSchemaVersion

        return true
    }
}
