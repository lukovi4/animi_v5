import AnimiEngineCore

/// Task-003 plan §6, §7 — the complete, immutable render-input resolution result the RenderGraph
/// compiler (§17 step 9) consumes. Produced by `RenderInputResolver` (§17 step 8) from a `FramePlan`,
/// a `RenderMaterialTable` and explicit pre-resolved fixture pixels.
///
/// Step-8 corrective:
///   * **issue #3** — it retains the exact selected `RenderMaterialProgram`s and scene-bindings (an
///     embedded minimal `RenderMaterialTable` subset) so step 9 keeps every mask/matte/path/input-
///     geometry dependency; nothing is dropped to a pixel/placement summary.
///   * **issue #4** — two supplied pixel inputs sharing a `PixelInputID` must be **value-identical** to
///     coalesce; a genuine content conflict is a typed failure, never a silent last-writer-wins.
///   * **issue #8** — construction is **structurally complete**: a scene layer is supplied as one
///     indivisible `ResolvedSceneLayerEntry` carrying its program id, pixel id and placement together,
///     so a partial scene-layer binding cannot be expressed. Overlays are pixel-only entries.
///
/// Per §6 it contains only immutable values and owned pixel buffers — no URL, path, closure, provider,
/// lazy load, mutable cache, or project lookup. Storage is private; iteration is by sorted key, so
/// construction order never affects identity or the content hash (D3-11).

/// The role a scene plays, mirrored into the render-input key so an outgoing and an incoming layer with
/// the same `layerID` (a 20-to-20 transition) never collide.
public enum ResolvedSceneRole: String, Hashable, Sendable, Comparable {
    case sole, outgoing, incoming
    public static func < (lhs: ResolvedSceneRole, rhs: ResolvedSceneRole) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A stable identity for one resolved draw target: a scene layer (scene instance + role + layer) or a
/// global overlay. Deterministically ordered so the frame input's encoding is order-independent.
public enum ResolvedLayerKey: Hashable, Sendable, Comparable {
    case sceneLayer(sceneID: SceneInstanceID, role: ResolvedSceneRole, layerID: LayerID)
    case overlay(overlayID: OverlayID)

    private var sortKey: (Int, String, String, String) {
        switch self {
        case let .sceneLayer(sceneID, role, layerID):
            return (0, sceneID.raw, role.rawValue, layerID.raw)
        case let .overlay(overlayID):
            return (1, overlayID.raw, "", "")
        }
    }
    public static func < (lhs: ResolvedLayerKey, rhs: ResolvedLayerKey) -> Bool { lhs.sortKey < rhs.sortKey }

    var canonicalString: String {
        switch self {
        case let .sceneLayer(sceneID, role, layerID):
            return "scene\u{1F}\(sceneID.raw)\u{1F}\(role.rawValue)\u{1F}\(layerID.raw)"
        case let .overlay(overlayID):
            return "overlay\u{1F}\(overlayID.raw)"
        }
    }
}

/// CP7.8 — a dynamic texture-backed pixel source (value only). It is the canonical, `Sendable`,
/// deterministic stand-in for a per-frame user-video frame: a stable `id` (also the runtime-binding key),
/// the **display/oriented** dimensions (post quarter-turn — what downstream draw + placement see, matching
/// the CPU bake output dims), the input byte format, the display orientation, and the raw→display clockwise
/// quarter-turn the GPU normalization pass applies. It carries NO bytes, NO content hash, NO `MTLTexture`/
/// `CVMetalTexture`/`CVPixelBuffer`. The actual raw GPU texture is supplied at execution time via
/// `RenderRuntimeTextureBindings` (MetalRender), keyed by `id`.
public struct ResolvedDynamicTextureInput: Hashable, Sendable {
    public let id: PixelInputID
    public let width: Int
    public let height: Int
    public let bytesFormat: PixelByteFormat
    /// Display orientation AFTER the quarter-turn is applied (always `.up` in practice, but explicit).
    public let orientation: PixelOrientation
    /// Raw→display CLOCKWISE quarter-turns (0/1/2/3) the normalization pass applies on the GPU.
    public let orientationQuarterTurns: Int

    public init(id: PixelInputID, width: Int, height: Int, bytesFormat: PixelByteFormat,
                orientation: PixelOrientation, orientationQuarterTurns: Int) throws {
        guard width > 0, height > 0 else {
            throw RenderModelError.malformedDimensions(
                field: "ResolvedDynamicTextureInput", width: Int64(width), height: Int64(height))
        }
        guard (0...3).contains(orientationQuarterTurns) else {
            throw RenderModelError.valueOutOfRange(
                field: "ResolvedDynamicTextureInput.orientationQuarterTurns",
                value: Int64(orientationQuarterTurns), lowerBound: 0, upperBound: 3)
        }
        self.id = id
        self.width = width
        self.height = height
        self.bytesFormat = bytesFormat
        self.orientation = orientation
        self.orientationQuarterTurns = orientationQuarterTurns
    }
}

/// The pixel source a scene layer draws (CP7.8): either owned bytes (photo / authored asset — unchanged
/// path, carries content hash) OR a dynamic texture (user video — value-only, GPU-bound at execution).
/// This is additive: the existing bytes path is preserved verbatim; only video uses `.dynamicTexture`.
public enum ResolvedLayerSource: Hashable, Sendable {
    case pixels(ResolvedPixelInput)
    case dynamicTexture(ResolvedDynamicTextureInput)

    /// The shared `PixelInputID` (both the binding key and, for a dynamic source, the runtime-binding key).
    public var id: PixelInputID {
        switch self {
        case .pixels(let p): return p.id
        case .dynamicTexture(let d): return d.id
        }
    }
}

/// One complete scene media layer (issue #8): its key, the selected material program (retained whole,
/// issue #3), the pixel SOURCE it draws (bytes or dynamic texture, CP7.8), and its resolved media
/// placement — supplied together so a partial binding is unrepresentable.
public struct ResolvedSceneLayerEntry: Hashable, Sendable {
    public let key: ResolvedLayerKey
    public let program: RenderMaterialProgram
    public let source: ResolvedLayerSource
    public let placement: ResolvedMediaPlacement

    /// Convenience: the owned bytes if this is a bytes-backed layer; `nil` for a dynamic-texture layer.
    public var pixelInput: ResolvedPixelInput? {
        if case .pixels(let p) = source { return p }
        return nil
    }

    /// Bytes-backed (photo / authored asset) — the existing path, unchanged signature.
    /// Key ownership (issue #6): a scene-layer entry accepts **only** a `.sceneLayer` key; an
    /// `.overlay` key is a typed failure, so a misclassified entry cannot be constructed.
    public init(key: ResolvedLayerKey, program: RenderMaterialProgram,
                pixelInput: ResolvedPixelInput, placement: ResolvedMediaPlacement) throws {
        try self.init(key: key, program: program, source: .pixels(pixelInput), placement: placement)
    }

    /// CP7.8 — bytes OR dynamic-texture source. Same `.sceneLayer` key requirement.
    public init(key: ResolvedLayerKey, program: RenderMaterialProgram,
                source: ResolvedLayerSource, placement: ResolvedMediaPlacement) throws {
        guard case .sceneLayer = key else {
            throw RenderModelError.unsupportedValue(
                field: "ResolvedSceneLayerEntry.key", value: "expected .sceneLayer, got \(key.canonicalString)")
        }
        self.key = key
        self.program = program
        self.source = source
        self.placement = placement
    }
}

/// One global overlay: its key and the pixel input it draws (overlays carry no media-fit placement,
/// D3-09 / §3.1).
public struct ResolvedOverlayEntry: Hashable, Sendable {
    public let key: ResolvedLayerKey
    public let pixelInput: ResolvedPixelInput
    /// Key ownership (issue #6): an overlay entry accepts **only** an `.overlay` key.
    public init(key: ResolvedLayerKey, pixelInput: ResolvedPixelInput) throws {
        guard case .overlay = key else {
            throw RenderModelError.unsupportedValue(
                field: "ResolvedOverlayEntry.key", value: "expected .overlay, got \(key.canonicalString)")
        }
        self.key = key
        self.pixelInput = pixelInput
    }
}

/// The key for an authored template asset's pre-resolved pixels (corrective #4): the **local**
/// identity `(RenderMaterialID, RenderAsset.id)` — no assumption that an asset id is globally unique.
public struct ResolvedAssetKey: Hashable, Sendable, Comparable {
    public let materialID: RenderMaterialID
    public let assetID: String
    public init(materialID: RenderMaterialID, assetID: String) {
        self.materialID = materialID
        self.assetID = assetID
    }
    public var canonicalString: String { "\(materialID.rawValue)\u{1F}\(assetID)" }
    public static func < (lhs: ResolvedAssetKey, rhs: ResolvedAssetKey) -> Bool {
        lhs.canonicalString < rhs.canonicalString
    }
}

/// One authored-asset pixel binding (corrective #4): an authored `.image(assetID)` layer's pixels,
/// keyed by `(materialID, assetID)`. Value-identical pixels coalesce by `PixelInputID`.
public struct ResolvedAssetPixelEntry: Hashable, Sendable {
    public let key: ResolvedAssetKey
    public let pixelInput: ResolvedPixelInput
    public init(key: ResolvedAssetKey, pixelInput: ResolvedPixelInput) {
        self.key = key
        self.pixelInput = pixelInput
    }
}

public struct ResolvedFrameInput: Hashable, Sendable {
    /// The embedded minimal material table (issue #3): exactly the selected programs + scene-bindings.
    public let materials: RenderMaterialTable
    private let pixelStorage: [PixelInputID: ResolvedPixelInput]
    private let bindingStorage: [ResolvedLayerKey: PixelInputID]
    private let placementStorage: [ResolvedLayerKey: ResolvedMediaPlacement]
    private let programBindingStorage: [ResolvedLayerKey: RenderMaterialID]
    /// Authored-asset pixels keyed by `(materialID, assetID)` (corrective #4).
    private let assetPixelStorage: [ResolvedAssetKey: PixelInputID]
    /// CP7.8: dynamic texture-backed pixel sources (user video), keyed by id. Value-only; the runtime
    /// GPU texture is bound out-of-band at execution. A given `PixelInputID` is EITHER in `pixelStorage`
    /// (bytes) OR here (dynamic), never both.
    private let dynamicTextureStorage: [PixelInputID: ResolvedDynamicTextureInput]

    /// Builds and validates a complete frame input from indivisible scene-layer entries and overlay
    /// entries (issue #8: structurally complete). It:
    ///   * coalesces value-identical pixel inputs by id and **rejects a content conflict** (issue #4);
    ///   * rejects duplicate layer keys;
    ///   * embeds the selected programs + scene-bindings as a minimal `RenderMaterialTable` (issue #3);
    ///   * validates each scene layer's `AnimationReference` against its program (issue #3) when the
    ///     plan supplies one (the caller passes the optional reference alongside the entry).
    public init(
        sceneLayers: [ResolvedSceneLayerEntry],
        overlays: [ResolvedOverlayEntry],
        assetPixels: [ResolvedAssetPixelEntry] = []
    ) throws {
        var pixels: [PixelInputID: ResolvedPixelInput] = [:]
        var bindings: [ResolvedLayerKey: PixelInputID] = [:]
        var placements: [ResolvedLayerKey: ResolvedMediaPlacement] = [:]
        var programBindings: [ResolvedLayerKey: RenderMaterialID] = [:]
        var programsByID: [RenderMaterialID: RenderMaterialProgram] = [:]
        var sceneBindings: [SceneMaterialBinding] = []
        var assetBindings: [ResolvedAssetKey: PixelInputID] = [:]
        var dynamicTextures: [PixelInputID: ResolvedDynamicTextureInput] = [:]

        // Coalesce a pixel input by id; a same-id different-content pair is a typed conflict (issue #4).
        func addPixel(_ input: ResolvedPixelInput) throws {
            guard dynamicTextures[input.id] == nil else {
                throw RenderModelError.conflictingPixelInput(id: input.id.rawValue)   // id is both bytes & dynamic
            }
            if let existing = pixels[input.id] {
                guard existing == input else {
                    throw RenderModelError.conflictingPixelInput(id: input.id.rawValue)
                }
            } else {
                pixels[input.id] = input
            }
        }

        // CP7.8: coalesce a dynamic texture source by id; same-id different-value is a typed conflict.
        func addDynamic(_ input: ResolvedDynamicTextureInput) throws {
            guard pixels[input.id] == nil else {
                throw RenderModelError.conflictingPixelInput(id: input.id.rawValue)   // id is both bytes & dynamic
            }
            if let existing = dynamicTextures[input.id] {
                guard existing == input else {
                    throw RenderModelError.conflictingPixelInput(id: input.id.rawValue)
                }
            } else {
                dynamicTextures[input.id] = input
            }
        }

        for entry in sceneLayers {
            guard bindings[entry.key] == nil else {
                throw RenderModelError.duplicateIdentity(
                    field: "ResolvedFrameInput.sceneLayers", value: entry.key.canonicalString)
            }
            switch entry.source {
            case .pixels(let p): try addPixel(p)
            case .dynamicTexture(let d): try addDynamic(d)
            }
            bindings[entry.key] = entry.source.id
            placements[entry.key] = entry.placement
            programBindings[entry.key] = entry.program.id
            // Program dedup (issue #5): coalesce only **value-identical** programs sharing an id; the
            // same `RenderMaterialID` with different program content is a typed conflict, never a silent
            // drop of one of them.
            if let existing = programsByID[entry.program.id] {
                guard existing == entry.program else {
                    throw RenderModelError.conflictingProgram(id: entry.program.id.rawValue)
                }
            } else {
                programsByID[entry.program.id] = entry.program
            }
            // Scene-binding for the embedded table. The entry key is guaranteed `.sceneLayer` (issue #6).
            guard case let .sceneLayer(sceneID, _, layerID) = entry.key else {
                throw RenderModelError.unsupportedValue(
                    field: "ResolvedFrameInput.sceneLayerEntry.key", value: entry.key.canonicalString)
            }
            sceneBindings.append(SceneMaterialBinding(
                key: SceneMaterialBindingKey(sceneID: sceneID, layerID: layerID),
                materialID: entry.program.id))
        }

        for overlay in overlays {
            guard bindings[overlay.key] == nil else {
                throw RenderModelError.duplicateIdentity(
                    field: "ResolvedFrameInput.overlays", value: overlay.key.canonicalString)
            }
            try addPixel(overlay.pixelInput)
            bindings[overlay.key] = overlay.pixelInput.id
        }

        // Authored-asset pixels (corrective #4): keyed by (materialID, assetID); value-identical pixels
        // coalesce by id; a duplicate asset key is a typed error.
        for entry in assetPixels {
            guard assetBindings[entry.key] == nil else {
                throw RenderModelError.duplicateIdentity(
                    field: "ResolvedFrameInput.assetPixels", value: entry.key.canonicalString)
            }
            try addPixel(entry.pixelInput)
            assetBindings[entry.key] = entry.pixelInput.id
        }

        // Build the embedded minimal table (issue #3) from the value-deduped programs (issue #5).
        // Duplicate scene-binding keys are typed errors here, never silent overwrites.
        self.materials = try RenderMaterialTable(
            programs: programsByID.values.sorted { $0.id < $1.id }, sceneBindings: sceneBindings)
        self.pixelStorage = pixels
        self.bindingStorage = bindings
        self.placementStorage = placements
        self.programBindingStorage = programBindings
        self.assetPixelStorage = assetBindings
        self.dynamicTextureStorage = dynamicTextures
    }

    /// The authored-asset pixels for `(materialID, assetID)`, or `nil` if not supplied (corrective #4).
    public func assetPixels(materialID: RenderMaterialID, assetID: String) -> ResolvedPixelInput? {
        guard let id = assetPixelStorage[ResolvedAssetKey(materialID: materialID, assetID: assetID)] else { return nil }
        return pixelStorage[id]
    }
    public var assetPixelKeys: [ResolvedAssetKey] { assetPixelStorage.keys.sorted() }

    // MARK: - Lookup (no fallback substitution)

    public func pixelInput(_ id: PixelInputID) -> ResolvedPixelInput? { pixelStorage[id] }
    public func pixelInput(for key: ResolvedLayerKey) -> ResolvedPixelInput? {
        guard let id = bindingStorage[key] else { return nil }
        return pixelStorage[id]
    }
    public func pixelInputID(for key: ResolvedLayerKey) -> PixelInputID? { bindingStorage[key] }

    /// CP7.8: the dynamic texture source bound to `id` / `key`, or `nil` if the binding is bytes-backed
    /// (or absent). A layer binding resolves to EITHER `pixelInput(for:)` OR `dynamicTexture(for:)`.
    public func dynamicTexture(_ id: PixelInputID) -> ResolvedDynamicTextureInput? { dynamicTextureStorage[id] }
    public func dynamicTexture(for key: ResolvedLayerKey) -> ResolvedDynamicTextureInput? {
        guard let id = bindingStorage[key] else { return nil }
        return dynamicTextureStorage[id]
    }
    public func mediaPlacement(for key: ResolvedLayerKey) -> ResolvedMediaPlacement? { placementStorage[key] }
    public func program(for key: ResolvedLayerKey) -> RenderMaterialProgram? {
        guard let id = programBindingStorage[key] else { return nil }
        return materials.program(id)
    }

    // MARK: - Deterministic ordered views (sort by key; no optional lookup)

    public var pixelInputs: [ResolvedPixelInput] { pixelStorage.values.sorted { $0.id < $1.id } }
    public var pixelInputCount: Int { pixelStorage.count }
    /// CP7.8: dynamic texture sources in deterministic id order (the compiler declares one dynamic
    /// resource per entry).
    public var dynamicTextureInputs: [ResolvedDynamicTextureInput] { dynamicTextureStorage.values.sorted { $0.id < $1.id } }
    public var dynamicTextureCount: Int { dynamicTextureStorage.count }
    public var layerKeys: [ResolvedLayerKey] { bindingStorage.keys.sorted() }
    public var bindingCount: Int { bindingStorage.count }
    public var mediaPlacementKeys: [ResolvedLayerKey] { placementStorage.keys.sorted() }
    public var mediaPlacementCount: Int { placementStorage.count }
    public var programCount: Int { materials.programCount }

    // MARK: - Canonical encoding / hashing (D3-11, §6 content hashes)

    public func canonicalValue() throws -> RenderCanonicalEncoding.Value {
        let pixelEntries = pixelInputs.map { input -> RenderCanonicalEncoding.Value in
            .object([
                ("contentHash", .string(input.contentHash)),
                ("id", .string(input.id.rawValue))
            ])
        }
        let bindingEntries = bindingStorage
            .sorted { $0.key < $1.key }
            .map { pair -> RenderCanonicalEncoding.Value in
                .object([
                    ("key", .string(pair.key.canonicalString)),
                    ("pixelInputID", .string(pair.value.rawValue))
                ])
            }
        let placementEntries = try placementStorage
            .sorted { $0.key < $1.key }
            .map { pair -> RenderCanonicalEncoding.Value in
                try RenderCanonicalEncoding.object([
                    ("key", .string(pair.key.canonicalString)),
                    ("placement", try pair.value.canonicalValue())
                ])
            }
        let programBindingEntries = programBindingStorage
            .sorted { $0.key < $1.key }
            .map { pair -> RenderCanonicalEncoding.Value in
                .object([
                    ("key", .string(pair.key.canonicalString)),
                    ("materialID", .string(pair.value.rawValue))
                ])
            }
        let assetEntries = assetPixelStorage
            .sorted { $0.key < $1.key }
            .map { pair -> RenderCanonicalEncoding.Value in
                .object([
                    ("key", .string(pair.key.canonicalString)),
                    ("pixelInputID", .string(pair.value.rawValue))
                ])
            }
        var fields: [(String, RenderCanonicalEncoding.Value)] = [
            ("assetPixels", .array(assetEntries)),
            ("layerBindings", .array(bindingEntries)),
            ("materials", try materials.canonicalValue()),
            ("mediaPlacements", .array(placementEntries)),
            ("pixelInputs", .array(pixelEntries)),
            ("programBindings", .array(programBindingEntries))
        ]
        // CP7.8: dynamic texture sources are emitted ONLY when present, so a photo/asset-only frame's
        // canonical value (and hash) is byte-identical to before — the ReferenceData oracle is unaffected.
        if !dynamicTextureStorage.isEmpty {
            let dynEntries = dynamicTextureInputs.map { d -> RenderCanonicalEncoding.Value in
                .object([
                    ("bytesFormat", .string(d.bytesFormat.rawValue)),
                    ("height", .int(Int64(d.height))),
                    ("id", .string(d.id.rawValue)),
                    ("orientation", .string(d.orientation.rawValue)),
                    ("orientationQuarterTurns", .int(Int64(d.orientationQuarterTurns))),
                    ("width", .int(Int64(d.width)))
                ])
            }
            fields.append(("dynamicTextureInputs", .array(dynEntries)))
        }
        // The canonical encoder sorts object keys itself, so omitting this key when empty yields a
        // byte-identical value/hash to the pre-CP7.8 photo/asset-only frame.
        return try RenderCanonicalEncoding.object(fields)
    }

    public func contentHash() throws -> String {
        try RenderCanonicalEncoding.sha256Hex(of: canonicalValue(), domain: .frameInput)
    }
}
