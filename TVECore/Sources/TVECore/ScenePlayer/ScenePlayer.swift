import Foundation

// MARK: - Scene Player

/// Compiles a ScenePackage into a runtime representation for playback.
/// Handles animation compilation, block layout, and render command generation.
public final class ScenePlayer {

    // MARK: - Properties

    /// Compiled scene runtime
    public private(set) var runtime: SceneRuntime?

    /// Merged asset index containing all assets from all animations (namespaced)
    public private(set) var mergedAssetIndex: AssetIndexIR?

    /// Merged path registry containing all paths from all animations
    public private(set) var mergedPathRegistry: PathRegistry?

    /// Animation compiler
    private let compiler = AnimIRCompiler()

    // MARK: - Initialization

    public init() {}

    // MARK: - Compilation

    /// Compiles a scene package into runtime representation
    ///
    /// - Parameters:
    ///   - package: Scene package with scene.json and animation files
    ///   - loadedAnimations: Pre-loaded Lottie animations from AnimLoader
    /// - Returns: Compiled SceneRuntime
    /// - Throws: ScenePlayerError if compilation fails
    @discardableResult
    public func compile(
        package: ScenePackage,
        loadedAnimations: LoadedAnimations
    ) throws -> SceneRuntime {
        let scene = package.scene

        guard !scene.mediaBlocks.isEmpty else {
            throw ScenePlayerError.noMediaBlocks
        }

        // Compile all blocks
        var blockRuntimes: [BlockRuntime] = []
        var allAssetsByIdMerged: [String: String] = [:]
        var allSizesByIdMerged: [String: AssetSize] = [:]

        for mediaBlock in scene.mediaBlocks {
            let blockRuntime = try compileBlock(
                mediaBlock: mediaBlock,
                loadedAnimations: loadedAnimations,
                sceneDurationFrames: scene.canvas.durationFrames
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
        blockRuntimes.sort { $0.zIndex < $1.zIndex }

        // Create merged asset index
        let merged = AssetIndexIR(byId: allAssetsByIdMerged, sizeById: allSizesByIdMerged)
        self.mergedAssetIndex = merged

        // Register paths from all blocks using a shared registry
        // This ensures globally unique pathIds across all animations
        var sharedPathRegistry = PathRegistry()
        for blockIndex in blockRuntimes.indices {
            for variantIndex in blockRuntimes[blockIndex].variants.indices {
                blockRuntimes[blockIndex].variants[variantIndex].animIR.registerPaths(into: &sharedPathRegistry)
            }
        }
        self.mergedPathRegistry = sharedPathRegistry

        // Create runtime
        let sceneRuntime = SceneRuntime(
            scene: scene,
            canvas: scene.canvas,
            blocks: blockRuntimes,
            durationFrames: scene.canvas.durationFrames,
            fps: scene.canvas.fps
        )

        self.runtime = sceneRuntime
        return sceneRuntime
    }

    // MARK: - Block Compilation

    /// Compiles a single media block
    private func compileBlock(
        mediaBlock: MediaBlock,
        loadedAnimations: LoadedAnimations,
        sceneDurationFrames: Int
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
                loadedAnimations: loadedAnimations
            )
            variantRuntimes.append(variantRuntime)
        }

        // Select first variant as default
        let selectedVariantId = mediaBlock.variants.first?.id ?? ""

        return BlockRuntime(
            blockId: mediaBlock.id,
            zIndex: mediaBlock.zIndex,
            rectCanvas: RectD(from: mediaBlock.rect),
            inputRect: RectD(from: mediaBlock.input.rect),
            timing: timing,
            containerClip: mediaBlock.containerClip,
            selectedVariantId: selectedVariantId,
            variants: variantRuntimes
        )
    }

    // MARK: - Variant Compilation

    /// Compiles a single variant
    private func compileVariant(
        variant: Variant,
        bindingKey: String,
        blockId: String,
        loadedAnimations: LoadedAnimations
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

        // Compile AnimIR (with namespaced asset IDs)
        // Note: path registration is deferred to compile() where we use a shared registry
        let animIR: AnimIR
        do {
            animIR = try compiler.compile(
                lottie: lottie,
                animRef: animRef,
                bindingKey: bindingKey,
                assetIndex: assetIndex
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
        guard let runtime = runtime else {
            return []
        }
        return runtime.renderCommands(sceneFrameIndex: sceneFrameIndex)
    }
}
