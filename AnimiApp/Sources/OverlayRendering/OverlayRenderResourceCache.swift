import CoreGraphics
import Foundation
import ImageIO
import Metal
import TVECore
import UIKit

/// Per-owner texture cache for overlay content.
/// Preview and export each own separate instances — shared type and algorithm, not state.
///
/// Thread-safe via NSLock (called synchronously from render path).
/// LRU eviction with max 32 entries.
internal final class OverlayRenderResourceCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [CacheKey: CachedEntry] = [:]
    private var accessOrder: [CacheKey] = []

    /// Max resident textures. Typical overlay count = 1-5, so 32 is generous.
    static let maxEntries = 32

    /// Cache key excludes stableId and position — two items with identical
    /// content/style share one cached texture.
    enum CacheKey: Hashable {
        /// Text: content descriptor + canvasPixelWidth (font scaling depends on canvas size).
        case text(content: ResolvedOverlayRenderItem.ContentDescriptor, canvasPixelWidth: Int)
        /// Sticker: content descriptor only (native resolution, GPU-scaled).
        case sticker(content: ResolvedOverlayRenderItem.ContentDescriptor)
    }

    struct CachedEntry {
        let texture: MTLTexture
        /// Content width in pixels (tight bounding box for text, native for sticker).
        let contentWidth: Int
        /// Content height in pixels (tight bounding box for text, native for sticker).
        let contentHeight: Int
    }

    /// Returns a cached texture for the item, or rasterizes/loads on cache miss.
    /// Returns `nil` if rasterization/loading fails.
    func texture(
        for item: ResolvedOverlayRenderItem,
        device: MTLDevice,
        canvasSize: SizeD,
        canvasPixelWidth: Int
    ) -> CachedEntry? {
        let key: CacheKey
        switch item.kind {
        case .text:
            key = .text(content: item.content, canvasPixelWidth: canvasPixelWidth)
        case .sticker:
            key = .sticker(content: item.content)
        }

        lock.lock()
        if let existing = entries[key] {
            // Move to end of access order (most recently used)
            if let idx = accessOrder.firstIndex(of: key) {
                accessOrder.remove(at: idx)
            }
            accessOrder.append(key)
            lock.unlock()
            return existing
        }
        lock.unlock()

        // Cache miss — rasterize/load outside lock
        let entry: CachedEntry?
        switch item.content {
        case .text(let text, let fontFamily, let fontSize, let colorHex):
            entry = rasterizeText(
                text: text, fontFamily: fontFamily, fontSize: fontSize, colorHex: colorHex,
                device: device, canvasSize: canvasSize, canvasPixelWidth: canvasPixelWidth
            )
        case .sticker(_, let imageURL):
            entry = loadSticker(imageURL: imageURL, device: device)
        }

        guard let entry else { return nil }

        lock.lock()
        // Evict LRU if at capacity
        while entries.count >= Self.maxEntries, let evictKey = accessOrder.first {
            accessOrder.removeFirst()
            entries.removeValue(forKey: evictKey)
        }
        entries[key] = entry
        accessOrder.append(key)
        lock.unlock()

        return entry
    }

    /// Clears all cached textures.
    func invalidateAll() {
        lock.lock()
        entries.removeAll()
        accessOrder.removeAll()
        lock.unlock()
    }

    /// Called on UIKit memory warning. Preview cache owner subscribes; export cache does not.
    func purgeOnMemoryPressure() {
        invalidateAll()
    }

    // MARK: - Text Rasterization

    private func rasterizeText(
        text: String,
        fontFamily: String?,
        fontSize: CGFloat,
        colorHex: String,
        device: MTLDevice,
        canvasSize: SizeD,
        canvasPixelWidth: Int
    ) -> CachedEntry? {
        let scale = CGFloat(canvasPixelWidth) / CGFloat(canvasSize.width)
        let scaledFontSize = fontSize * scale

        let font: UIFont
        if let family = fontFamily {
            font = UIFont(name: family, size: scaledFontSize) ?? .boldSystemFont(ofSize: scaledFontSize)
        } else {
            font = .boldSystemFont(ofSize: scaledFontSize)
        }
        let color = UIColor(overlayHexString: colorHex) ?? .white

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]

        let nsString = text as NSString
        let textSize = nsString.size(withAttributes: attributes)

        // Tight bounding box + 2px padding
        let texWidth = max(1, Int(ceil(textSize.width)) + 4)
        let texHeight = max(1, Int(ceil(textSize.height)) + 4)
        let bytesPerRow = texWidth * 4

        var pixelBuffer = [UInt8](repeating: 0, count: bytesPerRow * texHeight)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let cgContext = CGContext(
            data: &pixelBuffer,
            width: texWidth,
            height: texHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Flip for UIKit drawing
        cgContext.translateBy(x: 0, y: CGFloat(texHeight))
        cgContext.scaleBy(x: 1, y: -1)

        UIGraphicsPushContext(cgContext)
        nsString.draw(at: CGPoint(x: 2, y: 2), withAttributes: attributes)
        UIGraphicsPopContext()

        // RGBA → BGRA swap
        let dataSize = bytesPerRow * texHeight
        for i in stride(from: 0, to: dataSize, by: 4) {
            let r = pixelBuffer[i]
            pixelBuffer[i] = pixelBuffer[i + 2]
            pixelBuffer[i + 2] = r
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: texWidth,
            height: texHeight,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead

        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(
            region: MTLRegionMake2D(0, 0, texWidth, texHeight),
            mipmapLevel: 0,
            withBytes: pixelBuffer,
            bytesPerRow: bytesPerRow
        )

        return CachedEntry(texture: texture, contentWidth: texWidth, contentHeight: texHeight)
    }

    // MARK: - Sticker Loading

    private func loadSticker(imageURL: URL, device: MTLDevice) -> CachedEntry? {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4

        var pixelBuffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let cgContext = CGContext(
            data: &pixelBuffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        cgContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // RGBA → BGRA swap
        let dataSize = bytesPerRow * height
        for i in stride(from: 0, to: dataSize, by: 4) {
            let r = pixelBuffer[i]
            pixelBuffer[i] = pixelBuffer[i + 2]
            pixelBuffer[i + 2] = r
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead

        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: pixelBuffer,
            bytesPerRow: bytesPerRow
        )

        return CachedEntry(texture: texture, contentWidth: width, contentHeight: height)
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
