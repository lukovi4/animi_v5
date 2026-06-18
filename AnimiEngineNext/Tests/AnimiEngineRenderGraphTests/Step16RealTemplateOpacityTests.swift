import XCTest
import Foundation
import AnimiEngineCore
import AnimiEngineRenderModel
@testable import AnimiEngineRenderGraph
@testable import AnimiEngineRenderTestSupport

/// Task-003 / Step-16 corrective — targeted real-template assertions for the precomp/parent-opacity bugfix,
/// asserted at the COMPILED-GRAPH level (the fix is before Metal). Uses the same `RealTemplateMatrix` compile
/// path that produces the sealed-run candidates. READ-ONLY over the real compiled templates.
final class Step16RealTemplateOpacityTests: XCTestCase {

    private func scenesRoot() -> URL {
        // Tests/AnimiEngineRenderGraphTests/<file> → 4 up → repo root.
        var url = URL(fileURLWithPath: #file)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("AnimiApp/Resources/Scenes")
    }
    private func config() throws -> RenderConfiguration {
        try RenderConfiguration(
            output: OutputContext(canvas: try CanvasSize(width: 1080, height: 1920), frameRate: try FrameRate(numerator: 30, denominator: 1)),
            intermediateProfile: .rgba16FloatLinear)
    }
    private func graph(block: String, variant: String, tick: Int64) throws -> RenderGraph {
        switch try RealTemplateMatrix.compileOutcome(
            row: RealTemplateMatrix.Row(catalogID: "example_4blocks", blockID: block, variantID: variant, projectTimeTicks: tick, frameKind: "t"),
            scenesRootURL: scenesRoot(), configuration: try config()) {
        case .renderable(let cr): return cr.graph
        case .skippedInactive(_, let why): throw XCTSkip("skipped: \(why)")
        }
    }
    private func drawOpacities(_ g: RenderGraph) -> [Int64] {
        var ops: [Int64] = []
        for c in g.commands { if case let .drawImage(_, _, op, _) = c.payload { ops.append(op.rawValue) } }
        return ops
    }

    private func zeroCount(_ g: RenderGraph) -> Int { drawOpacities(g).filter { $0 == 0 }.count }

    // v4 @tick0 had opacity keyframe [0]@t=0 dropped → rendered as no-anim (block_01 at 100%). After the fix
    // block_01's draw opacity is 0 at t=0, so v4@t0 has STRICTLY MORE opacity-0 draws than no-anim@t0, and a
    // different graph hash. (no-anim@t0 already has one opacity-0 draw: block_02's null-parent opacity is
    // authored static 0 — itself a case the fix now honours.)
    func testBlock01V4Tick0OpacityNoLongerFull() throws {
        let v4 = try graph(block: "block_01", variant: "v4", tick: 0)
        let noAnim = try graph(block: "block_01", variant: "no-anim", tick: 0)
        XCTAssertEqual(zeroCount(v4), zeroCount(noAnim) + 1,
                       "v4@t0 adds exactly one opacity-0 draw (faded block_01) vs no-anim@t0; v4=\(drawOpacities(v4)) noAnim=\(drawOpacities(noAnim))")
        XCTAssertNotEqual(try v4.graphHash(), try noAnim.graphHash(), "v4@t0 must differ from no-anim@t0 after the fix")
    }

    // v1/v3 @tick0 are blank by POSITION (slide-in off-canvas) AND by opacity (held 0 at t0). After the fix
    // the opacity payload is also correct (an opacity-0 draw for the bound block), while position stays off.
    func testBlock01V1V3Tick0OpacityAlsoZero() throws {
        let noAnimZeros = zeroCount(try graph(block: "block_01", variant: "no-anim", tick: 0))
        for v in ["v1", "v3"] {
            let g = try graph(block: "block_01", variant: v, tick: 0)
            XCTAssertGreaterThan(zeroCount(g), noAnimZeros,
                                 "\(v)@t0 must add an opacity-0 draw (fade held 0) vs no-anim, got \(drawOpacities(g))")
        }
    }

    // (v4 keyframe interpolation over time is covered deterministically by the unit test
    // PrecompParentOpacityTests.testPrecompOpacityKeyframeInterpolatesAndChangesPayload; the real v4 layer is
    // timing-inactive past its authored window, so a real-template "recovery" tick is deterministically
    // skipped by the matrix and is not asserted here.)
}
