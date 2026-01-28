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
            // Recursively validate group items
            if let items = shapeGroup.items {
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

        case .ellipse:
            // Ellipse is decoded but not yet supported for rendering (until PR-08)
            // Fail-fast to prevent silent incorrect render
            issues.append(ValidationIssue(
                code: AnimValidationCode.unsupportedShapeItem,
                severity: .error,
                path: "\(basePath).ty",
                message: "Shape type 'el' not supported. Supported: gr, sh, fl, tr"
            ))

        case .polystar:
            // Polystar is decoded but not yet supported for rendering (until PR-09)
            // Fail-fast to prevent silent incorrect render
            issues.append(ValidationIssue(
                code: AnimValidationCode.unsupportedShapeItem,
                severity: .error,
                path: "\(basePath).ty",
                message: "Shape type 'sr' not supported. Supported: gr, sh, fl, tr"
            ))

        case .stroke:
            // Stroke is decoded but not yet supported for rendering (until PR-10)
            // Fail-fast to prevent silent incorrect render (stroke would disappear)
            issues.append(ValidationIssue(
                code: AnimValidationCode.unsupportedShapeItem,
                severity: .error,
                path: "\(basePath).ty",
                message: "Shape type 'st' not supported. Supported: gr, sh, fl, tr"
            ))

        case .unknown(let type):
            // Unknown shape type - report as unsupported
            issues.append(ValidationIssue(
                code: AnimValidationCode.unsupportedShapeItem,
                severity: .error,
                path: "\(basePath).ty",
                message: "Shape type '\(type)' not supported. Supported: gr, sh, fl, tr"
            ))
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
}
