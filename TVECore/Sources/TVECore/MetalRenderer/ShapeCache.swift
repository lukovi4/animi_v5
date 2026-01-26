import Metal
import Foundation

// MARK: - Shape Cache Key

/// Key for caching rasterized shape textures.
/// Combines path identity, target size, transform, fill color, and opacity for uniqueness.
struct ShapeCacheKey: Hashable {
    let pathHash: Int
    let width: Int
    let height: Int
    let transformHash: Int
    let colorHash: Int
    let opacity: Double

    init(path: BezierPath, size: (width: Int, height: Int), transform: Matrix2D, fillColor: [Double], opacity: Double) {
        self.pathHash = Self.computePathHash(path)
        self.width = size.width
        self.height = size.height
        self.transformHash = Self.computeTransformHash(transform)
        self.colorHash = Self.computeColorHash(fillColor)
        self.opacity = opacity
    }

    private static func computePathHash(_ path: BezierPath) -> Int {
        var hasher = Hasher()
        hasher.combine(path.closed)
        hasher.combine(path.vertices.count)
        for vertex in path.vertices {
            hasher.combine(vertex.x)
            hasher.combine(vertex.y)
        }
        for tangent in path.inTangents {
            hasher.combine(tangent.x)
            hasher.combine(tangent.y)
        }
        for tangent in path.outTangents {
            hasher.combine(tangent.x)
            hasher.combine(tangent.y)
        }
        return hasher.finalize()
    }

    private static func computeTransformHash(_ transform: Matrix2D) -> Int {
        var hasher = Hasher()
        hasher.combine(transform.a)
        hasher.combine(transform.b)
        hasher.combine(transform.c)
        hasher.combine(transform.d)
        hasher.combine(transform.tx)
        hasher.combine(transform.ty)
        return hasher.finalize()
    }

    private static func computeColorHash(_ color: [Double]) -> Int {
        var hasher = Hasher()
        for component in color {
            hasher.combine(component)
        }
        return hasher.finalize()
    }
}

// MARK: - Shape Cache

/// Caches rasterized shape textures to avoid re-rasterization.
/// Similar to MaskCache but produces BGRA textures with fill color.
final class ShapeCache {
    private let device: MTLDevice
    private var cache: [ShapeCacheKey: MTLTexture] = [:]
    private var accessOrder: [ShapeCacheKey] = []
    private let maxEntries: Int

    /// Creates a shape cache with the given device and capacity.
    /// - Parameters:
    ///   - device: Metal device for texture creation
    ///   - maxEntries: Maximum number of cached textures (default: 64)
    init(device: MTLDevice, maxEntries: Int = 64) {
        self.device = device
        self.maxEntries = maxEntries
    }

    /// Gets or creates a shape texture for the given parameters.
    /// - Parameters:
    ///   - path: The Bezier path to rasterize
    ///   - transform: Transform from path coords to viewport pixels
    ///   - size: Target texture size in pixels
    ///   - fillColor: RGB fill color (0.0 to 1.0)
    ///   - opacity: Overall opacity (0.0 to 1.0)
    /// - Returns: Metal texture with BGRA data, or nil on failure
    func texture(
        for path: BezierPath,
        transform: Matrix2D,
        size: (width: Int, height: Int),
        fillColor: [Double],
        opacity: Double
    ) -> MTLTexture? {
        let key = ShapeCacheKey(path: path, size: size, transform: transform, fillColor: fillColor, opacity: opacity)

        // Check cache
        if let cached = cache[key] {
            updateAccessOrder(key)
            return cached
        }

        // Rasterize path to alpha bytes
        let alphaBytes = MaskRasterizer.rasterize(
            path: path,
            transformToViewportPx: transform,
            targetSizePx: size,
            fillRule: .nonZero,
            antialias: true
        )

        guard !alphaBytes.isEmpty else { return nil }

        // Convert to BGRA with fill color and opacity
        let bgraBytes = convertToBGRA(
            alphaBytes: alphaBytes,
            width: size.width,
            height: size.height,
            fillColor: fillColor,
            opacity: opacity
        )

        // Create texture
        guard let texture = createTexture(from: bgraBytes, size: size) else {
            return nil
        }

        // Store in cache with eviction
        storeInCache(key: key, texture: texture)

        return texture
    }

    /// Clears all cached textures.
    func clear() {
        cache.removeAll()
        accessOrder.removeAll()
    }

    /// Returns the number of cached textures.
    var count: Int { cache.count }

    // MARK: - Private

    private func convertToBGRA(
        alphaBytes: [UInt8],
        width: Int,
        height: Int,
        fillColor: [Double],
        opacity: Double
    ) -> [UInt8] {
        let pixelCount = width * height
        var bgra = [UInt8](repeating: 0, count: pixelCount * 4)

        // Clamp and convert fill color to bytes
        let red = UInt8(clamping: Int(max(0, min(1, fillColor.count > 0 ? fillColor[0] : 1)) * 255))
        let green = UInt8(clamping: Int(max(0, min(1, fillColor.count > 1 ? fillColor[1] : 1)) * 255))
        let blue = UInt8(clamping: Int(max(0, min(1, fillColor.count > 2 ? fillColor[2] : 1)) * 255))

        for idx in 0..<pixelCount {
            let alpha = alphaBytes[idx]
            // Apply opacity to alpha
            let finalAlpha = UInt8((Int(alpha) * Int(opacity * 255)) / 255)

            // Premultiplied alpha: RGB = color * alpha
            let premultRed = UInt8((Int(red) * Int(finalAlpha)) / 255)
            let premultGreen = UInt8((Int(green) * Int(finalAlpha)) / 255)
            let premultBlue = UInt8((Int(blue) * Int(finalAlpha)) / 255)

            let pixelOffset = idx * 4
            bgra[pixelOffset + 0] = premultBlue    // B
            bgra[pixelOffset + 1] = premultGreen   // G
            bgra[pixelOffset + 2] = premultRed     // R
            bgra[pixelOffset + 3] = finalAlpha     // A
        }

        return bgra
    }

    private func createTexture(from bgraBytes: [UInt8], size: (width: Int, height: Int)) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: size.width,
            height: size.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        bgraBytes.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, size.width, size.height),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: size.width * 4
            )
        }

        return texture
    }

    private func storeInCache(key: ShapeCacheKey, texture: MTLTexture) {
        // Evict oldest if at capacity
        while cache.count >= maxEntries, let oldest = accessOrder.first {
            accessOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }

        cache[key] = texture
        accessOrder.append(key)
    }

    private func updateAccessOrder(_ key: ShapeCacheKey) {
        if let index = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: index)
            accessOrder.append(key)
        }
    }
}
