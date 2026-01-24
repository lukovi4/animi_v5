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
            animSize: SizeD(width: 1, height: 1), textureProvider: provider
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
            animSize: SizeD(width: 1, height: 1), textureProvider: provider
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
            animSize: SizeD(width: 32, height: 32), textureProvider: provider
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
            animSize: SizeD(width: 32, height: 32), textureProvider: provider
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
            animSize: SizeD(width: 32, height: 32), textureProvider: provider
        )
        let result2 = try renderer.drawOffscreen(
            commands: cmds, device: device, sizePx: (32, 32),
            animSize: SizeD(width: 32, height: 32), textureProvider: provider
        )
        let bytes1 = readAllPixels(from: result1, size: 32)
        let bytes2 = readAllPixels(from: result2, size: 32)
        XCTAssertEqual(bytes1, bytes2, "Two renders should produce identical pixels")
    }

    func testStacksBalanced_invalidPopThrows() throws {
        let provider = InMemoryTextureProvider()
        let cmds: [RenderCommand] = [.popTransform]
        XCTAssertThrowsError(
            try renderer.drawOffscreen(
                commands: cmds, device: device, sizePx: (32, 32),
                animSize: SizeD(width: 32, height: 32), textureProvider: provider
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
        let path = BezierPath(vertices: [], inTangents: [], outTangents: [], closed: true)
        let cmds: [RenderCommand] = [
            .beginGroup(name: "test"), .pushTransform(.identity), .beginMaskAdd(path: path),
            .drawImage(assetId: "test", opacity: 1.0), .endMask, .popTransform, .endGroup
        ]
        let result = try renderer.drawOffscreen(
            commands: cmds, device: device, sizePx: (32, 32),
            animSize: SizeD(width: 32, height: 32), textureProvider: provider
        )
        let pixel = readPixel(from: result, at: TestPoint(xPos: 4, yPos: 4))
        XCTAssertGreaterThan(pixel.alpha, 0, "Image should be rendered (mask is no-op)")
    }

    func testUnbalancedMask_throws() throws {
        let provider = InMemoryTextureProvider()
        let cmds: [RenderCommand] = [.endMask]
        XCTAssertThrowsError(
            try renderer.drawOffscreen(
                commands: cmds, device: device, sizePx: (32, 32),
                animSize: SizeD(width: 32, height: 32), textureProvider: provider
            )
        ) { error in
            guard let metalError = error as? MetalRendererError,
                  case .invalidCommandStack = metalError else {
                XCTFail("Expected invalidCommandStack, got \(error)")
                return
            }
        }
    }

    func createSolidColorTexture(device: MTLDevice, color: TestColor, size: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        let bpp = 4
        let bytesPerRow = size * bpp
        var pixels = [UInt8](repeating: 0, count: size * size * bpp)
        for idx in stride(from: 0, to: pixels.count, by: bpp) {
            pixels[idx] = color.blue
            pixels[idx + 1] = color.green
            pixels[idx + 2] = color.red
            pixels[idx + 3] = color.alpha
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, size, size),
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
