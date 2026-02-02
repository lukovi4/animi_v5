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
    ///   - renderPolicy: Render policy (PR-18). `.fullPreview` renders all layers;
    ///     `.editInputsOnly` renders only binding layers + dependencies.
    ///   - variantOverrides: Per-block variant overrides keyed by blockId (PR-20).
    ///     Blocks not present use `block.selectedVariantId` (compilation default).
    /// - Returns: Array of render commands for all visible blocks
    public static func renderCommands(
        for runtime: SceneRuntime,
        sceneFrameIndex: Int,
        userTransforms: [String: Matrix2D] = [:],
        renderPolicy: RenderPolicy = .fullPreview,
        variantOverrides: [String: String] = [:]
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
            // Skip invisible blocks.
            // v1 limitation (PR-18): in edit mode sceneFrameIndex == editFrameIndex (0),
            // so blocks whose timing starts after frame 0 are NOT editable.
            // This is intentional for v1 — a future version may show all blocks in edit.
            guard block.timing.isVisible(at: sceneFrameIndex) else {
                continue
            }

            // Resolve active variant: override → compilation default → first (PR-20)
            guard var variant = block.resolvedVariant(overrides: variantOverrides) else {
                continue
            }

            // Resolve user transform for this block (default: identity)
            let userTransform = userTransforms[block.blockId] ?? .identity

            // Generate commands based on render policy (PR-18)
            let blockCommands: [RenderCommand]
            switch renderPolicy {
            case .fullPreview:
                blockCommands = renderBlockCommands(
                    block: block,
                    variant: &variant,
                    sceneFrameIndex: sceneFrameIndex,
                    canvasSize: canvasSize,
                    userTransform: userTransform
                )
            case .editInputsOnly:
                blockCommands = renderBlockEditCommands(
                    block: block,
                    variant: &variant,
                    canvasSize: canvasSize,
                    userTransform: userTransform
                )
            }
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
        userTransform: Matrix2D
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

        // Get animation render commands with user transform (PR-16)
        let animCommands = variant.animIR.renderCommands(
            frameIndex: localFrameIndex,
            userTransform: userTransform
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

    /// Generates render commands for a single block in **edit mode** (PR-18).
    ///
    /// Uses `editFrameIndex = 0` directly — no timing/loop policies applied.
    /// Calls `AnimIR.renderEditCommands` which renders only the binding layer
    /// and its mask/matte dependencies.
    private static func renderBlockEditCommands(
        block: BlockRuntime,
        variant: inout VariantRuntime,
        canvasSize: SizeD,
        userTransform: Matrix2D
    ) -> [RenderCommand] {
        var commands: [RenderCommand] = []

        // Begin block group (tagged with "(edit)" for diagnostics)
        commands.append(.beginGroup(name: "Block:\(block.blockId)(edit)"))

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

        // Edit mode: use canonical editFrameIndex — no timing/loop policies
        let animCommands = variant.animIR.renderEditCommands(
            frameIndex: Self.editFrameIndex,
            userTransform: userTransform
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
    public func renderCommands(sceneFrameIndex: Int) -> [RenderCommand] {
        SceneRenderPlan.renderCommands(for: self, sceneFrameIndex: sceneFrameIndex)
    }
}
