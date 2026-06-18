import Metal
import AnimiEngineCore
import AnimiEngineRenderModel

/// Task-003 plan §6, §8.2, §8.4 — session-owned texture creation from RenderGraph resource descriptors.
///
/// Two responsibilities:
///   * map a `RenderSurfaceStorageFormat`/role to the exact `MTLPixelFormat` (plan §6) — never a silent
///     substitution; a capability gap surfaces as a thrown `MetalRenderError` from the throwing creator;
///   * convert an offscreen surface's `CanvasScalar`-raw dimensions (×65,536 per point) to an integer
///     pixel grid with **positivity + exact integer conversion only** — no `maxTextureDim` (plan §8.4,
///     Rev-3 correction #4).
struct MetalTextureAllocator {
    let device: MTLDevice

    /// The conservative texture↔buffer blit row alignment (plan §8.5, Rev-3 correction #2): the documented
    /// "Buffer alignment for copying an existing texture to a buffer" from the Metal Feature Set Tables is
    /// 256 B on some GPU families and 16 B on others; 256 is a safe superset for every supported family.
    /// `minimumLinearTextureAlignment(for:)` is deliberately NOT used as the blit-row API.
    static let blitRowAlignment = 256

    // MARK: - Pixel format mapping (plan §6)

    /// The `MTLPixelFormat` for a `pixelInput` source texture (always `.bgra8Unorm`, non-sRGB, so the
    /// shader owns the entire sRGB decode, plan §5.1/§6).
    static let pixelInputFormat: MTLPixelFormat = .bgra8Unorm

    /// The `MTLPixelFormat` for an offscreen surface, by role + declared storage (plan §6). The final
    /// sRGB output surface is stored as **plain** `.bgra8Unorm` (the sRGB encode is done in-shader,
    /// plan §5.3 item 4); intermediate surfaces use their storage's format.
    static func surfaceFormat(
        for descriptor: RenderResourceDescriptor
    ) throws -> MTLPixelFormat {
        guard let storage = descriptor.surfaceStorage else {
            throw MetalRenderError.surfaceStorageMismatch(
                resourceID: descriptor.resourceID, detail: "offscreen surface has no surfaceStorage")
        }
        // The final sRGB output surface is the one well-known sRGB surface id.
        if descriptor.resourceID == RenderSurface.sRGBSurface {
            // Its model storage is bgra8SRGB; the executor maps it to plain bgra8Unorm for the final write
            // because the sRGB encoding is performed in-shader (plan §5.3 item 4 / §6).
            guard storage == .bgra8SRGB else {
                throw MetalRenderError.surfaceStorageMismatch(
                    resourceID: descriptor.resourceID,
                    detail: "final sRGB surface storage \(storage) != bgra8SRGB")
            }
            return .bgra8Unorm
        }
        switch storage {
        case .bgra8SRGB: return .bgra8Unorm_srgb
        case .rgba16FloatLinear: return .rgba16Float
        }
    }

    // MARK: - Canvas-raw → pixel conversion (plan §8.4)

    /// Convert an offscreen surface descriptor's `CanvasScalar`-raw dimensions to an integer pixel grid.
    /// Positivity + exact integer conversion only; no maximum-dimension check (plan §8.4, correction #4).
    static func surfacePixelSize(_ descriptor: RenderResourceDescriptor) throws -> (width: Int, height: Int) {
        let u = CanvasScalar.unitsPerPoint
        let rawW = descriptor.width
        let rawH = descriptor.height
        guard rawW % u == 0, rawH % u == 0 else {
            throw MetalRenderError.invalidSurfaceDimensions(
                resourceID: descriptor.resourceID, width: rawW, height: rawH)
        }
        let pxW64 = rawW / u
        let pxH64 = rawH / u
        guard pxW64 > 0, pxH64 > 0 else {
            throw MetalRenderError.invalidSurfaceDimensions(
                resourceID: descriptor.resourceID, width: rawW, height: rawH)
        }
        // Int conversion may overflow on a 32-bit Int; that is a typed failure, not a trap.
        guard let pxW = Int(exactly: pxW64), let pxH = Int(exactly: pxH64) else {
            throw MetalRenderError.invalidSurfaceDimensions(
                resourceID: descriptor.resourceID, width: rawW, height: rawH)
        }
        return (pxW, pxH)
    }

    // MARK: - Texture creation

    /// Allocate a render-target offscreen surface texture (plan §8.2/§8.3). `usage` = renderTarget +
    /// shaderRead (the final-conversion pass reads the linear canvas; the output surface is blitted).
    func makeOffscreenTexture(_ descriptor: RenderResourceDescriptor) throws -> MTLTexture {
        let (pxW, pxH) = try Self.surfacePixelSize(descriptor)
        let format = try Self.surfaceFormat(for: descriptor)
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: pxW, height: pxH, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .private
        guard let texture = device.makeTexture(descriptor: td) else {
            throw MetalRenderError.textureAllocationFailed(resourceID: descriptor.resourceID)
        }
        return texture
    }

    /// Allocate a sampled source texture for a pixel input (plan §8.1). Dimensions are already pixels.
    func makePixelInputTexture(_ descriptor: RenderResourceDescriptor) throws -> MTLTexture {
        guard descriptor.width > 0, descriptor.height > 0,
              let pxW = Int(exactly: descriptor.width), let pxH = Int(exactly: descriptor.height) else {
            throw MetalRenderError.invalidSurfaceDimensions(
                resourceID: descriptor.resourceID, width: descriptor.width, height: descriptor.height)
        }
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.pixelInputFormat, width: pxW, height: pxH, mipmapped: false)
        td.usage = [.shaderRead]
        #if os(iOS)
        td.storageMode = .private
        #else
        td.storageMode = .shared
        #endif
        guard let texture = device.makeTexture(descriptor: td) else {
            throw MetalRenderError.textureAllocationFailed(resourceID: descriptor.resourceID)
        }
        return texture
    }

    /// Allocate the **normalized** linear-premultiplied source texture (corrective §1.2/§1.4). It is
    /// `rgba16Float`, `[.renderTarget, .shaderRead]`, `.private`, at the **raw texture's exact pixel
    /// dimensions** (§1.2a inv. 1: equal dims). The normalization render pass writes it; scene draws sample
    /// it with the approved R1 bilinear sampler.
    func makeNormalizedTexture(width: Int, height: Int, resourceID: String) throws -> MTLTexture {
        guard width > 0, height > 0 else {
            throw MetalRenderError.invalidSurfaceDimensions(
                resourceID: resourceID, width: Int64(width), height: Int64(height))
        }
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .private
        guard let texture = device.makeTexture(descriptor: td) else {
            throw MetalRenderError.textureAllocationFailed(resourceID: resourceID)
        }
        return texture
    }

    // MARK: - Step-11 transient coverage / accumulator textures (Rev-4 §7.2/§7.7)

    /// A 4x-MSAA `r16Float` coverage render target (transient; owned per execution, released at completion).
    func makeMSAACoverageTexture(width: Int, height: Int, resourceID: String) throws -> MTLTexture {
        guard width > 0, height > 0 else {
            throw MetalRenderError.invalidSurfaceDimensions(resourceID: resourceID, width: Int64(width), height: Int64(height))
        }
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: MetalPipelineLibrary.coverageFormat, width: width, height: height, mipmapped: false)
        td.textureType = .type2DMultisample
        td.sampleCount = MetalPipelineLibrary.coverageSampleCount
        td.usage = [.renderTarget]
        td.storageMode = .private
        guard let texture = device.makeTexture(descriptor: td) else {
            throw MetalRenderError.textureAllocationFailed(resourceID: resourceID)
        }
        return texture
    }

    /// A single-sample `r16Float` texture: an MSAA resolve target or a mask accumulator. `[.renderTarget,
    /// .shaderRead]` so it can be both written (resolve / combine) and read (apply / next combine).
    func makeCoverageResolveTexture(width: Int, height: Int, resourceID: String) throws -> MTLTexture {
        guard width > 0, height > 0 else {
            throw MetalRenderError.invalidSurfaceDimensions(resourceID: resourceID, width: Int64(width), height: Int64(height))
        }
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: MetalPipelineLibrary.coverageFormat, width: width, height: height, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .private
        guard let texture = device.makeTexture(descriptor: td) else {
            throw MetalRenderError.textureAllocationFailed(resourceID: resourceID)
        }
        return texture
    }

    /// Whether the platform requires staging-buffer upload for source textures (`.private` on iOS).
    var pixelInputNeedsStagedUpload: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }
}

/// Corrective §3 — checked `Int` arithmetic for graph/media-derived sizes, so no trap-capable `*`/`+` runs
/// on untrusted dimensions. Each op throws a caller-supplied typed error on overflow (no trap).
enum CheckedInt {
    static func mul(_ a: Int, _ b: Int, _ error: @autoclosure () -> MetalRenderError) throws -> Int {
        let (r, overflow) = a.multipliedReportingOverflow(by: b)
        if overflow { throw error() }
        return r
    }
    static func add(_ a: Int, _ b: Int, _ error: @autoclosure () -> MetalRenderError) throws -> Int {
        let (r, overflow) = a.addingReportingOverflow(b)
        if overflow { throw error() }
        return r
    }
}
