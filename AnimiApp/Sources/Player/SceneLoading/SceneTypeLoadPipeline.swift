import Foundation
import TVECore

/// Result of the shared lower-level scene loading pipeline.
/// Contains only the common resources needed by all consumers:
/// compiled scene and asset resolver. Derived metadata (canvasSize, fps, etc.)
/// is accessible via `compiled.runtime` / `compiled.mergedAssetIndex`.
public struct LoadedScenePackageResources: Sendable {
    public let sceneTypeId: String
    public let compiled: CompiledScene
    public let resolver: CompositeAssetResolver
}

/// Shared lower-level scene loading service.
/// Handles bundle decode → asset index construction → resolver assembly.
///
/// Consumer-specific concerns (ScenePlayer, texture provider, preload, caching,
/// cancellation policy) remain with the caller.
public enum SceneTypeLoadPipeline {

    /// Loads compiled scene package and asset resolver from a scene folder.
    /// Runs heavy IO on a background thread to avoid main thread freezes.
    /// Cooperates with caller cancellation: checks between heavy phases so that
    /// cancelled callers do not waste work on decode/index construction.
    ///
    /// - Parameters:
    ///   - sceneTypeId: Scene type identifier (for tagging the result).
    ///   - sceneURL: Folder URL containing the `.tve` file and `images/` directory.
    /// - Returns: Loaded resources with compiled scene and composite resolver.
    public static func load(
        sceneTypeId: String,
        from sceneURL: URL
    ) async throws -> LoadedScenePackageResources {
        let (compiledPackage, resolver) = try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()

            let loader = CompiledScenePackageLoader(engineVersion: TVECore.version)
            let compiledPackage = try loader.load(from: sceneURL)

            try Task.checkCancellation()

            let localIndex = try LocalAssetsIndex(
                imagesRootURL: sceneURL.appendingPathComponent("images")
            )
            let sharedIndex = try SharedAssetsIndex(
                bundle: Bundle.main,
                rootFolderName: "SharedAssets"
            )
            let resolver = CompositeAssetResolver(
                localIndex: localIndex,
                sharedIndex: sharedIndex
            )

            return (compiledPackage, resolver)
        }.value

        return LoadedScenePackageResources(
            sceneTypeId: sceneTypeId,
            compiled: compiledPackage.compiled,
            resolver: resolver
        )
    }
}
