import AnimiEngineCore

/// Task-003 plan §17 step 7 — conversion of a block's **selected** variant animation into the
/// canonical `AnimationReference` plus its duration policies.
///
/// Only the selected variant's AnimIR is consulted (item 3). The authored duration is taken exactly
/// from the selected scene variant's `defaultDurationFrames` mapped through the exact integer
/// ticks-per-frame; the out-of-range policies are mapped from the scene variant's
/// `ifAnimationShorter`/`ifAnimationLonger` with **no** default and **no** silent repair. A missing,
/// contradictory or unsupported policy is a typed error.
public enum CompiledAnimationConverter {

    /// Typed failures while converting a selected variant's animation (item 3).
    public enum ConversionError: Error, Equatable, Sendable {
        /// The selected scene variant carried no `defaultDurationFrames`, so authored duration is
        /// unknown — there is no default to substitute.
        case missingAuthoredDuration(blockID: String, variantID: String)
        /// The selected scene variant carried no `ifAnimationShorter` policy.
        case missingShorterPolicy(blockID: String, variantID: String)
        /// The selected scene variant carried no `ifAnimationLonger` policy.
        case missingLongerPolicy(blockID: String, variantID: String)
        /// The `ifAnimationLonger` policy is not one this stage supports (v1 supports only `cut`).
        case unsupportedLongerPolicy(blockID: String, variantID: String, policy: String)
        /// The authored duration mapped to a non-positive tick count, which the canonical
        /// `AnimationReference` rejects.
        case nonPositiveAuthoredDuration(blockID: String, variantID: String, frames: Int)
    }

    /// Converts the selected scene variant of `block` into a canonical `AnimationReference`.
    ///
    /// - Parameters:
    ///   - block: the authored scene media block (carries the scene variants with their policies);
    ///   - selectedVariantID: the explicitly chosen variant id (already validated to be authored);
    ///   - ticksPerFrame: the exact integer ticks-per-frame for the project frame rate.
    static func convert(
        block: CompiledMediaBlockDTO,
        selectedVariantID: String,
        ticksPerFrame: Int64
    ) throws -> AnimationReference {
        // The selected variant must be one of the authored scene variants (the inventory proved the
        // selection is valid; this lookup therefore resolves, but we fail closed regardless).
        guard let variant = block.variants.first(where: { $0.variantID == selectedVariantID }) else {
            throw CompiledAnimationConverter.ConversionError.missingAuthoredDuration(
                blockID: block.blockID, variantID: selectedVariantID)
        }

        // Authored duration: exact frames → exact ticks. No default.
        guard let frames = variant.defaultDurationFrames else {
            throw ConversionError.missingAuthoredDuration(blockID: block.blockID, variantID: selectedVariantID)
        }
        guard frames > 0 else {
            throw ConversionError.nonPositiveAuthoredDuration(
                blockID: block.blockID, variantID: selectedVariantID, frames: frames)
        }
        let durationTicks = try CheckedInt64.multiply(Int64(frames), ticksPerFrame, "animation.authoredDuration")

        // Policies: explicit, no default, no silent repair.
        guard let shorter = variant.ifAnimationShorter else {
            throw ConversionError.missingShorterPolicy(blockID: block.blockID, variantID: selectedVariantID)
        }
        guard let longer = variant.ifAnimationLonger else {
            throw ConversionError.missingLongerPolicy(blockID: block.blockID, variantID: selectedVariantID)
        }

        let ifShorter: AnimationShorterPolicy
        switch shorter {
        case .holdLastFrame: ifShorter = .holdLast
        case .loop: ifShorter = .loop
        case .cut: ifShorter = .becomeInactive  // "cut" while shorter ⇒ stop drawing (Task-002 §6.3)
        }

        // v1 longer policy is always `cutAtEvaluationEnd`; any other authored longer policy is
        // unsupported at this stage (fail closed, no default).
        let ifLonger: AnimationLongerPolicy
        switch longer {
        case .cut: ifLonger = .cutAtEvaluationEnd
        case .holdLastFrame, .loop:
            throw ConversionError.unsupportedLongerPolicy(
                blockID: block.blockID, variantID: selectedVariantID, policy: longer.rawValue)
        }

        let authoredDuration = try TickDuration(ticks: durationTicks)
        return try AnimationReference(
            variantID: variant.variantID,
            animationRef: variant.animRef,
            authoredDuration: authoredDuration,
            ifShorter: ifShorter,
            ifLonger: ifLonger
        )
    }
}
