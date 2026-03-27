import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import Foundation

// MARK: - Image File Prepare Pipeline

/// Parameterized file-based image preparation using ImageIO.
/// Takes a source image file, downsizes to maxDimension (no upscale), saves as JPEG to a temp file.
/// No UIImage, no UIKit — fully file-based end-to-end.
///
/// Shared by PhotoPreparePipeline (scene photos) and BackgroundTextureService (background images).
public enum ImageFilePreparePipeline {

    /// Prepares a JPEG from a file URL using ImageIO.
    /// Reads source -> creates downsampled thumbnail (respecting EXIF orientation) -> writes JPEG to temp.
    ///
    /// - Parameters:
    ///   - fileURL: Source image file URL
    ///   - maxDimension: Maximum dimension (width or height) for output
    ///   - jpegQuality: JPEG compression quality (0.0–1.0)
    /// - Returns: URL to a temporary JPEG file ready for persistence
    /// - Throws: `PhotoPrepareError` if any step fails
    public static func prepareJPEG(fileURL: URL, maxDimension: Int, jpegQuality: CGFloat) throws -> URL {
        // 1. Create image source
        guard let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            throw PhotoPrepareError.failedToCreateImageSource
        }

        // 2. Read original dimensions to avoid upscaling
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        let originalWidth = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let originalHeight = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let originalLongestSide = max(originalWidth, originalHeight)

        // Target: min(maxDimension, originalLongestSide) — never upscale
        let targetMaxDimension = originalLongestSide > 0 ? min(maxDimension, originalLongestSide) : maxDimension

        // 3. Create downsampled thumbnail with EXIF orientation applied
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: targetMaxDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            throw PhotoPrepareError.failedToCreateThumbnail
        }

        // 4. Write to temp JPEG
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent("\(UUID().uuidString).jpg")

        guard let destination = CGImageDestinationCreateWithURL(
            tempURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw PhotoPrepareError.jpegWriteFailed
        }

        let writeOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: jpegQuality
        ]
        CGImageDestinationAddImage(destination, cgImage, writeOptions as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw PhotoPrepareError.jpegWriteFailed
        }

        return tempURL
    }
}
