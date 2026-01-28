import XCTest
@testable import TVECore

/// Tests for ShapeItem decoding with overloaded "r" field
/// - Fill shapes: "r" is Int (fill rule: 1=non-zero, 2=even-odd)
/// - Transform shapes: "r" is LottieAnimatedValue (rotation)
final class ShapeItemDecodeTests: XCTestCase {

    // MARK: - Fill Shape (ty="fl")

    func testFillShape_decodesWithIntFillRule() throws {
        let json = """
        {
            "ty": "fl",
            "nm": "Fill 1",
            "c": {"a": 0, "k": [1, 0, 0, 1]},
            "o": {"a": 0, "k": 100},
            "r": 1
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)

        guard case .fill(let fill) = shape else {
            XCTFail("Expected .fill case, got \(shape)")
            return
        }

        XCTAssertEqual(fill.fillRule, 1, "Fill rule should be 1 (non-zero)")
        XCTAssertNotNil(fill.color, "Color should be present")
        XCTAssertNotNil(fill.opacity, "Opacity should be present")
    }

    func testFillShape_decodesEvenOddFillRule() throws {
        let json = """
        {
            "ty": "fl",
            "r": 2
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)

        guard case .fill(let fill) = shape else {
            XCTFail("Expected .fill case, got \(shape)")
            return
        }

        XCTAssertEqual(fill.fillRule, 2, "Fill rule should be 2 (even-odd)")
    }

    func testFillShape_decodesWithoutFillRule() throws {
        let json = """
        {
            "ty": "fl",
            "c": {"a": 0, "k": [0, 1, 0, 1]}
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)

        guard case .fill(let fill) = shape else {
            XCTFail("Expected .fill case, got \(shape)")
            return
        }

        XCTAssertNil(fill.fillRule, "Fill rule should be nil when not present")
    }

    // MARK: - Transform Shape (ty="tr")

    func testTransformShape_decodesWithAnimatedRotation() throws {
        let json = """
        {
            "ty": "tr",
            "nm": "Transform",
            "p": {"a": 0, "k": [0, 0]},
            "a": {"a": 0, "k": [0, 0]},
            "s": {"a": 0, "k": [100, 100]},
            "r": {"a": 0, "k": 0},
            "o": {"a": 0, "k": 100}
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)

        guard case .transform(let transform) = shape else {
            XCTFail("Expected .transform case, got \(shape)")
            return
        }

        XCTAssertNotNil(transform.rotation, "Rotation should be present as animated value")
        XCTAssertNotNil(transform.position, "Position should be present")
        XCTAssertNotNil(transform.scale, "Scale should be present")
        XCTAssertNotNil(transform.opacity, "Opacity should be present")
    }

    func testTransformShape_decodesAnimatedRotation() throws {
        let json = """
        {
            "ty": "tr",
            "r": {"a": 1, "k": [{"t": 0, "s": [0]}, {"t": 30, "s": [360]}]}
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)

        guard case .transform(let transform) = shape else {
            XCTFail("Expected .transform case, got \(shape)")
            return
        }

        XCTAssertNotNil(transform.rotation, "Rotation should be present")
        XCTAssertEqual(transform.rotation?.isAnimated, true, "Rotation should be animated")
    }

    // MARK: - Path Shape (ty="sh")

    func testPathShape_decodes() throws {
        let json = """
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
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)

        guard case .path(let path) = shape else {
            XCTFail("Expected .path case, got \(shape)")
            return
        }

        XCTAssertNotNil(path.vertices, "Vertices should be present")
        XCTAssertEqual(path.name, "Path 1")
    }

    // MARK: - Group Shape (ty="gr")

    func testGroupShape_decodesWithNestedItems() throws {
        let json = """
        {
            "ty": "gr",
            "nm": "Group 1",
            "it": [
                {"ty": "sh", "nm": "Path"},
                {"ty": "fl", "r": 1},
                {"ty": "tr", "r": {"a": 0, "k": 0}}
            ]
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)

        guard case .group(let group) = shape else {
            XCTFail("Expected .group case, got \(shape)")
            return
        }

        XCTAssertEqual(group.name, "Group 1")
        XCTAssertEqual(group.items?.count, 3, "Group should have 3 items")

        // Verify nested items decoded correctly
        if let items = group.items {
            guard case .path = items[0] else {
                XCTFail("First item should be path")
                return
            }
            guard case .fill(let fill) = items[1] else {
                XCTFail("Second item should be fill")
                return
            }
            XCTAssertEqual(fill.fillRule, 1)

            guard case .transform(let transform) = items[2] else {
                XCTFail("Third item should be transform")
                return
            }
            XCTAssertNotNil(transform.rotation)
        }
    }

    // MARK: - Rectangle Shape (ty="rc")

    func testRectShape_decodesWithStaticValues() throws {
        let json = """
        {
            "ty": "rc",
            "nm": "Rectangle 1",
            "mn": "ADBE Vector Shape - Rect",
            "hd": false,
            "ix": 1,
            "p": {"a": 0, "k": [100, 200]},
            "s": {"a": 0, "k": [300, 400]},
            "r": {"a": 0, "k": 12},
            "d": 1
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)

        guard case .rect(let rect) = shape else {
            XCTFail("Expected .rect case, got \(shape)")
            return
        }

        XCTAssertEqual(rect.type, "rc", "Type should be 'rc'")
        XCTAssertEqual(rect.name, "Rectangle 1")
        XCTAssertEqual(rect.matchName, "ADBE Vector Shape - Rect")
        XCTAssertEqual(rect.hidden, false)
        XCTAssertEqual(rect.index, 1)
        XCTAssertEqual(rect.direction, 1)

        // Verify position
        XCTAssertNotNil(rect.position, "Position should be present")
        XCTAssertEqual(rect.position?.isAnimated, false, "Position should be static")

        // Verify size
        XCTAssertNotNil(rect.size, "Size should be present")
        XCTAssertEqual(rect.size?.isAnimated, false, "Size should be static")

        // Verify roundness
        XCTAssertNotNil(rect.roundness, "Roundness should be present")
        XCTAssertEqual(rect.roundness?.isAnimated, false, "Roundness should be static")
    }

    func testRectShape_decodesWithAnimatedRoundness() throws {
        let json = """
        {
            "ty": "rc",
            "nm": "Animated Rect",
            "p": {"a": 0, "k": [50, 50]},
            "s": {"a": 0, "k": [100, 100]},
            "r": {"a": 1, "k": [{"t": 0, "s": [0]}, {"t": 30, "s": [20]}]}
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)

        guard case .rect(let rect) = shape else {
            XCTFail("Expected .rect case, got \(shape)")
            return
        }

        XCTAssertEqual(rect.type, "rc")
        XCTAssertNotNil(rect.roundness, "Roundness should be present")
        XCTAssertEqual(rect.roundness?.isAnimated, true, "Roundness should be animated (a=1)")
    }

    func testRectShape_decodesMinimalFields() throws {
        // Minimal rc - only type is required
        let json = """
        {
            "ty": "rc"
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)

        guard case .rect(let rect) = shape else {
            XCTFail("Expected .rect case, got \(shape)")
            return
        }

        XCTAssertEqual(rect.type, "rc")
        XCTAssertNil(rect.name)
        XCTAssertNil(rect.position)
        XCTAssertNil(rect.size)
        XCTAssertNil(rect.roundness)
    }

    func testRectShape_rFieldIsRoundness_notFillRule() throws {
        // Critical: verify "r" is decoded as roundness (LottieAnimatedValue), not fillRule (Int)
        let json = """
        {
            "ty": "rc",
            "r": {"a": 0, "k": 15}
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)

        guard case .rect(let rect) = shape else {
            XCTFail("Expected .rect case, got \(shape)")
            return
        }

        // "r" should be decoded as roundness (LottieAnimatedValue), not as Int
        XCTAssertNotNil(rect.roundness, "Roundness should be decoded from 'r' field")

        // Verify the value is correct
        if let value = rect.roundness?.value, case .number(let num) = value {
            XCTAssertEqual(num, 15, "Roundness value should be 15")
        } else {
            XCTFail("Roundness should have numeric value")
        }
    }

    // MARK: - Ellipse Shape (ty="el")

    func testEllipseShape_decodesWithStaticValues() throws {
        let json = """
        {
            "ty": "el",
            "nm": "Ellipse 1",
            "mn": "ADBE Vector Shape - Ellipse",
            "hd": false,
            "ix": 1,
            "p": {"a": 0, "k": [100, 200]},
            "s": {"a": 0, "k": [300, 400]},
            "d": 1
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)

        guard case .ellipse(let ellipse) = shape else {
            XCTFail("Expected .ellipse case, got \(shape)")
            return
        }

        XCTAssertEqual(ellipse.type, "el", "Type should be 'el'")
        XCTAssertEqual(ellipse.name, "Ellipse 1")
        XCTAssertEqual(ellipse.matchName, "ADBE Vector Shape - Ellipse")
        XCTAssertEqual(ellipse.hidden, false)
        XCTAssertEqual(ellipse.index, 1)
        XCTAssertEqual(ellipse.direction, 1)

        // Verify position
        XCTAssertNotNil(ellipse.position, "Position should be present")
        XCTAssertEqual(ellipse.position?.isAnimated, false, "Position should be static")

        // Verify size
        XCTAssertNotNil(ellipse.size, "Size should be present")
        XCTAssertEqual(ellipse.size?.isAnimated, false, "Size should be static")
    }

    func testEllipseShape_decodesWithAnimatedPosition() throws {
        let json = """
        {
            "ty": "el",
            "nm": "Animated Ellipse",
            "p": {"a": 1, "k": [{"t": 0, "s": [0, 0]}, {"t": 30, "s": [100, 100]}]},
            "s": {"a": 0, "k": [50, 50]}
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)

        guard case .ellipse(let ellipse) = shape else {
            XCTFail("Expected .ellipse case, got \(shape)")
            return
        }

        XCTAssertEqual(ellipse.type, "el")
        XCTAssertNotNil(ellipse.position, "Position should be present")
        XCTAssertEqual(ellipse.position?.isAnimated, true, "Position should be animated (a=1)")
        XCTAssertEqual(ellipse.size?.isAnimated, false, "Size should be static")
    }

    func testEllipseShape_decodesMinimalFields() throws {
        // Minimal el - only type is required
        let json = """
        {
            "ty": "el"
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)

        guard case .ellipse(let ellipse) = shape else {
            XCTFail("Expected .ellipse case, got \(shape)")
            return
        }

        XCTAssertEqual(ellipse.type, "el")
        XCTAssertNil(ellipse.name)
        XCTAssertNil(ellipse.position)
        XCTAssertNil(ellipse.size)
        XCTAssertNil(ellipse.direction)
    }

    // MARK: - Polystar Shape (ty="sr")

    func testPolystarShape_decodesWithStaticValues() throws {
        let json = """
        {
            "ty": "sr",
            "nm": "Star 1",
            "mn": "ADBE Vector Shape - Star",
            "hd": false,
            "ix": 1,
            "sy": 1,
            "p": {"a": 0, "k": [100, 200]},
            "r": {"a": 0, "k": 0},
            "pt": {"a": 0, "k": 5},
            "ir": {"a": 0, "k": 40},
            "or": {"a": 0, "k": 80},
            "is": {"a": 0, "k": 0},
            "os": {"a": 0, "k": 0},
            "d": 1
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)

        guard case .polystar(let star) = shape else {
            XCTFail("Expected .polystar case, got \(shape)")
            return
        }

        XCTAssertEqual(star.type, "sr", "Type should be 'sr'")
        XCTAssertEqual(star.name, "Star 1")
        XCTAssertEqual(star.matchName, "ADBE Vector Shape - Star")
        XCTAssertEqual(star.hidden, false)
        XCTAssertEqual(star.index, 1)
        XCTAssertEqual(star.starType, 1, "Star type should be 1 (star)")
        XCTAssertEqual(star.direction, 1)

        // Verify key geometry fields are present
        XCTAssertNotNil(star.position, "Position should be present")
        XCTAssertNotNil(star.rotation, "Rotation should be present")
        XCTAssertNotNil(star.points, "Points should be present")
        XCTAssertNotNil(star.innerRadius, "Inner radius should be present")
        XCTAssertNotNil(star.outerRadius, "Outer radius should be present")
        XCTAssertNotNil(star.innerRoundness, "Inner roundness should be present")
        XCTAssertNotNil(star.outerRoundness, "Outer roundness should be present")

        // Verify static values
        XCTAssertEqual(star.position?.isAnimated, false)
        XCTAssertEqual(star.points?.isAnimated, false)
    }

    func testPolystarShape_decodesWithAnimatedPoints() throws {
        let json = """
        {
            "ty": "sr",
            "sy": 1,
            "pt": {"a": 1, "k": [{"t": 0, "s": [5]}, {"t": 30, "s": [8]}]},
            "or": {"a": 0, "k": 50}
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)

        guard case .polystar(let star) = shape else {
            XCTFail("Expected .polystar case, got \(shape)")
            return
        }

        XCTAssertEqual(star.type, "sr")
        XCTAssertNotNil(star.points, "Points should be present")
        XCTAssertEqual(star.points?.isAnimated, true, "Points should be animated (a=1)")
        XCTAssertEqual(star.outerRadius?.isAnimated, false, "Outer radius should be static")
    }

    func testPolystarShape_decodesMinimalFields() throws {
        // Minimal sr - only type is required
        let json = """
        {
            "ty": "sr",
            "pt": {"a": 0, "k": 6}
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)

        guard case .polystar(let star) = shape else {
            XCTFail("Expected .polystar case, got \(shape)")
            return
        }

        XCTAssertEqual(star.type, "sr")
        XCTAssertNil(star.name)
        XCTAssertNil(star.starType)
        XCTAssertNil(star.position)
        XCTAssertNotNil(star.points)
        XCTAssertNil(star.innerRadius)
        XCTAssertNil(star.outerRadius)
    }

    func testPolystarShape_polygonType() throws {
        // Polygon (sy=2) has no inner radius
        let json = """
        {
            "ty": "sr",
            "sy": 2,
            "pt": {"a": 0, "k": 6},
            "or": {"a": 0, "k": 100}
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)

        guard case .polystar(let star) = shape else {
            XCTFail("Expected .polystar case, got \(shape)")
            return
        }

        XCTAssertEqual(star.starType, 2, "Star type should be 2 (polygon)")
        XCTAssertNotNil(star.points)
        XCTAssertNotNil(star.outerRadius)
        XCTAssertNil(star.innerRadius, "Polygon typically has no inner radius")
    }

    // MARK: - Unknown Shape Types

    func testUnknownShape_decodesTolerantly() throws {
        let json = """
        {
            "ty": "st",
            "nm": "Stroke 1"
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)

        guard case .unknown(let type) = shape else {
            XCTFail("Expected .unknown case, got \(shape)")
            return
        }

        XCTAssertEqual(type, "st", "Unknown type should be 'st' (stroke)")
    }

    func testUnknownShape_multipleTypes() throws {
        // Note: "rc", "el", "sr" are no longer unknown - they're decoded as .rect, .ellipse, .polystar
        let unknownTypes = ["st", "gs", "gf", "rd", "tm", "mm", "rp"]

        for typeStr in unknownTypes {
            let json = "{\"ty\": \"\(typeStr)\"}"
            let data = json.data(using: .utf8)!
            let shape = try JSONDecoder().decode(ShapeItem.self, from: data)

            guard case .unknown(let type) = shape else {
                XCTFail("Expected .unknown case for '\(typeStr)', got \(shape)")
                continue
            }

            XCTAssertEqual(type, typeStr, "Unknown type should be '\(typeStr)'")
        }
    }

    // MARK: - Animated Path Keyframes (PR-A)

    /// Test that animated path keyframes are correctly decoded
    /// This is the fix for anim-3.json matte mask animation
    func testPathShape_decodesAnimatedKeyframes() throws {
        // Path with animated keyframes (like in anim-3.json matte mask)
        let json = """
        {
            "ty": "sh",
            "nm": "Path 1",
            "ks": {
                "a": 1,
                "k": [
                    {
                        "t": 60,
                        "s": [{"v": [[-10, -160], [-10, 480], [10, 160], [10, -480]], "i": [[0, 0], [0, 0], [0, 0], [0, 0]], "o": [[0, 0], [0, 0], [0, 0], [0, 0]], "c": true}],
                        "i": {"x": [0.833], "y": [0.833]},
                        "o": {"x": [0.167], "y": [0.167]}
                    },
                    {
                        "t": 90,
                        "s": [{"v": [[270, -160], [270, 480], [-270, 160], [-270, -480]], "i": [[0, 0], [0, 0], [0, 0], [0, 0]], "o": [[0, 0], [0, 0], [0, 0], [0, 0]], "c": true}]
                    }
                ]
            }
        }
        """

        let data = json.data(using: .utf8)!
        let shape = try JSONDecoder().decode(ShapeItem.self, from: data)

        guard case .path(let path) = shape else {
            XCTFail("Expected .path case, got \(shape)")
            return
        }

        XCTAssertNotNil(path.vertices, "Vertices (ks) should be present")
        XCTAssertEqual(path.vertices?.isAnimated, true, "Path should be animated (a=1)")

        // Verify keyframes are decoded
        guard let value = path.vertices?.value,
              case .keyframes(let keyframes) = value else {
            XCTFail("Expected keyframes in path.vertices")
            return
        }

        XCTAssertEqual(keyframes.count, 2, "Should have 2 keyframes")

        // Check first keyframe
        let kf1 = keyframes[0]
        XCTAssertEqual(kf1.time, 60, "First keyframe time should be 60")

        // Verify startValue is path data, not numbers
        guard case .path(let pathData1) = kf1.startValue else {
            XCTFail("First keyframe startValue should be .path, got \(String(describing: kf1.startValue))")
            return
        }
        XCTAssertEqual(pathData1.vertices?.count, 4, "Path should have 4 vertices")
        XCTAssertEqual(pathData1.closed, true, "Path should be closed")

        // Check second keyframe
        let kf2 = keyframes[1]
        XCTAssertEqual(kf2.time, 90, "Second keyframe time should be 90")

        guard case .path(let pathData2) = kf2.startValue else {
            XCTFail("Second keyframe startValue should be .path")
            return
        }
        XCTAssertEqual(pathData2.vertices?.count, 4, "Path should have 4 vertices")

        // Verify the path actually changed between keyframes
        if let v1 = pathData1.vertices?.first, let v2 = pathData2.vertices?.first {
            XCTAssertNotEqual(v1, v2, "Path vertices should be different between keyframes")
        }
    }

    /// Test that anim-3.json shape path keyframes decode correctly
    func testAnim3_shapePathKeyframes_decode() throws {
        // Load anim-3.json from resources
        guard let url = Bundle.module.url(
            forResource: "anim-3",
            withExtension: "json",
            subdirectory: "Resources"
        ) else {
            XCTFail("Could not find anim-3.json in Resources")
            return
        }

        let data = try Data(contentsOf: url)
        let lottie = try JSONDecoder().decode(LottieJSON.self, from: data)

        // Find the matte source layer (td=1)
        let matteLayers = lottie.layers.filter { $0.isMatteSource == 1 }
        guard let matteLayer = matteLayers.first else {
            XCTFail("Could not find matte source layer (td=1)")
            return
        }

        XCTAssertEqual(matteLayer.name, "img_1.3_mask", "Matte layer should be img_1.3_mask")
        XCTAssertEqual(matteLayer.type, 4, "Matte layer should be shape layer (ty=4)")

        // Get shapes
        guard let shapes = matteLayer.shapes, !shapes.isEmpty else {
            XCTFail("Matte layer should have shapes")
            return
        }

        // Find the group containing the path
        guard case .group(let group) = shapes[0],
              let items = group.items else {
            XCTFail("First shape should be a group with items")
            return
        }

        // Find the path item
        guard let pathItem = items.first(where: {
            if case .path = $0 { return true }
            return false
        }), case .path(let pathShape) = pathItem else {
            XCTFail("Group should contain a path shape")
            return
        }

        // Verify path is animated
        XCTAssertEqual(pathShape.vertices?.isAnimated, true, "Path should be animated")

        // Verify keyframes
        guard let value = pathShape.vertices?.value,
              case .keyframes(let keyframes) = value else {
            XCTFail("Path should have keyframes")
            return
        }

        XCTAssertEqual(keyframes.count, 2, "Should have 2 keyframes (frames 60 and 90)")
        XCTAssertEqual(keyframes[0].time, 60)
        XCTAssertEqual(keyframes[1].time, 90)

        // Verify both keyframes have path data
        for (index, kf) in keyframes.enumerated() {
            guard case .path(let pathData) = kf.startValue else {
                XCTFail("Keyframe \(index) should have path data in startValue")
                continue
            }
            XCTAssertEqual(pathData.vertices?.count, 4, "Keyframe \(index) path should have 4 vertices")
        }
    }

    /// Test that numeric keyframes still work (position, scale, etc.)
    func testNumericKeyframes_stillWork() throws {
        let json = """
        {
            "a": 1,
            "k": [
                {"t": 0, "s": [0, 0]},
                {"t": 30, "s": [100, 100]}
            ]
        }
        """

        let data = json.data(using: .utf8)!
        let animValue = try JSONDecoder().decode(LottieAnimatedValue.self, from: data)

        XCTAssertEqual(animValue.isAnimated, true)

        guard let value = animValue.value,
              case .keyframes(let keyframes) = value else {
            XCTFail("Should decode as keyframes")
            return
        }

        XCTAssertEqual(keyframes.count, 2)

        // Verify startValue is numbers, not path
        guard case .numbers(let nums) = keyframes[0].startValue else {
            XCTFail("Numeric keyframe should have .numbers startValue")
            return
        }
        XCTAssertEqual(nums, [0, 0])
    }

    // MARK: - Critical: Fill and Transform "r" Field Disambiguation

    /// This is the critical test that validates the fix for the 16 skipped tests.
    /// The "r" field is overloaded:
    /// - In fill (ty="fl"): "r" is Int (fill rule)
    /// - In transform (ty="tr"): "r" is LottieAnimatedValue (rotation)
    func testCritical_rFieldDisambiguation() throws {
        // Fill with "r" as Int
        let fillJson = """
        {"ty": "fl", "r": 1}
        """

        // Transform with "r" as object
        let transformJson = """
        {"ty": "tr", "r": {"a": 0, "k": 45}}
        """

        let fillData = fillJson.data(using: .utf8)!
        let transformData = transformJson.data(using: .utf8)!

        // Both should decode successfully
        let fillShape = try JSONDecoder().decode(ShapeItem.self, from: fillData)
        let transformShape = try JSONDecoder().decode(ShapeItem.self, from: transformData)

        // Verify fill
        guard case .fill(let fill) = fillShape else {
            XCTFail("Fill JSON should decode to .fill case")
            return
        }
        XCTAssertEqual(fill.fillRule, 1)

        // Verify transform
        guard case .transform(let transform) = transformShape else {
            XCTFail("Transform JSON should decode to .transform case")
            return
        }
        XCTAssertNotNil(transform.rotation)
    }
}
