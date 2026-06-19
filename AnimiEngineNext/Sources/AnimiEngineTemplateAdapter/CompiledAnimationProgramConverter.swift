import AnimiEngineCore
import AnimiEngineRenderModel

/// Task-003 plan §17 step 7 (Stage-6 corrected) — converts a selected variant's **compiled AnimIR
/// DTO** (plus the scene-level path registry) into the complete immutable `RenderMaterialProgram`.
///
/// Numeric semantics are field-correct (item 2): position/anchor/path/stroke-width → `CanvasScalar`;
/// scale → `ScaleScalar` (100% → 1,000,000); layer/mask/fill opacity → `OpacityScalar` (÷100); stroke
/// opacity → `OpacityScalar` (unit); rotation → `RotationScalar`; easing tangents → `EasingScalar`;
/// miter limit → `MiterScalar`; all authored times → exact `RationalSourceTime` (no quantization).
enum CompiledAnimationProgramConverter {

    static func convert(
        animIR: CompiledAnimIRDTO,
        sceneRegistry: [CompiledPathEntryDTO],
        materialID: RenderMaterialID,
        blockID: String,
        variantID: String,
        animationRef: String,
        mediaGeometry: RenderMediaGeometry,
        toggleIDs: [String]
    ) throws -> RenderMaterialProgram {
        let compositions = try animIR.comps.map { try convertComp($0, blockID: blockID) }
        let assets = try convertAssets(animIR.assets, blockID: blockID)
        let binding = RenderBinding(
            bindingKey: animIR.binding.bindingKey, boundAssetID: animIR.binding.boundAssetID,
            boundCompID: animIR.binding.boundCompID, boundLayerID: animIR.binding.boundLayerID)
        let inputGeometry = try animIR.inputGeometry.map { ig in
            RenderInputGeometry(
                layerID: ig.layerID, pathID: ig.pathID,
                animPath: try convertPath(ig.animPath, field: "block[\(blockID)].inputGeometry.path"),
                compID: ig.compID)
        }
        let meta = try convertMeta(animIR.meta, blockID: blockID)
        let pathResources = try convertPathResources(
            animIR: animIR, sceneRegistry: sceneRegistry, blockID: blockID)

        return try RenderMaterialProgram(
            id: materialID, blockID: blockID, variantID: variantID, animationRef: animationRef,
            boundAssetID: animIR.binding.boundAssetID,           // item 3: from the AnimIR binding
            mediaGeometry: mediaGeometry, rootCompID: animIR.rootCompID,
            compositions: compositions, assets: assets, binding: binding,
            inputGeometry: inputGeometry, meta: meta,
            pathResources: pathResources, toggleIDs: toggleIDs.sorted())
    }

    // MARK: - Path resources (item 1)

    /// The scene-level path resources referenced by this selected AnimIR, each resolving exactly once,
    /// sorted by pathID. Paths belonging only to unselected variants are excluded.
    private static func convertPathResources(
        animIR: CompiledAnimIRDTO, sceneRegistry: [CompiledPathEntryDTO], blockID: String
    ) throws -> [RenderPathResource] {
        // Deduplicate the referenced ids (the selected AnimIR may name a pathId in several places).
        var referenced = Set<Int>()
        for (id, _) in animIR.referencedPathIDs() { referenced.insert(id) }

        let registryByID = Dictionary(uniqueKeysWithValues: sceneRegistry.map { ($0.pathID, $0) })
        var resources: [RenderPathResource] = []
        for id in referenced.sorted() {
            guard let entry = registryByID[id] else {
                throw TemplateConversionError.danglingPathResource(blockID: blockID, pathID: id)
            }
            resources.append(try convertPathEntry(entry, blockID: blockID))
        }
        return resources
    }

    private static func convertPathEntry(_ entry: CompiledPathEntryDTO, blockID: String) throws -> RenderPathResource {
        let field = "block[\(blockID)].path[\(entry.pathID)]"
        let times = try entry.keyframeTimes.enumerated().map { i, t in
            try FixedPointConversion.exactRational(t, field: "\(field).keyframeTimes[\(i)]")
        }
        let positions = try entry.keyframePositions.enumerated().map { rowIndex, row in
            try row.enumerated().map { i, c in
                try FixedPointConversion.canvasScalar(points: c, field: "\(field).keyframePositions[\(rowIndex)][\(i)]")
            }
        }
        let easing: [RenderPathEasing?] = try entry.keyframeEasing.enumerated().map { i, e in
            guard let e else { return nil }
            return RenderPathEasing(
                outX: EasingScalar(rawValue: try FixedPointConversion.dimensionlessRaw(e.outX, field: "\(field).easing[\(i)].outX")),
                outY: EasingScalar(rawValue: try FixedPointConversion.dimensionlessRaw(e.outY, field: "\(field).easing[\(i)].outY")),
                inX: EasingScalar(rawValue: try FixedPointConversion.dimensionlessRaw(e.inX, field: "\(field).easing[\(i)].inX")),
                inY: EasingScalar(rawValue: try FixedPointConversion.dimensionlessRaw(e.inY, field: "\(field).easing[\(i)].inY")),
                hold: e.hold)
        }
        return try RenderPathResource(
            pathID: entry.pathID, vertexCount: entry.vertexCount, indices: entry.indices,
            keyframeTimes: times, keyframePositions: positions, keyframeEasing: easing)
    }

    // MARK: - Meta / assets

    private static func convertMeta(_ meta: CompiledAnimMetaDTO, blockID: String) throws -> RenderProgramMeta {
        RenderProgramMeta(
            width: try FixedPointConversion.canvasScalar(points: meta.width, field: "block[\(blockID)].meta.width"),
            height: try FixedPointConversion.canvasScalar(points: meta.height, field: "block[\(blockID)].meta.height"),
            fps: try FixedPointConversion.exactRational(meta.fps, field: "block[\(blockID)].meta.fps"),
            inPoint: try FixedPointConversion.exactRational(meta.inPoint, field: "block[\(blockID)].meta.inPoint"),
            outPoint: try FixedPointConversion.exactRational(meta.outPoint, field: "block[\(blockID)].meta.outPoint"),
            sourceAnimRef: meta.sourceAnimRef)
    }

    private static func convertAssets(_ assets: CompiledMergedAssetIndexDTO, blockID: String) throws -> [RenderAsset] {
        try assets.byID.keys.sorted().map { id -> RenderAsset in
            guard let resolved = assets.byID[id], let basename = assets.basenameByID[id],
                  let size = assets.sizeByID[id] else {
                throw TemplateConversionError.malformedAssetIndex(blockID: blockID, assetID: id)
            }
            return RenderAsset(
                id: id, resolvedID: resolved, basename: basename,
                width: try FixedPointConversion.canvasScalar(points: size.width, field: "asset[\(id)].width"),
                height: try FixedPointConversion.canvasScalar(points: size.height, field: "asset[\(id)].height"))
        }
    }

    // MARK: - Compositions / layers

    private static func convertComp(_ comp: CompiledCompDTO, blockID: String) throws -> RenderComposition {
        RenderComposition(
            id: comp.id,
            width: try FixedPointConversion.canvasScalar(points: comp.size.width, field: "comp[\(comp.id)].width"),
            height: try FixedPointConversion.canvasScalar(points: comp.size.height, field: "comp[\(comp.id)].height"),
            layers: try comp.layers.map { try convertLayer($0, compID: comp.id, blockID: blockID) })
    }

    private static func convertLayer(_ layer: CompiledLayerDTO, compID: String, blockID: String) throws -> RenderLayer {
        let field = "block[\(blockID)].comp[\(compID)].layer[\(layer.id)]"
        return RenderLayer(
            id: layer.id, name: layer.name, type: layer.type.rawValue,
            timing: RenderLayerTiming(
                inPoint: try FixedPointConversion.exactRational(layer.timing.inPoint, field: "\(field).timing.inPoint"),
                outPoint: try FixedPointConversion.exactRational(layer.timing.outPoint, field: "\(field).timing.outPoint"),
                startTime: try FixedPointConversion.exactRational(layer.timing.startTime, field: "\(field).timing.startTime")),
            parentLayerID: layer.parentLayerID,
            transform: try convertTransform(layer.transform, field: "\(field).transform"),
            masks: try layer.masks.enumerated().map { try convertMask($1, field: "\(field).masks[\($0)]") },
            matte: layer.matte.map { RenderMatte(mode: $0.mode.rawValue, sourceLayerID: $0.sourceLayerID) },
            content: try convertContent(layer.content, field: "\(field).content"),
            isMatteSource: layer.isMatteSource, isHidden: layer.isHidden, toggleID: layer.toggleID)
    }

    private static func convertContent(_ content: CompiledLayerContent, field: String) throws -> RenderLayerContent {
        switch content {
        case .image(let assetID): return .image(assetID: assetID)
        case .precomp(let compID): return .precomp(compID: compID)
        case .none: return .none
        case .shapes(let group): return .shapes(try convertShapeGroup(group, field: "\(field).shapes"))
        }
    }

    // MARK: - Transforms / tracks (field-correct numeric semantics)

    private static func convertTransform(_ t: CompiledTransformDTO, field: String) throws -> RenderTransform {
        RenderTransform(
            position: try vectorTrack(t.position, field: "\(field).position"),
            scale: try scaleTrack(t.scale, field: "\(field).scale"),
            rotation: try rotationTrack(t.rotation, field: "\(field).rotation"),
            opacity: try opacityPercentTrack(t.opacity, field: "\(field).opacity"),
            anchor: try vectorTrack(t.anchor, field: "\(field).anchor"))
    }

    private static func convertGroupTransform(_ t: CompiledGroupTransformDTO, field: String) throws -> RenderGroupTransform {
        RenderGroupTransform(
            position: try vectorTrack(t.position, field: "\(field).position"),
            anchor: try vectorTrack(t.anchor, field: "\(field).anchor"),
            scale: try scaleTrack(t.scale, field: "\(field).scale"),
            rotation: try rotationTrack(t.rotation, field: "\(field).rotation"),
            // Group-transform opacity is UNIT (0–1), not percent — see opacityUnitTrack / TVECore.
            opacity: try opacityUnitTrack(t.opacity, field: "\(field).opacity"))
    }

    private static func vectorTrack(_ track: CompiledVectorTrackDTO, field: String) throws -> RenderVectorTrack {
        switch track {
        case .static(let v): return .static(try vec2(v, field: field))
        case .keyframed(let ks):
            return .keyframed(try ks.enumerated().map { i, k in
                try keyframe(k, field: "\(field)[\(i)]") { try vec2($0, field: "\(field)[\(i)].value") } })
        }
    }

    private static func scaleTrack(_ track: CompiledVectorTrackDTO, field: String) throws -> RenderScaleTrack {
        switch track {
        case .static(let v): return .static(try scaleVec2(v, field: field))
        case .keyframed(let ks):
            return .keyframed(try ks.enumerated().map { i, k in
                try keyframe(k, field: "\(field)[\(i)]") { try scaleVec2($0, field: "\(field)[\(i)].value") } })
        }
    }

    private static func rotationTrack(_ track: CompiledScalarTrackDTO, field: String) throws -> RenderRotationTrack {
        switch track {
        case .static(let v): return .static(try FixedPointConversion.rotationScalar(degrees: v, field: field))
        case .keyframed(let ks):
            return .keyframed(try ks.enumerated().map { i, k in
                try keyframe(k, field: "\(field)[\(i)]") { try FixedPointConversion.rotationScalar(degrees: $0, field: "\(field)[\(i)].value") } })
        }
    }

    private static func opacityPercentTrack(_ track: CompiledScalarTrackDTO, field: String) throws -> RenderOpacityTrack {
        switch track {
        case .static(let v): return .static(try FixedPointConversion.opacity(percent: v, field: field))
        case .keyframed(let ks):
            return .keyframed(try ks.enumerated().map { i, k in
                try keyframe(k, field: "\(field)[\(i)]") { try FixedPointConversion.opacity(percent: $0, field: "\(field)[\(i)].value") } })
        }
    }

    /// Shape GROUP-transform opacity is authored in the **0–1 unit** range (matches the TVECore oracle:
    /// `GroupTransform.opacity` default `.static(1.0)`, `opacityValue` samples it raw with NO ÷100 —
    /// unlike LAYER opacity which is 0–100). Converting it as a percent (÷100) wrongly turned an
    /// authored 1.0 into 0.01, near-zeroing matte-source shapes so `alpha` mattes produced nothing
    /// (example_4blocks block_02) and inverted mattes were wrong (block_03).
    private static func opacityUnitTrack(_ track: CompiledScalarTrackDTO, field: String) throws -> RenderOpacityTrack {
        switch track {
        case .static(let v): return .static(try FixedPointConversion.opacity(unit: v, field: field))
        case .keyframed(let ks):
            return .keyframed(try ks.enumerated().map { i, k in
                try keyframe(k, field: "\(field)[\(i)]") { try FixedPointConversion.opacity(unit: $0, field: "\(field)[\(i)].value") } })
        }
    }

    private static func widthTrack(_ track: CompiledScalarTrackDTO, field: String) throws -> RenderScalarTrack {
        switch track {
        case .static(let v): return .static(try FixedPointConversion.canvasScalar(points: v, field: field))
        case .keyframed(let ks):
            return .keyframed(try ks.enumerated().map { i, k in
                try keyframe(k, field: "\(field)[\(i)]") { try FixedPointConversion.canvasScalar(points: $0, field: "\(field)[\(i)].value") } })
        }
    }

    // MARK: - Masks / shapes / paths

    private static func convertMask(_ mask: CompiledMaskDTO, field: String) throws -> RenderMask {
        RenderMask(
            mode: mask.mode.rawValue, inverted: mask.inverted,
            opacity: try FixedPointConversion.opacity(percent: mask.opacity, field: "\(field).opacity"),
            path: try convertPath(mask.path, field: "\(field).path"), pathID: mask.pathID)
    }

    private static func convertShapeGroup(_ group: CompiledShapeGroupDTO, field: String) throws -> RenderShapeGroup {
        RenderShapeGroup(
            animPath: try group.animPath.map { try convertPath($0, field: "\(field).animPath") },
            fillColor: try group.fillColor.map { try color($0, field: "\(field).fillColor") },
            fillOpacity: try FixedPointConversion.opacity(percent: group.fillOpacity, field: "\(field).fillOpacity"),
            stroke: try group.stroke.map { try convertStroke($0, field: "\(field).stroke") },
            groupTransforms: try group.groupTransforms.enumerated().map {
                try convertGroupTransform($1, field: "\(field).groupTransforms[\($0)]") },
            pathID: group.pathID)
    }

    private static func convertStroke(_ stroke: CompiledStrokeDTO, field: String) throws -> RenderStroke {
        RenderStroke(
            color: try color(stroke.color, field: "\(field).color"),
            opacity: try FixedPointConversion.opacity(unit: stroke.opacity, field: "\(field).opacity"),
            width: try widthTrack(stroke.width, field: "\(field).width"),
            lineCap: stroke.lineCap, lineJoin: stroke.lineJoin,
            miterLimit: MiterScalar(rawValue: try FixedPointConversion.dimensionlessRaw(stroke.miterLimit, field: "\(field).miterLimit")))
    }

    private static func convertPath(_ path: CompiledAnimatedPathDTO, field: String) throws -> RenderAnimatedPath {
        switch path {
        case .static(let b): return .static(try bezier(b, field: field))
        case .keyframed(let ks):
            return .keyframed(try ks.enumerated().map { i, k in
                try keyframe(k, field: "\(field)[\(i)]") { try bezier($0, field: "\(field)[\(i)].value") } })
        }
    }

    private static func bezier(_ b: CompiledBezierDTO, field: String) throws -> RenderBezier {
        RenderBezier(
            vertices: try b.vertices.enumerated().map { try vec2($1, field: "\(field).v[\($0)]") },
            inTangents: try b.inTangents.enumerated().map { try vec2($1, field: "\(field).in[\($0)]") },
            outTangents: try b.outTangents.enumerated().map { try vec2($1, field: "\(field).out[\($0)]") },
            closed: b.closed)
    }

    // MARK: - Leaves

    private static func vec2(_ v: CompiledVec2DTO, field: String) throws -> RenderVec2 {
        RenderVec2(
            x: try FixedPointConversion.canvasScalar(points: v.x, field: "\(field).x"),
            y: try FixedPointConversion.canvasScalar(points: v.y, field: "\(field).y"))
    }

    private static func scaleVec2(_ v: CompiledVec2DTO, field: String) throws -> RenderScaleVec2 {
        RenderScaleVec2(
            x: try FixedPointConversion.scaleScalar(percent: v.x, field: "\(field).x"),
            y: try FixedPointConversion.scaleScalar(percent: v.y, field: "\(field).y"))
    }

    private static func color(_ components: [Double], field: String) throws -> RenderColor {
        RenderColor(components: try components.enumerated().map { i, c in
            try FixedPointConversion.normalizedColorComponent(c, field: "\(field)[\(i)]") })
    }

    private static func keyframe<DTOValue, RenderValue: Hashable & Sendable>(
        _ k: CompiledKeyframeDTO<DTOValue>, field: String, _ convertValue: (DTOValue) throws -> RenderValue
    ) throws -> RenderKeyframe<RenderValue> {
        RenderKeyframe(
            time: try FixedPointConversion.exactRational(k.time, field: "\(field).time"),
            value: try convertValue(k.value), hold: k.hold,
            // Keyframe tangents are Lottie easing controls → EasingScalar via dimensionlessRaw (item 2),
            // never canvas coordinates.
            inTangent: try k.inTangent.map { try easingVec2($0, field: "\(field).inTangent") },
            outTangent: try k.outTangent.map { try easingVec2($0, field: "\(field).outTangent") })
    }

    private static func easingVec2(_ v: CompiledVec2DTO, field: String) throws -> RenderEasingVec2 {
        RenderEasingVec2(
            x: EasingScalar(rawValue: try FixedPointConversion.dimensionlessRaw(v.x, field: "\(field).x")),
            y: EasingScalar(rawValue: try FixedPointConversion.dimensionlessRaw(v.y, field: "\(field).y")))
    }
}
