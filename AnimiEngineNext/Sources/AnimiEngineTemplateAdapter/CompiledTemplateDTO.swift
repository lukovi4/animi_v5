/// Strict DTOs for the top-level schema-2 `.tve` payload (Task-003 plan §5.2, §14.3 —
/// `CompiledTemplateDTO.swift`). The AnimIR subtree lives in `CompiledAnimIRDTO.swift`.
///
/// Every field, enum, nullable rule and relationship is derived **only** from the compiled-format
/// producer (`TVECore`/`TVECompilerCore`) and the five real fixtures (Stage-4 correction: do not
/// invent schema). Producer sources:
///   * `CompiledScenePayload` (`templateId: String?`, `templateRevision: Int`, `engineVersion`,
///     `compiled: CompiledScene`).
///   * `CompiledScene` (`runtime, mergedAssetIndex, pathRegistry, bindingAssetIds: Set<String>`).
///   * `SceneRuntime`, `BlockRuntime`, `BindingBaselineRuntime`, `MediaInputGeometryRuntime`,
///     `BlockTiming` — `ScenePlayerTypes.swift`.
///   * `Scene`, `Canvas`, `Background`, `MediaBlock`, `MediaInput`, `Variant`, `LayerToggle`,
///     `Timing`, `Rect`, plus enums `HitTestMode`, `ContainerClip`, `FitMode`, `EmptyPolicy`,
///     `AnimationDurationBehavior` — `TVECore/Models/*`.
///   * `PathRegistry`, `PathResource`, `PathID` — `PathResource.swift`.
///
/// The whole owned schema is recursively strict: unknown fields and wrong types are rejected at
/// every level; the scene-level product policy is decoded into exact DTOs (its *conversion* into
/// canonical/product semantics remains deferred to §17 step 6+).

// MARK: - Decoded result

/// The fully decoded, strictly-validated compiled template (`Data -> DecodedCompiledTemplate`,
/// §5.2). It pairs the diagnostic envelope facts with the validated payload DTO.
public struct DecodedCompiledTemplate: Equatable, Sendable {
    /// Diagnostic envelope facts. The engine hash is metadata only (§5.2).
    public let envelope: CompiledTemplateEnvelope
    /// The validated schema-2 payload.
    public let payload: CompiledTemplatePayloadDTO
}

// MARK: - Top level

/// The schema-2 payload root. Producer `CompiledScenePayload`: `templateId` is **nullable**.
public struct CompiledTemplatePayloadDTO: Equatable, Sendable {
    let engineVersion: String
    let templateID: String?
    let templateRevision: Int
    let compiled: CompiledRuntimePackageDTO

    static func decode(_ value: CompiledJSONValue) throws -> CompiledTemplatePayloadDTO {
        var r = try value.requireObject(path: "")
        let engineVersion = try r.string("engineVersion")
        let templateID = try r.optionalString("templateId")
        let templateRevision = try r.intValue("templateRevision")
        let compiled = try CompiledRuntimePackageDTO.decode(try r.value("compiled"), path: "compiled")
        try r.finish()
        return CompiledTemplatePayloadDTO(
            engineVersion: engineVersion,
            templateID: templateID,
            templateRevision: templateRevision,
            compiled: compiled
        )
    }
}

/// `compiled` — producer `CompiledScene`: `runtime, mergedAssetIndex, pathRegistry,
/// bindingAssetIds (Set<String>, encoded as a JSON array)`.
struct CompiledRuntimePackageDTO: Equatable, Sendable {
    let runtime: CompiledRuntimeDTO
    let mergedAssetIndex: CompiledMergedAssetIndexDTO
    let pathRegistry: CompiledPathRegistryDTO
    let bindingAssetIDs: [String]

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledRuntimePackageDTO {
        var r = try value.requireObject(path: path)
        let runtime = try CompiledRuntimeDTO.decode(try r.value("runtime"), path: r.childPath("runtime"))
        let mergedAssetIndex = try CompiledMergedAssetIndexDTO.decode(
            try r.value("mergedAssetIndex"), path: r.childPath("mergedAssetIndex")
        )
        let pathRegistry = try CompiledPathRegistryDTO.decode(
            try r.value("pathRegistry"), path: r.childPath("pathRegistry")
        )

        // `bindingAssetIds` is a `Set<String>` in the producer → JSON array of strings; element
        // uniqueness is therefore required (a duplicate would be impossible from a real Set).
        let bindingValues = try r.array("bindingAssetIds")
        var bindingAssetIDs: [String] = []
        var seenBinding = Set<String>()
        for (i, bv) in bindingValues.enumerated() {
            let id = try bv.requireString(path: "\(r.childPath("bindingAssetIds"))[\(i)]")
            guard seenBinding.insert(id).inserted else {
                throw CompiledTemplateDecodingError.duplicateIdentifier(
                    kind: "bindingAssetId", id: id, path: r.childPath("bindingAssetIds")
                )
            }
            bindingAssetIDs.append(id)
        }
        try r.finish()

        let result = CompiledRuntimePackageDTO(
            runtime: runtime, mergedAssetIndex: mergedAssetIndex,
            pathRegistry: pathRegistry, bindingAssetIDs: bindingAssetIDs
        )
        try result.validateReferences(path: path)
        return result
    }

    /// Whole-package references that need the merged index, the path registry and the runtime
    /// together.
    private func validateReferences(path: String) throws {
        let mergedKeys = Set(mergedAssetIndex.byID.keys)
        let registryIDs = Set(pathRegistry.paths.map(\.pathID))

        // bindingAssetIds: every id resolves in the merged asset index (a referential check) AND
        // the set equals exactly the set of all variants' AnimIR `binding.boundAssetId` (item 4).
        for id in bindingAssetIDs where !mergedKeys.contains(id) {
            throw CompiledTemplateDecodingError.danglingReference(
                kind: "bindingAssetId", id: id, path: "\(path).bindingAssetIds"
            )
        }
        try validateBindingAssetSet(path: "\(path).bindingAssetIds")

        // scene media-block IDs resolve consistently to runtime blocks (bijection).
        let runtimeBlockIDs = Set(runtime.blocks.map(\.blockID))
        let sceneBlockIDs = Set(runtime.scene.mediaBlockIDs)
        guard runtimeBlockIDs == sceneBlockIDs else {
            let onlyScene = sceneBlockIDs.subtracting(runtimeBlockIDs).sorted()
            let onlyRuntime = runtimeBlockIDs.subtracting(sceneBlockIDs).sorted()
            throw CompiledTemplateDecodingError.danglingReference(
                kind: "sceneMediaBlockId",
                id: "scene-only=\(onlyScene) runtime-only=\(onlyRuntime)",
                path: "\(path).runtime.scene.mediaBlocks"
            )
        }

        // scene-level mirror values shared by all blocks.
        let sceneCanvas = runtime.scene.canvas
        guard runtime.canvas == sceneCanvas else {
            throw CompiledTemplateDecodingError.sceneRuntimeInconsistency(
                path: "\(path).runtime.canvas", detail: "runtime.canvas != scene.canvas"
            )
        }
        guard runtime.fps == sceneCanvas.fps else {
            throw CompiledTemplateDecodingError.sceneRuntimeInconsistency(
                path: "\(path).runtime.fps", detail: "runtime.fps \(runtime.fps) != scene.canvas.fps \(sceneCanvas.fps)"
            )
        }
        guard runtime.durationFrames == sceneCanvas.durationFrames else {
            throw CompiledTemplateDecodingError.sceneRuntimeInconsistency(
                path: "\(path).runtime.durationFrames",
                detail: "runtime.durationFrames \(runtime.durationFrames) != scene.canvas.durationFrames \(sceneCanvas.durationFrames)"
            )
        }

        let sceneBlocks = runtime.scene.mediaBlocks
        let sceneByID = Dictionary(uniqueKeysWithValues: sceneBlocks.map { ($0.blockID, $0) })

        for block in runtime.blocks {
            let blockPath = "\(path).runtime.block[\(block.blockID)]"

            // block bindingBaseline asset resolves in the merged index.
            if !mergedKeys.contains(block.bindingBaseline.boundAssetID) {
                throw CompiledTemplateDecodingError.danglingReference(
                    kind: "bindingBaseline.boundAssetId", id: block.bindingBaseline.boundAssetID, path: blockPath
                )
            }

            // pathId references resolve in the scene-level registry (per-variant).
            for variant in block.variants {
                let variantPath = "\(blockPath).variant[\(variant.variantID)]"
                for ref in variant.animIR.referencedPathIDs() where !registryIDs.contains(ref.id) {
                    throw CompiledTemplateDecodingError.danglingReference(
                        kind: "pathId", id: String(ref.id), path: "\(variantPath).\(ref.path)"
                    )
                }
            }

            guard let sceneBlock = sceneByID[block.blockID] else { continue }  // bijection proven above
            try validateBlockConsistency(runtimeBlock: block, sceneBlock: sceneBlock,
                                         sceneBlocks: sceneBlocks, sceneDurationFrames: sceneCanvas.durationFrames,
                                         path: blockPath)
            try validateBlockToggles(runtimeBlock: block, sceneBlock: sceneBlock,
                                     sceneID: runtime.scene.sceneID, path: blockPath)
        }
    }

    /// Item 4 — `bindingAssetIds` equals exactly the set of all variants' AnimIR `boundAssetId`.
    private func validateBindingAssetSet(path: String) throws {
        var actual = Set<String>()
        for block in runtime.blocks {
            for variant in block.variants {
                actual.insert(variant.animIR.boundAssetID)
            }
        }
        let declared = Set(bindingAssetIDs)
        guard declared == actual else {
            let missing = actual.subtracting(declared).sorted()   // bound but not declared
            let extra = declared.subtracting(actual).sorted()     // declared but never bound
            throw CompiledTemplateDecodingError.bindingAssetSetMismatch(missing: missing, extra: extra, path: path)
        }
    }

    /// Item 2 — the runtime block must be the producer's faithful derivation of its scene block.
    private func validateBlockConsistency(
        runtimeBlock: CompiledBlockDTO, sceneBlock: CompiledMediaBlockDTO,
        sceneBlocks: [CompiledMediaBlockDTO], sceneDurationFrames: Int, path: String
    ) throws {
        func fail(_ detail: String) -> Error {
            CompiledTemplateDecodingError.sceneRuntimeInconsistency(path: path, detail: detail)
        }

        // Variant ID sets identical, matching variants have identical animRef.
        let runtimeVariantIDs = Set(runtimeBlock.variants.map(\.variantID))
        let sceneVariantIDs = Set(sceneBlock.variants.map(\.variantID))
        guard runtimeVariantIDs == sceneVariantIDs else {
            throw fail("variant id sets differ: runtime=\(runtimeVariantIDs.sorted()) scene=\(sceneVariantIDs.sorted())")
        }
        let sceneVariantByID = Dictionary(uniqueKeysWithValues: sceneBlock.variants.map { ($0.variantID, $0) })
        for rv in runtimeBlock.variants {
            guard let sv = sceneVariantByID[rv.variantID] else {
                throw fail("runtime variant '\(rv.variantID)' absent from scene")
            }
            if rv.animRef != sv.animRef {
                throw fail("variant '\(rv.variantID)' animRef runtime=\(rv.animRef) scene=\(sv.animRef)")
            }
            // input.bindingKey == runtime variant.bindingKey == AnimIR binding.bindingKey.
            if rv.bindingKey != sceneBlock.input.bindingKey {
                throw fail("variant '\(rv.variantID)' bindingKey \(rv.bindingKey) != input.bindingKey \(sceneBlock.input.bindingKey)")
            }
            if rv.animIR.binding.bindingKey != sceneBlock.input.bindingKey {
                throw fail("variant '\(rv.variantID)' AnimIR binding.bindingKey \(rv.animIR.binding.bindingKey) != input.bindingKey \(sceneBlock.input.bindingKey)")
            }
            if rv.animIR.meta.sourceAnimRef != rv.animRef {
                throw fail("variant '\(rv.variantID)' AnimIR sourceAnimRef \(rv.animIR.meta.sourceAnimRef) != animRef \(rv.animRef)")
            }
        }

        // selectedVariantId == first authored scene variant.
        guard let firstSceneVariant = sceneBlock.variants.first else {
            throw fail("scene block has no variants")
        }
        if runtimeBlock.selectedVariantID != firstSceneVariant.variantID {
            throw fail("selectedVariantId \(runtimeBlock.selectedVariantID) != first scene variant \(firstSceneVariant.variantID)")
        }

        // editVariantId == "no-anim" and exists.
        if runtimeBlock.editVariantID != "no-anim" {
            throw fail("editVariantId \(runtimeBlock.editVariantID) != \"no-anim\"")
        }
        if !runtimeVariantIDs.contains("no-anim") {
            throw fail("editVariantId \"no-anim\" not present among variants")
        }

        // orderIndex uniquely points to the matching scene block.
        let sceneIndex = sceneBlocks.firstIndex { $0.blockID == runtimeBlock.blockID }
        guard let sceneIndex, runtimeBlock.orderIndex == sceneIndex else {
            throw fail("orderIndex \(runtimeBlock.orderIndex) != scene index \(sceneIndex.map(String.init) ?? "nil")")
        }

        // Mirrored block values agree.
        if runtimeBlock.zIndex != sceneBlock.zIndex {
            throw fail("zIndex runtime=\(runtimeBlock.zIndex) scene=\(sceneBlock.zIndex)")
        }
        if runtimeBlock.rectCanvas != sceneBlock.rect {
            throw fail("rectCanvas != scene.rect")
        }
        if runtimeBlock.containerClip != sceneBlock.containerClip {
            throw fail("containerClip runtime=\(runtimeBlock.containerClip) scene=\(sceneBlock.containerClip)")
        }
        if runtimeBlock.hitTestMode != sceneBlock.input.hitTest {
            throw fail("hitTestMode runtime=\(String(describing: runtimeBlock.hitTestMode)) scene=\(String(describing: sceneBlock.input.hitTest))")
        }
        // timing: runtime BlockTiming derives from scene timing, defaulting to the full scene window.
        let expected = sceneBlock.timing ?? CompiledFrameRangeDTO(startFrame: 0, endFrame: sceneDurationFrames)
        if runtimeBlock.timing != expected {
            throw fail("timing runtime=(\(runtimeBlock.timing.startFrame),\(runtimeBlock.timing.endFrame)) expected=(\(expected.startFrame),\(expected.endFrame))")
        }
    }

    /// Item 3 — layer toggles: scene toggle id set equals each variant's AnimIR toggle id set;
    /// matte/parent/duplicate rules; non-empty sceneId required when toggles exist.
    private func validateBlockToggles(
        runtimeBlock: CompiledBlockDTO, sceneBlock: CompiledMediaBlockDTO, sceneID: String?, path: String
    ) throws {
        let sceneToggleIDs = sceneBlock.layerToggles?.map(\.id) ?? []
        let expected = Set(sceneToggleIDs)

        if !expected.isEmpty {
            // Non-empty sceneId required when toggles exist.
            guard let sceneID, !sceneID.isEmpty else {
                throw CompiledTemplateDecodingError.layerToggleViolation(
                    path: path, detail: "layerToggles present but scene.sceneId is missing/empty"
                )
            }
        }

        for variant in runtimeBlock.variants {
            let variantPath = "\(path).variant[\(variant.variantID)]"
            // Per-variant: duplicate / matte-source / matte-consumer / parent checks + id collection.
            let found = try variant.animIR.validatedToggleIDs(path: variantPath)
            guard found == expected else {
                throw CompiledTemplateDecodingError.layerToggleViolation(
                    path: variantPath,
                    detail: "AnimIR toggle ids \(found.sorted()) != scene toggle ids \(expected.sorted())"
                )
            }
        }
    }
}

// MARK: - Merged asset index

/// `mergedAssetIndex` / AnimIR `assets`. Producer `AssetIndexIR`: three maps `byId ([String:String]),
/// sizeById ([String:AssetSize]), basenameById ([String:String])` with `AssetSize` doubles.
struct CompiledMergedAssetIndexDTO: Equatable, Sendable {
    let byID: [String: String]
    let basenameByID: [String: String]
    let sizeByID: [String: CompiledSizeDTO]

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledMergedAssetIndexDTO {
        var r = try value.requireObject(path: path)
        let byID = try decodeStringMap(try r.object("byId"))
        let basenameByID = try decodeStringMap(try r.object("basenameById"))
        let sizeByID = try decodeSizeMap(try r.object("sizeById"))
        try r.finish()

        let byIDKeys = Set(byID.keys)
        guard Set(basenameByID.keys) == byIDKeys, Set(sizeByID.keys) == byIDKeys else {
            throw CompiledTemplateDecodingError.unsupportedCompiledFeature(
                path: path, detail: "mergedAssetIndex byId/basenameById/sizeById key sets differ"
            )
        }
        return CompiledMergedAssetIndexDTO(byID: byID, basenameByID: basenameByID, sizeByID: sizeByID)
    }

    private static func decodeStringMap(_ reader: CompiledObjectReader) throws -> [String: String] {
        var r = reader
        var map: [String: String] = [:]
        for (key, value) in r.entries {
            map[key] = try value.requireString(path: "\(r.path).\(key)")
        }
        r.markAllConsumed()
        try r.finish()
        return map
    }

    private static func decodeSizeMap(_ reader: CompiledObjectReader) throws -> [String: CompiledSizeDTO] {
        var r = reader
        var map: [String: CompiledSizeDTO] = [:]
        for (key, value) in r.entries {
            map[key] = try CompiledSizeDTO.decode(value, path: "\(r.path).\(key)")
        }
        r.markAllConsumed()
        try r.finish()
        return map
    }
}

// MARK: - Path registry

/// `compiled.pathRegistry` (and the empty AnimIR-level registry). Producer `PathRegistry` custom
/// Codable: a single `paths` array (`generationId` not serialized). `pathId.value` must be unique.
struct CompiledPathRegistryDTO: Equatable, Sendable {
    let paths: [CompiledPathEntryDTO]

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledPathRegistryDTO {
        var r = try value.requireObject(path: path)
        let pathValues = try r.array("paths")
        let pathsPath = r.childPath("paths")
        try r.finish()
        var entries: [CompiledPathEntryDTO] = []
        var seenIDs = Set<Int>()
        for (i, pv) in pathValues.enumerated() {
            let entry = try CompiledPathEntryDTO.decode(pv, path: "\(pathsPath)[\(i)]")
            guard seenIDs.insert(entry.pathID).inserted else {
                throw CompiledTemplateDecodingError.duplicateIdentifier(
                    kind: "pathId", id: String(entry.pathID), path: pathsPath
                )
            }
            entries.append(entry)
        }
        return CompiledPathRegistryDTO(paths: entries)
    }
}

/// One registry entry. Producer `PathResource`: `pathId (PathID), keyframePositions ([[Float]]),
/// keyframeTimes ([Double]), indices ([UInt16]), vertexCount (Int), keyframeEasing
/// ([KeyframeEasing?] — **nullable elements**)`.
struct CompiledPathEntryDTO: Equatable, Sendable {
    let pathID: Int
    let vertexCount: Int
    let indices: [Int]
    let keyframeTimes: [Double]
    let keyframePositions: [[Double]]
    let keyframeEasing: [CompiledPathEasingDTO?]

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledPathEntryDTO {
        var r = try value.requireObject(path: path)
        var pathIDReader = try r.object("pathId")
        let pathID = try pathIDReader.intValue("value")
        try pathIDReader.finish()
        let vertexCount = try r.intValue("vertexCount")
        let indices = try decodeIntArray(try r.array("indices"), path: r.childPath("indices"))
        let keyframeTimes = try decodeDoubleArray(try r.array("keyframeTimes"), path: r.childPath("keyframeTimes"))

        let posRows = try r.array("keyframePositions")
        var keyframePositions: [[Double]] = []
        for (i, row) in posRows.enumerated() {
            let rowPath = "\(r.childPath("keyframePositions"))[\(i)]"
            guard case .array(let cells) = row else {
                throw CompiledTemplateDecodingError.wrongType(path: rowPath, expected: "array")
            }
            keyframePositions.append(try cells.enumerated().map { j, c in try c.requireDouble(path: "\(rowPath)[\(j)]") })
        }

        // keyframeEasing elements are nullable: a literal `null` is a documented "linear/hold"
        // segment marker (producer `[KeyframeEasing?]`), NOT an absent field.
        let easingValues = try r.array("keyframeEasing")
        var keyframeEasing: [CompiledPathEasingDTO?] = []
        for (i, ev) in easingValues.enumerated() {
            let elemPath = "\(r.childPath("keyframeEasing"))[\(i)]"
            if case .null = ev {
                keyframeEasing.append(nil)
            } else {
                keyframeEasing.append(try CompiledPathEasingDTO.decode(ev, path: elemPath))
            }
        }
        try r.finish()
        return CompiledPathEntryDTO(
            pathID: pathID, vertexCount: vertexCount, indices: indices,
            keyframeTimes: keyframeTimes, keyframePositions: keyframePositions, keyframeEasing: keyframeEasing
        )
    }
}

/// Producer `PathResource.KeyframeEasing`: `{ outX, outY, inX, inY (Double), hold (Bool) }`.
struct CompiledPathEasingDTO: Equatable, Sendable {
    let outX: Double
    let outY: Double
    let inX: Double
    let inY: Double
    let hold: Bool

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledPathEasingDTO {
        var r = try value.requireObject(path: path)
        let dto = CompiledPathEasingDTO(
            outX: try r.double("outX"),
            outY: try r.double("outY"),
            inX: try r.double("inX"),
            inY: try r.double("inY"),
            hold: try r.bool("hold")
        )
        try r.finish()
        return dto
    }
}

// MARK: - Runtime

/// `compiled.runtime`. Producer `SceneRuntime`: `scene (Scene), canvas (Canvas), blocks
/// ([BlockRuntime]), durationFrames (Int), fps (Int)`.
struct CompiledRuntimeDTO: Equatable, Sendable {
    let scene: CompiledSceneDTO
    let canvas: CompiledCanvasDTO
    let blocks: [CompiledBlockDTO]
    let durationFrames: Int
    let fps: Int

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledRuntimeDTO {
        var r = try value.requireObject(path: path)
        let scene = try CompiledSceneDTO.decode(try r.value("scene"), path: r.childPath("scene"))
        let canvas = try CompiledCanvasDTO.decode(try r.value("canvas"), path: r.childPath("canvas"))
        let blockValues = try r.array("blocks")
        var blocks: [CompiledBlockDTO] = []
        var seenBlockIDs = Set<String>()
        for (i, bv) in blockValues.enumerated() {
            let block = try CompiledBlockDTO.decode(bv, path: "\(r.childPath("blocks"))[\(i)]")
            guard seenBlockIDs.insert(block.blockID).inserted else {
                throw CompiledTemplateDecodingError.duplicateIdentifier(
                    kind: "block", id: block.blockID, path: r.childPath("blocks")
                )
            }
            blocks.append(block)
        }
        let durationFrames = try r.intValue("durationFrames")
        let fps = try r.intValue("fps")
        try r.finish()
        return CompiledRuntimeDTO(
            scene: scene, canvas: canvas, blocks: blocks, durationFrames: durationFrames, fps: fps
        )
    }
}

/// Producer `Canvas`: `{ width, height, fps, durationFrames (Int) }`.
struct CompiledCanvasDTO: Equatable, Sendable {
    let width: Int
    let height: Int
    let fps: Int
    let durationFrames: Int

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledCanvasDTO {
        var r = try value.requireObject(path: path)
        let dto = CompiledCanvasDTO(
            width: try r.intValue("width"),
            height: try r.intValue("height"),
            fps: try r.intValue("fps"),
            durationFrames: try r.intValue("durationFrames")
        )
        try r.finish()
        return dto
    }
}

// MARK: - Closed enums (producer-derived)

/// Producer `HitTestMode: String` — `mask`, `rect`.
enum CompiledHitTestMode: String, Equatable, Sendable { case mask, rect }

/// Producer `ContainerClip: String` — `slotRect`, `slotRectAfterSettle`, `none`.
enum CompiledContainerClip: String, Equatable, Sendable {
    case slotRect, slotRectAfterSettle, none
}

/// Producer `FitMode: String` — `cover`, `contain`, `fill`.
enum CompiledFitMode: String, Equatable, Sendable { case cover, contain, fill }

/// Producer `EmptyPolicy: String` — `hideWholeBlock`, `renderWithColorFallback`.
enum CompiledEmptyPolicy: String, Equatable, Sendable { case hideWholeBlock, renderWithColorFallback }

/// Producer `AnimationDurationBehavior: String` — `holdLastFrame`, `cut`, `loop`.
enum CompiledAnimationDurationBehavior: String, Equatable, Sendable { case holdLastFrame, cut, loop }

// MARK: - Blocks (runtime)

/// One runtime block. Producer `BlockRuntime`: required `blockId, zIndex, orderIndex, rectCanvas,
/// bindingBaseline, mediaInputGeometry, timing, containerClip, selectedVariantId, editVariantId,
/// variants`; optional `hitTestMode` (`HitTestMode?`).
struct CompiledBlockDTO: Equatable, Sendable {
    let blockID: String
    let zIndex: Int
    let orderIndex: Int
    let rectCanvas: CompiledRectDTO
    let bindingBaseline: CompiledBindingBaselineDTO
    let mediaInputGeometry: CompiledMediaInputGeometryDTO
    let timing: CompiledFrameRangeDTO
    let containerClip: CompiledContainerClip
    let hitTestMode: CompiledHitTestMode?
    let selectedVariantID: String
    let editVariantID: String
    let variants: [CompiledVariantDTO]

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledBlockDTO {
        var r = try value.requireObject(path: path)
        let blockID = try r.string("blockId")
        let zIndex = try r.intValue("zIndex")
        let orderIndex = try r.intValue("orderIndex")
        let rectCanvas = try CompiledRectDTO.decode(try r.value("rectCanvas"), path: r.childPath("rectCanvas"))
        let bindingBaseline = try CompiledBindingBaselineDTO.decode(
            try r.value("bindingBaseline"), path: r.childPath("bindingBaseline")
        )
        let mediaInputGeometry = try CompiledMediaInputGeometryDTO.decode(
            try r.value("mediaInputGeometry"), path: r.childPath("mediaInputGeometry")
        )
        let timing = try CompiledFrameRangeDTO.decode(try r.value("timing"), path: r.childPath("timing"))
        let containerClip = try r.enumValue("containerClip", CompiledContainerClip.self)
        let hitTestMode = try r.optionalEnum("hitTestMode", CompiledHitTestMode.self)
        let selectedVariantID = try r.string("selectedVariantId")
        let editVariantID = try r.string("editVariantId")

        let variantValues = try r.array("variants")
        var variants: [CompiledVariantDTO] = []
        var seenVariantIDs = Set<String>()
        for (i, vv) in variantValues.enumerated() {
            let variant = try CompiledVariantDTO.decode(vv, path: "\(r.childPath("variants"))[\(i)]")
            guard seenVariantIDs.insert(variant.variantID).inserted else {
                throw CompiledTemplateDecodingError.duplicateIdentifier(
                    kind: "variant", id: variant.variantID, path: r.childPath("variants")
                )
            }
            variants.append(variant)
        }
        try r.finish()

        guard seenVariantIDs.contains(selectedVariantID) else {
            throw CompiledTemplateDecodingError.danglingReference(
                kind: "selectedVariantId", id: selectedVariantID, path: path
            )
        }
        guard seenVariantIDs.contains(editVariantID) else {
            throw CompiledTemplateDecodingError.danglingReference(
                kind: "editVariantId", id: editVariantID, path: path
            )
        }

        return CompiledBlockDTO(
            blockID: blockID, zIndex: zIndex, orderIndex: orderIndex,
            rectCanvas: rectCanvas, bindingBaseline: bindingBaseline,
            mediaInputGeometry: mediaInputGeometry, timing: timing,
            containerClip: containerClip, hitTestMode: hitTestMode,
            selectedVariantID: selectedVariantID, editVariantID: editVariantID, variants: variants
        )
    }
}

/// One runtime variant. Producer `VariantRuntime`: `variantId, animRef, animIR (AnimIR), bindingKey`.
struct CompiledVariantDTO: Equatable, Sendable {
    let variantID: String
    let animRef: String
    let bindingKey: String
    let animIR: CompiledAnimIRDTO

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledVariantDTO {
        var r = try value.requireObject(path: path)
        let variantID = try r.string("variantId")
        let animRef = try r.string("animRef")
        let bindingKey = try r.string("bindingKey")
        let animIR = try CompiledAnimIRDTO.decode(try r.value("animIR"), path: r.childPath("animIR"))
        try r.finish()
        return CompiledVariantDTO(variantID: variantID, animRef: animRef, bindingKey: bindingKey, animIR: animIR)
    }
}

// MARK: - Block geometry (runtime)

/// Producer `BindingBaselineRuntime`: `boundAssetId, contentSizeLocal (SizeD), contentRectLocal (RectD)`.
struct CompiledBindingBaselineDTO: Equatable, Sendable {
    let boundAssetID: String
    let contentSizeLocal: CompiledSizeDTO
    let contentRectLocal: CompiledRectDTO

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledBindingBaselineDTO {
        var r = try value.requireObject(path: path)
        let dto = CompiledBindingBaselineDTO(
            boundAssetID: try r.string("boundAssetId"),
            contentSizeLocal: try CompiledSizeDTO.decode(try r.value("contentSizeLocal"), path: r.childPath("contentSizeLocal")),
            contentRectLocal: try CompiledRectDTO.decode(try r.value("contentRectLocal"), path: r.childPath("contentRectLocal"))
        )
        try r.finish()
        return dto
    }
}

/// Producer `MediaInputGeometryRuntime`: `placementRectLocal (RectD)`.
struct CompiledMediaInputGeometryDTO: Equatable, Sendable {
    let placementRectLocal: CompiledRectDTO

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledMediaInputGeometryDTO {
        var r = try value.requireObject(path: path)
        let rect = try CompiledRectDTO.decode(try r.value("placementRectLocal"), path: r.childPath("placementRectLocal"))
        try r.finish()
        return CompiledMediaInputGeometryDTO(placementRectLocal: rect)
    }
}

/// Producer `Rect`/`RectD`: `{ x, y, width, height (Double) }`.
struct CompiledRectDTO: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledRectDTO {
        var r = try value.requireObject(path: path)
        let dto = CompiledRectDTO(
            x: try r.double("x"), y: try r.double("y"),
            width: try r.double("width"), height: try r.double("height")
        )
        try r.finish()
        return dto
    }
}

/// Producer `BlockTiming`: `{ startFrame, endFrame (Int) }`.
struct CompiledFrameRangeDTO: Equatable, Sendable {
    let startFrame: Int
    let endFrame: Int

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledFrameRangeDTO {
        var r = try value.requireObject(path: path)
        let dto = CompiledFrameRangeDTO(
            startFrame: try r.intValue("startFrame"),
            endFrame: try r.intValue("endFrame")
        )
        try r.finish()
        return dto
    }
}

// MARK: - Scene (product policy — decoded strictly, not converted)

/// `runtime.scene`. Producer `Scene`: `schemaVersion, sceneId (String?), canvas, background
/// (Background?), mediaBlocks ([MediaBlock])`.
struct CompiledSceneDTO: Equatable, Sendable {
    let schemaVersion: String
    let sceneID: String?
    let canvas: CompiledCanvasDTO
    let background: CompiledBackgroundDTO?
    let mediaBlocks: [CompiledMediaBlockDTO]

    /// Convenience for the bijection check against runtime block ids.
    var mediaBlockIDs: [String] { mediaBlocks.map(\.blockID) }

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledSceneDTO {
        var r = try value.requireObject(path: path)
        let schemaVersion = try r.string("schemaVersion")
        let sceneID = try r.optionalString("sceneId")
        let canvas = try CompiledCanvasDTO.decode(try r.value("canvas"), path: r.childPath("canvas"))
        let background: CompiledBackgroundDTO?
        if let bv = try r.optionalObject("background") {
            background = try CompiledBackgroundDTO.decode(bv)
        } else {
            background = nil
        }
        let mbValues = try r.array("mediaBlocks")
        var mediaBlocks: [CompiledMediaBlockDTO] = []
        var seen = Set<String>()
        for (i, mv) in mbValues.enumerated() {
            let mb = try CompiledMediaBlockDTO.decode(mv, path: "\(r.childPath("mediaBlocks"))[\(i)]")
            guard seen.insert(mb.blockID).inserted else {
                throw CompiledTemplateDecodingError.duplicateIdentifier(
                    kind: "mediaBlock", id: mb.blockID, path: r.childPath("mediaBlocks")
                )
            }
            mediaBlocks.append(mb)
        }
        try r.finish()
        return CompiledSceneDTO(
            schemaVersion: schemaVersion, sceneID: sceneID, canvas: canvas,
            background: background, mediaBlocks: mediaBlocks
        )
    }
}

/// `scene.mediaBlocks[]`. Producer `MediaBlock` (CodingKey `id="blockId"`): `blockId, zIndex, rect,
/// containerClip, timing (Timing?), input (MediaInput), variants ([Variant]), layerToggles
/// ([LayerToggle]?)`.
struct CompiledMediaBlockDTO: Equatable, Sendable {
    let blockID: String
    let zIndex: Int
    let rect: CompiledRectDTO
    let containerClip: CompiledContainerClip
    let timing: CompiledFrameRangeDTO?
    let input: CompiledMediaInputDTO
    let variants: [CompiledSceneVariantDTO]
    let layerToggles: [CompiledLayerToggleDTO]?

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledMediaBlockDTO {
        var r = try value.requireObject(path: path)
        let blockID = try r.string("blockId")
        let zIndex = try r.intValue("zIndex")
        let rect = try CompiledRectDTO.decode(try r.value("rect"), path: r.childPath("rect"))
        let containerClip = try r.enumValue("containerClip", CompiledContainerClip.self)
        let timing: CompiledFrameRangeDTO?
        if let tv = try r.optionalValue("timing") {
            timing = try CompiledFrameRangeDTO.decode(tv, path: r.childPath("timing"))
        } else {
            timing = nil
        }
        let input = try CompiledMediaInputDTO.decode(try r.value("input"), path: r.childPath("input"))

        let variantValues = try r.array("variants")
        var variants: [CompiledSceneVariantDTO] = []
        var seen = Set<String>()
        for (i, vv) in variantValues.enumerated() {
            let v = try CompiledSceneVariantDTO.decode(vv, path: "\(r.childPath("variants"))[\(i)]")
            guard seen.insert(v.variantID).inserted else {
                throw CompiledTemplateDecodingError.duplicateIdentifier(
                    kind: "sceneVariant", id: v.variantID, path: r.childPath("variants")
                )
            }
            variants.append(v)
        }

        let layerToggles: [CompiledLayerToggleDTO]?
        if let ltValues = try r.optionalArray("layerToggles") {
            var toggles: [CompiledLayerToggleDTO] = []
            var seenToggle = Set<String>()
            for (i, lv) in ltValues.enumerated() {
                let toggle = try CompiledLayerToggleDTO.decode(lv, path: "\(r.childPath("layerToggles"))[\(i)]")
                guard seenToggle.insert(toggle.id).inserted else {
                    throw CompiledTemplateDecodingError.duplicateIdentifier(
                        kind: "layerToggle", id: toggle.id, path: r.childPath("layerToggles")
                    )
                }
                toggles.append(toggle)
            }
            layerToggles = toggles
        } else {
            layerToggles = nil
        }
        try r.finish()
        return CompiledMediaBlockDTO(
            blockID: blockID, zIndex: zIndex, rect: rect, containerClip: containerClip,
            timing: timing, input: input, variants: variants, layerToggles: layerToggles
        )
    }
}

/// Producer `MediaInput`: `bindingKey (String), hitTest (HitTestMode?), allowedMedia ([String]),
/// emptyPolicy (EmptyPolicy?), fitModesAllowed ([FitMode]?), defaultFit (FitMode?),
/// userTransformsAllowed (UserTransformsAllowed?), audio (AudioConfig?), maskRef (String?)`.
/// Note: `allowedMedia` is `[String]` in the producer — kept as raw strings (not an enum).
struct CompiledMediaInputDTO: Equatable, Sendable {
    let bindingKey: String
    let hitTest: CompiledHitTestMode?
    let allowedMedia: [String]
    let emptyPolicy: CompiledEmptyPolicy?
    let fitModesAllowed: [CompiledFitMode]?
    let defaultFit: CompiledFitMode?
    let userTransformsAllowed: CompiledUserTransformsAllowedDTO?
    let audio: CompiledAudioConfigDTO?
    let maskRef: String?

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledMediaInputDTO {
        var r = try value.requireObject(path: path)
        let bindingKey = try r.string("bindingKey")
        let hitTest = try r.optionalEnum("hitTest", CompiledHitTestMode.self)
        // `allowedMedia` is a required `[String]` in the producer (kept as raw strings — it is not
        // a closed enum there).
        let allowedMediaValues = try r.array("allowedMedia")
        let allowedMedia = try allowedMediaValues.enumerated().map { i, v in
            try v.requireString(path: "\(r.childPath("allowedMedia"))[\(i)]")
        }
        let emptyPolicy = try r.optionalEnum("emptyPolicy", CompiledEmptyPolicy.self)
        let fitModesAllowed: [CompiledFitMode]?
        if let fm = try r.optionalArray("fitModesAllowed") {
            fitModesAllowed = try fm.enumerated().map { i, v in
                let tag = try v.requireString(path: "\(r.childPath("fitModesAllowed"))[\(i)]")
                guard let mode = CompiledFitMode(rawValue: tag) else {
                    throw CompiledTemplateDecodingError.unknownEnumTag(path: "\(r.childPath("fitModesAllowed"))[\(i)]", tag: tag)
                }
                return mode
            }
        } else {
            fitModesAllowed = nil
        }
        let defaultFit = try r.optionalEnum("defaultFit", CompiledFitMode.self)
        let userTransformsAllowed: CompiledUserTransformsAllowedDTO?
        if let uv = try r.optionalObject("userTransformsAllowed") {
            userTransformsAllowed = try CompiledUserTransformsAllowedDTO.decode(uv)
        } else {
            userTransformsAllowed = nil
        }
        let audio: CompiledAudioConfigDTO?
        if let av = try r.optionalObject("audio") {
            audio = try CompiledAudioConfigDTO.decode(av)
        } else {
            audio = nil
        }
        let maskRef = try r.optionalString("maskRef")
        try r.finish()
        return CompiledMediaInputDTO(
            bindingKey: bindingKey, hitTest: hitTest, allowedMedia: allowedMedia,
            emptyPolicy: emptyPolicy, fitModesAllowed: fitModesAllowed, defaultFit: defaultFit,
            userTransformsAllowed: userTransformsAllowed, audio: audio, maskRef: maskRef
        )
    }
}

/// Producer `UserTransformsAllowed`: `{ pan, zoom, rotate (Bool) }`.
struct CompiledUserTransformsAllowedDTO: Equatable, Sendable {
    let pan: Bool
    let zoom: Bool
    let rotate: Bool

    static func decode(_ reader: CompiledObjectReader) throws -> CompiledUserTransformsAllowedDTO {
        var r = reader
        let dto = CompiledUserTransformsAllowedDTO(
            pan: try r.bool("pan"), zoom: try r.bool("zoom"), rotate: try r.bool("rotate")
        )
        try r.finish()
        return dto
    }
}

/// Producer `AudioConfig`: `{ enabled (Bool), gain (Double) }`.
struct CompiledAudioConfigDTO: Equatable, Sendable {
    let enabled: Bool
    let gain: Double

    static func decode(_ reader: CompiledObjectReader) throws -> CompiledAudioConfigDTO {
        var r = reader
        let dto = CompiledAudioConfigDTO(enabled: try r.bool("enabled"), gain: try r.double("gain"))
        try r.finish()
        return dto
    }
}

/// Producer `Variant` (scene-level, CodingKey `id="variantId"`): `variantId, animRef,
/// defaultDurationFrames (Int?), ifAnimationShorter/Longer (AnimationDurationBehavior?),
/// loop (Bool?), loopRange (LoopRange?)`.
struct CompiledSceneVariantDTO: Equatable, Sendable {
    let variantID: String
    let animRef: String
    let defaultDurationFrames: Int?
    let ifAnimationShorter: CompiledAnimationDurationBehavior?
    let ifAnimationLonger: CompiledAnimationDurationBehavior?
    let loop: Bool?
    let loopRange: CompiledLoopRangeDTO?

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledSceneVariantDTO {
        var r = try value.requireObject(path: path)
        let variantID = try r.string("variantId")
        let animRef = try r.string("animRef")
        let defaultDurationFrames = try r.optionalInt("defaultDurationFrames")
        let ifShorter = try r.optionalEnum("ifAnimationShorter", CompiledAnimationDurationBehavior.self)
        let ifLonger = try r.optionalEnum("ifAnimationLonger", CompiledAnimationDurationBehavior.self)
        let loop = try r.optionalBool("loop")
        let loopRange: CompiledLoopRangeDTO?
        if let lv = try r.optionalObject("loopRange") {
            loopRange = try CompiledLoopRangeDTO.decode(lv)
        } else {
            loopRange = nil
        }
        try r.finish()
        return CompiledSceneVariantDTO(
            variantID: variantID, animRef: animRef, defaultDurationFrames: defaultDurationFrames,
            ifAnimationShorter: ifShorter, ifAnimationLonger: ifLonger, loop: loop, loopRange: loopRange
        )
    }
}

/// Producer `LoopRange`: `{ startFrame, endFrame (Int) }`.
struct CompiledLoopRangeDTO: Equatable, Sendable {
    let startFrame: Int
    let endFrame: Int

    static func decode(_ reader: CompiledObjectReader) throws -> CompiledLoopRangeDTO {
        var r = reader
        let dto = CompiledLoopRangeDTO(startFrame: try r.intValue("startFrame"), endFrame: try r.intValue("endFrame"))
        try r.finish()
        return dto
    }
}

/// Producer `LayerToggle`: `{ id, title (String), group (String?), defaultOn (Bool) }`.
struct CompiledLayerToggleDTO: Equatable, Sendable {
    let id: String
    let title: String
    let group: String?
    let defaultOn: Bool

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledLayerToggleDTO {
        var r = try value.requireObject(path: path)
        let dto = CompiledLayerToggleDTO(
            id: try r.string("id"),
            title: try r.string("title"),
            group: try r.optionalString("group"),
            defaultOn: try r.bool("defaultOn")
        )
        try r.finish()
        return dto
    }
}

/// Producer `Background`: `{ type (String), color (String?), presetId (String?),
/// defaults ([String:RegionDefault]?) }`. `type` is a raw string in the producer (legacy "solid" /
/// "preset"), so it is kept as a string, not an enum. `defaults` is now decoded into exact DTOs.
struct CompiledBackgroundDTO: Equatable, Sendable {
    let type: String
    let color: String?
    let presetID: String?
    /// Per-region defaults keyed by regionId. Absent → nil. Decoded recursively-strict.
    let defaults: [String: CompiledRegionDefaultDTO]?

    static func decode(_ reader: CompiledObjectReader) throws -> CompiledBackgroundDTO {
        var r = reader
        let type = try r.string("type")
        let color = try r.optionalString("color")
        let presetID = try r.optionalString("presetId")
        let defaults: [String: CompiledRegionDefaultDTO]?
        if let defaultsReader = try r.optionalObject("defaults") {
            var dr = defaultsReader
            var map: [String: CompiledRegionDefaultDTO] = [:]
            for (regionID, value) in dr.entries {
                map[regionID] = try CompiledRegionDefaultDTO.decode(value, path: "\(dr.path).\(regionID)")
            }
            dr.markAllConsumed()
            try dr.finish()
            defaults = map
        } else {
            defaults = nil
        }
        try r.finish()
        return CompiledBackgroundDTO(type: type, color: color, presetID: presetID, defaults: defaults)
    }
}

/// Producer `RegionDefault`: `{ sourceType (String), solidColor (String?),
/// gradientLinear (GradientLinearDefault?) }`.
struct CompiledRegionDefaultDTO: Equatable, Sendable {
    let sourceType: String
    let solidColor: String?
    let gradientLinear: CompiledGradientLinearDefaultDTO?

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledRegionDefaultDTO {
        var r = try value.requireObject(path: path)
        let sourceType = try r.string("sourceType")
        let solidColor = try r.optionalString("solidColor")
        let gradientLinear: CompiledGradientLinearDefaultDTO?
        if let gv = try r.optionalValue("gradientLinear") {
            gradientLinear = try CompiledGradientLinearDefaultDTO.decode(gv, path: r.childPath("gradientLinear"))
        } else {
            gradientLinear = nil
        }
        try r.finish()
        return CompiledRegionDefaultDTO(sourceType: sourceType, solidColor: solidColor, gradientLinear: gradientLinear)
    }
}

/// Producer `GradientLinearDefault`: `{ stops ([GradientStop]), p0 (Vec2D), p1 (Vec2D) }`.
struct CompiledGradientLinearDefaultDTO: Equatable, Sendable {
    let stops: [CompiledGradientStopDTO]
    let p0: CompiledVec2DTO
    let p1: CompiledVec2DTO

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledGradientLinearDefaultDTO {
        var r = try value.requireObject(path: path)
        let stopValues = try r.array("stops")
        var stops: [CompiledGradientStopDTO] = []
        for (i, sv) in stopValues.enumerated() {
            stops.append(try CompiledGradientStopDTO.decode(sv, path: "\(r.childPath("stops"))[\(i)]"))
        }
        let p0 = try CompiledVec2DTO.decode(try r.value("p0"), path: r.childPath("p0"))
        let p1 = try CompiledVec2DTO.decode(try r.value("p1"), path: r.childPath("p1"))
        try r.finish()
        return CompiledGradientLinearDefaultDTO(stops: stops, p0: p0, p1: p1)
    }
}

/// Producer `GradientStop`: `{ position (Double), color (String) }`.
struct CompiledGradientStopDTO: Equatable, Sendable {
    let position: Double
    let color: String

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledGradientStopDTO {
        var r = try value.requireObject(path: path)
        let dto = CompiledGradientStopDTO(position: try r.double("position"), color: try r.string("color"))
        try r.finish()
        return dto
    }
}

// MARK: - Small helpers

private func decodeIntArray(_ values: [CompiledJSONValue], path: String) throws -> [Int] {
    try values.enumerated().map { i, v in
        let raw = try v.requireInteger(path: "\(path)[\(i)]")
        guard let narrowed = Int(exactly: raw) else {
            throw CompiledTemplateDecodingError.malformedInteger(path: "\(path)[\(i)]")
        }
        return narrowed
    }
}

private func decodeDoubleArray(_ values: [CompiledJSONValue], path: String) throws -> [Double] {
    try values.enumerated().map { i, v in try v.requireDouble(path: "\(path)[\(i)]") }
}
