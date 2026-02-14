import Metal
import MetalKit
import CoreGraphics
import ImageIO
import Foundation

// MARK: - Premultiplied Texture Loader

/// Loads image textures with proper premultiplied alpha for correct compositing.
///
/// The renderer uses premultiplied alpha blending (src.rgb + dst.rgb * (1 - src.a)),
/// which requires textures to have RGB channels pre-multiplied by alpha.
/// Standard PNG files use straight (non-premultiplied) alpha, causing incorrect
/// rendering if loaded directly.
///
/// This loader:
/// 1. Decodes image via CGImageSource
/// 2. Renders into CGContext with premultiplied alpha (byteOrder32Little + premultipliedFirst)
/// 3. Uploads to GPU via staging buffer → private texture blit
///
/// Usage:
/// ```swift
/// let texture = try PremultipliedTextureLoader.loadTexture(
///     from: imageURL,
///     device: device,
///     commandQueue: commandQueue
/// )
/// ```
public enum PremultipliedTextureLoader {

    // MARK: - Errors

    public enum LoadError: Error, LocalizedError {
        case failedToCreateImageSource(url: URL)
        case failedToCreateCGImage(url: URL)
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
            case .failedToCreateCGImage(let url):
                return "Failed to decode CGImage from \(url.lastPathComponent)"
            case .failedToCreateCGContext(let width, let height):
                return "Failed to create CGContext for \(width)x\(height)"
            case .failedToCreateStagingBuffer(let size):
                return "Failed to create staging buffer of size \(size)"
            case .failedToCreateTexture(let width, let height):
                return "Failed to create texture \(width)x\(height)"
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

    /// Loads a premultiplied texture from a file URL.
    ///
    /// Handles EXIF orientation metadata automatically (JPEG/HEIC with rotation).
    ///
    /// - Parameters:
    ///   - url: File URL of the image (PNG, JPEG, etc.)
    ///   - device: Metal device for texture creation
    ///   - commandQueue: Command queue for staging → private blit
    /// - Returns: Metal texture with premultiplied alpha, storage mode `.private`
    /// - Throws: `LoadError` if loading fails
    public static func loadTexture(
        from url: URL,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> MTLTexture {
        // Decode CGImage from file
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw LoadError.failedToCreateImageSource(url: url)
        }

        // Get original image dimensions for thumbnail size
        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw LoadError.failedToCreateCGImage(url: url)
        }

        // Use thumbnail API with transform to apply EXIF orientation (BLOCKER 1 fix)
        // This handles rotated JPEG/HEIC correctly
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(pixelWidth, pixelHeight)
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions as CFDictionary) else {
            throw LoadError.failedToCreateCGImage(url: url)
        }

        return try loadTexture(from: cgImage, device: device, commandQueue: commandQueue)
    }

    /// Loads a premultiplied texture from a CGImage.
    ///
    /// - Parameters:
    ///   - cgImage: Source image
    ///   - device: Metal device for texture creation
    ///   - commandQueue: Command queue for staging → private blit
    /// - Returns: Metal texture with premultiplied alpha, storage mode `.private`
    /// - Throws: `LoadError` if loading fails
    public static func loadTexture(
        from cgImage: CGImage,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> MTLTexture {
        let width = cgImage.width
        let height = cgImage.height

        // Step 1: Render CGImage into premultiplied BGRA buffer via CGContext
        let premultipliedBytes = try renderToPremultipliedBGRA(cgImage: cgImage)

        // Step 2: Create staging buffer (.shared) and copy bytes
        let bytesPerRow = width * 4
        let bufferSize = bytesPerRow * height

        guard let stagingBuffer = device.makeBuffer(
            bytes: premultipliedBytes,
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

        // Nice 1: Verify GPU blit completed successfully
        if commandBuffer.status == .error {
            let errorMsg = commandBuffer.error?.localizedDescription ?? "unknown GPU error"
            throw LoadError.gpuBlitFailed(errorMsg)
        }

        return texture
    }

    // MARK: - Internal (exposed for testing)

    /// Renders a CGImage into a premultiplied BGRA byte array.
    ///
    /// Uses CGContext with `byteOrder32Little | premultipliedFirst` (BGRA premult).
    /// This is the canonical format for Metal textures with correct alpha blending.
    ///
    /// Note: No coordinate flip is applied — the renderer's UV coordinates already
    /// handle the origin convention matching.
    ///
    /// - Parameter cgImage: Source image
    /// - Returns: Byte array in BGRA premultiplied format with top-left origin
    /// - Throws: `LoadError.failedToCreateCGContext` if context creation fails
    internal static func renderToPremultipliedBGRA(cgImage: CGImage) throws -> [UInt8] {
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        let bufferSize = bytesPerRow * height

        var bytes = [UInt8](repeating: 0, count: bufferSize)

        // BGRA premultiplied: byteOrder32Little (BGRA on little-endian) + premultipliedFirst
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

        // Draw image into context — this performs the straight→premult conversion
        // Note: No Y-flip needed — renderer UV coordinates already handle origin convention
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return bytes
    }

    // MARK: - Alpha Detection

    /// Checks if a CGImage has an alpha channel.
    ///
    /// - Parameter cgImage: Image to check
    /// - Returns: `true` if image has alpha (premultiplied or straight)
    public static func hasAlpha(_ cgImage: CGImage) -> Bool {
        switch cgImage.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        case .premultipliedFirst, .premultipliedLast, .first, .last, .alphaOnly:
            return true
        @unknown default:
            return true // Assume alpha for safety
        }
    }
}
