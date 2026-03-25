import UIKit

// MARK: - Photo Prepare Pipeline

/// File-based photo preparation pipeline.
/// Takes a source image file, downsizes to max 2048px, saves as JPEG to a temp file.
/// The caller (MediaIngestCoordinator) then persists via MediaAssetStore.
public enum PhotoPreparePipeline {

    /// Maximum dimension (width or height) for output photos.
    public static let maxDimension: CGFloat = 2048

    /// JPEG compression quality.
    public static let jpegQuality: CGFloat = 0.9

    // MARK: - Prepare

    /// Prepares a photo from a UIImage: downsample + JPEG encode → temp file URL.
    ///
    /// - Parameter image: Source image (from PHPicker loadObject)
    /// - Returns: URL to a temporary JPEG file ready for persistence
    /// - Throws: If JPEG encoding or file write fails
    public static func prepare(image: UIImage) throws -> URL {
        let resized = resizeIfNeeded(image, maxDimension: maxDimension)

        guard let jpegData = resized.jpegData(compressionQuality: jpegQuality) else {
            throw PhotoPrepareError.jpegEncodingFailed
        }

        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent("\(UUID().uuidString).jpg")
        try jpegData.write(to: tempURL, options: .atomic)

        return tempURL
    }

    /// Prepares a photo from a file URL: load → downsample + JPEG encode → temp file URL.
    ///
    /// - Parameter fileURL: Source image file URL
    /// - Returns: URL to a temporary JPEG file ready for persistence
    /// - Throws: If image loading, JPEG encoding, or file write fails
    public static func prepare(fileURL: URL) throws -> URL {
        guard let image = UIImage(contentsOfFile: fileURL.path) else {
            throw PhotoPrepareError.unreadableImage
        }
        return try prepare(image: image)
    }

    // MARK: - Private

    private static func resizeIfNeeded(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        guard size.width > maxDimension || size.height > maxDimension else {
            return image
        }

        let scale: CGFloat
        if size.width > size.height {
            scale = maxDimension / size.width
        } else {
            scale = maxDimension / size.height
        }

        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

// MARK: - Errors

public enum PhotoPrepareError: Error, LocalizedError {
    case jpegEncodingFailed
    case unreadableImage

    public var errorDescription: String? {
        switch self {
        case .jpegEncodingFailed:
            return "Failed to encode image as JPEG"
        case .unreadableImage:
            return "Failed to load image from file"
        }
    }
}
