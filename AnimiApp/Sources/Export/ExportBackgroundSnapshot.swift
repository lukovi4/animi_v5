import Foundation
import TVECore

// MARK: - Export Background Snapshot

/// Lightweight descriptor for background media in export.
///
/// Contains slot keys and resolved URLs — NO live MTLTextures.
/// Built from `projectBackgroundOverride` + `effectiveBackgroundState`.
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

    /// Builds an ExportBackgroundSnapshot from project override and effective state.
    ///
    /// - Parameters:
    ///   - override: Project background override with MediaRefs
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
