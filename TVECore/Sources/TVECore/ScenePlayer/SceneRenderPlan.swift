import Foundation

// MARK: - Scene Render Plan

/// Generates render commands for a scene at a given frame
public enum SceneRenderPlan {

    /// Generates render commands for all visible blocks at the given scene frame
    ///
    /// - Parameters:
    ///   - runtime: Compiled scene runtime
    ///   - sceneFrameIndex: Current frame index in scene timeline
    /// - Returns: Array of render commands for all visible blocks
    public static func renderCommands(
        for runtime: SceneRuntime,
        sceneFrameIndex: Int
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
            // Skip invisible blocks
            guard block.timing.isVisible(at: sceneFrameIndex) else {
                continue
            }

            // Get selected variant
            guard var variant = block.selectedVariant else {
                continue
            }

            // Generate commands for this block
            let blockCommands = renderBlockCommands(
                block: block,
                variant: &variant,
                sceneFrameIndex: sceneFrameIndex,
                canvasSize: canvasSize
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
        canvasSize: SizeD
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
        let blockTransform = computeBlockTransform(
            animSize: variant.animIR.meta.size,
            blockRect: block.rectCanvas,
            canvasSize: canvasSize
        )
        commands.append(.pushTransform(blockTransform))

        // Compute local frame index for this animation
        let localFrameIndex = computeLocalFrameIndex(
            sceneFrameIndex: sceneFrameIndex,
            blockTiming: block.timing,
            animIR: variant.animIR
        )

        // Get animation render commands
        let animCommands = variant.animIR.renderCommands(frameIndex: localFrameIndex)
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

    /// Computes the transformation matrix to place animation content within a block
    ///
    /// Block Placement Policy:
    /// - If anim is full-canvas (animSize ≈ canvasSize), use identity transform (clip does the work)
    /// - Otherwise, scale animation to fit within block (contain policy)
    private static func computeBlockTransform(
        animSize: SizeD,
        blockRect: RectD,
        canvasSize: SizeD
    ) -> Matrix2D {
        // Policy: if anim is full-canvas, use identity (clip does the work)
        // Scale only when anim is not full-canvas
        if nearlyEqual(animSize.width, canvasSize.width) &&
           nearlyEqual(animSize.height, canvasSize.height) {
            return .identity
        }
        // Otherwise scale to fit block using GeometryMapping.animToInputContain which does:
        // - Uniform scale to fit (contain)
        // - Center within target rect
        // - Translate to target position
        return GeometryMapping.animToInputContain(animSize: animSize, inputRect: blockRect)
    }

    /// Compares two Double values with tolerance for floating-point comparison
    private static func nearlyEqual(_ lhs: Double, _ rhs: Double, eps: Double = 0.0001) -> Bool {
        abs(lhs - rhs) < eps
    }

    /// Computes the local frame index for an animation given the scene frame
    ///
    /// Current policy (PR10): Simple 1:1 mapping with clamping
    /// - Scene frame maps directly to animation frame
    /// - Result is clamped to animation bounds [0, op-1]
    private static func computeLocalFrameIndex(
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
    /// Generates render commands for the given scene frame
    /// Convenience method that delegates to SceneRenderPlan
    public func renderCommands(sceneFrameIndex: Int) -> [RenderCommand] {
        SceneRenderPlan.renderCommands(for: self, sceneFrameIndex: sceneFrameIndex)
    }
}
