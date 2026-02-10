import Foundation
import TVECore

/// Validates loaded animations against scene requirements and Part 1 subset constraints
public final class AnimValidator {
    /// Configuration options for animation validation
    public struct Options: Sendable {
        /// Require exactly one binding layer per block (Part 1 strict mode)
        public var requireExactlyOneBindingLayer: Bool = true

        /// Allow animated mask paths (enabled after PR-C animated path support)
        public var allowAnimatedMaskPath: Bool = true

        public init() {}
    }

    /// Supported layer types in Part 1
    private static let supportedLayerTypes: Set<Int> = [0, 2, 3, 4]

    /// Supported track matte types: 1 = alpha, 2 = alphaInv, 3 = luma, 4 = lumaInv
    private static let supportedMatteTypes: Set<Int> = [1, 2, 3, 4]

    /// Supported shape types for matte source layers
    static let supportedShapeTypes: Set<String> = ["gr", "sh", "fl", "tr"]

    let options: Options
    let fileManager: FileManager

    /// Creates a new animation validator
    public init(options: Options = .init(), fileManager: FileManager = .default) {
        self.options = options
        self.fileManager = fileManager
    }

    /// Validates all loaded animations against the scene.
    ///
    /// - Parameters:
    ///   - scene: Scene configuration
    ///   - package: Scene package with images root
    ///   - loaded: Loaded Lottie animations
    ///   - resolver: PR-28: Optional asset resolver for basename-based resolution.
    ///     When provided, asset presence is validated via Local → Shared resolution
    ///     and binding assets are skipped. When `nil`, uses legacy file-exists check.
    public func validate(
        scene: Scene,
        package: ScenePackage,
        loaded: LoadedAnimations,
        resolver: CompositeAssetResolver? = nil
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
                package: package,
                resolver: resolver
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
        /// PR-28: Optional resolver for basename-based asset resolution
        let resolver: CompositeAssetResolver?
    }

    func validateAnimation(_ ctx: AnimContext, issues: inout [ValidationIssue]) {
        validateRootSanity(animRef: ctx.animRef, lottie: ctx.lottie, issues: &issues)
        validateFPSInvariant(animRef: ctx.animRef, lottie: ctx.lottie, scene: ctx.scene, issues: &issues)
        validateSizeMismatch(animRef: ctx.animRef, lottie: ctx.lottie, blocks: ctx.blocks, issues: &issues)
        validateAssetPresence(
            animRef: ctx.animRef,
            lottie: ctx.lottie,
            package: ctx.package,
            blocks: ctx.blocks,
            resolver: ctx.resolver,
            issues: &issues
        )

        for block in ctx.blocks {
            validateBindingLayer(
                animRef: ctx.animRef,
                lottie: ctx.lottie,
                bindingKey: block.input.bindingKey,
                issues: &issues
            )

            // PR-15: Validate mediaInput layer
            validateMediaInput(
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
        // Deduplicate warnings by unique input rect sizes
        var seenSizes = Set<String>()

        for block in blocks {
            let inputWidth = block.input.rect.width
            let inputHeight = block.input.rect.height
            let sizeKey = "\(Int(inputWidth))x\(Int(inputHeight))"

            if lottie.width != inputWidth || lottie.height != inputHeight {
                // Only emit one warning per unique size mismatch
                if !seenSizes.contains(sizeKey) {
                    seenSizes.insert(sizeKey)
                    issues.append(ValidationIssue(
                        code: AnimValidationCode.warningAnimSizeMismatch,
                        severity: .warning,
                        path: "anim(\(animRef)).w",
                        message: "anim \(Int(lottie.width))x\(Int(lottie.height)) != " +
                                 "inputRect \(sizeKey) (contain policy will apply)"
                    ))
                }
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
        blocks: [MediaBlock],
        resolver: CompositeAssetResolver?,
        issues: inout [ValidationIssue]
    ) {
        if let resolver = resolver {
            // PR-28: Resolver-based validation with binding skip
            // Find all binding asset IDs: refId of binding layers (nm == bindingKey, ty == 2)
            let bindingAssetIds = findBindingAssetIds(lottie: lottie, blocks: blocks)

            for asset in lottie.assets where asset.isImage {
                // Skip binding assets — they have no file on disk (user media injected at runtime)
                if bindingAssetIds.contains(asset.id) {
                    continue
                }

                guard let filename = asset.filename, !filename.isEmpty else { continue }
                let basename = (filename as NSString).deletingPathExtension
                guard !basename.isEmpty else { continue }

                // Resolve via Local → Shared
                if !resolver.canResolve(key: basename) {
                    let stage = "shared" // searched up to shared stage
                    issues.append(ValidationIssue(
                        code: AnimValidationCode.assetMissing,
                        severity: .error,
                        path: "anim(\(animRef)).assets[id=\(asset.id)].p",
                        message: "Asset '\(basename)' (from \(filename)) not found in local or \(stage) assets"
                    ))
                }
            }
        } else {
            // Legacy: file-exists check (no resolver, no binding skip)
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
    }

    /// Finds asset IDs referenced by binding layers.
    ///
    /// Binding layer: `nm == bindingKey && ty == 2 (image)`.
    /// Returns the set of Lottie asset IDs (refId) that belong to binding layers.
    private func findBindingAssetIds(lottie: LottieJSON, blocks: [MediaBlock]) -> Set<String> {
        let bindingKeys = Set(blocks.map { $0.input.bindingKey })
        var bindingAssetIds = Set<String>()

        func scanLayers(_ layers: [LottieLayer]) {
            for layer in layers {
                if let name = layer.name, bindingKeys.contains(name),
                   layer.type == 2, let refId = layer.refId, !refId.isEmpty {
                    bindingAssetIds.insert(refId)
                }
            }
        }

        // Scan root layers
        scanLayers(lottie.layers)

        // Scan precomp layers
        for asset in lottie.assets where asset.isPrecomp {
            if let layers = asset.layers {
                scanLayers(layers)
            }
        }

        return bindingAssetIds
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
        // PR-12: Collect precomp IDs that are used as matte sources
        // These precomps get "matte-source context" where ct=1 is warning, not error
        let matteSourcePrecompIds = collectMatteSourcePrecompIds(
            layers: lottie.layers,
            assets: lottie.assets
        )

        // Validate root layers (not in matte-source context)
        for (index, layer) in lottie.layers.enumerated() {
            validateLayer(
                layer: layer,
                index: index,
                context: "layers",
                animRef: animRef,
                inMatteSourceContext: false,
                issues: &issues
            )
        }

        // Validate matte pairs in root layers (PR-12)
        validateMattePairs(
            layers: lottie.layers,
            context: "layers",
            animRef: animRef,
            issues: &issues
        )

        // Validate precomp asset layers with matte-source context propagation
        for asset in lottie.assets where asset.isPrecomp {
            let assetLayers = asset.layers ?? []
            let inMatteSourceContext = matteSourcePrecompIds.contains(asset.id)

            for (index, layer) in assetLayers.enumerated() {
                validateLayer(
                    layer: layer,
                    index: index,
                    context: "assets[id=\(asset.id)].layers",
                    animRef: animRef,
                    inMatteSourceContext: inMatteSourceContext,
                    issues: &issues
                )
            }

            // Validate matte pairs in precomp layers (PR-12)
            validateMattePairs(
                layers: assetLayers,
                context: "assets[id=\(asset.id)].layers",
                animRef: animRef,
                issues: &issues
            )
        }
    }

    /// Collects precomp IDs that are used as matte sources (td=1 precomp layers).
    /// Also recursively includes nested precomps within matte-source precomps.
    private func collectMatteSourcePrecompIds(
        layers: [LottieLayer],
        assets: [LottieAsset]
    ) -> Set<String> {
        var result = Set<String>()
        var queue = [String]()

        // Find direct matte source precomps in root layers
        for layer in layers {
            let isMatteSource = (layer.isMatteSource ?? 0) == 1
            let isPrecomp = layer.type == 0
            if isMatteSource, isPrecomp, let refId = layer.refId {
                queue.append(refId)
            }
        }

        // BFS to find nested precomps within matte-source precomps
        while !queue.isEmpty {
            let compId = queue.removeFirst()
            guard !result.contains(compId) else { continue }
            result.insert(compId)

            // Find nested precomps in this comp
            guard let asset = assets.first(where: { $0.id == compId }),
                  let assetLayers = asset.layers else { continue }

            for layer in assetLayers {
                let isPrecomp = layer.type == 0
                if isPrecomp, let refId = layer.refId {
                    queue.append(refId)
                }
            }
        }

        return result
    }

    func validateLayer(
        layer: LottieLayer,
        index: Int,
        context: String,
        animRef: String,
        inMatteSourceContext: Bool,
        issues: inout [ValidationIssue]
    ) {
        let basePath = "anim(\(animRef)).\(context)[\(index)]"

        // Check layer type
        if !Self.supportedLayerTypes.contains(layer.type) {
            issues.append(ValidationIssue(
                code: AnimValidationCode.unsupportedLayerType,
                severity: .error,
                path: "\(basePath).ty",
                message: "Layer type \(layer.type) not supported. Supported: 0,2,3,4"
            ))
        }

        // Validate forbidden layer flags
        // PR-12: ct=1 is warning if layer is matte source (td=1) OR inside matte-source precomp
        let isMatteSource = (layer.isMatteSource ?? 0) == 1
        validateForbiddenLayerFlags(
            layer: layer,
            basePath: basePath,
            isMatteSource: isMatteSource,
            inMatteSourceContext: inMatteSourceContext,
            issues: &issues
        )

        // Validate transform (skew)
        if let transform = layer.transform {
            validateTransform(
                transform: transform,
                basePath: "\(basePath).ks",
                issues: &issues
            )
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
                    path: "\(basePath).tt",
                    message: "Track matte type \(matteType) not supported. Supported: 1,2,3,4"
                ))
            }
        }

        // Validate shape items for ALL shape layers (ty=4), not just matte sources
        if layer.type == 4, let shapes = layer.shapes {
            validateShapes(
                shapes: shapes,
                layerIndex: index,
                context: context,
                animRef: animRef,
                issues: &issues
            )
        }
    }

    /// Validates forbidden layer flags that are not supported
    /// - Parameter isMatteSource: true if layer has td=1 (used for ct context-aware severity)
    /// - Parameter inMatteSourceContext: true if layer is inside a precomp used as matte source
    private func validateForbiddenLayerFlags(
        layer: LottieLayer,
        basePath: String,
        isMatteSource: Bool,
        inMatteSourceContext: Bool,
        issues: inout [ValidationIssue]
    ) {
        // 3D layer (ddd == 1)
        if layer.is3D == 1 {
            issues.append(ValidationIssue(
                code: AnimValidationCode.unsupportedLayer3D,
                severity: .error,
                path: "\(basePath).ddd",
                message: "3D layers (ddd=1) not supported"
            ))
        }

        // Auto-orient (ao == 1)
        if layer.autoOrient == 1 {
            issues.append(ValidationIssue(
                code: AnimValidationCode.unsupportedLayerAutoOrient,
                severity: .error,
                path: "\(basePath).ao",
                message: "Auto-orient (ao=1) not supported"
            ))
        }

        // Time stretch (sr != 1)
        if let stretch = layer.stretch, stretch != 1.0 {
            issues.append(ValidationIssue(
                code: AnimValidationCode.unsupportedLayerStretch,
                severity: .error,
                path: "\(basePath).sr",
                message: "Time stretch (sr=\(stretch)) not supported. Only sr=1 is allowed"
            ))
        }

        // Collapse transform (ct != 0) — always warning (ct is ignored by compiler)
        // SKIP for hidden layers (hd=true) — not rendered, ct has no effect
        if let ct = layer.collapseTransform, ct != 0, layer.hidden != true {
            issues.append(ValidationIssue(
                code: AnimValidationCode.unsupportedLayerCollapseTransform,
                severity: .warning,
                path: "\(basePath).ct",
                message: "Collapse transform (ct=\(ct)) not supported, ignored (best-effort)"
            ))
        }

        // Blend mode (bm != 0)
        if let bm = layer.blendMode, bm != 0 {
            issues.append(ValidationIssue(
                code: AnimValidationCode.unsupportedBlendMode,
                severity: .error,
                path: "\(basePath).bm",
                message: "Blend mode (bm=\(bm)) not supported. Only normal (bm=0) is allowed"
            ))
        }
    }

    /// Validates transform properties (skew)
    private func validateTransform(
        transform: LottieTransform,
        basePath: String,
        issues: inout [ValidationIssue]
    ) {
        // Validate skew (must be absent or static 0)
        guard let skew = transform.skew else { return }

        if skew.isAnimated {
            issues.append(ValidationIssue(
                code: AnimValidationCode.unsupportedSkew,
                severity: .error,
                path: "\(basePath).sk.a",
                message: "Animated skew not supported"
            ))
            return
        }

        // Check static value (must be 0)
        guard let value = skew.value else { return }

        let numericValue: Double?
        switch value {
        case .number(let num):
            numericValue = num
        case .array(let arr):
            numericValue = arr.first
        default:
            numericValue = nil
        }

        // Fail-fast: unrecognized format is an error (no silent ignore)
        guard let num = numericValue else {
            issues.append(ValidationIssue(
                code: AnimValidationCode.unsupportedSkew,
                severity: .error,
                path: "\(basePath).sk.k",
                message: "Skew has unrecognized value format"
            ))
            return
        }

        if num != 0 {
            issues.append(ValidationIssue(
                code: AnimValidationCode.unsupportedSkew,
                severity: .error,
                path: "\(basePath).sk.k",
                message: "Skew (sk=\(num)) not supported. Only sk=0 is allowed"
            ))
        }
    }

    /// Supported mask modes: add, subtract, intersect
    private static let supportedMaskModes: Set<String> = ["a", "s", "i"]

    func validateMask(
        mask: LottieMask,
        maskIndex: Int,
        layerIndex: Int,
        context: String,
        animRef: String,
        issues: inout [ValidationIssue]
    ) {
        let basePath = "anim(\(animRef)).\(context)[\(layerIndex)].masksProperties[\(maskIndex)]"

        // Check mode (must be "a", "s", or "i"; nil defaults to "a")
        if let mode = mask.mode, !Self.supportedMaskModes.contains(mode) {
            issues.append(ValidationIssue(
                code: AnimValidationCode.unsupportedMaskMode,
                severity: .error,
                path: "\(basePath).mode",
                message: "Mask mode '\(mode)' not supported. Supported: a (add), s (subtract), i (intersect)"
            ))
        }

        // Note: inverted masks (inv == true) are now allowed - no validation needed

        // Check animated path
        if let path = mask.path, path.isAnimated {
            if !options.allowAnimatedMaskPath {
                issues.append(ValidationIssue(
                    code: AnimValidationCode.unsupportedMaskPathAnimated,
                    severity: .error,
                    path: "\(basePath).pt.a",
                    message: "Animated mask paths not supported in Part 1"
                ))
            } else {
                // Validate topology consistency for animated paths
                validatePathTopology(
                    path: path,
                    basePath: "\(basePath).pt",
                    issues: &issues
                )
            }
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

        // Check mask expansion
        validateMaskExpansion(
            expansion: mask.expansion,
            basePath: basePath,
            issues: &issues
        )
    }

    /// Validates mask expansion: must be absent, or static with value 0
    private func validateMaskExpansion(
        expansion: LottieAnimatedValue?,
        basePath: String,
        issues: inout [ValidationIssue]
    ) {
        guard let expansion = expansion else { return }

        // Check if animated
        if expansion.isAnimated {
            issues.append(ValidationIssue(
                code: AnimValidationCode.unsupportedMaskExpansionAnimated,
                severity: .error,
                path: "\(basePath).x.a",
                message: "Animated mask expansion not supported"
            ))
            return
        }

        // Check static value (must be 0)
        guard let value = expansion.value else { return }

        let numericValue: Double?
        switch value {
        case .number(let num):
            numericValue = num
        case .array(let arr):
            numericValue = arr.first
        default:
            numericValue = nil
        }

        // Fail-fast: unrecognized format is an error (no silent ignore)
        guard let num = numericValue else {
            issues.append(ValidationIssue(
                code: AnimValidationCode.unsupportedMaskExpansionFormat,
                severity: .error,
                path: "\(basePath).x.k",
                message: "Mask expansion has unrecognized value format"
            ))
            return
        }

        if num != 0 {
            issues.append(ValidationIssue(
                code: AnimValidationCode.unsupportedMaskExpansionNonZero,
                severity: .error,
                path: "\(basePath).x.k",
                message: "Non-zero mask expansion (\(num)) not supported. Only x=0 is allowed"
            ))
        }
    }

    /// Validates that animated path keyframes have consistent topology
    /// (same vertex count and closed flag across all keyframes)
    func validatePathTopology(
        path: LottieAnimatedValue,
        basePath: String,
        issues: inout [ValidationIssue]
    ) {
        guard let data = path.value,
              case .keyframes(let keyframes) = data else {
            issues.append(ValidationIssue(
                code: AnimValidationCode.pathKeyframesMissing,
                severity: .error,
                path: basePath,
                message: "Animated path has no keyframes"
            ))
            return
        }

        guard !keyframes.isEmpty else {
            issues.append(ValidationIssue(
                code: AnimValidationCode.pathKeyframesMissing,
                severity: .error,
                path: basePath,
                message: "Animated path has empty keyframes array"
            ))
            return
        }

        // Extract topology from first keyframe
        guard case .path(let firstPathData) = keyframes[0].startValue,
              let firstVertices = firstPathData.vertices else {
            issues.append(ValidationIssue(
                code: AnimValidationCode.pathKeyframesMissing,
                severity: .error,
                path: "\(basePath).k[0]",
                message: "First keyframe has no path data"
            ))
            return
        }

        let expectedVertexCount = firstVertices.count
        let expectedClosed = firstPathData.closed ?? false

        // Validate all subsequent keyframes have matching topology
        for (index, kf) in keyframes.enumerated().dropFirst() {
            guard case .path(let pathData) = kf.startValue,
                  let vertices = pathData.vertices else {
                issues.append(ValidationIssue(
                    code: AnimValidationCode.pathKeyframesMissing,
                    severity: .error,
                    path: "\(basePath).k[\(index)]",
                    message: "Keyframe \(index) has no path data"
                ))
                continue
            }

            if vertices.count != expectedVertexCount {
                issues.append(ValidationIssue(
                    code: AnimValidationCode.pathTopologyMismatch,
                    severity: .error,
                    path: "\(basePath).k[\(index)]",
                    message: "Keyframe \(index) has \(vertices.count) vertices, expected \(expectedVertexCount)"
                ))
            }

            let closed = pathData.closed ?? false
            if closed != expectedClosed {
                issues.append(ValidationIssue(
                    code: AnimValidationCode.pathTopologyMismatch,
                    severity: .error,
                    path: "\(basePath).k[\(index)].c",
                    message: "Keyframe \(index) closed=\(closed), expected \(expectedClosed)"
                ))
            }
        }
    }

    // MARK: - MediaInput Validation (PR-15)

    /// Canonical layer name for the interactive input area
    private static let mediaInputLayerName = "mediaInput"

    /// Shape types forbidden in mediaInput (modifiers that alter path geometry)
    private static let forbiddenMediaInputShapeTypes: Set<String> = [
        "tm",  // Trim Paths
        "mm",  // Merge Paths
        "rp",  // Repeater
        "gf",  // Gradient Fill
        "gs",  // Gradient Stroke
        "rd",  // Rounded Corners
    ]

    /// Validates the mediaInput layer for a given binding key.
    ///
    /// Rules:
    /// - mediaInput must exist (nm == "mediaInput", ty == 4)
    /// - mediaInput must contain exactly one path (sh)
    /// - mediaInput and binding layer (media) must be in the same composition
    /// - mediaInput must not contain forbidden modifiers (tm, mm, rp, gf, gs, rd)
    func validateMediaInput(
        animRef: String,
        lottie: LottieJSON,
        bindingKey: String,
        issues: inout [ValidationIssue]
    ) {
        // Collect all layers in all compositions with their comp context
        struct LayerInComp {
            let layer: LottieLayer
            let index: Int
            let compContext: String  // "layers" for root, "assets[id=X].layers" for precomp
        }

        var allLayers: [LayerInComp] = []

        // Root layers
        for (index, layer) in lottie.layers.enumerated() {
            allLayers.append(LayerInComp(layer: layer, index: index, compContext: "layers"))
        }

        // Precomp layers
        for asset in lottie.assets where asset.isPrecomp {
            for (index, layer) in (asset.layers ?? []).enumerated() {
                allLayers.append(LayerInComp(
                    layer: layer,
                    index: index,
                    compContext: "assets[id=\(asset.id)].layers"
                ))
            }
        }

        // Find mediaInput layer
        let mediaInputCandidates = allLayers.filter { $0.layer.name == Self.mediaInputLayerName }

        guard let mediaInput = mediaInputCandidates.first else {
            // mediaInput is required (temporarily downgraded to warning for testing)
            issues.append(ValidationIssue(
                code: AnimValidationCode.mediaInputMissing,
                severity: .warning,
                path: "anim(\(animRef)).layers[*].nm",
                message: "No layer with nm='\(Self.mediaInputLayerName)' found — required for interactive media input"
            ))
            return
        }

        let basePath = "anim(\(animRef)).\(mediaInput.compContext)[\(mediaInput.index)]"

        // Must be shape layer (ty=4)
        if mediaInput.layer.type != 4 {
            issues.append(ValidationIssue(
                code: AnimValidationCode.mediaInputNotShape,
                severity: .warning,
                path: "\(basePath).ty",
                message: "mediaInput must be a shape layer (ty=4), got ty=\(mediaInput.layer.type)"
            ))
            return
        }

        // Same-comp check: mediaInput and binding layer must be in the same composition
        let bindingCandidates = allLayers.filter { $0.layer.name == bindingKey }
        if let bindingLayer = bindingCandidates.first {
            if mediaInput.compContext != bindingLayer.compContext {
                issues.append(ValidationIssue(
                    code: AnimValidationCode.mediaInputNotInSameComp,
                    severity: .warning,
                    path: "\(basePath).nm",
                    message: "mediaInput (\(mediaInput.compContext)) must be in the same composition as '\(bindingKey)' (\(bindingLayer.compContext))"
                ))
            }
        }

        // Validate shapes
        guard let shapes = mediaInput.layer.shapes, !shapes.isEmpty else {
            issues.append(ValidationIssue(
                code: AnimValidationCode.mediaInputNoPath,
                severity: .warning,
                path: "\(basePath).shapes",
                message: "mediaInput must contain shapes with at least one path (sh)"
            ))
            return
        }

        // Check forbidden modifiers and count paths
        var pathCount = 0
        validateMediaInputShapes(
            shapes: shapes,
            basePath: "\(basePath).shapes",
            pathCount: &pathCount,
            issues: &issues
        )

        if pathCount == 0 {
            issues.append(ValidationIssue(
                code: AnimValidationCode.mediaInputNoPath,
                severity: .warning,
                path: "\(basePath).shapes",
                message: "mediaInput must contain exactly one shape path (sh), found 0"
            ))
        } else if pathCount > 1 {
            issues.append(ValidationIssue(
                code: AnimValidationCode.mediaInputMultiplePaths,
                severity: .warning,
                path: "\(basePath).shapes",
                message: "mediaInput must contain exactly one shape path, found \(pathCount)"
            ))
        }
    }

    /// Recursively validates mediaInput shapes for forbidden modifiers and counts paths
    private func validateMediaInputShapes(
        shapes: [ShapeItem],
        basePath: String,
        pathCount: inout Int,
        issues: inout [ValidationIssue]
    ) {
        for (index, shape) in shapes.enumerated() {
            switch shape {
            case .group(let group):
                // Recurse into group items
                if let items = group.items {
                    validateMediaInputShapes(
                        shapes: items,
                        basePath: "\(basePath)[\(index)].it",
                        pathCount: &pathCount,
                        issues: &issues
                    )
                }

            case .path:
                pathCount += 1

            case .rect:
                pathCount += 1

            case .ellipse:
                pathCount += 1

            case .polystar:
                pathCount += 1

            case .fill, .transform, .stroke:
                // Allowed in mediaInput — no action needed
                break

            case .unknown(let type):
                // Check forbidden modifiers by type string
                if Self.forbiddenMediaInputShapeTypes.contains(type) {
                    issues.append(ValidationIssue(
                        code: AnimValidationCode.mediaInputForbiddenModifier,
                        severity: .warning,
                        path: "\(basePath)[\(index)].ty",
                        message: "mediaInput contains forbidden shape modifier: '\(type)'"
                    ))
                }
            }
        }
    }

    // MARK: - Matte Pair Validation (PR-12, PR-27 tp-based)

    /// Validates matte source/consumer pairs in a layer list.
    ///
    /// For each consumer layer (tt != nil):
    /// - If tp != nil: validate via tp (ind-based lookup, order check).
    ///   td==1 is NOT required — tp-targets become implicit matte sources (PR-29).
    /// - If tp == nil: legacy adjacency (previous layer must be td==1)
    func validateMattePairs(
        layers: [LottieLayer],
        context: String,
        animRef: String,
        issues: inout [ValidationIssue]
    ) {
        // Build ind → arrayIndex lookup for tp-based resolution
        var indToArrayIndex: [Int: Int] = [:]
        for (arrayIndex, layer) in layers.enumerated() {
            if let ind = layer.index {
                indToArrayIndex[ind] = arrayIndex
            }
        }

        for (index, layer) in layers.enumerated() {
            let basePath = "anim(\(animRef)).\(context)[\(index)]"

            // Check if this layer is a matte consumer (has tt)
            if let trackMatteType = layer.trackMatteType,
               Self.supportedMatteTypes.contains(trackMatteType) {

                if let tp = layer.matteTarget {
                    // tp-based validation: resolve source via ind
                    guard let sourceArrayIndex = indToArrayIndex[tp] else {
                        issues.append(ValidationIssue(
                            code: AnimValidationCode.matteTargetNotFound,
                            severity: .error,
                            path: "\(basePath).tp",
                            message: "Matte target tp=\(tp) not found (no layer with ind=\(tp))"
                        ))
                        continue
                    }

                    // PR-29: td==1 is NOT required for tp-targets.
                    // tp-targets become implicit matte sources in the compiler.

                    // Source must appear before consumer in array
                    if sourceArrayIndex >= index {
                        issues.append(ValidationIssue(
                            code: AnimValidationCode.matteTargetInvalidOrder,
                            severity: .error,
                            path: "\(basePath).tp",
                            message: "Matte target tp=\(tp) at array index \(sourceArrayIndex) must appear before consumer at index \(index)"
                        ))
                    }
                } else {
                    // Legacy adjacency fallback (no tp)
                    if index == 0 {
                        issues.append(ValidationIssue(
                            code: AnimValidationCode.unsupportedMatteLayerMissing,
                            severity: .error,
                            path: "\(basePath).tt",
                            message: "Matte consumer (tt=\(trackMatteType)) at index 0 has no matte source layer above it"
                        ))
                        continue
                    }

                    let previousLayer = layers[index - 1]
                    let previousIsMatteSource = (previousLayer.isMatteSource ?? 0) == 1

                    if !previousIsMatteSource {
                        let prevPath = "anim(\(animRef)).\(context)[\(index - 1)]"
                        issues.append(ValidationIssue(
                            code: AnimValidationCode.unsupportedMatteLayerOrder,
                            severity: .error,
                            path: "\(prevPath).td",
                            message: "Layer before matte consumer (tt=\(trackMatteType)) must be matte source (td=1), but td=\(previousLayer.isMatteSource ?? 0)"
                        ))
                    }
                }
            }

            // PR-29: Matte source (td=1) CAN be a consumer (matte chains).
            // Removed unsupportedMatteSourceHasConsumer check per TL decision.
        }
    }

}
