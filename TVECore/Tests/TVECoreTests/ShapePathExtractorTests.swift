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
}
