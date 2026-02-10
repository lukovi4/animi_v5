import Foundation
import TVECore

// MARK: - Scene Compiler

/// Compiles a ScenePackage into a CompiledScene.
/// This is the build-time/DEBUG-only compiler that transforms Lottie JSON into runtime IR.
public final class SceneCompiler {

    // MARK: - Properties

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
        var allBasenameByIdMerged: [String: String] = [:]

        for (index, mediaBlock) in scene.mediaBlocks.enumerated() {
            let blockRuntime = try compileBlock(
                mediaBlock: mediaBlock,
                orderIndex: index,
                loadedAnimations: loadedAnimations,
                sceneDurationFrames: scene.canvas.durationFrames,
                sceneId: scene.sceneId,
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
                for (assetId, basename) in variant.animIR.assets.basenameById {
                    allBasenameByIdMerged[assetId] = basename
                }
            }
        }

        // Sort blocks by zIndex for correct render order (lower zIndex rendered first)
        // Use orderIndex as tiebreaker for stable sorting when zIndex is equal
        blockRuntimes.sort { ($0.zIndex, $0.orderIndex) < ($1.zIndex, $1.orderIndex) }

        // Create merged asset index
        let mergedAssets = AssetIndexIR(
            byId: allAssetsByIdMerged,
            sizeById: allSizesByIdMerged,
            basenameById: allBasenameByIdMerged
        )

        // PR-28: Collect binding asset IDs across all variants.
        // These are namespaced IDs of image assets referenced by binding layers.
        // They have no file on disk — user media is injected at runtime.
        var bindingAssetIds: Set<String> = []
        for block in blockRuntimes {
            for variant in block.variants {
                bindingAssetIds.insert(variant.animIR.binding.boundAssetId)
            }
        }

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
            pathRegistry: sharedPathRegistry,
            bindingAssetIds: bindingAssetIds
        )

        return compiled
    }

    // MARK: - Block Compilation

    /// Compiles a single media block
    private func compileBlock(
        mediaBlock: MediaBlock,
        orderIndex: Int,
        loadedAnimations: LoadedAnimations,
        sceneDurationFrames: Int,
        sceneId: String?,
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

        // Resolve edit variant (must be "no-anim")
        guard let editVariant = variantRuntimes.first(where: { $0.variantId == "no-anim" }) else {
            throw ScenePlayerError.missingNoAnimVariant(blockId: mediaBlock.id)
        }

        // Validate no-anim: must have mediaInput (inputGeometry)
        guard editVariant.animIR.inputGeometry != nil else {
            throw ScenePlayerError.noAnimMissingMediaInput(
                blockId: mediaBlock.id,
                animRef: editVariant.animRef
            )
        }

        // Validate no-anim: binding layer must exist
        let bindingLayerId = editVariant.animIR.binding.boundLayerId
        let bindingCompId = editVariant.animIR.binding.boundCompId
        guard let bindingComp = editVariant.animIR.comps[bindingCompId],
              let bindingLayer = bindingComp.layers.first(where: { $0.id == bindingLayerId }) else {
            throw ScenePlayerError.noAnimMissingBindingLayer(
                blockId: mediaBlock.id,
                animRef: editVariant.animRef,
                bindingKey: mediaBlock.input.bindingKey
            )
        }

        // Validate no-anim: binding layer must be visible at edit frame 0
        let editFrame = Double(SceneRenderPlan.editFrameIndex)
        guard AnimIR.isVisible(bindingLayer, at: editFrame) else {
            throw ScenePlayerError.noAnimBindingNotVisibleAtEditFrame(
                blockId: mediaBlock.id,
                animRef: editVariant.animRef,
                editFrameIndex: SceneRenderPlan.editFrameIndex
            )
        }

        // Validate no-anim: binding layer must actually render at edit frame 0
        // (reachability check — catches invisible precomp containers)
        // PR-28: Probe runs with bindingLayerVisible=true to verify that the binding
        // layer is CAPABLE of rendering. The actual visibility at runtime is controlled
        // separately by hasUserMedia (empty binding is allowed at runtime).
        if case .image(let bindingAssetId) = bindingLayer.content {
            var probeIR = editVariant.animIR
            let probeCommands = probeIR.renderCommands(
                frameIndex: SceneRenderPlan.editFrameIndex,
                userTransform: .identity,
                bindingLayerVisible: true
            )
            let bindingRendered = probeCommands.contains { cmd in
                if case .drawImage(let assetId, _) = cmd {
                    return assetId == bindingAssetId
                }
                return false
            }
            guard bindingRendered else {
                throw ScenePlayerError.noAnimBindingNotRenderedAtEditFrame(
                    blockId: mediaBlock.id,
                    animRef: editVariant.animRef,
                    editFrameIndex: SceneRenderPlan.editFrameIndex
                )
            }
        }

        // PR-30: Validate layer toggles (Scene ↔ Lottie sync)
        try validateLayerToggles(
            sceneId: sceneId,
            block: mediaBlock,
            variants: variantRuntimes
        )

        return BlockRuntime(
            blockId: mediaBlock.id,
            zIndex: mediaBlock.zIndex,
            orderIndex: orderIndex,
            rectCanvas: RectD(from: mediaBlock.rect),
            inputRect: RectD(from: mediaBlock.input.rect),
            timing: timing,
            containerClip: mediaBlock.containerClip,
            hitTestMode: mediaBlock.input.hitTest,
            selectedVariantId: selectedVariantId,
            editVariantId: editVariant.variantId,
            variants: variantRuntimes
        )
    }

    // MARK: - Layer Toggle Validation (PR-30)

    /// Validates layer toggles for a block (Scene ↔ Lottie sync).
    ///
    /// Fatal errors are thrown as `templateCorrupted` — the template cannot be loaded.
    ///
    /// - Parameters:
    ///   - sceneId: Scene identifier (required when toggles are present)
    ///   - block: Media block from scene.json
    ///   - variants: Compiled variant runtimes for this block
    /// - Throws: `ScenePlayerError.templateCorrupted` on fatal validation errors
    private func validateLayerToggles(
        sceneId: String?,
        block: MediaBlock,
        variants: [VariantRuntime]
    ) throws {
        guard let toggles = block.layerToggles, !toggles.isEmpty else {
            return // No toggles — nothing to validate
        }

        // Rule 1: sceneId is required when toggles are present
        guard let sceneId = sceneId, !sceneId.isEmpty else {
            throw ScenePlayerError.templateCorrupted(reason: "TOGGLE_SCENE_MISSING_ID")
        }

        // Build expected toggle IDs from scene.json
        let expectedToggleIds = Set(toggles.map { $0.id })

        // Validate each variant
        for variant in variants {
            // Collect toggle IDs from this animation
            var foundToggleIds = Set<String>()
            var duplicateToggleIds = Set<String>()

            // Scan all compositions for toggle layers
            for (_, comp) in variant.animIR.comps {
                for layer in comp.layers {
                    if let toggleId = layer.toggleId {
                        // Check for duplicate toggle IDs within this animation
                        if foundToggleIds.contains(toggleId) {
                            duplicateToggleIds.insert(toggleId)
                        }
                        foundToggleIds.insert(toggleId)

                        // Rule: Toggle layer cannot be matte source
                        if layer.isMatteSource {
                            throw ScenePlayerError.templateCorrupted(
                                reason: "TOGGLE_LAYER_IS_MATTE_SOURCE"
                            )
                        }

                        // Rule: Toggle layer cannot be matte consumer
                        if layer.matte != nil {
                            throw ScenePlayerError.templateCorrupted(
                                reason: "TOGGLE_LAYER_IS_MATTE_CONSUMER"
                            )
                        }
                    }
                }
            }

            // Rule: No duplicate toggle IDs in animation
            if !duplicateToggleIds.isEmpty {
                throw ScenePlayerError.templateCorrupted(reason: "TOGGLE_DUPLICATE_IN_ANIM")
            }

            // Rule: Scene.json toggles must match Lottie toggle layers
            if foundToggleIds != expectedToggleIds {
                throw ScenePlayerError.templateCorrupted(reason: "TOGGLE_MISMATCH")
            }
        }

        // Rule: All variants must have the same set of toggle IDs
        // (Already covered by checking each variant against expectedToggleIds)

        // Rule: Toggle layer cannot be parent of other layers
        // Full scan across all layers to check parent references
        for variant in variants {
            // Collect all toggle layer IDs in this animation (LayerID is Int)
            var toggleLayerIds = Set<LayerID>()
            for (_, comp) in variant.animIR.comps {
                for layer in comp.layers {
                    if layer.toggleId != nil {
                        toggleLayerIds.insert(layer.id)
                    }
                }
            }

            // Check if any layer uses a toggle layer as parent
            for (_, comp) in variant.animIR.comps {
                for layer in comp.layers {
                    if let parentId = layer.parent,
                       toggleLayerIds.contains(parentId) {
                        throw ScenePlayerError.templateCorrupted(
                            reason: "TOGGLE_LAYER_IS_PARENT"
                        )
                    }
                }
            }
        }
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
}
