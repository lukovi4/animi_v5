import Foundation

// MARK: - Shared Assets Index

/// Builds a basename → URL index of shared assets from an App Bundle folder.
///
/// Shared assets are application-wide images (e.g. decorative frames, overlays)
/// used across multiple templates. They reside in the App Bundle under a root
/// folder (default: `SharedAssets/`).
///
/// Asset key = filename without extension, **case-sensitive**.
/// Keys must be globally unique within the shared assets folder.
public struct SharedAssetsIndex: Sendable {

    /// Allowed image file extensions for indexing
    public static let allowedExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]

    /// Internal index: basename (no extension, case-sensitive) → file URL
    private let index: [String: URL]

    // MARK: - Init from URL

    /// Creates a shared assets index by scanning a root directory.
    ///
    /// - Parameters:
    ///   - rootURL: Root directory to scan (e.g. `Bundle.resourceURL/SharedAssets`).
    ///     If `nil`, the index is empty.
    ///   - fileManager: FileManager for directory enumeration.
    /// - Throws: `AssetResolutionError.duplicateBasenameShared` if two files share the same basename.
    public init(rootURL: URL?, fileManager: FileManager = .default) throws {
        guard let rootURL = rootURL else {
            self.index = [:]
            return
        }

        var result: [String: URL] = [:]

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
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
                throw AssetResolutionError.duplicateBasenameShared(
                    key: basename, url1: existing, url2: fileURL
                )
            }
            result[basename] = fileURL
        }

        self.index = result
    }

    // MARK: - Init from Bundle (convenience)

    /// Creates a shared assets index from a Bundle.
    ///
    /// - Parameters:
    ///   - bundle: Bundle containing shared assets (e.g. `Bundle.main`).
    ///   - rootFolderName: Name of the root folder within the bundle (default: `"SharedAssets"`).
    ///   - fileManager: FileManager for directory enumeration.
    /// - Throws: `AssetResolutionError.duplicateBasenameShared` on duplicate basenames.
    public init(
        bundle: Bundle,
        rootFolderName: String = "SharedAssets",
        fileManager: FileManager = .default
    ) throws {
        let rootURL = bundle.resourceURL?.appendingPathComponent(rootFolderName)
        try self.init(rootURL: rootURL, fileManager: fileManager)
    }

    // MARK: - Empty

    /// An empty index (no shared assets available).
    public static let empty = try! SharedAssetsIndex(rootURL: nil)

    // MARK: - Lookup

    /// Returns the URL for a shared asset by its basename key.
    ///
    /// - Parameter key: Basename without extension, case-sensitive.
    /// - Returns: File URL if found, `nil` otherwise.
    public func url(forKey key: String) -> URL? {
        index[key]
    }

    /// Number of indexed shared assets.
    public var count: Int { index.count }

    /// All indexed basename keys.
    public var keys: Set<String> { Set(index.keys) }
}
