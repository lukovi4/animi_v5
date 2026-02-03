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

    /// Per-block user transforms (pan/zoom/rotate from editor UI).
    /// Key: blockId (MediaBlock.id). Value: user-specified Matrix2D.
    /// Blocks without an entry default to `.identity`.
    private var userTransforms: [String: Matrix2D] = [:]

    /// Per-block variant overrides (PR-20).
    /// Key: blockId. Value: variantId chosen by user.
    /// Blocks without an entry use `BlockRuntime.selectedVariantId` (compilation default = first).
    /// Compiled data remains immutable — overrides live here.
    private var variantOverrides: [String: String] = [:]

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
        // Clear stale overrides from a previous scene (PR-20 review fix)
        variantOverrides.removeAll()

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
        if case .image(let bindingAssetId) = bindingLayer.content {
            var probeIR = editVariant.animIR
            let probeCommands = probeIR.renderCommands(
                frameIndex: SceneRenderPlan.editFrameIndex,
                userTransform: .identity
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

    // MARK: - User Transform (PR-16)

    /// Sets the user transform for a media block.
    ///
    /// The transform represents the cumulative pan/zoom/rotate applied by the user
    /// in the editor. It is applied **only** to the binding layer (`media`);
    /// the `mediaInput` window remains fixed.
    ///
    /// - Parameters:
    ///   - blockId: Identifier of the media block (`MediaBlock.id`)
    ///   - transform: Combined user pan/zoom/rotate as a `Matrix2D`
    public func setUserTransform(blockId: String, transform: Matrix2D) {
        userTransforms[blockId] = transform
    }

    /// Returns the current user transform for a media block.
    ///
    /// - Parameter blockId: Identifier of the media block
    /// - Returns: The stored `Matrix2D`, or `.identity` if none was set
    public func userTransform(blockId: String) -> Matrix2D {
        userTransforms[blockId] ?? .identity
    }

    /// Resets user transforms for all blocks to identity.
    public func resetAllUserTransforms() {
        userTransforms.removeAll()
    }

    // MARK: - Variant Selection (PR-20)

    /// Returns available variants for a block.
    ///
    /// - Parameter blockId: Identifier of the media block
    /// - Returns: Array of `VariantInfo` (id + animRef), or empty if block not found
    public func availableVariants(blockId: String) -> [VariantInfo] {
        guard let compiled = compiledScene else { return [] }
        guard let block = compiled.runtime.blocks.first(where: { $0.blockId == blockId }) else {
            return []
        }
        return block.variants.map { VariantInfo(id: $0.variantId, animRef: $0.animRef) }
    }

    /// Returns the active variant ID for a block (override or compilation default).
    ///
    /// - Parameter blockId: Identifier of the media block
    /// - Returns: Active variant ID, or `nil` if block not found
    public func selectedVariantId(blockId: String) -> String? {
        guard let compiled = compiledScene else { return nil }
        guard let block = compiled.runtime.blocks.first(where: { $0.blockId == blockId }) else {
            return nil
        }
        return variantOverrides[blockId] ?? block.selectedVariantId
    }

    /// Sets the selected variant for a block.
    ///
    /// If `variantId` does not match any compiled variant, the override is removed
    /// and the block falls back to its compilation default.
    ///
    /// - Parameters:
    ///   - blockId: Identifier of the media block
    ///   - variantId: Variant to select
    public func setSelectedVariant(blockId: String, variantId: String) {
        guard let compiled = compiledScene else { return }
        guard let block = compiled.runtime.blocks.first(where: { $0.blockId == blockId }) else {
            return
        }
        // Validate variantId exists in this block
        if block.variants.contains(where: { $0.variantId == variantId }) {
            variantOverrides[blockId] = variantId
        } else {
            // Invalid variantId — remove override, fall back to default
            variantOverrides.removeValue(forKey: blockId)
        }
    }

    /// Applies a variant selection mapping to multiple blocks at once (scene preset).
    ///
    /// Each entry maps `blockId → variantId`. Invalid entries are silently skipped.
    ///
    /// - Parameter mapping: Dictionary of blockId to variantId
    public func applyVariantSelection(_ mapping: [String: String]) {
        for (blockId, variantId) in mapping {
            setSelectedVariant(blockId: blockId, variantId: variantId)
        }
    }

    /// Removes the variant override for a block, reverting to the compilation default.
    ///
    /// - Parameter blockId: Identifier of the media block
    public func clearSelectedVariantOverride(blockId: String) {
        variantOverrides.removeValue(forKey: blockId)
    }

    /// Resolves the active `VariantRuntime` for a block, respecting mode and overrides.
    ///
    /// - `.edit` → always uses `editVariantId` (no-anim variant)
    /// - `.preview` → delegates to `BlockRuntime.resolvedVariant(overrides:)` (user selection)
    private func resolveVariant(for block: BlockRuntime, mode: TemplateMode = .preview) -> VariantRuntime? {
        switch mode {
        case .edit:
            return block.resolvedVariant(overrides: [block.blockId: block.editVariantId])
        case .preview:
            return block.resolvedVariant(overrides: variantOverrides)
        }
    }

    // MARK: - Hit-Test & Overlay (PR-17)

    /// Returns the mediaInput hit path for a block in **canvas coordinates**.
    ///
    /// Canonical formula: `hitPath = mediaInputPath(frame).applying(blockTransform)`
    ///
    /// `mediaInputPath` already returns the path in composition space (world matrix applied).
    /// `blockTransform` then maps from anim-local space to canvas space.
    ///
    /// - Parameters:
    ///   - blockId: Identifier of the media block
    ///   - frame: Scene frame index (default: 0)
    ///   - mode: Template mode. `.edit` resolves to `editVariantId`; `.preview` uses current selection.
    /// - Returns: BezierPath in canvas coordinates, or `nil` if block/mediaInput not found
    public func mediaInputHitPath(blockId: String, frame: Int = 0, mode: TemplateMode = .preview) -> BezierPath? {
        guard let compiled = compiledScene else { return nil }
        let runtime = compiled.runtime

        guard let block = runtime.blocks.first(where: { $0.blockId == blockId }),
              var variant = resolveVariant(for: block, mode: mode) else {
            return nil
        }

        // Get mediaInput path in comp space (world matrix already applied inside)
        let localFrame = SceneRenderPlan.localFrameIndex(
            sceneFrameIndex: frame,
            blockTiming: block.timing,
            animIR: variant.animIR
        )

        guard let compSpacePath = variant.animIR.mediaInputPath(frame: localFrame) else {
            return nil
        }

        // Transform to canvas space
        let blockTransform = SceneTransforms.blockTransform(
            animSize: variant.animIR.meta.size,
            blockRect: block.rectCanvas,
            canvasSize: runtime.canvasSize
        )

        return compSpacePath.applying(blockTransform)
    }

    /// Hit-tests a point in canvas coordinates, returning the topmost block that contains it.
    ///
    /// Walks visible blocks in **top-to-bottom** order (highest zIndex first).
    /// For each block:
    /// - `hitTestMode == .mask` and mediaInput path available → test by shape (`BezierPath.contains`)
    /// - Otherwise → test by block rect
    ///
    /// - Parameters:
    ///   - point: Point in canvas coordinates
    ///   - frame: Scene frame index
    ///   - mode: Template mode. `.edit` resolves to `editVariantId`; `.preview` uses current selection.
    /// - Returns: `blockId` of the topmost hit block, or `nil` if no hit
    public func hitTest(point: Vec2D, frame: Int, mode: TemplateMode = .preview) -> String? {
        guard let compiled = compiledScene else { return nil }
        let runtime = compiled.runtime

        // Walk top-to-bottom (reversed: blocks are sorted ascending by zIndex)
        for block in runtime.blocks.reversed() {
            guard block.timing.isVisible(at: frame) else { continue }

            if block.hitTestMode == .mask {
                // Try shape hit-test via mediaInput path
                if let hitPath = mediaInputHitPath(blockId: block.blockId, frame: frame, mode: mode) {
                    if hitPath.contains(point: point) {
                        return block.blockId
                    }
                    continue // .mask mode: shape miss means miss (no rect fallback)
                }
                // No mediaInput path available — fall through to rect
            }

            // Rect hit-test (for .rect mode, nil mode, or .mask without mediaInput)
            let rect = block.rectCanvas
            if point.x >= rect.x && point.x <= rect.x + rect.width &&
               point.y >= rect.y && point.y <= rect.y + rect.height {
                return block.blockId
            }
        }

        return nil
    }

    /// Returns overlay descriptors for all visible blocks at the given frame.
    ///
    /// Each overlay contains the hit path in canvas coordinates and the block rect.
    /// The editor uses these to draw interactive overlays.
    /// Blocks are returned in **top-to-bottom** order (highest zIndex first)
    /// so the editor can draw front blocks on top.
    ///
    /// - Parameters:
    ///   - frame: Scene frame index
    ///   - mode: Template mode. `.edit` resolves to `editVariantId`; `.preview` uses current selection.
    /// - Returns: Array of `MediaInputOverlay` for all visible blocks
    public func overlays(frame: Int, mode: TemplateMode = .preview) -> [MediaInputOverlay] {
        guard let compiled = compiledScene else { return [] }
        let runtime = compiled.runtime

        var result: [MediaInputOverlay] = []

        // Top-to-bottom order (reversed: blocks are sorted ascending by zIndex)
        for block in runtime.blocks.reversed() {
            guard block.timing.isVisible(at: frame) else { continue }

            let hitPath: BezierPath

            if block.hitTestMode == .mask,
               let shapePath = mediaInputHitPath(blockId: block.blockId, frame: frame, mode: mode) {
                hitPath = shapePath
            } else {
                // Fallback: build path from block rect
                hitPath = rectToBezierPath(block.rectCanvas)
            }

            result.append(MediaInputOverlay(
                blockId: block.blockId,
                hitPath: hitPath,
                rectCanvas: block.rectCanvas
            ))
        }

        return result
    }

    /// Converts a RectD to a closed BezierPath (4 vertices, zero tangents).
    private func rectToBezierPath(_ rect: RectD) -> BezierPath {
        let topLeft = Vec2D(x: rect.x, y: rect.y)
        let topRight = Vec2D(x: rect.x + rect.width, y: rect.y)
        let bottomRight = Vec2D(x: rect.x + rect.width, y: rect.y + rect.height)
        let bottomLeft = Vec2D(x: rect.x, y: rect.y + rect.height)
        let zero = [Vec2D.zero, Vec2D.zero, Vec2D.zero, Vec2D.zero]
        return BezierPath(
            vertices: [topLeft, topRight, bottomRight, bottomLeft],
            inTangents: zero,
            outTangents: zero,
            closed: true
        )
    }

    // MARK: - Render Commands

    /// Canonical edit frame index — delegates to `SceneRenderPlan.editFrameIndex`.
    public static var editFrameIndex: Int { SceneRenderPlan.editFrameIndex }

    /// Generates render commands for the given scene frame.
    ///
    /// User transforms stored via `setUserTransform(blockId:transform:)` are
    /// automatically forwarded to each block's AnimIR render pass.
    ///
    /// - Parameter sceneFrameIndex: Frame index in scene timeline
    /// - Returns: Render commands for all visible blocks, or empty array if not compiled
    public func renderCommands(sceneFrameIndex: Int) -> [RenderCommand] {
        guard let compiledScene = compiledScene else {
            return []
        }
        return SceneRenderPlan.renderCommands(
            for: compiledScene.runtime,
            sceneFrameIndex: sceneFrameIndex,
            userTransforms: userTransforms,
            variantOverrides: variantOverrides
        )
    }

    /// Generates render commands using the specified template mode.
    ///
    /// - **Preview mode**: Full playback — all blocks, all layers, all animations.
    ///   Uses `sceneFrameIndex` for time-based rendering (scrubber / playback).
    /// - **Edit mode**: Full render of `no-anim` variant at `editFrameIndex` (0).
    ///   `sceneFrameIndex` is ignored; edit always renders at frame 0.
    ///
    /// User transforms stored via `setUserTransform(blockId:transform:)` are
    /// automatically forwarded to each block's render pass.
    ///
    /// - Parameters:
    ///   - mode: Template mode (`.preview` or `.edit`)
    ///   - sceneFrameIndex: Frame index in scene timeline (used by preview; ignored by edit)
    /// - Returns: Render commands, or empty array if not compiled
    public func renderCommands(
        mode: TemplateMode,
        sceneFrameIndex: Int = 0
    ) -> [RenderCommand] {
        guard let compiledScene = compiledScene else {
            return []
        }

        let frameIndex: Int
        let overrides: [String: String]

        switch mode {
        case .preview:
            frameIndex = sceneFrameIndex
            overrides = variantOverrides
        case .edit:
            frameIndex = Self.editFrameIndex
            // Build edit override map: every block → its editVariantId
            overrides = Dictionary(
                uniqueKeysWithValues: compiledScene.runtime.blocks.map {
                    ($0.blockId, $0.editVariantId)
                }
            )
        }

        return SceneRenderPlan.renderCommands(
            for: compiledScene.runtime,
            sceneFrameIndex: frameIndex,
            userTransforms: userTransforms,
            variantOverrides: overrides
        )
    }
}
