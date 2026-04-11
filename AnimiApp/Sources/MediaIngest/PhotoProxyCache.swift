import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Disk cache for photo proxy images (downsampled for runtime preview).
/// Derived artifact — not part of the schema. Regenerated on miss from master.
///
/// - Key: opaque stable `String` per media file (current callers pass
///   `slot.mediaRef.assetId.rawValue.uuidString`). PhotoProxyCache does
///   not know about `MediaRef` internals — it only sees the key.
/// - Profile: `2048px` long edge
/// - Format: JPEG for opaque images, PNG for images with alpha
/// - TTL: 7 days (matches `VideoPosterCache`); GC wired at app launch via `collectExpired()`
/// - Thread-safe: per-key lock prevents duplicate concurrent generation; atomic temp→rename
public final class PhotoProxyCache: @unchecked Sendable {

    /// Shared instance.
    public static let shared = PhotoProxyCache()

    /// Maximum dimension (long edge) for proxy images.
    public static let maxDimension: Int = 2048

    /// JPEG compression quality for opaque proxies.
    public static let jpegQuality: CGFloat = 0.9

    /// TTL for cached proxies (7 days).
    public static let ttlSeconds: TimeInterval = 7 * 24 * 3600

    /// Cache directory name within Application Support.
    private static let cacheDirectoryName = "PhotoProxyCache"

    private let fileManager: FileManager

    /// Per-key lock to prevent concurrent generation of the same proxy.
    private let lock = NSLock()
    private var inFlightKeys: Set<String> = []

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: - Cache Directory

    private func cacheDirectoryURL() throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent(Self.cacheDirectoryName)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Cache Key

    private func cacheKey(for mediaRefId: String) -> String {
        mediaRefId.replacingOccurrences(of: "/", with: "_")
    }

    // MARK: - Public API

    /// Returns the proxy URL for a photo, generating it lazily from master if needed.
    /// Thread-safe: concurrent calls for the same key are serialized.
    ///
    /// - Parameters:
    ///   - masterURL: Absolute URL of the master photo file
    ///   - mediaRefId: Opaque stable key for cache identity. Callers pass
    ///     `slot.mediaRef.assetId.rawValue.uuidString`.
    /// - Returns: URL to the proxy file, or `nil` if generation fails
    public func proxyURL(masterURL: URL, mediaRefId: String) -> URL? {
        let key = cacheKey(for: mediaRefId)

        // Fast path: cache hit (no lock needed for read — file existence is atomic)
        if let cached = cachedProxyURL(key: key) {
            return cached
        }

        // Acquire per-key generation slot
        lock.lock()
        if inFlightKeys.contains(key) {
            lock.unlock()
            // Another thread is generating this proxy — spin-wait briefly then re-check cache
            Thread.sleep(forTimeInterval: 0.05)
            return cachedProxyURL(key: key)
        }
        inFlightKeys.insert(key)
        lock.unlock()

        defer {
            lock.lock()
            inFlightKeys.remove(key)
            lock.unlock()
        }

        // Double-check after acquiring slot (another thread may have just finished)
        if let cached = cachedProxyURL(key: key) {
            return cached
        }

        // Generate with atomic temp→rename
        return generateProxy(masterURL: masterURL, key: key)
    }

    // MARK: - Generation (atomic)

    private func generateProxy(masterURL: URL, key: String) -> URL? {
        guard let source = CGImageSourceCreateWithURL(masterURL as CFURL, nil) else { return nil }

        let hasAlpha = sourceHasAlpha(source)
        let ext = hasAlpha ? "png" : "jpg"

        guard let cacheDir = try? cacheDirectoryURL() else { return nil }
        let finalURL = cacheDir.appendingPathComponent("\(key).\(ext)")

        // Get original dimensions to avoid upscaling
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let originalWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let originalHeight = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }

        let maxOriginal = max(originalWidth, originalHeight)
        let targetDimension = min(Self.maxDimension, maxOriginal)

        // Create downsampled image with EXIF orientation applied
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: targetDimension
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        // Write to temp file first, then atomic rename
        let tempURL = cacheDir.appendingPathComponent(".\(key).\(ext).tmp")

        let destType = hasAlpha ? UTType.png.identifier as CFString : UTType.jpeg.identifier as CFString
        guard let dest = CGImageDestinationCreateWithURL(tempURL as CFURL, destType, 1, nil) else { return nil }

        let writeOptions: [CFString: Any]
        if hasAlpha {
            writeOptions = [:]
        } else {
            writeOptions = [kCGImageDestinationLossyCompressionQuality: Self.jpegQuality]
        }

        CGImageDestinationAddImage(dest, thumbnail, writeOptions as CFDictionary)

        guard CGImageDestinationFinalize(dest) else {
            try? fileManager.removeItem(at: tempURL)
            return nil
        }

        // Atomic rename: temp → final
        do {
            if fileManager.fileExists(atPath: finalURL.path) {
                try fileManager.removeItem(at: finalURL)
            }
            try fileManager.moveItem(at: tempURL, to: finalURL)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            return nil
        }

        return finalURL
    }

    // MARK: - Alpha Detection

    private func sourceHasAlpha(_ source: CGImageSource) -> Bool {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
        if let hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool {
            return hasAlpha
        }
        if let depth = properties[kCGImagePropertyDepth] as? Int, depth == 32 {
            return true
        }
        return false
    }

    // MARK: - Cache Lookup

    private func cachedProxyURL(key: String) -> URL? {
        guard let dir = try? cacheDirectoryURL() else { return nil }
        for ext in ["jpg", "png"] {
            let url = dir.appendingPathComponent("\(key).\(ext)")
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    // MARK: - GC

    /// Removes expired cache entries (older than TTL).
    /// Call at app launch or periodically.
    public func collectExpired() {
        guard let dir = try? cacheDirectoryURL(),
              let contents = try? fileManager.contentsOfDirectory(
                  at: dir,
                  includingPropertiesForKeys: [.contentModificationDateKey],
                  options: [.skipsHiddenFiles]
              ) else { return }

        let cutoff = Date().addingTimeInterval(-Self.ttlSeconds)

        for fileURL in contents {
            guard let attrs = try? fileManager.attributesOfItem(atPath: fileURL.path),
                  let modDate = attrs[.modificationDate] as? Date,
                  modDate < cutoff else { continue }
            try? fileManager.removeItem(at: fileURL)
        }
    }

    /// Removes all cached proxies.
    public func clearAll() {
        guard let dir = try? cacheDirectoryURL() else { return }
        try? fileManager.removeItem(at: dir)
    }
}
