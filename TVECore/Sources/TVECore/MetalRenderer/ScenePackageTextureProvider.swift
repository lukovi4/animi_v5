import Metal
import MetalKit
import Foundation

// MARK: - Logger Type

/// Logger callback for diagnostic messages
public typealias TVELogger = (String) -> Void

// MARK: - Preload Stats (PR-B)

/// Statistics from texture preloading phase.
public struct PreloadStats: Sendable {
    /// Number of textures successfully loaded into cache.
    public let loadedCount: Int
    /// Number of assets that failed to load (missing/corrupted).
    public let missingCount: Int
    /// Number of binding assets skipped (expected — user media injected at runtime).
    public let skippedBindingCount: Int
    /// Duration of preload in milliseconds.
    public let durationMs: Double
}

// MARK: - Shared Preload Core (TT-07)

/// Internal shared core that owns preload infrastructure.
/// Used by both `ScenePackageBaseTextureProvider` (immutable) and
/// `ScenePackageTextureProvider` (mutable, scene-edit path).
final class TexturePreloadCore {
    let device: MTLDevice
    let assetIndex: AssetIndexIR
    let resolver: CompositeAssetResolver
    let bindingAssetIds: Set<String>
    let logger: TVELogger?

    private let loader: MTKTextureLoader
    private(set) var baseCache: [String: MTLTexture] = [:]
    private(set) var missingAssets: Set<String> = []
    private(set) var lastPreloadStats: PreloadStats?

    init(
        device: MTLDevice,
        assetIndex: AssetIndexIR,
        resolver: CompositeAssetResolver,
        bindingAssetIds: Set<String>,
        logger: TVELogger?
    ) {
        self.device = device
        self.assetIndex = assetIndex
        self.resolver = resolver
        self.bindingAssetIds = bindingAssetIds
        self.logger = logger
        self.loader = MTKTextureLoader(device: device)
    }

    /// Preloads all resolvable textures from the asset index with premultiplied alpha.
    ///
    /// **PR-B: Must be called before any rendering.** After this call, `texture(for:)`
    /// becomes a pure O(1) cache lookup with no IO.
    ///
    /// Binding assets (identified by `bindingAssetIds`) are expected to have no file on disk
    /// and are skipped with a debug log. All other non-resolvable assets are logged as errors.
    func preloadAll(commandQueue: MTLCommandQueue) {
        let startTime = CFAbsoluteTimeGetCurrent()
        var loadedCount = 0
        var skippedBindingCount = 0

        for (assetId, basename) in assetIndex.basenameById {
            // Skip already cached
            if baseCache[assetId] != nil {
                loadedCount += 1
                continue
            }

            guard let textureURL = try? resolver.resolveURL(forKey: basename) else {
                if bindingAssetIds.contains(assetId) {
                    logger?("[TextureProvider] Preload skipped binding asset '\(assetId)'")
                    skippedBindingCount += 1
                } else {
                    logger?("[TextureProvider] ERROR: Asset '\(assetId)' (basename='\(basename)') not resolvable — template may be corrupted")
                    missingAssets.insert(assetId)
                }
                continue
            }

            if let texture = loadTexture(from: textureURL, assetId: assetId, commandQueue: commandQueue) {
                baseCache[assetId] = texture
                loadedCount += 1
            }
        }

        let durationMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0

        lastPreloadStats = PreloadStats(
            loadedCount: loadedCount,
            missingCount: missingAssets.count,
            skippedBindingCount: skippedBindingCount,
            durationMs: durationMs
        )
    }

    /// Memoizes an asset ID as missing at runtime (prevents repeated assertionFailure spam).
    func recordRuntimeMiss(_ assetId: String) {
        missingAssets.insert(assetId)
    }

    /// Clears the base cache and missing assets set.
    func clearCache() {
        baseCache.removeAll()
        missingAssets.removeAll()
    }

    /// Loads texture with premultiplied alpha conversion.
    private func loadTexture(from url: URL, assetId: String, commandQueue: MTLCommandQueue) -> MTLTexture? {
        do {
            return try PremultipliedTextureLoader.loadTexture(
                from: url,
                device: device,
                commandQueue: commandQueue
            )
        } catch {
            let fileExtension = url.pathExtension.lowercased()
            logger?("[TextureProvider] FALLBACK: PremultipliedLoader failed for '\(assetId)' [\(fileExtension)]: \(error.localizedDescription)")

            let options: [MTKTextureLoader.Option: Any] = [
                .SRGB: false,
                .generateMipmaps: false,
                .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                .textureStorageMode: MTLStorageMode.private.rawValue
            ]

            do {
                let texture = try loader.newTexture(URL: url, options: options)
                logger?("[TextureProvider] WARNING: Fallback loaded '\(assetId)' [\(fileExtension)] — may have straight alpha (potential compositing issue)")
                return texture
            } catch let fallbackError {
                missingAssets.insert(assetId)
                logger?("[TextureProvider] ERROR: Both loaders failed for '\(assetId)' [\(fileExtension)] at \(url.lastPathComponent): \(fallbackError.localizedDescription)")
                return nil
            }
        }
    }
}

// MARK: - Scene Package Base Texture Provider (TT-07: Immutable)

/// Immutable texture provider for shared base textures per sceneTypeId.
///
/// Does NOT conform to `MutableTextureProvider` — no `setTexture`/`removeTexture`.
/// Used by `SceneTypeResourcesCache` for the shared base layer in timeline runtime.
/// Per-instance user media is handled by a separate overlay provider via `LayeredTextureProvider`.
public final class ScenePackageBaseTextureProvider: TextureProvider {

    private let core: TexturePreloadCore

    /// Last preload statistics (available after preloadAll(commandQueue:) call).
    public var lastPreloadStats: PreloadStats? {
        core.lastPreloadStats
    }

    /// Creates an immutable base texture provider.
    /// - Parameters:
    ///   - device: Metal device for texture creation
    ///   - assetIndex: Asset index with basename mappings (from compilation)
    ///   - resolver: Composite resolver for Local → Shared resolution
    ///   - bindingAssetIds: Namespaced IDs of binding layer assets (no file on disk).
    ///   - logger: Optional logger for diagnostic messages
    public init(
        device: MTLDevice,
        assetIndex: AssetIndexIR,
        resolver: CompositeAssetResolver,
        bindingAssetIds: Set<String> = [],
        logger: TVELogger? = nil
    ) {
        self.core = TexturePreloadCore(
            device: device,
            assetIndex: assetIndex,
            resolver: resolver,
            bindingAssetIds: bindingAssetIds,
            logger: logger
        )
    }

    // MARK: - TextureProvider

    /// Returns the texture for the given asset ID.
    ///
    /// **PR-B: IO-free runtime** — O(1) cache lookup only.
    ///
    /// Model A contract: texture access happens only on main during playback/render.
    public func texture(for assetId: String) -> MTLTexture? {
        dispatchPrecondition(condition: .onQueue(.main))

        if let cached = core.baseCache[assetId] {
            return cached
        }

        if core.missingAssets.contains(assetId) {
            return nil
        }

        // Binding assets return nil (no file on disk, injected via overlay)
        if core.bindingAssetIds.contains(assetId) {
            return nil
        }

        assertionFailure("[TextureProvider] Asset not preloaded: '\(assetId)' — call preloadAll(commandQueue:) before rendering")
        core.recordRuntimeMiss(assetId)
        return nil
    }

    // MARK: - Preloading

    /// Preloads all resolvable textures with premultiplied alpha.
    /// - Parameter commandQueue: Metal command queue for staging → private texture blit
    public func preloadAll(commandQueue: MTLCommandQueue) {
        core.preloadAll(commandQueue: commandQueue)
    }

    /// Clears the texture cache and missing assets set.
    public func clearCache() {
        core.clearCache()
    }
}

// MARK: - Scene Package Texture Provider (Mutable, Scene-Edit Path)

/// Mutable texture provider for scene-edit / legacy single-scene path.
///
/// TT-07: Internal base/overlay split — preloaded textures live in base cache,
/// injected textures live in overlay cache. `texture(for:)` checks overlay → base.
/// `removeTexture(for:)` removes only the overlay override, revealing base texture if present.
///
/// Conforms to `MutableTextureProvider` (PR-32) for user media injection.
public final class ScenePackageTextureProvider: MutableTextureProvider {

    private let core: TexturePreloadCore

    /// Per-instance overlay cache for injected textures (user media).
    private var overlayCache: [String: MTLTexture] = [:]

    /// PR-B: Last preload statistics (available after preloadAll(commandQueue:) call).
    public var lastPreloadStats: PreloadStats? {
        core.lastPreloadStats
    }

    // MARK: - Initialization

    /// Creates a mutable texture provider with resolver-based asset resolution.
    /// - Parameters:
    ///   - device: Metal device for texture creation
    ///   - assetIndex: Asset index with basename mappings (from compilation)
    ///   - resolver: Composite resolver for Local → Shared resolution
    ///   - bindingAssetIds: Namespaced IDs of binding layer assets (no file on disk).
    ///   - logger: Optional logger for diagnostic messages
    public init(
        device: MTLDevice,
        assetIndex: AssetIndexIR,
        resolver: CompositeAssetResolver,
        bindingAssetIds: Set<String> = [],
        logger: TVELogger? = nil
    ) {
        self.core = TexturePreloadCore(
            device: device,
            assetIndex: assetIndex,
            resolver: resolver,
            bindingAssetIds: bindingAssetIds,
            logger: logger
        )
    }

    // MARK: - TextureProvider

    /// Returns the texture for the given asset ID.
    ///
    /// TT-07: Checks overlay (injected) first, then base (preloaded).
    ///
    /// Model A contract: texture access happens only on main during playback/render.
    public func texture(for assetId: String) -> MTLTexture? {
        dispatchPrecondition(condition: .onQueue(.main))

        // 1. Check overlay first (injected user media takes precedence)
        if let overlay = overlayCache[assetId] {
            return overlay
        }

        // 2. Fallback to base (preloaded scene textures)
        if let base = core.baseCache[assetId] {
            return base
        }

        if core.missingAssets.contains(assetId) {
            return nil
        }

        // Binding assets return nil (no file on disk, injected via overlay)
        if core.bindingAssetIds.contains(assetId) {
            return nil
        }

        assertionFailure("[TextureProvider] Asset not preloaded: '\(assetId)' — call preloadAll(commandQueue:) before rendering")
        core.recordRuntimeMiss(assetId)
        return nil
    }

    // MARK: - MutableTextureProvider

    /// Injects an externally provided texture (e.g. user-selected media photo).
    ///
    /// TT-07: Injected textures are stored in overlay cache, separate from base.
    ///
    /// Model A contract: texture mutations happen only on main during playback/render.
    public func setTexture(_ texture: MTLTexture, for assetId: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        overlayCache[assetId] = texture
    }

    /// Removes an injected texture from overlay cache.
    ///
    /// TT-07: Only removes the overlay override. If a preloaded base texture exists
    /// for this asset ID, it becomes visible again through `texture(for:)`.
    ///
    /// Model A contract: texture mutations happen only on main during playback/render.
    public func removeTexture(for assetId: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        overlayCache.removeValue(forKey: assetId)
    }

    // MARK: - Preloading

    /// Preloads all resolvable textures with premultiplied alpha.
    /// - Parameter commandQueue: Metal command queue for staging → private texture blit
    public func preloadAll(commandQueue: MTLCommandQueue) {
        core.preloadAll(commandQueue: commandQueue)
    }

    /// Clears both base and overlay caches.
    public func clearCache() {
        core.clearCache()
        overlayCache.removeAll()
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
