import XCTest
@testable import AnimiApp
import TVECore

/// Tests for Matrix2DDecomposer: SRT decomposition with validation.
final class Matrix2DDecomposerTests: XCTestCase {

    // MARK: - Identity

    func test_identity_decomposesCorrectly() throws {
        let c = try Matrix2DDecomposer.decompose(.identity)

        XCTAssertEqual(c.offsetX, 0, accuracy: 1e-6)
        XCTAssertEqual(c.offsetY, 0, accuracy: 1e-6)
        XCTAssertEqual(c.scale, 1.0, accuracy: 1e-6)
        XCTAssertEqual(c.rotationDegrees, 0, accuracy: 1e-6)
    }

    // MARK: - Pure Translation

    func test_translation_decomposesCorrectly() throws {
        let matrix = Matrix2D.translation(x: 50, y: -30)
        let c = try Matrix2DDecomposer.decompose(matrix)

        XCTAssertEqual(c.offsetX, 50, accuracy: 1e-6)
        XCTAssertEqual(c.offsetY, -30, accuracy: 1e-6)
        XCTAssertEqual(c.scale, 1.0, accuracy: 1e-6)
        XCTAssertEqual(c.rotationDegrees, 0, accuracy: 1e-6)
    }

    // MARK: - Pure Scale

    func test_uniformScale_decomposesCorrectly() throws {
        let matrix = Matrix2D.scale(2.5)
        let c = try Matrix2DDecomposer.decompose(matrix)

        XCTAssertEqual(c.offsetX, 0, accuracy: 1e-6)
        XCTAssertEqual(c.offsetY, 0, accuracy: 1e-6)
        XCTAssertEqual(c.scale, 2.5, accuracy: 1e-6)
        XCTAssertEqual(c.rotationDegrees, 0, accuracy: 1e-6)
    }

    // MARK: - Pure Rotation

    func test_rotation45_decomposesCorrectly() throws {
        let matrix = Matrix2D.rotationDegrees(45)
        let c = try Matrix2DDecomposer.decompose(matrix)

        XCTAssertEqual(c.scale, 1.0, accuracy: 1e-6)
        XCTAssertEqual(c.rotationDegrees, 45, accuracy: 1e-4)
    }

    func test_rotation90_decomposesCorrectly() throws {
        let matrix = Matrix2D.rotationDegrees(90)
        let c = try Matrix2DDecomposer.decompose(matrix)

        XCTAssertEqual(c.scale, 1.0, accuracy: 1e-6)
        XCTAssertEqual(c.rotationDegrees, 90, accuracy: 1e-4)
    }

    func test_rotationNeg135_decomposesCorrectly() throws {
        let matrix = Matrix2D.rotationDegrees(-135)
        let c = try Matrix2DDecomposer.decompose(matrix)

        XCTAssertEqual(c.scale, 1.0, accuracy: 1e-6)
        XCTAssertEqual(c.rotationDegrees, -135, accuracy: 1e-4)
    }

    // MARK: - Combined SRT

    func test_translationScaleRotation_decomposesCorrectly() throws {
        // Build: T(10, 20) * R(30°) * S(1.5)
        let s = Matrix2D.scale(1.5)
        let r = Matrix2D.rotationDegrees(30)
        let t = Matrix2D.translation(x: 10, y: 20)
        let matrix = t.concatenating(r.concatenating(s))

        let c = try Matrix2DDecomposer.decompose(matrix)

        XCTAssertEqual(c.offsetX, 10, accuracy: 1e-4)
        XCTAssertEqual(c.offsetY, 20, accuracy: 1e-4)
        XCTAssertEqual(c.scale, 1.5, accuracy: 1e-4)
        XCTAssertEqual(c.rotationDegrees, 30, accuracy: 1e-3)
    }

    // MARK: - Error Cases

    func test_nonUniformScale_throws() {
        let matrix = Matrix2D.scale(x: 2.0, y: 3.0)

        XCTAssertThrowsError(try Matrix2DDecomposer.decompose(matrix)) { error in
            XCTAssertEqual(error as? Matrix2DDecomposer.DecomposeError, .nonUniformScale)
        }
    }

    func test_shearMatrix_throws() {
        // Shear matrix: | 1  0.5  0 |
        //               | 0  1    0 |
        let matrix = Matrix2D(a: 1, b: 0.5, c: 0, d: 1, tx: 0, ty: 0)

        XCTAssertThrowsError(try Matrix2DDecomposer.decompose(matrix)) { error in
            let decomposeError = error as? Matrix2DDecomposer.DecomposeError
            // May be hasShear or nonUniformScale depending on validation order
            XCTAssertTrue(
                decomposeError == .hasShear || decomposeError == .nonUniformScale,
                "Expected hasShear or nonUniformScale, got \(String(describing: decomposeError))"
            )
        }
    }

    func test_singularMatrix_throws() {
        // Zero matrix — not invertible
        let matrix = Matrix2D(a: 0, b: 0, c: 0, d: 0, tx: 0, ty: 0)

        XCTAssertThrowsError(try Matrix2DDecomposer.decompose(matrix)) { error in
            XCTAssertEqual(error as? Matrix2DDecomposer.DecomposeError, .notInvertible)
        }
    }

    func test_reflectionMatrix_throws() {
        // Reflection: scale x=-1, y=1
        let matrix = Matrix2D.scale(x: -1, y: 1)

        XCTAssertThrowsError(try Matrix2DDecomposer.decompose(matrix)) { error in
            XCTAssertEqual(error as? Matrix2DDecomposer.DecomposeError, .hasReflection)
        }
    }

    func test_infiniteComponents_throws() {
        let matrix = Matrix2D(a: .infinity, b: 0, c: 0, d: 1, tx: 0, ty: 0)

        XCTAssertThrowsError(try Matrix2DDecomposer.decompose(matrix)) { error in
            XCTAssertEqual(error as? Matrix2DDecomposer.DecomposeError, .notFinite)
        }
    }

    func test_nanComponents_throws() {
        let matrix = Matrix2D(a: .nan, b: 0, c: 0, d: 1, tx: 0, ty: 0)

        XCTAssertThrowsError(try Matrix2DDecomposer.decompose(matrix)) { error in
            XCTAssertEqual(error as? Matrix2DDecomposer.DecomposeError, .notFinite)
        }
    }

    // MARK: - Roundtrip Rebuild

    func test_rebuildMatrix_matchesOriginal() throws {
        let original = Matrix2D.translation(x: 5, y: -3)
            .concatenating(Matrix2D.rotationDegrees(60).concatenating(Matrix2D.scale(0.8)))

        let c = try Matrix2DDecomposer.decompose(original)
        let rebuilt = Matrix2DDecomposer.rebuildMatrix(from: c)

        XCTAssertTrue(
            rebuilt.isApproximatelyEqual(to: original, epsilon: 1e-4),
            "Rebuilt matrix must match original. Got \(rebuilt) vs \(original)"
        )
    }
}
