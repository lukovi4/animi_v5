import Metal
import TVECore

// MARK: - TT-06: Unified Render Executor

/// Errors specific to the unified render executor.
internal enum TimelineRenderExecutorError: Error, Sendable, Equatable {
    case failedToCreateCommandBuffer
    case failedToAcquireOffscreenTexture
    case missingTransitionCompositor
    case missingCompletionQueueForAsyncTransition
}

/// Describes everything needed to render one timeline frame.
internal struct TimelineRenderRequest {
    let resolved: ResolvedTimelineFrame
    let targetTexture: MTLTexture
    let drawableScale: Double
    let timelineCanvasSize: SizeD
    let backgroundState: EffectiveBackgroundState?
    let backgroundTextureProvider: TextureProvider?
    let clearColorOverride: ClearColor?   // nil -> renderer default; non-nil -> explicit
    let presentationDrawable: MTLDrawable?
    let waitUntilCompleted: Bool
    /// Optional diagnostic frame tag (compressed frame for preview, export frame index for export).
    let diagnosticFrameTag: Int?
    /// Resolved overlay items to render on top of the scene (stickers below text by zOrder).
    let overlayItems: [ResolvedOverlayRenderItem]

    init(
        resolved: ResolvedTimelineFrame,
        targetTexture: MTLTexture,
        drawableScale: Double,
        timelineCanvasSize: SizeD,
        backgroundState: EffectiveBackgroundState?,
        backgroundTextureProvider: TextureProvider?,
        clearColorOverride: ClearColor?,
        presentationDrawable: MTLDrawable?,
        waitUntilCompleted: Bool,
        diagnosticFrameTag: Int? = nil,
        overlayItems: [ResolvedOverlayRenderItem] = []
    ) {
        self.resolved = resolved
        self.targetTexture = targetTexture
        self.drawableScale = drawableScale
        self.timelineCanvasSize = timelineCanvasSize
        self.backgroundState = backgroundState
        self.backgroundTextureProvider = backgroundTextureProvider
        self.clearColorOverride = clearColorOverride
        self.presentationDrawable = presentationDrawable
        self.waitUntilCompleted = waitUntilCompleted
        self.diagnosticFrameTag = diagnosticFrameTag
        self.overlayItems = overlayItems
    }
}

/// Single composition contract for both preview and export paths.
/// Eliminates ~150 lines of duplicated render logic.
internal enum TimelineRenderExecutor {

    /// Render a timeline frame according to `request`.
    ///
    /// - `waitUntilCompleted == true` (export): synchronous commit+wait, textures released via defer.
    /// - `waitUntilCompleted == false` (preview): async commit, textures released in Metal completion handler
    ///   dispatched on `completionQueue`. If rendering a transition with `waitUntilCompleted == false`,
    ///   `completionQueue` **must** be non-nil.
    ///
    /// `onCommandBufferCompleted` is called directly from the Metal completion handler (non-blocking path)
    /// or synchronously after `waitUntilCompleted()` (blocking path). Use it for semaphore signaling.
    static func render(
        _ request: TimelineRenderRequest,
        renderer: MetalRenderer,
        commandQueue: MTLCommandQueue,
        transitionCompositor: TransitionCompositor?,
        completionQueue: DispatchQueue?,
        overlayCache: OverlayRenderResourceCache? = nil,
        onCommandBufferCompleted: ((MTLCommandBuffer) -> Void)? = nil,
        renderSink: RenderDiagnosticsSink? = nil
    ) throws {
        #if DEBUG
        if !request.overlayItems.isEmpty && overlayCache == nil {
            assertionFailure("[OverlayCompositor] overlayItems present but overlayCache is nil — overlays will not render")
        }
        #endif

        guard let cmdBuf = commandQueue.makeCommandBuffer() else {
            throw TimelineRenderExecutorError.failedToCreateCommandBuffer
        }

        switch request.resolved {
        case .single(let ctx):
            try renderSingle(request: request, context: ctx, renderer: renderer, commandBuffer: cmdBuf, overlayCache: overlayCache)

        case .transition(let ctx):
            guard let compositor = transitionCompositor else {
                throw TimelineRenderExecutorError.missingTransitionCompositor
            }
            let encodeStart = CFAbsoluteTimeGetCurrent()
            try renderTransition(
                request: request, context: ctx,
                renderer: renderer, compositor: compositor,
                commandBuffer: cmdBuf, completionQueue: completionQueue,
                overlayCache: overlayCache, renderSink: renderSink
            )
            let encodeTime = CFAbsoluteTimeGetCurrent() - encodeStart
            renderSink?.receive(.compositorEncodeTime(seconds: encodeTime))
        }

        // Emit firstCompositedFrame if diagnostic tag is set
        if let frameTag = request.diagnosticFrameTag {
            renderSink?.receive(.firstCompositedFrame(frameTag: frameTag))
        }

        if let drawable = request.presentationDrawable {
            cmdBuf.present(drawable)
        }

        if request.waitUntilCompleted {
            cmdBuf.commit()
            cmdBuf.waitUntilCompleted()
            onCommandBufferCompleted?(cmdBuf)
        } else {
            if let handler = onCommandBufferCompleted {
                cmdBuf.addCompletedHandler { cb in handler(cb) }
            }
            cmdBuf.commit()
        }
    }

    /// Compute offscreen pixel dimensions from canvas size and drawable scale.
    static func offscreenPixelSize(
        canvasSize: SizeD, drawableScale: Double
    ) -> (width: Int, height: Int) {
        (max(1, Int(round(canvasSize.width * drawableScale))),
         max(1, Int(round(canvasSize.height * drawableScale))))
    }

    // MARK: - Private Helpers

    private static func renderSingle(
        request: TimelineRenderRequest,
        context ctx: SceneRenderContext,
        renderer: MetalRenderer,
        commandBuffer: MTLCommandBuffer,
        overlayCache: OverlayRenderResourceCache?
    ) throws {
        let bgProvider: TextureProvider = request.backgroundTextureProvider ?? InMemoryTextureProvider()
        let target = RenderTarget(
            texture: request.targetTexture,
            drawableScale: request.drawableScale,
            animSize: ctx.canvasSize
        )

        // Pass 1: Background pre-pass
        try drawPass(
            renderer: renderer,
            commands: [],
            target: target,
            clearColorOverride: request.clearColorOverride,
            textureProvider: bgProvider,
            commandBuffer: commandBuffer,
            assetSizes: [:],
            pathRegistry: PathRegistry(),
            backgroundState: request.backgroundState,
            initialLoadAction: .clear
        )

        // Pass 2: Scene pass (preserves background)
        try drawPass(
            renderer: renderer,
            commands: ctx.commands,
            target: target,
            clearColorOverride: request.clearColorOverride,
            textureProvider: ctx.textureProvider,
            commandBuffer: commandBuffer,
            assetSizes: ctx.assetSizes,
            pathRegistry: ctx.pathRegistry,
            backgroundState: nil,
            initialLoadAction: .load
        )

        // Pass 3: Overlay composition (retained-mode per-item GPU composite)
        if let cache = overlayCache {
            try OverlayCompositor.compose(
                items: request.overlayItems,
                cache: cache,
                target: target,
                renderer: renderer,
                commandBuffer: commandBuffer,
                device: target.texture.device,
                canvasSize: ctx.canvasSize,
                clearColorOverride: request.clearColorOverride
            )
        }
    }

    private static func renderTransition(
        request: TimelineRenderRequest,
        context ctx: TransitionRenderContext,
        renderer: MetalRenderer,
        compositor: TransitionCompositor,
        commandBuffer: MTLCommandBuffer,
        completionQueue: DispatchQueue?,
        overlayCache: OverlayRenderResourceCache?,
        renderSink: RenderDiagnosticsSink? = nil
    ) throws {
        #if DEBUG
        assert(ctx.sceneA.canvasSize == ctx.sceneB.canvasSize,
               "Mixed-canvas transitions are not supported")
        #endif

        // Non-blocking transition requires a completion queue for thread-safe texture release.
        // TexturePool is not thread-safe — releasing from Metal's arbitrary callback queue is unsafe.
        if !request.waitUntilCompleted && completionQueue == nil {
            throw TimelineRenderExecutorError.missingCompletionQueueForAsyncTransition
        }

        let texturePool = renderer.texturePool
        let sizePx = offscreenPixelSize(
            canvasSize: ctx.sceneA.canvasSize,
            drawableScale: request.drawableScale
        )

        guard let textureA = TexturePool.withDebugOwner("timeline.transition.offscreen", {
                  texturePool.acquireColorTexture(size: sizePx)
              }),
              let textureB = TexturePool.withDebugOwner("timeline.transition.offscreen", {
                  texturePool.acquireColorTexture(size: sizePx)
              }) else {
            throw TimelineRenderExecutorError.failedToAcquireOffscreenTexture
        }

        // Emit offscreen render events
        renderSink?.receive(.offscreenRenderA(instanceId: ctx.sceneA.sceneInstanceId))
        renderSink?.receive(.offscreenRenderB(instanceId: ctx.sceneB.sceneInstanceId))

        // Texture release strategy depends on sync vs async path
        if request.waitUntilCompleted {
            defer {
                texturePool.release(textureA)
                texturePool.release(textureB)
            }
            try encodeTransition(
                request: request, context: ctx,
                renderer: renderer, compositor: compositor,
                commandBuffer: commandBuffer,
                textureA: textureA, textureB: textureB,
                overlayCache: overlayCache
            )
        } else {
            // Non-blocking: release via completion handler on safe queue
            do {
                try encodeTransition(
                    request: request, context: ctx,
                    renderer: renderer, compositor: compositor,
                    commandBuffer: commandBuffer,
                    textureA: textureA, textureB: textureB,
                    overlayCache: overlayCache
                )
            } catch {
                // Encoding failed — release immediately, handler not registered
                texturePool.release(textureA)
                texturePool.release(textureB)
                throw error
            }
            // Register release after successful encoding.
            // completionQueue is guaranteed non-nil here (guarded above).
            let releaseQueue = completionQueue!
            commandBuffer.addCompletedHandler { _ in
                releaseQueue.async {
                    texturePool.release(textureA)
                    texturePool.release(textureB)
                }
            }
        }
    }

    private static func encodeTransition(
        request: TimelineRenderRequest,
        context ctx: TransitionRenderContext,
        renderer: MetalRenderer,
        compositor: TransitionCompositor,
        commandBuffer: MTLCommandBuffer,
        textureA: MTLTexture,
        textureB: MTLTexture,
        overlayCache: OverlayRenderResourceCache?
    ) throws {
        // Render scene A offscreen
        let targetA = RenderTarget(texture: textureA, drawableScale: 1.0, animSize: ctx.sceneA.canvasSize)
        try renderer.draw(
            commands: ctx.sceneA.commands,
            target: targetA,
            clearColor: .transparentBlack,
            textureProvider: ctx.sceneA.textureProvider,
            commandBuffer: commandBuffer,
            assetSizes: ctx.sceneA.assetSizes,
            pathRegistry: ctx.sceneA.pathRegistry,
            backgroundState: nil
        )

        // Render scene B offscreen
        let targetB = RenderTarget(texture: textureB, drawableScale: 1.0, animSize: ctx.sceneB.canvasSize)
        try renderer.draw(
            commands: ctx.sceneB.commands,
            target: targetB,
            clearColor: .transparentBlack,
            textureProvider: ctx.sceneB.textureProvider,
            commandBuffer: commandBuffer,
            assetSizes: ctx.sceneB.assetSizes,
            pathRegistry: ctx.sceneB.pathRegistry,
            backgroundState: nil
        )

        // Background pre-pass on final target
        let bgProvider: TextureProvider = request.backgroundTextureProvider ?? InMemoryTextureProvider()
        let finalTarget = RenderTarget(
            texture: request.targetTexture,
            drawableScale: request.drawableScale,
            animSize: request.timelineCanvasSize
        )
        try drawPass(
            renderer: renderer,
            commands: [],
            target: finalTarget,
            clearColorOverride: request.clearColorOverride,
            textureProvider: bgProvider,
            commandBuffer: commandBuffer,
            assetSizes: [:],
            pathRegistry: PathRegistry(),
            backgroundState: request.backgroundState,
            initialLoadAction: .clear
        )

        // Composite A + B
        try compositor.composite(
            sceneA: textureA,
            sceneB: textureB,
            transition: ctx.transition.toTransitionParams(),
            progress: ctx.progress,
            canvasSize: request.timelineCanvasSize,
            target: request.targetTexture,
            commandBuffer: commandBuffer
        )

        // Pass 3: Overlay composition (retained-mode per-item GPU composite)
        if let cache = overlayCache {
            let overlayTarget = RenderTarget(
                texture: request.targetTexture,
                drawableScale: request.drawableScale,
                animSize: request.timelineCanvasSize
            )
            try OverlayCompositor.compose(
                items: request.overlayItems,
                cache: cache,
                target: overlayTarget,
                renderer: renderer,
                commandBuffer: commandBuffer,
                device: request.targetTexture.device,
                canvasSize: request.timelineCanvasSize,
                clearColorOverride: request.clearColorOverride
            )
        }
    }

    /// Routes to the appropriate MetalRenderer.draw overload based on clearColorOverride.
    private static func drawPass(
        renderer: MetalRenderer,
        commands: [RenderCommand],
        target: RenderTarget,
        clearColorOverride: ClearColor?,
        textureProvider: TextureProvider,
        commandBuffer: MTLCommandBuffer,
        assetSizes: [String: AssetSize],
        pathRegistry: PathRegistry,
        backgroundState: EffectiveBackgroundState?,
        initialLoadAction: MTLLoadAction
    ) throws {
        if let clearColor = clearColorOverride {
            try renderer.draw(
                commands: commands,
                target: target,
                clearColor: clearColor,
                textureProvider: textureProvider,
                commandBuffer: commandBuffer,
                assetSizes: assetSizes,
                pathRegistry: pathRegistry,
                backgroundState: backgroundState,
                initialLoadAction: initialLoadAction
            )
        } else {
            try renderer.draw(
                commands: commands,
                target: target,
                textureProvider: textureProvider,
                commandBuffer: commandBuffer,
                assetSizes: assetSizes,
                pathRegistry: pathRegistry,
                backgroundState: backgroundState,
                initialLoadAction: initialLoadAction
            )
        }
    }

}
