/// The content of a global timeline overlay (Task-002 plan, §6.4).
///
/// Text/sticker/graphic payloads are global timeline elements and are never scene layers.
public enum OverlayContent: Equatable, Sendable {
    case text(TextContentReference)
    case sticker(ImageReference)
    case graphic(ImageReference)
}
