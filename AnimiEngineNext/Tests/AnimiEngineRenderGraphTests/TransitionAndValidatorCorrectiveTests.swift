import XCTest
import Foundation
import AnimiEngineCore
import AnimiEngineRenderModel
@testable import AnimiEngineRenderGraph

/// Task-003 §7.3/§7.4 corrective — transition surface flow (#11: scenes write the exact surfaces the
/// transition consumes), independent validator rejections (#10), and profile mismatch actually
/// throwing (#11).
final class TransitionAndValidatorCorrectiveTests: XCTestCase {

    typealias F = GraphTestFixtures
    private let pt = CanvasScalar.unitsPerPoint
    private func cs(_ v: Int64) -> CanvasScalar { CanvasScalar(rawValue: v) }

    private func sub(_ s: String, role: SceneRole, layer l: String, ref: String) throws -> SceneSubplan {
        SceneSubplan(sceneID: try SceneInstanceID(s), role: role, scenePlaybackTime: .zero, transitionRelativeTime: nil,
            layers: [ActiveLayer(layerID: try LayerID(l), zIndex: 0, stableOrdinal: 0, localCompositionOrder: 0,
                placement: try Placement(frame: try FixedRect(x: cs(0), y: cs(0), width: cs(100 * pt), height: cs(100 * pt)), scale: .one, rotation: .zero),
                mediaPlacement: .identity(fitMode: .contain), content: .image(try ImageReference(ref)),
                animationReference: nil, animationRequest: .holdLast)])
    }

    private func transitionPlan(effect: String, easing: String = "linear", params: TransitionParameterSet = .empty, num: Int64 = 1, den: Int64 = 2) throws -> FramePlan {
        let tp = TransitionPlan(effectID: try TransitionEffectID(effect), parameters: params, easing: try EasingReference(easing),
            progressNumerator: num, progressDenominator: den,
            outgoing: try sub("sOut", role: .outgoing, layer: "lo", ref: "refO"),
            incoming: try sub("sIn", role: .incoming, layer: "li", ref: "refI"))
        return FramePlan(output: OutputContext(canvas: try CanvasSize(width: 1080, height: 1920), frameRate: try FrameRate(numerator: 30, denominator: 1)),
            projectTime: try ProjectTime(ticks: 0), body: .transition(tp), overlays: [])
    }

    private func transitionInput() throws -> ResolvedFrameInput {
        let e1 = try ResolvedSceneLayerEntry(key: .sceneLayer(sceneID: try SceneInstanceID("sOut"), role: .outgoing, layerID: try LayerID("lo")),
            program: try F.program(block: "o"), pixelInput: try F.pixels("pO"), placement: ResolvedMediaPlacement(fitMode: .contain, transform: .identity, clip: .none))
        let e2 = try ResolvedSceneLayerEntry(key: .sceneLayer(sceneID: try SceneInstanceID("sIn"), role: .incoming, layerID: try LayerID("li")),
            program: try F.program(block: "i"), pixelInput: try F.pixels("pI"), placement: ResolvedMediaPlacement(fitMode: .contain, transform: .identity, clip: .none))
        return try ResolvedFrameInput(sceneLayers: [e1, e2], overlays: [])
    }

    // MARK: - Transition writes exact surfaces consumed (#11)

    func testFadeScenesWriteExactSurfacesConsumed() throws {
        let plan = try transitionPlan(effect: "fade", easing: "easeInOut")
        let graph = try RenderGraphCompiler.compile(plan: plan, input: try transitionInput(), configuration: try F.config())
        // Find the fade command's consumed surfaces.
        let fade = try XCTUnwrap(graph.commands.compactMap { c -> (String, String)? in
            if case let .fadeTransition(_, out, inc, _) = c.payload { return (out, inc) }; return nil }.first)
        // Each scene must have written its surface (a beginScene targeting exactly that surface).
        func sceneWrote(_ surface: String) -> Bool {
            graph.commands.contains { if case let .beginScene(_, _, target) = $0.payload { return target == surface }; return false } }
        XCTAssertTrue(sceneWrote(fade.0), "outgoing scene writes the surface the fade consumes")
        XCTAssertTrue(sceneWrote(fade.1), "incoming scene writes the surface the fade consumes")
        XCTAssertNoThrow(try RenderGraphValidator.validate(graph, configuration: try F.config()))
    }

    func testSlideEveryDirectionWritesSurfaces() throws {
        for dir in ["left", "right", "up", "down"] {
            let params = try TransitionParameterSet([TransitionParameter(key: "direction", value: .identifier(dir))])
            let plan = try transitionPlan(effect: "slide", params: params, num: 1, den: 4)
            let graph = try RenderGraphCompiler.compile(plan: plan, input: try transitionInput(), configuration: try F.config())
            let slide = try XCTUnwrap(graph.commands.first { $0.category == .slideTransition })
            guard case let .slideTransition(direction, _, _, _, out, inc, _) = slide.payload else { return XCTFail() }
            XCTAssertEqual(direction.rawValue, dir)
            func sceneWrote(_ s: String) -> Bool { graph.commands.contains { if case let .beginScene(_, _, t) = $0.payload { return t == s }; return false } }
            XCTAssertTrue(sceneWrote(out)); XCTAssertTrue(sceneWrote(inc))
            XCTAssertNoThrow(try RenderGraphValidator.validate(graph, configuration: try F.config()))
        }
    }

    func testOutgoingSceneContinuesRendering() throws {
        let plan = try transitionPlan(effect: "fade")
        let graph = try RenderGraphCompiler.compile(plan: plan, input: try transitionInput(), configuration: try F.config())
        let draws = graph.commands.compactMap { c -> String? in if case let .drawImage(rid, _, _, _) = c.payload { return rid }; return nil }
        XCTAssertTrue(draws.contains("pO"), "outgoing scene continues rendering through the window")
        XCTAssertTrue(draws.contains("pI"))
    }

    func testSlideMissingDirectionRejected() throws {
        let plan = try transitionPlan(effect: "slide", params: .empty)
        XCTAssertThrowsError(try RenderGraphCompiler.compile(plan: plan, input: try transitionInput(), configuration: try F.config())) { error in
            guard case RenderGraphError.unsupportedSlideDirection? = error as? RenderGraphError else { return XCTFail("\(error)") }
        }
    }

    func testUnsupportedEffectRejected() throws {
        let plan = try transitionPlan(effect: "wipe")
        XCTAssertThrowsError(try RenderGraphCompiler.compile(plan: plan, input: try transitionInput(), configuration: try F.config())) { error in
            guard case RenderGraphError.unsupportedTransitionEffect? = error as? RenderGraphError else { return XCTFail("\(error)") }
        }
    }

    // MARK: - Independent validator rejections (#10)

    private func validGraph() throws -> RenderGraph {
        let p = try F.program(block: "a")
        let plan = try F.singlePlan(scene: "s", layers: [try F.imageActiveLayer("a", ref: "img", order: 0)])
        let inp = try F.singleInput(scene: "s", [("a", p, "px0")])
        return try RenderGraphCompiler.compile(plan: plan, input: inp, configuration: try F.config())
    }

    private func rebuilt(_ commands: [RenderCommandPayload], config: RenderConfiguration) throws -> RenderGraph {
        try RenderGraph(configuration: config, commands: try commands.enumerated().map { try RenderCommand(ordinal: $0.offset, payload: $0.element) })
    }

    func testValidatorRejectsReadBeforeWrite() throws {
        // finalOutput reads sRGB, but no finalLinearToSRGB wrote it.
        let p: [RenderCommandPayload] = [
            .clearBackground(color: .transparentBlack, targetSurfaceID: RenderSurface.linearCanvas),
            .offscreenSurface(RenderResourceDescriptor(offscreenID: RenderSurface.linearCanvas, width: 1, height: 1, profile: RenderSurface.linearCanvas == RenderSurface.sRGBSurface ? .finalSRGB : .intermediate(.rgba16FloatLinear), colorContract: .task003)),
            .offscreenSurface(RenderResourceDescriptor(offscreenID: RenderSurface.sRGBSurface, width: 1, height: 1, profile: RenderSurface.sRGBSurface == RenderSurface.sRGBSurface ? .finalSRGB : .intermediate(.rgba16FloatLinear), colorContract: .task003)),
            .finalLinearToSRGB(sourceSurfaceID: RenderSurface.sRGBSurface, targetSurfaceID: RenderSurface.sRGBSurface),   // reads sRGB before written
            .finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface)
        ]
        // finalLinearToSRGB must read linearCanvas → caught by final-chain check first; assert it throws.
        XCTAssertThrowsError(try RenderGraphValidator.validate(try rebuilt(p, config: try F.config()), configuration: try F.config()))
    }

    func testValidatorRejectsConfigurationMismatch() throws {
        let g = try validGraph()
        // A configuration differing in fps must be rejected (full config equality, corrective #10).
        let other = try RenderConfiguration(
            output: OutputContext(canvas: try CanvasSize(width: 1080, height: 1920), frameRate: try FrameRate(numerator: 60, denominator: 1)),
            intermediateProfile: .rgba16FloatLinear)
        XCTAssertThrowsError(try RenderGraphValidator.validate(g, configuration: other)) { error in
            guard case RenderGraphError.validatorColorProfileMismatch? = error as? RenderGraphError else { return XCTFail("\(error)") }
        }
    }

    func testValidatorRejectsIntermediateProfileMismatch() throws {
        // Graph built with rgba16FloatLinear; validate against a bgra8SRGB-profile config → mismatch.
        let g = try validGraph()
        let other = try RenderConfiguration(
            output: OutputContext(canvas: try CanvasSize(width: 1080, height: 1920), frameRate: try FrameRate(numerator: 30, denominator: 1)),
            intermediateProfile: .bgra8SRGB)
        XCTAssertThrowsError(try RenderGraphValidator.validate(g, configuration: other)) { error in
            guard case RenderGraphError.validatorColorProfileMismatch? = error as? RenderGraphError else { return XCTFail("\(error)") }
        }
    }

    private func lin() -> RenderCommandPayload {
        .offscreenSurface(RenderResourceDescriptor(offscreenID: RenderSurface.linearCanvas, width: 1, height: 1, profile: .intermediate(.rgba16FloatLinear), colorContract: .task003))
    }
    private func srgb() -> RenderCommandPayload {
        .offscreenSurface(RenderResourceDescriptor(offscreenID: RenderSurface.sRGBSurface, width: 1, height: 1, profile: .finalSRGB, colorContract: .task003))
    }

    func testValidatorRejectsDrawOutsideScene() throws {
        // Declarations first (corrective #5), then a draw outside any scene scope → rejected.
        let p: [RenderCommandPayload] = [
            lin(), srgb(),
            .declareResource(RenderResourceDescriptor(pixelInputID: "r", pixels: try F.pixels("r", 1, 1), colorContract: .task003)),
            .clearBackground(color: .transparentBlack, targetSurfaceID: RenderSurface.linearCanvas),
            .drawImage(resourceID: "r", transform: .identity, opacity: .opaque, targetSurfaceID: RenderSurface.linearCanvas),
            .finalLinearToSRGB(sourceSurfaceID: RenderSurface.linearCanvas, targetSurfaceID: RenderSurface.sRGBSurface),
            .finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface)
        ]
        XCTAssertThrowsError(try RenderGraphValidator.validate(try rebuilt(p, config: try F.config()), configuration: try F.config())) { error in
            guard case RenderGraphError.validatorInvalidCommandOrder? = error as? RenderGraphError else { return XCTFail("\(error)") }
        }
    }

    func testValidatorRejectsOffscreenUsedAsPixelReference() throws {
        let p: [RenderCommandPayload] = [
            lin(), srgb(),
            .clearBackground(color: .transparentBlack, targetSurfaceID: RenderSurface.linearCanvas),
            .beginScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas),
            .drawImage(resourceID: RenderSurface.linearCanvas, transform: .identity, opacity: .opaque, targetSurfaceID: RenderSurface.linearCanvas),   // draws an offscreen as pixels
            .endScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas),
            .finalLinearToSRGB(sourceSurfaceID: RenderSurface.linearCanvas, targetSurfaceID: RenderSurface.sRGBSurface),
            .finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface)
        ]
        XCTAssertThrowsError(try RenderGraphValidator.validate(try rebuilt(p, config: try F.config()), configuration: try F.config())) { error in
            guard case RenderGraphError.validatorUnsupportedMode? = error as? RenderGraphError else { return XCTFail("\(error)") }
        }
    }

    func testValidatorRejectsDeclarationAfterUse() throws {
        // A pixel used by a draw is declared AFTER the draw → declaration-after-use rejection (#9).
        let p: [RenderCommandPayload] = [
            lin(), srgb(),
            .clearBackground(color: .transparentBlack, targetSurfaceID: RenderSurface.linearCanvas),
            .beginScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas),
            .drawImage(resourceID: "late", transform: .identity, opacity: .opaque, targetSurfaceID: RenderSurface.linearCanvas),
            .endScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas),
            .declareResource(RenderResourceDescriptor(pixelInputID: "late", pixels: try F.pixels("late", 1, 1), colorContract: .task003)),
            .finalLinearToSRGB(sourceSurfaceID: RenderSurface.linearCanvas, targetSurfaceID: RenderSurface.sRGBSurface),
            .finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface)
        ]
        XCTAssertThrowsError(try RenderGraphValidator.validate(try rebuilt(p, config: try F.config()), configuration: try F.config())) { error in
            guard case RenderGraphError.validatorMissingResource? = error as? RenderGraphError else { return XCTFail("\(error)") }
        }
    }

    // MARK: - Step 12 (S-1) — a cut (.single body) emits NO transition command

    func testCutSingleBodyEmitsNoTransitionCommand() throws {
        let p = try F.program(block: "a")
        let plan = try F.singlePlan(scene: "s", layers: [try F.imageActiveLayer("a", ref: "img", order: 0)])
        let inp = try F.singleInput(scene: "s", [("a", p, "px0")])
        let graph = try RenderGraphCompiler.compile(plan: plan, input: inp, configuration: try F.config())
        XCTAssertFalse(graph.commands.contains { $0.category == .fadeTransition || $0.category == .slideTransition },
                       "a single-scene cut emits no fade/slide transition command")
        let soleTargets = graph.commands.compactMap { c -> String? in
            if case let .beginScene(_, role, target) = c.payload, role == .sole { return target }; return nil }
        XCTAssertEqual(soleTargets, [RenderSurface.linearCanvas], "cut scene targets the linear canvas directly")
    }
}
