import CoreGraphics
import Foundation

/// Fully-resolved overlay item ready for rendering.
/// Produced by `OverlayResolver`, consumed by `OverlayCompositor`.
internal struct ResolvedOverlayRenderItem: Sendable {
    internal enum Kind: Sendable { case text, sticker }

    /// Content descriptor used as the cache key (position excluded).
    internal enum ContentDescriptor: Hashable, Sendable {
        case text(text: String, fontFamily: String?, fontSize: CGFloat, colorHex: String)
        case sticker(stickerId: String, imageURL: URL)
    }

    /// TimelineItem.id — item identity (NOT part of cache key).
    let stableId: UUID
    let kind: Kind
    /// Cache key (position excluded).
    let content: ContentDescriptor
    let presentation: OverlayPresentationState
    /// Lower = behind (stickers 0..N-1, text N..N+M-1).
    let zOrder: Int
}
