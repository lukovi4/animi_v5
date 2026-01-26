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

    /// Compiles a Lottie animation into AnimIR
    ///
    /// - Parameters:
    ///   - lottie: Parsed Lottie JSON
    ///   - animRef: Animation reference identifier
    ///   - bindingKey: Layer name to bind for content replacement
    ///   - assetIndex: Asset index from AnimLoader
    /// - Returns: Compiled AnimIR
    /// - Throws: AnimIRCompilerError or UnsupportedFeature if compilation fails
    public func compile(
        lottie: LottieJSON,
        animRef: String,
        bindingKey: String,
        assetIndex: AssetIndex
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
            fallbackOp: lottie.outPoint
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
                fallbackOp: lottie.outPoint
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

        return AnimIR(
            meta: meta,
            rootComp: AnimIR.rootCompId,
            comps: comps,
            assets: assetsIR,
            binding: binding
        )
    }

    // MARK: - Layer Compilation

    /// Compiles an array of Lottie layers into IR layers with matte relationships
    private func compileLayers(
        _ lottieLayers: [LottieLayer],
        compId: CompID,
        animRef: String,
        fallbackOp: Double
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
                lottieLayer,
                index: index,
                compId: compId,
                animRef: animRef,
                fallbackOp: fallbackOp,
                matteInfo: matteInfo
            )
            layers.append(layer)
        }

        return layers
    }

    /// Compiles a single Lottie layer into IR layer
    private func compileLayer(
        _ lottie: LottieLayer,
        index: Int,
        compId: CompID,
        animRef: String,
        fallbackOp: Double,
        matteInfo: MatteInfo?
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

        // Build masks
        let masks = compileMasks(from: lottie.masksProperties)

        // Determine content (with namespaced asset IDs)
        let content = compileContent(from: lottie, layerType: layerType, animRef: animRef)

        // Check if this is a matte source
        let isMatteSource = (lottie.isMatteSource ?? 0) == 1

        return Layer(
            id: layerId,
            name: lottie.name ?? "Layer_\(index)",
            type: layerType,
            timing: timing,
            parent: lottie.parent,
            transform: transform,
            masks: masks,
            matte: matteInfo,
            content: content,
            isMatteSource: isMatteSource
        )
    }

    /// Compiles masks from Lottie mask properties
    private func compileMasks(from lottieMasks: [LottieMask]?) -> [Mask] {
        guard let lottieMasks = lottieMasks else { return [] }
        return lottieMasks.compactMap { Mask(from: $0) }
    }

    /// Compiles layer content based on type
    /// Image asset IDs are namespaced with animRef to avoid collisions across animations
    private func compileContent(
        from lottie: LottieLayer,
        layerType: LayerType,
        animRef: String
    ) -> LayerContent {
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
            // Extract animated shape data for matte source
            let animPath = ShapePathExtractor.extractAnimPath(from: lottie.shapes)
            let fillColor = ShapePathExtractor.extractFillColor(from: lottie.shapes)
            let fillOpacity = ShapePathExtractor.extractFillOpacity(from: lottie.shapes)

            return .shapes(ShapeGroup(
                animPath: animPath,
                fillColor: fillColor,
                fillOpacity: fillOpacity
            ))

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
}
