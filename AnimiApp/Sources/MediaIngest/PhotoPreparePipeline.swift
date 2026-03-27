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
        try ImageFilePreparePipeline.prepareJPEG(
            fileURL: fileURL,
            maxDimension: maxDimension,
            jpegQuality: jpegQuality
        )
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
