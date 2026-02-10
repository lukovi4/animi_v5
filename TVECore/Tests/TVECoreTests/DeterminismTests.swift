import XCTest
@testable import TVECore
@testable import TVECompilerCore

/// Tests for PR-14A: Determinism & Hashing
/// Verifies that quantized hashes are stable and eliminate floating-point noise issues.
final class DeterminismTests: XCTestCase {
    // MARK: - Quantization Tests

    func testQuantize_roundsToStep() {
        // Step = 0.125 (1/8)
        XCTAssertEqual(Quantization.quantize(0.0, step: 0.125), 0.0)
        XCTAssertEqual(Quantization.quantize(0.1, step: 0.125), 0.125)
        XCTAssertEqual(Quantization.quantize(0.06, step: 0.125), 0.0)
        XCTAssertEqual(Quantization.quantize(0.07, step: 0.125), 0.125)
        XCTAssertEqual(Quantization.quantize(1.9, step: 0.125), 1.875)
        XCTAssertEqual(Quantization.quantize(1.95, step: 0.125), 2.0)
    }

    func testQuantizedInt_convertsToIntegerGrid() {
        let step = 1.0 / 1024.0

        // Values that should map to same integer
        XCTAssertEqual(
            Quantization.quantizedInt(100.0, step: step),
            Quantization.quantizedInt(100.0 + 1e-12, step: step)
        )

        // Values that should map to different integers
        XCTAssertNotEqual(
            Quantization.quantizedInt(100.0, step: step),
            Quantization.quantizedInt(100.0 + step, step: step)
        )
    }

    func testIsNearlyEqual_withinEpsilon_returnsTrue() {
        XCTAssertTrue(Quantization.isNearlyEqual(1.0, 1.0))
        XCTAssertTrue(Quantization.isNearlyEqual(1.0, 1.0 + 1e-12))
        XCTAssertTrue(Quantization.isNearlyEqual(1.0, 1.0 + 0.0005))
        XCTAssertTrue(Quantization.isNearlyEqual(1.0, 1.0 - 0.0005))
    }

    func testIsNearlyEqual_outsideEpsilon_returnsFalse() {
        XCTAssertFalse(Quantization.isNearlyEqual(1.0, 1.0 + 0.002))
        XCTAssertFalse(Quantization.isNearlyEqual(1.0, 1.0 - 0.002))
        XCTAssertFalse(Quantization.isNearlyEqual(0.0, 1.0))
    }

    func testIsNearlyZero_withinEpsilon_returnsTrue() {
        XCTAssertTrue(Quantization.isNearlyZero(0.0))
        XCTAssertTrue(Quantization.isNearlyZero(1e-12))
        XCTAssertTrue(Quantization.isNearlyZero(-1e-12))
        XCTAssertTrue(Quantization.isNearlyZero(0.0005))
        XCTAssertTrue(Quantization.isNearlyZero(-0.0005))
    }

    func testIsNearlyZero_outsideEpsilon_returnsFalse() {
        XCTAssertFalse(Quantization.isNearlyZero(0.002))
        XCTAssertFalse(Quantization.isNearlyZero(-0.002))
        XCTAssertFalse(Quantization.isNearlyZero(1.0))
    }

    func testKeyframeTimesEqual_withinEpsilon_returnsTrue() {
        XCTAssertTrue(Quantization.keyframeTimesEqual(30.0, 30.0))
        XCTAssertTrue(Quantization.keyframeTimesEqual(30.0, 30.0 + 1e-12))
        XCTAssertTrue(Quantization.keyframeTimesEqual(30.0, 30.0 + 0.0005))
    }

    func testKeyframeTimesEqual_outsideEpsilon_returnsFalse() {
        XCTAssertFalse(Quantization.keyframeTimesEqual(30.0, 30.002))
        XCTAssertFalse(Quantization.keyframeTimesEqual(30.0, 31.0))
    }

    // MARK: - Matrix2D Quantized Hash Tests

    func testMatrix2D_quantizedHash_identicalMatrices_sameHash() {
        let m1 = Matrix2D(a: 1.0, b: 0.0, c: 0.0, d: 1.0, tx: 100.0, ty: 200.0)
        let m2 = Matrix2D(a: 1.0, b: 0.0, c: 0.0, d: 1.0, tx: 100.0, ty: 200.0)

        XCTAssertEqual(m1.quantizedHash(), m2.quantizedHash())
    }

    func testMatrix2D_quantizedHash_withMicroNoise_sameHash() {
        // Matrices that differ by 1e-12 (floating-point noise) should have same quantized hash
        let m1 = Matrix2D(a: 1.0, b: 0.0, c: 0.0, d: 1.0, tx: 100.0, ty: 200.0)
        let m2 = Matrix2D(
            a: 1.0 + 1e-12,
            b: 0.0 + 1e-12,
            c: 0.0 - 1e-12,
            d: 1.0 - 1e-12,
            tx: 100.0 + 1e-12,
            ty: 200.0 - 1e-12
        )

        XCTAssertEqual(
            m1.quantizedHash(),
            m2.quantizedHash(),
            "Matrices differing by 1e-12 should have same quantized hash"
        )
    }

    func testMatrix2D_quantizedHash_differentMatrices_differentHash() {
        let m1 = Matrix2D(a: 1.0, b: 0.0, c: 0.0, d: 1.0, tx: 100.0, ty: 200.0)
        let m2 = Matrix2D(a: 2.0, b: 0.0, c: 0.0, d: 2.0, tx: 100.0, ty: 200.0)

        XCTAssertNotEqual(m1.quantizedHash(), m2.quantizedHash())
    }

    func testMatrix2D_quantizedHash_rotationMatrices_deterministic() {
        // Same rotation angle should produce same hash
        let angle = 45.0 * .pi / 180.0
        let m1 = Matrix2D.rotation(angle)
        let m2 = Matrix2D.rotation(angle)

        XCTAssertEqual(m1.quantizedHash(), m2.quantizedHash())
    }

    func testMatrix2D_quantizedHash_customStep_worksCorrectly() {
        let m1 = Matrix2D(a: 1.0, b: 0.0, c: 0.0, d: 1.0, tx: 100.0, ty: 200.0)
        let m2 = Matrix2D(a: 1.0, b: 0.0, c: 0.0, d: 1.0, tx: 100.1, ty: 200.0)

        // With default step (1/1024 ≈ 0.001), these should have different hashes
        XCTAssertNotEqual(
            m1.quantizedHash(),
            m2.quantizedHash(),
            "Different tx should produce different hash with default step"
        )

        // With larger step (1.0), these should have same hash
        XCTAssertEqual(
            m1.quantizedHash(step: 1.0),
            m2.quantizedHash(step: 1.0),
            "With step=1.0, 100.0 and 100.1 should round to same value"
        )
    }

    // MARK: - AnimConstants Tests

    func testAnimConstants_valuesAreCorrect() {
        XCTAssertEqual(AnimConstants.keyframeTimeEpsilon, 0.001)
        XCTAssertEqual(AnimConstants.nearlyEqualEpsilon, 0.001)
        XCTAssertEqual(AnimConstants.matrixQuantStep, 1.0 / 1024.0)
        XCTAssertEqual(AnimConstants.pathCoordQuantStep, 1.0 / 1024.0)
        XCTAssertEqual(AnimConstants.strokeWidthQuantStep, 1.0 / 8.0)
    }

    // MARK: - Path Hash Determinism Tests

    func testPathHash_identicalPaths_sameHash() {
        let path1 = BezierPath(
            vertices: [Vec2D(x: 0, y: 0), Vec2D(x: 100, y: 0), Vec2D(x: 100, y: 100)],
            inTangents: [Vec2D.zero, Vec2D.zero, Vec2D.zero],
            outTangents: [Vec2D.zero, Vec2D.zero, Vec2D.zero],
            closed: true
        )
        let path2 = BezierPath(
            vertices: [Vec2D(x: 0, y: 0), Vec2D(x: 100, y: 0), Vec2D(x: 100, y: 100)],
            inTangents: [Vec2D.zero, Vec2D.zero, Vec2D.zero],
            outTangents: [Vec2D.zero, Vec2D.zero, Vec2D.zero],
            closed: true
        )

        let hash1 = computeQuantizedPathHash(path1)
        let hash2 = computeQuantizedPathHash(path2)

        XCTAssertEqual(hash1, hash2, "Identical paths should have same hash")
    }

    func testPathHash_withMicroNoise_sameHash() {
        let path1 = BezierPath(
            vertices: [Vec2D(x: 0, y: 0), Vec2D(x: 100, y: 0), Vec2D(x: 100, y: 100)],
            inTangents: [Vec2D.zero, Vec2D.zero, Vec2D.zero],
            outTangents: [Vec2D.zero, Vec2D.zero, Vec2D.zero],
            closed: true
        )
        let path2 = BezierPath(
            vertices: [
                Vec2D(x: 0 + 1e-12, y: 0 - 1e-12),
                Vec2D(x: 100 + 1e-12, y: 0 + 1e-12),
                Vec2D(x: 100 - 1e-12, y: 100 + 1e-12)
            ],
            inTangents: [Vec2D.zero, Vec2D.zero, Vec2D.zero],
            outTangents: [Vec2D.zero, Vec2D.zero, Vec2D.zero],
            closed: true
        )

        let hash1 = computeQuantizedPathHash(path1)
        let hash2 = computeQuantizedPathHash(path2)

        XCTAssertEqual(
            hash1,
            hash2,
            "Paths differing by 1e-12 should have same quantized hash"
        )
    }

    func testPathHash_differentPaths_differentHash() {
        let path1 = BezierPath(
            vertices: [Vec2D(x: 0, y: 0), Vec2D(x: 100, y: 0), Vec2D(x: 100, y: 100)],
            inTangents: [Vec2D.zero, Vec2D.zero, Vec2D.zero],
            outTangents: [Vec2D.zero, Vec2D.zero, Vec2D.zero],
            closed: true
        )
        let path2 = BezierPath(
            vertices: [Vec2D(x: 0, y: 0), Vec2D(x: 200, y: 0), Vec2D(x: 200, y: 200)],
            inTangents: [Vec2D.zero, Vec2D.zero, Vec2D.zero],
            outTangents: [Vec2D.zero, Vec2D.zero, Vec2D.zero],
            closed: true
        )

        let hash1 = computeQuantizedPathHash(path1)
        let hash2 = computeQuantizedPathHash(path2)

        XCTAssertNotEqual(hash1, hash2, "Different paths should have different hash")
    }

    // MARK: - Helper

    /// Computes quantized path hash (mirrors ShapeCacheKey implementation)
    private func computeQuantizedPathHash(_ path: BezierPath) -> Int {
        let step = AnimConstants.pathCoordQuantStep
        var hasher = Hasher()
        hasher.combine(path.closed)
        hasher.combine(path.vertices.count)
        for vertex in path.vertices {
            hasher.combine(Quantization.quantizedInt(vertex.x, step: step))
            hasher.combine(Quantization.quantizedInt(vertex.y, step: step))
        }
        for tangent in path.inTangents {
            hasher.combine(Quantization.quantizedInt(tangent.x, step: step))
            hasher.combine(Quantization.quantizedInt(tangent.y, step: step))
        }
        for tangent in path.outTangents {
            hasher.combine(Quantization.quantizedInt(tangent.x, step: step))
            hasher.combine(Quantization.quantizedInt(tangent.y, step: step))
        }
        return hasher.finalize()
    }
}
