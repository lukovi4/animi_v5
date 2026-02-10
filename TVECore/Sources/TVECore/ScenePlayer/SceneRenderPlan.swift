import Foundation

// MARK: - Scene Render Plan

/// Generates render commands for a scene at a given frame
public enum SceneRenderPlan {

    /// Canonical edit frame index — single source of truth.
    /// Edit mode always renders at this frame (no timing/loop policies).
    public static let editFrameIndex: Int = 0

    /// Generates render commands for all visible blocks at the given scene frame.
    ///
    /// - Parameters:
    ///   - runtime: Compiled scene runtime
    ///   - sceneFrameIndex: Current frame index in scene timeline
    ///   - userTransforms: Per-block user transforms keyed by blockId.
    ///     Blocks not present in the dictionary receive `.identity`.
    ///   - variantOverrides: Per-block variant overrides keyed by blockId (PR-20).
    ///     Blocks not present use `block.selectedVariantId` (compilation default).
    ///     For edit mode, the caller passes `{ blockId: editVariantId }` for all blocks.
    ///   - userMediaPresent: Per-block flag indicating whether user media is available (PR-28).
    ///     Blocks not present in the dictionary default to `false` (binding layer hidden).
    ///     When `false`, the binding layer is excluded from render commands entirely.
    ///   - layerToggleState: Per-block toggle state (PR-30).
    ///     Maps blockId → (toggleId → enabled). Toggles not present default to enabled.
    /// - Returns: Array of render commands for all visible blocks
    public static func renderCommands(
        for runtime: SceneRuntime,
        sceneFrameIndex: Int,
        userTransforms: [String: Matrix2D] = [:],
        variantOverrides: [String: String] = [:],
        userMediaPresent: [String: Bool] = [:],
        layerToggleState: [String: [String: Bool]] = [:]
    ) -> [RenderCommand] {
        var commands: [RenderCommand] = []

        // Begin scene group
        commands.append(.beginGroup(name: "Scene:\(runtime.scene.sceneId ?? "unnamed")"))

        // Canvas size for block transform policy
        let canvasSize = SizeD(
            width: Double(runtime.canvas.width),
            height: Double(runtime.canvas.height)
        )

        // Process blocks in zIndex order (already sorted in runtime)
        for block in runtime.blocks {
            // Skip invisible blocks at the given frame.
            // In edit mode sceneFrameIndex == editFrameIndex (0),
            // so blocks whose timing starts after frame 0 are NOT editable.
            guard block.timing.isVisible(at: sceneFrameIndex) else {
                continue
            }

            // Resolve active variant: override → compilation default → first (PR-20)
            guard var variant = block.resolvedVariant(overrides: variantOverrides) else {
                continue
            }

            // Resolve user transform for this block (default: identity)
            let userTransform = userTransforms[block.blockId] ?? .identity

            // PR-28: Resolve user media presence (default: false = binding hidden)
            let hasUserMedia = userMediaPresent[block.blockId] ?? false

            // PR-30: Compute disabled toggle IDs from state (toggles default to enabled)
            let blockToggleState = layerToggleState[block.blockId] ?? [:]
            let disabledToggleIds = Set(blockToggleState.filter { !$0.value }.map { $0.key })

            let blockCommands = renderBlockCommands(
                block: block,
                variant: &variant,
                sceneFrameIndex: sceneFrameIndex,
                canvasSize: canvasSize,
                userTransform: userTransform,
                hasUserMedia: hasUserMedia,
                disabledToggleIds: disabledToggleIds
            )
            commands.append(contentsOf: blockCommands)
        }

        // End scene group
        commands.append(.endGroup)

        return commands
    }

    /// Generates render commands for a single block
    private static func renderBlockCommands(
        block: BlockRuntime,
        variant: inout VariantRuntime,
        sceneFrameIndex: Int,
        canvasSize: SizeD,
        userTransform: Matrix2D,
        hasUserMedia: Bool,
        disabledToggleIds: Set<String>
    ) -> [RenderCommand] {
        var commands: [RenderCommand] = []

        // Begin block group
        commands.append(.beginGroup(name: "Block:\(block.blockId)"))

        // Apply clip if container clip is enabled
        let shouldClip = block.containerClip == .slotRect || block.containerClip == .slotRectAfterSettle
        if shouldClip {
            commands.append(.pushClipRect(block.rectCanvas))
        }

        // Compute block transform: identity when anim is full-canvas, otherwise scale to fit
        let blockTransform = SceneTransforms.blockTransform(
            animSize: variant.animIR.meta.size,
            blockRect: block.rectCanvas,
            canvasSize: canvasSize
        )
        commands.append(.pushTransform(blockTransform))

        // Compute local frame index for this animation
        let localFrameIndex = localFrameIndex(
            sceneFrameIndex: sceneFrameIndex,
            blockTiming: block.timing,
            animIR: variant.animIR
        )

        // PR-26: If active variant lacks inputGeometry, get clip override from editVariant.
        // The editVariant (no-anim) always has mediaInput by contract (validated in compileBlock).
        var inputClipOverride: InputClipOverride?
        if variant.animIR.inputGeometry == nil {
            if var editIR = block.variants.first(where: { $0.variantId == block.editVariantId })?.animIR,
               let editGeo = editIR.inputGeometry {
                if let clipWorld = editIR.mediaInputInCompWorldMatrix(frame: Self.editFrameIndex) {
                    inputClipOverride = InputClipOverride(
                        inputGeometry: editGeo,
                        clipWorldMatrix: clipWorld
                    )
                }
            }
        }

        // Get animation render commands with user transform (PR-16)
        // PR-28: Pass bindingLayerVisible to skip binding layer when user media is absent
        // PR-30: Pass disabledToggleIds to skip disabled toggle layers
        let animCommands = variant.animIR.renderCommands(
            frameIndex: localFrameIndex,
            userTransform: userTransform,
            inputClipOverride: inputClipOverride,
            bindingLayerVisible: hasUserMedia,
            disabledToggleIds: disabledToggleIds
        )
        commands.append(contentsOf: animCommands)

        // Pop transform
        commands.append(.popTransform)

        // Pop clip if applied
        if shouldClip {
            commands.append(.popClipRect)
        }

        // End block group
        commands.append(.endGroup)

        return commands
    }

    /// Computes the local frame index for an animation given the scene frame.
    ///
    /// Current policy (PR10): Simple 1:1 mapping with clamping.
    /// - Scene frame maps directly to animation frame.
    /// - Result is clamped to animation bounds [0, op-1].
    public static func localFrameIndex(
        sceneFrameIndex: Int,
        blockTiming: BlockTiming,
        animIR: AnimIR
    ) -> Int {
        // Calculate frame relative to block start
        let relativeFrame = sceneFrameIndex - blockTiming.startFrame

        // Clamp to animation bounds
        return animIR.localFrameIndex(sceneFrameIndex: relativeFrame)
    }
}

// MARK: - Scene Runtime Extensions

extension SceneRuntime {
    /// Generates render commands for the given scene frame.
    /// Convenience method that delegates to SceneRenderPlan with no user transforms.
    ///
    /// - Parameters:
    ///   - sceneFrameIndex: Frame index in scene timeline
    ///   - userMediaPresent: Per-block user media presence flags (default: empty = all binding hidden)
    public func renderCommands(
        sceneFrameIndex: Int,
        userMediaPresent: [String: Bool] = [:]
    ) -> [RenderCommand] {
        SceneRenderPlan.renderCommands(
            for: self,
            sceneFrameIndex: sceneFrameIndex,
            userMediaPresent: userMediaPresent
        )
    }
}
