import XCTest
import Foundation
import Metal
import AnimiEngineCore
import AnimiEngineRenderModel
import AnimiEngineRenderGraph
import AnimiEngineMetalRender

/// CP7.8 — `MetalRenderSession.render(_:into:textureBindings:)` GPU-direct texture-backed video path.
///
/// Proves: (1) binding validation fails closed with typed errors (missing / wrong device / wrong dims /
/// wrong format / missing shaderRead); (2) the existing bytes `execute(_:)` path is unchanged and rejects
/// a dynamic resource with no bindings; (3) GPU orientation is BIT-IDENTICAL to the CPU `rotateBGRA`
/// oracle for 0/90/180/270 (a dynamic raw texture + quarter-turn renders identically to the equivalent
/// CPU-rotated bytes input). No silent fallback anywhere.
final class CP78TextureBindingTests: XCTestCase {

    // MARK: - Helpers

    /// Premultiplied BGRA bytes for a straight (b,g,r,a) grid — matches `MetalTestEnvironment.makePixelInput`.
    private func premultipliedBytes(_ straight: [(b: UInt8, g: UInt8, r: UInt8, a: UInt8)], w: Int, h: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let s = straight[i]; let a = Int(s.a)
            func pm(_ c: UInt8) -> UInt8 { UInt8((Int(c) * a + 127) / 255) }
            out[i*4+0] = pm(s.b); out[i*4+1] = pm(s.g); out[i*4+2] = pm(s.r); out[i*4+3] = s.a
        }
        return out
    }

    /// The CPU oracle rotation (the exact index remap used by the app's `NextVideoBlockResolver.rotateBGRA`).
    /// Rotate a top-first BGRA buffer by N clockwise quarter-turns; odd turns swap W/H.
    private func rotateBGRA(_ src: [UInt8], w: Int, h: Int, turns t: Int) -> (bytes: [UInt8], w: Int, h: Int) {
        let turns = ((t % 4) + 4) % 4
        if turns == 0 { return (src, w, h) }
        let (dw, dh) = (turns % 2 == 0) ? (w, h) : (h, w)
        var dst = [UInt8](repeating: 0, count: dw * dh * 4)
        for y in 0..<h {
            for x in 0..<w {
                let (dx, dy): (Int, Int)
                switch turns {
                case 1: dx = h - 1 - y; dy = x
                case 2: dx = w - 1 - x; dy = h - 1 - y
                default: dx = y; dy = w - 1 - x
                }
                let s = (y * w + x) * 4, d = (dy * dw + dx) * 4
                for k in 0..<4 { dst[d+k] = src[s+k] }
            }
        }
        return (dst, dw, dh)
    }

    /// A raw `.bgra8Unorm` `.shaderRead` texture (mirrors what a CVMetalTextureCache hands the resolver),
    /// uploaded with the given premultiplied bytes (track-native orientation).
    private func makeRawTexture(_ device: MTLDevice, bytes: [UInt8], w: Int, h: Int,
                                usage: MTLTextureUsage = [.shaderRead], format: MTLPixelFormat = .bgra8Unorm) throws -> MTLTexture {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
        td.usage = usage
        td.storageMode = .shared
        let tex = try XCTUnwrap(device.makeTexture(descriptor: td))
        if format == .bgra8Unorm {
            bytes.withUnsafeBytes { raw in
                tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: w * 4)
            }
        }
        return tex
    }

    private func makeTarget(_ device: MTLDevice, w: Int, h: Int) throws -> MTLTexture {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]; td.storageMode = .shared
        return try XCTUnwrap(device.makeTexture(descriptor: td))
    }

    private func readback(_ tex: MTLTexture) -> [UInt8] {
        let w = tex.width, h = tex.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { raw in
            tex.getBytes(raw.baseAddress!, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        return bytes
    }

    /// A full-canvas single-image graph whose ONE draw references `resourceID` (identity transform fills
    /// the canvas). `dynamic` selects the dynamic-texture declare vs the bytes declare.
    private func graph(canvasW: Int64, canvasH: Int64, resourceID: String,
                       bytesInput: ResolvedPixelInput? = nil,
                       dynamic: (w: Int64, h: Int64, turns: Int)? = nil) throws -> RenderGraph {
        let config = try MetalTestEnvironment.configuration(width: canvasW, height: canvasH, profile: .rgba16FloatLinear)
        var cmds: [RenderCommand] = []; var o = 0
        func add(_ p: RenderCommandPayload) throws { cmds.append(try MetalTestEnvironment.command(o, p)); o += 1 }
        if let dyn = dynamic {
            try add(.declareResource(try RenderResourceDescriptor(
                dynamicTextureSourceID: resourceID, width: dyn.w, height: dyn.h, pixelFormat: .bgra8,
                orientation: .up, orientationQuarterTurns: dyn.turns, colorContract: .task003)))
        } else {
            try add(.declareResource(RenderResourceDescriptor(
                pixelInputID: resourceID, pixels: try XCTUnwrap(bytesInput), colorContract: .task003)))
        }
        try add(.offscreenSurface(MetalTestEnvironment.linearCanvasDescriptor(width: canvasW, height: canvasH, profile: .rgba16FloatLinear)))
        try add(.offscreenSurface(MetalTestEnvironment.sRGBSurfaceDescriptor(width: canvasW, height: canvasH)))
        try add(.clearBackground(color: .transparentBlack, targetSurfaceID: RenderSurface.linearCanvas))
        try add(.beginScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas))
        try add(.drawImage(resourceID: resourceID, transform: .identity, opacity: .opaque, targetSurfaceID: RenderSurface.linearCanvas))
        try add(.endScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas))
        try add(.finalLinearToSRGB(sourceSurfaceID: RenderSurface.linearCanvas, targetSurfaceID: RenderSurface.sRGBSurface))
        try add(.finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface))
        return try RenderGraph(configuration: config, commands: cmds)
    }

    private func bindings(_ map: [String: MTLTexture], retain: [Any] = []) -> RenderRuntimeTextureBindings {
        RenderRuntimeTextureBindings(map.mapValues { RuntimeTextureHandle(texture: $0, retain: retain) })
    }

    // A small asymmetric opaque pattern so every rotation is distinguishable.
    private func pattern(w: Int, h: Int) -> [(b: UInt8, g: UInt8, r: UInt8, a: UInt8)] {
        var out: [(b: UInt8, g: UInt8, r: UInt8, a: UInt8)] = []
        out.reserveCapacity(w * h)
        for i in 0..<(w * h) {
            let b = UInt8((i &* 40) % 256)
            let g = UInt8((i &* 70) % 256)
            let r = UInt8((i &* 110) % 256)
            out.append((b: b, g: g, r: r, a: UInt8(255)))
        }
        return out
    }

    // MARK: - Binding validation (typed errors, fail closed)

    func test_missingBinding_throwsMissingTextureBinding() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let s = try MetalRenderSession(device: device)
        let g = try graph(canvasW: 4, canvasH: 4, resourceID: "video:v:1", dynamic: (4, 4, 0))
        let target = try makeTarget(device, w: 4, h: 4)
        XCTAssertThrowsError(try s.render(g, into: GPURenderTarget(texture: target, alphaMode: .preserveAlpha), textureBindings: .none)) { err in
            guard case MetalRenderError.missingTextureBinding(let rid) = err else { return XCTFail("wrong error \(err)") }
            XCTAssertEqual(rid, "video:v:1")
        }
    }

    func test_executeReadback_rejectsDynamicResource() throws {
        // The oracle execute(_:) path takes NO bindings — a dynamic resource cannot be uploaded → typed error.
        let device = try MetalTestEnvironment.requireDevice()
        let s = try MetalRenderSession(device: device)
        let g = try graph(canvasW: 4, canvasH: 4, resourceID: "video:v:1", dynamic: (4, 4, 0))
        XCTAssertThrowsError(try s.execute(g))
    }

    func test_wrongPixelFormatBinding_throwsInvalid() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let s = try MetalRenderSession(device: device)
        let g = try graph(canvasW: 4, canvasH: 4, resourceID: "video:v:1", dynamic: (4, 4, 0))
        let badFmt = try makeRawTexture(device, bytes: [], w: 4, h: 4, usage: [.shaderRead], format: .rgba8Unorm)
        let target = try makeTarget(device, w: 4, h: 4)
        XCTAssertThrowsError(try s.render(g, into: GPURenderTarget(texture: target, alphaMode: .preserveAlpha),
                                          textureBindings: bindings(["video:v:1": badFmt]))) { err in
            guard case MetalRenderError.invalidTextureBinding = err else { return XCTFail("wrong error \(err)") }
        }
    }

    func test_missingShaderReadUsageBinding_throwsInvalid() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let s = try MetalRenderSession(device: device)
        let g = try graph(canvasW: 4, canvasH: 4, resourceID: "video:v:1", dynamic: (4, 4, 0))
        // renderTarget-only (no shaderRead).
        let noRead = try makeRawTexture(device, bytes: [], w: 4, h: 4, usage: [.renderTarget], format: .bgra8Unorm)
        let target = try makeTarget(device, w: 4, h: 4)
        XCTAssertThrowsError(try s.render(g, into: GPURenderTarget(texture: target, alphaMode: .preserveAlpha),
                                          textureBindings: bindings(["video:v:1": noRead]))) { err in
            guard case MetalRenderError.invalidTextureBinding = err else { return XCTFail("wrong error \(err)") }
        }
    }

    func test_wrongDimsBinding_throwsInvalid() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let s = try MetalRenderSession(device: device)
        // descriptor declares 4x4 display, turns 0 → expects raw 4x4; bind a 4x8 → mismatch.
        let g = try graph(canvasW: 4, canvasH: 4, resourceID: "video:v:1", dynamic: (4, 4, 0))
        let wrong = try makeRawTexture(device, bytes: premultipliedBytes(pattern(w: 4, h: 8), w: 4, h: 8), w: 4, h: 8)
        let target = try makeTarget(device, w: 4, h: 4)
        XCTAssertThrowsError(try s.render(g, into: GPURenderTarget(texture: target, alphaMode: .preserveAlpha),
                                          textureBindings: bindings(["video:v:1": wrong]))) { err in
            guard case MetalRenderError.invalidTextureBinding = err else { return XCTFail("wrong error \(err)") }
        }
    }

    // MARK: - Orientation parity vs CPU rotateBGRA oracle (0/90/180/270)

    func test_orientationParity_allQuarterTurns() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let s = try MetalRenderSession(device: device)
        let rawW = 4, rawH = 6   // asymmetric so rotations are distinguishable
        let straight = pattern(w: rawW, h: rawH)
        let rawPremul = premultipliedBytes(straight, w: rawW, h: rawH)

        for turns in 0...3 {
            // Display (oriented) dims = canvas dims (the draw fills the canvas at identity).
            let (rotBytes, dispW, dispH) = rotateBGRA(rawPremul, w: rawW, h: rawH, turns: turns)

            // BYTES ORACLE: a bytes input already rotated on the CPU, drawn into a dispW×dispH canvas.
            let oracleInput = try ResolvedPixelInput(
                id: try PixelInputID("oracle-\(turns)"),
                dimensions: try PixelDimensions(width: dispW, height: dispH, bytesPerRow: dispW * 4, format: .bgra8, orientation: .up),
                bytes: Data(rotBytes))
            let oracleGraph = try graph(canvasW: Int64(dispW), canvasH: Int64(dispH), resourceID: "oracle-\(turns)", bytesInput: oracleInput)
            let oracleTarget = try makeTarget(device, w: dispW, h: dispH)
            try s.render(oracleGraph, into: GPURenderTarget(texture: oracleTarget, alphaMode: .preserveAlpha))
            let oracle = readback(oracleTarget)

            // DYNAMIC: a RAW texture (track-native rawW×rawH) + quarter-turn; engine rotates on GPU.
            let rawTex = try makeRawTexture(device, bytes: rawPremul, w: rawW, h: rawH)
            let dynGraph = try graph(canvasW: Int64(dispW), canvasH: Int64(dispH), resourceID: "video:v:\(turns)", dynamic: (Int64(dispW), Int64(dispH), turns))
            let dynTarget = try makeTarget(device, w: dispW, h: dispH)
            try s.render(dynGraph, into: GPURenderTarget(texture: dynTarget, alphaMode: .preserveAlpha),
                         textureBindings: bindings(["video:v:\(turns)": rawTex]))
            let dyn = readback(dynTarget)

            XCTAssertEqual(dyn, oracle, "GPU orientation must match CPU rotateBGRA oracle for turns=\(turns)")
        }
    }

    // MARK: - Bytes path unchanged

    func test_bytesPath_stillRendersWithoutBindings() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let s = try MetalRenderSession(device: device)
        let input = try MetalTestEnvironment.makePixelInput(id: "photo", width: 4, height: 4, straightBGRA: pattern(w: 4, h: 4))
        let g = try graph(canvasW: 4, canvasH: 4, resourceID: "photo", bytesInput: input)
        // execute(_:) readback still works (no bindings).
        XCTAssertNoThrow(try s.execute(g))
        // render(into:) with empty bindings also works.
        let target = try makeTarget(device, w: 4, h: 4)
        XCTAssertNoThrow(try s.render(g, into: GPURenderTarget(texture: target, alphaMode: .preserveAlpha), textureBindings: .none))
    }
}
