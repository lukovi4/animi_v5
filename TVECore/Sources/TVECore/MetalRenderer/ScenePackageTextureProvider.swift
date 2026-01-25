import Metal
import MetalKit
import Foundation

// MARK: - Logger Type

/// Logger callback for diagnostic messages
public typealias TVELogger = (String) -> Void

// MARK: - Scene Package Texture Provider

/// Texture provider that loads textures from a scene package's images folder.
/// Uses MTKTextureLoader with caching by asset ID.
public final class ScenePackageTextureProvider: TextureProvider {
    // MARK: - Properties

    private let device: MTLDevice
    private let imagesRootURL: URL
    private let assetIndex: AssetIndexIR
    private let loader: MTKTextureLoader
    private var cache: [String: MTLTexture] = [:]
    private var missingAssets: Set<String> = []
    private let logger: TVELogger?

    // MARK: - Initialization

    /// Creates a texture provider for a scene package.
    /// - Parameters:
    ///   - device: Metal device for texture creation
    ///   - imagesRootURL: Root URL for images folder
    ///   - assetIndex: Asset index mapping asset IDs to relative paths
    ///   - logger: Optional logger for diagnostic messages
    public init(device: MTLDevice, imagesRootURL: URL, assetIndex: AssetIndexIR, logger: TVELogger? = nil) {
        self.device = device
        self.imagesRootURL = imagesRootURL
        self.assetIndex = assetIndex
        self.loader = MTKTextureLoader(device: device)
        self.logger = logger
    }

    // MARK: - TextureProvider

    /// Returns the texture for the given asset ID.
    /// Textures are loaded on first access and cached for subsequent calls.
    public func texture(for assetId: String) -> MTLTexture? {
        // Check cache first
        if let cached = cache[assetId] {
            return cached
        }

        // Skip known missing assets (don't spam log)
        if missingAssets.contains(assetId) {
            return nil
        }

        // Look up relative path in asset index
        guard let relativePath = assetIndex.byId[assetId] else {
            logger?("[TextureProvider] Asset '\(assetId)' not in index")
            missingAssets.insert(assetId)
            return nil
        }

        // Build full URL
        let textureURL = imagesRootURL.appendingPathComponent(relativePath)

        // Load texture
        guard let texture = loadTexture(from: textureURL, assetId: assetId) else {
            missingAssets.insert(assetId)
            return nil
        }

        // Cache and return
        cache[assetId] = texture
        return texture
    }

    // MARK: - Preloading

    /// Preloads all textures from the asset index.
    /// Call this to avoid loading delays during rendering.
    /// - Throws: Error if any texture fails to load
    public func preloadAll() throws {
        for (assetId, relativePath) in assetIndex.byId {
            if cache[assetId] != nil {
                continue
            }

            let textureURL = imagesRootURL.appendingPathComponent(relativePath)
            guard let texture = loadTexture(from: textureURL, assetId: assetId) else {
                throw TextureLoadError.failedToLoad(assetId: assetId, path: relativePath)
            }
            cache[assetId] = texture
        }
    }

    /// Clears the texture cache and missing assets set.
    public func clearCache() {
        cache.removeAll()
        missingAssets.removeAll()
    }

    // MARK: - Private

    private func loadTexture(from url: URL, assetId: String) -> MTLTexture? {
        // Load with options for premultiplied alpha
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: false, // Linear color space for correct blending
            .generateMipmaps: false,
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.shared.rawValue
        ]

        do {
            return try loader.newTexture(URL: url, options: options)
        } catch {
            logger?("[TextureProvider] Failed to load '\(assetId)' at \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - Texture Load Error

/// Errors that can occur during texture loading.
public enum TextureLoadError: Error, Sendable {
    case failedToLoad(assetId: String, path: String)
}

extension TextureLoadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .failedToLoad(let assetId, let path):
            return "Failed to load texture for asset '\(assetId)' at path '\(path)'"
        }
    }
}
