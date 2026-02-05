import Foundation

// MARK: - Local Assets Index

/// Builds a basename → URL index of local assets within a ScenePackage `images/` folder.
///
/// Local assets are template-specific images (e.g. decorative overlays) shipped
/// inside the scene package directory under `images/`.
///
/// Asset key = filename without extension, **case-sensitive**.
/// Keys must be unique within the package; duplicates are a template error.
public struct LocalAssetsIndex: Sendable {

    /// Allowed image file extensions for indexing (same as SharedAssetsIndex)
    public static let allowedExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]

    /// Internal index: basename (no extension, case-sensitive) → file URL
    private let index: [String: URL]

    // MARK: - Init

    /// Creates a local assets index by scanning the `images/` directory of a scene package.
    ///
    /// - Parameters:
    ///   - imagesRootURL: URL of the `images/` directory. If `nil`, the index is empty.
    ///   - fileManager: FileManager for directory enumeration.
    /// - Throws: `AssetResolutionError.duplicateBasenameLocal` if two files share the same basename.
    public init(imagesRootURL: URL?, fileManager: FileManager = .default) throws {
        guard let imagesRootURL = imagesRootURL else {
            self.index = [:]
            return
        }

        var result: [String: URL] = [:]

        guard let enumerator = fileManager.enumerator(
            at: imagesRootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            self.index = [:]
            return
        }

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard Self.allowedExtensions.contains(ext) else { continue }

            let basename = (fileURL.lastPathComponent as NSString).deletingPathExtension
            guard !basename.isEmpty else { continue }

            if let existing = result[basename] {
                throw AssetResolutionError.duplicateBasenameLocal(
                    key: basename, url1: existing, url2: fileURL
                )
            }
            result[basename] = fileURL
        }

        self.index = result
    }

    // MARK: - Empty

    /// An empty index (no local images directory).
    public static let empty = try! LocalAssetsIndex(imagesRootURL: nil)

    // MARK: - Lookup

    /// Returns the URL for a local asset by its basename key.
    ///
    /// - Parameter key: Basename without extension, case-sensitive.
    /// - Returns: File URL if found, `nil` otherwise.
    public func url(forKey key: String) -> URL? {
        index[key]
    }

    /// Number of indexed local assets.
    public var count: Int { index.count }

    /// All indexed basename keys.
    public var keys: Set<String> { Set(index.keys) }
}
