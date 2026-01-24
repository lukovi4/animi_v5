import Metal
import Foundation

// MARK: - Mask Cache Key

/// Key for caching rasterized mask textures.
/// Combines path identity, target size, and transform for uniqueness.
struct MaskCacheKey: Hashable {
    let pathHash: Int
    let width: Int
    let height: Int
    let transformHash: Int

    init(path: BezierPath, size: (width: Int, height: Int), transform: Matrix2D) {
        self.pathHash = Self.computePathHash(path)
        self.width = size.width
        self.height = size.height
        self.transformHash = Self.computeTransformHash(transform)
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
}

// MARK: - Mask Cache

/// Caches rasterized mask textures to avoid re-rasterization.
/// Textures are keyed by (pathHash, sizePx, transformHash).
final class MaskCache {
    private let device: MTLDevice
    private var cache: [MaskCacheKey: MTLTexture] = [:]
    private var accessOrder: [MaskCacheKey] = []
    private let maxEntries: Int

    /// Creates a mask cache with the given device and capacity.
    /// - Parameters:
    ///   - device: Metal device for texture creation
    ///   - maxEntries: Maximum number of cached textures (default: 64)
    init(device: MTLDevice, maxEntries: Int = 64) {
        self.device = device
        self.maxEntries = maxEntries
    }

    /// Gets or creates a mask texture for the given parameters.
    /// - Parameters:
    ///   - path: The Bezier path to rasterize
    ///   - transform: Transform from path coords to viewport pixels
    ///   - size: Target texture size in pixels
    ///   - opacity: Mask opacity (0.0 to 1.0)
    /// - Returns: Metal texture with alpha channel, or nil on failure
    func texture(
        for path: BezierPath,
        transform: Matrix2D,
        size: (width: Int, height: Int),
        opacity: Double
    ) -> MTLTexture? {
        let key = MaskCacheKey(path: path, size: size, transform: transform)

        // Check cache
        if let cached = cache[key] {
            updateAccessOrder(key)
            return cached
        }

        // Rasterize path to alpha bytes
        var alphaBytes = MaskRasterizer.rasterize(
            path: path,
            transformToViewportPx: transform,
            targetSizePx: size,
            fillRule: .nonZero,
            antialias: true
        )

        guard !alphaBytes.isEmpty else { return nil }

        // Apply opacity if not fully opaque
        if opacity < 1.0 {
            let opacityByte = UInt8(clamping: Int(opacity * 255.0))
            for idx in 0..<alphaBytes.count {
                alphaBytes[idx] = UInt8((Int(alphaBytes[idx]) * Int(opacityByte)) / 255)
            }
        }

        // Create texture
        guard let texture = createTexture(from: alphaBytes, size: size) else {
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

    private func createTexture(from alphaBytes: [UInt8], size: (width: Int, height: Int)) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: size.width,
            height: size.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        alphaBytes.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, size.width, size.height),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: size.width
            )
        }

        return texture
    }

    private func storeInCache(key: MaskCacheKey, texture: MTLTexture) {
        // Evict oldest if at capacity
        while cache.count >= maxEntries, let oldest = accessOrder.first {
            accessOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }

        cache[key] = texture
        accessOrder.append(key)
    }

    private func updateAccessOrder(_ key: MaskCacheKey) {
        if let index = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: index)
            accessOrder.append(key)
        }
    }
}
