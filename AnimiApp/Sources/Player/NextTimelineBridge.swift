#if DEBUG
import Foundation
import Metal

import AnimiEngineCore
import AnimiEngineRenderModel
import AnimiEngineTemplateAdapter
import AnimiEngineRenderGraph
import AnimiEngineMetalRender

// MARK: - CP5: AnimiEngineNext MULTI-SCENE timeline preview bridge (DEBUG only)
//
// Renders ONE frame of a MULTI-SCENE timeline (cut/fade/slide/push/dip) through AnimiEngineNext,
// end to end:
//   per scene: compiled.tve -> decode -> photo + authored-asset pixels   (reuses CP4 NextSingleSceneBridge)
//   assemble : N per-scene CanonicalProjectDocuments + boundary SceneTransitions
//              -> ONE multi-scene CanonicalProjectManifest/Document        (canonical evaluator owns
//                 the transition window + EXACT RATIONAL progress — no app-side Double progress)
//   per frame: EvaluationWindow + TimelineEvaluator  -> FramePlan (.single | .transition)
//              -> RenderInputResolver.resolve (per-scene fixtures, namespaced references)
//              -> graft authored-asset pixels
//              -> RenderGraphCompiler.compile (renders both scenes to surfaces + emits fade/slide)
//              -> MetalRenderSession.execute  -> one composited BGRA8 RenderedFrame
//
// DEBUG-only. Fail-closed: any unsupported input (multi-scene mapping gap, missing media, unsupported
// media kind) throws a typed `NextBridgeError`/`NextTransitionMappingError` — NO silent fallback.
//
// Boundaries after CP7: photo + user-video media are supported; background/text/sticker parity remain
// out of scope and fail closed before reaching here. The AnimiEngineNext schema is NOT changed for
// CP7 video media.

/// The app-supplied description of one timeline scene instance for CP5: its CP4-style per-scene
/// inputs (scene type, folder, variant, photo blocks) plus the boundary transition to the NEXT scene
/// (nil for the last scene). The timeline fps is the v1 product constant.
struct NextBridgeTimelineScene {
    /// Per-scene inputs (reuses the CP4 single-scene input shape; identity is assigned by the bridge).
    let scene: NextBridgeInputs
    /// The boundary transition from THIS scene to the next (nil for the final scene).
    let transitionToNext: NextBridgeTransition?
}

/// The full multi-scene timeline the bridge must render: the ordered scenes, the NOMINAL project
/// frame to render (cumulative nominal scene frames, NOT app-compressed — the canonical evaluator
/// applies its own boundary compression), and the timeline fps.
struct NextBridgeTimelineInputs {
    let scenes: [NextBridgeTimelineScene]
    /// NOMINAL project frame: 0 ..< sum(nominal scene frames). Mapped app-side from the compressed
    /// playhead via `TimelinePlayheadMapper.nominalFrame(forCompressedFrame:)`.
    let nominalFrameIndex: Int
    let fps: Int
}

/// A prepared multi-scene timeline context: the merged canonical document/materials, the evaluation
/// window, the combined per-reference media pixels, the deduplicated authored-asset entries, the
/// render configuration, the shared session, and the total nominal frame count. Frame INDEX is the
/// only per-render variable.
final class NextTimelinePreparedContext {
    let materials: RenderMaterialTable
    let window: EvaluationWindow
    /// STATIC per-scene photo pixels keyed by namespaced reference (video references are absent here).
    let mediaPixelsByReference: [String: ResolvedPixelInput]
    /// CP7: per-frame video resolvers keyed by namespaced reference. Empty for photo-only timelines.
    let videoResolversByReference: [String: NextVideoBlockResolver]
    let assetEntries: [ResolvedAssetPixelEntry]
    let configuration: RenderConfiguration
    let session: MetalRenderSession
    let totalFrames: Int

    init(materials: RenderMaterialTable, window: EvaluationWindow,
         mediaPixelsByReference: [String: ResolvedPixelInput],
         videoResolversByReference: [String: NextVideoBlockResolver] = [:],
         assetEntries: [ResolvedAssetPixelEntry],
         configuration: RenderConfiguration, session: MetalRenderSession, totalFrames: Int) {
        self.materials = materials; self.window = window
        self.mediaPixelsByReference = mediaPixelsByReference
        self.videoResolversByReference = videoResolversByReference
        self.assetEntries = assetEntries
        self.configuration = configuration; self.session = session; self.totalFrames = totalFrames
    }

    /// CP7.7-next: output canvas pixel size for the GPU-direct preview render target.
    var canvasPixelSize: (width: Int, height: Int) {
        (Int(configuration.output.canvas.width), Int(configuration.output.canvas.height))
    }
}

enum NextTimelineBridge {

    // MARK: - Decode (heavy, placement-INDEPENDENT — one decoded media per scene instance)

    /// Decode every scene's media ONCE (reuses CP4 `NextSingleSceneBridge.decodeMedia`). Each scene
    /// is decoded under a UNIQUE namespace identity so its references/material keys never collide
    /// with another scene's. The post-roll for each scene is the OUTGOING side of its boundary
    /// transition, supplied at decode time so layer active ranges match the render.
    static func decodeTimeline(_ inputs: NextBridgeTimelineInputs) throws -> [NextDecodedMedia] {
        guard inputs.scenes.count >= 1 else { throw NextBridgeError.noScene }
        guard inputs.scenes.count >= 2 else {
            // CP5 is the MULTI-scene path. A single scene must use the CP4 single-scene bridge.
            throw NextBridgeError.multiSceneUnsupported(sceneItemCount: inputs.scenes.count)
        }
        var decoded: [NextDecodedMedia] = []
        for (i, ts) in inputs.scenes.enumerated() {
            // Post-roll the OUTGOING scene must support for the boundary to the NEXT scene.
            let postRoll = try ts.transitionToNext.map { try NextTransitionMapping.postRollTicks($0, fps: inputs.fps).ticks } ?? 0
            var sceneInputs = ts.scene
            sceneInputs.identity = .cp5Timeline(index: i)
            sceneInputs.postRollTicks = postRoll
            decoded.append(try NextSingleSceneBridge.decodeMedia(sceneInputs))
        }
        return decoded
    }

    // MARK: - Assemble (light, placement-DEPENDENT — merges per-scene conversions)

    /// Build a multi-scene prepared context for the current per-scene placements, REUSING decoded
    /// media. Converts each scene, then merges them into ONE canonical document with the mapped
    /// boundary transitions; the canonical evaluator owns the transition window + rational progress.
    static func assembleTimeline(
        decoded: [NextDecodedMedia], inputs: NextBridgeTimelineInputs, sessionBox: NextSessionBox
    ) throws -> NextTimelinePreparedContext {
        guard decoded.count == inputs.scenes.count, decoded.count >= 2 else {
            throw NextBridgeError.multiSceneUnsupported(sceneItemCount: decoded.count)
        }

        // 1. Convert each scene with its current placements (reuses decoded pixels).
        var conversions: [NextSingleSceneBridge.NextSceneConversion] = []
        for (i, dec) in decoded.enumerated() {
            let placementByBlockID = Dictionary(uniqueKeysWithValues:
                inputs.scenes[i].scene.blocks.map { ($0.blockID, $0.placement) })
            conversions.append(try NextSingleSceneBridge.convertScene(decoded: dec, placementByBlockID: placementByBlockID))
        }

        // 2. Output context must be consistent across scenes (same canvas/frame rate). Fail closed
        //    if a scene differs — mixing canvases is not a CP5 capability.
        let firstOutput = conversions[0].output.document.manifest.output
        for conv in conversions.dropFirst() {
            guard conv.output.document.manifest.output == firstOutput else {
                throw NextBridgeError.engine("timeline scenes have inconsistent output contexts (canvas/frame rate mismatch)")
            }
        }

        // 3. Map app boundary transitions (n-1) to canonical SceneTransitions. push/dip* fail closed.
        //    (Fully qualified — the app declares its own `SceneTransition`.)
        var boundaryTransitions: [AnimiEngineCore.SceneTransition] = []
        for i in 0..<(inputs.scenes.count - 1) {
            guard let appT = inputs.scenes[i].transitionToNext else {
                // A missing boundary is an instant cut (no animation) — canonical `.cut`.
                boundaryTransitions.append(AnimiEngineCore.SceneTransition(
                    kind: .cut, duration: .zero, easing: try EasingReference("none")))
                continue
            }
            boundaryTransitions.append(try NextTransitionMapping.map(appT, fps: inputs.fps))
        }

        // 4. Merge per-scene manifests into ONE multi-scene manifest/document. Scene entries +
        //    payloads are kept per scene (namespaced by scene instance id). Material tables are merged
        //    via `RenderMaterialTable.merging`, which deduplicates identical programs (two scenes of
        //    the same template+variant share an IDENTICAL placement-independent program; the per-scene
        //    MEDIA differs only via the per-scene reference/fixture) and keeps all scene bindings.
        var sceneEntries: [SceneManifestEntry] = []
        var scenePayloads: [ResolvedScenePayload] = []
        var mediaPixelsByReference: [String: ResolvedPixelInput] = [:]
        var videoResolversByReference: [String: NextVideoBlockResolver] = [:]
        var assetByKey: [ResolvedAssetKey: ResolvedPixelInput] = [:]
        var materials = conversions[0].output.materials

        for (i, conv) in conversions.enumerated() {
            let doc = conv.output.document
            // Exactly one scene per per-scene conversion.
            guard doc.manifest.scenes.count == 1, doc.scenePayloads.count == 1 else {
                throw NextBridgeError.engine("per-scene conversion produced \(doc.manifest.scenes.count) scenes")
            }
            sceneEntries.append(doc.manifest.scenes[0])
            scenePayloads.append(doc.scenePayloads[0])

            // Merge material programs (dedup identical) + ALL scene bindings (namespaced per scene).
            // The first table seeds `materials`; merge each subsequent one.
            if i > 0 {
                do { materials = try materials.merging(conv.output.materials) }
                catch { throw NextBridgeError.engine("merge materials: \(error)") }
            }

            // Merge media pixels (per-scene namespaced references never collide).
            for (ref, pix) in conv.mediaPixelsByReference { mediaPixelsByReference[ref] = pix }
            // CP7: merge per-scene video resolvers (namespaced references never collide).
            for (ref, resolver) in conv.videoResolversByReference { videoResolversByReference[ref] = resolver }

            // Merge authored-asset pixels. Keys are (materialID, assetID); shared programs ⇒ identical
            // asset, so coalescing is safe (dedup, do not duplicate).
            for entry in conv.assetEntries { assetByKey[entry.key] = entry.pixelInput }
        }

        let manifest = CanonicalProjectManifest(
            schemaVersion: CanonicalProjectManifest.supportedSchemaVersion,
            output: firstOutput, scenes: sceneEntries,
            boundaryTransitions: boundaryTransitions, overlays: [])
        let document = CanonicalProjectDocument(
            manifest: manifest, scenePayloads: scenePayloads, overlayPayloads: [])

        let (window, totalFrames) = try buildWindow(document)

        let configuration: RenderConfiguration
        do {
            configuration = try RenderConfiguration(
                output: firstOutput, colorContract: .task003, intermediateProfile: .rgba16FloatLinear)
        } catch { throw NextBridgeError.engine("config: \(error)") }

        let assetEntries = assetByKey.map { ResolvedAssetPixelEntry(key: $0.key, pixelInput: $0.value) }

        return NextTimelinePreparedContext(
            materials: materials, window: window, mediaPixelsByReference: mediaPixelsByReference,
            videoResolversByReference: videoResolversByReference,
            assetEntries: assetEntries, configuration: configuration,
            session: sessionBox.session, totalFrames: totalFrames)
    }

    // MARK: - Test seam (DEBUG, internal): canonical window + structure without a Metal session

    /// The assembled canonical timeline STRUCTURE: the evaluation window, the per-scene instance ids
    /// (in timeline order), per-scene nominal frame counts, total frames, and fps. Used by the
    /// playhead↔window alignment test to evaluate `TimelineEvaluator` directly (no rendering).
    struct NextTimelineStructure {
        let window: EvaluationWindow
        let sceneInstanceIDs: [String]      // canonical scene instance ids in order
        let sceneNominalFrames: [Int]       // per-scene nominal frame count
        let totalFrames: Int
        let fps: Int
    }

    /// Build the canonical multi-scene window + structure from decoded media + inputs, WITHOUT a
    /// session (no Metal). Mirrors `assembleTimeline` steps 1–4 exactly (same document), so the window
    /// it returns is byte-identical to the one the real render path evaluates.
    static func buildTimelineStructureForTesting(
        decoded: [NextDecodedMedia], inputs: NextBridgeTimelineInputs
    ) throws -> NextTimelineStructure {
        guard decoded.count == inputs.scenes.count, decoded.count >= 2 else {
            throw NextBridgeError.multiSceneUnsupported(sceneItemCount: decoded.count)
        }
        var conversions: [NextSingleSceneBridge.NextSceneConversion] = []
        for (i, dec) in decoded.enumerated() {
            let placementByBlockID = Dictionary(uniqueKeysWithValues:
                inputs.scenes[i].scene.blocks.map { ($0.blockID, $0.placement) })
            conversions.append(try NextSingleSceneBridge.convertScene(decoded: dec, placementByBlockID: placementByBlockID))
        }
        let firstOutput = conversions[0].output.document.manifest.output

        var boundaryTransitions: [AnimiEngineCore.SceneTransition] = []
        for i in 0..<(inputs.scenes.count - 1) {
            guard let appT = inputs.scenes[i].transitionToNext else {
                boundaryTransitions.append(AnimiEngineCore.SceneTransition(
                    kind: .cut, duration: .zero, easing: try EasingReference("none")))
                continue
            }
            boundaryTransitions.append(try NextTransitionMapping.map(appT, fps: inputs.fps))
        }

        var sceneEntries: [SceneManifestEntry] = []
        var scenePayloads: [ResolvedScenePayload] = []
        var sceneInstanceIDs: [String] = []
        var sceneNominalFrames: [Int] = []
        let tpf = try NextTransitionMapping.ticksPerFrame(fps: inputs.fps)
        for conv in conversions {
            let doc = conv.output.document
            guard doc.manifest.scenes.count == 1, doc.scenePayloads.count == 1 else {
                throw NextBridgeError.engine("per-scene conversion produced \(doc.manifest.scenes.count) scenes")
            }
            let entry = doc.manifest.scenes[0]
            sceneEntries.append(entry)
            scenePayloads.append(doc.scenePayloads[0])
            sceneInstanceIDs.append(entry.id.raw)
            sceneNominalFrames.append(Int(entry.nominalDuration.ticks / tpf))
        }

        let manifest = CanonicalProjectManifest(
            schemaVersion: CanonicalProjectManifest.supportedSchemaVersion,
            output: firstOutput, scenes: sceneEntries,
            boundaryTransitions: boundaryTransitions, overlays: [])
        let document = CanonicalProjectDocument(
            manifest: manifest, scenePayloads: scenePayloads, overlayPayloads: [])
        let (window, totalFrames) = try buildWindow(document)

        return NextTimelineStructure(
            window: window, sceneInstanceIDs: sceneInstanceIDs,
            sceneNominalFrames: sceneNominalFrames, totalFrames: totalFrames, fps: inputs.fps)
    }

    // MARK: - Per-frame render (light)

    static func renderFrameBGRA(context ctx: NextTimelinePreparedContext, frameIndex: Int) throws -> NextBridgeBGRAFrame {
        let frame = try renderFrame(context: ctx, frameIndex: frameIndex)
        return NextBridgeBGRAFrame(
            bytes: frame.bytes, width: frame.dimensions.width,
            height: frame.dimensions.height, bytesPerRow: frame.dimensions.bytesPerRow)
    }

    static func renderFrame(context ctx: NextTimelinePreparedContext, frameIndex: Int) throws -> RenderedFrame {
        let graph = try buildGraph(context: ctx, frameIndex: frameIndex)
        do { return try ctx.session.execute(graph) }
        catch { throw NextBridgeError.engine("execute: \(error)") }
    }

    /// CP7.6a — GPU-direct: render ONE timeline frame DIRECTLY into a caller-supplied external texture
    /// (no CPU readback). Reuses the IDENTICAL evaluate→resolve→compile logic via `buildGraph`.
    static func renderFrame(
        context ctx: NextTimelinePreparedContext, frameIndex: Int,
        into target: MTLTexture, alphaMode: AlphaMode
    ) throws {
        let graph = try buildGraph(context: ctx, frameIndex: frameIndex)
        do { try ctx.session.render(graph, into: GPURenderTarget(texture: target, alphaMode: alphaMode)) }
        catch { throw NextBridgeError.engine("render(into:): \(error)") }
    }

    /// CP7.7-next PREVIEW GPU-direct entry (timeline). Mirrors `NextSingleSceneBridge.renderFramePreview`.
    static func renderFramePreview(context ctx: NextTimelinePreparedContext, frameIndex: Int, into target: MTLTexture) throws {
        try renderFrame(context: ctx, frameIndex: frameIndex, into: target, alphaMode: .preserveAlpha)
    }

    /// The shared per-frame timeline graph build (evaluate→resolve→compile). Used by BOTH the readback
    /// path (`renderFrame`/`renderFrameBGRA`, preview + tests) and the GPU-direct path (export).
    static func buildGraph(context ctx: NextTimelinePreparedContext, frameIndex: Int) throws -> RenderGraph {
        let plan: FramePlan
        do { plan = try TimelineEvaluator.evaluate(ctx.window, atFrame: try FrameIndex(value: Int64(max(0, frameIndex)))) }
        catch { throw NextBridgeError.engine("evaluate: \(error)") }

        // Subplans participating in this frame, with their canonical resolved roles.
        let subplans: [(SceneSubplan, ResolvedSceneRole)]
        switch plan.body {
        case let .single(s):
            subplans = [(s, .sole)]
        case let .transition(t):
            subplans = [(t.outgoing, .outgoing), (t.incoming, .incoming)]
        }

        // CP7: resolve any video references PER participating subplan at THAT subplan's scene-local
        // time. In a transition the outgoing and incoming scenes have DIFFERENT scene-local times, so
        // each video frame must be sampled at its own subplan's time (not the shared project frame).
        var mediaPixels = ctx.mediaPixelsByReference
        if !ctx.videoResolversByReference.isEmpty {
            for (subplan, _) in subplans {
                let perScene = try NextSingleSceneBridge.mergeVideoPixels(
                    subplan: subplan, staticPixels: [:], videoResolvers: ctx.videoResolversByReference)
                for (ref, pix) in perScene { mediaPixels[ref] = pix }
            }
        }

        // Build fixtures for EVERY participating scene reference (per-scene namespaced). Every bound
        // media reference present in the plan must have pixels; every supplied fixture must be used.
        let fixtures = try buildFixtures(subplans: subplans, mediaPixelsByReference: mediaPixels)

        let base: ResolvedFrameInput
        do { base = try RenderInputResolver.resolve(framePlan: plan, materials: ctx.materials, fixtures: fixtures) }
        catch { throw NextBridgeError.engine("resolve: \(error)") }

        // Graft authored-asset pixels (RenderInputResolver.resolve carries no asset pixels). Rebuild
        // the frame input from every participating subplan's resolved scene layers + asset entries.
        let resolved = try rebuildWithAssetEntries(subplans: subplans, base: base, assetEntries: ctx.assetEntries)

        do { return try RenderGraphCompiler.compile(plan: plan, input: resolved, configuration: ctx.configuration) }
        catch { throw NextBridgeError.engine("compile: \(error)") }
    }

    // MARK: - Helpers

    private static func buildWindow(_ document: CanonicalProjectDocument) throws -> (window: EvaluationWindow, totalFrames: Int) {
        do {
            let index = try TimelineIndex(manifest: document.manifest)
            let duration = try document.manifest.projectDuration()
            let coverage = try ProjectTimeRange(start: .zero, end: try ProjectTime(ticks: duration.ticks))
            let requirement = try index.requirements(for: coverage)
            let window = try EvaluationWindowBuilder.build(
                requirement: requirement, scenes: document.scenePayloads, overlays: document.overlayPayloads)
            let fr = document.manifest.output.frameRate
            let frames = Int((duration.ticks &* fr.numerator) / (Int64(TickClock.ticksPerSecond) &* fr.denominator))
            return (window, max(1, frames))
        } catch { throw NextBridgeError.engine("window: \(error)") }
    }

    /// Build fixtures for ONLY the scene references that actually participate in THIS frame's
    /// subplans. A single-scene frame uses one scene's references; a transition frame uses both. We
    /// must NOT supply other scenes' fixtures — `RenderInputResolver.resolve` rejects any unused
    /// fixture (exactly-complete contract). Conversely, every `.image` reference present in the plan
    /// MUST have decoded pixels, or the bridge fails closed (never a silently missing photo).
    private static func buildFixtures(
        subplans: [(SceneSubplan, ResolvedSceneRole)], mediaPixelsByReference: [String: ResolvedPixelInput]
    ) throws -> [RenderInputResolver.FixtureKey: ResolvedPixelInput] {
        var fixtures: [RenderInputResolver.FixtureKey: ResolvedPixelInput] = [:]
        var missing: [String] = []
        for (subplan, _) in subplans {
            for layer in subplan.layers {
                guard case let .image(ref) = layer.content else { continue }
                guard let pixels = mediaPixelsByReference[ref.raw] else {
                    missing.append(ref.raw)
                    continue
                }
                fixtures[.image(reference: ref.raw)] = pixels
            }
        }
        guard missing.isEmpty else {
            throw NextBridgeError.unsupportedFramePlan(
                "media reference(s) in frame plan have no decoded pixels: \(missing.sorted())")
        }
        return fixtures
    }

    /// Rebuild a per-frame `ResolvedFrameInput` from the base resolve (per-scene layers, correct
    /// roles) + cached authored-asset entries. Mirrors the CP4 single-scene rebuild but walks ALL
    /// participating subplans (sole / outgoing / incoming). A media layer with no resolved
    /// program/placement/pixels fails closed (never silently dropped).
    private static func rebuildWithAssetEntries(
        subplans: [(SceneSubplan, ResolvedSceneRole)], base: ResolvedFrameInput, assetEntries: [ResolvedAssetPixelEntry]
    ) throws -> ResolvedFrameInput {
        var sceneLayers: [ResolvedSceneLayerEntry] = []
        var dropped: [String] = []
        for (subplan, role) in subplans {
            for layer in subplan.layers {
                let key = ResolvedLayerKey.sceneLayer(sceneID: subplan.sceneID, role: role, layerID: layer.layerID)
                guard let program = base.program(for: key),
                      let placement = base.mediaPlacement(for: key),
                      let pixels = base.pixelInput(for: key) else {
                    dropped.append("\(subplan.sceneID.raw)/\(role.rawValue)/\(layer.layerID.raw)")
                    continue
                }
                sceneLayers.append(try ResolvedSceneLayerEntry(
                    key: key, program: program, pixelInput: pixels, placement: placement))
            }
        }
        guard dropped.isEmpty else {
            throw NextBridgeError.unsupportedFramePlan(
                "scene layer(s) had no resolved media pixels (dropped): \(dropped.sorted())")
        }
        do { return try ResolvedFrameInput(sceneLayers: sceneLayers, overlays: [], assetPixels: assetEntries) }
        catch { throw NextBridgeError.engine("rebuild with assets: \(error)") }
    }
}
#endif
