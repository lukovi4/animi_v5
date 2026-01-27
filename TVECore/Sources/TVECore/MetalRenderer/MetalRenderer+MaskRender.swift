import Metal
import simd

// MARK: - Mask Debug Counters

#if DEBUG
/// Debug counters for mask rendering verification (PR-C4).
/// Used to ensure GPU mask path is always taken and no fallbacks occur in tests.
/// - Note: Internal visibility to avoid polluting public API surface.
enum MaskDebugCounters {
    /// Number of times GPU mask fallback was triggered (degenerate bbox or allocation failure).
    /// Should be 0 in all mask tests to prove GPU path is working correctly.
    static var fallbackCount = 0

    /// Resets all counters. Call at the start of each test.
    static func reset() {
        fallbackCount = 0
    }
}
#endif

// MARK: - GPU Mask Group Rendering

extension MetalRenderer {
    /// Renders a mask group scope using GPU-based boolean operations.
    ///
    /// Algorithm:
    /// 1. Compute bbox from all mask paths
    /// 2. Allocate bbox-sized textures (coverage, accumA, accumB, content)
    /// 3. Clear accumulator with initial value based on first op mode
    /// 4. For each mask op: clear coverage → draw triangles → combine (ping-pong)
    /// 5. Render inner content to bbox-sized texture
    /// 6. Composite content × finalMask to main target
    ///
    /// - Parameters:
    ///   - scope: Extracted mask group scope with ops in AE order
    ///   - ctx: Mask scope rendering context
    ///   - inheritedState: Current execution state (transforms, scissors)
    func renderMaskGroupScope(
        scope: MaskGroupScope,
        ctx: MaskScopeContext,
        inheritedState: ExecutionState
    ) throws {
        // 1) Compute bbox
        var scratch: [Float] = []
        guard let bboxFloat = computeMaskGroupBboxFloat(
            ops: scope.opsInAeOrder,
            pathRegistry: ctx.pathRegistry,
            animToViewport: ctx.animToViewport,
            currentTransform: inheritedState.currentTransform,
            scratch: &scratch
        ),
        let bbox = roundClampIntersectBBoxToPixels(
            bboxFloat,
            targetSize: ctx.target.sizePx,
            scissor: inheritedState.currentScissor,
            expandAA: 2
        ) else {
            // Degenerate bbox - fallback: render inner commands without mask
            #if DEBUG
            MaskDebugCounters.fallbackCount += 1
            #endif
            try renderInnerCommandsFallback(
                scope.innerCommands,
                ctx: ctx,
                inheritedState: inheritedState
            )
            return
        }

        let bboxSize = (width: bbox.width, height: bbox.height)
        let bboxLocalScissor = MTLScissorRect(x: 0, y: 0, width: bbox.width, height: bbox.height)

        // 2) Allocate textures
        guard let coverageTex = texturePool.acquireR8Texture(size: bboxSize),
              let accumA = texturePool.acquireR8Texture(size: bboxSize),
              let accumB = texturePool.acquireR8Texture(size: bboxSize),
              let contentTex = texturePool.acquireColorTexture(size: bboxSize) else {
            // Allocation failed - fallback: render inner commands without mask
            #if DEBUG
            MaskDebugCounters.fallbackCount += 1
            #endif
            try renderInnerCommandsFallback(
                scope.innerCommands,
                ctx: ctx,
                inheritedState: inheritedState
            )
            return
        }
        defer {
            texturePool.release(coverageTex)
            texturePool.release(accumA)
            texturePool.release(accumB)
            texturePool.release(contentTex)
        }

        // 3) Clear accumulator with initial value
        let initVal = initialAccumulatorValue(for: scope.opsInAeOrder)
        clearR8Texture(accumA, value: initVal, commandBuffer: ctx.commandBuffer)

        var accIn = accumA
        var accOut = accumB

        // 4) Compute transforms for coverage rendering
        // Transform chain: point → pathToViewport → viewportToBbox → bboxToNDC
        // With A.concatenating(B) = "B first, then A", we build right-to-left:
        //   result = bboxToNDC ∘ viewportToBbox ∘ pathToViewport
        //          = bboxToNDC.concatenating(viewportToBbox.concatenating(pathToViewport))

        // pathToViewport: path coords → viewport pixels
        // animToViewport ∘ currentTransform means: currentTransform first, then animToViewport
        let pathToViewport = ctx.animToViewport.concatenating(inheritedState.currentTransform)

        // viewportToBbox: viewport pixels → bbox-local pixels (translate by -bbox.origin)
        let viewportToBbox = Matrix2D.translation(x: Double(-bbox.x), y: Double(-bbox.y))

        // bboxToNDC: bbox-local pixels → NDC
        let bboxToNDC = GeometryMapping.viewportToNDC(width: Double(bbox.width), height: Double(bbox.height))

        // Full chain: bboxToNDC ∘ viewportToBbox ∘ pathToViewport
        let pathToNDC = bboxToNDC.concatenating(viewportToBbox.concatenating(pathToViewport))
        let mvp = pathToNDC.toFloat4x4()

        // 5) Process each mask operation
        for op in scope.opsInAeOrder {
            // Clear coverage to 0
            clearR8Texture(coverageTex, value: 0, commandBuffer: ctx.commandBuffer)

            // Draw coverage triangles
            try renderCoverage(
                pathId: op.pathId,
                frame: op.frame,
                into: coverageTex,
                mvp: mvp,
                scissor: bboxLocalScissor,
                pathRegistry: ctx.pathRegistry,
                commandBuffer: ctx.commandBuffer,
                scratch: &scratch
            )

            // Combine with ping-pong (accIn !== accOut guaranteed by swap)
            precondition(accIn !== accOut, "Ping-pong violation: accIn === accOut")
            combineMask(
                coverage: coverageTex,
                accumIn: accIn,
                accumOut: accOut,
                mode: op.mode,
                inverted: op.inverted,
                opacity: Float(op.opacity),
                commandBuffer: ctx.commandBuffer
            )

            // Swap accumulators
            swap(&accIn, &accOut)
        }

        // After loop: final mask is in accIn
        let finalMask = accIn

        // 6) Render inner content to bbox-sized texture
        clearColorTexture(contentTex, commandBuffer: ctx.commandBuffer)

        // Create bbox-local context
        let offscreenTarget = RenderTarget(
            texture: contentTex,
            drawableScale: ctx.target.drawableScale,
            animSize: ctx.target.animSize // Keep original animSize
        )

        // Shift animToViewport for bbox-local rendering:
        // point → animToViewport → viewportToBbox
        // = viewportToBbox ∘ animToViewport (viewportToBbox applied after animToViewport)
        let bboxAnimToViewport = viewportToBbox.concatenating(ctx.animToViewport)

        // Create modified state with bbox-local scissor
        var bboxState = inheritedState
        // Replace scissor stack with bbox-local scissor
        bboxState.clipStack = [bboxLocalScissor]

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = contentTex
        descriptor.colorAttachments[0].loadAction = .load // Already cleared
        descriptor.colorAttachments[0].storeAction = .store

        try drawInternal(
            commands: scope.innerCommands,
            renderPassDescriptor: descriptor,
            target: offscreenTarget,
            textureProvider: ctx.textureProvider,
            commandBuffer: ctx.commandBuffer,
            assetSizes: ctx.assetSizes,
            pathRegistry: ctx.pathRegistry,
            initialState: bboxState,
            overrideAnimToViewport: bboxAnimToViewport
        )

        // 7) Composite content × mask to main target
        try compositeMaskedQuad(
            content: contentTex,
            mask: finalMask,
            bbox: bbox,
            target: ctx.target,
            viewportToNDC: ctx.viewportToNDC,
            commandBuffer: ctx.commandBuffer,
            scissor: inheritedState.currentScissor
        )
    }

    /// Fallback: renders inner commands directly to target without mask.
    /// Used when bbox is degenerate or texture allocation fails.
    private func renderInnerCommandsFallback(
        _ commands: [RenderCommand],
        ctx: MaskScopeContext,
        inheritedState: ExecutionState
    ) throws {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = ctx.target.texture
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store

        try drawInternal(
            commands: commands,
            renderPassDescriptor: descriptor,
            target: ctx.target,
            textureProvider: ctx.textureProvider,
            commandBuffer: ctx.commandBuffer,
            assetSizes: ctx.assetSizes,
            pathRegistry: ctx.pathRegistry,
            initialState: inheritedState
        )
    }
}
