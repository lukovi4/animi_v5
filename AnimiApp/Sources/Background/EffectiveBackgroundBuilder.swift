import Foundation
import TVECore

// MARK: - Effective Background Builder

/// Builds EffectiveBackgroundState from template defaults, preset library, and user overrides.
///
/// Priority (highest to lowest):
/// 1. User override (from ProjectBackgroundOverride)
/// 2. Template defaults (from scene.background.defaults)
/// 3. Fallback (solid black)
public enum EffectiveBackgroundBuilder {

    // MARK: - Public API

    /// Builds the effective background state for rendering.
    ///
    /// - Parameters:
    ///   - templateBackground: Background configuration from scene.json (may be nil)
    ///   - projectOverride: User's customizations (may be nil)
    ///   - presetLibrary: Library of available presets
    /// - Returns: EffectiveBackgroundState ready for rendering
    public static func build(
        templateBackground: Background?,
        projectOverride: ProjectBackgroundOverride?,
        presetLibrary: BackgroundPresetLibrary
    ) -> EffectiveBackgroundState? {

        // 1. Determine effective preset ID
        let effectivePresetId = resolvePresetId(
            templateBackground: templateBackground,
            projectOverride: projectOverride
        )

        // 2. Get preset from library (with fallback)
        guard let preset = presetLibrary.presetOrFallback(for: effectivePresetId) else {
            #if DEBUG
            print("[EffectiveBackgroundBuilder] ERROR: No preset found for '\(effectivePresetId)' and no fallback available")
            #endif
            return nil
        }

        // 3. Build region states
        var regionStates: [String: BackgroundRegionState] = [:]

        for regionPreset in preset.regions {
            let regionId = regionPreset.regionId

            let source = resolveRegionSource(
                regionId: regionId,
                presetId: preset.presetId,
                templateBackground: templateBackground,
                projectOverride: projectOverride
            )

            regionStates[regionId] = BackgroundRegionState(
                regionId: regionId,
                source: source
            )
        }

        return EffectiveBackgroundState(
            preset: preset,
            regionStates: regionStates
        )
    }

    // MARK: - Preset Resolution

    /// Resolves the effective preset ID.
    private static func resolvePresetId(
        templateBackground: Background?,
        projectOverride: ProjectBackgroundOverride?
    ) -> String {
        // Priority 1: User override
        if let overridePresetId = projectOverride?.selectedPresetId {
            return overridePresetId
        }

        // Priority 2: Template background
        if let background = templateBackground {
            return background.effectivePresetId
        }

        // Fallback: solid_fullscreen
        return BackgroundPresetLibrary.fallbackPresetId
    }

    // MARK: - Region Source Resolution

    /// Resolves the source for a single region.
    private static func resolveRegionSource(
        regionId: String,
        presetId: String,
        templateBackground: Background?,
        projectOverride: ProjectBackgroundOverride?
    ) -> RegionSource {

        // Priority 1: User override
        if let regionOverride = projectOverride?.regions[regionId] {
            return convertOverrideToSource(regionOverride.source, presetId: presetId, regionId: regionId)
        }

        // Priority 2: Template defaults
        if let defaults = templateBackground?.defaults,
           let regionDefault = defaults[regionId] {
            return convertDefaultToSource(regionDefault, presetId: presetId, regionId: regionId)
        }

        // Priority 3: Legacy solid color (for type="solid" templates)
        if let background = templateBackground,
           background.type == "solid",
           let colorHex = background.effectiveColor {
            let color = HexColorParser.parseOrBlack(colorHex)
            return .solid(SolidConfig(color: color))
        }

        // Fallback: solid black
        return .solid(SolidConfig(color: ClearColor(r: 0, g: 0, b: 0, a: 1)))
    }

    // MARK: - Conversion Helpers

    /// Converts a user override to a render source.
    private static func convertOverrideToSource(
        _ override: RegionSourceOverride,
        presetId: String,
        regionId: String
    ) -> RegionSource {
        switch override {
        case .solid(let colorHex):
            let color = HexColorParser.parseOrBlack(colorHex)
            return .solid(SolidConfig(color: color))

        case .gradient(let gradientOverride):
            return convertGradientOverride(gradientOverride)

        case .image(let imageOverride):
            let slotKey = makeSlotKey(presetId: presetId, regionId: regionId)
            let transform = convertTransformOverride(imageOverride.transform)
            return .image(ImageConfig(slotKey: slotKey, transform: transform))
        }
    }

    /// Converts a template default to a render source.
    private static func convertDefaultToSource(
        _ regionDefault: RegionDefault,
        presetId: String,
        regionId: String
    ) -> RegionSource {
        switch regionDefault.sourceType {
        case "solid":
            if let colorHex = regionDefault.solidColor {
                let color = HexColorParser.parseOrBlack(colorHex)
                return .solid(SolidConfig(color: color))
            }
            return .solid(SolidConfig(color: ClearColor(r: 0, g: 0, b: 0, a: 1)))

        case "gradient":
            if let gradientLinear = regionDefault.gradientLinear {
                return convertGradientLinearDefault(gradientLinear)
            }
            // Fallback if gradient config missing
            return .solid(SolidConfig(color: ClearColor(r: 0, g: 0, b: 0, a: 1)))

        case "image":
            // Template defaults cannot specify image (no MediaRef)
            // Log and fallback to solid black
            #if DEBUG
            print("[EffectiveBackgroundBuilder] WARNING: Template default specifies 'image' source type, which is not supported. Falling back to solid black.")
            #endif
            return .solid(SolidConfig(color: ClearColor(r: 0, g: 0, b: 0, a: 1)))

        default:
            #if DEBUG
            print("[EffectiveBackgroundBuilder] WARNING: Unknown source type '\(regionDefault.sourceType)'. Falling back to solid black.")
            #endif
            return .solid(SolidConfig(color: ClearColor(r: 0, g: 0, b: 0, a: 1)))
        }
    }

    /// Converts a gradient override to render config.
    private static func convertGradientOverride(_ override: GradientOverride) -> RegionSource {
        // Validate: v1 requires exactly 2 stops
        guard override.stops.count == 2 else {
            #if DEBUG
            print("[EffectiveBackgroundBuilder] WARNING: Gradient has \(override.stops.count) stops, expected 2. Falling back to solid black.")
            #endif
            return .solid(SolidConfig(color: ClearColor(r: 0, g: 0, b: 0, a: 1)))
        }

        let stops = override.stops.map { stop in
            BackgroundGradientStop(
                t: stop.t,
                color: HexColorParser.parseOrBlack(stop.colorHex)
            )
        }

        let config = GradientConfig(
            stops: stops,
            p0: Vec2D(x: override.p0.x, y: override.p0.y),
            p1: Vec2D(x: override.p1.x, y: override.p1.y)
        )

        return .gradient(config)
    }

    /// Converts a template gradient default to render config.
    private static func convertGradientLinearDefault(_ gradientLinear: GradientLinearDefault) -> RegionSource {
        // Validate: v1 requires exactly 2 stops
        guard gradientLinear.stops.count == 2 else {
            #if DEBUG
            print("[EffectiveBackgroundBuilder] WARNING: Gradient has \(gradientLinear.stops.count) stops, expected 2. Falling back to solid black.")
            #endif
            return .solid(SolidConfig(color: ClearColor(r: 0, g: 0, b: 0, a: 1)))
        }

        let stops = gradientLinear.stops.map { stop in
            BackgroundGradientStop(
                t: stop.position,
                color: HexColorParser.parseOrBlack(stop.color)
            )
        }

        let config = GradientConfig(
            stops: stops,
            p0: gradientLinear.p0,
            p1: gradientLinear.p1
        )

        return .gradient(config)
    }

    /// Converts a transform override to render transform.
    private static func convertTransformOverride(_ override: BgImageTransformOverride) -> ImageTransform {
        let fitMode: BackgroundFitMode
        switch override.fitMode.lowercased() {
        case "fit":
            fitMode = .fit
        default:
            fitMode = .fill
        }

        return ImageTransform(
            pan: Vec2D(x: override.pan.x, y: override.pan.y),
            zoom: override.zoom,
            rotationRadians: override.rotationRadians,
            flipX: override.flipX,
            flipY: override.flipY,
            fitMode: fitMode
        )
    }

    // MARK: - Slot Key Generation

    /// Generates the canonical slot key for a background image texture.
    /// Format: `bg/<presetId>/<regionId>`
    public static func makeSlotKey(presetId: String, regionId: String) -> String {
        "bg/\(presetId)/\(regionId)"
    }

    /// Generates the prefix for all slot keys of a preset.
    /// Used for cleanup when preset changes.
    public static func slotKeyPrefix(for presetId: String) -> String {
        "bg/\(presetId)/"
    }
}
