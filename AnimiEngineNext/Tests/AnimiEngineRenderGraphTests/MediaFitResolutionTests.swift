import XCTest
import AnimiEngineCore
import AnimiEngineRenderModel
@testable import AnimiEngineRenderGraph

/// Task-003 plan D3-05, §6, §13 row "Fit and crop" + step-8 corrective issue #2 — `MediaFitResolver`
/// cover/contain/fill + user placement against an analytic oracle. Fit baseline is the binding-baseline
/// `contentRect`; the slotRect clip targets `blockRectCanvas`; the aperture is separate. Arbitrary
/// rotation is supported via fixed-point CORDIC. Expectations are computed by hand from the documented
/// fixed-point units (CanvasScalar 65,536/pt; linear coefficients 1,000,000/1.0).
final class MediaFitResolutionTests: XCTestCase {

    private let pt = CanvasScalar.unitsPerPoint
    private let one = FixedAffineTransform2D.linearUnitsPerOne

    /// A rect of `wPoints × hPoints` at `(xPoints, yPoints)` in canvas raw units.
    private func rect(_ xPoints: Int64, _ yPoints: Int64, _ wPoints: Int64, _ hPoints: Int64) throws -> FixedRect {
        try FixedRect(
            x: CanvasScalar(rawValue: xPoints * pt), y: CanvasScalar(rawValue: yPoints * pt),
            width: CanvasScalar(rawValue: wPoints * pt), height: CanvasScalar(rawValue: hPoints * pt))
    }

    /// An identity media placement with an explicit fit mode.
    private func placement(_ fit: MediaFitMode) -> MediaPlacement { .identity(fitMode: fit) }

    private func resolve(
        content: FixedRect, blockCanvas: FixedRect? = nil,
        srcW: Int, srcH: Int, mediaPlacement: MediaPlacement, clip: String = "none"
    ) throws -> ResolvedMediaPlacement {
        try MediaFitResolver.resolve(
            contentRect: content,
            blockRectCanvas: blockCanvas ?? content,
            sourceWidthPixels: srcW, sourceHeightPixels: srcH,
            mediaPlacement: mediaPlacement, containerClip: clip)
    }

    // MARK: - Contain / cover / fill against the contentRect baseline

    func testContainUniformMinimumScaleAndCentering() throws {
        // baseline 100×100 at origin; source 200×100 px → sx=0.5, sy=1.0 → contain picks 0.5.
        let r = try resolve(content: try rect(0, 0, 100, 100), srcW: 200, srcH: 100,
                            mediaPlacement: placement(.contain))
        XCTAssertEqual(r.fitMode, .contain)
        XCTAssertEqual(r.transform.a, 500_000)
        XCTAssertEqual(r.transform.d, 500_000)
        // fittedW=100pt, fittedH=50pt → centered vertically by 25pt.
        XCTAssertEqual(r.transform.tx, 0)
        XCTAssertEqual(r.transform.ty, 25 * pt)
        XCTAssertEqual(r.clip, .none)
    }

    func testCoverUniformMaximumScaleAndCenteringClipToBlockCanvas() throws {
        // baseline 100×100; source 200×100 px → cover picks 1.0; block canvas distinct from baseline.
        let block = try rect(5, 7, 100, 100)
        let r = try resolve(content: try rect(0, 0, 100, 100), blockCanvas: block,
                            srcW: 200, srcH: 100, mediaPlacement: placement(.cover), clip: "slotRect")
        XCTAssertEqual(r.transform.a, 1_000_000)
        XCTAssertEqual(r.transform.d, 1_000_000)
        // fittedW=200pt overflows the 100pt baseline; centerX=(100-200)/2=-50pt; centerY=0.
        XCTAssertEqual(r.transform.tx, -50 * pt)
        XCTAssertEqual(r.transform.ty, 0)
        // slotRect clips to the BLOCK CANVAS rect, not the baseline (issue #2).
        XCTAssertEqual(r.clip, .rect(block))
    }

    func testFillIndependentAxisScale() throws {
        let r = try resolve(content: try rect(0, 0, 100, 100), srcW: 200, srcH: 100,
                            mediaPlacement: placement(.fill))
        XCTAssertEqual(r.transform.a, 500_000)
        XCTAssertEqual(r.transform.d, 1_000_000)
        XCTAssertEqual(r.transform.tx, 0)
        XCTAssertEqual(r.transform.ty, 0)
    }

    func testBaselineOriginOffsetsResult() throws {
        let r = try resolve(content: try rect(40, 60, 100, 100), srcW: 200, srcH: 100,
                            mediaPlacement: placement(.contain))
        XCTAssertEqual(r.transform.tx, 40 * pt)
        XCTAssertEqual(r.transform.ty, (60 + 25) * pt)
    }

    // MARK: - User transform composition

    func testUserOffsetComposesOnTop() throws {
        // square→square fit is identity-scale centered with no offset; user offset shifts the result.
        let mp = try MediaPlacement(
            fitMode: .contain, userOffsetX: CanvasScalar(rawValue: 10 * pt),
            userOffsetY: CanvasScalar(rawValue: 20 * pt), userScale: .one, userRotation: .zero)
        let r = try resolve(content: try rect(0, 0, 100, 100), srcW: 100, srcH: 100, mediaPlacement: mp)
        XCTAssertEqual(r.transform.a, 1_000_000)
        XCTAssertEqual(r.transform.tx, 10 * pt)
        XCTAssertEqual(r.transform.ty, 20 * pt)
    }

    func testUserScaleComposesAboutBaselineCentre() throws {
        // square 100×100; user scale ×2 about centre (50,50): source corner (0,0) → (-50,-50)pt.
        let mp = try MediaPlacement(
            fitMode: .contain, userOffsetX: CanvasScalar(rawValue: 0), userOffsetY: CanvasScalar(rawValue: 0),
            userScale: try ScaleScalar(positiveRawValue: 2_000_000), userRotation: .zero)
        let r = try resolve(content: try rect(0, 0, 100, 100), srcW: 100, srcH: 100, mediaPlacement: mp)
        XCTAssertEqual(r.transform.a, 2_000_000)
        XCTAssertEqual(r.transform.d, 2_000_000)
        let corner = try r.transform.apply(x: 0, y: 0)
        XCTAssertEqual(corner.x, -50 * pt)
        XCTAssertEqual(corner.y, -50 * pt)
    }

    func testArbitraryUserRotationIsSupported() throws {
        // 90° rotation about centre (50,50): source centre (50,50) stays fixed; corner (0,0)→(100,0).
        let mp = try MediaPlacement(
            fitMode: .contain, userOffsetX: CanvasScalar(rawValue: 0), userOffsetY: CanvasScalar(rawValue: 0),
            userScale: .one, userRotation: RotationScalar(rawValue: 90 * 1000))
        let r = try resolve(content: try rect(0, 0, 100, 100), srcW: 100, srcH: 100, mediaPlacement: mp)
        let centre = try r.transform.apply(x: 50 * pt, y: 50 * pt)
        XCTAssertEqual(centre.x, 50 * pt, accuracy: 4)
        XCTAssertEqual(centre.y, 50 * pt, accuracy: 4)
        // 45° must NOT throw any more (arbitrary rotation, issue #6).
        let mp45 = try MediaPlacement(
            fitMode: .contain, userOffsetX: CanvasScalar(rawValue: 0), userOffsetY: CanvasScalar(rawValue: 0),
            userScale: .one, userRotation: RotationScalar(rawValue: 45 * 1000))
        XCTAssertNoThrow(try resolve(content: try rect(0, 0, 100, 100), srcW: 100, srcH: 100, mediaPlacement: mp45))
    }

    // MARK: - Clip policy (issue #2)

    func testContainerClipPolicies() throws {
        let baseline = try rect(0, 0, 100, 100)
        let block = try rect(3, 4, 120, 130)
        XCTAssertEqual(try MediaFitResolver.resolveClip(containerClip: "none", blockRectCanvas: block), .none)
        XCTAssertEqual(try MediaFitResolver.resolveClip(containerClip: "slotRect", blockRectCanvas: block), .rect(block))
        // slotRectAfterSettle now fails closed (issue #2).
        XCTAssertThrowsError(try MediaFitResolver.resolveClip(containerClip: "slotRectAfterSettle", blockRectCanvas: block)) { error in
            guard case RenderGraphError.unsupportedSettledClip? = error as? RenderGraphError else {
                return XCTFail("expected unsupportedSettledClip, got \(error)")
            }
        }
        XCTAssertThrowsError(try MediaFitResolver.resolveClip(containerClip: "bogus", blockRectCanvas: block)) { error in
            guard case RenderGraphError.unsupportedContainerClip? = error as? RenderGraphError else {
                return XCTFail("expected unsupportedContainerClip, got \(error)")
            }
        }
        _ = baseline
    }

    func testSlotRectAfterSettleFailsClosedThroughResolve() throws {
        XCTAssertThrowsError(try resolve(
            content: try rect(0, 0, 100, 100), srcW: 100, srcH: 100,
            mediaPlacement: placement(.contain), clip: "slotRectAfterSettle")) { error in
            guard case RenderGraphError.unsupportedSettledClip? = error as? RenderGraphError else {
                return XCTFail("expected unsupportedSettledClip, got \(error)")
            }
        }
    }

    // MARK: - Degenerate inputs / determinism

    func testZeroSourceDimensionsRejected() {
        XCTAssertThrowsError(try resolve(
            content: try rect(0, 0, 100, 100), srcW: 0, srcH: 100, mediaPlacement: placement(.contain))) { error in
            guard case RenderGraphError.invalidSourceDimensions? = error as? RenderGraphError else {
                return XCTFail("expected invalidSourceDimensions, got \(error)")
            }
        }
    }

    func testIdenticalInputsProduceIdenticalTransform() throws {
        func run() throws -> ResolvedMediaPlacement {
            try resolve(content: try rect(7, 11, 123, 77), srcW: 333, srcH: 222,
                        mediaPlacement: placement(.cover), clip: "slotRect")
        }
        XCTAssertEqual(try run(), try run())
    }

    // MARK: - FixedAffineTransform2D arithmetic (issue #7 full-width, issue #6 CORDIC rotation)

    func testIdentityAppliesUnchanged() throws {
        let p = try FixedAffineTransform2D.identity.apply(x: 123 * pt, y: -7 * pt)
        XCTAssertEqual(p.x, 123 * pt); XCTAssertEqual(p.y, -7 * pt)
    }

    func testTranslationThenScaleCompositionOrder() throws {
        let t = try FixedAffineTransform2D
            .translation(tx: 10 * pt, ty: 20 * pt)
            .concatenating(.scale(scaleX: 2 * one, scaleY: 2 * one))
        // (3pt,4pt) → scale → (6pt,8pt) → translate(10,20) → (16pt,28pt).
        let p = try t.apply(x: 3 * pt, y: 4 * pt)
        XCTAssertEqual(p.x, 16 * pt); XCTAssertEqual(p.y, 28 * pt)
    }

    func testApplyLinearNoIntermediateOverflow() throws {
        // a huge coordinate × a scale that would overflow a 64-bit product survives via full width.
        let huge: Int64 = 9_000_000_000_000   // ~9e12 raw units
        XCTAssertEqual(try FixedAffineTransform2D.applyLinear(huge, 2_000_000, "t"), 18_000_000_000_000)
    }

    func testDivideRoundHalfAwayZeroDivisorIsTypedFailure() {
        XCTAssertThrowsError(try FixedAffineTransform2D.divideRoundHalfAway(1, 0, "t"))
    }
}
