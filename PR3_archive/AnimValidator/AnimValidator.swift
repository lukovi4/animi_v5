import Foundation

/// Validates loaded animations against scene requirements and Part 1 subset constraints
public final class AnimValidator: @unchecked Sendable {
    /// Configuration options for animation validation
    public struct Options: Sendable {
        /// Require exactly one binding layer per block (Part 1 strict mode)
        public var requireExactlyOneBindingLayer: Bool = true

        /// Allow animated mask paths (Part 1: false, only static paths)
        public var allowAnimatedMaskPath: Bool = false

        public init() {}
    }

    /// Supported layer types in Part 1
    private static let supportedLayerTypes: Set<Int> = [0, 2, 3, 4]

    /// Supported track matte types: 1 = alpha, 2 = alpha inverted
    private static let supportedMatteTypes: Set<Int> = [1, 2]

    /// Supported shape types for matte source layers
    private static let supportedShapeTypes: Set<String> = ["gr", "sh", "fl", "tr"]

    let options: Options
    let fileManager: FileManager

    /// Creates a new animation validator
    public init(options: Options = .init(), fileManager: FileManager = .default) {
        self.options = options
        self.fileManager = fileManager
    }

    /// Validates all loaded animations against the scene
    public func validate(
        scene: Scene,
        package: ScenePackage,
        loaded: LoadedAnimations
    ) -> ValidationReport {
        var issues: [ValidationIssue] = []

        // Collect all animRefs and their associated blocks
        let animRefToBlocks = buildAnimRefToBlocksMap(scene: scene)

        for (animRef, lottie) in loaded.lottieByAnimRef {
            let blocks = animRefToBlocks[animRef] ?? []
            let ctx = AnimContext(
                animRef: animRef,
                lottie: lottie,
                blocks: blocks,
                scene: scene,
                package: package
            )
            validateAnimation(ctx, issues: &issues)
        }

        return ValidationReport(issues: issues)
    }

    /// Build map from animRef to associated media blocks
    private func buildAnimRefToBlocksMap(scene: Scene) -> [String: [MediaBlock]] {
        var map: [String: [MediaBlock]] = [:]
        for block in scene.mediaBlocks {
            for variant in block.variants {
                map[variant.animRef, default: []].append(block)
            }
        }
        return map
    }
}

// MARK: - Animation Validation

extension AnimValidator {
    /// Context for validating a single animation
    struct AnimContext {
        let animRef: String
        let lottie: LottieJSON
        let blocks: [MediaBlock]
        let scene: Scene
        let package: ScenePackage
    }

    func validateAnimation(_ ctx: AnimContext, issues: inout [ValidationIssue]) {
        validateRootSanity(animRef: ctx.animRef, lottie: ctx.lottie, issues: &issues)
        validateFPSInvariant(animRef: ctx.animRef, lottie: ctx.lottie, scene: ctx.scene, issues: &issues)
        validateSizeMismatch(animRef: ctx.animRef, lottie: ctx.lottie, blocks: ctx.blocks, issues: &issues)
        validateAssetPresence(animRef: ctx.animRef, lottie: ctx.lottie, package: ctx.package, issues: &issues)

        for block in ctx.blocks {
            validateBindingLayer(
                animRef: ctx.animRef,
                lottie: ctx.lottie,
                bindingKey: block.input.bindingKey,
                issues: &issues
            )
        }

        validatePrecompRefs(animRef: ctx.animRef, lottie: ctx.lottie, issues: &issues)
        validateLayersSubset(animRef: ctx.animRef, lottie: ctx.lottie, issues: &issues)
    }
}

// MARK: - Root & FPS Validation

extension AnimValidator {
    func validateRootSanity(animRef: String, lottie: LottieJSON, issues: inout [ValidationIssue]) {
        if lottie.width <= 0 {
            issues.append(ValidationIssue(
                code: AnimValidationCode.animRootInvalid,
                severity: .error,
                path: "anim(\(animRef)).w",
                message: "Animation width must be > 0, got \(lottie.width)"
            ))
        }

        if lottie.height <= 0 {
            issues.append(ValidationIssue(
                code: AnimValidationCode.animRootInvalid,
                severity: .error,
                path: "anim(\(animRef)).h",
                message: "Animation height must be > 0, got \(lottie.height)"
            ))
        }

        if lottie.frameRate <= 0 {
            issues.append(ValidationIssue(
                code: AnimValidationCode.animRootInvalid,
                severity: .error,
                path: "anim(\(animRef)).fr",
                message: "Animation frame rate must be > 0, got \(lottie.frameRate)"
            ))
        }

        if lottie.outPoint <= lottie.inPoint {
            issues.append(ValidationIssue(
                code: AnimValidationCode.animRootInvalid,
                severity: .error,
                path: "anim(\(animRef)).op",
                message: "Animation outPoint (\(lottie.outPoint)) must be > inPoint (\(lottie.inPoint))"
            ))
        }
    }

    func validateFPSInvariant(
        animRef: String,
        lottie: LottieJSON,
        scene: Scene,
        issues: inout [ValidationIssue]
    ) {
        let sceneFPS = Double(scene.canvas.fps)
        if lottie.frameRate != sceneFPS {
            issues.append(ValidationIssue(
                code: AnimValidationCode.animFPSMismatch,
                severity: .error,
                path: "anim(\(animRef)).fr",
                message: "scene fps=\(Int(sceneFPS)) != anim fr=\(Int(lottie.frameRate)) for \(animRef)"
            ))
        }
    }

    func validateSizeMismatch(
        animRef: String,
        lottie: LottieJSON,
        blocks: [MediaBlock],
        issues: inout [ValidationIssue]
    ) {
        for block in blocks {
            let inputWidth = block.input.rect.width
            let inputHeight = block.input.rect.height

            if lottie.width != inputWidth || lottie.height != inputHeight {
                issues.append(ValidationIssue(
                    code: AnimValidationCode.warningAnimSizeMismatch,
                    severity: .warning,
                    path: "anim(\(animRef)).w",
                    message: "anim \(Int(lottie.width))x\(Int(lottie.height)) != " +
                             "inputRect \(Int(inputWidth))x\(Int(inputHeight)) (contain policy will apply)"
                ))
            }
        }
    }
}

// MARK: - Asset Validation

extension AnimValidator {
    func validateAssetPresence(
        animRef: String,
        lottie: LottieJSON,
        package: ScenePackage,
        issues: inout [ValidationIssue]
    ) {
        for asset in lottie.assets where asset.isImage {
            guard let relativePath = asset.relativePath else { continue }

            let fileURL = package.rootURL.appendingPathComponent(relativePath)
            if !fileManager.fileExists(atPath: fileURL.path) {
                issues.append(ValidationIssue(
                    code: AnimValidationCode.assetMissing,
                    severity: .error,
                    path: "anim(\(animRef)).assets[id=\(asset.id)].p",
                    message: "Missing file \(relativePath) for asset \(asset.id)"
                ))
            }
        }
    }

    func validatePrecompRefs(animRef: String, lottie: LottieJSON, issues: inout [ValidationIssue]) {
        let precompIds = Set(lottie.assets.filter { $0.isPrecomp }.map(\.id))

        func checkLayer(_ layer: LottieLayer, index: Int, context: String) {
            // Check precomp layer references
            if layer.type == 0, let refId = layer.refId, !refId.isEmpty {
                if !precompIds.contains(refId) {
                    issues.append(ValidationIssue(
                        code: AnimValidationCode.precompRefMissing,
                        severity: .error,
                        path: "anim(\(animRef)).\(context)[\(index)].refId",
                        message: "Precomp refId '\(refId)' not found in assets"
                    ))
                }
            }
        }

        // Check root layers
        for (index, layer) in lottie.layers.enumerated() {
            checkLayer(layer, index: index, context: "layers")
        }

        // Check precomp asset layers
        for asset in lottie.assets where asset.isPrecomp {
            for (index, layer) in (asset.layers ?? []).enumerated() {
                checkLayer(layer, index: index, context: "assets[id=\(asset.id)].layers")
            }
        }
    }
}

// MARK: - Binding Layer Validation

extension AnimValidator {
    func validateBindingLayer(
        animRef: String,
        lottie: LottieJSON,
        bindingKey: String,
        issues: inout [ValidationIssue]
    ) {
        // Find all layers with matching name across root and precomp assets
        var candidates: [(layer: LottieLayer, location: String)] = []

        // Search root layers
        for (index, layer) in lottie.layers.enumerated() where layer.name == bindingKey {
            candidates.append((layer, "layers[\(index)]"))
        }

        // Search precomp asset layers
        for asset in lottie.assets where asset.isPrecomp {
            for (index, layer) in (asset.layers ?? []).enumerated() where layer.name == bindingKey {
                candidates.append((layer, "assets[id=\(asset.id)].layers[\(index)]"))
            }
        }

        // Check binding count
        if candidates.isEmpty {
            issues.append(ValidationIssue(
                code: AnimValidationCode.bindingLayerNotFound,
                severity: .error,
                path: "anim(\(animRef)).layers[*].nm",
                message: "No layer with nm='\(bindingKey)' found in \(animRef)"
            ))
            return
        }

        if candidates.count > 1 && options.requireExactlyOneBindingLayer {
            let locations = candidates.map(\.location).joined(separator: ", ")
            issues.append(ValidationIssue(
                code: AnimValidationCode.bindingLayerAmbiguous,
                severity: .error,
                path: "anim(\(animRef)).layers[*].nm",
                message: "Multiple layers with nm='\(bindingKey)' found: \(locations)"
            ))
            return
        }

        // Validate first candidate
        let (layer, location) = candidates[0]

        if layer.type != 2 {
            issues.append(ValidationIssue(
                code: AnimValidationCode.bindingLayerNotImage,
                severity: .error,
                path: "anim(\(animRef)).\(location).ty",
                message: "Binding layer '\(bindingKey)' must be ty=2 (image), got ty=\(layer.type)"
            ))
        }

        if layer.refId?.isEmpty ?? true {
            issues.append(ValidationIssue(
                code: AnimValidationCode.bindingLayerNoAsset,
                severity: .error,
                path: "anim(\(animRef)).\(location).refId",
                message: "Binding layer '\(bindingKey)' must have a refId to an image asset"
            ))
        }
    }
}

// MARK: - Subset Scan Validation

extension AnimValidator {
    func validateLayersSubset(animRef: String, lottie: LottieJSON, issues: inout [ValidationIssue]) {
        // Validate root layers
        for (index, layer) in lottie.layers.enumerated() {
            validateLayer(
                layer: layer,
                index: index,
                context: "layers",
                animRef: animRef,
                issues: &issues
            )
        }

        // Validate precomp asset layers
        for asset in lottie.assets where asset.isPrecomp {
            for (index, layer) in (asset.layers ?? []).enumerated() {
                validateLayer(
                    layer: layer,
                    index: index,
                    context: "assets[id=\(asset.id)].layers",
                    animRef: animRef,
                    issues: &issues
                )
            }
        }
    }

    func validateLayer(
        layer: LottieLayer,
        index: Int,
        context: String,
        animRef: String,
        issues: inout [ValidationIssue]
    ) {
        // Check layer type
        if !Self.supportedLayerTypes.contains(layer.type) {
            issues.append(ValidationIssue(
                code: AnimValidationCode.unsupportedLayerType,
                severity: .error,
                path: "anim(\(animRef)).\(context)[\(index)].ty",
                message: "Layer type \(layer.type) not supported. Supported: 0,2,3,4"
            ))
        }

        // Validate masks
        if let masks = layer.masksProperties {
            for (maskIndex, mask) in masks.enumerated() {
                validateMask(
                    mask: mask,
                    maskIndex: maskIndex,
                    layerIndex: index,
                    context: context,
                    animRef: animRef,
                    issues: &issues
                )
            }
        }

        // Validate track matte type
        if let matteType = layer.trackMatteType {
            if !Self.supportedMatteTypes.contains(matteType) {
                issues.append(ValidationIssue(
                    code: AnimValidationCode.unsupportedMatteType,
                    severity: .error,
                    path: "anim(\(animRef)).\(context)[\(index)].tt",
                    message: "Track matte type \(matteType) not supported. Supported: 1,2"
                ))
            }
        }

        // Validate shape items for matte source shape layers
        let isMatteSourceShapeLayer = layer.type == 4 && layer.isMatteSource == 1
        if isMatteSourceShapeLayer, let shapes = layer.shapes {
            validateShapes(
                shapes: shapes,
                layerIndex: index,
                context: context,
                animRef: animRef,
                issues: &issues
            )
        }
    }

    func validateMask(
        mask: LottieMask,
        maskIndex: Int,
        layerIndex: Int,
        context: String,
        animRef: String,
        issues: inout [ValidationIssue]
    ) {
        let basePath = "anim(\(animRef)).\(context)[\(layerIndex)].masksProperties[\(maskIndex)]"

        // Check mode (must be "a" = add)
        if let mode = mask.mode, mode != "a" {
            issues.append(ValidationIssue(
                code: AnimValidationCode.unsupportedMaskMode,
                severity: .error,
                path: "\(basePath).mode",
                message: "Mask mode '\(mode)' not supported. Only 'a' (add) is supported"
            ))
        }

        // Check inverted flag
        if mask.inverted == true {
            issues.append(ValidationIssue(
                code: AnimValidationCode.unsupportedMaskInvert,
                severity: .error,
                path: "\(basePath).inv",
                message: "Inverted masks not supported"
            ))
        }

        // Check animated path
        if !options.allowAnimatedMaskPath, let path = mask.path, path.isAnimated {
            issues.append(ValidationIssue(
                code: AnimValidationCode.unsupportedMaskPathAnimated,
                severity: .error,
                path: "\(basePath).pt.a",
                message: "Animated mask paths not supported in Part 1"
            ))
        }

        // Check animated opacity
        if let opacity = mask.opacity, opacity.isAnimated {
            issues.append(ValidationIssue(
                code: AnimValidationCode.unsupportedMaskOpacityAnimated,
                severity: .error,
                path: "\(basePath).o.a",
                message: "Animated mask opacity not supported"
            ))
        }
    }

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
