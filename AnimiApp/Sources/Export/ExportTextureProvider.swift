import Metal
import MetalKit
import TVECore

// MARK: - Export Texture Provider

/// Thread-safe texture provider for video export (PR-E2.B).
///
/// Unlike `ScenePackageTextureProvider`, this provider:
/// - Has NO `dispatchPrecondition(.main)` assertions
/// - Uses a lock for thread-safe cache access
/// - Must be fully preloaded before export begins
/// - Supports texture injection for user media
///
/// Usage:
/// ```swift
/// // Create on main thread
/// let exportProvider = ExportTextureProvider(
///     device: device,
///     assetIndex: compiledScene.mergedAssetIndex,
///     resolver: resolver,
///     bindingAssetIds: compiledScene.bindingAssetIds
/// )
///
/// // Preload all textures (can be done on any thread)
/// exportProvider.preloadAll(commandQueue: renderer.commandQueue)
///
/// // Inject user media textures (from main thread ScenePackageTextureProvider)
/// exportProvider.injectTextures(from: mainTextureProvider, for: bindingAssetIds)
///
/// // Use in export (thread-safe)
/// exporter.exportVideo(..., textureProvider: exportProvider, ...)
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
    /// Must call `preloadAll()` before using this method.
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

    // MARK: - Preloading

    /// Preloads all resolvable textures from the asset index.
    ///
    /// Must be called before export begins. After this call,
    /// `texture(for:)` becomes a pure O(1) cache lookup.
    ///
    /// Thread-safe: can be called from any queue.
    ///
    /// - Parameter commandQueue: Metal command queue for texture blit operations
    public func preloadAll(commandQueue: MTLCommandQueue) {
        for (assetId, basename) in assetIndex.basenameById {
            // Skip already cached
            lock.lock()
            let alreadyCached = cache[assetId] != nil
            lock.unlock()

            if alreadyCached {
                continue
            }

            // Skip binding assets (injected separately)
            if bindingAssetIds.contains(assetId) {
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

    /// Injects textures from another provider for specified asset IDs.
    ///
    /// Use this to copy user media textures from the main-thread
    /// `ScenePackageTextureProvider` before export begins.
    ///
    /// - Note: Must be called on main thread if source provider requires it.
    ///
    /// - Parameters:
    ///   - sourceProvider: Source texture provider (typically ScenePackageTextureProvider)
    ///   - assetIds: Asset IDs to copy from source
    public func injectTextures(from sourceProvider: TextureProvider, for assetIds: Set<String>) {
        for assetId in assetIds {
            if let texture = sourceProvider.texture(for: assetId) {
                setTexture(texture, for: assetId)
            }
        }
    }

    /// Clears the texture cache.
    public func clearCache() {
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
