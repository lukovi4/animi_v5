import XCTest
import CoreGraphics
@testable import TVECore

/// Tests for PremultipliedTextureLoader CPU conversion.
///
/// These tests verify that straight-alpha pixels are correctly converted
/// to premultiplied alpha format, which is required for correct compositing
/// with premultiplied blending (src.rgb + dst.rgb * (1 - src.a)).
final class PremultipliedTextureLoaderTests: XCTestCase {

    // MARK: - CPU Premultiply Correctness Tests

    /// Test per ТЗ: straight alpha pixel (R=255, G=0, B=0, A=128) → premult (R=128, G=0, B=0, A=128)
    ///
    /// Formula: outR = inR * inA / 255 = 255 * 128 / 255 = 128
    func testPremultiply_straightAlphaRedPixel_convertsCorrectly() throws {
        // Create 1x1 CGImage with straight alpha: RGB=(255,0,0), A=128
        let cgImage = try createStraightAlphaImage(
            width: 1, height: 1,
            red: 255, green: 0, blue: 0, alpha: 128
        )

        // Convert to premultiplied BGRA
        let bytes = try PremultipliedTextureLoader.renderToPremultipliedBGRA(cgImage: cgImage)

        // BGRA order: bytes[0]=B, bytes[1]=G, bytes[2]=R, bytes[3]=A
        let outB = bytes[0]
        let outG = bytes[1]
        let outR = bytes[2]
        let outA = bytes[3]

        // Expected: R = 255 * 128 / 255 ≈ 128 (±1 for rounding)
        XCTAssertEqual(outR, 128, accuracy: 1, "Red should be premultiplied: 255 * 128/255 ≈ 128")
        XCTAssertEqual(outG, 0, accuracy: 1, "Green should remain 0")
        XCTAssertEqual(outB, 0, accuracy: 1, "Blue should remain 0")
        XCTAssertEqual(outA, 128, "Alpha should be preserved")
    }

    /// Test: fully transparent pixel should have RGB = 0 after premultiply
    func testPremultiply_fullyTransparent_rgbBecomesZero() throws {
        // Create 1x1 CGImage with straight alpha: RGB=(255,255,255), A=0
        let cgImage = try createStraightAlphaImage(
            width: 1, height: 1,
            red: 255, green: 255, blue: 255, alpha: 0
        )

        let bytes = try PremultipliedTextureLoader.renderToPremultipliedBGRA(cgImage: cgImage)

        let outB = bytes[0]
        let outG = bytes[1]
        let outR = bytes[2]
        let outA = bytes[3]

        // Fully transparent: RGB should be 0 (255 * 0/255 = 0)
        XCTAssertEqual(outR, 0, "Red should be 0 when alpha=0")
        XCTAssertEqual(outG, 0, "Green should be 0 when alpha=0")
        XCTAssertEqual(outB, 0, "Blue should be 0 when alpha=0")
        XCTAssertEqual(outA, 0, "Alpha should be 0")
    }

    /// Test: fully opaque pixel should have RGB unchanged after premultiply
    func testPremultiply_fullyOpaque_rgbUnchanged() throws {
        // Create 1x1 CGImage with straight alpha: RGB=(100,150,200), A=255
        let cgImage = try createStraightAlphaImage(
            width: 1, height: 1,
            red: 100, green: 150, blue: 200, alpha: 255
        )

        let bytes = try PremultipliedTextureLoader.renderToPremultipliedBGRA(cgImage: cgImage)

        let outB = bytes[0]
        let outG = bytes[1]
        let outR = bytes[2]
        let outA = bytes[3]

        // Fully opaque: RGB should be unchanged (value * 255/255 = value)
        XCTAssertEqual(outR, 100, accuracy: 1, "Red should be unchanged when alpha=255")
        XCTAssertEqual(outG, 150, accuracy: 1, "Green should be unchanged when alpha=255")
        XCTAssertEqual(outB, 200, accuracy: 1, "Blue should be unchanged when alpha=255")
        XCTAssertEqual(outA, 255, "Alpha should be 255")
    }

    /// Test: 2x2 image with gradient alpha
    ///
    /// Image layout (row-major, no flip):
    ///   bytes[0..7]:  Row 0 → (0,0) red A=64,    (1,0) green A=128
    ///   bytes[8..15]: Row 1 → (0,1) blue A=192,  (1,1) white A=255
    func testPremultiply_2x2GradientAlpha_allPixelsCorrect() throws {
        // Create 2x2 image with different alpha values
        let cgImage = try create2x2GradientAlphaImage()

        let bytes = try PremultipliedTextureLoader.renderToPremultipliedBGRA(cgImage: cgImage)

        // Pixel layout in memory (row-major, BGRA):
        // bytes[0..3]:  (0,0) red
        // bytes[4..7]:  (1,0) green
        // bytes[8..11]: (0,1) blue
        // bytes[12..15]: (1,1) white

        // Pixel (0,0) red at bytes[0..3]: RGB=(255,0,0), A=64 → R = 255*64/255 ≈ 64
        let p00_R = bytes[2]
        let p00_A = bytes[3]
        XCTAssertEqual(p00_R, 64, accuracy: 1, "Pixel(0,0) R should be ~64")
        XCTAssertEqual(p00_A, 64, "Pixel(0,0) A should be 64")

        // Pixel (1,0) green at bytes[4..7]: RGB=(0,255,0), A=128 → G = 255*128/255 ≈ 128
        let p10_G = bytes[5]
        let p10_A = bytes[7]
        XCTAssertEqual(p10_G, 128, accuracy: 1, "Pixel(1,0) G should be ~128")
        XCTAssertEqual(p10_A, 128, "Pixel(1,0) A should be 128")

        // Pixel (0,1) blue at bytes[8..11]: RGB=(0,0,255), A=192 → B = 255*192/255 ≈ 192
        let p01_B = bytes[8]
        let p01_A = bytes[11]
        XCTAssertEqual(p01_B, 192, accuracy: 1, "Pixel(0,1) B should be ~192")
        XCTAssertEqual(p01_A, 192, "Pixel(0,1) A should be 192")

        // Pixel (1,1) white at bytes[12..15]: RGB=(255,255,255), A=255 → unchanged
        let p11_R = bytes[14]
        let p11_A = bytes[15]
        XCTAssertEqual(p11_R, 255, accuracy: 1, "Pixel(1,1) R should be 255")
        XCTAssertEqual(p11_A, 255, "Pixel(1,1) A should be 255")
    }

    // MARK: - hasAlpha Tests

    func testHasAlpha_rgbaImage_returnsTrue() throws {
        let cgImage = try createStraightAlphaImage(width: 1, height: 1, red: 255, green: 0, blue: 0, alpha: 128)
        XCTAssertTrue(PremultipliedTextureLoader.hasAlpha(cgImage), "RGBA image should have alpha")
    }

    func testHasAlpha_rgbImage_returnsFalse() throws {
        let cgImage = try createOpaqueRGBImage(width: 1, height: 1, red: 255, green: 0, blue: 0)
        XCTAssertFalse(PremultipliedTextureLoader.hasAlpha(cgImage), "RGB image should not have alpha")
    }

    // MARK: - Test Helpers

    /// Creates a CGImage with straight (non-premultiplied) alpha via CGDataProvider.
    ///
    /// Note: CGContext doesn't support straight alpha directly, so we create the
    /// image via CGDataProvider which preserves the raw pixel data as-is.
    private func createStraightAlphaImage(
        width: Int, height: Int,
        red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8
    ) throws -> CGImage {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = red
            pixels[i + 1] = green
            pixels[i + 2] = blue
            pixels[i + 3] = alpha
        }

        // Create CGImage directly via CGDataProvider (preserves straight alpha)
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else {
            throw TestError.failedToCreateProvider
        }

        // RGBA with straight alpha (.last)
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)

        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw TestError.failedToCreateImage
        }

        return cgImage
    }

    /// Creates a 2x2 CGImage with gradient alpha for testing multiple pixels.
    private func create2x2GradientAlphaImage() throws -> CGImage {
        let width = 2
        let height = 2
        let bytesPerRow = width * 4

        // RGBA straight alpha pixels:
        // (0,0): R=255,G=0,B=0,A=64   (red, 25% opaque)
        // (1,0): R=0,G=255,B=0,A=128  (green, 50% opaque)
        // (0,1): R=0,G=0,B=255,A=192  (blue, 75% opaque)
        // (1,1): R=255,G=255,B=255,A=255 (white, fully opaque)
        let pixels: [UInt8] = [
            // Row 0
            255, 0, 0, 64,      // (0,0) red
            0, 255, 0, 128,     // (1,0) green
            // Row 1
            0, 0, 255, 192,     // (0,1) blue
            255, 255, 255, 255  // (1,1) white
        ]

        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else {
            throw TestError.failedToCreateProvider
        }

        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)

        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw TestError.failedToCreateImage
        }

        return cgImage
    }

    /// Creates a 1x1 opaque RGB image (no alpha channel).
    private func createOpaqueRGBImage(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) throws -> CGImage {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = red
            pixels[i + 1] = green
            pixels[i + 2] = blue
            pixels[i + 3] = 255  // Ignored due to noneSkipLast
        }

        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else {
            throw TestError.failedToCreateProvider
        }

        // No alpha (alphaInfo = .noneSkipLast means RGBX)
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)

        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw TestError.failedToCreateImage
        }

        return cgImage
    }

    private enum TestError: Error {
        case failedToCreateContext
        case failedToCreateImage
        case failedToCreateProvider
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
