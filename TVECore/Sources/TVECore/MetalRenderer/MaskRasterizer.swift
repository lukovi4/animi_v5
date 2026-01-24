import CoreGraphics
import Foundation

// MARK: - Fill Rule

/// Fill rule for path rasterization
enum FillRule {
    case nonZero
    case evenOdd
}

// MARK: - Mask Rasterizer

/// Rasterizes BezierPath to alpha bytes using CoreGraphics.
/// Used to create mask textures for stencil-based masking.
enum MaskRasterizer {
    /// Rasterizes a BezierPath to alpha bytes.
    /// - Parameters:
    ///   - path: The Bezier path to rasterize
    ///   - transformToViewportPx: Transform from path coords to viewport pixels
    ///   - targetSizePx: Target texture size in pixels (width, height)
    ///   - fillRule: Fill rule for the path (default: .nonZero)
    ///   - antialias: Whether to use antialiasing (default: true)
    /// - Returns: Alpha bytes array (row-major, one byte per pixel)
    static func rasterize(
        path: BezierPath,
        transformToViewportPx: Matrix2D,
        targetSizePx: (width: Int, height: Int),
        fillRule: FillRule = .nonZero,
        antialias: Bool = true
    ) -> [UInt8] {
        let width = targetSizePx.width
        let height = targetSizePx.height

        guard width > 0, height > 0 else {
            return []
        }

        // Create grayscale context (1 byte per pixel = alpha channel)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return [UInt8](repeating: 0, count: width * height)
        }

        // Configure context
        context.setShouldAntialias(antialias)
        context.setAllowsAntialiasing(antialias)

        // Clear to black (alpha = 0)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Convert BezierPath to CGPath with transform
        let cgPath = createCGPath(from: path, transform: transformToViewportPx, height: height)

        // Fill path with white (alpha = 1)
        context.setFillColor(gray: 1, alpha: 1)
        context.addPath(cgPath)

        switch fillRule {
        case .nonZero:
            context.fillPath(using: .winding)
        case .evenOdd:
            context.fillPath(using: .evenOdd)
        }

        // Extract pixel data
        guard let data = context.data else {
            return [UInt8](repeating: 0, count: width * height)
        }

        let buffer = data.bindMemory(to: UInt8.self, capacity: width * height)
        return Array(UnsafeBufferPointer(start: buffer, count: width * height))
    }

    // MARK: - Private

    /// Creates a CGPath from BezierPath with the given transform.
    /// Handles coordinate system flip (CoreGraphics Y is bottom-up).
    private static func createCGPath(
        from bezierPath: BezierPath,
        transform: Matrix2D,
        height: Int
    ) -> CGPath {
        let cgPath = CGMutablePath()

        guard bezierPath.vertexCount > 0 else {
            return cgPath
        }

        let vertices = bezierPath.vertices
        let inTangents = bezierPath.inTangents
        let outTangents = bezierPath.outTangents

        // Move to first vertex
        let firstPoint = transformPoint(vertices[0], transform: transform, height: height)
        cgPath.move(to: firstPoint)

        // Draw curves between vertices
        for idx in 1..<vertices.count {
            let prevIdx = idx - 1
            let currVertex = vertices[idx]
            let prevVertex = vertices[prevIdx]

            // Control points: cp1 = prevVertex + outTangent[prev], cp2 = currVertex + inTangent[curr]
            let cp1 = Vec2D(
                x: prevVertex.x + outTangents[prevIdx].x,
                y: prevVertex.y + outTangents[prevIdx].y
            )
            let cp2 = Vec2D(
                x: currVertex.x + inTangents[idx].x,
                y: currVertex.y + inTangents[idx].y
            )

            let cp1Transformed = transformPoint(cp1, transform: transform, height: height)
            let cp2Transformed = transformPoint(cp2, transform: transform, height: height)
            let endTransformed = transformPoint(currVertex, transform: transform, height: height)

            cgPath.addCurve(to: endTransformed, control1: cp1Transformed, control2: cp2Transformed)
        }

        // Close path if needed
        if bezierPath.closed && vertices.count > 1 {
            let lastIdx = vertices.count - 1
            let lastVertex = vertices[lastIdx]
            let firstVertex = vertices[0]

            // Closing curve from last vertex back to first
            let cp1 = Vec2D(
                x: lastVertex.x + outTangents[lastIdx].x,
                y: lastVertex.y + outTangents[lastIdx].y
            )
            let cp2 = Vec2D(
                x: firstVertex.x + inTangents[0].x,
                y: firstVertex.y + inTangents[0].y
            )

            let cp1Transformed = transformPoint(cp1, transform: transform, height: height)
            let cp2Transformed = transformPoint(cp2, transform: transform, height: height)
            let endTransformed = transformPoint(firstVertex, transform: transform, height: height)

            cgPath.addCurve(to: endTransformed, control1: cp1Transformed, control2: cp2Transformed)
            cgPath.closeSubpath()
        }

        return cgPath
    }

    /// Transforms a point and flips Y coordinate for CoreGraphics.
    private static func transformPoint(
        _ point: Vec2D,
        transform: Matrix2D,
        height: Int
    ) -> CGPoint {
        let transformed = transform.apply(to: point)
        // Flip Y: CoreGraphics origin is bottom-left, Metal is top-left
        return CGPoint(x: transformed.x, y: Double(height) - transformed.y)
    }
}
