import Foundation
import TVECore

// MARK: - BezierPath from Lottie

extension BezierPath {
    /// Creates BezierPath from LottiePathData
    public init?(from pathData: LottiePathData?) {
        guard let pathData = pathData,
              let pathVertices = pathData.vertices,
              !pathVertices.isEmpty else {
            return nil
        }

        let vertices = pathVertices.map { arr in
            Vec2D(x: !arr.isEmpty ? arr[0] : 0, y: arr.count > 1 ? arr[1] : 0)
        }

        let inTangents = (pathData.inTangents ?? []).map { arr in
            Vec2D(x: !arr.isEmpty ? arr[0] : 0, y: arr.count > 1 ? arr[1] : 0)
        }

        let outTangents = (pathData.outTangents ?? []).map { arr in
            Vec2D(x: !arr.isEmpty ? arr[0] : 0, y: arr.count > 1 ? arr[1] : 0)
        }

        let closed = pathData.closed ?? false

        self.init(vertices: vertices, inTangents: inTangents, outTangents: outTangents, closed: closed)
    }

    /// Creates BezierPath from LottieAnimatedValue (expects static path)
    public init?(from animatedValue: LottieAnimatedValue?) {
        guard let animatedValue = animatedValue,
              let data = animatedValue.value else {
            return nil
        }

        switch data {
        case .path(let pathData):
            self.init(from: pathData)
        default:
            return nil
        }
    }
}

// MARK: - Mask from Lottie

extension Mask {
    /// Creates Mask from LottieMask
    public init?(from lottieMask: LottieMask) {
        // Parse mode from Lottie string (a/s/i → add/subtract/intersect)
        guard let modeString = lottieMask.mode,
              let mode = MaskMode(rawValue: modeString) else {
            return nil
        }

        let inverted = lottieMask.inverted ?? false

        // Extract opacity (static only in Part 1)
        let opacity: Double
        if let opacityValue = lottieMask.opacity,
           let data = opacityValue.value {
            switch data {
            case .number(let num):
                opacity = num
            case .array(let arr) where !arr.isEmpty:
                opacity = arr[0]
            default:
                opacity = 100
            }
        } else {
            opacity = 100
        }

        // Extract path (static or animated)
        guard let pathValue = lottieMask.path else {
            return nil
        }

        let path: AnimPath
        if pathValue.isAnimated {
            // Extract animated path with keyframes
            guard let animPath = Self.extractAnimatedMaskPath(from: pathValue) else {
                return nil
            }
            path = animPath
        } else {
            // Static path
            guard let bezier = BezierPath(from: pathValue) else {
                return nil
            }
            path = .staticBezier(bezier)
        }

        self.init(mode: mode, inverted: inverted, opacity: opacity, path: path)
    }

    /// Extracts animated path from LottieAnimatedValue for mask
    private static func extractAnimatedMaskPath(from value: LottieAnimatedValue) -> AnimPath? {
        guard let data = value.value,
              case .keyframes(let lottieKeyframes) = data else {
            return nil
        }

        var keyframes: [Keyframe<BezierPath>] = []
        var expectedVertexCount: Int?
        var expectedClosed: Bool?

        for kf in lottieKeyframes {
            guard let time = kf.time else { continue }

            // Extract path data from keyframe
            guard case .path(let pathData) = kf.startValue,
                  let bezier = BezierPath(from: pathData) else {
                continue
            }

            // Validate topology matches across keyframes
            if let expectedCount = expectedVertexCount {
                guard bezier.vertexCount == expectedCount else {
                    // Topology mismatch - cannot interpolate
                    return nil
                }
            } else {
                expectedVertexCount = bezier.vertexCount
            }

            if let expectedClosedFlag = expectedClosed {
                guard bezier.closed == expectedClosedFlag else {
                    return nil
                }
            } else {
                expectedClosed = bezier.closed
            }

            // Extract easing tangents
            let inTan = extractTangent(from: kf.inTangent)
            let outTan = extractTangent(from: kf.outTangent)
            let hold = (kf.hold ?? 0) == 1

            keyframes.append(Keyframe(
                time: time,
                value: bezier,
                inTangent: inTan,
                outTangent: outTan,
                hold: hold
            ))
        }

        guard !keyframes.isEmpty else { return nil }

        if keyframes.count == 1 {
            return .staticBezier(keyframes[0].value)
        }

        return .keyframedBezier(keyframes)
    }

    /// Extracts easing tangent from LottieTangent
    private static func extractTangent(from tangent: LottieTangent?) -> Vec2D? {
        guard let tangent = tangent else { return nil }

        let x: Double
        let y: Double

        switch tangent.x {
        case .single(let val):
            x = val
        case .array(let arr) where !arr.isEmpty:
            x = arr[0]
        default:
            x = 0
        }

        switch tangent.y {
        case .single(let val):
            y = val
        case .array(let arr) where !arr.isEmpty:
            y = arr[0]
        default:
            y = 0
        }

        return Vec2D(x: x, y: y)
    }
}

// MARK: - Shape Path Extraction

/// Extracts bezier path from shape layer shapes
public enum ShapePathExtractor {
    /// Extracts the first path from a list of Lottie shapes (static only)
    public static func extractPath(from shapes: [ShapeItem]?) -> BezierPath? {
        guard let shapes = shapes else { return nil }

        for shape in shapes {
            if let path = extractPathFromShape(shape) {
                return path
            }
        }
        return nil
    }

    /// Extracts animated path (AnimPath) from a list of Lottie shapes
    /// Supports both static and keyframed paths with topology validation
    public static func extractAnimPath(from shapes: [ShapeItem]?) -> AnimPath? {
        guard let shapes = shapes else { return nil }

        for shape in shapes {
            if let animPath = extractAnimPathFromShape(shape) {
                return animPath
            }
        }
        return nil
    }

    // MARK: - Trim Paths Validation (PR-13)

    /// Validates that shapes do not contain Trim Paths (ty:"tm").
    /// Throws UnsupportedFeature if tm is found anywhere in the shape tree.
    /// This is a defensive check to prevent silent ignore even without validator.
    /// - Parameters:
    ///   - shapes: Array of shape items to validate
    ///   - basePath: Base path for error reporting (e.g., "anim(ref).layers[0]")
    /// - Throws: UnsupportedFeature if Trim Paths is found
    public static func validateNoTrimPaths(shapes: [ShapeItem]?, basePath: String) throws {
        guard let shapes = shapes else { return }

        for (index, shape) in shapes.enumerated() {
            let shapePath = "\(basePath).shapes[\(index)]"
            try validateShapeNoTrimPaths(shape: shape, basePath: shapePath)
        }
    }

    /// Recursively validates a single shape item for Trim Paths.
    /// - Parameters:
    ///   - shape: Shape item to validate
    ///   - basePath: Full path to this shape item
    /// - Throws: UnsupportedFeature if Trim Paths is found
    private static func validateShapeNoTrimPaths(shape: ShapeItem, basePath: String) throws {
        switch shape {
        case .group(let shapeGroup):
            // Recurse into group items
            guard let items = shapeGroup.items else { return }
            for (itemIndex, item) in items.enumerated() {
                try validateShapeNoTrimPaths(shape: item, basePath: "\(basePath).it[\(itemIndex)]")
            }

        case .unknown(let type) where type == "tm":
            // PR-13: Trim Paths found - throw error
            throw UnsupportedFeature(
                code: AnimValidationCode.unsupportedTrimPaths,
                message: "Trim Paths (ty:'tm') not supported. Remove it or bake the effect in After Effects.",
                path: "\(basePath).ty"
            )

        default:
            // Other shapes are OK - no validation needed
            break
        }
    }

    private static func extractPathFromShape(_ shape: ShapeItem) -> BezierPath? {
        switch shape {
        case .path(let pathShape):
            // Path shape - extract vertices
            return BezierPath(from: pathShape.vertices)

        case .rect(let rect):
            // Rectangle shape - build bezier path from position, size, roundness
            return buildRectBezierPath(from: rect)

        case .ellipse(let ellipse):
            // Ellipse shape - build bezier path from position and size
            return buildEllipseBezierPath(from: ellipse)

        case .polystar(let polystar):
            // Polystar shape - build bezier path from position, points, radii, rotation
            return buildPolystarBezierPath(from: polystar)

        case .group(let shapeGroup):
            // Group - recurse into items
            // NOTE (PR-11): Transform is NOT baked into path anymore!
            // Group transform is extracted separately and applied at render time.
            guard let items = shapeGroup.items else { return nil }

            // Extract path from items (recursive) - NO transform baking
            return extractPath(from: items)

        default:
            return nil
        }
    }

    private static func extractAnimPathFromShape(_ shape: ShapeItem) -> AnimPath? {
        switch shape {
        case .path(let pathShape):
            // Path shape - check if animated
            guard let vertices = pathShape.vertices else { return nil }

            if vertices.isAnimated {
                // Extract keyframed path
                return extractKeyframedPath(from: vertices)
            } else {
                // Static path
                if let bezier = BezierPath(from: vertices) {
                    return .staticBezier(bezier)
                }
                return nil
            }

        case .rect(let rect):
            // Rectangle shape - extract static or animated path
            return extractRectAnimPath(from: rect)

        case .ellipse(let ellipse):
            // Ellipse shape - extract static or animated path
            return extractEllipseAnimPath(from: ellipse)

        case .polystar(let polystar):
            // Polystar shape - extract static or animated path
            return extractPolystarAnimPath(from: polystar)

        case .group(let shapeGroup):
            // Group - recurse into items
            // NOTE (PR-11): Transform is NOT baked into path anymore!
            // Group transform is extracted separately and applied at render time.
            guard let items = shapeGroup.items else { return nil }

            // Extract AnimPath from items (recursive) - NO transform baking
            return extractAnimPath(from: items)

        default:
            return nil
        }
    }

    // MARK: - Rectangle Path Building

    /// Kappa constant for circular arc approximation with cubic Bezier
    /// This produces a quarter circle with < 0.02% error
    private static let kappa: Double = 0.5522847498307936

    /// Builds a static BezierPath from a LottieShapeRect
    /// - Parameter rect: The rectangle shape definition
    /// - Returns: BezierPath or nil if position/size cannot be extracted
    private static func buildRectBezierPath(from rect: LottieShapeRect) -> BezierPath? {
        // Extract static position [cx, cy]
        guard let position = extractVec2D(from: rect.position) else { return nil }

        // Extract static size [w, h]
        guard let size = extractVec2D(from: rect.size) else { return nil }

        // Extract static roundness (default 0)
        let roundness = extractDouble(from: rect.roundness) ?? 0

        // Direction: 1 = clockwise (default), 2 = counter-clockwise
        let direction = rect.direction ?? 1

        return buildRectBezierPath(
            cx: position.x,
            cy: position.y,
            width: size.x,
            height: size.y,
            roundness: roundness,
            direction: direction
        )
    }

    /// Builds a BezierPath for a rectangle with given parameters
    /// - Parameters:
    ///   - cx: Center X position
    ///   - cy: Center Y position
    ///   - width: Rectangle width
    ///   - height: Rectangle height
    ///   - roundness: Corner radius (will be clamped to valid range)
    ///   - direction: 1 = clockwise, 2 = counter-clockwise
    /// - Returns: BezierPath representing the rectangle
    private static func buildRectBezierPath(
        cx: Double,
        cy: Double,
        width: Double,
        height: Double,
        roundness: Double,
        direction: Int
    ) -> BezierPath {
        let halfW = width / 2
        let halfH = height / 2

        // Clamp roundness to valid range: 0 <= r <= min(halfW, halfH)
        let radius = max(0, min(roundness, min(halfW, halfH)))

        if radius == 0 {
            // Sharp corners: 4 vertices, no tangents
            return buildSharpRectPath(cx: cx, cy: cy, halfW: halfW, halfH: halfH, direction: direction)
        } else {
            // Rounded corners: 8 vertices with cubic bezier tangents
            return buildRoundedRectPath(cx: cx, cy: cy, halfW: halfW, halfH: halfH, radius: radius, direction: direction)
        }
    }

    /// Builds a sharp-cornered rectangle (4 vertices)
    private static func buildSharpRectPath(
        cx: Double,
        cy: Double,
        halfW: Double,
        halfH: Double,
        direction: Int
    ) -> BezierPath {
        // Vertices in clockwise order (d=1): top-left, top-right, bottom-right, bottom-left
        let topLeft = Vec2D(x: cx - halfW, y: cy - halfH)
        let topRight = Vec2D(x: cx + halfW, y: cy - halfH)
        let bottomRight = Vec2D(x: cx + halfW, y: cy + halfH)
        let bottomLeft = Vec2D(x: cx - halfW, y: cy + halfH)

        var vertices = [topLeft, topRight, bottomRight, bottomLeft]

        // Reverse for counter-clockwise (d=2)
        if direction == 2 {
            vertices.reverse()
        }

        // Zero tangents for sharp corners
        let zeroTangents = [Vec2D.zero, Vec2D.zero, Vec2D.zero, Vec2D.zero]

        return BezierPath(
            vertices: vertices,
            inTangents: zeroTangents,
            outTangents: zeroTangents,
            closed: true
        )
    }

    /// Builds a rounded rectangle (8 vertices with bezier tangents)
    /// Each corner has 2 vertices: one at the start of the arc, one at the end
    private static func buildRoundedRectPath(
        cx: Double,
        cy: Double,
        halfW: Double,
        halfH: Double,
        radius: Double,
        direction: Int
    ) -> BezierPath {
        // Control point offset for quarter circle
        let c = radius * kappa

        // Build vertices and tangents for clockwise direction (d=1)
        // Starting from top edge, going clockwise: TR corner, right edge, BR corner, etc.

        // Top edge end (before top-right corner arc)
        let p0 = Vec2D(x: cx + halfW - radius, y: cy - halfH)
        // Top-right corner arc end (start of right edge)
        let p1 = Vec2D(x: cx + halfW, y: cy - halfH + radius)
        // Right edge end (before bottom-right corner arc)
        let p2 = Vec2D(x: cx + halfW, y: cy + halfH - radius)
        // Bottom-right corner arc end (start of bottom edge)
        let p3 = Vec2D(x: cx + halfW - radius, y: cy + halfH)
        // Bottom edge end (before bottom-left corner arc)
        let p4 = Vec2D(x: cx - halfW + radius, y: cy + halfH)
        // Bottom-left corner arc end (start of left edge)
        let p5 = Vec2D(x: cx - halfW, y: cy + halfH - radius)
        // Left edge end (before top-left corner arc)
        let p6 = Vec2D(x: cx - halfW, y: cy - halfH + radius)
        // Top-left corner arc end (start of top edge)
        let p7 = Vec2D(x: cx - halfW + radius, y: cy - halfH)

        var vertices = [p0, p1, p2, p3, p4, p5, p6, p7]

        // Tangents for clockwise direction
        // For each arc: outTangent points toward next vertex, inTangent points toward previous
        // Straight segments have zero tangents at their endpoints

        // p0 (before TR arc): in=0 (from straight), out=(+c, 0) toward arc
        // p1 (after TR arc): in=(0, -c) from arc, out=0 (to straight)
        // p2 (before BR arc): in=0 (from straight), out=(0, +c) toward arc
        // p3 (after BR arc): in=(+c, 0) from arc, out=0 (to straight) -- note: in is toward p2
        // p4 (before BL arc): in=0 (from straight), out=(-c, 0) toward arc
        // p5 (after BL arc): in=(0, +c) from arc, out=0 (to straight)
        // p6 (before TL arc): in=0 (from straight), out=(0, -c) toward arc
        // p7 (after TL arc): in=(-c, 0) from arc, out=0 (to straight)

        var inTangents = [
            Vec2D.zero,            // p0: straight segment before
            Vec2D(x: 0, y: -c),    // p1: from TR arc
            Vec2D.zero,            // p2: straight segment before
            Vec2D(x: c, y: 0),     // p3: from BR arc
            Vec2D.zero,            // p4: straight segment before
            Vec2D(x: 0, y: c),     // p5: from BL arc
            Vec2D.zero,            // p6: straight segment before
            Vec2D(x: -c, y: 0)     // p7: from TL arc
        ]

        var outTangents = [
            Vec2D(x: c, y: 0),     // p0: to TR arc
            Vec2D.zero,            // p1: straight segment after
            Vec2D(x: 0, y: c),     // p2: to BR arc
            Vec2D.zero,            // p3: straight segment after
            Vec2D(x: -c, y: 0),    // p4: to BL arc
            Vec2D.zero,            // p5: straight segment after
            Vec2D(x: 0, y: -c),    // p6: to TL arc
            Vec2D.zero             // p7: straight segment after (to p0)
        ]

        // For counter-clockwise (d=2), reverse vertices and swap in/out tangents
        if direction == 2 {
            vertices.reverse()
            inTangents.reverse()
            outTangents.reverse()

            // After reversing, we need to swap in/out and negate tangent directions
            // But since we reversed the array, we actually need to swap in<->out at each position
            let tempIn = inTangents
            inTangents = outTangents.map { Vec2D(x: -$0.x, y: -$0.y) }
            outTangents = tempIn.map { Vec2D(x: -$0.x, y: -$0.y) }
        }

        return BezierPath(
            vertices: vertices,
            inTangents: inTangents,
            outTangents: outTangents,
            closed: true
        )
    }

    /// Extracts AnimPath from a LottieShapeRect (supports animated position/size)
    /// - Parameter rect: The rectangle shape definition
    /// - Returns: AnimPath (static or keyframed) or nil if extraction fails
    private static func extractRectAnimPath(from rect: LottieShapeRect) -> AnimPath? {
        let positionAnimated = rect.position?.isAnimated ?? false
        let sizeAnimated = rect.size?.isAnimated ?? false
        let roundnessAnimated = rect.roundness?.isAnimated ?? false

        // Animated roundness not supported in PR-07 (topology would change)
        if roundnessAnimated {
            return nil
        }

        // Static roundness value (default 0)
        let roundness = extractDouble(from: rect.roundness) ?? 0

        // Direction (static)
        let direction = rect.direction ?? 1

        // If both position and size are static, return static path
        if !positionAnimated && !sizeAnimated {
            if let bezier = buildRectBezierPath(from: rect) {
                return .staticBezier(bezier)
            }
            return nil
        }

        // Extract keyframes arrays
        let positionKeyframes: [LottieKeyframe]?
        let sizeKeyframes: [LottieKeyframe]?

        if positionAnimated {
            guard let posValue = rect.position,
                  let posData = posValue.value,
                  case .keyframes(let posKfs) = posData else {
                return nil
            }
            positionKeyframes = posKfs
        } else {
            positionKeyframes = nil
        }

        if sizeAnimated {
            guard let sizeValue = rect.size,
                  let sizeData = sizeValue.value,
                  case .keyframes(let sizeKfs) = sizeData else {
                return nil
            }
            sizeKeyframes = sizeKfs
        } else {
            sizeKeyframes = nil
        }

        // STRICT VALIDATION: If both p and s are animated, they must have matching keyframes
        if let posKfs = positionKeyframes, let sizeKfs = sizeKeyframes {
            // Check count match
            guard posKfs.count == sizeKfs.count else {
                return nil // Keyframe count mismatch - fail-fast
            }

            // Check time match for each keyframe
            for i in 0..<posKfs.count {
                let posTime = posKfs[i].time
                let sizeTime = sizeKfs[i].time

                // Both must have time
                guard let pt = posTime, let st = sizeTime else {
                    return nil // Missing time - fail-fast
                }

                // Times must match (PR-14A: use AnimConstants.keyframeTimeEpsilon)
                guard Quantization.keyframeTimesEqual(pt, st) else {
                    return nil // Time mismatch - fail-fast
                }
            }
        }

        // Extract static values strictly (no fallbacks for animated properties)
        let staticPosition: Vec2D?
        if !positionAnimated {
            // Position is static - must extract successfully
            guard let pos = extractVec2D(from: rect.position) else {
                return nil // Cannot extract static position - fail-fast
            }
            staticPosition = pos
        } else {
            staticPosition = nil
        }

        let staticSize: Vec2D?
        if !sizeAnimated {
            // Size is static - must extract successfully
            guard let sz = extractVec2D(from: rect.size) else {
                return nil // Cannot extract static size - fail-fast
            }
            staticSize = sz
        } else {
            staticSize = nil
        }

        // Determine driver keyframes (prefer size, then position)
        let driverKeyframes: [LottieKeyframe]
        if let sizeKfs = sizeKeyframes {
            driverKeyframes = sizeKfs
        } else if let posKfs = positionKeyframes {
            driverKeyframes = posKfs
        } else {
            return nil // Should not happen given earlier checks
        }

        var keyframes: [Keyframe<BezierPath>] = []

        for (index, driverKf) in driverKeyframes.enumerated() {
            // Time is required - fail-fast if missing
            guard let time = driverKf.time else {
                return nil // Missing keyframe time - fail-fast
            }

            // Get position at this keyframe - no fallbacks
            let position: Vec2D
            if let posKfs = positionKeyframes {
                // Position is animated - must extract from keyframe
                guard let pos = extractVec2DFromKeyframe(posKfs[index]) else {
                    return nil // Cannot extract animated position - fail-fast
                }
                position = pos
            } else if let staticPos = staticPosition {
                // Position is static - use extracted value
                position = staticPos
            } else {
                return nil // Should not happen
            }

            // Get size at this keyframe - no fallbacks
            let size: Vec2D
            if let sizeKfs = sizeKeyframes {
                // Size is animated - must extract from keyframe
                guard let sz = extractVec2DFromKeyframe(sizeKfs[index]) else {
                    return nil // Cannot extract animated size - fail-fast
                }
                size = sz
            } else if let staticSz = staticSize {
                // Size is static - use extracted value
                size = staticSz
            } else {
                return nil // Should not happen
            }

            // Build bezier path for this keyframe
            let bezier = buildRectBezierPath(
                cx: position.x,
                cy: position.y,
                width: size.x,
                height: size.y,
                roundness: roundness,
                direction: direction
            )

            // Extract easing from driver keyframe
            let inTan = extractTangent(from: driverKf.inTangent)
            let outTan = extractTangent(from: driverKf.outTangent)
            let hold = (driverKf.hold ?? 0) == 1

            keyframes.append(Keyframe(
                time: time,
                value: bezier,
                inTangent: inTan,
                outTangent: outTan,
                hold: hold
            ))
        }

        guard !keyframes.isEmpty else { return nil }

        if keyframes.count == 1 {
            return .staticBezier(keyframes[0].value)
        }

        return .keyframedBezier(keyframes)
    }

    /// Extracts Vec2D from a keyframe's startValue
    private static func extractVec2DFromKeyframe(_ kf: LottieKeyframe) -> Vec2D? {
        guard let startValue = kf.startValue else { return nil }
        switch startValue {
        case .numbers(let arr) where arr.count >= 2:
            return Vec2D(x: arr[0], y: arr[1])
        default:
            return nil
        }
    }

    // MARK: - Ellipse Path Building

    /// Builds a static BezierPath from a LottieShapeEllipse
    /// - Parameter ellipse: The ellipse shape definition
    /// - Returns: BezierPath or nil if position/size cannot be extracted or size is invalid
    private static func buildEllipseBezierPath(from ellipse: LottieShapeEllipse) -> BezierPath? {
        // Extract static position [cx, cy]
        guard let position = extractVec2D(from: ellipse.position) else { return nil }

        // Extract static size [w, h]
        guard let size = extractVec2D(from: ellipse.size) else { return nil }

        // Validate size - must be positive
        guard size.x > 0 && size.y > 0 else { return nil }

        // Direction: 1 = clockwise (default), 2 = counter-clockwise
        let direction = ellipse.direction ?? 1

        return buildEllipseBezierPath(
            cx: position.x,
            cy: position.y,
            width: size.x,
            height: size.y,
            direction: direction
        )
    }

    /// Builds a BezierPath for an ellipse with given parameters
    /// Uses 4-point cubic bezier approximation (kappa constant)
    /// - Parameters:
    ///   - cx: Center X position
    ///   - cy: Center Y position
    ///   - width: Ellipse width
    ///   - height: Ellipse height
    ///   - direction: 1 = clockwise, 2 = counter-clockwise
    /// - Returns: BezierPath representing the ellipse (always 4 vertices)
    private static func buildEllipseBezierPath(
        cx: Double,
        cy: Double,
        width: Double,
        height: Double,
        direction: Int
    ) -> BezierPath {
        let rx = width / 2   // horizontal radius
        let ry = height / 2  // vertical radius

        // Control point offsets for quarter-circle arc approximation
        let cpx = rx * kappa
        let cpy = ry * kappa

        // 4 anchor points in clockwise order (d=1): top, right, bottom, left
        let top = Vec2D(x: cx, y: cy - ry)
        let right = Vec2D(x: cx + rx, y: cy)
        let bottom = Vec2D(x: cx, y: cy + ry)
        let left = Vec2D(x: cx - rx, y: cy)

        var vertices = [top, right, bottom, left]

        // Tangents for clockwise direction
        // Each vertex has in-tangent (from previous segment) and out-tangent (to next segment)
        // Tangents are RELATIVE to the vertex

        // top: in from left arc (-cpx, 0), out to right arc (+cpx, 0)
        // right: in from top arc (0, -cpy), out to bottom arc (0, +cpy)
        // bottom: in from right arc (+cpx, 0), out to left arc (-cpx, 0)
        // left: in from bottom arc (0, +cpy), out to top arc (0, -cpy)

        var inTangents = [
            Vec2D(x: -cpx, y: 0),    // top: from left arc
            Vec2D(x: 0, y: -cpy),    // right: from top arc
            Vec2D(x: cpx, y: 0),     // bottom: from right arc
            Vec2D(x: 0, y: cpy)      // left: from bottom arc
        ]

        var outTangents = [
            Vec2D(x: cpx, y: 0),     // top: to right arc
            Vec2D(x: 0, y: cpy),     // right: to bottom arc
            Vec2D(x: -cpx, y: 0),    // bottom: to left arc
            Vec2D(x: 0, y: -cpy)     // left: to top arc
        ]

        // For counter-clockwise (d=2), reverse vertices and swap/negate tangents
        if direction == 2 {
            vertices.reverse()
            inTangents.reverse()
            outTangents.reverse()

            // After reversing, swap in/out and negate tangent directions
            let tempIn = inTangents
            inTangents = outTangents.map { Vec2D(x: -$0.x, y: -$0.y) }
            outTangents = tempIn.map { Vec2D(x: -$0.x, y: -$0.y) }
        }

        return BezierPath(
            vertices: vertices,
            inTangents: inTangents,
            outTangents: outTangents,
            closed: true
        )
    }

    /// Extracts AnimPath from a LottieShapeEllipse (supports animated position/size)
    /// - Parameter ellipse: The ellipse shape definition
    /// - Returns: AnimPath (static or keyframed) or nil if extraction fails
    private static func extractEllipseAnimPath(from ellipse: LottieShapeEllipse) -> AnimPath? {
        let positionAnimated = ellipse.position?.isAnimated ?? false
        let sizeAnimated = ellipse.size?.isAnimated ?? false

        // Direction (static)
        let direction = ellipse.direction ?? 1

        // If both position and size are static, return static path
        if !positionAnimated && !sizeAnimated {
            if let bezier = buildEllipseBezierPath(from: ellipse) {
                return .staticBezier(bezier)
            }
            return nil
        }

        // Extract keyframes arrays
        let positionKeyframes: [LottieKeyframe]?
        let sizeKeyframes: [LottieKeyframe]?

        if positionAnimated {
            guard let posValue = ellipse.position,
                  let posData = posValue.value,
                  case .keyframes(let posKfs) = posData else {
                return nil
            }
            positionKeyframes = posKfs
        } else {
            positionKeyframes = nil
        }

        if sizeAnimated {
            guard let sizeValue = ellipse.size,
                  let sizeData = sizeValue.value,
                  case .keyframes(let sizeKfs) = sizeData else {
                return nil
            }
            sizeKeyframes = sizeKfs
        } else {
            sizeKeyframes = nil
        }

        // STRICT VALIDATION: If both p and s are animated, they must have matching keyframes
        if let posKfs = positionKeyframes, let sizeKfs = sizeKeyframes {
            // Check count match
            guard posKfs.count == sizeKfs.count else {
                return nil // Keyframe count mismatch - fail-fast
            }

            // Check time match for each keyframe
            for i in 0..<posKfs.count {
                let posTime = posKfs[i].time
                let sizeTime = sizeKfs[i].time

                // Both must have time
                guard let pt = posTime, let st = sizeTime else {
                    return nil // Missing time - fail-fast
                }

                // Times must match (PR-14A: use AnimConstants.keyframeTimeEpsilon)
                guard Quantization.keyframeTimesEqual(pt, st) else {
                    return nil // Time mismatch - fail-fast
                }
            }
        }

        // Extract static values strictly (no fallbacks for animated properties)
        let staticPosition: Vec2D?
        if !positionAnimated {
            // Position is static - must extract successfully
            guard let pos = extractVec2D(from: ellipse.position) else {
                return nil // Cannot extract static position - fail-fast
            }
            staticPosition = pos
        } else {
            staticPosition = nil
        }

        let staticSize: Vec2D?
        if !sizeAnimated {
            // Size is static - must extract successfully
            guard let sz = extractVec2D(from: ellipse.size) else {
                return nil // Cannot extract static size - fail-fast
            }
            // Validate static size is positive
            guard sz.x > 0 && sz.y > 0 else {
                return nil // Invalid size - fail-fast
            }
            staticSize = sz
        } else {
            staticSize = nil
        }

        // Determine driver keyframes (prefer size, then position)
        let driverKeyframes: [LottieKeyframe]
        if let sizeKfs = sizeKeyframes {
            driverKeyframes = sizeKfs
        } else if let posKfs = positionKeyframes {
            driverKeyframes = posKfs
        } else {
            return nil // Should not happen given earlier checks
        }

        var keyframes: [Keyframe<BezierPath>] = []

        for (index, driverKf) in driverKeyframes.enumerated() {
            // Time is required - fail-fast if missing
            guard let time = driverKf.time else {
                return nil // Missing keyframe time - fail-fast
            }

            // Get position at this keyframe - no fallbacks
            let position: Vec2D
            if let posKfs = positionKeyframes {
                // Position is animated - must extract from keyframe
                guard let pos = extractVec2DFromKeyframe(posKfs[index]) else {
                    return nil // Cannot extract animated position - fail-fast
                }
                position = pos
            } else if let staticPos = staticPosition {
                // Position is static - use extracted value
                position = staticPos
            } else {
                return nil // Should not happen
            }

            // Get size at this keyframe - no fallbacks
            let size: Vec2D
            if let sizeKfs = sizeKeyframes {
                // Size is animated - must extract from keyframe
                guard let sz = extractVec2DFromKeyframe(sizeKfs[index]) else {
                    return nil // Cannot extract animated size - fail-fast
                }
                // Validate animated size is positive
                guard sz.x > 0 && sz.y > 0 else {
                    return nil // Invalid size in keyframe - fail-fast
                }
                size = sz
            } else if let staticSz = staticSize {
                // Size is static - use extracted value
                size = staticSz
            } else {
                return nil // Should not happen
            }

            // Build bezier path for this keyframe
            let bezier = buildEllipseBezierPath(
                cx: position.x,
                cy: position.y,
                width: size.x,
                height: size.y,
                direction: direction
            )

            // Extract easing from driver keyframe
            let inTan = extractTangent(from: driverKf.inTangent)
            let outTan = extractTangent(from: driverKf.outTangent)
            let hold = (driverKf.hold ?? 0) == 1

            keyframes.append(Keyframe(
                time: time,
                value: bezier,
                inTangent: inTan,
                outTangent: outTan,
                hold: hold
            ))
        }

        guard !keyframes.isEmpty else { return nil }

        if keyframes.count == 1 {
            return .staticBezier(keyframes[0].value)
        }

        return .keyframedBezier(keyframes)
    }

    // MARK: - Polystar Path Building

    /// Builds a static BezierPath from a LottieShapePolystar
    /// - Parameter polystar: The polystar shape definition
    /// - Returns: BezierPath or nil if parameters cannot be extracted or are invalid
    private static func buildPolystarBezierPath(from polystar: LottieShapePolystar) -> BezierPath? {
        // Extract star type (1 = star, 2 = polygon)
        guard let starType = polystar.starType, (starType == 1 || starType == 2) else { return nil }

        // Extract static position [cx, cy]
        guard let position = extractVec2D(from: polystar.position) else { return nil }

        // Extract static points count (must be integer in 3...100)
        guard let points = extractDouble(from: polystar.points),
              points >= 3, points <= 100, points == points.rounded() else { return nil }
        let pointsInt = Int(points)

        // Extract static outer radius
        guard let outerRadius = extractDouble(from: polystar.outerRadius),
              outerRadius > 0 else { return nil }

        // Extract inner radius (required for star, ignored for polygon)
        let innerRadius: Double
        if starType == 1 {
            guard let ir = extractDouble(from: polystar.innerRadius),
                  ir > 0, ir < outerRadius else { return nil }
            innerRadius = ir
        } else {
            innerRadius = 0 // Not used for polygon
        }

        // Extract static rotation (default 0)
        let rotationDeg = extractDouble(from: polystar.rotation) ?? 0

        // Validate roundness is zero (or absent) - PR-14A: use AnimConstants.nearlyEqualEpsilon
        if let innerRoundness = extractDouble(from: polystar.innerRoundness), !Quantization.isNearlyZero(innerRoundness) {
            return nil
        }
        if let outerRoundness = extractDouble(from: polystar.outerRoundness), !Quantization.isNearlyZero(outerRoundness) {
            return nil
        }

        // Direction: 1 = clockwise (default), 2 = counter-clockwise
        let direction = polystar.direction ?? 1

        return buildPolystarBezierPath(
            cx: position.x,
            cy: position.y,
            points: pointsInt,
            outerRadius: outerRadius,
            innerRadius: innerRadius,
            rotationDeg: rotationDeg,
            starType: starType,
            direction: direction
        )
    }

    /// Builds a BezierPath for a polystar with given parameters
    /// - Parameters:
    ///   - cx: Center X position
    ///   - cy: Center Y position
    ///   - points: Number of points (>= 3)
    ///   - outerRadius: Outer radius (> 0)
    ///   - innerRadius: Inner radius (only used for star, > 0 and < outerRadius)
    ///   - rotationDeg: Rotation in degrees
    ///   - starType: 1 = star (2N vertices), 2 = polygon (N vertices)
    ///   - direction: 1 = clockwise, 2 = counter-clockwise
    /// - Returns: BezierPath representing the polystar (sharp corners, no roundness)
    private static func buildPolystarBezierPath(
        cx: Double,
        cy: Double,
        points: Int,
        outerRadius: Double,
        innerRadius: Double,
        rotationDeg: Double,
        starType: Int,
        direction: Int
    ) -> BezierPath {
        // Convert rotation to radians
        let rotationRad = rotationDeg * .pi / 180.0

        // Start angle: -π/2 so that 0° rotation points "up" (matching AE/Lottie convention)
        let startAngle = -.pi / 2.0

        var vertices: [Vec2D] = []

        if starType == 2 {
            // Polygon: N vertices at equal angles
            let step = 2.0 * .pi / Double(points)
            for i in 0..<points {
                let angle = startAngle + rotationRad + Double(i) * step
                let x = cx + outerRadius * cos(angle)
                let y = cy + outerRadius * sin(angle)
                vertices.append(Vec2D(x: x, y: y))
            }
        } else {
            // Star: 2N vertices alternating outer/inner radius
            let step = .pi / Double(points)
            let totalVertices = points * 2
            for k in 0..<totalVertices {
                let angle = startAngle + rotationRad + Double(k) * step
                let radius = (k % 2 == 0) ? outerRadius : innerRadius
                let x = cx + radius * cos(angle)
                let y = cy + radius * sin(angle)
                vertices.append(Vec2D(x: x, y: y))
            }
        }

        // For counter-clockwise (d=2), reverse vertices
        if direction == 2 {
            vertices.reverse()
        }

        // Sharp corners: all tangents are zero
        let zeroTangents = Array(repeating: Vec2D.zero, count: vertices.count)

        return BezierPath(
            vertices: vertices,
            inTangents: zeroTangents,
            outTangents: zeroTangents,
            closed: true
        )
    }

    /// Extracts AnimPath from a LottieShapePolystar (supports animated position/rotation/radii)
    /// - Parameter polystar: The polystar shape definition
    /// - Returns: AnimPath (static or keyframed) or nil if extraction fails
    private static func extractPolystarAnimPath(from polystar: LottieShapePolystar) -> AnimPath? {
        // Extract star type (1 = star, 2 = polygon)
        guard let starType = polystar.starType, (starType == 1 || starType == 2) else { return nil }
        let isStar = starType == 1

        // Validate roundness is zero or absent
        if polystar.innerRoundness?.isAnimated == true || polystar.outerRoundness?.isAnimated == true {
            return nil
        }
        // PR-14A: use AnimConstants.nearlyEqualEpsilon
        if let innerRoundness = extractDouble(from: polystar.innerRoundness), !Quantization.isNearlyZero(innerRoundness) {
            return nil
        }
        if let outerRoundness = extractDouble(from: polystar.outerRoundness), !Quantization.isNearlyZero(outerRoundness) {
            return nil
        }

        // Points must be static (animated would change topology)
        if polystar.points?.isAnimated == true {
            return nil
        }
        // Points must be integer in 3...100
        guard let points = extractDouble(from: polystar.points),
              points >= 3, points <= 100, points == points.rounded() else { return nil }
        let pointsInt = Int(points)

        // Direction (static)
        let direction = polystar.direction ?? 1

        // Check which fields are animated
        let positionAnimated = polystar.position?.isAnimated ?? false
        let rotationAnimated = polystar.rotation?.isAnimated ?? false
        let outerRadiusAnimated = polystar.outerRadius?.isAnimated ?? false
        let innerRadiusAnimated = isStar && (polystar.innerRadius?.isAnimated ?? false)

        // If nothing is animated, return static path
        if !positionAnimated && !rotationAnimated && !outerRadiusAnimated && !innerRadiusAnimated {
            if let bezier = buildPolystarBezierPath(from: polystar) {
                return .staticBezier(bezier)
            }
            return nil
        }

        // Extract keyframes from animated fields
        let positionKeyframes: [LottieKeyframe]?
        let rotationKeyframes: [LottieKeyframe]?
        let outerRadiusKeyframes: [LottieKeyframe]?
        let innerRadiusKeyframes: [LottieKeyframe]?

        if positionAnimated {
            guard let posValue = polystar.position,
                  let posData = posValue.value,
                  case .keyframes(let kfs) = posData else { return nil }
            positionKeyframes = kfs
        } else {
            positionKeyframes = nil
        }

        if rotationAnimated {
            guard let rotValue = polystar.rotation,
                  let rotData = rotValue.value,
                  case .keyframes(let kfs) = rotData else { return nil }
            rotationKeyframes = kfs
        } else {
            rotationKeyframes = nil
        }

        if outerRadiusAnimated {
            guard let orValue = polystar.outerRadius,
                  let orData = orValue.value,
                  case .keyframes(let kfs) = orData else { return nil }
            outerRadiusKeyframes = kfs
        } else {
            outerRadiusKeyframes = nil
        }

        if innerRadiusAnimated {
            guard let irValue = polystar.innerRadius,
                  let irData = irValue.value,
                  case .keyframes(let kfs) = irData else { return nil }
            innerRadiusKeyframes = kfs
        } else {
            innerRadiusKeyframes = nil
        }

        // Collect all animated keyframe arrays
        var allKeyframeArrays: [[LottieKeyframe]] = []
        if let kfs = outerRadiusKeyframes { allKeyframeArrays.append(kfs) }
        if let kfs = positionKeyframes { allKeyframeArrays.append(kfs) }
        if let kfs = rotationKeyframes { allKeyframeArrays.append(kfs) }
        if let kfs = innerRadiusKeyframes { allKeyframeArrays.append(kfs) }

        // If 2+ animated fields, validate they match
        if allKeyframeArrays.count >= 2 {
            let referenceCount = allKeyframeArrays[0].count
            for i in 1..<allKeyframeArrays.count {
                guard allKeyframeArrays[i].count == referenceCount else {
                    return nil // Count mismatch - fail-fast
                }
            }

            // Validate time match
            for i in 0..<referenceCount {
                let refTime = allKeyframeArrays[0][i].time
                guard let rt = refTime else { return nil }
                for j in 1..<allKeyframeArrays.count {
                    guard let ot = allKeyframeArrays[j][i].time else { return nil }
                    // PR-14A: use AnimConstants.keyframeTimeEpsilon
                    guard Quantization.keyframeTimesEqual(rt, ot) else { return nil }
                }
            }
        }

        // Extract static values for non-animated fields
        let staticPosition: Vec2D?
        if !positionAnimated {
            guard let pos = extractVec2D(from: polystar.position) else { return nil }
            staticPosition = pos
        } else {
            staticPosition = nil
        }

        let staticRotation: Double?
        if !rotationAnimated {
            staticRotation = extractDouble(from: polystar.rotation) ?? 0
        } else {
            staticRotation = nil
        }

        let staticOuterRadius: Double?
        if !outerRadiusAnimated {
            guard let or = extractDouble(from: polystar.outerRadius), or > 0 else { return nil }
            staticOuterRadius = or
        } else {
            staticOuterRadius = nil
        }

        let staticInnerRadius: Double?
        if isStar && !innerRadiusAnimated {
            guard let ir = extractDouble(from: polystar.innerRadius), ir > 0 else { return nil }
            staticInnerRadius = ir
        } else {
            staticInnerRadius = nil
        }

        // Determine driver keyframes (priority: or > p > r > ir)
        let driverKeyframes: [LottieKeyframe]
        if let kfs = outerRadiusKeyframes {
            driverKeyframes = kfs
        } else if let kfs = positionKeyframes {
            driverKeyframes = kfs
        } else if let kfs = rotationKeyframes {
            driverKeyframes = kfs
        } else if let kfs = innerRadiusKeyframes {
            driverKeyframes = kfs
        } else {
            return nil // Should not happen
        }

        var keyframes: [Keyframe<BezierPath>] = []

        for (index, driverKf) in driverKeyframes.enumerated() {
            // Time is required - fail-fast if missing
            guard let time = driverKf.time else { return nil }

            // Get position at this keyframe
            let position: Vec2D
            if let posKfs = positionKeyframes {
                guard let pos = extractVec2DFromKeyframe(posKfs[index]) else { return nil }
                position = pos
            } else if let staticPos = staticPosition {
                position = staticPos
            } else {
                return nil
            }

            // Get rotation at this keyframe
            let rotationDeg: Double
            if let rotKfs = rotationKeyframes {
                guard let rot = extractDoubleFromKeyframe(rotKfs[index]) else { return nil }
                rotationDeg = rot
            } else if let staticRot = staticRotation {
                rotationDeg = staticRot
            } else {
                rotationDeg = 0
            }

            // Get outer radius at this keyframe
            let outerRadius: Double
            if let orKfs = outerRadiusKeyframes {
                guard let or = extractDoubleFromKeyframe(orKfs[index]), or > 0 else { return nil }
                outerRadius = or
            } else if let staticOr = staticOuterRadius {
                outerRadius = staticOr
            } else {
                return nil
            }

            // Get inner radius at this keyframe (only for star)
            let innerRadius: Double
            if isStar {
                if let irKfs = innerRadiusKeyframes {
                    guard let ir = extractDoubleFromKeyframe(irKfs[index]), ir > 0, ir < outerRadius else { return nil }
                    innerRadius = ir
                } else if let staticIr = staticInnerRadius {
                    guard staticIr < outerRadius else { return nil }
                    innerRadius = staticIr
                } else {
                    return nil
                }
            } else {
                innerRadius = 0
            }

            // Build bezier path for this keyframe
            let bezier = buildPolystarBezierPath(
                cx: position.x,
                cy: position.y,
                points: pointsInt,
                outerRadius: outerRadius,
                innerRadius: innerRadius,
                rotationDeg: rotationDeg,
                starType: starType,
                direction: direction
            )

            // Extract easing from driver keyframe
            let inTan = extractTangent(from: driverKf.inTangent)
            let outTan = extractTangent(from: driverKf.outTangent)
            let hold = (driverKf.hold ?? 0) == 1

            keyframes.append(Keyframe(
                time: time,
                value: bezier,
                inTangent: inTan,
                outTangent: outTan,
                hold: hold
            ))
        }

        guard !keyframes.isEmpty else { return nil }

        if keyframes.count == 1 {
            return .staticBezier(keyframes[0].value)
        }

        return .keyframedBezier(keyframes)
    }

    /// Extracts Double from a keyframe's startValue
    private static func extractDoubleFromKeyframe(_ kf: LottieKeyframe) -> Double? {
        guard let startValue = kf.startValue else { return nil }
        switch startValue {
        case .numbers(let arr) where !arr.isEmpty:
            return arr[0]
        default:
            return nil
        }
    }

    // MARK: - Path Keyframe Extraction

    /// Extracts keyframed path from LottieAnimatedValue
    /// Validates topology: all keyframes must have same vertex count and closed flag
    private static func extractKeyframedPath(from value: LottieAnimatedValue) -> AnimPath? {
        guard let data = value.value,
              case .keyframes(let lottieKeyframes) = data else {
            return nil
        }

        var keyframes: [Keyframe<BezierPath>] = []
        var expectedVertexCount: Int?
        var expectedClosed: Bool?

        for kf in lottieKeyframes {
            guard let time = kf.time else { continue }

            // Extract path data from keyframe
            guard case .path(let pathData) = kf.startValue,
                  let bezier = BezierPath(from: pathData) else {
                continue
            }

            // Validate topology matches
            if let expectedCount = expectedVertexCount {
                guard bezier.vertexCount == expectedCount else {
                    // Topology mismatch - return nil
                    return nil
                }
            } else {
                expectedVertexCount = bezier.vertexCount
            }

            if let expectedClosedFlag = expectedClosed {
                guard bezier.closed == expectedClosedFlag else {
                    // Topology mismatch - return nil
                    return nil
                }
            } else {
                expectedClosed = bezier.closed
            }

            // Extract easing tangents
            let inTan = extractTangent(from: kf.inTangent)
            let outTan = extractTangent(from: kf.outTangent)
            let hold = (kf.hold ?? 0) == 1

            keyframes.append(Keyframe(
                time: time,
                value: bezier,
                inTangent: inTan,
                outTangent: outTan,
                hold: hold
            ))
        }

        guard !keyframes.isEmpty else { return nil }

        if keyframes.count == 1 {
            return .staticBezier(keyframes[0].value)
        }

        return .keyframedBezier(keyframes)
    }

    /// Extracts easing tangent from LottieTangent
    private static func extractTangent(from tangent: LottieTangent?) -> Vec2D? {
        guard let tangent = tangent else { return nil }

        let x: Double
        let y: Double

        switch tangent.x {
        case .single(let val):
            x = val
        case .array(let arr) where !arr.isEmpty:
            x = arr[0]
        default:
            x = 0
        }

        switch tangent.y {
        case .single(let val):
            y = val
        case .array(let arr) where !arr.isEmpty:
            y = arr[0]
        default:
            y = 0
        }

        return Vec2D(x: x, y: y)
    }

    // MARK: - Group Transform Extraction (PR-11)

    /// Extracts list of GroupTransforms from shape layer shapes (transform stack)
    /// Only collects transforms along the branch where the FIRST path is found.
    /// Uses DFS with push/pop to ensure only ancestor transforms are included.
    /// - Parameter shapes: Array of shape items to search
    /// - Returns: Array of GroupTransform along path's branch, empty if path at root, nil if extraction fails
    public static func extractGroupTransforms(from shapes: [ShapeItem]?) -> [GroupTransform]? {
        guard let shapes = shapes else { return [] }

        var transformStack: [GroupTransform] = []

        switch collectTransformsToFirstPath(items: shapes, stack: &transformStack) {
        case .found:
            return transformStack
        case .notFound:
            return [] // No path found, return empty (valid case)
        case .failed:
            return nil // Invalid transform data
        }
    }

    /// Result of searching for first path
    private enum PathSearchResult {
        case found      // Path found, stack contains ancestor transforms
        case notFound   // No path in this branch
        case failed     // Invalid transform data (multiple tr, skew, etc.)
    }

    /// DFS search for first path, collecting only ancestor transforms
    /// - Parameters:
    ///   - items: Shape items to search
    ///   - stack: Transform stack (push on enter group, pop on backtrack)
    /// - Returns: PathSearchResult indicating whether path was found or error occurred
    private static func collectTransformsToFirstPath(
        items: [ShapeItem],
        stack: inout [GroupTransform]
    ) -> PathSearchResult {
        for item in items {
            switch item {
            // Path-producing items - first path found!
            case .path, .rect, .ellipse, .polystar:
                return .found

            case .group(let shapeGroup):
                guard let childItems = shapeGroup.items else { continue }

                // 1) Extract transform from this group (if any)
                let pushResult = tryPushTransform(from: childItems, stack: &stack)
                switch pushResult {
                case .failed:
                    return .failed // Invalid transform (multiple tr, skew, non-uniform scale, etc.)
                case .pushed, .noPush:
                    break
                }
                let didPush = (pushResult == .pushed)

                // 2) Recursively search for path in this group
                let childResult = collectTransformsToFirstPath(items: childItems, stack: &stack)

                switch childResult {
                case .found:
                    // Path found in this branch - keep transforms and return
                    return .found
                case .failed:
                    // Propagate failure
                    return .failed
                case .notFound:
                    // No path in this branch - backtrack (pop transform)
                    if didPush {
                        stack.removeLast()
                    }
                    // Continue searching siblings
                }

            default:
                // Fill, stroke, trim, etc. - skip
                continue
            }
        }

        // No path found in any item
        return .notFound
    }

    /// Result of trying to push a transform
    private enum PushResult {
        case pushed   // Transform was pushed to stack
        case noPush   // No transform in this group
        case failed   // Invalid transform data
    }

    /// Tries to extract and push transform from group items
    /// - Parameters:
    ///   - items: Items in the group
    ///   - stack: Transform stack to push to
    /// - Returns: PushResult indicating what happened
    private static func tryPushTransform(
        from items: [ShapeItem],
        stack: inout [GroupTransform]
    ) -> PushResult {
        // Find transform items in this group
        let transformItems = items.compactMap { item -> LottieShapeTransform? in
            if case .transform(let transform) = item { return transform }
            return nil
        }

        // Fail-fast: multiple tr items
        if transformItems.count > 1 {
            return .failed
        }

        // No transform in this group
        guard let tr = transformItems.first else {
            return .noPush
        }

        // Build and validate transform
        guard let groupTransform = buildGroupTransform(from: tr) else {
            return .failed // Invalid transform (skew, non-uniform scale, etc.)
        }

        stack.append(groupTransform)
        return .pushed
    }

    /// Builds GroupTransform from LottieShapeTransform with AnimTracks
    /// Fail-fast validation:
    /// - Skew present (sk != 0 or sk.a == 1) → nil
    /// - Non-uniform scale (sx != sy for static, or any keyframe with sx != sy) → nil
    /// - If field present but cannot be parsed → nil (no fallback defaults)
    /// - Parameter transform: Lottie shape transform
    /// - Returns: GroupTransform with tracks (static or animated), or nil if invalid
    private static func buildGroupTransform(from transform: LottieShapeTransform) -> GroupTransform? {
        // Fail-fast: skew must be absent or zero
        if let skew = transform.skew {
            if skew.isAnimated {
                return nil // Animated skew not supported
            }
            // PR-14A: use AnimConstants.nearlyEqualEpsilon
            if let skewValue = extractDouble(from: skew), !Quantization.isNearlyZero(skewValue) {
                return nil // Non-zero skew not supported
            }
        }

        // Extract position track
        let positionTrack: AnimTrack<Vec2D>
        if let pos = transform.position {
            if pos.isAnimated {
                guard let track = extractAnimatedVec2D(from: pos) else {
                    return nil // Fail-fast: invalid animated position
                }
                positionTrack = track
            } else {
                // Field present but not animated - must parse successfully
                guard let vec = extractVec2D(from: pos) else {
                    return nil // Fail-fast: field present but unparseable
                }
                positionTrack = .static(vec)
            }
        } else {
            // Field absent - use default
            positionTrack = .static(Vec2D(x: 0, y: 0))
        }

        // Extract anchor track
        let anchorTrack: AnimTrack<Vec2D>
        if let anc = transform.anchor {
            if anc.isAnimated {
                guard let track = extractAnimatedVec2D(from: anc) else {
                    return nil // Fail-fast: invalid animated anchor
                }
                anchorTrack = track
            } else {
                guard let vec = extractVec2D(from: anc) else {
                    return nil // Fail-fast: field present but unparseable
                }
                anchorTrack = .static(vec)
            }
        } else {
            anchorTrack = .static(Vec2D(x: 0, y: 0))
        }

        // Extract scale track with uniform scale validation
        let scaleTrack: AnimTrack<Vec2D>
        if let scl = transform.scale {
            if scl.isAnimated {
                guard let track = extractAnimatedVec2DUniformScale(from: scl) else {
                    return nil // Fail-fast: invalid or non-uniform animated scale
                }
                scaleTrack = track
            } else {
                guard let vec = extractVec2D(from: scl) else {
                    return nil // Fail-fast: field present but unparseable
                }
                // Validate uniform scale (sx == sy) - PR-14A: use AnimConstants.nearlyEqualEpsilon
                guard Quantization.isNearlyEqual(vec.x, vec.y) else {
                    return nil // Fail-fast: non-uniform scale
                }
                scaleTrack = .static(vec)
            }
        } else {
            scaleTrack = .static(Vec2D(x: 100, y: 100))
        }

        // Extract rotation track
        let rotationTrack: AnimTrack<Double>
        if let rot = transform.rotation {
            if rot.isAnimated {
                guard let track = extractAnimatedDouble(from: rot) else {
                    return nil // Fail-fast: invalid animated rotation
                }
                rotationTrack = track
            } else {
                guard let val = extractDouble(from: rot) else {
                    return nil // Fail-fast: field present but unparseable
                }
                rotationTrack = .static(val)
            }
        } else {
            rotationTrack = .static(0)
        }

        // Extract opacity track (normalize from 0-100 to 0-1)
        let opacityTrack: AnimTrack<Double>
        if let opa = transform.opacity {
            if opa.isAnimated {
                guard let track = extractAnimatedDouble(from: opa) else {
                    return nil // Fail-fast: invalid animated opacity
                }
                // Normalize keyframes from 0-100 to 0-1
                switch track {
                case .keyframed(let kfs):
                    let normalizedKeyframes = kfs.map { kf in
                        Keyframe(time: kf.time, value: kf.value / 100.0)
                    }
                    opacityTrack = .keyframed(normalizedKeyframes)
                case .static(let val):
                    opacityTrack = .static(val / 100.0)
                }
            } else {
                guard let rawOpacity = extractDouble(from: opa) else {
                    return nil // Fail-fast: field present but unparseable
                }
                opacityTrack = .static(rawOpacity / 100.0)
            }
        } else {
            opacityTrack = .static(1.0)
        }

        return GroupTransform(
            position: positionTrack,
            anchor: anchorTrack,
            scale: scaleTrack,
            rotation: rotationTrack,
            opacity: opacityTrack
        )
    }

    /// Extracts animated Vec2D track with uniform scale validation
    /// Returns nil if any keyframe has non-uniform scale (x != y)
    private static func extractAnimatedVec2DUniformScale(from value: LottieAnimatedValue) -> AnimTrack<Vec2D>? {
        guard let data = value.value,
              case .keyframes(let lottieKeyframes) = data else {
            return nil
        }
        guard !lottieKeyframes.isEmpty else { return nil }

        var keyframes: [Keyframe<Vec2D>] = []

        for kf in lottieKeyframes {
            guard let time = kf.time else { return nil }
            guard let startValue = kf.startValue else { return nil }

            let vec: Vec2D
            switch startValue {
            case .numbers(let arr) where arr.count >= 2:
                vec = Vec2D(x: arr[0], y: arr[1])
            default:
                return nil
            }

            // Validate uniform scale - PR-14A: use AnimConstants.nearlyEqualEpsilon
            guard Quantization.isNearlyEqual(vec.x, vec.y) else {
                return nil // Non-uniform scale in keyframe
            }

            keyframes.append(Keyframe(time: time, value: vec))
        }

        return .keyframed(keyframes)
    }

    /// Extracts animated Vec2D track from LottieAnimatedValue
    /// Fail-fast: returns nil if any keyframe is invalid
    private static func extractAnimatedVec2D(from value: LottieAnimatedValue) -> AnimTrack<Vec2D>? {
        guard let data = value.value,
              case .keyframes(let lottieKeyframes) = data else {
            return nil
        }
        guard !lottieKeyframes.isEmpty else { return nil }

        var keyframes: [Keyframe<Vec2D>] = []

        for kf in lottieKeyframes {
            // Fail-fast: missing time
            guard let time = kf.time else { return nil }

            // Fail-fast: missing startValue
            guard let startValue = kf.startValue else { return nil }

            // Extract Vec2D from startValue
            let vec: Vec2D
            switch startValue {
            case .numbers(let arr) where arr.count >= 2:
                vec = Vec2D(x: arr[0], y: arr[1])
            default:
                return nil // Fail-fast: invalid format
            }

            keyframes.append(Keyframe(time: time, value: vec))
        }

        return .keyframed(keyframes)
    }

    /// Extracts animated Double track from LottieAnimatedValue
    /// Fail-fast: returns nil if any keyframe is invalid
    private static func extractAnimatedDouble(from value: LottieAnimatedValue) -> AnimTrack<Double>? {
        guard let data = value.value,
              case .keyframes(let lottieKeyframes) = data else {
            return nil
        }
        guard !lottieKeyframes.isEmpty else { return nil }

        var keyframes: [Keyframe<Double>] = []

        for kf in lottieKeyframes {
            // Fail-fast: missing time
            guard let time = kf.time else { return nil }

            // Fail-fast: missing startValue
            guard let startValue = kf.startValue else { return nil }

            // Extract Double from startValue
            let doubleValue: Double
            switch startValue {
            case .numbers(let arr) where !arr.isEmpty:
                doubleValue = arr[0]
            default:
                return nil // Fail-fast: invalid format
            }

            keyframes.append(Keyframe(time: time, value: doubleValue))
        }

        return .keyframed(keyframes)
    }

    /// Extracts Vec2D from LottieAnimatedValue (static only)
    private static func extractVec2D(from value: LottieAnimatedValue?) -> Vec2D? {
        guard let value = value, let data = value.value else { return nil }
        switch data {
        case .array(let arr) where arr.count >= 2:
            return Vec2D(x: arr[0], y: arr[1])
        default:
            return nil
        }
    }

    /// Extracts Double from LottieAnimatedValue (static only)
    private static func extractDouble(from value: LottieAnimatedValue?) -> Double? {
        guard let value = value, let data = value.value else { return nil }
        switch data {
        case .number(let num):
            return num
        case .array(let arr) where !arr.isEmpty:
            return arr[0]
        default:
            return nil
        }
    }

    /// Extracts fill color from shape layer shapes
    public static func extractFillColor(from shapes: [ShapeItem]?) -> [Double]? {
        guard let shapes = shapes else { return nil }

        for shape in shapes {
            if let color = extractFillFromShape(shape) {
                return color
            }
        }
        return nil
    }

    private static func extractFillFromShape(_ shape: ShapeItem) -> [Double]? {
        switch shape {
        case .fill(let fill):
            // Fill shape - extract color
            guard let colorValue = fill.color,
                  let data = colorValue.value,
                  case .array(let arr) = data else {
                return nil
            }
            return arr

        case .group(let shapeGroup):
            // Group - recurse into items
            guard let items = shapeGroup.items else { return nil }
            return extractFillColor(from: items)

        default:
            return nil
        }
    }

    /// Extracts fill opacity from shape layer shapes
    public static func extractFillOpacity(from shapes: [ShapeItem]?) -> Double {
        guard let shapes = shapes else { return 100 }

        for shape in shapes {
            if let opacity = extractFillOpacityFromShape(shape) {
                return opacity
            }
        }
        return 100
    }

    private static func extractFillOpacityFromShape(_ shape: ShapeItem) -> Double? {
        switch shape {
        case .fill(let fill):
            // Fill shape - extract opacity
            guard let opacityValue = fill.opacity,
                  let data = opacityValue.value else {
                return nil
            }
            switch data {
            case .number(let num):
                return num
            case .array(let arr) where !arr.isEmpty:
                return arr[0]
            default:
                return nil
            }

        case .group(let shapeGroup):
            // Group - recurse into items
            guard let items = shapeGroup.items else { return nil }
            return extractFillOpacity(from: items)

        default:
            return nil
        }
    }

    // MARK: - Stroke Extraction (PR-10)

    /// Maximum allowed stroke width to prevent pathological input (synced with validator)
    private static let maxStrokeWidth: Double = 2048

    /// Extracts stroke style from shape layer shapes
    /// - Parameter shapes: Array of shape items to search
    /// - Returns: StrokeStyle or nil if no valid stroke found
    public static func extractStrokeStyle(from shapes: [ShapeItem]?) -> StrokeStyle? {
        guard let shapes = shapes else { return nil }

        for shape in shapes {
            if let stroke = extractStrokeFromShape(shape) {
                return stroke
            }
        }
        return nil
    }

    private static func extractStrokeFromShape(_ shape: ShapeItem) -> StrokeStyle? {
        switch shape {
        case .stroke(let stroke):
            // Stroke shape - extract style
            return buildStrokeStyle(from: stroke)

        case .group(let shapeGroup):
            // Group - recurse into items
            guard let items = shapeGroup.items else { return nil }
            return extractStrokeStyle(from: items)

        default:
            return nil
        }
    }

    /// Builds StrokeStyle from LottieShapeStroke
    /// Returns nil if:
    /// - dash is present (not supported in PR-10)
    /// - color is animated (not supported in PR-10)
    /// - opacity is animated (not supported in PR-10)
    /// - width is missing, <= 0, or > MAX_STROKE_WIDTH
    /// - lineCap/lineJoin is invalid
    /// - miterLimit <= 0
    private static func buildStrokeStyle(from stroke: LottieShapeStroke) -> StrokeStyle? {
        // 1) Dash must be absent or empty
        if let dash = stroke.dash, !dash.isEmpty {
            return nil
        }

        // 2) Color must be static
        if stroke.color?.isAnimated == true {
            return nil
        }

        // Extract color (default to white if not present)
        let color: [Double]
        if let colorValue = stroke.color,
           let data = colorValue.value,
           case .array(let arr) = data,
           arr.count >= 3 {
            color = Array(arr.prefix(3))
        } else {
            color = [1, 1, 1] // Default white
        }

        // 3) Opacity must be static
        if stroke.opacity?.isAnimated == true {
            return nil
        }

        // Extract opacity (default to 100, convert to 0...1)
        let opacity: Double
        if let opacityValue = stroke.opacity,
           let opacityNum = extractDouble(from: opacityValue) {
            opacity = opacityNum / 100.0
        } else {
            opacity = 1.0 // Default fully opaque
        }

        // 4) Width must exist and be valid
        guard let widthValue = stroke.width else {
            return nil
        }

        let width: AnimTrack<Double>
        if widthValue.isAnimated {
            // Extract animated width
            guard let animWidth = extractAnimatedWidth(from: widthValue) else {
                return nil
            }
            width = animWidth
        } else {
            // Extract static width
            guard let staticWidth = extractDouble(from: widthValue),
                  staticWidth > 0, staticWidth <= maxStrokeWidth else {
                return nil
            }
            width = .static(staticWidth)
        }

        // 5) LineCap (default: 2 = round)
        let lineCap = stroke.lineCap ?? 2
        guard lineCap >= 1 && lineCap <= 3 else {
            return nil
        }

        // 6) LineJoin (default: 2 = round)
        let lineJoin = stroke.lineJoin ?? 2
        guard lineJoin >= 1 && lineJoin <= 3 else {
            return nil
        }

        // 7) MiterLimit (default: 4.0)
        let miterLimit = stroke.miterLimit ?? 4.0
        guard miterLimit > 0 else {
            return nil
        }

        return StrokeStyle(
            color: color,
            opacity: opacity,
            width: width,
            lineCap: lineCap,
            lineJoin: lineJoin,
            miterLimit: miterLimit
        )
    }

    /// Extracts animated width track from LottieAnimatedValue.
    /// Fail-fast: returns nil if any keyframe is invalid (missing time, startValue, or invalid format)
    private static func extractAnimatedWidth(from value: LottieAnimatedValue) -> AnimTrack<Double>? {
        // If marked as animated but data is not keyframes → fail-fast
        guard let data = value.value,
              case .keyframes(let lottieKeyframes) = data else {
            return nil
        }

        // Empty keyframes array → fail-fast
        guard !lottieKeyframes.isEmpty else { return nil }

        var keyframes: [Keyframe<Double>] = []

        for kf in lottieKeyframes {
            // Missing time → fail-fast (no continue!)
            guard let time = kf.time else { return nil }

            // Missing startValue → fail-fast (no continue!)
            guard let startValue = kf.startValue else { return nil }

            // Extract width value from keyframe - invalid format → fail-fast (no continue!)
            let widthValue: Double
            switch startValue {
            case .numbers(let arr) where !arr.isEmpty:
                widthValue = arr[0]
            default:
                return nil // Invalid format - fail-fast
            }

            // Validate width bounds
            guard widthValue > 0, widthValue <= maxStrokeWidth else {
                return nil // Invalid width in keyframe - fail-fast
            }

            // Extract easing tangents
            let inTan = extractTangent(from: kf.inTangent)
            let outTan = extractTangent(from: kf.outTangent)
            let hold = (kf.hold ?? 0) == 1

            keyframes.append(Keyframe(
                time: time,
                value: widthValue,
                inTangent: inTan,
                outTangent: outTan,
                hold: hold
            ))
        }

        // Should never be empty at this point (checked lottieKeyframes above),
        // but defensive check anyway
        guard !keyframes.isEmpty else { return nil }

        if keyframes.count == 1 {
            return .static(keyframes[0].value)
        }

        return .keyframed(keyframes)
    }
}
