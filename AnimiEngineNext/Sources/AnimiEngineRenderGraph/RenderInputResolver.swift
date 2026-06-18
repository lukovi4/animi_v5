import AnimiEngineCore
import AnimiEngineRenderModel

/// Task-003 plan §6, §13 row "Input completeness" — the complete render-input resolver (§17 step 8,
/// step-8 corrective). It combines an immutable `FramePlan` with a `RenderMaterialTable` and explicit
/// pre-resolved fixture pixels, producing an immutable `ResolvedFrameInput` (§6). It performs **no IO**.
///
/// Step-8 corrective:
///   * the fit mode + user transform come from each layer's authored `ActiveLayer.mediaPlacement`
///     (issue #1) — there is **no external `fitModes` map**;
///   * the fit baseline is the program's `contentRect`, the clip target its `blockRectCanvas`, and the
///     aperture stays separate (issue #2);
///   * each scene layer is assembled as one indivisible `ResolvedSceneLayerEntry` (program + pixels +
///     placement together), so the result is structurally complete (issue #8);
///   * the selected program is retained whole (issue #3), and the layer's `AnimationReference`
///     (variant id + animation ref) is validated against it.
public enum RenderInputResolver {

    /// A fixture key: the content-addressable identity a layer/overlay resolves against. Video keys
    /// carry the exact rational target (different moments of one video are different inputs, §6).
    public enum FixtureKey: Hashable, Sendable {
        case image(reference: String)
        case video(reference: String, targetNumerator: Int64, targetDenominator: Int64)
        case overlay(reference: String)

        public var canonicalString: String {
            switch self {
            case let .image(reference): return "image\u{1F}\(reference)"
            case let .video(reference, num, den): return "video\u{1F}\(reference)\u{1F}\(num)/\(den)"
            case let .overlay(reference): return "overlay\u{1F}\(reference)"
            }
        }
    }

    public static func resolve(
        framePlan: FramePlan,
        materials: RenderMaterialTable,
        fixtures: [FixtureKey: ResolvedPixelInput]
    ) throws -> ResolvedFrameInput {
        var sceneEntries: [ResolvedSceneLayerEntry] = []
        var overlayEntries: [ResolvedOverlayEntry] = []
        var consumedFixtures = Set<FixtureKey>()

        func resolveSceneLayer(
            _ layer: ActiveLayer, sceneID: SceneInstanceID, role: ResolvedSceneRole
        ) throws {
            let key = ResolvedLayerKey.sceneLayer(sceneID: sceneID, role: role, layerID: layer.layerID)
            let fixtureKey: FixtureKey
            switch layer.content {
            case let .image(imageRef):
                fixtureKey = .image(reference: imageRef.raw)
            case let .video(sourceRequest):
                fixtureKey = .video(
                    reference: sourceRequest.media.raw,
                    targetNumerator: sourceRequest.target.numerator,
                    targetDenominator: sourceRequest.target.denominator)
            }
            guard let pixels = fixtures[fixtureKey] else {
                throw RenderGraphError.missingFixturePixels(reference: fixtureKey.canonicalString)
            }
            try requireCanonicalOrientation(pixels, reference: fixtureKey.canonicalString)
            consumedFixtures.insert(fixtureKey)

            // Retain the selected program whole (issue #3) via the scene binding.
            let bindingKey = SceneMaterialBindingKey(sceneID: sceneID, layerID: layer.layerID)
            guard let program = materials.program(for: bindingKey) else {
                throw RenderGraphError.missingMaterialBinding(sceneID: sceneID.raw, layerID: layer.layerID.raw)
            }

            // Validate the layer's outer placement rect against the program's block canvas rect
            // (issue #7): the layer must sit on exactly the block's canvas rectangle, or the fit/clip
            // geometry the resolver computes would not match what step 9 composes.
            guard layer.placement.frame == program.mediaGeometry.blockRectCanvas else {
                throw RenderGraphError.placementFrameMismatch(
                    sceneID: sceneID.raw, layerID: layer.layerID.raw)
            }
            // Validate the layer's AnimationReference against the selected program (issue #3).
            if let animationReference = layer.animationReference {
                guard animationReference.animationRef == program.animationRef else {
                    throw RenderGraphError.animationRefMismatch(
                        sceneID: sceneID.raw, layerID: layer.layerID.raw,
                        programRef: program.animationRef, layerRef: animationReference.animationRef)
                }
                guard animationReference.variantID == program.variantID else {
                    throw RenderGraphError.animationVariantMismatch(
                        sceneID: sceneID.raw, layerID: layer.layerID.raw,
                        programVariant: program.variantID, layerVariant: animationReference.variantID)
                }
            }

            // Fit against the binding-baseline content rect; clip to the block canvas rect (issue #2).
            // Source dims come from the fixture's presentation-oriented descriptor (issue #5).
            let placement = try MediaFitResolver.resolve(
                contentRect: program.mediaGeometry.contentRect,
                blockRectCanvas: program.mediaGeometry.blockRectCanvas,
                sourceWidthPixels: pixels.dimensions.width,
                sourceHeightPixels: pixels.dimensions.height,
                mediaPlacement: layer.mediaPlacement,
                containerClip: program.mediaGeometry.containerClip)

            sceneEntries.append(try ResolvedSceneLayerEntry(
                key: key, program: program, pixelInput: pixels, placement: placement))
        }

        /// Every supplied fixture must already be in the canonical presentation orientation `.up`
        /// (issue #4); a non-`.up` orientation is a typed failure rather than a silent re-orientation.
        func requireCanonicalOrientation(_ pixels: ResolvedPixelInput, reference: String) throws {
            guard pixels.dimensions.orientation == .up else {
                throw RenderGraphError.unsupportedFixtureOrientation(
                    reference: reference, orientation: pixels.dimensions.orientation.rawValue)
            }
        }

        func resolveSubplan(_ subplan: SceneSubplan, role: ResolvedSceneRole) throws {
            for layer in subplan.layers {
                try resolveSceneLayer(layer, sceneID: subplan.sceneID, role: role)
            }
        }

        switch framePlan.body {
        case let .single(subplan):
            try resolveSubplan(subplan, role: .sole)
        case let .transition(transition):
            try resolveSubplan(transition.outgoing, role: .outgoing)
            try resolveSubplan(transition.incoming, role: .incoming)
        }

        // Overlays are pre-resolved pixel material only (D3-09, §3.1).
        for overlay in framePlan.overlays {
            let key = ResolvedLayerKey.overlay(overlayID: overlay.overlayID)
            let reference: String
            switch overlay.content {
            case let .text(textRef): reference = textRef.raw
            case let .sticker(imageRef): reference = imageRef.raw
            case let .graphic(imageRef): reference = imageRef.raw
            }
            let fixtureKey = FixtureKey.overlay(reference: reference)
            guard let pixels = fixtures[fixtureKey] else {
                throw RenderGraphError.missingFixturePixels(reference: fixtureKey.canonicalString)
            }
            try requireCanonicalOrientation(pixels, reference: fixtureKey.canonicalString)
            consumedFixtures.insert(fixtureKey)
            overlayEntries.append(try ResolvedOverlayEntry(key: key, pixelInput: pixels))
        }

        // Exactly-complete: every supplied fixture must be consumed (no unused/approximate input, §6).
        for suppliedKey in fixtures.keys where !consumedFixtures.contains(suppliedKey) {
            throw RenderGraphError.unusedFixture(reference: suppliedKey.canonicalString)
        }

        return try ResolvedFrameInput(sceneLayers: sceneEntries, overlays: overlayEntries)
    }
}
