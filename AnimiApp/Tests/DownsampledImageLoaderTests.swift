import XCTest
import Metal
@testable import AnimiApp

/// Tests for DownsampledImageLoader.
final class DownsampledImageLoaderTests: XCTestCase {

    // MARK: - Downsample Dimension

    func test_loadTexture_respectsMaxDimensionPx() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            XCTSkip("Metal not available")
            return
        }

        // Create a temporary test image (100x100 red square)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_downsample_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try createTestImage(at: tempURL, width: 100, height: 100)

        // Load with maxDimensionPx = 50 — output should be ≤ 50 on longest side
        let texture = try DownsampledImageLoader.loadTexture(
            from: tempURL,
            device: device,
            commandQueue: commandQueue,
            maxDimensionPx: 50
        )

        XCTAssertLessThanOrEqual(texture.width, 50, "Width should be ≤ maxDimensionPx")
        XCTAssertLessThanOrEqual(texture.height, 50, "Height should be ≤ maxDimensionPx")
        XCTAssertEqual(texture.pixelFormat, .bgra8Unorm)
        XCTAssertEqual(texture.storageMode, .private)
    }

    func test_loadTexture_fullSize_whenMaxDimensionExceedsImage() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            XCTSkip("Metal not available")
            return
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_fullsize_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try createTestImage(at: tempURL, width: 64, height: 32)

        // Load with maxDimensionPx = 4096 — should load at full size
        let texture = try DownsampledImageLoader.loadTexture(
            from: tempURL,
            device: device,
            commandQueue: commandQueue,
            maxDimensionPx: 4096
        )

        XCTAssertEqual(texture.width, 64)
        XCTAssertEqual(texture.height, 32)
    }

    func test_loadTexture_invalidURL_throwsError() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            XCTSkip("Metal not available")
            return
        }

        let fakeURL = URL(fileURLWithPath: "/nonexistent/path/image.png")

        XCTAssertThrowsError(
            try DownsampledImageLoader.loadTexture(
                from: fakeURL,
                device: device,
                commandQueue: commandQueue,
                maxDimensionPx: 2048
            )
        ) { error in
            XCTAssertTrue(error is DownsampledImageLoader.LoadError)
        }
    }

    // MARK: - Helpers

    private func createTestImage(at url: URL, width: Int, height: Int) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw NSError(domain: "Test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create context"])
        }

        // Fill with red
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let cgImage = context.makeImage() else {
            throw NSError(domain: "Test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to make image"])
        }

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw NSError(domain: "Test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create destination"])
        }

        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "Test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to finalize"])
        }
    }
}
