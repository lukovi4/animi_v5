import Metal

/// GPU-based temporal blend of two video frames for export upsampling.
///
/// Uses a compute kernel to linearly interpolate between two textures
/// based on an alpha value. Scratch texture is lazily allocated and reused.
public final class VideoFrameBlender {
    private let computePipeline: MTLComputePipelineState
    private let device: MTLDevice
    private var scratchTexture: MTLTexture?

    public init(device: MTLDevice) throws {
        self.device = device

        // Load Metal library (same pattern as MetalRendererResources)
        let library: MTLLibrary
        if let url = Bundle.module.url(forResource: "default", withExtension: "metallib"),
           let lib = try? device.makeLibrary(URL: url) {
            library = lib
        } else if let lib = device.makeDefaultLibrary() {
            library = lib
        } else {
            throw VideoFrameBlenderError.failedToLoadLibrary
        }

        guard let function = library.makeFunction(name: "video_frame_blend_kernel") else {
            throw VideoFrameBlenderError.failedToLoadFunction
        }

        self.computePipeline = try device.makeComputePipelineState(function: function)
    }

    /// Blends two textures with linear interpolation.
    ///
    /// The returned scratch texture becomes valid **after** the committed command buffer
    /// executes on the GPU — not synchronously at the point of return. This is safe in
    /// the export path because blend CB and render CB share the same `commandQueue`,
    /// and the render path calls `waitUntilCompleted` as the frame-level sync point.
    ///
    /// - Parameters:
    ///   - prev: Previous frame texture
    ///   - next: Next frame texture
    ///   - alpha: Blend factor (0 = prev, 1 = next)
    ///   - commandQueue: Metal command queue for dispatch
    /// - Returns: Blended texture (valid after GPU execution), or nil on GPU failure
    public func blend(
        prev: MTLTexture, next: MTLTexture,
        alpha: Float, commandQueue: MTLCommandQueue
    ) -> MTLTexture? {
        let width = prev.width
        let height = prev.height

        // Ensure scratch texture matches dimensions
        if scratchTexture == nil
            || scratchTexture!.width != width
            || scratchTexture!.height != height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            desc.usage = [.shaderRead, .shaderWrite]
            desc.storageMode = .private
            scratchTexture = device.makeTexture(descriptor: desc)
        }

        guard let scratch = scratchTexture,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        encoder.setComputePipelineState(computePipeline)
        encoder.setTexture(prev, index: 0)
        encoder.setTexture(next, index: 1)
        encoder.setTexture(scratch, index: 2)

        var alphaValue = alpha
        encoder.setBytes(&alphaValue, length: MemoryLayout<Float>.stride, index: 0)

        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()

        #if DEBUG
        commandBuffer.addCompletedHandler { cb in
            if cb.status == .error {
                print("[VideoFrameBlender] blend error: \(cb.error?.localizedDescription ?? "unknown")")
            }
        }
        #endif
        commandBuffer.commit()

        return scratch
    }

    /// Releases the scratch texture. Next `blend()` call will re-create it lazily.
    public func releaseScratch() {
        scratchTexture = nil
    }
}

// MARK: - Errors

public enum VideoFrameBlenderError: Error {
    case failedToLoadLibrary
    case failedToLoadFunction
}
