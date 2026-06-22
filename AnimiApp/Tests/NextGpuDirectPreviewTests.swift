#if DEBUG
import XCTest
import Foundation
import Metal
import AVFoundation
import CoreVideo
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import AnimiApp
import AnimiEngineMetalRender

/// CP7.7-next: tests for the GPU-direct preview path — the bridge renders a frame DIRECTLY into a
/// canvas-sized `MTLTexture` (`renderFramePreview` → `MetalRenderSession.render(_:into:.preserveAlpha)`),
/// and `CanvasTexturePool` manages safe texture lifetime. The byte-exact parity of `render(into:)` vs the
/// readback `execute` path is already proven at the engine layer by `GPURenderTargetTests` (CP7.6a); here
/// we prove the APP-level wrapper produces the SAME pixels as `renderFrameBGRA` for a deterministic frame,
/// and that the pool's bound / state machine / exhaustion behave as specified.
final class NextGpuDirectPreviewTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextGpuDirectPreview_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: - Parity: GPU-direct texture == renderFrameBGRA for a deterministic frame

    func test_gpuDirectTexture_equalsReadbackFrame_deterministic() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let folder = try sceneFolderURL("full_image")
        // CP7.8: use a PHOTO — the GPU-direct == readback byte-parity invariant exists only for a bytes
        // input. A video is texture-backed (no readback path); its orientation parity is proven at the
        // engine layer (CP78TextureBindingTests.test_orientationParity_allQuarterTurns).
        let photo = try tempPhoto("parity")

        let inputs = photoInputs(folder: folder, photo: photo)
        let sessionBox = try NextSingleSceneBridge.makeSession(device: device)
        let decoded = try NextSingleSceneBridge.decodeMedia(inputs)
        let placementByBlockID = Dictionary(uniqueKeysWithValues: inputs.blocks.map { ($0.blockID, $0.placement) })
        let ctx = try NextSingleSceneBridge.assemble(decoded: decoded, placementByBlockID: placementByBlockID, sessionBox: sessionBox)

        // Readback oracle (the existing, ReferenceData-validated path) at frame 0.
        let oracle = try NextSingleSceneBridge.renderFrameBGRA(context: ctx, frameIndex: 0)
        XCTAssertEqual(oracle.width, 1080); XCTAssertEqual(oracle.height, 1920)

        // GPU-direct into a canvas-sized texture at the SAME frame 0.
        let (cw, ch) = ctx.canvasPixelSize
        XCTAssertEqual(cw, oracle.width); XCTAssertEqual(ch, oracle.height)
        let pool = CanvasTexturePool(device: sessionBox.metalDevice)
        let handle = try XCTUnwrap(pool.checkout(width: cw, height: ch))
        try NextSingleSceneBridge.renderFramePreview(context: ctx, frameIndex: 0, into: handle.texture)

        let gpuBytes = try readBackBGRA(handle.texture, device: device)
        // preserveAlpha → byte-identical to the readback frame (CP7.6a engine proof, here app-level).
        XCTAssertEqual(gpuBytes.count, oracle.bytes.count, "byte count must match canvas frame")
        XCTAssertEqual(gpuBytes, [UInt8](oracle.bytes),
                       "GPU-direct preview texture must be byte-identical to renderFrameBGRA at the same frame")
        pool.markRendered(handle)
    }

    // MARK: - Pool lifetime: reuse-eligible ONLY when not front AND no in-flight GPU reads

    /// The reuse-hazard invariant: a texture being presented (in-flight read) is NOT reusable; it
    /// becomes reusable only once the present completes AND it is no longer the front buffer.
    func test_pool_presentingTextureNotReusable_untilReadCompletesAndNotFront() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        // The pool floors maxTextures at 2 (double-buffer). Fill BOTH slots so the only way a 3rd checkout
        // can succeed is by reusing a `released` texture — proving the lifetime gate, not allocation slack.
        let pool = CanvasTexturePool(device: device, maxTextures: 2)
        let h = try XCTUnwrap(pool.checkout(width: 64, height: 64)); pool.markRendered(h)
        let filler = try XCTUnwrap(pool.checkout(width: 64, height: 64)); pool.markRendered(filler)
        pool.setFront(h)              // h adopted as front
        pool.retainForPresent(h)      // a present cmd buffer is sampling h (committed, not completed)
        pool.setFront(filler)         // filler becomes front; h demoted but its read is STILL in flight
        // Both slots are non-reusable (h: read in flight; filler: front). A 3rd checkout must be nil — never
        // hand back h (the GPU is still reading it → render-vs-present reuse hazard).
        XCTAssertNil(pool.checkout(width: 64, height: 64), "texture being presented must not be reusable")
        // h's present completes, but h's read drained while it was already demoted → h is now idle → reusable.
        pool.releaseAfterPresent(h)
        let reused = try XCTUnwrap(pool.checkout(width: 64, height: 64))
        XCTAssertTrue(reused === h, "h is reusable only once not front AND its read completed")
    }

    /// Replacing the front before the OLD front's present completes must NOT make the old texture reusable
    /// early (it may still be sampled). This is the exact CP7.6b/earlier-attempt race.
    func test_pool_replacingFrontBeforeCompletion_doesNotFreeOldTextureEarly() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let pool = CanvasTexturePool(device: device, maxTextures: 3)
        let a = try XCTUnwrap(pool.checkout(width: 64, height: 64)); pool.markRendered(a)
        pool.setFront(a); pool.retainForPresent(a)               // A presented, front, read in flight
        let b = try XCTUnwrap(pool.checkout(width: 64, height: 64)); pool.markRendered(b)
        pool.setFront(b); pool.retainForPresent(b)               // B becomes front; A demoted but read STILL in flight
        XCTAssertEqual(a.isFront, false, "A demoted from front")
        XCTAssertEqual(a.inFlightReads, 1, "A's present read is still in flight")
        // A is not front, but its read has NOT completed → must still be non-reusable.
        // Force the only reusable check: with B front+reading and one spare slot, checkout may make a NEW
        // texture, but must NEVER hand back A while A.inFlightReads > 0.
        let c = pool.checkout(width: 64, height: 64)
        XCTAssertFalse(c === a, "A must not be reused while its present read is still in flight")
        // A's present finally completes → now reusable.
        pool.releaseAfterPresent(a)
        XCTAssertEqual(a.inFlightReads, 0)
        XCTAssertTrue(a.isReusableForTesting, "A reusable once not front AND reads drained")
    }

    func test_pool_boundExhaustion_returnsNil_neverAllocatesPastCap() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let pool = CanvasTexturePool(device: device, maxTextures: 2)
        let a = try XCTUnwrap(pool.checkout(width: 64, height: 64)); pool.markRendered(a)
        let b = try XCTUnwrap(pool.checkout(width: 64, height: 64)); pool.markRendered(b)
        pool.setFront(a); pool.retainForPresent(a)
        pool.setFront(b); pool.retainForPresent(b)   // both in flight
        XCTAssertNil(pool.checkout(width: 64, height: 64), "pool must be bounded: all in flight → nil")
        XCTAssertEqual(pool.snapshotForTesting.total, 2)
        // Drain one (not front, read complete) → a slot frees.
        pool.clearFront()
        pool.releaseAfterPresent(a)
        XCTAssertNotNil(pool.checkout(width: 64, height: 64), "a drained slot is reusable")
    }

    func test_pool_canvasSizeChange_drainsAndReallocates() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let pool = CanvasTexturePool(device: device, maxTextures: 3)
        let small = try XCTUnwrap(pool.checkout(width: 64, height: 64))
        XCTAssertEqual(small.texture.width, 64)
        let big = try XCTUnwrap(pool.checkout(width: 128, height: 256))
        XCTAssertEqual(big.texture.width, 128); XCTAssertEqual(big.texture.height, 256)
        // The old handle is no longer owned → its eventual present-read release is a no-op.
        pool.releaseAfterPresent(small)
        XCTAssertEqual(pool.snapshotForTesting.total, 1, "only the new-size texture remains owned")
    }

    func test_pool_clear_releasesAll() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let pool = CanvasTexturePool(device: device, maxTextures: 3)
        _ = pool.checkout(width: 64, height: 64)
        _ = pool.checkout(width: 64, height: 64)
        XCTAssertEqual(pool.snapshotForTesting.total, 2)
        pool.clear()
        XCTAssertEqual(pool.snapshotForTesting.total, 0)
    }

    func test_pool_releaseUnownedHandle_isNoOp() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let pool = CanvasTexturePool(device: device, maxTextures: 2)
        let foreignTex = device.makeTexture(descriptor: {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 16, height: 16, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private; return d
        }())!
        let foreign = CanvasTextureHandle.makeForTesting(texture: foreignTex)
        pool.releaseAfterPresent(foreign)   // not owned → must not crash, must not change pool state
        pool.setFront(foreign)
        XCTAssertEqual(pool.snapshotForTesting.total, 0)
    }

    // MARK: - Helpers

    private func sceneFolderURL(_ id: String) throws -> URL {
        let snapshot = try BundleSceneLibraryLoader().load()
        let scene = try XCTUnwrap(snapshot.scene(byId: id), "bundled scene '\(id)' missing")
        return try XCTUnwrap(scene.folderURL, "bundled scene '\(id)' has no folder URL")
    }

    private func videoInputs(folder: URL, video: URL) -> NextBridgeInputs {
        NextBridgeInputs(
            sceneTypeId: "full_image", sceneFolderURL: folder, variantOverrides: [:],
            blocks: [NextBridgeBlock(
                blockID: "block_01", mediaURL: video,
                placement: NextBridgePlacement(fitModeRaw: "cover", offsetX: 0, offsetY: 0, userScale: 1, rotationDegrees: 0),
                video: NextBridgeVideo(winStart: 0, winEnd: 1.0))],
            frameIndex: 0)
    }

    /// CP7.8: the GPU-direct == readback BYTE-PARITY invariant holds only for a BYTES input (photo) — a
    /// video is texture-backed and has no readback path. This test uses a photo to keep proving the
    /// app-level wrapper matches `renderFrameBGRA`; video orientation parity is proven at the engine layer
    /// (`CP78TextureBindingTests.test_orientationParity_allQuarterTurns`, bit-identical vs the CPU oracle).
    private func photoInputs(folder: URL, photo: URL) -> NextBridgeInputs {
        NextBridgeInputs(
            sceneTypeId: "full_image", sceneFolderURL: folder, variantOverrides: [:],
            blocks: [NextBridgeBlock(
                blockID: "block_01", mediaURL: photo,
                placement: NextBridgePlacement(fitModeRaw: "cover", offsetX: 0, offsetY: 0, userScale: 1, rotationDegrees: 0))],
            frameIndex: 0)
    }

    private func tempPhoto(_ name: String, w: Int = 256, h: Int = 256) throws -> URL {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // A non-uniform pattern so the frame is a meaningful determinism fixture.
        ctx.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(red: 0.9, green: 0.1, blue: 0.3, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w/2, height: h/2))
        let image = try XCTUnwrap(ctx.makeImage())
        let url = tempDir.appendingPathComponent("cp78gpu-\(name).png")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    /// Blit a `.private` BGRA8 texture into a tight `.shared` buffer and read it back, row-unpadded.
    private func readBackBGRA(_ tex: MTLTexture, device: MTLDevice) throws -> [UInt8] {
        let w = tex.width, h = tex.height, bpr = w * 4
        let buf = try XCTUnwrap(device.makeBuffer(length: bpr * h, options: .storageModeShared))
        let q = try XCTUnwrap(device.makeCommandQueue())
        let cb = try XCTUnwrap(q.makeCommandBuffer())
        let blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
        blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: buf, destinationOffset: 0,
                  destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
        blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        return [UInt8](Data(bytesNoCopy: buf.contents(), count: bpr * h, deallocator: .none))
    }

    private func runAsync(_ body: @escaping () async throws -> Void) rethrows {
        let exp = expectation(description: "async")
        var thrown: Error?
        Task { do { try await body() } catch { thrown = error }; exp.fulfill() }
        wait(for: [exp], timeout: 30)
        if let thrown { try { throw thrown }() }
    }

    private func createRampVideo(at url: URL, frameCount: Int, fps: Int32, width: Int, height: Int) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        guard writer.canAdd(input) else { throw NSError(domain: "NextGpuDirectPreview", code: 1) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "NextGpuDirectPreview", code: 2) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
            guard let pb else { throw NSError(domain: "NextGpuDirectPreview", code: 3) }
            CVPixelBufferLockBaseAddress(pb, [])
            let bpr = CVPixelBufferGetBytesPerRow(pb)
            let base = CVPixelBufferGetBaseAddress(pb)!
            let v = UInt8((frame * 8) % 256)
            for y in 0..<height {
                let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width { let o = x * 4; row[o]=v; row[o+1]=v; row[o+2]=v; row[o+3]=255 }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            XCTAssertTrue(adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? NSError(domain: "NextGpuDirectPreview", code: 4) }
    }
}
#endif
