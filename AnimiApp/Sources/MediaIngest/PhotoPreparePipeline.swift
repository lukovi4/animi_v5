import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import Foundation

// MARK: - Photo Prepare Pipeline

/// File-based photo preparation pipeline using ImageIO.
/// Takes a source image file, downsizes to max 2048px (no upscale), saves as JPEG to a temp file.
/// No UIImage, no UIKit — fully file-based end-to-end.
public enum PhotoPreparePipeline {

    /// Maximum dimension (width or height) for output photos.
    public static let maxDimension: Int = 2048

    /// JPEG compression quality.
    public static let jpegQuality: CGFloat = 0.9

    // MARK: - Prepare

    /// Prepares a photo from a file URL using ImageIO.
    /// Reads source → creates downsampled thumbnail (respecting EXIF orientation) → writes JPEG to temp.
    ///
    /// - Parameter fileURL: Source image file URL
    /// - Returns: URL to a temporary JPEG file ready for persistence
    /// - Throws: `PhotoPrepareError` if any step fails
    public static func prepare(fileURL: URL) throws -> URL {
        // 1. Create image source
        guard let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            throw PhotoPrepareError.failedToCreateImageSource
        }

        // 2. Read original dimensions to avoid upscaling
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        let originalWidth = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let originalHeight = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let originalLongestSide = max(originalWidth, originalHeight)

        // Target: min(2048, originalLongestSide) — never upscale
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

// MARK: - Errors

public enum PhotoPrepareError: Error, LocalizedError {
    case failedToCreateImageSource
    case failedToCreateThumbnail
    case jpegWriteFailed

    public var errorDescription: String? {
        switch self {
        case .failedToCreateImageSource:
            return "Failed to create image source from file"
        case .failedToCreateThumbnail:
            return "Failed to create downsampled thumbnail"
        case .jpegWriteFailed:
            return "Failed to write JPEG to temp file"
        }
    }
}
