import Foundation
import TVECore

// MARK: - Export Background Snapshot

/// Lightweight descriptor for background media in export.
///
/// Contains slot keys and resolved URLs — NO live MTLTextures.
/// Built from the draft's background regions and effective background state.
/// Loaded via `BackgroundTextureService` + `DownsampledImageLoader` (not live preview provider).
public struct ExportBackgroundSnapshot: Sendable {

    // MARK: - Background Region Reference

    /// Reference to a background image for export.
    public struct BackgroundRegionRef: Sendable, Equatable {
        /// Texture slot key (e.g., "bg/wave_split/top")
        public let slotKey: String

        /// Media reference for the background image
        public let mediaRef: MediaRef

        /// Region ID
        public let regionId: String
    }

    // MARK: - Properties

    /// All background region references that need loading
    public let regionRefs: [BackgroundRegionRef]

    /// Preset ID for slot key generation
    public let presetId: String

    // MARK: - Factory

    /// Scene-aware factory: resolves scene override → project override for export.
    public static func build(
        from projectOverride: ProjectBackgroundOverride?,
        sceneOverride: ProjectBackgroundOverride?,
        effectiveState: EffectiveBackgroundState?
    ) -> ExportBackgroundSnapshot? {
        let resolvedOverride = sceneOverride ?? projectOverride
        return build(from: resolvedOverride, effectiveState: effectiveState)
    }

    /// Builds an ExportBackgroundSnapshot from a resolved override and effective state.
    ///
    /// - Parameters:
    ///   - override: Resolved background override with MediaRefs
    ///   - effectiveState: Effective background state with preset info
    /// - Returns: Snapshot with background region references, or nil if no backgrounds to load
    public static func build(
        from override: ProjectBackgroundOverride?,
        effectiveState: EffectiveBackgroundState?
    ) -> ExportBackgroundSnapshot? {
        guard let override, let effectiveState else { return nil }

        let presetId = effectiveState.preset.presetId
        var regionRefs: [BackgroundRegionRef] = []

        for (regionId, regionOverride) in override.regions {
            // Only image regions are supported by the export texture loader
            // (DownsampledImageLoader). Video/animated are rendered as solid
            // black by the background renderer and need no snapshot entry.
            guard let mediaRef = regionOverride.imageMediaRef else { continue }

            let slotKey = EffectiveBackgroundBuilder.makeSlotKey(
                presetId: presetId,
                regionId: regionId
            )

            regionRefs.append(BackgroundRegionRef(
                slotKey: slotKey,
                mediaRef: mediaRef,
                regionId: regionId
            ))
        }

        guard !regionRefs.isEmpty else { return nil }

        return ExportBackgroundSnapshot(
            regionRefs: regionRefs,
            presetId: presetId
        )
    }
}
