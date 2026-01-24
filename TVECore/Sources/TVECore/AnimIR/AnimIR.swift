import Foundation

/// Intermediate Representation of a Lottie animation
/// Provides a normalized, render-ready structure for the animation pipeline
public struct AnimIR: Sendable, Equatable {
    /// Animation metadata
    public let meta: Meta

    /// Root composition ID
    public let rootComp: CompID

    /// All compositions (root + precomps) keyed by ID
    public let comps: [CompID: Composition]

    /// Asset index (assetId -> relativePath)
    public let assets: AssetIndexIR

    /// Binding layer information
    public let binding: BindingInfo

    public init(
        meta: Meta,
        rootComp: CompID,
        comps: [CompID: Composition],
        assets: AssetIndexIR,
        binding: BindingInfo
    ) {
        self.meta = meta
        self.rootComp = rootComp
        self.comps = comps
        self.assets = assets
        self.binding = binding
    }

    /// Root composition ID constant
    public static let rootCompId: CompID = "__root__"
}

// MARK: - Render Commands Generation

extension AnimIR {
    /// Generates render commands for the given frame index
    /// Commands are in animation local space (0..w, 0..h)
    ///
    /// - Parameter frameIndex: Frame number to render
    /// - Returns: Array of render commands in execution order
    public func renderCommands(frameIndex: Int) -> [RenderCommand] {
        var commands: [RenderCommand] = []

        // Begin root group
        commands.append(.beginGroup(name: "AnimIR:\(meta.sourceAnimRef)"))

        // Render root composition
        if let rootComposition = comps[rootComp] {
            renderComposition(
                rootComposition,
                frameIndex: frameIndex,
                commands: &commands
            )
        }

        // End root group
        commands.append(.endGroup)

        return commands
    }

    /// Renders a composition recursively
    private func renderComposition(
        _ composition: Composition,
        frameIndex: Int,
        commands: inout [RenderCommand]
    ) {
        // Process layers in order (as they appear in JSON)
        for layer in composition.layers {
            renderLayer(layer, frameIndex: frameIndex, commands: &commands)
        }
    }

    /// Renders a single layer
    private func renderLayer(
        _ layer: Layer,
        frameIndex: Int,
        commands: inout [RenderCommand]
    ) {
        // Skip matte source layers - they don't render directly
        // They are referenced by consumer layers via BeginMatte commands
        if layer.isMatteSource {
            return
        }

        // Begin layer group
        commands.append(.beginGroup(name: "Layer:\(layer.name)(\(layer.id))"))

        // Push transform (placeholder identity in PR4, computed in PR5)
        commands.append(.pushTransform(.identity))

        // Handle matte - wrap content in matte begin/end
        if let matte = layer.matte {
            switch matte.mode {
            case .alpha:
                commands.append(.beginMatteAlpha(sourceLayerId: matte.sourceLayerId))
            case .alphaInverted:
                commands.append(.beginMatteAlphaInverted(sourceLayerId: matte.sourceLayerId))
            }
        }

        // Handle masks - apply before content
        let hasMasks = !layer.masks.isEmpty
        if hasMasks {
            for mask in layer.masks {
                if let staticPath = mask.path.staticPath {
                    commands.append(.beginMaskAdd(path: staticPath))
                }
            }
        }

        // Render content based on layer type
        renderLayerContent(layer, frameIndex: frameIndex, commands: &commands)

        // End masks (LIFO order)
        if hasMasks {
            for _ in layer.masks {
                commands.append(.endMask)
            }
        }

        // End matte
        if layer.matte != nil {
            commands.append(.endMatte)
        }

        // Pop transform
        commands.append(.popTransform)

        // End layer group
        commands.append(.endGroup)
    }

    /// Renders layer content based on type
    private func renderLayerContent(
        _ layer: Layer,
        frameIndex: Int,
        commands: inout [RenderCommand]
    ) {
        switch layer.content {
        case .image(let assetId):
            // Draw image with placeholder opacity (1.0 in PR4, computed in PR5)
            commands.append(.drawImage(assetId: assetId, opacity: 1.0))

        case .precomp(let compId):
            // Recursively render precomp composition
            if let precomp = comps[compId] {
                renderComposition(precomp, frameIndex: frameIndex, commands: &commands)
            }

        case .shapes:
            // Shape layers used as matte sources don't render directly
            // They're only used when referenced by BeginMatte commands
            break

        case .none:
            // Null layers have no visual content
            break
        }
    }
}

// MARK: - Lookup Helpers

extension AnimIR {
    /// Finds a layer by ID across all compositions
    public func findLayer(byId layerId: LayerID) -> (layer: Layer, compId: CompID)? {
        for (compId, comp) in comps {
            if let layer = comp.layers.first(where: { $0.id == layerId }) {
                return (layer, compId)
            }
        }
        return nil
    }

    /// Finds a layer by name across all compositions
    public func findLayer(byName name: String) -> (layer: Layer, compId: CompID)? {
        for (compId, comp) in comps {
            if let layer = comp.layers.first(where: { $0.name == name }) {
                return (layer, compId)
            }
        }
        return nil
    }

    /// Gets the root composition
    public var rootComposition: Composition? {
        comps[rootComp]
    }
}
