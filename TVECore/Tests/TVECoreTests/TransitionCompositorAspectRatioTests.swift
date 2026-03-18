import XCTest
import Metal
@testable import TVECore

// MARK: - Local Test Helpers

private struct ARTestColor {
    let red, green, blue, alpha: UInt8

    static let red = ARTestColor(red: 255, green: 0, blue: 0, alpha: 255)
    static let green = ARTestColor(red: 0, green: 255, blue: 0, alpha: 255)
    static let blue = ARTestColor(red: 0, green: 0, blue: 255, alpha: 255)
    static let white = ARTestColor(red: 255, green: 255, blue: 255, alpha: 255)
    static let black = ARTestColor(red: 0, green: 0, blue: 0, alpha: 255)
}

private struct ARTestPoint {
    let x, y: Int
}

// MARK: - TransitionCompositorAspectRatioTests

/// TT-04: Tests for aspect-ratio parity in TransitionCompositor.
///
/// These tests verify that compositor uses the same contain mapping as MetalRenderer,
/// and that background is preserved outside the contained rect.
final class TransitionCompositorAspectRatioTests: XCTestCase {

    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var compositor: TransitionCompositor!

    override func setUpWithError() throws {
        device = MTLCreateSystemDefaultDevice()
        try XCTSkipIf(device == nil, "Metal not available")
        commandQueue = device.makeCommandQueue()
        try XCTSkipIf(commandQueue == nil, "Failed to create command queue")
        do {
            compositor = try TransitionCompositor(device: device, colorPixelFormat: .bgra8Unorm)
        } catch {
            // Metal library may not be available in SPM test environment
            throw XCTSkip("TransitionCompositor unavailable: \(error)")
        }
    }

    override func tearDown() {
        compositor = nil
        commandQueue = nil
        device = nil
    }

    // MARK: - Test: None transition preserves background

    /// Canvas: 100×100 (square), Target: 200×100 (wide)
    /// Scene: solid RED, Background: solid GREEN
    /// Expected: center=RED, pillarbox=GREEN
    func testNone_wideTarget_preservesBackgroundOutsideContainedRect() throws {
        // Setup textures
        let sceneTexture = try XCTUnwrap(createSolidColorTexture(color: ARTestColor.red, width: 100, height: 100))
        let target = try XCTUnwrap(createRenderableTexture(width: 200, height: 100))

        // Prefill target with GREEN background
        prefillTexture(target, with: ARTestColor.green)

        // Run compositor
        let cmdBuf = try XCTUnwrap(commandQueue.makeCommandBuffer())
        try compositor.composite(
            sceneA: sceneTexture,
            sceneB: sceneTexture,
            transition: .none,
            progress: 1.0,
            canvasSize: SizeD(width: 100, height: 100),
            target: target,
            commandBuffer: cmdBuf
        )
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        // Verify: center should be RED (scene content)
        // Canvas 100×100 in target 200×100 → pillarbox 50px on each side
        // Contained rect: x=50..150
        let centerPixel = readPixel(from: target, at: ARTestPoint(x: 100, y: 50))
        XCTAssertGreaterThan(centerPixel.red, 200, "Center should be RED (scene content)")
        XCTAssertLessThan(centerPixel.green, 50, "Center should not be GREEN")

        // Verify: left pillarbox should be GREEN (preserved background)
        let leftPillarbox = readPixel(from: target, at: ARTestPoint(x: 25, y: 50))
        XCTAssertGreaterThan(leftPillarbox.green, 200, "Left pillarbox should be GREEN (background)")
        XCTAssertLessThan(leftPillarbox.red, 50, "Left pillarbox should not be RED")

        // Verify: right pillarbox should be GREEN
        let rightPillarbox = readPixel(from: target, at: ARTestPoint(x: 175, y: 50))
        XCTAssertGreaterThan(rightPillarbox.green, 200, "Right pillarbox should be GREEN (background)")
        XCTAssertLessThan(rightPillarbox.red, 50, "Right pillarbox should not be RED")
    }

    // MARK: - Test: Fade blends only inside contained rect

    /// Canvas: 100×100, Target: 200×100 (wide)
    /// SceneA: RED, SceneB: BLUE, Background: GREEN
    /// Expected: center=blend, pillarbox=GREEN
    func testFade_wideTarget_blendsOnlyInsideContainedRect() throws {
        let sceneA = try XCTUnwrap(createSolidColorTexture(color: ARTestColor.red, width: 100, height: 100))
        let sceneB = try XCTUnwrap(createSolidColorTexture(color: ARTestColor.blue, width: 100, height: 100))
        let target = try XCTUnwrap(createRenderableTexture(width: 200, height: 100))

        // Prefill with GREEN
        prefillTexture(target, with: ARTestColor.green)

        let cmdBuf = try XCTUnwrap(commandQueue.makeCommandBuffer())
        try compositor.composite(
            sceneA: sceneA,
            sceneB: sceneB,
            transition: TransitionParams(type: .fade, easing: .linear),
            progress: 0.5,
            canvasSize: SizeD(width: 100, height: 100),
            target: target,
            commandBuffer: cmdBuf
        )
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        // Center should have blend of A and B (not pure red, not pure blue)
        let centerPixel = readPixel(from: target, at: ARTestPoint(x: 100, y: 50))
        // At 50% fade-over: A is full, B is 50% → result has red from A and some blue from B
        XCTAssertGreaterThan(centerPixel.red, 100, "Center should have RED from A")
        XCTAssertGreaterThan(centerPixel.blue, 50, "Center should have some BLUE from B")
        XCTAssertLessThan(centerPixel.green, 50, "Center should not be GREEN")

        // Pillarbox should be GREEN (preserved)
        let leftPillarbox = readPixel(from: target, at: ARTestPoint(x: 25, y: 50))
        XCTAssertGreaterThan(leftPillarbox.green, 200, "Pillarbox should remain GREEN")
        XCTAssertLessThan(leftPillarbox.red, 50, "Pillarbox should not have RED")
        XCTAssertLessThan(leftPillarbox.blue, 50, "Pillarbox should not have BLUE")
    }

    // MARK: - Test: Slide moves inside contain domain

    /// Canvas: 100×100, Target: 200×100 (wide)
    /// Slide left at progress=0.5: B should be partially in contained rect
    func testSlide_wideTarget_movesInsideContainDomain() throws {
        let sceneA = try XCTUnwrap(createSolidColorTexture(color: ARTestColor.red, width: 100, height: 100))
        let sceneB = try XCTUnwrap(createSolidColorTexture(color: ARTestColor.blue, width: 100, height: 100))
        let target = try XCTUnwrap(createRenderableTexture(width: 200, height: 100))

        prefillTexture(target, with: ARTestColor.green)

        let cmdBuf = try XCTUnwrap(commandQueue.makeCommandBuffer())
        try compositor.composite(
            sceneA: sceneA,
            sceneB: sceneB,
            transition: TransitionParams(type: .slide(direction: .left), easing: .linear),
            progress: 0.5,  // B is halfway in
            canvasSize: SizeD(width: 100, height: 100),
            target: target,
            commandBuffer: cmdBuf
        )
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        // At slide progress=0.5, B enters from left:
        // - B starts at -100 (canvas units), at 0.5 it's at -50
        // - In contained rect (50..150 in target), B covers 50..100, A covers 100..150

        // Right side of contained rect should still be A (RED)
        let rightOfContained = readPixel(from: target, at: ARTestPoint(x: 125, y: 50))
        XCTAssertGreaterThan(rightOfContained.red, 200, "Right of contained should be RED (A)")

        // Left pillarbox should still be GREEN (not B sliding into it)
        let leftPillarbox = readPixel(from: target, at: ARTestPoint(x: 25, y: 50))
        XCTAssertGreaterThan(leftPillarbox.green, 200, "Left pillarbox should remain GREEN")
        XCTAssertLessThan(leftPillarbox.blue, 50, "B should not slide into pillarbox")
    }

    // MARK: - Test: Push moves inside contain domain (tall target)

    /// Canvas: 100×100, Target: 100×200 (tall, letterbox case)
    /// Push down: both A and B move in contained rect
    func testPush_tallTarget_movesInsideContainDomain() throws {
        let sceneA = try XCTUnwrap(createSolidColorTexture(color: ARTestColor.red, width: 100, height: 100))
        let sceneB = try XCTUnwrap(createSolidColorTexture(color: ARTestColor.blue, width: 100, height: 100))
        let target = try XCTUnwrap(createRenderableTexture(width: 100, height: 200))

        prefillTexture(target, with: ARTestColor.green)

        let cmdBuf = try XCTUnwrap(commandQueue.makeCommandBuffer())
        try compositor.composite(
            sceneA: sceneA,
            sceneB: sceneB,
            transition: TransitionParams(type: .push(direction: .down), easing: .linear),
            progress: 0.5,
            canvasSize: SizeD(width: 100, height: 100),
            target: target,
            commandBuffer: cmdBuf
        )
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        // Canvas 100×100 in target 100×200 → letterbox 50px top/bottom
        // Contained rect: y=50..150

        // Top letterbox should be GREEN
        let topLetterbox = readPixel(from: target, at: ARTestPoint(x: 50, y: 25))
        XCTAssertGreaterThan(topLetterbox.green, 200, "Top letterbox should be GREEN")
        XCTAssertLessThan(topLetterbox.red, 50, "Top letterbox should not have A")
        XCTAssertLessThan(topLetterbox.blue, 50, "Top letterbox should not have B")

        // Bottom letterbox should be GREEN
        let bottomLetterbox = readPixel(from: target, at: ARTestPoint(x: 50, y: 175))
        XCTAssertGreaterThan(bottomLetterbox.green, 200, "Bottom letterbox should be GREEN")
    }

    // MARK: - Test: DipToBlack preserves background

    /// Canvas: 100×100, Target: 200×100 (wide)
    /// DipToBlack: dip effect inside contained rect, pillarbox=GREEN
    func testDipToBlack_preservesBackgroundOutsideContainedRect() throws {
        let sceneA = try XCTUnwrap(createSolidColorTexture(color: ARTestColor.red, width: 100, height: 100))
        let sceneB = try XCTUnwrap(createSolidColorTexture(color: ARTestColor.blue, width: 100, height: 100))
        let target = try XCTUnwrap(createRenderableTexture(width: 200, height: 100))

        prefillTexture(target, with: ARTestColor.green)

        let cmdBuf = try XCTUnwrap(commandQueue.makeCommandBuffer())
        try compositor.composite(
            sceneA: sceneA,
            sceneB: sceneB,
            transition: TransitionParams(type: .dipToBlack, easing: .linear),
            progress: 0.5,  // At midpoint, should be mostly black
            canvasSize: SizeD(width: 100, height: 100),
            target: target,
            commandBuffer: cmdBuf
        )
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        // Center should have dip effect (dark, not pure red/blue)
        let centerPixel = readPixel(from: target, at: ARTestPoint(x: 100, y: 50))
        // At progress=0.5, dip is at maximum darkness
        let centerBrightness = Int(centerPixel.red) + Int(centerPixel.green) + Int(centerPixel.blue)
        XCTAssertLessThan(centerBrightness, 400, "Center should be dark (dip effect)")

        // Pillarbox should be GREEN (not black fullscreen overlay!)
        let leftPillarbox = readPixel(from: target, at: ARTestPoint(x: 25, y: 50))
        XCTAssertGreaterThan(leftPillarbox.green, 200, "Pillarbox should remain GREEN")
        // If dip was fullscreen, pillarbox would be black
        XCTAssertGreaterThan(
            Int(leftPillarbox.green),
            Int(leftPillarbox.red) + Int(leftPillarbox.blue),
            "Pillarbox should not be affected by dip"
        )
    }

    // MARK: - Test: Odd-size targets (fractional contained rect)

    /// Canvas: 100×100, Target: 101×100 (odd width)
    /// Contained rect: x=0.5...100.5 (fractional)
    /// Scissor must use floor/ceil to include edge pixels
    ///
    /// Key test: with incorrect rounded() scissor would be x=1,w=100, cutting off x=0.
    /// With correct floor/ceil scissor is x=0,w=101, allowing x=0 to be rendered.
    func testNone_oddWidthTarget_leftEdgeNotClipped() throws {
        let sceneTexture = try XCTUnwrap(createSolidColorTexture(color: ARTestColor.red, width: 100, height: 100))
        let target = try XCTUnwrap(createRenderableTexture(width: 101, height: 100))

        // Prefill with GREEN
        prefillTexture(target, with: ARTestColor.green)

        let cmdBuf = try XCTUnwrap(commandQueue.makeCommandBuffer())
        try compositor.composite(
            sceneA: sceneTexture,
            sceneB: sceneTexture,
            transition: .none,
            progress: 1.0,
            canvasSize: SizeD(width: 100, height: 100),
            target: target,
            commandBuffer: cmdBuf
        )
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        // Canvas 100×100 in target 101×100:
        // offsetX = 0.5, contained rect: 0.5...100.5
        // With floor/ceil scissor: x=0, w=101
        // Quad covers pixels 0-100 (partially for edge pixels)

        // Left edge (x=0) must NOT be clipped by scissor.
        // Pixel x=0 has center at 0.5, quad starts at 0.5, so it's at least partially covered.
        // With wrong scissor (x=1), this pixel would be completely GREEN (background).
        let leftEdge = readPixel(from: target, at: ARTestPoint(x: 0, y: 50))
        // The pixel should have at least SOME red (partial coverage), not pure green
        XCTAssertGreaterThan(leftEdge.red, 0, "Left edge (x=0) should not be clipped by scissor")

        // Center should definitely be RED
        let center = readPixel(from: target, at: ARTestPoint(x: 50, y: 50))
        XCTAssertGreaterThan(center.red, 200, "Center should be RED from scene")
    }

    /// Canvas: 100×100, Target: 100×101 (odd height)
    /// Contained rect: y=0.5...100.5 (fractional)
    func testNone_oddHeightTarget_topEdgeNotClipped() throws {
        let sceneTexture = try XCTUnwrap(createSolidColorTexture(color: ARTestColor.red, width: 100, height: 100))
        let target = try XCTUnwrap(createRenderableTexture(width: 100, height: 101))

        prefillTexture(target, with: ARTestColor.green)

        let cmdBuf = try XCTUnwrap(commandQueue.makeCommandBuffer())
        try compositor.composite(
            sceneA: sceneTexture,
            sceneB: sceneTexture,
            transition: .none,
            progress: 1.0,
            canvasSize: SizeD(width: 100, height: 100),
            target: target,
            commandBuffer: cmdBuf
        )
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        // Canvas 100×100 in target 100×101:
        // offsetY = 0.5, contained rect: 0.5...100.5
        // With floor/ceil scissor: y=0, h=101

        // Top edge (y=0) must NOT be clipped by scissor.
        let topEdge = readPixel(from: target, at: ARTestPoint(x: 50, y: 0))
        XCTAssertGreaterThan(topEdge.red, 0, "Top edge (y=0) should not be clipped by scissor")

        // Center should definitely be RED
        let center = readPixel(from: target, at: ARTestPoint(x: 50, y: 50))
        XCTAssertGreaterThan(center.red, 200, "Center should be RED from scene")
    }

    // MARK: - Test: Determinism

    func testDeterminism_sameInputsSameBytes() throws {
        let sceneA = try XCTUnwrap(createSolidColorTexture(color: ARTestColor.red, width: 100, height: 100))
        let sceneB = try XCTUnwrap(createSolidColorTexture(color: ARTestColor.blue, width: 100, height: 100))

        let target1 = try XCTUnwrap(createRenderableTexture(width: 200, height: 100))
        let target2 = try XCTUnwrap(createRenderableTexture(width: 200, height: 100))

        prefillTexture(target1, with: ARTestColor.green)
        prefillTexture(target2, with: ARTestColor.green)

        // First run
        let cmdBuf1 = try XCTUnwrap(commandQueue.makeCommandBuffer())
        try compositor.composite(
            sceneA: sceneA,
            sceneB: sceneB,
            transition: TransitionParams(type: .fade, easing: .easeInOut),
            progress: 0.7,
            canvasSize: SizeD(width: 100, height: 100),
            target: target1,
            commandBuffer: cmdBuf1
        )
        cmdBuf1.commit()
        cmdBuf1.waitUntilCompleted()

        // Second run
        let cmdBuf2 = try XCTUnwrap(commandQueue.makeCommandBuffer())
        try compositor.composite(
            sceneA: sceneA,
            sceneB: sceneB,
            transition: TransitionParams(type: .fade, easing: .easeInOut),
            progress: 0.7,
            canvasSize: SizeD(width: 100, height: 100),
            target: target2,
            commandBuffer: cmdBuf2
        )
        cmdBuf2.commit()
        cmdBuf2.waitUntilCompleted()

        // Compare all pixels
        let bytes1 = readAllPixels(from: target1, width: 200, height: 100)
        let bytes2 = readAllPixels(from: target2, width: 200, height: 100)
        XCTAssertEqual(bytes1, bytes2, "Two identical compositor runs should produce identical bytes")
    }

    // MARK: - Local Helpers

    private func createSolidColorTexture(color: ARTestColor, width: Int, height: Int) -> MTLTexture? {
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
            pixels[idx] = color.blue      // BGRA format
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

    private func createRenderableTexture(width: Int, height: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        return device.makeTexture(descriptor: desc)
    }

    /// Prefills texture with solid color (simulates background already rendered)
    private func prefillTexture(_ texture: MTLTexture, with color: ARTestColor) {
        let width = texture.width
        let height = texture.height
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
    }

    private func readPixel(from texture: MTLTexture, at point: ARTestPoint) -> ARTestColor {
        var pixel: [UInt8] = [0, 0, 0, 0]
        texture.getBytes(
            &pixel, bytesPerRow: 4,
            from: MTLRegionMake2D(point.x, point.y, 1, 1), mipmapLevel: 0
        )
        // BGRA → RGB
        return ARTestColor(red: pixel[2], green: pixel[1], blue: pixel[0], alpha: pixel[3])
    }

    private func readAllPixels(from texture: MTLTexture, width: Int, height: Int) -> [UInt8] {
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(
            &bytes, bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0
        )
        return bytes
    }
}
