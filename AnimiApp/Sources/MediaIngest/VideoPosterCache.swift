import Foundation
import AVFoundation
import UIKit

// MARK: - Video Poster Cache

/// Disk cache for video poster frames (first frame thumbnails).
/// Derived artifact — not part of the schema. Regenerated on miss.
/// Removable by GC without data loss.
public final class VideoPosterCache {

    /// Shared instance.
    public static let shared = VideoPosterCache()

    /// Cache directory name within Application Support.
    private static let cacheDirectoryName = "VideoPosterCache"

    /// TTL for cached posters (7 days).
    public static let ttlSeconds: TimeInterval = 7 * 24 * 3600

    private let fileManager: FileManager

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

    /// Generates a cache key from a video file URL.
    /// Uses the file's last path component + modification date for uniqueness.
    private func cacheKey(for videoURL: URL) -> String {
        let name = videoURL.lastPathComponent
        let mod = (try? fileManager.attributesOfItem(atPath: videoURL.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(name)_\(Int(mod))"
    }

    private func cachedFileURL(for key: String) throws -> URL {
        try cacheDirectoryURL().appendingPathComponent("\(key).jpg")
    }

    // MARK: - Get / Generate

    /// Returns a cached poster image for the video, or generates and caches one.
    ///
    /// - Parameter videoURL: Persisted video file URL
    /// - Returns: UIImage of the poster frame, or nil if extraction fails
    public func poster(for videoURL: URL) async -> UIImage? {
        let key = cacheKey(for: videoURL)

        // Check cache
        if let cached = try? cachedFileURL(for: key),
           fileManager.fileExists(atPath: cached.path),
           let image = UIImage(contentsOfFile: cached.path) {
            return image
        }

        // Generate
        guard let image = await extractPoster(from: videoURL) else { return nil }

        // Cache
        if let jpegData = image.jpegData(compressionQuality: 0.8),
           let dest = try? cachedFileURL(for: key) {
            try? jpegData.write(to: dest, options: .atomic)
        }

        return image
    }

    // MARK: - Poster Extraction

    private func extractPoster(from videoURL: URL) async -> UIImage? {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1024, height: 1024)

        do {
            let (cgImage, _) = try await generator.image(at: .zero)
            return UIImage(cgImage: cgImage)
        } catch {
            return nil
        }
    }

    // MARK: - GC

    /// Removes expired cache entries.
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

    /// Removes all cached posters.
    public func clearAll() {
        guard let dir = try? cacheDirectoryURL() else { return }
        try? fileManager.removeItem(at: dir)
    }
}
