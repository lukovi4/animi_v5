import Metal
import simd

// MARK: - Execution Context

/// Tracks state during command execution.
private struct ExecutionContext {
    // Transform stack: starts with identity, push concatenates, pop restores
    var transformStack: [Matrix2D] = [.identity]

    // Scissor stack: full target rect initially
    var clipStack: [MTLScissorRect] = []

    // Balance counters for validation
    var groupDepth: Int = 0
    var maskDepth: Int = 0
    var matteDepth: Int = 0

    // Warning tracking (avoid spam per frame)
    var didWarnMasks: Bool = false
    var didWarnMattes: Bool = false

    // Current transform (top of stack)
    var currentTransform: Matrix2D {
        transformStack.last ?? .identity
    }

    // Current scissor rect (top of stack)
    var currentScissor: MTLScissorRect? {
        clipStack.last
    }

    // MARK: - Transform Stack

    mutating func pushTransform(_ matrix: Matrix2D) {
        // Stack behavior: current = current.concatenating(matrix)
        // This matches the PR6 effective matrix calculation
        let newTransform = currentTransform.concatenating(matrix)
        transformStack.append(newTransform)
    }

    mutating func popTransform() throws {
        // Cannot pop below initial identity
        guard transformStack.count > 1 else {
            throw MetalRendererError.invalidCommandStack(
                reason: "PopTransform with empty stack (would go below identity)"
            )
        }
        transformStack.removeLast()
    }

    // MARK: - Clip Stack

    mutating func pushClipRect(_ rect: RectD, targetSize: (width: Int, height: Int)) {
        let newScissor = makeScissorRect(from: rect, targetSize: targetSize)

        // Intersect with current scissor if exists
        let intersected: MTLScissorRect
        if let current = currentScissor {
            intersected = intersectScissorRects(current, newScissor, targetSize: targetSize)
        } else {
            intersected = newScissor
        }

        clipStack.append(intersected)
    }

    mutating func popClipRect() throws {
        guard !clipStack.isEmpty else {
            throw MetalRendererError.invalidCommandStack(
                reason: "PopClipRect with empty stack"
            )
        }
        clipStack.removeLast()
    }

    // MARK: - Scissor Helpers

    private func makeScissorRect(
        from rect: RectD,
        targetSize: (width: Int, height: Int)
    ) -> MTLScissorRect {
        // Clamp to target bounds
        let x = max(0, min(Int(rect.x), targetSize.width))
        let y = max(0, min(Int(rect.y), targetSize.height))
        let maxW = targetSize.width - x
        let maxH = targetSize.height - y
        let w = max(0, min(Int(rect.width), maxW))
        let h = max(0, min(Int(rect.height), maxH))

        return MTLScissorRect(x: x, y: y, width: w, height: h)
    }

    private func intersectScissorRects(
        _ a: MTLScissorRect,
        _ b: MTLScissorRect,
        targetSize: (width: Int, height: Int)
    ) -> MTLScissorRect {
        let x1 = max(a.x, b.x)
        let y1 = max(a.y, b.y)
        let x2 = min(a.x + a.width, b.x + b.width)
        let y2 = min(a.y + a.height, b.y + b.height)

        // If no intersection, return zero-sized rect
        if x2 <= x1 || y2 <= y1 {
            return MTLScissorRect(x: 0, y: 0, width: 0, height: 0)
        }

        return MTLScissorRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }
}

// MARK: - MetalRenderer Execute Extension

extension MetalRenderer {
    /// Internal rendering implementation shared by on-screen and offscreen paths.
    func drawInternal(
        commands: [RenderCommand],
        renderPassDescriptor: MTLRenderPassDescriptor,
        target: RenderTarget,
        textureProvider: TextureProvider,
        commandBuffer: MTLCommandBuffer
    ) throws {
        // Create render encoder
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            throw MetalRendererError.failedToCreateCommandBuffer
        }

        // Ensure encoder is always ended, even on error
        defer { encoder.endEncoding() }

        // Initialize context
        var context = ExecutionContext()
        let fullScissor = MTLScissorRect(
            x: 0,
            y: 0,
            width: target.sizePx.width,
            height: target.sizePx.height
        )
        context.clipStack.append(fullScissor)

        // Set initial scissor
        encoder.setScissorRect(fullScissor)

        // Compute mapping matrices
        let targetRect = RectD(
            x: 0,
            y: 0,
            width: Double(target.sizePx.width),
            height: Double(target.sizePx.height)
        )
        let animToViewport = GeometryMapping.animToInputContain(
            animSize: target.animSize,
            inputRect: targetRect
        )
        let viewportToNDC = GeometryMapping.viewportToNDC(
            width: Double(target.sizePx.width),
            height: Double(target.sizePx.height)
        )

        // Set up pipeline
        encoder.setRenderPipelineState(resources.pipelineState)
        encoder.setFragmentSamplerState(resources.samplerState, index: 0)

        // Execute commands
        for command in commands {
            try executeCommand(
                command,
                encoder: encoder,
                context: &context,
                target: target,
                textureProvider: textureProvider,
                animToViewport: animToViewport,
                viewportToNDC: viewportToNDC
            )
        }

        // Validate balanced stacks
        if context.groupDepth != 0 {
            throw MetalRendererError.invalidCommandStack(
                reason: "Unbalanced groups: depth=\(context.groupDepth)"
            )
        }
        if context.transformStack.count != 1 {
            throw MetalRendererError.invalidCommandStack(
                reason: "Unbalanced transforms: stack size=\(context.transformStack.count)"
            )
        }
        if context.clipStack.count != 1 {
            throw MetalRendererError.invalidCommandStack(
                reason: "Unbalanced clips: stack size=\(context.clipStack.count)"
            )
        }
        if context.maskDepth != 0 {
            throw MetalRendererError.invalidCommandStack(
                reason: "Unbalanced masks: depth=\(context.maskDepth)"
            )
        }
        if context.matteDepth != 0 {
            throw MetalRendererError.invalidCommandStack(
                reason: "Unbalanced mattes: depth=\(context.matteDepth)"
            )
        }
    }

    // MARK: - Command Execution

    private func executeCommand(
        _ command: RenderCommand,
        encoder: MTLRenderCommandEncoder,
        context: inout ExecutionContext,
        target: RenderTarget,
        textureProvider: TextureProvider,
        animToViewport: Matrix2D,
        viewportToNDC: Matrix2D
    ) throws {
        switch command {
        // MARK: Groups (no-op, but track balance)
        case .beginGroup:
            context.groupDepth += 1

        case .endGroup:
            context.groupDepth -= 1
            if context.groupDepth < 0 {
                throw MetalRendererError.invalidCommandStack(
                    reason: "EndGroup without matching BeginGroup"
                )
            }

        // MARK: Transform Stack
        case .pushTransform(let matrix):
            context.pushTransform(matrix)

        case .popTransform:
            try context.popTransform()

        // MARK: Clip Stack
        case .pushClipRect(let rect):
            context.pushClipRect(rect, targetSize: target.sizePx)
            if let scissor = context.currentScissor {
                encoder.setScissorRect(scissor)
            }

        case .popClipRect:
            try context.popClipRect()
            if let scissor = context.currentScissor {
                encoder.setScissorRect(scissor)
            }

        // MARK: Draw Image
        case .drawImage(let assetId, let opacity):
            try drawImage(
                assetId: assetId,
                opacity: opacity,
                encoder: encoder,
                context: context,
                target: target,
                textureProvider: textureProvider,
                animToViewport: animToViewport,
                viewportToNDC: viewportToNDC
            )

        // MARK: Masks (no-op in baseline, track balance)
        case .beginMaskAdd:
            context.maskDepth += 1
            if options.enableWarningsForUnsupportedCommands && !context.didWarnMasks {
                context.didWarnMasks = true
                #if DEBUG
                print("[MetalRenderer] Masks are not rendered in PR7 baseline")
                #endif
            }

        case .endMask:
            context.maskDepth -= 1
            if context.maskDepth < 0 {
                throw MetalRendererError.invalidCommandStack(
                    reason: "EndMask without matching BeginMask"
                )
            }

        // MARK: Mattes (no-op in baseline, track balance)
        case .beginMatteAlpha, .beginMatteAlphaInverted:
            context.matteDepth += 1
            if options.enableWarningsForUnsupportedCommands && !context.didWarnMattes {
                context.didWarnMattes = true
                #if DEBUG
                print("[MetalRenderer] Mattes are not rendered in PR7 baseline")
                #endif
            }

        case .endMatte:
            context.matteDepth -= 1
            if context.matteDepth < 0 {
                throw MetalRendererError.invalidCommandStack(
                    reason: "EndMatte without matching BeginMatte"
                )
            }
        }
    }

    // MARK: - Draw Image

    private func drawImage(
        assetId: String,
        opacity: Double,
        encoder: MTLRenderCommandEncoder,
        context: ExecutionContext,
        target: RenderTarget,
        textureProvider: TextureProvider,
        animToViewport: Matrix2D,
        viewportToNDC: Matrix2D
    ) throws {
        // Skip if fully transparent
        guard opacity > 0 else { return }

        // Get texture
        guard let texture = textureProvider.texture(for: assetId) else {
            throw MetalRendererError.noTextureForAsset(assetId: assetId)
        }

        // Get texture size for quad vertices
        let texWidth = Float(texture.width)
        let texHeight = Float(texture.height)

        // Create vertex buffer with quad in pixel coordinates
        guard let vertexBuffer = resources.makeQuadVertexBuffer(
            device: device,
            width: texWidth,
            height: texHeight
        ) else {
            return // Skip if buffer creation fails
        }

        // Compute MVP matrix:
        // MVP = viewportToNDC * animToViewport * currentTransform
        // Quad vertices are already in anim-space pixels (0..texW, 0..texH)
        let mvpMatrix2D = viewportToNDC
            .concatenating(animToViewport)
            .concatenating(context.currentTransform)

        // Convert Matrix2D to simd_float4x4
        let mvp = mvpMatrix2D.toFloat4x4()

        // Create uniforms
        var uniforms = QuadUniforms(mvp: mvp, opacity: Float(opacity))

        // Set vertex buffer
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

        // Set uniforms
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 1)

        // Set texture
        encoder.setFragmentTexture(texture, index: 0)

        // Draw indexed quad
        encoder.drawIndexedPrimitives(
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
    /// Converts 2D affine matrix to 4x4 matrix for Metal.
    /// The 2D matrix is embedded in the XY plane with Z=0.
    func toFloat4x4() -> simd_float4x4 {
        // Matrix2D layout:
        // | a  b  tx |
        // | c  d  ty |
        // | 0  0  1  |
        //
        // Embed into 4x4:
        // | a  b  0  tx |
        // | c  d  0  ty |
        // | 0  0  1  0  |
        // | 0  0  0  1  |
        //
        // Note: simd_float4x4 is column-major
        return simd_float4x4(columns: (
            SIMD4<Float>(Float(a), Float(c), 0, 0),   // Column 0
            SIMD4<Float>(Float(b), Float(d), 0, 0),   // Column 1
            SIMD4<Float>(0, 0, 1, 0),                  // Column 2
            SIMD4<Float>(Float(tx), Float(ty), 0, 1)  // Column 3
        ))
    }
}
