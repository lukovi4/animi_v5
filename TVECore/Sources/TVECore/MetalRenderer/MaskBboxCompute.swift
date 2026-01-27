import Foundation
import Metal

// MARK: - Pixel Bounding Box

/// Integer pixel bounding box for mask rendering.
struct PixelBBox: Equatable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    /// Converts to MTLScissorRect for GPU commands.
    var scissorRect: MTLScissorRect {
        MTLScissorRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - BBox Computation

/// Computes float bounding box for mask group from triangulated vertices in viewport pixels.
///
/// Uses triangulated vertices from PathRegistry for accurate bounds calculation.
/// Applies transforms to convert from path space to viewport space.
///
/// - Parameters:
///   - ops: Mask operations in AE order
///   - pathRegistry: Registry containing triangulated path data
///   - animToViewport: Animation to viewport transform
///   - currentTransform: Current layer transform stack
///   - scratch: Reusable scratch buffer for position sampling
/// - Returns: Bounding box in viewport pixels (float), or nil if empty/invalid
func computeMaskGroupBboxFloat(
    ops: [MaskOp],
    pathRegistry: PathRegistry,
    animToViewport: Matrix2D,
    currentTransform: Matrix2D,
    scratch: inout [Float]
) -> CGRect? {
    let pathToViewport = animToViewport.concatenating(currentTransform)

    var minX = CGFloat.greatestFiniteMagnitude
    var minY = CGFloat.greatestFiniteMagnitude
    var maxX = -CGFloat.greatestFiniteMagnitude
    var maxY = -CGFloat.greatestFiniteMagnitude

    var hasAnyVertex = false

    for op in ops {
        guard let resource = pathRegistry.path(for: op.pathId) else { continue }
        guard resource.vertexCount > 0 else { continue }

        // Sample triangulated positions at the operation's frame
        resource.sampleTriangulatedPositions(at: op.frame, into: &scratch)

        // Safety guard: ensure scratch has enough data
        // (defensive against future sampling implementation changes or corrupted resources)
        let vertexCount = resource.vertexCount
        let needed = vertexCount * 2
        guard scratch.count >= needed else { continue }

        // Transform each vertex and accumulate bounds
        for idx in 0..<vertexCount {
            let px = CGFloat(scratch[idx * 2])
            let py = CGFloat(scratch[idx * 2 + 1])

            // Apply pathToViewport transform
            let vx = pathToViewport.a * px + pathToViewport.b * py + pathToViewport.tx
            let vy = pathToViewport.c * px + pathToViewport.d * py + pathToViewport.ty

            minX = min(minX, vx)
            minY = min(minY, vy)
            maxX = max(maxX, vx)
            maxY = max(maxY, vy)
            hasAnyVertex = true
        }
    }

    guard hasAnyVertex, minX < maxX, minY < maxY else { return nil }

    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

// MARK: - BBox Rounding and Clamping

/// Rounds float bbox to integer pixels with AA expansion, clamps to target, and intersects with scissor.
///
/// Canonical rounding rules:
/// - `floor(minX/minY)` for origin
/// - `ceil(maxX/maxY)` for extent
/// - Expand by `expandAA` pixels for anti-aliasing
/// - Clamp to target bounds
/// - Intersect with current scissor (if any)
///
/// - Parameters:
///   - bboxFloat: Float bounding box in viewport pixels
///   - targetSize: Target texture size for clamping
///   - scissor: Current scissor rect (optional)
///   - expandAA: Pixels to expand for anti-aliasing (typically 2)
/// - Returns: Integer pixel bbox, or nil if fully clipped/degenerate
func roundClampIntersectBBoxToPixels(
    _ bboxFloat: CGRect,
    targetSize: (width: Int, height: Int),
    scissor: MTLScissorRect?,
    expandAA: Int = 2
) -> PixelBBox? {
    // Floor mins, ceil maxs for conservative rounding
    var x = Int(floor(bboxFloat.minX)) - expandAA
    var y = Int(floor(bboxFloat.minY)) - expandAA
    var maxX = Int(ceil(bboxFloat.maxX)) + expandAA
    var maxY = Int(ceil(bboxFloat.maxY)) + expandAA

    // Clamp to target bounds
    x = max(0, x)
    y = max(0, y)
    maxX = min(targetSize.width, maxX)
    maxY = min(targetSize.height, maxY)

    var width = maxX - x
    var height = maxY - y

    // Check for degenerate bbox after clamping
    guard width > 0, height > 0 else { return nil }

    // Intersect with scissor if present
    if let sc = scissor {
        let scMinX = sc.x
        let scMinY = sc.y
        let scMaxX = sc.x + sc.width
        let scMaxY = sc.y + sc.height

        let intMinX = max(x, scMinX)
        let intMinY = max(y, scMinY)
        let intMaxX = min(x + width, scMaxX)
        let intMaxY = min(y + height, scMaxY)

        // Check for empty intersection
        guard intMaxX > intMinX, intMaxY > intMinY else { return nil }

        x = intMinX
        y = intMinY
        width = intMaxX - intMinX
        height = intMaxY - intMinY
    }

    return PixelBBox(x: x, y: y, width: width, height: height)
}
