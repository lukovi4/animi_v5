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
    /// Relative path to scene folder (contains compiled.tve).
    public let folderPath: String
    /// Relative path to preview image (optional).
    public let previewImagePath: String?

    /// Resolved URL for the scene folder (set after manifest load).
    public var folderURL: URL?

    enum CodingKeys: String, CodingKey {
        case id, order, title, baseDurationUs, folderPath, previewImagePath
    }

    public init(
        id: SceneTypeID,
        order: Int,
        title: String,
        baseDurationUs: TimeUs,
        folderPath: String,
        previewImagePath: String? = nil,
        folderURL: URL? = nil
    ) {
        self.id = id
        self.order = order
        self.title = title
        self.baseDurationUs = baseDurationUs
        self.folderPath = folderPath
        self.previewImagePath = previewImagePath
        self.folderURL = folderURL
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
}
