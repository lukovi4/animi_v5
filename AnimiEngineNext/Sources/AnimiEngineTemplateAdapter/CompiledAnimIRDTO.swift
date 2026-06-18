/// Strict DTOs for the compiled **AnimIR** subtree of a schema-2 `.tve` payload
/// (Task-003 plan §5.2, §14.3 — `CompiledAnimIRDTO.swift`).
///
/// Every field, enum tag/code, nullable rule and relationship in this file is derived **only** from
/// the compiled-format producer in `TVECore`/`TVECompilerCore` and the five real compiled fixtures
/// (Stage-4 correction: "Do not invent schema"). The adapter does **not** import or depend on those
/// modules — the producer types are read as the authoritative specification and re-expressed here.
///
/// Producer sources of truth:
///   * `AnimIR`, `Composition`, `Layer`, `LayerType`, `LayerContent`, `LayerTiming`, `MatteInfo`,
///     `MatteMode`, `Mask`, `MaskMode`, `ShapeGroup`, `StrokeStyle`, `GroupTransform`, `BindingInfo`,
///     `Meta`, `AssetIndexIR`, `AssetSize`, `InputGeometryInfo` — `TVECore/AnimIR/AnimIRTypes.swift`.
///   * `AnimTrack`, `Keyframe`, `TransformTrack`, `BezierPath`, `AnimPath` — `AnimIRTrack.swift`,
///     `AnimIRPath.swift`.
///   * `PathID` (`{value: Int}`), `LayerID = Int`, `CompID = String` — `PathResource.swift`,
///     `AnimIRTypes.swift`.
///
/// Numeric typing follows the producer exactly: `Meta`/`LayerTiming`/`AssetSize` numbers and
/// keyframe `time`s are `Double`; ids, type/matte codes and `lineCap`/`lineJoin` are integers.
/// Render-only real leaves (coordinates, tangents, colours) are retained verbatim as finite
/// `Double` — they are **not** converted to render units (§17 step 6+).

// MARK: - Animation IR root

/// One variant's compiled animation IR (`variant.animIR`). Producer: `AnimIR` custom Codable —
/// keys `meta, rootComp, comps, assets, binding, pathRegistry, inputGeometry?` (inputGeometry via
/// `encodeIfPresent`).
struct CompiledAnimIRDTO: Equatable, Sendable {
    let meta: CompiledAnimMetaDTO
    let rootCompID: String
    let comps: [CompiledCompDTO]
    let assets: CompiledMergedAssetIndexDTO
    let binding: CompiledAnimBindingDTO
    let inputGeometry: CompiledInputGeometryDTO?

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledAnimIRDTO {
        var reader = try value.requireObject(path: path)

        let meta = try CompiledAnimMetaDTO.decode(try reader.value("meta"), path: reader.childPath("meta"))
        let rootCompID = try reader.string("rootComp")

        // `comps` is a free-form map keyed by comp id (data, not schema fields).
        var compsReader = try reader.object("comps")
        let compsPath = reader.childPath("comps")
        var comps: [CompiledCompDTO] = []
        var seenCompIDs = Set<String>()
        for (key, compValue) in compsReader.entries {
            let comp = try CompiledCompDTO.decode(compValue, key: key, path: "\(compsPath).\(key)")
            guard seenCompIDs.insert(key).inserted else {
                throw CompiledTemplateDecodingError.duplicateIdentifier(kind: "comp", id: key, path: compsPath)
            }
            comps.append(comp)
        }
        compsReader.markAllConsumed()

        let assets = try CompiledMergedAssetIndexDTO.decode(
            try reader.value("assets"), path: reader.childPath("assets")
        )
        let binding = try CompiledAnimBindingDTO.decode(
            try reader.value("binding"), path: reader.childPath("binding")
        )

        // `pathRegistry` is present at the AnimIR level (empty in every compiled fixture, but the
        // producer always encodes it). Validated for shape; its entries are not consumed here.
        _ = try CompiledPathRegistryDTO.decode(
            try reader.value("pathRegistry"), path: reader.childPath("pathRegistry")
        )

        let inputGeometry: CompiledInputGeometryDTO?
        if let ig = try reader.optionalValue("inputGeometry") {
            inputGeometry = try CompiledInputGeometryDTO.decode(ig, path: reader.childPath("inputGeometry"))
        } else {
            inputGeometry = nil
        }

        try reader.finish()

        guard seenCompIDs.contains(rootCompID) else {
            throw CompiledTemplateDecodingError.danglingReference(kind: "rootComp", id: rootCompID, path: path)
        }
        let result = CompiledAnimIRDTO(
            meta: meta, rootCompID: rootCompID, comps: comps,
            assets: assets, binding: binding, inputGeometry: inputGeometry
        )
        try result.validateInternalReferences(path: path)
        return result
    }

    /// Cross-references resolved within this AnimIR (producer renderer relies on all of these):
    /// matte/parent layer ids, precomp comp ids, image content assets, the binding target
    /// (`boundAssetId`/`boundCompId`/`boundLayerId`) and `inputGeometry` (`compId`/`layerId`).
    private func validateInternalReferences(path: String) throws {
        let compsByID = Dictionary(uniqueKeysWithValues: comps.map { ($0.id, $0) })
        let assetIDs = Set(assets.byID.keys)

        for comp in comps {
            let layerIDs = Set(comp.layers.map(\.id))
            let compPath = "\(path).comps.\(comp.id)"
            for layer in comp.layers {
                let layerPath = "\(compPath).layer[\(layer.id)]"
                if let matte = layer.matte, !layerIDs.contains(matte.sourceLayerID) {
                    throw CompiledTemplateDecodingError.danglingReference(
                        kind: "matte.sourceLayerId", id: String(matte.sourceLayerID), path: layerPath
                    )
                }
                if let parent = layer.parentLayerID, !layerIDs.contains(parent) {
                    throw CompiledTemplateDecodingError.danglingReference(
                        kind: "layer.parent", id: String(parent), path: layerPath
                    )
                }
                switch layer.content {
                case .precomp(let compID):
                    if compsByID[compID] == nil {
                        throw CompiledTemplateDecodingError.danglingReference(
                            kind: "content.precomp.compId", id: compID, path: layerPath
                        )
                    }
                case .image(let assetID):
                    if !assetIDs.contains(assetID) {
                        throw CompiledTemplateDecodingError.danglingReference(
                            kind: "content.image.assetId", id: assetID, path: layerPath
                        )
                    }
                case .shapes, .none:
                    break
                }
            }
        }

        // Binding target must resolve: asset in this AnimIR's index, comp exists, layer in that comp.
        if !assetIDs.contains(binding.boundAssetID) {
            throw CompiledTemplateDecodingError.danglingReference(
                kind: "binding.boundAssetId", id: binding.boundAssetID, path: path
            )
        }
        guard let boundComp = compsByID[binding.boundCompID] else {
            throw CompiledTemplateDecodingError.danglingReference(
                kind: "binding.boundCompId", id: binding.boundCompID, path: path
            )
        }
        if !boundComp.layers.contains(where: { $0.id == binding.boundLayerID }) {
            throw CompiledTemplateDecodingError.danglingReference(
                kind: "binding.boundLayerId", id: String(binding.boundLayerID), path: path
            )
        }

        // inputGeometry (when present) must resolve to an existing comp + layer.
        if let ig = inputGeometry {
            guard let igComp = compsByID[ig.compID] else {
                throw CompiledTemplateDecodingError.danglingReference(
                    kind: "inputGeometry.compId", id: ig.compID, path: path
                )
            }
            if !igComp.layers.contains(where: { $0.id == ig.layerID }) {
                throw CompiledTemplateDecodingError.danglingReference(
                    kind: "inputGeometry.layerId", id: String(ig.layerID), path: path
                )
            }
        }
    }

    /// All `PathID` values referenced by this AnimIR's masks, shapes and input geometry. Resolved
    /// against the scene-level `compiled.pathRegistry` by the top-level decoder (the AnimIR-level
    /// registry is always empty per the producer's `SceneCompiler`).
    func referencedPathIDs() -> [(id: Int, path: String)] {
        var result: [(Int, String)] = []
        for comp in comps {
            for layer in comp.layers {
                let layerPath = "comps.\(comp.id).layer[\(layer.id)]"
                for (i, mask) in layer.masks.enumerated() {
                    if let pid = mask.pathID { result.append((pid, "\(layerPath).masks[\(i)].pathId")) }
                }
                if case .shapes(let group) = layer.content, let pid = group.pathID {
                    result.append((pid, "\(layerPath).content.shapes.pathId"))
                }
            }
        }
        if let ig = inputGeometry {
            result.append((ig.pathID, "inputGeometry.pathId"))
        }
        return result
    }

    /// The asset id bound by this variant's binding layer (producer `bindingAssetIds` is the set of
    /// these across every variant).
    var boundAssetID: String { binding.boundAssetID }

    /// Validates this variant's toggle layers against the producer's `validateLayerToggles` rules
    /// and returns the toggle id set found in the AnimIR. Throws on a duplicate `toggleId`, or a
    /// toggle layer used as a matte source, matte consumer, or parent of another layer.
    func validatedToggleIDs(path: String) throws -> Set<String> {
        var found = Set<String>()
        var toggleLayerIDs = Set<Int>()
        for comp in comps {
            for layer in comp.layers {
                guard let toggleID = layer.toggleID else { continue }
                let layerPath = "\(path).comps.\(comp.id).layer[\(layer.id)]"
                guard found.insert(toggleID).inserted else {
                    throw CompiledTemplateDecodingError.layerToggleViolation(
                        path: layerPath, detail: "duplicate toggleId '\(toggleID)' within animIR"
                    )
                }
                toggleLayerIDs.insert(layer.id)
                if layer.isMatteSource {
                    throw CompiledTemplateDecodingError.layerToggleViolation(
                        path: layerPath, detail: "toggle layer '\(toggleID)' is a matte source"
                    )
                }
                if layer.matte != nil {
                    throw CompiledTemplateDecodingError.layerToggleViolation(
                        path: layerPath, detail: "toggle layer '\(toggleID)' is a matte consumer"
                    )
                }
            }
        }
        // No layer may use a toggle layer as its parent.
        for comp in comps {
            for layer in comp.layers {
                if let parent = layer.parentLayerID, toggleLayerIDs.contains(parent) {
                    throw CompiledTemplateDecodingError.layerToggleViolation(
                        path: "\(path).comps.\(comp.id).layer[\(layer.id)]",
                        detail: "layer \(layer.id) parents onto toggle layer \(parent)"
                    )
                }
            }
        }
        return found
    }
}

/// `animIR.meta`. Producer `Meta`: width/height/fps/inPoint/outPoint are **Double**.
struct CompiledAnimMetaDTO: Equatable, Sendable {
    let width: Double
    let height: Double
    let fps: Double
    let inPoint: Double
    let outPoint: Double
    let sourceAnimRef: String

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledAnimMetaDTO {
        var r = try value.requireObject(path: path)
        let dto = CompiledAnimMetaDTO(
            width: try r.double("width"),
            height: try r.double("height"),
            fps: try r.double("fps"),
            inPoint: try r.double("inPoint"),
            outPoint: try r.double("outPoint"),
            sourceAnimRef: try r.string("sourceAnimRef")
        )
        try r.finish()
        return dto
    }
}

/// `animIR.binding`. Producer `BindingInfo`: `boundLayerId` is `LayerID = Int`.
struct CompiledAnimBindingDTO: Equatable, Sendable {
    let bindingKey: String
    let boundAssetID: String
    let boundCompID: String
    let boundLayerID: Int

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledAnimBindingDTO {
        var r = try value.requireObject(path: path)
        let dto = CompiledAnimBindingDTO(
            bindingKey: try r.string("bindingKey"),
            boundAssetID: try r.string("boundAssetId"),
            boundCompID: try r.string("boundCompId"),
            boundLayerID: try r.intValue("boundLayerId")
        )
        try r.finish()
        return dto
    }
}

// MARK: - Compositions and layers

/// One composition (`animIR.comps.<id>`). Producer `Composition`: `id, size (SizeD), layers`.
struct CompiledCompDTO: Equatable, Sendable {
    let id: String
    let size: CompiledSizeDTO
    let layers: [CompiledLayerDTO]

    static func decode(_ value: CompiledJSONValue, key: String, path: String) throws -> CompiledCompDTO {
        var r = try value.requireObject(path: path)
        let id = try r.string("id")
        guard id == key else {
            throw CompiledTemplateDecodingError.danglingReference(kind: "comp.id", id: id, path: path)
        }
        let size = try CompiledSizeDTO.decode(try r.value("size"), path: r.childPath("size"))
        let layerValues = try r.array("layers")
        var layers: [CompiledLayerDTO] = []
        var seenLayerIDs = Set<Int>()
        for (i, lv) in layerValues.enumerated() {
            let layer = try CompiledLayerDTO.decode(lv, path: "\(r.childPath("layers"))[\(i)]")
            guard seenLayerIDs.insert(layer.id).inserted else {
                throw CompiledTemplateDecodingError.duplicateIdentifier(
                    kind: "layer", id: String(layer.id), path: r.childPath("layers")
                )
            }
            layers.append(layer)
        }
        try r.finish()
        return CompiledCompDTO(id: id, size: size, layers: layers)
    }
}

/// Producer `LayerType: Int` — `precomp=0, image=2, null=3, shapeMatte=4`.
enum CompiledLayerType: Int, Equatable, Sendable {
    case precomp = 0
    case image = 2
    case null = 3
    case shapeMatte = 4
}

/// One layer. Producer `Layer` (default Codable): required `id, name, type, timing, transform,
/// masks, content, isMatteSource, isHidden`; optional `parent, matte, toggleId`.
struct CompiledLayerDTO: Equatable, Sendable {
    let id: Int
    let name: String
    let type: CompiledLayerType
    let timing: CompiledLayerTimingDTO
    let parentLayerID: Int?
    let transform: CompiledTransformDTO
    let masks: [CompiledMaskDTO]
    let matte: CompiledMatteDTO?
    let content: CompiledLayerContent
    let isMatteSource: Bool
    let isHidden: Bool
    let toggleID: String?

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledLayerDTO {
        var r = try value.requireObject(path: path)
        let id = try r.intValue("id")
        let name = try r.string("name")
        let type = try r.enumIntValue("type", CompiledLayerType.self)
        let timing = try CompiledLayerTimingDTO.decode(try r.value("timing"), path: r.childPath("timing"))
        let parentLayerID = try r.optionalInt("parent")
        let transform = try CompiledTransformDTO.decode(
            try r.value("transform"), path: r.childPath("transform")
        )
        let maskValues = try r.array("masks")
        var masks: [CompiledMaskDTO] = []
        for (i, mv) in maskValues.enumerated() {
            masks.append(try CompiledMaskDTO.decode(mv, path: "\(r.childPath("masks"))[\(i)]"))
        }
        let matte: CompiledMatteDTO?
        if let mv = try r.optionalObject("matte") {
            matte = try CompiledMatteDTO.decode(mv)
        } else {
            matte = nil
        }
        let content = try CompiledLayerContent.decode(try r.value("content"), path: r.childPath("content"))
        let isMatteSource = try r.bool("isMatteSource")
        let isHidden = try r.bool("isHidden")
        let toggleID = try r.optionalString("toggleId")
        try r.finish()

        // Layer type ↔ content compatibility (producer pairs each type with one content kind):
        //   precomp(0)→precomp, image(2)→image, null(3)→none, shapeMatte(4)→shapes.
        try validateTypeContent(type: type, content: content, path: path)

        return CompiledLayerDTO(
            id: id, name: name, type: type, timing: timing, parentLayerID: parentLayerID,
            transform: transform, masks: masks, matte: matte, content: content,
            isMatteSource: isMatteSource, isHidden: isHidden, toggleID: toggleID
        )
    }

    private static func validateTypeContent(
        type: CompiledLayerType, content: CompiledLayerContent, path: String
    ) throws {
        let ok: Bool
        switch (type, content) {
        case (.precomp, .precomp), (.image, .image), (.null, .none), (.shapeMatte, .shapes):
            ok = true
        default:
            ok = false
        }
        guard ok else {
            throw CompiledTemplateDecodingError.layerContentMismatch(
                path: path, layerType: type.rawValue, contentKind: content.kindName
            )
        }
    }
}

/// `layer.timing`. Producer `LayerTiming`: inPoint/outPoint/startTime are **Double**.
struct CompiledLayerTimingDTO: Equatable, Sendable {
    let inPoint: Double
    let outPoint: Double
    let startTime: Double

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledLayerTimingDTO {
        var r = try value.requireObject(path: path)
        let dto = CompiledLayerTimingDTO(
            inPoint: try r.double("inPoint"),
            outPoint: try r.double("outPoint"),
            startTime: try r.double("startTime")
        )
        try r.finish()
        return dto
    }
}

/// Producer `MatteMode: Int` — `alpha=1, alphaInverted=2, luma=3, lumaInverted=4`.
enum CompiledMatteMode: Int, Equatable, Sendable {
    case alpha = 1
    case alphaInverted = 2
    case luma = 3
    case lumaInverted = 4
}

/// `layer.matte`. Producer `MatteInfo`: `mode (MatteMode), sourceLayerId (LayerID)`.
struct CompiledMatteDTO: Equatable, Sendable {
    let mode: CompiledMatteMode
    let sourceLayerID: Int

    static func decode(_ reader: CompiledObjectReader) throws -> CompiledMatteDTO {
        var r = reader
        let dto = CompiledMatteDTO(
            mode: try r.enumIntValue("mode", CompiledMatteMode.self),
            sourceLayerID: try r.intValue("sourceLayerId")
        )
        try r.finish()
        return dto
    }
}

// MARK: - Layer content (discriminated union)

/// `layer.content` — producer `LayerContent` synthesised enum Codable:
/// `{image:{assetId}} | {precomp:{compId}} | {shapes:{_0}} | {none:{}}`.
enum CompiledLayerContent: Equatable, Sendable {
    case image(assetID: String)
    case precomp(compID: String)
    case shapes(CompiledShapeGroupDTO)
    case none

    var kindName: String {
        switch self {
        case .image: return "image"
        case .precomp: return "precomp"
        case .shapes: return "shapes"
        case .none: return "none"
        }
    }

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledLayerContent {
        var r = try value.requireObject(path: path)
        let keys = r.entries.map(\.0)
        guard keys.count == 1 else {
            throw CompiledTemplateDecodingError.ambiguousUnion(path: path, keys: keys)
        }
        let result: CompiledLayerContent
        switch keys[0] {
        case "image":
            var img = try r.object("image")
            let assetID = try img.string("assetId")
            try img.finish()
            result = .image(assetID: assetID)
        case "precomp":
            var pc = try r.object("precomp")
            let compID = try pc.string("compId")
            try pc.finish()
            result = .precomp(compID: compID)
        case "shapes":
            var sh = try r.object("shapes")
            let group = try CompiledShapeGroupDTO.decode(try sh.value("_0"), path: sh.childPath("_0"))
            try sh.finish()
            result = .shapes(group)
        case "none":
            let n = try r.object("none")
            try n.finish()   // synthesised `case none` encodes as an empty object
            result = .none
        default:
            throw CompiledTemplateDecodingError.unsupportedCompiledFeature(
                path: path, detail: "unrecognised content kind '\(keys[0])'"
            )
        }
        try r.finish()
        return result
    }
}

// MARK: - Masks

/// Producer `MaskMode: String` — `add="a", subtract="s", intersect="i"`.
enum CompiledMaskMode: String, Equatable, Sendable {
    case add = "a"
    case subtract = "s"
    case intersect = "i"
}

/// `layer.masks[]`. Producer `Mask`: `mode (MaskMode), inverted (Bool), opacity (Double),
/// path (AnimPath), pathId (PathID?)`. `pathId` is optional.
struct CompiledMaskDTO: Equatable, Sendable {
    let mode: CompiledMaskMode
    let inverted: Bool
    let opacity: Double
    let path: CompiledAnimatedPathDTO
    let pathID: Int?

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledMaskDTO {
        var r = try value.requireObject(path: path)
        let mode = try r.enumValue("mode", CompiledMaskMode.self)
        let inverted = try r.bool("inverted")
        let opacity = try r.double("opacity")
        let animPath = try CompiledAnimatedPathDTO.decode(try r.value("path"), path: r.childPath("path"))
        let pathID = try Self.decodeOptionalPathID(&r, key: "pathId")
        try r.finish()
        return CompiledMaskDTO(mode: mode, inverted: inverted, opacity: opacity, path: animPath, pathID: pathID)
    }

    /// `PathID` encodes as `{"value": Int}`. Optional → absent means nil.
    static func decodeOptionalPathID(_ r: inout CompiledObjectReader, key: String) throws -> Int? {
        guard var idReader = try r.optionalObject(key) else { return nil }
        let v = try idReader.intValue("value")
        try idReader.finish()
        return v
    }
}

// MARK: - Transform and animated value tracks

/// `layer.transform`. Producer `TransformTrack`: position/scale/anchor are `AnimTrack<Vec2D>`,
/// rotation/opacity are `AnimTrack<Double>`.
struct CompiledTransformDTO: Equatable, Sendable {
    let position: CompiledVectorTrackDTO
    let scale: CompiledVectorTrackDTO
    let rotation: CompiledScalarTrackDTO
    let opacity: CompiledScalarTrackDTO
    let anchor: CompiledVectorTrackDTO

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledTransformDTO {
        var r = try value.requireObject(path: path)
        let dto = CompiledTransformDTO(
            position: try CompiledVectorTrackDTO.decode(try r.value("position"), path: r.childPath("position")),
            scale: try CompiledVectorTrackDTO.decode(try r.value("scale"), path: r.childPath("scale")),
            rotation: try CompiledScalarTrackDTO.decode(try r.value("rotation"), path: r.childPath("rotation")),
            opacity: try CompiledScalarTrackDTO.decode(try r.value("opacity"), path: r.childPath("opacity")),
            anchor: try CompiledVectorTrackDTO.decode(try r.value("anchor"), path: r.childPath("anchor"))
        )
        try r.finish()
        return dto
    }
}

/// `AnimTrack<Vec2D>` synthesised enum Codable: `{static:{_0}} | {keyframed:{_0:[...]}}`.
enum CompiledVectorTrackDTO: Equatable, Sendable {
    case `static`(CompiledVec2DTO)
    case keyframed([CompiledKeyframeDTO<CompiledVec2DTO>])

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledVectorTrackDTO {
        let (key, inner) = try exactlyOneTrackKey(value, path: path)
        switch key {
        case "static":
            var s = try inner.requireObject(path: path)
            let v = try CompiledVec2DTO.decode(try s.value("_0"), path: s.childPath("_0"))
            try s.finish()
            return .static(v)
        case "keyframed":
            return .keyframed(try decodeKeyframes(inner, path: path, decodeValue: CompiledVec2DTO.decode))
        default:
            throw CompiledTemplateDecodingError.unsupportedCompiledFeature(
                path: path, detail: "unrecognised value-track kind '\(key)'"
            )
        }
    }
}

/// `AnimTrack<Double>` synthesised enum Codable: `{static:{_0}} | {keyframed:{_0:[...]}}`.
enum CompiledScalarTrackDTO: Equatable, Sendable {
    case `static`(Double)
    case keyframed([CompiledKeyframeDTO<Double>])

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledScalarTrackDTO {
        let (key, inner) = try exactlyOneTrackKey(value, path: path)
        switch key {
        case "static":
            var s = try inner.requireObject(path: path)
            let v = try s.double("_0")
            try s.finish()
            return .static(v)
        case "keyframed":
            return .keyframed(try decodeKeyframes(inner, path: path) { v, p in try v.requireDouble(path: p) })
        default:
            throw CompiledTemplateDecodingError.unsupportedCompiledFeature(
                path: path, detail: "unrecognised value-track kind '\(key)'"
            )
        }
    }
}

/// Producer `Keyframe<T>` (default Codable): `time (Double), value (T), inTangent (Vec2D?),
/// outTangent (Vec2D?), hold (Bool)`. Tangents are encoded via `encodeIfPresent` (absent when nil).
struct CompiledKeyframeDTO<Value: Equatable & Sendable>: Equatable, Sendable {
    let time: Double
    let value: Value
    let hold: Bool
    let inTangent: CompiledVec2DTO?
    let outTangent: CompiledVec2DTO?
}

/// Reads `{ "_0": [ keyframe, ... ] }`, decoding each keyframe value with `decodeValue`.
private func decodeKeyframes<Value>(
    _ inner: CompiledJSONValue,
    path: String,
    decodeValue: (CompiledJSONValue, String) throws -> Value
) throws -> [CompiledKeyframeDTO<Value>] {
    var r = try inner.requireObject(path: path)
    let elements = try r.array("_0")
    let arrayPath = r.childPath("_0")
    try r.finish()
    var keyframes: [CompiledKeyframeDTO<Value>] = []
    for (i, ev) in elements.enumerated() {
        var kr = try ev.requireObject(path: "\(arrayPath)[\(i)]")
        let time = try kr.double("time")
        let value = try decodeValue(try kr.value("value"), kr.childPath("value"))
        let hold = try kr.bool("hold")
        let inTangent = try kr.optionalValue("inTangent").map {
            try CompiledVec2DTO.decode($0, path: kr.childPath("inTangent"))
        }
        let outTangent = try kr.optionalValue("outTangent").map {
            try CompiledVec2DTO.decode($0, path: kr.childPath("outTangent"))
        }
        try kr.finish()
        keyframes.append(CompiledKeyframeDTO(
            time: time, value: value, hold: hold, inTangent: inTangent, outTangent: outTangent
        ))
    }
    return keyframes
}

/// Returns the single wrapper key and value of a synthesised-enum object, rejecting zero or
/// multiple keys (ambiguous union).
private func exactlyOneTrackKey(
    _ value: CompiledJSONValue, path: String
) throws -> (String, CompiledJSONValue) {
    guard case .object(let pairs) = value else {
        throw CompiledTemplateDecodingError.wrongType(path: path, expected: "object")
    }
    guard pairs.count == 1 else {
        throw CompiledTemplateDecodingError.ambiguousUnion(path: path, keys: pairs.map(\.0))
    }
    return (pairs[0].0, pairs[0].1)
}

// MARK: - Geometry leaves

/// Producer `Vec2D`: `{x: Double, y: Double}`.
struct CompiledVec2DTO: Equatable, Sendable {
    let x: Double
    let y: Double

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledVec2DTO {
        var r = try value.requireObject(path: path)
        let dto = CompiledVec2DTO(x: try r.double("x"), y: try r.double("y"))
        try r.finish()
        return dto
    }
}

/// Producer `SizeD`: `{width: Double, height: Double}`. Compositions use integral sizes, but the
/// producer type is `Double` — accept any finite number.
struct CompiledSizeDTO: Equatable, Sendable {
    let width: Double
    let height: Double

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledSizeDTO {
        var r = try value.requireObject(path: path)
        let dto = CompiledSizeDTO(width: try r.double("width"), height: try r.double("height"))
        try r.finish()
        return dto
    }
}

// MARK: - Bezier paths (animated path values)

/// Producer `AnimPath` synthesised enum Codable: `{staticBezier:{_0}} | {keyframedBezier:{_0:[...]}}`.
enum CompiledAnimatedPathDTO: Equatable, Sendable {
    case `static`(CompiledBezierDTO)
    case keyframed([CompiledKeyframeDTO<CompiledBezierDTO>])

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledAnimatedPathDTO {
        let (key, inner) = try exactlyOneTrackKey(value, path: path)
        switch key {
        case "staticBezier":
            var s = try inner.requireObject(path: path)
            let bz = try CompiledBezierDTO.decode(try s.value("_0"), path: s.childPath("_0"))
            try s.finish()
            return .static(bz)
        case "keyframedBezier":
            return .keyframed(try decodeKeyframes(inner, path: path, decodeValue: CompiledBezierDTO.decode))
        default:
            throw CompiledTemplateDecodingError.unsupportedCompiledFeature(
                path: path, detail: "unrecognised path-track kind '\(key)'"
            )
        }
    }
}

/// Producer `BezierPath`: `vertices, inTangents, outTangents ([Vec2D]), closed (Bool)`. Tangent and
/// vertex counts must agree (producer invariant; the renderer indexes them in lockstep).
struct CompiledBezierDTO: Equatable, Sendable {
    let vertices: [CompiledVec2DTO]
    let inTangents: [CompiledVec2DTO]
    let outTangents: [CompiledVec2DTO]
    let closed: Bool

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledBezierDTO {
        var r = try value.requireObject(path: path)
        let vertices = try decodeVec2Array(try r.array("vertices"), path: r.childPath("vertices"))
        let inTangents = try decodeVec2Array(try r.array("inTangents"), path: r.childPath("inTangents"))
        let outTangents = try decodeVec2Array(try r.array("outTangents"), path: r.childPath("outTangents"))
        let closed = try r.bool("closed")
        try r.finish()
        guard vertices.count == inTangents.count, vertices.count == outTangents.count else {
            throw CompiledTemplateDecodingError.unsupportedCompiledFeature(
                path: path,
                detail: "bezier tangent count mismatch "
                    + "(\(vertices.count)/\(inTangents.count)/\(outTangents.count))"
            )
        }
        return CompiledBezierDTO(vertices: vertices, inTangents: inTangents, outTangents: outTangents, closed: closed)
    }
}

private func decodeVec2Array(_ values: [CompiledJSONValue], path: String) throws -> [CompiledVec2DTO] {
    try values.enumerated().map { i, v in try CompiledVec2DTO.decode(v, path: "\(path)[\(i)]") }
}

// MARK: - Shapes

/// `content.shapes._0`. Producer `ShapeGroup`: `animPath (AnimPath?), fillColor ([Double]?),
/// fillOpacity (Double), stroke (StrokeStyle?), groupTransforms ([GroupTransform]), pathId (PathID?)`.
/// `animPath`, `fillColor`, `stroke` and `pathId` are all optional (`encodeIfPresent`).
struct CompiledShapeGroupDTO: Equatable, Sendable {
    let animPath: CompiledAnimatedPathDTO?
    let fillColor: [Double]?
    let fillOpacity: Double
    let stroke: CompiledStrokeDTO?
    let groupTransforms: [CompiledGroupTransformDTO]
    let pathID: Int?

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledShapeGroupDTO {
        var r = try value.requireObject(path: path)
        let animPath = try r.optionalValue("animPath").map {
            try CompiledAnimatedPathDTO.decode($0, path: r.childPath("animPath"))
        }
        let fillColor = try r.optionalArray("fillColor").map {
            try decodeDoubleArray($0, path: r.childPath("fillColor"))
        }
        let fillOpacity = try r.double("fillOpacity")
        let stroke: CompiledStrokeDTO?
        if let sv = try r.optionalObject("stroke") {
            stroke = try CompiledStrokeDTO.decode(sv)
        } else {
            stroke = nil
        }
        let gtValues = try r.array("groupTransforms")
        var groupTransforms: [CompiledGroupTransformDTO] = []
        for (i, gv) in gtValues.enumerated() {
            groupTransforms.append(try CompiledGroupTransformDTO.decode(gv, path: "\(r.childPath("groupTransforms"))[\(i)]"))
        }
        let pathID = try CompiledMaskDTO.decodeOptionalPathID(&r, key: "pathId")
        try r.finish()
        return CompiledShapeGroupDTO(
            animPath: animPath, fillColor: fillColor, fillOpacity: fillOpacity,
            stroke: stroke, groupTransforms: groupTransforms, pathID: pathID
        )
    }
}

/// Producer `GroupTransform` (default Codable): position/anchor/scale `AnimTrack<Vec2D>`,
/// rotation/opacity `AnimTrack<Double>`.
struct CompiledGroupTransformDTO: Equatable, Sendable {
    let position: CompiledVectorTrackDTO
    let anchor: CompiledVectorTrackDTO
    let scale: CompiledVectorTrackDTO
    let rotation: CompiledScalarTrackDTO
    let opacity: CompiledScalarTrackDTO

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledGroupTransformDTO {
        var r = try value.requireObject(path: path)
        let dto = CompiledGroupTransformDTO(
            position: try CompiledVectorTrackDTO.decode(try r.value("position"), path: r.childPath("position")),
            anchor: try CompiledVectorTrackDTO.decode(try r.value("anchor"), path: r.childPath("anchor")),
            scale: try CompiledVectorTrackDTO.decode(try r.value("scale"), path: r.childPath("scale")),
            rotation: try CompiledScalarTrackDTO.decode(try r.value("rotation"), path: r.childPath("rotation")),
            opacity: try CompiledScalarTrackDTO.decode(try r.value("opacity"), path: r.childPath("opacity"))
        )
        try r.finish()
        return dto
    }
}

/// Producer `StrokeStyle`: `color ([Double]), opacity (Double), width (AnimTrack<Double>),
/// lineCap (Int), lineJoin (Int), miterLimit (Double)`. `lineCap`/`lineJoin` are documented `1...3`.
struct CompiledStrokeDTO: Equatable, Sendable {
    let color: [Double]
    let opacity: Double
    let width: CompiledScalarTrackDTO
    let lineCap: Int
    let lineJoin: Int
    let miterLimit: Double

    static func decode(_ reader: CompiledObjectReader) throws -> CompiledStrokeDTO {
        var r = reader
        let color = try decodeDoubleArray(try r.array("color"), path: r.childPath("color"))
        let opacity = try r.double("opacity")
        let width = try CompiledScalarTrackDTO.decode(try r.value("width"), path: r.childPath("width"))
        let lineCap = try r.intValue("lineCap")
        let lineJoin = try r.intValue("lineJoin")
        let miterLimit = try r.double("miterLimit")
        try r.finish()
        // Producer documents lineCap (1=butt,2=round,3=square) and lineJoin (1=miter,2=round,3=bevel).
        guard (1...3).contains(lineCap) else {
            throw CompiledTemplateDecodingError.valueOutOfRange(
                path: r.childPath("lineCap"), detail: "lineCap \(lineCap) outside 1...3"
            )
        }
        guard (1...3).contains(lineJoin) else {
            throw CompiledTemplateDecodingError.valueOutOfRange(
                path: r.childPath("lineJoin"), detail: "lineJoin \(lineJoin) outside 1...3"
            )
        }
        return CompiledStrokeDTO(
            color: color, opacity: opacity, width: width,
            lineCap: lineCap, lineJoin: lineJoin, miterLimit: miterLimit
        )
    }
}

private func decodeDoubleArray(_ values: [CompiledJSONValue], path: String) throws -> [Double] {
    try values.enumerated().map { i, v in try v.requireDouble(path: "\(path)[\(i)]") }
}

// MARK: - Input geometry

/// `animIR.inputGeometry`. Producer `InputGeometryInfo`: `layerId (LayerID), pathId (PathID),
/// animPath (AnimPath), compId (CompID)`.
struct CompiledInputGeometryDTO: Equatable, Sendable {
    let layerID: Int
    let pathID: Int
    let animPath: CompiledAnimatedPathDTO
    let compID: String

    static func decode(_ value: CompiledJSONValue, path: String) throws -> CompiledInputGeometryDTO {
        var r = try value.requireObject(path: path)
        let layerID = try r.intValue("layerId")
        var pathIDReader = try r.object("pathId")
        let pathID = try pathIDReader.intValue("value")
        try pathIDReader.finish()
        let animPath = try CompiledAnimatedPathDTO.decode(try r.value("animPath"), path: r.childPath("animPath"))
        let compID = try r.string("compId")
        try r.finish()
        return CompiledInputGeometryDTO(layerID: layerID, pathID: pathID, animPath: animPath, compID: compID)
    }
}
