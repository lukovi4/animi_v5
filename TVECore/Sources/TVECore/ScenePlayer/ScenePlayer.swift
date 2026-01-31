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
            hitTestMode: mediaBlock.input.hitTest,
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
    /// - Returns: BezierPath in canvas coordinates, or `nil` if block/mediaInput not found
    public func mediaInputHitPath(blockId: String, frame: Int = 0) -> BezierPath? {
        guard let compiled = compiledScene else { return nil }
        let runtime = compiled.runtime

        guard let block = runtime.blocks.first(where: { $0.blockId == blockId }),
              var variant = block.selectedVariant else {
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
    /// - Returns: `blockId` of the topmost hit block, or `nil` if no hit
    public func hitTest(point: Vec2D, frame: Int) -> String? {
        guard let compiled = compiledScene else { return nil }
        let runtime = compiled.runtime

        // Walk top-to-bottom (reversed: blocks are sorted ascending by zIndex)
        for block in runtime.blocks.reversed() {
            guard block.timing.isVisible(at: frame) else { continue }

            if block.hitTestMode == .mask {
                // Try shape hit-test via mediaInput path
                if let hitPath = mediaInputHitPath(blockId: block.blockId, frame: frame) {
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
    /// - Parameter frame: Scene frame index
    /// - Returns: Array of `MediaInputOverlay` for all visible blocks
    public func overlays(frame: Int) -> [MediaInputOverlay] {
        guard let compiled = compiledScene else { return [] }
        let runtime = compiled.runtime

        var result: [MediaInputOverlay] = []

        // Top-to-bottom order (reversed: blocks are sorted ascending by zIndex)
        for block in runtime.blocks.reversed() {
            guard block.timing.isVisible(at: frame) else { continue }

            let hitPath: BezierPath

            if block.hitTestMode == .mask,
               let shapePath = mediaInputHitPath(blockId: block.blockId, frame: frame) {
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
            userTransforms: userTransforms
        )
    }
}
