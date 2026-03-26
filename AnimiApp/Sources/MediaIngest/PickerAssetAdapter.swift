import Foundation
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Picker Asset Adapter

/// Extracts file representations from PHPicker results.
/// All media paths are file-based — no UIImage materialization.
///
/// Photo path: `extract(from:)` → temp copy → returned as `.photo(URL)`
/// Video path: `withVideoFileRepresentation(from:perform:)` — caller does persistent copy inside callback
public enum PickerAssetAdapter {

    /// Extracted asset from PHPicker (photo only — video uses withVideoFileRepresentation).
    public enum PickedAsset: Sendable {
        case photo(URL)  // Temporary URL — valid only until consumed by ingest pipeline
    }

    // MARK: - Photo Extraction

    /// Extracts a photo asset from a PHPicker result.
    /// Copies file to temp before returning (PHPicker URLs expire after callback).
    ///
    /// - Parameter result: PHPicker result
    /// - Returns: Extracted photo asset
    /// - Throws: If loading fails or media type is unsupported
    @MainActor
    public static func extractPhoto(from result: PHPickerResult) async throws -> PickedAsset {
        let provider = result.itemProvider

        guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
            throw PickerAssetError.unsupportedMediaType
        }

        let tempURL = try await loadImageFileRepresentation(provider: provider)
        return .photo(tempURL)
    }

    // MARK: - Video File Representation

    /// Provides access to the PHPicker video file URL inside a scoped callback.
    /// The callback runs on a system thread while the PHPicker URL is still valid.
    /// Use this to perform the single persistent copy (MediaAssetStore.saveMedia) directly.
    ///
    /// - Parameters:
    ///   - result: PHPicker result
    ///   - perform: Closure called with the source URL while it's valid. Must be Sendable.
    /// - Returns: Result of the perform closure
    /// - Throws: If loading fails or the perform closure throws
    public static func withVideoFileRepresentation<T: Sendable>(
        from result: PHPickerResult,
        perform: @escaping @Sendable (URL) throws -> T
    ) async throws -> T {
        let provider = result.itemProvider

        guard provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) else {
            throw PickerAssetError.unsupportedMediaType
        }

        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in
                guard let sourceURL = url else {
                    continuation.resume(throwing: error ?? PickerAssetError.videoLoadFailed)
                    return
                }

                do {
                    let result = try perform(sourceURL)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Determines the expected media kind from a PHPicker result without loading.
    public static func mediaKind(of result: PHPickerResult) -> MediaKind? {
        let provider = result.itemProvider
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            return .video
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            return .photo
        }
        return nil
    }

    // MARK: - Private Loaders

    private static func loadImageFileRepresentation(provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
                guard let sourceURL = url else {
                    continuation.resume(throwing: error ?? PickerAssetError.imageLoadFailed)
                    return
                }

                // PHPicker URL is only valid inside this callback — must copy immediately
                let tempDir = FileManager.default.temporaryDirectory
                let tempURL = tempDir.appendingPathComponent("\(UUID().uuidString).\(sourceURL.pathExtension)")

                do {
                    try FileManager.default.copyItem(at: sourceURL, to: tempURL)
                    continuation.resume(returning: tempURL)
                } catch {
                    continuation.resume(throwing: PickerAssetError.imageCopyFailed(error))
                }
            }
        }
    }
}

// MARK: - Errors

public enum PickerAssetError: Error, LocalizedError {
    case unsupportedMediaType
    case imageLoadFailed
    case imageCopyFailed(Error)
    case videoLoadFailed

    public var errorDescription: String? {
        switch self {
        case .unsupportedMediaType:
            return "Unsupported media type from picker"
        case .imageLoadFailed:
            return "Failed to load image from picker"
        case .imageCopyFailed(let error):
            return "Failed to copy image from picker: \(error.localizedDescription)"
        case .videoLoadFailed:
            return "Failed to load video from picker"
        }
    }
}
