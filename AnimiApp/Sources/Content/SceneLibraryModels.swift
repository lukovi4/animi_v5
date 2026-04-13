import Foundation

// MARK: - Type Aliases

/// Scene type identifier (refers to a scene in SceneLibrary).
public typealias SceneTypeID = String

// MARK: - Canvas Configuration

/// Global canvas configuration for all scenes in the library.
public struct CanvasConfig: Codable, Equatable, Sendable {
    /// Canvas width in pixels.
    public let width: Int
    /// Canvas height in pixels.
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

// MARK: - Scene Type Descriptor

/// Where a scene is allowed to appear.
public enum SceneUsage: String, Codable, Equatable, Sendable {
    /// Shown in the scene catalog picker inside the editor.
    case catalog
    /// Only used as a starter scene for blank projects; hidden from catalog UI.
    case starterOnly
}

/// Describes a single scene type in the library.
public struct SceneTypeDescriptor: Codable, Equatable, Sendable, Identifiable {
    /// Unique scene type identifier.
    public let id: SceneTypeID
    /// Display order in catalog.
    public let order: Int
    /// Display title.
    public let title: String
    /// Base duration from AE in microseconds.
    public let baseDurationUs: TimeUs
    /// Where this scene is allowed to appear. Defaults to `.catalog`.
    public let usage: SceneUsage

    /// Resolved URL for the scene folder (set by loader using convention: Scenes/<id>).
    public var folderURL: URL?

    enum CodingKeys: String, CodingKey {
        case id, order, title, baseDurationUs, usage
    }

    public init(
        id: SceneTypeID,
        order: Int,
        title: String,
        baseDurationUs: TimeUs,
        usage: SceneUsage = .catalog,
        folderURL: URL? = nil
    ) {
        self.id = id
        self.order = order
        self.title = title
        self.baseDurationUs = baseDurationUs
        self.usage = usage
        self.folderURL = folderURL
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(SceneTypeID.self, forKey: .id)
        order = try container.decode(Int.self, forKey: .order)
        title = try container.decode(String.self, forKey: .title)
        baseDurationUs = try container.decode(TimeUs.self, forKey: .baseDurationUs)
        usage = try container.decodeIfPresent(SceneUsage.self, forKey: .usage) ?? .catalog
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(order, forKey: .order)
        try container.encode(title, forKey: .title)
        try container.encode(baseDurationUs, forKey: .baseDurationUs)
        try container.encode(usage, forKey: .usage)
    }
}

// MARK: - Scene Library Manifest

/// Root structure of Scenes/library.json.
public struct SceneLibraryManifest: Codable, Equatable, Sendable {
    /// Global frame rate for all scenes.
    public let fps: Int
    /// Global canvas configuration.
    public let canvas: CanvasConfig
    /// Array of scene descriptors.
    public let scenes: [SceneTypeDescriptor]

    public init(fps: Int, canvas: CanvasConfig, scenes: [SceneTypeDescriptor]) {
        self.fps = fps
        self.canvas = canvas
        self.scenes = scenes
    }
}

// MARK: - Scene Library Snapshot

/// In-memory snapshot of the scene library with resolved URLs.
public struct SceneLibrarySnapshot: Sendable {
    /// Global frame rate.
    public let fps: Int
    /// Global canvas configuration.
    public let canvas: CanvasConfig
    /// Scene descriptors by ID.
    public let scenesById: [SceneTypeID: SceneTypeDescriptor]
    /// Ordered list of scene IDs.
    public let orderedIds: [SceneTypeID]

    public init(fps: Int, canvas: CanvasConfig, scenes: [SceneTypeDescriptor]) {
        self.fps = fps
        self.canvas = canvas
        self.orderedIds = scenes.sorted { $0.order < $1.order }.map(\.id)
        var byId: [SceneTypeID: SceneTypeDescriptor] = [:]
        for scene in scenes {
            byId[scene.id] = scene
        }
        self.scenesById = byId
    }

    /// Returns scene descriptor by ID.
    public func scene(byId id: SceneTypeID) -> SceneTypeDescriptor? {
        scenesById[id]
    }

    /// Returns all scenes sorted by order.
    public var scenesInOrder: [SceneTypeDescriptor] {
        orderedIds.compactMap { scenesById[$0] }
    }

    /// Returns only catalog-visible scenes sorted by order.
    public var catalogScenes: [SceneTypeDescriptor] {
        scenesInOrder.filter { $0.usage == .catalog }
    }
}

// MARK: - Scene Type Default

/// Default scene configuration for initializing a project from a template.
public struct SceneTypeDefault: Equatable, Sendable {
    /// Scene type identifier.
    public let sceneTypeId: SceneTypeID
    /// Base duration from scene library.
    public let baseDurationUs: TimeUs

    public init(sceneTypeId: SceneTypeID, baseDurationUs: TimeUs) {
        self.sceneTypeId = sceneTypeId
        self.baseDurationUs = baseDurationUs
    }
}
