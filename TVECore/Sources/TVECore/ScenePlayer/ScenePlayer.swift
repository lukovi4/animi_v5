import Foundation

// MARK: - Scene Player

/// Runtime player for compiled scenes.
/// Handles playback, user transforms, variant selection, and render command generation.
/// Does NOT handle compilation — use SceneCompiler from TVECompilerCore for that.
public final class ScenePlayer {

    // MARK: - Properties

    /// Compiled scene (single source of truth after loading)
    /// Contains runtime, merged assets, and path registry.
    /// Nil before loadCompiledScene() is called.
    public private(set) var compiledScene: CompiledScene?

    /// Per-block user transforms (pan/zoom/rotate from editor UI).
    /// Key: blockId (MediaBlock.id). Value: user-specified Matrix2D.
    /// Blocks without an entry default to `.identity`.
    private var userTransforms: [String: Matrix2D] = [:]

    /// Per-block variant overrides (PR-20).
    /// Key: blockId. Value: variantId chosen by user.
    /// Blocks without an entry use `BlockRuntime.selectedVariantId` (compilation default = first).
    /// Compiled data remains immutable — overrides live here.
    private var variantOverrides: [String: String] = [:]

    /// Per-block user media presence (PR-28).
    /// Key: blockId. Value: `true` if user has selected media for this block.
    /// Blocks without an entry default to `false` (binding layer hidden).
    /// When `false`, the binding layer is excluded from render commands entirely,
    /// preventing any texture requests for the binding placeholder.
    private var userMediaPresent: [String: Bool] = [:]

    /// Per-block layer toggle state (PR-30).
    /// Key: blockId. Value: dictionary of (toggleId → enabled).
    /// All toggles for each block are stored (full state, not sparse).
    /// Toggles default to `defaultOn` from scene.json if no persisted value exists.
    private var layerToggleState: [String: [String: Bool]] = [:]

    /// Per-block timing cache (PR1).
    /// Key: blockId. Value: BlockTiming.
    /// Built once during load for O(1) access.
    private var timingByBlockId: [String: BlockTiming] = [:]

    /// Optional persistence store for layer toggle state (PR-30).
    /// If nil, toggle state is only kept in memory for the session.
    private let toggleStore: LayerToggleStore?

    // MARK: - Initialization

    /// Creates a new ScenePlayer.
    ///
    /// - Parameter toggleStore: Optional persistence store for layer toggle state.
    ///   If provided, toggle state is saved/loaded across sessions.
    public init(toggleStore: LayerToggleStore? = nil) {
        self.toggleStore = toggleStore
    }

    // MARK: - Load Pre-Compiled Scene (PR2)

    /// Loads a pre-compiled scene from a CompiledScenePackage.
    ///
    /// This bypasses the Lottie JSON compilation path — the scene was compiled
    /// offline by TVETemplateCompiler. Performs minimal post-load initialization:
    /// - Clears stale overrides
    /// - Sets compiledScene
    /// - Builds timing cache
    /// - Initializes toggle state
    ///
    /// Used in Release builds where templates are pre-compiled at build time.
    ///
    /// - Parameter compiled: Pre-compiled scene from CompiledScenePackageLoader
    /// - Returns: The loaded CompiledScene for convenience
    @discardableResult
    public func loadCompiledScene(_ compiled: CompiledScene) -> CompiledScene {
        // 1. Clear stale overrides from a previous scene
        variantOverrides.removeAll()

        // 2. Set compiled scene (single source of truth)
        self.compiledScene = compiled

        // 3. Build timing cache for O(1) access
        self.timingByBlockId = Dictionary(
            uniqueKeysWithValues: compiled.runtime.blocks.map { ($0.blockId, $0.timing) }
        )

        // 4. Initialize toggle state (load from store or use defaults)
        initializeToggleState()

        return compiled
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

    // MARK: - User Media State (PR-28)

    /// Sets whether user media is present for a block.
    ///
    /// When `true`, the binding layer renders normally (user photo is shown).
    /// When `false`, the binding layer is excluded from render commands entirely —
    /// no draw commands are emitted and no texture requests are made.
    ///
    /// - Parameters:
    ///   - blockId: Identifier of the media block
    ///   - present: Whether user media is available for this block
    public func setUserMediaPresent(blockId: String, present: Bool) {
        userMediaPresent[blockId] = present
    }

    /// Returns whether user media is present for a block.
    ///
    /// - Parameter blockId: Identifier of the media block
    /// - Returns: `true` if user media is set, `false` otherwise (default)
    public func isUserMediaPresent(blockId: String) -> Bool {
        userMediaPresent[blockId] ?? false
    }

    // MARK: - Block Timing (PR1)

    /// Returns the timing information for a block.
    ///
    /// Used by `UserMediaService` to compute `tBlock` (time from block start)
    /// for video frame synchronization with trim/offset.
    ///
    /// - Parameter blockId: Identifier of the media block
    /// - Returns: BlockTiming with startFrame/endFrame, or `nil` if block not found
    public func blockTiming(for blockId: String) -> BlockTiming? {
        timingByBlockId[blockId]
    }

    // MARK: - Binding Asset IDs (PR-32)

    /// Returns the binding asset ID for the edit variant of a block.
    ///
    /// This is the namespaced asset ID where user media textures should be injected.
    /// The edit variant ("no-anim") is used because UI editing always operates on this variant.
    ///
    /// Example return value: `"no-anim.json|image_2"`
    ///
    /// - Parameter blockId: Identifier of the media block
    /// - Returns: Namespaced binding asset ID, or `nil` if block not found
    public func bindingAssetId(blockId: String) -> String? {
        guard let compiled = compiledScene else { return nil }
        guard let block = compiled.runtime.blocks.first(where: { $0.blockId == blockId }) else {
            return nil
        }
        guard let editVariant = block.variants.first(where: { $0.variantId == block.editVariantId }) else {
            return nil
        }
        return editVariant.animIR.binding.boundAssetId
    }

    /// Returns binding asset IDs for all variants of a block.
    ///
    /// When setting user media, textures should be injected for ALL variant binding asset IDs
    /// to ensure media persists across variant switches.
    ///
    /// Example return value:
    /// ```
    /// [
    ///     "no-anim": "no-anim.json|image_2",
    ///     "anim-1": "anim-1.json|image_2"
    /// ]
    /// ```
    ///
    /// - Parameter blockId: Identifier of the media block
    /// - Returns: Dictionary mapping variantId → namespaced binding asset ID, or empty if block not found
    public func bindingAssetIdsByVariant(blockId: String) -> [String: String] {
        guard let compiled = compiledScene else { return [:] }
        guard let block = compiled.runtime.blocks.first(where: { $0.blockId == blockId }) else {
            return [:]
        }
        var result: [String: String] = [:]
        for variant in block.variants {
            result[variant.variantId] = variant.animIR.binding.boundAssetId
        }
        return result
    }

    // MARK: - Layer Toggles (PR-30)

    /// Returns the list of available toggles for a block.
    ///
    /// - Parameter blockId: Identifier of the media block
    /// - Returns: Array of `LayerToggle` metadata, or empty if block not found or has no toggles
    public func availableToggles(blockId: String) -> [LayerToggle] {
        guard let compiled = compiledScene else { return [] }
        guard let block = compiled.runtime.scene.mediaBlocks.first(where: { $0.id == blockId }) else {
            return []
        }
        return block.layerToggles ?? []
    }

    /// Sets the enabled state for a layer toggle.
    ///
    /// The state is saved to the persistence store (if provided) and takes effect
    /// on the next render.
    ///
    /// - Parameters:
    ///   - blockId: Identifier of the media block
    ///   - toggleId: Identifier of the toggle (from scene.json)
    ///   - enabled: Whether the toggle layer should be visible
    public func setLayerToggle(blockId: String, toggleId: String, enabled: Bool) {
        guard let compiled = compiledScene else { return }

        // Ensure toggle exists in this block
        guard let block = compiled.runtime.scene.mediaBlocks.first(where: { $0.id == blockId }),
              let toggles = block.layerToggles,
              toggles.contains(where: { $0.id == toggleId }) else {
            return
        }

        // Update in-memory state
        if layerToggleState[blockId] == nil {
            layerToggleState[blockId] = [:]
        }
        layerToggleState[blockId]?[toggleId] = enabled

        // Persist if store available
        if let store = toggleStore, let sceneId = compiled.runtime.scene.sceneId {
            store.save(templateId: sceneId, blockId: blockId, toggleId: toggleId, value: enabled)
        }
    }

    /// Returns the current enabled state for a layer toggle.
    ///
    /// - Parameters:
    ///   - blockId: Identifier of the media block
    ///   - toggleId: Identifier of the toggle
    /// - Returns: `true` if enabled, `false` if disabled, `nil` if toggle not found
    public func isLayerToggleEnabled(blockId: String, toggleId: String) -> Bool? {
        guard let state = layerToggleState[blockId] else { return nil }
        return state[toggleId]
    }

    /// Resets a toggle to its default state from scene.json.
    ///
    /// - Parameters:
    ///   - blockId: Identifier of the media block
    ///   - toggleId: Identifier of the toggle
    public func resetLayerToggle(blockId: String, toggleId: String) {
        guard let compiled = compiledScene else { return }
        guard let block = compiled.runtime.scene.mediaBlocks.first(where: { $0.id == blockId }),
              let toggles = block.layerToggles,
              let toggle = toggles.first(where: { $0.id == toggleId }) else {
            return
        }

        setLayerToggle(blockId: blockId, toggleId: toggleId, enabled: toggle.defaultOn)
    }

    /// Resets all toggles for a block to their default states.
    ///
    /// - Parameter blockId: Identifier of the media block
    public func resetAllToggles(blockId: String) {
        guard let compiled = compiledScene else { return }
        guard let block = compiled.runtime.scene.mediaBlocks.first(where: { $0.id == blockId }),
              let toggles = block.layerToggles else {
            return
        }

        for toggle in toggles {
            setLayerToggle(blockId: blockId, toggleId: toggle.id, enabled: toggle.defaultOn)
        }
    }

    /// Initializes toggle state for all blocks after loading.
    ///
    /// Called internally after loadCompiledScene() succeeds. Loads persisted state from store
    /// or falls back to `defaultOn` from scene.json.
    private func initializeToggleState() {
        guard let compiled = compiledScene else { return }
        let sceneId = compiled.runtime.scene.sceneId

        layerToggleState.removeAll()

        for block in compiled.runtime.scene.mediaBlocks {
            guard let toggles = block.layerToggles, !toggles.isEmpty else {
                continue
            }

            var blockState: [String: Bool] = [:]

            for toggle in toggles {
                // Try to load from persistence store
                if let store = toggleStore, let sid = sceneId,
                   let persisted = store.load(templateId: sid, blockId: block.id, toggleId: toggle.id) {
                    blockState[toggle.id] = persisted
                } else {
                    // Fall back to default
                    blockState[toggle.id] = toggle.defaultOn
                }
            }

            layerToggleState[block.id] = blockState
        }
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
    /// User media presence (PR-28) controls binding layer visibility per block.
    /// Layer toggle state (PR-30) controls toggle layer visibility per block.
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
            variantOverrides: variantOverrides,
            userMediaPresent: userMediaPresent,
            layerToggleState: layerToggleState
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
            variantOverrides: overrides,
            userMediaPresent: userMediaPresent,
            layerToggleState: layerToggleState
        )
    }
}
