#if DEBUG
import Foundation
import CoreGraphics
import ImageIO
import Metal
import MetalKit

import AnimiEngineCore
import AnimiEngineRenderModel
import AnimiEngineTemplateAdapter
import AnimiEngineRenderGraph
import AnimiEngineMetalRender

// MARK: - CP2: AnimiEngineNext single-scene preview bridge (DEBUG only)
//
// Renders ONE frame of ONE single-scene template through AnimiEngineNext, end to end:
//   compiled.tve bytes
//     -> CompiledTemplateDecoder.decode
//     -> TemplateVariantInventory + Selection
//     -> CompiledTemplateConverter.convert      (CanonicalProjectDocument + RenderMaterialTable)
//     -> EvaluationWindowBuilder + TimelineEvaluator   (FramePlan)
//     -> RenderInputResolver.resolve            (user photo -> ResolvedPixelInput fixtures)
//     -> RenderGraphCompiler.compile            (RenderGraph)
//     -> MetalRenderSession.execute             (RenderedFrame BGRA8 premultiplied sRGB)
//
// This is a DEBUG-only experimental slice. It NEVER replaces the production path: the
// caller only invokes it behind `NextEngineBridgeToggles.renderWithNextEngine` (default OFF).
//
// Fail-closed contract: any unsupported / missing input throws `NextBridgeError`. There is
// NO silent fallback inside the Next path — the caller surfaces the error visibly.

/// Typed, visible failure for the CP2 Next bridge. No silent substitution.
enum NextBridgeError: Error, CustomStringConvertible, LocalizedError {
    case noScene
    case multiSceneUnsupported(sceneItemCount: Int)
    case notASceneItem
    case sceneFolderMissing(sceneTypeId: String)
    case compiledTemplateMissing(URL)
    case multiBlockUnsupported(blockCount: Int)
    case noMediaBound(blockID: String)
    case blockHidden(blockID: String)
    case unsupportedMediaKind(blockID: String, kind: String)
    case mediaResolveFailed(String)
    case imageDecodeFailed(URL)
    case placementConversion(String)
    case authoredAssetsUnsupported(count: Int)
    case authoredAssetFileMissing(materialID: String, assetID: String, basename: String)
    case authoredAssetDecodeFailed(materialID: String, assetID: String, basename: String)
    case authoredAssetDuplicate(pixelID: String)
    case unsupportedFramePlan(String)
    case engine(String)

    var description: String {
        switch self {
        case .noScene:
            return "Next bridge: no single scene in current project."
        case .multiSceneUnsupported(let n):
            return "Next bridge: single-scene slice requires exactly 1 scene item, got \(n). (CP2 scope)"
        case .notASceneItem:
            return "Next bridge: first timeline item is not a scene payload."
        case .sceneFolderMissing(let id):
            return "Next bridge: scene folder URL missing for '\(id)'."
        case .compiledTemplateMissing(let url):
            return "Next bridge: compiled.tve not found at \(url.path)."
        case .multiBlockUnsupported(let n):
            return "Next bridge: single-scene slice supports 1 media block, got \(n). (CP2 scope)"
        case .noMediaBound(let blockID):
            return "Next bridge: no media bound to block '\(blockID)'. Add a photo first."
        case .blockHidden(let blockID):
            return "Next bridge: media block '\(blockID)' is hidden (visibility=false). (CP4: fail closed)"
        case .unsupportedMediaKind(let blockID, let kind):
            return "Next bridge: block '\(blockID)' has unsupported media kind '\(kind)'. CP4 is photo-only (video/audio fail closed)."
        case .mediaResolveFailed(let m):
            return "Next bridge: media resolve failed: \(m)."
        case .imageDecodeFailed(let url):
            return "Next bridge: image decode failed for \(url.lastPathComponent)."
        case .placementConversion(let m):
            return "Next bridge: placement conversion failed: \(m)."
        case .authoredAssetsUnsupported(let n):
            return "Next bridge: scene has \(n) authored-asset image layer(s) with no supplied pixels. (CP2 scope)"
        case .authoredAssetFileMissing(let m, let a, let b):
            return "Next bridge: authored asset file missing — material \(m), asset '\(a)', basename '\(b)' not in SharedAssets."
        case .authoredAssetDecodeFailed(let m, let a, let b):
            return "Next bridge: authored asset decode failed — material \(m), asset '\(a)', basename '\(b)'."
        case .authoredAssetDuplicate(let pid):
            return "Next bridge: duplicate authored-asset pixel id '\(pid)'."
        case .unsupportedFramePlan(let m):
            return "Next bridge: unsupported frame plan: \(m). (CP2 = single scene only)"
        case .engine(let m):
            return "Next bridge engine error: \(m)."
        }
    }

    /// Surface the human-readable `description` through `Error.localizedDescription` (the export/preview
    /// UI shows `error.localizedDescription`). Without `LocalizedError` conformance Foundation returns
    /// the useless `"AnimiApp.NextBridgeError error <code>"` — so every fail-closed reason (stretched
    /// scene, unsupported media, etc.) was invisible to the user until this was added.
    var errorDescription: String? { description }
}

/// App media-placement values, passed as primitives so this struct stays free of any
/// AnimiEngineNext module dependency. Units match `MediaPlacementState`:
/// `fitModeRaw` ∈ {cover,contain,fill}; offsets in binding-local points; scale relative to fit;
/// rotation in degrees. The bridge converts these to fixed-point `MediaPlacement` with checked
/// rounding (no silent Float coercion).
struct NextBridgePlacement {
    let fitModeRaw: String
    let offsetX: Double
    let offsetY: Double
    let userScale: Double
    let rotationDegrees: Double
}

/// CP7: the trim window for a bound VIDEO block, in seconds. Mirrors `VideoSelection.winStart/winEnd`
/// (trim-only — no speed/loop/hold for user media, owner-confirmed). Carried as primitives so the
/// bridge stays free of any TVECore dependency.
struct NextBridgeVideo {
    let winStart: Double
    let winEnd: Double
}

/// One bound media block: the block id, its resolved file URL, and its app placement. CP4 was
/// photo-only; CP7 adds an optional `video` descriptor — when present the block is a VIDEO whose
/// per-frame pixels are resolved on demand (the URL is the video file). `video == nil` ⇒ photo
/// (unchanged path). Color/hidden/toggle blocks are still fail-closed before this is built.
struct NextBridgeBlock {
    let blockID: String
    let mediaURL: URL
    let placement: NextBridgePlacement
    /// Trim window if this block is a video; nil for a photo.
    var video: NextBridgeVideo? = nil
    /// CP7.8-CORR (main-thread fix B): the media file's (size, mtime) carried as VALUES, computed OFF the
    /// main thread when the URL is resolved (`NextMediaStatCache`). `NextPreviewKey.init` consumes these
    /// instead of calling `FileManager.attributesOfItem` per `draw(in:)` (~30ms/frame for 6 videos). `-1`
    /// means "not yet stat'd" — a value-only sentinel; the editor fills it on URL resolve before drawing.
    var mediaSize: Int64 = -1
    var mediaMTime: Double = -1
}

/// The canonical-namespace identity for ONE converted scene instance. CP2/CP4 single-scene used a
/// fixed `"cp4-inst"`/`"cp4-pay"` and an un-namespaced media reference. CP5 needs every scene of a
/// multi-scene timeline to carry UNIQUE ids and UNIQUE media references, because the canonical
/// `RenderInputResolver` fixture keys and scene-binding keys are global — two scenes that reused the
/// same reference would collide. `referencePrefix` namespaces each block's media reference.
struct NextSceneIdentity: Equatable {
    let sceneInstanceID: String
    let scenePayloadID: String
    /// Media references become `"\(referencePrefix)-\(blockID)"` — unique per scene instance.
    let referencePrefix: String

    /// The CP4 single-scene identity, preserved verbatim so the existing single-scene preview path
    /// renders byte-identically (same references → same fixtures/material keys as before).
    static let cp4Single = NextSceneIdentity(
        sceneInstanceID: "cp4-inst", scenePayloadID: "cp4-pay", referencePrefix: "cp4")

    /// A per-index CP5 timeline scene identity.
    static func cp5Timeline(index: Int) -> NextSceneIdentity {
        NextSceneIdentity(
            sceneInstanceID: "cp5-inst-\(index)", scenePayloadID: "cp5-pay-\(index)",
            referencePrefix: "cp5-s\(index)")
    }
}

/// Inputs the caller must assemble from existing app state before invoking the bridge.
/// CP4 single-scene scope: exactly ONE scene; ONE OR MORE photo media blocks.
struct NextBridgeInputs {
    /// Scene type id of the (single) open scene — from the single timeline scene item's payload.
    let sceneTypeId: String
    /// Folder URL of the scene package — `SceneTypeDescriptor.folderURL`.
    let sceneFolderURL: URL
    /// Per-block variant selection — `SceneState.variantOverrides` (may be partial).
    let variantOverrides: [String: String]
    /// All bound photo blocks, sorted by blockID for deterministic keys/binding order.
    let blocks: [NextBridgeBlock]
    /// Current playhead frame index (single-scene local frame == project frame).
    let frameIndex: Int
    /// Canonical namespace identity for this scene instance. Defaults to the CP4 single-scene
    /// identity so the existing CP4 preview path is unchanged.
    var identity: NextSceneIdentity = .cp4Single
    /// Post-roll (ticks) this scene's OUTGOING side must support to satisfy an animated transition
    /// to the next scene. Single-scene / cut → 0. Set per CP5 boundary. Affects the converter's
    /// per-layer effective active range AND the manifest `postRollCapability`, so it must be supplied
    /// at convert time (not patched afterward).
    var postRollTicks: Int64 = 0
    /// CP7.5: the scene's TIMELINE span in frames (the app's `durationUs` → frames). When it exceeds
    /// the template's native nominal frames the scene is STRETCHED — the bridge resolves it to a
    /// canonical `timelineSpan` (ticks) and the Next evaluator runs the two-clock model (visual held
    /// at nominal, media continuing to span). `nil` or a nominal-equal value ⇒ unstretched.
    var timelineDurationFrames: Int? = nil

    /// CP2/CP3 compatibility accessors for the FIRST block (used by single-block tests and the
    /// cache key's per-block fields). CP4 keys include every block, not just this one.
    var mediaBlockID: String { blocks.first?.blockID ?? "" }
    var mediaURL: URL { blocks.first?.mediaURL ?? URL(fileURLWithPath: "/") }
    var placement: NextBridgePlacement { blocks.first?.placement ?? NextBridgePlacement(fitModeRaw: "contain", offsetX: 0, offsetY: 0, userScale: 1, rotationDegrees: 0) }
}

/// Plain BGRA8 frame the editor can present without importing any AnimiEngineNext module
/// (avoids `RenderCommand` name collision with TVECore in `EditorViewController`).
struct NextBridgeBGRAFrame {
    let bytes: Data
    let width: Int
    let height: Int
    let bytesPerRow: Int
}

/// One block's placement-INDEPENDENT decoded media: its binding reference, chosen variant, and
/// EITHER a decoded photo (CP4) OR a per-frame video resolver (CP7). Reused across placement changes
/// (no re-decode of a photo; the video resolver streams forward across frames).
struct NextDecodedBlock {
    let blockID: String
    let chosenVariantID: String
    let mediaReference: String
    /// Decoded photo pixels (nil for a video block).
    let photoPixels: ResolvedPixelInput?
    /// Per-frame CPU video resolver (nil for a photo block). Owns one AVAssetReader; stateful across
    /// frames. Retained as the PARITY ORACLE / fallback (CP7.8 keeps the CPU bake path for tests); the
    /// shipping preview/export use the GPU texture resolver built from `videoWindow` at assemble time.
    let videoResolver: NextVideoBlockResolver?
    /// CP7.8: the video block's trim window (nil for a photo). `assemble` builds a per-context
    /// `NextVideoTextureResolver` from this + the session device for the GPU texture-backed path.
    let videoWindow: NextVideoWindow?

    /// Photo block (CP4).
    init(blockID: String, chosenVariantID: String, mediaReference: String, photoPixels: ResolvedPixelInput) {
        self.blockID = blockID; self.chosenVariantID = chosenVariantID
        self.mediaReference = mediaReference; self.photoPixels = photoPixels
        self.videoResolver = nil; self.videoWindow = nil
    }
    /// Video block (CP7 / CP7.8).
    init(blockID: String, chosenVariantID: String, mediaReference: String,
         videoResolver: NextVideoBlockResolver, videoWindow: NextVideoWindow) {
        self.blockID = blockID; self.chosenVariantID = chosenVariantID
        self.mediaReference = mediaReference; self.photoPixels = nil
        self.videoResolver = videoResolver; self.videoWindow = videoWindow
    }
}

/// Placement-INDEPENDENT decoded media (CP3/CP4 perf): the compiled.tve bytes + per-block decoded
/// photo pixels + authored-asset pixels. Cached keyed by `(scene, variant, media)` for ALL blocks —
/// a placement/fit/scale/rotation change on any block reuses this (no image re-decode).
final class NextDecodedMedia {
    let compiledData: Data
    /// Decoded photo blocks, sorted by blockID (deterministic binding order).
    let blocks: [NextDecodedBlock]
    /// Decoded authored-asset pixels keyed by (materialID, assetID) — placement-free, reusable.
    let assetPixelsByKey: [ResolvedAssetKey: ResolvedPixelInput]
    let canvasMaxPixel: Int
    /// The scene catalog id, namespace identity, and post-roll this media was decoded for. `assemble`
    /// reuses them so the real convert matches the probe (same ids, references, layer ranges).
    let sceneTypeId: String
    let identity: NextSceneIdentity
    let postRollTicks: Int64
    /// CP7.5: the scene's stretched timeline span in canonical ticks, or nil if unstretched. `assemble`
    /// / `convertScene` pass it to the converter so the canonical doc carries `timelineSpan` and the
    /// evaluator runs the two-clock model. Resolved once at decode against the template's frame rate.
    let timelineSpanTicks: Int64?

    init(compiledData: Data, blocks: [NextDecodedBlock],
         assetPixelsByKey: [ResolvedAssetKey: ResolvedPixelInput], canvasMaxPixel: Int,
         sceneTypeId: String, identity: NextSceneIdentity, postRollTicks: Int64,
         timelineSpanTicks: Int64?) {
        self.compiledData = compiledData; self.blocks = blocks
        self.assetPixelsByKey = assetPixelsByKey; self.canvasMaxPixel = canvasMaxPixel
        self.sceneTypeId = sceneTypeId; self.identity = identity; self.postRollTicks = postRollTicks
        self.timelineSpanTicks = timelineSpanTicks
    }
}

/// Prepared template-level context (CP3): the heavy, frame-INDEPENDENT work cached once per
/// opened single-scene template and reused for every per-frame render. Holds the converted
/// canonical document/materials, the evaluation window, the decoded photo + authored-asset
/// pixels, the render configuration, and a reusable `MetalRenderSession`.
///
/// Frame INDEX is the only thing that varies per render — see `NextSingleSceneBridge.renderFrame`.
final class NextPreparedContext {
    let materials: RenderMaterialTable
    let window: EvaluationWindow
    /// STATIC per-block photo pixels keyed by binding reference (video references are absent here).
    let mediaPixelsByReference: [String: ResolvedPixelInput]
    /// CP7: per-frame CPU video resolvers keyed by binding reference (parity oracle / fallback). Empty
    /// for photo-only scenes. NOT used by the shipping GPU texture path below.
    let videoResolversByReference: [String: NextVideoBlockResolver]
    /// CP7.8: per-frame GPU texture-backed video resolvers keyed by binding reference. Built once per
    /// context from the session device. The shipping preview/export per-frame render resolves each at the
    /// scene-local time → (dynamic descriptor, runtime texture binding). Empty for photo-only scenes.
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

    /// CP7.7-next: the output canvas pixel size, so the GPU-direct preview can allocate a canvas-sized
    /// render target for `MetalRenderSession.render(_:into:)` (which requires target dims == canvas).
    var canvasPixelSize: (width: Int, height: Int) {
        (Int(configuration.output.canvas.width), Int(configuration.output.canvas.height))
    }
}

/// Opaque holder for the shared `MetalRenderSession` so `NextPreviewController` can own/reuse one
/// session without importing `AnimiEngineMetalRender` (which would collide with TVECore types in
/// the editor module). Created once via `NextSingleSceneBridge.makeSession`.
final class NextSessionBox {
    let session: MetalRenderSession
    init(session: MetalRenderSession) {
        self.session = session
    }
    /// CP7.6a — the engine `MTLDevice`, so the export runner can build a `CVMetalTextureCache` /
    /// external render-target textures on the SAME device the session renders with.
    var metalDevice: MTLDevice { session.metalDevice }
}

/// DEBUG-only bridge that produces frames via AnimiEngineNext. CP3 splits the work into a
/// `prepare` step (heavy, once per template context) and a `renderFrame` step (per frame).
enum NextSingleSceneBridge {

    /// Create the single shared render session for a device (expensive; build once).
    static func makeSession(device: MTLDevice) throws -> NextSessionBox {
        do { return NextSessionBox(session: try MetalRenderSession(device: device)) }
        catch { throw NextBridgeError.engine("session: \(error)") }
    }

    // MARK: - Decode (heavy, placement-INDEPENDENT — cached per scene+variant+media)

    /// Load compiled.tve + decode the photo + decode authored-asset pixels ONCE. Independent of
    /// placement (fit/scale/offset/rotation), so dragging media reuses this. Uses identity placement
    /// only to walk programs for authored assets; the asset pixels + their `RenderMaterialID` keys
    /// are placement-stable.
    static func decodeMedia(_ inputs: NextBridgeInputs) throws -> NextDecodedMedia {
        let tveURL = inputs.sceneFolderURL.appendingPathComponent("compiled.tve", isDirectory: false)
        guard FileManager.default.fileExists(atPath: tveURL.path) else {
            throw NextBridgeError.compiledTemplateMissing(tveURL)
        }
        let data = try Data(contentsOf: tveURL)

        let decoded: DecodedCompiledTemplate
        let inventory: TemplateVariantInventory
        do {
            decoded = try CompiledTemplateDecoder.decode(data)
            inventory = try TemplateVariantInventory(from: decoded)
        } catch { throw NextBridgeError.engine("decode/inventory: \(error)") }

        // CP4: support N media blocks. The caller MUST supply exactly one bound photo per authored
        // block (fail closed otherwise — no partial scenes, no inventing empty bindings).
        guard !inputs.blocks.isEmpty else { throw NextBridgeError.noMediaBound(blockID: "(none)") }
        let inventoryBlockIDs = Set(inventory.blocks.map { $0.blockID })
        let inputBlockIDs = Set(inputs.blocks.map { $0.blockID })
        guard inputBlockIDs == inventoryBlockIDs else {
            // Every authored block must have a bound photo, and every bound block must be authored.
            throw NextBridgeError.multiBlockUnsupported(blockCount: inventory.blocks.count)
        }

        // Per-block: chosen variant, binding reference, identity-placement binding for the probe.
        let invByID = Dictionary(uniqueKeysWithValues: inventory.blocks.map { ($0.blockID, $0) })
        var chosenVariantByBlockID: [String: String] = [:]
        var probeBindings: [String: CompiledTemplateConverter.MediaBinding] = [:]
        var referenceByBlockID: [String: String] = [:]
        for b in inputs.blocks {
            guard let inv = invByID[b.blockID] else { throw NextBridgeError.noMediaBound(blockID: b.blockID) }
            let variant = inputs.variantOverrides[b.blockID] ?? inv.selectedVariantID
            // CP5: media reference is namespaced per scene instance so two scenes never collide.
            let ref = "\(inputs.identity.referencePrefix)-\(b.blockID)"
            chosenVariantByBlockID[b.blockID] = variant
            referenceByBlockID[b.blockID] = ref
            probeBindings[b.blockID] = .image(reference: ref, mediaPlacement: .identity(fitMode: .contain))
        }

        // Convert with IDENTITY placements to obtain materials/canvas for asset walking. The probe
        // uses the SAME post-roll AND timeline span as the real render so layer active ranges, the
        // asset walk, and the canonical project duration match the per-frame convert in `assemble`.
        let postRoll: TickDuration
        do { postRoll = try TickDuration(ticks: max(0, inputs.postRollTicks)) }
        catch { throw NextBridgeError.engine("postRoll: \(error)") }
        // CP7.5: ONE probe convert (no span — span does not affect canvas/asset-walk/media decode,
        // only the per-render window built in `assemble`). The stretched span in ticks is resolved
        // from the probe's native nominal frame count and stored; `convertScene` applies it.
        let probeOut: CompiledTemplateConverter.Output
        do {
            probeOut = try CompiledTemplateConverter.convert(.init(
                compiledTemplateData: data, catalogID: inputs.sceneTypeId,
                sceneInstanceID: inputs.identity.sceneInstanceID, scenePayloadID: inputs.identity.scenePayloadID,
                selection: TemplateVariantInventory.Selection(chosenVariantByBlockID: chosenVariantByBlockID),
                mediaBindings: probeBindings, requiredPostRoll: postRoll))
        } catch { throw NextBridgeError.engine("convert(probe): \(error)") }
        let timelineSpanTicks = Self.timelineSpanTicks(
            timelineDurationFrames: inputs.timelineDurationFrames, document: probeOut.document)

        let canvas = probeOut.document.manifest.output.canvas
        let maxPixel = Int(max(canvas.width, canvas.height))

        // Decode each block's media downsampled to canvas; build fixtures for all references. A photo
        // decodes once (placement-free, reused every frame). A VIDEO (CP7) builds a per-frame resolver
        // and a frame-0 fixture for the probe resolve; the per-frame pixels come from the resolver.
        var decodedBlocks: [NextDecodedBlock] = []
        var fixtures: [RenderInputResolver.FixtureKey: ResolvedPixelInput] = [:]
        for b in inputs.blocks.sorted(by: { $0.blockID < $1.blockID }) {
            let ref = referenceByBlockID[b.blockID]!
            if let v = b.video {
                let window = NextVideoWindow(url: b.mediaURL, winStart: v.winStart, winEnd: v.winEnd)
                let resolver = NextVideoBlockResolver(
                    blockID: b.blockID, mediaReference: ref,
                    window: window, maxPixelSize: maxPixel)
                // Frame-0 pixels (scene-local time 0) for the probe resolve / authored-asset walk. The
                // CPU resolver realizes the probe frame; the shipping per-frame path uses the GPU texture
                // resolver (built at assemble), so this probe bake happens ONCE per decode (not per frame).
                let frame0: ResolvedPixelInput
                do { frame0 = try resolver.resolve(scenePlaybackSeconds: 0) }
                catch { throw NextBridgeError.engine("video decode(probe) block \(b.blockID): \(error)") }
                decodedBlocks.append(NextDecodedBlock(
                    blockID: b.blockID, chosenVariantID: chosenVariantByBlockID[b.blockID]!,
                    mediaReference: ref, videoResolver: resolver, videoWindow: window))
                fixtures[.image(reference: ref)] = frame0
            } else {
                let pixels = try decodeImageToPixelInput(url: b.mediaURL, id: ref, maxPixelSize: maxPixel)
                decodedBlocks.append(NextDecodedBlock(
                    blockID: b.blockID, chosenVariantID: chosenVariantByBlockID[b.blockID]!,
                    mediaReference: ref, photoPixels: pixels))
                fixtures[.image(reference: ref)] = pixels
            }
        }

        // Decode authored-asset pixels using a frame-0 probe resolve (binds all block references).
        let probeWindow = try buildWindow(probeOut.document).window
        let probePlan = try evaluatePlan(window: probeWindow, frame: 0)
        guard case let .single(probeSubplan) = probePlan.body else {
            throw NextBridgeError.unsupportedFramePlan("expected single scene body")
        }
        try assertReferencesPresent(subplan: probeSubplan, references: Set(referenceByBlockID.values))
        let probeBase: ResolvedFrameInput
        do { probeBase = try RenderInputResolver.resolve(framePlan: probePlan, materials: probeOut.materials, fixtures: fixtures) }
        catch { throw NextBridgeError.engine("resolve(probe): \(error)") }
        let entries = try loadAuthoredAssets(subplan: probeSubplan, base: probeBase, maxPixelSize: maxPixel)
        var assetPixelsByKey: [ResolvedAssetKey: ResolvedPixelInput] = [:]
        for e in entries { assetPixelsByKey[e.key] = e.pixelInput }

        return NextDecodedMedia(
            compiledData: data, blocks: decodedBlocks,
            assetPixelsByKey: assetPixelsByKey, canvasMaxPixel: maxPixel,
            sceneTypeId: inputs.sceneTypeId, identity: inputs.identity, postRollTicks: max(0, inputs.postRollTicks),
            timelineSpanTicks: timelineSpanTicks)
    }

    /// CP7.5: resolve the stretched timeline span in canonical TICKS from the app's timeline-frame
    /// count, using the template document's own frame rate. Returns nil when unstretched (frames <=
    /// native nominal frames, within a 1-frame µs↔frame rounding tolerance) so the converter defaults
    /// to `timelineSpan == nominalDuration`.
    static func timelineSpanTicks(timelineDurationFrames: Int?, document: CanonicalProjectDocument) -> Int64? {
        guard let frames = timelineDurationFrames else { return nil }
        let nominalFrames = nominalFrameCount(of: document)
        guard frames > nominalFrames + 1 else { return nil }   // unstretched (+1 rounding tolerance)
        let fr = document.manifest.output.frameRate
        // ticks = frames * ticksPerSecond * denominator / numerator (inverse of nominalFrameCount).
        let ticks = (Int64(frames) &* Int64(TickClock.ticksPerSecond) &* fr.denominator) / fr.numerator
        return ticks
    }

    // MARK: - Assemble (light, placement-DEPENDENT — reuses decoded media)

    /// One scene's placement-applied conversion: the converter `Output` (document + materials),
    /// the per-block media pixels keyed by reference, and the de-duplicated authored-asset entries.
    /// Reused by the single-scene `assemble` and the CP5 multi-scene timeline bridge.
    struct NextSceneConversion {
        let output: CompiledTemplateConverter.Output
        /// STATIC photo pixels keyed by reference (video references are absent — resolved per frame).
        let mediaPixelsByReference: [String: ResolvedPixelInput]
        /// CP7: per-frame CPU video resolvers keyed by reference (parity oracle). Empty for photo-only.
        let videoResolversByReference: [String: NextVideoBlockResolver]
        /// CP7.8: per-video trim windows keyed by reference, so the assembler can build the GPU texture
        /// resolver from the session device. Empty for photo-only scenes.
        let videoWindowsByReference: [String: NextVideoWindow]
        let assetEntries: [ResolvedAssetPixelEntry]
    }

    /// Convert ONE decoded scene with its current per-block placements (cheap: reuses decoded
    /// pixels). Uses the decoded scene's stored identity + post-roll so the document matches the
    /// probe and (for CP5) carries unique scene/payload ids.
    static func convertScene(decoded: NextDecodedMedia, placementByBlockID: [String: NextBridgePlacement])
        throws -> NextSceneConversion {
        var bindings: [String: CompiledTemplateConverter.MediaBinding] = [:]
        var chosenVariantByBlockID: [String: String] = [:]
        var mediaPixelsByReference: [String: ResolvedPixelInput] = [:]
        var videoResolversByReference: [String: NextVideoBlockResolver] = [:]
        var videoWindowsByReference: [String: NextVideoWindow] = [:]
        for blk in decoded.blocks {
            guard let p = placementByBlockID[blk.blockID] else {
                throw NextBridgeError.noMediaBound(blockID: blk.blockID)
            }
            bindings[blk.blockID] = .image(reference: blk.mediaReference, mediaPlacement: try convertPlacement(p))
            chosenVariantByBlockID[blk.blockID] = blk.chosenVariantID
            if let photo = blk.photoPixels {
                mediaPixelsByReference[blk.mediaReference] = photo
            } else if let resolver = blk.videoResolver, let window = blk.videoWindow {
                videoResolversByReference[blk.mediaReference] = resolver
                videoWindowsByReference[blk.mediaReference] = window
            } else {
                throw NextBridgeError.engine("decoded block \(blk.blockID) has neither photo nor video")
            }
        }

        let postRoll: TickDuration
        do { postRoll = try TickDuration(ticks: max(0, decoded.postRollTicks)) }
        catch { throw NextBridgeError.engine("postRoll: \(error)") }

        let out: CompiledTemplateConverter.Output
        do {
            out = try CompiledTemplateConverter.convert(.init(
                compiledTemplateData: decoded.compiledData, catalogID: decoded.sceneTypeId,
                sceneInstanceID: decoded.identity.sceneInstanceID, scenePayloadID: decoded.identity.scenePayloadID,
                selection: TemplateVariantInventory.Selection(chosenVariantByBlockID: chosenVariantByBlockID),
                mediaBindings: bindings, requiredPostRoll: postRoll,
                timelineSpan: decoded.timelineSpanTicks.map { try? TickDuration(ticks: $0) } ?? nil))
        } catch { throw NextBridgeError.engine("convert: \(error)") }

        var assetEntries: [ResolvedAssetPixelEntry] = []
        for (key, pix) in decoded.assetPixelsByKey {
            assetEntries.append(ResolvedAssetPixelEntry(key: key, pixelInput: pix))
        }
        return NextSceneConversion(
            output: out, mediaPixelsByReference: mediaPixelsByReference,
            videoResolversByReference: videoResolversByReference,
            videoWindowsByReference: videoWindowsByReference, assetEntries: assetEntries)
    }

    /// Build a single-scene render context for given per-block placements, REUSING decoded media.
    /// CP4 single-scene path — unchanged behavior.
    static func assemble(decoded: NextDecodedMedia, placementByBlockID: [String: NextBridgePlacement],
                         sessionBox: NextSessionBox) throws -> NextPreparedContext {
        let conv = try convertScene(decoded: decoded, placementByBlockID: placementByBlockID)
        let (window, totalFrames) = try buildWindow(conv.output.document)

        let configuration: RenderConfiguration
        do {
            configuration = try RenderConfiguration(
                output: conv.output.document.manifest.output, colorContract: .task003, intermediateProfile: .rgba16FloatLinear)
        } catch { throw NextBridgeError.engine("config: \(error)") }

        // CP7.8: build a GPU texture resolver per video reference from the session device + shared queue.
        let textureResolvers = try makeVideoTextureResolvers(
            windowsByReference: conv.videoWindowsByReference, sessionBox: sessionBox)

        return NextPreparedContext(
            materials: conv.output.materials, window: window, mediaPixelsByReference: conv.mediaPixelsByReference,
            videoResolversByReference: conv.videoResolversByReference,
            videoTextureResolversByReference: textureResolvers,
            assetEntries: conv.assetEntries, configuration: configuration,
            session: sessionBox.session, totalFrames: totalFrames)
    }

    /// CP7.8/CP7.9: build one `NextVideoTextureResolver` per video reference on the session device. The
    /// resolver realizes frames via a `CVMetalTextureCache` direct bind (no command queue / no blit since
    /// CP7.8-CORR F3).
    static func makeVideoTextureResolvers(
        windowsByReference: [String: NextVideoWindow], sessionBox: NextSessionBox
    ) throws -> [String: NextVideoTextureResolver] {
        guard !windowsByReference.isEmpty else { return [:] }
        var resolvers: [String: NextVideoTextureResolver] = [:]
        for (ref, window) in windowsByReference {
            resolvers[ref] = NextVideoTextureResolver(
                blockID: ref, mediaReference: ref, window: window, device: sessionBox.metalDevice)
        }
        return resolvers
    }

    /// Canonical NOMINAL frame count of a converted document (projectDuration → frames). Used by the
    /// CP7 stretch guard to compare against the app's timeline span. Returns 0 on any error so the
    /// guard treats it conservatively (the real `buildWindow` later surfaces genuine failures).
    static func nominalFrameCount(of document: CanonicalProjectDocument) -> Int {
        guard let duration = try? document.manifest.projectDuration() else { return 0 }
        let fr = document.manifest.output.frameRate
        return Int((duration.ticks &* fr.numerator) / (Int64(TickClock.ticksPerSecond) &* fr.denominator))
    }

    /// Build the evaluation window + total frame count from a converted document.
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

    // MARK: - Per-frame (light, uses the prepared context)

    /// Render ONE frame index from a prepared context. Only evaluate→resolve→compile→execute run
    /// per frame; all heavy decode/convert/session work is reused from `ctx`.
    static func renderFrameBGRA(context ctx: NextPreparedContext, frameIndex: Int) throws -> NextBridgeBGRAFrame {
        let frame = try renderFrame(context: ctx, frameIndex: frameIndex)
        return NextBridgeBGRAFrame(
            bytes: frame.bytes, width: frame.dimensions.width,
            height: frame.dimensions.height, bytesPerRow: frame.dimensions.bytesPerRow)
    }

    /// READBACK path (oracle / tests / photo prerender). Uses `execute(_:)` which takes NO texture
    /// bindings — so a frame containing a dynamic (video) resource fails closed here (correct: the
    /// readback oracle never renders user video; preview/export use the texture path below).
    static func renderFrame(context ctx: NextPreparedContext, frameIndex: Int) throws -> RenderedFrame {
        let built = try buildGraph(context: ctx, frameIndex: frameIndex)
        guard built.textureBindings.isEmpty else {
            throw NextBridgeError.engine("readback execute() path cannot render a dynamic-texture (video) frame; use the texture-binding preview/export path")
        }
        do { return try ctx.session.execute(built.graph) }
        catch { throw NextBridgeError.engine("execute: \(error)") }
    }

    /// CP7.6a — GPU-direct: render ONE frame index DIRECTLY into a caller-supplied external texture
    /// (no CPU readback, no `RenderedFrame`/`Data`). Reuses the IDENTICAL evaluate→resolve→compile
    /// business logic via `buildGraph`; only the final write differs (`render(into:)` vs `execute`).
    static func renderFrame(
        context ctx: NextPreparedContext, frameIndex: Int,
        into target: MTLTexture, alphaMode: AlphaMode
    ) throws {
        let built = try buildGraph(context: ctx, frameIndex: frameIndex)
        do {
            try ctx.session.render(
                built.graph, into: GPURenderTarget(texture: target, alphaMode: alphaMode),
                textureBindings: built.textureBindings)
        } catch { throw NextBridgeError.engine("render(into:): \(error)") }
    }

    /// CP7.7-next PREVIEW GPU-direct entry. Renders frame `frameIndex` straight into `target` with
    /// `.preserveAlpha` (preview composites onto a cleared drawable). Hides `AlphaMode`/`GPURenderTarget`
    /// from the editor module (which must not import `AnimiEngineMetalRender`). Replaces the readback
    /// (`renderFrameBGRA` → Data → srcTex.replace) preview hot path; `renderFrameBGRA` stays for oracle/tests.
    /// CP7.8-CORR F1/F2: PREVIEW passes a `decodeBudget` (cold decodes/tick) so an active multi-video scrub
    /// never serializes N far decodes. `.max` = exact (settled/pause). Export uses `renderFrame(into:)`
    /// (unbounded/exact) — never this bounded preview entry.
    static func renderFramePreview(context ctx: NextPreparedContext, frameIndex: Int, into target: MTLTexture, decodeBudget: Int = .max) throws {
        let built = try buildGraph(context: ctx, frameIndex: frameIndex, decodeBudget: decodeBudget)
        do {
            try ctx.session.render(
                built.graph, into: GPURenderTarget(texture: target, alphaMode: .preserveAlpha),
                textureBindings: built.textureBindings)
        } catch { throw NextBridgeError.engine("render(into:): \(error)") }
    }

    /// The shared per-frame graph build (evaluate→resolve→compile). Used by BOTH the readback path
    /// (`renderFrame`/`renderFrameBGRA`, preview + tests) and the GPU-direct path (export).
    /// The per-frame graph build result: the canonical graph + the runtime texture bindings for any
    /// dynamic (user-video) resources in it. Photo-only frames return `.none` bindings.
    struct BuiltGraph {
        let graph: RenderGraph
        let textureBindings: RenderRuntimeTextureBindings
    }

    /// `decodeBudget` (CP7.8-CORR F1/F2) caps the number of COLD video decodes this build performs; over
    /// budget, a video reuses its last-good texture (preview scrub soft-skip). Default `.max` = unbounded
    /// (export / settled / readback / tests — exact). Preview-active-scrub passes a small budget.
    static func buildGraph(context ctx: NextPreparedContext, frameIndex: Int, decodeBudget: Int = .max) throws -> BuiltGraph {
        let plan = try evaluatePlan(window: ctx.window, frame: max(0, frameIndex))
        guard case let .single(subplan) = plan.body else {
            throw NextBridgeError.unsupportedFramePlan("expected single scene body")
        }
        // CP7.8: resolve any video references at THIS frame's scene-local time on the GPU. Each produces
        // a VALUE descriptor (for the canonical fixtures) + a runtime texture handle (for execution). The
        // static photo pixels stay bytes-backed. No CPU bake / SHA-256 on the per-frame video path.
        // CP7.8-CORR F1/F2: `decodeBudget` caps cold decodes this tick (preview scrub); over budget a video
        // reuses its last-good texture (soft-skip) so the UI never blocks on N simultaneous far decodes.
        let (dynamicFixtures, bindings) = try resolveVideoTextures(
            subplan: subplan, textureResolvers: ctx.videoTextureResolversByReference,
            decodeBudget: decodeBudget)
        let fixtures = try buildFixtures(
            subplan: subplan, mediaPixelsByReference: ctx.mediaPixelsByReference,
            dynamicRefs: Set(ctx.videoTextureResolversByReference.keys))
        let base: ResolvedFrameInput
        do {
            base = try RenderInputResolver.resolve(
                framePlan: plan, materials: ctx.materials, fixtures: fixtures, dynamicFixtures: dynamicFixtures)
        } catch { throw NextBridgeError.engine("resolve: \(error)") }
        let resolved = try rebuildWithAssetEntries(subplan: subplan, base: base, assetEntries: ctx.assetEntries)
        let graph: RenderGraph
        do { graph = try RenderGraphCompiler.compile(plan: plan, input: resolved, configuration: ctx.configuration) }
        catch { throw NextBridgeError.engine("compile: \(error)") }
        return BuiltGraph(graph: graph, textureBindings: bindings)
    }

    /// CP7.8: resolve every GPU video texture resolver whose reference appears in THIS subplan, at the
    /// subplan's scene-local media time. Returns the value descriptors keyed by the resolver's fixture
    /// key (`.image(reference:)`) + the runtime binding map keyed by descriptor resourceID. A resolver not
    /// in this subplan is skipped.
    ///
    /// CP7.8-CORR F1/F2 bounded hybrid: `decodeBudget` caps COLD decodes this tick. A video whose frame is
    /// already cached (cheap) always resolves. A video that WOULD cold-decode (far advance / rebuild) spends
    /// one budget unit; once budget is exhausted, it reuses its **last-good** frame (soft-skip) instead of
    /// blocking — so the preview never serializes N simultaneous far decodes (the 3.3 s 6-video stall).
    /// A video with neither a cheap frame nor any last-good (true first appearance) is decoded regardless
    /// (unavoidable to render its first frame; bounded by #new-videos, not by scrub distance). Order is
    /// deterministic (sorted refs) so the SAME videos win the budget across consecutive ticks (no flicker).
    static func resolveVideoTextures(
        subplan: SceneSubplan, textureResolvers: [String: NextVideoTextureResolver],
        decodeBudget: Int = .max
    ) throws -> (dynamicFixtures: [RenderInputResolver.FixtureKey: ResolvedDynamicTextureInput],
                 bindings: RenderRuntimeTextureBindings) {
        let (d, b, _) = try resolveVideoTexturesSpending(
            subplan: subplan, textureResolvers: textureResolvers, decodeBudget: decodeBudget)
        return (d, b)
    }

    /// As `resolveVideoTextures`, additionally returning the number of COLD decodes spent (so a timeline
    /// transition can share ONE per-tick budget across its two subplans).
    static func resolveVideoTexturesSpending(
        subplan: SceneSubplan, textureResolvers: [String: NextVideoTextureResolver],
        decodeBudget: Int
    ) throws -> (dynamicFixtures: [RenderInputResolver.FixtureKey: ResolvedDynamicTextureInput],
                 bindings: RenderRuntimeTextureBindings, spent: Int) {
        guard !textureResolvers.isEmpty else { return ([:], .none, 0) }
        var refsInPlan = Set<String>()
        for layer in subplan.layers {
            if case let .image(ref) = layer.content { refsInPlan.insert(ref.raw) }
        }
        let seconds = scenePlaybackSeconds(subplan)
        var dynamicFixtures: [RenderInputResolver.FixtureKey: ResolvedDynamicTextureInput] = [:]
        var handles: [String: RuntimeTextureHandle] = [:]
        var coldSpent = 0
        // Deterministic order so the same refs win the budget tick-to-tick (no flicker).
        for ref in textureResolvers.keys.sorted() where refsInPlan.contains(ref) {
            let resolver = textureResolvers[ref]!
            let cold = resolver.wouldColdDecode(scenePlaybackSeconds: seconds)
            let frame: NextVideoTextureResolver.Frame
            if cold, coldSpent >= decodeBudget, let lastGood = resolver.lastCachedFrame {
                // Over budget AND a far/new sample → soft-skip: present last-good, do not block this tick.
                frame = lastGood
            } else {
                if cold { coldSpent += 1 }
                do { frame = try resolver.resolve(scenePlaybackSeconds: seconds) }
                catch { throw NextBridgeError.engine("video texture resolve '\(ref)' at \(seconds)s: \(error)") }
            }
            dynamicFixtures[.image(reference: ref)] = frame.descriptor
            // CP7.8-CORR F4 FIX: the runtime binding map MUST be keyed by the descriptor's resourceID
            // (== sourceID, which now includes PTS), NOT by the layer reference. The executor looks the
            // binding up by `descriptor.resourceID`; keying by `ref` left it unfound → missingTextureBinding
            // (red screen). The fixture key stays `.image(reference: ref)` so the layer still resolves.
            handles[frame.descriptor.id.rawValue] = frame.handle
        }
        return (dynamicFixtures, RenderRuntimeTextureBindings(handles), coldSpent)
    }

    // MARK: - Shared frame helpers

    private static func evaluatePlan(window: EvaluationWindow, frame: Int) throws -> FramePlan {
        do { return try TimelineEvaluator.evaluate(window, atFrame: try FrameIndex(value: Int64(frame))) }
        catch { throw NextBridgeError.engine("evaluate: \(error)") }
    }

    /// Bind each block's user photo to its media reference (authored assets use assetPixels, not this).
    /// Every supplied reference MUST appear in the frame plan (fail closed otherwise).
    private static func buildFixtures(
        subplan: SceneSubplan, mediaPixelsByReference: [String: ResolvedPixelInput],
        dynamicRefs: Set<String> = []
    ) throws -> [RenderInputResolver.FixtureKey: ResolvedPixelInput] {
        var present = Set<String>()
        for layer in subplan.layers {
            if case let .image(ref) = layer.content, mediaPixelsByReference[ref.raw] != nil {
                present.insert(ref.raw)
            }
        }
        let missing = Set(mediaPixelsByReference.keys).subtracting(present)
        guard missing.isEmpty else {
            throw NextBridgeError.unsupportedFramePlan("bound media reference(s) not present in frame plan: \(missing.sorted())")
        }
        var fixtures: [RenderInputResolver.FixtureKey: ResolvedPixelInput] = [:]
        // CP7.8: a dynamic (video) reference is supplied via dynamicFixtures, not bytes — skip it here.
        for (ref, pixels) in mediaPixelsByReference where !dynamicRefs.contains(ref) {
            fixtures[.image(reference: ref)] = pixels
        }
        return fixtures
    }

    /// MEDIA scene-local playback time of a subplan, in seconds (canonical ticks are 240,000/sec).
    /// CP7.5: video sampling uses the MEDIA clock (continues across a stretched span); the evaluator
    /// has already applied transition compression / scene offsets / the two-clock split.
    static func scenePlaybackSeconds(_ subplan: SceneSubplan) -> Double {
        Double(subplan.mediaPlaybackTime.ticks) / Double(TickClock.ticksPerSecond)
    }

    /// CP7: produce the COMPLETE per-block media-pixel map for one subplan at its scene-local time —
    /// the static photo pixels plus a freshly-resolved BGRA8 frame for each VIDEO reference that
    /// appears in this subplan. A video resolver whose reference is NOT in this subplan is skipped
    /// (it belongs to a non-participating scene); a reference present in both maps is a programmer
    /// error (a block is either photo or video) and fails closed.
    static func mergeVideoPixels(
        subplan: SceneSubplan,
        staticPixels: [String: ResolvedPixelInput],
        videoResolvers: [String: NextVideoBlockResolver]
    ) throws -> [String: ResolvedPixelInput] {
        guard !videoResolvers.isEmpty else { return staticPixels }
        var merged = staticPixels
        let seconds = scenePlaybackSeconds(subplan)
        // Only resolve video references that actually appear in THIS subplan's image layers.
        var refsInPlan = Set<String>()
        for layer in subplan.layers {
            if case let .image(ref) = layer.content { refsInPlan.insert(ref.raw) }
        }
        for (ref, resolver) in videoResolvers where refsInPlan.contains(ref) {
            guard merged[ref] == nil else {
                throw NextBridgeError.engine("reference '\(ref)' is bound as both photo and video")
            }
            do { merged[ref] = try resolver.resolve(scenePlaybackSeconds: seconds) }
            catch { throw NextBridgeError.engine("video resolve '\(ref)' at \(seconds)s: \(error)") }
        }
        return merged
    }

    /// Assert every supplied media reference is present in the (probe) subplan — fail closed if a
    /// bound block's media layer is absent (e.g. an unexpected template shape).
    private static func assertReferencesPresent(subplan: SceneSubplan, references: Set<String>) throws {
        var present = Set<String>()
        for layer in subplan.layers {
            if case let .image(ref) = layer.content, references.contains(ref.raw) { present.insert(ref.raw) }
        }
        let missing = references.subtracting(present)
        guard missing.isEmpty else {
            throw NextBridgeError.unsupportedFramePlan("bound media reference(s) not present in frame plan: \(missing.sorted())")
        }
    }

    // MARK: - Placement conversion (fix 3: checked fixed-point, no Float coercion)

    /// Convert app `MediaPlacementState` primitives into canonical fixed-point `MediaPlacement`.
    /// Units (from the core scalar definitions):
    ///   - `CanvasScalar`: 65,536 raw units per canvas point  (offsets are in binding-local points)
    ///   - `ScaleScalar`:  1,000,000 raw units per 1.0
    ///   - `RotationScalar`: 1,000 raw units per degree
    /// Each conversion rounds to nearest and is range-checked; out-of-range throws (no silent coercion).
    private static func convertPlacement(_ p: NextBridgePlacement) throws -> MediaPlacement {
        guard let fitMode = MediaFitMode(rawValue: p.fitModeRaw) else {
            throw NextBridgeError.placementConversion("unknown fit mode '\(p.fitModeRaw)'")
        }
        let offsetX = CanvasScalar(rawValue: try rawUnits(p.offsetX, CanvasScalar.unitsPerPoint, "offsetX"))
        let offsetY = CanvasScalar(rawValue: try rawUnits(p.offsetY, CanvasScalar.unitsPerPoint, "offsetY"))
        let scaleRaw = try rawUnits(p.userScale, ScaleScalar.unitsPerUnit, "userScale")
        let scale: ScaleScalar
        do {
            scale = try ScaleScalar(positiveRawValue: scaleRaw)
        } catch {
            throw NextBridgeError.placementConversion("userScale must be > 0 (got \(p.userScale))")
        }
        let rotation = RotationScalar(
            rawValue: try rawUnits(p.rotationDegrees, RotationScalar.unitsPerDegree, "rotationDegrees"))
        do {
            return try MediaPlacement(
                fitMode: fitMode,
                userOffsetX: offsetX, userOffsetY: offsetY,
                userScale: scale, userRotation: rotation)
        } catch {
            throw NextBridgeError.placementConversion("\(error)")
        }
    }

    /// Multiply a `Double` authoring value by an integer fixed-point unit count, rounding to
    /// nearest, with overflow/finite checks. No silent truncation.
    private static func rawUnits(_ value: Double, _ unitsPerUnit: Int64, _ field: String) throws -> Int64 {
        guard value.isFinite else {
            throw NextBridgeError.placementConversion("\(field) is not finite")
        }
        let scaled = (value * Double(unitsPerUnit)).rounded()
        guard scaled >= Double(Int64.min) && scaled <= Double(Int64.max) else {
            throw NextBridgeError.placementConversion("\(field) out of fixed-point range")
        }
        return Int64(scaled)
    }

    // MARK: - Authored-asset pixel loading (CP2 device-smoke corrective; CP3 cached once)

    /// Decode authored-asset pixels (e.g. `plastik.png`) from bundled SharedAssets ONCE. The
    /// returned entries are frame-independent and cached in the prepared context (CP3). User
    /// media stays bound to the media reference only; authored assets use assetPixels.
    private static func loadAuthoredAssets(
        subplan: SceneSubplan, base: ResolvedFrameInput, maxPixelSize: Int
    ) throws -> [ResolvedAssetPixelEntry] {
        let sharedIndex = try sharedAssetsIndex()
        var assetEntries: [ResolvedAssetPixelEntry] = []
        var seenPixelIDs = Set<String>()

        for layer in subplan.layers {
            let key = ResolvedLayerKey.sceneLayer(
                sceneID: subplan.sceneID, role: .sole, layerID: layer.layerID)
            guard let program = base.program(for: key) else { continue }
            let assetByID = Dictionary(uniqueKeysWithValues: program.assets.map { ($0.id, $0) })
            for assetID in authoredAssetIDs(program).sorted() {
                let materialIDStr = program.id.rawValue
                guard let asset = assetByID[assetID] else {
                    throw NextBridgeError.authoredAssetFileMissing(
                        materialID: materialIDStr, assetID: assetID, basename: "(unknown)")
                }
                guard let url = sharedIndex[asset.basename] else {
                    throw NextBridgeError.authoredAssetFileMissing(
                        materialID: materialIDStr, assetID: assetID, basename: asset.basename)
                }
                let pixelID = "cp3-asset-\(materialIDStr)-\(assetID)"
                guard seenPixelIDs.insert(pixelID).inserted else {
                    throw NextBridgeError.authoredAssetDuplicate(pixelID: pixelID)
                }
                let pixelInput: ResolvedPixelInput
                do { pixelInput = try decodeImageToPixelInput(url: url, id: pixelID, maxPixelSize: maxPixelSize) }
                catch {
                    throw NextBridgeError.authoredAssetDecodeFailed(
                        materialID: materialIDStr, assetID: assetID, basename: asset.basename)
                }
                assetEntries.append(ResolvedAssetPixelEntry(
                    key: ResolvedAssetKey(materialID: program.id, assetID: assetID), pixelInput: pixelInput))
            }
        }
        return assetEntries
    }

    /// Rebuild a per-frame `ResolvedFrameInput` from the base resolve + CACHED authored-asset
    /// entries — no image decode (the heavy decode happened once in `loadAuthoredAssets`).
    private static func rebuildWithAssetEntries(
        subplan: SceneSubplan, base: ResolvedFrameInput, assetEntries: [ResolvedAssetPixelEntry]
    ) throws -> ResolvedFrameInput {
        var sceneEntries: [ResolvedSceneLayerEntry] = []
        var dropped: [String] = []
        for layer in subplan.layers {
            let key = ResolvedLayerKey.sceneLayer(
                sceneID: subplan.sceneID, role: .sole, layerID: layer.layerID)
            guard let program = base.program(for: key),
                  let placement = base.mediaPlacement(for: key) else {
                dropped.append(layer.layerID.raw)
                continue
            }
            // CP7.8: a layer is EITHER bytes-backed (photo/asset) OR dynamic texture-backed (video).
            if let pixels = base.pixelInput(for: key) {
                sceneEntries.append(try ResolvedSceneLayerEntry(
                    key: key, program: program, pixelInput: pixels, placement: placement))
            } else if let dyn = base.dynamicTexture(for: key) {
                sceneEntries.append(try ResolvedSceneLayerEntry(
                    key: key, program: program, source: .dynamicTexture(dyn), placement: placement))
            } else {
                // CP4 fail-closed: a media-bearing scene layer with no resolved program/placement/
                // pixels would silently vanish (this is why example_4blocks showed only 1 of 4).
                dropped.append(layer.layerID.raw)
                continue
            }
        }
        guard dropped.isEmpty else {
            throw NextBridgeError.unsupportedFramePlan(
                "scene layer(s) had no resolved media pixels (dropped): \(dropped.sorted())")
        }
        do {
            return try ResolvedFrameInput(
                sceneLayers: sceneEntries, overlays: [], assetPixels: assetEntries)
        } catch {
            throw NextBridgeError.engine("rebuild with assets: \(error)")
        }
    }

    /// Build a basename → file URL index of bundled SharedAssets. Mirrors the approved
    /// `SharedAssetsIndex` rule: recursive scan, key = filename without extension (case-sensitive),
    /// allowed image extensions. Kept local so the bridge does not import TVECore.
    private static func sharedAssetsIndex() throws -> [String: URL] {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("SharedAssets", isDirectory: true),
              let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]) else {
            return [:]
        }
        let allowed: Set<String> = ["png", "jpg", "jpeg", "webp"]
        var index: [String: URL] = [:]
        for case let fileURL as URL in enumerator {
            guard allowed.contains(fileURL.pathExtension.lowercased()) else { continue }
            let basename = (fileURL.lastPathComponent as NSString).deletingPathExtension
            guard !basename.isEmpty else { continue }
            index[basename] = fileURL  // last-wins; SharedAssets basenames are globally unique by contract
        }
        return index
    }

    /// Walk a material program's composition tree and collect authored-asset ids — `.image(assetID)`
    /// layers that are not the program's bound media layer. Mirrors the Task-003 reference walk.
    private static func authoredAssetIDs(_ program: RenderMaterialProgram) -> Set<String> {
        var ids = Set<String>()
        let compByID = Dictionary(uniqueKeysWithValues: program.compositions.map { ($0.id, $0) })
        func walk(_ comp: RenderComposition, visiting: Set<String>) {
            guard !visiting.contains(comp.id) else { return }
            let next = visiting.union([comp.id])
            for layer in comp.layers {
                let isBinding = (comp.id == program.binding.boundCompID
                                 && layer.id == program.binding.boundLayerID)
                switch layer.content {
                case let .image(assetID) where !isBinding:
                    ids.insert(assetID)
                case let .precomp(compID):
                    if let sub = compByID[compID] { walk(sub, visiting: next) }
                default:
                    break
                }
            }
        }
        if let root = compByID[program.rootCompID] { walk(root, visiting: []) }
        return ids
    }

    // MARK: - Test seams (DEBUG, internal — for focused unit tests)

    /// Raw fixed-point scalars produced by placement conversion, for assertions.
    struct PlacementRaw: Equatable {
        let fitModeRaw: String
        let offsetXRaw: Int64
        let offsetYRaw: Int64
        let scaleRaw: Int64
        let rotationRaw: Int64
    }

    /// Test-only wrapper over `convertPlacement` that surfaces the raw fixed-point values.
    static func convertPlacementForTesting(_ p: NextBridgePlacement) throws -> PlacementRaw {
        let mp = try convertPlacement(p)
        return PlacementRaw(
            fitModeRaw: mp.fitMode.rawValue,
            offsetXRaw: mp.userOffsetX.rawValue,
            offsetYRaw: mp.userOffsetY.rawValue,
            scaleRaw: mp.userScale.rawValue,
            rotationRaw: mp.userRotation.rawValue)
    }

    // MARK: - Image decode (DEBUG-local, audited BGRA8 premultiplied path)

    /// Decode a file URL to a premultiplied BGRA8 `ResolvedPixelInput` in canonical `.up`
    /// orientation. Mirrors the audited CGContext path used by `DownsampledImageLoader`,
    /// kept local so the bridge has no production coupling.
    private static func decodeImageToPixelInput(url: URL, id: String, maxPixelSize: Int) throws -> ResolvedPixelInput {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw NextBridgeError.imageDecodeFailed(url)
        }
        // Create an orientation-normalized image (transform applied -> canonical .up), DOWNSAMPLED to
        // at most `maxPixelSize` on the long edge. A full-res camera photo (~12MP) decoded to BGRA8
        // is ~48MB/copy; held across the frame cache + ResolvedFrameInput copies that exceeded the
        // 3GB process limit and the OS killed the app. Cap to the canvas size — more is invisible.
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(16, maxPixelSize)
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
            throw NextBridgeError.imageDecodeFailed(url)
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)

        // BGRA premultiplied: byteOrder32Little (BGRA on little-endian) + premultipliedFirst.
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            throw NextBridgeError.imageDecodeFailed(url)
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        do {
            let dims = try PixelDimensions(
                width: width, height: height, bytesPerRow: bytesPerRow,
                format: .bgra8, orientation: .up)
            return try ResolvedPixelInput(
                id: try PixelInputID(id), dimensions: dims, bytes: Data(bytes))
        } catch {
            throw NextBridgeError.engine("pixel input: \(error)")
        }
    }
}
#endif
