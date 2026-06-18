import Metal

/// Task-003 plan §9.2 — session-owned shader library, pipeline-state cache, and sampler.
///
/// Built once per session (plan §4/§8: nothing process-global). `imagePipeline(for:)` is keyed by the
/// render-target `MTLPixelFormat` (bgra8SRGB and rgba16FloatLinear canvases need distinct PSOs) and uses
/// the **fixed-function premultiplied source-over** blend descriptor (plan §5.2, approved R1/R4). The
/// final-conversion PSO uses `.replace` (writes, never blends, plan §5.3). The sampler is **bilinear,
/// clampToZero, no mip** (approved R1, plan §7.8).
final class MetalPipelineLibrary {
    private let device: MTLDevice
    private let library: MTLLibrary
    private let imageVertex: MTLFunction
    private let imageFragment: MTLFunction
    private let fullscreenVertex: MTLFunction
    private let finalFragment: MTLFunction
    private let normalizeFragment: MTLFunction
    // Step-11 functions.
    private let coverageVertex: MTLFunction
    private let coverageFragment: MTLFunction
    private let shapeApplyFragment: MTLFunction
    private let maskCombineFragment: MTLFunction
    private let maskApplyFragment: MTLFunction
    private let matteApplyFragment: MTLFunction
    // Step-12 functions.
    private let fadeFragment: MTLFunction
    private let slideFragment: MTLFunction

    private var imagePipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private var finalPipelineState: MTLRenderPipelineState?
    private var normalizePipelineState: MTLRenderPipelineState?
    // Step-11 caches.
    private var coveragePipelineState: MTLRenderPipelineState?
    private var maskCombinePipelineState: MTLRenderPipelineState?
    private var shapeApplyPipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private var maskApplyPipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private var matteApplyPipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    // Step-12 caches.
    private var fadePipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private var slidePipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private let linearSampler: MTLSamplerState

    /// Step-11 (§7.2) — the required MSAA sample count for coverage rasterization.
    static let coverageSampleCount = 4
    /// Step-11 — coverage texture format.
    static let coverageFormat: MTLPixelFormat = .r16Float

    init(device: MTLDevice, loader: ShaderLibraryLoader) throws {
        self.device = device
        let library = try loader.makeLibrary(device: device)
        self.library = library

        self.imageVertex = try Self.function("image_vertex", in: library)
        self.imageFragment = try Self.function("image_fragment", in: library)
        self.fullscreenVertex = try Self.function("fullscreen_vertex", in: library)
        self.finalFragment = try Self.function("final_srgb_fragment", in: library)
        self.normalizeFragment = try Self.function("normalize_fragment", in: library)
        // Step-11 functions (loaded eagerly; missing function is a typed failure, §8).
        self.coverageVertex = try Self.function("coverage_vertex", in: library)
        self.coverageFragment = try Self.function("coverage_fragment", in: library)
        self.shapeApplyFragment = try Self.function("shape_apply_fragment", in: library)
        self.maskCombineFragment = try Self.function("mask_combine_fragment", in: library)
        self.maskApplyFragment = try Self.function("mask_apply_fragment", in: library)
        self.matteApplyFragment = try Self.function("matte_apply_fragment", in: library)
        // Step-12 functions (loaded eagerly; missing function is a typed failure).
        self.fadeFragment = try Self.function("fade_fragment", in: library)
        self.slideFragment = try Self.function("slide_fragment", in: library)

        // §7.2/§8 — require 4x MSAA capability up front; no lazy creation during execute.
        guard device.supportsTextureSampleCount(Self.coverageSampleCount) else {
            throw MetalRenderError.requiredSampleCountUnsupported(sampleCount: Self.coverageSampleCount)
        }

        // Bilinear, clampToZero, no mip (approved R1, plan §7.8). clampToZero gives transparent border so
        // sampling outside the source contributes nothing (plan §7.6).
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.mipFilter = .notMipmapped
        sd.sAddressMode = .clampToZero
        sd.tAddressMode = .clampToZero
        guard let sampler = device.makeSamplerState(descriptor: sd) else {
            throw MetalRenderError.pipelineCreationFailed(detail: "sampler state creation failed")
        }
        self.linearSampler = sampler

        // §8 — create every Step-11 pipeline at session construction (no lazy creation during execute):
        // the 4x r16Float coverage pipeline, the mask-combine pipeline, and the apply pipelines for both
        // supported intermediate target formats.
        self.coveragePipelineState = try makeCoveragePipeline()
        self.maskCombinePipelineState = try makeMaskCombinePipeline()
        for format in Self.supportedTargetFormats {
            shapeApplyPipelines[format] = try makeApplyPipeline(fragment: shapeApplyFragment, format: format, detail: "shapeApply")
            maskApplyPipelines[format] = try makeApplyPipeline(fragment: maskApplyFragment, format: format, detail: "maskApply")
            matteApplyPipelines[format] = try makeApplyPipeline(fragment: matteApplyFragment, format: format, detail: "matteApply")
            // Step-12 fade/slide are SELF-CONTAINED full-surface `.replace` passes (R1): blending disabled,
            // the fragment emits the final composited value.
            fadePipelines[format] = try makeReplaceFullSurfacePipeline(fragment: fadeFragment, format: format, detail: "fade")
            slidePipelines[format] = try makeReplaceFullSurfacePipeline(fragment: slideFragment, format: format, detail: "slide")
        }
    }

    /// The intermediate target formats a Step-11 apply pass can composite into (§8).
    static let supportedTargetFormats: [MTLPixelFormat] = [.rgba16Float, .bgra8Unorm_srgb]

    private static func function(_ name: String, in library: MTLLibrary) throws -> MTLFunction {
        guard let f = library.makeFunction(name: name) else {
            throw MetalRenderError.missingShaderFunction(name: name)
        }
        return f
    }

    /// Colour attachment 0 of a pipeline descriptor, as a typed failure instead of a force-unwrap
    /// (corrective Issue 2a/2b). Apple returns a non-nil index-0 attachment in practice; the guard makes
    /// its absence a typed error, never a trap.
    private static func attachment0(
        _ descriptor: MTLRenderPipelineDescriptor
    ) throws -> MTLRenderPipelineColorAttachmentDescriptor {
        guard let attachment = descriptor.colorAttachments[0] else {
            throw MetalRenderError.pipelineCreationFailed(detail: "no color attachment 0")
        }
        return attachment
    }

    /// The bilinear clamp-to-zero sampler (approved R1).
    func sampler() -> MTLSamplerState { linearSampler }

    /// The image-draw pipeline for a given render-target format, with fixed-function premultiplied
    /// source-over blending enabled (plan §5.2). Cached per format.
    func imagePipeline(for format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        if let cached = imagePipelines[format] { return cached }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = imageVertex
        pd.fragmentFunction = imageFragment
        let attachment = try Self.attachment0(pd)
        attachment.pixelFormat = format
        // Fixed-function premultiplied source-over (plan §5.2 descriptor).
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let pso = try makePipeline(pd, detail: "image[\(format.rawValue)]")
        imagePipelines[format] = pso
        return pso
    }

    /// The final linear→sRGB conversion pipeline (target `.bgra8Unorm`, blending disabled / `.replace`,
    /// plan §5.3). Cached.
    func finalPipeline() throws -> MTLRenderPipelineState {
        if let cached = finalPipelineState { return cached }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = fullscreenVertex
        pd.fragmentFunction = finalFragment
        let attachment = try Self.attachment0(pd)
        attachment.pixelFormat = .bgra8Unorm
        attachment.isBlendingEnabled = false
        let pso = try makePipeline(pd, detail: "finalLinearToSRGB")
        finalPipelineState = pso
        return pso
    }

    /// The source-normalization pipeline (corrective §1.2): full-surface triangle, target `rgba16Float`,
    /// blending disabled (`.replace`). The fragment reads the raw texture by exact integer coordinate.
    func normalizePipeline() throws -> MTLRenderPipelineState {
        if let cached = normalizePipelineState { return cached }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = fullscreenVertex
        pd.fragmentFunction = normalizeFragment
        let attachment = try Self.attachment0(pd)
        attachment.pixelFormat = .rgba16Float
        attachment.isBlendingEnabled = false
        let pso = try makePipeline(pd, detail: "normalize")
        normalizePipelineState = pso
        return pso
    }

    // MARK: - Step-11 pipelines

    /// The 4x-MSAA coverage rasterization pipeline (target `r16Float`, blending DISABLED — replacement).
    func coveragePipeline() throws -> MTLRenderPipelineState {
        guard let pso = coveragePipelineState else {
            throw MetalRenderError.pipelineCreationFailed(detail: "coverage pipeline not created")
        }
        return pso
    }

    /// The mask-combine pipeline (single-sample `r16Float`, replace).
    func maskCombinePipeline() throws -> MTLRenderPipelineState {
        guard let pso = maskCombinePipelineState else {
            throw MetalRenderError.pipelineCreationFailed(detail: "mask-combine pipeline not created")
        }
        return pso
    }

    /// The fill/stroke colour-apply pipeline for a target format (premultiplied source-over).
    func shapeApplyPipeline(for format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        guard let pso = shapeApplyPipelines[format] else {
            throw MetalRenderError.pipelineCreationFailed(detail: "shapeApply pipeline for \(format.rawValue)")
        }
        return pso
    }

    /// The mask content-apply pipeline for a target format (premultiplied source-over).
    func maskApplyPipeline(for format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        guard let pso = maskApplyPipelines[format] else {
            throw MetalRenderError.pipelineCreationFailed(detail: "maskApply pipeline for \(format.rawValue)")
        }
        return pso
    }

    /// The matte-apply pipeline for a target format (premultiplied source-over).
    func matteApplyPipeline(for format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        guard let pso = matteApplyPipelines[format] else {
            throw MetalRenderError.pipelineCreationFailed(detail: "matteApply pipeline for \(format.rawValue)")
        }
        return pso
    }

    /// The fade-transition pipeline for a target format (self-contained `.replace`, R1).
    func fadePipeline(for format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        guard let pso = fadePipelines[format] else {
            throw MetalRenderError.pipelineCreationFailed(detail: "fade pipeline for \(format.rawValue)")
        }
        return pso
    }

    /// The slide-transition pipeline for a target format (self-contained `.replace`, R1).
    func slidePipeline(for format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        guard let pso = slidePipelines[format] else {
            throw MetalRenderError.pipelineCreationFailed(detail: "slide pipeline for \(format.rawValue)")
        }
        return pso
    }

    /// A full-surface `.replace` pipeline (blending disabled) into a target format — the fragment emits the
    /// final composited value itself (Step-12 fade/slide, R1).
    private func makeReplaceFullSurfacePipeline(fragment: MTLFunction, format: MTLPixelFormat, detail: String) throws -> MTLRenderPipelineState {
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = fullscreenVertex
        pd.fragmentFunction = fragment
        let attachment = try Self.attachment0(pd)
        attachment.pixelFormat = format
        attachment.isBlendingEnabled = false
        return try makePipeline(pd, detail: "\(detail)[\(format.rawValue)]")
    }

    private func makeCoveragePipeline() throws -> MTLRenderPipelineState {
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = coverageVertex
        pd.fragmentFunction = coverageFragment
        pd.rasterSampleCount = Self.coverageSampleCount
        let attachment = try Self.attachment0(pd)
        attachment.pixelFormat = Self.coverageFormat
        attachment.isBlendingEnabled = false
        return try makePipeline(pd, detail: "coverage")
    }

    private func makeMaskCombinePipeline() throws -> MTLRenderPipelineState {
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = fullscreenVertex
        pd.fragmentFunction = maskCombineFragment
        let attachment = try Self.attachment0(pd)
        attachment.pixelFormat = Self.coverageFormat
        attachment.isBlendingEnabled = false
        return try makePipeline(pd, detail: "maskCombine")
    }

    /// A full-surface apply pipeline (shape/mask/matte) into a target format, with the fixed-function
    /// premultiplied source-over blend (same descriptor as the image pipeline).
    private func makeApplyPipeline(fragment: MTLFunction, format: MTLPixelFormat, detail: String) throws -> MTLRenderPipelineState {
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = fullscreenVertex
        pd.fragmentFunction = fragment
        let attachment = try Self.attachment0(pd)
        attachment.pixelFormat = format
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try makePipeline(pd, detail: "\(detail)[\(format.rawValue)]")
    }

    private func makePipeline(_ descriptor: MTLRenderPipelineDescriptor, detail: String) throws -> MTLRenderPipelineState {
        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw MetalRenderError.pipelineCreationFailed(detail: "\(detail): \(error)")
        }
    }
}
