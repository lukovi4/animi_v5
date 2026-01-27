import Foundation

// MARK: - Scene Player

/// Compiles a ScenePackage into a runtime representation for playback.
/// Handles animation compilation, block layout, and render command generation.
public final class ScenePlayer {

    // MARK: - Properties

    /// Compiled scene (single source of truth after compilation)
    /// Contains runtime, merged assets, and path registry.
    /// Nil before compile() is called.
    public private(set) var compiledScene: CompiledScene?

    /// Animation compiler
    private let compiler = AnimIRCompiler()

    // MARK: - Initialization

    public init() {}

    // MARK: - Compilation

    /// Compiles a scene package into a CompiledScene.
    ///
    /// PathIDs are assigned deterministically during compilation into a shared
    /// scene-level registry. This ensures:
    /// - No runtime path registration needed
    /// - Variant switching works without registry rebuild
    /// - Each AnimIR has empty pathRegistry (scene uses CompiledScene.pathRegistry)
    ///
    /// - Parameters:
    ///   - package: Scene package with scene.json and animation files
    ///   - loadedAnimations: Pre-loaded Lottie animations from AnimLoader
    /// - Returns: CompiledScene containing runtime, assets, and path registry
    /// - Throws: ScenePlayerError if compilation fails
    @discardableResult
    public func compile(
        package: ScenePackage,
        loadedAnimations: LoadedAnimations
    ) throws -> CompiledScene {
        let scene = package.scene

        guard !scene.mediaBlocks.isEmpty else {
            throw ScenePlayerError.noMediaBlocks
        }

        // Scene-level path registry - paths are registered during compilation
        var sharedPathRegistry = PathRegistry()

        // Compile all blocks
        var blockRuntimes: [BlockRuntime] = []
        var allAssetsByIdMerged: [String: String] = [:]
        var allSizesByIdMerged: [String: AssetSize] = [:]

        for (index, mediaBlock) in scene.mediaBlocks.enumerated() {
            let blockRuntime = try compileBlock(
                mediaBlock: mediaBlock,
                orderIndex: index,
                loadedAnimations: loadedAnimations,
                sceneDurationFrames: scene.canvas.durationFrames,
                pathRegistry: &sharedPathRegistry
            )
            blockRuntimes.append(blockRuntime)

            // Merge assets from all variants of this block
            for variant in blockRuntime.variants {
                for (assetId, path) in variant.animIR.assets.byId {
                    allAssetsByIdMerged[assetId] = path
                }
                for (assetId, size) in variant.animIR.assets.sizeById {
                    allSizesByIdMerged[assetId] = size
                }
            }
        }

        // Sort blocks by zIndex for correct render order (lower zIndex rendered first)
        // Use orderIndex as tiebreaker for stable sorting when zIndex is equal
        blockRuntimes.sort { ($0.zIndex, $0.orderIndex) < ($1.zIndex, $1.orderIndex) }

        // Create merged asset index
        let mergedAssets = AssetIndexIR(byId: allAssetsByIdMerged, sizeById: allSizesByIdMerged)

        // Create runtime
        let sceneRuntime = SceneRuntime(
            scene: scene,
            canvas: scene.canvas,
            blocks: blockRuntimes,
            durationFrames: scene.canvas.durationFrames,
            fps: scene.canvas.fps
        )

        // Create CompiledScene (single source of truth)
        let compiled = CompiledScene(
            runtime: sceneRuntime,
            mergedAssetIndex: mergedAssets,
            pathRegistry: sharedPathRegistry
        )

        self.compiledScene = compiled
        return compiled
    }

    // MARK: - Block Compilation

    /// Compiles a single media block
    private func compileBlock(
        mediaBlock: MediaBlock,
        orderIndex: Int,
        loadedAnimations: LoadedAnimations,
        sceneDurationFrames: Int,
        pathRegistry: inout PathRegistry
    ) throws -> BlockRuntime {
        guard !mediaBlock.variants.isEmpty else {
            throw ScenePlayerError.noVariantsForBlock(blockId: mediaBlock.id)
        }

        // Validate timing
        let timing = BlockTiming(from: mediaBlock.timing, sceneDurationFrames: sceneDurationFrames)
        if timing.startFrame >= timing.endFrame {
            throw ScenePlayerError.invalidBlockTiming(
                blockId: mediaBlock.id,
                startFrame: timing.startFrame,
                endFrame: timing.endFrame
            )
        }

        // Compile all variants
        var variantRuntimes: [VariantRuntime] = []

        for variant in mediaBlock.variants {
            let variantRuntime = try compileVariant(
                variant: variant,
                bindingKey: mediaBlock.input.bindingKey,
                blockId: mediaBlock.id,
                loadedAnimations: loadedAnimations,
                pathRegistry: &pathRegistry
            )
            variantRuntimes.append(variantRuntime)
        }

        // Select first variant as default
        let selectedVariantId = mediaBlock.variants.first?.id ?? ""

        return BlockRuntime(
            blockId: mediaBlock.id,
            zIndex: mediaBlock.zIndex,
            orderIndex: orderIndex,
            rectCanvas: RectD(from: mediaBlock.rect),
            inputRect: RectD(from: mediaBlock.input.rect),
            timing: timing,
            containerClip: mediaBlock.containerClip,
            selectedVariantId: selectedVariantId,
            variants: variantRuntimes
        )
    }

    // MARK: - Variant Compilation

    /// Compiles a single variant with path registration into scene-level registry
    private func compileVariant(
        variant: Variant,
        bindingKey: String,
        blockId: String,
        loadedAnimations: LoadedAnimations,
        pathRegistry: inout PathRegistry
    ) throws -> VariantRuntime {
        let animRef = variant.animRef

        // Get Lottie JSON for this animation
        guard let lottie = loadedAnimations.lottieByAnimRef[animRef] else {
            throw ScenePlayerError.animRefNotFound(animRef: animRef, blockId: blockId)
        }

        // Get asset index for this animation
        guard let assetIndex = loadedAnimations.assetIndexByAnimRef[animRef] else {
            throw ScenePlayerError.animRefNotFound(animRef: animRef, blockId: blockId)
        }

        // Compile AnimIR with scene-level path registry
        // PathIDs are assigned during compilation, no post-pass registerPaths needed
        let animIR: AnimIR
        do {
            animIR = try compiler.compile(
                lottie: lottie,
                animRef: animRef,
                bindingKey: bindingKey,
                assetIndex: assetIndex,
                pathRegistry: &pathRegistry
            )
        } catch {
            throw ScenePlayerError.compilationFailed(
                animRef: animRef,
                reason: error.localizedDescription
            )
        }

        return VariantRuntime(
            variantId: variant.id,
            animRef: animRef,
            animIR: animIR,
            bindingKey: bindingKey
        )
    }

    // MARK: - Render Commands

    /// Generates render commands for the given scene frame
    ///
    /// - Parameter sceneFrameIndex: Frame index in scene timeline
    /// - Returns: Render commands for all visible blocks, or empty array if not compiled
    public func renderCommands(sceneFrameIndex: Int) -> [RenderCommand] {
        guard let compiledScene = compiledScene else {
            return []
        }
        return compiledScene.runtime.renderCommands(sceneFrameIndex: sceneFrameIndex)
    }
}
