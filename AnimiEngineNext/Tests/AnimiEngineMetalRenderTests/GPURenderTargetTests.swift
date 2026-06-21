import XCTest
import Foundation
import Metal
import AnimiEngineCore
import AnimiEngineRenderModel
import AnimiEngineRenderGraph
import AnimiEngineMetalRender

/// CP7.6a — `MetalRenderSession.render(_:into:)` GPU-direct path.
///
/// Proves: (1) `preserveAlpha` into an external `.bgra8Unorm` texture is BYTE-IDENTICAL to the readback
/// path `execute(_:).bytes` (so the new path is the oracle's twin); (2) `opaqueBlack` equals the CPU
/// `compositeOpaque` semantics (keep premultiplied B/G/R, force A=255); (3) invalid targets fail closed
/// with typed errors. The existing `execute(_:)` readback path is unchanged (covered by every other
/// MetalRender test + PostPromotionMatrix).
final class GPURenderTargetTests: XCTestCase {

    // MARK: - Helpers

    private func img(
        _ pixels: [(b: UInt8, g: UInt8, r: UInt8, a: UInt8)], w: Int, h: Int, id: String
    ) throws -> ResolvedPixelInput {
        try MetalTestEnvironment.makePixelInput(id: id, width: w, height: h, straightBGRA: pixels)
    }

    /// Allocate an external render target (CV-less plain texture, mirrors what a CVMetalTextureCache
    /// texture provides: .bgra8Unorm, render-target capable, on the session device).
    private func makeTarget(device: MTLDevice, w: Int, h: Int) throws -> MTLTexture {
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        return try XCTUnwrap(device.makeTexture(descriptor: td))
    }

    /// Read an external `.bgra8Unorm` `.shared` texture back to tight BGRA bytes.
    private func readback(_ tex: MTLTexture) -> [UInt8] {
        let w = tex.width, h = tex.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { raw in
            tex.getBytes(raw.baseAddress!, bytesPerRow: w * 4,
                         from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        return bytes
    }

    private func executeBytes(_ session: MetalRenderSession, _ graph: RenderGraph) throws -> [UInt8] {
        let frame = try session.execute(graph)
        // Repack to tight w*4 in case the frame's bytesPerRow is padded (it is already tight here).
        let w = frame.dimensions.width, h = frame.dimensions.height
        let bpr = frame.dimensions.bytesPerRow
        let src = [UInt8](frame.bytes)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for row in 0..<h {
            for i in 0..<(w * 4) { out[row * w * 4 + i] = src[row * bpr + i] }
        }
        return out
    }

    // MARK: - preserveAlpha byte-parity with execute(_:)

    func test_preserveAlpha_byteIdenticalToExecute_transparentPixel() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let s = try MetalRenderSession(device: device)
        let graph = try MetalTestEnvironment.singleImageGraph(
            width: 1, height: 1, profile: .rgba16FloatLinear,
            pixels: try img([(0, 0, 0, 0)], w: 1, h: 1, id: "p-transparent"))
        let expected = try executeBytes(s, graph)
        let target = try makeTarget(device: device, w: 1, h: 1)
        try s.render(graph, into: GPURenderTarget(texture: target, alphaMode: .preserveAlpha))
        XCTAssertEqual(readback(target), expected)
    }

    func test_preserveAlpha_byteIdenticalToExecute_partialAlphaPixel() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let s = try MetalRenderSession(device: device)
        for profile in [IntermediateProfile.rgba16FloatLinear, .bgra8SRGB] {
            let graph = try MetalTestEnvironment.singleImageGraph(
                width: 1, height: 1, profile: profile,
                pixels: try img([(128, 128, 128, 128)], w: 1, h: 1, id: "p-partial-\(profile)"))
            let expected = try executeBytes(s, graph)
            let target = try makeTarget(device: device, w: 1, h: 1)
            try s.render(graph, into: GPURenderTarget(texture: target, alphaMode: .preserveAlpha))
            XCTAssertEqual(readback(target), expected, "profile \(profile)")
        }
    }

    func test_preserveAlpha_byteIdenticalToExecute_asymmetric2x2() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let s = try MetalRenderSession(device: device)
        // Distinct per-pixel colours so any orientation/row-stride bug shows up.
        let pixels: [(b: UInt8, g: UInt8, r: UInt8, a: UInt8)] = [
            (255, 0, 0, 255),   // (0,0) blue
            (0, 255, 0, 255),   // (1,0) green
            (0, 0, 255, 255),   // (0,1) red
            (0, 0, 0, 128),     // (1,1) half-transparent black
        ]
        let graph = try MetalTestEnvironment.singleImageGraph(
            width: 2, height: 2, profile: .rgba16FloatLinear,
            pixels: try img(pixels, w: 2, h: 2, id: "p-2x2"))
        let expected = try executeBytes(s, graph)
        let target = try makeTarget(device: device, w: 2, h: 2)
        try s.render(graph, into: GPURenderTarget(texture: target, alphaMode: .preserveAlpha))
        XCTAssertEqual(readback(target), expected)
    }

    // MARK: - opaqueBlack matches CPU compositeOpaque

    func test_opaqueBlack_keepsBGR_forcesAlpha255_vsExecute() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let s = try MetalRenderSession(device: device)
        // Semi-transparent premultiplied content over a transparent canvas.
        let graph = try MetalTestEnvironment.singleImageGraph(
            width: 2, height: 2, profile: .rgba16FloatLinear,
            pixels: try img([(128, 64, 32, 128), (0, 0, 0, 0), (200, 200, 200, 200), (10, 20, 30, 255)],
                            w: 2, h: 2, id: "p-opaque"))
        let preserved = try executeBytes(s, graph)   // == the readback (premultiplied, real alpha)

        let target = try makeTarget(device: device, w: 2, h: 2)
        try s.render(graph, into: GPURenderTarget(texture: target, alphaMode: .opaqueBlack))
        let opaque = readback(target)

        // opaqueBlack == preserved B/G/R verbatim with alpha forced to 255 — exactly compositeOpaque.
        XCTAssertEqual(opaque.count, preserved.count)
        for px in 0..<(2 * 2) {
            let o = px * 4
            XCTAssertEqual(opaque[o + 0], preserved[o + 0], "B px \(px)")
            XCTAssertEqual(opaque[o + 1], preserved[o + 1], "G px \(px)")
            XCTAssertEqual(opaque[o + 2], preserved[o + 2], "R px \(px)")
            XCTAssertEqual(opaque[o + 3], 255, "A px \(px) must be opaque")
        }
    }

    // MARK: - invalid target → typed throws (no trap)

    func test_invalidTarget_wrongDimensions_throwsDimensionMismatch() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let s = try MetalRenderSession(device: device)
        let graph = try MetalTestEnvironment.singleImageGraph(
            width: 1, height: 1, profile: .rgba16FloatLinear,
            pixels: try img([(0, 0, 0, 255)], w: 1, h: 1, id: "p-dim"))
        let target = try makeTarget(device: device, w: 2, h: 2)   // wrong size
        XCTAssertThrowsError(try s.render(graph, into: GPURenderTarget(texture: target, alphaMode: .preserveAlpha))) { e in
            guard case MetalRenderError.surfaceDimensionMismatch = e else {
                return XCTFail("expected surfaceDimensionMismatch, got \(e)")
            }
        }
    }

    func test_invalidTarget_wrongPixelFormat_throwsInvalidRenderTarget() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let s = try MetalRenderSession(device: device)
        let graph = try MetalTestEnvironment.singleImageGraph(
            width: 1, height: 1, profile: .rgba16FloatLinear,
            pixels: try img([(0, 0, 0, 255)], w: 1, h: 1, id: "p-fmt"))
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)   // wrong format
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: td))
        XCTAssertThrowsError(try s.render(graph, into: GPURenderTarget(texture: target, alphaMode: .preserveAlpha))) { e in
            guard case MetalRenderError.invalidRenderTarget = e else {
                return XCTFail("expected invalidRenderTarget, got \(e)")
            }
        }
    }

    func test_invalidTarget_missingRenderTargetUsage_throwsInvalidRenderTarget() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let s = try MetalRenderSession(device: device)
        let graph = try MetalTestEnvironment.singleImageGraph(
            width: 1, height: 1, profile: .rgba16FloatLinear,
            pixels: try img([(0, 0, 0, 255)], w: 1, h: 1, id: "p-usage"))
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        td.usage = [.shaderRead]   // no .renderTarget
        td.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: td))
        XCTAssertThrowsError(try s.render(graph, into: GPURenderTarget(texture: target, alphaMode: .preserveAlpha))) { e in
            guard case MetalRenderError.invalidRenderTarget = e else {
                return XCTFail("expected invalidRenderTarget, got \(e)")
            }
        }
    }
}
