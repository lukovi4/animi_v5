import XCTest
import Foundation
import AnimiEngineCore
import AnimiEngineRenderModel
import AnimiEngineRenderGraph
import AnimiEngineMetalRender

/// Task-003 plan D3-08, §13 — the colour/alpha contract value model **and** the Step-10 execution proofs.
///
/// The value-model tests pin the pinned contract descriptors and `PremultipliedColor` invariants. The
/// execution tests (Step 10) prove the colour/alpha pipeline end to end through `MetalRenderSession`:
/// transfer functions, premultiplication, fixed-function source-over, geometry, hard-clip, and the final
/// BGRA8 readback. Exact bytes are asserted only for opaque, integer-aligned, hard-clip endpoints; any path
/// through `pow`/partial-alpha/rotation uses bounded assertions (plan §13, correction #8).
final class ColorAlphaContractTests: XCTestCase {

    func testTask003ContractIsBGRA8SRGBSDRPremultiplied() {
        let c = RenderColorContract.task003
        XCTAssertEqual(c.outputFormat, .bgra8)
        XCTAssertEqual(c.colorSpace, .sRGB)
        XCTAssertEqual(c.dynamicRange, .sdr)
        XCTAssertEqual(c.alphaStorage, .premultiplied)
    }

    func testContractFormsAreClosedSets() {
        XCTAssertEqual(PixelByteFormat.allCases, [.bgra8])
        XCTAssertEqual(ColorSpaceDescriptor.allCases, [.sRGB])
        XCTAssertEqual(DynamicRange.allCases, [.sdr])
        XCTAssertEqual(AlphaStorage.allCases, [.premultiplied])
    }

    func testPremultipliedColorIsImmutableValue() throws {
        let opaqueRed = try PremultipliedColor(
            red: .one, green: .zero, blue: .zero, alpha: .one)
        XCTAssertEqual(opaqueRed.red, .one)
        XCTAssertEqual(opaqueRed.alpha, .one)
        XCTAssertEqual(PremultipliedColor.transparentBlack.alpha, .zero)
        // Value equality.
        XCTAssertEqual(opaqueRed, try PremultipliedColor(red: .one, green: .zero, blue: .zero, alpha: .one))
    }

    func testPremultipliedColorRejectsChannelExceedingAlpha() throws {
        // red > alpha is not a representable premultiplied colour (item 3).
        let half = try NormalizedColorComponent(rawValue: 500_000)
        XCTAssertThrowsError(
            try PremultipliedColor(red: .one, green: .zero, blue: .zero, alpha: half)
        ) { error in
            guard case let RenderModelError.unsupportedValue(field, _)? = error as? RenderModelError else {
                return XCTFail("got \(error)")
            }
            XCTAssertEqual(field, "PremultipliedColor.red")
        }
        // green and blue are checked too (exact typed case asserted, corrective Rev-4 pt.4).
        XCTAssertThrowsError(try PremultipliedColor(red: .zero, green: .one, blue: .zero, alpha: half)) { error in
            guard case let RenderModelError.unsupportedValue(field, _)? = error as? RenderModelError else {
                return XCTFail("got \(error)")
            }
            XCTAssertEqual(field, "PremultipliedColor.green")
        }
        XCTAssertThrowsError(try PremultipliedColor(red: .zero, green: .zero, blue: .one, alpha: half)) { error in
            guard case let RenderModelError.unsupportedValue(field, _)? = error as? RenderModelError else {
                return XCTFail("got \(error)")
            }
            XCTAssertEqual(field, "PremultipliedColor.blue")
        }
        // Equal to alpha is allowed (fully saturated premultiplied channel).
        XCTAssertNoThrow(try PremultipliedColor(red: half, green: half, blue: half, alpha: half))
    }

    func testColorComponentsAreFixedPointNotFloat() throws {
        // The component is fixed-point Int64 raw; there is no Double/Float in canonical state (§5.4).
        let half = try NormalizedColorComponent(rawValue: 500_000)
        XCTAssertEqual(half.rawValue, 500_000)
    }

    // MARK: - Execution proofs (Step 10)

    private func solidImage(_ b: UInt8, _ g: UInt8, _ r: UInt8, _ a: UInt8, id: String) throws -> ResolvedPixelInput {
        try MetalTestEnvironment.makePixelInput(
            id: id, width: 1, height: 1, straightBGRA: [(b: b, g: g, r: r, a: a)])
    }

    // #1 exact opaque 1x1 colour (both profiles)
    func testOpaque1x1ExactColor() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let s = try MetalRenderSession(device: device)
        for profile in [IntermediateProfile.rgba16FloatLinear, .bgra8SRGB] {
            let img = try solidImage(0, 128, 200, 255, id: "opaque-\(profile)")
            let frame = try s.execute(try MetalTestEnvironment.singleImageGraph(
                width: 1, height: 1, profile: profile, pixels: img))
            let p = MetalTestEnvironment.pixel(frame, x: 0, y: 0)
            // Opaque round-trip is the identity within quantization (plan §5).
            XCTAssertEqual(p.r, MetalTestEnvironment.opaqueRoundTripByte(200), "r profile \(profile)")
            XCTAssertEqual(p.g, MetalTestEnvironment.opaqueRoundTripByte(128), "g profile \(profile)")
            XCTAssertEqual(p.b, MetalTestEnvironment.opaqueRoundTripByte(0), "b profile \(profile)")
            XCTAssertEqual(p.a, 255, "a profile \(profile)")
        }
    }

    // #2 transparent pixel → transparent output
    func testTransparentPixelProducesTransparentOutput() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let s = try MetalRenderSession(device: device)
        let img = try solidImage(0, 0, 0, 0, id: "transparent")
        let frame = try s.execute(try MetalTestEnvironment.singleImageGraph(
            width: 1, height: 1, profile: .rgba16FloatLinear, pixels: img))
        let p = MetalTestEnvironment.pixel(frame, x: 0, y: 0)
        XCTAssertEqual([p.b, p.g, p.r, p.a], [0, 0, 0, 0])
    }

    // #3 partial-alpha premultiplied input (bounded — pow + partial alpha)
    func testPartialAlphaPremultipliedSourceOver() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let s = try MetalRenderSession(device: device)
        // 50%-alpha mid-grey straight colour over a transparent canvas. Composited over transparent, the
        // output is the source itself: straight grey 128 at alpha 128.
        let img = try solidImage(128, 128, 128, 128, id: "partial")
        for profile in [IntermediateProfile.rgba16FloatLinear, .bgra8SRGB] {
            let frame = try s.execute(try MetalTestEnvironment.singleImageGraph(
                width: 1, height: 1, profile: profile, pixels: img))
            let p = MetalTestEnvironment.pixel(frame, x: 0, y: 0)
            // Output alpha is exact (no pow). RGB is premultiplied straight-128 → bounded.
            XCTAssertEqual(p.a, 128, "alpha profile \(profile)")
            // Expected premultiplied byte: straight 128 round-trips to ~128, then *0.502 ≈ 64. Bounded.
            let expectedPremul = Int(Double(MetalTestEnvironment.opaqueRoundTripByte(128)) * 128.0 / 255.0)
            let tol = profile == .rgba16FloatLinear ? 3 : 6
            XCTAssertLessThanOrEqual(abs(Int(p.r) - expectedPremul), tol, "r profile \(profile) got \(p.r) exp ~\(expectedPremul)")
        }
    }

    // #5 multiple draw ordering (fixed-function blend) — bounded
    func testMultipleDrawOrderingOverlap() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let s = try MetalRenderSession(device: device)
        // Two opaque 1x1 draws into the same canvas: the second (blue) fully covers and must win.
        let red = try solidImage(0, 0, 255, 255, id: "ord-red")
        let blue = try solidImage(255, 0, 0, 255, id: "ord-blue")
        let config = try MetalTestEnvironment.configuration(width: 1, height: 1, profile: .rgba16FloatLinear)
        var cmds: [RenderCommand] = []
        var o = 0
        func add(_ p: RenderCommandPayload) throws { cmds.append(try RenderCommand(ordinal: o, payload: p)); o += 1 }
        try add(.declareResource(RenderResourceDescriptor(pixelInputID: red.id.rawValue, pixels: red, colorContract: .task003)))
        try add(.declareResource(RenderResourceDescriptor(pixelInputID: blue.id.rawValue, pixels: blue, colorContract: .task003)))
        try add(.offscreenSurface(MetalTestEnvironment.linearCanvasDescriptor(width: 1, height: 1, profile: .rgba16FloatLinear)))
        try add(.offscreenSurface(MetalTestEnvironment.sRGBSurfaceDescriptor(width: 1, height: 1)))
        try add(.clearBackground(color: .transparentBlack, targetSurfaceID: RenderSurface.linearCanvas))
        try add(.beginScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas))
        try add(.drawImage(resourceID: red.id.rawValue, transform: .identity, opacity: .opaque, targetSurfaceID: RenderSurface.linearCanvas))
        try add(.drawImage(resourceID: blue.id.rawValue, transform: .identity, opacity: .opaque, targetSurfaceID: RenderSurface.linearCanvas))
        try add(.endScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas))
        try add(.finalLinearToSRGB(sourceSurfaceID: RenderSurface.linearCanvas, targetSurfaceID: RenderSurface.sRGBSurface))
        try add(.finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface))
        let frame = try s.execute(try RenderGraph(configuration: config, commands: cmds))
        let p = MetalTestEnvironment.pixel(frame, x: 0, y: 0)
        // Blue opaque on top wins (the second draw, opaque, fully replaces).
        XCTAssertEqual(p.b, 255); XCTAssertEqual(p.r, 0); XCTAssertEqual(p.a, 255)
    }

    // #8 asymmetric 2x2: physical BGRA order + vertical orientation (opaque, exact)
    func testAsymmetric2x2ChannelAndOrientation() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let s = try MetalRenderSession(device: device)
        // Distinct opaque colours per cell: TL red, TR green, BL blue, BR white.
        let img = try MetalTestEnvironment.makePixelInput(
            id: "asym", width: 2, height: 2,
            straightBGRA: [
                (b: 0, g: 0, r: 255, a: 255),     (b: 0, g: 255, r: 0, a: 255),     // row 0 (top): red, green
                (b: 255, g: 0, r: 0, a: 255),     (b: 255, g: 255, r: 255, a: 255), // row 1 (bottom): blue, white
            ])
        let frame = try s.execute(try MetalTestEnvironment.singleImageGraph(
            width: 2, height: 2, profile: .rgba16FloatLinear, pixels: img))
        let tl = MetalTestEnvironment.pixel(frame, x: 0, y: 0)
        let tr = MetalTestEnvironment.pixel(frame, x: 1, y: 0)
        let bl = MetalTestEnvironment.pixel(frame, x: 0, y: 1)
        let br = MetalTestEnvironment.pixel(frame, x: 1, y: 1)
        XCTAssertEqual(tl.r, 255, "TL red"); XCTAssertEqual(tl.b, 0)
        XCTAssertEqual(tr.g, 255, "TR green"); XCTAssertEqual(tr.r, 0)
        XCTAssertEqual(bl.b, 255, "BL blue"); XCTAssertEqual(bl.r, 0)
        XCTAssertEqual(br.r, 255, "BR white"); XCTAssertEqual(br.g, 255); XCTAssertEqual(br.b, 255)
    }

    // #10 identity transform (opaque, exact)
    func testIdentityTransform() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let s = try MetalRenderSession(device: device)
        let img = try MetalTestEnvironment.makePixelInput(
            id: "ident", width: 2, height: 2,
            straightBGRA: [
                (b: 0, g: 0, r: 255, a: 255), (b: 0, g: 255, r: 0, a: 255),
                (b: 255, g: 0, r: 0, a: 255), (b: 0, g: 0, r: 0, a: 255)])
        let frame = try s.execute(try MetalTestEnvironment.singleImageGraph(
            width: 2, height: 2, profile: .rgba16FloatLinear, pixels: img, transform: .identity))
        XCTAssertEqual(MetalTestEnvironment.pixel(frame, x: 0, y: 0).r, 255)
        XCTAssertEqual(MetalTestEnvironment.pixel(frame, x: 1, y: 1).a, 255)
    }

    // #11 integer translation (opaque, exact): translate a 1x1 red into a 2x1 canvas's right cell.
    func testIntegerTranslation() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let s = try MetalRenderSession(device: device)
        let img = try solidImage(0, 0, 255, 255, id: "trans")
        // Translate by +1 point in x (raw 65536). Source 1x1 at x∈[1,2).
        let t = FixedAffineTransform2D.translation(tx: CanvasScalar.unitsPerPoint, ty: 0)
        let frame = try s.execute(try MetalTestEnvironment.singleImageGraph(
            width: 2, height: 1, profile: .rgba16FloatLinear, pixels: img, transform: t))
        let left = MetalTestEnvironment.pixel(frame, x: 0, y: 0)
        let right = MetalTestEnvironment.pixel(frame, x: 1, y: 0)
        XCTAssertEqual(left.a, 0, "left cell untouched (transparent)")
        XCTAssertEqual(right.r, 255, "right cell red")
        XCTAssertEqual(right.a, 255)
    }

    // #12 integer-factor scaling (opaque, exact): downscale a UNIFORM 4x4 red ×0.5 into a 2x2 canvas.
    // A uniform source is exact under bilinear for any interior sample (no clampToZero border bleed: the
    // pixel centres map to uv {0.25,0.75}, ≥1 texel from every edge), so integer scaling stays exact.
    func testIntegerScale() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let s = try MetalRenderSession(device: device)
        let cells: [(b: UInt8, g: UInt8, r: UInt8, a: UInt8)] =
            Array(repeating: (b: 0, g: 0, r: 255, a: 255), count: 16)
        let img = try MetalTestEnvironment.makePixelInput(id: "scale", width: 4, height: 4, straightBGRA: cells)
        let scale = FixedAffineTransform2D.scale(scaleX: 500_000, scaleY: 500_000)  // ×0.5
        let frame = try s.execute(try MetalTestEnvironment.singleImageGraph(
            width: 2, height: 2, profile: .rgba16FloatLinear, pixels: img, transform: scale))
        for y in 0..<2 { for x in 0..<2 {
            let p = MetalTestEnvironment.pixel(frame, x: x, y: y)
            XCTAssertEqual(p.r, 255, "scaled (\(x),\(y)) red"); XCTAssertEqual(p.a, 255)
        }}
    }

    // #13 rotation: bounded invariants (fractional bilinear) — not exact CPU-vs-GPU bytes
    func testRotationBoundedInvariants() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let s = try MetalRenderSession(device: device)
        // A solid opaque red 4x4 rotated about origin by a small angle: the centre stays red & opaque;
        // bilinear at the rotated edges may differ in precision (bounded), but the centre is covered.
        let img = try MetalTestEnvironment.makePixelInput(
            id: "rot", width: 4, height: 4,
            straightBGRA: Array(repeating: (b: 0, g: 0, r: 255, a: 255), count: 16))
        // Rotate +5° about the canvas; translate to keep centre roughly centred.
        let rot = try FixedAffineTransform2D.rotation(degreesTimesUnitsPerDegree: 5_000)
        let frame = try s.execute(try MetalTestEnvironment.singleImageGraph(
            width: 4, height: 4, profile: .rgba16FloatLinear, pixels: img, transform: rot))
        // Bounded invariant: the centre pixel is substantially red and opaque-ish (covered by the source).
        let c = MetalTestEnvironment.pixel(frame, x: 1, y: 1)
        XCTAssertGreaterThan(c.r, 100, "rotated centre should be substantially red, got \(c.r)")
    }

    // #14 hard pixel-center clip (R4-A) — exact: clip an opaque 2x1 to the left pixel.
    func testHardPixelCenterClip() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let s = try MetalRenderSession(device: device)
        let img = try MetalTestEnvironment.makePixelInput(
            id: "clip", width: 2, height: 1,
            straightBGRA: [(b: 0, g: 0, r: 255, a: 255), (b: 255, g: 0, r: 0, a: 255)])
        // Clip rect [0,1)x[0,1) in points → only pixel column 0 (center 0.5) is inside.
        let clip = try FixedRect(
            x: CanvasScalar(rawValue: 0), y: CanvasScalar(rawValue: 0),
            width: CanvasScalar(rawValue: CanvasScalar.unitsPerPoint),
            height: CanvasScalar(rawValue: CanvasScalar.unitsPerPoint))
        let frame = try s.execute(try MetalTestEnvironment.singleImageGraph(
            width: 2, height: 1, profile: .rgba16FloatLinear, pixels: img, clip: clip))
        let left = MetalTestEnvironment.pixel(frame, x: 0, y: 0)
        let right = MetalTestEnvironment.pixel(frame, x: 1, y: 0)
        XCTAssertEqual(left.r, 255, "clipped-in left red")
        XCTAssertEqual(left.a, 255)
        XCTAssertEqual(right.a, 0, "clipped-out right transparent")
    }

    // #14a empty clip skips enclosed draws (no zero-sized scissor)
    func testEmptyClipSkipsEnclosedDraws() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let s = try MetalRenderSession(device: device)
        let img = try solidImage(0, 0, 255, 255, id: "emptyclip")
        // A clip rect entirely outside the 1x1 canvas: x ∈ [10,11) points → empty intersection.
        let clip = try FixedRect(
            x: CanvasScalar(rawValue: 10 * CanvasScalar.unitsPerPoint),
            y: CanvasScalar(rawValue: 0),
            width: CanvasScalar(rawValue: CanvasScalar.unitsPerPoint),
            height: CanvasScalar(rawValue: CanvasScalar.unitsPerPoint))
        let frame = try s.execute(try MetalTestEnvironment.singleImageGraph(
            width: 1, height: 1, profile: .rgba16FloatLinear, pixels: img, clip: clip))
        let p = MetalTestEnvironment.pixel(frame, x: 0, y: 0)
        XCTAssertEqual([p.b, p.g, p.r, p.a], [0, 0, 0, 0], "empty clip ⇒ draw skipped ⇒ canvas stays transparent")
    }

    // #15 transparent sampling outside source bounds: a 1x1 source scaled into a 2x2 canvas at half size
    // leaves the uncovered cells transparent (clampToZero border).
    func testSamplingOutsideSourceIsTransparent() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let s = try MetalRenderSession(device: device)
        let img = try solidImage(0, 0, 255, 255, id: "outside")
        // Identity transform: source 1x1 covers only canvas pixel (0,0); the rest is uncovered.
        let frame = try s.execute(try MetalTestEnvironment.singleImageGraph(
            width: 2, height: 2, profile: .rgba16FloatLinear, pixels: img, transform: .identity))
        XCTAssertEqual(MetalTestEnvironment.pixel(frame, x: 0, y: 0).r, 255)
        XCTAssertEqual(MetalTestEnvironment.pixel(frame, x: 1, y: 0).a, 0)
        XCTAssertEqual(MetalTestEnvironment.pixel(frame, x: 0, y: 1).a, 0)
        XCTAssertEqual(MetalTestEnvironment.pixel(frame, x: 1, y: 1).a, 0)
    }

    // #16 clear-to-transparent-black
    func testClearToTransparentBlack() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let s = try MetalRenderSession(device: device)
        let frame = try s.execute(try MetalTestEnvironment.clearOnlyGraph(width: 3, height: 2, profile: .rgba16FloatLinear))
        for y in 0..<2 { for x in 0..<3 {
            let p = MetalTestEnvironment.pixel(frame, x: x, y: y)
            XCTAssertEqual([p.b, p.g, p.r, p.a], [0, 0, 0, 0])
        }}
    }

    // #26 non-1080x1920 canvas renders (derived dimensions, not hardcoded)
    func testSmallCanvasDerivedDimensions() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let s = try MetalRenderSession(device: device)
        let smallCells: [(b: UInt8, g: UInt8, r: UInt8, a: UInt8)] =
            Array(repeating: (b: 0, g: 0, r: 255, a: 255), count: 21)
        let img = try MetalTestEnvironment.makePixelInput(
            id: "small", width: 7, height: 3, straightBGRA: smallCells)
        let frame = try s.execute(try MetalTestEnvironment.singleImageGraph(
            width: 7, height: 3, profile: .rgba16FloatLinear, pixels: img))
        XCTAssertEqual(frame.dimensions.width, 7)
        XCTAssertEqual(frame.dimensions.height, 3)
        XCTAssertEqual(MetalTestEnvironment.pixel(frame, x: 3, y: 1).r, 255)
    }

    // MARK: - Corrective Issue 1 — partial-alpha colour edge, bilinear in the LINEAR domain (two-sided)

    /// Per-channel byte tolerance accounting for rgba16Float storage + 8-bit quantization (§1.5a).
    private static let T = 3

    /// Shared body: a 2-wide partial-alpha colour edge (col0 opaque red a=255; col1 green a=64) drawn
    /// upscaled ×`scale` into a `2*scale × 1` canvas. For each output column compute the GPU sample position,
    /// the linear-domain oracle and the filter-first oracle, and assert (corrective §1.5/#11):
    ///   * GPU output ≤ T of `linearDomainOracle` at every column, AND
    ///   * at the straddling columns `filterFirstOracle` differs from `linearDomainOracle` by > T
    ///     (so the rejected filter-first implementation would be caught).
    private func runPartialAlphaEdge(scale: Int) throws {
        let device = try MetalTestEnvironment.requireDevice()
        let s = try MetalRenderSession(device: device)
        // col0: opaque red; col1: green at a=64 — a sharp partial-alpha colour edge.
        let src = try MetalTestEnvironment.makePixelInput(
            id: "edge-\(scale)", width: 2, height: 1,
            straightBGRA: [(b: 0, g: 0, r: 255, a: 255), (b: 0, g: 255, r: 0, a: 64)])
        let n00 = MetalTestEnvironment.normalizeTexel(MetalTestEnvironment.storedBGRA(src, x: 0, y: 0))
        let n10 = MetalTestEnvironment.normalizeTexel(MetalTestEnvironment.storedBGRA(src, x: 1, y: 0))
        // filter-first: bilinear of the STORED premultiplied-sRGB bytes (the rejected order), then normalize.
        let s00 = MetalTestEnvironment.storedBGRA(src, x: 0, y: 0)
        let s10 = MetalTestEnvironment.storedBGRA(src, x: 1, y: 0)

        let outW = 2 * scale
        let scaleT = FixedAffineTransform2D.scale(
            scaleX: Int64(scale) * 1_000_000, scaleY: 1_000_000)
        let frame = try s.execute(try MetalTestEnvironment.singleImageGraph(
            width: Int64(outW), height: 1, profile: .rgba16FloatLinear, pixels: src, transform: scaleT))

        var sawEdgeGap = false
        for px in 0..<outW {
            // GPU samples the normalized texture at UV center; source-x in texel units:
            // canvasX = px + 0.5 ; sourceX(texels) = canvasX / scale ; sample center between texels.
            let sourceX = (Double(px) + 0.5) / Double(scale)
            // Texel centers are at 0.5 and 1.5; clamp-to-zero border outside [0, width].
            // Map sourceX (pixel coord) to a fractional position between texel centers.
            // texelIndexF: position relative to texel centers (center0 at 0.5, center1 at 1.5).
            let between = sourceX - 0.5                    // 0 at center0, 1 at center1
            let fx = min(1.0, max(0.0, between))
            // For clampToZero, outside the [0.5,1.5] band one neighbour is the border (transparent zero).
            // We restrict the assertion to the interior band where both taps are real texels.
            let interior = sourceX >= 0.5 && sourceX <= 1.5
            guard interior else { continue }

            // linear-domain oracle: interpolate normalized linear-premultiplied corners.
            let linOut = MetalTestEnvironment.bilinear(n00, n10, n00, n10, fx: fx, fy: 0)
            let expected = MetalTestEnvironment.encodeFinal(linOut)

            // filter-first oracle: interpolate stored premultiplied-sRGB bytes, then normalize+encode.
            func mixB(_ a: UInt8, _ b: UInt8) -> UInt8 {
                UInt8((Double(a) * (1 - fx) + Double(b) * fx).rounded())
            }
            let filtByte = (b: mixB(s00.b, s10.b), g: mixB(s00.g, s10.g),
                            r: mixB(s00.r, s10.r), a: mixB(s00.a, s10.a))
            let filtNorm = MetalTestEnvironment.normalizeTexel(filtByte)
            let filterFirst = MetalTestEnvironment.encodeFinal(filtNorm)

            let p = MetalTestEnvironment.pixel(frame, x: px, y: 0)
            // (1) corrected GPU output within T of the linear-domain oracle.
            XCTAssertLessThanOrEqual(abs(Int(p.r) - Int(expected.r)), Self.T, "col \(px) r: gpu \(p.r) exp \(expected.r)")
            XCTAssertLessThanOrEqual(abs(Int(p.g) - Int(expected.g)), Self.T, "col \(px) g: gpu \(p.g) exp \(expected.g)")
            XCTAssertLessThanOrEqual(abs(Int(p.b) - Int(expected.b)), Self.T, "col \(px) b: gpu \(p.b) exp \(expected.b)")
            XCTAssertLessThanOrEqual(abs(Int(p.a) - Int(expected.a)), Self.T, "col \(px) a: gpu \(p.a) exp \(expected.a)")

            // (2) at a straddling column (fx near 0.5) the filter-first oracle is far from linear-domain.
            if fx > 0.25 && fx < 0.75 {
                let gap = max(abs(Int(filterFirst.r) - Int(expected.r)),
                              max(abs(Int(filterFirst.g) - Int(expected.g)),
                                  abs(Int(filterFirst.b) - Int(expected.b))))
                if gap > Self.T { sawEdgeGap = true }
            }
        }
        XCTAssertTrue(sawEdgeGap,
            "the filter-first oracle must differ from the linear-domain oracle by > T at the edge — " +
            "otherwise the test could not catch the rejected implementation")
    }

    // C-1 scaling
    func testPartialAlphaColorEdgeBilinearInLinearDomain() throws {
        try runPartialAlphaEdge(scale: 3)
    }

    /// Generic two-sided partial-alpha edge test under an arbitrary affine `transform`. For each interior
    /// output texel it inverts the transform to find the GPU's source sample point, then computes BOTH the
    /// linear-domain oracle (correct) and the filter-first oracle (rejected order), and asserts:
    ///   * GPU output ≤ T of the linear-domain oracle at every interior texel, AND
    ///   * the filter-first oracle differs from the linear-domain oracle by > T at ≥1 straddling texel
    ///     (so a filter-first implementation would be outside T → the test catches the rejected impl).
    /// Works for scaling AND rotation (the only difference is the transform).
    private func runTwoSidedEdge(
        id: String, src: ResolvedPixelInput, transform: FixedAffineTransform2D,
        canvasW: Int, canvasH: Int
    ) throws {
        let device = try MetalTestEnvironment.requireDevice()
        let s = try MetalRenderSession(device: device)
        let frame = try s.execute(try MetalTestEnvironment.singleImageGraph(
            width: Int64(canvasW), height: Int64(canvasH), profile: .rgba16FloatLinear,
            pixels: src, transform: transform))

        // The executor maps source-pixel (sx,sy) → canvas point: canvas = L·src + T  (in point/pixel units),
        // where L = [[a,c],[b,d]]/1e6 and T = (tx,ty)/65536 (the 65536 from CanvasScalar cancels — see
        // MetalSceneCompositor.imageQuad). Invert L to find the source point a given output pixel samples.
        let U = Double(CanvasScalar.unitsPerPoint)
        let la = Double(transform.a) / 1_000_000, lc = Double(transform.c) / 1_000_000
        let lb = Double(transform.b) / 1_000_000, ld = Double(transform.d) / 1_000_000
        let tx = Double(transform.tx) / U, ty = Double(transform.ty) / U
        let det = la * ld - lc * lb
        XCTAssertNotEqual(det, 0, "transform must be invertible")
        let iA = ld / det, iC = -lc / det, iB = -lb / det, iD = la / det   // inverse linear part

        let w = src.dimensions.width, h = src.dimensions.height
        func texel(_ x: Int, _ y: Int) -> MetalTestEnvironment.LinPremul {
            MetalTestEnvironment.normalizeTexel(MetalTestEnvironment.storedBGRA(src, x: x, y: y))
        }
        func storedByte(_ x: Int, _ y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
            MetalTestEnvironment.storedBGRA(src, x: x, y: y)
        }

        var sawEdgeGap = false
        for py in 0..<canvasH { for px in 0..<canvasW {
            // canvas point of the pixel center; subtract T then apply inverse L → source pixel coord.
            let cx = Double(px) + 0.5 - tx
            let cy = Double(py) + 0.5 - ty
            let srcX = iA * cx + iC * cy
            let srcY = iB * cx + iD * cy
            // Bilinear taps around the texel centers: texel center i is at i+0.5 in pixel coords.
            let fx0 = srcX - 0.5, fy0 = srcY - 0.5
            let x0 = Int(floor(fx0)), y0 = Int(floor(fy0))
            let fx = fx0 - Double(x0), fy = fy0 - Double(y0)
            // Only assert where all four taps are inside the source (interior; clampToZero elsewhere).
            guard x0 >= 0, x0 + 1 < w, y0 >= 0, y0 + 1 < h else { continue }

            // linear-domain oracle.
            let lin = MetalTestEnvironment.bilinear(
                texel(x0, y0), texel(x0 + 1, y0), texel(x0, y0 + 1), texel(x0 + 1, y0 + 1), fx: fx, fy: fy)
            let expected = MetalTestEnvironment.encodeFinal(lin)

            // filter-first oracle: bilinear of stored premultiplied-sRGB bytes, then normalize+encode.
            func mixB(_ a: UInt8, _ b: UInt8, _ t: Double) -> Double { Double(a) * (1 - t) + Double(b) * t }
            func bilB(_ sel: (((b: UInt8, g: UInt8, r: UInt8, a: UInt8)) -> UInt8)) -> UInt8 {
                let t00 = sel(storedByte(x0, y0)), t10 = sel(storedByte(x0 + 1, y0))
                let t01 = sel(storedByte(x0, y0 + 1)), t11 = sel(storedByte(x0 + 1, y0 + 1))
                let top = mixB(t00, t10, fx), bot = mixB(t01, t11, fx)
                return UInt8(min(255.0, max(0.0, (top * (1 - fy) + bot * fy).rounded())))
            }
            let filtByte = (b: bilB { $0.b }, g: bilB { $0.g }, r: bilB { $0.r }, a: bilB { $0.a })
            let filterFirst = MetalTestEnvironment.encodeFinal(MetalTestEnvironment.normalizeTexel(filtByte))

            let p = MetalTestEnvironment.pixel(frame, x: px, y: py)
            // (1) GPU within T of the linear-domain oracle.
            XCTAssertLessThanOrEqual(abs(Int(p.r) - Int(expected.r)), Self.T, "\(id) (\(px),\(py)) r")
            XCTAssertLessThanOrEqual(abs(Int(p.g) - Int(expected.g)), Self.T, "\(id) (\(px),\(py)) g")
            XCTAssertLessThanOrEqual(abs(Int(p.b) - Int(expected.b)), Self.T, "\(id) (\(px),\(py)) b")
            XCTAssertLessThanOrEqual(abs(Int(p.a) - Int(expected.a)), Self.T, "\(id) (\(px),\(py)) a")

            // (2) at a straddling texel the filter-first oracle is far from the linear-domain oracle.
            if fx > 0.2 && fx < 0.8 {
                let gap = max(abs(Int(filterFirst.r) - Int(expected.r)),
                              max(abs(Int(filterFirst.g) - Int(expected.g)),
                                  max(abs(Int(filterFirst.b) - Int(expected.b)),
                                      abs(Int(filterFirst.a) - Int(expected.a)))))
                if gap > Self.T { sawEdgeGap = true }
            }
        }}
        XCTAssertTrue(sawEdgeGap,
            "\(id): the filter-first oracle must differ from the linear-domain oracle by > T at the edge — " +
            "otherwise the test could not catch the rejected implementation")
    }

    // C-2 rotation — TWO-SIDED (corrective Rev-4 pt.1): GPU ≤ T vs linear-domain oracle AND filter-first > T.
    func testPartialAlphaColorEdgeRotationInLinearDomain() throws {
        // A wide partial-alpha colour edge so rotated taps straddle it across several interior texels:
        // left half opaque red, right half green a=64 (4x4 source: cols 0-1 red, cols 2-3 green).
        var cells: [(b: UInt8, g: UInt8, r: UInt8, a: UInt8)] = []
        for _ in 0..<4 { for x in 0..<4 {
            cells.append(x < 2 ? (b: 0, g: 0, r: 255, a: 255) : (b: 0, g: 255, r: 0, a: 64))
        }}
        let src = try MetalTestEnvironment.makePixelInput(id: "rot-edge", width: 4, height: 4, straightBGRA: cells)
        // Upscale ×4 then rotate 7° (about the source origin) — a non-trivial fractional sampling.
        let scale = FixedAffineTransform2D.scale(scaleX: 4_000_000, scaleY: 4_000_000)
        let rot = try FixedAffineTransform2D.rotation(degreesTimesUnitsPerDegree: 7_000)
        let composed = try rot.concatenating(scale)
        try runTwoSidedEdge(id: "rotation", src: src, transform: composed, canvasW: 16, canvasH: 16)
    }

    // C-2a normalization 1:1 texel mapping — small + odd sizes (§1.2a, correction #2).
    func testNormalization1to1MappingExact() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let s = try MetalRenderSession(device: device)
        let sizes: [(w: Int, h: Int)] = [(3, 1), (1, 3), (3, 3), (5, 3)]
        for size in sizes {
            // Position-encoded opaque colours: r = (x*40+10)%256, g = (y*50+20)%256, b = ((x+y)*30+5)%256.
            var cells: [(b: UInt8, g: UInt8, r: UInt8, a: UInt8)] = []
            for y in 0..<size.h { for x in 0..<size.w {
                cells.append((
                    b: UInt8(((x + y) * 30 + 5) % 256),
                    g: UInt8((y * 50 + 20) % 256),
                    r: UInt8((x * 40 + 10) % 256),
                    a: 255))
            }}
            let src = try MetalTestEnvironment.makePixelInput(
                id: "map-\(size.w)x\(size.h)", width: size.w, height: size.h, straightBGRA: cells)
            let frame = try s.execute(try MetalTestEnvironment.singleImageGraph(
                width: Int64(size.w), height: Int64(size.h), profile: .rgba16FloatLinear,
                pixels: src, transform: .identity))
            for y in 0..<size.h { for x in 0..<size.w {
                let cell = cells[y * size.w + x]
                let p = MetalTestEnvironment.pixel(frame, x: x, y: y)
                // Each output texel == opaque round-trip of ITS OWN source texel (no shift/flip/bleed).
                XCTAssertEqual(p.r, MetalTestEnvironment.opaqueRoundTripByte(cell.r), "\(size.w)x\(size.h) (\(x),\(y)) r")
                XCTAssertEqual(p.g, MetalTestEnvironment.opaqueRoundTripByte(cell.g), "\(size.w)x\(size.h) (\(x),\(y)) g")
                XCTAssertEqual(p.b, MetalTestEnvironment.opaqueRoundTripByte(cell.b), "\(size.w)x\(size.h) (\(x),\(y)) b")
                XCTAssertEqual(p.a, 255, "\(size.w)x\(size.h) (\(x),\(y)) a")
            }}
        }
    }
}
