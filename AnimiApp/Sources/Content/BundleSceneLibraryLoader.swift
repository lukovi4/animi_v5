import Foundation

// MARK: - Scene Library Errors

public enum SceneLibraryError: Error, LocalizedError {
    case manifestNotFound
    case decodingFailed(Error)
    case invalidPath(String)
    case loadFailed(String)
    case sceneNotFound(SceneTypeID)
    case contentCorrupted(String)

    public var errorDescription: String? {
        switch self {
        case .manifestNotFound:
            return "Scene library.json not found in bundle"
        case .decodingFailed(let error):
            return "Failed to decode scene library: \(error.localizedDescription)"
        case .invalidPath(let path):
            return "Invalid scene path: \(path)"
        case .loadFailed(let reason):
            return "Failed to load scene library: \(reason)"
        case .sceneNotFound(let id):
            return "Scene type not found: \(id)"
        case .contentCorrupted(let reason):
            return "Content corrupted: \(reason)"
        }
    }
}

// MARK: - Bundle Scene Library Loader

/// Loads scene library from app bundle.
public final class BundleSceneLibraryLoader {

    private let bundle: Bundle

    public init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    /// Loads library.json and resolves all folder URLs.
    /// - Returns: Scene library snapshot with resolved URLs
    /// - Throws: `SceneLibraryError` on failure
    public func load() throws -> SceneLibrarySnapshot {
        // Find library.json in Scenes/
        guard let manifestURL = bundle.url(
            forResource: "library",
            withExtension: "json",
            subdirectory: "Scenes"
        ) else {
            #if DEBUG
            print("[SceneLibrary] ERROR: library.json not found in Scenes/")
            #endif
            throw SceneLibraryError.manifestNotFound
        }

        #if DEBUG
        print("[SceneLibrary] Found manifest at: \(manifestURL.path)")
        #endif

        // Decode manifest
        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        let manifest: SceneLibraryManifest
        do {
            manifest = try decoder.decode(SceneLibraryManifest.self, from: data)
        } catch {
            throw SceneLibraryError.decodingFailed(error)
        }

        // Resolve folder URLs for each scene
        var resolvedScenes: [SceneTypeDescriptor] = []

        for scene in manifest.scenes {
            var resolved = scene

            // Extract folder name from path (e.g., "Scenes/example_4blocks" -> "example_4blocks")
            let folderName = (scene.folderPath as NSString).lastPathComponent
            let parentDir = (scene.folderPath as NSString).deletingLastPathComponent

            if let folderURL = bundle.url(
                forResource: folderName,
                withExtension: nil,
                subdirectory: parentDir.isEmpty ? nil : parentDir
            ) {
                resolved.folderURL = folderURL
                resolvedScenes.append(resolved)

                #if DEBUG
                print("[SceneLibrary] Resolved scene '\(scene.id)' -> \(folderURL.path)")
                #endif
            } else {
                #if DEBUG
                print("[SceneLibrary] WARNING: Scene '\(scene.id)' folder not found at \(scene.folderPath)")
                #endif
                // Skip scenes with missing folders
            }
        }

        // Validate at least one scene exists
        guard !resolvedScenes.isEmpty else {
            throw SceneLibraryError.contentCorrupted("No valid scenes found in library")
        }

        return SceneLibrarySnapshot(
            fps: manifest.fps,
            canvas: manifest.canvas,
            scenes: resolvedScenes
        )
    }
}
