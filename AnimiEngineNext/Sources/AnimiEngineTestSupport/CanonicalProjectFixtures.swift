import Foundation
import AnimiEngineCore

/// Deterministic canonical-project fixtures for Task-002 functional tests (Task-002 plan, §9, §18).
///
/// These builders live in test support. They instantiate template slot descriptors with **explicit
/// fake bindings** and assemble synthetic stress cases (20-video scenes, 10-text overlays, animated
/// transitions). They never load real media; only structural shape and timing come from templates.
public enum CanonicalProjectFixtures {

    // MARK: - Mapping authoring policy → engine policy (strict; corrective plan C-7)

    /// Maps a template's `ifAnimationShorter` string to the engine policy, **reconciling** with the
    /// `loop` flag. Unknown strings throw; contradictory `loop`/policy combinations throw.
    ///
    /// - `loop == false`: `ifAnimationShorter` is taken verbatim; `"loop"` here is contradictory.
    /// - `loop == true`: only `"loop"` is consistent; `holdLastFrame`/`becomeInactive` are contradictory.
    public static func shorterPolicy(_ raw: String, loop: Bool, blockID: String = "", variantID: String = "") throws -> AnimationShorterPolicy {
        let policy: AnimationShorterPolicy
        switch raw {
        case "holdLastFrame": policy = .holdLast
        case "loop": policy = .loop
        case "becomeInactive": policy = .becomeInactive
        default: throw TemplateFixtureReader.ReadError.unknownShorterPolicy(raw)
        }
        let isLoopPolicy = (policy == .loop)
        guard isLoopPolicy == loop else {
            throw TemplateFixtureReader.ReadError.contradictoryLoopPolicy(blockID: blockID, variantID: variantID)
        }
        return policy
    }

    /// Maps a template's `ifAnimationLonger` string to the engine policy. Only `"cut"` is supported.
    public static func longerPolicy(_ raw: String) throws -> AnimationLongerPolicy {
        switch raw {
        case "cut": return .cutAtEvaluationEnd
        default: throw TemplateFixtureReader.ReadError.unknownLongerPolicy(raw)
        }
    }

    /// Exact checked conversion of `defaultDurationFrames` to ticks (no silent 0, no rounding).
    public static func authoredDurationTicks(variant: TemplateVariantDescriptor, frameRate: FrameRate) throws -> TickDuration {
        guard variant.defaultDurationFrames > 0 else { throw TemplateFixtureReader.ReadError.nonPositiveDuration }
        let ticksPerFrame = try frameRate.exactTicksPerFrame
        let ticks = try CheckedInt64.multiply(ticksPerFrame, Int64(variant.defaultDurationFrames), "authoredDuration")
        return try TickDuration(ticks: ticks)
    }

    // MARK: - Primitive builders

    /// A placement covering a rect given in canvas points, identity scale, zero rotation.
    public static func placement(x: Double, y: Double, width: Double, height: Double) throws -> Placement {
        let frame = try FixedRect(
            x: canvasScalar(x), y: canvasScalar(y),
            width: canvasScalar(max(width, 1)), height: canvasScalar(max(height, 1))
        )
        return try Placement(frame: frame, scale: .one, rotation: .zero)
    }

    /// A test ``MediaPlacement`` with an explicit fit mode and optional user transform (step-8
    /// corrective, issue #1).
    public static func mediaPlacement(
        fitMode: MediaFitMode = .contain,
        offsetX: Double = 0, offsetY: Double = 0,
        scale: Int64 = ScaleScalar.unitsPerUnit, rotationDegrees: Double = 0
    ) throws -> MediaPlacement {
        try MediaPlacement(
            fitMode: fitMode,
            userOffsetX: canvasScalar(offsetX), userOffsetY: canvasScalar(offsetY),
            userScale: ScaleScalar(rawValue: scale),
            userRotation: RotationScalar(rawValue: Int64((rotationDegrees * Double(RotationScalar.unitsPerDegree)).rounded())))
    }

    public static func canvasScalar(_ points: Double) -> CanvasScalar {
        CanvasScalar(rawValue: Int64((points * Double(CanvasScalar.unitsPerPoint)).rounded()))
    }

    /// A 1/1 source mapping with trim `[0, trimSeconds)` at the given native timescale.
    public static func sourceMapping(trimSeconds: Int64, nativeTimescale: Int64 = 30_000) throws -> SourceTimeMapping {
        let start = try RationalSourceTime(numerator: 0, denominator: 1)
        let end = try RationalSourceTime(numerator: trimSeconds, denominator: 1)
        let trim = try RationalSourceRange(start: start, end: end)
        return SourceTimeMapping(
            trimRange: trim,
            nativeTimescale: try SourceTimescale(unitsPerSecond: nativeTimescale),
            rate: .oneToOne
        )
    }

    public static func videoLayer(
        id: String,
        zIndex: Int,
        stableOrdinal: Int,
        sceneDurationTicks: Int64,
        media: String,
        trimSeconds: Int64,
        placement: Placement,
        mediaPlacement: MediaPlacement = .identity(fitMode: .contain),
        animation: AnimationReference? = nil
    ) throws -> SceneLayer {
        let range = try ScenePlaybackRange(
            start: .zero, end: try ScenePlaybackTime(ticks: sceneDurationTicks)
        )
        let binding = VideoBinding(
            media: try MediaReference(media),
            sourceMapping: try sourceMapping(trimSeconds: trimSeconds)
        )
        return SceneLayer(
            id: try LayerID(id), zIndex: zIndex, stableOrdinal: stableOrdinal,
            activeRange: range, placement: placement, mediaPlacement: mediaPlacement,
            content: .video(binding), animation: animation
        )
    }

    public static func imageLayer(
        id: String,
        zIndex: Int,
        stableOrdinal: Int,
        sceneDurationTicks: Int64,
        image: String,
        placement: Placement,
        mediaPlacement: MediaPlacement = .identity(fitMode: .contain),
        animation: AnimationReference? = nil
    ) throws -> SceneLayer {
        let range = try ScenePlaybackRange(
            start: .zero, end: try ScenePlaybackTime(ticks: sceneDurationTicks)
        )
        return SceneLayer(
            id: try LayerID(id), zIndex: zIndex, stableOrdinal: stableOrdinal,
            activeRange: range, placement: placement, mediaPlacement: mediaPlacement,
            content: .image(try ImageReference(image)), animation: animation
        )
    }

    public static func holdLastAnimation(authoredTicks: Int64, variant: String = "v1") throws -> AnimationReference {
        try AnimationReference(
            variantID: variant, animationRef: "\(variant).json",
            authoredDuration: try TickDuration(ticks: authoredTicks),
            ifShorter: .holdLast, ifLonger: .cutAtEvaluationEnd
        )
    }

    // MARK: - Template instantiation

    /// Instantiates a template descriptor into a resolved scene payload with explicit fake bindings
    /// (Task-002 plan, §9 step 4–5; corrective plan C-7).
    ///
    /// `selection` is an explicit `[blockID: variantID]` map that **must cover every block**; a missing
    /// block or a variant id not present in that block's authored set is a typed error. No block is
    /// silently defaulted and no variant is silently chosen.
    public static func instantiate(
        _ descriptor: TemplateFixtureDescriptor,
        sceneInstanceID: String,
        payloadID: String,
        selection: [String: String],
        mediaPrefix: String = "fake-media"
    ) throws -> ResolvedScenePayload {
        let templateRef = try TemplateReference(catalogID: descriptor.catalogID, sceneID: descriptor.sceneID)
        let durationTicks = descriptor.duration.ticks
        var layers: [SceneLayer] = []
        for (ordinal, slot) in descriptor.slots.enumerated() {
            let place = try placement(
                x: slot.rect.x, y: slot.rect.y, width: slot.rect.width, height: slot.rect.height
            )
            // Resolve the explicitly-selected variant for this block.
            guard let variantID = selection[slot.blockID] else {
                throw TemplateFixtureReader.ReadError.missingVariantSelection(blockID: slot.blockID)
            }
            guard let variant = slot.variants.first(where: { $0.variantID == variantID }) else {
                throw TemplateFixtureReader.ReadError.unknownVariantSelection(blockID: slot.blockID, variantID: variantID)
            }
            let animation = try slotAnimation(slot: slot, variant: variant, frameRate: descriptor.frameRate)
            let layer = try videoLayer(
                id: "\(sceneInstanceID).\(slot.blockID)",
                zIndex: slot.zIndex,
                stableOrdinal: ordinal,
                sceneDurationTicks: durationTicks,
                media: "\(mediaPrefix)-\(slot.blockID)",
                trimSeconds: 600,                 // generous fake trim so material is always available
                placement: place,
                animation: animation
            )
            layers.append(layer)
        }
        return ResolvedScenePayload(
            payloadID: try ScenePayloadID(payloadID),
            sceneID: try SceneInstanceID(sceneInstanceID),
            templateRef: templateRef,
            layers: layers
        )
    }

    private static func slotAnimation(slot: TemplateSlotDescriptor, variant: TemplateVariantDescriptor, frameRate: FrameRate) throws -> AnimationReference {
        let shorter = try shorterPolicy(
            variant.ifAnimationShorter, loop: variant.loop, blockID: slot.blockID, variantID: variant.variantID
        )
        let longer = try longerPolicy(variant.ifAnimationLonger)
        let authored = try authoredDurationTicks(variant: variant, frameRate: frameRate)
        return try AnimationReference(
            variantID: variant.variantID,
            animationRef: variant.animationRef,
            authoredDuration: authored,
            ifShorter: shorter,
            ifLonger: longer
        )
    }

    // MARK: - Manifest / document assembly

    public static func output(width: Int64 = 1080, height: Int64 = 1920, frameRate: FrameRate = .fps30) throws -> OutputContext {
        OutputContext(canvas: try CanvasSize(width: width, height: height), frameRate: frameRate)
    }

    /// A single-scene document with no transitions or overlays.
    public static func singleSceneDocument(
        payload: ResolvedScenePayload,
        nominalDurationTicks: Int64,
        postRollTicks: Int64 = 0,
        timelineSpanTicks: Int64? = nil,
        output: OutputContext? = nil
    ) throws -> CanonicalProjectDocument {
        let entry = SceneManifestEntry(
            id: payload.sceneID,
            payloadID: payload.payloadID,
            nominalDuration: try TickDuration(ticks: nominalDurationTicks),
            postRollCapability: try TickDuration(ticks: postRollTicks),
            timelineSpan: try timelineSpanTicks.map { try TickDuration(ticks: $0) }
        )
        let manifest = CanonicalProjectManifest(
            schemaVersion: CanonicalProjectManifest.supportedSchemaVersion,
            output: try output ?? CanonicalProjectFixtures.output(),
            scenes: [entry],
            boundaryTransitions: [],
            overlays: []
        )
        return CanonicalProjectDocument(manifest: manifest, scenePayloads: [payload], overlayPayloads: [])
    }

    /// A two-scene document with one boundary transition.
    public static func twoSceneDocument(
        sceneA: ResolvedScenePayload,
        sceneB: ResolvedScenePayload,
        durationATicks: Int64,
        durationBTicks: Int64,
        transition: SceneTransition,
        postRollTicks: Int64,
        overlays: [(OverlayManifestEntry, ResolvedOverlayPayload)] = [],
        output: OutputContext? = nil
    ) throws -> CanonicalProjectDocument {
        let entryA = SceneManifestEntry(
            id: sceneA.sceneID, payloadID: sceneA.payloadID,
            nominalDuration: try TickDuration(ticks: durationATicks),
            postRollCapability: try TickDuration(ticks: postRollTicks)
        )
        let entryB = SceneManifestEntry(
            id: sceneB.sceneID, payloadID: sceneB.payloadID,
            nominalDuration: try TickDuration(ticks: durationBTicks),
            postRollCapability: try TickDuration(ticks: postRollTicks)
        )
        let manifest = CanonicalProjectManifest(
            schemaVersion: CanonicalProjectManifest.supportedSchemaVersion,
            output: try output ?? CanonicalProjectFixtures.output(),
            scenes: [entryA, entryB],
            boundaryTransitions: [transition],
            overlays: overlays.map(\.0)
        )
        return CanonicalProjectDocument(
            manifest: manifest,
            scenePayloads: [sceneA, sceneB],
            overlayPayloads: overlays.map(\.1)
        )
    }

    // MARK: - Synthetic stress builders

    /// A scene payload with `count` video layers, ordered z-index 0..<count.
    public static func scene(withVideoLayers count: Int, sceneID: String, payloadID: String, durationTicks: Int64) throws -> ResolvedScenePayload {
        var layers: [SceneLayer] = []
        for i in 0..<count {
            let place = try placement(x: Double(i), y: 0, width: 100, height: 100)
            layers.append(try videoLayer(
                id: "\(sceneID).layer\(i)", zIndex: i, stableOrdinal: i,
                sceneDurationTicks: durationTicks, media: "media-\(i)", trimSeconds: 600, placement: place
            ))
        }
        return ResolvedScenePayload(
            payloadID: try ScenePayloadID(payloadID),
            sceneID: try SceneInstanceID(sceneID),
            templateRef: try TemplateReference(catalogID: "synthetic", sceneID: sceneID),
            layers: layers
        )
    }

    /// `count` animated text overlays spanning `[0, projectDurationTicks)`, ordered z 0..<count.
    public static func textOverlays(count: Int, projectDurationTicks: Int64) throws -> [(OverlayManifestEntry, ResolvedOverlayPayload)] {
        var result: [(OverlayManifestEntry, ResolvedOverlayPayload)] = []
        for i in 0..<count {
            let overlayID = try OverlayID("overlay\(i)")
            let payloadID = try OverlayPayloadID("overlayPayload\(i)")
            let range = try ProjectTimeRange(
                start: .zero, end: try ProjectTime(ticks: projectDurationTicks)
            )
            let entry = OverlayManifestEntry(
                id: overlayID, payloadID: payloadID, timeRange: range, zIndex: i, stableOrdinal: i
            )
            let place = try placement(x: 0, y: Double(i) * 10, width: 200, height: 50)
            let animation = try holdLastAnimation(authoredTicks: max(projectDurationTicks, 1), variant: "text\(i)")
            let payload = ResolvedOverlayPayload(
                payloadID: payloadID, overlayID: overlayID,
                content: .text(try TextContentReference("text-\(i)")),
                placement: place, animation: animation
            )
            result.append((entry, payload))
        }
        return result
    }

    /// A fade transition with empty parameters and the given duration.
    public static func fadeTransition(durationTicks: Int64, easing: String = "linear") throws -> SceneTransition {
        SceneTransition(
            kind: .animated(TransitionEffect(
                effectID: try TransitionEffectID("fade"),
                parameters: .empty
            )),
            duration: try TickDuration(ticks: durationTicks),
            easing: try EasingReference(easing)
        )
    }

    /// A slide transition with a `direction` identifier and the given duration.
    public static func slideTransition(direction: String, durationTicks: Int64, easing: String = "linear") throws -> SceneTransition {
        let params = try TransitionParameterSet([
            TransitionParameter(key: "direction", value: .identifier(direction))
        ])
        return SceneTransition(
            kind: .animated(TransitionEffect(effectID: try TransitionEffectID("slide"), parameters: params)),
            duration: try TickDuration(ticks: durationTicks),
            easing: try EasingReference(easing)
        )
    }

    /// A cut transition (duration zero).
    public static func cutTransition() throws -> SceneTransition {
        SceneTransition(kind: .cut, duration: .zero, easing: try EasingReference("none"))
    }
}
