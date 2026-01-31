import Foundation

// MARK: - Unsupported Feature Error

/// Error thrown when the compiler encounters an unsupported Lottie feature
public struct UnsupportedFeature: Error, Sendable {
    /// Error code for categorization
    public let code: String

    /// Human-readable error message
    public let message: String

    /// Path/context where the error occurred
    public let path: String

    public init(code: String, message: String, path: String) {
        self.code = code
        self.message = message
        self.path = path
    }
}

extension UnsupportedFeature: LocalizedError {
    public var errorDescription: String? {
        "[\(code)] \(message) at \(path)"
    }
}

// MARK: - Compiler Error

/// Errors that can occur during AnimIR compilation
public enum AnimIRCompilerError: Error, Sendable {
    case bindingLayerNotFound(bindingKey: String, animRef: String)
    case bindingLayerNotImage(bindingKey: String, layerType: Int, animRef: String)
    case bindingLayerNoAsset(bindingKey: String, animRef: String)
    case unsupportedLayerType(layerType: Int, layerName: String, animRef: String)
    case mediaInputNotInSameComp(animRef: String, mediaInputCompId: String, bindingCompId: String)
}

extension AnimIRCompilerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .bindingLayerNotFound(let key, let animRef):
            return "Binding layer '\(key)' not found in \(animRef)"
        case .bindingLayerNotImage(let key, let layerType, let animRef):
            return "Binding layer '\(key)' must be image (ty=2), got ty=\(layerType) in \(animRef)"
        case .bindingLayerNoAsset(let key, let animRef):
            return "Binding layer '\(key)' has no asset reference in \(animRef)"
        case .unsupportedLayerType(let layerType, let layerName, let animRef):
            return "Unsupported layer type \(layerType) for layer '\(layerName)' in \(animRef)"
        case .mediaInputNotInSameComp(let animRef, let mediaInputCompId, let bindingCompId):
            return "mediaInput (comp=\(mediaInputCompId)) must be in same composition as binding layer (comp=\(bindingCompId)) in \(animRef)"
        }
    }
}

// MARK: - Asset ID Namespacing

/// Separator used for asset ID namespacing
private let assetIdNamespaceSeparator = "|"

/// Creates a namespaced asset ID from animRef and original Lottie asset ID.
/// Format: "<animRef>|<lottieAssetId>" e.g. "anim-1.json|image_0"
private func namespacedAssetId(animRef: String, assetId: String) -> String {
    "\(animRef)\(assetIdNamespaceSeparator)\(assetId)"
}

// MARK: - AnimIR Compiler

/// Compiles LottieJSON into AnimIR representation
public final class AnimIRCompiler {
    public init() {}

    /// Compiles a Lottie animation into AnimIR with scene-level path registry.
    ///
    /// This is the preferred method for scene compilation. PathIDs are assigned
    /// deterministically during compilation into the shared registry.
    ///
    /// - Parameters:
    ///   - lottie: Parsed Lottie JSON
    ///   - animRef: Animation reference identifier
    ///   - bindingKey: Layer name to bind for content replacement
    ///   - assetIndex: Asset index from AnimLoader
    ///   - pathRegistry: Scene-level path registry (shared across all animations)
    /// - Returns: Compiled AnimIR (with pathRegistry field empty - use scene-level registry)
    /// - Throws: AnimIRCompilerError or UnsupportedFeature if compilation fails
    public func compile(
        lottie: LottieJSON,
        animRef: String,
        bindingKey: String,
        assetIndex: AssetIndex,
        pathRegistry: inout PathRegistry
    ) throws -> AnimIR {
        // Build metadata
        let meta = Meta(
            width: lottie.width,
            height: lottie.height,
            fps: lottie.frameRate,
            inPoint: lottie.inPoint,
            outPoint: lottie.outPoint,
            sourceAnimRef: animRef
        )

        var comps: [CompID: Composition] = [:]

        // Build root composition
        let rootSize = SizeD(width: lottie.width, height: lottie.height)
        let rootLayers = try compileLayers(
            lottie.layers,
            compId: AnimIR.rootCompId,
            animRef: animRef,
            fallbackOp: lottie.outPoint,
            pathRegistry: &pathRegistry
        )
        comps[AnimIR.rootCompId] = Composition(
            id: AnimIR.rootCompId,
            size: rootSize,
            layers: rootLayers
        )

        // Build precomp compositions from assets
        for asset in lottie.assets where asset.isPrecomp {
            guard let assetLayers = asset.layers else { continue }

            let compId = asset.id
            let compSize = SizeD(
                width: asset.width ?? lottie.width,
                height: asset.height ?? lottie.height
            )
            let layers = try compileLayers(
                assetLayers,
                compId: compId,
                animRef: animRef,
                fallbackOp: lottie.outPoint,
                pathRegistry: &pathRegistry
            )
            comps[compId] = Composition(id: compId, size: compSize, layers: layers)
        }

        // Find binding layer
        let binding = try findBindingLayer(
            bindingKey: bindingKey,
            comps: comps,
            animRef: animRef
        )

        // Build asset index IR with namespaced keys
        var namespacedById: [String: String] = [:]
        var namespacedSizeById: [String: AssetSize] = [:]

        for (originalId, path) in assetIndex.byId {
            let nsId = namespacedAssetId(animRef: animRef, assetId: originalId)
            namespacedById[nsId] = path
        }

        for asset in lottie.assets where asset.isImage {
            if let width = asset.width, let height = asset.height {
                let nsId = namespacedAssetId(animRef: animRef, assetId: asset.id)
                namespacedSizeById[nsId] = AssetSize(width: width, height: height)
            }
        }

        let assetsIR = AssetIndexIR(byId: namespacedById, sizeById: namespacedSizeById)

        // PR-15: Find mediaInput layer and build InputGeometryInfo
        let inputGeometry = try findMediaInput(
            comps: comps,
            binding: binding,
            animRef: animRef,
            pathRegistry: &pathRegistry
        )

        // Return AnimIR with empty local pathRegistry
        // Scene pipeline uses scene-level registry, not AnimIR.pathRegistry
        return AnimIR(
            meta: meta,
            rootComp: AnimIR.rootCompId,
            comps: comps,
            assets: assetsIR,
            binding: binding,
            pathRegistry: PathRegistry(), // Empty - scene uses merged registry
            inputGeometry: inputGeometry
        )
    }

    /// Compiles a Lottie animation into AnimIR (legacy/standalone mode).
    ///
    /// This method creates a local PathRegistry and registers paths into it.
    /// Use `compile(..., pathRegistry:)` for scene compilation with shared registry.
    ///
    /// - Parameters:
    ///   - lottie: Parsed Lottie JSON
    ///   - animRef: Animation reference identifier
    ///   - bindingKey: Layer name to bind for content replacement
    ///   - assetIndex: Asset index from AnimLoader
    /// - Returns: Compiled AnimIR with paths registered in local pathRegistry
    /// - Throws: AnimIRCompilerError or UnsupportedFeature if compilation fails
    @available(*, deprecated, message: "Use compile(..., pathRegistry:) for scene-level path registration")
    public func compile(
        lottie: LottieJSON,
        animRef: String,
        bindingKey: String,
        assetIndex: AssetIndex
    ) throws -> AnimIR {
        var localRegistry = PathRegistry()
        var animIR = try compile(
            lottie: lottie,
            animRef: animRef,
            bindingKey: bindingKey,
            assetIndex: assetIndex,
            pathRegistry: &localRegistry
        )
        // For standalone usage, store local registry in AnimIR
        animIR.pathRegistry = localRegistry
        return animIR
    }

    // MARK: - Layer Compilation

    /// Compiles an array of Lottie layers into IR layers with matte relationships
    private func compileLayers(
        _ lottieLayers: [LottieLayer],
        compId: CompID,
        animRef: String,
        fallbackOp: Double,
        pathRegistry: inout PathRegistry
    ) throws -> [Layer] {
        // First pass: identify matte source → consumer relationships
        // In Lottie, matte source (td=1) is immediately followed by consumer (tt=1|2)
        var matteSourceForConsumer: [LayerID: LayerID] = [:]

        for (index, lottieLayer) in lottieLayers.enumerated() where (lottieLayer.isMatteSource ?? 0) == 1 {
            let sourceId = lottieLayer.index ?? index
            // The next layer is the consumer
            if index + 1 < lottieLayers.count {
                let consumerLayer = lottieLayers[index + 1]
                let consumerId = consumerLayer.index ?? (index + 1)
                matteSourceForConsumer[consumerId] = sourceId
            }
        }

        // Second pass: compile all layers with matte info
        var layers: [Layer] = []

        for (index, lottieLayer) in lottieLayers.enumerated() {
            let layerId = lottieLayer.index ?? index

            // Build matte info if this layer is a consumer
            var matteInfo: MatteInfo?
            if let trackMatteType = lottieLayer.trackMatteType,
               let mode = MatteMode(trackMatteType: trackMatteType),
               let sourceId = matteSourceForConsumer[layerId] {
                matteInfo = MatteInfo(mode: mode, sourceLayerId: sourceId)
            }

            let layer = try compileLayer(
                lottie: lottieLayer,
                index: index,
                compId: compId,
                animRef: animRef,
                fallbackOp: fallbackOp,
                matteInfo: matteInfo,
                pathRegistry: &pathRegistry
            )
            layers.append(layer)
        }

        return layers
    }

    /// Compiles a single Lottie layer into IR layer
    private func compileLayer(
        lottie: LottieLayer,
        index: Int,
        compId: CompID,
        animRef: String,
        fallbackOp: Double,
        matteInfo: MatteInfo?,
        pathRegistry: inout PathRegistry
    ) throws -> Layer {
        // Determine layer ID (from ind or index)
        let layerId: LayerID = lottie.index ?? index

        // Determine layer type
        guard let layerType = LayerType(lottieType: lottie.type) else {
            throw AnimIRCompilerError.unsupportedLayerType(
                layerType: lottie.type,
                layerName: lottie.name ?? "unnamed",
                animRef: animRef
            )
        }

        // Build timing
        let timing = LayerTiming(
            ip: lottie.inPoint,
            op: lottie.outPoint,
            st: lottie.startTime,
            fallbackOp: fallbackOp
        )

        // Build transform
        let transform = TransformTrack(from: lottie.transform)

        // Build masks with path registration
        let layerName = lottie.name ?? "Layer_\(index)"
        let masks = try compileMasks(
            from: lottie.masksProperties,
            animRef: animRef,
            layerName: layerName,
            pathRegistry: &pathRegistry
        )

        // Determine content (with namespaced asset IDs and path registration for shapeMatte)
        let content = try compileContent(
            from: lottie,
            layerType: layerType,
            animRef: animRef,
            layerName: layerName,
            pathRegistry: &pathRegistry
        )

        // Check if this is a matte source
        let isMatteSource = (lottie.isMatteSource ?? 0) == 1

        // PR-15: Hidden flag (hd=true)
        let isHidden = lottie.hidden ?? false

        return Layer(
            id: layerId,
            name: layerName,
            type: layerType,
            timing: timing,
            parent: lottie.parent,
            transform: transform,
            masks: masks,
            matte: matteInfo,
            content: content,
            isMatteSource: isMatteSource,
            isHidden: isHidden
        )
    }

    /// Compiles masks from Lottie mask properties with path registration
    /// - Throws: UnsupportedFeature if mask path cannot be triangulated
    private func compileMasks(
        from lottieMasks: [LottieMask]?,
        animRef: String,
        layerName: String,
        pathRegistry: inout PathRegistry
    ) throws -> [Mask] {
        guard let lottieMasks = lottieMasks else { return [] }

        var masks: [Mask] = []

        for (index, lottieMask) in lottieMasks.enumerated() {
            guard var mask = Mask(from: lottieMask) else {
                throw UnsupportedFeature(
                    code: "UNSUPPORTED_MASK_MODE",
                    message: "Unknown mask mode '\(lottieMask.mode ?? "nil")' - only add/subtract/intersect (a/s/i) supported",
                    path: "anim(\(animRef)).layer(\(layerName)).mask[\(index)]"
                )
            }

            // Build PathResource with dummy PathID - rely only on assignedId from register()
            guard let resource = PathResourceBuilder.build(from: mask.path, pathId: PathID(0)) else {
                throw UnsupportedFeature(
                    code: "MASK_PATH_BUILD_FAILED",
                    message: "Cannot triangulate/flatten mask path (topology mismatch or too few vertices)",
                    path: "anim(\(animRef)).layer(\(layerName)).mask[\(index)]"
                )
            }

            // Register path and use only the assigned ID
            let assignedId = pathRegistry.register(resource)
            mask.pathId = assignedId

            masks.append(mask)
        }

        return masks
    }

    /// Compiles layer content based on type with path registration for shapeMatte
    /// Image asset IDs are namespaced with animRef to avoid collisions across animations
    /// - Throws: UnsupportedFeature if shapeMatte path cannot be triangulated
    private func compileContent(
        from lottie: LottieLayer,
        layerType: LayerType,
        animRef: String,
        layerName: String,
        pathRegistry: inout PathRegistry
    ) throws -> LayerContent {
        switch layerType {
        case .image:
            if let refId = lottie.refId, !refId.isEmpty {
                // Namespace the asset ID to avoid collisions across different animations
                let nsAssetId = namespacedAssetId(animRef: animRef, assetId: refId)
                return .image(assetId: nsAssetId)
            }
            return .none

        case .precomp:
            // Precomp IDs are local to AnimIR, no namespacing needed
            if let refId = lottie.refId, !refId.isEmpty {
                return .precomp(compId: refId)
            }
            return .none

        case .shapeMatte:
            // PR-13: Validate no Trim Paths before extraction (defensive check)
            try ShapePathExtractor.validateNoTrimPaths(
                shapes: lottie.shapes,
                basePath: "anim(\(animRef)).layer(\(layerName))"
            )

            // Extract animated shape data for matte source
            let animPath = ShapePathExtractor.extractAnimPath(from: lottie.shapes)
            let fillColor = ShapePathExtractor.extractFillColor(from: lottie.shapes)
            let fillOpacity = ShapePathExtractor.extractFillOpacity(from: lottie.shapes)

            // Extract stroke style (PR-10)
            let strokeStyle = ShapePathExtractor.extractStrokeStyle(from: lottie.shapes)

            // Extract group transforms stack (PR-11) - list of transforms from nested groups
            // Returns nil if extraction fails (invalid data: skew, non-uniform scale, keyframe issues)
            guard let groupTransforms = ShapePathExtractor.extractGroupTransforms(from: lottie.shapes) else {
                throw UnsupportedFeature(
                    code: AnimValidationCode.unsupportedGroupTransformKeyframeFormat,
                    message: "Invalid group transform data (skew, non-uniform scale, or keyframe format error)",
                    path: "anim(\(animRef)).layer(\(layerName)).shapeMatte.groupTransform"
                )
            }

            var shapeGroup = ShapeGroup(
                animPath: animPath,
                fillColor: fillColor,
                fillOpacity: fillOpacity,
                stroke: strokeStyle,
                groupTransforms: groupTransforms
            )

            // Register path if animPath exists
            if let animPath = animPath {
                // Build PathResource with dummy PathID - rely only on assignedId from register()
                guard let resource = PathResourceBuilder.build(from: animPath, pathId: PathID(0)) else {
                    throw UnsupportedFeature(
                        code: "MATTE_PATH_BUILD_FAILED",
                        message: "Cannot triangulate/flatten matte shape path (topology mismatch or too few vertices)",
                        path: "anim(\(animRef)).layer(\(layerName)).shapeMatte"
                    )
                }

                // Register path and use only the assigned ID
                let assignedId = pathRegistry.register(resource)
                shapeGroup.pathId = assignedId
            }

            return .shapes(shapeGroup)

        case .null:
            return .none
        }
    }

    // MARK: - Binding Layer

    /// Finds the binding layer across all compositions
    private func findBindingLayer(
        bindingKey: String,
        comps: [CompID: Composition],
        animRef: String
    ) throws -> BindingInfo {
        // Search in deterministic order: root first, then precomps by sorted ID
        let sortedCompIds = comps.keys.sorted { lhs, rhs in
            if lhs == AnimIR.rootCompId { return true }
            if rhs == AnimIR.rootCompId { return false }
            return lhs < rhs
        }

        for compId in sortedCompIds {
            guard let comp = comps[compId] else { continue }

            for layer in comp.layers where layer.name == bindingKey {
                // Verify it's an image layer
                guard layer.type == .image else {
                    throw AnimIRCompilerError.bindingLayerNotImage(
                        bindingKey: bindingKey,
                        layerType: layer.type.rawValue,
                        animRef: animRef
                    )
                }

                // Verify it has an asset reference
                guard case .image(let assetId) = layer.content else {
                    throw AnimIRCompilerError.bindingLayerNoAsset(
                        bindingKey: bindingKey,
                        animRef: animRef
                    )
                }

                return BindingInfo(
                    bindingKey: bindingKey,
                    boundLayerId: layer.id,
                    boundAssetId: assetId,
                    boundCompId: compId
                )
            }
        }

        throw AnimIRCompilerError.bindingLayerNotFound(
            bindingKey: bindingKey,
            animRef: animRef
        )
    }

    // MARK: - MediaInput (PR-15)

    /// Canonical layer name for the interactive input area
    private static let mediaInputLayerName = "mediaInput"

    /// Finds the mediaInput layer and builds InputGeometryInfo.
    /// Returns nil if no mediaInput layer exists (optional feature).
    /// Throws if mediaInput exists but violates constraints (e.g. not in same comp as binding).
    private func findMediaInput(
        comps: [CompID: Composition],
        binding: BindingInfo,
        animRef: String,
        pathRegistry: inout PathRegistry
    ) throws -> InputGeometryInfo? {
        // Search all compositions for a shape layer named "mediaInput"
        let sortedCompIds = comps.keys.sorted { lhs, rhs in
            if lhs == AnimIR.rootCompId { return true }
            if rhs == AnimIR.rootCompId { return false }
            return lhs < rhs
        }

        for compId in sortedCompIds {
            guard let comp = comps[compId] else { continue }

            for layer in comp.layers where layer.name == Self.mediaInputLayerName {
                // Must be a shape layer (ty=4 → .shapeMatte in IR)
                guard layer.type == .shapeMatte else {
                    continue
                }

                // Same-comp constraint: mediaInput must be in same composition as binding layer
                guard compId == binding.boundCompId else {
                    throw AnimIRCompilerError.mediaInputNotInSameComp(
                        animRef: animRef,
                        mediaInputCompId: compId,
                        bindingCompId: binding.boundCompId
                    )
                }

                // Extract the shape path from the layer's content
                guard case .shapes(let shapeGroup) = layer.content,
                      let animPath = shapeGroup.animPath else {
                    // No extractable path — skip silently (validator will catch this)
                    return nil
                }

                // Register the path in the shared registry for GPU rendering
                guard let resource = PathResourceBuilder.build(from: animPath, pathId: PathID(0)) else {
                    // Path build failed — skip (validator will report detailed error)
                    return nil
                }

                let assignedId = pathRegistry.register(resource)

                return InputGeometryInfo(
                    layerId: layer.id,
                    pathId: assignedId,
                    animPath: animPath,
                    compId: compId
                )
            }
        }

        // No mediaInput found — that's OK, it's optional
        return nil
    }
}
