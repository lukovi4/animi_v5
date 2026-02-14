import UIKit
import Metal
import MetalKit
import CoreVideo
import TVECore

// MARK: - User Media Texture Factory

/// Creates Metal textures from user media (photos and video frames).
///
/// Handles proper color space, orientation, and memory management for:
/// - UIImage → MTLTexture (for photos)
/// - CVPixelBuffer → MTLTexture (for video frames, via CVMetalTextureCache)
///
/// **Alpha Fix:** Images with alpha channel are loaded via `PremultipliedTextureLoader`
/// for correct compositing with the renderer's premultiplied blending mode.
///
/// Usage:
/// ```swift
/// let factory = UserMediaTextureFactory(device: device, commandQueue: queue)
/// let texture = factory.makeTexture(from: userImage)
/// ```
public final class UserMediaTextureFactory {

    // MARK: - Properties

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureLoader: MTKTextureLoader
    private var textureCache: CVMetalTextureCache?

    /// Maximum texture dimension (prevents memory issues with very large images)
    private let maxTextureDimension: Int = 4096

    // MARK: - Initialization

    /// Creates a new texture factory.
    ///
    /// - Parameters:
    ///   - device: Metal device for texture creation
    ///   - commandQueue: Command queue for staging → private blit (for alpha images)
    public init(device: MTLDevice, commandQueue: MTLCommandQueue) {
        self.device = device
        self.commandQueue = commandQueue
        self.textureLoader = MTKTextureLoader(device: device)

        // Create CVMetalTextureCache for video frame conversion
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &cache
        )
        if status == kCVReturnSuccess {
            self.textureCache = cache
        }
    }

    // MARK: - Photo Texture Creation

    /// Creates a Metal texture from a UIImage.
    ///
    /// Handles:
    /// - Image orientation correction
    /// - Size limiting for memory safety
    /// - Proper color space (sRGB)
    /// - **Premultiplied alpha** for images with transparency (correct compositing)
    ///
    /// - Parameter image: Source image
    /// - Returns: Metal texture with `.private` storage, or `nil` if creation failed
    public func makeTexture(from image: UIImage) -> MTLTexture? {
        // Normalize orientation and limit size
        guard let normalizedImage = normalizeImage(image) else {
            return nil
        }

        guard let cgImage = normalizedImage.cgImage else {
            return nil
        }

        // Check if image has alpha channel
        if PremultipliedTextureLoader.hasAlpha(cgImage) {
            // Alpha images: use PremultipliedTextureLoader for correct compositing
            do {
                return try PremultipliedTextureLoader.loadTexture(
                    from: cgImage,
                    device: device,
                    commandQueue: commandQueue
                )
            } catch {
                print("[UserMediaTextureFactory] Failed to create premult texture: \(error)")
                return nil
            }
        } else {
            // No alpha: fast path via MTKTextureLoader (no premultiply needed)
            let options: [MTKTextureLoader.Option: Any] = [
                .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                .textureStorageMode: MTLStorageMode.private.rawValue,
                .SRGB: false,  // Linear color space for correct blending
                .generateMipmaps: false
            ]

            do {
                return try textureLoader.newTexture(cgImage: cgImage, options: options)
            } catch {
                print("[UserMediaTextureFactory] Failed to create texture from image: \(error)")
                return nil
            }
        }
    }

    // MARK: - Video Frame Texture Creation

    /// Creates a Metal texture from a CVPixelBuffer (video frame).
    ///
    /// Uses CVMetalTextureCache for efficient GPU-side conversion without CPU copies.
    ///
    /// - Parameter pixelBuffer: Video frame pixel buffer
    /// - Returns: Metal texture, or `nil` if creation failed
    public func makeTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let cache = textureCache else {
            return nil
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Determine pixel format
        let pixelFormat: MTLPixelFormat
        let osType = CVPixelBufferGetPixelFormatType(pixelBuffer)
        switch osType {
        case kCVPixelFormatType_32BGRA:
            pixelFormat = .bgra8Unorm
        case kCVPixelFormatType_32RGBA:
            pixelFormat = .rgba8Unorm
        default:
            // Try BGRA as fallback
            pixelFormat = .bgra8Unorm
        }

        // Create texture from pixel buffer
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            0,
            &cvTexture
        )

        guard status == kCVReturnSuccess, let cvTex = cvTexture else {
            return nil
        }

        return CVMetalTextureGetTexture(cvTex)
    }

    // MARK: - Private Helpers

    /// Normalizes image orientation and limits size.
    private func normalizeImage(_ image: UIImage) -> UIImage? {
        var targetSize = image.size

        // Limit maximum dimension for memory safety
        let maxDim = CGFloat(maxTextureDimension)
        if targetSize.width > maxDim || targetSize.height > maxDim {
            let scale = min(maxDim / targetSize.width, maxDim / targetSize.height)
            targetSize = CGSize(
                width: targetSize.width * scale,
                height: targetSize.height * scale
            )
        }

        // Check if normalization is needed
        let needsResize = targetSize != image.size
        let needsOrientationFix = image.imageOrientation != .up

        if !needsResize && !needsOrientationFix {
            return image
        }

        // Draw into new context with correct orientation
        UIGraphicsBeginImageContextWithOptions(targetSize, false, 1.0)
        defer { UIGraphicsEndImageContext() }

        image.draw(in: CGRect(origin: .zero, size: targetSize))
        return UIGraphicsGetImageFromCurrentImageContext()
    }

    // MARK: - Cache Management

    /// Flushes the CVMetalTextureCache.
    ///
    /// Call periodically during video playback to prevent memory buildup.
    public func flushCache() {
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }
}
