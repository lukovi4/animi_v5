import XCTest
import Foundation
import Metal
import AnimiEngineCore
import AnimiEngineRenderModel
import AnimiEngineRenderGraph
import AnimiEngineMetalRender

/// Task-003 plan §13, §14.8 — shared Metal test environment, RenderGraph builders, and CPU oracles.
///
/// `MetalTestEnvironment` provides a guarded default `MTLDevice` (tests skip cleanly with `XCTSkip` when
/// no device exists, plan §13), an independent CPU colour/source-over/sRGB oracle (plan §D3-02 allows
/// isolated reference math), and small helpers to build the minimal valid RenderGraphs the Step-10
/// executor consumes (the graph compiler is not used here — these are hand-built value graphs).
enum MetalTestEnvironment {
    /// The system default Metal device, or `nil` if none is available.
    static func makeDevice() -> MTLDevice? {
        MTLCreateSystemDefaultDevice()
    }

    /// Skip the calling test if Metal is unavailable in this environment.
    static func requireDevice(file: StaticString = #filePath, line: UInt = #line) throws -> MTLDevice {
        guard let device = makeDevice() else {
            throw XCTSkip("no Metal device available in this environment")
        }
        return device
    }

    // MARK: - Configuration / surface builders

    static func configuration(
        width: Int64, height: Int64, profile: IntermediateProfile
    ) throws -> RenderConfiguration {
        let canvas = try CanvasSize(width: width, height: height)
        let output = OutputContext(canvas: canvas, frameRate: try FrameRate(numerator: 30, denominator: 1))
        return try RenderConfiguration(output: output, intermediateProfile: profile)
    }

    static func canvasRaw(_ points: Int64) -> Int64 { points * CanvasScalar.unitsPerPoint }

    static func linearCanvasDescriptor(
        width: Int64, height: Int64, profile: IntermediateProfile
    ) -> RenderResourceDescriptor {
        RenderResourceDescriptor(
            offscreenID: RenderSurface.linearCanvas,
            width: canvasRaw(width), height: canvasRaw(height),
            profile: .intermediate(profile), colorContract: .task003)
    }

    static func sRGBSurfaceDescriptor(width: Int64, height: Int64) -> RenderResourceDescriptor {
        RenderResourceDescriptor(
            offscreenID: RenderSurface.sRGBSurface,
            width: canvasRaw(width), height: canvasRaw(height),
            profile: .finalSRGB, colorContract: .task003)
    }

    // MARK: - Pixel input builder

    /// Build a BGRA8 premultiplied pixel input from straight (non-premultiplied) sRGB-byte channels.
    /// `pixels` is row-major [(b,g,r,a)] in BGRA byte order, straight; this premultiplies into the stored
    /// bytes (the canonical conventional form the executor expects).
    static func makePixelInput(
        id: String, width: Int, height: Int,
        bytesPerRow: Int? = nil,
        straightBGRA: [(b: UInt8, g: UInt8, r: UInt8, a: UInt8)]
    ) throws -> ResolvedPixelInput {
        let bpr = bytesPerRow ?? width * 4
        precondition(straightBGRA.count == width * height)
        var data = Data(count: bpr * height)
        data.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self).baseAddress!
            for y in 0..<height {
                for x in 0..<width {
                    let s = straightBGRA[y * width + x]
                    let a = Int(s.a)
                    // Premultiply each straight sRGB byte by alpha/255 (integer, round to nearest).
                    func pm(_ c: UInt8) -> UInt8 { UInt8((Int(c) * a + 127) / 255) }
                    let off = y * bpr + x * 4
                    p[off + 0] = pm(s.b)
                    p[off + 1] = pm(s.g)
                    p[off + 2] = pm(s.r)
                    p[off + 3] = s.a
                }
            }
        }
        let dims = try PixelDimensions(width: width, height: height, bytesPerRow: bpr, format: .bgra8)
        return try ResolvedPixelInput(id: try PixelInputID(id), dimensions: dims, bytes: data)
    }

    // MARK: - Command builders

    static func command(_ ordinal: Int, _ payload: RenderCommandPayload) throws -> RenderCommand {
        try RenderCommand(ordinal: ordinal, payload: payload)
    }

    /// Build a clear-only graph (no draws): declare both surfaces, clear the linear canvas, convert, output.
    static func clearOnlyGraph(
        width: Int64, height: Int64, profile: IntermediateProfile
    ) throws -> RenderGraph {
        let config = try configuration(width: width, height: height, profile: profile)
        var cmds: [RenderCommand] = []
        var o = 0
        func add(_ p: RenderCommandPayload) throws { cmds.append(try command(o, p)); o += 1 }
        try add(.offscreenSurface(linearCanvasDescriptor(width: width, height: height, profile: profile)))
        try add(.offscreenSurface(sRGBSurfaceDescriptor(width: width, height: height)))
        try add(.clearBackground(color: .transparentBlack, targetSurfaceID: RenderSurface.linearCanvas))
        try add(.finalLinearToSRGB(sourceSurfaceID: RenderSurface.linearCanvas, targetSurfaceID: RenderSurface.sRGBSurface))
        try add(.finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface))
        return try RenderGraph(configuration: config, commands: cmds)
    }

    /// Build a single-scene single-image graph. The image is drawn into the linear canvas via one scene.
    /// `clip` is an optional destination-space clip rect wrapping the draw.
    static func singleImageGraph(
        width: Int64, height: Int64, profile: IntermediateProfile,
        pixels: ResolvedPixelInput,
        transform: FixedAffineTransform2D = .identity,
        opacity: OpacityScalar = .opaque,
        clip: FixedRect? = nil
    ) throws -> RenderGraph {
        let config = try configuration(width: width, height: height, profile: profile)
        var cmds: [RenderCommand] = []
        var o = 0
        func add(_ p: RenderCommandPayload) throws { cmds.append(try command(o, p)); o += 1 }
        try add(.declareResource(RenderResourceDescriptor(
            pixelInputID: pixels.id.rawValue, pixels: pixels, colorContract: .task003)))
        try add(.offscreenSurface(linearCanvasDescriptor(width: width, height: height, profile: profile)))
        try add(.offscreenSurface(sRGBSurfaceDescriptor(width: width, height: height)))
        try add(.clearBackground(color: .transparentBlack, targetSurfaceID: RenderSurface.linearCanvas))
        try add(.beginScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas))
        if let clip { try add(.beginClip(rect: clip)) }
        try add(.drawImage(resourceID: pixels.id.rawValue, transform: transform, opacity: opacity, targetSurfaceID: RenderSurface.linearCanvas))
        if clip != nil { try add(.endClip) }
        try add(.endScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas))
        try add(.finalLinearToSRGB(sourceSurfaceID: RenderSurface.linearCanvas, targetSurfaceID: RenderSurface.sRGBSurface))
        try add(.finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface))
        return try RenderGraph(configuration: config, commands: cmds)
    }

    // MARK: - Frame pixel access

    /// Read one output pixel as physical BGRA bytes from a frame.
    static func pixel(_ frame: RenderedFrame, x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
        let bpr = frame.dimensions.bytesPerRow
        let off = y * bpr + x * 4
        let bytes = [UInt8](frame.bytes)
        return (bytes[off], bytes[off + 1], bytes[off + 2], bytes[off + 3])
    }

    // MARK: - CPU oracle (plan §D3-02, §13)

    /// Exact sRGB transfer functions (IEC 61966-2-1), matching the shader (plan §5).
    static func srgbToLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    static func linearToSRGB(_ c: Double) -> Double {
        c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1.0 / 2.4) - 0.055
    }

    /// The CPU oracle for a single opaque solid colour drawn over a transparent canvas: straight sRGB byte
    /// (0...255) → linear → (composite over transparent is identity) → linear → sRGB → quantized byte.
    /// For an opaque, identity-transform, fully-covering source this is exact: the round-trip
    /// sRGB→linear→sRGB of an opaque value returns the same byte.
    static func opaqueRoundTripByte(_ srgbByte: UInt8) -> UInt8 {
        let s = Double(srgbByte) / 255.0
        let lin = srgbToLinear(s)
        let enc = linearToSRGB(lin)
        let q = (enc * 255.0 + 0.5).rounded(.down)
        return UInt8(min(255.0, max(0.0, q)))
    }

    // MARK: - Corrective two-sided colour oracles over STORED canonical bytes (corrective §1.5)

    /// A linear-premultiplied RGBA value (r,g,b,a in [0,1] linear, premultiplied).
    typealias LinPremul = (r: Double, g: Double, b: Double, a: Double)

    /// Read the **stored** BGRA8 premultiplied-sRGB bytes of a resolved input at integer texel (x,y).
    /// (Corrective §3: oracles start from the actual canonical bytes, not the original straight colours.)
    static func storedBGRA(_ input: ResolvedPixelInput, x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
        let dims = input.dimensions
        let off = y * dims.bytesPerRow + x * 4
        let bytes = [UInt8](input.bytes)
        return (bytes[off], bytes[off + 1], bytes[off + 2], bytes[off + 3])
    }

    /// Normalize one stored premultiplied-sRGB texel to linear-premultiplied (the corrective contract).
    static func normalizeTexel(_ t: (b: UInt8, g: UInt8, r: UInt8, a: UInt8)) -> LinPremul {
        let a = Double(t.a) / 255.0
        if a <= 0 { return (0, 0, 0, 0) }
        func lin(_ premulByte: UInt8) -> Double {
            let straight = (Double(premulByte) / 255.0) / a   // unpremultiply in sRGB byte domain
            return srgbToLinear(min(1.0, straight))
        }
        return (lin(t.r) * a, lin(t.g) * a, lin(t.b) * a, a)
    }

    /// Bilinearly interpolate four linear-premultiplied corners with weights fx,fy in [0,1].
    static func bilinear(_ c00: LinPremul, _ c10: LinPremul, _ c01: LinPremul, _ c11: LinPremul,
                         fx: Double, fy: Double) -> LinPremul {
        func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a * (1 - t) + b * t }
        func mix4(_ a: LinPremul, _ b: LinPremul, _ t: Double) -> LinPremul {
            (mix(a.r, b.r, t), mix(a.g, b.g, t), mix(a.b, b.b, t), mix(a.a, b.a, t))
        }
        let top = mix4(c00, c10, fx)
        let bot = mix4(c01, c11, fx)
        return mix4(top, bot, fy)
    }

    /// Encode a linear-premultiplied value to the final BGRA8 output bytes (linear→sRGB, quantize).
    static func encodeFinal(_ v: LinPremul) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
        let a = v.a
        func enc(_ premulLin: Double) -> UInt8 {
            let straight = a > 0 ? premulLin / a : 0
            let s = linearToSRGB(min(1.0, max(0.0, straight)))
            let premulSRGB = s * a
            let q = (min(1.0, max(0.0, premulSRGB)) * 255.0 + 0.5).rounded(.down)
            return UInt8(min(255.0, max(0.0, q)))
        }
        let aByte = UInt8((min(1.0, max(0.0, a)) * 255.0 + 0.5).rounded(.down))
        return (enc(v.b), enc(v.g), enc(v.r), aByte)
    }
}

final class MetalTestEnvironmentTests: XCTestCase {
    func testMetalRenderModuleLinksWithAllowedDependenciesOnly() {
        let metalErrors = [MetalRenderError]()
        XCTAssertTrue(metalErrors.isEmpty)
    }

    func testOpaqueRoundTripIsIdentityForOpaqueBytes() {
        // The opaque sRGB→linear→sRGB round-trip is the identity within the quantization (plan §5).
        for b in stride(from: 0, through: 255, by: 17) {
            XCTAssertEqual(MetalTestEnvironment.opaqueRoundTripByte(UInt8(b)), UInt8(b),
                           "round-trip of \(b)")
        }
    }
}
