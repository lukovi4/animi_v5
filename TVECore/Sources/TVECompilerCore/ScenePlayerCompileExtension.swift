import Foundation
import TVECore

// MARK: - ScenePlayer Compile Extension (Compiler-only)

/// Extension that adds compile capability to ScenePlayer.
/// This is only available in TVECompilerCore (build-time), not in TVECore runtime.
public extension ScenePlayer {

    /// Compiles a scene package and loads it into the player.
    ///
    /// This is a convenience method that combines SceneCompiler.compile() and loadCompiledScene().
    /// Only available in DEBUG/build-time context via TVECompilerCore.
    ///
    /// - Parameters:
    ///   - package: Scene package with scene.json
    ///   - loadedAnimations: Pre-loaded Lottie animations from AnimLoader
    /// - Returns: The compiled scene
    /// - Throws: ScenePlayerError if compilation fails
    @discardableResult
    func compile(
        package: ScenePackage,
        loadedAnimations: LoadedAnimations
    ) throws -> CompiledScene {
        let sceneCompiler = SceneCompiler()
        let compiled = try sceneCompiler.compile(package: package, loadedAnimations: loadedAnimations)
        return loadCompiledScene(compiled)
    }
}
