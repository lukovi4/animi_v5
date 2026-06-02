import CoreGraphics
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

            // Text boxes may sit off-canvas; clip their draw to the canvas rect
            // so out-of-bounds text disappears under the template edge (matches
            // the selection-border clip in OverlayPositionDragView and export).
            let clipsToCanvas = (item.kind == .text)
            if clipsToCanvas {
                commands.append(.pushClipRect(RectD(x: 0, y: 0, width: canvasSize.width, height: canvasSize.height)))
            }
            commands.append(.pushTransform(itemTransform))
            commands.append(.drawImage(assetId: assetId, opacity: Double(presentation.opacity)))
            commands.append(.popTransform)
            if clipsToCanvas {
                commands.append(.popClipRect)
            }
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

// MARK: - Preview Tap Hit Testing

/// Pure rectangular hit testing for preview overlay tap selection (timeline mode).
///
/// Mirrors `OverlayCompositor.compose` geometry: each item is centered at
/// `(centerX * canvasW, centerY * canvasH)` in canvas units with an axis-aligned
/// rectangle sized from the rendered content size. Items are tested in reverse
/// z-order so the topmost rendered item (text over sticker) wins on overlap.
///
/// GPU-free and dependency-injected via `contentCanvasSize`, so it is unit
/// testable without a Metal device or texture cache.
internal enum OverlayPreviewHitTester {

    /// Result identifying which overlay item a tap selected.
    internal enum Hit: Equatable {
        case text(itemId: UUID)
        case sticker(itemId: UUID)
    }

    /// Returns the topmost overlay item hit by `viewPoint`, or `nil` for an
    /// empty-space tap.
    ///
    /// - Parameters:
    ///   - viewPoint: Tap location in preview view coordinates (same space as the
    ///     canvas-to-view transform's output).
    ///   - items: Visible overlay items for the current frame, in render z-order
    ///     (stickers below text). Tested in reverse so text wins on overlap.
    ///   - canvasSize: Canvas size in logical units.
    ///   - viewSize: Preview view size in points.
    ///   - minTouchTargetPoints: Minimum touch target edge length in view points.
    ///     Tiny rendered bounds expand to at least this size without changing the
    ///     drawn overlay.
    ///   - contentCanvasSize: Rendered content size in canvas units for an item
    ///     (text: pixel dimensions converted to canvas units; sticker: 15% canvas
    ///     width aspect-fit). Returns `nil` when unavailable; the minimum touch
    ///     target still applies in that case.
    static func hitTest(
        viewPoint: CGPoint,
        items: [ResolvedOverlayRenderItem],
        canvasSize: SizeD,
        viewSize: CGSize,
        minTouchTargetPoints: CGFloat,
        contentCanvasSize: (ResolvedOverlayRenderItem) -> CGSize?
    ) -> Hit? {
        guard canvasSize.width > 0, canvasSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return nil }

        var mapper = EditorCanvasMapper()
        mapper.canvasSize = canvasSize
        mapper.viewSize = viewSize

        let canvasPoint = mapper.viewToCanvas(viewPoint)

        // Convert the minimum touch target from view points to canvas units using
        // the aspect-fit scale (canvas units per point = 1 / pointsPerCanvasUnit).
        let scale = mapper.scale()
        let minTargetCanvas = scale > 0 ? minTouchTargetPoints / scale : minTouchTargetPoints

        // Reverse z-order: topmost rendered item wins (text over sticker).
        for item in items.reversed() {
            let cx = item.presentation.centerX * CGFloat(canvasSize.width)
            let cy = item.presentation.centerY * CGFloat(canvasSize.height)
            let center = CGPoint(x: cx, y: cy)

            let content = contentCanvasSize(item) ?? .zero
            let targetSize = CGSize(
                width: max(content.width, minTargetCanvas),
                height: max(content.height, minTargetCanvas)
            )

            switch item.kind {
            case .text:
                // Rotated box test: text honors its persisted rotation so the
                // selectable region matches the drawn (rotated) text box.
                guard TextOverlayLayout.contains(
                    point: canvasPoint,
                    center: center,
                    size: targetSize,
                    rotation: item.presentation.rotation
                ) else { continue }
                return .text(itemId: item.stableId)
            case .sticker:
                // Sticker hit testing stays axis-aligned (unchanged contract).
                let rect = CGRect(
                    x: cx - targetSize.width / 2,
                    y: cy - targetSize.height / 2,
                    width: targetSize.width,
                    height: targetSize.height
                )
                guard rect.contains(canvasPoint) else { continue }
                return .sticker(itemId: item.stableId)
            }
        }

        return nil
    }

    /// Rendered content size in canvas units for an item, matching
    /// `OverlayCompositor.compose` sizing. `contentWidth`/`contentHeight` are the
    /// cached texture's pixel dimensions; `canvasPixelWidth` is the target texture
    /// width in pixels.
    ///
    /// Returns `nil` when pixel inputs are non-positive.
    static func contentCanvasSize(
        kind: ResolvedOverlayRenderItem.Kind,
        contentWidth: Int,
        contentHeight: Int,
        canvasSize: SizeD,
        canvasPixelWidth: Int
    ) -> CGSize? {
        guard contentWidth > 0, contentHeight > 0, canvasPixelWidth > 0,
              canvasSize.width > 0 else { return nil }

        switch kind {
        case .text:
            let pixelToCanvas = canvasSize.width / Double(canvasPixelWidth)
            return CGSize(
                width: Double(contentWidth) * pixelToCanvas,
                height: Double(contentHeight) * pixelToCanvas
            )
        case .sticker:
            let targetCanvasWidth = canvasSize.width * 0.15
            let imageAspect = Double(contentWidth) / max(1, Double(contentHeight))
            if imageAspect >= 1.0 {
                return CGSize(width: targetCanvasWidth, height: targetCanvasWidth / imageAspect)
            } else {
                return CGSize(width: targetCanvasWidth * imageAspect, height: targetCanvasWidth)
            }
        }
    }
}
