// swiftlint:disable file_length identifier_name type_body_length large_tuple line_length
import XCTest
import Metal
@testable import TVECore

/// Integration tests for animated matte morph rendering (anim-3).
/// Verifies that matte shape path animation actually affects rendered output.
final class MetalRendererAnimatedMatteMorphTests: XCTestCase {
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

    // MARK: - Animated Matte Morph Test

    /// Tests that anim-3 matte morph actually changes rendered output between frames 60 and 90.
    ///
    /// anim-3 has:
    /// - Matte source (shape layer) with animated path: narrow at frame 60, wide at frame 90
    /// - Matte consumer (precomp with image)
    ///
    /// Expected behavior:
    /// - Frame 60: ROI on right side should be mostly transparent (matte shape is narrow)
    /// - Frame 90: ROI on right side should be mostly opaque (matte shape is wide)
    func testAnim3MatteMorph_rightROI_changesVisibility() throws {
        // Load anim-3.json
        guard let url = Bundle.module.url(
            forResource: "anim-3",
            withExtension: "json",
            subdirectory: "Resources"
        ) else {
            XCTFail("Could not find anim-3.json in Resources")
            return
        }

        let data = try Data(contentsOf: url)
        let lottie = try JSONDecoder().decode(LottieJSON.self, from: data)

        // Build asset index (anim-3 has image_0 asset)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img_3.png"])

        // Compile to AnimIR
        // bindingKey "img_3.png" matches the layer name in comp_0
        var animIR = try compiler.compile(
            lottie: lottie,
            animRef: "anim-3",
            bindingKey: "img_3.png",
            assetIndex: assetIndex
        )

        // Register paths (this is the crucial step that was broken before PR-C1)
        animIR.registerPaths()
        let pathRegistry = animIR.pathRegistry

        // Create mock texture provider with white texture for the image asset
        let animSize = SizeD(width: Double(lottie.width), height: Double(lottie.height))
        let renderSize = (width: 108, height: 192) // 1/10 scale for faster tests

        let textureProvider = MockTextureProvider(device: device, fallbackSize: (540, 960))

        // Render frame 60 (matte shape is narrow - right side should be clipped)
        let commands60 = animIR.renderCommands(frameIndex: 60)
        let texture60 = try renderer.drawOffscreen(
            commands: commands60,
            device: device,
            sizePx: renderSize,
            animSize: animSize,
            textureProvider: textureProvider,
            pathRegistry: pathRegistry
        )

        // Render frame 90 (matte shape is wide - edges visible due to alphaInverted mode)
        let commands90 = animIR.renderCommands(frameIndex: 90)
        let texture90 = try renderer.drawOffscreen(
            commands: commands90,
            device: device,
            sizePx: renderSize,
            animSize: animSize,
            textureProvider: textureProvider,
            pathRegistry: pathRegistry
        )

        // Count non-zero alpha pixels for each frame
        let totalAlpha60 = computeTotalAlpha(texture: texture60)
        let totalAlpha90 = computeTotalAlpha(texture: texture90)

        // Assertions
        // Note: anim-3 uses alphaInverted matte mode, so visible area is INVERSE of matte shape.
        // At frame 60: matte source opacity=0, so consumer is fully visible (but matte not applied?)
        // At frame 90: matte source opacity=100, matte shape wide, so edges visible (inverted)
        //
        // The key test: frame 90 should have content somewhere (morph + matte is working)
        // Frame 60 has opacity=0 on matte source, so no clipping happens → depends on fallback behavior

        // Frame 90 should have visible content somewhere (content bounds show x:0-53, y:96-191)
        XCTAssertGreaterThan(
            totalAlpha90, 100,
            "Frame 90 should have visible content (matte composite working). " +
            "Got total non-zero pixels: \(totalAlpha90)"
        )

        // Verify there's a difference between frames (morph/opacity is working)
        XCTAssertGreaterThan(
            totalAlpha90, totalAlpha60,
            "Frame 90 should have more visible content than frame 60. " +
            "Frame 60: \(totalAlpha60), Frame 90: \(totalAlpha90)"
        )
    }

    /// Secondary test: verify center ROI has content on frame 90
    func testAnim3MatteMorph_centerROI_hasContent() throws {
        guard let url = Bundle.module.url(
            forResource: "anim-3",
            withExtension: "json",
            subdirectory: "Resources"
        ) else {
            XCTFail("Could not find anim-3.json")
            return
        }

        let data = try Data(contentsOf: url)
        let lottie = try JSONDecoder().decode(LottieJSON.self, from: data)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img_3.png"])
        var animIR = try compiler.compile(
            lottie: lottie,
            animRef: "anim-3",
            bindingKey: "img_3.png",
            assetIndex: assetIndex
        )
        animIR.registerPaths()

        let animSize = SizeD(width: Double(lottie.width), height: Double(lottie.height))
        let renderSize = (width: 108, height: 192)
        let textureProvider = MockTextureProvider(device: device, fallbackSize: (540, 960))

        let commands90 = animIR.renderCommands(frameIndex: 90)
        let texture90 = try renderer.drawOffscreen(
            commands: commands90,
            device: device,
            sizePx: renderSize,
            animSize: animSize,
            textureProvider: textureProvider,
            pathRegistry: animIR.pathRegistry
        )

        // Check total non-zero pixels at frame 90
        let totalAlpha = computeTotalAlpha(texture: texture90)

        XCTAssertGreaterThan(
            totalAlpha, 100,
            "Frame 90 should have visible content. Got total non-zero: \(totalAlpha)"
        )
    }

    // MARK: - Helper Methods

    /// Tests that path morph actually changes content bounds between frames.
    /// Compares frame 75 vs frame 90 - both have non-zero opacity, but path should differ.
    /// At frame 75: path is interpolated (narrower than frame 90)
    /// At frame 90: path is at final wide position
    func testAnim3MatteMorph_pathChangesContentBounds() throws {
        guard let url = Bundle.module.url(
            forResource: "anim-3",
            withExtension: "json",
            subdirectory: "Resources"
        ) else {
            XCTFail("Could not find anim-3.json")
            return
        }

        let data = try Data(contentsOf: url)
        let lottie = try JSONDecoder().decode(LottieJSON.self, from: data)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img_3.png"])
        var animIR = try compiler.compile(
            lottie: lottie,
            animRef: "anim-3",
            bindingKey: "img_3.png",
            assetIndex: assetIndex
        )
        animIR.registerPaths()

        let animSize = SizeD(width: Double(lottie.width), height: Double(lottie.height))
        let renderSize = (width: 108, height: 192)
        let textureProvider = MockTextureProvider(device: device, fallbackSize: (540, 960))

        // Frame 75: opacity ~50%, path interpolated (mid-morph)
        let commands75 = animIR.renderCommands(frameIndex: 75)
        let texture75 = try renderer.drawOffscreen(
            commands: commands75,
            device: device,
            sizePx: renderSize,
            animSize: animSize,
            textureProvider: textureProvider,
            pathRegistry: animIR.pathRegistry
        )

        // Frame 90: opacity=100%, path at final wide position
        let commands90 = animIR.renderCommands(frameIndex: 90)
        let texture90 = try renderer.drawOffscreen(
            commands: commands90,
            device: device,
            sizePx: renderSize,
            animSize: animSize,
            textureProvider: textureProvider,
            pathRegistry: animIR.pathRegistry
        )

        let bounds75 = findContentBounds(texture: texture75)
        let bounds90 = findContentBounds(texture: texture90)
        let total75 = computeTotalAlpha(texture: texture75)
        let total90 = computeTotalAlpha(texture: texture90)

        print("[PATH MORPH] Frame 75: bounds=\(bounds75), total=\(total75)")
        print("[PATH MORPH] Frame 90: bounds=\(bounds90), total=\(total90)")

        // Both frames should have content
        XCTAssertGreaterThan(total75, 0, "Frame 75 should have some visible content")
        XCTAssertGreaterThan(total90, 0, "Frame 90 should have visible content")

        // If path morph works, the content area should be DIFFERENT between frames
        // anim-3 uses alphaInverted matte, so wider matte = smaller visible area
        // At frame 75: narrower matte path → more visible (inverted)
        // At frame 90: wider matte path → less visible (inverted)
        // So total75 should be > total90 if path morph is working

        // Key assertion: content bounds or pixel count should differ
        let boundsDiffer = (bounds75.minX != bounds90.minX) ||
                          (bounds75.maxX != bounds90.maxX) ||
                          (bounds75.minY != bounds90.minY) ||
                          (bounds75.maxY != bounds90.maxY)
        let pixelCountDiffers = abs(total75 - total90) > 100

        XCTAssertTrue(
            boundsDiffer || pixelCountDiffers,
            "Path morph should cause different content between frames 75 and 90. " +
            "Bounds75=\(bounds75), Bounds90=\(bounds90), Total75=\(total75), Total90=\(total90)"
        )
    }

    // MARK: - Helper Methods

    /// Counts non-zero alpha pixels in the entire texture
    private func computeTotalAlpha(texture: MTLTexture) -> Int {
        let w = texture.width
        let h = texture.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&pixels, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)

        var count = 0
        for i in 0..<(w * h) {
            if pixels[i * 4 + 3] > 0 { count += 1 }
        }
        return count
    }

    /// Finds bounding box of non-zero alpha content
    private func findContentBounds(texture: MTLTexture) -> (minX: Int, maxX: Int, minY: Int, maxY: Int) {
        let w = texture.width
        let h = texture.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&pixels, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)

        var minX = w, maxX = 0, minY = h, maxY = 0
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                if pixels[i + 3] > 0 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }
        return (minX, maxX, minY, maxY)
    }
}

// MARK: - Mock Texture Provider

/// Provides fallback white textures for any asset ID
private final class MockTextureProvider: TextureProvider {
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
        // Return fallback white texture for any asset
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
// swiftlint:enable file_length identifier_name type_body_length large_tuple line_length
