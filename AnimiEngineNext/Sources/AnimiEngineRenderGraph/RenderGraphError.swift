/// Task-003 plan §4.1, §7.4, §9 — typed error root for deterministic RenderGraph compilation.
///
/// §17 step 8 (Stage-7) adds the fit-resolution and input-resolution failures. The graph
/// compiler/validator, samplers and transition/overlay builders listed in §14.4 are implemented in
/// later steps (§17 step 9+); their cases are added then. Every failure is typed and fail-closed — no
/// layer substitutes a default fit, a placeholder pixel, a default clip or a missing input (§9).
public enum RenderGraphError: Error, Equatable, Sendable {

    // MARK: - Media-fit resolution (§17 step 8, D3-05)

    /// Source presentation dimensions were not strictly positive.
    case invalidSourceDimensions(width: Int, height: Int)
    /// The computed fit scale collapsed to zero or negative on an axis.
    case degenerateFitScale(scaleX: Int64, scaleY: Int64)
    /// The producer container-clip tag was not one of `slotRect`, `slotRectAfterSettle`, `none`.
    case unsupportedContainerClip(tag: String)
    /// `slotRectAfterSettle` was requested, but the settled-slot state is not yet represented (issue
    /// #2): the resolver fails closed rather than guessing a clip for a static frame.
    case unsupportedSettledClip

    // MARK: - Render-input resolution (§17 step 8, §6)

    /// A scene layer / overlay referenced media for which no fixture pixel input was supplied.
    case missingFixturePixels(reference: String)
    /// A scene **media** layer (image / video) had no material binding in the `RenderMaterialTable`, so
    /// its binding-baseline geometry could not be resolved.
    case missingMaterialBinding(sceneID: String, layerID: String)
    /// The supplied fixtures contained a reference that no layer/overlay in the frame plan consumes
    /// (an unused fixture is rejected so the resolved input is exactly complete, never approximate).
    case unusedFixture(reference: String)
    /// Issue #4: a supplied fixture was not in the canonical presentation orientation `.up`.
    case unsupportedFixtureOrientation(reference: String, orientation: String)
    /// Issue #7: the layer's outer placement frame does not equal the program's block canvas rect.
    case placementFrameMismatch(sceneID: String, layerID: String)
    /// Issue #3: the selected program's `animationRef` disagrees with the layer's `AnimationReference`.
    case animationRefMismatch(sceneID: String, layerID: String, programRef: String, layerRef: String)
    /// Issue #3: the layer's `AnimationReference.variantID` disagrees with the selected program variant.
    case animationVariantMismatch(sceneID: String, layerID: String, programVariant: String, layerVariant: String)

    // MARK: - §17 step 9 — graph compilation (transitions, easing, sampling, composition)

    /// An easing identifier was not one of the supported `linear`/`easeInOut`/`none` (D3-07).
    case unsupportedEasing(raw: String)
    /// A transition progress numerator/denominator was non-positive or out of `[0, 1]`.
    case invalidTransitionProgress(numerator: Int64, denominator: Int64)
    /// A transition `effectID` was not one of the supported `fade`/`slide` (§7.3).
    case unsupportedTransitionEffect(effectID: String)
    /// A slide transition's `direction` parameter was missing or not `left`/`right`/`up`/`down`.
    case unsupportedSlideDirection(raw: String)
    /// An animation request referenced a layer with no `AnimationReference`, or vice versa.
    case inconsistentAnimationRequest(sceneID: String, layerID: String, detail: String)
    /// A keyframed track was empty, or its keyframe times were not strictly increasing.
    case malformedTrack(field: String, detail: String)
    /// The layer parent chain contained a cycle.
    case parentCycle(compID: String, layerID: Int)
    /// A matte source→consumer chain referenced a layer already being rendered as a matte source in the
    /// same chain (e.g. A consumes B which consumes A). Detected explicitly by a per-chain visited set,
    /// independent of the depth-64 backstop (final micro-correction #3).
    case matteCycle(compID: String, layerID: Int)
    /// A `parentLayerID` referenced a layer absent from its composition.
    case missingParentLayer(compID: String, layerID: Int, parentLayerID: Int)
    /// A media layer's `RenderBinding` referenced a composition/layer that could not be resolved.
    case ambiguousMediaBinding(sceneID: String, layerID: String, detail: String)
    /// A `RenderLayerContent.precomp` referenced a composition absent from the program.
    case missingComposition(compID: String)
    /// A layer/matte mode value was outside the documented supported set.
    case unsupportedLayerMode(field: String, value: String)
    /// A toggled-off or hidden layer that nonetheless must resolve produced no content (fail closed).
    case missingLayerContent(compID: String, layerID: Int)
    /// An overlay used an animation behavior unsupported for Task-003 static composition.
    case unsupportedOverlayAnimation(overlayID: String, detail: String)
    /// Corrective #4: an authored image layer's asset pixels were not supplied.
    case missingAssetPixels(materialID: String, assetID: String)
    /// Final corrective #6: an authored image layer's `RenderAsset` is missing or has invalid
    /// (non-positive) dimensions, so the pixel→authored-size composition cannot be formed.
    case missingAuthoredAsset(materialID: String, assetID: String, detail: String)
    /// Corrective #9: composition/overlay orders were not dense and unique (0..<n).
    case nonDenseOrder(field: String, detail: String)

    // MARK: - §17 step 9 — independent graph validation (§7.4)

    /// A command referenced a resource id that was never declared.
    case validatorMissingResource(resourceID: String)
    /// Two declared resources shared an id.
    case validatorDuplicateResource(resourceID: String)
    /// The command list violated a required ordering rule.
    case validatorInvalidCommandOrder(detail: String)
    /// A clip/mask/matte scope was not balanced (an unmatched begin/end or crossed nesting).
    case validatorUnbalancedScope(detail: String)
    /// A surface/offscreen dependency referenced a surface not yet declared.
    case validatorInvalidSurfaceDependency(detail: String)
    /// A resource or canvas dimension was non-positive or otherwise invalid.
    case validatorInvalidDimensions(field: String, width: Int64, height: Int64)
    /// A geometry value overflowed the fixed-point range.
    case validatorGeometryOverflow(field: String)
    /// A graph's colour contract disagreed with the configuration's reference contract.
    case validatorColorProfileMismatch(detail: String)
    /// The final linear→sRGB conversion or final output command was missing/misplaced.
    case validatorIncompleteFinalOutput(detail: String)
    /// A mask/matte/blend mode in a command was outside the supported set.
    case validatorUnsupportedMode(field: String, value: String)

    // MARK: - §17 step 11 (Rev-4 §6.4) — masks/mattes/shapes execution-complete compilation

    /// A `RenderMask`/`RenderShapeGroup` referenced a `pathID` absent from the program's path resources.
    case missingPathResource(pathID: Int, field: String)
    /// A path resource could not be matched unambiguously to its animated path, or a contradictory /
    /// non-invariant property (e.g. a `closed` flag changing across keyframes) was found.
    case pathResourceMismatch(pathID: Int, field: String, detail: String)
    /// An authored stroke could not be turned into a valid execution mesh (degenerate, out-of-range
    /// width, exact 180-degree reversal, or unknown cap/join).
    case unsupportedStrokeGeometry(field: String, detail: String)
    /// An isolation surface (mask content / matte source / matte consumer) and its target surface had
    /// mismatched width/height/profile/storage descriptors.
    case validatorSurfaceDescriptorMismatch(resourceID: String, targetSurfaceID: String)
    /// A surface id aliased another role's surface where the contract requires distinct surfaces.
    case validatorSurfaceAlias(resourceID: String)
}
