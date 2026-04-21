import XCTest
import Metal
import UIKit
import TVECore
@testable import AnimiApp

/// TT-06: Tests for the unified TimelineRenderExecutor.
/// Verifies preview/export parity (with real commands), async preview path,
/// offscreen pixel size helper, and error paths.
@MainActor
final class TimelineRenderExecutorTests: XCTestCase {

    private var device: MTLDevice!
    private var renderer: MetalRenderer!
    private var compositor: TransitionCompositor!

    override func setUp() async throws {
        try await super.setUp()

        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        device = metalDevice
        renderer = try MetalRenderer(
            device: device,
            colorPixelFormat: .bgra8Unorm,
            options: MetalRendererOptions(clearColor: .opaqueBlack)
        )
        compositor = try TransitionCompositor(device: device, colorPixelFormat: .bgra8Unorm)
    }

    override func tearDown() async throws {
        renderer = nil
        compositor = nil
        device = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeRenderTarget(width: Int, height: Int, storageMode: MTLStorageMode = .shared) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width, height: height,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead, .shaderWrite]
        desc.storageMode = storageMode
        return device.makeTexture(descriptor: desc)!
    }

    /// Creates a solid-color BGRA texture for use as a drawImage asset.
    private func makeSolidTexture(
        width: Int, height: Int,
        red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8
    ) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width, height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        let texture = device.makeTexture(descriptor: desc)!
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i]     = blue
            pixels[i + 1] = green
            pixels[i + 2] = red
            pixels[i + 3] = alpha
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0, withBytes: &pixels, bytesPerRow: width * 4
        )
        return texture
    }

    /// Creates a SceneRenderContext with a drawImage command and real texture.
    private func makeSceneContext(
        canvasSize: SizeD,
        assetId: String,
        texture: MTLTexture,
        opacity: Double = 1.0
    ) -> SceneRenderContext {
        let provider = InMemoryTextureProvider()
        provider.setTexture(texture, for: assetId)
        return SceneRenderContext(
            commands: [
                .pushTransform(Matrix2D.identity),
                .drawImage(assetId: assetId, opacity: opacity),
                .popTransform
            ],
            textureProvider: provider,
            pathRegistry: PathRegistry(),
            assetSizes: [assetId: AssetSize(width: canvasSize.width, height: canvasSize.height)],
            localFrame: 0,
            canvasSize: canvasSize,
            sceneInstanceId: UUID()
        )
    }

    private func readPixels(from texture: MTLTexture) -> [UInt8] {
        let w = texture.width
        let h = texture.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(
            &pixels,
            bytesPerRow: w * 4,
            from: MTLRegionMake2D(0, 0, w, h),
            mipmapLevel: 0
        )
        return pixels
    }

    /// Reads pixels from a `.private` storage texture by blitting to a `.shared` staging texture.
    private func readPixelsViaBlit(from texture: MTLTexture) -> [UInt8] {
        let staging = makeRenderTarget(width: texture.width, height: texture.height, storageMode: .shared)
        let cmdBuf = renderer.commandQueue.makeCommandBuffer()!
        let blit = cmdBuf.makeBlitCommandEncoder()!
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: staging, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
        return readPixels(from: staging)
    }

    // MARK: - 1. Single scene parity with real commands

    func testSingle_previewAndExportRequestsMatchAtScale1() throws {
        let canvasSize = SizeD(width: 16, height: 16)
        let assetTex = makeSolidTexture(width: 16, height: 16, red: 200, green: 100, blue: 50, alpha: 255)
        let ctx = makeSceneContext(canvasSize: canvasSize, assetId: "test_img", texture: assetTex)

        // Preview path (clearColorOverride: nil -> renderer default opaqueBlack)
        let previewTex = makeRenderTarget(width: 16, height: 16)
        let previewRequest = TimelineRenderRequest(
            resolved: .single(ctx),
            targetTexture: previewTex,
            drawableScale: 1.0,
            timelineCanvasSize: canvasSize,
            backgroundState: nil,
            backgroundTextureProvider: nil,
            clearColorOverride: nil,
            presentationDrawable: nil,
            waitUntilCompleted: true
        )
        try TimelineRenderExecutor.render(
            previewRequest, renderer: renderer,
            commandQueue: renderer.commandQueue,
            transitionCompositor: nil,
            completionQueue: nil
        )

        // Export path (clearColorOverride: .opaqueBlack)
        let exportTex = makeRenderTarget(width: 16, height: 16)
        let exportRequest = TimelineRenderRequest(
            resolved: .single(ctx),
            targetTexture: exportTex,
            drawableScale: 1.0,
            timelineCanvasSize: canvasSize,
            backgroundState: nil,
            backgroundTextureProvider: nil,
            clearColorOverride: .opaqueBlack,
            presentationDrawable: nil,
            waitUntilCompleted: true
        )
        try TimelineRenderExecutor.render(
            exportRequest, renderer: renderer,
            commandQueue: renderer.commandQueue,
            transitionCompositor: nil,
            completionQueue: nil
        )

        let previewPixels = readPixels(from: previewTex)
        let exportPixels = readPixels(from: exportTex)

        // Verify scene content was actually rendered (not just cleared).
        // Renderer default clear is opaqueBlack = BGRA(0,0,0,255).
        // Our asset is red=200,green=100,blue=50 → BGRA(50,100,200,255).
        // Check that at least one pixel has the expected asset color.
        let expectedBGRA: (UInt8, UInt8, UInt8, UInt8) = (50, 100, 200, 255)
        let hasAssetPixel = stride(from: 0, to: previewPixels.count, by: 4).contains { i in
            previewPixels[i] == expectedBGRA.0 && previewPixels[i+1] == expectedBGRA.1
                && previewPixels[i+2] == expectedBGRA.2 && previewPixels[i+3] == expectedBGRA.3
        }
        XCTAssertTrue(hasAssetPixel, "Scene drawImage must produce pixels matching the asset color (BGRA 50,100,200,255)")
        XCTAssertEqual(previewPixels, exportPixels, "Preview and export single scene should produce identical pixels")
    }

    // MARK: - 2. Transition parity with real commands

    func testTransition_previewAndExportRequestsMatchAtScale1() throws {
        let canvasSize = SizeD(width: 16, height: 16)
        let texA = makeSolidTexture(width: 16, height: 16, red: 255, green: 0, blue: 0, alpha: 255)
        let texB = makeSolidTexture(width: 16, height: 16, red: 0, green: 0, blue: 255, alpha: 255)
        let ctxA = makeSceneContext(canvasSize: canvasSize, assetId: "scene_a", texture: texA)
        let ctxB = makeSceneContext(canvasSize: canvasSize, assetId: "scene_b", texture: texB)
        let transition = SceneTransition(type: .fade, durationFrames: 14, easingPreset: .linear)
        let transCtx = TransitionRenderContext(sceneA: ctxA, sceneB: ctxB, transition: transition, progress: 0.5)

        // Preview path (blocking for pixel comparison)
        let previewTex = makeRenderTarget(width: 16, height: 16)
        let previewRequest = TimelineRenderRequest(
            resolved: .transition(transCtx),
            targetTexture: previewTex,
            drawableScale: 1.0,
            timelineCanvasSize: canvasSize,
            backgroundState: nil,
            backgroundTextureProvider: nil,
            clearColorOverride: nil,
            presentationDrawable: nil,
            waitUntilCompleted: true
        )
        try TimelineRenderExecutor.render(
            previewRequest, renderer: renderer,
            commandQueue: renderer.commandQueue,
            transitionCompositor: compositor,
            completionQueue: nil
        )

        // Export path
        let exportTex = makeRenderTarget(width: 16, height: 16)
        let exportRequest = TimelineRenderRequest(
            resolved: .transition(transCtx),
            targetTexture: exportTex,
            drawableScale: 1.0,
            timelineCanvasSize: canvasSize,
            backgroundState: nil,
            backgroundTextureProvider: nil,
            clearColorOverride: .opaqueBlack,
            presentationDrawable: nil,
            waitUntilCompleted: true
        )
        try TimelineRenderExecutor.render(
            exportRequest, renderer: renderer,
            commandQueue: renderer.commandQueue,
            transitionCompositor: compositor,
            completionQueue: nil
        )

        let previewPixels = readPixels(from: previewTex)
        let exportPixels = readPixels(from: exportTex)

        // Verify composited output contains scene content, not just opaqueBlack clear.
        // opaqueBlack clear = BGRA(0,0,0,255) for every pixel.
        // Fade 0.5 of red(255,0,0) + blue(0,0,255) should produce non-zero R and B channels.
        let opaqueBlackPixel: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 255)
        let hasNonClearPixel = stride(from: 0, to: previewPixels.count, by: 4).contains { i in
            let b = previewPixels[i], g = previewPixels[i+1], r = previewPixels[i+2]
            // At least one of R or B must be non-zero (from the red/blue scene assets)
            return r != opaqueBlackPixel.2 || b != opaqueBlackPixel.0 || g != opaqueBlackPixel.1
        }
        XCTAssertTrue(hasNonClearPixel, "Transition must produce pixels with non-zero color from scene assets")
        XCTAssertEqual(previewPixels, exportPixels, "Preview and export transition should produce identical pixels")
    }

    // MARK: - 3. offscreenPixelSize helper

    func testOffscreenPixelSize_usesCanvasTimesDrawableScale() {
        let size1 = TimelineRenderExecutor.offscreenPixelSize(
            canvasSize: SizeD(width: 100, height: 50), drawableScale: 2.0
        )
        XCTAssertEqual(size1.width, 200)
        XCTAssertEqual(size1.height, 100)

        let size2 = TimelineRenderExecutor.offscreenPixelSize(
            canvasSize: SizeD(width: 101, height: 100), drawableScale: 1.0
        )
        XCTAssertEqual(size2.width, 101)
        XCTAssertEqual(size2.height, 100)

        // Tiny canvas — clamp to 1
        let size3 = TimelineRenderExecutor.offscreenPixelSize(
            canvasSize: SizeD(width: 0.1, height: 0.1), drawableScale: 1.0
        )
        XCTAssertEqual(size3.width, 1)
        XCTAssertEqual(size3.height, 1)
    }

    // MARK: - 4. Missing compositor throws

    func testTransition_withoutCompositor_throwsMissingTransitionCompositor() {
        let canvasSize = SizeD(width: 16, height: 16)
        let ctx = makeSceneContext(
            canvasSize: canvasSize, assetId: "img",
            texture: makeSolidTexture(width: 16, height: 16, red: 128, green: 128, blue: 128, alpha: 255)
        )
        let transition = SceneTransition(type: .fade, durationFrames: 14, easingPreset: .linear)
        let transCtx = TransitionRenderContext(sceneA: ctx, sceneB: ctx, transition: transition, progress: 0.5)

        let tex = makeRenderTarget(width: 16, height: 16)
        let request = TimelineRenderRequest(
            resolved: .transition(transCtx),
            targetTexture: tex,
            drawableScale: 1.0,
            timelineCanvasSize: canvasSize,
            backgroundState: nil,
            backgroundTextureProvider: nil,
            clearColorOverride: nil,
            presentationDrawable: nil,
            waitUntilCompleted: true
        )

        XCTAssertThrowsError(
            try TimelineRenderExecutor.render(
                request, renderer: renderer,
                commandQueue: renderer.commandQueue,
                transitionCompositor: nil,
                completionQueue: nil
            )
        ) { error in
            XCTAssertEqual(error as? TimelineRenderExecutorError, .missingTransitionCompositor)
        }
    }

    // MARK: - 5. Async preview path: completion fires and does not hang

    func testAsyncPreviewPath_completionHandlerFires() throws {
        let canvasSize = SizeD(width: 16, height: 16)
        let assetTex = makeSolidTexture(width: 16, height: 16, red: 100, green: 200, blue: 50, alpha: 255)
        let ctx = makeSceneContext(canvasSize: canvasSize, assetId: "async_img", texture: assetTex)

        let tex = makeRenderTarget(width: 16, height: 16)
        let completionExpectation = expectation(description: "onCommandBufferCompleted fires")

        let request = TimelineRenderRequest(
            resolved: .single(ctx),
            targetTexture: tex,
            drawableScale: 1.0,
            timelineCanvasSize: canvasSize,
            backgroundState: nil,
            backgroundTextureProvider: nil,
            clearColorOverride: nil,
            presentationDrawable: nil,
            waitUntilCompleted: false
        )
        try TimelineRenderExecutor.render(
            request, renderer: renderer,
            commandQueue: renderer.commandQueue,
            transitionCompositor: nil,
            completionQueue: nil,
            onCommandBufferCompleted: { _ in
                completionExpectation.fulfill()
            }
        )

        wait(for: [completionExpectation], timeout: 5.0)
    }

    // MARK: - 6. Async transition path: completion fires and textures return to pool

    func testAsyncTransitionPath_completionFiresAndTexturesReturnToPool() throws {
        let canvasSize = SizeD(width: 16, height: 16)
        let texA = makeSolidTexture(width: 16, height: 16, red: 255, green: 0, blue: 0, alpha: 255)
        let texB = makeSolidTexture(width: 16, height: 16, red: 0, green: 255, blue: 0, alpha: 255)
        let ctxA = makeSceneContext(canvasSize: canvasSize, assetId: "async_a", texture: texA)
        let ctxB = makeSceneContext(canvasSize: canvasSize, assetId: "async_b", texture: texB)
        let transition = SceneTransition(type: .fade, durationFrames: 14, easingPreset: .linear)
        let transCtx = TransitionRenderContext(sceneA: ctxA, sceneB: ctxB, transition: transition, progress: 0.5)

        let targetTex = makeRenderTarget(width: 16, height: 16)
        let completionExpectation = expectation(description: "async transition completion fires")
        let releaseQueue = DispatchQueue(label: "test.release")
        let texturePool = renderer.texturePool
        let sizePx = TimelineRenderExecutor.offscreenPixelSize(
            canvasSize: canvasSize, drawableScale: 1.0
        )

        // Pre-flight: pool is empty for this size. Acquire+release two textures to seed
        // the pool, then record their ObjectIdentifiers as the "known pool textures".
        let seed1 = texturePool.acquireColorTexture(size: sizePx)!
        let seed2 = texturePool.acquireColorTexture(size: sizePx)!
        let seedId1 = ObjectIdentifier(seed1)
        let seedId2 = ObjectIdentifier(seed2)
        texturePool.release(seed1)
        texturePool.release(seed2)

        // Now these two textures are in the pool's available set.
        // The executor will acquire them for offscreen A/B, and release must return them.

        let request = TimelineRenderRequest(
            resolved: .transition(transCtx),
            targetTexture: targetTex,
            drawableScale: 1.0,
            timelineCanvasSize: canvasSize,
            backgroundState: nil,
            backgroundTextureProvider: nil,
            clearColorOverride: nil,
            presentationDrawable: nil,
            waitUntilCompleted: false
        )
        try TimelineRenderExecutor.render(
            request, renderer: renderer,
            commandQueue: renderer.commandQueue,
            transitionCompositor: compositor,
            completionQueue: releaseQueue,
            onCommandBufferCompleted: { _ in
                completionExpectation.fulfill()
            }
        )

        wait(for: [completionExpectation], timeout: 5.0)

        // Drain releaseQueue to ensure the texture release block has completed.
        // Metal calls completion handlers in registration order:
        //   1. releaseQueue.async { pool.release(A); pool.release(B) }
        //   2. onCommandBufferCompleted (fulfills expectation)
        // After expectation fires, the releaseQueue.async block is already enqueued.
        // A sync barrier ensures it has finished.
        releaseQueue.sync {}

        // Now acquire two textures — they must be the same objects we seeded.
        let reacquired1 = texturePool.acquireColorTexture(size: sizePx)!
        let reacquired2 = texturePool.acquireColorTexture(size: sizePx)!
        let reacquiredIds: Set<ObjectIdentifier> = [ObjectIdentifier(reacquired1), ObjectIdentifier(reacquired2)]
        let seedIds: Set<ObjectIdentifier> = [seedId1, seedId2]

        XCTAssertEqual(reacquiredIds, seedIds, "Pool must return the same texture objects that were released by the async completion handler")

        texturePool.release(reacquired1)
        texturePool.release(reacquired2)
    }

    // MARK: - TT-12 Parity helper

    /// Renders preview and export for a given transition at the specified progress,
    /// validates output via `oracle`, and asserts pixel-identical preview/export parity.
    private func assertPreviewExportParity(
        transition: SceneTransition,
        progress: Double,
        textureA: MTLTexture? = nil,
        textureB: MTLTexture? = nil,
        oracle: ([UInt8]) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let canvasSize = SizeD(width: 16, height: 16)
        let texA = textureA ?? makeSolidTexture(width: 16, height: 16, red: 255, green: 0, blue: 0, alpha: 255)
        let texB = textureB ?? makeSolidTexture(width: 16, height: 16, red: 0, green: 0, blue: 255, alpha: 255)
        let ctxA = makeSceneContext(canvasSize: canvasSize, assetId: "parity_a", texture: texA)
        let ctxB = makeSceneContext(canvasSize: canvasSize, assetId: "parity_b", texture: texB)
        let transCtx = TransitionRenderContext(sceneA: ctxA, sceneB: ctxB, transition: transition, progress: progress)

        // Preview
        let previewTex = makeRenderTarget(width: 16, height: 16)
        let previewRequest = TimelineRenderRequest(
            resolved: .transition(transCtx),
            targetTexture: previewTex,
            drawableScale: 1.0,
            timelineCanvasSize: canvasSize,
            backgroundState: nil,
            backgroundTextureProvider: nil,
            clearColorOverride: nil,
            presentationDrawable: nil,
            waitUntilCompleted: true
        )
        try TimelineRenderExecutor.render(
            previewRequest, renderer: renderer,
            commandQueue: renderer.commandQueue,
            transitionCompositor: compositor,
            completionQueue: nil
        )

        // Export
        let exportTex = makeRenderTarget(width: 16, height: 16)
        let exportRequest = TimelineRenderRequest(
            resolved: .transition(transCtx),
            targetTexture: exportTex,
            drawableScale: 1.0,
            timelineCanvasSize: canvasSize,
            backgroundState: nil,
            backgroundTextureProvider: nil,
            clearColorOverride: .opaqueBlack,
            presentationDrawable: nil,
            waitUntilCompleted: true
        )
        try TimelineRenderExecutor.render(
            exportRequest, renderer: renderer,
            commandQueue: renderer.commandQueue,
            transitionCompositor: compositor,
            completionQueue: nil
        )

        let previewPixels = readPixels(from: previewTex)
        let exportPixels = readPixels(from: exportTex)

        oracle(previewPixels)
        XCTAssertEqual(previewPixels, exportPixels, "Preview and export must produce identical pixels", file: file, line: line)
    }

    // MARK: - 8. Slide transition parity

    func testTransition_slide_previewAndExportRequestsMatchAtScale1() throws {
        let transition = SceneTransition(type: .slide(direction: .left), durationFrames: 14, easingPreset: .easeInOut)
        try assertPreviewExportParity(transition: transition, progress: 0.5) { pixels in
            // BGRA8: index 0=B, 1=G, 2=R, 3=A
            var hasRed = false
            var hasBlu = false
            for i in stride(from: 0, to: pixels.count, by: 4) {
                if pixels[i + 2] > 128 { hasRed = true } // R channel (sceneA red)
                if pixels[i] > 128 { hasBlu = true }     // B channel (sceneB blue)
            }
            XCTAssertTrue(hasRed, "Slide at 0.5 must contain red pixels from sceneA")
            XCTAssertTrue(hasBlu, "Slide at 0.5 must contain blue pixels from sceneB")

            // Spatial asymmetry: left half ≠ right half
            let w = 16, h = 16
            var leftPixels = [UInt8]()
            var rightPixels = [UInt8]()
            for row in 0..<h {
                for col in 0..<w {
                    let base = (row * w + col) * 4
                    if col < w / 2 {
                        leftPixels.append(contentsOf: pixels[base..<base+4])
                    } else {
                        rightPixels.append(contentsOf: pixels[base..<base+4])
                    }
                }
            }
            XCTAssertNotEqual(leftPixels, rightPixels, "Slide transition must produce spatially asymmetric output")
        }
    }

    // MARK: - 9. Push transition parity

    func testTransition_push_previewAndExportRequestsMatchAtScale1() throws {
        let transition = SceneTransition(type: .push(direction: .left), durationFrames: 14, easingPreset: .easeInOut)
        try assertPreviewExportParity(transition: transition, progress: 0.5) { pixels in
            var hasRed = false
            var hasBlu = false
            for i in stride(from: 0, to: pixels.count, by: 4) {
                if pixels[i + 2] > 128 { hasRed = true }
                if pixels[i] > 128 { hasBlu = true }
            }
            XCTAssertTrue(hasRed, "Push at 0.5 must contain red pixels from sceneA")
            XCTAssertTrue(hasBlu, "Push at 0.5 must contain blue pixels from sceneB")

            let w = 16, h = 16
            var leftPixels = [UInt8]()
            var rightPixels = [UInt8]()
            for row in 0..<h {
                for col in 0..<w {
                    let base = (row * w + col) * 4
                    if col < w / 2 {
                        leftPixels.append(contentsOf: pixels[base..<base+4])
                    } else {
                        rightPixels.append(contentsOf: pixels[base..<base+4])
                    }
                }
            }
            XCTAssertNotEqual(leftPixels, rightPixels, "Push transition must produce spatially asymmetric output")
        }
    }

    // MARK: - 10. DipToBlack transition parity

    func testTransition_dipToBlack_previewAndExportRequestsMatchAtScale1() throws {
        let transition = SceneTransition(type: .dipToBlack, durationFrames: 14, easingPreset: .easeInOut)
        // Progress 0.25: Phase 1 (A → black) partially applied.
        // easeInOut(0.25) ≈ 0.156, shader t ≈ 0.3125 → mix(red, black, 0.3125)
        // Result is dimmed red, avg RGB lower than pure red/blue baseline (~85).
        try assertPreviewExportParity(transition: transition, progress: 0.25) { pixels in
            let baselineAvg: Double = 85.0
            var totalRGB: Double = 0
            let pixelCount = pixels.count / 4
            for i in stride(from: 0, to: pixels.count, by: 4) {
                totalRGB += Double(pixels[i])     // B
                totalRGB += Double(pixels[i + 1]) // G
                totalRGB += Double(pixels[i + 2]) // R
            }
            let avgRGB = totalRGB / Double(pixelCount * 3)
            XCTAssertLessThan(avgRGB, baselineAvg, "DipToBlack at 0.25 should produce darker output than pure red or blue (avg \(avgRGB) vs baseline \(baselineAvg))")
        }
    }

    // MARK: - 11. DipToWhite transition parity

    func testTransition_dipToWhite_previewAndExportRequestsMatchAtScale1() throws {
        let transition = SceneTransition(type: .dipToWhite, durationFrames: 14, easingPreset: .easeInOut)
        // Progress 0.25: Phase 1 (A → white) partially applied.
        // easeInOut(0.25) ≈ 0.156, shader t ≈ 0.3125 → mix(red, white, 0.3125)
        // Result has elevated G and B channels from white mix, avg RGB higher than baseline (~85).
        try assertPreviewExportParity(transition: transition, progress: 0.25) { pixels in
            let baselineAvg: Double = 85.0
            var totalRGB: Double = 0
            let pixelCount = pixels.count / 4
            for i in stride(from: 0, to: pixels.count, by: 4) {
                totalRGB += Double(pixels[i])     // B
                totalRGB += Double(pixels[i + 1]) // G
                totalRGB += Double(pixels[i + 2]) // R
            }
            let avgRGB = totalRGB / Double(pixelCount * 3)
            XCTAssertGreaterThan(avgRGB, baselineAvg, "DipToWhite at 0.25 should produce brighter output than pure red or blue (avg \(avgRGB) vs baseline \(baselineAvg))")
        }
    }

    // MARK: - 12. Photo-to-video media combination parity

    func testTransition_photoToVideo_previewAndExportMatch() throws {
        let greenTex = makeSolidTexture(width: 16, height: 16, red: 0, green: 255, blue: 0, alpha: 255)
        let magentaTex = makeSolidTexture(width: 16, height: 16, red: 255, green: 0, blue: 255, alpha: 255)
        let transition = SceneTransition(type: .fade, durationFrames: 14, easingPreset: .easeInOut)
        try assertPreviewExportParity(
            transition: transition,
            progress: 0.5,
            textureA: greenTex,
            textureB: magentaTex
        ) { pixels in
            // Fade at 0.5: expect both green and magenta channels present.
            // Green: G channel high. Magenta: R+B channels high.
            var hasGreen = false
            var hasRedOrBlue = false
            for i in stride(from: 0, to: pixels.count, by: 4) {
                if pixels[i + 1] > 64 { hasGreen = true }     // G channel
                if pixels[i + 2] > 64 || pixels[i] > 64 {     // R or B channel
                    hasRedOrBlue = true
                }
            }
            XCTAssertTrue(hasGreen, "Photo-to-video fade must contain green channel from photo scene")
            XCTAssertTrue(hasRedOrBlue, "Photo-to-video fade must contain red/blue channels from video scene")
        }
    }

    // MARK: - 13. Video-to-photo media combination parity

    func testTransition_videoToPhoto_previewAndExportMatch() throws {
        let magentaTex = makeSolidTexture(width: 16, height: 16, red: 255, green: 0, blue: 255, alpha: 255)
        let greenTex = makeSolidTexture(width: 16, height: 16, red: 0, green: 255, blue: 0, alpha: 255)
        let transition = SceneTransition(type: .fade, durationFrames: 14, easingPreset: .easeInOut)
        try assertPreviewExportParity(
            transition: transition,
            progress: 0.5,
            textureA: magentaTex,
            textureB: greenTex
        ) { pixels in
            var hasGreen = false
            var hasRedOrBlue = false
            for i in stride(from: 0, to: pixels.count, by: 4) {
                if pixels[i + 1] > 64 { hasGreen = true }
                if pixels[i + 2] > 64 || pixels[i] > 64 {
                    hasRedOrBlue = true
                }
            }
            XCTAssertTrue(hasGreen, "Video-to-photo fade must contain green channel from photo scene")
            XCTAssertTrue(hasRedOrBlue, "Video-to-photo fade must contain red/blue channels from video scene")
        }
    }

    // MARK: - 7. Missing completionQueue for async transition throws

    func testAsyncTransition_withoutCompletionQueue_throwsMissingCompletionQueue() {
        let canvasSize = SizeD(width: 16, height: 16)
        let ctx = makeSceneContext(
            canvasSize: canvasSize, assetId: "img",
            texture: makeSolidTexture(width: 16, height: 16, red: 128, green: 128, blue: 128, alpha: 255)
        )
        let transition = SceneTransition(type: .fade, durationFrames: 14, easingPreset: .linear)
        let transCtx = TransitionRenderContext(sceneA: ctx, sceneB: ctx, transition: transition, progress: 0.5)

        let tex = makeRenderTarget(width: 16, height: 16)
        let request = TimelineRenderRequest(
            resolved: .transition(transCtx),
            targetTexture: tex,
            drawableScale: 1.0,
            timelineCanvasSize: canvasSize,
            backgroundState: nil,
            backgroundTextureProvider: nil,
            clearColorOverride: nil,
            presentationDrawable: nil,
            waitUntilCompleted: false
        )

        XCTAssertThrowsError(
            try TimelineRenderExecutor.render(
                request, renderer: renderer,
                commandQueue: renderer.commandQueue,
                transitionCompositor: compositor,
                completionQueue: nil
            )
        ) { error in
            XCTAssertEqual(error as? TimelineRenderExecutorError, .missingCompletionQueueForAsyncTransition)
        }
    }

    // MARK: - 14. Text overlay cache produces non-zero pixels

    func testOverlayCache_textProducesNonTransparentPixels() throws {
        let size = 64
        let canvasSize = SizeD(width: Double(size), height: Double(size))
        let cache = OverlayRenderResourceCache()
        let item = ResolvedOverlayRenderItem(
            stableId: UUID(),
            kind: .text,
            content: .text(text: "HELLO", fontFamily: nil, fontSize: 24, colorHex: "#FFFFFF"),
            presentation: .default(centerX: 0.5, centerY: 0.5),
            zOrder: 0
        )
        let entry = try XCTUnwrap(
            cache.texture(for: item, device: device, canvasSize: canvasSize, canvasPixelWidth: size),
            "Cache must return non-nil for text overlay"
        )

        let pixels = readPixels(from: entry.texture)
        let hasNonTransparentPixel = stride(from: 0, to: pixels.count, by: 4).contains { i in
            pixels[i + 3] > 0
        }
        XCTAssertTrue(hasNonTransparentPixel, "Text overlay cache must produce non-transparent pixels")
    }

    // MARK: - 14b. Text overlay GPU composition produces visible pixels

    func testSingle_textOverlay_producesVisiblePixels() throws {
        let canvasSize = SizeD(width: 64, height: 64)
        let assetTex = makeSolidTexture(width: 64, height: 64, red: 0, green: 0, blue: 0, alpha: 255)
        let ctx = makeSceneContext(canvasSize: canvasSize, assetId: "bg_black", texture: assetTex)

        let tex = makeRenderTarget(width: 64, height: 64)
        let request = TimelineRenderRequest(
            resolved: .single(ctx),
            targetTexture: tex,
            drawableScale: 1.0,
            timelineCanvasSize: canvasSize,
            backgroundState: nil,
            backgroundTextureProvider: nil,
            clearColorOverride: .opaqueBlack,
            presentationDrawable: nil,
            waitUntilCompleted: true,
            overlayItems: [
                ResolvedOverlayRenderItem(
                    stableId: UUID(),
                    kind: .text,
                    content: .text(text: "HELLO", fontFamily: nil, fontSize: 24, colorHex: "#FFFFFF"),
                    presentation: .default(centerX: 0.5, centerY: 0.5),
                    zOrder: 1
                )
            ]
        )
        try TimelineRenderExecutor.render(
            request, renderer: renderer,
            commandQueue: renderer.commandQueue,
            transitionCompositor: nil,
            completionQueue: nil,
            overlayCache: OverlayRenderResourceCache()
        )

        let pixels = readPixels(from: tex)
        // Text "HELLO" in white on black — at least one pixel must have non-zero R/G/B
        let hasNonBlackPixel = stride(from: 0, to: pixels.count, by: 4).contains { i in
            pixels[i] > 0 || pixels[i + 1] > 0 || pixels[i + 2] > 0
        }
        XCTAssertTrue(hasNonBlackPixel, "Text overlay must produce visible (non-black) pixels")
    }

    // MARK: - 15. Sticker overlay produces visible pixels (GPU composition)

    func testSingle_stickerOverlay_producesVisiblePixels() throws {
        let canvasSize = SizeD(width: 128, height: 128)
        let assetTex = makeSolidTexture(width: 128, height: 128, red: 0, green: 0, blue: 0, alpha: 255)
        let ctx = makeSceneContext(canvasSize: canvasSize, assetId: "bg_black", texture: assetTex)

        // Create a temporary red PNG as sticker fixture (32x32 so 15% of 128 = ~19px is enough)
        let stickerURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_sticker_\(UUID().uuidString).png")
        let stickerSize = 32
        var stickerPixels = [UInt8](repeating: 0, count: stickerSize * stickerSize * 4)
        for i in stride(from: 0, to: stickerPixels.count, by: 4) {
            stickerPixels[i]     = 255   // R (premultipliedLast = RGBA)
            stickerPixels[i + 1] = 0     // G
            stickerPixels[i + 2] = 0     // B
            stickerPixels[i + 3] = 255   // A
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let cgContext = CGContext(
            data: &stickerPixels,
            width: stickerSize, height: stickerSize,
            bitsPerComponent: 8, bytesPerRow: stickerSize * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
        let cgImage = cgContext.makeImage(),
        let pngData = UIImage(cgImage: cgImage).pngData()
        else {
            XCTFail("Failed to create sticker fixture PNG")
            return
        }
        try pngData.write(to: stickerURL)
        defer { try? FileManager.default.removeItem(at: stickerURL) }

        let tex = makeRenderTarget(width: 128, height: 128)
        let request = TimelineRenderRequest(
            resolved: .single(ctx),
            targetTexture: tex,
            drawableScale: 1.0,
            timelineCanvasSize: canvasSize,
            backgroundState: nil,
            backgroundTextureProvider: nil,
            clearColorOverride: .opaqueBlack,
            presentationDrawable: nil,
            waitUntilCompleted: true,
            overlayItems: [
                ResolvedOverlayRenderItem(
                    stableId: UUID(),
                    kind: .sticker,
                    content: .sticker(stickerId: "test_sticker", imageURL: stickerURL),
                    presentation: .default(centerX: 0.5, centerY: 0.5),
                    zOrder: 0
                )
            ]
        )
        try TimelineRenderExecutor.render(
            request, renderer: renderer,
            commandQueue: renderer.commandQueue,
            transitionCompositor: nil,
            completionQueue: nil,
            overlayCache: OverlayRenderResourceCache()
        )

        let pixels = readPixels(from: tex)
        // Sticker on black — at least one pixel with non-zero color channels
        let hasColorPixel = stride(from: 0, to: pixels.count, by: 4).contains { i in
            pixels[i] > 0 || pixels[i + 1] > 0 || pixels[i + 2] > 0
        }
        XCTAssertTrue(hasColorPixel, "Sticker overlay must produce visible pixels")
    }

    // MARK: - 16. Transition with overlays produces visible overlay pixels

    func testTransition_withOverlays_producesVisiblePixels() throws {
        let canvasSize = SizeD(width: 16, height: 16)
        let texA = makeSolidTexture(width: 16, height: 16, red: 0, green: 0, blue: 0, alpha: 255)
        let texB = makeSolidTexture(width: 16, height: 16, red: 0, green: 0, blue: 0, alpha: 255)
        let ctxA = makeSceneContext(canvasSize: canvasSize, assetId: "scene_a", texture: texA)
        let ctxB = makeSceneContext(canvasSize: canvasSize, assetId: "scene_b", texture: texB)
        let transition = SceneTransition(type: .fade, durationFrames: 14, easingPreset: .linear)
        let transCtx = TransitionRenderContext(sceneA: ctxA, sceneB: ctxB, transition: transition, progress: 0.5)

        let tex = makeRenderTarget(width: 16, height: 16)
        let request = TimelineRenderRequest(
            resolved: .transition(transCtx),
            targetTexture: tex,
            drawableScale: 1.0,
            timelineCanvasSize: canvasSize,
            backgroundState: nil,
            backgroundTextureProvider: nil,
            clearColorOverride: .opaqueBlack,
            presentationDrawable: nil,
            waitUntilCompleted: true,
            overlayItems: [
                ResolvedOverlayRenderItem(
                    stableId: UUID(),
                    kind: .text,
                    content: .text(text: "X", fontFamily: nil, fontSize: 14, colorHex: "#FFFFFF"),
                    presentation: .default(centerX: 0.5, centerY: 0.5),
                    zOrder: 1
                )
            ]
        )
        try TimelineRenderExecutor.render(
            request, renderer: renderer,
            commandQueue: renderer.commandQueue,
            transitionCompositor: compositor,
            completionQueue: nil,
            overlayCache: OverlayRenderResourceCache()
        )

        let pixels = readPixels(from: tex)
        let hasNonBlackPixel = stride(from: 0, to: pixels.count, by: 4).contains { i in
            pixels[i] > 0 || pixels[i + 1] > 0 || pixels[i + 2] > 0
        }
        XCTAssertTrue(hasNonBlackPixel, "Transition with text overlay must produce visible pixels")
    }

    // MARK: - 17. No overlays does not alter pixels

    func testNoOverlays_doesNotAlterPixels() throws {
        let canvasSize = SizeD(width: 16, height: 16)
        let assetTex = makeSolidTexture(width: 16, height: 16, red: 200, green: 100, blue: 50, alpha: 255)
        let ctx = makeSceneContext(canvasSize: canvasSize, assetId: "test_img", texture: assetTex)

        // Render without overlays
        let baselineTex = makeRenderTarget(width: 16, height: 16)
        let baselineRequest = TimelineRenderRequest(
            resolved: .single(ctx),
            targetTexture: baselineTex,
            drawableScale: 1.0,
            timelineCanvasSize: canvasSize,
            backgroundState: nil,
            backgroundTextureProvider: nil,
            clearColorOverride: .opaqueBlack,
            presentationDrawable: nil,
            waitUntilCompleted: true
        )
        try TimelineRenderExecutor.render(
            baselineRequest, renderer: renderer,
            commandQueue: renderer.commandQueue,
            transitionCompositor: nil,
            completionQueue: nil
        )

        // Render with empty overlay arrays (explicit)
        let overlayTex = makeRenderTarget(width: 16, height: 16)
        let overlayRequest = TimelineRenderRequest(
            resolved: .single(ctx),
            targetTexture: overlayTex,
            drawableScale: 1.0,
            timelineCanvasSize: canvasSize,
            backgroundState: nil,
            backgroundTextureProvider: nil,
            clearColorOverride: .opaqueBlack,
            presentationDrawable: nil,
            waitUntilCompleted: true,
            overlayItems: []
        )
        try TimelineRenderExecutor.render(
            overlayRequest, renderer: renderer,
            commandQueue: renderer.commandQueue,
            transitionCompositor: nil,
            completionQueue: nil
        )

        let baselinePixels = readPixels(from: baselineTex)
        let overlayPixels = readPixels(from: overlayTex)
        XCTAssertEqual(baselinePixels, overlayPixels, "Empty overlay arrays must produce pixel-identical output to no overlays")
    }

    // MARK: - 18. Private storage target does not crash (device-like surface)

    func testSingle_textOverlay_privateStorageTarget_doesNotCrash() throws {
        let canvasSize = SizeD(width: 64, height: 64)
        let assetTex = makeSolidTexture(width: 64, height: 64, red: 0, green: 0, blue: 0, alpha: 255)
        let ctx = makeSceneContext(canvasSize: canvasSize, assetId: "bg_black", texture: assetTex)

        let tex = makeRenderTarget(width: 64, height: 64, storageMode: .private)
        let request = TimelineRenderRequest(
            resolved: .single(ctx),
            targetTexture: tex,
            drawableScale: 1.0,
            timelineCanvasSize: canvasSize,
            backgroundState: nil,
            backgroundTextureProvider: nil,
            clearColorOverride: .opaqueBlack,
            presentationDrawable: nil,
            waitUntilCompleted: true,
            overlayItems: [
                ResolvedOverlayRenderItem(
                    stableId: UUID(),
                    kind: .text,
                    content: .text(text: "HELLO", fontFamily: nil, fontSize: 24, colorHex: "#FFFFFF"),
                    presentation: .default(centerX: 0.5, centerY: 0.5),
                    zOrder: 1
                )
            ]
        )
        try TimelineRenderExecutor.render(
            request, renderer: renderer,
            commandQueue: renderer.commandQueue,
            transitionCompositor: nil,
            completionQueue: nil,
            overlayCache: OverlayRenderResourceCache()
        )

        // Blit from .private → .shared to verify pixels
        let pixels = readPixelsViaBlit(from: tex)
        let hasNonBlackPixel = stride(from: 0, to: pixels.count, by: 4).contains { i in
            pixels[i] > 0 || pixels[i + 1] > 0 || pixels[i + 2] > 0
        }
        XCTAssertTrue(hasNonBlackPixel, "Text overlay on .private target must produce visible pixels (no crash, correct composition)")
    }

    // MARK: - 19. Off-main overlay cache correctness (export path simulation)

    func testOverlayCache_offMainThread_producesNonTransparentPixels() throws {
        let expectation = expectation(description: "off-main cache completes")
        var offMainResult: MTLTexture?
        let capturedDevice = device!

        DispatchQueue.global(qos: .userInitiated).async {
            let size = 64
            let canvasSize = SizeD(width: Double(size), height: Double(size))
            let cache = OverlayRenderResourceCache()
            let item = ResolvedOverlayRenderItem(
                stableId: UUID(),
                kind: .text,
                content: .text(text: "EXPORT", fontFamily: nil, fontSize: 20, colorHex: "#FF0000"),
                presentation: .default(centerX: 0.5, centerY: 0.5),
                zOrder: 0
            )
            offMainResult = cache.texture(
                for: item, device: capturedDevice,
                canvasSize: canvasSize, canvasPixelWidth: size
            )?.texture
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)

        let texture = try XCTUnwrap(offMainResult, "Off-main cache must return non-nil texture")
        let pixels = readPixels(from: texture)
        let hasNonTransparentPixel = stride(from: 0, to: pixels.count, by: 4).contains { i in
            pixels[i + 3] > 0
        }
        XCTAssertTrue(hasNonTransparentPixel, "Off-main cache must produce non-transparent pixels (export path)")
    }
}
