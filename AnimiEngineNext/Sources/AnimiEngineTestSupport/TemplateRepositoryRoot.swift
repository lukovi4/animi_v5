import Foundation

/// An **injected** repository-root abstraction (Task-001 plan, correction #5).
///
/// Production logic never depends on `FileManager` CWD or `#file` heuristics to locate templates;
/// the root is always provided explicitly. This keeps `TemplateFixtureIndex` deterministic and
/// independent of where the process runs.
public struct TemplateRepositoryRoot: Sendable {
    /// Absolute URL of the repository root that contains `SceneSources/`.
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The directory holding the source templates: `<root>/SceneSources`.
    public var sceneSourcesURL: URL {
        url.appendingPathComponent("SceneSources", isDirectory: true)
    }

    /// The source directory for a given catalog template id: `<root>/SceneSources/<id>`.
    public func templateDirectoryURL(forCatalogID id: String) -> URL {
        sceneSourcesURL.appendingPathComponent(id, isDirectory: true)
    }
}
