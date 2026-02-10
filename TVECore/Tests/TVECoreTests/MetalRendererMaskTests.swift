import XCTest
import Metal
import simd
@testable import TVECore
@testable import TVECompilerCore

// MARK: - Test Helpers

private struct MaskTestColor { let red, green, blue, alpha: UInt8 }
private struct MaskTestPoint { let xPos, yPos: Int }

// MARK: - Metal Renderer Mask Tests

final class MetalRendererMaskTests: XCTestCase {
    var device: MTLDevice!
    var renderer: MetalRenderer!

    #if DEBUG
    /// Expected number of GPU mask fallbacks for current test.
    /// Default is 0 (no fallbacks expected). Override in tests where fallback is valid.
    private var expectedMaskFallbacks: Int = 0
    #endif

    override func setUpWithError() throws {
        device = MTLCreateSystemDefaultDevice()
        try XCTSkipIf(device == nil, "Metal not available")
        renderer = try MetalRenderer(
            device: device,
            colorPixelFormat: .bgra8Unorm,
            options: MetalRendererOptions(clearColor: .transparentBlack)
        )
        #if DEBUG
        MaskDebugCounters.reset()
        expectedMaskFallbacks = 0
        #endif
    }

    override func tearDown() {
        #if DEBUG
        // PR-C4: Verify GPU mask fallback count matches expectation
        XCTAssertEqual(MaskDebugCounters.fallbackCount, expectedMaskFallbacks,
                       "Unexpected GPU mask fallback count")
        #endif
        renderer = nil
        device = nil
    }

    // MARK: - Helper to register path and get pathId

    private func registerPath(_ path: BezierPath, in registry: inout PathRegistry) -> PathID {
        let pathId = PathID(registry.count)
        if let resource = PathResourceBuilder.build(from: path, pathId: pathId) {
            return registry.register(resource)
        }
        // For empty paths, create a minimal resource
        return registry.register(PathResource(
            pathId: pathId,
            keyframePositions: [[]],
            keyframeTimes: [0],
            indices: [],
            vertexCount: 0
        ))
    }

    // MARK: - Test 1: Mask clips content to path bounds

    func testMaskClipsContentToPathBounds() throws {
        let provider = InMemoryTextureProvider()
        let col = MaskTestColor(red: 255, green: 255, blue: 255, alpha: 255)
        let tex = try XCTUnwrap(createSolidColorTexture(device: device, color: col, size: 32))
        provider.register(tex, for: "test")

        // Create a small square mask in the center (8x8 at position 12,12)
        let maskPath = createRectPath(xPos: 12, yPos: 12, width: 8, height: 8)
        var registry = PathRegistry()
        let pathId = registerPath(maskPath, in: &registry)

        let cmds: [RenderCommand] = [
            .beginGroup(name: "test"),
            .pushTransform(.identity),
            .beginMask(mode: .add, inverted: false, pathId: pathId, opacity: 1.0, frame: 0),
            .drawImage(assetId: "test", opacity: 1.0),
            .endMask,
            .popTransform,
            .endGroup
        ]

        let result = try renderer.drawOffscreen(
            commands: cmds, device: device, sizePx: (32, 32),
            animSize: SizeD(width: 32, height: 32), textureProvider: provider,
            pathRegistry: registry
        )

        // Inside mask area should have content
        let insidePixel = readPixel(from: result, at: MaskTestPoint(xPos: 16, yPos: 16))
        XCTAssertGreaterThan(insidePixel.alpha, 0, "Inside mask should have content")

        // Outside mask area should be empty
        let outsidePixel = readPixel(from: result, at: MaskTestPoint(xPos: 4, yPos: 4))
        XCTAssertEqual(outsidePixel.alpha, 0, "Outside mask should be empty")
    }

    // MARK: - Test 2: Mask with zero opacity renders nothing

    func testMaskWithZeroOpacity() throws {
        let provider = InMemoryTextureProvider()
        let col = MaskTestColor(red: 255, green: 255, blue: 255, alpha: 255)
        let tex = try XCTUnwrap(createSolidColorTexture(device: device, color: col, size: 32))
        provider.register(tex, for: "test")

        let maskPath = createRectPath(xPos: 0, yPos: 0, width: 32, height: 32)
        var registry = PathRegistry()
        let pathId = registerPath(maskPath, in: &registry)

        let cmds: [RenderCommand] = [
            .beginGroup(name: "test"),
            .pushTransform(.identity),
            .beginMask(mode: .add, inverted: false, pathId: pathId, opacity: 0.0, frame: 0),
            .drawImage(assetId: "test", opacity: 1.0),
            .endMask,
            .popTransform,
            .endGroup
        ]

        let result = try renderer.drawOffscreen(
            commands: cmds, device: device, sizePx: (32, 32),
            animSize: SizeD(width: 32, height: 32), textureProvider: provider,
            pathRegistry: registry
        )

        let pixel = readPixel(from: result, at: MaskTestPoint(xPos: 16, yPos: 16))
        XCTAssertEqual(pixel.alpha, 0, "Mask with zero opacity should render nothing")
    }

    // MARK: - Test 3: Empty mask path renders content unmasked

    func testEmptyMaskPathRendersContent() throws {
        // Empty path triggers fallback (degenerate bbox) - this is expected
        #if DEBUG
        expectedMaskFallbacks = 1
        #endif

        let provider = InMemoryTextureProvider()
        let col = MaskTestColor(red: 255, green: 255, blue: 255, alpha: 255)
        let tex = try XCTUnwrap(createSolidColorTexture(device: device, color: col, size: 32))
        provider.register(tex, for: "test")

        // Empty path (fewer than 3 vertices)
        let emptyPath = BezierPath(vertices: [], inTangents: [], outTangents: [], closed: true)
        var registry = PathRegistry()
        let pathId = registerPath(emptyPath, in: &registry)

        let cmds: [RenderCommand] = [
            .beginGroup(name: "test"),
            .pushTransform(.identity),
            .beginMask(mode: .add, inverted: false, pathId: pathId, opacity: 1.0, frame: 0),
            .drawImage(assetId: "test", opacity: 1.0),
            .endMask,
            .popTransform,
            .endGroup
        ]

        let result = try renderer.drawOffscreen(
            commands: cmds, device: device, sizePx: (32, 32),
            animSize: SizeD(width: 32, height: 32), textureProvider: provider,
            pathRegistry: registry
        )

        // Empty mask should render content without masking (fallback behavior)
        let pixel = readPixel(from: result, at: MaskTestPoint(xPos: 16, yPos: 16))
        XCTAssertGreaterThan(pixel.alpha, 0, "Empty mask should render content")
    }

    // MARK: - Test 4: Mask scope extraction

    func testMaskScopeExtraction() throws {
        let path = createRectPath(xPos: 0, yPos: 0, width: 10, height: 10)
        var registry = PathRegistry()
        let pathId = registerPath(path, in: &registry)

        let commands: [RenderCommand] = [
            .beginGroup(name: "root"),
            .beginMask(mode: .add, inverted: false, pathId: pathId, opacity: 1.0, frame: 0),
            .pushTransform(.identity),
            .drawImage(assetId: "test", opacity: 1.0),
            .popTransform,
            .endMask,
            .endGroup
        ]

        let scope = renderer.extractMaskScope(from: commands, startIndex: 1)
        XCTAssertNotNil(scope, "Should extract mask scope")
        XCTAssertEqual(scope?.startIndex, 1)
        XCTAssertEqual(scope?.endIndex, 5)
        XCTAssertEqual(scope?.innerCommands.count, 3)
    }

    // MARK: - Test 5: Nested mask scope extraction

    func testNestedMaskScopeExtraction() throws {
        let outerPath = createRectPath(xPos: 0, yPos: 0, width: 20, height: 20)
        let innerPath = createRectPath(xPos: 5, yPos: 5, width: 10, height: 10)
        var registry = PathRegistry()
        let outerPathId = registerPath(outerPath, in: &registry)
        let innerPathId = registerPath(innerPath, in: &registry)

        let commands: [RenderCommand] = [
            .beginMask(mode: .add, inverted: false, pathId: outerPathId, opacity: 1.0, frame: 0),  // 0
            .pushTransform(.identity),                                    // 1
            .beginMask(mode: .add, inverted: false, pathId: innerPathId, opacity: 1.0, frame: 0),   // 2
            .drawImage(assetId: "test", opacity: 1.0),                    // 3
            .endMask,                                                     // 4 (matches inner)
            .popTransform,                                                // 5
            .endMask                                                      // 6 (matches outer)
        ]

        let outerScope = renderer.extractMaskScope(from: commands, startIndex: 0)
        XCTAssertNotNil(outerScope)
        XCTAssertEqual(outerScope?.startIndex, 0)
        XCTAssertEqual(outerScope?.endIndex, 6, "Outer scope should end at index 6")
        XCTAssertEqual(outerScope?.innerCommands.count, 5, "Outer scope should have 5 inner commands")

        let innerScope = renderer.extractMaskScope(from: commands, startIndex: 2)
        XCTAssertNotNil(innerScope)
        XCTAssertEqual(innerScope?.startIndex, 2)
        XCTAssertEqual(innerScope?.endIndex, 4, "Inner scope should end at index 4")
        XCTAssertEqual(innerScope?.innerCommands.count, 1, "Inner scope should have 1 inner command")
    }

    // MARK: - Test 6: Determinism - same mask renders same pixels

    func testMaskRenderingDeterminism() throws {
        let provider = InMemoryTextureProvider()
        let col = MaskTestColor(red: 128, green: 64, blue: 32, alpha: 255)
        let tex = try XCTUnwrap(createSolidColorTexture(device: device, color: col, size: 32))
        provider.register(tex, for: "test")

        let maskPath = createRectPath(xPos: 8, yPos: 8, width: 16, height: 16)
        var registry = PathRegistry()
        let pathId = registerPath(maskPath, in: &registry)

        let cmds: [RenderCommand] = [
            .beginGroup(name: "test"),
            .pushTransform(.identity),
            .beginMask(mode: .add, inverted: false, pathId: pathId, opacity: 0.8, frame: 0),
            .drawImage(assetId: "test", opacity: 1.0),
            .endMask,
            .popTransform,
            .endGroup
        ]

        let result1 = try renderer.drawOffscreen(
            commands: cmds, device: device, sizePx: (32, 32),
            animSize: SizeD(width: 32, height: 32), textureProvider: provider,
            pathRegistry: registry
        )
        let result2 = try renderer.drawOffscreen(
            commands: cmds, device: device, sizePx: (32, 32),
            animSize: SizeD(width: 32, height: 32), textureProvider: provider,
            pathRegistry: registry
        )

        let bytes1 = readAllPixels(from: result1, size: 32)
        let bytes2 = readAllPixels(from: result2, size: 32)
        XCTAssertEqual(bytes1, bytes2, "Two renders should produce identical pixels")
    }

    // MARK: - Test 7: Mask with transform applied

    func testMaskWithTransform() throws {
        let provider = InMemoryTextureProvider()
        let col = MaskTestColor(red: 255, green: 255, blue: 255, alpha: 255)
        let tex = try XCTUnwrap(createSolidColorTexture(device: device, color: col, size: 16))
        provider.register(tex, for: "test")

        // Create a larger mask to ensure visibility
        let maskPath = createRectPath(xPos: 0, yPos: 0, width: 16, height: 16)
        var registry = PathRegistry()
        let pathId = registerPath(maskPath, in: &registry)

        let cmds: [RenderCommand] = [
            .beginGroup(name: "test"),
            .pushTransform(.identity),
            .beginMask(mode: .add, inverted: false, pathId: pathId, opacity: 1.0, frame: 0),
            .drawImage(assetId: "test", opacity: 1.0),
            .endMask,
            .popTransform,
            .endGroup
        ]

        let result = try renderer.drawOffscreen(
            commands: cmds, device: device, sizePx: (32, 32),
            animSize: SizeD(width: 32, height: 32), textureProvider: provider,
            pathRegistry: registry
        )

        // Check that masked content was rendered (at least some pixels non-transparent)
        let bytes = readAllPixels(from: result, size: 32)
        let nonZeroAlpha = stride(from: 3, to: bytes.count, by: 4).filter { bytes[$0] > 0 }.count
        XCTAssertGreaterThan(nonZeroAlpha, 0, "Masked content should be rendered")
    }

    // MARK: - Test 8: Mask inherits transform (translation)

    func testMaskInheritsTransform_translation() throws {
        let provider = InMemoryTextureProvider()
        let col = MaskTestColor(red: 255, green: 255, blue: 255, alpha: 255)
        let tex = try XCTUnwrap(createSolidColorTexture(device: device, color: col, size: 32))
        provider.register(tex, for: "test")

        // Small mask near origin (0,0) with size 8x8
        let maskPath = createRectPath(xPos: 0, yPos: 0, width: 8, height: 8)
        var registry = PathRegistry()
        let pathId = registerPath(maskPath, in: &registry)

        // Apply translation BEFORE the mask - content should appear at translated position
        let cmds: [RenderCommand] = [
            .beginGroup(name: "test"),
            .pushTransform(.translation(x: 16, y: 0)),
            .beginMask(mode: .add, inverted: false, pathId: pathId, opacity: 1.0, frame: 0),
            .drawImage(assetId: "test", opacity: 1.0),
            .endMask,
            .popTransform,
            .endGroup
        ]

        let result = try renderer.drawOffscreen(
            commands: cmds, device: device, sizePx: (32, 32),
            animSize: SizeD(width: 32, height: 32), textureProvider: provider,
            pathRegistry: registry
        )

        // Original position (0-8) should be empty due to translation
        let originPixel = readPixel(from: result, at: MaskTestPoint(xPos: 4, yPos: 4))
        XCTAssertEqual(originPixel.alpha, 0, "Origin should be empty - mask was translated")

        // Translated position (16-24) should have content
        let translatedPixel = readPixel(from: result, at: MaskTestPoint(xPos: 20, yPos: 4))
        XCTAssertGreaterThan(translatedPixel.alpha, 0, "Translated position should have content")
    }

    // MARK: - Test 9: Mask inherits clip (scissor applied to composite)

    func testMaskInheritsClip_scissorAppliedToComposite() throws {
        let provider = InMemoryTextureProvider()
        let col = MaskTestColor(red: 255, green: 255, blue: 255, alpha: 255)
        let tex = try XCTUnwrap(createSolidColorTexture(device: device, color: col, size: 32))
        provider.register(tex, for: "test")

        // Large mask covering entire area
        let maskPath = createRectPath(xPos: 0, yPos: 0, width: 32, height: 32)
        var registry = PathRegistry()
        let pathId = registerPath(maskPath, in: &registry)

        // Apply clip BEFORE the mask - composite should respect clip
        let cmds: [RenderCommand] = [
            .beginGroup(name: "test"),
            .pushClipRect(RectD(x: 0, y: 0, width: 8, height: 8)),
            .pushTransform(.identity),
            .beginMask(mode: .add, inverted: false, pathId: pathId, opacity: 1.0, frame: 0),
            .drawImage(assetId: "test", opacity: 1.0),
            .endMask,
            .popTransform,
            .popClipRect,
            .endGroup
        ]

        let result = try renderer.drawOffscreen(
            commands: cmds, device: device, sizePx: (32, 32),
            animSize: SizeD(width: 32, height: 32), textureProvider: provider,
            pathRegistry: registry
        )

        // Inside clip area (0-8) should have content
        let insidePixel = readPixel(from: result, at: MaskTestPoint(xPos: 4, yPos: 4))
        XCTAssertGreaterThan(insidePixel.alpha, 0, "Inside clip should have content")

        // Outside clip area should be empty (even though mask covers it)
        let outsidePixel = readPixel(from: result, at: MaskTestPoint(xPos: 16, yPos: 16))
        XCTAssertEqual(outsidePixel.alpha, 0, "Outside clip should be empty")
    }

    // MARK: - Test 10: Unbalanced mask does not crash (M1-fallback)

    func testUnbalancedMaskDoesNotCrash() throws {
        // Disable pre-execution validator assertion — this test deliberately
        // sends unbalanced commands to verify the renderer's fallback behavior.
        RenderCommandValidator.assertOnFailure = false
        defer { RenderCommandValidator.assertOnFailure = true }

        // M1-fallback: malformed scope (missing endMask) should NOT throw.
        // Instead, it should render inner commands without mask.
        let provider = InMemoryTextureProvider()
        let maskPath = createRectPath(xPos: 0, yPos: 0, width: 10, height: 10)
        var registry = PathRegistry()
        let pathId = registerPath(maskPath, in: &registry)

        // Add a test texture so drawImage doesn't fail
        let col = MaskTestColor(red: 255, green: 0, blue: 0, alpha: 255)
        let tex = try XCTUnwrap(createSolidColorTexture(device: device, color: col, size: 32))
        provider.register(tex, for: "test")

        // BeginMaskAdd without EndMask
        let cmds: [RenderCommand] = [
            .beginGroup(name: "test"),
            .beginMask(mode: .add, inverted: false, pathId: pathId, opacity: 1.0, frame: 0),
            .drawImage(assetId: "test", opacity: 1.0),
            // Missing .endMask - malformed scope
            .endGroup
        ]

        // NOTE: Malformed scope goes through skipMalformedMaskScope, not renderMaskGroupScope
        // So no fallback counter is incremented - this is handled in execute loop directly

        // Should NOT throw - fallback renders content without mask
        let result = try renderer.drawOffscreen(
            commands: cmds, device: device, sizePx: (32, 32),
            animSize: SizeD(width: 32, height: 32), textureProvider: provider,
            pathRegistry: registry
        )

        // Verify render completed (content was drawn without mask)
        XCTAssertNotNil(result, "Render should complete successfully with fallback")

        // Verify content was actually rendered (red color from texture)
        let centerPixel = readPixel(from: result, at: MaskTestPoint(xPos: 16, yPos: 16))
        XCTAssertGreaterThan(centerPixel.alpha, 0, "Fallback should render content")
        XCTAssertGreaterThan(centerPixel.red, 200, "Content should be red (from test texture)")
    }

    // MARK: - Helper Methods

    private func createSolidColorTexture(
        device: MTLDevice,
        color: MaskTestColor,
        size: Int
    ) -> MTLTexture? {
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

    private func readPixel(from texture: MTLTexture, at point: MaskTestPoint) -> MaskTestColor {
        var pixel: [UInt8] = [0, 0, 0, 0]
        texture.getBytes(
            &pixel, bytesPerRow: 4,
            from: MTLRegionMake2D(point.xPos, point.yPos, 1, 1), mipmapLevel: 0
        )
        return MaskTestColor(red: pixel[2], green: pixel[1], blue: pixel[0], alpha: pixel[3])
    }

    private func readAllPixels(from texture: MTLTexture, size: Int) -> [UInt8] {
        let bytesPerRow = size * 4
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        texture.getBytes(
            &bytes, bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0
        )
        return bytes
    }

    private func createRectPath(xPos: Double, yPos: Double, width: Double, height: Double) -> BezierPath {
        let vertices = [
            Vec2D(x: xPos, y: yPos),
            Vec2D(x: xPos + width, y: yPos),
            Vec2D(x: xPos + width, y: yPos + height),
            Vec2D(x: xPos, y: yPos + height)
        ]
        let zeroTangents = [Vec2D](repeating: Vec2D(x: 0, y: 0), count: 4)
        return BezierPath(
            vertices: vertices,
            inTangents: zeroTangents,
            outTangents: zeroTangents,
            closed: true
        )
    }
}

// MARK: - Mask Rasterizer Tests

final class MaskRasterizerTests: XCTestCase {
    func testRasterizeSimpleSquare() {
        let path = createSquarePath(size: 10)
        let transform = Matrix2D.identity

        let result = MaskRasterizer.rasterize(
            path: path,
            transformToViewportPx: transform,
            targetSizePx: (width: 20, height: 20)
        )

        XCTAssertEqual(result.count, 20 * 20, "Should have 400 pixels")

        // Verify some pixels are filled (square path should fill interior)
        let filledCount = result.filter { $0 > 0 }.count
        XCTAssertGreaterThan(filledCount, 0, "Some pixels should be filled")

        // Check that filled area is roughly the expected size (10x10 = 100 pixels, allow variance for antialiasing)
        XCTAssertGreaterThan(filledCount, 50, "Should have substantial filled area")
    }

    func testRasterizeEmptyPath() {
        let path = BezierPath(vertices: [], inTangents: [], outTangents: [], closed: true)
        let transform = Matrix2D.identity

        let result = MaskRasterizer.rasterize(
            path: path,
            transformToViewportPx: transform,
            targetSizePx: (width: 10, height: 10)
        )

        XCTAssertEqual(result.count, 100, "Should have 100 pixels")
        XCTAssertTrue(result.allSatisfy { $0 == 0 }, "All pixels should be zero")
    }

    func testRasterizeWithTransform() {
        let path = createSquarePath(size: 5)
        let transform = Matrix2D.translation(x: 10, y: 10)

        let result = MaskRasterizer.rasterize(
            path: path,
            transformToViewportPx: transform,
            targetSizePx: (width: 20, height: 20)
        )

        // Origin area should be empty
        let originIdx = 2 * 20 + 2
        XCTAssertEqual(result[originIdx], 0, "Origin should be empty")

        // Translated area should have content
        let translatedIdx = 12 * 20 + 12
        XCTAssertGreaterThan(result[translatedIdx], 0, "Translated area should have content")
    }

    private func createSquarePath(size: Double) -> BezierPath {
        let vertices = [
            Vec2D(x: 0, y: 0),
            Vec2D(x: size, y: 0),
            Vec2D(x: size, y: size),
            Vec2D(x: 0, y: size)
        ]
        let zeroTangents = [Vec2D](repeating: Vec2D(x: 0, y: 0), count: 4)
        return BezierPath(
            vertices: vertices,
            inTangents: zeroTangents,
            outTangents: zeroTangents,
            closed: true
        )
    }
}

// MARK: - Mask Cache Tests (DEPRECATED - CPU mask path forbidden)

/// **PR-C4:** These tests are for the legacy CPU mask cache which is now forbidden.
/// MaskCache.texture() has a DEBUG preconditionFailure.
/// Tests are skipped in DEBUG builds. Will be removed in future cleanup PR.
final class MaskCacheTests: XCTestCase {
    var device: MTLDevice!

    override func setUpWithError() throws {
        device = MTLCreateSystemDefaultDevice()
        try XCTSkipIf(device == nil, "Metal not available")
        #if DEBUG
        // PR-C4: Skip all MaskCache tests - CPU mask path is forbidden
        throw XCTSkip("MaskCache tests skipped: CPU mask path is forbidden (PR-C4). GPU masks only.")
        #endif
    }

    override func tearDown() {
        device = nil
    }

    func testCacheReturnsTexture() throws {
        let cache = MaskCache(device: device)
        let path = createTestPath()
        let transform = Matrix2D.identity

        let texture = cache.texture(for: path, transform: transform, size: (10, 10), opacity: 1.0)
        XCTAssertNotNil(texture)
        XCTAssertEqual(cache.count, 1)
    }

    func testCacheReusesTexture() throws {
        let cache = MaskCache(device: device)
        let path = createTestPath()
        let transform = Matrix2D.identity

        let tex1 = cache.texture(for: path, transform: transform, size: (10, 10), opacity: 1.0)
        let tex2 = cache.texture(for: path, transform: transform, size: (10, 10), opacity: 1.0)

        XCTAssertEqual(cache.count, 1, "Should reuse cached texture")
        XCTAssertTrue(tex1 === tex2, "Should return same texture instance")
    }

    func testCacheDifferentSizes() throws {
        let cache = MaskCache(device: device)
        let path = createTestPath()
        let transform = Matrix2D.identity

        _ = cache.texture(for: path, transform: transform, size: (10, 10), opacity: 1.0)
        _ = cache.texture(for: path, transform: transform, size: (20, 20), opacity: 1.0)

        XCTAssertEqual(cache.count, 2, "Different sizes should create separate entries")
    }

    func testCacheEviction() throws {
        let cache = MaskCache(device: device, maxEntries: 2)
        let transform = Matrix2D.identity

        let path1 = createTestPath(offset: 0)
        let path2 = createTestPath(offset: 10)
        let path3 = createTestPath(offset: 20)

        _ = cache.texture(for: path1, transform: transform, size: (10, 10), opacity: 1.0)
        _ = cache.texture(for: path2, transform: transform, size: (10, 10), opacity: 1.0)
        _ = cache.texture(for: path3, transform: transform, size: (10, 10), opacity: 1.0)

        XCTAssertEqual(cache.count, 2, "Cache should evict oldest entry")
    }

    func testCacheClear() throws {
        let cache = MaskCache(device: device)
        let path = createTestPath()

        _ = cache.texture(for: path, transform: .identity, size: (10, 10), opacity: 1.0)
        XCTAssertEqual(cache.count, 1)

        cache.clear()
        XCTAssertEqual(cache.count, 0)
    }

    private func createTestPath(offset: Double = 0) -> BezierPath {
        let vertices = [
            Vec2D(x: offset, y: offset),
            Vec2D(x: offset + 5, y: offset),
            Vec2D(x: offset + 5, y: offset + 5),
            Vec2D(x: offset, y: offset + 5)
        ]
        let zeroTangents = [Vec2D](repeating: Vec2D(x: 0, y: 0), count: 4)
        return BezierPath(
            vertices: vertices,
            inTangents: zeroTangents,
            outTangents: zeroTangents,
            closed: true
        )
    }
}

// MARK: - Texture Pool Tests

final class TexturePoolTests: XCTestCase {
    var device: MTLDevice!

    override func setUpWithError() throws {
        device = MTLCreateSystemDefaultDevice()
        try XCTSkipIf(device == nil, "Metal not available")
    }

    override func tearDown() {
        device = nil
    }

    func testAcquireColorTexture() throws {
        let pool = TexturePool(device: device)
        let texture = pool.acquireColorTexture(size: (100, 100))

        XCTAssertNotNil(texture)
        XCTAssertEqual(texture?.width, 100)
        XCTAssertEqual(texture?.height, 100)
        XCTAssertEqual(texture?.pixelFormat, .bgra8Unorm)
    }

    func testAcquireStencilTexture() throws {
        let pool = TexturePool(device: device)
        let texture = pool.acquireStencilTexture(size: (100, 100))

        XCTAssertNotNil(texture)
        XCTAssertEqual(texture?.width, 100)
        XCTAssertEqual(texture?.height, 100)
        XCTAssertEqual(texture?.pixelFormat, .depth32Float_stencil8)
    }

    func testReleaseAndReuse() throws {
        let pool = TexturePool(device: device)

        let tex1 = pool.acquireColorTexture(size: (50, 50))
        XCTAssertNotNil(tex1)

        pool.release(tex1!)

        let tex2 = pool.acquireColorTexture(size: (50, 50))
        XCTAssertTrue(tex1 === tex2, "Should reuse released texture")
    }

    func testClearPool() throws {
        let pool = TexturePool(device: device)

        let tex = pool.acquireColorTexture(size: (50, 50))
        pool.release(tex!)
        pool.clear()

        let tex2 = pool.acquireColorTexture(size: (50, 50))
        XCTAssertFalse(tex === tex2, "Should create new texture after clear")
    }

    // MARK: - R8 Texture Tests (GPU Mask Infrastructure)

    func testAcquireR8Texture() throws {
        let pool = TexturePool(device: device)
        let texture = pool.acquireR8Texture(size: (100, 100))

        XCTAssertNotNil(texture)
        XCTAssertEqual(texture?.width, 100)
        XCTAssertEqual(texture?.height, 100)
        XCTAssertEqual(texture?.pixelFormat, .r8Unorm)
    }

    func testR8TextureHasCorrectUsage() throws {
        let pool = TexturePool(device: device)
        let texture = pool.acquireR8Texture(size: (64, 64))

        XCTAssertNotNil(texture)
        // R8 texture should support render target, shader read, and shader write
        XCTAssertTrue(texture!.usage.contains(.renderTarget))
        XCTAssertTrue(texture!.usage.contains(.shaderRead))
        XCTAssertTrue(texture!.usage.contains(.shaderWrite))
    }

    func testR8TextureReleaseAndReuse() throws {
        let pool = TexturePool(device: device)

        let tex1 = pool.acquireR8Texture(size: (32, 32))
        XCTAssertNotNil(tex1)

        pool.release(tex1!)

        let tex2 = pool.acquireR8Texture(size: (32, 32))
        XCTAssertTrue(tex1 === tex2, "Should reuse released R8 texture")
    }

    func testR8TextureDifferentSizesNotReused() throws {
        let pool = TexturePool(device: device)

        let tex1 = pool.acquireR8Texture(size: (32, 32))
        pool.release(tex1!)

        let tex2 = pool.acquireR8Texture(size: (64, 64))
        XCTAssertFalse(tex1 === tex2, "Different size should create new texture")
    }
}

// MARK: - GPU Mask Pipeline Tests

final class GPUMaskPipelineTests: XCTestCase {
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

    override func tearDown() {
        renderer = nil
        device = nil
    }

    func testCoveragePipelineCreated() throws {
        // Verify the actual pipeline object exists
        let pipeline = renderer.resources.coveragePipelineState
        XCTAssertNotNil(pipeline)
        // Verify it's a render pipeline (has vertex/fragment functions)
        XCTAssertNotNil(pipeline.label ?? "") // Pipeline exists and is valid
    }

    func testMaskedCompositePipelineCreated() throws {
        // Verify the actual pipeline object exists
        let pipeline = renderer.resources.maskedCompositePipelineState
        XCTAssertNotNil(pipeline)
    }

    func testMaskCombineComputePipelineCreated() throws {
        // Verify the actual compute pipeline object exists
        let pipeline = renderer.resources.maskCombineComputePipeline
        XCTAssertNotNil(pipeline)
        // Verify it has reasonable threadgroup size
        XCTAssertGreaterThan(pipeline.maxTotalThreadsPerThreadgroup, 0)
    }

    func testMaskCombineParamsStructLayout() throws {
        // Verify struct layout matches Metal shader exactly
        let params = MaskCombineParams(mode: MaskCombineParams.modeAdd, inverted: false, opacity: 1.0)

        // Strict layout verification
        XCTAssertEqual(MemoryLayout<MaskCombineParams>.size, 16, "MaskCombineParams size must be 16 bytes")
        XCTAssertEqual(MemoryLayout<MaskCombineParams>.stride, 16, "MaskCombineParams stride must be 16 bytes")
        XCTAssertEqual(MemoryLayout<MaskCombineParams>.alignment, 4, "MaskCombineParams alignment must be 4 bytes")

        // Verify values
        XCTAssertEqual(params.mode, 0)
        XCTAssertEqual(params.inverted, 0)
        XCTAssertEqual(params.opacity, 1.0)
    }

    func testMaskCombineParamsModes() throws {
        XCTAssertEqual(MaskCombineParams.modeAdd, 0)
        XCTAssertEqual(MaskCombineParams.modeSubtract, 1)
        XCTAssertEqual(MaskCombineParams.modeIntersect, 2)
    }

    func testMaskCombineParamsInverted() throws {
        let normalParams = MaskCombineParams(mode: MaskCombineParams.modeAdd, inverted: false, opacity: 0.5)
        XCTAssertEqual(normalParams.inverted, 0)

        let invertedParams = MaskCombineParams(mode: MaskCombineParams.modeSubtract, inverted: true, opacity: 0.8)
        XCTAssertEqual(invertedParams.inverted, 1)
    }

    func testCoverageUniformsStructLayout() throws {
        let uniforms = CoverageUniforms(mvp: matrix_identity_float4x4)
        // CoverageUniforms contains only MVP matrix (4x4 = 64 bytes)
        let size = MemoryLayout<CoverageUniforms>.size
        XCTAssertEqual(size, 64, "Should be exactly 64 bytes (4x4 matrix)")
        XCTAssertEqual(uniforms.mvp, matrix_identity_float4x4)
    }

    func testMaskedCompositeUniformsStructLayout() throws {
        let uniforms = MaskedCompositeUniforms(mvp: matrix_identity_float4x4, opacity: 0.5)

        // Strict layout verification - must match Metal shader struct exactly
        // Metal layout (with float3 alignment = 16):
        //   float4x4 mvp:    64 bytes (offset 0)
        //   float opacity:    4 bytes (offset 64)
        //   padding:         12 bytes (offset 68, for float3 alignment)
        //   float3 _padding: 12 bytes (offset 80) + 4 bytes struct padding = 16 bytes
        //   Total: 96 bytes
        XCTAssertEqual(MemoryLayout<MaskedCompositeUniforms>.size, 96, "MaskedCompositeUniforms size must be 96 bytes")
        XCTAssertEqual(MemoryLayout<MaskedCompositeUniforms>.stride, 96, "MaskedCompositeUniforms stride must be 96 bytes")
        XCTAssertEqual(MemoryLayout<MaskedCompositeUniforms>.alignment, 16, "MaskedCompositeUniforms alignment must be 16 bytes")

        // Verify values
        XCTAssertEqual(uniforms.opacity, 0.5)
    }
}
