import Foundation
import Metal
@preconcurrency import TVECore

// MARK: - Scene URL Provider

/// Closure that returns the folder URL for a scene type.
/// Provided by app layer (SceneLibrary knows the paths).
public typealias SceneURLProvider = @Sendable (String) -> URL?

// MARK: - Scene Type Resources Cache

/// Cache for shared scene type resources.
/// Stores compiled scenes, base textures, and resolvers per sceneTypeId.
/// Multiple scene instances of the same type share these resources.
@MainActor
public final class SceneTypeResourcesCache {

    // MARK: - Resources

    /// Cached resources for a scene type.
    public struct Resources: Sendable {
        /// Scene type identifier.
        public let sceneTypeId: String

        /// Compiled scene (AnimIR).
        public let compiled: CompiledScene

        /// Asset resolver.
        public let resolver: CompositeAssetResolver

        /// Base texture provider (immutable, preloaded).
        public let baseTextureProvider: TextureProvider

        /// Asset sizes for rendering.
        public let assetSizes: [String: AssetSize]

        /// Path registry for GPU paths.
        public let pathRegistry: PathRegistry

        /// Canvas size from scene.
        public let canvasSize: SizeD

        /// Frames per second.
        public let fps: Int

        /// Duration in frames.
        public let durationFrames: Int

        public init(
            sceneTypeId: String,
            compiled: CompiledScene,
            resolver: CompositeAssetResolver,
            baseTextureProvider: TextureProvider,
            assetSizes: [String: AssetSize],
            pathRegistry: PathRegistry,
            canvasSize: SizeD,
            fps: Int,
            durationFrames: Int
        ) {
            self.sceneTypeId = sceneTypeId
            self.compiled = compiled
            self.resolver = resolver
            self.baseTextureProvider = baseTextureProvider
            self.assetSizes = assetSizes
            self.pathRegistry = pathRegistry
            self.canvasSize = canvasSize
            self.fps = fps
            self.durationFrames = durationFrames
        }
    }

    // MARK: - State

    /// Cached resources by sceneTypeId.
    private var cache: [String: Resources] = [:]

    /// Pending load tasks by sceneTypeId.
    private var loadingTasks: [String: Task<Resources, Error>] = [:]

    // MARK: - Dependencies

    /// Metal device for texture operations.
    private let device: MTLDevice

    /// Command queue for GPU operations.
    private let commandQueue: MTLCommandQueue

    /// Scene URL provider (from app layer).
    public var sceneURLProvider: SceneURLProvider?

    // MARK: - Init

    public init(device: MTLDevice, commandQueue: MTLCommandQueue) {
        self.device = device
        self.commandQueue = commandQueue
    }

    // MARK: - Cache Access

    /// Returns cached resources for scene type, if available.
    public func resources(for sceneTypeId: String) -> Resources? {
        cache[sceneTypeId]
    }

    /// Checks if resources are cached for scene type.
    public func isCached(_ sceneTypeId: String) -> Bool {
        cache[sceneTypeId] != nil
    }

    // MARK: - Preload

    /// Preloads resources for a scene type.
    /// If already loading, returns existing task.
    /// If already cached, returns immediately.
    ///
    /// - Parameter sceneTypeId: Scene type to preload.
    /// - Returns: Loaded resources.
    public func preload(sceneTypeId: String) async throws -> Resources {
        #if DEBUG
        MemoryDiagnostics.event("SceneTypeCache.preload.start", "id=\(sceneTypeId) cached=\(cache.count)")
        #endif
        // Already cached?
        if let existing = cache[sceneTypeId] {
            #if DEBUG
            MemoryDiagnostics.event("SceneTypeCache.preload.hit", "id=\(sceneTypeId)")
            #endif
            return existing
        }

        // Already loading?
        if let existingTask = loadingTasks[sceneTypeId] {
            return try await existingTask.value
        }

        // Validate provider
        guard let urlProvider = sceneURLProvider else {
            throw SceneCacheError.noURLProvider
        }

        guard let sceneURL = urlProvider(sceneTypeId) else {
            throw SceneCacheError.sceneNotFound(sceneTypeId)
        }

        // Capture dependencies for Sendable closure
        let capturedDevice = device
        let capturedQueue = commandQueue

        // Start new load task
        let task = Task<Resources, Error> {
            // 1. Heavy IO via shared pipeline
            let loaded = try await SceneTypeLoadPipeline.load(
                sceneTypeId: sceneTypeId,
                from: sceneURL
            )

            let compiled = loaded.compiled
            let resolver = loaded.resolver

            // 2. Create immutable base texture provider (TT-07: no mutable semantics in shared cache)
            let provider = await MainActor.run {
                SceneTextureProviderFactory.createBaseProvider(
                    device: capturedDevice,
                    mergedAssetIndex: compiled.mergedAssetIndex,
                    resolver: resolver,
                    bindingAssetIds: compiled.bindingAssetIds,
                    logger: { _ in }
                )
            }

            // 3. Preload textures on background thread
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    provider.preloadAll(commandQueue: capturedQueue)
                    cont.resume()
                }
            }

            // 4. Build Resources
            return Resources(
                sceneTypeId: sceneTypeId,
                compiled: compiled,
                resolver: resolver,
                baseTextureProvider: provider,
                assetSizes: compiled.mergedAssetIndex.sizeById,
                pathRegistry: compiled.pathRegistry,
                canvasSize: compiled.runtime.canvasSize,
                fps: compiled.runtime.fps,
                durationFrames: compiled.runtime.durationFrames
            )
        }

        loadingTasks[sceneTypeId] = task

        do {
            let resources = try await task.value
            cache[sceneTypeId] = resources
            loadingTasks.removeValue(forKey: sceneTypeId)
            #if DEBUG
            MemoryDiagnostics.event("SceneTypeCache.preload.stored", "id=\(sceneTypeId) total=\(cache.count) ids=\(Array(cache.keys).joined(separator: ","))")
            MemoryDiagnostics.signpostEvent("cache.stored")
            #endif
            return resources
        } catch {
            loadingTasks.removeValue(forKey: sceneTypeId)
            throw error
        }
    }

    // MARK: - Metadata-Only Preload (Export)

    /// Preloads compiled scene metadata without warming GPU textures.
    /// Export creates its own ExportTextureProvider via TimelineExportResidencyController —
    /// the base texture provider from cache is not used.
    /// Result is NOT cached — must not pollute the full-preload cache used by preview.
    public func preloadMetadata(sceneTypeId: String) async throws -> Resources {
        // Full cache hit? Return it (textures already warm — harmless for export).
        if let existing = cache[sceneTypeId] {
            return existing
        }

        // Full preload in flight? Await it.
        if let existingTask = loadingTasks[sceneTypeId] {
            return try await existingTask.value
        }

        guard let urlProvider = sceneURLProvider,
              let sceneURL = urlProvider(sceneTypeId) else {
            throw SceneCacheError.sceneNotFound(sceneTypeId)
        }

        let capturedDevice = device

        // Heavy IO via shared pipeline — no texture warm-up
        let loaded = try await SceneTypeLoadPipeline.load(
            sceneTypeId: sceneTypeId,
            from: sceneURL
        )

        let compiled = loaded.compiled
        let resolver = loaded.resolver

        // Create provider structure only — NO preloadAll()
        let provider = SceneTextureProviderFactory.createBaseProvider(
            device: capturedDevice,
            mergedAssetIndex: compiled.mergedAssetIndex,
            resolver: resolver,
            bindingAssetIds: compiled.bindingAssetIds,
            logger: { _ in }
        )

        // NOT cached — lighter than full preload, would break preview if used as cache entry
        return Resources(
            sceneTypeId: sceneTypeId,
            compiled: compiled,
            resolver: resolver,
            baseTextureProvider: provider,
            assetSizes: compiled.mergedAssetIndex.sizeById,
            pathRegistry: compiled.pathRegistry,
            canvasSize: compiled.runtime.canvasSize,
            fps: compiled.runtime.fps,
            durationFrames: compiled.runtime.durationFrames
        )
    }

    // MARK: - Cache Management

    /// Evicts resources for a scene type.
    public func evict(sceneTypeId: String) {
        cache.removeValue(forKey: sceneTypeId)
        loadingTasks[sceneTypeId]?.cancel()
        loadingTasks.removeValue(forKey: sceneTypeId)
        #if DEBUG
        MemoryDiagnostics.event("SceneTypeCache.evict", "id=\(sceneTypeId) remaining=\(cache.count)")
        #endif
    }

    /// Evicts all cached resources.
    public func evictAll() {
        #if DEBUG
        MemoryDiagnostics.event("SceneTypeCache.evictAll", "count=\(cache.count)")
        #endif
        cache.removeAll()
        for task in loadingTasks.values {
            task.cancel()
        }
        loadingTasks.removeAll()
    }

    /// Returns all cached scene type IDs.
    public var cachedSceneTypeIds: [String] {
        Array(cache.keys)
    }

    // MARK: - Manual Cache Population

    /// Manually adds resources to cache.
    /// Used when resources are loaded externally (e.g., during initial scene load).
    public func addToCache(_ resources: Resources) {
        cache[resources.sceneTypeId] = resources
        #if DEBUG
        MemoryDiagnostics.event("SceneTypeCache.addToCache", "id=\(resources.sceneTypeId) total=\(cache.count)")
        #endif
    }
}

// MARK: - Errors

public enum SceneCacheError: Error, LocalizedError {
    case noURLProvider
    case sceneNotFound(String)
    case loadFailed(String, Error)

    public var errorDescription: String? {
        switch self {
        case .noURLProvider:
            return "Scene URL provider not configured"
        case .sceneNotFound(let sceneTypeId):
            return "Scene not found: \(sceneTypeId)"
        case .loadFailed(let sceneTypeId, let error):
            return "Failed to load scene \(sceneTypeId): \(error.localizedDescription)"
        }
    }
}
