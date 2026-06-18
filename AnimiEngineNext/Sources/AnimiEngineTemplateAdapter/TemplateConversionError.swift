/// Task-003 plan §9, §17 step 7 (Stage-6 correction item 6) — the adapter's **conversion** error
/// domain.
///
/// Every conversion failure is one of these typed cases; there is no `??` fallback, no `[0]` index, no
/// force-unwrap and no trap on the conversion path. Strict selection failures are surfaced as the
/// dedicated ``TemplateVariantSelectionError`` (item 1), animation-policy failures as
/// ``CompiledAnimationConverter/ConversionError``; this enum covers the remaining conversion-level
/// failures.
public enum TemplateConversionError: Error, Equatable, Sendable {
    /// The decoded template's `runtime.scene.sceneId` is missing/empty (item 8 "missing sceneID").
    case missingSceneID
    /// A block authored in the scene had no media binding in the request.
    case missingBlockBinding(blockID: String)
    /// The request named a binding for a block that is not authored in the scene.
    case unknownBlockBinding(blockID: String)
    /// A runtime block matching an authored scene block could not be found (malformed package).
    case missingRuntimeBlock(blockID: String)
    /// The selected runtime variant was absent from the matched runtime block (malformed package).
    case missingRuntimeVariant(blockID: String, variantID: String)
    /// The video binding's trim range was empty or inverted.
    case invalidVideoTrim(blockID: String)
    /// A media/image reference was empty / invalid.
    case invalidMediaReference(blockID: String)
    /// The project frame rate (canvas fps) is not a supported rate.
    case unsupportedFrameRate(fps: Int)
    /// The merged asset index was internally inconsistent (key sets disagreed) for a referenced asset.
    case malformedAssetIndex(blockID: String, assetID: String)
    /// A pathID referenced by the selected AnimIR was absent from the scene-level path registry.
    case danglingPathResource(blockID: String, pathID: Int)
    /// `requiredPostRoll` was negative.
    case negativePostRoll(ticks: Int64)
    /// A video layer cannot supply enough source material to satisfy the requested continuation.
    case insufficientVideoContinuation(blockID: String)
    /// A `becomeInactive` animation cannot satisfy the requested continuation (it would go inactive
    /// before the evaluated end). Images and hold/loop animations satisfy continuation.
    case insufficientAnimationContinuation(blockID: String)
    /// Step-8 corrective (issue #1b): the chosen media fit is not in the block's `fitModesAllowed`.
    case fitModeNotAllowed(blockID: String, chosen: String, allowed: [String])
}
