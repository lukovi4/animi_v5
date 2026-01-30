import Metal
import Foundation
import CoreGraphics

// MARK: - Shape Cache Key

/// Key for caching rasterized shape textures.
/// Combines path identity, target size, transform, fill color, and opacity for uniqueness.
/// PR-14A: Uses quantized hashes for determinism and better cache hit rate.
struct ShapeCacheKey: Hashable {
    let pathHash: Int
    let width: Int
    let height: Int
    let transformHash: Int
    let colorHash: Int
    let quantizedOpacity: Int

    init(path: BezierPath, size: (width: Int, height: Int), transform: Matrix2D, fillColor: [Double], opacity: Double) {
        self.pathHash = Self.computeQuantizedPathHash(path)
        self.width = size.width
        self.height = size.height
        self.transformHash = transform.quantizedHash()
        self.colorHash = Self.computeQuantizedColorHash(fillColor)
        // Quantize opacity to 1/256 steps (8-bit precision matches texture output)
        self.quantizedOpacity = Quantization.quantizedInt(opacity, step: 1.0 / 256.0)
    }

    /// Computes deterministic path hash using quantized coordinates.
    /// Eliminates cache misses from floating-point noise (e.g., 1e-12 differences).
    private static func computeQuantizedPathHash(_ path: BezierPath) -> Int {
        let step = AnimConstants.pathCoordQuantStep
        var hasher = Hasher()
        hasher.combine(path.closed)
        hasher.combine(path.vertices.count)
        for vertex in path.vertices {
            hasher.combine(Quantization.quantizedInt(vertex.x, step: step))
            hasher.combine(Quantization.quantizedInt(vertex.y, step: step))
        }
        for tangent in path.inTangents {
            hasher.combine(Quantization.quantizedInt(tangent.x, step: step))
            hasher.combine(Quantization.quantizedInt(tangent.y, step: step))
        }
        for tangent in path.outTangents {
            hasher.combine(Quantization.quantizedInt(tangent.x, step: step))
            hasher.combine(Quantization.quantizedInt(tangent.y, step: step))
        }
        return hasher.finalize()
    }

    /// Computes deterministic color hash using quantized components.
    private static func computeQuantizedColorHash(_ color: [Double]) -> Int {
        var hasher = Hasher()
        // Quantize to 8-bit precision (1/256) to match texture color depth
        for component in color {
            hasher.combine(Quantization.quantizedInt(component, step: 1.0 / 256.0))
        }
        return hasher.finalize()
    }
}

// MARK: - Stroke Cache Key

/// Key for caching rasterized stroke textures (PR-10).
/// Extends shape key with stroke-specific parameters.
/// PR-14A: Uses quantized hashes for determinism and better cache hit rate.
struct StrokeCacheKey: Hashable {
    let pathHash: Int
    let width: Int
    let height: Int
    let transformHash: Int
    let colorHash: Int
    let quantizedOpacity: Int
    let quantizedStrokeWidth: Int
    let lineCap: Int
    let lineJoin: Int
    let quantizedMiterLimit: Int

    init(
        path: BezierPath,
        size: (width: Int, height: Int),
        transform: Matrix2D,
        strokeColor: [Double],
        opacity: Double,
        strokeWidth: Double,
        lineCap: Int,
        lineJoin: Int,
        miterLimit: Double
    ) {
        self.pathHash = Self.computeQuantizedPathHash(path)
        self.width = size.width
        self.height = size.height
        self.transformHash = transform.quantizedHash()
        self.colorHash = Self.computeQuantizedColorHash(strokeColor)
        self.quantizedOpacity = Quantization.quantizedInt(opacity, step: 1.0 / 256.0)
        self.quantizedStrokeWidth = Quantization.quantizedInt(strokeWidth, step: AnimConstants.strokeWidthQuantStep)
        self.lineCap = lineCap
        self.lineJoin = lineJoin
        // Quantize miter limit to 1/16 precision (adequate for visual consistency)
        self.quantizedMiterLimit = Quantization.quantizedInt(miterLimit, step: 1.0 / 16.0)
    }

    /// Computes deterministic path hash using quantized coordinates.
    private static func computeQuantizedPathHash(_ path: BezierPath) -> Int {
        let step = AnimConstants.pathCoordQuantStep
        var hasher = Hasher()
        hasher.combine(path.closed)
        hasher.combine(path.vertices.count)
        for vertex in path.vertices {
            hasher.combine(Quantization.quantizedInt(vertex.x, step: step))
            hasher.combine(Quantization.quantizedInt(vertex.y, step: step))
        }
        for tangent in path.inTangents {
            hasher.combine(Quantization.quantizedInt(tangent.x, step: step))
            hasher.combine(Quantization.quantizedInt(tangent.y, step: step))
        }
        for tangent in path.outTangents {
            hasher.combine(Quantization.quantizedInt(tangent.x, step: step))
            hasher.combine(Quantization.quantizedInt(tangent.y, step: step))
        }
        return hasher.finalize()
    }

    /// Computes deterministic color hash using quantized components.
    private static func computeQuantizedColorHash(_ color: [Double]) -> Int {
        var hasher = Hasher()
        for component in color {
            hasher.combine(Quantization.quantizedInt(component, step: 1.0 / 256.0))
        }
        return hasher.finalize()
    }
}

// MARK: - Shape Cache

/// Caches rasterized shape textures to avoid re-rasterization.
/// Similar to MaskCache but produces BGRA textures with fill color.
/// Also supports stroke rendering (PR-10).
final class ShapeCache {
    private let device: MTLDevice
    private var cache: [ShapeCacheKey: MTLTexture] = [:]
    private var accessOrder: [ShapeCacheKey] = []
    private var strokeCache: [StrokeCacheKey: MTLTexture] = [:]
    private var strokeAccessOrder: [StrokeCacheKey] = []
    private let maxEntries: Int

    /// Creates a shape cache with the given device and capacity.
    /// - Parameters:
    ///   - device: Metal device for texture creation
    ///   - maxEntries: Maximum number of cached textures (default: 64)
    init(device: MTLDevice, maxEntries: Int = 64) {
        self.device = device
        self.maxEntries = maxEntries
    }

    /// Result of a shape cache lookup, exposing hit/miss for external metrics.
    struct TextureResult {
        let texture: MTLTexture?
        let didHit: Bool
        let didEvict: Bool
    }

    /// Gets or creates a shape texture for the given parameters.
    /// - Parameters:
    ///   - path: The Bezier path to rasterize
    ///   - transform: Transform from path coords to viewport pixels
    ///   - size: Target texture size in pixels
    ///   - fillColor: RGB fill color (0.0 to 1.0)
    ///   - opacity: Overall opacity (0.0 to 1.0)
    /// - Returns: Result with texture and cache hit/eviction info
    func texture(
        for path: BezierPath,
        transform: Matrix2D,
        size: (width: Int, height: Int),
        fillColor: [Double],
        opacity: Double
    ) -> TextureResult {
        let key = ShapeCacheKey(path: path, size: size, transform: transform, fillColor: fillColor, opacity: opacity)

        // Check cache
        if let cached = cache[key] {
            updateAccessOrder(key)
            return TextureResult(texture: cached, didHit: true, didEvict: false)
        }

        // Rasterize path to alpha bytes
        let alphaBytes = MaskRasterizer.rasterize(
            path: path,
            transformToViewportPx: transform,
            targetSizePx: size,
            fillRule: .nonZero,
            antialias: true
        )

        guard !alphaBytes.isEmpty else { return TextureResult(texture: nil, didHit: false, didEvict: false) }

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
            return TextureResult(texture: nil, didHit: false, didEvict: false)
        }

        // Store in cache with eviction
        let evicted = storeInCache(key: key, texture: texture)

        return TextureResult(texture: texture, didHit: false, didEvict: evicted)
    }

    /// Gets or creates a stroke texture for the given parameters (PR-10).
    /// - Parameters:
    ///   - path: The Bezier path to stroke
    ///   - transform: Transform from path coords to viewport pixels
    ///   - size: Target texture size in pixels
    ///   - strokeColor: RGB stroke color (0.0 to 1.0)
    ///   - opacity: Overall opacity (0.0 to 1.0)
    ///   - strokeWidth: Stroke width in Lottie units (will be scaled by transform)
    ///   - lineCap: Line cap style (1=butt, 2=round, 3=square)
    ///   - lineJoin: Line join style (1=miter, 2=round, 3=bevel)
    ///   - miterLimit: Miter limit for miter joins
    /// - Returns: Result with texture and cache hit/eviction info
    func strokeTexture(
        for path: BezierPath,
        transform: Matrix2D,
        size: (width: Int, height: Int),
        strokeColor: [Double],
        opacity: Double,
        strokeWidth: Double,
        lineCap: Int,
        lineJoin: Int,
        miterLimit: Double
    ) -> TextureResult {
        // Compute uniform scale from transform (length of X-basis vector)
        // This scales stroke width from Lottie coords to viewport pixels
        let uniformScale = Self.computeUniformScale(from: transform)
        let scaledStrokeWidth = strokeWidth * uniformScale

        // Quantize stroke width for cache key using AnimConstants.strokeWidthQuantStep (PR-14A)
        let quantizedWidth = Quantization.quantize(scaledStrokeWidth, step: AnimConstants.strokeWidthQuantStep)

        let key = StrokeCacheKey(
            path: path,
            size: size,
            transform: transform,
            strokeColor: strokeColor,
            opacity: opacity,
            strokeWidth: quantizedWidth,
            lineCap: lineCap,
            lineJoin: lineJoin,
            miterLimit: miterLimit
        )

        // Check cache
        if let cached = strokeCache[key] {
            updateStrokeAccessOrder(key)
            return TextureResult(texture: cached, didHit: true, didEvict: false)
        }

        // Rasterize stroke to BGRA bytes using CoreGraphics
        // Use actual scaled width (not quantized) for best visual quality
        let bgraBytes = rasterizeStroke(
            path: path,
            transform: transform,
            size: size,
            strokeColor: strokeColor,
            opacity: opacity,
            scaledStrokeWidth: scaledStrokeWidth,
            lineCap: lineCap,
            lineJoin: lineJoin,
            miterLimit: miterLimit
        )

        guard !bgraBytes.isEmpty else { return TextureResult(texture: nil, didHit: false, didEvict: false) }

        // Create texture
        guard let texture = createTexture(from: bgraBytes, size: size) else {
            return TextureResult(texture: nil, didHit: false, didEvict: false)
        }

        // Store in cache with eviction
        let evicted = storeInStrokeCache(key: key, texture: texture)

        return TextureResult(texture: texture, didHit: false, didEvict: evicted)
    }

    /// Clears all cached textures.
    func clear() {
        cache.removeAll()
        accessOrder.removeAll()
        strokeCache.removeAll()
        strokeAccessOrder.removeAll()
    }

    /// Returns the number of cached fill textures.
    var count: Int { cache.count }

    /// Returns the number of cached stroke textures.
    var strokeCount: Int { strokeCache.count }

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

    @discardableResult
    private func storeInCache(key: ShapeCacheKey, texture: MTLTexture) -> Bool {
        // Evict oldest if at capacity
        var evicted = false
        while cache.count >= maxEntries, let oldest = accessOrder.first {
            accessOrder.removeFirst()
            cache.removeValue(forKey: oldest)
            evicted = true
        }

        cache[key] = texture
        accessOrder.append(key)
        return evicted
    }

    private func updateAccessOrder(_ key: ShapeCacheKey) {
        if let index = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: index)
            accessOrder.append(key)
        }
    }

    @discardableResult
    private func storeInStrokeCache(key: StrokeCacheKey, texture: MTLTexture) -> Bool {
        // Evict oldest if at capacity
        var evicted = false
        while strokeCache.count >= maxEntries, let oldest = strokeAccessOrder.first {
            strokeAccessOrder.removeFirst()
            strokeCache.removeValue(forKey: oldest)
            evicted = true
        }

        strokeCache[key] = texture
        strokeAccessOrder.append(key)
        return evicted
    }

    private func updateStrokeAccessOrder(_ key: StrokeCacheKey) {
        if let index = strokeAccessOrder.firstIndex(of: key) {
            strokeAccessOrder.remove(at: index)
            strokeAccessOrder.append(key)
        }
    }

    // MARK: - Stroke Rasterization (CoreGraphics)

    /// Computes uniform scale factor from transform matrix (length of X-basis vector)
    /// Used to scale stroke width from Lottie coords to viewport pixels
    static func computeUniformScale(from transform: Matrix2D) -> Double {
        // hypot(a, b) = length of X-basis vector = uniform scale factor
        // This is correct for rotation and uniform scale transforms
        return hypot(transform.a, transform.b)
    }

    // swiftlint:disable:next function_parameter_count
    private func rasterizeStroke(
        path: BezierPath,
        transform: Matrix2D,
        size: (width: Int, height: Int),
        strokeColor: [Double],
        opacity: Double,
        scaledStrokeWidth: Double,
        lineCap: Int,
        lineJoin: Int,
        miterLimit: Double
    ) -> [UInt8] {
        guard size.width > 0 && size.height > 0 else { return [] }
        guard path.vertexCount >= 2 else { return [] }

        let width = size.width
        let height = size.height
        let bytesPerRow = width * 4

        // Create BGRA bitmap context
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return [] }

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return [] }

        // Set stroke color with opacity (premultiplied alpha)
        let red = CGFloat(max(0, min(1, strokeColor.count > 0 ? strokeColor[0] : 1)))
        let green = CGFloat(max(0, min(1, strokeColor.count > 1 ? strokeColor[1] : 1)))
        let blue = CGFloat(max(0, min(1, strokeColor.count > 2 ? strokeColor[2] : 1)))
        let alpha = CGFloat(max(0, min(1, opacity)))

        context.setStrokeColor(red: red, green: green, blue: blue, alpha: alpha)

        // Stroke width is already scaled by caller (strokeTexture)
        context.setLineWidth(CGFloat(scaledStrokeWidth))

        // Set line cap
        let cgLineCap: CGLineCap
        switch lineCap {
        case 1: cgLineCap = .butt
        case 2: cgLineCap = .round
        case 3: cgLineCap = .square
        default: cgLineCap = .round
        }
        context.setLineCap(cgLineCap)

        // Set line join
        let cgLineJoin: CGLineJoin
        switch lineJoin {
        case 1: cgLineJoin = .miter
        case 2: cgLineJoin = .round
        case 3: cgLineJoin = .bevel
        default: cgLineJoin = .round
        }
        context.setLineJoin(cgLineJoin)

        // Set miter limit
        context.setMiterLimit(CGFloat(miterLimit))

        // Build CGPath from BezierPath
        let cgPath = buildCGPath(from: path, transform: transform)

        // Stroke the path
        context.addPath(cgPath)
        context.strokePath()

        return pixels
    }

    private func buildCGPath(from path: BezierPath, transform: Matrix2D) -> CGPath {
        let cgPath = CGMutablePath()

        guard !path.vertices.isEmpty else { return cgPath }

        let vertexCount = path.vertices.count

        // Start at first vertex
        let startVertex = transform.apply(to: path.vertices[0])
        cgPath.move(to: CGPoint(x: startVertex.x, y: startVertex.y))

        // Draw segments
        for i in 0..<vertexCount {
            let nextIdx = (i + 1) % vertexCount
            if !path.closed && nextIdx == 0 {
                break // Don't close open path
            }

            let currentVertex = path.vertices[i]
            let nextVertex = path.vertices[nextIdx]
            let outTangent = path.outTangents[i]
            let inTangent = path.inTangents[nextIdx]

            // Transform points
            let cp1 = transform.apply(to: Vec2D(x: currentVertex.x + outTangent.x, y: currentVertex.y + outTangent.y))
            let cp2 = transform.apply(to: Vec2D(x: nextVertex.x + inTangent.x, y: nextVertex.y + inTangent.y))
            let endPoint = transform.apply(to: nextVertex)

            // Check if this is a straight line (both tangents are nearly zero)
            // PR-14A: Use AnimConstants.nearlyEqualEpsilon for consistency
            let isLine = Quantization.isNearlyZero(outTangent.x) &&
                         Quantization.isNearlyZero(outTangent.y) &&
                         Quantization.isNearlyZero(inTangent.x) &&
                         Quantization.isNearlyZero(inTangent.y)

            if isLine {
                cgPath.addLine(to: CGPoint(x: endPoint.x, y: endPoint.y))
            } else {
                cgPath.addCurve(
                    to: CGPoint(x: endPoint.x, y: endPoint.y),
                    control1: CGPoint(x: cp1.x, y: cp1.y),
                    control2: CGPoint(x: cp2.x, y: cp2.y)
                )
            }
        }

        if path.closed {
            cgPath.closeSubpath()
        }

        return cgPath
    }
}
