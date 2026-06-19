import Foundation
import AnimiEngineCore
import AnimiEngineRenderModel

/// Task-003 plan §17 step 7 — the compiled-template → canonical conversion (Stage-6 corrected).
///
/// The request carries the **raw `.tve` bytes** (decoded internally so the input hash and the decoded
/// content can never disagree), the catalog id, the scene instance/payload ids, a complete variant
/// selection (validated here against the inventory), exactly one explicit image/video binding per
/// block, and an explicit `requiredPostRoll` (no default). It produces:
///
///   * a single canonical `CanonicalProjectDocument` (one `SceneLayer` per media block, authored
///     order, exact canvas/fps/duration, exact tick ranges, fixed-point placement, selected animation);
///   * an immutable `RenderMaterialTable` whose programs carry the **complete selected AnimIR** in
///     RenderModel fixed-point/rational types (no DTO/Double/path/URL/pixel/adapter dependency);
///   * three separate deterministic hashes: `compiledTemplateHash` (raw input bytes, independent of
///     selection/media/instance ids), `projectHash` (canonical project bytes), `materialHash`
///     (complete selected material program table).
///
/// Nothing is generated or defaulted; every failure is typed; the conversion is pure. No transitions
/// or overlays are emitted; only the selected variant is converted. There is no `?? ""` / `?? 0`,
/// no `[0]` index, and no force-unwrap on the conversion path (item 6).
public enum CompiledTemplateConverter {

    // MARK: - Explicit input

    /// The explicit, deterministic media binding for one block (item 1, item 7).
    ///
    /// Step-8 corrective (issue #1b): every binding carries the full authored ``MediaPlacement`` (fit
    /// mode + user offset/scale/rotation). The converter validates the chosen fit against the block's
    /// `fitModesAllowed` and threads the placement onto the `SceneLayer`. There is no implicit default
    /// fit — the caller must choose one.
    public enum MediaBinding: Equatable, Sendable {
        case image(reference: String, mediaPlacement: MediaPlacement)
        case video(mediaReference: String, trimStartTicks: Int64, trimEndTicks: Int64,
                   nativeTimescale: Int64, mediaPlacement: MediaPlacement)

        /// The authored media placement carried by this binding.
        public var mediaPlacement: MediaPlacement {
            switch self {
            case let .image(_, mediaPlacement): return mediaPlacement
            case let .video(_, _, _, _, mediaPlacement): return mediaPlacement
            }
        }
    }

    /// A complete, explicit conversion request (item 1, item 5).
    public struct Request: Sendable {
        /// The raw `.tve` bytes; decoded internally (item 4).
        public let compiledTemplateData: Data
        public let catalogID: String
        public let sceneInstanceID: String
        public let scenePayloadID: String
        public let selection: TemplateVariantInventory.Selection
        public let mediaBindings: [String: MediaBinding]
        /// Explicit requested continuation past nominal scene duration (item 5). No default.
        public let requiredPostRoll: TickDuration

        public init(
            compiledTemplateData: Data,
            catalogID: String,
            sceneInstanceID: String,
            scenePayloadID: String,
            selection: TemplateVariantInventory.Selection,
            mediaBindings: [String: MediaBinding],
            requiredPostRoll: TickDuration
        ) {
            self.compiledTemplateData = compiledTemplateData
            self.catalogID = catalogID
            self.sceneInstanceID = sceneInstanceID
            self.scenePayloadID = scenePayloadID
            self.selection = selection
            self.mediaBindings = mediaBindings
            self.requiredPostRoll = requiredPostRoll
        }
    }

    /// The conversion product.
    public struct Output: Sendable {
        public let document: CanonicalProjectDocument
        public let materials: RenderMaterialTable
        /// SHA-256 of the raw compiled bytes — independent of selection, media, and instance ids.
        public let compiledTemplateHash: String
        /// SHA-256 of the canonical project bytes.
        public let projectHash: String
        /// SHA-256 of the complete selected material program table.
        public let materialHash: String
    }

    // MARK: - Conversion

    public static func convert(_ request: Request) throws -> Output {
        // Decode internally (item 4): the hash and the decoded content share one source of bytes.
        let decoded = try CompiledTemplateDecoder.decode(request.compiledTemplateData)
        let compiledTemplateHash = TemplateContentHash.compiledTemplateHash(request.compiledTemplateData)

        let runtime = decoded.payload.compiled.runtime
        let scene = runtime.scene

        // Authoritative scene identity must be present (item 8).
        guard let sceneID = scene.sceneID, !sceneID.isEmpty else {
            throw TemplateConversionError.missingSceneID
        }

        // Strict selection validation (item 1): missing / extra / unknown selections surface as the
        // dedicated typed selection error, NOT as a binding/runtime error.
        let inventory = try TemplateVariantInventory(from: decoded)
        try inventory.validate(selection: request.selection)

        guard request.requiredPostRoll.ticks >= 0 else {
            throw TemplateConversionError.negativePostRoll(ticks: request.requiredPostRoll.ticks)
        }

        // Frame rate / exact ticks-per-frame.
        let frameRate = try Self.frameRate(forFPS: scene.canvas.fps)
        let ticksPerFrame = try frameRate.exactTicksPerFrame

        let canvas = try CanvasSize(width: Int64(scene.canvas.width), height: Int64(scene.canvas.height))
        let outputContext = OutputContext(canvas: canvas, frameRate: frameRate)
        let durationTicks = try CheckedInt64.multiply(
            Int64(scene.canvas.durationFrames), ticksPerFrame, "scene.duration")
        let nominalDuration = try TickDuration(ticks: durationTicks)

        // Reject bindings for blocks that are not authored (item 8).
        let authoredBlockIDs = Set(scene.mediaBlocks.map(\.blockID))
        for key in request.mediaBindings.keys.sorted() where !authoredBlockIDs.contains(key) {
            throw TemplateConversionError.unknownBlockBinding(blockID: key)
        }

        let runtimeByID = Dictionary(uniqueKeysWithValues: runtime.blocks.map { ($0.blockID, $0) })
        let sceneRegistry = decoded.payload.compiled.pathRegistry.paths   // scene-level (item 1)
        let instanceID = try SceneInstanceID(request.sceneInstanceID)

        var layers: [SceneLayer] = []
        var programs: [RenderMaterialProgram] = []
        var sceneBindings: [SceneMaterialBinding] = []
        layers.reserveCapacity(scene.mediaBlocks.count)
        programs.reserveCapacity(scene.mediaBlocks.count)

        for block in scene.mediaBlocks {
            guard let runtimeBlock = runtimeByID[block.blockID] else {
                throw TemplateConversionError.missingRuntimeBlock(blockID: block.blockID)
            }
            guard let selectedVariantID = request.selection.chosenVariantByBlockID[block.blockID] else {
                // Selection validated above; a missing entry here is impossible, but fail closed.
                throw TemplateConversionError.missingBlockBinding(blockID: block.blockID)
            }
            guard let binding = request.mediaBindings[block.blockID] else {
                throw TemplateConversionError.missingBlockBinding(blockID: block.blockID)
            }
            guard let selectedRuntimeVariant = runtimeBlock.variants.first(where: { $0.variantID == selectedVariantID }) else {
                throw TemplateConversionError.missingRuntimeVariant(blockID: block.blockID, variantID: selectedVariantID)
            }

            let layer = try Self.makeLayer(
                block: block, runtimeBlock: runtimeBlock, selectedVariantID: selectedVariantID,
                binding: binding, ticksPerFrame: ticksPerFrame,
                nominalTicks: nominalDuration.ticks, requiredPostRoll: request.requiredPostRoll.ticks)
            // Continuation is validated over the layer's *effective* active range (which already
            // includes post-roll only for layers that reach the nominal scene end).
            try Self.validateContinuation(layer: layer, binding: binding, blockID: block.blockID)
            layers.append(layer)

            let program = try Self.makeProgram(
                block: block, runtimeBlock: runtimeBlock, selectedRuntimeVariant: selectedRuntimeVariant,
                sceneRegistry: sceneRegistry, compiledTemplateHash: compiledTemplateHash)
            programs.append(program)
            // Scene binding: (sceneInstanceID, layerID == blockID) → this program's material id (item 4).
            sceneBindings.append(SceneMaterialBinding(
                key: SceneMaterialBindingKey(sceneID: instanceID, layerID: layer.id), materialID: program.id))
        }

        // Assemble the single-scene canonical document.
        let payloadID = try ScenePayloadID(request.scenePayloadID)
        let templateRef = try TemplateReference(catalogID: request.catalogID, sceneID: sceneID)
        let payload = ResolvedScenePayload(
            payloadID: payloadID, sceneID: instanceID, templateRef: templateRef, layers: layers)
        let sceneEntry = SceneManifestEntry(
            id: instanceID, payloadID: payloadID,
            nominalDuration: nominalDuration, postRollCapability: request.requiredPostRoll)  // item 5
        let manifest = CanonicalProjectManifest(
            schemaVersion: CanonicalProjectManifest.supportedSchemaVersion,
            output: outputContext, scenes: [sceneEntry], boundaryTransitions: [], overlays: [])
        let document = CanonicalProjectDocument(
            manifest: manifest, scenePayloads: [payload], overlayPayloads: [])

        let materialTable = try RenderMaterialTable(
            programs: programs, sceneBindings: sceneBindings, pixelInputs: [])

        // Hashes (item 4, item 6).
        let projectBytes = try CanonicalProjectEncoding.encode(document)
        let projectHash = TemplateContentHash.projectHash(projectBytes)
        let materialHash = try TemplateContentHash.materialHash(materialTable)

        return Output(
            document: document, materials: materialTable,
            compiledTemplateHash: compiledTemplateHash, projectHash: projectHash, materialHash: materialHash)
    }

    // MARK: - Layer construction

    private static func makeLayer(
        block: CompiledMediaBlockDTO, runtimeBlock: CompiledBlockDTO,
        selectedVariantID: String, binding: MediaBinding, ticksPerFrame: Int64,
        nominalTicks: Int64, requiredPostRoll: Int64
    ) throws -> SceneLayer {
        let startTicks = try CheckedInt64.multiply(Int64(runtimeBlock.timing.startFrame), ticksPerFrame, "block.timing.start")
        let authoredEndTicks = try CheckedInt64.multiply(Int64(runtimeBlock.timing.endFrame), ticksPerFrame, "block.timing.end")

        // Post-roll visibility (item 1): only a layer whose authored active range ends **exactly** at
        // the nominal scene end is extended to cover nominal + requiredPostRoll. A layer ending before
        // the nominal end is left unchanged (and is not validated through post-roll).
        let effectiveEndTicks: Int64
        if authoredEndTicks == nominalTicks {
            effectiveEndTicks = try CheckedInt64.add(nominalTicks, requiredPostRoll, "block.activeRange.postRoll")
        } else {
            effectiveEndTicks = authoredEndTicks
        }
        let activeRange = try ScenePlaybackRange(
            start: try ScenePlaybackTime(ticks: startTicks),
            end: try ScenePlaybackTime(ticks: effectiveEndTicks))

        let placement = try Self.placement(forRect: block.rect, blockID: block.blockID)
        let content = try Self.content(for: binding, blockID: block.blockID)
        // Step-8 corrective (issue #1b): validate the chosen fit against the template's allowed set and
        // thread the authored media placement onto the layer. No implicit default fit.
        let mediaPlacement = try Self.validatedMediaPlacement(binding.mediaPlacement, block: block)
        let animation = try CompiledAnimationConverter.convert(
            block: block, selectedVariantID: selectedVariantID, ticksPerFrame: ticksPerFrame)

        return SceneLayer(
            id: try LayerID(block.blockID),
            zIndex: runtimeBlock.zIndex,
            stableOrdinal: runtimeBlock.orderIndex,
            activeRange: activeRange,
            placement: placement,
            mediaPlacement: mediaPlacement,
            content: content,
            animation: animation)
    }

    /// Validates the authored fit against the block's `fitModesAllowed` (issue #1b). When the template
    /// pins a non-empty allowed set, the chosen fit must be a member; an empty/absent set means the
    /// template does not constrain the fit. There is no implicit default — the chosen fit comes from
    /// the caller's `MediaPlacement`.
    private static func validatedMediaPlacement(
        _ mediaPlacement: MediaPlacement, block: CompiledMediaBlockDTO
    ) throws -> MediaPlacement {
        if let allowed = block.input.fitModesAllowed, !allowed.isEmpty {
            let chosen = CompiledFitMode(rawValue: mediaPlacement.fitMode.rawValue)
            guard let chosen, allowed.contains(chosen) else {
                throw TemplateConversionError.fitModeNotAllowed(
                    blockID: block.blockID, chosen: mediaPlacement.fitMode.rawValue,
                    allowed: allowed.map(\.rawValue).sorted())
            }
        }
        return mediaPlacement
    }

    private static func placement(forRect rect: CompiledRectDTO, blockID: String) throws -> Placement {
        let frame = try Self.fixedRect(rect, field: "block[\(blockID)].rect")
        return try Placement(frame: frame, scale: .one, rotation: .zero)
    }

    private static func fixedRect(_ rect: CompiledRectDTO, field: String) throws -> FixedRect {
        try FixedRect(
            x: try FixedPointConversion.canvasScalar(points: rect.x, field: "\(field).x"),
            y: try FixedPointConversion.canvasScalar(points: rect.y, field: "\(field).y"),
            width: try FixedPointConversion.canvasScalar(points: rect.width, field: "\(field).width"),
            height: try FixedPointConversion.canvasScalar(points: rect.height, field: "\(field).height"))
    }

    private static func content(for binding: MediaBinding, blockID: String) throws -> SceneLayerContent {
        switch binding {
        case let .image(reference, _):
            do { return .image(try ImageReference(reference)) }
            catch { throw TemplateConversionError.invalidMediaReference(blockID: blockID) }
        case let .video(mediaReference, trimStartTicks, trimEndTicks, nativeTimescale, _):
            guard trimEndTicks > trimStartTicks else {
                throw TemplateConversionError.invalidVideoTrim(blockID: blockID)
            }
            let media: MediaReference
            do { media = try MediaReference(mediaReference) }
            catch { throw TemplateConversionError.invalidMediaReference(blockID: blockID) }
            let trimRange = try RationalSourceRange(
                start: try RationalSourceTime(numerator: trimStartTicks, denominator: TickClock.ticksPerSecond),
                end: try RationalSourceTime(numerator: trimEndTicks, denominator: TickClock.ticksPerSecond))
            let timescale = try SourceTimescale(unitsPerSecond: nativeTimescale)
            let mapping = SourceTimeMapping(trimRange: trimRange, nativeTimescale: timescale, rate: .oneToOne)
            return .video(VideoBinding(media: media, sourceMapping: mapping))
        }
    }

    // MARK: - Continuation validation (item 5)

    /// Validates that the layer can play across its **effective** active range
    /// `[activeRange.start, activeRange.end)` — which already includes post-roll for layers reaching
    /// the nominal scene end, and is the authored range for layers ending earlier (item 1):
    ///   * images need no temporal material (always satisfy continuation);
    ///   * video must have its source targets contained in the trim range across the whole range —
    ///     a trim that ends before the effective end cannot satisfy the post-roll;
    ///   * a `becomeInactive` animation must not be required past its authored end; `holdLast`/`loop`
    ///     animations satisfy continuation.
    private static func validateContinuation(
        layer: SceneLayer, binding: MediaBinding, blockID: String
    ) throws {
        let lo = layer.activeRange.start.ticks
        let hi = layer.activeRange.end.ticks
        guard hi > lo else { return }
        let firstTick = lo
        let lastTick = hi - 1

        switch layer.content {
        case .image:
            break
        case .video(let videoBinding):
            let firstTarget = try videoBinding.sourceMapping.target(for: try ScenePlaybackTime(ticks: firstTick))
            let lastTarget = try videoBinding.sourceMapping.target(for: try ScenePlaybackTime(ticks: lastTick))
            guard videoBinding.sourceMapping.trimRange.contains(firstTarget),
                  videoBinding.sourceMapping.trimRange.contains(lastTarget) else {
                throw TemplateConversionError.insufficientVideoContinuation(blockID: blockID)
            }
        }

        if let animation = layer.animation, animation.ifShorter == .becomeInactive,
           lastTick >= animation.authoredDuration.ticks {
            throw TemplateConversionError.insufficientAnimationContinuation(blockID: blockID)
        }
    }

    // MARK: - Program construction (item 2, item 3)

    private static func makeProgram(
        block: CompiledMediaBlockDTO, runtimeBlock: CompiledBlockDTO,
        selectedRuntimeVariant: CompiledVariantDTO,
        sceneRegistry: [CompiledPathEntryDTO], compiledTemplateHash: String
    ) throws -> RenderMaterialProgram {
        // Structured, collision-safe identity (item 4): compiled hash + block id + variant id.
        let materialID = try RenderMaterialID(
            compiledTemplateHash: compiledTemplateHash,
            blockID: block.blockID, variantID: selectedRuntimeVariant.variantID)

        // Render-required media geometry, kept explicitly separate from the bound asset (item 3, 5):
        // baseline content size + rect, the media-input placement rect, and the container-clip policy.
        let baseline = runtimeBlock.bindingBaseline
        let mediaGeometry = RenderMediaGeometry(
            contentSizeWidth: try FixedPointConversion.canvasScalar(
                points: baseline.contentSizeLocal.width, field: "block[\(block.blockID)].contentSize.width"),
            contentSizeHeight: try FixedPointConversion.canvasScalar(
                points: baseline.contentSizeLocal.height, field: "block[\(block.blockID)].contentSize.height"),
            // NOTE: the WHOLE animation coordinate space (TVECore animIR.meta.size) is NOT duplicated here;
            // it is carried once by `RenderProgramMeta.width/height` (same animIR.meta.size). The canonical
            // block→canvas transform reads it from `program.meta`. (CP4 Rev-4 canonical cleanup.)
            contentRect: try Self.fixedRect(baseline.contentRectLocal, field: "block[\(block.blockID)].contentRect"),
            placementRect: try Self.fixedRect(
                runtimeBlock.mediaInputGeometry.placementRectLocal, field: "block[\(block.blockID)].placementRect"),
            // slotRect container clip target — the block's canvas rect (oracle: block.rectCanvas), issue #2.
            blockRectCanvas: try Self.fixedRect(block.rect, field: "block[\(block.blockID)].rectCanvas"),
            containerClip: runtimeBlock.containerClip.rawValue)

        // Toggle ids present in the selected variant's AnimIR.
        let toggleIDs = try selectedRuntimeVariant.animIR.validatedToggleIDs(
            path: "block[\(block.blockID)].variant[\(selectedRuntimeVariant.variantID)]")

        return try CompiledAnimationProgramConverter.convert(
            animIR: selectedRuntimeVariant.animIR,
            sceneRegistry: sceneRegistry,
            materialID: materialID,
            blockID: block.blockID,
            variantID: selectedRuntimeVariant.variantID,
            animationRef: selectedRuntimeVariant.animRef,
            mediaGeometry: mediaGeometry,
            toggleIDs: Array(toggleIDs))
    }

    // MARK: - Frame rate mapping

    private static func frameRate(forFPS fps: Int) throws -> FrameRate {
        switch fps {
        case 24: return .fps24
        case 25: return .fps25
        case 30: return .fps30
        case 50: return .fps50
        case 60: return .fps60
        default: throw TemplateConversionError.unsupportedFrameRate(fps: fps)
        }
    }
}
