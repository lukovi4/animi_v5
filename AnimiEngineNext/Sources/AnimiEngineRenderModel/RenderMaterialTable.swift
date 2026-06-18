import Foundation

/// Task-003 plan §4.1, D3-11 — an immutable, order-independent table of resolved render materials.
///
/// It holds, with the same invariants (unique identity, order independence, deterministic canonical
/// encoding and hashing):
///   * **programs** (§17 step 7) — the complete selected-AnimIR `RenderMaterialProgram` for each
///     block's selected variant, keyed by structured `RenderMaterialID`. Each program carries the
///     full authored animation in RenderModel fixed-point/rational types — no `Double`, DTO, path,
///     URL, pixel buffer, or adapter dependency.
///   * **scene bindings** (Stage-6 correction item 4) — a `SceneMaterialBindingKey`
///     (`SceneInstanceID` + `LayerID`) → `RenderMaterialID` map, so a later `RenderInputResolver` can
///     resolve a FramePlan layer from only `SceneSubplan.sceneID` + `ActiveLayer.layerID`, importing
///     only this module.
///   * **pixelInputs** (§17 step 8) — resolved pixel buffers; empty at conversion time.
///
/// Backing stores are private. Iteration is by dictionary **values** sorted by their own ids — no
/// optional lookup and therefore no `compactMap`-based silent omission and no force-unwrap (item 6).
/// An immutable scene-layer → material binding value (Stage-6 correction item 4). Used instead of a
/// pre-collapsed dictionary so duplicate keys are caught explicitly rather than silently overwritten.
public struct SceneMaterialBinding: Hashable, Sendable {
    public let key: SceneMaterialBindingKey
    public let materialID: RenderMaterialID
    public init(key: SceneMaterialBindingKey, materialID: RenderMaterialID) {
        self.key = key
        self.materialID = materialID
    }
}

public struct RenderMaterialTable: Hashable, Sendable {
    private let programStorage: [RenderMaterialID: RenderMaterialProgram]
    private let sceneBindingStorage: [SceneMaterialBindingKey: RenderMaterialID]
    private let storage: [PixelInputID: ResolvedPixelInput]

    /// Builds a table from programs, scene bindings (as explicit values) and pixel inputs, rejecting
    /// duplicate program ids, duplicate scene-binding keys, dangling bindings and duplicate pixel ids.
    /// Accepting `[SceneMaterialBinding]` (not a dictionary) means a duplicate key is a typed error,
    /// never a silent overwrite (item 4).
    public init(
        programs: [RenderMaterialProgram] = [],
        sceneBindings: [SceneMaterialBinding] = [],
        pixelInputs: [ResolvedPixelInput] = []
    ) throws {
        var programTable: [RenderMaterialID: RenderMaterialProgram] = [:]
        for program in programs {
            guard programTable[program.id] == nil else {
                throw RenderModelError.duplicateIdentity(
                    field: "RenderMaterialTable.programs", value: program.id.rawValue)
            }
            programTable[program.id] = program
        }
        var bindingTable: [SceneMaterialBindingKey: RenderMaterialID] = [:]
        for binding in sceneBindings {
            guard bindingTable[binding.key] == nil else {
                throw RenderModelError.duplicateSceneBinding(
                    sceneID: binding.key.sceneID.raw, layerID: binding.key.layerID.raw)
            }
            guard programTable[binding.materialID] != nil else {
                throw RenderModelError.danglingSceneBinding(
                    sceneID: binding.key.sceneID.raw, layerID: binding.key.layerID.raw,
                    materialID: binding.materialID.rawValue)
            }
            bindingTable[binding.key] = binding.materialID
        }
        var table: [PixelInputID: ResolvedPixelInput] = [:]
        for input in pixelInputs {
            guard table[input.id] == nil else {
                throw RenderModelError.duplicateIdentity(
                    field: "RenderMaterialTable.pixelInputs", value: input.id.rawValue)
            }
            table[input.id] = input
        }
        self.programStorage = programTable
        self.sceneBindingStorage = bindingTable
        self.storage = table
    }

    /// Private exact-storage initializer used by `merging(_:)` (already-validated maps).
    private init(
        programStorage: [RenderMaterialID: RenderMaterialProgram],
        sceneBindingStorage: [SceneMaterialBindingKey: RenderMaterialID],
        storage: [PixelInputID: ResolvedPixelInput]
    ) {
        self.programStorage = programStorage
        self.sceneBindingStorage = sceneBindingStorage
        self.storage = storage
    }

    // MARK: - Typed merge (item 4)

    /// Merges another table into this one (Stage-6 correction item 4). It:
    ///   * preserves programs, scene bindings and pixel inputs;
    ///   * coalesces only **value-identical** programs sharing an id, and throws
    ///     `conflictingProgram` on a genuine conflict;
    ///   * throws `duplicateSceneBinding` on a repeated `SceneMaterialBindingKey`;
    ///   * throws `duplicateIdentity` on a repeated pixel-input id;
    ///   * never silently overwrites a dictionary entry.
    public func merging(_ other: RenderMaterialTable) throws -> RenderMaterialTable {
        var mergedPrograms = programStorage
        for (id, program) in other.programStorage {
            if let existing = mergedPrograms[id] {
                guard existing == program else {
                    throw RenderModelError.conflictingProgram(id: id.rawValue)
                }
                // value-identical → keep one copy.
            } else {
                mergedPrograms[id] = program
            }
        }
        var mergedBindings = sceneBindingStorage
        for (key, materialID) in other.sceneBindingStorage {
            guard mergedBindings[key] == nil else {
                throw RenderModelError.duplicateSceneBinding(sceneID: key.sceneID.raw, layerID: key.layerID.raw)
            }
            guard mergedPrograms[materialID] != nil else {
                throw RenderModelError.danglingSceneBinding(
                    sceneID: key.sceneID.raw, layerID: key.layerID.raw, materialID: materialID.rawValue)
            }
            mergedBindings[key] = materialID
        }
        var mergedPixels = storage
        for (id, input) in other.storage {
            guard mergedPixels[id] == nil else {
                throw RenderModelError.duplicateIdentity(field: "RenderMaterialTable.pixelInputs", value: id.rawValue)
            }
            mergedPixels[id] = input
        }
        return RenderMaterialTable(
            programStorage: mergedPrograms, sceneBindingStorage: mergedBindings, storage: mergedPixels)
    }

    // MARK: - Program lookup (§17 step 7)

    /// The selected program for `id`, or `nil` if absent. No fallback material is ever substituted.
    public func program(_ id: RenderMaterialID) -> RenderMaterialProgram? { programStorage[id] }

    /// The programs in deterministic id order (sort the values by their own id — no optional lookup).
    public var programs: [RenderMaterialProgram] { programStorage.values.sorted { $0.id < $1.id } }

    /// The number of selected programs.
    public var programCount: Int { programStorage.count }

    // MARK: - Scene-binding resolution (item 4)

    /// The material id bound to a scene layer, or `nil` if unbound. Adapter-free FramePlan resolution.
    public func materialID(for key: SceneMaterialBindingKey) -> RenderMaterialID? { sceneBindingStorage[key] }

    /// The program bound to a scene layer (`sceneID` + `layerID`), or `nil`. The path a later
    /// `RenderInputResolver` uses, importing only this module.
    public func program(for key: SceneMaterialBindingKey) -> RenderMaterialProgram? {
        guard let id = sceneBindingStorage[key] else { return nil }
        return programStorage[id]
    }

    /// The scene-binding keys in deterministic order.
    public var sceneBindingKeys: [SceneMaterialBindingKey] { sceneBindingStorage.keys.sorted() }

    // MARK: - Pixel-input lookup (§17 step 8; empty at conversion time)

    public func pixelInput(_ id: PixelInputID) -> ResolvedPixelInput? { storage[id] }

    /// The resolved pixel inputs in deterministic id order (sort values by id — no optional lookup).
    public var pixelInputs: [ResolvedPixelInput] { storage.values.sorted { $0.id < $1.id } }

    public var pixelInputCount: Int { storage.count }

    // MARK: - Canonical encoding / hashing (D3-11)

    public func canonicalValue() throws -> RenderCanonicalEncoding.Value {
        let programEntries = programs.map { $0.canonicalValue() }
        // Iterate the binding pairs directly (no optional lookup), sorted by key for determinism.
        let bindingEntries = sceneBindingStorage
            .sorted { $0.key < $1.key }
            .map { pair -> RenderCanonicalEncoding.Value in
                .object([
                    ("layerID", .string(pair.key.layerID.raw)),
                    ("materialID", .string(pair.value.rawValue)),
                    ("sceneID", .string(pair.key.sceneID.raw))
                ])
            }
        let pixelEntries = try pixelInputs.map { input -> RenderCanonicalEncoding.Value in
            try RenderCanonicalEncoding.object([
                ("contentHash", .string(input.contentHash)),
                ("height", .int(Int64(input.dimensions.height))),
                ("id", .string(input.id.rawValue)),
                ("width", .int(Int64(input.dimensions.width)))
            ])
        }
        return try RenderCanonicalEncoding.object([
            ("pixelInputs", .array(pixelEntries)),
            ("programs", .array(programEntries)),
            ("sceneBindings", .array(bindingEntries))
        ])
    }

    public func contentHash() throws -> String {
        try RenderCanonicalEncoding.sha256Hex(of: canonicalValue(), domain: .materialTable)
    }
}
