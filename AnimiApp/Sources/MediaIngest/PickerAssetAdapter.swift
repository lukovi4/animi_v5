import Foundation
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Picker Asset Adapter

/// Extracts file representations from PHPicker results.
/// Replaces inline loadObject(UIImage.self) and loadFileRepresentation in PlayerViewController.
///
/// Usage:
/// ```swift
/// let asset = try await PickerAssetAdapter.extract(from: result)
/// // asset is .photo(UIImage) or .video(URL)
/// ```
public enum PickerAssetAdapter {

    /// Extracted asset from PHPicker.
    public enum PickedAsset: Sendable {
        case photo(UIImage)
        case video(URL)  // Temporary URL — valid only until consumed by ingest pipeline
    }

    // MARK: - Extraction

    /// Extracts the media asset from a PHPicker result.
    /// Copies video files to temp before returning (PHPicker URLs expire after callback).
    ///
    /// - Parameter result: PHPicker result
    /// - Returns: Extracted asset
    /// - Throws: If loading fails or media type is unsupported
    @MainActor
    public static func extract(from result: PHPickerResult) async throws -> PickedAsset {
        let provider = result.itemProvider

        // Try video first (loadFileRepresentation)
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            let tempURL = try await loadVideoRepresentation(provider: provider)
            return .video(tempURL)
        }

        // Try photo
        if provider.canLoadObject(ofClass: UIImage.self) {
            let image = try await loadImage(provider: provider)
            return .photo(image)
        }

        throw PickerAssetError.unsupportedMediaType
    }

    /// Determines the expected media kind from a PHPicker result without loading.
    public static func mediaKind(of result: PHPickerResult) -> MediaKind? {
        let provider = result.itemProvider
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            return .video
        }
        if provider.canLoadObject(ofClass: UIImage.self) {
            return .photo
        }
        return nil
    }

    // MARK: - Private Loaders

    private static func loadImage(provider: NSItemProvider) async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadObject(ofClass: UIImage.self) { object, error in
                if let image = object as? UIImage {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? PickerAssetError.imageLoadFailed)
                }
            }
        }
    }

    private static func loadVideoRepresentation(provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in
                guard let sourceURL = url else {
                    continuation.resume(throwing: error ?? PickerAssetError.videoLoadFailed)
                    return
                }

                // PHPicker URL is only valid inside this callback — must copy immediately
                let tempDir = FileManager.default.temporaryDirectory
                let tempURL = tempDir.appendingPathComponent("\(UUID().uuidString).\(sourceURL.pathExtension)")

                do {
                    try FileManager.default.copyItem(at: sourceURL, to: tempURL)
                    continuation.resume(returning: tempURL)
                } catch {
                    continuation.resume(throwing: PickerAssetError.videoCopyFailed(error))
                }
            }
        }
    }
}

// MARK: - Errors

public enum PickerAssetError: Error, LocalizedError {
    case unsupportedMediaType
    case imageLoadFailed
    case videoLoadFailed
    case videoCopyFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .unsupportedMediaType:
            return "Unsupported media type from picker"
        case .imageLoadFailed:
            return "Failed to load image from picker"
        case .videoLoadFailed:
            return "Failed to load video from picker"
        case .videoCopyFailed(let error):
            return "Failed to copy video from picker: \(error.localizedDescription)"
        }
    }
}
