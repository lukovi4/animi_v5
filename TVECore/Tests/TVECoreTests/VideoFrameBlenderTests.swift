import XCTest
import Metal
@testable import TVECore

final class VideoFrameBlenderTests: XCTestCase {

    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!

    override func setUpWithError() throws {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        device = dev
        commandQueue = device.makeCommandQueue()!
    }

    private func makeBlender() throws -> VideoFrameBlender {
        do {
            return try VideoFrameBlender(device: device)
        } catch {
            throw XCTSkip("Metal shader library not available in test environment: \(error)")
        }
    }

    // MARK: - GPU Blend Correctness

    func test_blend_halfAlpha_mixesColors() throws {
        let blender = try makeBlender()
        let size = 4

        // Create two shared textures with solid colors for upload
        let prevTex = try makeSharedTexture(width: size, height: size)
        let nextTex = try makeSharedTexture(width: size, height: size)

        // Fill prev = red (BGRA: 0, 0, 255, 255), next = blue (BGRA: 255, 0, 0, 255)
        let redPixel: [UInt8] = [0, 0, 255, 255]  // BGRA
        let bluePixel: [UInt8] = [255, 0, 0, 255]  // BGRA
        fillTexture(prevTex, with: redPixel)
        fillTexture(nextTex, with: bluePixel)

        // Blit to private textures (blend kernel reads from private storage)
        let prevPrivate = try blitToPrivate(prevTex)
        let nextPrivate = try blitToPrivate(nextTex)

        // Blend at alpha=0.5
        guard let result = blender.blend(
            prev: prevPrivate, next: nextPrivate,
            alpha: 0.5, commandQueue: commandQueue
        ) else {
            XCTFail("Blend returned nil")
            return
        }

        // Read back result
        let pixels = try readPixels(from: result, width: size, height: size)

        // Check center pixel — expect mix of red and blue ≈ (127, 0, 127, 255) in BGRA
        let b = pixels[0]
        let g = pixels[1]
        let r = pixels[2]
        let a = pixels[3]

        // Allow ±2 tolerance for GPU rounding
        XCTAssertEqual(Int(b), 127, accuracy: 2, "Blue channel")
        XCTAssertEqual(Int(g), 0, accuracy: 2, "Green channel")
        XCTAssertEqual(Int(r), 127, accuracy: 2, "Red channel")
        XCTAssertEqual(Int(a), 255, accuracy: 2, "Alpha channel")
    }

    // MARK: - Scratch Reuse

    func test_blend_twoCalls_sameDimensions_bothSucceed() throws {
        let blender = try makeBlender()
        let size = 2

        let prevTex = try makePrivateTexture(width: size, height: size)
        let nextTex = try makePrivateTexture(width: size, height: size)

        let result1 = blender.blend(prev: prevTex, next: nextTex, alpha: 0.3, commandQueue: commandQueue)
        let result2 = blender.blend(prev: prevTex, next: nextTex, alpha: 0.7, commandQueue: commandQueue)

        XCTAssertNotNil(result1)
        XCTAssertNotNil(result2)
    }

    // MARK: - Resource Cleanup

    func test_releaseScratch_thenBlend_stillWorks() throws {
        let blender = try makeBlender()
        let size = 2

        let prevTex = try makePrivateTexture(width: size, height: size)
        let nextTex = try makePrivateTexture(width: size, height: size)

        // First blend
        let result1 = blender.blend(prev: prevTex, next: nextTex, alpha: 0.5, commandQueue: commandQueue)
        XCTAssertNotNil(result1)

        // Release scratch
        blender.releaseScratch()

        // Blend again — scratch should be lazily re-created
        let result2 = blender.blend(prev: prevTex, next: nextTex, alpha: 0.5, commandQueue: commandQueue)
        XCTAssertNotNil(result2)
    }

    // MARK: - Edge Alphas

    func test_blend_alphaZero_returnsOriginalPrev() throws {
        let blender = try makeBlender()
        let size = 4

        let prevTex = try makeSharedTexture(width: size, height: size)
        let nextTex = try makeSharedTexture(width: size, height: size)

        let redPixel: [UInt8] = [0, 0, 255, 255]
        let bluePixel: [UInt8] = [255, 0, 0, 255]
        fillTexture(prevTex, with: redPixel)
        fillTexture(nextTex, with: bluePixel)

        let prevPrivate = try blitToPrivate(prevTex)
        let nextPrivate = try blitToPrivate(nextTex)

        guard let result = blender.blend(
            prev: prevPrivate, next: nextPrivate,
            alpha: 0.0, commandQueue: commandQueue
        ) else {
            XCTFail("Blend returned nil")
            return
        }

        let pixels = try readPixels(from: result, width: size, height: size)
        // alpha=0 → pure prev (red in BGRA: 0, 0, 255, 255)
        XCTAssertEqual(Int(pixels[0]), 0, accuracy: 1, "Blue channel should be 0")
        XCTAssertEqual(Int(pixels[2]), 255, accuracy: 1, "Red channel should be 255")
    }

    func test_blend_alphaOne_returnsOriginalNext() throws {
        let blender = try makeBlender()
        let size = 4

        let prevTex = try makeSharedTexture(width: size, height: size)
        let nextTex = try makeSharedTexture(width: size, height: size)

        let redPixel: [UInt8] = [0, 0, 255, 255]
        let bluePixel: [UInt8] = [255, 0, 0, 255]
        fillTexture(prevTex, with: redPixel)
        fillTexture(nextTex, with: bluePixel)

        let prevPrivate = try blitToPrivate(prevTex)
        let nextPrivate = try blitToPrivate(nextTex)

        guard let result = blender.blend(
            prev: prevPrivate, next: nextPrivate,
            alpha: 1.0, commandQueue: commandQueue
        ) else {
            XCTFail("Blend returned nil")
            return
        }

        let pixels = try readPixels(from: result, width: size, height: size)
        // alpha=1 → pure next (blue in BGRA: 255, 0, 0, 255)
        XCTAssertEqual(Int(pixels[0]), 255, accuracy: 1, "Blue channel should be 255")
        XCTAssertEqual(Int(pixels[2]), 0, accuracy: 1, "Red channel should be 0")
    }

    // MARK: - Helpers

    private func makeSharedTexture(width: Int, height: Int) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else {
            throw XCTSkip("Failed to create shared texture")
        }
        return tex
    }

    private func makePrivateTexture(width: Int, height: Int) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        guard let tex = device.makeTexture(descriptor: desc) else {
            throw XCTSkip("Failed to create private texture")
        }
        return tex
    }

    private func fillTexture(_ texture: MTLTexture, with pixel: [UInt8]) {
        let w = texture.width
        let h = texture.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            data[i * 4 + 0] = pixel[0]
            data[i * 4 + 1] = pixel[1]
            data[i * 4 + 2] = pixel[2]
            data[i * 4 + 3] = pixel[3]
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, w, h),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: w * 4
        )
    }

    private func blitToPrivate(_ shared: MTLTexture) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: shared.width, height: shared.height, mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        guard let privateTex = device.makeTexture(descriptor: desc),
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let blitEncoder = cmdBuf.makeBlitCommandEncoder() else {
            throw XCTSkip("Failed to create blit resources")
        }
        blitEncoder.copy(
            from: shared, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOriginMake(0, 0, 0),
            sourceSize: MTLSizeMake(shared.width, shared.height, 1),
            to: privateTex, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOriginMake(0, 0, 0)
        )
        blitEncoder.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
        return privateTex
    }

    private func readPixels(from texture: MTLTexture, width: Int, height: Int) throws -> [UInt8] {
        // Blit private → shared for CPU read
        let sharedDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        sharedDesc.usage = [.shaderRead]
        sharedDesc.storageMode = .shared
        guard let sharedTex = device.makeTexture(descriptor: sharedDesc),
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let blitEncoder = cmdBuf.makeBlitCommandEncoder() else {
            throw XCTSkip("Failed to create readback resources")
        }
        blitEncoder.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOriginMake(0, 0, 0),
            sourceSize: MTLSizeMake(width, height, 1),
            to: sharedTex, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOriginMake(0, 0, 0)
        )
        blitEncoder.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        var pixels = [UInt8](repeating: 0, count: 4)
        sharedTex.getBytes(
            &pixels,
            bytesPerRow: width * 4,
            from: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0
        )
        return pixels
    }
}
