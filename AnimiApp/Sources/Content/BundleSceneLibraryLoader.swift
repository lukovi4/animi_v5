import Foundation
import TVECore

// MARK: - Scene Library Errors

public enum SceneLibraryError: Error, LocalizedError {
    case manifestNotFound
    case decodingFailed(Error)
    case loadFailed(String)
    case sceneNotFound(SceneTypeID)
    case contentCorrupted(String)

    public var errorDescription: String? {
        switch self {
        case .manifestNotFound:
            return "Scene library.json not found in bundle"
        case .decodingFailed(let error):
            return "Failed to decode scene library: \(error.localizedDescription)"
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
/// Validates each scene package is loadable before publishing.
public final class BundleSceneLibraryLoader {

    private let bundle: Bundle
    private let loadabilityProbe: (URL) throws -> Void

    /// - Parameters:
    ///   - bundle: Bundle to load from (default: .main)
    ///   - loadabilityProbe: Validates that a scene folder contains a loadable compiled.tve.
    ///     Default uses `CompiledScenePackageLoader`. Inject a custom closure for testing.
    public init(
        bundle: Bundle = .main,
        loadabilityProbe: @escaping (URL) throws -> Void = BundleSceneLibraryLoader.defaultProbe
    ) {
        self.bundle = bundle
        self.loadabilityProbe = loadabilityProbe
    }

    /// Loads library.json, resolves folder URLs, and validates each scene package is loadable.
    /// - Returns: Scene library snapshot with only loadable scenes
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

        // Resolve folder URLs and validate loadability
        var resolvedScenes: [SceneTypeDescriptor] = []

        for scene in manifest.scenes {
            var resolved = scene

            guard let folderURL = bundle.url(
                forResource: scene.id,
                withExtension: nil,
                subdirectory: "Scenes"
            ) else {
                #if DEBUG
                print("[SceneLibrary] WARNING: Scene '\(scene.id)' folder not found at Scenes/\(scene.id)")
                #endif
                continue
            }

            // Validate compiled.tve is loadable
            do {
                try loadabilityProbe(folderURL)
            } catch {
                #if DEBUG
                print("[SceneLibrary] WARNING: Scene '\(scene.id)' failed loadability probe: \(error)")
                #endif
                continue
            }

            resolved.folderURL = folderURL
            resolvedScenes.append(resolved)

            #if DEBUG
            print("[SceneLibrary] Resolved scene '\(scene.id)' -> \(folderURL.path)")
            #endif
        }

        // Validate at least one loadable scene exists
        guard !resolvedScenes.isEmpty else {
            throw SceneLibraryError.contentCorrupted("No loadable scenes found in library")
        }

        return SceneLibrarySnapshot(
            fps: manifest.fps,
            canvas: manifest.canvas,
            scenes: resolvedScenes
        )
    }
}

// MARK: - Default Loadability Probe

extension BundleSceneLibraryLoader {
    /// Default probe: loads compiled.tve via CompiledScenePackageLoader to validate
    /// magic bytes, format version, IR schema version, and payload decode.
    public static let defaultProbe: (URL) throws -> Void = { folderURL in
        let loader = CompiledScenePackageLoader(engineVersion: TVECore.version)
        _ = try loader.load(from: folderURL)
    }
}
