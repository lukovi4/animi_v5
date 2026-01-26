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
            validateShapeItem(
                shape: shape,
                shapeIndex: shapeIndex,
                layerIndex: layerIndex,
                context: context,
                animRef: animRef,
                issues: &issues
            )
        }
    }

    func validateShapeItem(
        shape: ShapeItem,
        shapeIndex: Int,
        layerIndex: Int,
        context: String,
        animRef: String,
        issues: inout [ValidationIssue]
    ) {
        let basePath = "anim(\(animRef)).\(context)[\(layerIndex)].shapes[\(shapeIndex)]"

        switch shape {
        case .group(let shapeGroup):
            // Recursively validate group items
            if let items = shapeGroup.items {
                for (itemIndex, item) in items.enumerated() {
                    validateShapeItem(
                        shape: item,
                        shapeIndex: itemIndex,
                        layerIndex: layerIndex,
                        context: "\(context)[\(layerIndex)].shapes[\(shapeIndex)].it",
                        animRef: animRef,
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
