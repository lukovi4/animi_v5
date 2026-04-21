import Metal
import TVECore

/// Retained-mode per-item GPU compositor for overlay items.
/// One draw pass, one render encoder, all items in one command list.
internal enum OverlayCompositor {

    /// Composites resolved overlay items onto the render target.
    /// Uses per-item cached textures and center-pivot transforms.
    ///
    /// - Parameters:
    ///   - items: Resolved overlay items sorted by zOrder.
    ///   - cache: Per-owner texture cache (preview or export).
    ///   - target: Render target to composite onto.
    ///   - renderer: Metal renderer.
    ///   - commandBuffer: Active command buffer.
    ///   - device: Metal device.
    ///   - canvasSize: Canvas size in logical units.
    ///   - clearColorOverride: Optional clear color override.
    static func compose(
        items: [ResolvedOverlayRenderItem],
        cache: OverlayRenderResourceCache,
        target: RenderTarget,
        renderer: MetalRenderer,
        commandBuffer: MTLCommandBuffer,
        device: MTLDevice,
        canvasSize: SizeD,
        clearColorOverride: ClearColor? = nil
    ) throws {
        guard !items.isEmpty else { return }

        let provider = ThreadSafeInMemoryTextureProvider()
        var assetSizes: [String: AssetSize] = [:]
        var commands: [RenderCommand] = []

        let pixelWidth = target.texture.width

        // OverlayResolver already returns items in stable zOrder.
        // No re-sort needed — iterate in provided order.
        for item in items {
            guard let cached = cache.texture(
                for: item,
                device: device,
                canvasSize: canvasSize,
                canvasPixelWidth: pixelWidth
            ) else { continue }

            let assetId = "__overlay_\(item.stableId.uuidString)"
            provider.setTexture(cached.texture, for: assetId)

            // Compute asset size in canvas coordinates
            let assetCanvasWidth: Double
            let assetCanvasHeight: Double

            switch item.kind {
            case .text:
                // Text: convert pixel dimensions back to canvas units
                let pixelToCanvas = canvasSize.width / Double(pixelWidth)
                assetCanvasWidth = Double(cached.contentWidth) * pixelToCanvas
                assetCanvasHeight = Double(cached.contentHeight) * pixelToCanvas
            case .sticker:
                // Sticker: 15% of canvas width, aspect-fit (current contract)
                let targetCanvasWidth = canvasSize.width * 0.15
                let imageAspect = Double(cached.contentWidth) / max(1, Double(cached.contentHeight))
                if imageAspect >= 1.0 {
                    assetCanvasWidth = targetCanvasWidth
                    assetCanvasHeight = targetCanvasWidth / imageAspect
                } else {
                    assetCanvasHeight = targetCanvasWidth
                    assetCanvasWidth = targetCanvasWidth * imageAspect
                }
            }

            assetSizes[assetId] = AssetSize(width: assetCanvasWidth, height: assetCanvasHeight)

            // Build center-pivot transform
            let presentation = item.presentation
            let cx = Double(presentation.centerX) * canvasSize.width
            let cy = Double(presentation.centerY) * canvasSize.height
            let hw = assetCanvasWidth / 2.0
            let hh = assetCanvasHeight / 2.0

            // Transform order (applied right-to-left in concatenation):
            // 1. Offset quad so its center is at origin: translate(-hw, -hh)
            // 2. Apply scale around origin
            // 3. Apply rotation around origin
            // 4. Translate to final canvas position: translate(cx, cy)
            let itemTransform = Matrix2D.translation(x: cx, y: cy)
                .concatenating(Matrix2D.rotation(Double(presentation.rotation)))
                .concatenating(Matrix2D.scale(Double(presentation.scale)))
                .concatenating(Matrix2D.translation(x: -hw, y: -hh))

            commands.append(.pushTransform(itemTransform))
            commands.append(.drawImage(assetId: assetId, opacity: Double(presentation.opacity)))
            commands.append(.popTransform)
        }

        // Single draw pass with .load to preserve existing target content
        if let clearColor = clearColorOverride {
            try renderer.draw(
                commands: commands,
                target: target,
                clearColor: clearColor,
                textureProvider: provider,
                commandBuffer: commandBuffer,
                assetSizes: assetSizes,
                pathRegistry: PathRegistry(),
                backgroundState: nil,
                initialLoadAction: .load
            )
        } else {
            try renderer.draw(
                commands: commands,
                target: target,
                textureProvider: provider,
                commandBuffer: commandBuffer,
                assetSizes: assetSizes,
                pathRegistry: PathRegistry(),
                backgroundState: nil,
                initialLoadAction: .load
            )
        }
    }
}
