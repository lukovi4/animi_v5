import Metal
import simd

// MARK: - Render Context

/// Groups rendering parameters to reduce function parameter count.
private struct RenderContext {
    let encoder: MTLRenderCommandEncoder
    let target: RenderTarget
    let textureProvider: TextureProvider
    let animToViewport: Matrix2D
    let viewportToNDC: Matrix2D
}

// MARK: - Execution State

/// Tracks state during command execution.
private struct ExecutionState {
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
    func drawInternal(
        commands: [RenderCommand],
        renderPassDescriptor: MTLRenderPassDescriptor,
        target: RenderTarget,
        textureProvider: TextureProvider,
        commandBuffer: MTLCommandBuffer
    ) throws {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            throw MetalRendererError.failedToCreateCommandBuffer
        }
        defer { encoder.endEncoding() }

        let ctx = makeRenderContext(encoder: encoder, target: target, textureProvider: textureProvider)
        var state = makeInitialState(target: target)

        encoder.setScissorRect(state.clipStack[0])
        encoder.setRenderPipelineState(resources.pipelineState)
        encoder.setFragmentSamplerState(resources.samplerState, index: 0)

        for command in commands {
            try executeCommand(command, ctx: ctx, state: &state)
        }

        try validateBalancedStacks(state)
    }

    private func makeRenderContext(
        encoder: MTLRenderCommandEncoder,
        target: RenderTarget,
        textureProvider: TextureProvider
    ) -> RenderContext {
        let targetRect = RectD(x: 0, y: 0, width: Double(target.sizePx.width), height: Double(target.sizePx.height))
        return RenderContext(
            encoder: encoder,
            target: target,
            textureProvider: textureProvider,
            animToViewport: GeometryMapping.animToInputContain(animSize: target.animSize, inputRect: targetRect),
            viewportToNDC: GeometryMapping.viewportToNDC(width: targetRect.width, height: targetRect.height)
        )
    }

    private func makeInitialState(target: RenderTarget) -> ExecutionState {
        var state = ExecutionState()
        state.clipStack.append(MTLScissorRect(x: 0, y: 0, width: target.sizePx.width, height: target.sizePx.height))
        return state
    }

    private func validateBalancedStacks(_ state: ExecutionState) throws {
        if state.groupDepth != 0 {
            throw MetalRendererError.invalidCommandStack(reason: "Unbalanced groups: \(state.groupDepth)")
        }
        if state.transformStack.count != 1 {
            throw MetalRendererError.invalidCommandStack(reason: "Unbalanced transforms: \(state.transformStack.count)")
        }
        if state.clipStack.count != 1 {
            throw MetalRendererError.invalidCommandStack(reason: "Unbalanced clips: \(state.clipStack.count)")
        }
        if state.maskDepth != 0 {
            throw MetalRendererError.invalidCommandStack(reason: "Unbalanced masks: \(state.maskDepth)")
        }
        if state.matteDepth != 0 {
            throw MetalRendererError.invalidCommandStack(reason: "Unbalanced mattes: \(state.matteDepth)")
        }
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
        case .beginMaskAdd:
            state.maskDepth += 1
        case .endMask:
            state.maskDepth -= 1
            guard state.maskDepth >= 0 else {
                throw MetalRendererError.invalidCommandStack(reason: "EndMask without BeginMask")
            }
        case .beginMatteAlpha, .beginMatteAlphaInverted:
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
        guard let vertexBuffer = resources.makeQuadVertexBuffer(
            device: device,
            width: Float(texture.width),
            height: Float(texture.height)
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
