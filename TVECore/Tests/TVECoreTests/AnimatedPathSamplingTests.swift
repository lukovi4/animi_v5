import XCTest
@testable import TVECore

/// Tests for AnimPath keyframe sampling with bezier easing
final class AnimatedPathSamplingTests: XCTestCase {

    // MARK: - CubicBezierEasing Tests

    func testCubicBezierEasing_linear() {
        // Linear easing: (0,0) to (1,1)
        let result = CubicBezierEasing.solve(x: 0.5, x1: 0, y1: 0, x2: 1, y2: 1)
        XCTAssertEqual(result, 0.5, accuracy: 0.001)
    }

    func testCubicBezierEasing_easeInOut() {
        // Ease in-out: starts slow, speeds up, ends slow
        let mid = CubicBezierEasing.solve(x: 0.5, x1: 0.42, y1: 0, x2: 0.58, y2: 1)
        // At midpoint, eased value should be close to 0.5
        XCTAssertEqual(mid, 0.5, accuracy: 0.1)

        // At 25%, should be less than linear (ease-in effect)
        let early = CubicBezierEasing.solve(x: 0.25, x1: 0.42, y1: 0, x2: 0.58, y2: 1)
        XCTAssertLessThan(early, 0.25)
    }

    func testCubicBezierEasing_edgeCases() {
        // x <= 0 should return 0
        XCTAssertEqual(CubicBezierEasing.solve(x: 0, x1: 0.5, y1: 0, x2: 0.5, y2: 1), 0)
        XCTAssertEqual(CubicBezierEasing.solve(x: -0.1, x1: 0.5, y1: 0, x2: 0.5, y2: 1), 0)

        // x >= 1 should return 1
        XCTAssertEqual(CubicBezierEasing.solve(x: 1, x1: 0.5, y1: 0, x2: 0.5, y2: 1), 1)
        XCTAssertEqual(CubicBezierEasing.solve(x: 1.1, x1: 0.5, y1: 0, x2: 0.5, y2: 1), 1)
    }

    /// DoD for PR-B fix 2: test bad tangents (x1==x2==0 / nearly flat curve) → returns value in [0,1], no NaN
    func testCubicBezierEasing_badTangents_noNaN_returnsValueIn0to1() {
        // Test case 1: x1 == x2 == 0 (flat curve, derivative issues)
        let result1 = CubicBezierEasing.solve(x: 0.5, x1: 0, y1: 0, x2: 0, y2: 1)
        XCTAssertFalse(result1.isNaN, "Result should not be NaN for x1==x2==0")
        XCTAssertFalse(result1.isInfinite, "Result should not be infinite for x1==x2==0")
        XCTAssertGreaterThanOrEqual(result1, 0, "Result should be >= 0")
        XCTAssertLessThanOrEqual(result1, 1, "Result should be <= 1")

        // Test case 2: x1 == x2 == 1 (another degenerate case)
        let result2 = CubicBezierEasing.solve(x: 0.5, x1: 1, y1: 0, x2: 1, y2: 1)
        XCTAssertFalse(result2.isNaN, "Result should not be NaN for x1==x2==1")
        XCTAssertFalse(result2.isInfinite, "Result should not be infinite for x1==x2==1")
        XCTAssertGreaterThanOrEqual(result2, 0, "Result should be >= 0")
        XCTAssertLessThanOrEqual(result2, 1, "Result should be <= 1")

        // Test case 3: Nearly flat curve (very small x values)
        let result3 = CubicBezierEasing.solve(x: 0.5, x1: 0.001, y1: 0.5, x2: 0.001, y2: 0.5)
        XCTAssertFalse(result3.isNaN, "Result should not be NaN for nearly flat curve")
        XCTAssertFalse(result3.isInfinite, "Result should not be infinite for nearly flat curve")
        XCTAssertGreaterThanOrEqual(result3, 0, "Result should be >= 0")
        XCTAssertLessThanOrEqual(result3, 1, "Result should be <= 1")

        // Test case 4: Extreme out-of-range control points (should be clamped)
        let result4 = CubicBezierEasing.solve(x: 0.5, x1: -1, y1: 2, x2: 2, y2: -1)
        XCTAssertFalse(result4.isNaN, "Result should not be NaN for extreme control points")
        XCTAssertFalse(result4.isInfinite, "Result should not be infinite for extreme control points")
        XCTAssertGreaterThanOrEqual(result4, 0, "Result should be >= 0")
        XCTAssertLessThanOrEqual(result4, 1, "Result should be <= 1")

        // Test case 5: All zeros
        let result5 = CubicBezierEasing.solve(x: 0.5, x1: 0, y1: 0, x2: 0, y2: 0)
        XCTAssertFalse(result5.isNaN, "Result should not be NaN for all zeros")
        XCTAssertFalse(result5.isInfinite, "Result should not be infinite for all zeros")
        XCTAssertGreaterThanOrEqual(result5, 0, "Result should be >= 0")
        XCTAssertLessThanOrEqual(result5, 1, "Result should be <= 1")
    }

    func testCubicBezierEasing_multipleInputValues_allInRange() {
        // Test various input values with bad tangents to ensure all outputs are in [0,1]
        let badTangentCases: [(x1: Double, y1: Double, x2: Double, y2: Double)] = [
            (0, 0, 0, 0),
            (0, 0, 0, 1),
            (1, 0, 1, 1),
            (0.001, 0.999, 0.001, 0.001),
            (-0.5, 0.5, 1.5, 0.5), // Out of range
        ]

        let testInputs = [0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0]

        for (x1, y1, x2, y2) in badTangentCases {
            for input in testInputs {
                let result = CubicBezierEasing.solve(x: input, x1: x1, y1: y1, x2: x2, y2: y2)
                XCTAssertFalse(result.isNaN, "Result should not be NaN for input=\(input), tangents=(\(x1),\(y1),\(x2),\(y2))")
                XCTAssertFalse(result.isInfinite, "Result should not be infinite")
                XCTAssertGreaterThanOrEqual(result, 0, "Result should be >= 0")
                XCTAssertLessThanOrEqual(result, 1, "Result should be <= 1")
            }
        }
    }

    // MARK: - BezierPath Interpolation Tests

    func testBezierPath_interpolation_basic() {
        let path1 = BezierPath(
            vertices: [Vec2D(x: 0, y: 0), Vec2D(x: 100, y: 0)],
            inTangents: [Vec2D(x: 0, y: 0), Vec2D(x: 0, y: 0)],
            outTangents: [Vec2D(x: 0, y: 0), Vec2D(x: 0, y: 0)],
            closed: false
        )
        let path2 = BezierPath(
            vertices: [Vec2D(x: 0, y: 100), Vec2D(x: 100, y: 100)],
            inTangents: [Vec2D(x: 0, y: 0), Vec2D(x: 0, y: 0)],
            outTangents: [Vec2D(x: 0, y: 0), Vec2D(x: 0, y: 0)],
            closed: false
        )

        let interpolated = path1.interpolated(to: path2, t: 0.5)
        XCTAssertNotNil(interpolated)

        // Vertices should be halfway
        XCTAssertEqual(interpolated!.vertices[0].y, 50, accuracy: 0.001)
        XCTAssertEqual(interpolated!.vertices[1].y, 50, accuracy: 0.001)
    }

    func testBezierPath_interpolation_topologyMismatch_returnsNil() {
        let path1 = BezierPath(
            vertices: [Vec2D(x: 0, y: 0), Vec2D(x: 100, y: 0)],
            inTangents: [Vec2D(x: 0, y: 0), Vec2D(x: 0, y: 0)],
            outTangents: [Vec2D(x: 0, y: 0), Vec2D(x: 0, y: 0)],
            closed: false
        )
        let path2 = BezierPath(
            vertices: [Vec2D(x: 0, y: 100)],  // Different vertex count!
            inTangents: [Vec2D(x: 0, y: 0)],
            outTangents: [Vec2D(x: 0, y: 0)],
            closed: false
        )

        let interpolated = path1.interpolated(to: path2, t: 0.5)
        XCTAssertNil(interpolated, "Should return nil when vertex count differs")
    }

    func testBezierPath_interpolation_closedMismatch_returnsNil() {
        let path1 = BezierPath(
            vertices: [Vec2D(x: 0, y: 0), Vec2D(x: 100, y: 0)],
            inTangents: [Vec2D(x: 0, y: 0), Vec2D(x: 0, y: 0)],
            outTangents: [Vec2D(x: 0, y: 0), Vec2D(x: 0, y: 0)],
            closed: false
        )
        let path2 = BezierPath(
            vertices: [Vec2D(x: 0, y: 100), Vec2D(x: 100, y: 100)],
            inTangents: [Vec2D(x: 0, y: 0), Vec2D(x: 0, y: 0)],
            outTangents: [Vec2D(x: 0, y: 0), Vec2D(x: 0, y: 0)],
            closed: true  // Different closed flag!
        )

        let interpolated = path1.interpolated(to: path2, t: 0.5)
        XCTAssertNil(interpolated, "Should return nil when closed flag differs")
    }

    func testBezierPath_interpolation_edgeCases() {
        let path1 = BezierPath(
            vertices: [Vec2D(x: 0, y: 0)],
            inTangents: [Vec2D(x: 0, y: 0)],
            outTangents: [Vec2D(x: 0, y: 0)],
            closed: true
        )
        let path2 = BezierPath(
            vertices: [Vec2D(x: 100, y: 100)],
            inTangents: [Vec2D(x: 0, y: 0)],
            outTangents: [Vec2D(x: 0, y: 0)],
            closed: true
        )

        // t <= 0 returns self
        let atZero = path1.interpolated(to: path2, t: 0)
        XCTAssertEqual(atZero?.vertices[0].x, 0)

        // t >= 1 returns other
        let atOne = path1.interpolated(to: path2, t: 1)
        XCTAssertEqual(atOne?.vertices[0].x, 100)
    }

    // MARK: - AnimPath Sample Tests

    func testAnimPath_staticPath_sample() {
        let path = BezierPath(
            vertices: [Vec2D(x: 50, y: 50)],
            inTangents: [Vec2D(x: 0, y: 0)],
            outTangents: [Vec2D(x: 0, y: 0)],
            closed: true
        )
        let animPath = AnimPath.staticBezier(path)

        // Static path returns same path for any frame
        let sampled = animPath.sample(frame: 0)
        XCTAssertEqual(sampled?.vertices[0].x, 50)

        let sampled2 = animPath.sample(frame: 1000)
        XCTAssertEqual(sampled2?.vertices[0].x, 50)
    }

    func testAnimPath_keyframed_sample_beforeFirst() {
        let kf1 = Keyframe(time: 60.0, value: makePath(y: 0), inTangent: nil, outTangent: nil, hold: false)
        let kf2 = Keyframe(time: 90.0, value: makePath(y: 100), inTangent: nil, outTangent: nil, hold: false)
        let animPath = AnimPath.keyframedBezier([kf1, kf2])

        // Before first keyframe - returns first value
        let sampled = animPath.sample(frame: 0)
        XCTAssertEqual(sampled?.vertices[0].y, 0)
    }

    func testAnimPath_keyframed_sample_afterLast() {
        let kf1 = Keyframe(time: 60.0, value: makePath(y: 0), inTangent: nil, outTangent: nil, hold: false)
        let kf2 = Keyframe(time: 90.0, value: makePath(y: 100), inTangent: nil, outTangent: nil, hold: false)
        let animPath = AnimPath.keyframedBezier([kf1, kf2])

        // After last keyframe - returns last value
        let sampled = animPath.sample(frame: 120)
        XCTAssertEqual(sampled?.vertices[0].y, 100)
    }

    func testAnimPath_keyframed_sample_linearInterpolation() {
        let kf1 = Keyframe(time: 60.0, value: makePath(y: 0), inTangent: nil, outTangent: nil, hold: false)
        let kf2 = Keyframe(time: 90.0, value: makePath(y: 100), inTangent: nil, outTangent: nil, hold: false)
        let animPath = AnimPath.keyframedBezier([kf1, kf2])

        // Mid-point (frame 75 = 50% between 60 and 90)
        let sampled = animPath.sample(frame: 75)
        XCTAssertEqual(sampled!.vertices[0].y, 50, accuracy: 0.001)
    }

    func testAnimPath_keyframed_sample_holdKeyframe() {
        let kf1 = Keyframe(time: 60.0, value: makePath(y: 0), inTangent: nil, outTangent: nil, hold: true)
        let kf2 = Keyframe(time: 90.0, value: makePath(y: 100), inTangent: nil, outTangent: nil, hold: false)
        let animPath = AnimPath.keyframedBezier([kf1, kf2])

        // Hold keyframe - should stay at first value until next keyframe
        let sampled = animPath.sample(frame: 75)
        XCTAssertEqual(sampled?.vertices[0].y, 0, "Hold keyframe should not interpolate")
    }

    // MARK: - Anim3 Integration Test

    /// Critical test: verifies that path AABB changes between frames 60 and 90 in anim-3.json
    func testAnim3_pathAABB_changes_between_60_and_90() throws {
        // Load anim-3.json
        guard let url = Bundle.module.url(
            forResource: "anim-3",
            withExtension: "json",
            subdirectory: "Resources"
        ) else {
            XCTFail("Could not find anim-3.json")
            return
        }

        let data = try Data(contentsOf: url)
        let lottie = try JSONDecoder().decode(LottieJSON.self, from: data)

        // Find the matte source layer (td=1, shape layer with animated path)
        let matteLayers = lottie.layers.filter { $0.isMatteSource == 1 }
        guard let matteLayer = matteLayers.first else {
            XCTFail("Could not find matte source layer")
            return
        }

        // Extract AnimPath from shapes
        guard let animPath = ShapePathExtractor.extractAnimPath(from: matteLayer.shapes) else {
            XCTFail("Could not extract AnimPath from matte layer")
            return
        }

        // Verify it's animated
        XCTAssertTrue(animPath.isAnimated, "Path should be animated")

        // Sample at frame 60 (start of animation)
        guard let path60 = animPath.sample(frame: 60) else {
            XCTFail("Could not sample path at frame 60")
            return
        }

        // Sample at frame 90 (end of animation)
        guard let path90 = animPath.sample(frame: 90) else {
            XCTFail("Could not sample path at frame 90")
            return
        }

        // Get AABBs
        let aabb60 = path60.aabb
        let aabb90 = path90.aabb

        // Frame 60: narrow strip (vertices around ±10 X)
        // Frame 90: full width (vertices around ±270 X)
        // The AABB width should be significantly different!

        let width60 = aabb60.maxX - aabb60.minX
        let width90 = aabb90.maxX - aabb90.minX

        // Frame 60 should be narrow (around 20 units wide based on JSON: -10 to 10)
        // Frame 90 should be wide (around 540 units wide based on JSON: -270 to 270)
        XCTAssertLessThan(width60, 100, "Frame 60 path should be narrow")
        XCTAssertGreaterThan(width90, 400, "Frame 90 path should be wide")
        XCTAssertGreaterThan(width90, width60 * 2, "Frame 90 should be significantly wider than frame 60")

        // Sample at mid-point (frame 75)
        guard let path75 = animPath.sample(frame: 75) else {
            XCTFail("Could not sample path at frame 75")
            return
        }

        let aabb75 = path75.aabb
        let width75 = aabb75.maxX - aabb75.minX

        // Width at frame 75 should be between 60 and 90
        XCTAssertGreaterThan(width75, width60, "Frame 75 width should be > frame 60")
        XCTAssertLessThan(width75, width90, "Frame 75 width should be < frame 90")
    }

    // MARK: - Topology Validation Tests

    func testExtractAnimPath_topologyMismatch_returnsNil() throws {
        // Create JSON with mismatched vertex counts between keyframes
        let json = """
        {
            "ty": "sh",
            "ks": {
                "a": 1,
                "k": [
                    {
                        "t": 0,
                        "s": [{"v": [[0, 0], [100, 0]], "i": [[0, 0], [0, 0]], "o": [[0, 0], [0, 0]], "c": true}]
                    },
                    {
                        "t": 30,
                        "s": [{"v": [[0, 0]], "i": [[0, 0]], "o": [[0, 0]], "c": true}]
                    }
                ]
            }
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)

        // extractAnimPath should return nil due to topology mismatch
        let animPath = ShapePathExtractor.extractAnimPath(from: [shape])
        XCTAssertNil(animPath, "Should return nil when keyframes have different vertex counts")
    }

    // MARK: - Helpers

    private func makePath(y: Double) -> BezierPath {
        BezierPath(
            vertices: [Vec2D(x: 0, y: y)],
            inTangents: [Vec2D(x: 0, y: 0)],
            outTangents: [Vec2D(x: 0, y: 0)],
            closed: true
        )
    }
}
