import Foundation
import TVECore

/// Validates Scene objects against Scene.json Spec v0.1
public final class SceneValidator: Sendable {
    /// Configuration options for the validator
    public struct Options: Sendable {
        /// Set of supported schema versions
        public var supportedSchemaVersions: Set<String> = ["0.1"]

        /// Set of supported containerClip values (Part 1 subset)
        public var supportedContainerClip: Set<ContainerClip> = [.none, .slotRect]

        public init() {}
    }

    let options: Options
    let maskCatalog: MaskCatalog?

    /// Creates a new scene validator
    /// - Parameters:
    ///   - options: Configuration options for validation
    ///   - maskCatalog: Optional mask catalog for maskRef validation
    public init(options: Options = .init(), maskCatalog: MaskCatalog? = nil) {
        self.options = options
        self.maskCatalog = maskCatalog
    }

    /// Validates a scene and returns a validation report
    /// - Parameter scene: The scene to validate
    /// - Returns: ValidationReport containing all found issues
    public func validate(scene: Scene) -> ValidationReport {
        var issues: [ValidationIssue] = []

        validateSchemaVersion(scene: scene, issues: &issues)
        validateCanvas(scene: scene, issues: &issues)
        validateMediaBlocks(scene: scene, issues: &issues)

        return ValidationReport(issues: issues)
    }
}

// MARK: - Schema & Canvas Validation

extension SceneValidator {
    func validateSchemaVersion(scene: Scene, issues: inout [ValidationIssue]) {
        if !options.supportedSchemaVersions.contains(scene.schemaVersion) {
            issues.append(ValidationIssue(
                code: SceneValidationCode.sceneUnsupportedVersion,
                severity: .error,
                path: "$.schemaVersion",
                message: "Schema version '\(scene.schemaVersion)' is not supported. " +
                         "Supported versions: \(options.supportedSchemaVersions.sorted().joined(separator: ", "))"
            ))
        }
    }

    func validateCanvas(scene: Scene, issues: inout [ValidationIssue]) {
        let canvas = scene.canvas

        if canvas.width <= 0 {
            issues.append(ValidationIssue(
                code: SceneValidationCode.canvasInvalidDimensions,
                severity: .error,
                path: "$.canvas.width",
                message: "Canvas width must be greater than 0, got \(canvas.width)"
            ))
        }

        if canvas.height <= 0 {
            issues.append(ValidationIssue(
                code: SceneValidationCode.canvasInvalidDimensions,
                severity: .error,
                path: "$.canvas.height",
                message: "Canvas height must be greater than 0, got \(canvas.height)"
            ))
        }

        if canvas.fps <= 0 {
            issues.append(ValidationIssue(
                code: SceneValidationCode.canvasInvalidFPS,
                severity: .error,
                path: "$.canvas.fps",
                message: "Canvas fps must be greater than 0, got \(canvas.fps)"
            ))
        }

        if canvas.durationFrames <= 0 {
            issues.append(ValidationIssue(
                code: SceneValidationCode.canvasInvalidDuration,
                severity: .error,
                path: "$.canvas.durationFrames",
                message: "Canvas durationFrames must be greater than 0, got \(canvas.durationFrames)"
            ))
        }
    }
}

// MARK: - MediaBlocks Validation

extension SceneValidator {
    func validateMediaBlocks(scene: Scene, issues: inout [ValidationIssue]) {
        let blocks = scene.mediaBlocks

        if blocks.isEmpty {
            issues.append(ValidationIssue(
                code: SceneValidationCode.blocksEmpty,
                severity: .error,
                path: "$.mediaBlocks",
                message: "MediaBlocks array must not be empty"
            ))
            return
        }

        var seenIds = Set<String>()
        for (index, block) in blocks.enumerated() {
            if seenIds.contains(block.id) {
                issues.append(ValidationIssue(
                    code: SceneValidationCode.blockIdDuplicate,
                    severity: .error,
                    path: "$.mediaBlocks[\(index)].blockId",
                    message: "Duplicate block ID '\(block.id)'"
                ))
            }
            seenIds.insert(block.id)
        }

        for (index, block) in blocks.enumerated() {
            validateMediaBlock(block: block, index: index, scene: scene, issues: &issues)
        }
    }

    func validateMediaBlock(block: MediaBlock, index: Int, scene: Scene, issues: inout [ValidationIssue]) {
        let basePath = "$.mediaBlocks[\(index)]"

        validateRect(rect: block.rect, path: "\(basePath).rect", context: "block rect", issues: &issues)
        validateBlockBounds(block: block, canvas: scene.canvas, path: "\(basePath).rect", issues: &issues)
        validateContainerClip(containerClip: block.containerClip, path: "\(basePath).containerClip", issues: &issues)

        if let timing = block.timing {
            validateTiming(timing: timing, canvas: scene.canvas, path: "\(basePath).timing", issues: &issues)
        }

        validateMediaInput(input: block.input, basePath: basePath, issues: &issues)
        validateVariants(variants: block.variants, basePath: basePath, issues: &issues)

        // PR-30: Validate layer toggles
        if let layerToggles = block.layerToggles {
            validateLayerToggles(layerToggles: layerToggles, basePath: basePath, issues: &issues)
        }
    }
}

// MARK: - Rect & ContainerClip Validation

extension SceneValidator {
    func validateRect(rect: Rect, path: String, context: String, issues: inout [ValidationIssue]) {
        if rect.width <= 0 || !rect.width.isFinite {
            issues.append(ValidationIssue(
                code: SceneValidationCode.rectInvalid,
                severity: .error,
                path: "\(path).width",
                message: "Rect width must be positive and finite, got \(rect.width) in \(context)"
            ))
        }

        if rect.height <= 0 || !rect.height.isFinite {
            issues.append(ValidationIssue(
                code: SceneValidationCode.rectInvalid,
                severity: .error,
                path: "\(path).height",
                message: "Rect height must be positive and finite, got \(rect.height) in \(context)"
            ))
        }

        if !rect.x.isFinite {
            issues.append(ValidationIssue(
                code: SceneValidationCode.rectInvalid,
                severity: .error,
                path: "\(path).x",
                message: "Rect x must be finite, got \(rect.x) in \(context)"
            ))
        }

        if !rect.y.isFinite {
            issues.append(ValidationIssue(
                code: SceneValidationCode.rectInvalid,
                severity: .error,
                path: "\(path).y",
                message: "Rect y must be finite, got \(rect.y) in \(context)"
            ))
        }
    }

    func validateBlockBounds(block: MediaBlock, canvas: Canvas, path: String, issues: inout [ValidationIssue]) {
        let rect = block.rect
        let isOutside = rect.x < 0 ||
                        rect.y < 0 ||
                        rect.x + rect.width > Double(canvas.width) ||
                        rect.y + rect.height > Double(canvas.height)

        if isOutside {
            issues.append(ValidationIssue(
                code: SceneValidationCode.blockOutsideCanvas,
                severity: .warning,
                path: path,
                message: "Block rect (\(Int(rect.x)),\(Int(rect.y)) \(Int(rect.width))x\(Int(rect.height))) " +
                         "extends outside canvas (\(canvas.width)x\(canvas.height))"
            ))
        }
    }

    func validateContainerClip(containerClip: ContainerClip, path: String, issues: inout [ValidationIssue]) {
        if !options.supportedContainerClip.contains(containerClip) {
            let supported = options.supportedContainerClip.map(\.rawValue).sorted().joined(separator: ", ")
            issues.append(ValidationIssue(
                code: SceneValidationCode.containerClipUnsupported,
                severity: .error,
                path: path,
                message: "ContainerClip '\(containerClip.rawValue)' is not supported in Part 1. Supported: \(supported)"
            ))
        }
    }

    func validateTiming(timing: Timing, canvas: Canvas, path: String, issues: inout [ValidationIssue]) {
        let isValid = timing.startFrame >= 0 &&
                      timing.startFrame < timing.endFrame &&
                      timing.endFrame <= canvas.durationFrames

        if !isValid {
            issues.append(ValidationIssue(
                code: SceneValidationCode.timingInvalidRange,
                severity: .error,
                path: path,
                message: "Timing range is invalid: startFrame=\(timing.startFrame), " +
                         "endFrame=\(timing.endFrame), canvas.durationFrames=\(canvas.durationFrames). " +
                         "Must satisfy: 0 <= startFrame < endFrame <= durationFrames"
            ))
        }
    }
}

// MARK: - MediaInput Validation

extension SceneValidator {
    func validateMediaInput(input: MediaInput, basePath: String, issues: inout [ValidationIssue]) {
        let inputPath = "\(basePath).input"

        validateRect(rect: input.rect, path: "\(inputPath).rect", context: "input rect", issues: &issues)

        if input.bindingKey.isEmpty {
            issues.append(ValidationIssue(
                code: SceneValidationCode.inputBindingKeyEmpty,
                severity: .error,
                path: "\(inputPath).bindingKey",
                message: "Input bindingKey must not be empty"
            ))
        }

        validateAllowedMedia(allowedMedia: input.allowedMedia, path: "\(inputPath).allowedMedia", issues: &issues)

        if let maskRef = input.maskRef {
            validateMaskRef(maskRef: maskRef, path: "\(inputPath).maskRef", issues: &issues)
        }
    }

    func validateAllowedMedia(allowedMedia: [String], path: String, issues: inout [ValidationIssue]) {
        if allowedMedia.isEmpty {
            issues.append(ValidationIssue(
                code: SceneValidationCode.allowedMediaEmpty,
                severity: .error,
                path: path,
                message: "AllowedMedia array must not be empty"
            ))
            return
        }

        let validValues = Set(AllowedMediaType.allCases.map(\.rawValue))

        for (index, value) in allowedMedia.enumerated() where !validValues.contains(value) {
            issues.append(ValidationIssue(
                code: SceneValidationCode.allowedMediaInvalidValue,
                severity: .error,
                path: "\(path)[\(index)]",
                message: "Invalid allowedMedia value '\(value)'. Valid: \(validValues.sorted().joined(separator: ", "))"
            ))
        }

        var seen = Set<String>()
        for (index, value) in allowedMedia.enumerated() {
            if seen.contains(value) {
                issues.append(ValidationIssue(
                    code: SceneValidationCode.allowedMediaDuplicate,
                    severity: .error,
                    path: "\(path)[\(index)]",
                    message: "Duplicate allowedMedia value '\(value)'"
                ))
            }
            seen.insert(value)
        }
    }

    func validateMaskRef(maskRef: String, path: String, issues: inout [ValidationIssue]) {
        guard let catalog = maskCatalog else {
            issues.append(ValidationIssue(
                code: SceneValidationCode.maskRefCatalogUnavailable,
                severity: .warning,
                path: path,
                message: "MaskRef '\(maskRef)' cannot be validated: mask catalog unavailable"
            ))
            return
        }

        if !catalog.contains(maskRef: maskRef) {
            issues.append(ValidationIssue(
                code: SceneValidationCode.maskRefNotFound,
                severity: .warning,
                path: path,
                message: "MaskRef '\(maskRef)' not found in mask catalog"
            ))
        }
    }
}

// MARK: - Variants Validation

extension SceneValidator {
    func validateVariants(variants: [Variant], basePath: String, issues: inout [ValidationIssue]) {
        let variantsPath = "\(basePath).variants"

        if variants.isEmpty {
            issues.append(ValidationIssue(
                code: SceneValidationCode.variantsEmpty,
                severity: .error,
                path: variantsPath,
                message: "Variants array must not be empty"
            ))
            return
        }

        for (index, variant) in variants.enumerated() {
            validateVariant(variant: variant, index: index, basePath: variantsPath, issues: &issues)
        }
    }

    func validateVariant(variant: Variant, index: Int, basePath: String, issues: inout [ValidationIssue]) {
        let variantPath = "\(basePath)[\(index)]"

        if variant.animRef.isEmpty {
            issues.append(ValidationIssue(
                code: SceneValidationCode.variantAnimRefEmpty,
                severity: .error,
                path: "\(variantPath).animRef",
                message: "Variant animRef must not be empty"
            ))
        }

        if let duration = variant.defaultDurationFrames, duration <= 0 {
            issues.append(ValidationIssue(
                code: SceneValidationCode.variantDefaultDurationInvalid,
                severity: .error,
                path: "\(variantPath).defaultDurationFrames",
                message: "Variant defaultDurationFrames must be greater than 0, got \(duration)"
            ))
        }

        if let loopRange = variant.loopRange {
            validateLoopRange(loopRange: loopRange, path: "\(variantPath).loopRange", issues: &issues)
        }
    }

    func validateLoopRange(loopRange: LoopRange, path: String, issues: inout [ValidationIssue]) {
        let isValid = loopRange.startFrame >= 0 && loopRange.startFrame < loopRange.endFrame

        if !isValid {
            issues.append(ValidationIssue(
                code: SceneValidationCode.variantLoopRangeInvalid,
                severity: .error,
                path: path,
                message: "LoopRange is invalid: startFrame=\(loopRange.startFrame), " +
                         "endFrame=\(loopRange.endFrame). Must satisfy: 0 <= startFrame < endFrame"
            ))
        }
    }
}

// MARK: - Layer Toggles Validation (PR-30)

extension SceneValidator {
    /// Validates layer toggle definitions in scene.json.
    ///
    /// Checks:
    /// - Each toggle has a non-empty `id`
    /// - Each toggle has a non-empty `title`
    /// - No duplicate toggle ids within the block
    func validateLayerToggles(
        layerToggles: [LayerToggle],
        basePath: String,
        issues: inout [ValidationIssue]
    ) {
        var seenIds = Set<String>()

        for (index, toggle) in layerToggles.enumerated() {
            let togglePath = "\(basePath).layerToggles[\(index)]"

            // Validate non-empty id
            if toggle.id.isEmpty {
                issues.append(ValidationIssue(
                    code: SceneValidationCode.layerToggleIdEmpty,
                    severity: .error,
                    path: "\(togglePath).id",
                    message: "LayerToggle id must not be empty"
                ))
            }

            // Validate non-empty title
            if toggle.title.isEmpty {
                issues.append(ValidationIssue(
                    code: SceneValidationCode.layerToggleTitleEmpty,
                    severity: .error,
                    path: "\(togglePath).title",
                    message: "LayerToggle title must not be empty"
                ))
            }

            // Check for duplicate ids
            if !toggle.id.isEmpty {
                if seenIds.contains(toggle.id) {
                    issues.append(ValidationIssue(
                        code: SceneValidationCode.layerToggleIdDuplicate,
                        severity: .error,
                        path: "\(togglePath).id",
                        message: "Duplicate LayerToggle id '\(toggle.id)' in block"
                    ))
                } else {
                    seenIds.insert(toggle.id)
                }
            }
        }
    }
}
