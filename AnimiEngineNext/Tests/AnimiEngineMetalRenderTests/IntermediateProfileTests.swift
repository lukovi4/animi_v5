import XCTest
import Metal
import AnimiEngineCore
import AnimiEngineRenderModel
import AnimiEngineRenderGraph
@testable import AnimiEngineMetalRender

/// Task-003 plan D3-08, §13 — both intermediate profiles are explicit, render with identical semantics,
/// and the chosen profile is never silently substituted during execution (Step 10).
final class IntermediateProfileTests: XCTestCase {

    func testBothIntermediateProfilesAreExplicit() {
        XCTAssertEqual(Set(IntermediateProfile.allCases), [.bgra8SRGB, .rgba16FloatLinear])
    }

    func testConfigurationPreservesChosenProfileWithNoSilentChange() throws {
        let canvas = try CanvasSize(width: 1080, height: 1920)
        let output = OutputContext(canvas: canvas, frameRate: try FrameRate(numerator: 30, denominator: 1))

        let reference = try RenderConfiguration(output: output, intermediateProfile: .rgba16FloatLinear)
        XCTAssertEqual(reference.intermediateProfile, .rgba16FloatLinear)

        let srgb = try RenderConfiguration(output: output, intermediateProfile: .bgra8SRGB)
        XCTAssertEqual(srgb.intermediateProfile, .bgra8SRGB)

        // Different profiles produce different configurations (no collapsing to one).
        XCTAssertNotEqual(reference, srgb)
    }

    // MARK: - Execution proofs (Step 10)

    // #6 both intermediate profiles render with the same colour semantics (per-profile bounded oracle).
    func testBothProfilesRenderWithSameSemantics() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let s = try MetalRenderSession(device: device)
        let img = try MetalTestEnvironment.makePixelInput(
            id: "prof", width: 1, height: 1, straightBGRA: [(b: 30, g: 90, r: 180, a: 255)])
        var results: [IntermediateProfile: (b: UInt8, g: UInt8, r: UInt8, a: UInt8)] = [:]
        for profile in [IntermediateProfile.rgba16FloatLinear, .bgra8SRGB] {
            let frame = try s.execute(try MetalTestEnvironment.singleImageGraph(
                width: 1, height: 1, profile: profile, pixels: img))
            results[profile] = MetalTestEnvironment.pixel(frame, x: 0, y: 0)
        }
        // Both honour the opaque round-trip; bytes may differ only by 8-bit quantization, not semantics.
        for (profile, p) in results {
            XCTAssertEqual(p.a, 255, "alpha profile \(profile)")
            XCTAssertEqual(p.r, MetalTestEnvironment.opaqueRoundTripByte(180), "r profile \(profile)")
            XCTAssertEqual(p.g, MetalTestEnvironment.opaqueRoundTripByte(90), "g profile \(profile)")
            XCTAssertEqual(p.b, MetalTestEnvironment.opaqueRoundTripByte(30), "b profile \(profile)")
        }
    }

    // #7 the chosen profile is honoured, not silently substituted: the executor uses the surface storage
    // the configuration's profile implies. We prove both profiles produce a complete frame (the executor
    // would throw surfaceStorageMismatch / fail to allocate if it substituted a mismatched format).
    func testProfileSelectionIsHonoredNotSubstituted() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let s = try MetalRenderSession(device: device)
        let img = try MetalTestEnvironment.makePixelInput(
            id: "nosub", width: 1, height: 1, straightBGRA: [(b: 0, g: 0, r: 255, a: 255)])
        // rgba16FloatLinear surface declared with its exact storage → must render.
        let f16 = try s.execute(try MetalTestEnvironment.singleImageGraph(
            width: 1, height: 1, profile: .rgba16FloatLinear, pixels: img))
        XCTAssertEqual(MetalTestEnvironment.pixel(f16, x: 0, y: 0).r, 255)
        // bgra8SRGB surface declared with its exact storage → must render.
        let f8 = try s.execute(try MetalTestEnvironment.singleImageGraph(
            width: 1, height: 1, profile: .bgra8SRGB, pixels: img))
        XCTAssertEqual(MetalTestEnvironment.pixel(f8, x: 0, y: 0).r, 255)

        // A graph whose surface storage disagrees with the configuration profile is rejected by the
        // validator at construction (no silent substitution path exists). Build a mismatched graph.
        let config = try MetalTestEnvironment.configuration(width: 1, height: 1, profile: .rgba16FloatLinear)
        // Declare the linear canvas with the WRONG intermediate profile (bgra8SRGB) vs config rgba16FloatLinear.
        let wrong = RenderResourceDescriptor(
            offscreenID: RenderSurface.linearCanvas,
            width: MetalTestEnvironment.canvasRaw(1), height: MetalTestEnvironment.canvasRaw(1),
            profile: .intermediate(.bgra8SRGB), colorContract: .task003)
        var cmds: [RenderCommand] = []
        var o = 0
        func add(_ p: RenderCommandPayload) throws { cmds.append(try RenderCommand(ordinal: o, payload: p)); o += 1 }
        try add(.offscreenSurface(wrong))
        try add(.offscreenSurface(MetalTestEnvironment.sRGBSurfaceDescriptor(width: 1, height: 1)))
        try add(.clearBackground(color: .transparentBlack, targetSurfaceID: RenderSurface.linearCanvas))
        try add(.finalLinearToSRGB(sourceSurfaceID: RenderSurface.linearCanvas, targetSurfaceID: RenderSurface.sRGBSurface))
        try add(.finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface))
        // The graph validator (run by the executor preflight) must reject the linearCanvas profile/storage
        // mismatch with the EXACT RenderGraphError.validatorColorProfileMismatch case (not any RenderGraphError).
        XCTAssertThrowsError(try {
            let g = try RenderGraph(configuration: config, commands: cmds)
            _ = try s.execute(g)
        }()) { error in
            guard case RenderGraphError.validatorColorProfileMismatch = error else {
                return XCTFail("expected validatorColorProfileMismatch, got \(error)")
            }
        }
    }

    // C-5 — exact allocator format mapping (corrective Issue 8). Pure value-level (no device required for
    // the mapping; texture creation needs one). Successful rendering alone does not prove the mapping.
    func testAllocatorFormatMappingExact() throws {
        // intermediate rgba16FloatLinear → .rgba16Float
        let lin = RenderResourceDescriptor(
            offscreenID: RenderSurface.linearCanvas,
            width: MetalTestEnvironment.canvasRaw(4), height: MetalTestEnvironment.canvasRaw(4),
            profile: .intermediate(.rgba16FloatLinear), colorContract: .task003)
        XCTAssertEqual(try MetalTextureAllocator.surfaceFormat(for: lin), .rgba16Float)

        // intermediate bgra8SRGB (a scene/linear surface, NOT the sRGB output id) → .bgra8Unorm_srgb
        let srgbInter = RenderResourceDescriptor(
            offscreenID: "scene\u{1F}x",
            width: MetalTestEnvironment.canvasRaw(4), height: MetalTestEnvironment.canvasRaw(4),
            profile: .intermediate(.bgra8SRGB), colorContract: .task003)
        XCTAssertEqual(try MetalTextureAllocator.surfaceFormat(for: srgbInter), .bgra8Unorm_srgb)

        // final sRGB surface (RenderSurface.sRGBSurface, storage bgra8SRGB) → plain .bgra8Unorm
        let finalSurf = MetalTestEnvironment.sRGBSurfaceDescriptor(width: 4, height: 4)
        XCTAssertEqual(try MetalTextureAllocator.surfaceFormat(for: finalSurf), .bgra8Unorm)

        // pixel-input source texture format → .bgra8Unorm; normalized texture → .rgba16Float (constants).
        XCTAssertEqual(MetalTextureAllocator.pixelInputFormat, .bgra8Unorm)
        guard let device = MetalTestEnvironment.makeDevice() else { return }  // mapping above is device-free
        let alloc = MetalTextureAllocator(device: device)
        let normalized = try alloc.makeNormalizedTexture(width: 4, height: 4, resourceID: "n")
        XCTAssertEqual(normalized.pixelFormat, .rgba16Float)
    }

    // C-5 mismatch — a final sRGB descriptor whose storage ≠ bgra8SRGB fails closed.
    func testAllocatorFormatMappingMismatchFailsClosed() throws {
        // The sRGBSurface id with an rgba16FloatLinear storage is contradictory → surfaceStorageMismatch.
        let bad = RenderResourceDescriptor(
            offscreenID: RenderSurface.sRGBSurface,
            width: MetalTestEnvironment.canvasRaw(4), height: MetalTestEnvironment.canvasRaw(4),
            profile: .intermediate(.rgba16FloatLinear), colorContract: .task003)
        XCTAssertThrowsError(try MetalTextureAllocator.surfaceFormat(for: bad)) { error in
            guard case MetalRenderError.surfaceStorageMismatch = error else {
                return XCTFail("expected surfaceStorageMismatch, got \(error)")
            }
        }
    }
}
