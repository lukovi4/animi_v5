// swiftlint:disable file_length identifier_name type_body_length large_tuple line_length
import XCTest
import Metal
@testable import TVECore
@testable import TVECompilerCore

// MARK: - Metal Renderer Matte Tests

/// Tests for track matte rendering in MetalRenderer (PR9)
final class MetalRendererMatteTests: XCTestCase {
    private var device: MTLDevice!
    private var renderer: MetalRenderer!

    override func setUp() async throws {
        try await super.setUp()
        guard let mtlDevice = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available")
        }
        device = mtlDevice
        renderer = try MetalRenderer(device: device, colorPixelFormat: .bgra8Unorm)
    }

    override func tearDown() {
        renderer?.clearCaches()
        renderer = nil
        device = nil
        super.tearDown()
    }

    // MARK: - Helper Methods

    private func createTestTexture(width: Int, height: Int, color: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        // Fill with solid color
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            pixels[i * 4 + 0] = color.b
            pixels[i * 4 + 1] = color.g
            pixels[i * 4 + 2] = color.r
            pixels[i * 4 + 3] = color.a
        }

        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: width * 4
        )

        return texture
    }

    private func createHalfAlphaTexture(width: Int, height: Int) -> MTLTexture? {
        // Left half: alpha=255, right half: alpha=0
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let halfWidth = width / 2

        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if x < halfWidth {
                    // Left half: white with full alpha
                    pixels[i + 0] = 255 // B
                    pixels[i + 1] = 255 // G
                    pixels[i + 2] = 255 // R
                    pixels[i + 3] = 255 // A
                } else {
                    // Right half: transparent
                    pixels[i + 0] = 0
                    pixels[i + 1] = 0
                    pixels[i + 2] = 0
                    pixels[i + 3] = 0
                }
            }
        }

        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: width * 4
        )

        return texture
    }

    private func createHalfLumaTexture(width: Int, height: Int) -> MTLTexture? {
        // Left half: white (high luma), right half: black (low luma), both opaque
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let halfWidth = width / 2

        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if x < halfWidth {
                    // Left half: white (high luma)
                    pixels[i + 0] = 255 // B
                    pixels[i + 1] = 255 // G
                    pixels[i + 2] = 255 // R
                    pixels[i + 3] = 255 // A
                } else {
                    // Right half: black (low luma) with full alpha
                    pixels[i + 0] = 0   // B
                    pixels[i + 1] = 0   // G
                    pixels[i + 2] = 0   // R
                    pixels[i + 3] = 255 // A (opaque but dark)
                }
            }
        }

        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: width * 4
        )

        return texture
    }

    private func readPixel(from texture: MTLTexture, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        var pixel = [UInt8](repeating: 0, count: 4)
        texture.getBytes(
            &pixel,
            bytesPerRow: 4,
            from: MTLRegionMake2D(x, y, 1, 1),
            mipmapLevel: 0
        )
        return (r: pixel[2], g: pixel[1], b: pixel[0], a: pixel[3])
    }

    // MARK: - Alpha Matte Tests

    func testAlphaMatte_clipsConsumer() throws {
        // Arrange: matte with left half opaque, right half transparent
        // Consumer: fully opaque white
        // Expected: left half visible, right half transparent
        let size = 64
        let commands: [RenderCommand] = [
            .beginMatte(mode: .alpha),
            .beginGroup(name: "matteSource"),
            .drawImage(assetId: "halfAlpha", opacity: 1.0),
            .endGroup,
            .beginGroup(name: "matteConsumer"),
            .drawImage(assetId: "white", opacity: 1.0),
            .endGroup,
            .endMatte
        ]

        guard let halfAlphaTex = createHalfAlphaTexture(width: size, height: size),
              let whiteTex = createTestTexture(width: size, height: size, color: (255, 255, 255, 255)) else {
            throw XCTSkip("Failed to create test textures")
        }

        let textureProvider = MockTextureProvider(textures: [
            "halfAlpha": halfAlphaTex,
            "white": whiteTex
        ])

        // Act
        let resultTex = try renderer.drawOffscreen(
            commands: commands,
            device: device,
            sizePx: (size, size),
            animSize: SizeD(width: Double(size), height: Double(size)),
            textureProvider: textureProvider,
            pathRegistry: PathRegistry()
        )

        // Assert: left side should have content, right side should be transparent
        let leftPixel = readPixel(from: resultTex, x: size / 4, y: size / 2)
        let rightPixel = readPixel(from: resultTex, x: 3 * size / 4, y: size / 2)

        XCTAssertGreaterThan(leftPixel.a, 200, "Left pixel should be mostly opaque (matte visible)")
        XCTAssertLessThan(rightPixel.a, 50, "Right pixel should be mostly transparent (matte clips)")
    }

    func testAlphaMatteInverted_clipsOpposite() throws {
        // Arrange: inverted alpha matte - left half transparent (was opaque), right half visible
        let size = 64
        let commands: [RenderCommand] = [
            .beginMatte(mode: .alphaInverted),
            .beginGroup(name: "matteSource"),
            .drawImage(assetId: "halfAlpha", opacity: 1.0),
            .endGroup,
            .beginGroup(name: "matteConsumer"),
            .drawImage(assetId: "white", opacity: 1.0),
            .endGroup,
            .endMatte
        ]

        guard let halfAlphaTex = createHalfAlphaTexture(width: size, height: size),
              let whiteTex = createTestTexture(width: size, height: size, color: (255, 255, 255, 255)) else {
            throw XCTSkip("Failed to create test textures")
        }

        let textureProvider = MockTextureProvider(textures: [
            "halfAlpha": halfAlphaTex,
            "white": whiteTex
        ])

        // Act
        let resultTex = try renderer.drawOffscreen(
            commands: commands,
            device: device,
            sizePx: (size, size),
            animSize: SizeD(width: Double(size), height: Double(size)),
            textureProvider: textureProvider,
            pathRegistry: PathRegistry()
        )

        // Assert: inverted - left should be transparent, right should be visible
        let leftPixel = readPixel(from: resultTex, x: size / 4, y: size / 2)
        let rightPixel = readPixel(from: resultTex, x: 3 * size / 4, y: size / 2)

        XCTAssertLessThan(leftPixel.a, 50, "Left pixel should be transparent (inverted matte)")
        XCTAssertGreaterThan(rightPixel.a, 200, "Right pixel should be visible (inverted matte)")
    }

    // MARK: - Luma Matte Tests

    func testLumaMatte_usesRGBLuminance() throws {
        // Arrange: luma matte - left half white (high luma), right half black (low luma)
        // Expected: left half visible, right half transparent based on luminance
        let size = 64
        let commands: [RenderCommand] = [
            .beginMatte(mode: .luma),
            .beginGroup(name: "matteSource"),
            .drawImage(assetId: "halfLuma", opacity: 1.0),
            .endGroup,
            .beginGroup(name: "matteConsumer"),
            .drawImage(assetId: "white", opacity: 1.0),
            .endGroup,
            .endMatte
        ]

        guard let halfLumaTex = createHalfLumaTexture(width: size, height: size),
              let whiteTex = createTestTexture(width: size, height: size, color: (255, 255, 255, 255)) else {
            throw XCTSkip("Failed to create test textures")
        }

        let textureProvider = MockTextureProvider(textures: [
            "halfLuma": halfLumaTex,
            "white": whiteTex
        ])

        // Act
        let resultTex = try renderer.drawOffscreen(
            commands: commands,
            device: device,
            sizePx: (size, size),
            animSize: SizeD(width: Double(size), height: Double(size)),
            textureProvider: textureProvider,
            pathRegistry: PathRegistry()
        )

        // Assert: left (high luma) should be visible, right (low luma) should be nearly transparent
        let leftPixel = readPixel(from: resultTex, x: size / 4, y: size / 2)
        let rightPixel = readPixel(from: resultTex, x: 3 * size / 4, y: size / 2)

        XCTAssertGreaterThan(leftPixel.a, 200, "Left pixel (high luma) should be visible")
        XCTAssertLessThan(rightPixel.a, 50, "Right pixel (low luma) should be nearly transparent")
    }

    func testLumaMatteInverted_usesInverseLuminance() throws {
        // Arrange: inverted luma matte - left half becomes transparent, right half visible
        let size = 64
        let commands: [RenderCommand] = [
            .beginMatte(mode: .lumaInverted),
            .beginGroup(name: "matteSource"),
            .drawImage(assetId: "halfLuma", opacity: 1.0),
            .endGroup,
            .beginGroup(name: "matteConsumer"),
            .drawImage(assetId: "white", opacity: 1.0),
            .endGroup,
            .endMatte
        ]

        guard let halfLumaTex = createHalfLumaTexture(width: size, height: size),
              let whiteTex = createTestTexture(width: size, height: size, color: (255, 255, 255, 255)) else {
            throw XCTSkip("Failed to create test textures")
        }

        let textureProvider = MockTextureProvider(textures: [
            "halfLuma": halfLumaTex,
            "white": whiteTex
        ])

        // Act
        let resultTex = try renderer.drawOffscreen(
            commands: commands,
            device: device,
            sizePx: (size, size),
            animSize: SizeD(width: Double(size), height: Double(size)),
            textureProvider: textureProvider,
            pathRegistry: PathRegistry()
        )

        // Assert: inverted - left (high luma) becomes transparent, right (low luma) becomes visible
        let leftPixel = readPixel(from: resultTex, x: size / 4, y: size / 2)
        let rightPixel = readPixel(from: resultTex, x: 3 * size / 4, y: size / 2)

        XCTAssertLessThan(leftPixel.a, 50, "Left pixel (high luma inverted) should be transparent")
        XCTAssertGreaterThan(rightPixel.a, 200, "Right pixel (low luma inverted) should be visible")
    }

    // MARK: - Transform Inheritance Tests

    func testMatteInheritsTransform_translation() throws {
        // Arrange: push transform before matte, verify both source and consumer are affected
        let size = 64
        let translateX = 10.0
        let translateY = 5.0

        let commands: [RenderCommand] = [
            .pushTransform(Matrix2D.translation(x: translateX, y: translateY)),
            .beginMatte(mode: .alpha),
            .beginGroup(name: "matteSource"),
            .drawImage(assetId: "white", opacity: 1.0),
            .endGroup,
            .beginGroup(name: "matteConsumer"),
            .drawImage(assetId: "white", opacity: 1.0),
            .endGroup,
            .endMatte,
            .popTransform
        ]

        guard let whiteTex = createTestTexture(width: 20, height: 20, color: (255, 255, 255, 255)) else {
            throw XCTSkip("Failed to create test texture")
        }

        let textureProvider = MockTextureProvider(textures: ["white": whiteTex])

        // Act
        let resultTex = try renderer.drawOffscreen(
            commands: commands,
            device: device,
            sizePx: (size, size),
            animSize: SizeD(width: Double(size), height: Double(size)),
            textureProvider: textureProvider,
            pathRegistry: PathRegistry()
        )

        // Assert: origin pixel should be transparent (content shifted), translated position should have content
        let originPixel = readPixel(from: resultTex, x: 0, y: 0)
        let translatedPixel = readPixel(from: resultTex, x: Int(translateX) + 5, y: Int(translateY) + 5)

        XCTAssertLessThan(originPixel.a, 50, "Origin should be transparent (content translated)")
        XCTAssertGreaterThan(translatedPixel.a, 200, "Translated position should have content")
    }

    // MARK: - Error Handling Tests

    func testUnbalancedMatteThrows() throws {
        // Disable pre-execution validator assertion — this test deliberately
        // sends unbalanced commands to verify the renderer's own error handling.
        RenderCommandValidator.assertOnFailure = false
        defer { RenderCommandValidator.assertOnFailure = true }

        // Arrange: beginMatte without endMatte
        let size = 64
        let commands: [RenderCommand] = [
            .beginMatte(mode: .alpha),
            .beginGroup(name: "matteSource"),
            .endGroup,
            .beginGroup(name: "matteConsumer"),
            .endGroup
            // Missing endMatte!
        ]

        let textureProvider = MockTextureProvider(textures: [:])

        // Act & Assert
        XCTAssertThrowsError(try renderer.drawOffscreen(
            commands: commands,
            device: device,
            sizePx: (size, size),
            animSize: SizeD(width: Double(size), height: Double(size)),
            textureProvider: textureProvider,
            pathRegistry: PathRegistry()
        )) { error in
            guard case MetalRendererError.invalidCommandStack(let reason) = error else {
                XCTFail("Expected invalidCommandStack error, got: \(error)")
                return
            }
            XCTAssertTrue(
                reason.contains("EndMatte") || reason.contains("Unbalanced"),
                "Error should mention missing EndMatte or unbalanced: \(reason)"
            )
        }
    }

    func testMatteScopeMissingSourceGroupThrows() throws {
        // Arrange: matte without matteSource group
        let size = 64
        let commands: [RenderCommand] = [
            .beginMatte(mode: .alpha),
            .beginGroup(name: "wrongName"), // Should be "matteSource"
            .endGroup,
            .beginGroup(name: "matteConsumer"),
            .endGroup,
            .endMatte
        ]

        let textureProvider = MockTextureProvider(textures: [:])

        // Act & Assert
        XCTAssertThrowsError(try renderer.drawOffscreen(
            commands: commands,
            device: device,
            sizePx: (size, size),
            animSize: SizeD(width: Double(size), height: Double(size)),
            textureProvider: textureProvider,
            pathRegistry: PathRegistry()
        )) { error in
            guard case MetalRendererError.invalidCommandStack(let reason) = error else {
                XCTFail("Expected invalidCommandStack error, got: \(error)")
                return
            }
            XCTAssertTrue(
                reason.contains("matteSource"),
                "Error should mention missing matteSource group: \(reason)"
            )
        }
    }

    // MARK: - Clip Inheritance Tests

    func testMatteInheritsClip_scissorAppliedToComposite() throws {
        // Arrange: push clip rect before matte, verify composite respects scissor
        let size = 64
        let clipRect = RectD(x: 10, y: 10, width: 30, height: 30)

        let commands: [RenderCommand] = [
            .pushClipRect(clipRect),
            .beginMatte(mode: .alpha),
            .beginGroup(name: "matteSource"),
            .drawImage(assetId: "white", opacity: 1.0),
            .endGroup,
            .beginGroup(name: "matteConsumer"),
            .drawImage(assetId: "white", opacity: 1.0),
            .endGroup,
            .endMatte,
            .popClipRect
        ]

        guard let whiteTex = createTestTexture(width: size, height: size, color: (255, 255, 255, 255)) else {
            throw XCTSkip("Failed to create test texture")
        }

        let textureProvider = MockTextureProvider(textures: ["white": whiteTex])

        // Act
        let resultTex = try renderer.drawOffscreen(
            commands: commands,
            device: device,
            sizePx: (size, size),
            animSize: SizeD(width: Double(size), height: Double(size)),
            textureProvider: textureProvider,
            pathRegistry: PathRegistry()
        )

        // Assert: outside clip should be transparent, inside clip should have content
        let outsidePixel = readPixel(from: resultTex, x: 0, y: 0) // Outside clip
        let insidePixel = readPixel(from: resultTex, x: 20, y: 20) // Inside clip

        XCTAssertLessThan(outsidePixel.a, 50, "Pixel outside clip should be transparent")
        XCTAssertGreaterThan(insidePixel.a, 200, "Pixel inside clip should have content")
    }
}

// MARK: - Mock Texture Provider

private final class MockTextureProvider: TextureProvider {
    private let textures: [String: MTLTexture]

    init(textures: [String: MTLTexture]) {
        self.textures = textures
    }

    func texture(for assetId: String) -> MTLTexture? {
        textures[assetId]
    }
}
// swiftlint:enable file_length identifier_name type_body_length large_tuple line_length
