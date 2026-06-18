import Foundation
import Metal
import AnimiEngineCore
import AnimiEngineRenderModel

/// Task-003 plan §8.1 — uploads `ResolvedPixelInput` bytes into a source texture.
///
/// Handles arbitrary valid input `bytesPerRow` (padded ≥ width*4), **odd** widths, and copies **only the
/// active pixel bytes** of each source row — never source padding (plan §8.1). Two paths:
///   * `.shared` (macOS dev): host-populate the texture with `replaceRegion`, no command buffer needed;
///   * `.private` (iOS): fill a 256-aligned `.shared` staging buffer on the CPU **before** encoding, then
///     the executor encodes a buffer→texture upload blit **first** inside the single command buffer
///     (plan §8.1 / §8.6, Rev-3 correction #1) — no claim a private upload completes before a command
///     buffer exists.
struct MetalResourceUploader {
    let device: MTLDevice

    /// A prepared private-texture upload: a filled staging buffer + the blit parameters the executor
    /// encodes (plan §8.1 step 2 / §8.6 step 7a).
    struct StagedUpload {
        let stagingBuffer: MTLBuffer
        let sourceBytesPerRow: Int
        let sourceBytesPerImage: Int
        let size: MTLSize
        let destination: MTLTexture
    }

    /// Host-populate a `.shared` source texture directly (plan §8.1, macOS path).
    func uploadShared(_ pixels: ResolvedPixelInput, into texture: MTLTexture, resourceID: String) throws {
        let dims = pixels.dimensions
        let region = MTLRegionMake2D(0, 0, dims.width, dims.height)
        try pixels.bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                throw MetalRenderError.uploadFailed(resourceID: resourceID, detail: "empty source bytes")
            }
            texture.replace(
                region: region, mipmapLevel: 0, withBytes: base, bytesPerRow: dims.bytesPerRow)
        }
    }

    /// Prepare a `.private` source-texture upload (plan §8.1, iOS path): allocate a 256-aligned `.shared`
    /// staging buffer and fill it row-by-row, copying only the active `width*4` bytes of each source row
    /// (skipping source padding). The returned `StagedUpload` is encoded by the executor before rendering.
    func prepareStagedUpload(
        _ pixels: ResolvedPixelInput, into texture: MTLTexture, resourceID: String
    ) throws -> StagedUpload {
        let dims = pixels.dimensions
        let tight = try CheckedInt64.multiply(Int64(dims.width), 4, "upload.tight")
        guard let tightInt = Int(exactly: tight) else {
            throw MetalRenderError.uploadFailed(resourceID: resourceID, detail: "row byte overflow")
        }
        let aligned = try Self.roundUp(
            tightInt, to: MetalTextureAllocator.blitRowAlignment,
            MetalRenderError.uploadFailed(resourceID: resourceID, detail: "aligned row overflow"))
        let total = try CheckedInt64.multiply(Int64(aligned), Int64(dims.height), "upload.total")
        guard let totalInt = Int(exactly: total) else {
            throw MetalRenderError.uploadFailed(resourceID: resourceID, detail: "staging size overflow")
        }
        guard let staging = device.makeBuffer(length: totalInt, options: .storageModeShared) else {
            throw MetalRenderError.uploadFailed(resourceID: resourceID, detail: "staging buffer allocation failed")
        }
        let dst = staging.contents()
        try pixels.bytes.withUnsafeBytes { raw in
            guard let src = raw.baseAddress else {
                throw MetalRenderError.uploadFailed(resourceID: resourceID, detail: "empty source bytes")
            }
            for row in 0..<dims.height {
                // Checked row offsets (corrective §3, sites 3b/3c).
                let srcOff = try CheckedInt.mul(
                    row, dims.bytesPerRow,
                    MetalRenderError.uploadFailed(resourceID: resourceID, detail: "src row offset overflow"))
                let dstOff = try CheckedInt.mul(
                    row, aligned,
                    MetalRenderError.uploadFailed(resourceID: resourceID, detail: "dst row offset overflow"))
                let srcRow = src.advanced(by: srcOff)
                let dstRow = dst.advanced(by: dstOff)
                // Copy only the active tight bytes; never source padding.
                dstRow.copyMemory(from: srcRow, byteCount: tightInt)
            }
        }
        return StagedUpload(
            stagingBuffer: staging,
            sourceBytesPerRow: aligned,
            sourceBytesPerImage: totalInt,
            size: MTLSize(width: dims.width, height: dims.height, depth: 1),
            destination: texture)
    }

    /// Round `value` up to the next multiple of `alignment`, with a **checked** add (corrective §3, site 3a):
    /// an overflow throws the supplied typed error rather than trapping. A non-positive alignment (never
    /// produced — the only caller passes the 256 constant) returns `value` unchanged.
    static func roundUp(_ value: Int, to alignment: Int, _ error: @autoclosure () -> MetalRenderError) throws -> Int {
        guard alignment > 0 else { return value }
        let r = value % alignment
        if r == 0 { return value }
        return try CheckedInt.add(value, alignment - r, error())
    }
}
