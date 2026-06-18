/// Task-003 plan §4.1, §9 — typed error domain for the immutable render-material model.
///
/// Every fallible construction in `AnimiEngineRenderModel` throws one of these cases instead of
/// trapping, wrapping, or silently substituting a default (§9: "No layer may silently substitute …").
/// There is no `Float`/`Double` in canonical render state; numeric failures are reported here, not
/// absorbed.
public enum RenderModelError: Error, Equatable, Sendable {
    /// A fixed-point raw value fell outside its type's permitted closed interval.
    case valueOutOfRange(field: String, value: Int64, lowerBound: Int64, upperBound: Int64)

    /// A checked integer operation overflowed while constructing a render-model value.
    case integerOverflow(operation: String)

    /// Pixel dimensions were malformed (non-positive width/height, or a row stride smaller than the
    /// minimum implied by the width and bytes-per-pixel).
    case malformedDimensions(field: String, width: Int64, height: Int64)

    /// The supplied pixel-byte count did not match the count implied by dimensions, stride and the
    /// pixel format (`expected` vs `actual`).
    case pixelByteCountMismatch(expected: Int, actual: Int)

    /// A value used a tag/case that is not supported by the Task-003 contract (e.g. an unknown
    /// colour profile or blend mode at a point where only the pinned set is allowed).
    case unsupportedValue(field: String, value: String)

    /// A required identity was empty or duplicated within an unordered collection that must be keyed
    /// by unique identity (e.g. two materials sharing one id).
    case duplicateIdentity(field: String, value: String)

    /// An empty identifier where a non-empty one is required.
    case emptyIdentifier(field: String)

    /// Two **different** programs were merged under the same `RenderMaterialID` (Stage-6 item 4). Only
    /// value-identical duplicates are allowed to coalesce; a genuine conflict fails closed.
    case conflictingProgram(id: String)

    /// The same `SceneMaterialBindingKey` was bound twice (Stage-6 item 4) — a duplicate scene/layer
    /// binding, which must never silently overwrite.
    case duplicateSceneBinding(sceneID: String, layerID: String)

    /// A scene binding referenced a material id with no corresponding program (dangling binding).
    case danglingSceneBinding(sceneID: String, layerID: String, materialID: String)

    /// Step-8 corrective (issue #4): two pixel inputs share a `PixelInputID` but differ in content.
    case conflictingPixelInput(id: String)
}
