// swiftlint:disable identifier_name
import XCTest
import Metal
@testable import TVECore
@testable import TVECompilerCore

/// Integration tests for ScenePlayer rendering (PR10.1)
/// Verifies that all 4 blocks render correctly with proper transform and clip inheritance
final class ScenePlayerRenderIntegrationTests: XCTestCase {
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

    // MARK: - Test Resources

    private var testPackageURL: URL {
        Bundle.module.url(
            forResource: "scene",
            withExtension: "json",
            subdirectory: "Resources/example_4blocks"
        )!.deletingLastPathComponent()
    }

    private func loadTestPackage() throws -> (ScenePackage, LoadedAnimations) {
        let loader = ScenePackageLoader()
        let package = try loader.load(from: testPackageURL)

        let animLoader = AnimLoader()
        let animations = try animLoader.loadAnimations(from: package)

        return (package, animations)
    }

    // MARK: - Helper Methods

    // swiftlint:disable:next large_tuple
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

    private func maxAlpha(from texture: MTLTexture, centerX: Int, centerY: Int, radius: Int = 4) -> UInt8 {
        var maxA: UInt8 = 0
        for dy in -radius...radius {
            for dx in -radius...radius {
                let x = max(0, min(texture.width - 1, centerX + dx))
                let y = max(0, min(texture.height - 1, centerY + dy))
                let pixel = readPixel(from: texture, x: x, y: y)
                maxA = max(maxA, pixel.a)
            }
        }
        return maxA
    }

    // MARK: - Quadrant Center Points (canvas 1080x1920)
    // Block1 (top-left): center at (canvasW*0.25, canvasH*0.25) = (270, 480)
    // Block2 (top-right): center at (canvasW*0.75, canvasH*0.25) = (810, 480)
    // Block3 (bottom-left): center at (canvasW*0.25, canvasH*0.75) = (270, 1440)
    // Block4 (bottom-right): center at (canvasW*0.75, canvasH*0.75) = (810, 1440)

    private let canvasWidth = 1080
    private let canvasHeight = 1920

    private var block1Center: (x: Int, y: Int) { (canvasWidth * 1 / 4, canvasHeight * 1 / 4) }
    private var block2Center: (x: Int, y: Int) { (canvasWidth * 3 / 4, canvasHeight * 1 / 4) }
    private var block3Center: (x: Int, y: Int) { (canvasWidth * 1 / 4, canvasHeight * 3 / 4) }
    private var block4Center: (x: Int, y: Int) { (canvasWidth * 3 / 4, canvasHeight * 3 / 4) }

    // MARK: - Pixel Tests

    /// Test: Block 1 (top-left) renders correctly after fade-in (frame 30+)
    /// Note: anim-1.json has opacity animation 0→100 between frames 0-30
    func testScene_frame30_block1HasNonZeroPixels() throws {
        // Given
        let (package, animations) = try loadTestPackage()
        let player = ScenePlayer()
        let compiled = try player.compile(package: package, loadedAnimations: animations)

        let localIndex = try LocalAssetsIndex(imagesRootURL: package.imagesRootURL)
        let resolver = CompositeAssetResolver(localIndex: localIndex, sharedIndex: .empty)
        let textureProvider = SceneTextureProviderFactory.create(
            device: device,
            mergedAssetIndex: compiled.mergedAssetIndex,
            resolver: resolver
        )

        // When - render frame 30 (anim-1 opacity should be 100%)
        // PR-28: Set userMediaPresent=true for all blocks to show binding layers
        let userMediaPresent = Dictionary(
            uniqueKeysWithValues: compiled.runtime.blocks.map { ($0.blockId, true) }
        )
        let commands = compiled.runtime.renderCommands(
            sceneFrameIndex: 30,
            userMediaPresent: userMediaPresent
        )

        let resultTex = try renderer.drawOffscreen(
            commands: commands,
            device: device,
            sizePx: (canvasWidth, canvasHeight),
            animSize: SizeD(width: Double(canvasWidth), height: Double(canvasHeight)),
            textureProvider: textureProvider,
            pathRegistry: compiled.pathRegistry
        )

        // Then - block 1 center should have non-zero alpha (check 9x9 area)
        let alpha = maxAlpha(from: resultTex, centerX: block1Center.x, centerY: block1Center.y)
        XCTAssertGreaterThan(
            alpha, 0,
            "Block 1 (top-left) at (\(block1Center.x), \(block1Center.y)) should have alpha > 0 at frame 30"
        )
    }

    /// Test: Block 2 (top-right) renders correctly at frame 60 (after position animation)
    /// anim-2 has position animation (810,-480)→(810,480) over frames 30-60
    /// At frame 60, content is fully in visible area
    func testScene_frame60_block2HasNonZeroPixels() throws {
        // Given
        let (package, animations) = try loadTestPackage()
        let player = ScenePlayer()
        let compiled = try player.compile(package: package, loadedAnimations: animations)

        let localIndex = try LocalAssetsIndex(imagesRootURL: package.imagesRootURL)
        let resolver = CompositeAssetResolver(localIndex: localIndex, sharedIndex: .empty)
        let textureProvider = SceneTextureProviderFactory.create(
            device: device,
            mergedAssetIndex: compiled.mergedAssetIndex,
            resolver: resolver
        )

        // When - render frame 60 (anim-2 position animation complete)
        // PR-28: Set userMediaPresent=true for all blocks to show binding layers
        let userMediaPresent = Dictionary(
            uniqueKeysWithValues: compiled.runtime.blocks.map { ($0.blockId, true) }
        )
        let commands = compiled.runtime.renderCommands(
            sceneFrameIndex: 60,
            userMediaPresent: userMediaPresent
        )

        let resultTex = try renderer.drawOffscreen(
            commands: commands,
            device: device,
            sizePx: (canvasWidth, canvasHeight),
            animSize: SizeD(width: Double(canvasWidth), height: Double(canvasHeight)),
            textureProvider: textureProvider,
            pathRegistry: compiled.pathRegistry
        )

        // Then - block 2 center should have non-zero alpha (check 9x9 area)
        let alpha = maxAlpha(from: resultTex, centerX: block2Center.x, centerY: block2Center.y)
        XCTAssertGreaterThan(
            alpha, 0,
            "Block 2 (top-right) at (\(block2Center.x), \(block2Center.y)) should have alpha > 0 at frame 60"
        )
    }

    /// Test: Block 3 (bottom-left) renders correctly at frame 90 (after animations)
    /// anim-3 has scale animation 0%→100% over frames 60-90 with alphaInverted matte
    /// With alphaInverted matte, content is visible OUTSIDE the matte shape area
    /// Matte is parallelogram: top-left(0,960) → top-right(540,1280) → bottom-right(540,1920) → bottom-left(0,1600)
    /// We check top-right corner of block 3 which is ABOVE matte's top edge
    func testScene_frame90_block3HasNonZeroPixels() throws {
        // Given
        let (package, animations) = try loadTestPackage()
        let player = ScenePlayer()
        let compiled = try player.compile(package: package, loadedAnimations: animations)

        let localIndex = try LocalAssetsIndex(imagesRootURL: package.imagesRootURL)
        let resolver = CompositeAssetResolver(localIndex: localIndex, sharedIndex: .empty)
        let textureProvider = SceneTextureProviderFactory.create(
            device: device,
            mergedAssetIndex: compiled.mergedAssetIndex,
            resolver: resolver
        )

        // When - render frame 90 (anim-3 scale animation complete)
        // PR-28: Set userMediaPresent=true for all blocks to show binding layers
        let userMediaPresent = Dictionary(
            uniqueKeysWithValues: compiled.runtime.blocks.map { ($0.blockId, true) }
        )
        let commands = compiled.runtime.renderCommands(
            sceneFrameIndex: 90,
            userMediaPresent: userMediaPresent
        )

        let resultTex = try renderer.drawOffscreen(
            commands: commands,
            device: device,
            sizePx: (canvasWidth, canvasHeight),
            animSize: SizeD(width: Double(canvasWidth), height: Double(canvasHeight)),
            textureProvider: textureProvider,
            pathRegistry: compiled.pathRegistry
        )

        // Then - with alphaInverted matte, check top-right corner of block 3
        // Matte top edge at x=500: y ≈ 960 + (320/540)*500 ≈ 1256
        // Point (500, 980) is ABOVE matte edge (980 < 1256) → outside matte → visible
        let cornerX = 500  // Near right edge of block 3
        let cornerY = 980  // Near top of block 3, above matte
        let alpha = maxAlpha(from: resultTex, centerX: cornerX, centerY: cornerY, radius: 20)
        XCTAssertGreaterThan(
            alpha, 0,
            "Block 3 top-right corner at (\(cornerX), \(cornerY)) should have alpha > 0 at frame 90 (outside alphaInverted matte)"
        )
    }

    /// Test: Block 4 (bottom-right) renders correctly at frame 120 (after scale animation)
    /// anim-4 has scale animation 0%→100% over frames 90-120
    /// At frame 120, scale is 100% and content is fully visible
    func testScene_frame120_block4HasNonZeroPixels() throws {
        // Given
        let (package, animations) = try loadTestPackage()
        let player = ScenePlayer()
        let compiled = try player.compile(package: package, loadedAnimations: animations)

        let localIndex = try LocalAssetsIndex(imagesRootURL: package.imagesRootURL)
        let resolver = CompositeAssetResolver(localIndex: localIndex, sharedIndex: .empty)
        let textureProvider = SceneTextureProviderFactory.create(
            device: device,
            mergedAssetIndex: compiled.mergedAssetIndex,
            resolver: resolver
        )

        // When - render frame 120 (anim-4 scale animation complete)
        // PR-28: Set userMediaPresent=true for all blocks to show binding layers
        let userMediaPresent = Dictionary(
            uniqueKeysWithValues: compiled.runtime.blocks.map { ($0.blockId, true) }
        )
        let commands = compiled.runtime.renderCommands(
            sceneFrameIndex: 120,
            userMediaPresent: userMediaPresent
        )

        let resultTex = try renderer.drawOffscreen(
            commands: commands,
            device: device,
            sizePx: (canvasWidth, canvasHeight),
            animSize: SizeD(width: Double(canvasWidth), height: Double(canvasHeight)),
            textureProvider: textureProvider,
            pathRegistry: compiled.pathRegistry
        )

        // Then - block 4 center should have non-zero alpha (check 9x9 area)
        let alpha = maxAlpha(from: resultTex, centerX: block4Center.x, centerY: block4Center.y)
        XCTAssertGreaterThan(
            alpha, 0,
            "Block 4 (bottom-right) at (\(block4Center.x), \(block4Center.y)) should have alpha > 0 at frame 120"
        )
    }

    /// Test: Block 4 (bottom-right) renders correctly at frame 150
    /// This verifies the identity transform fix works (animSize == canvasSize)
    func testScene_frame150_block4HasNonZeroPixels() throws {
        // Given
        let (package, animations) = try loadTestPackage()
        let player = ScenePlayer()
        let compiled = try player.compile(package: package, loadedAnimations: animations)

        let localIndex = try LocalAssetsIndex(imagesRootURL: package.imagesRootURL)
        let resolver = CompositeAssetResolver(localIndex: localIndex, sharedIndex: .empty)
        let textureProvider = SceneTextureProviderFactory.create(
            device: device,
            mergedAssetIndex: compiled.mergedAssetIndex,
            resolver: resolver
        )

        // When - render frame 150 (all anims fully visible)
        // PR-28: Set userMediaPresent=true for all blocks to show binding layers
        let userMediaPresent = Dictionary(
            uniqueKeysWithValues: compiled.runtime.blocks.map { ($0.blockId, true) }
        )
        let commands = compiled.runtime.renderCommands(
            sceneFrameIndex: 150,
            userMediaPresent: userMediaPresent
        )

        let resultTex = try renderer.drawOffscreen(
            commands: commands,
            device: device,
            sizePx: (canvasWidth, canvasHeight),
            animSize: SizeD(width: Double(canvasWidth), height: Double(canvasHeight)),
            textureProvider: textureProvider,
            pathRegistry: compiled.pathRegistry
        )

        // Then - block 4 center should have non-zero alpha (check 9x9 area)
        let alpha = maxAlpha(from: resultTex, centerX: block4Center.x, centerY: block4Center.y)
        XCTAssertGreaterThan(
            alpha, 0,
            "Block 4 (bottom-right) at (\(block4Center.x), \(block4Center.y)) should have alpha > 0 at frame 150"
        )
    }

    /// Test: All 4 blocks render at frame 150
    /// Verifies matte inheritance fix: all blocks should render correctly
    func testScene_frame150_multipleBlocksRender() throws {
        // Given
        let (package, animations) = try loadTestPackage()
        let player = ScenePlayer()
        let compiled = try player.compile(package: package, loadedAnimations: animations)

        let localIndex = try LocalAssetsIndex(imagesRootURL: package.imagesRootURL)
        let resolver = CompositeAssetResolver(localIndex: localIndex, sharedIndex: .empty)
        let textureProvider = SceneTextureProviderFactory.create(
            device: device,
            mergedAssetIndex: compiled.mergedAssetIndex,
            resolver: resolver
        )

        // When - render frame 150
        // PR-28: Set userMediaPresent=true for all blocks to show binding layers
        let userMediaPresent = Dictionary(
            uniqueKeysWithValues: compiled.runtime.blocks.map { ($0.blockId, true) }
        )
        let commands = compiled.runtime.renderCommands(
            sceneFrameIndex: 150,
            userMediaPresent: userMediaPresent
        )

        let resultTex = try renderer.drawOffscreen(
            commands: commands,
            device: device,
            sizePx: (canvasWidth, canvasHeight),
            animSize: SizeD(width: Double(canvasWidth), height: Double(canvasHeight)),
            textureProvider: textureProvider,
            pathRegistry: compiled.pathRegistry
        )

        // Then - all 4 blocks should have content
        // Block 3 uses alphaInverted matte, so center is hidden - check top-right corner instead
        // Matte is parallelogram: point (500, 980) is ABOVE matte's top edge
        let alpha1 = maxAlpha(from: resultTex, centerX: block1Center.x, centerY: block1Center.y)
        let alpha2 = maxAlpha(from: resultTex, centerX: block2Center.x, centerY: block2Center.y)
        // Block 3 top-right corner (outside matte shape): x=500, y=980
        let alpha3 = maxAlpha(from: resultTex, centerX: 500, centerY: 980, radius: 20)
        let alpha4 = maxAlpha(from: resultTex, centerX: block4Center.x, centerY: block4Center.y)

        XCTAssertGreaterThan(alpha1, 0, "Block 1 should have alpha > 0 at frame 150")
        XCTAssertGreaterThan(alpha2, 0, "Block 2 should have alpha > 0 at frame 150")
        XCTAssertGreaterThan(alpha3, 0, "Block 3 top-right corner should have alpha > 0 at frame 150 (outside alphaInverted matte)")
        XCTAssertGreaterThan(alpha4, 0, "Block 4 should have alpha > 0 at frame 150")
    }

    /// Test: Scene generates correct number of clip rects (one per block)
    func testScene_commandsHaveCorrectClipRects() throws {
        // Given
        let (package, animations) = try loadTestPackage()
        let player = ScenePlayer()
        let compiled = try player.compile(package: package, loadedAnimations: animations)

        // When - render at frame 150
        // PR-28: Set userMediaPresent=true for all blocks to show binding layers
        let userMediaPresent = Dictionary(
            uniqueKeysWithValues: compiled.runtime.blocks.map { ($0.blockId, true) }
        )
        let commands = compiled.runtime.renderCommands(
            sceneFrameIndex: 150,
            userMediaPresent: userMediaPresent
        )

        // Then - should have 4 pushClipRect commands (one per block)
        var pushClipCount = 0
        var clipRects: [RectD] = []
        for command in commands {
            if case .pushClipRect(let rect) = command {
                pushClipCount += 1
                clipRects.append(rect)
            }
        }

        XCTAssertEqual(pushClipCount, 4, "Should have 4 pushClipRect commands")

        // Verify clip rects match expected block positions
        let expectedOrigins: [(Double, Double)] = [(0, 0), (540, 0), (0, 960), (540, 960)]
        for (x, y) in expectedOrigins {
            let found = clipRects.contains { abs($0.x - x) < 1 && abs($0.y - y) < 1 }
            XCTAssertTrue(found, "Should have clip rect at (\(x), \(y))")
        }
    }

    /// Test: Identity transform is used when animSize equals canvasSize
    /// This is the core fix for Blocker A in PR10.1
    func testScene_identityTransformWhenFullCanvas() throws {
        // Given
        let (package, animations) = try loadTestPackage()
        let player = ScenePlayer()
        let compiled = try player.compile(package: package, loadedAnimations: animations)

        // When - render at frame 150
        // PR-28: Set userMediaPresent=true for all blocks to show binding layers
        let userMediaPresent = Dictionary(
            uniqueKeysWithValues: compiled.runtime.blocks.map { ($0.blockId, true) }
        )
        let commands = compiled.runtime.renderCommands(
            sceneFrameIndex: 150,
            userMediaPresent: userMediaPresent
        )

        // Then - count transforms that are identity
        var identityTransformCount = 0
        for command in commands {
            if case .pushTransform(let matrix) = command {
                if matrix == .identity {
                    identityTransformCount += 1
                }
            }
        }

        // With full-canvas animations, block transforms should be identity
        // At least 4 identity transforms (one per block)
        XCTAssertGreaterThanOrEqual(
            identityTransformCount, 4,
            "Full-canvas animations should use identity block transforms"
        )
    }
}
// swiftlint:enable identifier_name
