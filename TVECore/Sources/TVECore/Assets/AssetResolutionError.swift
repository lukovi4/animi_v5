import Foundation

// MARK: - Asset Resolution Stage

/// Stage at which asset resolution failed
public enum AssetResolutionStage: String, Sendable {
    case local
    case shared
}

// MARK: - Asset Resolution Error

/// Errors that can occur during asset resolution (Local → Shared pipeline)
public enum AssetResolutionError: Error, Sendable {
    /// Asset not found in either local or shared index
    case assetNotFound(key: String, stage: AssetResolutionStage)

    /// Duplicate basename found within local package images
    case duplicateBasenameLocal(key: String, url1: URL, url2: URL)

    /// Duplicate basename found within shared assets bundle
    case duplicateBasenameShared(key: String, url1: URL, url2: URL)
}

extension AssetResolutionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .assetNotFound(let key, let stage):
            return "Asset '\(key)' not found (searched up to \(stage.rawValue) stage)"
        case .duplicateBasenameLocal(let key, let url1, let url2):
            return "Duplicate basename '\(key)' in local assets: \(url1.lastPathComponent) vs \(url2.lastPathComponent)"
        case .duplicateBasenameShared(let key, let url1, let url2):
            return "Duplicate basename '\(key)' in shared assets: \(url1.lastPathComponent) vs \(url2.lastPathComponent)"
        }
    }
}
