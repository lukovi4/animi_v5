import Foundation
import CoreGraphics

// MARK: - Matte BBox Computation

/// Computes bounding box for matte scope based on draw commands.
///
/// Algorithm:
/// 1. Dry-run through sourceRange and consumerRange commands
/// 2. Simulate transform stack (pushTransform/popTransform)
/// 3. Accumulate bounds for drawImage, drawShape, drawStroke
/// 4. Return intersection(sourceBbox, consumerBbox)
///
/// If source bbox cannot be computed, returns consumer bbox only (conservative).
/// If neither can be computed, returns nil (fallback to full-frame).
///
/// - Parameters:
///   - commands: Full command array
///   - sourceRange: Range of matte source commands
///   - consumerRange: Range of matte consumer commands
///   - inheritedTransform: Current accumulated transform from parent scope
///   - animToViewport: Animation to viewport coordinate transform
///   - assetSizes: Asset size metadata for drawImage bounds
///   - pathRegistry: Path registry for drawShape/drawStroke bounds
/// - Returns: Float bounding box in viewport coordinates, or nil if cannot be computed
func computeMatteBBox(
    commands: [RenderCommand],
    sourceRange: Range<Int>,
    consumerRange: Range<Int>,
    inheritedTransform: Matrix2D,
    animToViewport: Matrix2D,
    assetSizes: [String: AssetSize],
    pathRegistry: PathRegistry
) -> CGRect? {
    // Compute source and consumer bboxes separately
    let sourceBbox = computeRangeBBox(
        commands: commands,
        range: sourceRange,
        inheritedTransform: inheritedTransform,
        animToViewport: animToViewport,
        assetSizes: assetSizes,
        pathRegistry: pathRegistry
    )

    let consumerBbox = computeRangeBBox(
        commands: commands,
        range: consumerRange,
        inheritedTransform: inheritedTransform,
        animToViewport: animToViewport,
        assetSizes: assetSizes,
        pathRegistry: pathRegistry
    )

    // Per review.md #2: intersection(source, consumer)
    // If source nil → use consumer only (conservative)
    // If both nil → return nil (fallback)
    switch (sourceBbox, consumerBbox) {
    case let (source?, consumer?):
        // Intersection of both
        let intersection = source.intersection(consumer)
        // Check for empty intersection
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
            return nil
        }
        return intersection

    case (nil, let consumer?):
        // Source unavailable, use consumer only (less optimal but safe)
        return consumer

    case (_, nil):
        // Consumer unavailable → cannot compute valid bbox
        return nil
    }
}

// MARK: - Range BBox Computation

/// Computes bounding box for a range of commands by dry-running through them.
///
/// Simulates transform stack and accumulates bounds for all draw* commands.
/// Ignores clip rects (per review.md #7 - scissor applied later).
///
/// - Parameters:
///   - commands: Full command array
///   - range: Range of commands to process
///   - inheritedTransform: Starting transform
///   - animToViewport: Animation to viewport transform
///   - assetSizes: Asset sizes for drawImage
///   - pathRegistry: Path registry for shapes
/// - Returns: Accumulated bbox in viewport coordinates, or nil if no valid bounds
private func computeRangeBBox(
    commands: [RenderCommand],
    range: Range<Int>,
    inheritedTransform: Matrix2D,
    animToViewport: Matrix2D,
    assetSizes: [String: AssetSize],
    pathRegistry: PathRegistry
) -> CGRect? {
    guard !range.isEmpty else { return nil }

    // Transform stack simulation
    var transformStack: [Matrix2D] = [inheritedTransform]

    // Accumulated bounds
    var minX = CGFloat.greatestFiniteMagnitude
    var minY = CGFloat.greatestFiniteMagnitude
    var maxX = -CGFloat.greatestFiniteMagnitude
    var maxY = -CGFloat.greatestFiniteMagnitude
    var hasAnyBounds = false

    // Scratch buffer for path sampling (reused to avoid allocations)
    var scratch: [Float] = []

    for idx in range {
        let command = commands[idx]

        switch command {
        case .pushTransform(let matrix):
            let current = transformStack.last ?? .identity
            transformStack.append(current.concatenating(matrix))

        case .popTransform:
            if transformStack.count > 1 {
                transformStack.removeLast()
            }

        case .drawImage(let assetId, let opacity):
            guard opacity > 0 else { continue }

            // Get asset size from metadata
            guard let assetSize = assetSizes[assetId] else {
                // Per review.md #4: missing asset size → bbox invalid → return nil
                return nil
            }

            let currentTransform = transformStack.last ?? .identity
            let bounds = computeImageBounds(
                width: assetSize.width,
                height: assetSize.height,
                transform: currentTransform,
                animToViewport: animToViewport
            )

            minX = min(minX, bounds.minX)
            minY = min(minY, bounds.minY)
            maxX = max(maxX, bounds.maxX)
            maxY = max(maxY, bounds.maxY)
            hasAnyBounds = true

        case .drawShape(let pathId, _, let fillOpacity, let layerOpacity, let frame):
            let effectiveOpacity = (fillOpacity / 100.0) * layerOpacity
            guard effectiveOpacity > 0 else { continue }

            guard let pathResource = pathRegistry.path(for: pathId) else {
                // Missing path → bbox invalid
                return nil
            }

            let currentTransform = transformStack.last ?? .identity
            guard let bounds = computePathBounds(
                pathResource: pathResource,
                frame: frame,
                transform: currentTransform,
                animToViewport: animToViewport,
                expansion: 0,
                scratch: &scratch
            ) else {
                continue // Empty path, skip
            }

            minX = min(minX, bounds.minX)
            minY = min(minY, bounds.minY)
            maxX = max(maxX, bounds.maxX)
            maxY = max(maxY, bounds.maxY)
            hasAnyBounds = true

        case .drawStroke(let pathId, _, let strokeOpacity, let strokeWidth, _, _, let miterLimit, let layerOpacity, let frame):
            let effectiveOpacity = strokeOpacity * layerOpacity
            guard effectiveOpacity > 0 else { continue }
            guard strokeWidth > 0 else { continue }

            guard let pathResource = pathRegistry.path(for: pathId) else {
                // Missing path → bbox invalid
                return nil
            }

            let currentTransform = transformStack.last ?? .identity

            // Stroke expansion in anim space
            let expansionAnim = strokeWidth * max(1.0, miterLimit) / 2.0

            // Scale expansion to viewport using upper bound of transform scale.
            // Frobenius norm of linear part: sqrt(a² + b² + c² + d²)
            // This guarantees expansion ≥ actual stroke coverage in viewport.
            let fullTransform = animToViewport.concatenating(currentTransform)
            let scaleUpper = sqrt(
                fullTransform.a * fullTransform.a +
                fullTransform.b * fullTransform.b +
                fullTransform.c * fullTransform.c +
                fullTransform.d * fullTransform.d
            )
            let expansionViewport = expansionAnim * scaleUpper

            guard let bounds = computePathBounds(
                pathResource: pathResource,
                frame: frame,
                transform: currentTransform,
                animToViewport: animToViewport,
                expansion: expansionViewport,
                scratch: &scratch
            ) else {
                continue // Empty path, skip
            }

            minX = min(minX, bounds.minX)
            minY = min(minY, bounds.minY)
            maxX = max(maxX, bounds.maxX)
            maxY = max(maxY, bounds.maxY)
            hasAnyBounds = true

        // Structural commands - process but don't affect bbox
        case .beginGroup, .endGroup:
            break

        case .pushClipRect, .popClipRect:
            // Per review.md #7: ignore clip rects in dry-run
            break

        case .beginMask, .endMask, .beginMatte, .endMatte:
            // Per review.md #6: process nested scopes linearly
            // Just continue iterating, bounds inside will be accumulated
            break
        }
    }

    guard hasAnyBounds, minX < maxX, minY < maxY else {
        return nil
    }

    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

// MARK: - Image Bounds

/// Computes transformed bounding box for an image quad.
private func computeImageBounds(
    width: Double,
    height: Double,
    transform: Matrix2D,
    animToViewport: Matrix2D
) -> CGRect {
    // Image quad corners in local coordinates (origin at 0,0)
    let corners: [(Double, Double)] = [
        (0, 0),
        (width, 0),
        (0, height),
        (width, height)
    ]

    // Full transform: animToViewport ∘ transform
    let fullTransform = animToViewport.concatenating(transform)

    var minX = CGFloat.greatestFiniteMagnitude
    var minY = CGFloat.greatestFiniteMagnitude
    var maxX = -CGFloat.greatestFiniteMagnitude
    var maxY = -CGFloat.greatestFiniteMagnitude

    for (x, y) in corners {
        let vx = fullTransform.a * x + fullTransform.b * y + fullTransform.tx
        let vy = fullTransform.c * x + fullTransform.d * y + fullTransform.ty

        minX = min(minX, CGFloat(vx))
        minY = min(minY, CGFloat(vy))
        maxX = max(maxX, CGFloat(vx))
        maxY = max(maxY, CGFloat(vy))
    }

    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

// MARK: - Path Bounds

/// Computes transformed bounding box for a path at a given frame.
///
/// - Parameters:
///   - pathResource: Path to compute bounds for
///   - frame: Animation frame for sampling
///   - transform: Current accumulated transform
///   - animToViewport: Animation to viewport transform
///   - expansion: Extra expansion for stroke width (0 for fill)
///   - scratch: Reusable scratch buffer for sampling
/// - Returns: Bounding box in viewport coordinates, or nil if path is empty
private func computePathBounds(
    pathResource: PathResource,
    frame: Double,
    transform: Matrix2D,
    animToViewport: Matrix2D,
    expansion: Double,
    scratch: inout [Float]
) -> CGRect? {
    guard pathResource.vertexCount > 0 else { return nil }

    // Sample positions at frame
    pathResource.sampleTriangulatedPositions(at: frame, into: &scratch)

    let vertexCount = pathResource.vertexCount
    guard scratch.count >= vertexCount * 2 else { return nil }

    // Full transform: animToViewport ∘ transform
    let fullTransform = animToViewport.concatenating(transform)

    var minX = CGFloat.greatestFiniteMagnitude
    var minY = CGFloat.greatestFiniteMagnitude
    var maxX = -CGFloat.greatestFiniteMagnitude
    var maxY = -CGFloat.greatestFiniteMagnitude

    for idx in 0..<vertexCount {
        let px = Double(scratch[idx * 2])
        let py = Double(scratch[idx * 2 + 1])

        let vx = fullTransform.a * px + fullTransform.b * py + fullTransform.tx
        let vy = fullTransform.c * px + fullTransform.d * py + fullTransform.ty

        minX = min(minX, CGFloat(vx))
        minY = min(minY, CGFloat(vy))
        maxX = max(maxX, CGFloat(vx))
        maxY = max(maxY, CGFloat(vy))
    }

    guard minX < maxX, minY < maxY else { return nil }

    // Apply expansion for stroke
    if expansion > 0 {
        let exp = CGFloat(expansion)
        minX -= exp
        minY -= exp
        maxX += exp
        maxY += exp
    }

    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}
