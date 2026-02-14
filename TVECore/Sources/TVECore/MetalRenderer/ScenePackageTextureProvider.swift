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
///
/// Conforms to `MutableTextureProvider` (PR-32) for user media injection.
public final class ScenePackageTextureProvider: MutableTextureProvider {
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

    /// PR-B: Last preload statistics (available after preloadAll(commandQueue:) call).
    private(set) public var lastPreloadStats: PreloadStats?

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
    ///
    /// **PR-B: IO-free runtime** — This method performs O(1) cache lookup only.
    /// No file IO or texture decoding happens here. All textures must be preloaded
    /// via `preloadAll(commandQueue:)` before rendering begins.
    ///
    /// Externally injected textures (via `setTexture`) are returned from cache directly.
    ///
    /// Model A contract: texture access happens only on main during playback/render.
    public func texture(for assetId: String) -> MTLTexture? {
        dispatchPrecondition(condition: .onQueue(.main))

        // Check cache (includes preloaded and injected user media textures)
        if let cached = cache[assetId] {
            return cached
        }

        // Skip known missing assets (don't spam assertions)
        if missingAssets.contains(assetId) {
            return nil
        }

        // PR-B: Cache miss in runtime = preload contract violation
        // In DEBUG: signal developer about missing preload
        // In Release: assertionFailure is stripped, just return nil
        assertionFailure("[TextureProvider] Asset not preloaded: '\(assetId)' — call preloadAll(commandQueue:) before rendering")
        missingAssets.insert(assetId)
        return nil
    }

    // MARK: - External Texture Injection

    /// Injects an externally provided texture (e.g. user-selected media photo).
    ///
    /// Injected textures are stored in cache and returned directly by `texture(for:)`,
    /// bypassing resolver-based resolution. Used for binding layer user media.
    ///
    /// Model A contract: texture mutations happen only on main during playback/render.
    ///
    /// - Parameters:
    ///   - texture: Metal texture to inject
    ///   - assetId: Asset ID to associate the texture with (namespaced)
    public func setTexture(_ texture: MTLTexture, for assetId: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        cache[assetId] = texture
        missingAssets.remove(assetId)
    }

    /// Removes an injected texture, allowing re-resolution or marking as missing.
    ///
    /// Model A contract: texture mutations happen only on main during playback/render.
    ///
    /// - Parameter assetId: Asset ID to remove from cache
    public func removeTexture(for assetId: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        cache.removeValue(forKey: assetId)
        missingAssets.remove(assetId)
    }

    // MARK: - Preloading

    /// Preloads all resolvable textures from the asset index with premultiplied alpha.
    ///
    /// **PR-B: Must be called before any rendering.** After this call, `texture(for:)`
    /// becomes a pure O(1) cache lookup with no IO.
    ///
    /// **Alpha Fix:** All textures are loaded with premultiplied alpha via
    /// `PremultipliedTextureLoader` for correct compositing with the renderer's
    /// premultiplied blending mode (src.rgb + dst.rgb * (1 - src.a)).
    ///
    /// Binding assets (identified by `bindingAssetIds`) are expected to have no file on disk
    /// and are skipped with a debug log. All other non-resolvable assets are logged as errors
    /// and added to `missingAssets` — this indicates a corrupted template.
    ///
    /// Statistics are stored in `lastPreloadStats` after completion.
    ///
    /// - Parameter commandQueue: Metal command queue for staging → private texture blit
    public func preloadAll(commandQueue: MTLCommandQueue) {
        let startTime = CFAbsoluteTimeGetCurrent()
        var loadedCount = 0
        var skippedBindingCount = 0

        for (assetId, basename) in assetIndex.basenameById {
            // Skip already cached (including injected textures)
            if cache[assetId] != nil {
                loadedCount += 1 // Count as loaded (was pre-injected)
                continue
            }

            guard let textureURL = try? resolver.resolveURL(forKey: basename) else {
                if bindingAssetIds.contains(assetId) {
                    // Expected: binding asset has no file (user media injected at runtime)
                    logger?("[TextureProvider] Preload skipped binding asset '\(assetId)'")
                    skippedBindingCount += 1
                } else {
                    // Unexpected: non-binding asset missing — template corrupted
                    logger?("[TextureProvider] ERROR: Asset '\(assetId)' (basename='\(basename)') not resolvable — template may be corrupted")
                    missingAssets.insert(assetId)
                }
                continue
            }

            if let texture = loadTexture(from: textureURL, assetId: assetId, commandQueue: commandQueue) {
                cache[assetId] = texture
                loadedCount += 1
            }
            // Note: loadTexture already adds to missingAssets on failure
        }

        let durationMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0

        lastPreloadStats = PreloadStats(
            loadedCount: loadedCount,
            missingCount: missingAssets.count,
            skippedBindingCount: skippedBindingCount,
            durationMs: durationMs
        )
    }

    /// Clears the texture cache and missing assets set.
    public func clearCache() {
        cache.removeAll()
        missingAssets.removeAll()
    }

    // MARK: - Private

    /// Loads texture with premultiplied alpha conversion.
    ///
    /// Uses `PremultipliedTextureLoader` for correct alpha compositing.
    /// Falls back to `MTKTextureLoader` if CGImageSource fails (rare, e.g. unsupported format).
    ///
    /// - Parameters:
    ///   - url: File URL of the image
    ///   - assetId: Asset identifier for logging
    ///   - commandQueue: Command queue for staging → private blit
    /// - Returns: Metal texture with premultiplied alpha, or nil on failure
    private func loadTexture(from url: URL, assetId: String, commandQueue: MTLCommandQueue) -> MTLTexture? {
        // Primary path: PremultipliedTextureLoader for correct alpha compositing
        do {
            return try PremultipliedTextureLoader.loadTexture(
                from: url,
                device: device,
                commandQueue: commandQueue
            )
        } catch {
            // Fallback: MTKTextureLoader for unsupported formats (rare)
            // WARNING: Fallback may produce straight-alpha textures
            // Nice 2: Enhanced telemetry-friendly logging
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
