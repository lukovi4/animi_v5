import Foundation

// MARK: - Scene Transforms

/// Shared transform utilities for scene block placement.
///
/// Extracted from `SceneRenderPlan` (PR-17) so that both the render pipeline
/// and the hit-test / overlay pipeline use **exactly the same** block-to-canvas
/// transform — guaranteeing bit-for-bit determinism.
public enum SceneTransforms {

    /// Computes the transformation matrix that places animation content within a block
    /// on the canvas.
    ///
    /// Block Placement Policy:
    /// - If the animation is full-canvas (`animSize ~= canvasSize`), returns `.identity`
    ///   (clip does the work).
    /// - Otherwise, scales animation to fit within the block using contain policy
    ///   (uniform scale + centering via `GeometryMapping.animToInputContain`).
    ///
    /// - Parameters:
    ///   - animSize: Size of the animation in its local coordinate space
    ///   - blockRect: Block rectangle in canvas coordinates
    ///   - canvasSize: Canvas dimensions
    /// - Returns: Transformation matrix from anim-local space to canvas space
    public static func blockTransform(
        animSize: SizeD,
        blockRect: RectD,
        canvasSize: SizeD
    ) -> Matrix2D {
        // Policy: if anim is full-canvas, use identity (clip does the work)
        if Quantization.isNearlyEqual(animSize.width, canvasSize.width) &&
           Quantization.isNearlyEqual(animSize.height, canvasSize.height) {
            return .identity
        }
        // Otherwise scale to fit block using GeometryMapping.animToInputContain which does:
        // - Uniform scale to fit (contain)
        // - Center within target rect
        // - Translate to target position
        return GeometryMapping.animToInputContain(animSize: animSize, inputRect: blockRect)
    }
}
