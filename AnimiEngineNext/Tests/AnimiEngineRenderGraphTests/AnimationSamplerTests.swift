import XCTest
import AnimiEngineCore
import AnimiEngineRenderModel
@testable import AnimiEngineRenderGraph

/// Task-003 §7.2, §13 rows "Animation" / parent transforms / cubic interpolation / hold keyframes —
/// `AnimationSampler` fixed-point track sampling, request modes, and the local/world transform chain.
final class AnimationSamplerTests: XCTestCase {

    private func cs(_ v: Int64) -> CanvasScalar { CanvasScalar(rawValue: v) }
    private func frame(_ n: Int64) throws -> RationalSourceTime { try RationalSourceTime(numerator: n, denominator: 1) }

    private func vkf(_ time: Int64, _ x: Int64, _ y: Int64, hold: Bool = false) throws -> RenderKeyframe<RenderVec2> {
        RenderKeyframe(time: try frame(time), value: RenderVec2(x: cs(x), y: cs(y)), hold: hold, inTangent: nil, outTangent: nil)
    }

    // MARK: - Static and keyframed linear interpolation

    func testStaticTrackReturnsValue() throws {
        let track = RenderVectorTrack.static(RenderVec2(x: cs(100), y: cs(200)))
        let r = try AnimationSampler.sampleVector(track, at: try frame(5), field: "t")
        XCTAssertEqual(r.x, 100); XCTAssertEqual(r.y, 200)
    }

    func testLinearInterpolationMidpoint() throws {
        // kf at frame 0 → (0,0), frame 10 → (100, 200). Linear (no tangents). At frame 5 → (50, 100).
        let track = RenderVectorTrack.keyframed([try vkf(0, 0, 0), try vkf(10, 100, 200)])
        let r = try AnimationSampler.sampleVector(track, at: try frame(5), field: "t")
        XCTAssertEqual(r.x, 50); XCTAssertEqual(r.y, 100)
    }

    func testClampBeforeFirstAndAfterLast() throws {
        let track = RenderVectorTrack.keyframed([try vkf(2, 10, 10), try vkf(8, 90, 90)])
        let before = try AnimationSampler.sampleVector(track, at: try frame(0), field: "t")
        XCTAssertEqual(before.x, 10)   // clamped to first
        let after = try AnimationSampler.sampleVector(track, at: try frame(100), field: "t")
        XCTAssertEqual(after.x, 90)    // clamped to last
    }

    func testHoldKeyframeDoesNotInterpolate() throws {
        // lo keyframe is hold → value stays at lo across the segment.
        let track = RenderVectorTrack.keyframed([try vkf(0, 10, 10, hold: true), try vkf(10, 90, 90)])
        let mid = try AnimationSampler.sampleVector(track, at: try frame(5), field: "t")
        XCTAssertEqual(mid.x, 10); XCTAssertEqual(mid.y, 10)
    }

    func testMalformedTracksRejected() {
        XCTAssertThrowsError(try AnimationSampler.sampleVector(.keyframed([]), at: try frame(0), field: "t"))
        // non-increasing times
        XCTAssertThrowsError(try AnimationSampler.sampleVector(
            .keyframed([try vkf(5, 0, 0), try vkf(5, 1, 1)]), at: try frame(5), field: "t"))
    }

    // MARK: - Animation request modes

    private func meta(fps: Int64) -> RenderProgramMeta {
        RenderProgramMeta(width: cs(1), height: cs(1),
            fps: (try? RationalSourceTime(numerator: fps, denominator: 1)) ?? .zero,
            inPoint: .zero, outPoint: (try? RationalSourceTime(numerator: 30, denominator: 1)) ?? .zero,
            sourceAnimRef: "a")
    }

    func testInactiveRequestReturnsNil() throws {
        XCTAssertNil(try AnimationSampler.frameTime(for: .inactive, meta: meta(fps: 30), authoredDurationTicks: 240_000))
    }

    func testHoldLastReturnsLastRepresentableInstant() throws {
        // Corrective #8: holdLast = outPoint − 1 frame (the last representable authored instant), not
        // the exclusive outPoint. meta.outPoint == frame 30 → holdLast samples frame 29.
        let f = try AnimationSampler.frameTime(for: .holdLast, meta: meta(fps: 30), authoredDurationTicks: 240_000)
        XCTAssertEqual(f, try frame(29))
    }

    func testSampleConvertsTicksToFrames() throws {
        // 0.5s at 30fps = frame 15. 0.5s = 120_000 ticks.
        let t = try AnimationPlaybackTime(ticks: 120_000)
        let f = try AnimationSampler.frameTime(for: .sample(t), meta: meta(fps: 30), authoredDurationTicks: 240_000)
        XCTAssertEqual(f, try frame(15))
    }

    func testLoopedWraps() throws {
        // authored 1s (240_000 ticks); request 1.5s → wraps to 0.5s → frame 15 at 30fps.
        let t = try AnimationPlaybackTime(ticks: 360_000)
        let f = try AnimationSampler.frameTime(for: .looped(t), meta: meta(fps: 30), authoredDurationTicks: 240_000)
        XCTAssertEqual(f, try frame(15))
    }

    // MARK: - Local / world transform composition

    private func staticTransform(posX: Int64, posY: Int64, scale: Int64 = ScaleScalar.unitsPerUnit,
                                 rotDeg: Int64 = 0, anchorX: Int64 = 0, anchorY: Int64 = 0) -> RenderTransform {
        RenderTransform(
            position: .static(RenderVec2(x: cs(posX), y: cs(posY))),
            scale: .static(RenderScaleVec2(x: ScaleScalar(rawValue: scale), y: ScaleScalar(rawValue: scale))),
            rotation: .static(RotationScalar(rawValue: rotDeg * 1000)),
            opacity: .static(.opaque),
            anchor: .static(RenderVec2(x: cs(anchorX), y: cs(anchorY))))
    }

    private func layer(_ id: Int, parent: Int?, _ transform: RenderTransform) -> RenderLayer {
        RenderLayer(id: id, name: "L\(id)", type: 2,
            timing: RenderLayerTiming(inPoint: .zero, outPoint: (try? frame(30)) ?? .zero, startTime: .zero),
            parentLayerID: parent, transform: transform, masks: [], matte: nil,
            content: .image(assetID: "a"), isMatteSource: false, isHidden: false, toggleID: nil)
    }

    func testLocalTransformTranslate() throws {
        let local = try AnimationSampler.localTransform(staticTransform(posX: 10, posY: 20), at: try frame(0), field: "t")
        let p = try local.apply(x: 0, y: 0)
        XCTAssertEqual(p.x, 10); XCTAssertEqual(p.y, 20)
    }

    func testWorldTransformComposesParentChain() throws {
        // parent translates (100,0); child translates (10,5). world(child) origin → (110,5).
        let comp = RenderComposition(id: "c", width: cs(1000), height: cs(1000), layers: [
            layer(1, parent: nil, staticTransform(posX: 100, posY: 0)),
            layer(2, parent: 1, staticTransform(posX: 10, posY: 5))
        ])
        let world = try AnimationSampler.worldTransform(ofLayerID: 2, in: comp, at: try frame(0))
        let p = try world.apply(x: 0, y: 0)
        XCTAssertEqual(p.x, 110); XCTAssertEqual(p.y, 5)
    }

    func testParentCycleRejected() {
        let comp = RenderComposition(id: "c", width: cs(1), height: cs(1), layers: [
            layer(1, parent: 2, staticTransform(posX: 0, posY: 0)),
            layer(2, parent: 1, staticTransform(posX: 0, posY: 0))
        ])
        XCTAssertThrowsError(try AnimationSampler.worldTransform(ofLayerID: 1, in: comp, at: try frame(0))) { error in
            guard case RenderGraphError.parentCycle? = error as? RenderGraphError else {
                return XCTFail("expected parentCycle, got \(error)")
            }
        }
    }

    func testMissingParentRejected() {
        let comp = RenderComposition(id: "c", width: cs(1), height: cs(1), layers: [
            layer(1, parent: 99, staticTransform(posX: 0, posY: 0))
        ])
        XCTAssertThrowsError(try AnimationSampler.worldTransform(ofLayerID: 1, in: comp, at: try frame(0))) { error in
            guard case RenderGraphError.missingParentLayer? = error as? RenderGraphError else {
                return XCTFail("expected missingParentLayer, got \(error)")
            }
        }
    }

    func testSamplerDeterministic() throws {
        let comp = RenderComposition(id: "c", width: cs(1), height: cs(1), layers: [
            layer(1, parent: nil, staticTransform(posX: 7, posY: 9, scale: 2_000_000, rotDeg: 30))
        ])
        let a = try AnimationSampler.worldTransform(ofLayerID: 1, in: comp, at: try frame(0))
        let b = try AnimationSampler.worldTransform(ofLayerID: 1, in: comp, at: try frame(0))
        XCTAssertEqual(a, b)
    }
}
