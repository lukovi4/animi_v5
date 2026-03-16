import Foundation
import Metal
import TVECore

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
        // Already cached?
        if let existing = cache[sceneTypeId] {
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
            // 1. Heavy IO on background thread
            let (compiledPackage, resolver) = try await Task.detached(priority: .userInitiated) {
                let compiledLoader = CompiledScenePackageLoader(engineVersion: TVECore.version)
                let compiledPackage = try compiledLoader.load(from: sceneURL)

                let localIndex = try LocalAssetsIndex(imagesRootURL: sceneURL.appendingPathComponent("images"))
                let sharedIndex = try SharedAssetsIndex(bundle: Bundle.main, rootFolderName: "SharedAssets")
                let resolver = CompositeAssetResolver(localIndex: localIndex, sharedIndex: sharedIndex)

                return (compiledPackage, resolver)
            }.value

            let compiled = compiledPackage.compiled

            // 2. Create texture provider (main actor for Metal resources)
            let provider = await MainActor.run {
                SceneTextureProviderFactory.create(
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
            return resources
        } catch {
            loadingTasks.removeValue(forKey: sceneTypeId)
            throw error
        }
    }

    // MARK: - Cache Management

    /// Evicts resources for a scene type.
    public func evict(sceneTypeId: String) {
        cache.removeValue(forKey: sceneTypeId)
        loadingTasks[sceneTypeId]?.cancel()
        loadingTasks.removeValue(forKey: sceneTypeId)
    }

    /// Evicts all cached resources.
    public func evictAll() {
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
