import XCTest
@testable import TVECore

/// Tests for ShapePathExtractor group transform handling
/// Per review.md:
/// - Unit: ShapePathExtractor_GroupTransformTranslationApplied
/// - Unit: GroupTransformRotationScale
/// - Integration: MatteShapeAlignsWithConsumer
final class ShapePathExtractorTests: XCTestCase {

    // MARK: - Group Transform Translation

    /// Test that group transform translation (p, a) is applied to path vertices
    /// Based on anim-2.json: tr.p=[-25.149, 69.595], tr.a=[0, 0]
    /// Expected: AABB shifted by (-25.149, +69.595)
    func testGroupTransform_translationApplied() throws {
        // Create group with path + transform
        // Path: square at origin, vertices: (0,0), (100,0), (100,100), (0,100)
        // Transform: p=[-25, 70], a=[0, 0]
        // Expected after transform: (-25, 70), (75, 70), (75, 170), (-25, 170)
        let json = """
        {
            "ty": "gr",
            "nm": "Group 1",
            "it": [
                {
                    "ty": "sh",
                    "nm": "Path 1",
                    "ks": {
                        "a": 0,
                        "k": {
                            "v": [[0, 0], [100, 0], [100, 100], [0, 100]],
                            "i": [[0, 0], [0, 0], [0, 0], [0, 0]],
                            "o": [[0, 0], [0, 0], [0, 0], [0, 0]],
                            "c": true
                        }
                    }
                },
                {
                    "ty": "fl",
                    "c": {"a": 0, "k": [0, 0, 0, 1]}
                },
                {
                    "ty": "tr",
                    "p": {"a": 0, "k": [-25, 70]},
                    "a": {"a": 0, "k": [0, 0]},
                    "s": {"a": 0, "k": [100, 100]},
                    "r": {"a": 0, "k": 0},
                    "o": {"a": 0, "k": 100}
                }
            ]
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)

        // Extract path using ShapePathExtractor
        let path = ShapePathExtractor.extractPath(from: [shape])

        XCTAssertNotNil(path, "Path should be extracted from group")
        guard let extractedPath = path else { return }

        // Check AABB shifted by translation
        let aabb = extractedPath.aabb
        let epsilon = 0.001

        // Original AABB: (0, 0, 100, 100)
        // After translation by (-25, 70): (-25, 70) to (75, 170)
        XCTAssertEqual(aabb.minX, -25, accuracy: epsilon, "minX should be -25")
        XCTAssertEqual(aabb.minY, 70, accuracy: epsilon, "minY should be 70")
        XCTAssertEqual(aabb.maxX, 75, accuracy: epsilon, "maxX should be 75")
        XCTAssertEqual(aabb.maxY, 170, accuracy: epsilon, "maxY should be 170")
    }

    /// Test with non-zero anchor point
    /// Transform: p=[10, 20], a=[5, 10]
    /// Effective translation: (10-5, 20-10) = (5, 10)
    func testGroupTransform_anchorPointApplied() throws {
        let json = """
        {
            "ty": "gr",
            "it": [
                {
                    "ty": "sh",
                    "ks": {
                        "a": 0,
                        "k": {
                            "v": [[0, 0], [100, 0], [100, 100], [0, 100]],
                            "i": [[0, 0], [0, 0], [0, 0], [0, 0]],
                            "o": [[0, 0], [0, 0], [0, 0], [0, 0]],
                            "c": true
                        }
                    }
                },
                {
                    "ty": "tr",
                    "p": {"a": 0, "k": [10, 20]},
                    "a": {"a": 0, "k": [5, 10]}
                }
            ]
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)
        let path = ShapePathExtractor.extractPath(from: [shape])

        XCTAssertNotNil(path)
        guard let extractedPath = path else { return }

        let aabb = extractedPath.aabb
        let epsilon = 0.001

        // Effective translation: T(10,20) * T(-5,-10) = T(5, 10)
        // Original: (0,0) to (100,100) -> After: (5,10) to (105,110)
        XCTAssertEqual(aabb.minX, 5, accuracy: epsilon)
        XCTAssertEqual(aabb.minY, 10, accuracy: epsilon)
        XCTAssertEqual(aabb.maxX, 105, accuracy: epsilon)
        XCTAssertEqual(aabb.maxY, 110, accuracy: epsilon)
    }

    // MARK: - Group Transform Rotation & Scale

    /// Test that group transform scale is applied
    /// Transform: scale 200%
    /// Path: square (0,0) to (100,100)
    /// Expected: square (0,0) to (200,200)
    func testGroupTransform_scaleApplied() throws {
        let json = """
        {
            "ty": "gr",
            "it": [
                {
                    "ty": "sh",
                    "ks": {
                        "a": 0,
                        "k": {
                            "v": [[0, 0], [100, 0], [100, 100], [0, 100]],
                            "i": [[0, 0], [0, 0], [0, 0], [0, 0]],
                            "o": [[0, 0], [0, 0], [0, 0], [0, 0]],
                            "c": true
                        }
                    }
                },
                {
                    "ty": "tr",
                    "p": {"a": 0, "k": [0, 0]},
                    "a": {"a": 0, "k": [0, 0]},
                    "s": {"a": 0, "k": [200, 200]}
                }
            ]
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)
        let path = ShapePathExtractor.extractPath(from: [shape])

        XCTAssertNotNil(path)
        guard let extractedPath = path else { return }

        let aabb = extractedPath.aabb
        let epsilon = 0.001

        // Scale 200%: (0,0)-(100,100) -> (0,0)-(200,200)
        XCTAssertEqual(aabb.minX, 0, accuracy: epsilon)
        XCTAssertEqual(aabb.minY, 0, accuracy: epsilon)
        XCTAssertEqual(aabb.maxX, 200, accuracy: epsilon)
        XCTAssertEqual(aabb.maxY, 200, accuracy: epsilon)
    }

    /// Test that group transform rotation is applied (90 degrees)
    /// Path: square (0,0) to (100,100)
    /// Rotation 90° around anchor (0,0)
    /// Expected: vertices rotated 90° CW
    func testGroupTransform_rotationApplied() throws {
        let json = """
        {
            "ty": "gr",
            "it": [
                {
                    "ty": "sh",
                    "ks": {
                        "a": 0,
                        "k": {
                            "v": [[100, 0], [100, 100], [0, 100], [0, 0]],
                            "i": [[0, 0], [0, 0], [0, 0], [0, 0]],
                            "o": [[0, 0], [0, 0], [0, 0], [0, 0]],
                            "c": true
                        }
                    }
                },
                {
                    "ty": "tr",
                    "p": {"a": 0, "k": [0, 0]},
                    "a": {"a": 0, "k": [0, 0]},
                    "s": {"a": 0, "k": [100, 100]},
                    "r": {"a": 0, "k": 90}
                }
            ]
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)
        let path = ShapePathExtractor.extractPath(from: [shape])

        XCTAssertNotNil(path)
        guard let extractedPath = path else { return }

        let aabb = extractedPath.aabb
        let epsilon = 0.1

        // Original square: (0,0) to (100,100)
        // After 90° CW rotation around origin: (0,-100) to (100,0)
        // Note: In screen coordinates (Y down), 90° rotation maps (x,y) to (y, -x)
        // (100,0) -> (0, -100), (100,100) -> (100, -100), (0,100) -> (100, 0), (0,0) -> (0, 0)
        // AABB: minX=0, maxX=100, minY=-100, maxY=0
        XCTAssertEqual(aabb.minX, 0, accuracy: epsilon, "minX after 90° rotation")
        XCTAssertEqual(aabb.maxX, 100, accuracy: epsilon, "maxX after 90° rotation")
        XCTAssertEqual(aabb.minY, -100, accuracy: epsilon, "minY after 90° rotation")
        XCTAssertEqual(aabb.maxY, 0, accuracy: epsilon, "maxY after 90° rotation")
    }

    /// Combined test: scale 200% + rotation 90° around anchor
    func testGroupTransform_rotationAndScaleCombined() throws {
        let json = """
        {
            "ty": "gr",
            "it": [
                {
                    "ty": "sh",
                    "ks": {
                        "a": 0,
                        "k": {
                            "v": [[50, 0], [50, 50], [0, 50], [0, 0]],
                            "i": [[0, 0], [0, 0], [0, 0], [0, 0]],
                            "o": [[0, 0], [0, 0], [0, 0], [0, 0]],
                            "c": true
                        }
                    }
                },
                {
                    "ty": "tr",
                    "p": {"a": 0, "k": [0, 0]},
                    "a": {"a": 0, "k": [0, 0]},
                    "s": {"a": 0, "k": [200, 200]},
                    "r": {"a": 0, "k": 90}
                }
            ]
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)
        let path = ShapePathExtractor.extractPath(from: [shape])

        XCTAssertNotNil(path)
        guard let extractedPath = path else { return }

        let aabb = extractedPath.aabb
        let epsilon = 0.1

        // Original: (0,0) to (50,50)
        // After R(90°) * S(200%):
        // Scale first: (0,0) to (100,100)
        // Then rotate 90°: (0,-100) to (100,0)
        XCTAssertEqual(aabb.minX, 0, accuracy: epsilon)
        XCTAssertEqual(aabb.maxX, 100, accuracy: epsilon)
        XCTAssertEqual(aabb.minY, -100, accuracy: epsilon)
        XCTAssertEqual(aabb.maxY, 0, accuracy: epsilon)
    }

    // MARK: - No Transform (Identity)

    /// Test that paths without group transform are unchanged
    func testGroupTransform_noTransformIdentity() throws {
        let json = """
        {
            "ty": "gr",
            "it": [
                {
                    "ty": "sh",
                    "ks": {
                        "a": 0,
                        "k": {
                            "v": [[0, 0], [100, 0], [100, 100], [0, 100]],
                            "i": [[0, 0], [0, 0], [0, 0], [0, 0]],
                            "o": [[0, 0], [0, 0], [0, 0], [0, 0]],
                            "c": true
                        }
                    }
                },
                {
                    "ty": "fl",
                    "c": {"a": 0, "k": [1, 0, 0, 1]}
                }
            ]
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)
        let path = ShapePathExtractor.extractPath(from: [shape])

        XCTAssertNotNil(path)
        guard let extractedPath = path else { return }

        let aabb = extractedPath.aabb
        let epsilon = 0.001

        // No transform = identity, path unchanged
        XCTAssertEqual(aabb.minX, 0, accuracy: epsilon)
        XCTAssertEqual(aabb.minY, 0, accuracy: epsilon)
        XCTAssertEqual(aabb.maxX, 100, accuracy: epsilon)
        XCTAssertEqual(aabb.maxY, 100, accuracy: epsilon)
    }

    // MARK: - Tangent Transform

    /// Test that tangent vectors are transformed correctly (rotation/scale only, no translation)
    func testGroupTransform_tangentsTransformed() throws {
        let json = """
        {
            "ty": "gr",
            "it": [
                {
                    "ty": "sh",
                    "ks": {
                        "a": 0,
                        "k": {
                            "v": [[0, 0], [100, 0]],
                            "i": [[0, 0], [0, 0]],
                            "o": [[10, 0], [0, 0]],
                            "c": false
                        }
                    }
                },
                {
                    "ty": "tr",
                    "p": {"a": 0, "k": [50, 50]},
                    "a": {"a": 0, "k": [0, 0]},
                    "s": {"a": 0, "k": [200, 200]}
                }
            ]
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)
        let path = ShapePathExtractor.extractPath(from: [shape])

        XCTAssertNotNil(path)
        guard let extractedPath = path else { return }

        // Out tangent at vertex 0 was (10, 0)
        // After scale 200%: should be (20, 0)
        // Translation should NOT affect tangent (tangents are relative vectors)
        XCTAssertEqual(extractedPath.outTangents.count, 2)
        let outTangent0 = extractedPath.outTangents[0]
        XCTAssertEqual(outTangent0.x, 20, accuracy: 0.001, "Out tangent X should be scaled")
        XCTAssertEqual(outTangent0.y, 0, accuracy: 0.001, "Out tangent Y should remain 0")
    }

    // MARK: - Integration: anim-2.json Matte Shape

    /// Integration test using exact data from anim-2.json
    /// Verifies that matte shape AABB aligns with consumer image quad after group transform
    ///
    /// From anim-2.json shape layer (ind:2):
    /// - Shape vertices: [[270, -160], [270, 480], [-270, 160], [-270, -480]]
    /// - Group transform: p=[-25.149, 69.595], a=[0, 0]
    ///
    /// Before group transform: AABB = (-270, -480) to (270, 480) = 540x960
    /// After group transform: shifted by (-25.149, +69.595)
    ///   AABB = (-295.149, -410.405) to (244.851, 549.595) = 540x960
    ///
    /// Consumer image is 540x960, positioned at same location.
    /// The matte shape AABB.left (-295.149) after adding layer transform should match consumer quad.left
    func testIntegration_anim2MatteShapeGroupTransformApplied() throws {
        // Exact JSON from anim-2.json shape layer (simplified)
        let json = """
        {
            "ty": "gr",
            "it": [
                {
                    "ty": "sh",
                    "ks": {
                        "a": 0,
                        "k": {
                            "v": [[270, -160], [270, 480], [-270, 160], [-270, -480]],
                            "i": [[0, 0], [0, 0], [0, 0], [0, 0]],
                            "o": [[0, 0], [0, 0], [0, 0], [0, 0]],
                            "c": true
                        }
                    }
                },
                {
                    "ty": "fl",
                    "c": {"a": 0, "k": [0, 0, 0, 1]},
                    "o": {"a": 0, "k": 100},
                    "r": 1
                },
                {
                    "ty": "tr",
                    "p": {"a": 0, "k": [-25.149, 69.595]},
                    "a": {"a": 0, "k": [0, 0]},
                    "s": {"a": 0, "k": [100, 100]},
                    "r": {"a": 0, "k": 0},
                    "o": {"a": 0, "k": 100}
                }
            ]
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)
        let path = ShapePathExtractor.extractPath(from: [shape])

        XCTAssertNotNil(path, "Path should be extracted from anim-2 matte shape group")
        guard let extractedPath = path else { return }

        let aabb = extractedPath.aabb
        let epsilon = 0.01

        // Original AABB: (-270, -480) to (270, 480)
        // After group transform p=(-25.149, 69.595), a=(0,0):
        // New AABB: (-270-25.149, -480+69.595) to (270-25.149, 480+69.595)
        //         = (-295.149, -410.405) to (244.851, 549.595)

        XCTAssertEqual(aabb.minX, -295.149, accuracy: epsilon,
                       "minX should be shifted by group transform p.x=-25.149")
        XCTAssertEqual(aabb.minY, -410.405, accuracy: epsilon,
                       "minY should be shifted by group transform p.y=+69.595")
        XCTAssertEqual(aabb.maxX, 244.851, accuracy: epsilon,
                       "maxX should be shifted by group transform p.x=-25.149")
        XCTAssertEqual(aabb.maxY, 549.595, accuracy: epsilon,
                       "maxY should be shifted by group transform p.y=+69.595")

        // Verify dimensions unchanged (540x960)
        let width = aabb.maxX - aabb.minX
        let height = aabb.maxY - aabb.minY
        XCTAssertEqual(width, 540, accuracy: epsilon, "Width should remain 540")
        XCTAssertEqual(height, 960, accuracy: epsilon, "Height should remain 960")
    }

    // MARK: - Rectangle Shape (rc) Tests - PR-07

    /// Test static rectangle with no roundness (r=0)
    /// rect: p=[0,0], s=[100,200], r=0, d=1 (clockwise)
    /// Expected AABB: minX=-50, maxX=50, minY=-100, maxY=100
    /// Expected vertex count: 4
    func testRect_staticSharpCorners() throws {
        let json = """
        {
            "ty": "rc",
            "nm": "Rectangle 1",
            "p": {"a": 0, "k": [0, 0]},
            "s": {"a": 0, "k": [100, 200]},
            "r": {"a": 0, "k": 0},
            "d": 1
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)
        let path = ShapePathExtractor.extractPath(from: [shape])

        XCTAssertNotNil(path, "Path should be extracted from rectangle")
        guard let extractedPath = path else { return }

        let epsilon = 0.001

        // Verify vertex count for sharp corners
        XCTAssertEqual(extractedPath.vertexCount, 4, "Sharp rectangle should have 4 vertices")

        // Verify AABB
        let aabb = extractedPath.aabb
        XCTAssertEqual(aabb.minX, -50, accuracy: epsilon, "minX should be -50 (cx - w/2)")
        XCTAssertEqual(aabb.maxX, 50, accuracy: epsilon, "maxX should be 50 (cx + w/2)")
        XCTAssertEqual(aabb.minY, -100, accuracy: epsilon, "minY should be -100 (cy - h/2)")
        XCTAssertEqual(aabb.maxY, 100, accuracy: epsilon, "maxY should be 100 (cy + h/2)")

        // Verify closed path
        XCTAssertTrue(extractedPath.closed, "Rectangle path should be closed")
    }

    /// Test static rectangle with roundness (r>0)
    /// rect: p=[0,0], s=[100,200], r=20
    /// Expected vertex count: 8 (2 per corner)
    /// Expected AABB: same as sharp rectangle (corners don't extend past original bounds)
    func testRect_staticRoundedCorners() throws {
        let json = """
        {
            "ty": "rc",
            "nm": "Rounded Rectangle",
            "p": {"a": 0, "k": [0, 0]},
            "s": {"a": 0, "k": [100, 200]},
            "r": {"a": 0, "k": 20},
            "d": 1
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)
        let path = ShapePathExtractor.extractPath(from: [shape])

        XCTAssertNotNil(path, "Path should be extracted from rounded rectangle")
        guard let extractedPath = path else { return }

        let epsilon = 0.001

        // Verify vertex count for rounded corners
        XCTAssertEqual(extractedPath.vertexCount, 8, "Rounded rectangle should have 8 vertices")

        // Verify AABB is same as sharp rectangle (rounded corners don't extend past bounds)
        let aabb = extractedPath.aabb
        XCTAssertEqual(aabb.minX, -50, accuracy: epsilon, "minX should be -50")
        XCTAssertEqual(aabb.maxX, 50, accuracy: epsilon, "maxX should be 50")
        XCTAssertEqual(aabb.minY, -100, accuracy: epsilon, "minY should be -100")
        XCTAssertEqual(aabb.maxY, 100, accuracy: epsilon, "maxY should be 100")

        // Verify closed path
        XCTAssertTrue(extractedPath.closed, "Rectangle path should be closed")

        // Verify tangent arrays have correct count
        XCTAssertEqual(extractedPath.inTangents.count, 8, "Should have 8 in tangents")
        XCTAssertEqual(extractedPath.outTangents.count, 8, "Should have 8 out tangents")
    }

    /// Test animated rectangle size
    /// s: keyframes at t=0 [100,100], t=10 [200,100]
    /// p: static [0,0]
    /// Expected: keyframedBezier with 2 keyframes
    func testRect_animatedSize() throws {
        let json = """
        {
            "ty": "rc",
            "nm": "Animated Size Rectangle",
            "p": {"a": 0, "k": [0, 0]},
            "s": {
                "a": 1,
                "k": [
                    {"t": 0, "s": [100, 100]},
                    {"t": 10, "s": [200, 100]}
                ]
            },
            "r": {"a": 0, "k": 0},
            "d": 1
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)
        let animPath = ShapePathExtractor.extractAnimPath(from: [shape])

        XCTAssertNotNil(animPath, "AnimPath should be extracted from animated rectangle")
        guard let extractedAnimPath = animPath else { return }

        // Verify it's keyframed
        if case .keyframedBezier(let keyframes) = extractedAnimPath {
            XCTAssertEqual(keyframes.count, 2, "Should have 2 keyframes")

            // Sample at frame 0: width should be 100 (AABB -50 to 50)
            let path0 = extractedAnimPath.sample(frame: 0)
            XCTAssertNotNil(path0)
            if let p0 = path0 {
                let aabb0 = p0.aabb
                XCTAssertEqual(aabb0.maxX - aabb0.minX, 100, accuracy: 0.001, "Width at t=0 should be 100")
            }

            // Sample at frame 10: width should be 200 (AABB -100 to 100)
            let path10 = extractedAnimPath.sample(frame: 10)
            XCTAssertNotNil(path10)
            if let p10 = path10 {
                let aabb10 = p10.aabb
                XCTAssertEqual(aabb10.maxX - aabb10.minX, 200, accuracy: 0.001, "Width at t=10 should be 200")
            }
        } else {
            XCTFail("Expected keyframedBezier, got static")
        }
    }

    /// Test rectangle inside group with transform
    /// Group contains rc + tr with translation
    /// Verifies group transform is applied to rectangle path
    func testRect_insideGroupWithTransform() throws {
        let json = """
        {
            "ty": "gr",
            "nm": "Group with Rectangle",
            "it": [
                {
                    "ty": "rc",
                    "nm": "Rectangle",
                    "p": {"a": 0, "k": [0, 0]},
                    "s": {"a": 0, "k": [100, 100]},
                    "r": {"a": 0, "k": 0},
                    "d": 1
                },
                {
                    "ty": "fl",
                    "c": {"a": 0, "k": [1, 0, 0, 1]}
                },
                {
                    "ty": "tr",
                    "p": {"a": 0, "k": [50, 100]},
                    "a": {"a": 0, "k": [0, 0]},
                    "s": {"a": 0, "k": [100, 100]},
                    "r": {"a": 0, "k": 0}
                }
            ]
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)
        let path = ShapePathExtractor.extractPath(from: [shape])

        XCTAssertNotNil(path, "Path should be extracted from group containing rectangle")
        guard let extractedPath = path else { return }

        let epsilon = 0.001

        // Original rectangle: center (0,0), size 100x100
        // AABB before transform: (-50, -50) to (50, 50)
        // After translation by (50, 100): (0, 50) to (100, 150)
        let aabb = extractedPath.aabb
        XCTAssertEqual(aabb.minX, 0, accuracy: epsilon, "minX after translation should be 0")
        XCTAssertEqual(aabb.maxX, 100, accuracy: epsilon, "maxX after translation should be 100")
        XCTAssertEqual(aabb.minY, 50, accuracy: epsilon, "minY after translation should be 50")
        XCTAssertEqual(aabb.maxY, 150, accuracy: epsilon, "maxY after translation should be 150")
    }

    /// Test rectangle with counter-clockwise direction (d=2)
    func testRect_counterClockwiseDirection() throws {
        let json = """
        {
            "ty": "rc",
            "nm": "CCW Rectangle",
            "p": {"a": 0, "k": [0, 0]},
            "s": {"a": 0, "k": [100, 100]},
            "r": {"a": 0, "k": 0},
            "d": 2
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)
        let path = ShapePathExtractor.extractPath(from: [shape])

        XCTAssertNotNil(path, "Path should be extracted from CCW rectangle")
        guard let extractedPath = path else { return }

        // AABB should be the same regardless of direction
        let epsilon = 0.001
        let aabb = extractedPath.aabb
        XCTAssertEqual(aabb.minX, -50, accuracy: epsilon)
        XCTAssertEqual(aabb.maxX, 50, accuracy: epsilon)
        XCTAssertEqual(aabb.minY, -50, accuracy: epsilon)
        XCTAssertEqual(aabb.maxY, 50, accuracy: epsilon)

        // Vertex count should still be 4
        XCTAssertEqual(extractedPath.vertexCount, 4)
    }

    /// Test rectangle roundness is clamped to valid range
    /// When r > min(w/2, h/2), it should be clamped
    func testRect_roundnessClampedToValidRange() throws {
        let json = """
        {
            "ty": "rc",
            "nm": "Over-rounded Rectangle",
            "p": {"a": 0, "k": [0, 0]},
            "s": {"a": 0, "k": [100, 50]},
            "r": {"a": 0, "k": 100},
            "d": 1
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)
        let path = ShapePathExtractor.extractPath(from: [shape])

        XCTAssertNotNil(path, "Path should be extracted from over-rounded rectangle")
        guard let extractedPath = path else { return }

        // Should still have 8 vertices (rounded)
        XCTAssertEqual(extractedPath.vertexCount, 8, "Should have 8 vertices for rounded corners")

        // AABB should match original bounds (clamped radius doesn't extend past edges)
        let epsilon = 0.001
        let aabb = extractedPath.aabb
        XCTAssertEqual(aabb.minX, -50, accuracy: epsilon)
        XCTAssertEqual(aabb.maxX, 50, accuracy: epsilon)
        XCTAssertEqual(aabb.minY, -25, accuracy: epsilon)
        XCTAssertEqual(aabb.maxY, 25, accuracy: epsilon)
    }

    /// Test that extractAnimPath returns static for non-animated rectangle
    func testRect_extractAnimPath_staticReturnsStaticBezier() throws {
        let json = """
        {
            "ty": "rc",
            "nm": "Static Rectangle",
            "p": {"a": 0, "k": [0, 0]},
            "s": {"a": 0, "k": [100, 100]},
            "r": {"a": 0, "k": 0},
            "d": 1
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)
        let animPath = ShapePathExtractor.extractAnimPath(from: [shape])

        XCTAssertNotNil(animPath)
        guard let extractedAnimPath = animPath else { return }

        if case .staticBezier(let bezier) = extractedAnimPath {
            XCTAssertEqual(bezier.vertexCount, 4)
            XCTAssertFalse(extractedAnimPath.isAnimated)
        } else {
            XCTFail("Expected staticBezier for non-animated rectangle")
        }
    }

    // MARK: - Rectangle Keyframe Mismatch Tests (PR-07 Fix)

    /// Test that animated p and s with different keyframe counts returns nil (fail-fast)
    func testRect_animatedPAndS_differentKeyframeCounts_returnsNil() throws {
        // p has 2 keyframes, s has 3 keyframes - must fail
        let json = """
        {
            "ty": "rc",
            "nm": "Mismatched Keyframe Count Rectangle",
            "p": {
                "a": 1,
                "k": [
                    {"t": 0, "s": [0, 0]},
                    {"t": 10, "s": [50, 50]}
                ]
            },
            "s": {
                "a": 1,
                "k": [
                    {"t": 0, "s": [100, 100]},
                    {"t": 5, "s": [150, 150]},
                    {"t": 10, "s": [200, 200]}
                ]
            },
            "r": {"a": 0, "k": 0},
            "d": 1
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)
        let animPath = ShapePathExtractor.extractAnimPath(from: [shape])

        XCTAssertNil(animPath, "extractAnimPath should return nil when p and s have different keyframe counts")
    }

    /// Test that animated p and s with same count but different times returns nil (fail-fast)
    func testRect_animatedPAndS_differentKeyframeTimes_returnsNil() throws {
        // p and s both have 2 keyframes, but times don't match
        let json = """
        {
            "ty": "rc",
            "nm": "Mismatched Keyframe Times Rectangle",
            "p": {
                "a": 1,
                "k": [
                    {"t": 0, "s": [0, 0]},
                    {"t": 10, "s": [50, 50]}
                ]
            },
            "s": {
                "a": 1,
                "k": [
                    {"t": 0, "s": [100, 100]},
                    {"t": 15, "s": [200, 200]}
                ]
            },
            "r": {"a": 0, "k": 0},
            "d": 1
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)
        let animPath = ShapePathExtractor.extractAnimPath(from: [shape])

        XCTAssertNil(animPath, "extractAnimPath should return nil when p and s have different keyframe times")
    }

    /// Test that keyframe with missing startValue returns nil (fail-fast)
    func testRect_keyframeWithMissingStartValue_returnsNil() throws {
        // Size keyframe at t=10 has no startValue ("s" field)
        let json = """
        {
            "ty": "rc",
            "nm": "Missing StartValue Rectangle",
            "p": {"a": 0, "k": [0, 0]},
            "s": {
                "a": 1,
                "k": [
                    {"t": 0, "s": [100, 100]},
                    {"t": 10}
                ]
            },
            "r": {"a": 0, "k": 0},
            "d": 1
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)
        let animPath = ShapePathExtractor.extractAnimPath(from: [shape])

        XCTAssertNil(animPath, "extractAnimPath should return nil when keyframe is missing startValue")
    }

    /// Test that animated p with static s works correctly (no mismatch validation needed)
    func testRect_animatedP_staticS_works() throws {
        let json = """
        {
            "ty": "rc",
            "nm": "Animated Position Only Rectangle",
            "p": {
                "a": 1,
                "k": [
                    {"t": 0, "s": [0, 0]},
                    {"t": 10, "s": [50, 50]}
                ]
            },
            "s": {"a": 0, "k": [100, 100]},
            "r": {"a": 0, "k": 0},
            "d": 1
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)
        let animPath = ShapePathExtractor.extractAnimPath(from: [shape])

        XCTAssertNotNil(animPath, "extractAnimPath should work when only p is animated")

        if case .keyframedBezier(let keyframes) = animPath {
            XCTAssertEqual(keyframes.count, 2)
        } else {
            XCTFail("Expected keyframedBezier")
        }
    }

    /// Test that animated p and s with matching keyframes works correctly
    func testRect_animatedPAndS_matchingKeyframes_works() throws {
        let json = """
        {
            "ty": "rc",
            "nm": "Matching Keyframes Rectangle",
            "p": {
                "a": 1,
                "k": [
                    {"t": 0, "s": [0, 0]},
                    {"t": 10, "s": [50, 50]}
                ]
            },
            "s": {
                "a": 1,
                "k": [
                    {"t": 0, "s": [100, 100]},
                    {"t": 10, "s": [200, 200]}
                ]
            },
            "r": {"a": 0, "k": 0},
            "d": 1
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)
        let animPath = ShapePathExtractor.extractAnimPath(from: [shape])

        XCTAssertNotNil(animPath, "extractAnimPath should work when p and s have matching keyframes")

        if case .keyframedBezier(let keyframes) = animPath {
            XCTAssertEqual(keyframes.count, 2)

            // Sample at frame 0: p=(0,0), s=(100,100) -> AABB (-50,-50) to (50,50)
            let path0 = animPath?.sample(frame: 0)
            XCTAssertNotNil(path0)
            if let p0 = path0 {
                let aabb0 = p0.aabb
                XCTAssertEqual(aabb0.minX, -50, accuracy: 0.001)
                XCTAssertEqual(aabb0.maxX, 50, accuracy: 0.001)
            }

            // Sample at frame 10: p=(50,50), s=(200,200) -> AABB (-50,-50) to (150,150)
            let path10 = animPath?.sample(frame: 10)
            XCTAssertNotNil(path10)
            if let p10 = path10 {
                let aabb10 = p10.aabb
                XCTAssertEqual(aabb10.minX, -50, accuracy: 0.001)
                XCTAssertEqual(aabb10.maxX, 150, accuracy: 0.001)
            }
        } else {
            XCTFail("Expected keyframedBezier")
        }
    }

    // MARK: - Ellipse Shape (el) Tests - PR-08

    /// Test static circle (w=h) - 4 vertices with cubic tangents
    /// ellipse: p=[0,0], s=[100,100], d=1 (clockwise)
    /// Expected AABB: minX=-50, maxX=50, minY=-50, maxY=50
    /// Expected vertex count: 4
    func testEllipse_staticCircle_builds4VerticesClosed() throws {
        let json = """
        {
            "ty": "el",
            "nm": "Circle 1",
            "p": {"a": 0, "k": [0, 0]},
            "s": {"a": 0, "k": [100, 100]},
            "d": 1
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)
        let path = ShapePathExtractor.extractPath(from: [shape])

        XCTAssertNotNil(path, "Path should be extracted from ellipse")
        guard let extractedPath = path else { return }

        let epsilon = 0.001

        // Verify vertex count - ellipse always has 4 vertices
        XCTAssertEqual(extractedPath.vertexCount, 4, "Ellipse should have 4 vertices")

        // Verify AABB
        let aabb = extractedPath.aabb
        XCTAssertEqual(aabb.minX, -50, accuracy: epsilon, "minX should be -50 (cx - rx)")
        XCTAssertEqual(aabb.maxX, 50, accuracy: epsilon, "maxX should be 50 (cx + rx)")
        XCTAssertEqual(aabb.minY, -50, accuracy: epsilon, "minY should be -50 (cy - ry)")
        XCTAssertEqual(aabb.maxY, 50, accuracy: epsilon, "maxY should be 50 (cy + ry)")

        // Verify closed path
        XCTAssertTrue(extractedPath.closed, "Ellipse path should be closed")

        // Verify tangent arrays have correct count
        XCTAssertEqual(extractedPath.inTangents.count, 4, "Should have 4 in tangents")
        XCTAssertEqual(extractedPath.outTangents.count, 4, "Should have 4 out tangents")

        // Verify tangents are non-zero (cubic bezier for circle)
        let hasNonZeroTangents = extractedPath.inTangents.contains { $0.x != 0 || $0.y != 0 }
        XCTAssertTrue(hasNonZeroTangents, "Ellipse should have non-zero tangents for cubic bezier arcs")
    }

    /// Test static ellipse (w != h) with correct AABB
    /// ellipse: p=[0,0], s=[200,100], d=1
    /// Expected AABB: minX=-100, maxX=100, minY=-50, maxY=50
    func testEllipse_staticEllipse_buildsCorrectAABB() throws {
        let json = """
        {
            "ty": "el",
            "nm": "Ellipse 1",
            "p": {"a": 0, "k": [0, 0]},
            "s": {"a": 0, "k": [200, 100]},
            "d": 1
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)
        let path = ShapePathExtractor.extractPath(from: [shape])

        XCTAssertNotNil(path, "Path should be extracted from ellipse")
        guard let extractedPath = path else { return }

        let epsilon = 0.001
        let aabb = extractedPath.aabb

        // rx = 200/2 = 100, ry = 100/2 = 50
        XCTAssertEqual(aabb.minX, -100, accuracy: epsilon, "minX should be -100 (cx - rx)")
        XCTAssertEqual(aabb.maxX, 100, accuracy: epsilon, "maxX should be 100 (cx + rx)")
        XCTAssertEqual(aabb.minY, -50, accuracy: epsilon, "minY should be -50 (cy - ry)")
        XCTAssertEqual(aabb.maxY, 50, accuracy: epsilon, "maxY should be 50 (cy + ry)")
    }

    /// Test counter-clockwise direction (d=2)
    /// Should produce same AABB but reversed vertex order
    func testEllipse_directionCCW_reversesCorrectly() throws {
        let jsonCW = """
        {
            "ty": "el",
            "nm": "Ellipse CW",
            "p": {"a": 0, "k": [0, 0]},
            "s": {"a": 0, "k": [100, 100]},
            "d": 1
        }
        """

        let jsonCCW = """
        {
            "ty": "el",
            "nm": "Ellipse CCW",
            "p": {"a": 0, "k": [0, 0]},
            "s": {"a": 0, "k": [100, 100]},
            "d": 2
        }
        """

        let dataCW = jsonCW.data(using: .utf8)!
        let shapeCW = try JSONDecoder().decode(ShapeItem.self, from: dataCW)
        let pathCW = ShapePathExtractor.extractPath(from: [shapeCW])

        let dataCCW = jsonCCW.data(using: .utf8)!
        let shapeCCW = try JSONDecoder().decode(ShapeItem.self, from: dataCCW)
        let pathCCW = ShapePathExtractor.extractPath(from: [shapeCCW])

        XCTAssertNotNil(pathCW, "CW path should be extracted")
        XCTAssertNotNil(pathCCW, "CCW path should be extracted")

        guard let cw = pathCW, let ccw = pathCCW else { return }

        // Both should have same vertex count
        XCTAssertEqual(cw.vertexCount, ccw.vertexCount, "Both should have 4 vertices")

        // Both should have same AABB
        let epsilon = 0.001
        XCTAssertEqual(cw.aabb.minX, ccw.aabb.minX, accuracy: epsilon)
        XCTAssertEqual(cw.aabb.maxX, ccw.aabb.maxX, accuracy: epsilon)
        XCTAssertEqual(cw.aabb.minY, ccw.aabb.minY, accuracy: epsilon)
        XCTAssertEqual(cw.aabb.maxY, ccw.aabb.maxY, accuracy: epsilon)

        // Verify CCW has reversed vertex order (first vertex of CW should be last of CCW)
        // CW: top(0), right(1), bottom(2), left(3)
        // CCW reversed: left(0), bottom(1), right(2), top(3)
        XCTAssertEqual(cw.vertices[0].x, ccw.vertices[3].x, accuracy: epsilon, "CW top should be CCW last")
        XCTAssertEqual(cw.vertices[0].y, ccw.vertices[3].y, accuracy: epsilon)
    }

    /// Test ellipse inside group with transform
    /// group: translation (100, 50)
    /// ellipse: p=[0,0], s=[100,100]
    /// Expected AABB: minX=50, maxX=150, minY=0, maxY=100
    func testEllipse_insideGroupWithTransform_appliesMatrix() throws {
        let json = """
        {
            "ty": "gr",
            "nm": "Group 1",
            "it": [
                {
                    "ty": "el",
                    "nm": "Ellipse 1",
                    "p": {"a": 0, "k": [0, 0]},
                    "s": {"a": 0, "k": [100, 100]},
                    "d": 1
                },
                {
                    "ty": "tr",
                    "p": {"a": 0, "k": [100, 50]},
                    "a": {"a": 0, "k": [0, 0]},
                    "s": {"a": 0, "k": [100, 100]},
                    "r": {"a": 0, "k": 0}
                }
            ]
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)
        let path = ShapePathExtractor.extractPath(from: [shape])

        XCTAssertNotNil(path, "Path should be extracted from ellipse in group")
        guard let extractedPath = path else { return }

        let epsilon = 0.001
        let aabb = extractedPath.aabb

        // Original: AABB (-50,-50) to (50,50)
        // After translation (100,50): AABB (50, 0) to (150, 100)
        XCTAssertEqual(aabb.minX, 50, accuracy: epsilon, "minX should be 50 after translation")
        XCTAssertEqual(aabb.maxX, 150, accuracy: epsilon, "maxX should be 150 after translation")
        XCTAssertEqual(aabb.minY, 0, accuracy: epsilon, "minY should be 0 after translation")
        XCTAssertEqual(aabb.maxY, 100, accuracy: epsilon, "maxY should be 100 after translation")
    }

    /// Test animated ellipse size
    /// s: keyframes at t=0 [100,100], t=10 [200,100]
    /// p: static [0,0]
    /// Expected: keyframedBezier with 2 keyframes
    func testEllipse_animatedSize_buildsKeyframedAnimPath() throws {
        let json = """
        {
            "ty": "el",
            "nm": "Animated Size Ellipse",
            "p": {"a": 0, "k": [0, 0]},
            "s": {
                "a": 1,
                "k": [
                    {"t": 0, "s": [100, 100]},
                    {"t": 10, "s": [200, 100]}
                ]
            },
            "d": 1
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)
        let animPath = ShapePathExtractor.extractAnimPath(from: [shape])

        XCTAssertNotNil(animPath, "AnimPath should be extracted from animated ellipse")

        if case .keyframedBezier(let keyframes) = animPath {
            XCTAssertEqual(keyframes.count, 2, "Should have 2 keyframes")

            // Frame 0: s=[100,100], AABB (-50,-50) to (50,50)
            let path0 = animPath?.sample(frame: 0)
            XCTAssertNotNil(path0)
            if let p0 = path0 {
                let aabb = p0.aabb
                XCTAssertEqual(aabb.minX, -50, accuracy: 0.001)
                XCTAssertEqual(aabb.maxX, 50, accuracy: 0.001)
            }

            // Frame 10: s=[200,100], AABB (-100,-50) to (100,50)
            let path10 = animPath?.sample(frame: 10)
            XCTAssertNotNil(path10)
            if let p10 = path10 {
                let aabb = p10.aabb
                XCTAssertEqual(aabb.minX, -100, accuracy: 0.001)
                XCTAssertEqual(aabb.maxX, 100, accuracy: 0.001)
            }
        } else {
            XCTFail("Expected keyframedBezier")
        }
    }

    /// Test animated ellipse position
    /// p: keyframes at t=0 [0,0], t=10 [100,0]
    /// s: static [100,100]
    /// Expected: keyframedBezier with 2 keyframes
    func testEllipse_animatedPosition_buildsKeyframedAnimPath() throws {
        let json = """
        {
            "ty": "el",
            "nm": "Animated Position Ellipse",
            "p": {
                "a": 1,
                "k": [
                    {"t": 0, "s": [0, 0]},
                    {"t": 10, "s": [100, 0]}
                ]
            },
            "s": {"a": 0, "k": [100, 100]},
            "d": 1
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)
        let animPath = ShapePathExtractor.extractAnimPath(from: [shape])

        XCTAssertNotNil(animPath, "AnimPath should be extracted from animated ellipse")

        if case .keyframedBezier(let keyframes) = animPath {
            XCTAssertEqual(keyframes.count, 2, "Should have 2 keyframes")

            // Frame 0: p=[0,0], AABB (-50,-50) to (50,50)
            let path0 = animPath?.sample(frame: 0)
            XCTAssertNotNil(path0)
            if let p0 = path0 {
                let aabb = p0.aabb
                XCTAssertEqual(aabb.minX, -50, accuracy: 0.001)
                XCTAssertEqual(aabb.maxX, 50, accuracy: 0.001)
            }

            // Frame 10: p=[100,0], AABB (50,-50) to (150,50)
            let path10 = animPath?.sample(frame: 10)
            XCTAssertNotNil(path10)
            if let p10 = path10 {
                let aabb = p10.aabb
                XCTAssertEqual(aabb.minX, 50, accuracy: 0.001)
                XCTAssertEqual(aabb.maxX, 150, accuracy: 0.001)
            }
        } else {
            XCTFail("Expected keyframedBezier")
        }
    }

    /// Test animated p and s with matching keyframe times
    func testEllipse_animatedPAndS_matchingTimes_buildsKeyframedAnimPath() throws {
        let json = """
        {
            "ty": "el",
            "nm": "Animated P and S Ellipse",
            "p": {
                "a": 1,
                "k": [
                    {"t": 0, "s": [0, 0]},
                    {"t": 10, "s": [50, 50]}
                ]
            },
            "s": {
                "a": 1,
                "k": [
                    {"t": 0, "s": [100, 100]},
                    {"t": 10, "s": [200, 200]}
                ]
            },
            "d": 1
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)
        let animPath = ShapePathExtractor.extractAnimPath(from: [shape])

        XCTAssertNotNil(animPath, "AnimPath should be extracted when p and s have matching keyframe times")

        if case .keyframedBezier(let keyframes) = animPath {
            XCTAssertEqual(keyframes.count, 2, "Should have 2 keyframes")
        } else {
            XCTFail("Expected keyframedBezier")
        }
    }

    /// Test animated p and s with different keyframe counts - should return nil
    func testEllipse_animatedPAndS_differentKeyframeCounts_returnsNil() throws {
        let json = """
        {
            "ty": "el",
            "nm": "Mismatched Keyframe Counts Ellipse",
            "p": {
                "a": 1,
                "k": [
                    {"t": 0, "s": [0, 0]},
                    {"t": 10, "s": [50, 50]}
                ]
            },
            "s": {
                "a": 1,
                "k": [
                    {"t": 0, "s": [100, 100]},
                    {"t": 5, "s": [150, 150]},
                    {"t": 10, "s": [200, 200]}
                ]
            },
            "d": 1
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)
        let animPath = ShapePathExtractor.extractAnimPath(from: [shape])

        XCTAssertNil(animPath, "extractAnimPath should return nil when p and s have different keyframe counts")
    }

    /// Test animated p and s with different keyframe times - should return nil
    func testEllipse_animatedPAndS_differentKeyframeTimes_returnsNil() throws {
        let json = """
        {
            "ty": "el",
            "nm": "Mismatched Keyframe Times Ellipse",
            "p": {
                "a": 1,
                "k": [
                    {"t": 0, "s": [0, 0]},
                    {"t": 10, "s": [50, 50]}
                ]
            },
            "s": {
                "a": 1,
                "k": [
                    {"t": 0, "s": [100, 100]},
                    {"t": 15, "s": [200, 200]}
                ]
            },
            "d": 1
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)
        let animPath = ShapePathExtractor.extractAnimPath(from: [shape])

        XCTAssertNil(animPath, "extractAnimPath should return nil when p and s have different keyframe times")
    }

    /// Test keyframe missing startValue - should return nil
    func testEllipse_keyframeMissingStartValue_returnsNil() throws {
        let json = """
        {
            "ty": "el",
            "nm": "Missing StartValue Ellipse",
            "p": {"a": 0, "k": [0, 0]},
            "s": {
                "a": 1,
                "k": [
                    {"t": 0, "s": [100, 100]},
                    {"t": 10}
                ]
            },
            "d": 1
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)
        let animPath = ShapePathExtractor.extractAnimPath(from: [shape])

        XCTAssertNil(animPath, "extractAnimPath should return nil when keyframe is missing startValue")
    }

    /// Test static ellipse with zero width - should return nil
    func testEllipse_staticSizeZeroWidth_returnsNil() throws {
        let json = """
        {
            "ty": "el",
            "nm": "Zero Width Ellipse",
            "p": {"a": 0, "k": [0, 0]},
            "s": {"a": 0, "k": [0, 100]},
            "d": 1
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)
        let path = ShapePathExtractor.extractPath(from: [shape])

        XCTAssertNil(path, "extractPath should return nil when ellipse width is 0")
    }

    /// Test static ellipse with zero height - should return nil
    func testEllipse_staticSizeZeroHeight_returnsNil() throws {
        let json = """
        {
            "ty": "el",
            "nm": "Zero Height Ellipse",
            "p": {"a": 0, "k": [0, 0]},
            "s": {"a": 0, "k": [100, 0]},
            "d": 1
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)
        let path = ShapePathExtractor.extractPath(from: [shape])

        XCTAssertNil(path, "extractPath should return nil when ellipse height is 0")
    }

    /// Test static ellipse returns staticBezier via extractAnimPath
    func testEllipse_extractAnimPath_staticReturnsStaticBezier() throws {
        let json = """
        {
            "ty": "el",
            "nm": "Static Ellipse",
            "p": {"a": 0, "k": [0, 0]},
            "s": {"a": 0, "k": [100, 100]},
            "d": 1
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)
        let animPath = ShapePathExtractor.extractAnimPath(from: [shape])

        XCTAssertNotNil(animPath, "AnimPath should be extracted from static ellipse")

        if case .staticBezier(let bezier) = animPath {
            XCTAssertEqual(bezier.vertexCount, 4, "Static ellipse should have 4 vertices")
            XCTAssertTrue(bezier.closed, "Ellipse should be closed")
        } else {
            XCTFail("Expected staticBezier for static ellipse")
        }
    }
}
