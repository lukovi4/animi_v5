import CoreGraphics
import Foundation
import TVECore

/// Unified overlay resolver for both preview and export paths.
/// Replaces `TimelineCompositionEngine.resolveTextOverlays/resolveStickerOverlays`
/// and `OverlayExportResolver.resolveText/resolveSticker`.
internal enum OverlayResolver {

    // MARK: - Preview path: resolve from CanonicalTimeline

    /// Resolves overlay items visible at the given time from a live timeline.
    /// Z-order: stickers 0..N-1, text N..N+M-1 (stickers below text).
    ///
    /// `excludedOverlayIds` omits exactly those items from the result. This is
    /// used only by the preview path to hide the committed Metal copy of a text
    /// overlay while it is being transformed live by the Core Animation layer, so
    /// there is no ghost/duplicate. The export path never excludes anything.
    static func resolve(
        from timeline: CanonicalTimeline,
        at timeUs: TimeUs,
        stickerProvider: StickerProviding?,
        excludedOverlayIds: Set<UUID> = []
    ) -> [ResolvedOverlayRenderItem] {
        guard let overlayTrack = timeline.overlayTrack else { return [] }

        var stickerItems: [ResolvedOverlayRenderItem] = []
        var textItems: [ResolvedOverlayRenderItem] = []

        // Two passes in track order to produce stable z-ordering.
        // Pass 1: stickers
        for item in overlayTrack.items where item.kind == .sticker {
            guard !excludedOverlayIds.contains(item.id) else { continue }
            let itemStart = item.startUs ?? 0
            let itemEnd = itemStart + item.durationUs
            guard timeUs >= itemStart && timeUs < itemEnd else { continue }

            guard let payload = timeline.payloads[item.payloadId],
                  case .sticker(let stickerPayload) = payload,
                  let imageURL = stickerProvider?.resourceURL(for: stickerPayload.stickerId) else { continue }

            stickerItems.append(ResolvedOverlayRenderItem(
                stableId: item.id,
                kind: .sticker,
                content: .sticker(stickerId: stickerPayload.stickerId, imageURL: imageURL),
                presentation: .default(centerX: stickerPayload.centerX, centerY: stickerPayload.centerY),
                zOrder: stickerItems.count
            ))
        }

        // Pass 2: text
        let stickerCount = stickerItems.count
        for item in overlayTrack.items where item.kind == .text {
            guard !excludedOverlayIds.contains(item.id) else { continue }
            let itemStart = item.startUs ?? 0
            let itemEnd = itemStart + item.durationUs
            guard timeUs >= itemStart && timeUs < itemEnd else { continue }

            guard let payload = timeline.payloads[item.payloadId],
                  case .text(let textPayload) = payload else { continue }

            textItems.append(ResolvedOverlayRenderItem(
                stableId: item.id,
                kind: .text,
                content: .text(
                    text: textPayload.geometry.text,
                    fontFamily: textPayload.style.fontFamily,
                    fontSize: textPayload.style.fontSize,
                    colorHex: textPayload.style.colorHex,
                    boxWidth: textPayload.geometry.boxWidth
                ),
                presentation: .text(
                    centerX: textPayload.geometry.centerX,
                    centerY: textPayload.geometry.centerY,
                    rotation: textPayload.geometry.rotation
                ),
                zOrder: stickerCount + textItems.count
            ))
        }

        return stickerItems + textItems
    }

    // MARK: - Export path: resolve from OverlayExportSnapshot

    /// Resolves overlay items visible at the given time from a pre-built snapshot.
    /// Z-order: stickers 0..N-1, text N..N+M-1 (stickers below text).
    static func resolve(
        from snapshot: OverlayExportSnapshot,
        at timeUs: TimeUs
    ) -> [ResolvedOverlayRenderItem] {
        var stickerItems: [ResolvedOverlayRenderItem] = []
        var textItems: [ResolvedOverlayRenderItem] = []

        // Pass 1: stickers (in snapshot order = track order)
        for item in snapshot.stickerItems {
            guard timeUs >= item.startUs && timeUs < item.endUs else { continue }

            stickerItems.append(ResolvedOverlayRenderItem(
                stableId: item.itemId,
                kind: .sticker,
                content: .sticker(stickerId: item.stickerId, imageURL: item.imageURL),
                presentation: .default(centerX: item.centerX, centerY: item.centerY),
                zOrder: stickerItems.count
            ))
        }

        // Pass 2: text (in snapshot order = track order)
        let stickerCount = stickerItems.count
        for item in snapshot.textItems {
            guard timeUs >= item.startUs && timeUs < item.endUs else { continue }

            textItems.append(ResolvedOverlayRenderItem(
                stableId: item.itemId,
                kind: .text,
                content: .text(
                    text: item.text,
                    fontFamily: item.fontFamily,
                    fontSize: item.fontSize,
                    colorHex: item.colorHex,
                    boxWidth: item.boxWidth
                ),
                presentation: .text(centerX: item.centerX, centerY: item.centerY, rotation: item.rotation),
                zOrder: stickerCount + textItems.count
            ))
        }

        return stickerItems + textItems
    }
}
