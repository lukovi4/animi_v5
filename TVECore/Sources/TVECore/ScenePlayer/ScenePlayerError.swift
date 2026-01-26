import Foundation

/// Errors that can occur during ScenePlayer operations
public enum ScenePlayerError: Error, Sendable, Equatable {
    /// Animation reference not found in package
    case animRefNotFound(animRef: String, blockId: String)

    /// Failed to compile animation
    case compilationFailed(animRef: String, reason: String)

    /// No variants available for block
    case noVariantsForBlock(blockId: String)

    /// Scene has no media blocks
    case noMediaBlocks

    /// Invalid block timing configuration
    case invalidBlockTiming(blockId: String, startFrame: Int, endFrame: Int)
}

extension ScenePlayerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .animRefNotFound(let animRef, let blockId):
            return "Animation '\(animRef)' not found for block '\(blockId)'"
        case .compilationFailed(let animRef, let reason):
            return "Failed to compile animation '\(animRef)': \(reason)"
        case .noVariantsForBlock(let blockId):
            return "No variants available for block '\(blockId)'"
        case .noMediaBlocks:
            return "Scene has no media blocks"
        case .invalidBlockTiming(let blockId, let startFrame, let endFrame):
            return "Invalid timing for block '\(blockId)': start=\(startFrame), end=\(endFrame)"
        }
    }
}
