// swiftlint:disable file_length
import Metal
import simd

// MARK: - Render Context

/// Groups rendering parameters to reduce function parameter count.
struct RenderContext {
    let encoder: MTLRenderCommandEncoder
    let target: RenderTarget
    let textureProvider: TextureProvider
    let animToViewport: Matrix2D
    let viewportToNDC: Matrix2D
    let commandBuffer: MTLCommandBuffer
    let assetSizes: [String: AssetSize]
    let pathRegistry: PathRegistry
}

/// Groups parameters for mask composite operations.
struct MaskCompositeContext {
    let target: RenderTarget
    let viewportToNDC: Matrix2D
    let commandBuffer: MTLCommandBuffer
    let scissor: MTLScissorRect?
}

/// Groups parameters for inner command rendering.
struct InnerRenderContext {
    let target: RenderTarget
    let textureProvider: TextureProvider
    let commandBuffer: MTLCommandBuffer
    let assetSizes: [String: AssetSize]
    let pathRegistry: PathRegistry
}

/// Groups parameters for mask scope rendering.
struct MaskScopeContext {
    let target: RenderTarget
    let textureProvider: TextureProvider
    let commandBuffer: MTLCommandBuffer
    let animToViewport: Matrix2D
    let viewportToNDC: Matrix2D
    let assetSizes: [String: AssetSize]
    let pathRegistry: PathRegistry
}

/// Groups parameters for matte scope rendering.
struct MatteScopeContext {
    let target: RenderTarget
    let textureProvider: TextureProvider
    let commandBuffer: MTLCommandBuffer
    let animToViewport: Matrix2D
    let viewportToNDC: Matrix2D
    let assetSizes: [String: AssetSize]
    let pathRegistry: PathRegistry
}

/// Type of scope encountered during command processing.
private enum ScopeType {
    case mask
    case matte
}

// MARK: - Execution State

/// Tracks state during command execution.
struct ExecutionState {
    var transformStack: [Matrix2D] = [.identity]
    var clipStack: [MTLScissorRect] = []
    var groupDepth: Int = 0
    var maskDepth: Int = 0
    var matteDepth: Int = 0

    var currentTransform: Matrix2D { transformStack.last ?? .identity }
    var currentScissor: MTLScissorRect? { clipStack.last }

    mutating func pushTransform(_ matrix: Matrix2D) {
        transformStack.append(currentTransform.concatenating(matrix))
    }

    mutating func popTransform() throws {
        guard transformStack.count > 1 else {
            throw MetalRendererError.invalidCommandStack(reason: "PopTransform below identity")
        }
        transformStack.removeLast()
    }

    mutating func pushClip(
        _ rect: RectD,
        targetSize: (width: Int, height: Int),
        animToViewport: Matrix2D
    ) {
        // Per review.md: scissor mapping uses only animToViewport
        // Transform 4 corners of rect through animToViewport
        let tl = animToViewport.apply(to: Vec2D(x: rect.x, y: rect.y))
        let tr = animToViewport.apply(to: Vec2D(x: rect.x + rect.width, y: rect.y))
        let bl = animToViewport.apply(to: Vec2D(x: rect.x, y: rect.y + rect.height))
        let br = animToViewport.apply(to: Vec2D(x: rect.x + rect.width, y: rect.y + rect.height))

        // Get AABB in pixel coords
        let minX = min(tl.x, tr.x, bl.x, br.x)
        let minY = min(tl.y, tr.y, bl.y, br.y)
        let maxX = max(tl.x, tr.x, bl.x, br.x)
        let maxY = max(tl.y, tr.y, bl.y, br.y)

        // Round: floor(min), ceil(max) per review.md
        let x = Int(floor(minX))
        let y = Int(floor(minY))
        let w = Int(ceil(maxX)) - x
        let h = Int(ceil(maxY)) - y

        // Clamp to texture bounds
        let clampedX = max(0, min(x, targetSize.width))
        let clampedY = max(0, min(y, targetSize.height))
        let clampedW = max(0, min(w, targetSize.width - clampedX))
        let clampedH = max(0, min(h, targetSize.height - clampedY))

        let newScissor = MTLScissorRect(x: clampedX, y: clampedY, width: clampedW, height: clampedH)
        let intersected = currentScissor.map {
            ScissorHelper.intersect($0, newScissor)
        } ?? newScissor
        clipStack.append(intersected)
    }

    mutating func popClip() throws {
        guard !clipStack.isEmpty else {
            throw MetalRendererError.invalidCommandStack(reason: "PopClipRect with empty stack")
        }
        clipStack.removeLast()
    }
}

// MARK: - Scissor Helper

private enum ScissorHelper {
    static func makeScissorRect(from rect: RectD, targetSize: (width: Int, height: Int)) -> MTLScissorRect {
        let clipX = max(0, min(Int(rect.x), targetSize.width))
        let clipY = max(0, min(Int(rect.y), targetSize.height))
        let clipW = max(0, min(Int(rect.width), targetSize.width - clipX))
        let clipH = max(0, min(Int(rect.height), targetSize.height - clipY))
        return MTLScissorRect(x: clipX, y: clipY, width: clipW, height: clipH)
    }

    static func intersect(_ rectA: MTLScissorRect, _ rectB: MTLScissorRect) -> MTLScissorRect {
        let minX = max(rectA.x, rectB.x)
        let minY = max(rectA.y, rectB.y)
        let maxX = min(rectA.x + rectA.width, rectB.x + rectB.width)
        let maxY = min(rectA.y + rectA.height, rectB.y + rectB.height)
        guard maxX > minX, maxY > minY else {
            return MTLScissorRect(x: 0, y: 0, width: 0, height: 0)
        }
        return MTLScissorRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

// MARK: - MetalRenderer Execute Extension

extension MetalRenderer {
    // swiftlint:disable:next function_body_length
    func drawInternal(
        commands: [RenderCommand],
        renderPassDescriptor: MTLRenderPassDescriptor,
        target: RenderTarget,
        textureProvider: TextureProvider,
        commandBuffer: MTLCommandBuffer,
        assetSizes: [String: AssetSize] = [:],
        pathRegistry: PathRegistry,
        initialState: ExecutionState? = nil,
        overrideAnimToViewport: Matrix2D? = nil
    ) throws {
        let baseline = initialState ?? makeInitialState(target: target)
        var state = baseline
        let targetRect = RectD(
            x: 0, y: 0,
            width: Double(target.sizePx.width),
            height: Double(target.sizePx.height)
        )
        let animToViewport = overrideAnimToViewport ?? GeometryMapping.animToInputContain(animSize: target.animSize, inputRect: targetRect)
        let viewportToNDC = GeometryMapping.viewportToNDC(width: targetRect.width, height: targetRect.height)

        // Process commands in segments separated by mask/matte scopes
        var index = 0
        var isFirstPass = true

        #if DEBUG
        perf?.beginPhase(.executeCommandsTotal)
        #endif

        while index < commands.count {
            // Find next mask or matte scope or end of commands
            let segmentStart = index
            var segmentEnd = commands.count
            var foundScopeType: ScopeType?

            for idx in segmentStart..<commands.count {
                switch commands[idx] {
                case .beginMask:
                    segmentEnd = idx
                    foundScopeType = .mask
                case .beginMatte:
                    segmentEnd = idx
                    foundScopeType = .matte
                default:
                    continue
                }
                break
            }

            // Render segment if non-empty
            // **PR Hot Path:** Pass range instead of copying commands
            if segmentStart < segmentEnd {
                try renderSegment(
                    commands,
                    in: segmentStart..<segmentEnd,
                    target: target,
                    textureProvider: textureProvider,
                    commandBuffer: commandBuffer,
                    animToViewport: animToViewport,
                    viewportToNDC: viewportToNDC,
                    assetSizes: assetSizes,
                    pathRegistry: pathRegistry,
                    state: &state,
                    renderPassDescriptor: isFirstPass ? renderPassDescriptor : nil
                )
                isFirstPass = false
            }

            index = segmentEnd

            // Process scope if found
            switch foundScopeType {
            case .mask:
                #if DEBUG
                perf?.beginPhase(.executeMasksTotal)
                perf?.recordMask()
                #endif

                // PR-C2: GPU mask path with boolean operations
                if let scope = extractMaskGroupScope(from: commands, startIndex: index) {
                    let scopeCtx = MaskScopeContext(
                        target: target,
                        textureProvider: textureProvider,
                        commandBuffer: commandBuffer,
                        animToViewport: animToViewport,
                        viewportToNDC: viewportToNDC,
                        assetSizes: assetSizes,
                        pathRegistry: pathRegistry
                    )
                    // **PR Hot Path:** Pass commands array + scope with range
                    try renderMaskGroupScope(commands: commands, scope: scope, ctx: scopeCtx, inheritedState: state)
                    index = scope.endIndex // endIndex already points to next command after last endMask
                } else {
                    // M1-fallback: malformed scope - skip to matching endMask and render inner without mask
                    // This is safer than crashing the entire render
                    // **PR Hot Path:** skipMalformedMaskScope returns range, not array
                    let (innerRange, endIdx) = skipMalformedMaskScope(from: commands, startIndex: index)
                    if !innerRange.isEmpty {
                        try renderSegment(
                            commands,
                            in: innerRange,
                            target: target,
                            textureProvider: textureProvider,
                            commandBuffer: commandBuffer,
                            animToViewport: animToViewport,
                            viewportToNDC: viewportToNDC,
                            assetSizes: assetSizes,
                            pathRegistry: pathRegistry,
                            state: &state,
                            renderPassDescriptor: nil
                        )
                    }
                    index = endIdx
                }

                #if DEBUG
                perf?.endPhase(.executeMasksTotal)
                #endif
                isFirstPass = false

            case .matte:
                #if DEBUG
                perf?.beginPhase(.executeMattesTotal)
                perf?.recordMatte()
                #endif

                let matteScope = try extractMatteScope(from: commands, startIndex: index)
                let matteScopeCtx = MatteScopeContext(
                    target: target,
                    textureProvider: textureProvider,
                    commandBuffer: commandBuffer,
                    animToViewport: animToViewport,
                    viewportToNDC: viewportToNDC,
                    assetSizes: assetSizes,
                    pathRegistry: pathRegistry
                )
                // **PR Hot Path:** Pass commands array + scope with ranges
                try renderMatteScope(commands: commands, scope: matteScope, ctx: matteScopeCtx, inheritedState: state)
                index = matteScope.endIndex + 1

                #if DEBUG
                perf?.endPhase(.executeMattesTotal)
                #endif
                isFirstPass = false

            case .none:
                break
            }
        }

        #if DEBUG
        perf?.endPhase(.executeCommandsTotal)
        #endif

        try validateBalancedStacks(state, baseline: baseline)
    }

    /// **PR Hot Path:** Overload that renders commands within a specified range.
    /// Delegates to main drawInternal by iterating over range instead of full array.
    // swiftlint:disable:next function_body_length
    func drawInternal(
        commands: [RenderCommand],
        in range: Range<Int>,
        renderPassDescriptor: MTLRenderPassDescriptor,
        target: RenderTarget,
        textureProvider: TextureProvider,
        commandBuffer: MTLCommandBuffer,
        assetSizes: [String: AssetSize] = [:],
        pathRegistry: PathRegistry,
        initialState: ExecutionState? = nil,
        overrideAnimToViewport: Matrix2D? = nil
    ) throws {
        guard !range.isEmpty else { return }

        let baseline = initialState ?? makeInitialState(target: target)
        var state = baseline
        let targetRect = RectD(
            x: 0, y: 0,
            width: Double(target.sizePx.width),
            height: Double(target.sizePx.height)
        )
        let animToViewport = overrideAnimToViewport ?? GeometryMapping.animToInputContain(animSize: target.animSize, inputRect: targetRect)
        let viewportToNDC = GeometryMapping.viewportToNDC(width: targetRect.width, height: targetRect.height)

        // Process commands in segments separated by mask/matte scopes
        var index = range.lowerBound
        var isFirstPass = true

        #if DEBUG
        perf?.beginPhase(.executeCommandsTotal)
        #endif

        while index < range.upperBound {
            // Find next mask or matte scope or end of range
            let segmentStart = index
            var segmentEnd = range.upperBound
            var foundScopeType: ScopeType?

            for idx in segmentStart..<range.upperBound {
                switch commands[idx] {
                case .beginMask:
                    segmentEnd = idx
                    foundScopeType = .mask
                case .beginMatte:
                    segmentEnd = idx
                    foundScopeType = .matte
                default:
                    continue
                }
                break
            }

            // Render segment if non-empty
            if segmentStart < segmentEnd {
                try renderSegment(
                    commands,
                    in: segmentStart..<segmentEnd,
                    target: target,
                    textureProvider: textureProvider,
                    commandBuffer: commandBuffer,
                    animToViewport: animToViewport,
                    viewportToNDC: viewportToNDC,
                    assetSizes: assetSizes,
                    pathRegistry: pathRegistry,
                    state: &state,
                    renderPassDescriptor: isFirstPass ? renderPassDescriptor : nil
                )
                isFirstPass = false
            }

            index = segmentEnd

            // Process scope if found
            switch foundScopeType {
            case .mask:
                #if DEBUG
                perf?.beginPhase(.executeMasksTotal)
                perf?.recordMask()
                #endif

                if let scope = extractMaskGroupScope(from: commands, startIndex: index) {
                    let scopeCtx = MaskScopeContext(
                        target: target,
                        textureProvider: textureProvider,
                        commandBuffer: commandBuffer,
                        animToViewport: animToViewport,
                        viewportToNDC: viewportToNDC,
                        assetSizes: assetSizes,
                        pathRegistry: pathRegistry
                    )
                    try renderMaskGroupScope(commands: commands, scope: scope, ctx: scopeCtx, inheritedState: state)
                    index = scope.endIndex
                } else {
                    let (innerRange, endIdx) = skipMalformedMaskScope(from: commands, startIndex: index)
                    if !innerRange.isEmpty {
                        try renderSegment(
                            commands,
                            in: innerRange,
                            target: target,
                            textureProvider: textureProvider,
                            commandBuffer: commandBuffer,
                            animToViewport: animToViewport,
                            viewportToNDC: viewportToNDC,
                            assetSizes: assetSizes,
                            pathRegistry: pathRegistry,
                            state: &state,
                            renderPassDescriptor: nil
                        )
                    }
                    index = endIdx
                }

                #if DEBUG
                perf?.endPhase(.executeMasksTotal)
                #endif
                isFirstPass = false

            case .matte:
                #if DEBUG
                perf?.beginPhase(.executeMattesTotal)
                perf?.recordMatte()
                #endif

                let matteScope = try extractMatteScope(from: commands, startIndex: index)
                let matteScopeCtx = MatteScopeContext(
                    target: target,
                    textureProvider: textureProvider,
                    commandBuffer: commandBuffer,
                    animToViewport: animToViewport,
                    viewportToNDC: viewportToNDC,
                    assetSizes: assetSizes,
                    pathRegistry: pathRegistry
                )
                try renderMatteScope(commands: commands, scope: matteScope, ctx: matteScopeCtx, inheritedState: state)
                index = matteScope.endIndex + 1

                #if DEBUG
                perf?.endPhase(.executeMattesTotal)
                #endif
                isFirstPass = false

            case .none:
                break
            }
        }

        #if DEBUG
        perf?.endPhase(.executeCommandsTotal)
        #endif

        try validateBalancedStacks(state, baseline: baseline)
    }

    /// Renders a segment of commands using range-based iteration (no array allocation).
    /// **PR Hot Path:** Iterates over range instead of copying commands to new array.
    // swiftlint:disable:next function_parameter_count
    private func renderSegment(
        _ commands: [RenderCommand],
        in range: Range<Int>,
        target: RenderTarget,
        textureProvider: TextureProvider,
        commandBuffer: MTLCommandBuffer,
        animToViewport: Matrix2D,
        viewportToNDC: Matrix2D,
        assetSizes: [String: AssetSize],
        pathRegistry: PathRegistry,
        state: inout ExecutionState,
        renderPassDescriptor: MTLRenderPassDescriptor?
    ) throws {
        guard !range.isEmpty else { return }

        let descriptor: MTLRenderPassDescriptor
        if let provided = renderPassDescriptor {
            descriptor = provided
        } else {
            descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = target.texture
            descriptor.colorAttachments[0].loadAction = .load
            descriptor.colorAttachments[0].storeAction = .store
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw MetalRendererError.failedToCreateCommandBuffer
        }
        defer { encoder.endEncoding() }

        let ctx = RenderContext(
            encoder: encoder,
            target: target,
            textureProvider: textureProvider,
            animToViewport: animToViewport,
            viewportToNDC: viewportToNDC,
            commandBuffer: commandBuffer,
            assetSizes: assetSizes,
            pathRegistry: pathRegistry
        )

        // Use current scissor (respects inherited clip state) or fallback to base scissor
        let initialScissor = state.currentScissor ?? state.clipStack[0]
        encoder.setScissorRect(initialScissor)
        encoder.setRenderPipelineState(resources.pipelineState)
        encoder.setFragmentSamplerState(resources.samplerState, index: 0)

        for i in range {
            try executeCommand(commands[i], ctx: ctx, state: &state)
        }
    }

    // NOTE: Legacy CPU mask rendering path has been removed.
    // GPU masks only (PR-C2+). See renderMaskGroupScope for current implementation.

    /// Samples a path at the given frame using PathResource keyframes.
    /// Returns interpolated BezierPath for CPU rasterization fallback.
    private func samplePath(resource: PathResource, frame: Double) -> BezierPath? {
        guard resource.vertexCount > 0 else { return nil }

        // For static path, return first keyframe
        guard resource.isAnimated else {
            return pathResourceToBezierPath(positions: resource.keyframePositions[0], vertexCount: resource.vertexCount)
        }

        // Find keyframe segment
        let times = resource.keyframeTimes
        guard !times.isEmpty else { return nil }

        // Before first keyframe
        if frame <= times[0] {
            return pathResourceToBezierPath(positions: resource.keyframePositions[0], vertexCount: resource.vertexCount)
        }

        // After last keyframe
        if frame >= times[times.count - 1] {
            return pathResourceToBezierPath(positions: resource.keyframePositions[times.count - 1], vertexCount: resource.vertexCount)
        }

        // Find segment
        for idx in 0..<(times.count - 1) {
            if frame >= times[idx] && frame < times[idx + 1] {
                let t0 = times[idx]
                let t1 = times[idx + 1]
                var linearT = (frame - t0) / (t1 - t0)

                // Apply easing if available
                if idx < resource.keyframeEasing.count, let easing = resource.keyframeEasing[idx] {
                    if easing.hold {
                        linearT = 0 // Hold at start value
                    } else {
                        linearT = CubicBezierEasing.solve(
                            x: linearT,
                            x1: easing.outX,
                            y1: easing.outY,
                            x2: easing.inX,
                            y2: easing.inY
                        )
                    }
                }

                // Interpolate positions
                let pos0 = resource.keyframePositions[idx]
                let pos1 = resource.keyframePositions[idx + 1]
                var interpolated = [Float](repeating: 0, count: pos0.count)
                for pIdx in 0..<pos0.count {
                    interpolated[pIdx] = pos0[pIdx] + Float(linearT) * (pos1[pIdx] - pos0[pIdx])
                }

                return pathResourceToBezierPath(positions: interpolated, vertexCount: resource.vertexCount)
            }
        }

        return nil
    }

    /// Cached wrapper around `samplePath(resource:frame:)`.
    ///
    /// Uses `PathSamplingCache` (two-level: FrameMemo + LRU) to eliminate redundant
    /// sampling when fill + stroke reference the same pathId at the same frame.
    ///
    /// PR-14C: Returns `PathSampleResult` so MetalRenderer can record metrics externally.
    ///
    /// - Parameters:
    ///   - resource: Path resource to sample
    ///   - frame: Animation frame
    ///   - generationId: PathRegistry generation for cache key isolation
    /// - Returns: Sampled `BezierPath`, or `nil` if path is empty/degenerate
    private func samplePathCached(
        resource: PathResource,
        frame: Double,
        generationId: Int
    ) -> BezierPath? {
        #if DEBUG
        perf?.beginPhase(.pathSamplingTotal)
        #endif

        let result = pathSamplingCache.sample(
            generationId: generationId,
            pathId: resource.pathId,
            frame: frame,
            producer: { samplePath(resource: resource, frame: frame) }
        )

        #if DEBUG
        perf?.endPhase(.pathSamplingTotal)

        // Record outcome for PerfMetrics
        if let perf = perf {
            let key = PathSampleKey(
                generationId: generationId,
                pathId: resource.pathId,
                quantizedFrame: Quantization.quantizedInt(frame, step: AnimConstants.frameQuantStep)
            )
            switch result {
            case .hitFrameMemo:
                perf.recordPathSampling(outcome: .hitFrameMemo, key: key)
            case .hitLRU:
                perf.recordPathSampling(outcome: .hitLRU, key: key)
            case .miss:
                perf.recordPathSampling(outcome: .miss, key: key)
            case .missNil:
                perf.recordPathSampling(outcome: .missNil, key: key)
            }
        }
        #endif

        // Extract the BezierPath (or nil) from the result enum
        switch result {
        case .hitFrameMemo(let path): return path
        case .hitLRU(let path): return path
        case .miss(let path): return path
        case .missNil: return nil
        }
    }

    /// Converts flattened positions from PathResource to BezierPath (for CPU fallback).
    private func pathResourceToBezierPath(positions: [Float], vertexCount: Int) -> BezierPath? {
        guard positions.count >= vertexCount * 2 else { return nil }

        var vertices: [Vec2D] = []
        for idx in 0..<vertexCount {
            let x = Double(positions[idx * 2])
            let y = Double(positions[idx * 2 + 1])
            vertices.append(Vec2D(x: x, y: y))
        }

        // PathResource stores flattened polylines, so tangents are zero
        let zeroTangents = [Vec2D](repeating: Vec2D(x: 0, y: 0), count: vertexCount)

        return BezierPath(
            vertices: vertices,
            inTangents: zeroTangents,
            outTangents: zeroTangents,
            closed: true // Assume closed for masks
        )
    }

    // NOTE: renderInnerCommandsToTarget and renderInnerCommandsToTexture removed.
    // Legacy CPU mask path no longer used - GPU masks only (PR-C2+).

    private func compositeTextureToTarget(
        _ texture: MTLTexture,
        target: RenderTarget,
        viewportToNDC: Matrix2D,
        commandBuffer: MTLCommandBuffer,
        scissor: MTLScissorRect?
    ) throws {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target.texture
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        defer { encoder.endEncoding() }

        if let scissor = scissor {
            encoder.setScissorRect(scissor)
        }

        guard let vertexBuffer = resources.makeQuadVertexBuffer(
            device: device,
            width: Float(texture.width),
            height: Float(texture.height)
        ) else { return }

        let mvp = viewportToNDC.toFloat4x4()
        var uniforms = QuadUniforms(mvp: mvp, opacity: 1.0)

        // DEBUG: Validate uniforms struct matches Metal shader (96 bytes)
        #if DEBUG
        precondition(MemoryLayout<QuadUniforms>.stride == 96,
                     "QuadUniforms stride mismatch: \(MemoryLayout<QuadUniforms>.stride) != 96")
        #endif

        encoder.setRenderPipelineState(resources.pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 1)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(resources.samplerState, index: 0)
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: resources.quadIndexCount,
            indexType: .uint16,
            indexBuffer: resources.quadIndexBuffer,
            indexBufferOffset: 0
        )
    }

    private func compositeWithStencilMask(
        contentTex: MTLTexture,
        maskTex: MTLTexture,
        ctx: MaskCompositeContext
    ) throws {
        let targetSize = ctx.target.sizePx

        // Create stencil texture
        guard let stencilTex = texturePool.acquireStencilTexture(size: targetSize) else {
            return
        }
        defer { texturePool.release(stencilTex) }

        // Pass 1: Write mask to stencil buffer
        try writeMaskToStencilBuffer(
            maskTex: maskTex,
            stencilTex: stencilTex,
            viewportToNDC: ctx.viewportToNDC,
            commandBuffer: ctx.commandBuffer,
            scissor: ctx.scissor
        )

        // Pass 2: Composite content with stencil test
        try compositeContentWithStencil(
            contentTex: contentTex,
            stencilTex: stencilTex,
            ctx: ctx
        )
    }

    private func writeMaskToStencilBuffer(
        maskTex: MTLTexture,
        stencilTex: MTLTexture,
        viewportToNDC: Matrix2D,
        commandBuffer: MTLCommandBuffer,
        scissor: MTLScissorRect?
    ) throws {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.depthAttachment.texture = stencilTex
        descriptor.depthAttachment.loadAction = .clear
        descriptor.depthAttachment.storeAction = .store
        descriptor.depthAttachment.clearDepth = 1.0
        descriptor.stencilAttachment.texture = stencilTex
        descriptor.stencilAttachment.loadAction = .clear
        descriptor.stencilAttachment.storeAction = .store
        descriptor.stencilAttachment.clearStencil = 0

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        defer { encoder.endEncoding() }

        if let scissor = scissor {
            encoder.setScissorRect(scissor)
        }

        guard let vertexBuffer = resources.makeQuadVertexBuffer(
            device: device,
            width: Float(maskTex.width),
            height: Float(maskTex.height)
        ) else { return }

        let mvp = viewportToNDC.toFloat4x4()
        var uniforms = QuadUniforms(mvp: mvp, opacity: 1.0)

        encoder.setRenderPipelineState(resources.maskWritePipelineState)
        encoder.setDepthStencilState(resources.stencilWriteDepthStencilState)
        encoder.setStencilReferenceValue(0xFF)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 1)
        encoder.setFragmentTexture(maskTex, index: 0)
        encoder.setFragmentSamplerState(resources.samplerState, index: 0)
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: resources.quadIndexCount,
            indexType: .uint16,
            indexBuffer: resources.quadIndexBuffer,
            indexBufferOffset: 0
        )
    }

    private func compositeContentWithStencil(
        contentTex: MTLTexture,
        stencilTex: MTLTexture,
        ctx: MaskCompositeContext
    ) throws {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = ctx.target.texture
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.depthAttachment.texture = stencilTex
        descriptor.depthAttachment.loadAction = .load
        descriptor.depthAttachment.storeAction = .dontCare
        descriptor.stencilAttachment.texture = stencilTex
        descriptor.stencilAttachment.loadAction = .load
        descriptor.stencilAttachment.storeAction = .dontCare

        guard let encoder = ctx.commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        defer { encoder.endEncoding() }

        if let scissor = ctx.scissor {
            encoder.setScissorRect(scissor)
        }

        guard let vertexBuffer = resources.makeQuadVertexBuffer(
            device: device,
            width: Float(contentTex.width),
            height: Float(contentTex.height)
        ) else { return }

        let mvp = ctx.viewportToNDC.toFloat4x4()
        var uniforms = QuadUniforms(mvp: mvp, opacity: 1.0)

        encoder.setRenderPipelineState(resources.stencilCompositePipelineState)
        encoder.setDepthStencilState(resources.stencilTestDepthStencilState)
        encoder.setStencilReferenceValue(0xFF)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 1)
        encoder.setFragmentTexture(contentTex, index: 0)
        encoder.setFragmentSamplerState(resources.samplerState, index: 0)
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: resources.quadIndexCount,
            indexType: .uint16,
            indexBuffer: resources.quadIndexBuffer,
            indexBufferOffset: 0
        )
    }

    // MARK: - Matte Scope Rendering

    /// **PR Hot Path:** Takes full commands array + scope with ranges (no array copy).
    private func renderMatteScope(
        commands: [RenderCommand],
        scope: MatteScope,
        ctx: MatteScopeContext,
        inheritedState: ExecutionState
    ) throws {
        let targetSize = ctx.target.sizePx
        let currentScissor = inheritedState.currentScissor

        // Step 1: Render matte source commands to matteTex
        guard let matteTex = texturePool.acquireColorTexture(size: targetSize) else {
            return
        }
        defer { texturePool.release(matteTex) }

        try renderCommandsToTexture(
            commands,
            in: scope.sourceRange,
            texture: matteTex,
            target: ctx.target,
            textureProvider: ctx.textureProvider,
            commandBuffer: ctx.commandBuffer,
            pathRegistry: ctx.pathRegistry,
            inheritedState: inheritedState,
            scissor: currentScissor
        )

        // Step 2: Render matte consumer commands to consumerTex
        guard let consumerTex = texturePool.acquireColorTexture(size: targetSize) else {
            return
        }
        defer { texturePool.release(consumerTex) }

        try renderCommandsToTexture(
            commands,
            in: scope.consumerRange,
            texture: consumerTex,
            target: ctx.target,
            textureProvider: ctx.textureProvider,
            commandBuffer: ctx.commandBuffer,
            pathRegistry: ctx.pathRegistry,
            inheritedState: inheritedState,
            scissor: currentScissor
        )

        // Step 3: Composite consumerTex to target with matteTex as matte
        try compositeWithMatte(
            consumerTex: consumerTex,
            matteTex: matteTex,
            mode: scope.mode,
            target: ctx.target,
            viewportToNDC: ctx.viewportToNDC,
            commandBuffer: ctx.commandBuffer,
            scissor: currentScissor
        )
    }

    /// **PR Hot Path:** Takes full commands array + range (no array copy).
    // swiftlint:disable:next function_parameter_count
    private func renderCommandsToTexture(
        _ commands: [RenderCommand],
        in range: Range<Int>,
        texture: MTLTexture,
        target: RenderTarget,
        textureProvider: TextureProvider,
        commandBuffer: MTLCommandBuffer,
        pathRegistry: PathRegistry,
        inheritedState: ExecutionState,
        scissor: MTLScissorRect?
    ) throws {
        // Assumes offscreen textures are same size as target; otherwise scissor must be remapped.
        var stateWithScissor = inheritedState
        if let scissor = scissor {
            stateWithScissor.clipStack.append(scissor)  // PUSH, not replace
        }

        let offscreenTarget = RenderTarget(
            texture: texture,
            drawableScale: target.drawableScale,
            animSize: target.animSize
        )

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        try drawInternal(
            commands: commands,
            in: range,
            renderPassDescriptor: descriptor,
            target: offscreenTarget,
            textureProvider: textureProvider,
            commandBuffer: commandBuffer,
            pathRegistry: pathRegistry,
            initialState: stateWithScissor
        )
    }

    // swiftlint:disable:next function_parameter_count
    private func compositeWithMatte(
        consumerTex: MTLTexture,
        matteTex: MTLTexture,
        mode: RenderMatteMode,
        target: RenderTarget,
        viewportToNDC: Matrix2D,
        commandBuffer: MTLCommandBuffer,
        scissor: MTLScissorRect?
    ) throws {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target.texture
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        defer { encoder.endEncoding() }

        if let scissor = scissor {
            encoder.setScissorRect(scissor)
        }

        guard let vertexBuffer = resources.makeQuadVertexBuffer(
            device: device,
            width: Float(consumerTex.width),
            height: Float(consumerTex.height)
        ) else { return }

        let mvp = viewportToNDC.toFloat4x4()
        var uniforms = MatteCompositeUniforms(mvp: mvp, mode: mode.shaderModeValue)

        encoder.setRenderPipelineState(resources.matteCompositePipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MatteCompositeUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MatteCompositeUniforms>.stride, index: 1)
        encoder.setFragmentTexture(consumerTex, index: 0)
        encoder.setFragmentTexture(matteTex, index: 1)
        encoder.setFragmentSamplerState(resources.samplerState, index: 0)
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: resources.quadIndexCount,
            indexType: .uint16,
            indexBuffer: resources.quadIndexBuffer,
            indexBufferOffset: 0
        )
    }

    private func makeInitialState(target: RenderTarget) -> ExecutionState {
        var state = ExecutionState()
        state.clipStack.append(MTLScissorRect(x: 0, y: 0, width: target.sizePx.width, height: target.sizePx.height))
        return state
    }

    private func validateBalancedStacks(_ state: ExecutionState, baseline: ExecutionState) throws {
        if state.groupDepth != baseline.groupDepth {
            throw MetalRendererError.invalidCommandStack(
                reason: "Unbalanced groups: expected \(baseline.groupDepth), got \(state.groupDepth)"
            )
        }
        if state.transformStack.count != baseline.transformStack.count {
            let exp = baseline.transformStack.count
            let got = state.transformStack.count
            throw MetalRendererError.invalidCommandStack(
                reason: "Unbalanced transforms: expected \(exp), got \(got)"
            )
        }
        if state.clipStack.count != baseline.clipStack.count {
            throw MetalRendererError.invalidCommandStack(
                reason: "Unbalanced clips: expected \(baseline.clipStack.count), got \(state.clipStack.count)"
            )
        }
        if state.maskDepth != baseline.maskDepth {
            throw MetalRendererError.invalidCommandStack(
                reason: "Unbalanced masks: expected \(baseline.maskDepth), got \(state.maskDepth)"
            )
        }
        if state.matteDepth != baseline.matteDepth {
            throw MetalRendererError.invalidCommandStack(
                reason: "Unbalanced mattes: expected \(baseline.matteDepth), got \(state.matteDepth)"
            )
        }
    }
}

// MARK: - Mask Scope Extraction

/// Result of extracting a mask scope from command list.
/// **PR Hot Path:** Uses `Range<Int>` instead of `[RenderCommand]` to avoid allocations.
struct MaskScope {
    let startIndex: Int
    let endIndex: Int
    let innerRange: Range<Int>
    let pathId: PathID
    let opacity: Double
    let frame: Double
}

// MARK: - Matte Scope Extraction

/// Result of extracting a matte scope from command list.
/// **PR Hot Path:** Uses `Range<Int>` instead of `[RenderCommand]` to avoid allocations.
struct MatteScope {
    let startIndex: Int
    let endIndex: Int
    let mode: RenderMatteMode
    let sourceRange: Range<Int>
    let consumerRange: Range<Int>
}

extension MetalRenderer {
    /// Extracts a mask scope starting at the given index.
    /// Handles nested masks by counting begin/end pairs.
    /// **PR Hot Path:** Returns range instead of copying commands.
    func extractMaskScope(from commands: [RenderCommand], startIndex: Int) -> MaskScope? {
        guard startIndex < commands.count else { return nil }

        let pathId: PathID
        let opacity: Double
        let frame: Double

        switch commands[startIndex] {
        case .beginMask(_, _, let pid, let op, let fr):
            pathId = pid; opacity = op; frame = fr
        default:
            return nil
        }

        var depth = 1
        var index = startIndex + 1

        while index < commands.count && depth > 0 {
            switch commands[index] {
            case .beginMask:
                depth += 1
            case .endMask:
                depth -= 1
            default:
                break
            }
            if depth > 0 {
                index += 1
            }
        }

        guard depth == 0, index < commands.count else {
            return nil
        }

        let innerRange = (startIndex + 1)..<index

        return MaskScope(
            startIndex: startIndex,
            endIndex: index,
            innerRange: innerRange,
            pathId: pathId,
            opacity: opacity,
            frame: frame
        )
    }

    /// Extracts a complete mask group scope from the command stream.
    ///
    /// Handles LIFO-nested mask structure where masks are emitted in reverse order:
    /// ```
    /// beginMask(M2) → beginMask(M1) → beginMask(M0) → [inner] → endMask → endMask → endMask
    /// ```
    ///
    /// Also supports nested mask scopes inside inner content (e.g. container mask
    /// wrapping a binding layer that has its own inputClip mask):
    /// ```
    /// beginMask(container) → [… beginMask(inputClip) … endMask …] → endMask
    /// ```
    /// Nested scopes are included verbatim in `innerCommands` and handled
    /// recursively by `drawInternal`.
    ///
    /// Returns masks in AE application order (M0, M1, M2) for correct accumulation.
    /// The `endIndex` points to the next command after the last `endMask`.
    ///
    /// - Parameters:
    ///   - commands: Full command stream
    ///   - startIndex: Index of first beginMask command
    /// - Returns: Extracted scope with ops in AE order, or nil if invalid structure
    func extractMaskGroupScope(from commands: [RenderCommand], startIndex: Int) -> MaskGroupScope? {
        guard startIndex < commands.count else { return nil }

        var ops: [MaskOp] = []
        var index = startIndex

        // Phase 1: Collect consecutive beginMask commands (outer chain)
        while index < commands.count {
            switch commands[index] {
            case .beginMask(let mode, let inverted, let pathId, let opacity, let frame):
                ops.append(MaskOp(mode: mode, inverted: inverted, pathId: pathId, opacity: opacity, frame: frame))
                index += 1
            default:
                break
            }

            // Check if next command is also a beginMask
            if index < commands.count {
                switch commands[index] {
                case .beginMask:
                    continue
                default:
                    break
                }
            }
            break
        }

        guard !ops.isEmpty else { return nil }

        let baseDepth = ops.count
        let innerStart = index
        var depth = baseDepth
        var innerEnd: Int?

        // Phase 2: Walk until all outer scopes are closed.
        // Nested beginMask/endMask pairs inside inner content are tracked via depth
        // and included in innerCommands — they will be handled recursively by drawInternal.
        while index < commands.count && depth > 0 {
            switch commands[index] {
            case .beginMask:
                depth += 1

            case .endMask:
                // Before decrement: if depth == baseDepth, all nested scopes are closed
                // and this endMask starts closing the outer chain.
                if innerEnd == nil && depth == baseDepth {
                    innerEnd = index
                }
                depth -= 1

            default:
                break
            }
            index += 1
        }

        // Verify balanced structure
        guard depth == 0, let innerEndIdx = innerEnd else {
            #if DEBUG
            print("[TVECore] ⚠️ Unbalanced mask commands: depth=\(depth) at end of stream")
            #endif
            return nil
        }

        // Inner range: everything between outer chain and first outer endMask.
        // For nested scopes, this includes the complete nested beginMask…endMask pair.
        // **PR Hot Path:** Use range instead of copying commands.
        let innerRange = innerStart..<innerEndIdx

        // Reverse ops to get AE application order (emission was reversed)
        let opsInAeOrder = Array(ops.reversed())

        return MaskGroupScope(
            opsInAeOrder: opsInAeOrder,
            innerRange: innerRange,
            endIndex: index
        )
    }

    /// Skips a malformed mask scope and extracts inner command range for fallback rendering.
    ///
    /// Used when `extractMaskGroupScope` returns nil (malformed structure).
    /// Finds all commands between beginMask chain and matching endMask(s),
    /// returning range for rendering without mask.
    ///
    /// **Contract:**
    /// - Nested beginMask inside inner content is NOT supported in normal path,
    ///   but here we simply count depth and render inner WITHOUT mask up to first endMask.
    /// - Goal: **do not crash render**, not guarantee visual equivalence.
    /// - This is best-effort fallback for malformed command streams.
    ///
    /// **PR Hot Path:** Returns range instead of copying commands.
    ///
    /// - Parameters:
    ///   - commands: Full command stream
    ///   - startIndex: Index of first beginMask command
    /// - Returns: Tuple of (innerRange to render, endIndex after scope)
    func skipMalformedMaskScope(from commands: [RenderCommand], startIndex: Int) -> (Range<Int>, Int) {
        guard startIndex < commands.count else {
            return (0..<0, commands.count)
        }

        var index = startIndex
        var depth = 0

        // Count initial beginMask commands
        while index < commands.count {
            switch commands[index] {
            case .beginMask:
                depth += 1
                index += 1
            default:
                break
            }
            if index < commands.count {
                switch commands[index] {
                case .beginMask:
                    continue
                default:
                    break
                }
            }
            break
        }

        guard depth > 0 else {
            return (0..<0, startIndex)
        }

        let innerStart = index

        // Find first endMask (inner content ends there)
        var firstEndMaskIndex: Int?
        while index < commands.count && depth > 0 {
            switch commands[index] {
            case .beginMask:
                // Nested mask - just count it
                depth += 1
            case .endMask:
                if firstEndMaskIndex == nil {
                    firstEndMaskIndex = index
                }
                depth -= 1
            default:
                break
            }
            index += 1
        }

        let innerEnd = firstEndMaskIndex ?? index
        // **PR Hot Path:** Return range instead of copying commands.
        let innerRange = innerStart..<innerEnd

        return (innerRange, index)
    }

    /// Extracts a matte scope starting at the given index.
    /// Expects exactly two child groups: "matteSource" and "matteConsumer".
    /// **PR Hot Path:** Returns ranges instead of copying commands.
    func extractMatteScope(from commands: [RenderCommand], startIndex: Int) throws -> MatteScope {
        guard startIndex < commands.count,
              case .beginMatte(let mode) = commands[startIndex] else {
            throw MetalRendererError.invalidCommandStack(reason: "Expected beginMatte at index \(startIndex)")
        }

        // Find matching endMatte
        var matteDepth = 1
        var endMatteIndex = startIndex + 1
        while endMatteIndex < commands.count && matteDepth > 0 {
            switch commands[endMatteIndex] {
            case .beginMatte:
                matteDepth += 1
            case .endMatte:
                matteDepth -= 1
            default:
                break
            }
            if matteDepth > 0 {
                endMatteIndex += 1
            }
        }

        guard matteDepth == 0, endMatteIndex < commands.count else {
            let msg = "Missing EndMatte for BeginMatte at index \(startIndex)"
            throw MetalRendererError.invalidCommandStack(reason: msg)
        }

        // Inner range (between beginMatte and endMatte)
        let innerRange = (startIndex + 1)..<endMatteIndex

        // Parse the two groups: matteSource and matteConsumer
        // **PR Hot Path:** parseMatteGroups now returns ranges
        let (sourceRange, consumerRange) = try parseMatteGroups(commands, innerRange: innerRange)

        return MatteScope(
            startIndex: startIndex,
            endIndex: endMatteIndex,
            mode: mode,
            sourceRange: sourceRange,
            consumerRange: consumerRange
        )
    }

    /// Parses matte scope inner commands to extract matteSource and matteConsumer group ranges.
    /// **PR Hot Path:** Returns ranges into original command array instead of copying.
    ///
    /// - Parameters:
    ///   - commands: Full command array
    ///   - innerRange: Range of commands between beginMatte and endMatte
    /// - Returns: Tuple of (sourceRange, consumerRange) as ranges into original commands array
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func parseMatteGroups(
        _ commands: [RenderCommand],
        innerRange: Range<Int>
    ) throws -> (source: Range<Int>, consumer: Range<Int>) {
        let baseIndex = innerRange.lowerBound

        // Find first group (matteSource)
        guard !innerRange.isEmpty,
              case .beginGroup(let firstName) = commands[baseIndex],
              firstName == "matteSource" else {
            let msg = "Matte scope must start with beginGroup(\"matteSource\")"
            throw MetalRendererError.invalidCommandStack(reason: msg)
        }

        // Find end of matteSource group (index relative to baseIndex)
        var depth = 1
        var sourceEndOffset = 1
        while (baseIndex + sourceEndOffset) < innerRange.upperBound && depth > 0 {
            switch commands[baseIndex + sourceEndOffset] {
            case .beginGroup:
                depth += 1
            case .endGroup:
                depth -= 1
            default:
                break
            }
            if depth > 0 {
                sourceEndOffset += 1
            }
        }

        guard depth == 0 else {
            throw MetalRendererError.invalidCommandStack(reason: "Unbalanced matteSource group")
        }

        // sourceRange: commands inside matteSource group (excluding begin/end group)
        let sourceRange = (baseIndex + 1)..<(baseIndex + sourceEndOffset)

        // Find second group (matteConsumer)
        let consumerStartOffset = sourceEndOffset + 1
        guard (baseIndex + consumerStartOffset) < innerRange.upperBound,
              case .beginGroup(let secondName) = commands[baseIndex + consumerStartOffset],
              secondName == "matteConsumer" else {
            let msg = "Matte scope must have beginGroup(\"matteConsumer\") after matteSource"
            throw MetalRendererError.invalidCommandStack(reason: msg)
        }

        // Find end of matteConsumer group
        depth = 1
        var consumerEndOffset = consumerStartOffset + 1
        while (baseIndex + consumerEndOffset) < innerRange.upperBound && depth > 0 {
            switch commands[baseIndex + consumerEndOffset] {
            case .beginGroup:
                depth += 1
            case .endGroup:
                depth -= 1
            default:
                break
            }
            if depth > 0 {
                consumerEndOffset += 1
            }
        }

        guard depth == 0 else {
            throw MetalRendererError.invalidCommandStack(reason: "Unbalanced matteConsumer group")
        }

        // consumerRange: commands inside matteConsumer group (excluding begin/end group)
        let consumerRange = (baseIndex + consumerStartOffset + 1)..<(baseIndex + consumerEndOffset)

        // Verify nothing else after matteConsumer
        if (baseIndex + consumerEndOffset + 1) < innerRange.upperBound {
            let msg = "Unexpected commands after matteConsumer group in matte scope"
            throw MetalRendererError.invalidCommandStack(reason: msg)
        }

        return (sourceRange, consumerRange)
    }
}

// MARK: - Command Execution

extension MetalRenderer {
    // swiftlint:disable:next cyclomatic_complexity
    private func executeCommand(_ command: RenderCommand, ctx: RenderContext, state: inout ExecutionState) throws {
        #if DEBUG
        perf?.recordCommand(command)
        #endif

        switch command {
        case .beginGroup:
            state.groupDepth += 1
        case .endGroup:
            state.groupDepth -= 1
            guard state.groupDepth >= 0 else {
                throw MetalRendererError.invalidCommandStack(reason: "EndGroup without BeginGroup")
            }
        case .pushTransform(let matrix):
            state.pushTransform(matrix)
        case .popTransform:
            try state.popTransform()
        case .pushClipRect(let rect):
            state.pushClip(rect, targetSize: ctx.target.sizePx, animToViewport: ctx.animToViewport)
            if let scissor = state.currentScissor {
                ctx.encoder.setScissorRect(scissor)
            }
        case .popClipRect:
            try state.popClip()
            if let scissor = state.currentScissor { ctx.encoder.setScissorRect(scissor) }
        case .drawImage(let assetId, let opacity):
            try drawImage(
                assetId: assetId,
                opacity: opacity,
                ctx: ctx,
                transform: state.currentTransform,
                scissor: state.currentScissor
            )
        case .drawShape(let pathId, let fillColor, let fillOpacity, let layerOpacity, let frame):
            #if DEBUG
            perf?.beginPhase(.executeFillTotal)
            #endif
            try drawShape(
                pathId: pathId,
                fillColor: fillColor,
                fillOpacity: fillOpacity,
                layerOpacity: layerOpacity,
                frame: frame,
                ctx: ctx,
                transform: state.currentTransform
            )
            #if DEBUG
            perf?.endPhase(.executeFillTotal)
            #endif
        case .drawStroke(let pathId, let strokeColor, let strokeOpacity, let strokeWidth, let lineCap, let lineJoin, let miterLimit, let layerOpacity, let frame):
            #if DEBUG
            perf?.beginPhase(.executeStrokeTotal)
            #endif
            try drawStroke(
                pathId: pathId,
                strokeColor: strokeColor,
                strokeOpacity: strokeOpacity,
                strokeWidth: strokeWidth,
                lineCap: lineCap,
                lineJoin: lineJoin,
                miterLimit: miterLimit,
                layerOpacity: layerOpacity,
                frame: frame,
                ctx: ctx,
                transform: state.currentTransform
            )
            #if DEBUG
            perf?.endPhase(.executeStrokeTotal)
            #endif
        case .beginMask:
            // Mask commands increment depth.
            // Actual GPU mask rendering will be implemented in PR-C via extraction.
            state.maskDepth += 1
        case .endMask:
            state.maskDepth -= 1
            guard state.maskDepth >= 0 else {
                throw MetalRendererError.invalidCommandStack(reason: "EndMask without BeginMask")
            }
        case .beginMatte:
            state.matteDepth += 1
        case .endMatte:
            state.matteDepth -= 1
            guard state.matteDepth >= 0 else {
                throw MetalRendererError.invalidCommandStack(reason: "EndMatte without BeginMatte")
            }
        }
    }

    // swiftlint:disable:next function_parameter_count
    private func drawImage(
        assetId: String,
        opacity: Double,
        ctx: RenderContext,
        transform: Matrix2D,
        scissor: MTLScissorRect?
    ) throws {
        guard opacity > 0 else { return }
        guard let texture = ctx.textureProvider.texture(for: assetId) else {
            throw MetalRendererError.noTextureForAsset(assetId: assetId)
        }
        // Use asset size from metadata if available, otherwise fallback to texture size
        let quadWidth: Float
        let quadHeight: Float
        if let assetSize = ctx.assetSizes[assetId] {
            quadWidth = Float(assetSize.width)
            quadHeight = Float(assetSize.height)
        } else {
            quadWidth = Float(texture.width)
            quadHeight = Float(texture.height)
        }

        let fullTransform = ctx.animToViewport.concatenating(transform)

        guard let vertexBuffer = resources.makeQuadVertexBuffer(
            device: device,
            width: quadWidth,
            height: quadHeight
        ) else { return }

        let mvp = ctx.viewportToNDC.concatenating(fullTransform).toFloat4x4()
        var uniforms = QuadUniforms(mvp: mvp, opacity: Float(opacity))

        ctx.encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        ctx.encoder.setVertexBytes(&uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 1)
        ctx.encoder.setFragmentTexture(texture, index: 0)
        ctx.encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: resources.quadIndexCount,
            indexType: .uint16,
            indexBuffer: resources.quadIndexBuffer,
            indexBufferOffset: 0
        )
    }

    // swiftlint:disable:next function_parameter_count
    private func drawShape(
        pathId: PathID,
        fillColor: [Double]?,
        fillOpacity: Double,
        layerOpacity: Double,
        frame: Double,
        ctx: RenderContext,
        transform: Matrix2D
    ) throws {
        let effectiveOpacity = (fillOpacity / 100.0) * layerOpacity
        guard effectiveOpacity > 0 else { return }

        // Look up path in registry and sample at current frame (PR-14B: cached)
        guard let pathResource = ctx.pathRegistry.path(for: pathId) else {
            assertionFailure("Missing path resource for pathId: \(pathId)")
            throw MetalRendererError.missingPathResource(pathId: pathId)
        }
        guard let path = samplePathCached(resource: pathResource, frame: frame, generationId: ctx.pathRegistry.generationId) else { return }
        guard path.vertexCount > 2 else { return }

        let targetSize = ctx.target.sizePx

        // Compute transform from path to viewport
        let pathToViewport = ctx.animToViewport.concatenating(transform)

        #if DEBUG
        perf?.beginPhase(.shapeCacheTotal)
        #endif

        // Rasterize shape to BGRA texture using the shape cache (CPU fallback)
        let fillResult = shapeCache.texture(
            for: path,
            transform: pathToViewport,
            size: targetSize,
            fillColor: fillColor ?? [1, 1, 1],
            opacity: effectiveOpacity
        )

        #if DEBUG
        perf?.endPhase(.shapeCacheTotal)
        // Record fill cache outcome
        if fillResult.didHit {
            perf?.recordShapeFill(outcome: .hit)
        } else if fillResult.didEvict {
            perf?.recordShapeFill(outcome: .missEvicted)
        } else {
            perf?.recordShapeFill(outcome: .miss)
        }
        #endif

        guard let shapeTex = fillResult.texture else { return }

        // Draw the rasterized shape texture
        guard let vertexBuffer = resources.makeQuadVertexBuffer(
            device: device,
            width: Float(shapeTex.width),
            height: Float(shapeTex.height)
        ) else { return }

        let mvp = ctx.viewportToNDC.toFloat4x4()
        var uniforms = QuadUniforms(mvp: mvp, opacity: 1.0) // Opacity already baked into texture

        ctx.encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        ctx.encoder.setVertexBytes(&uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 1)
        ctx.encoder.setFragmentTexture(shapeTex, index: 0)
        ctx.encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: resources.quadIndexCount,
            indexType: .uint16,
            indexBuffer: resources.quadIndexBuffer,
            indexBufferOffset: 0
        )
    }

    // swiftlint:disable:next function_parameter_count
    private func drawStroke(
        pathId: PathID,
        strokeColor: [Double],
        strokeOpacity: Double,
        strokeWidth: Double,
        lineCap: Int,
        lineJoin: Int,
        miterLimit: Double,
        layerOpacity: Double,
        frame: Double,
        ctx: RenderContext,
        transform: Matrix2D
    ) throws {
        let effectiveOpacity = strokeOpacity * layerOpacity
        guard effectiveOpacity > 0 else { return }
        guard strokeWidth > 0 else { return }

        // Look up path in registry and sample at current frame (PR-14B: cached)
        guard let pathResource = ctx.pathRegistry.path(for: pathId) else {
            assertionFailure("Missing path resource for pathId: \(pathId)")
            throw MetalRendererError.missingPathResource(pathId: pathId)
        }
        guard let path = samplePathCached(resource: pathResource, frame: frame, generationId: ctx.pathRegistry.generationId) else { return }
        guard path.vertexCount >= 2 else { return } // Stroke needs at least 2 vertices

        let targetSize = ctx.target.sizePx

        // Compute transform from path to viewport
        let pathToViewport = ctx.animToViewport.concatenating(transform)

        #if DEBUG
        perf?.beginPhase(.shapeCacheTotal)
        #endif

        // Rasterize stroke to BGRA texture using the shape cache
        let strokeResult = shapeCache.strokeTexture(
            for: path,
            transform: pathToViewport,
            size: targetSize,
            strokeColor: strokeColor,
            opacity: effectiveOpacity,
            strokeWidth: strokeWidth,
            lineCap: lineCap,
            lineJoin: lineJoin,
            miterLimit: miterLimit
        )

        #if DEBUG
        perf?.endPhase(.shapeCacheTotal)
        // Record stroke cache outcome
        if strokeResult.didHit {
            perf?.recordShapeStroke(outcome: .hit)
        } else if strokeResult.didEvict {
            perf?.recordShapeStroke(outcome: .missEvicted)
        } else {
            perf?.recordShapeStroke(outcome: .miss)
        }
        #endif

        guard let strokeTex = strokeResult.texture else { return }

        // Draw the rasterized stroke texture
        guard let vertexBuffer = resources.makeQuadVertexBuffer(
            device: device,
            width: Float(strokeTex.width),
            height: Float(strokeTex.height)
        ) else { return }

        let mvp = ctx.viewportToNDC.toFloat4x4()
        var uniforms = QuadUniforms(mvp: mvp, opacity: 1.0) // Opacity already baked into texture

        ctx.encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        ctx.encoder.setVertexBytes(&uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 1)
        ctx.encoder.setFragmentTexture(strokeTex, index: 0)
        ctx.encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: resources.quadIndexCount,
            indexType: .uint16,
            indexBuffer: resources.quadIndexBuffer,
            indexBufferOffset: 0
        )
    }
}

// MARK: - Matrix2D to simd_float4x4 Conversion

extension Matrix2D {
    func toFloat4x4() -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4<Float>(Float(a), Float(c), 0, 0),
            SIMD4<Float>(Float(b), Float(d), 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(Float(tx), Float(ty), 0, 1)
        ))
    }
}

// MARK: - Matte Composite Uniforms

/// Uniform buffer structure for matte composite rendering.
struct MatteCompositeUniforms {
    var mvp: simd_float4x4
    var mode: Int32
    var padding: SIMD3<Float> = .zero

    init(mvp: simd_float4x4, mode: Int32) {
        self.mvp = mvp
        self.mode = mode
    }
}

// MARK: - RenderMatteMode Shader Value

extension RenderMatteMode {
    /// Returns the shader mode value for this matte mode.
    /// 0 = alpha, 1 = alphaInverted, 2 = luma, 3 = lumaInverted
    var shaderModeValue: Int32 {
        switch self {
        case .alpha: return 0
        case .alphaInverted: return 1
        case .luma: return 2
        case .lumaInverted: return 3
        }
    }
}
