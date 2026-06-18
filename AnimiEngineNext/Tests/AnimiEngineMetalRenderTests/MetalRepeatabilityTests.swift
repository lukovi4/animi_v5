import XCTest
import AnimiEngineCore
import AnimiEngineRenderModel
import AnimiEngineRenderGraph
import AnimiEngineMetalRender

/// Task-003 plan §13 (#21, #23) — same-device exact byte + `rawOutputHash` repeatability.
///
/// On a fixed device/build/OS/config, repeated execution of the same graph (including the rotated bilinear
/// case, whose correctness is asserted only as bounded invariants elsewhere) reproduces identical bytes
/// and identical `rawOutputHash` (plan §D3-11, §7.8). Also proves repeated execution without stale
/// per-execution resources.
final class MetalRepeatabilityTests: XCTestCase {

    private func opaqueImage(_ id: String) throws -> ResolvedPixelInput {
        var cells: [(b: UInt8, g: UInt8, r: UInt8, a: UInt8)] = []
        for i in 0..<16 {
            cells.append((b: UInt8((i * 13) % 256), g: UInt8((i * 7) % 256), r: UInt8((i * 31) % 256), a: 255))
        }
        return try MetalTestEnvironment.makePixelInput(id: id, width: 4, height: 4, straightBGRA: cells)
    }

    func testExactByteAndHashRepeatability() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let session = try MetalRenderSession(device: device)
        let pixels = try opaqueImage("repeat")
        // A rotated transform (fractional bilinear): repeatability must still be exact on the same device.
        let rot = try FixedAffineTransform2D.rotation(degreesTimesUnitsPerDegree: 17_000)  // 17°
        let graph = try MetalTestEnvironment.singleImageGraph(
            width: 4, height: 4, profile: .rgba16FloatLinear, pixels: pixels, transform: rot)

        let a = try session.execute(graph)
        let b = try session.execute(graph)
        let c = try session.execute(graph)
        XCTAssertEqual(a.bytes, b.bytes, "byte repeatability (a vs b)")
        XCTAssertEqual(b.bytes, c.bytes, "byte repeatability (b vs c)")
        XCTAssertEqual(a.rawOutputHash, b.rawOutputHash, "hash repeatability (a vs b)")
        XCTAssertEqual(b.rawOutputHash, c.rawOutputHash, "hash repeatability (b vs c)")
    }

    func testRepeatedExecutionNoStaleResources() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let session = try MetalRenderSession(device: device)
        // Interleave different graphs; each must produce its own correct, independent frame.
        let img = try opaqueImage("stale")
        let drawGraph = try MetalTestEnvironment.singleImageGraph(
            width: 4, height: 4, profile: .bgra8SRGB, pixels: img)
        let clearGraph = try MetalTestEnvironment.clearOnlyGraph(width: 4, height: 4, profile: .bgra8SRGB)

        let d1 = try session.execute(drawGraph)
        let c1 = try session.execute(clearGraph)
        let d2 = try session.execute(drawGraph)
        let c2 = try session.execute(clearGraph)

        // The clear results must be fully transparent (no stale draw pixels leaking in).
        for y in 0..<4 { for x in 0..<4 {
            let p = MetalTestEnvironment.pixel(c1, x: x, y: y)
            XCTAssertEqual(p.a, 0, "clear c1 (\(x),\(y)) not transparent")
        }}
        XCTAssertEqual(c1.bytes, c2.bytes, "clear repeatable")
        XCTAssertEqual(d1.bytes, d2.bytes, "draw repeatable")
    }

    func testNoWallClockPerformanceAssertions() {
        // Negative requirement (#24): this suite asserts no timing. Documented, not measured.
        XCTAssertTrue(true)
    }
}
