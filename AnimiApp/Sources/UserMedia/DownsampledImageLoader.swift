import Metal
import ImageIO
import CoreGraphics
import Foundation

// MARK: - Downsampled Image Loader

/// Loads images at a capped resolution using Image I/O thumbnail API.
///
/// Uses `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceThumbnailMaxPixelSize`
/// to decode images at a target size without ever loading the full-resolution image into memory.
///
/// Reuses the staging-buffer → private-texture blit path from `PremultipliedTextureLoader`
/// for correct premultiplied alpha compositing.
///
/// Used by both export user media AND export background loading paths.
/// Export does NOT use `UserMediaTextureFactory` — this is the file-based downsampling path.
public enum DownsampledImageLoader {

    // MARK: - Errors

    public enum LoadError: Error, LocalizedError {
        case failedToCreateImageSource(url: URL)
        case failedToCreateThumbnail(url: URL)
        case failedToCreateCGContext(width: Int, height: Int)
        case failedToCreateStagingBuffer(size: Int)
        case failedToCreateTexture(width: Int, height: Int)
        case failedToCreateCommandBuffer
        case failedToCreateBlitEncoder
        case gpuBlitFailed(String)

        public var errorDescription: String? {
            switch self {
            case .failedToCreateImageSource(let url):
                return "Failed to create image source from \(url.lastPathComponent)"
            case .failedToCreateThumbnail(let url):
                return "Failed to create downsampled thumbnail from \(url.lastPathComponent)"
            case .failedToCreateCGContext(let w, let h):
                return "Failed to create CGContext for \(w)x\(h)"
            case .failedToCreateStagingBuffer(let size):
                return "Failed to create staging buffer of size \(size)"
            case .failedToCreateTexture(let w, let h):
                return "Failed to create texture \(w)x\(h)"
            case .failedToCreateCommandBuffer:
                return "Failed to create command buffer"
            case .failedToCreateBlitEncoder:
                return "Failed to create blit command encoder"
            case .gpuBlitFailed(let reason):
                return "GPU blit failed: \(reason)"
            }
        }
    }

    // MARK: - Public API

    /// Loads a texture from a file URL, downsampled to at most `maxDimensionPx` on the longest side.
    ///
    /// - Parameters:
    ///   - url: File URL of the image (PNG, JPEG, HEIC, etc.)
    ///   - device: Metal device for texture creation
    ///   - commandQueue: Command queue for staging → private blit
    ///   - maxDimensionPx: Maximum dimension in pixels for the longest side
    /// - Returns: Metal texture with premultiplied alpha, storage mode `.private`
    /// - Throws: `LoadError` if loading fails
    public static func loadTexture(
        from url: URL,
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        maxDimensionPx: Int
    ) throws -> MTLTexture {
        // 1. Create image source
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw LoadError.failedToCreateImageSource(url: url)
        }

        // 2. Create downsampled thumbnail with EXIF orientation applied
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimensionPx,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            throw LoadError.failedToCreateThumbnail(url: url)
        }

        // 3. Render to premultiplied BGRA and upload via staging buffer → private texture
        return try uploadToPrivateTexture(cgImage: cgImage, device: device, commandQueue: commandQueue)
    }

    // MARK: - Private

    /// Renders CGImage to premultiplied BGRA and uploads via staging buffer → private texture.
    /// Reuses the same approach as PremultipliedTextureLoader.
    private static func uploadToPrivateTexture(
        cgImage: CGImage,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> MTLTexture {
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        let bufferSize = bytesPerRow * height

        // Step 1: Render into premultiplied BGRA buffer
        var bytes = [UInt8](repeating: 0, count: bufferSize)
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            throw LoadError.failedToCreateCGContext(width: width, height: height)
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Step 2: Create staging buffer (.shared)
        guard let stagingBuffer = device.makeBuffer(
            bytes: bytes,
            length: bufferSize,
            options: .storageModeShared
        ) else {
            throw LoadError.failedToCreateStagingBuffer(size: bufferSize)
        }

        // Step 3: Create private texture
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = .shaderRead

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw LoadError.failedToCreateTexture(width: width, height: height)
        }

        // Step 4: Blit from staging buffer to private texture
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw LoadError.failedToCreateCommandBuffer
        }

        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            throw LoadError.failedToCreateBlitEncoder
        }

        blitEncoder.copy(
            from: stagingBuffer,
            sourceOffset: 0,
            sourceBytesPerRow: bytesPerRow,
            sourceBytesPerImage: bufferSize,
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )

        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if commandBuffer.status == .error {
            throw LoadError.gpuBlitFailed(commandBuffer.error?.localizedDescription ?? "unknown GPU error")
        }

        return texture
    }
}
