import Foundation

// MARK: - Scene Draft (PR2: Multi-scene support)

/// Represents a single scene in the project timeline.
/// Duration is in microseconds (source of truth).
public struct SceneDraft: Codable, Equatable, Sendable {
    /// Unique identifier for this scene.
    public let id: UUID

    /// Duration of this scene in microseconds.
    public var durationUs: TimeUs

    // Future: transitionAfterUs, title, templateRef, etc.

    public init(id: UUID = UUID(), durationUs: TimeUs) {
        self.id = id
        self.durationUs = durationUs
    }
}

// MARK: - Project Draft

/// User project based on a single template.
/// Stored in `<projectId>.json` in Application Support.
/// Contains all user customizations: duration, background, scene state, timeline.
public struct ProjectDraft: Codable, Equatable, Sendable {

    // MARK: - Schema Version

    /// Current schema version for migration support.
    /// v1: Initial schema with projectDurationFrames
    /// v2: Added projectDurationUs for fractional duration support
    /// v3: Added scenes array for multi-scene support
    /// v4: Canonical microseconds timeline (single source of truth)
    public static let currentSchemaVersion: Int = 4

    /// Minimum scene duration in microseconds (0.1 seconds).
    public static let minSceneDurationUs: TimeUs = 100_000

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

    // MARK: - Scenes (PR2: Multi-scene support)

    /// Array of scenes in the project timeline (v3 schema).
    /// When non-nil, duration is derived from sum of scene durations.
    /// When nil, falls back to legacy projectDurationUs behavior.
    public var scenes: [SceneDraft]?

    // MARK: - Scene State

    /// State of the base scene (variants, transforms, toggles).
    public var sceneState: SceneState

    // MARK: - Canonical Timeline (v4)

    /// Canonical microseconds-based timeline (v4 schema).
    /// Single source of truth for all timeline data.
    /// When non-nil, `scenes` and `timeline` fields are ignored (legacy).
    public var canonicalTimeline: CanonicalTimeline?

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
        scenes: [SceneDraft]? = nil,
        background: ProjectBackgroundOverride = .empty,
        timeline: Timeline? = nil,
        sceneState: SceneState = .empty,
        canonicalTimeline: CanonicalTimeline? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.templateId = templateId
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.projectDurationFrames = projectDurationFrames
        self.projectDurationUs = projectDurationUs
        self.scenes = scenes
        self.background = background
        self.timeline = timeline
        self.sceneState = sceneState
        self.canonicalTimeline = canonicalTimeline

        // PR1.1 Safety: v4 must always have canonical timeline
        if schemaVersion >= 4 && self.canonicalTimeline == nil {
            self.canonicalTimeline = .empty()
        }
    }

    // MARK: - Factory

    /// Creates a new draft for a template with default values.
    /// PR1.1: New v4 projects always have canonical timeline.
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
            templateId: templateId,
            canonicalTimeline: .empty()
        )
    }

    /// Creates a draft from legacy ProjectBackgroundOverride (migration).
    /// PR1.1: New v4 projects always have canonical timeline.
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
            background: legacy,
            canonicalTimeline: .empty()
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

// MARK: - Scenes Support (v2 → v3)

public extension ProjectDraft {
    /// Returns the sum of all scene durations in microseconds.
    /// Returns nil if scenes array is nil or empty.
    var scenesDurationUs: TimeUs? {
        guard let scenes = scenes, !scenes.isEmpty else { return nil }
        return scenes.reduce(0) { $0 + $1.durationUs }
    }

    /// Returns effective duration considering scenes if available.
    /// Priority: scenes sum > projectDurationUs > templateDefault
    func effectiveDurationUsWithScenes(templateDefaultUs: TimeUs) -> TimeUs {
        if let scenesSum = scenesDurationUs {
            return scenesSum
        }
        return projectDurationUs ?? templateDefaultUs
    }

    /// Lazily initializes scenes array if not already set.
    /// Creates a single scene with the effective duration.
    /// - Parameter templateDefaultUs: Template default duration for fallback
    /// - Returns: true if scenes were initialized, false if already present
    @discardableResult
    mutating func initializeScenesIfNeeded(templateDefaultUs: TimeUs) -> Bool {
        guard scenes == nil else { return false }

        let effectiveDuration = effectiveDurationUs(templateDefaultUs: templateDefaultUs)
        scenes = [SceneDraft(id: UUID(), durationUs: effectiveDuration)]
        schemaVersion = ProjectDraft.currentSchemaVersion

        return true
    }

    /// Updates duration of a specific scene.
    /// - Parameters:
    ///   - sceneId: ID of the scene to update
    ///   - newDurationUs: New duration in microseconds
    /// - Returns: true if scene was found and updated
    @discardableResult
    mutating func updateSceneDuration(sceneId: UUID, newDurationUs: TimeUs) -> Bool {
        guard let index = scenes?.firstIndex(where: { $0.id == sceneId }) else {
            return false
        }
        scenes?[index].durationUs = newDurationUs
        return true
    }
}

// MARK: - Canonical Timeline Support (v3 → v4)

public extension ProjectDraft {

    /// Result of v3→v4 migration.
    struct MigrationResult {
        /// Whether migration was performed.
        public let didMigrate: Bool
        /// Number of scenes that were extended to meet minimum duration.
        public let scenesExtended: Int
        /// Total duration increase due to min duration enforcement.
        public let durationIncreaseUs: TimeUs
    }

    /// Migrates from v3 (scenes array) to v4 (canonical timeline).
    ///
    /// Migration rules:
    /// - If `canonicalTimeline` already exists → no-op
    /// - If `scenes` exists → convert to canonical timeline
    /// - If neither exists → create empty canonical timeline
    ///
    /// Min duration enforcement:
    /// - Scenes shorter than 0.1s (100_000 µs) are extended
    /// - Project duration increases (no stealing from neighbors)
    ///
    /// After migration:
    /// - `canonicalTimeline` is populated
    /// - `scenes` is set to nil
    /// - `timeline` is set to nil
    /// - `schemaVersion` is updated to 4
    ///
    /// - Parameter templateDefaultUs: Template default duration for fallback
    /// - Returns: Migration result with statistics
    @discardableResult
    mutating func migrateToCanonicalTimelineIfNeeded(templateDefaultUs: TimeUs) -> MigrationResult {
        // Already on v4
        if canonicalTimeline != nil {
            return MigrationResult(didMigrate: false, scenesExtended: 0, durationIncreaseUs: 0)
        }

        var scenesExtended = 0
        var durationIncreaseUs: TimeUs = 0

        // Build scene items from existing scenes or create default
        let sceneItems: [TimelineItem]
        var payloads: [UUID: TimelinePayload] = [:]

        if let existingScenes = scenes, !existingScenes.isEmpty {
            // Migrate existing scenes
            sceneItems = existingScenes.map { sceneDraft in
                let payloadId = UUID()

                // Enforce minimum duration
                var duration = sceneDraft.durationUs
                if duration < ProjectDraft.minSceneDurationUs {
                    let increase = ProjectDraft.minSceneDurationUs - duration
                    durationIncreaseUs += increase
                    duration = ProjectDraft.minSceneDurationUs
                    scenesExtended += 1
                }

                // Create payload
                payloads[payloadId] = .scene(ScenePayload())

                // Create item (preserving sceneDraft.id as item.id)
                return TimelineItem(
                    id: sceneDraft.id,
                    payloadId: payloadId,
                    kind: .scene,
                    startUs: nil, // derived for sceneSequence
                    durationUs: duration
                )
            }
        } else if let durationUs = projectDurationUs, durationUs > 0 {
            // Create single scene from projectDurationUs
            let payloadId = UUID()
            let duration = max(durationUs, ProjectDraft.minSceneDurationUs)
            if durationUs < ProjectDraft.minSceneDurationUs {
                durationIncreaseUs = ProjectDraft.minSceneDurationUs - durationUs
                scenesExtended = 1
            }

            payloads[payloadId] = .scene(ScenePayload())
            sceneItems = [
                TimelineItem(
                    id: UUID(),
                    payloadId: payloadId,
                    kind: .scene,
                    startUs: nil,
                    durationUs: duration
                )
            ]
        } else {
            // Create single scene from template default
            let payloadId = UUID()
            let duration = max(templateDefaultUs, ProjectDraft.minSceneDurationUs)

            payloads[payloadId] = .scene(ScenePayload())
            sceneItems = [
                TimelineItem(
                    id: UUID(),
                    payloadId: payloadId,
                    kind: .scene,
                    startUs: nil,
                    durationUs: duration
                )
            ]
        }

        // Create sceneSequence track (always at index 0)
        let sceneTrack = Track(
            id: UUID(),
            kind: .sceneSequence,
            items: sceneItems
        )

        // Create canonical timeline
        canonicalTimeline = CanonicalTimeline(
            tracks: [sceneTrack],
            payloads: payloads
        )

        // Clear legacy fields (PR1.1: no dual truths)
        scenes = nil
        timeline = nil
        projectDurationUs = nil
        projectDurationFrames = nil

        // Update schema version
        schemaVersion = ProjectDraft.currentSchemaVersion

        return MigrationResult(
            didMigrate: true,
            scenesExtended: scenesExtended,
            durationIncreaseUs: durationIncreaseUs
        )
    }

    /// Returns effective duration from canonical timeline.
    /// Falls back to legacy methods if canonical timeline not present.
    func effectiveDurationUsFromCanonical(templateDefaultUs: TimeUs) -> TimeUs {
        if let canonical = canonicalTimeline {
            return canonical.totalDurationUs
        }
        return effectiveDurationUsWithScenes(templateDefaultUs: templateDefaultUs)
    }

    /// Returns scene items from canonical timeline.
    /// Returns empty array if canonical timeline not present.
    var canonicalSceneItems: [TimelineItem] {
        canonicalTimeline?.sceneItems ?? []
    }
}
