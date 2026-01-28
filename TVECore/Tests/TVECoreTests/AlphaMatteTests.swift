import XCTest
import Metal
@testable import TVECore

/// Integration tests for alpha matte rendering (track mattes with tt:2).
/// Verifies that alpha mattes correctly clip content based on matte layer alpha.
final class AlphaMatteTests: XCTestCase {
    private var device: MTLDevice!
    private var renderer: MetalRenderer!
    private var compiler: AnimIRCompiler!

    override func setUp() async throws {
        try await super.setUp()
        guard let mtlDevice = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available")
        }
        device = mtlDevice
        renderer = try MetalRenderer(device: device, colorPixelFormat: .bgra8Unorm)
        compiler = AnimIRCompiler()
    }

    override func tearDown() {
        renderer?.clearCaches()
        renderer = nil
        device = nil
        compiler = nil
        super.tearDown()
    }

    // MARK: - Test A: Alpha Matte Clips Content

    /// Tests that alpha matte (inverted) correctly clips content at frame 26.
    ///
    /// Animation structure (alpha_matte_basic/anim.json):
    /// - 1080x1920, 30fps, 91 frames
    /// - Matte source: comp_0 with 12 shape layers (3x4 grid of tiles)
    /// - Matte consumer: comp_1 with image (Img_1.png)
    /// - Track matte type: Alpha Inverted (tt:2)
    ///
    /// Alpha Inverted mode (tt=2) means:
    /// - Where matte source alpha > 0 → consumer is HIDDEN
    /// - Where matte source alpha = 0 → consumer is VISIBLE
    ///
    /// At frame 26:
    /// - Only Shape Layer 12 at (900, 1680) is visible in matte source
    /// - All other tiles have opacity=0 or size=0
    ///
    /// Expected behavior:
    /// - Point INSIDE matte (900, 1680): alpha ≈ 0 (hidden by inverted matte)
    /// - Point OUTSIDE matte (180, 240): alpha > 0 (visible because matte is empty there)
    func testAlphaMatteClipsContent_frame26() throws {
        // Load alpha_matte_basic/anim.json
        guard let url = Bundle.module.url(
            forResource: "anim",
            withExtension: "json",
            subdirectory: "Resources/mattes/alpha_matte_basic"
        ) else {
            XCTFail("Could not find anim.json in Resources/mattes/alpha_matte_basic")
            return
        }

        let data = try Data(contentsOf: url)
        let lottie = try JSONDecoder().decode(LottieJSON.self, from: data)

        // Build asset index (anim.json references image_0 -> images/Img_1.png)
        let assetIndex = AssetIndex(byId: ["image_0": "images/Img_1.png"])

        // Compile to AnimIR with scene-level path registry
        var pathRegistry = PathRegistry()
        var animIR = try compiler.compile(
            lottie: lottie,
            animRef: "alpha_matte_basic",
            bindingKey: "Img_1.png",
            assetIndex: assetIndex,
            pathRegistry: &pathRegistry
        )

        // Animation is 1080x1920, render at 1:1 for pixel-accurate testing
        let animSize = SizeD(width: Double(lottie.width), height: Double(lottie.height))
        let renderSize = (width: 1080, height: 1920)

        // Create texture provider with white fallback texture
        let textureProvider = AlphaMatteTestTextureProvider(
            device: device,
            fallbackSize: (1080, 1920)
        )

        // Render frame 26
        let commands = animIR.renderCommands(frameIndex: 26)
        let texture = try renderer.drawOffscreen(
            commands: commands,
            device: device,
            sizePx: renderSize,
            animSize: animSize,
            textureProvider: textureProvider,
            pathRegistry: pathRegistry
        )

        // Sample points:
        // Grid is 3x4 with tile centers at X: 180/540/900, Y: 240/720/1200/1680
        // At frame 26, only Shape Layer 12 at (900, 1680) renders in matte source

        // Point INSIDE matte area: (900, 1680) - bottom-right tile (the only one visible)
        // Alpha inverted mode: where matte alpha > 0 → consumer is hidden
        let insideMatteAlpha = readAlpha(from: texture, x: 900, y: 1680)

        // Point OUTSIDE matte area: (180, 240) - top-left tile (opacity = 0 at frame 26)
        // Alpha inverted mode: where matte alpha = 0 → consumer is visible
        let outsideMatteAlpha = readAlpha(from: texture, x: 180, y: 240)

        // Assertions with tolerance for AA/filtering
        // Alpha inverted: inside matte = hidden, outside matte = visible
        XCTAssertLessThan(
            insideMatteAlpha, 0.1,
            "Point inside matte (900, 1680) should have alpha < 0.1 (hidden by inverted matte), got \(insideMatteAlpha)"
        )
        XCTAssertGreaterThan(
            outsideMatteAlpha, 0.9,
            "Point outside matte (180, 240) should have alpha > 0.9 (visible), got \(outsideMatteAlpha)"
        )
    }

    // MARK: - Helper Methods

    /// Reads alpha value at given pixel coordinates (normalized 0.0-1.0)
    private func readAlpha(from texture: MTLTexture, x: Int, y: Int) -> Float {
        var pixel = [UInt8](repeating: 0, count: 4)
        texture.getBytes(
            &pixel,
            bytesPerRow: texture.width * 4,
            from: MTLRegionMake2D(x, y, 1, 1),
            mipmapLevel: 0
        )
        // BGRA format: pixel[3] is alpha
        return Float(pixel[3]) / 255.0
    }
}

// MARK: - Test Texture Provider

/// Provides fallback white textures for any asset ID
private final class AlphaMatteTestTextureProvider: TextureProvider {
    private let device: MTLDevice
    private let fallbackTexture: MTLTexture?

    init(device: MTLDevice, fallbackSize: (width: Int, height: Int)) {
        self.device = device
        self.fallbackTexture = Self.createWhiteTexture(
            device: device,
            width: fallbackSize.width,
            height: fallbackSize.height
        )
    }

    func texture(for assetId: String) -> MTLTexture? {
        return fallbackTexture
    }

    private static func createWhiteTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
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

        // Fill with opaque white
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: &pixels,
            bytesPerRow: width * 4
        )

        return texture
    }
}
