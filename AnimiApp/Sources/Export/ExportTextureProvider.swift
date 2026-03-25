import Metal
import MetalKit
import TVECore

// MARK: - Export Texture Provider

/// Thread-safe texture provider for video export (PR-E2.B).
///
/// Unlike `ScenePackageTextureProvider`, this provider:
/// - Has NO `dispatchPrecondition(.main)` assertions
/// - Uses a lock for thread-safe cache access
/// - Supports scene-local residency: warm only the assets needed for the current scene
/// - Supports texture injection for user media (photos/video frames)
///
/// Usage:
/// ```swift
/// let exportProvider = ExportTextureProvider(
///     device: device,
///     assetIndex: compiledScene.mergedAssetIndex,
///     resolver: resolver,
///     bindingAssetIds: compiledScene.bindingAssetIds
/// )
///
/// // Warm template textures for the active scene
/// exportProvider.warm(assetIds: sceneAssetIds, commandQueue: queue)
///
/// // Inject user media via setTexture (photos loaded via DownsampledImageLoader)
/// exportProvider.setTexture(texture, for: assetId)
///
/// // On scene eviction:
/// exportProvider.clearAll()
/// ```
public final class ExportTextureProvider: MutableTextureProvider {
    // MARK: - Properties

    private let device: MTLDevice
    private let assetIndex: AssetIndexIR
    private let resolver: CompositeAssetResolver
    private let loader: MTKTextureLoader
    private let bindingAssetIds: Set<String>

    /// Thread-safe cache access via lock
    private let lock = NSLock()
    private var cache: [String: MTLTexture] = [:]
    private var missingAssets: Set<String> = []

    // MARK: - Initialization

    /// Creates a thread-safe texture provider for export.
    ///
    /// - Parameters:
    ///   - device: Metal device for texture creation
    ///   - assetIndex: Asset index with basename mappings (from CompiledScene.mergedAssetIndex)
    ///   - resolver: Composite resolver for Local → Shared resolution
    ///   - bindingAssetIds: Namespaced IDs of binding layer assets (no file on disk)
    public init(
        device: MTLDevice,
        assetIndex: AssetIndexIR,
        resolver: CompositeAssetResolver,
        bindingAssetIds: Set<String> = []
    ) {
        self.device = device
        self.assetIndex = assetIndex
        self.resolver = resolver
        self.bindingAssetIds = bindingAssetIds
        self.loader = MTKTextureLoader(device: device)
    }

    // MARK: - TextureProvider

    /// Returns the texture for the given asset ID.
    ///
    /// Thread-safe O(1) cache lookup. No IO performed.
    /// Must call `warm(assetIds:commandQueue:)` before using this method.
    public func texture(for assetId: String) -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }

        return cache[assetId]
    }

    // MARK: - MutableTextureProvider

    /// Injects a texture for runtime use (thread-safe).
    ///
    /// Used for user media injection (photos/video frames).
    public func setTexture(_ texture: MTLTexture, for assetId: String) {
        lock.lock()
        defer { lock.unlock() }

        cache[assetId] = texture
        missingAssets.remove(assetId)
    }

    /// Removes an injected texture (thread-safe).
    public func removeTexture(for assetId: String) {
        lock.lock()
        defer { lock.unlock() }

        cache.removeValue(forKey: assetId)
    }

    // MARK: - Targeted Loading

    /// Warms (loads) textures for the specified asset IDs.
    ///
    /// Only loads template assets that are resolvable via the asset index.
    /// Binding assets are skipped (they are injected separately via `setTexture`).
    /// Already-cached assets are skipped.
    ///
    /// For single-scene export, call with all scene asset IDs.
    /// For timeline export, called per-scene by the residency controller.
    ///
    /// Thread-safe: can be called from any queue.
    ///
    /// - Parameters:
    ///   - assetIds: Set of asset IDs to warm
    ///   - commandQueue: Metal command queue for texture blit operations
    public func warm(assetIds: Set<String>, commandQueue: MTLCommandQueue) {
        for assetId in assetIds {
            // Skip already cached
            lock.lock()
            let alreadyCached = cache[assetId] != nil
            lock.unlock()

            if alreadyCached {
                continue
            }

            // Skip binding assets (injected separately via setTexture)
            if bindingAssetIds.contains(assetId) {
                continue
            }

            // Resolve basename from asset index
            guard let basename = assetIndex.basenameById[assetId] else {
                continue
            }

            // Resolve URL
            guard let textureURL = try? resolver.resolveURL(forKey: basename) else {
                lock.lock()
                missingAssets.insert(assetId)
                lock.unlock()
                continue
            }

            // Load texture with premultiplied alpha
            if let texture = loadTexture(from: textureURL, commandQueue: commandQueue) {
                lock.lock()
                cache[assetId] = texture
                lock.unlock()
            } else {
                lock.lock()
                missingAssets.insert(assetId)
                lock.unlock()
            }
        }
    }

    /// Clears textures for the specified asset IDs.
    ///
    /// - Parameter assetIds: Set of asset IDs to clear
    public func clear(assetIds: Set<String>) {
        lock.lock()
        defer { lock.unlock() }

        for assetId in assetIds {
            cache.removeValue(forKey: assetId)
            missingAssets.remove(assetId)
        }
    }

    /// Clears all cached textures.
    public func clearAll() {
        lock.lock()
        defer { lock.unlock() }

        cache.removeAll()
        missingAssets.removeAll()
    }


    // MARK: - Private

    /// Loads texture with premultiplied alpha conversion.
    private func loadTexture(from url: URL, commandQueue: MTLCommandQueue) -> MTLTexture? {
        // Primary path: PremultipliedTextureLoader for correct alpha compositing
        do {
            return try PremultipliedTextureLoader.loadTexture(
                from: url,
                device: device,
                commandQueue: commandQueue
            )
        } catch {
            // Fallback: MTKTextureLoader
            let options: [MTKTextureLoader.Option: Any] = [
                .SRGB: false,
                .generateMipmaps: false,
                .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                .textureStorageMode: MTLStorageMode.private.rawValue
            ]

            return try? loader.newTexture(URL: url, options: options)
        }
    }
}
