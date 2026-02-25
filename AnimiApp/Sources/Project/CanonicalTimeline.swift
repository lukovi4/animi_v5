import Foundation

// MARK: - Scene Draft (UI Adapter)

/// Simple struct for passing scene info to UI components.
/// Contains only id and duration - used by TimelineView, SceneTrackView, etc.
/// This is a UI adapter, NOT the domain model (use TimelineItem for domain logic).
public struct SceneDraft: Codable, Equatable, Sendable {
    /// Unique identifier for this scene instance.
    public let id: UUID

    /// Duration of this scene in microseconds.
    public var durationUs: TimeUs

    public init(id: UUID = UUID(), durationUs: TimeUs) {
        self.id = id
        self.durationUs = durationUs
    }
}

// MARK: - Canonical Timeline (v4 Schema)

/// Canonical microseconds-based timeline model.
/// Single source of truth for all timeline data in the project.
/// Replaces frame-based Timeline and parallel scenes array.
public struct CanonicalTimeline: Codable, Equatable, Sendable {

    /// Ordered tracks. Index determines z-order (lower = back, higher = front).
    /// tracks[0] is always sceneSequence track (invariant enforced by Store).
    public var tracks: [Track]

    /// Payload registry. Maps payloadId to payload data.
    public var payloads: [UUID: TimelinePayload]

    public init(tracks: [Track] = [], payloads: [UUID: TimelinePayload] = [:]) {
        self.tracks = tracks
        self.payloads = payloads
    }

    /// Creates an empty timeline with a single sceneSequence track.
    public static func empty() -> CanonicalTimeline {
        let sceneTrack = Track(id: UUID(), kind: .sceneSequence, items: [])
        return CanonicalTimeline(tracks: [sceneTrack], payloads: [:])
    }

    /// Creates a timeline with a single scene.
    /// - Parameters:
    ///   - sceneTypeId: Scene type identifier from SceneLibrary
    ///   - durationUs: Duration for the scene in microseconds
    /// - Returns: CanonicalTimeline with one scene item and its payload
    public static func makeWithSingleScene(sceneTypeId: String, durationUs: TimeUs) -> CanonicalTimeline {
        let payloadId = UUID()
        let sceneItem = TimelineItem(
            id: UUID(),
            payloadId: payloadId,
            kind: .scene,
            startUs: nil,
            durationUs: durationUs
        )
        let sceneTrack = Track(id: UUID(), kind: .sceneSequence, items: [sceneItem])
        let payloads: [UUID: TimelinePayload] = [payloadId: .scene(ScenePayload(sceneTypeId: sceneTypeId))]
        return CanonicalTimeline(tracks: [sceneTrack], payloads: payloads)
    }

    /// Creates a timeline from a sequence of scene type defaults.
    /// Used when initializing a project from a template recipe.
    /// - Parameter defaults: Array of scene type defaults from recipe
    /// - Returns: CanonicalTimeline with scene items for each default
    public static func makeFromRecipe(defaults: [SceneTypeDefault]) -> CanonicalTimeline {
        var items: [TimelineItem] = []
        var payloads: [UUID: TimelinePayload] = [:]

        for sceneDefault in defaults {
            let payloadId = UUID()
            let durationUs = max(sceneDefault.baseDurationUs, ProjectDraft.minSceneDurationUs)

            let item = TimelineItem(
                id: UUID(),
                payloadId: payloadId,
                kind: .scene,
                startUs: nil,
                durationUs: durationUs
            )

            items.append(item)
            payloads[payloadId] = .scene(ScenePayload(sceneTypeId: sceneDefault.sceneTypeId))
        }

        let sceneTrack = Track(id: UUID(), kind: .sceneSequence, items: items)
        return CanonicalTimeline(tracks: [sceneTrack], payloads: payloads)
    }
}

// MARK: - Track

/// A track on the timeline containing items of compatible kinds.
public struct Track: Codable, Equatable, Sendable {
    /// Unique identifier for this track.
    public let id: UUID

    /// Type of track (determines which ItemKinds are allowed).
    public let kind: TrackKind

    /// Items on this track, ordered by time.
    public var items: [TimelineItem]

    public init(id: UUID = UUID(), kind: TrackKind, items: [TimelineItem] = []) {
        self.id = id
        self.kind = kind
        self.items = items
    }
}

// MARK: - TrackKind

/// Type of track on the timeline.
public enum TrackKind: String, Codable, Sendable {
    /// Scene sequence track. Contains only scene items.
    /// Invariant: exactly one per timeline, always at tracks[0].
    /// Items have no gaps, startUs is derived from cumulative duration sum.
    case sceneSequence

    /// Audio track. Contains only audioClip items.
    /// Multiple audio tracks allowed. Overlap allowed (mixed during playback/export).
    case audio

    /// Overlay track. Contains sticker and text items.
    /// Multiple overlay tracks allowed. Order determines z-order.
    case overlay
}

// MARK: - TimelineItem

/// A single item on a track.
public struct TimelineItem: Codable, Equatable, Sendable {
    /// Unique identifier for this item instance.
    public let id: UUID

    /// Reference to payload in CanonicalTimeline.payloads registry.
    public let payloadId: UUID

    /// Kind of item (must be compatible with parent track's kind).
    public let kind: ItemKind

    /// Start time in microseconds.
    /// - For sceneSequence items: nil (derived from cumulative sum of previous durations)
    /// - For audio/overlay items: explicit start time
    public var startUs: TimeUs?

    /// Duration in microseconds.
    public var durationUs: TimeUs

    public init(
        id: UUID = UUID(),
        payloadId: UUID,
        kind: ItemKind,
        startUs: TimeUs? = nil,
        durationUs: TimeUs
    ) {
        self.id = id
        self.payloadId = payloadId
        self.kind = kind
        self.startUs = startUs
        self.durationUs = durationUs
    }
}

// MARK: - ItemKind

/// Kind of timeline item.
public enum ItemKind: String, Codable, Sendable {
    /// Scene item. Only allowed in sceneSequence track.
    case scene

    /// Audio clip item. Only allowed in audio track.
    case audioClip

    /// Sticker overlay item. Only allowed in overlay track.
    case sticker

    /// Text overlay item. Only allowed in overlay track.
    case text
}

// MARK: - Convenience Extensions

public extension CanonicalTimeline {
    /// Returns the sceneSequence track (always tracks[0]).
    /// Asserts if invariant is violated.
    var sceneSequenceTrack: Track {
        guard let track = tracks.first, track.kind == .sceneSequence else {
            assertionFailure("Invariant violated: sceneSequence track must be at tracks[0]")
            return Track(kind: .sceneSequence)
        }
        return track
    }

    /// Returns all scene items from the sceneSequence track.
    var sceneItems: [TimelineItem] {
        sceneSequenceTrack.items
    }

    /// Computes total project duration from scene sequence.
    var totalDurationUs: TimeUs {
        sceneSequenceTrack.items.reduce(0) { $0 + $1.durationUs }
    }

    /// Returns sceneTypeId of the first scene in timeline, if any.
    /// Used to determine initial scene when opening a saved project.
    var firstSceneTypeId: String? {
        guard let firstItem = sceneItems.first,
              let payload = payloads[firstItem.payloadId],
              case .scene(let scenePayload) = payload else {
            return nil
        }
        return scenePayload.sceneTypeId
    }

    /// Computes startUs for a scene item at given index (derived from cumulative sum).
    func computedStartUs(forSceneAt index: Int) -> TimeUs {
        guard index >= 0 && index < sceneSequenceTrack.items.count else { return 0 }
        return sceneSequenceTrack.items[0..<index].reduce(0) { $0 + $1.durationUs }
    }
}

// MARK: - Track Validation

public extension TrackKind {
    /// Returns the allowed ItemKinds for this track type.
    var allowedItemKinds: Set<ItemKind> {
        switch self {
        case .sceneSequence:
            return [.scene]
        case .audio:
            return [.audioClip]
        case .overlay:
            return [.sticker, .text]
        }
    }

    /// Checks if an ItemKind is valid for this track type.
    func allows(_ itemKind: ItemKind) -> Bool {
        allowedItemKinds.contains(itemKind)
    }
}

// MARK: - SceneDraft Adapter (PR1 UI Compatibility)

public extension CanonicalTimeline {
    /// Converts scene items to SceneDraft array for UI compatibility.
    /// This is a bridge for PR1 until UI is fully migrated to TimelineItem.
    func toSceneDrafts() -> [SceneDraft] {
        sceneItems.map { item in
            SceneDraft(id: item.id, durationUs: item.durationUs)
        }
    }

    /// Updates a scene item's duration by ID.
    /// - Parameters:
    ///   - sceneId: ID of the scene item to update
    ///   - newDurationUs: New duration in microseconds
    /// - Returns: true if item was found and updated
    @discardableResult
    mutating func updateSceneDuration(sceneId: UUID, newDurationUs: TimeUs) -> Bool {
        guard !tracks.isEmpty,
              tracks[0].kind == .sceneSequence,
              let index = tracks[0].items.firstIndex(where: { $0.id == sceneId }) else {
            return false
        }
        tracks[0].items[index].durationUs = newDurationUs
        return true
    }

    /// Returns scene item by ID.
    func sceneItem(byId id: UUID) -> TimelineItem? {
        sceneItems.first { $0.id == id }
    }
}

// MARK: - Mutable SceneSequence Operations

public extension CanonicalTimeline {
    /// Adds a new scene item to the sceneSequence track.
    /// - Parameters:
    ///   - sceneTypeId: Scene type identifier from SceneLibrary
    ///   - durationUs: Duration in microseconds
    ///   - payloads: Inout reference to payloads registry
    /// - Returns: The created item
    @discardableResult
    mutating func addScene(sceneTypeId: String, durationUs: TimeUs, payloads: inout [UUID: TimelinePayload]) -> TimelineItem {
        let payloadId = UUID()
        payloads[payloadId] = .scene(ScenePayload(sceneTypeId: sceneTypeId))

        let item = TimelineItem(
            id: UUID(),
            payloadId: payloadId,
            kind: .scene,
            startUs: nil,
            durationUs: durationUs
        )

        if !tracks.isEmpty && tracks[0].kind == .sceneSequence {
            tracks[0].items.append(item)
        }

        return item
    }

    /// Removes a scene item by ID.
    /// - Parameter sceneId: ID of the scene to remove
    /// - Returns: The removed item, or nil if not found
    @discardableResult
    mutating func removeScene(sceneId: UUID) -> TimelineItem? {
        guard !tracks.isEmpty,
              tracks[0].kind == .sceneSequence,
              let index = tracks[0].items.firstIndex(where: { $0.id == sceneId }) else {
            return nil
        }
        return tracks[0].items.remove(at: index)
    }

    /// Reorders scenes by moving item from one index to another.
    /// - Parameters:
    ///   - fromIndex: Source index
    ///   - toIndex: Destination index
    mutating func reorderScene(from fromIndex: Int, to toIndex: Int) {
        guard !tracks.isEmpty,
              tracks[0].kind == .sceneSequence,
              fromIndex >= 0,
              fromIndex < tracks[0].items.count,
              toIndex >= 0,
              toIndex < tracks[0].items.count,
              fromIndex != toIndex else {
            return
        }

        let item = tracks[0].items.remove(at: fromIndex)
        tracks[0].items.insert(item, at: toIndex)
    }
}
