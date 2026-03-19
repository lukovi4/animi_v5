import XCTest
import Metal
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

    private func makeRenderTarget(width: Int, height: Int) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width, height: height,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead, .shaderWrite]
        desc.storageMode = .shared
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
}
