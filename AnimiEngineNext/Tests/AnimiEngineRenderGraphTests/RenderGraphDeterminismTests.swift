import XCTest
import AnimiEngineCore
import AnimiEngineRenderModel

/// Task-003 plan §7, §7.1, §7.4, D3-11, §13 row "Graph determinism" — the RenderGraph value model's
/// pinned invariants, including the completion invariants (item 9) and configuration-embedded hash
/// (item 5).
final class RenderGraphDeterminismTests: XCTestCase {

    private func configuration(
        width: Int64 = 1080, height: Int64 = 1920, fps: Int64 = 30,
        profile: IntermediateProfile = .rgba16FloatLinear
    ) throws -> RenderConfiguration {
        let canvas = try CanvasSize(width: width, height: height)
        let output = OutputContext(canvas: canvas, frameRate: try FrameRate(numerator: fps, denominator: 1))
        return try RenderConfiguration(output: output, intermediateProfile: profile)
    }

    private func commands(_ categories: [RenderCommandCategory]) throws -> [RenderCommand] {
        try categories.enumerated().map { try RenderCommand(ordinal: $0.offset, payload: GraphTestPayloads.minimal($0.element)) }
    }

    private func minimalGraph(fps: Int64 = 30) throws -> RenderGraph {
        try RenderGraph(configuration: try configuration(fps: fps),
                        commands: try commands([.clearBackground, .drawImage, .finalLinearToSRGB, .finalOutput]))
    }

    func testValueIdenticalInputsProduceValueIdenticalGraphAndHash() throws {
        let a = try minimalGraph()
        let b = try minimalGraph()
        XCTAssertEqual(a, b, "value-identical inputs must produce value-identical graphs (D3-11)")
        XCTAssertEqual(try a.graphHash(), try b.graphHash(), "graph hash must be stable for identical inputs")
        XCTAssertFalse(try a.graphHash().isEmpty)
    }

    func testDifferentCommandsProduceDifferentHash() throws {
        let a = try minimalGraph()
        let b = try RenderGraph(
            configuration: try configuration(),
            commands: try commands([.clearBackground, .drawImage, .overlay, .finalLinearToSRGB, .finalOutput]))
        XCTAssertNotEqual(try a.graphHash(), try b.graphHash())
    }

    func testCommandOrderIsSemanticInHash() throws {
        let a = try RenderGraph(configuration: try configuration(),
                                commands: try commands([.clearBackground, .drawImage, .finalLinearToSRGB, .finalOutput]))
        let b = try RenderGraph(configuration: try configuration(),
                                commands: try commands([.drawImage, .clearBackground, .finalLinearToSRGB, .finalOutput]))
        XCTAssertNotEqual(try a.graphHash(), try b.graphHash())
    }

    /// Item 5: otherwise-identical 30-fps and 60-fps graphs must hash differently because the graph
    /// embeds the complete canonical configuration (which carries the frame rate).
    func testThirtyAndSixtyFpsGraphsHashDifferently() throws {
        let thirty = try minimalGraph(fps: 30)
        let sixty = try minimalGraph(fps: 60)
        XCTAssertNotEqual(thirty, sixty)
        XCTAssertNotEqual(try thirty.graphHash(), try sixty.graphHash(),
                          "fps must participate in the graph hash via the embedded configuration")
    }

    func testIntermediateProfileParticipatesInGraphHash() throws {
        let ref = try RenderGraph(configuration: try configuration(profile: .rgba16FloatLinear),
                                  commands: try commands([.clearBackground, .finalLinearToSRGB, .finalOutput]))
        let srgb = try RenderGraph(configuration: try configuration(profile: .bgra8SRGB),
                                   commands: try commands([.clearBackground, .finalLinearToSRGB, .finalOutput]))
        XCTAssertNotEqual(try ref.graphHash(), try srgb.graphHash())
    }

    // MARK: - Completion invariants (item 9)

    func testNonContiguousOrdinalsRejected() throws {
        let bad = [try RenderCommand(ordinal: 0, payload: GraphTestPayloads.minimal(.clearBackground)),
                   try RenderCommand(ordinal: 1, payload: GraphTestPayloads.minimal(.finalLinearToSRGB)),
                   try RenderCommand(ordinal: 5, payload: GraphTestPayloads.minimal(.finalOutput))]   // gap
        XCTAssertThrowsError(try RenderGraph(configuration: try configuration(), commands: bad))
    }

    func testMissingFinalOutputRejected() throws {
        let bad = try commands([.clearBackground, .finalLinearToSRGB])   // no finalOutput
        XCTAssertThrowsError(try RenderGraph(configuration: try configuration(), commands: bad)) { error in
            guard case let RenderModelError.unsupportedValue(field, _)? = error as? RenderModelError else {
                return XCTFail("got \(error)")
            }
            XCTAssertEqual(field, "RenderGraph.finalOutputCount")
        }
    }

    func testTwoFinalOutputsRejected() throws {
        let bad = try commands([.clearBackground, .finalLinearToSRGB, .finalOutput, .finalOutput])
        XCTAssertThrowsError(try RenderGraph(configuration: try configuration(), commands: bad)) { error in
            guard case let RenderModelError.unsupportedValue(field, _)? = error as? RenderModelError else {
                return XCTFail("got \(error)")
            }
            // finalOutput is not last → finalCommand fires first; count==2 also invalid. Either is a
            // valid rejection point; assert it is one of the completion fields.
            XCTAssertTrue(["RenderGraph.finalOutputCount", "RenderGraph.finalCommand"].contains(field), field)
        }
    }

    func testFinalLinearToSRGBMustImmediatelyPrecedeFinalOutput() throws {
        // sRGB present but not immediately before output.
        let bad = try commands([.finalLinearToSRGB, .clearBackground, .finalOutput])
        XCTAssertThrowsError(try RenderGraph(configuration: try configuration(), commands: bad)) { error in
            guard case let RenderModelError.unsupportedValue(field, _)? = error as? RenderModelError else {
                return XCTFail("got \(error)")
            }
            XCTAssertEqual(field, "RenderGraph.finalLinearToSRGBPosition")
        }
    }

    func testMissingFinalLinearToSRGBRejected() throws {
        let bad = try commands([.clearBackground, .finalOutput])   // no sRGB conversion
        XCTAssertThrowsError(try RenderGraph(configuration: try configuration(), commands: bad)) { error in
            guard case let RenderModelError.unsupportedValue(field, _)? = error as? RenderModelError else {
                return XCTFail("got \(error)")
            }
            XCTAssertEqual(field, "RenderGraph.finalLinearToSRGBCount")
        }
    }

    func testTwoFinalLinearToSRGBRejected() throws {
        let bad = try commands([.finalLinearToSRGB, .finalLinearToSRGB, .finalOutput])
        XCTAssertThrowsError(try RenderGraph(configuration: try configuration(), commands: bad)) { error in
            guard case let RenderModelError.unsupportedValue(field, _)? = error as? RenderModelError else {
                return XCTFail("got \(error)")
            }
            XCTAssertEqual(field, "RenderGraph.finalLinearToSRGBCount")
        }
    }

    func testEmptyGraphRejected() throws {
        XCTAssertThrowsError(try RenderGraph(configuration: try configuration(), commands: []))
    }

    func testConfigurationRejectsNonPositiveFramesInFlight() throws {
        let canvas = try CanvasSize(width: 1080, height: 1920)
        let output = OutputContext(canvas: canvas, frameRate: try FrameRate(numerator: 30, denominator: 1))
        XCTAssertThrowsError(
            try RenderConfiguration(output: output, intermediateProfile: .bgra8SRGB, framesInFlight: 0))
    }
}
