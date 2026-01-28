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

        case .rect:
            // Rectangle is decoded but not yet supported for rendering (until PR-07)
            // Fail-fast to prevent silent incorrect render
            issues.append(ValidationIssue(
                code: AnimValidationCode.unsupportedShapeItem,
                severity: .error,
                path: "\(basePath).ty",
                message: "Shape type 'rc' not supported. Supported: gr, sh, fl, tr"
            ))

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
}
