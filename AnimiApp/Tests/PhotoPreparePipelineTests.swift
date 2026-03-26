import XCTest
import ImageIO
import CoreGraphics
@testable import AnimiApp

/// Tests for PhotoPreparePipeline (ImageIO-based file-to-file photo preparation).
final class PhotoPreparePipelineTests: XCTestCase {

    // MARK: - Large Image Downsample

    /// Large image (4000x3000) should be downsampled to ≤ 2048 on longest side.
    func test_prepare_largeImage_downsamplesTo2048() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_large_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try createTestImage(at: tempURL, width: 4000, height: 3000)

        let resultURL = try PhotoPreparePipeline.prepare(fileURL: tempURL)
        defer { try? FileManager.default.removeItem(at: resultURL) }

        // Verify output is JPEG
        XCTAssertEqual(resultURL.pathExtension, "jpg")

        // Verify dimensions ≤ 2048
        guard let imageSource = CGImageSourceCreateWithURL(resultURL as CFURL, nil) else {
            XCTFail("Failed to create image source from result")
            return
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0

        XCTAssertLessThanOrEqual(max(width, height), 2048,
                                 "Longest side should be ≤ 2048, got \(width)x\(height)")
        XCTAssertGreaterThan(width, 0)
        XCTAssertGreaterThan(height, 0)
    }

    // MARK: - Small Image No Upscale

    /// Small image (100x50) should NOT be upscaled — output ≤ original dimensions.
    func test_prepare_smallImage_noUpscale() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_small_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try createTestImage(at: tempURL, width: 100, height: 50)

        let resultURL = try PhotoPreparePipeline.prepare(fileURL: tempURL)
        defer { try? FileManager.default.removeItem(at: resultURL) }

        guard let imageSource = CGImageSourceCreateWithURL(resultURL as CFURL, nil) else {
            XCTFail("Failed to create image source from result")
            return
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0

        XCTAssertLessThanOrEqual(width, 100, "Width should not exceed original (100)")
        XCTAssertLessThanOrEqual(height, 50, "Height should not exceed original (50)")
        XCTAssertGreaterThan(width, 0)
        XCTAssertGreaterThan(height, 0)
    }

    // MARK: - Invalid File

    /// Non-existent file should throw failedToCreateImageSource.
    func test_prepare_invalidFile_throwsFailedToCreateImageSource() {
        let fakeURL = URL(fileURLWithPath: "/nonexistent/path/image.png")

        XCTAssertThrowsError(try PhotoPreparePipeline.prepare(fileURL: fakeURL)) { error in
            guard let prepareError = error as? PhotoPrepareError else {
                XCTFail("Expected PhotoPrepareError, got \(error)")
                return
            }
            XCTAssertEqual(prepareError, .failedToCreateImageSource)
        }
    }

    // MARK: - Unreadable File (corrupted data)

    /// File with non-image data should throw failedToCreateImageSource or failedToCreateThumbnail.
    func test_prepare_unreadableFile_throwsError() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_corrupt_\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Write garbage data
        try Data([0xDE, 0xAD, 0xBE, 0xEF]).write(to: tempURL)

        XCTAssertThrowsError(try PhotoPreparePipeline.prepare(fileURL: tempURL)) { error in
            guard let prepareError = error as? PhotoPrepareError else {
                XCTFail("Expected PhotoPrepareError, got \(error)")
                return
            }
            // Either error is acceptable for corrupt data
            XCTAssertTrue(
                prepareError == .failedToCreateImageSource || prepareError == .failedToCreateThumbnail,
                "Expected failedToCreateImageSource or failedToCreateThumbnail, got \(prepareError)"
            )
        }
    }

    // MARK: - Helpers

    /// Creates a test image on disk using CGContext + CGImageDestination.
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
