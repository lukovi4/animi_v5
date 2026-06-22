#if DEBUG
import XCTest
import CoreGraphics
@testable import AnimiApp

/// CP7.7-next — SYNTHETIC regression for the video-bake opaque-alpha contract.
///
/// User H.264 video carries no authored alpha; it is opaque. The decoded BGRA alpha byte is not guaranteed
/// 255, so `NextVideoBlockResolver.bake` forces opaque `A = 255` (draws into a `noneSkipFirst` context and
/// sets the alpha lane), guaranteeing every baked pixel is valid premultiplied (`B,G,R ≤ A`, `A == 255`).
///
/// This is a SYNTHETIC contract test using hand-built `CGImage`s — it is NOT a proof of the on-device
/// VideoToolbox decode path (no `VTCreateCGImageFromCVPixelBuffer` / real `.mov` here). It pins the bake's
/// output contract: regardless of the source image's alpha byte, the baked frame is opaque + valid
/// premultiplied.
final class NextVideoBakeAlphaContractTests: XCTestCase {

    /// Build a synthetic `CGImage` with opaque RGB content but a chosen ALPHA byte (possibly < 255), to
    /// stand in for a decoder buffer whose alpha lane is not 255.
    private func makeImageWithAlpha(_ alphaByte: UInt8, w: Int, h: Int) throws -> CGImage {
        let bpr = w * 4
        var bytes = [UInt8](repeating: 0, count: bpr * h)
        for y in 0..<h {
            for x in 0..<w {
                let o = y * bpr + x * 4
                bytes[o + 0] = 255          // B
                bytes[o + 1] = 0            // G
                bytes[o + 2] = 255          // R
                bytes[o + 3] = alphaByte    // A
            }
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let bmp = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.first.rawValue
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
                       space: cs, bitmapInfo: CGBitmapInfo(rawValue: bmp), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// Count baked pixels where max(B,G,R) > A (invalid premultiplied).
    private func countRGBgtA(_ baked: (bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int)) -> Int {
        var n = 0
        for y in 0..<baked.height {
            for x in 0..<baked.width {
                let o = y * baked.bytesPerRow + x * 4
                let b = baked.bytes[o + 0], g = baked.bytes[o + 1], r = baked.bytes[o + 2], a = baked.bytes[o + 3]
                if Int(max(b, max(g, r))) > Int(a) { n += 1 }
            }
        }
        return n
    }

    /// Contract: regardless of the source image's alpha byte, the bake forces opaque `A = 255` and produces
    /// valid premultiplied pixels (`B,G,R ≤ A`).
    func test_bake_forcesOpaqueAlpha_andValidPremultiplied() throws {
        for alphaByte: UInt8 in [255, 128, 0] {
            let img = try makeImageWithAlpha(alphaByte, w: 16, h: 16)
            let baked = try NextVideoBlockResolver.bake(
                cgImage: img, quarter: 0, maxPixelSize: 16, url: URL(fileURLWithPath: "/synthetic.mp4"))
            for y in 0..<baked.height {
                for x in 0..<baked.width {
                    let o = y * baked.bytesPerRow + x * 4
                    let b = baked.bytes[o + 0], g = baked.bytes[o + 1], r = baked.bytes[o + 2], a = baked.bytes[o + 3]
                    XCTAssertEqual(a, 255, "video bake must force opaque A=255 (src alpha \(alphaByte)) at (\(x),\(y))")
                    XCTAssertLessThanOrEqual(b, a, "B ≤ A")
                    XCTAssertLessThanOrEqual(g, a, "G ≤ A")
                    XCTAssertLessThanOrEqual(r, a, "R ≤ A")
                }
            }
            XCTAssertEqual(countRGBgtA(baked), 0, "no rgb>alpha pixels after the opaque bake (src alpha \(alphaByte))")
        }
    }
}
#endif
