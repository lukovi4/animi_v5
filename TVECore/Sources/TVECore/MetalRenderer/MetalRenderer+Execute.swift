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
}

/// Groups parameters for mask scope rendering.
struct MaskScopeContext {
    let target: RenderTarget
    let textureProvider: TextureProvider
    let commandBuffer: MTLCommandBuffer
    let animToViewport: Matrix2D
    let viewportToNDC: Matrix2D
    let assetSizes: [String: AssetSize]
}

/// Groups parameters for matte scope rendering.
struct MatteScopeContext {
    let target: RenderTarget
    let textureProvider: TextureProvider
    let commandBuffer: MTLCommandBuffer
    let animToViewport: Matrix2D
    let viewportToNDC: Matrix2D
    let assetSizes: [String: AssetSize]
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

    mutating func pushClip(_ rect: RectD, targetSize: (width: Int, height: Int)) {
        let newScissor = ScissorHelper.makeScissorRect(from: rect, targetSize: targetSize)
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
        initialState: ExecutionState? = nil
    ) throws {
        let baseline = initialState ?? makeInitialState(target: target)
        var state = baseline
        let targetRect = RectD(
            x: 0, y: 0,
            width: Double(target.sizePx.width),
            height: Double(target.sizePx.height)
        )
        let animToViewport = GeometryMapping.animToInputContain(animSize: target.animSize, inputRect: targetRect)
        let viewportToNDC = GeometryMapping.viewportToNDC(width: targetRect.width, height: targetRect.height)

        // Process commands in segments separated by mask/matte scopes
        var index = 0
        var isFirstPass = true

        while index < commands.count {
            // Find next mask or matte scope or end of commands
            let segmentStart = index
            var segmentEnd = commands.count
            var foundScopeType: ScopeType?

            for idx in segmentStart..<commands.count {
                if case .beginMaskAdd = commands[idx] {
                    segmentEnd = idx
                    foundScopeType = .mask
                    break
                }
                if case .beginMatte = commands[idx] {
                    segmentEnd = idx
                    foundScopeType = .matte
                    break
                }
            }

            // Render segment if non-empty
            if segmentStart < segmentEnd {
                try renderSegment(
                    commands: Array(commands[segmentStart..<segmentEnd]),
                    target: target,
                    textureProvider: textureProvider,
                    commandBuffer: commandBuffer,
                    animToViewport: animToViewport,
                    viewportToNDC: viewportToNDC,
                    assetSizes: assetSizes,
                    state: &state,
                    renderPassDescriptor: isFirstPass ? renderPassDescriptor : nil
                )
                isFirstPass = false
            }

            index = segmentEnd

            // Process scope if found
            switch foundScopeType {
            case .mask:
                guard let scope = extractMaskScope(from: commands, startIndex: index) else {
                    throw MetalRendererError.invalidCommandStack(reason: "Malformed mask: BeginMaskAdd without EndMask")
                }
                let scopeCtx = MaskScopeContext(
                    target: target,
                    textureProvider: textureProvider,
                    commandBuffer: commandBuffer,
                    animToViewport: animToViewport,
                    viewportToNDC: viewportToNDC,
                    assetSizes: assetSizes
                )
                try renderMaskScope(scope: scope, ctx: scopeCtx, inheritedState: state)
                index = scope.endIndex + 1
                isFirstPass = false

            case .matte:
                let matteScope = try extractMatteScope(from: commands, startIndex: index)
                let matteScopeCtx = MatteScopeContext(
                    target: target,
                    textureProvider: textureProvider,
                    commandBuffer: commandBuffer,
                    animToViewport: animToViewport,
                    viewportToNDC: viewportToNDC,
                    assetSizes: assetSizes
                )
                try renderMatteScope(scope: matteScope, ctx: matteScopeCtx, inheritedState: state)
                index = matteScope.endIndex + 1
                isFirstPass = false

            case .none:
                break
            }
        }

        try validateBalancedStacks(state, baseline: baseline)
    }

    // swiftlint:disable:next function_parameter_count
    private func renderSegment(
        commands: [RenderCommand],
        target: RenderTarget,
        textureProvider: TextureProvider,
        commandBuffer: MTLCommandBuffer,
        animToViewport: Matrix2D,
        viewportToNDC: Matrix2D,
        assetSizes: [String: AssetSize],
        state: inout ExecutionState,
        renderPassDescriptor: MTLRenderPassDescriptor?
    ) throws {
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
            assetSizes: assetSizes
        )

        encoder.setScissorRect(state.clipStack[0])
        encoder.setRenderPipelineState(resources.pipelineState)
        encoder.setFragmentSamplerState(resources.samplerState, index: 0)

        for command in commands {
            try executeCommand(command, ctx: ctx, state: &state)
        }
    }

    private func renderMaskScope(
        scope: MaskScope,
        ctx: MaskScopeContext,
        inheritedState: ExecutionState
    ) throws {
        let targetSize = ctx.target.sizePx
        let currentScissor = inheritedState.currentScissor

        // Skip if path is empty or degenerate
        guard scope.path.vertexCount > 2 else {
            try renderInnerCommandsToTarget(
                scope.innerCommands,
                target: ctx.target,
                textureProvider: ctx.textureProvider,
                commandBuffer: ctx.commandBuffer,
                inheritedState: inheritedState
            )
            return
        }

        // Step 1: Render inner commands to offscreen texture
        guard let contentTex = texturePool.acquireColorTexture(size: targetSize) else {
            return
        }
        defer { texturePool.release(contentTex) }

        let innerCtx = InnerRenderContext(
            target: ctx.target,
            textureProvider: ctx.textureProvider,
            commandBuffer: ctx.commandBuffer,
            assetSizes: ctx.assetSizes
        )
        try renderInnerCommandsToTexture(
            scope.innerCommands,
            texture: contentTex,
            ctx: innerCtx,
            inheritedState: inheritedState
        )

        // Step 2: Get or create mask texture
        let maskTransform = ctx.animToViewport.concatenating(inheritedState.currentTransform)
        guard let maskTex = maskCache.texture(
            for: scope.path,
            transform: maskTransform,
            size: targetSize,
            opacity: scope.opacity
        ) else {
            try compositeTextureToTarget(
                contentTex,
                target: ctx.target,
                viewportToNDC: ctx.viewportToNDC,
                commandBuffer: ctx.commandBuffer,
                scissor: currentScissor
            )
            return
        }

        // Step 3: Composite with stencil
        let compositeCtx = MaskCompositeContext(
            target: ctx.target,
            viewportToNDC: ctx.viewportToNDC,
            commandBuffer: ctx.commandBuffer,
            scissor: currentScissor
        )
        try compositeWithStencilMask(contentTex: contentTex, maskTex: maskTex, ctx: compositeCtx)
    }

    private func renderInnerCommandsToTarget(
        _ commands: [RenderCommand],
        target: RenderTarget,
        textureProvider: TextureProvider,
        commandBuffer: MTLCommandBuffer,
        inheritedState: ExecutionState
    ) throws {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target.texture
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store

        try drawInternal(
            commands: commands,
            renderPassDescriptor: descriptor,
            target: target,
            textureProvider: textureProvider,
            commandBuffer: commandBuffer,
            initialState: inheritedState
        )
    }

    private func renderInnerCommandsToTexture(
        _ commands: [RenderCommand],
        texture: MTLTexture,
        ctx: InnerRenderContext,
        inheritedState: ExecutionState
    ) throws {
        let offscreenTarget = RenderTarget(
            texture: texture,
            drawableScale: ctx.target.drawableScale,
            animSize: ctx.target.animSize
        )

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        try drawInternal(
            commands: commands,
            renderPassDescriptor: descriptor,
            target: offscreenTarget,
            textureProvider: ctx.textureProvider,
            commandBuffer: ctx.commandBuffer,
            initialState: inheritedState
        )
    }

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

    private func renderMatteScope(
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
            scope.sourceCommands,
            texture: matteTex,
            target: ctx.target,
            textureProvider: ctx.textureProvider,
            commandBuffer: ctx.commandBuffer,
            inheritedState: inheritedState
        )

        // Step 2: Render matte consumer commands to consumerTex
        guard let consumerTex = texturePool.acquireColorTexture(size: targetSize) else {
            return
        }
        defer { texturePool.release(consumerTex) }

        try renderCommandsToTexture(
            scope.consumerCommands,
            texture: consumerTex,
            target: ctx.target,
            textureProvider: ctx.textureProvider,
            commandBuffer: ctx.commandBuffer,
            inheritedState: inheritedState
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

    // swiftlint:disable:next function_parameter_count
    private func renderCommandsToTexture(
        _ commands: [RenderCommand],
        texture: MTLTexture,
        target: RenderTarget,
        textureProvider: TextureProvider,
        commandBuffer: MTLCommandBuffer,
        inheritedState: ExecutionState
    ) throws {
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
            renderPassDescriptor: descriptor,
            target: offscreenTarget,
            textureProvider: textureProvider,
            commandBuffer: commandBuffer,
            initialState: inheritedState
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

/// Result of extracting a mask scope from command list
struct MaskScope {
    let startIndex: Int
    let endIndex: Int
    let innerCommands: [RenderCommand]
    let path: BezierPath
    let opacity: Double
}

// MARK: - Matte Scope Extraction

/// Result of extracting a matte scope from command list
struct MatteScope {
    let startIndex: Int
    let endIndex: Int
    let mode: RenderMatteMode
    let sourceCommands: [RenderCommand]
    let consumerCommands: [RenderCommand]
}

extension MetalRenderer {
    /// Extracts a mask scope starting at the given index.
    /// Handles nested masks by counting begin/end pairs.
    func extractMaskScope(from commands: [RenderCommand], startIndex: Int) -> MaskScope? {
        guard startIndex < commands.count,
              case .beginMaskAdd(let path, let opacity) = commands[startIndex] else {
            return nil
        }

        var depth = 1
        var index = startIndex + 1

        while index < commands.count && depth > 0 {
            switch commands[index] {
            case .beginMaskAdd:
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

        let innerCommands = Array(commands[(startIndex + 1)..<index])

        return MaskScope(
            startIndex: startIndex,
            endIndex: index,
            innerCommands: innerCommands,
            path: path,
            opacity: opacity
        )
    }

    /// Extracts a matte scope starting at the given index.
    /// Expects exactly two child groups: "matteSource" and "matteConsumer".
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

        // Extract inner commands (between beginMatte and endMatte)
        let innerCommands = Array(commands[(startIndex + 1)..<endMatteIndex])

        // Parse the two groups: matteSource and matteConsumer
        let (sourceCommands, consumerCommands) = try parseMatteGroups(innerCommands)

        return MatteScope(
            startIndex: startIndex,
            endIndex: endMatteIndex,
            mode: mode,
            sourceCommands: sourceCommands,
            consumerCommands: consumerCommands
        )
    }

    // Parses matte scope inner commands to extract matteSource and matteConsumer group contents.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func parseMatteGroups(
        _ commands: [RenderCommand]
    ) throws -> (source: [RenderCommand], consumer: [RenderCommand]) {
        // Find first group (matteSource)
        guard !commands.isEmpty,
              case .beginGroup(let firstName) = commands[0],
              firstName == "matteSource" else {
            let msg = "Matte scope must start with beginGroup(\"matteSource\")"
            throw MetalRendererError.invalidCommandStack(reason: msg)
        }

        // Find end of matteSource group
        var depth = 1
        var sourceEndIndex = 1
        while sourceEndIndex < commands.count && depth > 0 {
            switch commands[sourceEndIndex] {
            case .beginGroup:
                depth += 1
            case .endGroup:
                depth -= 1
            default:
                break
            }
            if depth > 0 {
                sourceEndIndex += 1
            }
        }

        guard depth == 0 else {
            throw MetalRendererError.invalidCommandStack(reason: "Unbalanced matteSource group")
        }

        let sourceCommands = Array(commands[1..<sourceEndIndex])

        // Find second group (matteConsumer)
        let consumerStartIndex = sourceEndIndex + 1
        guard consumerStartIndex < commands.count,
              case .beginGroup(let secondName) = commands[consumerStartIndex],
              secondName == "matteConsumer" else {
            let msg = "Matte scope must have beginGroup(\"matteConsumer\") after matteSource"
            throw MetalRendererError.invalidCommandStack(reason: msg)
        }

        // Find end of matteConsumer group
        depth = 1
        var consumerEndIndex = consumerStartIndex + 1
        while consumerEndIndex < commands.count && depth > 0 {
            switch commands[consumerEndIndex] {
            case .beginGroup:
                depth += 1
            case .endGroup:
                depth -= 1
            default:
                break
            }
            if depth > 0 {
                consumerEndIndex += 1
            }
        }

        guard depth == 0 else {
            throw MetalRendererError.invalidCommandStack(reason: "Unbalanced matteConsumer group")
        }

        let consumerCommands = Array(commands[(consumerStartIndex + 1)..<consumerEndIndex])

        // Verify nothing else after matteConsumer
        if consumerEndIndex + 1 < commands.count {
            let msg = "Unexpected commands after matteConsumer group in matte scope"
            throw MetalRendererError.invalidCommandStack(reason: msg)
        }

        return (sourceCommands, consumerCommands)
    }
}

// MARK: - Command Execution

extension MetalRenderer {
    // swiftlint:disable:next cyclomatic_complexity
    private func executeCommand(_ command: RenderCommand, ctx: RenderContext, state: inout ExecutionState) throws {
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
            state.pushClip(rect, targetSize: ctx.target.sizePx)
            if let scissor = state.currentScissor { ctx.encoder.setScissorRect(scissor) }
        case .popClipRect:
            try state.popClip()
            if let scissor = state.currentScissor { ctx.encoder.setScissorRect(scissor) }
        case .drawImage(let assetId, let opacity):
            try drawImage(assetId: assetId, opacity: opacity, ctx: ctx, transform: state.currentTransform)
        case .drawShape(let path, let fillColor, let fillOpacity, let layerOpacity):
            try drawShape(
                path: path,
                fillColor: fillColor,
                fillOpacity: fillOpacity,
                layerOpacity: layerOpacity,
                ctx: ctx,
                transform: state.currentTransform
            )
        case .beginMaskAdd:
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

    private func drawImage(assetId: String, opacity: Double, ctx: RenderContext, transform: Matrix2D) throws {
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
        guard let vertexBuffer = resources.makeQuadVertexBuffer(
            device: device,
            width: quadWidth,
            height: quadHeight
        ) else { return }

        let mvp = ctx.viewportToNDC.concatenating(ctx.animToViewport).concatenating(transform).toFloat4x4()
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
        path: BezierPath,
        fillColor: [Double]?,
        fillOpacity: Double,
        layerOpacity: Double,
        ctx: RenderContext,
        transform: Matrix2D
    ) throws {
        let effectiveOpacity = (fillOpacity / 100.0) * layerOpacity
        guard effectiveOpacity > 0, path.vertexCount > 2 else { return }

        let targetSize = ctx.target.sizePx

        // Compute transform from path to viewport
        let pathToViewport = ctx.animToViewport.concatenating(transform)

        // Rasterize shape to BGRA texture using the shape cache
        guard let shapeTex = shapeCache.texture(
            for: path,
            transform: pathToViewport,
            size: targetSize,
            fillColor: fillColor ?? [1, 1, 1],
            opacity: effectiveOpacity
        ) else { return }

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
