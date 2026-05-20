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
        let capturedSceneTypeId = sceneTypeId
        let (compiledPackage, resolver) = try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()

            #if DEBUG
            let t0 = DispatchTime.now().uptimeNanoseconds
            #endif

            let loader = CompiledScenePackageLoader(engineVersion: TVECore.version)
            let compiledPackage = try loader.load(from: sceneURL)

            #if DEBUG
            let t1 = DispatchTime.now().uptimeNanoseconds
            #endif

            try Task.checkCancellation()

            let localIndex = try LocalAssetsIndex(
                imagesRootURL: sceneURL.appendingPathComponent("images")
            )

            #if DEBUG
            let t2 = DispatchTime.now().uptimeNanoseconds
            #endif

            let sharedIndex = try SharedAssetsIndex(
                bundle: Bundle.main,
                rootFolderName: "SharedAssets"
            )

            #if DEBUG
            let t3 = DispatchTime.now().uptimeNanoseconds
            #endif

            let resolver = CompositeAssetResolver(
                localIndex: localIndex,
                sharedIndex: sharedIndex
            )

            #if DEBUG
            let t4 = DispatchTime.now().uptimeNanoseconds
            MemoryDiagnostics.event(
                "sceneTypeLoad.summary",
                String(format: "id=%@ package=%.3fs localIndex=%.3fs sharedIndex=%.3fs resolver=%.3fs total=%.3fs",
                       capturedSceneTypeId,
                       Double(t1 - t0) / 1e9,
                       Double(t2 - t1) / 1e9,
                       Double(t3 - t2) / 1e9,
                       Double(t4 - t3) / 1e9,
                       Double(t4 - t0) / 1e9)
            )
            #endif

            return (compiledPackage, resolver)
        }.value

        return LoadedScenePackageResources(
            sceneTypeId: sceneTypeId,
            compiled: compiledPackage.compiled,
            resolver: resolver
        )
    }
}
