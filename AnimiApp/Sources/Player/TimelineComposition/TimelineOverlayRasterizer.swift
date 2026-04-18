import CoreGraphics
import ImageIO
import Metal
import TVECore
import UIKit

// MARK: - Thread-safe Sticker Image Cache

/// Thread-safe CGImage cache for sticker overlays.
/// Uses NSLock (not actor) because it's called synchronously from the render path.
internal final class StickerImageCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [URL: CGImage] = [:]

    func image(for url: URL) -> CGImage? {
        lock.lock()
        if let cached = cache[url] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Load outside lock to avoid holding it during disk I/O
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let loaded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        lock.lock()
        cache[url] = loaded
        lock.unlock()
        return loaded
    }
}

// MARK: - Overlay Rasterizer

/// CPU-rasterizes text and sticker overlays into a standalone MTLTexture
/// with `.shared` storage. The caller composites this onto the render target
/// via a GPU draw pass, avoiding `getBytes`/`replace` on potentially `.private` textures.
internal enum TimelineOverlayRasterizer {

    /// Rasterizes stickers and text into an offscreen BGRA texture.
    /// Returns `nil` if both arrays are empty (fast path — no GPU work needed).
    static func makeOverlayTexture(
        stickers: [ResolvedStickerOverlay],
        texts: [ResolvedTextOverlay],
        pixelWidth: Int,
        pixelHeight: Int,
        animSize: SizeD,
        device: MTLDevice,
        stickerCache: StickerImageCache
    ) -> MTLTexture? {
        guard (!stickers.isEmpty || !texts.isEmpty),
              pixelWidth > 0, pixelHeight > 0 else { return nil }

        let bytesPerRow = pixelWidth * 4
        let dataSize = bytesPerRow * pixelHeight

        // Zeroed buffer = transparent black
        var pixelBuffer = [UInt8](repeating: 0, count: dataSize)

        // Use RGBA (premultipliedLast) for CGContext — UIKit/CoreText require this format.
        // After rasterization, swap R↔B to produce BGRA matching bgra8Unorm.
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let cgContext = CGContext(
            data: &pixelBuffer,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Flip coordinates (CG bottom-left → Metal top-left)
        cgContext.translateBy(x: 0, y: CGFloat(pixelHeight))
        cgContext.scaleBy(x: 1, y: -1)

        // Push CG context for UIKit/NSString drawing
        UIGraphicsPushContext(cgContext)
        defer { UIGraphicsPopContext() }

        // Draw stickers first (below text)
        for overlay in stickers {
            guard let cgImage = stickerCache.image(for: overlay.imageURL) else { continue }

            // Render size: 15% of canvas pixel width, aspect-fit
            let targetWidth = CGFloat(pixelWidth) * 0.15
            let imageAspect = CGFloat(cgImage.width) / max(1, CGFloat(cgImage.height))
            let drawWidth: CGFloat
            let drawHeight: CGFloat
            if imageAspect >= 1.0 {
                drawWidth = targetWidth
                drawHeight = targetWidth / imageAspect
            } else {
                drawHeight = targetWidth
                drawWidth = targetWidth * imageAspect
            }

            let x = CGFloat(overlay.centerX) * CGFloat(pixelWidth) - drawWidth / 2
            let y = CGFloat(overlay.centerY) * CGFloat(pixelHeight) - drawHeight / 2
            cgContext.draw(cgImage, in: CGRect(x: x, y: y, width: drawWidth, height: drawHeight))
        }

        // Draw text second (above stickers)
        for overlay in texts {
            let scale = CGFloat(pixelWidth) / CGFloat(animSize.width)
            let fontSize = overlay.fontSize * scale

            let font: UIFont
            if let family = overlay.fontFamily {
                font = UIFont(name: family, size: fontSize) ?? .boldSystemFont(ofSize: fontSize)
            } else {
                font = .boldSystemFont(ofSize: fontSize)
            }
            let color = UIColor(overlayHexString: overlay.colorHex) ?? .white

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
            ]

            let nsString = overlay.text as NSString
            let textSize = nsString.size(withAttributes: attributes)

            let x = CGFloat(overlay.centerX) * CGFloat(pixelWidth) - textSize.width / 2
            let y = CGFloat(overlay.centerY) * CGFloat(pixelHeight) - textSize.height / 2
            nsString.draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
        }

        // Swap R↔B: RGBA → BGRA to match bgra8Unorm
        for i in stride(from: 0, to: dataSize, by: 4) {
            let r = pixelBuffer[i]
            pixelBuffer[i] = pixelBuffer[i + 2]
            pixelBuffer[i + 2] = r
        }

        // Create .shared texture and upload pixel data
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: pixelWidth,
            height: pixelHeight,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead

        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        texture.replace(
            region: MTLRegionMake2D(0, 0, pixelWidth, pixelHeight),
            mipmapLevel: 0,
            withBytes: pixelBuffer,
            bytesPerRow: bytesPerRow
        )

        return texture
    }
}

// MARK: - UIColor Hex Helper

internal extension UIColor {
    convenience init?(overlayHexString hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        hex = hex.replacingOccurrences(of: "#", with: "")
        guard hex.count == 6 else { return nil }

        var rgb: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgb)

        self.init(
            red: CGFloat((rgb & 0xFF0000) >> 16) / 255.0,
            green: CGFloat((rgb & 0x00FF00) >> 8) / 255.0,
            blue: CGFloat(rgb & 0x0000FF) / 255.0,
            alpha: 1.0
        )
    }
}
