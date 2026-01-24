import Foundation

// MARK: - Shape Validation

extension AnimValidator {
    func validateShapes(
        shapes: [LottieShape],
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
        shape: LottieShape,
        shapeIndex: Int,
        layerIndex: Int,
        context: String,
        animRef: String,
        issues: inout [ValidationIssue]
    ) {
        let basePath = "anim(\(animRef)).\(context)[\(layerIndex)].shapes[\(shapeIndex)]"

        if !Self.supportedShapeTypes.contains(shape.type) {
            issues.append(ValidationIssue(
                code: AnimValidationCode.unsupportedShapeItem,
                severity: .error,
                path: "\(basePath).ty",
                message: "Shape type '\(shape.type)' not supported. Supported: gr, sh, fl, tr"
            ))
        }

        // Recursively check group items
        if shape.type == "gr", let items = shape.items {
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
    }
}
