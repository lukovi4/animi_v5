# Rendering Pipeline (canonical) — RenderCommands → Metal passes (Masks/Matte/Shaders)

Snapshot: `project_snapshot.zip`.

**Rule:** Every statement below is backed by a **code anchor**: `file:lineStart-lineEnd` showing 5–15 lines. If something exists in code but is **not called** by the current execution path, it is marked **UNREACHABLE in snapshot**.

---

## 1) RenderCommand stream model (all scopes + clip rect)

Render commands are a linear stream interpreted by `MetalRenderer`.

**Anchors (RenderCommand definition + clip commands explicitly present)**
  - `TVECore/Sources/TVECore/RenderGraph/RenderCommand.swift:21-110`

    ```swift
    public enum RenderCommand: Sendable, Equatable {
        // MARK: - Grouping
    
        /// Begin a named group (for debugging and hierarchy)
        case beginGroup(name: String)
    
        /// End the current group
        case endGroup
    
        // MARK: - Transform Stack
    
        /// Push a transform matrix onto the stack
        case pushTransform(Matrix2D)
    
        /// Pop the top transform from the stack
        case popTransform
    
        // MARK: - Clipping
    
        /// Push a clip rectangle onto the stack
        case pushClipRect(RectD)
    
        /// Pop the top clip rectangle from the stack
        case popClipRect
    
        // MARK: - Drawing
    
        /// Draw an image asset
        case drawImage(assetId: String, opacity: Double)
    
        /// Draw a shape using GPU path rendering
        /// Used for shape layers as matte sources
        /// - Parameters:
        ///   - pathId: Reference to PathResource in PathRegistry
        ///   - fillColor: RGB fill color (0-1 each component)
        ///   - fillOpacity: Fill opacity (0-100)
        ///   - layerOpacity: Layer opacity (0-1)
        ///   - frame: Current frame for animated path interpolation
        case drawShape(pathId: PathID, fillColor: [Double]?, fillOpacity: Double, layerOpacity: Double, frame: Double)
    
        /// Draw a stroke around a shape path (PR-10)
        /// Renders the path outline with specified stroke style
        /// - Parameters:
        ///   - pathId: Reference to PathResource in PathRegistry
        ///   - strokeColor: RGB stroke color (0-1 each component)
        ///   - strokeOpacity: Stroke opacity (0-1)
        ///   - strokeWidth: Stroke width in pixels
        ///   - lineCap: Line cap style (1=butt, 2=round, 3=square)
        ///   - lineJoin: Line join style (1=miter, 2=round, 3=bevel)
        ///   - miterLimit: Miter limit for miter joins
        ///   - layerOpacity: Layer opacity (0-1)
        ///   - frame: Current frame for animated path interpolation
        case drawStroke(
            pathId: PathID,
            strokeColor: [Double],
            strokeOpacity: Double,
            strokeWidth: Double,
            lineCap: Int,
            lineJoin: Int,
            miterLimit: Double,
            layerOpacity: Double,
            frame: Double
        )
    
        // MARK: - Masking
    
        /// Begin a mask scope with boolean operation mode for GPU mask accumulation.
        /// Masks are applied via coverage texture and combined using the specified mode.
        /// - Parameters:
        ///   - mode: Boolean operation (add/subtract/intersect)
        ///   - inverted: Whether to invert coverage before applying operation
        ///   - pathId: Reference to PathResource in PathRegistry
        ///   - opacity: Mask opacity (0.0 to 1.0)
        ///   - frame: Current frame for animated path interpolation
        case beginMask(mode: MaskMode, inverted: Bool, pathId: PathID, opacity: Double, frame: Double)
    
        /// End the current mask
        case endMask
    
        // MARK: - Track Matte
    
        /// Begin track matte scope with the specified mode.
        /// The scope must contain exactly two child groups in order:
        /// 1. `beginGroup("matteSource")` - commands rendering the matte source
        /// 2. `beginGroup("matteConsumer")` - commands rendering the consumer layer
        case beginMatte(mode: RenderMatteMode)
    
        /// End the current track matte scope
        case endMatte
    }
    ```

  - `TVECore/Sources/TVECore/RenderGraph/RenderCommand.swift:114-151`

    ```swift
    extension RenderCommand {
        /// Returns true if this is a "begin" command that requires a matching "end"
        public var isBeginCommand: Bool {
            switch self {
            case .beginGroup, .pushTransform, .pushClipRect, .beginMask, .beginMatte:
                return true
            default:
                return false
            }
        }
    
        /// Returns true if this is an "end" command
        public var isEndCommand: Bool {
            switch self {
            case .endGroup, .popTransform, .popClipRect, .endMask, .endMatte:
                return true
            default:
                return false
            }
        }
    
        /// Returns the matching end command type for begin commands
        public var matchingEndCommand: RenderCommand? {
            switch self {
            case .beginGroup:
                return .endGroup
            case .pushTransform:
                return .popTransform
            case .pushClipRect:
                return .popClipRect
            case .beginMask:
                return .endMask
            case .beginMatte:
                return .endMatte
            default:
                return nil
            }
        }
    ```

---

## 2) ExecutionState (transform stack + clip/scissor stack)

Renderer execution keeps:
- `transformStack` of `Matrix2D`
- `clipStack` of `MTLScissorRect` (push intersects with current)

**Anchors**
  - `TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift:64-131`

    ```swift
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
    ```

  - `TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift:88-123`

    ```swift
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
    ```

---

## 3) Entry points + dispatcher (segments and scopes)

### 3.1 drawInternal(...) (full array) and overrideAnimToViewport

`drawInternal` chooses `animToViewport` from `overrideAnimToViewport ?? GeometryMapping.animToInputContain(...)`.

**Anchor**
  - `TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift:160-180`

    ```swift
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
    
    ```

### 3.2 drawInternal(commands: in range: ...) overload (bbox/local rendering)

There is an overload that renders only `Range<Int>`; it also supports `overrideAnimToViewport`.

**Anchor**
  - `TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift:317-343`

    ```swift
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
    
    ```

### 3.3 Dispatcher: split command stream into plain segments and scopes

`drawInternal` scans for the next `.beginMask` / `.beginMatte`, renders the preceding segment via `renderSegment`, then extracts and renders the scope.

**Anchors**
  - `TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift:189-225`

    ```swift
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
    ```

  - `TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift:238-272`

    ```swift
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
    ```

  - `TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift:286-298`

    ```swift
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
    ```

---

## 4) Plain segment rendering: encoder creation + per-command execution

### 4.1 renderSegment creates a render encoder + sets pipeline + scissor

**Anchor**
  - `TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift:491-525`

    ```swift
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
    ```

### 4.2 Clip rect stack → encoder scissor

`pushClipRect`/`popClipRect` update `ExecutionState.clipStack` and immediately update encoder scissor.

**Anchor**
  - `TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift:1680-1687`

    ```swift
            case .pushClipRect(let rect):
                state.pushClip(rect, targetSize: ctx.target.sizePx, animToViewport: ctx.animToViewport)
                if let scissor = state.currentScissor {
                    ctx.encoder.setScissorRect(scissor)
                }
            case .popClipRect:
                try state.popClip()
                if let scissor = state.currentScissor { ctx.encoder.setScissorRect(scissor) }
    ```

### 4.3 drawImage (quad pipeline)

**Anchor**
  - `TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift:1759-1794`

    ```swift
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
    ```

### 4.4 drawShape and drawStroke (CPU raster → quad)

Both use `samplePathCached` and `ShapeCache` to avoid repeated sampling and raster.

**Anchors**
  - `TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift:1827-1869`

    ```swift
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
    ```

  - `TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift:1907-1953`

    ```swift
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
    ```

---

## 5) Shaders & pipeline states (entrypoints)

### 5.1 Library loading (Bundle.module metallib → default library)

**Anchor**
  - `TVECore/Sources/TVECore/MetalRenderer/MetalRendererResources.swift:197-209`

    ```swift
    extension MetalRendererResources {
        private static func makeShaderLibrary(device: MTLDevice) throws -> MTLLibrary {
            // Try SPM Bundle.module first (for TVECore as Swift Package)
            if let url = Bundle.module.url(forResource: "default", withExtension: "metallib"),
               let lib = try? device.makeLibrary(URL: url) {
                return lib
            }
            // Fallback: main bundle (for embedded frameworks or direct integration)
            if let lib = device.makeDefaultLibrary() {
                return lib
            }
            throw MetalRendererError.failedToCreatePipeline(reason: "Failed to load Metal library from Bundle.module or main bundle")
        }
    ```

### 5.2 Quad pipeline (quad_vertex + quad_fragment)

**Anchors**
  - `TVECore/Sources/TVECore/MetalRenderer/MetalRendererResources.swift:211-235`

    ```swift
        private static func makePipelineState(
            device: MTLDevice,
            library: MTLLibrary,
            colorPixelFormat: MTLPixelFormat
        ) throws -> MTLRenderPipelineState {
            guard let vertexFunc = library.makeFunction(name: "quad_vertex") else {
                throw MetalRendererError.failedToCreatePipeline(reason: "quad_vertex not found")
            }
            guard let fragmentFunc = library.makeFunction(name: "quad_fragment") else {
                throw MetalRendererError.failedToCreatePipeline(reason: "quad_fragment not found")
            }
    
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunc
            descriptor.fragmentFunction = fragmentFunc
            descriptor.vertexDescriptor = makeVertexDescriptor()
            configureBlending(descriptor.colorAttachments[0], pixelFormat: colorPixelFormat)
    
            do {
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                let msg = "Pipeline creation failed: \(error.localizedDescription)"
                throw MetalRendererError.failedToCreatePipeline(reason: msg)
            }
        }
    ```

  - `TVECore/Sources/TVECore/MetalRenderer/Shaders/QuadShaders.metal:29-48`

    ```metal
    vertex QuadVertexOut quad_vertex(
        QuadVertexIn in [[stage_in]],
        constant QuadUniforms& uniforms [[buffer(1)]]
    ) {
        QuadVertexOut out;
        out.position = uniforms.mvp * float4(in.position, 0.0, 1.0);
        out.texCoord = in.texCoord;
        out.opacity = uniforms.opacity;
        return out;
    }
    
    fragment float4 quad_fragment(
        QuadVertexOut in [[stage_in]],
        texture2d<float> tex [[texture(0)]],
        sampler samp [[sampler(0)]]
    ) {
        float4 color = tex.sample(samp, in.texCoord);
        // Premultiplied alpha: multiply all channels by opacity
        return color * in.opacity;
    }
    ```

### 5.3 Matte composite pipeline (matte_composite_*)

**Anchors**
  - `TVECore/Sources/TVECore/MetalRenderer/MetalRendererResources.swift:393-417`

    ```swift
        private static func makeMatteCompositePipeline(
            device: MTLDevice,
            library: MTLLibrary,
            colorPixelFormat: MTLPixelFormat
        ) throws -> MTLRenderPipelineState {
            guard let vertexFunc = library.makeFunction(name: "matte_composite_vertex") else {
                throw MetalRendererError.failedToCreatePipeline(reason: "matte_composite_vertex not found")
            }
            guard let fragmentFunc = library.makeFunction(name: "matte_composite_fragment") else {
                throw MetalRendererError.failedToCreatePipeline(reason: "matte_composite_fragment not found")
            }
    
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunc
            descriptor.fragmentFunction = fragmentFunc
            descriptor.vertexDescriptor = makeVertexDescriptor()
            configureBlending(descriptor.colorAttachments[0], pixelFormat: colorPixelFormat)
    
            do {
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                let msg = "Matte composite pipeline failed: \(error.localizedDescription)"
                throw MetalRendererError.failedToCreatePipeline(reason: msg)
            }
        }
    ```

  - `TVECore/Sources/TVECore/MetalRenderer/Shaders/QuadShaders.metal:93-134`

    ```metal
    vertex MatteCompositeVertexOut matte_composite_vertex(
        QuadVertexIn in [[stage_in]],
        constant MatteCompositeUniforms& uniforms [[buffer(1)]]
    ) {
        MatteCompositeVertexOut out;
        out.position = uniforms.mvp * float4(in.position, 0.0, 1.0);
        out.texCoord = in.texCoord;
        return out;
    }
    
    fragment float4 matte_composite_fragment(
        MatteCompositeVertexOut in [[stage_in]],
        texture2d<float> consumerTex [[texture(0)]],
        texture2d<float> matteTex [[texture(1)]],
        sampler samp [[sampler(0)]],
        constant MatteCompositeUniforms& uniforms [[buffer(1)]]
    ) {
        float4 consumer = consumerTex.sample(samp, in.texCoord);
        float4 matte = matteTex.sample(samp, in.texCoord);
    
        float factor;
        int mode = uniforms.mode;
    
        if (mode == 0) {
            // alpha
            factor = matte.a;
        } else if (mode == 1) {
            // alphaInverted
            factor = 1.0 - matte.a;
        } else if (mode == 2) {
            // luma: luminance = 0.2126*r + 0.7152*g + 0.0722*b
            float luma = 0.2126 * matte.r + 0.7152 * matte.g + 0.0722 * matte.b;
            factor = luma;
        } else {
            // lumaInverted
            float luma = 0.2126 * matte.r + 0.7152 * matte.g + 0.0722 * matte.b;
            factor = 1.0 - luma;
        }
    
        // Apply factor to premultiplied consumer
        return float4(consumer.rgb * factor, consumer.a * factor);
    }
    ```

### 5.4 GPU mask pipelines (coverage + masked composite + compute combine)

**Anchors**
  - `TVECore/Sources/TVECore/MetalRenderer/MetalRendererResources.swift:422-454`

    ```swift
    extension MetalRendererResources {
        /// Creates pipeline for rendering path triangles to R8 coverage texture.
        /// Uses additive blending for overlapping triangles.
        private static func makeCoveragePipeline(
            device: MTLDevice,
            library: MTLLibrary
        ) throws -> MTLRenderPipelineState {
            guard let vertexFunc = library.makeFunction(name: "coverage_vertex") else {
                throw MetalRendererError.failedToCreatePipeline(reason: "coverage_vertex not found")
            }
            guard let fragmentFunc = library.makeFunction(name: "coverage_fragment") else {
                throw MetalRendererError.failedToCreatePipeline(reason: "coverage_fragment not found")
            }
    
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunc
            descriptor.fragmentFunction = fragmentFunc
    
            // R8Unorm output for coverage
            let colorAttachment = descriptor.colorAttachments[0]!
            colorAttachment.pixelFormat = .r8Unorm
            // No blending - triangulation should not produce overlapping triangles
            // If overlap occurs, it's a bug in triangulation data
            // saturate() in compute kernel handles any edge cases
            colorAttachment.isBlendingEnabled = false
    
            do {
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                let msg = "Coverage pipeline failed: \(error.localizedDescription)"
                throw MetalRendererError.failedToCreatePipeline(reason: msg)
            }
        }
    ```

  - `TVECore/Sources/TVECore/MetalRenderer/Shaders/QuadShaders.metal:149-165`

    ```metal
    vertex CoverageVertexOut coverage_vertex(
        uint vertexID [[vertex_id]],
        const device float2* positions [[buffer(0)]],
        constant CoverageUniforms& uniforms [[buffer(1)]]
    ) {
        CoverageVertexOut out;
        float2 pos = positions[vertexID];
        out.position = uniforms.mvp * float4(pos, 0.0, 1.0);
        return out;
    }
    
    fragment float coverage_fragment(CoverageVertexOut in [[stage_in]]) {
        // Output raw coverage = 1.0 inside path triangles
        // No blending - triangulation produces non-overlapping triangles
        // saturate() in combine kernel handles any edge cases
        return 1.0;
    }
    ```

  - `TVECore/Sources/TVECore/MetalRenderer/MetalRendererResources.swift:456-481`

    ```swift
        /// Creates pipeline for compositing content with R8 mask (content × mask.r).
        private static func makeMaskedCompositePipeline(
            device: MTLDevice,
            library: MTLLibrary,
            colorPixelFormat: MTLPixelFormat
        ) throws -> MTLRenderPipelineState {
            guard let vertexFunc = library.makeFunction(name: "masked_composite_vertex") else {
                throw MetalRendererError.failedToCreatePipeline(reason: "masked_composite_vertex not found")
            }
            guard let fragmentFunc = library.makeFunction(name: "masked_composite_fragment") else {
                throw MetalRendererError.failedToCreatePipeline(reason: "masked_composite_fragment not found")
            }
    
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunc
            descriptor.fragmentFunction = fragmentFunc
            descriptor.vertexDescriptor = makeVertexDescriptor()
            configureBlending(descriptor.colorAttachments[0], pixelFormat: colorPixelFormat)
    
            do {
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                let msg = "Masked composite pipeline failed: \(error.localizedDescription)"
                throw MetalRendererError.failedToCreatePipeline(reason: msg)
            }
        }
    ```

  - `TVECore/Sources/TVECore/MetalRenderer/Shaders/QuadShaders.metal:175-198`

    ```metal
    vertex QuadVertexOut masked_composite_vertex(
        QuadVertexIn in [[stage_in]],
        constant MaskedCompositeUniforms& uniforms [[buffer(1)]]
    ) {
        QuadVertexOut out;
        out.position = uniforms.mvp * float4(in.position, 0.0, 1.0);
        out.texCoord = in.texCoord;
        out.opacity = uniforms.opacity;
        return out;
    }
    
    fragment float4 masked_composite_fragment(
        QuadVertexOut in [[stage_in]],
        texture2d<float> contentTex [[texture(0)]],
        texture2d<float> maskTex [[texture(1)]],
        sampler samp [[sampler(0)]]
    ) {
        float4 content = contentTex.sample(samp, in.texCoord);
        float maskValue = maskTex.sample(samp, in.texCoord).r;
    
        // Apply mask to premultiplied content
        float factor = maskValue * in.opacity;
        return float4(content.rgb * factor, content.a * factor);
    }
    ```

  - `TVECore/Sources/TVECore/MetalRenderer/MetalRendererResources.swift:483-498`

    ```swift
        /// Creates compute pipeline for mask boolean operations.
        private static func makeMaskCombineComputePipeline(
            device: MTLDevice,
            library: MTLLibrary
        ) throws -> MTLComputePipelineState {
            guard let kernelFunc = library.makeFunction(name: "mask_combine_kernel") else {
                throw MetalRendererError.failedToCreatePipeline(reason: "mask_combine_kernel not found")
            }
    
            do {
                return try device.makeComputePipelineState(function: kernelFunc)
            } catch {
                let msg = "Mask combine compute pipeline failed: \(error.localizedDescription)"
                throw MetalRendererError.failedToCreatePipeline(reason: msg)
            }
        }
    ```

  - `TVECore/Sources/TVECore/MetalRenderer/Shaders/QuadShaders.metal:214-257`

    ```metal
    kernel void mask_combine_kernel(
        texture2d<float, access::read> coverageTex [[texture(0)]],
        texture2d<float, access::read> accumInTex [[texture(1)]],
        texture2d<float, access::write> accumOutTex [[texture(2)]],
        constant MaskCombineParams& params [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        // Bounds check
        if (gid.x >= accumOutTex.get_width() || gid.y >= accumOutTex.get_height()) {
            return;
        }
    
        // Read current accumulator value
        float acc = accumInTex.read(gid).r;
    
        // Read and process coverage
        float cov = coverageTex.read(gid).r;
    
        // Clamp coverage to [0,1] (triangulation may cause slight overdraw)
        cov = saturate(cov);
    
        // Apply inverted flag
        if (params.inverted != 0) {
            cov = 1.0 - cov;
        }
    
        // Apply opacity
        cov *= params.opacity;
    
        // Apply boolean operation
        float result;
        if (params.mode == MASK_MODE_ADD) {
            // ADD: acc = max(acc, cov)
            result = max(acc, cov);
        } else if (params.mode == MASK_MODE_SUBTRACT) {
            // SUBTRACT: acc = acc * (1 - cov)
            result = acc * (1.0 - cov);
        } else {
            // INTERSECT: acc = min(acc, cov)
            result = min(acc, cov);
        }
    
        accumOutTex.write(float4(result, 0.0, 0.0, 0.0), gid);
    }
    ```

---

## 6) Mask scopes (GPU boolean masks)

Mask scopes are routed into the GPU-mask implementation: coverage render to R8, boolean combine in compute, then composite masked content.

### 6.1 Mask bbox + texture acquisition + degenerate fallback

**Anchors**
  - `TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+MaskRender.swift:48-95`

    ```swift
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
                    commands,
                    in: scope.innerRange,
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
                    commands,
                    in: scope.innerRange,
                    ctx: ctx,
                    inheritedState: inheritedState
                )
                return
            }
    ```

### 6.2 Per-op clear + coverage render + combine kernel (ping-pong)

**Anchors**
  - `TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+MaskRender.swift:130-161`

    ```swift
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
    ```

### 6.3 Accumulator initial value depends on mask mode

**Anchor**
  - `TVECore/Sources/TVECore/MetalRenderer/MaskTypes.swift:63-70`

    ```swift
    func initialAccumulatorValue(for opsInAeOrder: [MaskOp]) -> Float {
        guard let first = opsInAeOrder.first else { return 0 }
        switch first.mode {
        case .add:
            return 0
        case .subtract, .intersect:
            return 1
        }
    ```

### 6.4 Inner render and final composite

**Anchors**
  - `TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+MaskRender.swift:191-203`

    ```swift
            // **PR Hot Path:** Pass full commands + range for inner content
            try drawInternal(
                commands: commands,
                in: scope.innerRange,
                renderPassDescriptor: descriptor,
                target: offscreenTarget,
                textureProvider: ctx.textureProvider,
                commandBuffer: ctx.commandBuffer,
                assetSizes: ctx.assetSizes,
                pathRegistry: ctx.pathRegistry,
                initialState: bboxState,
                overrideAnimToViewport: bboxAnimToViewport
            )
    ```

  - `TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+MaskHelpers.swift:243-278`

    ```swift
            encoder.setRenderPipelineState(resources.maskedCompositePipelineState)
            encoder.setFragmentSamplerState(resources.samplerState, index: 0)
    
            // Create quad vertices at bbox position
            let x = Float(bbox.x)
            let y = Float(bbox.y)
            let w = Float(bbox.width)
            let h = Float(bbox.height)
    
            let vertices: [QuadVertex] = [
                QuadVertex(position: SIMD2<Float>(x, y), texCoord: SIMD2<Float>(0, 0)),
                QuadVertex(position: SIMD2<Float>(x + w, y), texCoord: SIMD2<Float>(1, 0)),
                QuadVertex(position: SIMD2<Float>(x, y + h), texCoord: SIMD2<Float>(0, 1)),
                QuadVertex(position: SIMD2<Float>(x + w, y + h), texCoord: SIMD2<Float>(1, 1))
            ]
    
            let vertexSize = vertices.count * MemoryLayout<QuadVertex>.stride
            guard let vertexBuffer = device.makeBuffer(bytes: vertices, length: vertexSize, options: .storageModeShared) else {
                return
            }
    
            // MVP transforms viewport coords to NDC
            let mvp = viewportToNDC.toFloat4x4()
            var uniforms = MaskedCompositeUniforms(mvp: mvp, opacity: 1.0)
    
            // DEBUG: Validate uniforms struct matches Metal shader (96 bytes)
            #if DEBUG
            precondition(MemoryLayout<MaskedCompositeUniforms>.stride == 96,
                         "MaskedCompositeUniforms stride mismatch: \(MemoryLayout<MaskedCompositeUniforms>.stride) != 96")
            #endif
    
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MaskedCompositeUniforms>.stride, index: 1)
            encoder.setFragmentTexture(content, index: 0)
            encoder.setFragmentTexture(mask, index: 1)
    
    ```

---

## 7) Matte scopes (track matte)

Matte scopes render source and consumer into offscreen textures and then composite using `matte_composite_fragment`. There are two paths: bbox-optimized or full-frame fallback.

### 7.1 Bbox decision and fallback

**Anchor**
  - `TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift:881-916`

    ```swift
            // Step 0: Compute bbox for matte scope
            let bboxFloat = computeMatteBBox(
                commands: commands,
                sourceRange: scope.sourceRange,
                consumerRange: scope.consumerRange,
                inheritedTransform: inheritedState.currentTransform,
                animToViewport: ctx.animToViewport,
                assetSizes: ctx.assetSizes,
                pathRegistry: ctx.pathRegistry
            )
    
            // Check if bbox is valid and convert to pixels
            if let floatBbox = bboxFloat,
               let bbox = roundClampIntersectBBoxToPixels(
                   floatBbox,
                   targetSize: targetSize,
                   scissor: currentScissor,
                   expandAA: 2
               ) {
                // Bbox-based rendering path
                try renderMatteScopeBBox(
                    commands: commands,
                    scope: scope,
                    ctx: ctx,
                    inheritedState: inheritedState,
                    bbox: bbox
                )
            } else {
                // Fallback: full-frame rendering (original behavior)
                try renderMatteScopeFullFrame(
                    commands: commands,
                    scope: scope,
                    ctx: ctx,
                    inheritedState: inheritedState
                )
            }
    ```

### 7.2 Bbox path (range drawInternal + overrideAnimToViewport)

**Anchor**
  - `TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift:933-1004`

    ```swift
            // Allocate bbox-sized textures
            guard let matteTex = texturePool.acquireColorTexture(size: bboxSize) else {
                return
            }
            defer { texturePool.release(matteTex) }
    
            guard let consumerTex = texturePool.acquireColorTexture(size: bboxSize) else {
                return
            }
            defer { texturePool.release(consumerTex) }
    
            // Compute viewport offset for bbox-local rendering
            // viewportToBbox: translate by -bbox.origin
            let viewportToBbox = Matrix2D.translation(x: Double(-bbox.x), y: Double(-bbox.y))
            let bboxAnimToViewport = viewportToBbox.concatenating(ctx.animToViewport)
    
            // Create bbox-local state
            var bboxState = inheritedState
            bboxState.clipStack = [bboxLocalScissor]
    
            // Create bbox-sized offscreen target
            let offscreenTarget = RenderTarget(
                texture: matteTex,
                drawableScale: ctx.target.drawableScale,
                animSize: ctx.target.animSize
            )
    
            // Step 1: Render matte source to bbox-sized matteTex
            let sourceDescriptor = MTLRenderPassDescriptor()
            sourceDescriptor.colorAttachments[0].texture = matteTex
            sourceDescriptor.colorAttachments[0].loadAction = .clear
            sourceDescriptor.colorAttachments[0].storeAction = .store
            sourceDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    
            try drawInternal(
                commands: commands,
                in: scope.sourceRange,
                renderPassDescriptor: sourceDescriptor,
                target: offscreenTarget,
                textureProvider: ctx.textureProvider,
                commandBuffer: ctx.commandBuffer,
                assetSizes: ctx.assetSizes,
                pathRegistry: ctx.pathRegistry,
                initialState: bboxState,
                overrideAnimToViewport: bboxAnimToViewport
            )
    
            // Step 2: Render matte consumer to bbox-sized consumerTex
            let consumerOffscreenTarget = RenderTarget(
                texture: consumerTex,
                drawableScale: ctx.target.drawableScale,
                animSize: ctx.target.animSize
            )
    
            let consumerDescriptor = MTLRenderPassDescriptor()
            consumerDescriptor.colorAttachments[0].texture = consumerTex
            consumerDescriptor.colorAttachments[0].loadAction = .clear
            consumerDescriptor.colorAttachments[0].storeAction = .store
            consumerDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    
            try drawInternal(
                commands: commands,
                in: scope.consumerRange,
                renderPassDescriptor: consumerDescriptor,
                target: consumerOffscreenTarget,
                textureProvider: ctx.textureProvider,
                commandBuffer: ctx.commandBuffer,
                assetSizes: ctx.assetSizes,
                pathRegistry: ctx.pathRegistry,
                initialState: bboxState,
                overrideAnimToViewport: bboxAnimToViewport
            )
    ```

### 7.3 Full-frame fallback (renderMatteScopeFullFrame)

**Anchor**
  - `TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift:1019-1065`

    ```swift
        /// Fallback: Renders matte scope using full-frame offscreen textures.
        ///
        /// This is the original behavior, used when bbox cannot be computed.
        /// Preserves 100% visual compatibility.
        private func renderMatteScopeFullFrame(
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
    ```

### 7.4 Matte bbox computation (MatteBboxCompute.swift)

**Anchors**
  - `TVECore/Sources/TVECore/MetalRenderer/MatteBboxCompute.swift:26-74`

    ```swift
    func computeMatteBBox(
        commands: [RenderCommand],
        sourceRange: Range<Int>,
        consumerRange: Range<Int>,
        inheritedTransform: Matrix2D,
        animToViewport: Matrix2D,
        assetSizes: [String: AssetSize],
        pathRegistry: PathRegistry
    ) -> CGRect? {
        // Compute source and consumer bboxes separately
        let sourceBbox = computeRangeBBox(
            commands: commands,
            range: sourceRange,
            inheritedTransform: inheritedTransform,
            animToViewport: animToViewport,
            assetSizes: assetSizes,
            pathRegistry: pathRegistry
        )
    
        let consumerBbox = computeRangeBBox(
            commands: commands,
            range: consumerRange,
            inheritedTransform: inheritedTransform,
            animToViewport: animToViewport,
            assetSizes: assetSizes,
            pathRegistry: pathRegistry
        )
    
        // Per review.md #2: intersection(source, consumer)
        // If source nil → use consumer only (conservative)
        // If both nil → return nil (fallback)
        switch (sourceBbox, consumerBbox) {
        case let (source?, consumer?):
            // Intersection of both
            let intersection = source.intersection(consumer)
            // Check for empty intersection
            guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
                return nil
            }
            return intersection
    
        case (nil, let consumer?):
            // Source unavailable, use consumer only (less optimal but safe)
            return consumer
    
        case (_, nil):
            // Consumer unavailable → cannot compute valid bbox
            return nil
        }
    ```

  - `TVECore/Sources/TVECore/MetalRenderer/MatteBboxCompute.swift:79-99`

    ```swift
    /// Computes bounding box for a range of commands by dry-running through them.
    ///
    /// Simulates transform stack and accumulates bounds for all draw* commands.
    /// Ignores clip rects (per review.md #7 - scissor applied later).
    ///
    /// - Parameters:
    ///   - commands: Full command array
    ///   - range: Range of commands to process
    ///   - inheritedTransform: Starting transform
    ///   - animToViewport: Animation to viewport transform
    ///   - assetSizes: Asset sizes for drawImage
    ///   - pathRegistry: Path registry for shapes
    /// - Returns: Accumulated bbox in viewport coordinates, or nil if no valid bounds
    private func computeRangeBBox(
        commands: [RenderCommand],
        range: Range<Int>,
        inheritedTransform: Matrix2D,
        animToViewport: Matrix2D,
        assetSizes: [String: AssetSize],
        pathRegistry: PathRegistry
    ) -> CGRect? {
    ```

---

## 8) Caching & pools (performance-critical)

This section addresses the previously missing onboarding-critical components.

### 8.1 Ownership and initialization in MetalRenderer

**Anchor**
  - `TVECore/Sources/TVECore/MetalRenderer/MetalRenderer.swift:147-222`

    ```swift
    public final class MetalRenderer {
        // MARK: - Properties
    
        let device: MTLDevice
        let resources: MetalRendererResources
        let options: MetalRendererOptions
        let texturePool: TexturePool
        let maskCache: MaskCache
        let shapeCache: ShapeCache
        private let logger: TVELogger?
    
        // PR-C3: GPU buffer caching for mask rendering
        let vertexUploadPool: VertexUploadPool
        let pathIndexBufferCache: PathIndexBufferCache
    
        // PR-14B: Two-level path sampling cache (frame memo + LRU)
        let pathSamplingCache: PathSamplingCache
    
        // PR-14C: Performance metrics (DEBUG-only, opt-in via options.enablePerfMetrics)
        #if DEBUG
        private(set) var perf: PerfMetrics?
        private var perfFrameIndex: Int = 0
        #endif
    
        // MARK: - Initialization
    
        /// Creates a Metal renderer.
        /// - Parameters:
        ///   - device: Metal device to use
        ///   - colorPixelFormat: Pixel format for color attachments
        ///   - options: Renderer configuration options
        ///   - logger: Optional logger for diagnostic messages
        /// - Throws: MetalRendererError if initialization fails
        public init(
            device: MTLDevice,
            colorPixelFormat: MTLPixelFormat,
            options: MetalRendererOptions = MetalRendererOptions(),
            logger: TVELogger? = nil
        ) throws {
            self.device = device
            self.options = options
            self.logger = logger
            self.resources = try MetalRendererResources(device: device, colorPixelFormat: colorPixelFormat)
            self.texturePool = TexturePool(device: device)
            self.maskCache = MaskCache(device: device)
            self.shapeCache = ShapeCache(device: device)
            self.vertexUploadPool = VertexUploadPool(device: device, buffersInFlight: options.maxFramesInFlight)
            self.pathIndexBufferCache = PathIndexBufferCache(device: device)
            self.pathSamplingCache = PathSamplingCache()
    
            #if DEBUG
            self.perf = options.enablePerfMetrics ? PerfMetrics() : nil
            #endif
        }
    
        /// Diagnostic logging (only when enabled via options)
        func diagLog(_ message: String) {
            guard options.enableDiagnostics else { return }
            if let logger = logger {
                logger("[RENDERER] \(message)")
            } else {
                #if DEBUG
                print("[RENDERER] \(message)")
                #endif
            }
        }
    
        /// Clears pooled textures to free memory.
        /// Call this when the renderer won't be used for a while.
        public func clearCaches() {
            texturePool.clear()
            maskCache.clear()
            shapeCache.clear()
            pathIndexBufferCache.clear()
            pathSamplingCache.clear()
        }
    ```

### 8.2 TexturePool (offscreen texture reuse)

**Anchors**
  - `TVECore/Sources/TVECore/MetalRenderer/TexturePool.swift:24-85`

    ```swift
    // MARK: - Texture Pool
    
    /// Manages reusable Metal textures to avoid per-frame allocations.
    /// Textures are pooled by (width, height, pixelFormat) key.
    final class TexturePool {
        private let device: MTLDevice
        private var available: [TexturePoolKey: [MTLTexture]] = [:]
        private var inUse: Set<ObjectIdentifier> = []
    
        init(device: MTLDevice) {
            self.device = device
        }
    
        /// Acquires a color texture (BGRA8Unorm) for offscreen rendering.
        /// - Parameter size: Texture dimensions in pixels
        /// - Returns: A texture configured for render target and shader read
        /// - Note: PR1 — uses `.private` storage for GPU-only access (no CPU read/write)
        func acquireColorTexture(size: (width: Int, height: Int)) -> MTLTexture? {
            acquire(
                size: size,
                pixelFormat: .bgra8Unorm,
                usage: [.renderTarget, .shaderRead],
                storageMode: .private
            )
        }
    
        /// Acquires a stencil texture (depth32Float_stencil8) for mask rendering.
        /// - Parameter size: Texture dimensions in pixels
        /// - Returns: A texture configured for render target
        func acquireStencilTexture(size: (width: Int, height: Int)) -> MTLTexture? {
            acquire(
                size: size,
                pixelFormat: .depth32Float_stencil8,
                usage: [.renderTarget],
                storageMode: .private
            )
        }
    
        /// Acquires a mask texture (r8Unorm) for alpha mask storage (CPU raster path).
        /// - Parameter size: Texture dimensions in pixels
        /// - Returns: A texture configured for shader read
        func acquireMaskTexture(size: (width: Int, height: Int)) -> MTLTexture? {
            acquire(
                size: size,
                pixelFormat: .r8Unorm,
                usage: [.shaderRead],
                storageMode: .shared
            )
        }
    
        /// Acquires an R8 texture for GPU mask accumulator or coverage rendering.
        /// Used for GPU-based mask boolean operations (add/subtract/intersect).
        /// - Parameter size: Texture dimensions in pixels
        /// - Returns: A texture configured for render target, shader read, and shader write
        func acquireR8Texture(size: (width: Int, height: Int)) -> MTLTexture? {
            acquire(
                size: size,
                pixelFormat: .r8Unorm,
                usage: [.renderTarget, .shaderRead, .shaderWrite],
                storageMode: .private
            )
        }
    ```

  - `TVECore/Sources/TVECore/MetalRenderer/TexturePool.swift:87-142`

    ```swift
        /// Releases a texture back to the pool for reuse.
        /// - Parameter texture: The texture to release
        func release(_ texture: MTLTexture) {
            let identifier = ObjectIdentifier(texture)
            guard inUse.contains(identifier) else { return }
    
            inUse.remove(identifier)
            let key = TexturePoolKey(
                width: texture.width,
                height: texture.height,
                pixelFormat: texture.pixelFormat
            )
            available[key, default: []].append(texture)
        }
    
        /// Clears all pooled textures to free memory.
        func clear() {
            available.removeAll()
            inUse.removeAll()
        }
    
        // MARK: - Private
    
        private func acquire(
            size: (width: Int, height: Int),
            pixelFormat: MTLPixelFormat,
            usage: MTLTextureUsage,
            storageMode: MTLStorageMode
        ) -> MTLTexture? {
            let key = TexturePoolKey(size: size, pixelFormat: pixelFormat)
    
            // Try to reuse existing texture
            if var textures = available[key], !textures.isEmpty {
                let texture = textures.removeLast()
                available[key] = textures
                inUse.insert(ObjectIdentifier(texture))
                return texture
            }
    
            // Create new texture
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat,
                width: size.width,
                height: size.height,
                mipmapped: false
            )
            descriptor.usage = usage
            descriptor.storageMode = storageMode
    
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                return nil
            }
    
            inUse.insert(ObjectIdentifier(texture))
            return texture
        }
    ```

### 8.3 ShapeCache (LRU cache for rasterized fill/stroke textures)

**Anchors**
  - `TVECore/Sources/TVECore/MetalRenderer/ShapeCache.swift:7-58`

    ```swift
    /// Key for caching rasterized shape textures.
    /// Combines path identity, target size, transform, fill color, and opacity for uniqueness.
    /// PR-14A: Uses quantized hashes for determinism and better cache hit rate.
    struct ShapeCacheKey: Hashable {
        let pathHash: Int
        let width: Int
        let height: Int
        let transformHash: Int
        let colorHash: Int
        let quantizedOpacity: Int
    
        init(path: BezierPath, size: (width: Int, height: Int), transform: Matrix2D, fillColor: [Double], opacity: Double) {
            self.pathHash = Self.computeQuantizedPathHash(path)
            self.width = size.width
            self.height = size.height
            self.transformHash = transform.quantizedHash()
            self.colorHash = Self.computeQuantizedColorHash(fillColor)
            // Quantize opacity to 1/256 steps (8-bit precision matches texture output)
            self.quantizedOpacity = Quantization.quantizedInt(opacity, step: 1.0 / 256.0)
        }
    
        /// Computes deterministic path hash using quantized coordinates.
        /// Eliminates cache misses from floating-point noise (e.g., 1e-12 differences).
        private static func computeQuantizedPathHash(_ path: BezierPath) -> Int {
            let step = AnimConstants.pathCoordQuantStep
            var hasher = Hasher()
            hasher.combine(path.closed)
            hasher.combine(path.vertices.count)
            for vertex in path.vertices {
                hasher.combine(Quantization.quantizedInt(vertex.x, step: step))
                hasher.combine(Quantization.quantizedInt(vertex.y, step: step))
            }
            for tangent in path.inTangents {
                hasher.combine(Quantization.quantizedInt(tangent.x, step: step))
                hasher.combine(Quantization.quantizedInt(tangent.y, step: step))
            }
            for tangent in path.outTangents {
                hasher.combine(Quantization.quantizedInt(tangent.x, step: step))
                hasher.combine(Quantization.quantizedInt(tangent.y, step: step))
            }
            return hasher.finalize()
        }
    
        /// Computes deterministic color hash using quantized components.
        private static func computeQuantizedColorHash(_ color: [Double]) -> Int {
            var hasher = Hasher()
            // Quantize to 8-bit precision (1/256) to match texture color depth
            for component in color {
                hasher.combine(Quantization.quantizedInt(component, step: 1.0 / 256.0))
            }
            return hasher.finalize()
        }
    ```

  - `TVECore/Sources/TVECore/MetalRenderer/ShapeCache.swift:133-214`

    ```swift
    // MARK: - Shape Cache
    
    /// Caches rasterized shape textures to avoid re-rasterization.
    /// Similar to MaskCache but produces BGRA textures with fill color.
    /// Also supports stroke rendering (PR-10).
    final class ShapeCache {
        private let device: MTLDevice
        private var cache: [ShapeCacheKey: MTLTexture] = [:]
        private var accessOrder: [ShapeCacheKey] = []
        private var strokeCache: [StrokeCacheKey: MTLTexture] = [:]
        private var strokeAccessOrder: [StrokeCacheKey] = []
        private let maxEntries: Int
    
        /// Creates a shape cache with the given device and capacity.
        /// - Parameters:
        ///   - device: Metal device for texture creation
        ///   - maxEntries: Maximum number of cached textures (default: 64)
        init(device: MTLDevice, maxEntries: Int = 64) {
            self.device = device
            self.maxEntries = maxEntries
        }
    
        /// Result of a shape cache lookup, exposing hit/miss for external metrics.
        struct TextureResult {
            let texture: MTLTexture?
            let didHit: Bool
            let didEvict: Bool
        }
    
        /// Gets or creates a shape texture for the given parameters.
        /// - Parameters:
        ///   - path: The Bezier path to rasterize
        ///   - transform: Transform from path coords to viewport pixels
        ///   - size: Target texture size in pixels
        ///   - fillColor: RGB fill color (0.0 to 1.0)
        ///   - opacity: Overall opacity (0.0 to 1.0)
        /// - Returns: Result with texture and cache hit/eviction info
        func texture(
            for path: BezierPath,
            transform: Matrix2D,
            size: (width: Int, height: Int),
            fillColor: [Double],
            opacity: Double
        ) -> TextureResult {
            let key = ShapeCacheKey(path: path, size: size, transform: transform, fillColor: fillColor, opacity: opacity)
    
            // Check cache
            if let cached = cache[key] {
                updateAccessOrder(key)
                return TextureResult(texture: cached, didHit: true, didEvict: false)
            }
    
            // Rasterize path to alpha bytes
            let alphaBytes = MaskRasterizer.rasterize(
                path: path,
                transformToViewportPx: transform,
                targetSizePx: size,
                fillRule: .nonZero,
                antialias: true
            )
    
            guard !alphaBytes.isEmpty else { return TextureResult(texture: nil, didHit: false, didEvict: false) }
    
            // Convert to BGRA with fill color and opacity
            let bgraBytes = convertToBGRA(
                alphaBytes: alphaBytes,
                width: size.width,
                height: size.height,
                fillColor: fillColor,
                opacity: opacity
            )
    
            // Create texture
            guard let texture = createTexture(from: bgraBytes, size: size) else {
                return TextureResult(texture: nil, didHit: false, didEvict: false)
            }
    
            // Store in cache with eviction
            let evicted = storeInCache(key: key, texture: texture)
    
            return TextureResult(texture: texture, didHit: false, didEvict: evicted)
        }
    ```

### 8.4 PathSamplingCache (FrameMemo + LRU) + samplePathCached wrapper

**Anchors**
  - `TVECore/Sources/TVECore/MetalRenderer/PathSamplingCache.swift:32-124`

    ```swift
    // MARK: - Path Sampling Cache (PR-14B)
    
    /// Two-level cache for `samplePath(resource:, frame:)` results.
    ///
    /// Eliminates redundant BezierPath sampling during rendering:
    /// - **FrameMemo** (Level 1): per-frame dictionary, cleared at each `beginFrame()`.
    ///   Catches fill + stroke sampling of the same path within a single draw call.
    /// - **SamplingLRU** (Level 2): bounded multi-frame cache with LRU eviction.
    ///   Catches repeated frames during playback (looping, scrubbing back).
    ///
    /// Lookup order: FrameMemo → LRU → producer closure (actual sampling).
    /// On miss, the result is stored in both levels.
    ///
    /// PR-14C: No internal counters. Returns `PathSampleResult` so the caller
    /// (MetalRenderer + PerfMetrics) can record outcomes externally.
    ///
    /// Owned by `MetalRenderer`, lives alongside `ShapeCache`.
    /// Not a global singleton — freed when renderer is deallocated.
    final class PathSamplingCache {
        // MARK: - Frame Memo (per-frame, Level 1)
    
        private var frameMemo: [PathSampleKey: BezierPath] = [:]
    
        // MARK: - LRU Cache (multi-frame, Level 2)
    
        private var lruCache: [PathSampleKey: BezierPath] = [:]
        private var lruAccessOrder: [PathSampleKey] = []
        private let maxLRUEntries: Int
    
        // MARK: - Init
    
        /// Creates a path sampling cache.
        /// - Parameter maxLRUEntries: Maximum entries in the LRU cache (default: 1024).
        ///   Frame memo is unbounded per-frame but reset every `beginFrame()`.
        init(maxLRUEntries: Int = 1024) {
            self.maxLRUEntries = maxLRUEntries
        }
    
        // MARK: - Frame Lifecycle
    
        /// Clears the per-frame memo. Call at the start of each `draw()`.
        /// The LRU cache is preserved across frames.
        func beginFrame() {
            frameMemo.removeAll(keepingCapacity: true)
        }
    
        // MARK: - Sampling
    
        /// Retrieves a cached BezierPath or computes it via the producer closure.
        /// Returns a `PathSampleResult` indicating the cache outcome.
        ///
        /// - Parameters:
        ///   - generationId: `PathRegistry.generationId` (prevents cross-compilation collisions)
        ///   - pathId: Path identifier from RenderCommand
        ///   - frame: Animation frame (quantized internally via `AnimConstants.frameQuantStep`)
        ///   - producer: Closure that performs the actual `samplePath(resource:, frame:)`.
        ///              Called only on cache miss.
        /// - Returns: `PathSampleResult` with the sampled path (or nil) and outcome type.
        func sample(
            generationId: Int,
            pathId: PathID,
            frame: Double,
            producer: () -> BezierPath?
        ) -> PathSampleResult {
            let key = PathSampleKey(
                generationId: generationId,
                pathId: pathId,
                quantizedFrame: Quantization.quantizedInt(frame, step: AnimConstants.frameQuantStep)
            )
    
            // Level 1: Frame memo (same-frame dedup — fill + stroke)
            if let cached = frameMemo[key] {
                return .hitFrameMemo(cached)
            }
    
            // Level 2: LRU (cross-frame reuse — loops, scrubbing)
            if let cached = lruCache[key] {
                frameMemo[key] = cached
                updateLRUAccessOrder(key)
                return .hitLRU(cached)
            }
    
            // Miss: compute via producer
            guard let result = producer() else {
                return .missNil
            }
    
            // Store in both levels
            frameMemo[key] = result
            storeLRU(key: key, value: result)
    
            return .miss(result)
        }
    ```

  - `TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift:592-650`

    ```swift
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
    ```

### 8.5 VertexUploadPool (ring buffers) + PathIndexBufferCache

**Anchors**
  - `TVECore/Sources/TVECore/MetalRenderer/VertexUploadPool.swift:5-157`

    ```swift
    /// Ring buffer pool for uploading vertex data to GPU without per-op allocations.
    ///
    /// Uses multiple buffers (ring) to avoid GPU/CPU data hazards when GPU is still
    /// reading data from previous frames (typically 1-3 frames behind).
    ///
    /// Usage:
    /// 1. Call `beginFrame()` at the start of each frame (rotates to next buffer in ring)
    /// 2. Call `uploadFloats(_:)` to upload vertex data
    /// 3. Use returned `Slice` for `setVertexBuffer(slice.buffer, offset: slice.offset, ...)`
    ///
    /// The pool manages N shared MTLBuffers internally (default 3 for triple buffering)
    /// and handles growth when needed (rare, only on first few frames or very large paths).
    final class VertexUploadPool {
        /// A slice of the upload buffer containing uploaded data.
        struct Slice {
            let buffer: MTLBuffer
            let offset: Int
            let length: Int
        }
    
        /// Default initial capacity per buffer (256 KB)
        static let defaultCapacity = 256 * 1024
    
        /// Default number of buffers in ring (triple buffering)
        static let defaultBuffersInFlight = 3
    
        /// Alignment for vertex data (16 bytes for SIMD compatibility)
        private static let alignment = 16
    
        private let device: MTLDevice
        private let buffersInFlight: Int
        private let initialCapacity: Int
    
        /// Ring of buffers, one per in-flight frame
        private var buffers: [MTLBuffer?]
        /// Capacity of each buffer in ring (can grow independently)
        private var capacities: [Int]
        /// Current buffer index in ring (starts at buffersInFlight-1 so first beginFrame selects 0)
        private var bufferIndex: Int
        /// Current write offset in active buffer
        private var currentOffset: Int = 0
    
        #if DEBUG
        /// Number of times a new MTLBuffer was created (for testing)
        private(set) var debugCreatedBuffersCount: Int = 0
        /// Current buffer index (for testing)
        var debugCurrentBufferIndex: Int { bufferIndex }
        /// Whether beginFrame was called this frame (for contract validation)
        private var frameStarted: Bool = false
        #endif
    
        /// Creates a vertex upload pool with ring buffer.
        /// - Parameters:
        ///   - device: Metal device for buffer creation
        ///   - buffersInFlight: Number of buffers in ring (default 3 for triple buffering)
        ///   - initialCapacityBytes: Initial buffer capacity in bytes per buffer
        init(
            device: MTLDevice,
            buffersInFlight: Int = defaultBuffersInFlight,
            initialCapacityBytes: Int = defaultCapacity
        ) {
            self.device = device
            self.buffersInFlight = max(1, buffersInFlight)
            self.initialCapacity = initialCapacityBytes
            self.buffers = [MTLBuffer?](repeating: nil, count: self.buffersInFlight)
            self.capacities = [Int](repeating: initialCapacityBytes, count: self.buffersInFlight)
            // Start at buffersInFlight-1 so first beginFrame() selects buffer 0
            self.bufferIndex = self.buffersInFlight - 1
        }
    
        /// Begins a new frame by rotating to the next buffer in ring.
        /// Call this at the start of each frame before any uploads.
        ///
        /// This ensures we don't overwrite data that GPU may still be reading
        /// from previous frames.
        ///
        /// - Important: Must be called before any `uploadFloats()` calls in a frame.
        func beginFrame() {
            bufferIndex = (bufferIndex + 1) % buffersInFlight
            currentOffset = 0
            #if DEBUG
            frameStarted = true
            #endif
        }
    
        /// Uploads float array to the pool and returns a slice.
        ///
        /// - Important: `beginFrame()` must be called before this method in each frame.
        /// - Parameter floats: Float array to upload
        /// - Returns: Slice containing buffer, offset, and length; or nil if allocation fails
        func uploadFloats(_ floats: [Float]) -> Slice? {
            #if DEBUG
            precondition(frameStarted, "uploadFloats() called before beginFrame(). Must call beginFrame() at start of each frame.")
            #endif
    
            let byteCount = floats.count * MemoryLayout<Float>.stride
            guard byteCount > 0 else { return nil }
    
            // Align offset
            let alignedOffset = Self.alignUp(currentOffset, Self.alignment)
            let requiredCapacity = alignedOffset + byteCount
    
            // Get current buffer and its capacity
            var currentBuffer = buffers[bufferIndex]
            var currentCapacity = capacities[bufferIndex]
    
            // Ensure buffer exists and has enough capacity
            if currentBuffer == nil {
                // First allocation for this buffer slot - use initial or required capacity
                let newCapacity = max(initialCapacity, requiredCapacity)
                guard let newBuffer = device.makeBuffer(length: newCapacity, options: .storageModeShared) else {
                    return nil
                }
                currentBuffer = newBuffer
                currentCapacity = newCapacity
                buffers[bufferIndex] = newBuffer
                capacities[bufferIndex] = newCapacity
                #if DEBUG
                debugCreatedBuffersCount += 1
                #endif
            } else if requiredCapacity > currentCapacity {
                // Need to grow this buffer - use 2x or required capacity
                let newCapacity = max(currentCapacity * 2, requiredCapacity)
                guard let newBuffer = device.makeBuffer(length: newCapacity, options: .storageModeShared) else {
                    return nil
                }
                currentBuffer = newBuffer
                currentCapacity = newCapacity
                buffers[bufferIndex] = newBuffer
                capacities[bufferIndex] = newCapacity
                // Reset offset since we have a fresh buffer
                currentOffset = 0
                #if DEBUG
                debugCreatedBuffersCount += 1
                #endif
            }
    
            guard let buf = currentBuffer else { return nil }
    
            // Recalculate aligned offset (may have changed if buffer was reallocated)
            let alignedOffsetFinal = Self.alignUp(currentOffset, Self.alignment)
    
            // Copy data
            let dest = buf.contents().advanced(by: alignedOffsetFinal)
            _ = floats.withUnsafeBytes { src in
                memcpy(dest, src.baseAddress!, byteCount)
            }
    
            // Advance offset
            currentOffset = alignedOffsetFinal + byteCount
    
            return Slice(buffer: buf, offset: alignedOffsetFinal, length: byteCount)
        }
    ```

  - `TVECore/Sources/TVECore/MetalRenderer/VertexUploadPool.swift:165-214`

    ```swift
    // MARK: - Path Index Buffer Cache
    
    /// Cache for index buffers keyed by PathID.
    ///
    /// Index buffers are stable per PathResource (indices don't change across frames),
    /// so we cache them to avoid per-op allocations.
    final class PathIndexBufferCache {
        private var cache: [PathID: MTLBuffer] = [:]
        private let device: MTLDevice
    
        #if DEBUG
        /// Number of times a new index buffer was created (for testing)
        private(set) var debugCreatedBuffersCount: Int = 0
        #endif
    
        init(device: MTLDevice) {
            self.device = device
        }
    
        /// Gets or creates an index buffer for the given path.
        ///
        /// - Parameters:
        ///   - pathId: Path identifier
        ///   - indices: Index data (only used if buffer doesn't exist)
        /// - Returns: Cached or newly created MTLBuffer, or nil if creation fails
        func getOrCreate(for pathId: PathID, indices: [UInt16]) -> MTLBuffer? {
            // Check cache
            if let existing = cache[pathId] {
                return existing
            }
    
            // Create new buffer
            let byteCount = indices.count * MemoryLayout<UInt16>.stride
            guard byteCount > 0,
                  let newBuffer = device.makeBuffer(bytes: indices, length: byteCount, options: .storageModeShared) else {
                return nil
            }
    
            cache[pathId] = newBuffer
            #if DEBUG
            debugCreatedBuffersCount += 1
            #endif
            return newBuffer
        }
    
        /// Clears all cached buffers.
        func clear() {
            cache.removeAll()
        }
    
    ```

---

## 9) Stencil mask path (exists, but **UNREACHABLE in snapshot**)

Stencil-related pipeline state/shader code exists, but mask scopes are routed into the GPU-mask implementation (Section 6) by the `drawInternal` dispatcher.

### 9.1 Stencil pipeline + depth/stencil states

**Anchor**
  - `TVECore/Sources/TVECore/MetalRenderer/MetalRendererResources.swift:288-391`

    ```swift
    // MARK: - Stencil Pipeline Creation
    
    extension MetalRendererResources {
        private static func makeStencilCompositePipeline(
            device: MTLDevice,
            library: MTLLibrary,
            colorPixelFormat: MTLPixelFormat
        ) throws -> MTLRenderPipelineState {
            guard let vertexFunc = library.makeFunction(name: "quad_vertex") else {
                throw MetalRendererError.failedToCreatePipeline(reason: "quad_vertex not found")
            }
            guard let fragmentFunc = library.makeFunction(name: "quad_fragment") else {
                throw MetalRendererError.failedToCreatePipeline(reason: "quad_fragment not found")
            }
    
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunc
            descriptor.fragmentFunction = fragmentFunc
            descriptor.vertexDescriptor = makeVertexDescriptor()
            configureBlending(descriptor.colorAttachments[0], pixelFormat: colorPixelFormat)
            descriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
            descriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
    
            do {
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                let msg = "Stencil composite pipeline failed: \(error.localizedDescription)"
                throw MetalRendererError.failedToCreatePipeline(reason: msg)
            }
        }
    
        private static func makeMaskWritePipeline(
            device: MTLDevice,
            library: MTLLibrary
        ) throws -> MTLRenderPipelineState {
            guard let vertexFunc = library.makeFunction(name: "mask_vertex") else {
                throw MetalRendererError.failedToCreatePipeline(reason: "mask_vertex not found")
            }
            guard let fragmentFunc = library.makeFunction(name: "mask_fragment") else {
                throw MetalRendererError.failedToCreatePipeline(reason: "mask_fragment not found")
            }
    
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunc
            descriptor.fragmentFunction = fragmentFunc
            descriptor.vertexDescriptor = makeVertexDescriptor()
            // No color attachment - stencil only
            descriptor.colorAttachments[0].pixelFormat = .invalid
            descriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
            descriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
    
            do {
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                let msg = "Mask write pipeline failed: \(error.localizedDescription)"
                throw MetalRendererError.failedToCreatePipeline(reason: msg)
            }
        }
    
        private static func makeStencilWriteDepthStencilState(device: MTLDevice) throws -> MTLDepthStencilState {
            let descriptor = MTLDepthStencilDescriptor()
            descriptor.isDepthWriteEnabled = false
            descriptor.depthCompareFunction = .always
    
            // Front face stencil: write 0xFF where fragment passes (mask alpha > 0)
            let stencilDescriptor = MTLStencilDescriptor()
            stencilDescriptor.stencilCompareFunction = .always
            stencilDescriptor.stencilFailureOperation = .keep
            stencilDescriptor.depthFailureOperation = .keep
            stencilDescriptor.depthStencilPassOperation = .replace
            stencilDescriptor.readMask = 0xFF
            stencilDescriptor.writeMask = 0xFF
    
            descriptor.frontFaceStencil = stencilDescriptor
            descriptor.backFaceStencil = stencilDescriptor
    
            guard let state = device.makeDepthStencilState(descriptor: descriptor) else {
                throw MetalRendererError.failedToCreatePipeline(reason: "Stencil write state failed")
            }
            return state
        }
    
        private static func makeStencilTestDepthStencilState(device: MTLDevice) throws -> MTLDepthStencilState {
            let descriptor = MTLDepthStencilDescriptor()
            descriptor.isDepthWriteEnabled = false
            descriptor.depthCompareFunction = .always
    
            // Front face stencil: pass only where stencil == 0xFF
            let stencilDescriptor = MTLStencilDescriptor()
            stencilDescriptor.stencilCompareFunction = .equal
            stencilDescriptor.stencilFailureOperation = .keep
            stencilDescriptor.depthFailureOperation = .keep
            stencilDescriptor.depthStencilPassOperation = .keep
            stencilDescriptor.readMask = 0xFF
            stencilDescriptor.writeMask = 0x00
    
            descriptor.frontFaceStencil = stencilDescriptor
            descriptor.backFaceStencil = stencilDescriptor
    
            guard let state = device.makeDepthStencilState(descriptor: descriptor) else {
                throw MetalRendererError.failedToCreatePipeline(reason: "Stencil test state failed")
            }
            return state
        }
    ```

### 9.2 Stencil mask fragment uses discard threshold

**Anchor**
  - `TVECore/Sources/TVECore/MetalRenderer/Shaders/QuadShaders.metal:57-78`

    ```metal
    vertex MaskVertexOut mask_vertex(
        QuadVertexIn in [[stage_in]],
        constant QuadUniforms& uniforms [[buffer(1)]]
    ) {
        MaskVertexOut out;
        out.position = uniforms.mvp * float4(in.position, 0.0, 1.0);
        out.texCoord = in.texCoord;
        return out;
    }
    
    fragment void mask_fragment(
        MaskVertexOut in [[stage_in]],
        texture2d<float> maskTex [[texture(0)]],
        sampler samp [[sampler(0)]]
    ) {
        float alpha = maskTex.sample(samp, in.texCoord).r;
        // Discard fragments where mask alpha is zero
        if (alpha < 0.004) {
            discard_fragment();
        }
        // Fragment passes - stencil will be written via depth stencil state
    }
    ```

---

## 10) RenderCommand → GPU passes (reachable mapping)

| RenderCommand | Execution site | GPU pass type | Pipeline / shader entrypoints | Key textures |
|---|---|---:|---|---|
| beginGroup/endGroup | `drawInternal` scope parsing | — | — | — |
| pushTransform/popTransform | `ExecutionState.transformStack` | — | — | — |
| pushClipRect/popClipRect | `ExecutionState.clipStack` → `encoder.setScissorRect` | — | — | — |
| drawImage | `executeCommand` inside `renderSegment` | render | `quad_vertex` + `quad_fragment` | asset texture |
| drawShape | `executeCommand` inside `renderSegment` | render | `quad_vertex` + `quad_fragment` | CPU-raster BGRA from `ShapeCache` |
| drawStroke | `executeCommand` inside `renderSegment` | render | `quad_vertex` + `quad_fragment` | CPU-raster BGRA from `ShapeCache.strokeTexture` |
| beginMask…endMask | `renderMaskGroupScope` | render + compute + render | coverage: `coverage_vertex/coverage_fragment` → combine: `mask_combine_kernel` → composite: `masked_composite_*` | R8 coverage + R8 accum + offscreen color |
| beginMatte…endMatte | `renderMatteScope` | render(offscreen) + render(composite) | offscreen: normal segment renderer; composite: `matte_composite_*` | 2× offscreen BGRA |

