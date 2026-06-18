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
enum NextBridgeError: Error, CustomStringConvertible {
    case noScene
    case multiSceneUnsupported(sceneItemCount: Int)
    case notASceneItem
    case sceneFolderMissing(sceneTypeId: String)
    case compiledTemplateMissing(URL)
    case multiBlockUnsupported(blockCount: Int)
    case noMediaBound(blockID: String)
    case blockHidden(blockID: String)
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
            return "Next bridge: media block '\(blockID)' is hidden (visibility=false). (CP2: fail closed)"
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

/// Inputs the caller must assemble from existing app state before invoking the bridge.
/// CP2 single-scene scope: exactly ONE scene, ONE media block.
struct NextBridgeInputs {
    /// Scene type id of the (single) open scene — from the single timeline scene item's payload.
    let sceneTypeId: String
    /// Folder URL of the scene package — `SceneTypeDescriptor.folderURL`.
    let sceneFolderURL: URL
    /// Per-block variant selection — `SceneState.variantOverrides` (may be partial).
    let variantOverrides: [String: String]
    /// The block id whose media the caller resolved (the single media block).
    let mediaBlockID: String
    /// Resolved absolute file URL of the bound photo for `mediaBlockID`.
    let mediaURL: URL
    /// App placement for `mediaBlockID` — converted to canonical fixed-point by the bridge.
    let placement: NextBridgePlacement
    /// Current playhead frame index (single-scene local frame == project frame).
    let frameIndex: Int
}

/// Plain BGRA8 frame the editor can present without importing any AnimiEngineNext module
/// (avoids `RenderCommand` name collision with TVECore in `EditorViewController`).
struct NextBridgeBGRAFrame {
    let bytes: Data
    let width: Int
    let height: Int
    let bytesPerRow: Int
}

/// Placement-INDEPENDENT decoded media (CP3 perf): the compiled.tve bytes + decoded photo pixels.
/// Cached keyed by `(scene, variant, media)` ONLY — a placement/fit/scale/rotation change reuses
/// this (no image re-decode), so dragging the media is fast. Authored-asset pixels also live here.
final class NextDecodedMedia {
    let compiledData: Data
    let blockID: String
    let chosenVariantID: String
    let mediaReference: String
    let photoPixels: ResolvedPixelInput
    /// Decoded authored-asset pixels keyed by (materialID, assetID) — content is placement-free, but
    /// the RenderMaterialID embeds the compiled-template hash (stable across placement), so reusable.
    let assetPixelsByKey: [ResolvedAssetKey: ResolvedPixelInput]
    let canvasMaxPixel: Int

    init(compiledData: Data, blockID: String, chosenVariantID: String, mediaReference: String,
         photoPixels: ResolvedPixelInput, assetPixelsByKey: [ResolvedAssetKey: ResolvedPixelInput],
         canvasMaxPixel: Int) {
        self.compiledData = compiledData; self.blockID = blockID; self.chosenVariantID = chosenVariantID
        self.mediaReference = mediaReference; self.photoPixels = photoPixels
        self.assetPixelsByKey = assetPixelsByKey; self.canvasMaxPixel = canvasMaxPixel
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
    let mediaReference: String
    let photoPixels: ResolvedPixelInput
    let assetEntries: [ResolvedAssetPixelEntry]
    let configuration: RenderConfiguration
    let session: MetalRenderSession
    let totalFrames: Int

    init(materials: RenderMaterialTable, window: EvaluationWindow, mediaReference: String,
         photoPixels: ResolvedPixelInput, assetEntries: [ResolvedAssetPixelEntry],
         configuration: RenderConfiguration, session: MetalRenderSession, totalFrames: Int) {
        self.materials = materials; self.window = window; self.mediaReference = mediaReference
        self.photoPixels = photoPixels; self.assetEntries = assetEntries
        self.configuration = configuration; self.session = session; self.totalFrames = totalFrames
    }
}

/// Opaque holder for the shared `MetalRenderSession` so `NextPreviewController` can own/reuse one
/// session without importing `AnimiEngineMetalRender` (which would collide with TVECore types in
/// the editor module). Created once via `NextSingleSceneBridge.makeSession`.
final class NextSessionBox {
    let session: MetalRenderSession
    init(session: MetalRenderSession) { self.session = session }
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

        guard inventory.blocks.count == 1 else {
            throw NextBridgeError.multiBlockUnsupported(blockCount: inventory.blocks.count)
        }
        let block = inventory.blocks[0]
        guard block.blockID == inputs.mediaBlockID else {
            throw NextBridgeError.noMediaBound(blockID: inputs.mediaBlockID)
        }
        let chosenVariantID = inputs.variantOverrides[block.blockID] ?? block.selectedVariantID
        let mediaReference = "cp3-\(block.blockID)"

        // Convert with IDENTITY placement just to obtain materials/canvas for asset walking. The
        // assemble() step re-converts with the real placement (cheap).
        let selection = TemplateVariantInventory.Selection(chosenVariantByBlockID: [block.blockID: chosenVariantID])
        let probeOut: CompiledTemplateConverter.Output
        do {
            probeOut = try CompiledTemplateConverter.convert(.init(
                compiledTemplateData: data, catalogID: inputs.sceneTypeId,
                sceneInstanceID: "cp3-inst", scenePayloadID: "cp3-pay", selection: selection,
                mediaBindings: [block.blockID: .image(reference: mediaReference, mediaPlacement: .identity(fitMode: .contain))],
                requiredPostRoll: .zero))
        } catch { throw NextBridgeError.engine("convert(probe): \(error)") }

        let canvas = probeOut.document.manifest.output.canvas
        let maxPixel = Int(max(canvas.width, canvas.height))

        // Decode photo (heavy) downsampled to canvas.
        let photoPixels = try decodeImageToPixelInput(url: inputs.mediaURL, id: mediaReference, maxPixelSize: maxPixel)

        // Decode authored-asset pixels (e.g. plastik) using a frame-0 probe resolve.
        let probeWindow = try buildWindow(probeOut.document).window
        let probePlan = try evaluatePlan(window: probeWindow, frame: 0)
        guard case let .single(probeSubplan) = probePlan.body else {
            throw NextBridgeError.unsupportedFramePlan("expected single scene body")
        }
        let probeFixtures = try buildFixtures(subplan: probeSubplan, mediaReference: mediaReference, photoPixels: photoPixels)
        let probeBase: ResolvedFrameInput
        do { probeBase = try RenderInputResolver.resolve(framePlan: probePlan, materials: probeOut.materials, fixtures: probeFixtures) }
        catch { throw NextBridgeError.engine("resolve(probe): \(error)") }
        let entries = try loadAuthoredAssets(subplan: probeSubplan, base: probeBase, maxPixelSize: maxPixel)
        var assetPixelsByKey: [ResolvedAssetKey: ResolvedPixelInput] = [:]
        for e in entries { assetPixelsByKey[e.key] = e.pixelInput }

        return NextDecodedMedia(
            compiledData: data, blockID: block.blockID, chosenVariantID: chosenVariantID,
            mediaReference: mediaReference, photoPixels: photoPixels,
            assetPixelsByKey: assetPixelsByKey, canvasMaxPixel: maxPixel)
    }

    // MARK: - Assemble (light, placement-DEPENDENT — reuses decoded media)

    /// Build a render context for a given placement, REUSING the decoded media (no image re-decode).
    /// Only convert + window are placement-dependent here.
    static func assemble(decoded: NextDecodedMedia, placement: NextBridgePlacement, sessionBox: NextSessionBox) throws -> NextPreparedContext {
        let mediaPlacement = try convertPlacement(placement)
        let selection = TemplateVariantInventory.Selection(chosenVariantByBlockID: [decoded.blockID: decoded.chosenVariantID])
        let out: CompiledTemplateConverter.Output
        do {
            out = try CompiledTemplateConverter.convert(.init(
                compiledTemplateData: decoded.compiledData, catalogID: "cp3", sceneInstanceID: "cp3-inst",
                scenePayloadID: "cp3-pay", selection: selection,
                mediaBindings: [decoded.blockID: .image(reference: decoded.mediaReference, mediaPlacement: mediaPlacement)],
                requiredPostRoll: .zero))
        } catch { throw NextBridgeError.engine("convert: \(error)") }

        let (window, totalFrames) = try buildWindow(out.document)

        // Rebuild asset entries from cached pixels, keyed by the program material IDs in THIS convert.
        var assetEntries: [ResolvedAssetPixelEntry] = []
        for (key, pix) in decoded.assetPixelsByKey {
            assetEntries.append(ResolvedAssetPixelEntry(key: key, pixelInput: pix))
        }

        let configuration: RenderConfiguration
        do {
            configuration = try RenderConfiguration(
                output: out.document.manifest.output, colorContract: .task003, intermediateProfile: .rgba16FloatLinear)
        } catch { throw NextBridgeError.engine("config: \(error)") }

        return NextPreparedContext(
            materials: out.materials, window: window, mediaReference: decoded.mediaReference,
            photoPixels: decoded.photoPixels, assetEntries: assetEntries, configuration: configuration,
            session: sessionBox.session, totalFrames: totalFrames)
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

    static func renderFrame(context ctx: NextPreparedContext, frameIndex: Int) throws -> RenderedFrame {
        let plan = try evaluatePlan(window: ctx.window, frame: max(0, frameIndex))
        guard case let .single(subplan) = plan.body else {
            throw NextBridgeError.unsupportedFramePlan("expected single scene body")
        }
        let fixtures = try buildFixtures(subplan: subplan, mediaReference: ctx.mediaReference, photoPixels: ctx.photoPixels)
        let base: ResolvedFrameInput
        do { base = try RenderInputResolver.resolve(framePlan: plan, materials: ctx.materials, fixtures: fixtures) }
        catch { throw NextBridgeError.engine("resolve: \(error)") }
        let resolved = try rebuildWithAssetEntries(subplan: subplan, base: base, assetEntries: ctx.assetEntries)
        let graph: RenderGraph
        do { graph = try RenderGraphCompiler.compile(plan: plan, input: resolved, configuration: ctx.configuration) }
        catch { throw NextBridgeError.engine("compile: \(error)") }
        do { return try ctx.session.execute(graph) }
        catch { throw NextBridgeError.engine("execute: \(error)") }
    }

    // MARK: - Shared frame helpers

    private static func evaluatePlan(window: EvaluationWindow, frame: Int) throws -> FramePlan {
        do { return try TimelineEvaluator.evaluate(window, atFrame: try FrameIndex(value: Int64(frame))) }
        catch { throw NextBridgeError.engine("evaluate: \(error)") }
    }

    /// Bind the user photo ONLY to the media reference (authored assets use assetPixels, not this).
    private static func buildFixtures(subplan: SceneSubplan, mediaReference: String, photoPixels: ResolvedPixelInput)
        throws -> [RenderInputResolver.FixtureKey: ResolvedPixelInput] {
        var fixtures: [RenderInputResolver.FixtureKey: ResolvedPixelInput] = [:]
        var found = false
        for layer in subplan.layers {
            if case let .image(ref) = layer.content, ref.raw == mediaReference {
                fixtures[.image(reference: mediaReference)] = photoPixels
                found = true
            }
        }
        guard found else {
            throw NextBridgeError.unsupportedFramePlan("bound media reference '\(mediaReference)' not present in frame plan")
        }
        return fixtures
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
        for layer in subplan.layers {
            let key = ResolvedLayerKey.sceneLayer(
                sceneID: subplan.sceneID, role: .sole, layerID: layer.layerID)
            guard let program = base.program(for: key),
                  let placement = base.mediaPlacement(for: key),
                  let pixels = base.pixelInput(for: key) else { continue }
            sceneEntries.append(try ResolvedSceneLayerEntry(
                key: key, program: program, pixelInput: pixels, placement: placement))
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
