import XCTest
import Metal
@testable import TVECore

// MARK: - Metal Renderer Baseline Tests

final class MetalRendererBaselineTests: XCTestCase {
    var device: MTLDevice!
    var renderer: MetalRenderer!

    override func setUpWithError() throws {
        device = MTLCreateSystemDefaultDevice()
        try XCTSkipIf(device == nil, "Metal not available on this device")

        renderer = try MetalRenderer(
            device: device,
            colorPixelFormat: .bgra8Unorm,
            options: MetalRendererOptions(
                clearColor: .transparentBlack,
                enableWarningsForUnsupportedCommands: false
            )
        )
    }

    override func tearDown() {
        renderer = nil
        device = nil
    }

    // MARK: - Test 1: DrawImage writes non-zero pixels

    func testDrawImage_writesNonZeroPixels() throws {
        let provider = InMemoryTextureProvider()
        let whiteTex = try XCTUnwrap(
            createSolidColorTexture(device: device, color: (255, 255, 255, 255), size: 1)
        )
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

        // Sample center pixel
        let pixel = readPixel(from: result, at: (16, 16))
        XCTAssertGreaterThan(pixel.a, 0, "Expected non-zero alpha at center")
    }

    // MARK: - Test 2: Opacity zero draws nothing

    func testOpacityZero_drawsNothing() throws {
        let provider = InMemoryTextureProvider()
        let whiteTex = try XCTUnwrap(
            createSolidColorTexture(device: device, color: (255, 255, 255, 255), size: 1)
        )
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

        // Sample center pixel
        let pixel = readPixel(from: result, at: (16, 16))
        XCTAssertEqual(pixel.a, 0, "Expected zero alpha with opacity 0")
    }

    // MARK: - Test 3: Transform translation moves quad

    func testTransformTranslation_movesQuad() throws {
        let provider = InMemoryTextureProvider()
        // Create 8x8 white texture
        let whiteTex = try XCTUnwrap(
            createSolidColorTexture(device: device, color: (255, 255, 255, 255), size: 8)
        )
        provider.register(whiteTex, for: "test")

        // Translate quad to right half (x=16)
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

        // Left side (x=4) should be empty
        let leftPixel = readPixel(from: result, at: (4, 4))
        XCTAssertEqual(leftPixel.a, 0, "Left side should be empty")

        // Right side (x=20) should have content
        let rightPixel = readPixel(from: result, at: (20, 4))
        XCTAssertGreaterThan(rightPixel.a, 0, "Right side should have content")
    }

    // MARK: - Test 4: ClipRect scissors drawing

    func testClipRect_scissorsDrawing() throws {
        let provider = InMemoryTextureProvider()
        // Create 32x32 white texture (fills entire viewport)
        let whiteTex = try XCTUnwrap(
            createSolidColorTexture(device: device, color: (255, 255, 255, 255), size: 32)
        )
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

        // Inside clip (4,4)
        let insidePixel = readPixel(from: result, at: (4, 4))
        XCTAssertGreaterThan(insidePixel.a, 0, "Inside clip should have content")

        // Outside clip (16,16)
        let outsidePixel = readPixel(from: result, at: (16, 16))
        XCTAssertEqual(outsidePixel.a, 0, "Outside clip should be empty")
    }

    // MARK: - Test 5: Determinism - same inputs = same pixels

    func testDeterminism_sameInputsSamePixels() throws {
        let provider = InMemoryTextureProvider()
        let colorTex = try XCTUnwrap(
            createSolidColorTexture(device: device, color: (128, 64, 32, 255), size: 4)
        )
        provider.register(colorTex, for: "test")

        let transform = Matrix2D.translation(x: 5, y: 3)
            .concatenating(.scale(x: 2, y: 2))

        let commands: [RenderCommand] = [
            .beginGroup(name: "test"),
            .pushTransform(transform),
            .drawImage(assetId: "test", opacity: 0.75),
            .popTransform,
            .endGroup
        ]

        // First render
        let result1 = try renderer.drawOffscreen(
            commands: commands,
            device: device,
            sizePx: (32, 32),
            animSize: SizeD(width: 32, height: 32),
            textureProvider: provider
        )

        // Second render
        let result2 = try renderer.drawOffscreen(
            commands: commands,
            device: device,
            sizePx: (32, 32),
            animSize: SizeD(width: 32, height: 32),
            textureProvider: provider
        )

        // Compare all pixels
        let bytes1 = readAllPixels(from: result1, size: 32)
        let bytes2 = readAllPixels(from: result2, size: 32)

        XCTAssertEqual(bytes1, bytes2, "Two renders should produce identical pixels")
    }

    // MARK: - Test 6: Invalid pop throws error

    func testStacksBalanced_invalidPopThrows() throws {
        let provider = InMemoryTextureProvider()

        let commands: [RenderCommand] = [
            .popTransform // Invalid: nothing to pop
        ]

        XCTAssertThrowsError(
            try renderer.drawOffscreen(
                commands: commands,
                device: device,
                sizePx: (32, 32),
                animSize: SizeD(width: 32, height: 32),
                textureProvider: provider
            )
        ) { error in
            guard let metalError = error as? MetalRendererError,
                  case .invalidCommandStack = metalError else {
                XCTFail("Expected MetalRendererError.invalidCommandStack, got \(error)")
                return
            }
        }
    }

    // MARK: - Test 7: Masks are no-op but balanced

    func testMasksNoOp_balanceChecked() throws {
        let provider = InMemoryTextureProvider()
        let whiteTex = try XCTUnwrap(
            createSolidColorTexture(device: device, color: (255, 255, 255, 255), size: 8)
        )
        provider.register(whiteTex, for: "test")

        // Commands with mask (should be no-op but balanced)
        let commands: [RenderCommand] = [
            .beginGroup(name: "test"),
            .pushTransform(.identity),
            .beginMaskAdd(path: BezierPath(vertices: [], inTangents: [], outTangents: [], closed: true)),
            .drawImage(assetId: "test", opacity: 1.0),
            .endMask,
            .popTransform,
            .endGroup
        ]

        // Should not throw - masks are ignored but balance is checked
        let result = try renderer.drawOffscreen(
            commands: commands,
            device: device,
            sizePx: (32, 32),
            animSize: SizeD(width: 32, height: 32),
            textureProvider: provider
        )

        // Image should still be rendered (mask is no-op)
        let pixel = readPixel(from: result, at: (4, 4))
        XCTAssertGreaterThan(pixel.a, 0, "Image should be rendered (mask is no-op)")
    }

    // MARK: - Test 8: Unbalanced mask throws

    func testUnbalancedMask_throws() throws {
        let provider = InMemoryTextureProvider()

        let commands: [RenderCommand] = [
            .endMask // Invalid: no matching begin
        ]

        XCTAssertThrowsError(
            try renderer.drawOffscreen(
                commands: commands,
                device: device,
                sizePx: (32, 32),
                animSize: SizeD(width: 32, height: 32),
                textureProvider: provider
            )
        ) { error in
            guard let metalError = error as? MetalRendererError,
                  case .invalidCommandStack = metalError else {
                XCTFail("Expected MetalRendererError.invalidCommandStack, got \(error)")
                return
            }
        }
    }
}

// MARK: - Viewport to NDC Mapping Tests

final class ViewportToNDCMappingTests: XCTestCase {

    func testViewportToNDC_topLeftMapsToTopLeftNDC() {
        // Viewport (0,0) should map to NDC (-1, +1) (top-left in Metal)
        let matrix = GeometryMapping.viewportToNDC(width: 100, height: 100)
        let point = matrix.apply(to: Vec2D(x: 0, y: 0))

        XCTAssertEqual(point.x, -1.0, accuracy: 1e-6, "Top-left X should be -1")
        XCTAssertEqual(point.y, 1.0, accuracy: 1e-6, "Top-left Y should be +1")
    }

    func testViewportToNDC_bottomRightMapsToBottomRightNDC() {
        // Viewport (W, H) should map to NDC (+1, -1) (bottom-right in Metal)
        let matrix = GeometryMapping.viewportToNDC(width: 100, height: 100)
        let point = matrix.apply(to: Vec2D(x: 100, y: 100))

        XCTAssertEqual(point.x, 1.0, accuracy: 1e-6, "Bottom-right X should be +1")
        XCTAssertEqual(point.y, -1.0, accuracy: 1e-6, "Bottom-right Y should be -1")
    }

    func testViewportToNDC_centerMapsToOrigin() {
        // Viewport center (W/2, H/2) should map to NDC (0, 0)
        let matrix = GeometryMapping.viewportToNDC(width: 100, height: 100)
        let point = matrix.apply(to: Vec2D(x: 50, y: 50))

        XCTAssertEqual(point.x, 0.0, accuracy: 1e-6, "Center X should be 0")
        XCTAssertEqual(point.y, 0.0, accuracy: 1e-6, "Center Y should be 0")
    }

    func testViewportToNDC_zeroSize_returnsIdentity() {
        let matrix = GeometryMapping.viewportToNDC(width: 0, height: 0)
        XCTAssertEqual(matrix, .identity)
    }
}

// MARK: - Test Helpers

extension MetalRendererBaselineTests {
    /// Creates a solid color texture for testing.
    func createSolidColorTexture(
        device: MTLDevice,
        color: (r: UInt8, g: UInt8, b: UInt8, a: UInt8),
        size: Int
    ) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: size,
            height: size,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        // Fill with solid color (BGRA format)
        let bytesPerPixel = 4
        let bytesPerRow = size * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: size * size * bytesPerPixel)

        for i in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            pixels[i] = color.b     // Blue
            pixels[i + 1] = color.g // Green
            pixels[i + 2] = color.r // Red
            pixels[i + 3] = color.a // Alpha
        }

        texture.replace(
            region: MTLRegionMake2D(0, 0, size, size),
            mipmapLevel: 0,
            withBytes: &pixels,
            bytesPerRow: bytesPerRow
        )

        return texture
    }

    /// Reads a single pixel from a texture (BGRA format).
    func readPixel(
        from texture: MTLTexture,
        at point: (x: Int, y: Int)
    ) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        var pixel: [UInt8] = [0, 0, 0, 0]
        texture.getBytes(
            &pixel,
            bytesPerRow: 4,
            from: MTLRegionMake2D(point.x, point.y, 1, 1),
            mipmapLevel: 0
        )
        // BGRA -> RGBA
        return (pixel[2], pixel[1], pixel[0], pixel[3])
    }

    /// Reads all pixels from a square texture.
    func readAllPixels(from texture: MTLTexture, size: Int) -> [UInt8] {
        let bytesPerRow = size * 4
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        texture.getBytes(
            &bytes,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, size, size),
            mipmapLevel: 0
        )
        return bytes
    }
}
