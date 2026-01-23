import Foundation

/// Errors that can occur when loading a scene package
public enum ScenePackageLoadError: Error, Equatable, Sendable {
    /// scene.json file was not found in the package root
    case sceneJSONNotFound

    /// Failed to read scene.json file
    case sceneJSONReadFailed(reason: String)

    /// Failed to decode scene.json into Scene model
    case sceneJSONDecodeFailed(reason: String)

    /// Referenced animation file was not found
    case animFileNotFound(animRef: String)

    /// Package structure is invalid
    case invalidPackageStructure(reason: String)
}

// MARK: - LocalizedError

extension ScenePackageLoadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .sceneJSONNotFound:
            return "scene.json not found in package root"

        case .sceneJSONReadFailed(let reason):
            return "Failed to read scene.json: \(reason)"

        case .sceneJSONDecodeFailed(let reason):
            return "Failed to decode scene.json: \(reason)"

        case .animFileNotFound(let animRef):
            return "Animation file not found: \(animRef)"

        case .invalidPackageStructure(let reason):
            return "Invalid package structure: \(reason)"
        }
    }
}

// MARK: - CustomStringConvertible

extension ScenePackageLoadError: CustomStringConvertible {
    public var description: String {
        errorDescription ?? "Unknown ScenePackageLoadError"
    }
}
