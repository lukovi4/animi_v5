# PR7 Implementation Plan — Metal Baseline Executor

## Overview

Create `MetalRenderer` that executes `RenderCommand` list from `AnimIR.renderCommands(frameIndex:)` and renders textured quads to Metal drawable.

**Goal:** "Draws simple frame without masks/mattes" + "Same frameIndex → same pixels (determinism)"

---

## 1. New Files Structure

```
Sources/TVECore/MetalRenderer/
├── MetalRenderer.swift              # Main class + public API
├── MetalRendererResources.swift     # Pipeline, buffers, samplers
├── MetalRenderer+Execute.swift      # Command execution logic
├── TextureProvider.swift            # Protocol + ScenePackageTextureProvider
└── Shaders/
    └── QuadShaders.metal            # Vertex + fragment shaders
```

---

## 2. Public API

### 2.1 TextureProvider Protocol

```swift
// TextureProvider.swift

public protocol TextureProvider {
    func texture(for assetId: String) -> MTLTexture?
}

public final class ScenePackageTextureProvider: TextureProvider {
    private let device: MTLDevice
    private let imagesRootURL: URL
    private let assetIndex: AssetIndexIR
    private var cache: [String: MTLTexture] = [:]
    private let loader: MTKTextureLoader

    public init(device: MTLDevice, imagesRootURL: URL, assetIndex: AssetIndexIR)
    public func texture(for assetId: String) -> MTLTexture?
    public func preloadAll() throws  // Optional: preload all textures
}
```

**Notes:**
- Uses `MTKTextureLoader` with `SRGB: false` for linear sampling
- Premultiplied alpha by default (MTKTextureLoader standard behavior)
- Cache keyed by assetId
- Returns `nil` if asset not found or load fails

### 2.2 RenderTarget

```swift
// MetalRenderer.swift

public struct RenderTarget: Sendable {
    public let texture: MTLTexture
    public let sizePx: (width: Int, height: Int)
    public let drawableScale: Double  // For MTKView: UIScreen.main.scale; tests: 1.0
    public let animSize: SizeD        // Animation w/h for contain mapping

    public init(texture: MTLTexture, drawableScale: Double, animSize: SizeD)
}
```

### 2.3 MetalRendererError

```swift
// MetalRenderer.swift

public enum MetalRendererError: Error, Sendable {
    case noTextureForAsset(assetId: String)
    case failedToCreateCommandBuffer
    case failedToCreatePipeline(reason: String)
    case invalidCommandStack(reason: String)
}
```

### 2.4 MetalRenderer

```swift
// MetalRenderer.swift

public final class MetalRenderer {
    public struct Options: Sendable {
        public var clearColorRGBA: (Double, Double, Double, Double)
        public var enableWarningsForUnsupportedCommands: Bool

        public init(
            clearColorRGBA: (Double, Double, Double, Double) = (0, 0, 0, 0),
            enableWarningsForUnsupportedCommands: Bool = true
        )
    }

    public init(device: MTLDevice, colorPixelFormat: MTLPixelFormat, options: Options = .init()) throws

    /// On-screen rendering (MTKView drawable)
    public func draw(
        commands: [RenderCommand],
        target: RenderTarget,
        textureProvider: TextureProvider,
        commandQueue: MTLCommandQueue
    ) throws

    /// Offscreen rendering (for tests)
    public func drawOffscreen(
        commands: [RenderCommand],
        device: MTLDevice,
        sizePx: (width: Int, height: Int),
        animSize: SizeD,
        textureProvider: TextureProvider
    ) throws -> MTLTexture
}
```

---

## 3. Internal Architecture

### 3.1 MetalRendererResources

```swift
// MetalRendererResources.swift

struct QuadVertex {
    var position: SIMD2<Float>  // Quad corner (0,0), (1,0), (0,1), (1,1)
    var texCoord: SIMD2<Float>  // UV
}

struct QuadUniforms {
    var mvp: simd_float4x4      // Model-View-Projection
    var opacity: Float
    var _padding: SIMD3<Float>  // Alignment
}

final class MetalRendererResources {
    let pipelineState: MTLRenderPipelineState
    let samplerState: MTLSamplerState
    let quadVertexBuffer: MTLBuffer  // Unit quad [0..1] x [0..1]
    let quadIndexBuffer: MTLBuffer   // 6 indices for 2 triangles

    init(device: MTLDevice, colorPixelFormat: MTLPixelFormat) throws
}
```

### 3.2 Execution Context

```swift
// MetalRenderer+Execute.swift

private struct ExecutionContext {
    var transformStack: [Matrix2D] = [.identity]
    var clipStack: [MTLScissorRect] = []

    // Balance counters
    var groupDepth: Int = 0
    var maskDepth: Int = 0
    var matteDepth: Int = 0

    // Warning tracking (avoid spam)
    var didWarnMasks: Bool = false
    var didWarnMattes: Bool = false

    // Current state
    var currentTransform: Matrix2D { transformStack.last ?? .identity }
    var currentScissor: MTLScissorRect? { clipStack.last }

    mutating func pushTransform(_ m: Matrix2D)
    mutating func popTransform() throws
    mutating func pushClipRect(_ rect: RectD, targetSize: (Int, Int))
    mutating func popClipRect()
}
```

### 3.3 Command Execution

```swift
// MetalRenderer+Execute.swift

extension MetalRenderer {
    func drawInternal(
        commands: [RenderCommand],
        renderPassDescriptor: MTLRenderPassDescriptor,
        target: RenderTarget,
        textureProvider: TextureProvider,
        commandBuffer: MTLCommandBuffer
    ) throws {
        // 1. Create encoder
        // 2. Initialize context with full scissor
        // 3. Compute mapping matrices:
        //    - M_animToViewport = GeometryMapping.animToInputContain(animSize:, inputRect: fullViewport)
        //    - M_viewportToNDC = viewport-to-NDC transform
        // 4. For each command:
        //    - execute(command, encoder, context, ...)
        // 5. Validate balanced stacks
        // 6. End encoding
    }
}
```

---

## 4. Geometry & Math

### 4.1 Coordinate Spaces

```
Anim Space (0..animW, 0..animH)
    ↓ M_animToViewport (contain + center)
Viewport Space (0..targetW, 0..targetH)
    ↓ M_viewportToNDC
NDC (-1..1, -1..1)
```

### 4.2 Matrix Calculations

```swift
// For DrawImage:
// 1. Get quad size from texture (texture.width, texture.height)
// 2. quadLocalMatrix = scale to quad size
// 3. M_final = M_viewportToNDC * M_animToViewport * currentTransform * quadLocalMatrix
// 4. Pass M_final as MVP uniform
```

### 4.3 Viewport-to-NDC Matrix

```swift
// Metal NDC: X left-to-right (-1..1), Y bottom-to-top (-1..1)
// Viewport: X left-to-right (0..W), Y top-to-bottom (0..H)
// Formula:
//   ndcX = (vpX / W) * 2 - 1
//   ndcY = 1 - (vpY / H) * 2  // Flip Y
static func viewportToNDC(width: Double, height: Double) -> Matrix2D {
    Matrix2D(
        a: 2.0 / width,
        b: 0,
        c: 0,
        d: -2.0 / height,  // Flip Y
        tx: -1.0,
        ty: 1.0
    )
}
```

### 4.4 Scissor Rect Calculation

```swift
// ClipRect comes in target-space (after M_animToViewport applied by caller)
// Metal scissor: origin at top-left, Y down
func toScissorRect(_ rect: RectD, targetSize: (Int, Int)) -> MTLScissorRect {
    // Clamp to target bounds
    let x = max(0, min(Int(rect.x), targetSize.0))
    let y = max(0, min(Int(rect.y), targetSize.1))
    let w = max(0, min(Int(rect.width), targetSize.0 - x))
    let h = max(0, min(Int(rect.height), targetSize.1 - y))
    return MTLScissorRect(x: x, y: y, width: w, height: h)
}

// On push: intersect with current scissor
// On pop: restore previous
```

---

## 5. Shaders

### 5.1 QuadShaders.metal

```metal
#include <metal_stdlib>
using namespace metal;

struct QuadVertex {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct QuadUniforms {
    float4x4 mvp;
    float opacity;
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    float opacity;
};

vertex VertexOut quad_vertex(
    QuadVertex in [[stage_in]],
    constant QuadUniforms& uniforms [[buffer(1)]]
) {
    VertexOut out;
    out.position = uniforms.mvp * float4(in.position, 0.0, 1.0);
    out.texCoord = in.texCoord;
    out.opacity = uniforms.opacity;
    return out;
}

fragment float4 quad_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    sampler samp [[sampler(0)]]
) {
    float4 color = tex.sample(samp, in.texCoord);
    // Premultiplied alpha: multiply all by opacity
    return color * in.opacity;
}
```

### 5.2 Pipeline State

```swift
// Premultiplied alpha blending
colorAttachment.isBlendingEnabled = true
colorAttachment.rgbBlendOperation = .add
colorAttachment.alphaBlendOperation = .add
colorAttachment.sourceRGBBlendFactor = .one
colorAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
colorAttachment.sourceAlphaBlendFactor = .one
colorAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
```

---

## 6. Command Handling

| Command | Action |
|---------|--------|
| `beginGroup(name)` | `groupDepth += 1` (no-op for rendering) |
| `endGroup` | `groupDepth -= 1`; error if < 0 |
| `pushTransform(m)` | `current = current.concatenating(m)`; push |
| `popTransform` | Pop; error if stack would be empty |
| `pushClipRect(rect)` | Intersect with current; set scissor |
| `popClipRect` | Restore previous scissor |
| `drawImage(assetId, opacity)` | Draw textured quad |
| `beginMaskAdd` | `maskDepth += 1`; warn once; no-op |
| `endMask` | `maskDepth -= 1`; error if < 0 |
| `beginMatteAlpha/Inverted` | `matteDepth += 1`; warn once; no-op |
| `endMatte` | `matteDepth -= 1`; error if < 0 |

---

## 7. Demo VC Integration

### 7.1 Changes to PlayerViewController

```swift
// Add properties
private var animIR: AnimIR?
private var renderer: MetalRenderer?
private var textureProvider: ScenePackageTextureProvider?
private var currentFrameIndex: Int = 0

// Add UI
private lazy var frameSlider: UISlider = { ... }()
private lazy var frameLabel: UILabel = { ... }()
private lazy var playPauseButton: UIButton = { ... }()
private var displayLink: CADisplayLink?
private var isPlaying: Bool = false
```

### 7.2 Load Flow

```swift
private func setupMetalRenderer() throws {
    guard let device = metalView.device else { return }

    renderer = try MetalRenderer(
        device: device,
        colorPixelFormat: metalView.colorPixelFormat
    )
}

private func loadAnimationForBaseline() throws {
    guard let package = currentPackage,
          let loaded = loadedAnimations,
          let lottie = loaded.lottieByAnimRef["anim-1.json"],
          let assetIndex = loaded.assetIndexByAnimRef["anim-1.json"],
          let imagesURL = package.imagesRootURL
    else { return }

    let compiler = AnimIRCompiler()
    let bindingKey = package.scene.mediaBlocks.first?.input.bindingKey ?? "media"

    animIR = try compiler.compile(
        lottie: lottie,
        animRef: "anim-1.json",
        bindingKey: bindingKey,
        assetIndex: assetIndex
    )

    guard let device = metalView.device else { return }
    textureProvider = ScenePackageTextureProvider(
        device: device,
        imagesRootURL: imagesURL,
        assetIndex: animIR!.assets
    )

    // Configure slider
    frameSlider.minimumValue = 0
    frameSlider.maximumValue = Float(animIR!.meta.frameCount - 1)
    frameSlider.value = 0
    currentFrameIndex = 0
}
```

### 7.3 Draw Implementation

```swift
func draw(in view: MTKView) {
    guard let drawable = view.currentDrawable,
          let descriptor = view.currentRenderPassDescriptor,
          let commandQueue = commandQueue,
          let commandBuffer = commandQueue.makeCommandBuffer(),
          let renderer = renderer,
          var animIR = animIR,
          let textureProvider = textureProvider
    else {
        // Fallback: just clear
        ...
        return
    }

    let commands = animIR.renderCommands(frameIndex: currentFrameIndex)

    let target = RenderTarget(
        texture: drawable.texture,
        drawableScale: Double(view.contentScaleFactor),
        animSize: animIR.meta.size
    )

    do {
        try renderer.draw(
            commands: commands,
            target: target,
            textureProvider: textureProvider,
            commandQueue: commandQueue
        )
    } catch {
        log("Render error: \(error)")
    }

    commandBuffer.present(drawable)
    commandBuffer.commit()
}
```

### 7.4 Playback Controls

```swift
@objc private func playPauseTapped() {
    isPlaying.toggle()
    playPauseButton.setTitle(isPlaying ? "Pause" : "Play", for: .normal)

    if isPlaying {
        startDisplayLink()
    } else {
        stopDisplayLink()
    }
}

private func startDisplayLink() {
    displayLink = CADisplayLink(target: self, selector: #selector(displayLinkFired))
    displayLink?.preferredFrameRateRange = CAFrameRateRange(
        minimum: 30, maximum: Float(animIR?.meta.fps ?? 30), __preferred: Float(animIR?.meta.fps ?? 30)
    )
    displayLink?.add(to: .main, forMode: .common)
}

@objc private func displayLinkFired() {
    guard let animIR = animIR else { return }
    currentFrameIndex = (currentFrameIndex + 1) % animIR.meta.frameCount
    frameSlider.value = Float(currentFrameIndex)
    updateFrameLabel()
    metalView.setNeedsDisplay()
}
```

---

## 8. Unit Tests

File: `Tests/TVECoreTests/MetalRendererBaselineTests.swift`

### 8.1 Test Helper

```swift
final class InMemoryTextureProvider: TextureProvider {
    private var textures: [String: MTLTexture] = [:]

    func register(_ texture: MTLTexture, for assetId: String) {
        textures[assetId] = texture
    }

    func texture(for assetId: String) -> MTLTexture? {
        textures[assetId]
    }
}

extension XCTestCase {
    func createSolidColorTexture(
        device: MTLDevice,
        color: (r: UInt8, g: UInt8, b: UInt8, a: UInt8),
        size: Int = 1
    ) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: size,
            height: size,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]

        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = size * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: size * size * bytesPerPixel)
        for i in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            pixels[i] = color.r
            pixels[i+1] = color.g
            pixels[i+2] = color.b
            pixels[i+3] = color.a
        }

        texture.replace(
            region: MTLRegionMake2D(0, 0, size, size),
            mipmapLevel: 0,
            withBytes: &pixels,
            bytesPerRow: bytesPerRow
        )

        return texture
    }

    func readPixel(from texture: MTLTexture, at point: (x: Int, y: Int)) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        var pixel: [UInt8] = [0, 0, 0, 0]
        texture.getBytes(
            &pixel,
            bytesPerRow: 4,
            from: MTLRegionMake2D(point.x, point.y, 1, 1),
            mipmapLevel: 0
        )
        return (pixel[0], pixel[1], pixel[2], pixel[3])
    }
}
```

### 8.2 Tests

```swift
final class MetalRendererBaselineTests: XCTestCase {
    var device: MTLDevice!
    var renderer: MetalRenderer!

    override func setUpWithError() throws {
        device = MTLCreateSystemDefaultDevice()
        try XCTSkipIf(device == nil, "Metal not available")
        renderer = try MetalRenderer(device: device, colorPixelFormat: .bgra8Unorm)
    }

    // 1. DrawImage writes non-zero pixels
    func testDrawImage_writesNonZeroPixels() throws {
        let provider = InMemoryTextureProvider()
        let whiteTex = try XCTUnwrap(createSolidColorTexture(device: device, color: (255, 255, 255, 255)))
        provider.register(whiteTex, for: "test")

        let commands: [RenderCommand] = [
            .beginGroup(name: "test"),
            .pushTransform(.identity),
            .drawImage(assetId: "test", opacity: 1.0),
            .popTransform,
            .endGroup
        ]

        let result = try renderer.drawOffscreen(
            commands: commands,
            device: device,
            sizePx: (32, 32),
            animSize: SizeD(width: 1, height: 1),
            textureProvider: provider
        )

        let pixel = readPixel(from: result, at: (16, 16))
        XCTAssertGreaterThan(pixel.a, 0, "Expected non-zero alpha at center")
    }

    // 2. Opacity zero draws nothing
    func testOpacityZero_drawsNothing() throws {
        let provider = InMemoryTextureProvider()
        let whiteTex = try XCTUnwrap(createSolidColorTexture(device: device, color: (255, 255, 255, 255)))
        provider.register(whiteTex, for: "test")

        let commands: [RenderCommand] = [
            .beginGroup(name: "test"),
            .pushTransform(.identity),
            .drawImage(assetId: "test", opacity: 0.0),
            .popTransform,
            .endGroup
        ]

        let result = try renderer.drawOffscreen(
            commands: commands,
            device: device,
            sizePx: (32, 32),
            animSize: SizeD(width: 1, height: 1),
            textureProvider: provider
        )

        let pixel = readPixel(from: result, at: (16, 16))
        XCTAssertEqual(pixel.a, 0, "Expected zero alpha with opacity 0")
    }

    // 3. Transform translation moves quad
    func testTransformTranslation_movesQuad() throws {
        let provider = InMemoryTextureProvider()
        let whiteTex = try XCTUnwrap(createSolidColorTexture(device: device, color: (255, 255, 255, 255), size: 8))
        provider.register(whiteTex, for: "test")

        // Translate quad to right half
        let translateRight = Matrix2D.translation(x: 16, y: 0)

        let commands: [RenderCommand] = [
            .beginGroup(name: "test"),
            .pushTransform(translateRight),
            .drawImage(assetId: "test", opacity: 1.0),
            .popTransform,
            .endGroup
        ]

        let result = try renderer.drawOffscreen(
            commands: commands,
            device: device,
            sizePx: (32, 32),
            animSize: SizeD(width: 32, height: 32),
            textureProvider: provider
        )

        // Left side should be empty
        let leftPixel = readPixel(from: result, at: (4, 16))
        XCTAssertEqual(leftPixel.a, 0, "Left should be empty")

        // Right side should have content
        let rightPixel = readPixel(from: result, at: (20, 16))
        XCTAssertGreaterThan(rightPixel.a, 0, "Right should have content")
    }

    // 4. ClipRect scissors drawing
    func testClipRect_scissorsDrawing() throws {
        let provider = InMemoryTextureProvider()
        let whiteTex = try XCTUnwrap(createSolidColorTexture(device: device, color: (255, 255, 255, 255), size: 32))
        provider.register(whiteTex, for: "test")

        // Clip to top-left 8x8 region
        let clipRect = RectD(x: 0, y: 0, width: 8, height: 8)

        let commands: [RenderCommand] = [
            .beginGroup(name: "test"),
            .pushClipRect(clipRect),
            .pushTransform(.identity),
            .drawImage(assetId: "test", opacity: 1.0),
            .popTransform,
            .popClipRect,
            .endGroup
        ]

        let result = try renderer.drawOffscreen(
            commands: commands,
            device: device,
            sizePx: (32, 32),
            animSize: SizeD(width: 32, height: 32),
            textureProvider: provider
        )

        // Inside clip
        let insidePixel = readPixel(from: result, at: (4, 4))
        XCTAssertGreaterThan(insidePixel.a, 0, "Inside clip should have content")

        // Outside clip
        let outsidePixel = readPixel(from: result, at: (16, 16))
        XCTAssertEqual(outsidePixel.a, 0, "Outside clip should be empty")
    }

    // 5. Determinism: same inputs = same pixels
    func testDeterminism_sameInputsSamePixels() throws {
        let provider = InMemoryTextureProvider()
        let whiteTex = try XCTUnwrap(createSolidColorTexture(device: device, color: (128, 64, 32, 255), size: 4))
        provider.register(whiteTex, for: "test")

        let transform = Matrix2D.translation(x: 5, y: 3)
            .concatenating(.scale(x: 2, y: 2))

        let commands: [RenderCommand] = [
            .beginGroup(name: "test"),
            .pushTransform(transform),
            .drawImage(assetId: "test", opacity: 0.75),
            .popTransform,
            .endGroup
        ]

        let result1 = try renderer.drawOffscreen(
            commands: commands,
            device: device,
            sizePx: (32, 32),
            animSize: SizeD(width: 32, height: 32),
            textureProvider: provider
        )

        let result2 = try renderer.drawOffscreen(
            commands: commands,
            device: device,
            sizePx: (32, 32),
            animSize: SizeD(width: 32, height: 32),
            textureProvider: provider
        )

        // Compare all pixels
        let size = 32 * 32 * 4
        var bytes1 = [UInt8](repeating: 0, count: size)
        var bytes2 = [UInt8](repeating: 0, count: size)

        result1.getBytes(&bytes1, bytesPerRow: 32 * 4, from: MTLRegionMake2D(0, 0, 32, 32), mipmapLevel: 0)
        result2.getBytes(&bytes2, bytesPerRow: 32 * 4, from: MTLRegionMake2D(0, 0, 32, 32), mipmapLevel: 0)

        XCTAssertEqual(bytes1, bytes2, "Two renders should produce identical pixels")
    }

    // 6. Invalid pop throws error
    func testStacksBalanced_invalidPopThrows() throws {
        let provider = InMemoryTextureProvider()

        let commands: [RenderCommand] = [
            .popTransform  // Invalid: nothing to pop
        ]

        XCTAssertThrowsError(try renderer.drawOffscreen(
            commands: commands,
            device: device,
            sizePx: (32, 32),
            animSize: SizeD(width: 32, height: 32),
            textureProvider: provider
        )) { error in
            guard case MetalRendererError.invalidCommandStack = error else {
                XCTFail("Expected invalidCommandStack error")
                return
            }
        }
    }
}
```

---

## 9. Implementation Order

1. **Shaders + Pipeline** (`QuadShaders.metal`, `MetalRendererResources.swift`)
   - Vertex/fragment shaders
   - Pipeline state with premultiplied alpha
   - Sampler state
   - Unit quad vertex/index buffers

2. **MetalRenderer Core** (`MetalRenderer.swift`)
   - `RenderTarget`, `Options`, `MetalRendererError`
   - `init(device:colorPixelFormat:options:)`
   - Basic structure

3. **TextureProvider** (`TextureProvider.swift`)
   - Protocol definition
   - `ScenePackageTextureProvider` with MTKTextureLoader
   - Cache implementation

4. **Command Execution** (`MetalRenderer+Execute.swift`)
   - `ExecutionContext` with transform/clip stacks
   - `drawInternal(...)` — main execution loop
   - Individual command handlers
   - Transform stack: `current.concatenating(m)`
   - Scissor stack: intersect + MTLScissorRect

5. **Geometry Mapping**
   - Add `viewportToNDC(width:height:)` to `GeometryMapping`
   - MVP assembly: `M_viewportToNDC * M_animToViewport * stackTransform * quadScale`

6. **Offscreen Path**
   - `drawOffscreen(...)` — creates texture + calls `drawInternal`
   - Readback helper for tests

7. **Unit Tests** (`MetalRendererBaselineTests.swift`)
   - 6 tests as specified

8. **Demo VC Integration** (`PlayerViewController.swift`)
   - Frame slider + label
   - Play/Pause button + CADisplayLink
   - Load anim-1.json → AnimIR → render

---

## 10. DoD Checklist

- [ ] Draws textured quad in MTKView (demo working)
- [ ] Transform stack works (rotation/scale/anchor visually change)
- [ ] PushClipRect = scissor in target-space
- [ ] Masks/mattes commands = no-op (no crash, balanced)
- [ ] Determinism: same input → same pixels (unit test)
- [ ] All tests green
- [ ] SwiftLint clean

---

## 11. Files Modified

### New Files
- `Sources/TVECore/MetalRenderer/MetalRenderer.swift`
- `Sources/TVECore/MetalRenderer/MetalRendererResources.swift`
- `Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift`
- `Sources/TVECore/MetalRenderer/TextureProvider.swift`
- `Sources/TVECore/MetalRenderer/Shaders/QuadShaders.metal`
- `Tests/TVECoreTests/MetalRendererBaselineTests.swift`

### Modified Files
- `Sources/TVECore/Math/GeometryMapping.swift` — add `viewportToNDC`
- `AnimiApp/Sources/Player/PlayerViewController.swift` — demo integration
