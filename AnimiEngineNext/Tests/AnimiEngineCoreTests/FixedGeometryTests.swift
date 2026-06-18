import XCTest
@testable import AnimiEngineCore

/// Fixed-point geometry tests (Task-002 plan, §18 "Geometry").
final class FixedGeometryTests: XCTestCase {

    func testExactUnits() throws {
        XCTAssertEqual(CanvasScalar.unitsPerPoint, 65_536)
        XCTAssertEqual(ScaleScalar.unitsPerUnit, 1_000_000)
        XCTAssertEqual(RotationScalar.unitsPerDegree, 1_000)
        XCTAssertEqual(try CanvasScalar(points: 2).rawValue, 131_072)
        XCTAssertEqual(ScaleScalar.one.rawValue, 1_000_000)
    }

    func testInvalidSizesAndScalesReject() {
        XCTAssertThrowsError(try FixedRect(
            x: CanvasScalar(rawValue: 0), y: CanvasScalar(rawValue: 0),
            width: CanvasScalar(rawValue: 0), height: CanvasScalar(rawValue: 100)
        ))
        XCTAssertThrowsError(try FixedRect(
            x: CanvasScalar(rawValue: 0), y: CanvasScalar(rawValue: 0),
            width: CanvasScalar(rawValue: 100), height: CanvasScalar(rawValue: -1)
        ))
        XCTAssertThrowsError(try ScaleScalar(positiveRawValue: 0))
        // Placement rejects non-positive scale.
        let frame = try! FixedRect(
            x: CanvasScalar(rawValue: 0), y: CanvasScalar(rawValue: 0),
            width: CanvasScalar(rawValue: 100), height: CanvasScalar(rawValue: 100)
        )
        XCTAssertThrowsError(try Placement(frame: frame, scale: ScaleScalar(rawValue: 0), rotation: .zero))
    }

    func testCheckedOverflowRejects() {
        XCTAssertThrowsError(try CanvasScalar(points: Int64.max))
        XCTAssertThrowsError(try CanvasScalar(rawValue: Int64.max).adding(CanvasScalar(rawValue: 1)))
    }

    func testCanonicalRoundTripPreservesRawValues() throws {
        // Raw values are preserved verbatim through construction (no float path).
        let x = CanvasScalar(rawValue: 123_456_789)
        let rect = try FixedRect(
            x: x, y: CanvasScalar(rawValue: -42),
            width: CanvasScalar(rawValue: 65_536), height: CanvasScalar(rawValue: 65_536)
        )
        XCTAssertEqual(rect.x.rawValue, 123_456_789)
        XCTAssertEqual(rect.y.rawValue, -42)
        let placement = try Placement(frame: rect, scale: ScaleScalar(rawValue: 2_500_000), rotation: RotationScalar(rawValue: 90_000))
        XCTAssertEqual(placement.scale.rawValue, 2_500_000)
        XCTAssertEqual(placement.rotation.rawValue, 90_000)
    }
}
