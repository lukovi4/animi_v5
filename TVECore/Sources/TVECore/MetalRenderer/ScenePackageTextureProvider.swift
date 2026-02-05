import Metal
import MetalKit
import Foundation

// MARK: - Logger Type

/// Logger callback for diagnostic messages
public typealias TVELogger = (String) -> Void

// MARK: - Scene Package Texture Provider

/// Texture provider that resolves textures via basename-based asset resolution (PR-28).
///
/// Resolution pipeline per asset ID:
/// 1. Check cache (includes externally injected textures, e.g. user media photos)
/// 2. Look up basename via `AssetIndexIR.basenameById`
/// 3. Resolve URL via `CompositeAssetResolver` (Local → Shared)
/// 4. Load texture from resolved URL
///
/// Binding layer textures are injected externally via `setTexture(_:for:)`.
/// When user media is not selected, the binding layer is skipped at render time (PR-28 Q2),
/// so TextureProvider is never asked for the binding asset ID.
public final class ScenePackageTextureProvider: TextureProvider {
    // MARK: - Properties

    private let device: MTLDevice
    private let assetIndex: AssetIndexIR
    private let resolver: CompositeAssetResolver
    private let loader: MTKTextureLoader
    private var cache: [String: MTLTexture] = [:]
    private var missingAssets: Set<String> = []
    private let logger: TVELogger?

    /// Namespaced asset IDs that belong to binding layers (PR-28 Fix-A).
    /// These assets have no file on disk — user media is injected at runtime.
    /// Only these IDs may be skipped during preload; all others are treated as errors.
    private let bindingAssetIds: Set<String>

    // MARK: - Initialization

    /// Creates a texture provider with resolver-based asset resolution.
    /// - Parameters:
    ///   - device: Metal device for texture creation
    ///   - assetIndex: Asset index with basename mappings (from compilation)
    ///   - resolver: Composite resolver for Local → Shared resolution
    ///   - bindingAssetIds: Namespaced IDs of binding layer assets (no file on disk).
    ///     Only these may be skipped during preload. All other missing assets are errors.
    ///   - logger: Optional logger for diagnostic messages
    public init(
        device: MTLDevice,
        assetIndex: AssetIndexIR,
        resolver: CompositeAssetResolver,
        bindingAssetIds: Set<String> = [],
        logger: TVELogger? = nil
    ) {
        self.device = device
        self.assetIndex = assetIndex
        self.resolver = resolver
        self.bindingAssetIds = bindingAssetIds
        self.loader = MTKTextureLoader(device: device)
        self.logger = logger
    }

    // MARK: - TextureProvider

    /// Returns the texture for the given asset ID.
    /// Textures are loaded on first access and cached for subsequent calls.
    /// Externally injected textures (via `setTexture`) are returned from cache directly.
    public func texture(for assetId: String) -> MTLTexture? {
        // Check cache first (includes injected user media textures)
        if let cached = cache[assetId] {
            return cached
        }

        // Skip known missing assets (don't spam log)
        if missingAssets.contains(assetId) {
            return nil
        }

        // Look up basename in asset index (PR-28)
        guard let basename = assetIndex.basenameById[assetId] else {
            logger?("[TextureProvider] Asset '\(assetId)' has no basename in index")
            missingAssets.insert(assetId)
            return nil
        }

        // Resolve URL via CompositeAssetResolver (Local → Shared)
        let textureURL: URL
        do {
            textureURL = try resolver.resolveURL(forKey: basename)
        } catch {
            logger?("[TextureProvider] Asset '\(assetId)' (basename='\(basename)') not found: \(error.localizedDescription)")
            missingAssets.insert(assetId)
            return nil
        }

        // Load texture from resolved URL
        guard let texture = loadTexture(from: textureURL, assetId: assetId) else {
            missingAssets.insert(assetId)
            return nil
        }

        // Cache and return
        cache[assetId] = texture
        return texture
    }

    // MARK: - External Texture Injection

    /// Injects an externally provided texture (e.g. user-selected media photo).
    ///
    /// Injected textures are stored in cache and returned directly by `texture(for:)`,
    /// bypassing resolver-based resolution. Used for binding layer user media.
    ///
    /// - Parameters:
    ///   - texture: Metal texture to inject
    ///   - assetId: Asset ID to associate the texture with (namespaced)
    public func setTexture(_ texture: MTLTexture, for assetId: String) {
        cache[assetId] = texture
        missingAssets.remove(assetId)
    }

    /// Removes an injected texture, allowing re-resolution or marking as missing.
    ///
    /// - Parameter assetId: Asset ID to remove from cache
    public func removeTexture(for assetId: String) {
        cache.removeValue(forKey: assetId)
        missingAssets.remove(assetId)
    }

    // MARK: - Preloading

    /// Preloads all resolvable textures from the asset index.
    ///
    /// Binding assets (identified by `bindingAssetIds`) are expected to have no file on disk
    /// and are skipped with a debug log. All other non-resolvable assets are logged as errors
    /// and added to `missingAssets` — this indicates a corrupted template.
    public func preloadAll() {
        for (assetId, basename) in assetIndex.basenameById {
            // Skip already cached (including injected textures)
            if cache[assetId] != nil { continue }

            guard let textureURL = try? resolver.resolveURL(forKey: basename) else {
                if bindingAssetIds.contains(assetId) {
                    // Expected: binding asset has no file (user media injected at runtime)
                    logger?("[TextureProvider] Preload skipped binding asset '\(assetId)'")
                } else {
                    // Unexpected: non-binding asset missing — template corrupted
                    logger?("[TextureProvider] ERROR: Asset '\(assetId)' (basename='\(basename)') not resolvable — template may be corrupted")
                    missingAssets.insert(assetId)
                }
                continue
            }

            if let texture = loadTexture(from: textureURL, assetId: assetId) {
                cache[assetId] = texture
            }
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
