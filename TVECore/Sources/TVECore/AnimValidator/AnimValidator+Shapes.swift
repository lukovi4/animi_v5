import Foundation

// MARK: - Shape Validation

extension AnimValidator {
    func validateShapes(
        shapes: [ShapeItem],
        layerIndex: Int,
        context: String,
        animRef: String,
        issues: inout [ValidationIssue]
    ) {
        for (shapeIndex, shape) in shapes.enumerated() {
            let basePath = "anim(\(animRef)).\(context)[\(layerIndex)].shapes[\(shapeIndex)]"
            validateShapeItemRecursive(
                shape: shape,
                basePath: basePath,
                issues: &issues
            )
        }
    }

    /// Recursively validates a shape item and its children.
    /// - Parameters:
    ///   - shape: The shape item to validate
    ///   - basePath: Full path to this shape item (e.g., "anim(ref).layers[0].shapes[0]" or "anim(ref).layers[0].shapes[0].it[1]")
    ///   - issues: Collection to append validation issues to
    private func validateShapeItemRecursive(
        shape: ShapeItem,
        basePath: String,
        issues: inout [ValidationIssue]
    ) {
        switch shape {
        case .group(let shapeGroup):
            // PR-11: Validate group transform (tr inside gr)
            if let items = shapeGroup.items {
                validateGroupTransform(items: items, basePath: basePath, issues: &issues)

                // Recursively validate group items
                for (itemIndex, item) in items.enumerated() {
                    validateShapeItemRecursive(
                        shape: item,
                        basePath: "\(basePath).it[\(itemIndex)]",
                        issues: &issues
                    )
                }
            }

        case .path(let shapePath):
            // Validate animated path topology if animated paths are allowed
            if let pathValue = shapePath.vertices, pathValue.isAnimated {
                if !options.allowAnimatedMaskPath {
                    issues.append(ValidationIssue(
                        code: AnimValidationCode.unsupportedMaskPathAnimated,
                        severity: .error,
                        path: "\(basePath).ks.a",
                        message: "Animated shape paths not supported in Part 1"
                    ))
                } else {
                    validatePathTopology(
                        path: pathValue,
                        basePath: "\(basePath).ks",
                        issues: &issues
                    )
                }
            }

        case .fill:
            // Fill shape is supported, no validation issues
            break

        case .transform:
            // Transform shape is supported, no validation issues
            break

        case .rect(let rect):
            // Rectangle shape is supported (PR-07)
            // Validate that animated roundness is not used (not supported yet)
            if let roundness = rect.roundness, roundness.isAnimated {
                issues.append(ValidationIssue(
                    code: AnimValidationCode.unsupportedRectRoundnessAnimated,
                    severity: .error,
                    path: "\(basePath).r.a",
                    message: "Animated rectangle roundness not supported. Use static roundness value."
                ))
            }

            // Validate animated p/s keyframes consistency
            validateRectKeyframes(rect: rect, basePath: basePath, issues: &issues)

        case .ellipse(let ellipse):
            // Ellipse shape is supported (PR-08)
            // Validate animated p/s keyframes consistency and size validity
            validateEllipseKeyframes(ellipse: ellipse, basePath: basePath, issues: &issues)

        case .polystar(let polystar):
            // Polystar shape is supported (PR-09)
            // Validate star type, points, roundness, radii, and keyframe consistency
            validatePolystarKeyframes(polystar: polystar, basePath: basePath, issues: &issues)

        case .stroke(let stroke):
            // Stroke shape is supported (PR-10)
            // Validate dash, color, opacity, width, lineCap, lineJoin, miterLimit
            validateStroke(stroke: stroke, basePath: basePath, issues: &issues)

        case .unknown(let type):
            // PR-13: Trim Paths (tm) - explicit unsupported error with specific code
            if type == "tm" {
                issues.append(ValidationIssue(
                    code: AnimValidationCode.unsupportedTrimPaths,
                    severity: .error,
                    path: "\(basePath).ty",
                    message: "Trim Paths (ty:'tm') not supported. Remove it or bake the effect in After Effects."
                ))
            } else {
                // Other unknown shape types - generic unsupported error
                issues.append(ValidationIssue(
                    code: AnimValidationCode.unsupportedShapeItem,
                    severity: .error,
                    path: "\(basePath).ty",
                    message: "Shape type '\(type)' not supported. Supported: gr, sh, fl, tr, rc, el, sr, st"
                ))
            }
        }
    }

    /// Validates rectangle position/size keyframes for consistency
    /// - If both p and s are animated, they must have matching keyframe count and times
    /// - Each keyframe must have valid time and startValue
    private func validateRectKeyframes(
        rect: LottieShapeRect,
        basePath: String,
        issues: inout [ValidationIssue]
    ) {
        let positionAnimated = rect.position?.isAnimated ?? false
        let sizeAnimated = rect.size?.isAnimated ?? false

        // If neither is animated, no keyframe validation needed
        guard positionAnimated || sizeAnimated else { return }

        // Extract keyframes
        var positionKeyframes: [LottieKeyframe]?
        var sizeKeyframes: [LottieKeyframe]?

        if positionAnimated {
            if let posValue = rect.position,
               let posData = posValue.value,
               case .keyframes(let kfs) = posData {
                positionKeyframes = kfs
            }
        }

        if sizeAnimated {
            if let sizeValue = rect.size,
               let sizeData = sizeValue.value,
               case .keyframes(let kfs) = sizeData {
                sizeKeyframes = kfs
            }
        }

        // ⚠️ FAIL-FAST: If animated but keyframes couldn't be extracted, report error
        if positionAnimated && positionKeyframes == nil {
            issues.append(ValidationIssue(
                code: AnimValidationCode.unsupportedRectKeyframeFormat,
                severity: .error,
                path: "\(basePath).p",
                message: "Rectangle position is animated but keyframes could not be decoded."
            ))
        }

        if sizeAnimated && sizeKeyframes == nil {
            issues.append(ValidationIssue(
                code: AnimValidationCode.unsupportedRectKeyframeFormat,
                severity: .error,
                path: "\(basePath).s",
                message: "Rectangle size is animated but keyframes could not be decoded."
            ))
        }

        // If both animated, validate consistency
        if let posKfs = positionKeyframes, let sizeKfs = sizeKeyframes {
            // Check count match
            if posKfs.count != sizeKfs.count {
                issues.append(ValidationIssue(
                    code: AnimValidationCode.unsupportedRectKeyframesMismatch,
                    severity: .error,
                    path: "\(basePath)",
                    message: "Rectangle position has \(posKfs.count) keyframes but size has \(sizeKfs.count). Both must have same count."
                ))
                return // Don't check times if counts differ
            }

            // Check time match for each keyframe
            for i in 0..<posKfs.count {
                let posTime = posKfs[i].time
                let sizeTime = sizeKfs[i].time

                // Both must have time
                if posTime == nil || sizeTime == nil {
                    issues.append(ValidationIssue(
                        code: AnimValidationCode.unsupportedRectKeyframeFormat,
                        severity: .error,
                        path: "\(basePath)",
                        message: "Rectangle keyframe[\(i)] missing time value."
                    ))
                    continue
                }

                // Times must match
                if let pt = posTime, let st = sizeTime, abs(pt - st) >= 0.001 {
                    issues.append(ValidationIssue(
                        code: AnimValidationCode.unsupportedRectKeyframesMismatch,
                        severity: .error,
                        path: "\(basePath)",
                        message: "Rectangle keyframe[\(i)] time mismatch: position.t=\(pt), size.t=\(st)."
                    ))
                }
            }
        }

        // Validate individual keyframe format for driver (whichever is animated)
        let driverKeyframes = sizeKeyframes ?? positionKeyframes
        let driverName = sizeKeyframes != nil ? "size" : "position"

        if let kfs = driverKeyframes {
            for (i, kf) in kfs.enumerated() {
                // Check time exists
                if kf.time == nil {
                    issues.append(ValidationIssue(
                        code: AnimValidationCode.unsupportedRectKeyframeFormat,
                        severity: .error,
                        path: "\(basePath).\(driverName == "size" ? "s" : "p").k[\(i)]",
                        message: "Rectangle \(driverName) keyframe[\(i)] missing time (t)."
                    ))
                }

                // Check startValue exists and is valid Vec2D format
                if let startValue = kf.startValue {
                    switch startValue {
                    case .numbers(let arr) where arr.count >= 2:
                        break // Valid
                    default:
                        issues.append(ValidationIssue(
                            code: AnimValidationCode.unsupportedRectKeyframeFormat,
                            severity: .error,
                            path: "\(basePath).\(driverName == "size" ? "s" : "p").k[\(i)].s",
                            message: "Rectangle \(driverName) keyframe[\(i)] has invalid startValue format. Expected [x, y] array."
                        ))
                    }
                } else {
                    issues.append(ValidationIssue(
                        code: AnimValidationCode.unsupportedRectKeyframeFormat,
                        severity: .error,
                        path: "\(basePath).\(driverName == "size" ? "s" : "p").k[\(i)].s",
                        message: "Rectangle \(driverName) keyframe[\(i)] missing startValue (s)."
                    ))
                }
            }
        }
    }

    /// Validates ellipse position/size keyframes for consistency and size validity
    /// - If both p and s are animated, they must have matching keyframe count and times
    /// - Each keyframe must have valid time and startValue
    /// - Size values must be positive (w > 0 && h > 0)
    private func validateEllipseKeyframes(
        ellipse: LottieShapeEllipse,
        basePath: String,
        issues: inout [ValidationIssue]
    ) {
        let positionAnimated = ellipse.position?.isAnimated ?? false
        let sizeAnimated = ellipse.size?.isAnimated ?? false

        // Validate static size if not animated
        if !sizeAnimated {
            if let sizeValue = ellipse.size,
               let sizeData = sizeValue.value,
               case .array(let arr) = sizeData,
               arr.count >= 2 {
                let width = arr[0]
                let height = arr[1]
                if width <= 0 || height <= 0 {
                    issues.append(ValidationIssue(
                        code: AnimValidationCode.unsupportedEllipseInvalidSize,
                        severity: .error,
                        path: "\(basePath).s.k",
                        message: "Ellipse has invalid size: width=\(width), height=\(height). Both must be > 0."
                    ))
                }
            }
        }

        // If neither is animated, no keyframe validation needed
        guard positionAnimated || sizeAnimated else { return }

        // Extract keyframes
        var positionKeyframes: [LottieKeyframe]?
        var sizeKeyframes: [LottieKeyframe]?

        if positionAnimated {
            if let posValue = ellipse.position,
               let posData = posValue.value,
               case .keyframes(let kfs) = posData {
                positionKeyframes = kfs
            }
        }

        if sizeAnimated {
            if let sizeValue = ellipse.size,
               let sizeData = sizeValue.value,
               case .keyframes(let kfs) = sizeData {
                sizeKeyframes = kfs
            }
        }

        // FAIL-FAST: If animated but keyframes couldn't be extracted, report error
        if positionAnimated && positionKeyframes == nil {
            issues.append(ValidationIssue(
                code: AnimValidationCode.unsupportedEllipseKeyframeFormat,
                severity: .error,
                path: "\(basePath).p",
                message: "Ellipse position is animated but keyframes could not be decoded."
            ))
        }

        if sizeAnimated && sizeKeyframes == nil {
            issues.append(ValidationIssue(
                code: AnimValidationCode.unsupportedEllipseKeyframeFormat,
                severity: .error,
                path: "\(basePath).s",
                message: "Ellipse size is animated but keyframes could not be decoded."
            ))
        }

        // If both animated, validate consistency
        if let posKfs = positionKeyframes, let sizeKfs = sizeKeyframes {
            // Check count match
            if posKfs.count != sizeKfs.count {
                issues.append(ValidationIssue(
                    code: AnimValidationCode.unsupportedEllipseKeyframesMismatch,
                    severity: .error,
                    path: "\(basePath)",
                    message: "Ellipse position has \(posKfs.count) keyframes but size has \(sizeKfs.count). Both must have same count."
                ))
                return // Don't check times if counts differ
            }

            // Check time match for each keyframe
            for i in 0..<posKfs.count {
                let posTime = posKfs[i].time
                let sizeTime = sizeKfs[i].time

                // Both must have time
                if posTime == nil || sizeTime == nil {
                    issues.append(ValidationIssue(
                        code: AnimValidationCode.unsupportedEllipseKeyframeFormat,
                        severity: .error,
                        path: "\(basePath)",
                        message: "Ellipse keyframe[\(i)] missing time value."
                    ))
                    continue
                }

                // Times must match
                if let pt = posTime, let st = sizeTime, abs(pt - st) >= 0.001 {
                    issues.append(ValidationIssue(
                        code: AnimValidationCode.unsupportedEllipseKeyframesMismatch,
                        severity: .error,
                        path: "\(basePath)",
                        message: "Ellipse keyframe[\(i)] time mismatch: position.t=\(pt), size.t=\(st)."
                    ))
                }
            }
        }

        // Validate individual keyframe format for driver (whichever is animated)
        let driverKeyframes = sizeKeyframes ?? positionKeyframes
        let driverName = sizeKeyframes != nil ? "size" : "position"

        if let kfs = driverKeyframes {
            for (i, kf) in kfs.enumerated() {
                // Check time exists
                if kf.time == nil {
                    issues.append(ValidationIssue(
                        code: AnimValidationCode.unsupportedEllipseKeyframeFormat,
                        severity: .error,
                        path: "\(basePath).\(driverName == "size" ? "s" : "p").k[\(i)]",
                        message: "Ellipse \(driverName) keyframe[\(i)] missing time (t)."
                    ))
                }

                // Check startValue exists and is valid Vec2D format
                if let startValue = kf.startValue {
                    switch startValue {
                    case .numbers(let arr) where arr.count >= 2:
                        // For size keyframes, validate that values are positive
                        if driverName == "size" {
                            let width = arr[0]
                            let height = arr[1]
                            if width <= 0 || height <= 0 {
                                issues.append(ValidationIssue(
                                    code: AnimValidationCode.unsupportedEllipseInvalidSize,
                                    severity: .error,
                                    path: "\(basePath).s.k[\(i)].s",
                                    message: "Ellipse size keyframe[\(i)] has invalid size: width=\(width), height=\(height). Both must be > 0."
                                ))
                            }
                        }
                    default:
                        issues.append(ValidationIssue(
                            code: AnimValidationCode.unsupportedEllipseKeyframeFormat,
                            severity: .error,
                            path: "\(basePath).\(driverName == "size" ? "s" : "p").k[\(i)].s",
                            message: "Ellipse \(driverName) keyframe[\(i)] has invalid startValue format. Expected [x, y] array."
                        ))
                    }
                } else {
                    issues.append(ValidationIssue(
                        code: AnimValidationCode.unsupportedEllipseKeyframeFormat,
                        severity: .error,
                        path: "\(basePath).\(driverName == "size" ? "s" : "p").k[\(i)].s",
                        message: "Ellipse \(driverName) keyframe[\(i)] missing startValue (s)."
                    ))
                }
            }
        }
    }

    // MARK: - Polystar Validation

    /// Maximum allowed points for polystar (to prevent excessive vertex count)
    private static let maxPolystarPoints = 100

    /// Validates polystar shape parameters and keyframe consistency
    /// - Star type must be 1 (star) or 2 (polygon)
    /// - Points must be static, integer, >= 3, <= 100
    /// - Roundness (is/os) must be static and zero
    /// - Radii must be valid (or > 0, for star: ir > 0 and ir < or)
    /// - Animated keyframes must have matching count and times
    private func validatePolystarKeyframes(
        polystar: LottieShapePolystar,
        basePath: String,
        issues: inout [ValidationIssue]
    ) {
        // 1) Validate star type (sy)
        guard let starType = polystar.starType, (starType == 1 || starType == 2) else {
            issues.append(ValidationIssue(
                code: AnimValidationCode.unsupportedPolystarStarType,
                severity: .error,
                path: "\(basePath).sy",
                message: "Polystar has invalid star type: \(polystar.starType ?? -1). Must be 1 (star) or 2 (polygon)."
            ))
            return // Can't validate further without valid star type
        }

        let isStar = starType == 1

        // 2) Validate points (pt) - must be static
        if let points = polystar.points {
            if points.isAnimated {
                issues.append(ValidationIssue(
                    code: AnimValidationCode.unsupportedPolystarPointsAnimated,
                    severity: .error,
                    path: "\(basePath).pt.a",
                    message: "Polystar points animation not supported. Topology would change between keyframes."
                ))
            } else {
                // Extract static points value
                if let pointsData = points.value {
                    let pointsValue: Double?
                    switch pointsData {
                    case .number(let num):
                        pointsValue = num
                    case .array(let arr) where !arr.isEmpty:
                        pointsValue = arr[0]
                    default:
                        pointsValue = nil
                    }

                    if let pv = pointsValue {
                        // Check if integer
                        if pv != pv.rounded() {
                            issues.append(ValidationIssue(
                                code: AnimValidationCode.unsupportedPolystarPointsNonInteger,
                                severity: .error,
                                path: "\(basePath).pt.k",
                                message: "Polystar points must be an integer. Got: \(pv)."
                            ))
                        } else {
                            let intPoints = Int(pv)
                            if intPoints < 3 || intPoints > Self.maxPolystarPoints {
                                issues.append(ValidationIssue(
                                    code: AnimValidationCode.unsupportedPolystarPointsInvalid,
                                    severity: .error,
                                    path: "\(basePath).pt.k",
                                    message: "Polystar points must be between 3 and \(Self.maxPolystarPoints). Got: \(intPoints)."
                                ))
                            }
                        }
                    } else {
                        issues.append(ValidationIssue(
                            code: AnimValidationCode.unsupportedPolystarPointsFormat,
                            severity: .error,
                            path: "\(basePath).pt.k",
                            message: "Polystar points has invalid format. Expected a number."
                        ))
                    }
                }
            }
        }

        // 3) Validate roundness (is/os) - must be static and zero
        validatePolystarRoundness(
            value: polystar.innerRoundness,
            fieldName: "innerRoundness",
            fieldPath: "is",
            basePath: basePath,
            issues: &issues
        )
        validatePolystarRoundness(
            value: polystar.outerRoundness,
            fieldName: "outerRoundness",
            fieldPath: "os",
            basePath: basePath,
            issues: &issues
        )

        // 4) Validate radii - extract static values for validation
        let outerRadiusAnimated = polystar.outerRadius?.isAnimated ?? false
        let innerRadiusAnimated = polystar.innerRadius?.isAnimated ?? false

        // Validate static outer radius
        if !outerRadiusAnimated {
            if let orValue = extractStaticDouble(from: polystar.outerRadius) {
                if orValue <= 0 {
                    issues.append(ValidationIssue(
                        code: AnimValidationCode.unsupportedPolystarInvalidRadius,
                        severity: .error,
                        path: "\(basePath).or.k",
                        message: "Polystar outer radius must be > 0. Got: \(orValue)."
                    ))
                }
            }
        }

        // Validate static inner radius (only for star)
        if isStar && !innerRadiusAnimated {
            if let irValue = extractStaticDouble(from: polystar.innerRadius) {
                if irValue <= 0 {
                    issues.append(ValidationIssue(
                        code: AnimValidationCode.unsupportedPolystarInvalidRadius,
                        severity: .error,
                        path: "\(basePath).ir.k",
                        message: "Polystar inner radius must be > 0. Got: \(irValue)."
                    ))
                }
                // Check ir < or if both static
                if !outerRadiusAnimated, let orValue = extractStaticDouble(from: polystar.outerRadius) {
                    if irValue >= orValue {
                        issues.append(ValidationIssue(
                            code: AnimValidationCode.unsupportedPolystarInvalidRadius,
                            severity: .error,
                            path: "\(basePath).ir.k",
                            message: "Polystar inner radius (\(irValue)) must be < outer radius (\(orValue))."
                        ))
                    }
                }
            }
        }

        // 5) Validate animated keyframes consistency
        validatePolystarAnimatedKeyframes(
            polystar: polystar,
            isStar: isStar,
            basePath: basePath,
            issues: &issues
        )
    }

    /// Validates polystar roundness field (must be static and zero)
    private func validatePolystarRoundness(
        value: LottieAnimatedValue?,
        fieldName: String,
        fieldPath: String,
        basePath: String,
        issues: inout [ValidationIssue]
    ) {
        guard let roundness = value else { return }

        if roundness.isAnimated {
            issues.append(ValidationIssue(
                code: AnimValidationCode.unsupportedPolystarRoundnessAnimated,
                severity: .error,
                path: "\(basePath).\(fieldPath).a",
                message: "Polystar \(fieldName) animation not supported."
            ))
        } else {
            // Check if non-zero
            if let data = roundness.value {
                let roundnessValue: Double?
                switch data {
                case .number(let num):
                    roundnessValue = num
                case .array(let arr) where !arr.isEmpty:
                    roundnessValue = arr[0]
                default:
                    roundnessValue = nil
                }

                if let rv = roundnessValue, abs(rv) > 0.001 {
                    issues.append(ValidationIssue(
                        code: AnimValidationCode.unsupportedPolystarRoundnessNonzero,
                        severity: .error,
                        path: "\(basePath).\(fieldPath).k",
                        message: "Polystar \(fieldName) must be 0. Got: \(rv). Roundness not supported in current version."
                    ))
                }
            }
        }
    }

    /// Validates animated keyframes for polystar (p, r, or, ir)
    private func validatePolystarAnimatedKeyframes(
        polystar: LottieShapePolystar,
        isStar: Bool,
        basePath: String,
        issues: inout [ValidationIssue]
    ) {
        let positionAnimated = polystar.position?.isAnimated ?? false
        let rotationAnimated = polystar.rotation?.isAnimated ?? false
        let outerRadiusAnimated = polystar.outerRadius?.isAnimated ?? false
        let innerRadiusAnimated = isStar && (polystar.innerRadius?.isAnimated ?? false)

        // If nothing is animated, no keyframe validation needed
        guard positionAnimated || rotationAnimated || outerRadiusAnimated || innerRadiusAnimated else { return }

        // Extract keyframes from animated fields
        var allKeyframeArrays: [(name: String, path: String, keyframes: [LottieKeyframe]?)] = []

        if positionAnimated {
            let kfs = extractKeyframes(from: polystar.position)
            allKeyframeArrays.append(("position", "p", kfs))
            if kfs == nil {
                issues.append(ValidationIssue(
                    code: AnimValidationCode.unsupportedPolystarKeyframeFormat,
                    severity: .error,
                    path: "\(basePath).p",
                    message: "Polystar position is animated but keyframes could not be decoded."
                ))
            }
        }

        if rotationAnimated {
            let kfs = extractKeyframes(from: polystar.rotation)
            allKeyframeArrays.append(("rotation", "r", kfs))
            if kfs == nil {
                issues.append(ValidationIssue(
                    code: AnimValidationCode.unsupportedPolystarKeyframeFormat,
                    severity: .error,
                    path: "\(basePath).r",
                    message: "Polystar rotation is animated but keyframes could not be decoded."
                ))
            }
        }

        if outerRadiusAnimated {
            let kfs = extractKeyframes(from: polystar.outerRadius)
            allKeyframeArrays.append(("outerRadius", "or", kfs))
            if kfs == nil {
                issues.append(ValidationIssue(
                    code: AnimValidationCode.unsupportedPolystarKeyframeFormat,
                    severity: .error,
                    path: "\(basePath).or",
                    message: "Polystar outer radius is animated but keyframes could not be decoded."
                ))
            }
        }

        if innerRadiusAnimated {
            let kfs = extractKeyframes(from: polystar.innerRadius)
            allKeyframeArrays.append(("innerRadius", "ir", kfs))
            if kfs == nil {
                issues.append(ValidationIssue(
                    code: AnimValidationCode.unsupportedPolystarKeyframeFormat,
                    severity: .error,
                    path: "\(basePath).ir",
                    message: "Polystar inner radius is animated but keyframes could not be decoded."
                ))
            }
        }

        // Get valid keyframe arrays
        let validArrays = allKeyframeArrays.compactMap { item -> (name: String, path: String, keyframes: [LottieKeyframe])? in
            guard let kfs = item.keyframes else { return nil }
            return (item.name, item.path, kfs)
        }

        // If we have 2+ animated fields, validate they match
        if validArrays.count >= 2 {
            let referenceKfs = validArrays[0].keyframes
            let referenceName = validArrays[0].name

            for i in 1..<validArrays.count {
                let otherKfs = validArrays[i].keyframes
                let otherName = validArrays[i].name

                // Check count match
                if referenceKfs.count != otherKfs.count {
                    issues.append(ValidationIssue(
                        code: AnimValidationCode.unsupportedPolystarKeyframesMismatch,
                        severity: .error,
                        path: basePath,
                        message: "Polystar \(referenceName) has \(referenceKfs.count) keyframes but \(otherName) has \(otherKfs.count). All animated fields must have same keyframe count."
                    ))
                    continue
                }

                // Check time match for each keyframe
                for j in 0..<referenceKfs.count {
                    let refTime = referenceKfs[j].time
                    let otherTime = otherKfs[j].time

                    if refTime == nil || otherTime == nil {
                        issues.append(ValidationIssue(
                            code: AnimValidationCode.unsupportedPolystarKeyframeFormat,
                            severity: .error,
                            path: basePath,
                            message: "Polystar keyframe[\(j)] missing time value."
                        ))
                        continue
                    }

                    if let rt = refTime, let ot = otherTime, abs(rt - ot) >= 0.001 {
                        issues.append(ValidationIssue(
                            code: AnimValidationCode.unsupportedPolystarKeyframesMismatch,
                            severity: .error,
                            path: basePath,
                            message: "Polystar keyframe[\(j)] time mismatch: \(referenceName).t=\(rt), \(otherName).t=\(ot)."
                        ))
                    }
                }
            }
        }

        // Validate individual keyframe format for each animated field
        for (name, fieldPath, keyframes) in validArrays {
            let isVec2D = (name == "position")

            for (i, kf) in keyframes.enumerated() {
                // Check time exists
                if kf.time == nil {
                    issues.append(ValidationIssue(
                        code: AnimValidationCode.unsupportedPolystarKeyframeFormat,
                        severity: .error,
                        path: "\(basePath).\(fieldPath).k[\(i)]",
                        message: "Polystar \(name) keyframe[\(i)] missing time (t)."
                    ))
                }

                // Check startValue exists and has correct format
                if let startValue = kf.startValue {
                    if isVec2D {
                        // Position expects [x, y] array
                        switch startValue {
                        case .numbers(let arr) where arr.count >= 2:
                            break // Valid
                        default:
                            issues.append(ValidationIssue(
                                code: AnimValidationCode.unsupportedPolystarKeyframeFormat,
                                severity: .error,
                                path: "\(basePath).\(fieldPath).k[\(i)].s",
                                message: "Polystar \(name) keyframe[\(i)] has invalid startValue format. Expected [x, y] array."
                            ))
                        }
                    } else {
                        // Rotation/radius expect a number (stored as single-element array)
                        switch startValue {
                        case .numbers(let arr) where !arr.isEmpty:
                            break // Valid
                        default:
                            issues.append(ValidationIssue(
                                code: AnimValidationCode.unsupportedPolystarKeyframeFormat,
                                severity: .error,
                                path: "\(basePath).\(fieldPath).k[\(i)].s",
                                message: "Polystar \(name) keyframe[\(i)] has invalid startValue format. Expected a number."
                            ))
                        }
                    }
                } else {
                    issues.append(ValidationIssue(
                        code: AnimValidationCode.unsupportedPolystarKeyframeFormat,
                        severity: .error,
                        path: "\(basePath).\(fieldPath).k[\(i)].s",
                        message: "Polystar \(name) keyframe[\(i)] missing startValue (s)."
                    ))
                }
            }
        }
    }

    /// Extracts keyframes array from LottieAnimatedValue
    private func extractKeyframes(from value: LottieAnimatedValue?) -> [LottieKeyframe]? {
        guard let value = value,
              let data = value.value,
              case .keyframes(let kfs) = data else {
            return nil
        }
        return kfs
    }

    /// Extracts static Double value from LottieAnimatedValue
    private func extractStaticDouble(from value: LottieAnimatedValue?) -> Double? {
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

    // MARK: - Stroke Validation

    /// Maximum allowed stroke width to prevent pathological input
    private static let maxStrokeWidth: Double = 2048

    /// Validates stroke shape parameters
    /// - Dash must be absent (not supported in PR-10)
    /// - Color must be static
    /// - Opacity must be static
    /// - Width must exist, be > 0 and <= 2048 (static or animated with valid keyframes)
    /// - LineCap must be 1, 2, or 3
    /// - LineJoin must be 1, 2, or 3
    /// - MiterLimit must be > 0
    private func validateStroke(
        stroke: LottieShapeStroke,
        basePath: String,
        issues: inout [ValidationIssue]
    ) {
        // 1) Validate dash - must be absent or empty
        if let dash = stroke.dash, !dash.isEmpty {
            issues.append(ValidationIssue(
                code: AnimValidationCode.unsupportedStrokeDash,
                severity: .error,
                path: "\(basePath).d",
                message: "Stroke dash pattern not supported. Remove dash array."
            ))
        }

        // 2) Validate color - must be static
        if let color = stroke.color {
            if color.isAnimated {
                issues.append(ValidationIssue(
                    code: AnimValidationCode.unsupportedStrokeColorAnimated,
                    severity: .error,
                    path: "\(basePath).c.a",
                    message: "Animated stroke color not supported. Use static color."
                ))
            }
        }

        // 3) Validate opacity - must be static
        if let opacity = stroke.opacity {
            if opacity.isAnimated {
                issues.append(ValidationIssue(
                    code: AnimValidationCode.unsupportedStrokeOpacityAnimated,
                    severity: .error,
                    path: "\(basePath).o.a",
                    message: "Animated stroke opacity not supported. Use static opacity."
                ))
            }
        }

        // 4) Validate width - must exist, > 0, <= MAX_STROKE_WIDTH
        guard let width = stroke.width else {
            issues.append(ValidationIssue(
                code: AnimValidationCode.unsupportedStrokeWidthMissing,
                severity: .error,
                path: "\(basePath).w",
                message: "Stroke width is missing. Width is required."
            ))
            return
        }

        if width.isAnimated {
            // Validate animated width keyframes
            validateStrokeWidthKeyframes(width: width, basePath: basePath, issues: &issues)
        } else {
            // Validate static width value
            if let widthValue = extractStaticDouble(from: width) {
                if widthValue <= 0 || widthValue > Self.maxStrokeWidth {
                    issues.append(ValidationIssue(
                        code: AnimValidationCode.unsupportedStrokeWidthInvalid,
                        severity: .error,
                        path: "\(basePath).w.k",
                        message: "Stroke width must be > 0 and <= \(Int(Self.maxStrokeWidth)). Got: \(widthValue)."
                    ))
                }
            }
        }

        // 5) Validate lineCap - must be 1, 2, or 3
        if let lineCap = stroke.lineCap {
            if lineCap < 1 || lineCap > 3 {
                issues.append(ValidationIssue(
                    code: AnimValidationCode.unsupportedStrokeLinecap,
                    severity: .error,
                    path: "\(basePath).lc",
                    message: "Stroke lineCap must be 1 (butt), 2 (round), or 3 (square). Got: \(lineCap)."
                ))
            }
        }

        // 6) Validate lineJoin - must be 1, 2, or 3
        if let lineJoin = stroke.lineJoin {
            if lineJoin < 1 || lineJoin > 3 {
                issues.append(ValidationIssue(
                    code: AnimValidationCode.unsupportedStrokeLinejoin,
                    severity: .error,
                    path: "\(basePath).lj",
                    message: "Stroke lineJoin must be 1 (miter), 2 (round), or 3 (bevel). Got: \(lineJoin)."
                ))
            }
        }

        // 7) Validate miterLimit - must be > 0
        if let miterLimit = stroke.miterLimit {
            if miterLimit <= 0 {
                issues.append(ValidationIssue(
                    code: AnimValidationCode.unsupportedStrokeMiterlimit,
                    severity: .error,
                    path: "\(basePath).ml",
                    message: "Stroke miterLimit must be > 0. Got: \(miterLimit)."
                ))
            }
        }
    }

    /// Validates animated stroke width keyframes
    private func validateStrokeWidthKeyframes(
        width: LottieAnimatedValue,
        basePath: String,
        issues: inout [ValidationIssue]
    ) {
        // Extract keyframes
        guard let data = width.value,
              case .keyframes(let keyframes) = data else {
            issues.append(ValidationIssue(
                code: AnimValidationCode.unsupportedStrokeWidthKeyframeFormat,
                severity: .error,
                path: "\(basePath).w",
                message: "Stroke width is animated but keyframes could not be decoded."
            ))
            return
        }

        // Validate each keyframe
        for (i, kf) in keyframes.enumerated() {
            // Check time exists
            if kf.time == nil {
                issues.append(ValidationIssue(
                    code: AnimValidationCode.unsupportedStrokeWidthKeyframeFormat,
                    severity: .error,
                    path: "\(basePath).w.k[\(i)]",
                    message: "Stroke width keyframe[\(i)] missing time (t)."
                ))
            }

            // Check startValue exists and is valid
            if let startValue = kf.startValue {
                switch startValue {
                case .numbers(let arr) where !arr.isEmpty:
                    let widthValue = arr[0]
                    if widthValue <= 0 || widthValue > Self.maxStrokeWidth {
                        issues.append(ValidationIssue(
                            code: AnimValidationCode.unsupportedStrokeWidthInvalid,
                            severity: .error,
                            path: "\(basePath).w.k[\(i)].s",
                            message: "Stroke width keyframe[\(i)] has invalid value: \(widthValue). Must be > 0 and <= \(Int(Self.maxStrokeWidth))."
                        ))
                    }
                default:
                    issues.append(ValidationIssue(
                        code: AnimValidationCode.unsupportedStrokeWidthKeyframeFormat,
                        severity: .error,
                        path: "\(basePath).w.k[\(i)].s",
                        message: "Stroke width keyframe[\(i)] has invalid startValue format. Expected a number."
                    ))
                }
            } else {
                issues.append(ValidationIssue(
                    code: AnimValidationCode.unsupportedStrokeWidthKeyframeFormat,
                    severity: .error,
                    path: "\(basePath).w.k[\(i)].s",
                    message: "Stroke width keyframe[\(i)] missing startValue (s)."
                ))
            }
        }
    }

    // MARK: - Group Transform Validation (PR-11)

    /// Validates group transform (tr inside gr)
    /// - Multiple tr items in a group → error
    /// - Skew present → error
    /// - Non-uniform scale (sx != sy) → error (breaks strokeWidth scaling)
    /// - Animated keyframes must have matching count/times
    private func validateGroupTransform(
        items: [ShapeItem],
        basePath: String,
        issues: inout [ValidationIssue]
    ) {
        // Find all transform items in this group
        let transforms = items.enumerated().compactMap { index, item -> (Int, LottieShapeTransform)? in
            if case .transform(let tr) = item { return (index, tr) }
            return nil
        }

        // 1) Check for multiple transforms
        if transforms.count > 1 {
            issues.append(ValidationIssue(
                code: AnimValidationCode.unsupportedGroupTransformMultiple,
                severity: .error,
                path: "\(basePath).tr",
                message: "Group has \(transforms.count) transform items. Only one tr per group is allowed."
            ))
            return // Can't validate further with multiple transforms
        }

        // If no transform, nothing to validate
        guard let (trIndex, transform) = transforms.first else { return }
        let trPath = "\(basePath).it[\(trIndex)]"

        // 2) Validate skew is not present
        if let skew = transform.skew {
            if skew.isAnimated {
                issues.append(ValidationIssue(
                    code: AnimValidationCode.unsupportedGroupTransformSkew,
                    severity: .error,
                    path: "\(trPath).sk.a",
                    message: "Animated group transform skew not supported."
                ))
            } else if let skewValue = extractStaticDouble(from: skew), abs(skewValue) > 0.001 {
                issues.append(ValidationIssue(
                    code: AnimValidationCode.unsupportedGroupTransformSkew,
                    severity: .error,
                    path: "\(trPath).sk.k",
                    message: "Group transform skew must be 0. Got: \(skewValue)."
                ))
            }
        }

        if let skewAxis = transform.skewAxis {
            if skewAxis.isAnimated {
                issues.append(ValidationIssue(
                    code: AnimValidationCode.unsupportedGroupTransformSkew,
                    severity: .error,
                    path: "\(trPath).sa.a",
                    message: "Animated group transform skew axis not supported."
                ))
            }
        }

        // 3) Validate scale uniformity (sx == sy)
        if let scale = transform.scale {
            if scale.isAnimated {
                // Check each keyframe for uniform scale
                validateGroupTransformScaleKeyframes(scale: scale, basePath: trPath, issues: &issues)
            } else {
                // Static scale - check uniformity
                if let scaleVec = extractStaticVec2D(from: scale) {
                    if abs(scaleVec.x - scaleVec.y) > 0.001 {
                        issues.append(ValidationIssue(
                            code: AnimValidationCode.unsupportedGroupTransformScaleNonuniform,
                            severity: .error,
                            path: "\(trPath).s.k",
                            message: "Group transform scale must be uniform (sx == sy). Got: sx=\(scaleVec.x), sy=\(scaleVec.y)."
                        ))
                    }
                }
            }
        }

        // 4) Validate animated keyframes consistency
        validateGroupTransformKeyframes(transform: transform, basePath: trPath, issues: &issues)
    }

    /// Validates animated scale keyframes for uniformity
    private func validateGroupTransformScaleKeyframes(
        scale: LottieAnimatedValue,
        basePath: String,
        issues: inout [ValidationIssue]
    ) {
        guard let data = scale.value,
              case .keyframes(let keyframes) = data else {
            issues.append(ValidationIssue(
                code: AnimValidationCode.unsupportedGroupTransformKeyframeFormat,
                severity: .error,
                path: "\(basePath).s",
                message: "Group transform scale is animated but keyframes could not be decoded."
            ))
            return
        }

        for (i, kf) in keyframes.enumerated() {
            guard let startValue = kf.startValue else {
                issues.append(ValidationIssue(
                    code: AnimValidationCode.unsupportedGroupTransformKeyframeFormat,
                    severity: .error,
                    path: "\(basePath).s.k[\(i)].s",
                    message: "Group transform scale keyframe[\(i)] missing startValue (s)."
                ))
                continue
            }

            switch startValue {
            case .numbers(let arr) where arr.count >= 2:
                let sx = arr[0]
                let sy = arr[1]
                if abs(sx - sy) > 0.001 {
                    issues.append(ValidationIssue(
                        code: AnimValidationCode.unsupportedGroupTransformScaleNonuniform,
                        severity: .error,
                        path: "\(basePath).s.k[\(i)].s",
                        message: "Group transform scale keyframe[\(i)] must be uniform. Got: sx=\(sx), sy=\(sy)."
                    ))
                }
            default:
                issues.append(ValidationIssue(
                    code: AnimValidationCode.unsupportedGroupTransformKeyframeFormat,
                    severity: .error,
                    path: "\(basePath).s.k[\(i)].s",
                    message: "Group transform scale keyframe[\(i)] has invalid format. Expected [sx, sy] array."
                ))
            }
        }
    }

    /// Validates animated keyframes consistency for group transform (p/a/s/r/o)
    private func validateGroupTransformKeyframes(
        transform: LottieShapeTransform,
        basePath: String,
        issues: inout [ValidationIssue]
    ) {
        let positionAnimated = transform.position?.isAnimated ?? false
        let anchorAnimated = transform.anchor?.isAnimated ?? false
        let scaleAnimated = transform.scale?.isAnimated ?? false
        let rotationAnimated = transform.rotation?.isAnimated ?? false
        let opacityAnimated = transform.opacity?.isAnimated ?? false

        // If nothing is animated, no keyframe validation needed
        guard positionAnimated || anchorAnimated || scaleAnimated || rotationAnimated || opacityAnimated else {
            return
        }

        // Extract keyframes from animated fields
        var allKeyframeArrays: [(name: String, path: String, keyframes: [LottieKeyframe]?)] = []

        if positionAnimated {
            let kfs = extractKeyframes(from: transform.position)
            allKeyframeArrays.append(("position", "p", kfs))
            if kfs == nil {
                issues.append(ValidationIssue(
                    code: AnimValidationCode.unsupportedGroupTransformKeyframeFormat,
                    severity: .error,
                    path: "\(basePath).p",
                    message: "Group transform position is animated but keyframes could not be decoded."
                ))
            }
        }

        if anchorAnimated {
            let kfs = extractKeyframes(from: transform.anchor)
            allKeyframeArrays.append(("anchor", "a", kfs))
            if kfs == nil {
                issues.append(ValidationIssue(
                    code: AnimValidationCode.unsupportedGroupTransformKeyframeFormat,
                    severity: .error,
                    path: "\(basePath).a",
                    message: "Group transform anchor is animated but keyframes could not be decoded."
                ))
            }
        }

        if scaleAnimated {
            let kfs = extractKeyframes(from: transform.scale)
            allKeyframeArrays.append(("scale", "s", kfs))
            // Note: scale keyframe format already validated above for uniformity
        }

        if rotationAnimated {
            let kfs = extractKeyframes(from: transform.rotation)
            allKeyframeArrays.append(("rotation", "r", kfs))
            if kfs == nil {
                issues.append(ValidationIssue(
                    code: AnimValidationCode.unsupportedGroupTransformKeyframeFormat,
                    severity: .error,
                    path: "\(basePath).r",
                    message: "Group transform rotation is animated but keyframes could not be decoded."
                ))
            }
        }

        if opacityAnimated {
            let kfs = extractKeyframes(from: transform.opacity)
            allKeyframeArrays.append(("opacity", "o", kfs))
            if kfs == nil {
                issues.append(ValidationIssue(
                    code: AnimValidationCode.unsupportedGroupTransformKeyframeFormat,
                    severity: .error,
                    path: "\(basePath).o",
                    message: "Group transform opacity is animated but keyframes could not be decoded."
                ))
            }
        }

        // Get valid keyframe arrays
        let validArrays = allKeyframeArrays.compactMap { item -> (name: String, path: String, keyframes: [LottieKeyframe])? in
            guard let kfs = item.keyframes else { return nil }
            return (item.name, item.path, kfs)
        }

        // If we have 2+ animated fields, validate they match
        if validArrays.count >= 2 {
            let referenceKfs = validArrays[0].keyframes
            let referenceName = validArrays[0].name

            for i in 1..<validArrays.count {
                let otherKfs = validArrays[i].keyframes
                let otherName = validArrays[i].name

                // Check count match
                if referenceKfs.count != otherKfs.count {
                    issues.append(ValidationIssue(
                        code: AnimValidationCode.unsupportedGroupTransformKeyframesMismatch,
                        severity: .error,
                        path: basePath,
                        message: "Group transform \(referenceName) has \(referenceKfs.count) keyframes but \(otherName) has \(otherKfs.count). All animated fields must have same keyframe count."
                    ))
                    continue
                }

                // Check time match for each keyframe
                for j in 0..<referenceKfs.count {
                    let refTime = referenceKfs[j].time
                    let otherTime = otherKfs[j].time

                    if refTime == nil || otherTime == nil {
                        issues.append(ValidationIssue(
                            code: AnimValidationCode.unsupportedGroupTransformKeyframeFormat,
                            severity: .error,
                            path: basePath,
                            message: "Group transform keyframe[\(j)] missing time value."
                        ))
                        continue
                    }

                    if let rt = refTime, let ot = otherTime, abs(rt - ot) >= 0.001 {
                        issues.append(ValidationIssue(
                            code: AnimValidationCode.unsupportedGroupTransformKeyframesMismatch,
                            severity: .error,
                            path: basePath,
                            message: "Group transform keyframe[\(j)] time mismatch: \(referenceName).t=\(rt), \(otherName).t=\(ot)."
                        ))
                    }
                }
            }
        }

        // Validate individual keyframe format for each animated field
        for (name, fieldPath, keyframes) in validArrays {
            let isVec2D = (name == "position" || name == "anchor" || name == "scale")

            for (i, kf) in keyframes.enumerated() {
                // Check time exists
                if kf.time == nil {
                    issues.append(ValidationIssue(
                        code: AnimValidationCode.unsupportedGroupTransformKeyframeFormat,
                        severity: .error,
                        path: "\(basePath).\(fieldPath).k[\(i)]",
                        message: "Group transform \(name) keyframe[\(i)] missing time (t)."
                    ))
                }

                // Check startValue exists and has correct format
                if let startValue = kf.startValue {
                    if isVec2D {
                        switch startValue {
                        case .numbers(let arr) where arr.count >= 2:
                            break // Valid
                        default:
                            issues.append(ValidationIssue(
                                code: AnimValidationCode.unsupportedGroupTransformKeyframeFormat,
                                severity: .error,
                                path: "\(basePath).\(fieldPath).k[\(i)].s",
                                message: "Group transform \(name) keyframe[\(i)] has invalid format. Expected [x, y] array."
                            ))
                        }
                    } else {
                        switch startValue {
                        case .numbers(let arr) where !arr.isEmpty:
                            break // Valid
                        default:
                            issues.append(ValidationIssue(
                                code: AnimValidationCode.unsupportedGroupTransformKeyframeFormat,
                                severity: .error,
                                path: "\(basePath).\(fieldPath).k[\(i)].s",
                                message: "Group transform \(name) keyframe[\(i)] has invalid format. Expected a number."
                            ))
                        }
                    }
                } else {
                    issues.append(ValidationIssue(
                        code: AnimValidationCode.unsupportedGroupTransformKeyframeFormat,
                        severity: .error,
                        path: "\(basePath).\(fieldPath).k[\(i)].s",
                        message: "Group transform \(name) keyframe[\(i)] missing startValue (s)."
                    ))
                }
            }
        }
    }

    /// Extracts static Vec2D value from LottieAnimatedValue
    private func extractStaticVec2D(from value: LottieAnimatedValue?) -> Vec2D? {
        guard let value = value, let data = value.value else { return nil }
        switch data {
        case .array(let arr) where arr.count >= 2:
            return Vec2D(x: arr[0], y: arr[1])
        default:
            return nil
        }
    }
}
