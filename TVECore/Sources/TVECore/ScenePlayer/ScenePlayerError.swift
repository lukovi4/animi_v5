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

    /// Block is missing the required `no-anim` variant for edit mode
    case missingNoAnimVariant(blockId: String)

    /// The `no-anim` variant is missing the `mediaInput` shape layer
    case noAnimMissingMediaInput(blockId: String, animRef: String)

    /// The `no-anim` variant is missing the binding layer for the given key
    case noAnimMissingBindingLayer(blockId: String, animRef: String, bindingKey: String)

    /// The binding layer in `no-anim` variant is not visible at editFrameIndex
    case noAnimBindingNotVisibleAtEditFrame(blockId: String, animRef: String, editFrameIndex: Int)

    /// The binding layer in `no-anim` variant does not produce any draw commands at edit frame
    /// (e.g. binding is reachable by layer visibility but its precomp container is invisible)
    case noAnimBindingNotRenderedAtEditFrame(blockId: String, animRef: String, editFrameIndex: Int)
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
        case .missingNoAnimVariant(let blockId):
            return "Block '\(blockId)' is missing required 'no-anim' variant for edit mode"
        case .noAnimMissingMediaInput(let blockId, let animRef):
            return "no-anim variant '\(animRef)' for block '\(blockId)' is missing 'mediaInput' shape layer"
        case .noAnimMissingBindingLayer(let blockId, let animRef, let bindingKey):
            return "no-anim variant '\(animRef)' for block '\(blockId)' is missing binding layer '\(bindingKey)'"
        case .noAnimBindingNotVisibleAtEditFrame(let blockId, let animRef, let editFrameIndex):
            return "Binding layer in no-anim variant '\(animRef)' for block '\(blockId)' is not visible at edit frame \(editFrameIndex)"
        case .noAnimBindingNotRenderedAtEditFrame(let blockId, let animRef, let editFrameIndex):
            return "Binding layer in no-anim variant '\(animRef)' for block '\(blockId)' is not rendered at edit frame \(editFrameIndex) (unreachable via precomp chain)"
        }
    }
}
