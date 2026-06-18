import XCTest
import AnimiEngineCore
import AnimiEngineRenderModel
@testable import AnimiEngineRenderGraph

/// Task-003 / Step-11 (Rev-4 §3.4) — exact producer-mesh sampling proofs.
final class PathResourceSamplerTests: XCTestCase {
    private let pt = CanvasScalar.unitsPerPoint
    private func cs(_ v: Int64) -> CanvasScalar { CanvasScalar(rawValue: v) }
    private func t(_ n: Int64) throws -> RationalSourceTime { try RationalSourceTime(numerator: n, denominator: 1) }

    /// A two-keyframe animated triangle: at frame 0 the row is `a`, at frame 10 the row is `b`. Linear
    /// (no hold, no easing handles) so the midpoint is the exact average.
    private func twoKeyframeResource(a: [Int64], b: [Int64], hold: Bool = false) throws -> RenderPathResource {
        let easing = RenderPathEasing(outX: EasingScalar(rawValue: 0), outY: EasingScalar(rawValue: 0),
                                      inX: EasingScalar(rawValue: EasingScalar.unitsPerUnit), inY: EasingScalar(rawValue: EasingScalar.unitsPerUnit),
                                      hold: hold)
        return try RenderPathResource(
            pathID: 5, vertexCount: 3, indices: [0, 1, 2],
            keyframeTimes: [try t(0), try t(10)],
            keyframePositions: [a.map { cs($0) }, b.map { cs($0) }],
            keyframeEasing: [easing])
    }

    func testStaticPathReturnsSingleRowVerbatim() throws {
        let r = try RenderPathResource(
            pathID: 5, vertexCount: 3, indices: [0, 1, 2],
            keyframeTimes: [try t(0)],
            keyframePositions: [[cs(1), cs(2), cs(3), cs(4), cs(5), cs(6)]], keyframeEasing: [])
        let mesh = try PathResourceSampler.sample(resource: r, closed: true, at: try t(99), field: "s")
        XCTAssertEqual(mesh.positions.map { $0.rawValue }, [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(mesh.indices, [0, 1, 2])
        XCTAssertEqual(mesh.positions.count, 6, "positions.count == vertexCount*2")
    }

    func testFirstAndLastKeyframesExact() throws {
        let a: [Int64] = [0, 0, 100, 0, 100, 100]
        let b: [Int64] = [0, 0, 200, 0, 200, 200]
        let r = try twoKeyframeResource(a: a, b: b)
        // Before/at first keyframe → first row; at/after last → last row.
        XCTAssertEqual(try PathResourceSampler.sample(resource: r, closed: true, at: try t(-5), field: "f").positions.map { $0.rawValue }, a)
        XCTAssertEqual(try PathResourceSampler.sample(resource: r, closed: true, at: try t(0), field: "f").positions.map { $0.rawValue }, a)
        XCTAssertEqual(try PathResourceSampler.sample(resource: r, closed: true, at: try t(10), field: "f").positions.map { $0.rawValue }, b)
        XCTAssertEqual(try PathResourceSampler.sample(resource: r, closed: true, at: try t(99), field: "f").positions.map { $0.rawValue }, b)
    }

    func testMidpointInterpolationExact() throws {
        let a: [Int64] = [0, 0, 100, 0, 100, 100]
        let b: [Int64] = [0, 0, 200, 0, 200, 200]
        let r = try twoKeyframeResource(a: a, b: b)
        // Linear easing at frame 5 (halfway) → exact midpoint.
        let mid = try PathResourceSampler.sample(resource: r, closed: true, at: try t(5), field: "m").positions.map { $0.rawValue }
        XCTAssertEqual(mid, [0, 0, 150, 0, 150, 150])
    }

    func testHoldUsesPreviousRowUntilBoundary() throws {
        let a: [Int64] = [0, 0, 100, 0, 100, 100]
        let b: [Int64] = [0, 0, 200, 0, 200, 200]
        let r = try twoKeyframeResource(a: a, b: b, hold: true)
        // Hold: anywhere in [0,10) returns the lower row exactly; at 10 returns the last row.
        XCTAssertEqual(try PathResourceSampler.sample(resource: r, closed: true, at: try t(5), field: "h").positions.map { $0.rawValue }, a)
        XCTAssertEqual(try PathResourceSampler.sample(resource: r, closed: true, at: try t(10), field: "h").positions.map { $0.rawValue }, b)
    }

    func testEasingChangesSampledRow() throws {
        let a: [Int64] = [0, 0, 100, 0, 100, 100]
        let b: [Int64] = [0, 0, 200, 0, 200, 200]
        // Linear-ish easing vs an ease that biases the fraction → different midpoint sample.
        let linear = try twoKeyframeResource(a: a, b: b)
        let eased = try RenderPathResource(
            pathID: 5, vertexCount: 3, indices: [0, 1, 2],
            keyframeTimes: [try t(0), try t(10)],
            keyframePositions: [a.map { cs($0) }, b.map { cs($0) }],
            keyframeEasing: [RenderPathEasing(
                outX: EasingScalar(rawValue: 250_000), outY: EasingScalar(rawValue: 900_000),
                inX: EasingScalar(rawValue: 900_000), inY: EasingScalar(rawValue: 950_000), hold: false)])
        let m1 = try PathResourceSampler.sample(resource: linear, closed: true, at: try t(5), field: "e").positions.map { $0.rawValue }
        let m2 = try PathResourceSampler.sample(resource: eased, closed: true, at: try t(5), field: "e").positions.map { $0.rawValue }
        XCTAssertNotEqual(m1, m2, "easing changes the sampled row")
    }

    func testMalformedRowLengthFails() throws {
        // A row whose length != vertexCount*2 cannot be constructed by RenderPathResource itself, so we
        // assert the constructor enforces it (the sampler trusts that invariant).
        XCTAssertThrowsError(try RenderPathResource(
            pathID: 5, vertexCount: 3, indices: [0, 1, 2],
            keyframeTimes: [try t(0)], keyframePositions: [[cs(1), cs(2)]], keyframeEasing: []))
    }

    func testInvalidIndexFails() throws {
        XCTAssertThrowsError(try RenderPathResource(
            pathID: 5, vertexCount: 3, indices: [0, 1, 9],  // 9 >= vertexCount
            keyframeTimes: [try t(0)],
            keyframePositions: [[cs(0), cs(0), cs(1), cs(0), cs(1), cs(1)]], keyframeEasing: []))
    }

    func testBezierAnchorCountMayDifferFromMeshVertexCount() throws {
        // The control bezier (SampledBezier) is unrelated to the producer mesh vertex count: a mesh with 4
        // flattened vertices coexists with a 3-anchor control path. No cross-indexing.
        let r = try RenderPathResource(
            pathID: 5, vertexCount: 4, indices: [0, 1, 2, 0, 2, 3],
            keyframeTimes: [try t(0)],
            keyframePositions: [[cs(0), cs(0), cs(10), cs(0), cs(10), cs(10), cs(0), cs(10)]], keyframeEasing: [])
        let mesh = try PathResourceSampler.sample(resource: r, closed: true, at: try t(0), field: "b")
        XCTAssertEqual(mesh.positions.count, 8, "4 flattened verts")
        XCTAssertEqual(mesh.indices.count, 6, "two triangles")
    }

    func testClosedFlagThreadsThrough() throws {
        let r = try twoKeyframeResource(a: [0, 0, 100, 0, 100, 100], b: [0, 0, 200, 0, 200, 200])
        XCTAssertTrue(try PathResourceSampler.sample(resource: r, closed: true, at: try t(0), field: "c").closed)
        XCTAssertFalse(try PathResourceSampler.sample(resource: r, closed: false, at: try t(0), field: "c").closed)
    }
}
