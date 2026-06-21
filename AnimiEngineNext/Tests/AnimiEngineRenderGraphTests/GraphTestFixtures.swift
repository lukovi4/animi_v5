import Foundation
import AnimiEngineCore
import AnimiEngineRenderModel
@testable import AnimiEngineRenderGraph

/// Shared fixtures for the corrected RenderGraph compiler tests: build `RenderMaterialProgram`s with a
/// real composition tree (binding layer + authored image + precomp + shape + mask + matte), the
/// matching `ActiveLayer`/`FramePlan`, and a complete `ResolvedFrameInput` (media + asset pixels).
enum GraphTestFixtures {
    static let pt = CanvasScalar.unitsPerPoint
    static func cs(_ v: Int64) -> CanvasScalar { CanvasScalar(rawValue: v) }
    static func frame(_ n: Int64) throws -> RationalSourceTime { try RationalSourceTime(numerator: n, denominator: 1) }

    static func staticTransform(posX: Int64 = 0, posY: Int64 = 0, scale: Int64 = ScaleScalar.unitsPerUnit,
                                rotDeg: Int64 = 0, anchorX: Int64 = 0, anchorY: Int64 = 0) -> RenderTransform {
        RenderTransform(
            position: .static(RenderVec2(x: cs(posX), y: cs(posY))),
            scale: .static(RenderScaleVec2(x: ScaleScalar(rawValue: scale), y: ScaleScalar(rawValue: scale))),
            rotation: .static(RotationScalar(rawValue: rotDeg * 1000)),
            opacity: .static(.opaque),
            anchor: .static(RenderVec2(x: cs(anchorX), y: cs(anchorY))))
    }

    static func timing(_ inP: Int64 = 0, _ outP: Int64 = 150) throws -> RenderLayerTiming {
        RenderLayerTiming(inPoint: try frame(inP), outPoint: try frame(outP), startTime: .zero)
    }

    static func bezier() -> RenderAnimatedPath {
        .static(RenderBezier(
            vertices: [RenderVec2(x: cs(0), y: cs(0)), RenderVec2(x: cs(100), y: cs(0)), RenderVec2(x: cs(100), y: cs(100))],
            inTangents: [RenderVec2(x: cs(0), y: cs(0)), RenderVec2(x: cs(0), y: cs(0)), RenderVec2(x: cs(0), y: cs(0))],
            outTangents: [RenderVec2(x: cs(0), y: cs(0)), RenderVec2(x: cs(0), y: cs(0)), RenderVec2(x: cs(0), y: cs(0))],
            closed: true))
    }

    /// A producer path resource (Step-11): a static closed triangle, `vertexCount = 3`, indices [0,1,2].
    /// `pathID` defaults to 7. The positions are in `CanvasScalar` raw (points × unitsPerPoint).
    static func pathResource(id pathID: Int = 7) throws -> RenderPathResource {
        try RenderPathResource(
            pathID: pathID, vertexCount: 3, indices: [0, 1, 2],
            keyframeTimes: [try frame(0)],
            keyframePositions: [[cs(0), cs(0), cs(100 * pt), cs(0), cs(100 * pt), cs(100 * pt)]],
            keyframeEasing: [])
    }

    /// A closed control bezier (3 anchors) that pairs with `pathResource` for masks/shapes.
    static func closedBezier() -> RenderAnimatedPath { bezier() }

    static func meta() throws -> RenderProgramMeta {
        RenderProgramMeta(width: cs(1080 * pt), height: cs(1920 * pt), fps: try frame(30),
                          inPoint: .zero, outPoint: try frame(150), sourceAnimRef: "anim.json")
    }

    static func mediaGeometry(containerClip: String = "none") throws -> RenderMediaGeometry {
        let rect = try FixedRect(x: cs(0), y: cs(0), width: cs(100 * pt), height: cs(100 * pt))
        return RenderMediaGeometry(contentSizeWidth: cs(100 * pt), contentSizeHeight: cs(100 * pt),
            contentRect: rect, placementRect: rect, blockRectCanvas: rect, containerClip: containerClip)
    }

    /// A program whose root comp = [binding image layer (id 1)] plus optional extra layers.
    static func program(
        block: String, variant: String = "v",
        extraRootLayers: [RenderLayer] = [], extraComps: [RenderComposition] = [],
        assets: [RenderAsset] = [], pathResources: [RenderPathResource] = []
    ) throws -> RenderMaterialProgram {
        let bound = RenderLayer(id: 1, name: "media", type: 2, timing: try timing(), parentLayerID: nil,
            transform: staticTransform(), masks: [], matte: nil, content: .image(assetID: "boundAsset"),
            isMatteSource: false, isHidden: false, toggleID: nil)
        let root = RenderComposition(id: "comp_0", width: cs(1080 * pt), height: cs(1920 * pt), layers: [bound] + extraRootLayers)
        let binding = RenderBinding(bindingKey: "media", boundAssetID: "boundAsset", boundCompID: "comp_0", boundLayerID: 1)
        return try RenderMaterialProgram(
            id: try RenderMaterialID(compiledTemplateHash: "t", blockID: block, variantID: variant),
            blockID: block, variantID: variant, animationRef: "anim.json", boundAssetID: "boundAsset",
            mediaGeometry: try mediaGeometry(), rootCompID: "comp_0", compositions: [root] + extraComps,
            assets: assets, binding: binding, inputGeometry: nil, meta: try meta(),
            pathResources: pathResources, toggleIDs: [])
    }

    static func pixels(_ id: String, _ w: Int = 64, _ h: Int = 64, fill: UInt8 = 0xFF) throws -> ResolvedPixelInput {
        try ResolvedPixelInput(id: try PixelInputID(id),
            dimensions: try PixelDimensions(width: w, height: h, bytesPerRow: w * 4, format: .bgra8, orientation: .up),
            bytes: Data(repeating: fill, count: w * h * 4))
    }

    static func imageActiveLayer(_ id: String, ref: String, order: Int, request: AnimationRequest = .holdLast,
                                 animation: AnimationReference? = nil) throws -> ActiveLayer {
        ActiveLayer(layerID: try LayerID(id), zIndex: order, stableOrdinal: order, localCompositionOrder: order,
            placement: try Placement(frame: try FixedRect(x: cs(0), y: cs(0), width: cs(100 * pt), height: cs(100 * pt)), scale: .one, rotation: .zero),
            mediaPlacement: .identity(fitMode: .contain), content: .image(try ImageReference(ref)),
            animationReference: animation, animationRequest: request)
    }

    static func config() throws -> RenderConfiguration {
        try RenderConfiguration(
            output: OutputContext(canvas: try CanvasSize(width: 1080, height: 1920), frameRate: try FrameRate(numerator: 30, denominator: 1)),
            intermediateProfile: .rgba16FloatLinear)
    }

    static func singlePlan(scene s: String, layers: [ActiveLayer], overlays: [ActiveOverlay] = []) throws -> FramePlan {
        FramePlan(output: OutputContext(canvas: try CanvasSize(width: 1080, height: 1920), frameRate: try FrameRate(numerator: 30, denominator: 1)),
            projectTime: try ProjectTime(ticks: 0),
            body: .single(SceneSubplan(sceneID: try SceneInstanceID(s), role: .sole, visualPlaybackTime: .zero, mediaPlaybackTime: .zero, transitionRelativeTime: nil, layers: layers)),
            overlays: overlays)
    }

    /// Builds a ResolvedFrameInput for a single-scene plan: one entry per layer + optional asset pixels.
    static func singleInput(
        scene s: String, _ entries: [(layer: String, program: RenderMaterialProgram, pixID: String)],
        assetPixels: [ResolvedAssetPixelEntry] = [], overlays: [ResolvedOverlayEntry] = []
    ) throws -> ResolvedFrameInput {
        let scene = try SceneInstanceID(s)
        let sceneEntries = try entries.map { e -> ResolvedSceneLayerEntry in
            try ResolvedSceneLayerEntry(
                key: .sceneLayer(sceneID: scene, role: .sole, layerID: try LayerID(e.layer)),
                program: e.program, pixelInput: try pixels(e.pixID),
                placement: ResolvedMediaPlacement(fitMode: .contain, transform: .identity, clip: .none))
        }
        return try ResolvedFrameInput(sceneLayers: sceneEntries, overlays: overlays, assetPixels: assetPixels)
    }
}
