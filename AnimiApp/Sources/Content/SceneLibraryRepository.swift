import Foundation

/// Abstracts access to the scene library for feature controllers.
/// Feature code depends on this protocol, not on `SceneLibrary.shared`.
@MainActor
protocol SceneLibraryProviding {
    func load() async throws -> SceneLibrarySnapshot
    var cachedSnapshot: SceneLibrarySnapshot? { get }
    func scene(byId id: SceneTypeID) -> SceneTypeDescriptor?
    var fps: Int { get }
}

/// Singleton-backed implementation. The singleton lives inside this adapter only.
@MainActor
final class SceneLibraryRepository: SceneLibraryProviding {

    private let library: SceneLibrary

    init(library: SceneLibrary = .shared) {
        self.library = library
    }

    func load() async throws -> SceneLibrarySnapshot {
        try await library.load()
    }

    var cachedSnapshot: SceneLibrarySnapshot? {
        library.cachedSnapshot
    }

    func scene(byId id: SceneTypeID) -> SceneTypeDescriptor? {
        library.scene(byId: id)
    }

    var fps: Int {
        library.fps
    }
}
