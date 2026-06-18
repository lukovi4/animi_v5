import XCTest
import Foundation
import AnimiEngineCore
import AnimiEngineRenderModel
@testable import AnimiEngineRenderGraph

/// Task-003 / Step-16 corrective — regression tests for the precomp/parent-layer opacity propagation bugfix.
///
/// Bug (found in the Step-16 review of the sealed run): a precomp layer's opacity (animated or static) was
/// computed but DROPPED at the precomp boundary — `expandComposition` threaded `parentWorld` (transform) but
/// not the parent opacity. So an opacity keyframe on a precomp/root layer had no effect on the rendered
/// subtree. Fix: thread `parentOpacity` through `expandComposition`, and accumulate a layer's opacity along
/// its parent chain (`opacityWithinComp`), symmetric to `worldWithinComp` for transforms.
///
/// These tests assert at the COMPILED-GRAPH level (drawImage payload opacity), i.e. before Metal — that is
/// where the bug lived and where the fix must show.
final class PrecompParentOpacityTests: XCTestCase {

    private typealias F = GraphTestFixtures
    private static let pt = CanvasScalar.unitsPerPoint
    private func cs(_ v: Int64) -> CanvasScalar { CanvasScalar(rawValue: v) }
    private func frame(_ n: Int64) throws -> RationalSourceTime { try RationalSourceTime(numerator: n, denominator: 1) }

    private func transform(opacity: RenderOpacityTrack, parent: Bool = false) -> RenderTransform {
        RenderTransform(
            position: .static(RenderVec2(x: cs(0), y: cs(0))),
            scale: .static(RenderScaleVec2(x: ScaleScalar(rawValue: ScaleScalar.unitsPerUnit), y: ScaleScalar(rawValue: ScaleScalar.unitsPerUnit))),
            rotation: .static(RotationScalar(rawValue: 0)),
            opacity: opacity,
            anchor: .static(RenderVec2(x: cs(0), y: cs(0))))
    }

    private func timing() throws -> RenderLayerTiming {
        RenderLayerTiming(inPoint: try frame(0), outPoint: try frame(150), startTime: .zero)
    }

    /// A program where the ROOT comp has ONE precomp layer (id 1) whose opacity is `rootOpacity`, and the
    /// inner comp "inner" has ONE bound image layer (id 2). The bound media layer is inside the precomp.
    private func precompProgram(rootOpacity: RenderOpacityTrack) throws -> RenderMaterialProgram {
        let boundImage = RenderLayer(id: 2, name: "media", type: 2, timing: try timing(), parentLayerID: nil,
            transform: transform(opacity: .static(.opaque)), masks: [], matte: nil,
            content: .image(assetID: "boundAsset"), isMatteSource: false, isHidden: false, toggleID: nil)
        let inner = RenderComposition(id: "inner", width: cs(1080 * Self.pt), height: cs(1920 * Self.pt), layers: [boundImage])
        let precompLayer = RenderLayer(id: 1, name: "root-precomp", type: 0, timing: try timing(), parentLayerID: nil,
            transform: transform(opacity: rootOpacity), masks: [], matte: nil,
            content: .precomp(compID: "inner"), isMatteSource: false, isHidden: false, toggleID: nil)
        let root = RenderComposition(id: "comp_0", width: cs(1080 * Self.pt), height: cs(1920 * Self.pt), layers: [precompLayer])
        // Bind the media to the INNER image layer (id 2) inside "inner".
        let binding = RenderBinding(bindingKey: "media", boundAssetID: "boundAsset", boundCompID: "inner", boundLayerID: 2)
        return try RenderMaterialProgram(
            id: try RenderMaterialID(compiledTemplateHash: "t", blockID: "blk", variantID: "v"),
            blockID: "blk", variantID: "v", animationRef: "anim.json", boundAssetID: "boundAsset",
            mediaGeometry: try F.mediaGeometry(), rootCompID: "comp_0", compositions: [root, inner],
            assets: [], binding: binding, inputGeometry: nil, meta: try F.meta(),
            pathResources: [], toggleIDs: [])
    }

    /// Matches the program's variantID ("v") so RenderInputResolver's animation-variant check passes.
    private func animRef() throws -> AnimationReference {
        try AnimationReference(variantID: "v", animationRef: "anim.json",
            authoredDuration: try TickDuration(ticks: 8_000_000), ifShorter: .holdLast, ifLonger: .cutAtEvaluationEnd)
    }

    private func compileDrawOpacities(rootOpacity: RenderOpacityTrack) throws -> [Int64] {
        let program = try precompProgram(rootOpacity: rootOpacity)
        let layer = try F.imageActiveLayer("blk", ref: "media-ref", order: 0, request: .sample(.zero), animation: try animRef())
        let plan = try F.singlePlan(scene: "inst", layers: [layer])
        let input = try F.singleInput(scene: "inst", [(layer: "blk", program: program, pixID: "px")])
        let graph = try RenderGraphCompiler.compile(plan: plan, input: input, configuration: try F.config())
        var ops: [Int64] = []
        for c in graph.commands { if case let .drawImage(_, _, op, _) = c.payload { ops.append(op.rawValue) } }
        return ops
    }

    // 1) precomp opacity 0 ⇒ the subtree draws at opacity 0 (transparent), not 100%.
    func testPrecompOpacityZeroMakesSubtreeTransparent() throws {
        let ops = try compileDrawOpacities(rootOpacity: .static(try OpacityScalar(rawValue: 0)))
        XCTAssertFalse(ops.isEmpty, "the bound image draws")
        XCTAssertTrue(ops.allSatisfy { $0 == 0 }, "precomp opacity 0 ⇒ child draw opacity 0, got \(ops)")
    }

    // 2) precomp opacity 100 ⇒ subtree draws at full opacity (no regression for the common case).
    func testPrecompOpacityFullKeepsSubtreeOpaque() throws {
        let ops = try compileDrawOpacities(rootOpacity: .static(.opaque))
        XCTAssertTrue(ops.allSatisfy { $0 == OpacityScalar.unitsPerUnit }, "precomp opacity 100 ⇒ full, got \(ops)")
    }

    // 3) precomp opacity 50% ⇒ child draw opacity is exactly 50% (product, checked fixed point).
    func testPrecompOpacityHalfScalesChild() throws {
        let half = OpacityScalar.unitsPerUnit / 2
        let ops = try compileDrawOpacities(rootOpacity: .static(try OpacityScalar(rawValue: half)))
        XCTAssertTrue(ops.allSatisfy { $0 == half }, "precomp opacity 0.5 ⇒ child 0.5, got \(ops)")
    }

    // 4) opacity keyframe 0→100 on the precomp layer interpolates: at t=0 child is 0, at the end it is full,
    //    and the two graphs differ (payload/hash change with time — the keyframe now has effect).
    func testPrecompOpacityKeyframeInterpolatesAndChangesPayload() throws {
        let kfTrack: RenderOpacityTrack = .keyframed([
            RenderKeyframe(time: try frame(0), value: try OpacityScalar(rawValue: 0), hold: false, inTangent: nil, outTangent: nil),
            RenderKeyframe(time: try frame(30), value: .opaque, hold: false, inTangent: nil, outTangent: nil),
        ])
        // At t=0 the precomp opacity keyframe value is 0 ⇒ child draws transparent.
        let program = try precompProgram(rootOpacity: kfTrack)
        func opsAt(tick: Int64) throws -> (ops: [Int64], hash: String) {
            let layer = try F.imageActiveLayer("blk", ref: "media-ref", order: 0,
                request: .sample(try AnimationPlaybackTime(ticks: tick)), animation: try animRef())
            let plan = try F.singlePlan(scene: "inst", layers: [layer])
            let input = try F.singleInput(scene: "inst", [(layer: "blk", program: program, pixID: "px")])
            let graph = try RenderGraphCompiler.compile(plan: plan, input: input, configuration: try F.config())
            var ops: [Int64] = []
            for c in graph.commands { if case let .drawImage(_, _, op, _) = c.payload { ops.append(op.rawValue) } }
            return (ops, try graph.graphHash())
        }
        let atZero = try opsAt(tick: 0)
        // 30 frames at 30fps = 1s = 240000 ticks ⇒ end of the fade (opacity 100).
        let atEnd = try opsAt(tick: 240_000)
        XCTAssertTrue(atZero.ops.allSatisfy { $0 == 0 }, "fade-in keyframe @t0 ⇒ child opacity 0, got \(atZero.ops)")
        XCTAssertTrue(atEnd.ops.allSatisfy { $0 == OpacityScalar.unitsPerUnit }, "fade-in keyframe @end ⇒ full, got \(atEnd.ops)")
        XCTAssertNotEqual(atZero.hash, atEnd.hash, "the opacity keyframe must change the graph payload/hash over time")
    }

    // 5) null/parent opacity: a child whose parent is a null layer (opacity 0) draws transparent — parent
    //    opacity is inherited like parent transform.
    func testNullParentOpacityInheritedByChild() throws {
        // Root comp: null/parent layer id 1 (opacity 0), child image layer id 2 parented to 1.
        let nullParent = RenderLayer(id: 1, name: "null", type: 3, timing: try timing(), parentLayerID: nil,
            transform: transform(opacity: .static(try OpacityScalar(rawValue: 0))), masks: [], matte: nil,
            content: .none, isMatteSource: false, isHidden: false, toggleID: nil)
        let child = RenderLayer(id: 2, name: "media", type: 2, timing: try timing(), parentLayerID: 1,
            transform: transform(opacity: .static(.opaque)), masks: [], matte: nil,
            content: .image(assetID: "boundAsset"), isMatteSource: false, isHidden: false, toggleID: nil)
        let root = RenderComposition(id: "comp_0", width: cs(1080 * Self.pt), height: cs(1920 * Self.pt), layers: [nullParent, child])
        let binding = RenderBinding(bindingKey: "media", boundAssetID: "boundAsset", boundCompID: "comp_0", boundLayerID: 2)
        let program = try RenderMaterialProgram(
            id: try RenderMaterialID(compiledTemplateHash: "t", blockID: "blk", variantID: "v"),
            blockID: "blk", variantID: "v", animationRef: "anim.json", boundAssetID: "boundAsset",
            mediaGeometry: try F.mediaGeometry(), rootCompID: "comp_0", compositions: [root],
            assets: [], binding: binding, inputGeometry: nil, meta: try F.meta(), pathResources: [], toggleIDs: [])
        let layer = try F.imageActiveLayer("blk", ref: "media-ref", order: 0, request: .sample(.zero), animation: try animRef())
        let plan = try F.singlePlan(scene: "inst", layers: [layer])
        let input = try F.singleInput(scene: "inst", [(layer: "blk", program: program, pixID: "px")])
        let graph = try RenderGraphCompiler.compile(plan: plan, input: input, configuration: try F.config())
        var ops: [Int64] = []
        for c in graph.commands { if case let .drawImage(_, _, op, _) = c.payload { ops.append(op.rawValue) } }
        XCTAssertFalse(ops.isEmpty, "child draws")
        XCTAssertTrue(ops.allSatisfy { $0 == 0 }, "null parent opacity 0 ⇒ child draw opacity 0, got \(ops)")
    }
}
