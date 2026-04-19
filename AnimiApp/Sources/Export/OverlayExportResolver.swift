import Foundation
import TVECore

// MARK: - Overlay Export Snapshot

/// Fully-flattened, pre-resolved, Sendable snapshot of overlay items for export.
/// Built once before the export loop; consumed per-frame by `OverlayExportResolver`.
internal struct OverlayExportSnapshot: Sendable {
    struct TextItem: Sendable {
        let startUs: TimeUs
        let endUs: TimeUs
        let text: String
        let fontFamily: String?
        let fontSize: CGFloat
        let colorHex: String
        let centerX: CGFloat
        let centerY: CGFloat
    }
    struct StickerItem: Sendable {
        let startUs: TimeUs
        let endUs: TimeUs
        let stickerId: String
        let imageURL: URL
        let centerX: CGFloat
        let centerY: CGFloat
    }
    let textItems: [TextItem]
    let stickerItems: [StickerItem]
}

// MARK: - Factory A: from CanonicalTimeline (single-scene path)

extension OverlayExportSnapshot {
    static func build(
        from timeline: CanonicalTimeline,
        stickerProvider: StickerProviding?
    ) -> OverlayExportSnapshot {
        guard let overlayTrack = timeline.overlayTrack else {
            return OverlayExportSnapshot(textItems: [], stickerItems: [])
        }

        var textItems: [TextItem] = []
        var stickerItems: [StickerItem] = []

        for item in overlayTrack.items {
            let itemStart = item.startUs ?? 0
            let itemEnd = itemStart + item.durationUs

            switch item.kind {
            case .text:
                guard let payload = timeline.payloads[item.payloadId],
                      case .text(let textPayload) = payload else { continue }
                textItems.append(TextItem(
                    startUs: itemStart,
                    endUs: itemEnd,
                    text: textPayload.text,
                    fontFamily: textPayload.fontFamily,
                    fontSize: textPayload.fontSize ?? 32,
                    colorHex: textPayload.colorHex ?? "#FFFFFF",
                    centerX: textPayload.centerX,
                    centerY: textPayload.centerY
                ))
            case .sticker:
                guard let payload = timeline.payloads[item.payloadId],
                      case .sticker(let stickerPayload) = payload,
                      let imageURL = stickerProvider?.resourceURL(for: stickerPayload.stickerId) else { continue }
                stickerItems.append(StickerItem(
                    startUs: itemStart,
                    endUs: itemEnd,
                    stickerId: stickerPayload.stickerId,
                    imageURL: imageURL,
                    centerX: stickerPayload.centerX,
                    centerY: stickerPayload.centerY
                ))
            default:
                break
            }
        }

        return OverlayExportSnapshot(textItems: textItems, stickerItems: stickerItems)
    }
}

// MARK: - Factory B: from session tuples (timeline path)

extension OverlayExportSnapshot {
    static func build(
        textOverlayItems: [(item: TimelineItem, payload: TextPayload)],
        stickerOverlayItems: [(item: TimelineItem, payload: StickerPayload, imageURL: URL)]
    ) -> OverlayExportSnapshot {
        let textItems = textOverlayItems.map { (item, payload) in
            let itemStart = item.startUs ?? 0
            return TextItem(
                startUs: itemStart,
                endUs: itemStart + item.durationUs,
                text: payload.text,
                fontFamily: payload.fontFamily,
                fontSize: payload.fontSize ?? 32,
                colorHex: payload.colorHex ?? "#FFFFFF",
                centerX: payload.centerX,
                centerY: payload.centerY
            )
        }
        let stickerItems = stickerOverlayItems.map { (item, payload, imageURL) in
            let itemStart = item.startUs ?? 0
            return StickerItem(
                startUs: itemStart,
                endUs: itemStart + item.durationUs,
                stickerId: payload.stickerId,
                imageURL: imageURL,
                centerX: payload.centerX,
                centerY: payload.centerY
            )
        }
        return OverlayExportSnapshot(textItems: textItems, stickerItems: stickerItems)
    }
}

// MARK: - Resolver: pure time-range filter

internal enum OverlayExportResolver {
    /// Resolves text overlays visible at the given time (half-open: startUs <= timeUs < endUs).
    static func resolveText(from snapshot: OverlayExportSnapshot, at timeUs: TimeUs) -> [ResolvedTextOverlay] {
        snapshot.textItems.compactMap { item in
            guard timeUs >= item.startUs && timeUs < item.endUs else { return nil }
            return ResolvedTextOverlay(
                text: item.text,
                fontFamily: item.fontFamily,
                fontSize: item.fontSize,
                colorHex: item.colorHex,
                centerX: item.centerX,
                centerY: item.centerY
            )
        }
    }

    /// Resolves sticker overlays visible at the given time (half-open: startUs <= timeUs < endUs).
    static func resolveSticker(from snapshot: OverlayExportSnapshot, at timeUs: TimeUs) -> [ResolvedStickerOverlay] {
        snapshot.stickerItems.compactMap { item in
            guard timeUs >= item.startUs && timeUs < item.endUs else { return nil }
            return ResolvedStickerOverlay(
                stickerId: item.stickerId,
                imageURL: item.imageURL,
                centerX: item.centerX,
                centerY: item.centerY
            )
        }
    }
}
