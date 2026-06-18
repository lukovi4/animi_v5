import Foundation
import Metal
import AnimiEngineCore
import AnimiEngineRenderModel

/// Task-003 plan §8.5 — final-surface readback to canonical tightly-packed BGRA8 bytes.
///
/// Dimensions are **derived from the final-surface texture** (never hardcoded, plan §8.5/correction #5).
/// The blit destination stride is the documented conservative 256-aligned value; after validated
/// completion the bytes are repacked row-by-row into a tight `width*4` `Data` and wrapped in a
/// `RenderedFrame` (plan §8.5).
struct MetalFrameReadback {
    let device: MTLDevice

    /// The plan for a readback, prepared **before** encoding (plan §8.6 step 5): the staging buffer + the
    /// blit parameters the executor encodes, plus the derived output dimensions for the final repack.
    struct Plan {
        let stagingBuffer: MTLBuffer
        let alignedBytesPerRow: Int
        let tightBytesPerRow: Int
        let width: Int
        let height: Int
        let source: MTLTexture
    }

    /// Allocate the readback staging buffer and compute strides (plan §8.5/§8.6 step 5). Dimensions come
    /// from the final-surface texture.
    func makePlan(finalSurface: MTLTexture) throws -> Plan {
        let width = finalSurface.width
        let height = finalSurface.height
        guard width > 0, height > 0 else {
            throw MetalRenderError.readbackFailed(detail: "non-positive final surface \(width)x\(height)")
        }
        let tight = try CheckedInt64.multiply(Int64(width), 4, "readback.tight")
        guard let tightInt = Int(exactly: tight) else {
            throw MetalRenderError.readbackFailed(detail: "tight row overflow")
        }
        let aligned = try MetalResourceUploader.roundUp(
            tightInt, to: MetalTextureAllocator.blitRowAlignment,
            MetalRenderError.readbackFailed(detail: "aligned row overflow"))
        let total = try CheckedInt64.multiply(Int64(aligned), Int64(height), "readback.total")
        guard let totalInt = Int(exactly: total) else {
            throw MetalRenderError.readbackFailed(detail: "staging size overflow")
        }
        guard let staging = device.makeBuffer(length: totalInt, options: .storageModeShared) else {
            throw MetalRenderError.readbackFailed(detail: "staging buffer allocation failed")
        }
        return Plan(stagingBuffer: staging, alignedBytesPerRow: aligned, tightBytesPerRow: tightInt,
                    width: width, height: height, source: finalSurface)
    }

    /// Encode the texture→staging-buffer blit (plan §8.6 step 7c). Encoded last, inside the one buffer.
    func encodeBlit(into commandBuffer: MTLCommandBuffer, plan: Plan) throws {
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw MetalRenderError.encodingFailed(detail: "readback blit encoder")
        }
        // Checked bytesPerImage (corrective §3, site 3d).
        let bytesPerImage = try CheckedInt.mul(
            plan.alignedBytesPerRow, plan.height,
            MetalRenderError.readbackFailed(detail: "bytesPerImage overflow"))
        blit.copy(
            from: plan.source, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: plan.width, height: plan.height, depth: 1),
            to: plan.stagingBuffer, destinationOffset: 0,
            destinationBytesPerRow: plan.alignedBytesPerRow,
            destinationBytesPerImage: bytesPerImage)
        blit.endEncoding()
    }

    /// After validated completion (plan §8.6 step 10): repack the staging rows tight and build the frame.
    func makeFrame(from plan: Plan, colorContract: RenderColorContract) throws -> RenderedFrame {
        // Checked output buffer length (corrective §3, site 3e).
        let outputCount = try CheckedInt.mul(
            plan.tightBytesPerRow, plan.height,
            MetalRenderError.readbackFailed(detail: "output size overflow"))
        var output = Data(count: outputCount)
        let src = plan.stagingBuffer.contents()
        try output.withUnsafeMutableBytes { dstRaw in
            guard let dst = dstRaw.baseAddress else {
                throw MetalRenderError.readbackFailed(detail: "empty output buffer")
            }
            for row in 0..<plan.height {
                // Checked row offsets (corrective §3, sites 3f/3g).
                let srcOff = try CheckedInt.mul(
                    row, plan.alignedBytesPerRow,
                    MetalRenderError.readbackFailed(detail: "src row offset overflow"))
                let dstOff = try CheckedInt.mul(
                    row, plan.tightBytesPerRow,
                    MetalRenderError.readbackFailed(detail: "dst row offset overflow"))
                let srcRow = src.advanced(by: srcOff)
                let dstRow = dst.advanced(by: dstOff)
                dstRow.copyMemory(from: srcRow, byteCount: plan.tightBytesPerRow)
            }
        }
        let dims = try PixelDimensions(
            width: plan.width, height: plan.height,
            bytesPerRow: plan.tightBytesPerRow, format: .bgra8, orientation: .up)
        return try RenderedFrame(dimensions: dims, colorContract: colorContract, bytes: output)
    }
}
