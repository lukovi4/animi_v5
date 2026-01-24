import XCTest
@testable import TVECore

final class GeometryMappingTests: XCTestCase {
    let epsilon = 1e-6

    // MARK: - animToInputContain Tests

    func testAnimToInputContain_exactMatch_returnsScaleOneAndTranslate() {
        // Given: anim size equals input rect size
        let animSize = SizeD(width: 100, height: 100)
        let inputRect = RectD(x: 0, y: 0, width: 100, height: 100)

        // When
        let matrix = GeometryMapping.animToInputContain(animSize: animSize, inputRect: inputRect)

        // Then: scale=1, translate=(0,0)
        XCTAssertEqual(matrix.a, 1.0, accuracy: epsilon)
        XCTAssertEqual(matrix.d, 1.0, accuracy: epsilon)
        XCTAssertEqual(matrix.tx, 0.0, accuracy: epsilon)
        XCTAssertEqual(matrix.ty, 0.0, accuracy: epsilon)
    }

    func testAnimToInputContain_inputWider_centersByX() {
        // Given: input is wider than anim (200x100 vs 100x100)
        let animSize = SizeD(width: 100, height: 100)
        let inputRect = RectD(x: 0, y: 0, width: 200, height: 100)

        // When
        let matrix = GeometryMapping.animToInputContain(animSize: animSize, inputRect: inputRect)

        // Then: scale=1 (limited by height), centered horizontally
        // scaledWidth = 100, offsetX = (200-100)/2 = 50
        XCTAssertEqual(matrix.a, 1.0, accuracy: epsilon)
        XCTAssertEqual(matrix.d, 1.0, accuracy: epsilon)
        XCTAssertEqual(matrix.tx, 50.0, accuracy: epsilon)
        XCTAssertEqual(matrix.ty, 0.0, accuracy: epsilon)
    }

    func testAnimToInputContain_inputTaller_centersByY() {
        // Given: input is taller than anim (100x200 vs 100x100)
        let animSize = SizeD(width: 100, height: 100)
        let inputRect = RectD(x: 0, y: 0, width: 100, height: 200)

        // When
        let matrix = GeometryMapping.animToInputContain(animSize: animSize, inputRect: inputRect)

        // Then: scale=1 (limited by width), centered vertically
        // scaledHeight = 100, offsetY = (200-100)/2 = 50
        XCTAssertEqual(matrix.a, 1.0, accuracy: epsilon)
        XCTAssertEqual(matrix.d, 1.0, accuracy: epsilon)
        XCTAssertEqual(matrix.tx, 0.0, accuracy: epsilon)
        XCTAssertEqual(matrix.ty, 50.0, accuracy: epsilon)
    }

    func testAnimToInputContain_nonZeroOrigin_addsOffset() {
        // Given: input rect at non-zero origin
        let animSize = SizeD(width: 100, height: 100)
        let inputRect = RectD(x: 50, y: 100, width: 100, height: 100)

        // When
        let matrix = GeometryMapping.animToInputContain(animSize: animSize, inputRect: inputRect)

        // Then: scale=1, translate includes input origin
        XCTAssertEqual(matrix.a, 1.0, accuracy: epsilon)
        XCTAssertEqual(matrix.d, 1.0, accuracy: epsilon)
        XCTAssertEqual(matrix.tx, 50.0, accuracy: epsilon)
        XCTAssertEqual(matrix.ty, 100.0, accuracy: epsilon)
    }

    func testAnimToInputContain_scaleDown_appliesUniformScale() {
        // Given: anim is larger than input
        let animSize = SizeD(width: 200, height: 200)
        let inputRect = RectD(x: 0, y: 0, width: 100, height: 100)

        // When
        let matrix = GeometryMapping.animToInputContain(animSize: animSize, inputRect: inputRect)

        // Then: scale=0.5 (200*0.5=100), no centering offset
        XCTAssertEqual(matrix.a, 0.5, accuracy: epsilon)
        XCTAssertEqual(matrix.d, 0.5, accuracy: epsilon)
        XCTAssertEqual(matrix.tx, 0.0, accuracy: epsilon)
        XCTAssertEqual(matrix.ty, 0.0, accuracy: epsilon)
    }

    func testAnimToInputContain_scaleUp_appliesUniformScale() {
        // Given: anim is smaller than input
        let animSize = SizeD(width: 50, height: 50)
        let inputRect = RectD(x: 0, y: 0, width: 100, height: 100)

        // When
        let matrix = GeometryMapping.animToInputContain(animSize: animSize, inputRect: inputRect)

        // Then: scale=2 (50*2=100), no centering offset
        XCTAssertEqual(matrix.a, 2.0, accuracy: epsilon)
        XCTAssertEqual(matrix.d, 2.0, accuracy: epsilon)
        XCTAssertEqual(matrix.tx, 0.0, accuracy: epsilon)
        XCTAssertEqual(matrix.ty, 0.0, accuracy: epsilon)
    }

    func testAnimToInputContain_aspectRatioMismatch_containsAndCenters() {
        // Given: anim 16:9, input 4:3
        let animSize = SizeD(width: 1920, height: 1080)  // 16:9
        let inputRect = RectD(x: 0, y: 0, width: 800, height: 600)  // 4:3

        // When
        let matrix = GeometryMapping.animToInputContain(animSize: animSize, inputRect: inputRect)

        // Then: scale limited by width
        // scaleX = 800/1920 = 0.4167
        // scaleY = 600/1080 = 0.5556
        // scale = min(0.4167, 0.5556) = 0.4167
        let expectedScale = 800.0 / 1920.0
        let scaledHeight = 1080.0 * expectedScale
        let offsetY = (600.0 - scaledHeight) / 2.0

        XCTAssertEqual(matrix.a, expectedScale, accuracy: epsilon)
        XCTAssertEqual(matrix.d, expectedScale, accuracy: epsilon)
        XCTAssertEqual(matrix.tx, 0.0, accuracy: epsilon)
        XCTAssertEqual(matrix.ty, offsetY, accuracy: epsilon)
    }

    func testAnimToInputContain_zeroAnimSize_returnsTranslationOnly() {
        // Given: zero anim size (edge case)
        let animSize = SizeD(width: 0, height: 0)
        let inputRect = RectD(x: 10, y: 20, width: 100, height: 100)

        // When
        let matrix = GeometryMapping.animToInputContain(animSize: animSize, inputRect: inputRect)

        // Then: just translation to input origin
        XCTAssertEqual(matrix.tx, 10.0, accuracy: epsilon)
        XCTAssertEqual(matrix.ty, 20.0, accuracy: epsilon)
    }

    // MARK: - Matrix2D Tests

    func testMatrix2D_identity() {
        let identity = Matrix2D.identity

        XCTAssertEqual(identity.a, 1.0)
        XCTAssertEqual(identity.b, 0.0)
        XCTAssertEqual(identity.c, 0.0)
        XCTAssertEqual(identity.d, 1.0)
        XCTAssertEqual(identity.tx, 0.0)
        XCTAssertEqual(identity.ty, 0.0)
    }

    func testMatrix2D_translation() {
        let matrix = Matrix2D.translation(x: 10, y: 20)

        XCTAssertEqual(matrix.tx, 10.0)
        XCTAssertEqual(matrix.ty, 20.0)
        XCTAssertEqual(matrix.a, 1.0)
        XCTAssertEqual(matrix.d, 1.0)
    }

    func testMatrix2D_scale() {
        let matrix = Matrix2D.scale(x: 2, y: 3)

        XCTAssertEqual(matrix.a, 2.0)
        XCTAssertEqual(matrix.d, 3.0)
        XCTAssertEqual(matrix.tx, 0.0)
        XCTAssertEqual(matrix.ty, 0.0)
    }

    func testMatrix2D_applyToPoint() {
        // Scale by 2 and translate by (10, 20)
        let matrix = Matrix2D(a: 2, b: 0, c: 0, d: 2, tx: 10, ty: 20)
        let point = Vec2D(x: 5, y: 5)

        let result = matrix.apply(to: point)

        // (5*2 + 10, 5*2 + 20) = (20, 30)
        XCTAssertEqual(result.x, 20.0, accuracy: epsilon)
        XCTAssertEqual(result.y, 30.0, accuracy: epsilon)
    }

    func testMatrix2D_concatenating() {
        // First scale, then translate
        let scale = Matrix2D.scale(2)
        let translate = Matrix2D.translation(x: 10, y: 20)

        // translate.concatenating(scale) means: apply scale first, then translate
        let combined = translate.concatenating(scale)

        // Apply to point (5, 5): scale -> (10, 10), translate -> (20, 30)
        let point = Vec2D(x: 5, y: 5)
        let result = combined.apply(to: point)

        XCTAssertEqual(result.x, 20.0, accuracy: epsilon)
        XCTAssertEqual(result.y, 30.0, accuracy: epsilon)
    }

    func testMatrix2D_isApproximatelyEqual() {
        let m1 = Matrix2D(a: 1.0, b: 0, c: 0, d: 1.0, tx: 0, ty: 0)
        let m2 = Matrix2D(a: 1.0000001, b: 0, c: 0, d: 0.9999999, tx: 0.0000001, ty: 0)

        XCTAssertTrue(m1.isApproximatelyEqual(to: m2))
    }

    // MARK: - Vec2D Tests

    func testVec2D_zero() {
        let zero = Vec2D.zero

        XCTAssertEqual(zero.x, 0.0)
        XCTAssertEqual(zero.y, 0.0)
    }

    // MARK: - SizeD Tests

    func testSizeD_zero() {
        let zero = SizeD.zero

        XCTAssertEqual(zero.width, 0.0)
        XCTAssertEqual(zero.height, 0.0)
    }

    // MARK: - RectD Tests

    func testRectD_originAndSize() {
        let rect = RectD(x: 10, y: 20, width: 100, height: 200)

        XCTAssertEqual(rect.origin.x, 10.0)
        XCTAssertEqual(rect.origin.y, 20.0)
        XCTAssertEqual(rect.size.width, 100.0)
        XCTAssertEqual(rect.size.height, 200.0)
    }

    func testRectD_fromRect() {
        let rect = Rect(x: 10, y: 20, width: 100, height: 200)
        let rectD = RectD(from: rect)

        XCTAssertEqual(rectD.x, 10.0)
        XCTAssertEqual(rectD.y, 20.0)
        XCTAssertEqual(rectD.width, 100.0)
        XCTAssertEqual(rectD.height, 200.0)
    }
}
