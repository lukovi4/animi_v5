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
    /// CP7: per-frame CPU video resolvers keyed by namespaced reference (parity oracle). Empty for photo-only.
    let videoResolversByReference: [String: NextVideoBlockResolver]
    /// CP7.8: per-frame GPU texture-backed video resolvers keyed by namespaced reference. Empty for photo-only.
    let videoTextureResolversByReference: [String: NextVideoTextureResolver]
    let assetEntries: [ResolvedAssetPixelEntry]
    let configuration: RenderConfiguration
    let session: MetalRenderSession
    let totalFrames: Int

    init(materials: RenderMaterialTable, window: EvaluationWindow,
         mediaPixelsByReference: [String: ResolvedPixelInput],
         videoResolversByReference: [String: NextVideoBlockResolver] = [:],
         videoTextureResolversByReference: [String: NextVideoTextureResolver] = [:],
         assetEntries: [ResolvedAssetPixelEntry],
         configuration: RenderConfiguration, session: MetalRenderSession, totalFrames: Int) {
        self.materials = materials; self.window = window
        self.mediaPixelsByReference = mediaPixelsByReference
        self.videoResolversByReference = videoResolversByReference
        self.videoTextureResolversByReference = videoTextureResolversByReference
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
        var videoWindowsByReference: [String: NextVideoWindow] = [:]
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
            // CP7.8: merge per-scene video trim windows (for the GPU texture resolvers built below).
            for (ref, win) in conv.videoWindowsByReference { videoWindowsByReference[ref] = win }

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

        // CP7.8: build GPU texture resolvers for every (namespaced) video reference from the session device.
        let textureResolvers = try NextSingleSceneBridge.makeVideoTextureResolvers(
            windowsByReference: videoWindowsByReference, sessionBox: sessionBox)

        return NextTimelinePreparedContext(
            materials: materials, window: window, mediaPixelsByReference: mediaPixelsByReference,
            videoResolversByReference: videoResolversByReference,
            videoTextureResolversByReference: textureResolvers,
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

    /// READBACK path (oracle / tests / photo prerender). `execute(_:)` takes NO texture bindings — a
    /// dynamic (video) timeline frame fails closed here; preview/export use the texture path below.
    static func renderFrame(context ctx: NextTimelinePreparedContext, frameIndex: Int) throws -> RenderedFrame {
        let built = try buildGraph(context: ctx, frameIndex: frameIndex)
        guard built.textureBindings.isEmpty else {
            throw NextBridgeError.engine("readback execute() path cannot render a dynamic-texture (video) timeline frame; use the texture-binding preview/export path")
        }
        do { return try ctx.session.execute(built.graph) }
        catch { throw NextBridgeError.engine("execute: \(error)") }
    }

    /// CP7.6a/CP7.8 — GPU-direct: render ONE timeline frame DIRECTLY into a caller-supplied external
    /// texture (no CPU readback), binding any per-subplan video textures.
    static func renderFrame(
        context ctx: NextTimelinePreparedContext, frameIndex: Int,
        into target: MTLTexture, alphaMode: AlphaMode
    ) throws {
        let built = try buildGraph(context: ctx, frameIndex: frameIndex)
        do {
            try ctx.session.render(
                built.graph, into: GPURenderTarget(texture: target, alphaMode: alphaMode),
                textureBindings: built.textureBindings)
        } catch { throw NextBridgeError.engine("render(into:): \(error)") }
    }

    /// CP7.7-next PREVIEW GPU-direct entry (timeline). CP7.8-CORR F1/F2: passes a `decodeBudget` (cold
    /// decodes/tick) for bounded multi-video scrub. `.max` = exact. Export uses `renderFrame(into:)`.
    static func renderFramePreview(context ctx: NextTimelinePreparedContext, frameIndex: Int, into target: MTLTexture, decodeBudget: Int = .max) throws {
        let built = try buildGraph(context: ctx, frameIndex: frameIndex, decodeBudget: decodeBudget)
        do {
            try ctx.session.render(
                built.graph, into: GPURenderTarget(texture: target, alphaMode: .preserveAlpha),
                textureBindings: built.textureBindings)
        } catch { throw NextBridgeError.engine("render(into:): \(error)") }
    }

    /// The shared per-frame timeline graph build (evaluate→resolve→compile). Used by BOTH the readback
    /// path (`renderFrame`/`renderFrameBGRA`, preview + tests) and the GPU-direct path (export).
    static func buildGraph(context ctx: NextTimelinePreparedContext, frameIndex: Int, decodeBudget: Int = .max) throws -> NextSingleSceneBridge.BuiltGraph {
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

        // CP7.8: resolve any video references PER participating subplan at THAT subplan's scene-local
        // media time → value descriptor + runtime texture handle. In a transition the outgoing/incoming
        // scenes have DIFFERENT scene-local times, so each is sampled at its own subplan's time.
        var dynamicFixtures: [RenderInputResolver.FixtureKey: ResolvedDynamicTextureInput] = [:]
        var handles: [String: RuntimeTextureHandle] = [:]
        if !ctx.videoTextureResolversByReference.isEmpty {
            // CP7.8-CORR F1/F2: the decode budget is per-TICK (shared across a transition's two subplans),
            // so a 6-video transition cannot spend 2×budget. Spend it down as each subplan resolves.
            var remainingBudget = decodeBudget
            for (subplan, _) in subplans {
                let (dyn, binds, spent) = try NextSingleSceneBridge.resolveVideoTexturesSpending(
                    subplan: subplan, textureResolvers: ctx.videoTextureResolversByReference,
                    decodeBudget: remainingBudget)
                if remainingBudget != .max { remainingBudget = max(0, remainingBudget - spent) }
                // Merge this subplan's fixtures + bindings. The binding map is keyed by the descriptor's
                // resourceID (== sourceID with PTS, CP7.8-CORR F4); look each up by that id, NOT the layer ref.
                for (k, d) in dyn {
                    dynamicFixtures[k] = d
                    if let h = binds.handle(for: d.id.rawValue) { handles[d.id.rawValue] = h }
                }
            }
        }
        let bindings = RenderRuntimeTextureBindings(handles)
        let dynamicRefs = Set(ctx.videoTextureResolversByReference.keys)

        // Build BYTES fixtures for every participating non-video scene reference (per-scene namespaced).
        let fixtures = try buildFixtures(
            subplans: subplans, mediaPixelsByReference: ctx.mediaPixelsByReference, dynamicRefs: dynamicRefs)

        let base: ResolvedFrameInput
        do {
            base = try RenderInputResolver.resolve(
                framePlan: plan, materials: ctx.materials, fixtures: fixtures, dynamicFixtures: dynamicFixtures)
        } catch { throw NextBridgeError.engine("resolve: \(error)") }

        // Graft authored-asset pixels. Rebuild from every participating subplan's resolved scene layers.
        let resolved = try rebuildWithAssetEntries(subplans: subplans, base: base, assetEntries: ctx.assetEntries)

        let graph: RenderGraph
        do { graph = try RenderGraphCompiler.compile(plan: plan, input: resolved, configuration: ctx.configuration) }
        catch { throw NextBridgeError.engine("compile: \(error)") }
        return NextSingleSceneBridge.BuiltGraph(graph: graph, textureBindings: bindings)
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
        subplans: [(SceneSubplan, ResolvedSceneRole)], mediaPixelsByReference: [String: ResolvedPixelInput],
        dynamicRefs: Set<String> = []
    ) throws -> [RenderInputResolver.FixtureKey: ResolvedPixelInput] {
        var fixtures: [RenderInputResolver.FixtureKey: ResolvedPixelInput] = [:]
        var missing: [String] = []
        for (subplan, _) in subplans {
            for layer in subplan.layers {
                guard case let .image(ref) = layer.content else { continue }
                // CP7.8: a dynamic (video) reference is supplied via dynamicFixtures, not bytes — skip.
                if dynamicRefs.contains(ref.raw) { continue }
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
                      let placement = base.mediaPlacement(for: key) else {
                    dropped.append("\(subplan.sceneID.raw)/\(role.rawValue)/\(layer.layerID.raw)")
                    continue
                }
                // CP7.8: bytes-backed (photo) OR dynamic texture-backed (video).
                if let pixels = base.pixelInput(for: key) {
                    sceneLayers.append(try ResolvedSceneLayerEntry(
                        key: key, program: program, pixelInput: pixels, placement: placement))
                } else if let dyn = base.dynamicTexture(for: key) {
                    sceneLayers.append(try ResolvedSceneLayerEntry(
                        key: key, program: program, source: .dynamicTexture(dyn), placement: placement))
                } else {
                    dropped.append("\(subplan.sceneID.raw)/\(role.rawValue)/\(layer.layerID.raw)")
                    continue
                }
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
