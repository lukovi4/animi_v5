import XCTest
import Metal
@testable import TVECore

struct TestColor { let red, green, blue, alpha: UInt8 }
struct TestPoint { let xPos, yPos: Int }

final class MetalRendererBaselineTests: XCTestCase {
    var device: MTLDevice!
    var renderer: MetalRenderer!

    override func setUpWithError() throws {
        device = MTLCreateSystemDefaultDevice()
        try XCTSkipIf(device == nil, "Metal not available")
        renderer = try MetalRenderer(
            device: device,
            colorPixelFormat: .bgra8Unorm,
            options: MetalRendererOptions(clearColor: .transparentBlack)
        )
    }

    override func tearDown() { renderer = nil; device = nil }

    func testDrawImage_writesNonZeroPixels() throws {
        let provider = InMemoryTextureProvider()
        let col = TestColor(red: 255, green: 255, blue: 255, alpha: 255)
        let tex = try XCTUnwrap(createSolidColorTexture(device: device, color: col, size: 1))
        provider.register(tex, for: "test")
        let cmds: [RenderCommand] = [
            .beginGroup(name: "test"), .pushTransform(.identity),
            .drawImage(assetId: "test", opacity: 1.0), .popTransform, .endGroup
        ]
        let result = try renderer.drawOffscreen(
            commands: cmds, device: device, sizePx: (32, 32),
            animSize: SizeD(width: 1, height: 1), textureProvider: provider,
            pathRegistry: PathRegistry()
        )
        let pixel = readPixel(from: result, at: TestPoint(xPos: 16, yPos: 16))
        XCTAssertGreaterThan(pixel.alpha, 0, "Expected non-zero alpha")
    }

    func testOpacityZero_drawsNothing() throws {
        let provider = InMemoryTextureProvider()
        let col = TestColor(red: 255, green: 255, blue: 255, alpha: 255)
        let tex = try XCTUnwrap(createSolidColorTexture(device: device, color: col, size: 1))
        provider.register(tex, for: "test")
        let cmds: [RenderCommand] = [
            .beginGroup(name: "test"), .pushTransform(.identity),
            .drawImage(assetId: "test", opacity: 0.0), .popTransform, .endGroup
        ]
        let result = try renderer.drawOffscreen(
            commands: cmds, device: device, sizePx: (32, 32),
            animSize: SizeD(width: 1, height: 1), textureProvider: provider,
            pathRegistry: PathRegistry()
        )
        let pixel = readPixel(from: result, at: TestPoint(xPos: 16, yPos: 16))
        XCTAssertEqual(pixel.alpha, 0, "Expected zero alpha")
    }

    func testTransformTranslation_movesQuad() throws {
        let provider = InMemoryTextureProvider()
        let col = TestColor(red: 255, green: 255, blue: 255, alpha: 255)
        let tex = try XCTUnwrap(createSolidColorTexture(device: device, color: col, size: 8))
        provider.register(tex, for: "test")
        let cmds: [RenderCommand] = [
            .beginGroup(name: "test"), .pushTransform(.translation(x: 16, y: 0)),
            .drawImage(assetId: "test", opacity: 1.0), .popTransform, .endGroup
        ]
        let result = try renderer.drawOffscreen(
            commands: cmds, device: device, sizePx: (32, 32),
            animSize: SizeD(width: 32, height: 32), textureProvider: provider,
            pathRegistry: PathRegistry()
        )
        let leftPixel = readPixel(from: result, at: TestPoint(xPos: 4, yPos: 4))
        XCTAssertEqual(leftPixel.alpha, 0, "Left side should be empty")
        let rightPixel = readPixel(from: result, at: TestPoint(xPos: 20, yPos: 4))
        XCTAssertGreaterThan(rightPixel.alpha, 0, "Right side should have content")
    }

    func testClipRect_scissorsDrawing() throws {
        let provider = InMemoryTextureProvider()
        let col = TestColor(red: 255, green: 255, blue: 255, alpha: 255)
        let tex = try XCTUnwrap(createSolidColorTexture(device: device, color: col, size: 32))
        provider.register(tex, for: "test")
        let clipRect = RectD(x: 0, y: 0, width: 8, height: 8)
        let cmds: [RenderCommand] = [
            .beginGroup(name: "test"), .pushClipRect(clipRect), .pushTransform(.identity),
            .drawImage(assetId: "test", opacity: 1.0), .popTransform, .popClipRect, .endGroup
        ]
        let result = try renderer.drawOffscreen(
            commands: cmds, device: device, sizePx: (32, 32),
            animSize: SizeD(width: 32, height: 32), textureProvider: provider,
            pathRegistry: PathRegistry()
        )
        let insidePixel = readPixel(from: result, at: TestPoint(xPos: 4, yPos: 4))
        XCTAssertGreaterThan(insidePixel.alpha, 0, "Inside clip should have content")
        let outsidePixel = readPixel(from: result, at: TestPoint(xPos: 16, yPos: 16))
        XCTAssertEqual(outsidePixel.alpha, 0, "Outside clip should be empty")
    }

    func testDeterminism_sameInputsSamePixels() throws {
        let provider = InMemoryTextureProvider()
        let col = TestColor(red: 128, green: 64, blue: 32, alpha: 255)
        let tex = try XCTUnwrap(createSolidColorTexture(device: device, color: col, size: 4))
        provider.register(tex, for: "test")
        let transform = Matrix2D.translation(x: 5, y: 3).concatenating(.scale(x: 2, y: 2))
        let cmds: [RenderCommand] = [
            .beginGroup(name: "test"), .pushTransform(transform),
            .drawImage(assetId: "test", opacity: 0.75), .popTransform, .endGroup
        ]
        let result1 = try renderer.drawOffscreen(
            commands: cmds, device: device, sizePx: (32, 32),
            animSize: SizeD(width: 32, height: 32), textureProvider: provider,
            pathRegistry: PathRegistry()
        )
        let result2 = try renderer.drawOffscreen(
            commands: cmds, device: device, sizePx: (32, 32),
            animSize: SizeD(width: 32, height: 32), textureProvider: provider,
            pathRegistry: PathRegistry()
        )
        let bytes1 = readAllPixels(from: result1, size: 32)
        let bytes2 = readAllPixels(from: result2, size: 32)
        XCTAssertEqual(bytes1, bytes2, "Two renders should produce identical pixels")
    }

    func testStacksBalanced_invalidPopThrows() throws {
        // Disable pre-execution validator assertion — this test deliberately
        // sends invalid commands to verify the renderer's own error handling.
        RenderCommandValidator.assertOnFailure = false
        defer { RenderCommandValidator.assertOnFailure = true }

        let provider = InMemoryTextureProvider()
        let cmds: [RenderCommand] = [.popTransform]
        XCTAssertThrowsError(
            try renderer.drawOffscreen(
                commands: cmds, device: device, sizePx: (32, 32),
                animSize: SizeD(width: 32, height: 32), textureProvider: provider,
                pathRegistry: PathRegistry()
            )
        ) { error in
            guard let metalError = error as? MetalRendererError,
                  case .invalidCommandStack = metalError else {
                XCTFail("Expected invalidCommandStack, got \(error)")
                return
            }
        }
    }

    func testMasksNoOp_balanceChecked() throws {
        let provider = InMemoryTextureProvider()
        let col = TestColor(red: 255, green: 255, blue: 255, alpha: 255)
        let tex = try XCTUnwrap(createSolidColorTexture(device: device, color: col, size: 8))
        provider.register(tex, for: "test")
        // Empty path - register with minimal PathResource
        var registry = PathRegistry()
        let pathId = registry.register(PathResource(
            pathId: PathID(0),
            keyframePositions: [[]],
            keyframeTimes: [0],
            indices: [],
            vertexCount: 0
        ))
        let cmds: [RenderCommand] = [
            .beginGroup(name: "test"), .pushTransform(.identity),
            .beginMask(mode: .add, inverted: false, pathId: pathId, opacity: 1.0, frame: 0),
            .drawImage(assetId: "test", opacity: 1.0), .endMask, .popTransform, .endGroup
        ]
        let result = try renderer.drawOffscreen(
            commands: cmds, device: device, sizePx: (32, 32),
            animSize: SizeD(width: 32, height: 32), textureProvider: provider,
            pathRegistry: registry
        )
        let pixel = readPixel(from: result, at: TestPoint(xPos: 4, yPos: 4))
        XCTAssertGreaterThan(pixel.alpha, 0, "Image should be rendered (mask is no-op)")
    }

    func testUnbalancedMask_throws() throws {
        // Disable pre-execution validator assertion — this test deliberately
        // sends invalid commands to verify the renderer's own error handling.
        RenderCommandValidator.assertOnFailure = false
        defer { RenderCommandValidator.assertOnFailure = true }

        let provider = InMemoryTextureProvider()
        let cmds: [RenderCommand] = [.endMask]
        XCTAssertThrowsError(
            try renderer.drawOffscreen(
                commands: cmds, device: device, sizePx: (32, 32),
                animSize: SizeD(width: 32, height: 32), textureProvider: provider,
                pathRegistry: PathRegistry()
            )
        ) { error in
            guard let metalError = error as? MetalRendererError,
                  case .invalidCommandStack = metalError else {
                XCTFail("Expected invalidCommandStack, got \(error)")
                return
            }
        }
    }

    // MARK: - Scissor Scaling Tests (review.md section 2)

    /// Test per review.md: clipRect scaling when animToViewport != identity
    /// This reproduces the bug where scissor is in anim coords instead of pixel coords
    func testClipRect_scaledWhenAnimToViewportNotIdentity() throws {
        // Setup: sizePx = 64x64 (texture), animSize = 32x32 (anim)
        // animToViewport scale = 2.0
        // clipRect in anim coords (0,0,16,16) should become (0,0,32,32) in pixels
        let provider = InMemoryTextureProvider()
        let col = TestColor(red: 255, green: 255, blue: 255, alpha: 255)
        let tex = try XCTUnwrap(createSolidColorTexture(device: device, color: col, size: 64))
        provider.register(tex, for: "test")

        // clipRect is 16x16 in anim space (half of 32x32 anim)
        // After scaling by 2.0, should clip to 32x32 pixels (half of 64x64 texture)
        let clipRect = RectD(x: 0, y: 0, width: 16, height: 16)
        let cmds: [RenderCommand] = [
            .beginGroup(name: "test"),
            .pushClipRect(clipRect),
            .pushTransform(.identity),
            .drawImage(assetId: "test", opacity: 1.0),
            .popTransform,
            .popClipRect,
            .endGroup
        ]

        let result = try renderer.drawOffscreen(
            commands: cmds,
            device: device,
            sizePx: (64, 64),  // texture is 64x64
            animSize: SizeD(width: 32, height: 32),  // anim is 32x32, scale = 2.0
            textureProvider: provider,
            pathRegistry: PathRegistry()
        )

        // If scissor is correctly scaled:
        // - pixel (16, 16) should have content (inside 32x32 scaled clip)
        // - pixel (48, 48) should be empty (outside 32x32 scaled clip)
        //
        // If scissor is NOT scaled (bug):
        // - pixel (16, 16) should be empty (outside 16x16 unscaled clip)
        // - only pixel (8, 8) would have content

        let insideScaledClip = readPixel(from: result, at: TestPoint(xPos: 16, yPos: 16))
        let outsideScaledClip = readPixel(from: result, at: TestPoint(xPos: 48, yPos: 48))

        // This assertion will FAIL if scissor is not scaled (current bug)
        XCTAssertGreaterThan(
            insideScaledClip.alpha, 0,
            "Pixel at (16,16) should be inside scaled clip (32x32 pixels). " +
            "If this fails, scissor is not being scaled through animToViewport!"
        )
        XCTAssertEqual(
            outsideScaledClip.alpha, 0,
            "Pixel at (48,48) should be outside scaled clip"
        )
    }

    /// Test per review.md: clipRect with translate (tx/ty), not just scale
    /// This tests letterboxing case where contain+center produces non-zero tx
    func testClipRect_translatedWhenAnimToViewportHasOffset() throws {
        // Setup: sizePx = 100x50 (wide texture), animSize = 50x50 (square anim)
        // contain policy: scale = min(100/50, 50/50) = 1.0
        // center: tx = (100 - 50) / 2 = 25, ty = 0
        // animToViewport = scale(1.0) + translate(25, 0)
        //
        // clipRect (0,0,25,50) in anim → should become (25,0,25,50) in pixels
        let provider = InMemoryTextureProvider()
        let col = TestColor(red: 255, green: 255, blue: 255, alpha: 255)
        // Create wide texture 100x50
        let tex = try XCTUnwrap(createRectTexture(device: device, color: col, width: 100, height: 50))
        provider.register(tex, for: "test")

        // clipRect covers left half of anim (0..25, 0..50)
        // After translate by tx=25, should cover pixels (25..50, 0..50)
        let clipRect = RectD(x: 0, y: 0, width: 25, height: 50)
        let cmds: [RenderCommand] = [
            .beginGroup(name: "test"),
            .pushClipRect(clipRect),
            .pushTransform(.identity),
            .drawImage(assetId: "test", opacity: 1.0),
            .popTransform,
            .popClipRect,
            .endGroup
        ]

        let result = try renderer.drawOffscreen(
            commands: cmds,
            device: device,
            sizePx: (100, 50),  // wide texture
            animSize: SizeD(width: 50, height: 50),  // square anim → tx=25
            textureProvider: provider,
            pathRegistry: PathRegistry()
        )

        // If scissor is correctly translated:
        // - pixel (10, 25) should be empty (left letterbox area, x < 25)
        // - pixel (35, 25) should have content (inside translated clip, 25 <= x < 50)
        // - pixel (60, 25) should be empty (outside clip, x >= 50)
        //
        // If scissor is NOT translated (bug):
        // - pixel (10, 25) would have content (inside unshifted 0..25)

        let leftLetterbox = readPixel(from: result, at: TestPoint(xPos: 10, yPos: 25))
        let insideTranslatedClip = readPixel(from: result, at: TestPoint(xPos: 35, yPos: 25))
        let outsideClip = readPixel(from: result, at: TestPoint(xPos: 60, yPos: 25))

        XCTAssertEqual(
            leftLetterbox.alpha, 0,
            "Pixel at (10,25) should be in left letterbox (empty). " +
            "If this fails, scissor tx offset is not applied!"
        )
        XCTAssertGreaterThan(
            insideTranslatedClip.alpha, 0,
            "Pixel at (35,25) should be inside translated clip"
        )
        XCTAssertEqual(
            outsideClip.alpha, 0,
            "Pixel at (60,25) should be outside clip"
        )
    }

    func createSolidColorTexture(device: MTLDevice, color: TestColor, size: Int) -> MTLTexture? {
        createRectTexture(device: device, color: color, width: size, height: size)
    }

    func createRectTexture(device: MTLDevice, color: TestColor, width: Int, height: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        let bpp = 4
        let bytesPerRow = width * bpp
        var pixels = [UInt8](repeating: 0, count: width * height * bpp)
        for idx in stride(from: 0, to: pixels.count, by: bpp) {
            pixels[idx] = color.blue
            pixels[idx + 1] = color.green
            pixels[idx + 2] = color.red
            pixels[idx + 3] = color.alpha
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0, withBytes: &pixels, bytesPerRow: bytesPerRow
        )
        return texture
    }

    func readPixel(from texture: MTLTexture, at point: TestPoint) -> TestColor {
        var pixel: [UInt8] = [0, 0, 0, 0]
        texture.getBytes(
            &pixel, bytesPerRow: 4,
            from: MTLRegionMake2D(point.xPos, point.yPos, 1, 1), mipmapLevel: 0
        )
        return TestColor(red: pixel[2], green: pixel[1], blue: pixel[0], alpha: pixel[3])
    }

    func readAllPixels(from texture: MTLTexture, size: Int) -> [UInt8] {
        let bytesPerRow = size * 4
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        texture.getBytes(
            &bytes, bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0
        )
        return bytes
    }
}

final class ViewportToNDCMappingTests: XCTestCase {
    func testViewportToNDC_topLeftMapsToTopLeftNDC() {
        let matrix = GeometryMapping.viewportToNDC(width: 100, height: 100)
        let point = matrix.apply(to: Vec2D(x: 0, y: 0))
        XCTAssertEqual(point.x, -1.0, accuracy: 1e-6, "Top-left X should be -1")
        XCTAssertEqual(point.y, 1.0, accuracy: 1e-6, "Top-left Y should be +1")
    }

    func testViewportToNDC_bottomRightMapsToBottomRightNDC() {
        let matrix = GeometryMapping.viewportToNDC(width: 100, height: 100)
        let point = matrix.apply(to: Vec2D(x: 100, y: 100))
        XCTAssertEqual(point.x, 1.0, accuracy: 1e-6, "Bottom-right X should be +1")
        XCTAssertEqual(point.y, -1.0, accuracy: 1e-6, "Bottom-right Y should be -1")
    }

    func testViewportToNDC_centerMapsToOrigin() {
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
