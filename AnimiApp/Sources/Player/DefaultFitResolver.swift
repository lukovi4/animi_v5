import TVECore

/// Resolves defaultFit for a block from scene-type metadata.
/// Extracted from EditorViewController for testability.
enum DefaultFitResolver {

    /// Resolves defaultFit synchronously from cache, returns nil on miss.
    @MainActor
    static func resolveFromCache(
        sceneTypeId: String,
        blockId: String,
        cache: SceneTypeResourcesCache
    ) -> FitMode? {
        guard let resources = cache.resources(for: sceneTypeId) else { return nil }
        return resources.compiled.runtime.scene.mediaBlocks
            .first { $0.id == blockId }?.input.defaultFit
    }

    /// Resolves defaultFit, preloading metadata on cache miss.
    @MainActor
    static func resolve(
        sceneTypeId: String,
        blockId: String,
        cache: SceneTypeResourcesCache
    ) async -> FitMode {
        // Sync cache hit
        if let fit = resolveFromCache(sceneTypeId: sceneTypeId, blockId: blockId, cache: cache) {
            return fit
        }
        // Async preload
        do {
            let resources = try await cache.preloadMetadata(sceneTypeId: sceneTypeId)
            if let fit = resources.compiled.runtime.scene.mediaBlocks
                .first(where: { $0.id == blockId })?.input.defaultFit {
                return fit
            }
        } catch {}
        return .cover
    }
}
