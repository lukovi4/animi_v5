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
        let unknownTypes = ["st", "gs", "gf", "rd", "tm", "mm", "rp", "sr", "el", "rc"]

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
