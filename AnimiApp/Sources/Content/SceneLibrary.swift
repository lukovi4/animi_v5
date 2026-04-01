import Foundation
import os.log

private let logger = Logger(subsystem: "com.animi.app", category: "SceneLibrary")

// MARK: - Scene Library

/// Singleton providing access to the scene library.
/// Loads and caches scene type descriptors from bundle.
@MainActor
public final class SceneLibrary {

    // MARK: - Singleton

    public static let shared = SceneLibrary()

    // MARK: - State

    private var snapshot: SceneLibrarySnapshot?
    private var loadTask: Task<SceneLibrarySnapshot, Error>?

    // MARK: - Initialization

    private init() {}

    // MARK: - Public API

    /// Loads the scene library from bundle if not already loaded.
    /// Bundle IO runs on a background thread; main actor only caches the result.
    /// Concurrent callers coalesce into a single load operation.
    /// - Returns: Scene library snapshot
    /// - Throws: `SceneLibraryError` on load failure
    public func load() async throws -> SceneLibrarySnapshot {
        if let snapshot = snapshot {
            return snapshot
        }

        // Coalesce concurrent callers into one load
        if let existingTask = loadTask {
            return try await existingTask.value
        }

        loadTask = Task<SceneLibrarySnapshot, Error> {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try BundleSceneLibraryLoader().load()
            }.value
            return loaded
        }

        do {
            let loaded = try await loadTask!.value
            snapshot = loaded
            loadTask = nil

            #if DEBUG
            logger.debug("[SceneLibrary] Loaded \(loaded.scenesById.count) scenes, fps=\(loaded.fps)")
            #endif

            return loaded
        } catch {
            loadTask = nil
            throw error
        }
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
