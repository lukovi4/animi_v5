import XCTest
import Metal
@testable import TVECore

/// Tests for isolated group (precomp opacity) rendering.
///
/// Isolated groups ensure that children are composited internally at full opacity,
/// with the container's opacity applied once to the final result.
/// This matches AE/Lottie semantics for precomp opacity.
final class IsolatedGroupTests: XCTestCase {
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

    // MARK: - Isolated Group Opacity Tests

    /// Tests that isolated group applies opacity to the composited result, not each child.
    ///
    /// Setup:
    /// - "media" (red texture) as background
    /// - "frame" (blue texture, opaque) covers media completely
    /// - Both inside isolated group with opacity 0.5
    ///
    /// Expected:
    /// - Without isolated group: frame at 0.5 opacity would blend with media → purple-ish
    /// - With isolated group: frame covers media internally → result is pure blue at 0.5 opacity
    func testIsolatedGroup_frameCoversMedia_noMediaBleedthrough() throws {
        let provider = InMemoryTextureProvider()

        // Create textures: media (red) and frame (blue)
        let mediaColor = PixelColor(red: 255, green: 0, blue: 0, alpha: 255)
        let frameColor = PixelColor(red: 0, green: 0, blue: 255, alpha: 255)

        let mediaTex = try XCTUnwrap(createSolidTexture(device: device, color: mediaColor, size: 32))
        let frameTex = try XCTUnwrap(createSolidTexture(device: device, color: frameColor, size: 32))

        provider.register(mediaTex, for: "media")
        provider.register(frameTex, for: "frame")

        // Commands: isolated group with opacity 0.5 containing media + frame
        // Frame is drawn after media, so it should completely cover it inside the group
        let commands: [RenderCommand] = [
            .beginGroup(name: "test"),
            .beginIsolatedGroup(opacity: 0.5),
            .pushTransform(.identity),
            .drawImage(assetId: "media", opacity: 1.0),  // Background (red)
            .drawImage(assetId: "frame", opacity: 1.0),  // Foreground covers it (blue)
            .popTransform,
            .endIsolatedGroup,
            .endGroup
        ]

        let result = try renderer.drawOffscreen(
            commands: commands,
            device: device,
            sizePx: (32, 32),
            animSize: SizeD(width: 32, height: 32),
            textureProvider: provider,
            pathRegistry: PathRegistry()
        )

        // Read center pixel
        let pixel = readPixel(from: result, at: (16, 16))

        // Expected: blue (frame) at 0.5 opacity over transparent background
        // With premultiplied alpha: RGB = color * alpha, A = alpha
        // Blue 255 * 0.5 ≈ 127, Alpha ≈ 127
        //
        // If isolated group is NOT working correctly, we'd see red bleeding through
        // because frame would be composited at 0.5 over media at 0.5

        // Verify NO red bleedthrough (media should be completely covered)
        XCTAssertLessThan(pixel.red, 10, "Red should be near-zero (no media bleedthrough)")

        // Verify blue is present
        XCTAssertGreaterThan(pixel.blue, 100, "Blue should be significant (frame is visible)")

        // Verify alpha is around 50%
        XCTAssertGreaterThan(pixel.alpha, 100, "Alpha should be around 50%")
        XCTAssertLessThan(pixel.alpha, 160, "Alpha should be around 50%")
    }

    /// Tests that isolated group with opacity 1.0 produces same result as no isolated group.
    func testIsolatedGroup_opacityOne_sameAsNoGroup() throws {
        let provider = InMemoryTextureProvider()

        let color = PixelColor(red: 100, green: 150, blue: 200, alpha: 255)
        let tex = try XCTUnwrap(createSolidTexture(device: device, color: color, size: 32))
        provider.register(tex, for: "test")

        // With isolated group at opacity 1.0
        let commandsWithGroup: [RenderCommand] = [
            .beginGroup(name: "test"),
            .beginIsolatedGroup(opacity: 1.0),
            .pushTransform(.identity),
            .drawImage(assetId: "test", opacity: 1.0),
            .popTransform,
            .endIsolatedGroup,
            .endGroup
        ]

        let resultWithGroup = try renderer.drawOffscreen(
            commands: commandsWithGroup,
            device: device,
            sizePx: (32, 32),
            animSize: SizeD(width: 32, height: 32),
            textureProvider: provider,
            pathRegistry: PathRegistry()
        )

        // Without isolated group
        let commandsWithout: [RenderCommand] = [
            .beginGroup(name: "test"),
            .pushTransform(.identity),
            .drawImage(assetId: "test", opacity: 1.0),
            .popTransform,
            .endGroup
        ]

        let resultWithout = try renderer.drawOffscreen(
            commands: commandsWithout,
            device: device,
            sizePx: (32, 32),
            animSize: SizeD(width: 32, height: 32),
            textureProvider: provider,
            pathRegistry: PathRegistry()
        )

        let pixelWith = readPixel(from: resultWithGroup, at: (16, 16))
        let pixelWithout = readPixel(from: resultWithout, at: (16, 16))

        // Should be identical (within tolerance for any rounding)
        XCTAssertEqual(pixelWith.red, pixelWithout.red, accuracy: 2)
        XCTAssertEqual(pixelWith.green, pixelWithout.green, accuracy: 2)
        XCTAssertEqual(pixelWith.blue, pixelWithout.blue, accuracy: 2)
        XCTAssertEqual(pixelWith.alpha, pixelWithout.alpha, accuracy: 2)
    }

    /// Tests nested isolated groups.
    func testIsolatedGroup_nested_compositesCorrectly() throws {
        let provider = InMemoryTextureProvider()

        let color = PixelColor(red: 255, green: 255, blue: 255, alpha: 255)
        let tex = try XCTUnwrap(createSolidTexture(device: device, color: color, size: 32))
        provider.register(tex, for: "test")

        // Nested groups: outer 0.5, inner 0.5 → total 0.25
        let commands: [RenderCommand] = [
            .beginGroup(name: "outer"),
            .beginIsolatedGroup(opacity: 0.5),
            .beginGroup(name: "inner"),
            .beginIsolatedGroup(opacity: 0.5),
            .pushTransform(.identity),
            .drawImage(assetId: "test", opacity: 1.0),
            .popTransform,
            .endIsolatedGroup,
            .endGroup,
            .endIsolatedGroup,
            .endGroup
        ]

        let result = try renderer.drawOffscreen(
            commands: commands,
            device: device,
            sizePx: (32, 32),
            animSize: SizeD(width: 32, height: 32),
            textureProvider: provider,
            pathRegistry: PathRegistry()
        )

        let pixel = readPixel(from: result, at: (16, 16))

        // Expected: white at 0.5 * 0.5 = 0.25 opacity
        // Premultiplied: RGB ≈ 64, A ≈ 64
        XCTAssertGreaterThan(pixel.alpha, 50, "Alpha should be around 25%")
        XCTAssertLessThan(pixel.alpha, 80, "Alpha should be around 25%")
    }

    // MARK: - Helpers

    private struct PixelColor {
        let red, green, blue, alpha: UInt8
    }

    private func createSolidTexture(device: MTLDevice, color: PixelColor, size: Int) -> MTLTexture? {
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
            pixels[idx] = color.blue      // BGRA order
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

    private func readPixel(from texture: MTLTexture, at point: (x: Int, y: Int)) -> PixelColor {
        var pixel: [UInt8] = [0, 0, 0, 0]
        texture.getBytes(
            &pixel, bytesPerRow: 4,
            from: MTLRegionMake2D(point.x, point.y, 1, 1), mipmapLevel: 0
        )
        return PixelColor(red: pixel[2], green: pixel[1], blue: pixel[0], alpha: pixel[3])
    }
}

// MARK: - XCTAssertEqual with accuracy for UInt8

private func XCTAssertEqual(
    _ expression1: UInt8,
    _ expression2: UInt8,
    accuracy: UInt8,
    _ message: String = "",
    file: StaticString = #file,
    line: UInt = #line
) {
    let diff = expression1 > expression2 ? expression1 - expression2 : expression2 - expression1
    XCTAssertLessThanOrEqual(diff, accuracy, message, file: file, line: line)
}
