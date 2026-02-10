import Foundation
import TVECore

/// Loads and parses scene packages from disk
public final class ScenePackageLoader {
    private let fileManager: FileManager

    /// Creates a new scene package loader
    /// - Parameter fileManager: File manager to use for file operations
    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Loads a scene package from the specified directory
    /// - Parameter rootURL: Root directory of the scene package
    /// - Returns: Loaded scene package with all resolved resources
    /// - Throws: ScenePackageLoadError if loading fails
    public func load(from rootURL: URL) throws -> ScenePackage {
        // Verify root directory exists
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ScenePackageLoadError.invalidPackageStructure(
                reason: "Root path is not a directory: \(rootURL.lastPathComponent)"
            )
        }

        // Load and parse scene.json
        let scene = try loadScene(from: rootURL)

        // Collect and resolve all animation references
        let animFilesByRef = try resolveAnimationFiles(for: scene, in: rootURL)

        // Check for images directory
        let imagesURL = rootURL.appendingPathComponent("images", isDirectory: true)
        var imagesIsDirectory: ObjCBool = false
        let imagesExists = fileManager.fileExists(atPath: imagesURL.path, isDirectory: &imagesIsDirectory)
        let imagesRootURL: URL? = (imagesExists && imagesIsDirectory.boolValue) ? imagesURL : nil

        return ScenePackage(
            rootURL: rootURL,
            scene: scene,
            animFilesByRef: animFilesByRef,
            imagesRootURL: imagesRootURL
        )
    }

    // MARK: - Private Methods

    private func loadScene(from rootURL: URL) throws -> Scene {
        let sceneURL = rootURL.appendingPathComponent("scene.json")

        guard fileManager.fileExists(atPath: sceneURL.path) else {
            throw ScenePackageLoadError.sceneJSONNotFound
        }

        let data: Data
        do {
            data = try Data(contentsOf: sceneURL)
        } catch {
            throw ScenePackageLoadError.sceneJSONReadFailed(reason: error.localizedDescription)
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(Scene.self, from: data)
        } catch let decodingError as DecodingError {
            throw ScenePackageLoadError.sceneJSONDecodeFailed(
                reason: formatDecodingError(decodingError)
            )
        } catch {
            throw ScenePackageLoadError.sceneJSONDecodeFailed(reason: error.localizedDescription)
        }
    }

    private func resolveAnimationFiles(
        for scene: Scene,
        in rootURL: URL
    ) throws -> [String: URL] {
        var animFilesByRef: [String: URL] = [:]

        // Collect all unique animRefs from all variants
        let animRefs = collectAnimRefs(from: scene)

        for animRef in animRefs {
            let resolvedURL = try resolveAnimFile(animRef: animRef, in: rootURL)
            animFilesByRef[animRef] = resolvedURL
        }

        return animFilesByRef
    }

    private func collectAnimRefs(from scene: Scene) -> Set<String> {
        var refs = Set<String>()
        for block in scene.mediaBlocks {
            for variant in block.variants {
                refs.insert(variant.animRef)
            }
        }
        return refs
    }

    private func resolveAnimFile(animRef: String, in rootURL: URL) throws -> URL {
        // Try with the exact reference first
        let directURL = rootURL.appendingPathComponent(animRef)
        if fileManager.fileExists(atPath: directURL.path) {
            return directURL
        }

        // If no extension, try adding .json
        if !animRef.hasSuffix(".json") {
            let withExtension = rootURL.appendingPathComponent("\(animRef).json")
            if fileManager.fileExists(atPath: withExtension.path) {
                return withExtension
            }
        }

        throw ScenePackageLoadError.animFileNotFound(animRef: animRef)
    }

    private func formatDecodingError(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            let path = formatCodingPath(context.codingPath)
            return "Missing key '\(key.stringValue)' at \(path)"

        case .valueNotFound(let type, let context):
            let path = formatCodingPath(context.codingPath)
            return "Missing value of type \(type) at \(path)"

        case .typeMismatch(let type, let context):
            let path = formatCodingPath(context.codingPath)
            return "Type mismatch for \(type) at \(path)"

        case .dataCorrupted(let context):
            let path = formatCodingPath(context.codingPath)
            return "Data corrupted at \(path): \(context.debugDescription)"

        @unknown default:
            return error.localizedDescription
        }
    }

    private func formatCodingPath(_ path: [CodingKey]) -> String {
        if path.isEmpty {
            return "root"
        }
        return path.map { key in
            if let intValue = key.intValue {
                return "[\(intValue)]"
            }
            return key.stringValue
        }.joined(separator: ".")
    }
}
