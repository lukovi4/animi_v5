import Foundation

// MARK: - Scene Library

/// Singleton providing access to the scene library.
/// Loads and caches scene type descriptors from bundle.
@MainActor
public final class SceneLibrary {

    // MARK: - Singleton

    public static let shared = SceneLibrary()

    // MARK: - State

    private var snapshot: SceneLibrarySnapshot?
    private var isLoading = false

    // MARK: - Initialization

    private init() {}

    // MARK: - Public API

    /// Loads the scene library from bundle if not already loaded.
    /// - Returns: Scene library snapshot
    /// - Throws: `SceneLibraryError` on load failure
    public func load() async throws -> SceneLibrarySnapshot {
        if let snapshot = snapshot {
            return snapshot
        }

        guard !isLoading else {
            // Wait for loading to complete (simple polling)
            while isLoading {
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            }
            if let snapshot = snapshot {
                return snapshot
            }
            throw SceneLibraryError.loadFailed("Loading was interrupted")
        }

        isLoading = true
        defer { isLoading = false }

        let loader = BundleSceneLibraryLoader()
        let loadedSnapshot = try loader.load()
        self.snapshot = loadedSnapshot

        #if DEBUG
        print("[SceneLibrary] Loaded \(loadedSnapshot.scenesById.count) scenes, fps=\(loadedSnapshot.fps)")
        #endif

        return loadedSnapshot
    }

    /// Returns cached snapshot or nil if not loaded.
    public var cachedSnapshot: SceneLibrarySnapshot? {
        snapshot
    }

    /// Clears the cached snapshot (for testing).
    public func clearCache() {
        snapshot = nil
    }

    /// Returns scene descriptor by ID from cached snapshot.
    /// Returns nil if library not loaded or scene not found.
    public func scene(byId id: SceneTypeID) -> SceneTypeDescriptor? {
        snapshot?.scene(byId: id)
    }

    /// Returns global FPS from cached snapshot.
    /// Returns 30 as fallback if library not loaded.
    public var fps: Int {
        snapshot?.fps ?? 30
    }
}
