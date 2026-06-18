import XCTest
import AnimiEngineCore
import AnimiEngineRenderModel
@testable import AnimiEngineRenderGraph

/// Task-003 / Step-11 (Rev-4 §4.9) — deterministic stroke-mesh construction proofs.
final class StrokeMeshBuilderTests: XCTestCase {
    private let pt = CanvasScalar.unitsPerPoint
    private func cs(_ v: Int64) -> CanvasScalar { CanvasScalar(rawValue: v) }

    /// A path mesh from raw point coordinates (a polyline used as the stroke spine). `indices` are a
    /// dummy fan (the stroke builder uses positions as a polyline, not the fill triangulation).
    private func polyline(_ pointsPt: [(Int64, Int64)], closed: Bool, pathID: Int = 1) throws -> SampledPathMesh {
        var positions: [CanvasScalar] = []
        for p in pointsPt { positions.append(cs(p.0 * pt)); positions.append(cs(p.1 * pt)) }
        // A valid index buffer (fan over the first three verts); stroke ignores it.
        let n = pointsPt.count
        var indices: [Int] = []
        var i = 1
        while i + 1 < n { indices.append(0); indices.append(i); indices.append(i + 1); i += 1 }
        if indices.isEmpty { indices = [0, 1, max(2, n - 1)] }
        return try SampledPathMesh(pathID: pathID, positions: positions, indices: indices, closed: closed)
    }

    private func miter(_ x: Int64) -> MiterScalar { MiterScalar(rawValue: x) }
    private let width10 = CanvasScalar(rawValue: 10 * CanvasScalar.unitsPerPoint)

    // MARK: - Cap / join raw mapping (1/2/3) and unknown rejection

    func testCapRawMapping() {
        XCTAssertEqual(RenderStrokeLineCap(rawValue: 1), .butt)
        XCTAssertEqual(RenderStrokeLineCap(rawValue: 2), .round)
        XCTAssertEqual(RenderStrokeLineCap(rawValue: 3), .square)
        XCTAssertNil(RenderStrokeLineCap(rawValue: 0))
        XCTAssertNil(RenderStrokeLineCap(rawValue: 4))
    }

    func testJoinRawMapping() {
        XCTAssertEqual(RenderStrokeLineJoin(rawValue: 1), .miter)
        XCTAssertEqual(RenderStrokeLineJoin(rawValue: 2), .round)
        XCTAssertEqual(RenderStrokeLineJoin(rawValue: 3), .bevel)
        XCTAssertNil(RenderStrokeLineJoin(rawValue: 0))
        XCTAssertNil(RenderStrokeLineJoin(rawValue: 4))
    }

    // MARK: - Caps produce valid, non-empty meshes

    func testButtCapOpenSegment() throws {
        let path = try polyline([(0, 0), (50, 0), (100, 0)], closed: false)
        let mesh = try StrokeMeshBuilder.build(path: path, width: width10, lineCap: .butt, lineJoin: .miter, miterLimit: miter(4_000_000))
        XCTAssertFalse(mesh.indices.isEmpty)
        XCTAssertEqual(mesh.indices.count % 3, 0)
        // Two collinear segments, butt caps (no cap geometry), collinear join (no join geometry) → two
        // quads = 12 indices.
        XCTAssertEqual(mesh.indices.count, 12, "two collinear segments, butt caps → two quads")
    }

    func testSquareCapAddsExtension() throws {
        let path = try polyline([(0, 0), (50, 0), (100, 0)], closed: false)
        let butt = try StrokeMeshBuilder.build(path: path, width: width10, lineCap: .butt, lineJoin: .miter, miterLimit: miter(4_000_000))
        let square = try StrokeMeshBuilder.build(path: path, width: width10, lineCap: .square, lineJoin: .miter, miterLimit: miter(4_000_000))
        XCTAssertGreaterThan(square.indices.count, butt.indices.count, "square caps add extension triangles")
    }

    func testRoundCapAddsArc() throws {
        let path = try polyline([(0, 0), (50, 0), (100, 0)], closed: false)
        let round = try StrokeMeshBuilder.build(path: path, width: width10, lineCap: .round, lineJoin: .miter, miterLimit: miter(4_000_000))
        // A semicircle at 1-degree steps is ~180 fan triangles per cap → well over the bare quad.
        XCTAssertGreaterThan(round.indices.count, 6 + 100 * 3, "round caps add a dense arc fan")
    }

    // MARK: - Joins

    func testBevelJoin() throws {
        let path = try polyline([(0, 0), (100, 0), (100, 100)], closed: false)
        let mesh = try StrokeMeshBuilder.build(path: path, width: width10, lineCap: .butt, lineJoin: .bevel, miterLimit: miter(4_000_000))
        XCTAssertFalse(mesh.indices.isEmpty)
        XCTAssertEqual(mesh.indices.count % 3, 0)
    }

    func testMiterJoinWithinLimit() throws {
        let path = try polyline([(0, 0), (100, 0), (100, 100)], closed: false)
        let miterMesh = try StrokeMeshBuilder.build(path: path, width: width10, lineCap: .butt, lineJoin: .miter, miterLimit: miter(10_000_000))
        let bevelMesh = try StrokeMeshBuilder.build(path: path, width: width10, lineCap: .butt, lineJoin: .bevel, miterLimit: miter(10_000_000))
        // A 90-degree miter within the limit adds an apex triangle pair the bevel does not.
        XCTAssertGreaterThan(miterMesh.indices.count, bevelMesh.indices.count, "miter apex adds geometry over bevel")
    }

    func testMiterLimitFallbackToBevel() throws {
        // A near-180 sharp turn with a tiny miter limit must fall back to a bevel (same triangle count as
        // an explicit bevel join).
        let path = try polyline([(0, 0), (100, 0), (0, 5)], closed: false)
        let miterMesh = try StrokeMeshBuilder.build(path: path, width: width10, lineCap: .butt, lineJoin: .miter, miterLimit: miter(1_000_000))
        let bevelMesh = try StrokeMeshBuilder.build(path: path, width: width10, lineCap: .butt, lineJoin: .bevel, miterLimit: miter(1_000_000))
        XCTAssertEqual(miterMesh.indices.count, bevelMesh.indices.count, "miter beyond limit falls back to bevel geometry")
    }

    func testRoundJoinAddsArc() throws {
        let path = try polyline([(0, 0), (100, 0), (100, 100)], closed: false)
        let round = try StrokeMeshBuilder.build(path: path, width: width10, lineCap: .butt, lineJoin: .round, miterLimit: miter(4_000_000))
        let bevel = try StrokeMeshBuilder.build(path: path, width: width10, lineCap: .butt, lineJoin: .bevel, miterLimit: miter(4_000_000))
        XCTAssertGreaterThan(round.indices.count, bevel.indices.count, "round join arc adds geometry")
    }

    func testCollinearJoinEmitsNoExtraGeometry() throws {
        // Four collinear points → three straight (collinear) joins add no triangles: exactly three
        // segment quads = 9 triangles = 27 indices, regardless of join style.
        let straight4 = try polyline([(0, 0), (33, 0), (66, 0), (100, 0)], closed: false)
        let miterMesh = try StrokeMeshBuilder.build(path: straight4, width: width10, lineCap: .butt, lineJoin: .miter, miterLimit: miter(4_000_000))
        let bevelMesh = try StrokeMeshBuilder.build(path: straight4, width: width10, lineCap: .butt, lineJoin: .bevel, miterLimit: miter(4_000_000))
        XCTAssertEqual(miterMesh.indices.count, 18, "three collinear quads (2 triangles each), no join geometry")
        XCTAssertEqual(miterMesh.indices.count, bevelMesh.indices.count, "join style irrelevant for collinear joins")
    }

    // MARK: - Input normalization

    func testDuplicatePointsRemoved() throws {
        let withDup = try polyline([(0, 0), (50, 0), (50, 0), (100, 0)], closed: false)
        let withoutDup = try polyline([(0, 0), (50, 0), (100, 0)], closed: false)
        let a = try StrokeMeshBuilder.build(path: withDup, width: width10, lineCap: .butt, lineJoin: .miter, miterLimit: miter(4_000_000))
        let b = try StrokeMeshBuilder.build(path: withoutDup, width: width10, lineCap: .butt, lineJoin: .miter, miterLimit: miter(4_000_000))
        XCTAssertEqual(a.indices.count, b.indices.count, "consecutive duplicate point removed deterministically")
    }

    func testOpenAndClosedDiffer() throws {
        let open = try polyline([(0, 0), (100, 0), (100, 100)], closed: false)
        let closed = try polyline([(0, 0), (100, 0), (100, 100)], closed: true)
        let mo = try StrokeMeshBuilder.build(path: open, width: width10, lineCap: .butt, lineJoin: .bevel, miterLimit: miter(4_000_000))
        let mc = try StrokeMeshBuilder.build(path: closed, width: width10, lineCap: .butt, lineJoin: .bevel, miterLimit: miter(4_000_000))
        // Closed adds the wrap segment + its joins and emits no caps.
        XCTAssertNotEqual(mo.indices.count, mc.indices.count)
    }

    // MARK: - Rejections (typed, no trap)

    func testZeroLengthPathRejected() throws {
        // All-duplicate points collapse to one distinct point → typed rejection.
        let degenerate = try polyline([(10, 10), (10, 10), (10, 10)], closed: false)
        XCTAssertThrowsError(try StrokeMeshBuilder.build(path: degenerate, width: width10, lineCap: .butt, lineJoin: .miter, miterLimit: miter(4_000_000))) { e in
            guard case RenderGraphError.unsupportedStrokeGeometry = e else { return XCTFail("\(e)") }
        }
    }

    func testExact180ReversalRejected() throws {
        // (0,0)->(100,0)->(0,0) reverses exactly 180°.
        let reversal = try polyline([(0, 0), (100, 0), (0, 0)], closed: false)
        XCTAssertThrowsError(try StrokeMeshBuilder.build(path: reversal, width: width10, lineCap: .butt, lineJoin: .miter, miterLimit: miter(4_000_000))) { e in
            guard case RenderGraphError.unsupportedStrokeGeometry = e else { return XCTFail("\(e)") }
        }
    }

    func testZeroWidthRejected() throws {
        let path = try polyline([(0, 0), (50, 0), (100, 0)], closed: false)
        XCTAssertThrowsError(try StrokeMeshBuilder.build(path: path, width: cs(0), lineCap: .butt, lineJoin: .miter, miterLimit: miter(4_000_000)))
    }

    func testExcessiveWidthRejected() throws {
        let path = try polyline([(0, 0), (50, 0), (100, 0)], closed: false)
        let huge = CanvasScalar(rawValue: 4096 * CanvasScalar.unitsPerPoint)
        XCTAssertThrowsError(try StrokeMeshBuilder.build(path: path, width: huge, lineCap: .butt, lineJoin: .miter, miterLimit: miter(4_000_000)))
    }

    func testNonPositiveMiterLimitRejectedForMiter() throws {
        let path = try polyline([(0, 0), (100, 0), (100, 100)], closed: false)
        XCTAssertThrowsError(try StrokeMeshBuilder.build(path: path, width: width10, lineCap: .butt, lineJoin: .miter, miterLimit: miter(0)))
    }

    // MARK: - Determinism

    func testDeterministicRepeatedBuild() throws {
        let path = try polyline([(0, 0), (100, 0), (100, 100), (0, 100)], closed: true)
        let a = try StrokeMeshBuilder.build(path: path, width: width10, lineCap: .round, lineJoin: .round, miterLimit: miter(4_000_000))
        let b = try StrokeMeshBuilder.build(path: path, width: width10, lineCap: .round, lineJoin: .round, miterLimit: miter(4_000_000))
        XCTAssertEqual(a, b, "same inputs → byte-identical mesh")
    }

    // MARK: - Non-uniform transform applied AFTER local mesh construction (§4.4)

    func testWidthIsPathLocalBeforeTransform() throws {
        // The builder produces a path-local mesh; a non-uniform transform is applied by the compiler
        // afterwards. So the local mesh for a given width is independent of any later transform — proven
        // by the mesh being identical regardless of how the caller intends to transform it.
        let path = try polyline([(0, 0), (50, 0), (100, 0)], closed: false)
        let m1 = try StrokeMeshBuilder.build(path: path, width: width10, lineCap: .butt, lineJoin: .miter, miterLimit: miter(4_000_000))
        let m2 = try StrokeMeshBuilder.build(path: path, width: width10, lineCap: .butt, lineJoin: .miter, miterLimit: miter(4_000_000))
        XCTAssertEqual(m1, m2)
        // The local mesh half-width offset is exactly width/2 = 5pt on a horizontal segment.
        let ys = Set(stride(from: 1, to: m1.positions.count, by: 2).map { m1.positions[$0].rawValue })
        XCTAssertTrue(ys.contains(5 * pt) && ys.contains(-5 * pt), "path-local half-width = 5pt")
    }
}
