import Foundation

/// Stable validation error and warning codes for animation validation
public enum AnimValidationCode {
    // MARK: - Root/FPS Errors

    /// Animation frame rate does not match scene canvas fps
    public static let animFPSMismatch = "ANIM_FPS_MISMATCH"

    /// Animation root properties are invalid (w/h/fr <= 0 or op <= ip)
    public static let animRootInvalid = "ANIM_ROOT_INVALID"

    // MARK: - Binding Layer Errors

    /// No binding layer found with matching name
    public static let bindingLayerNotFound = "BINDING_LAYER_NOT_FOUND"

    /// Multiple binding layers found with matching name
    public static let bindingLayerAmbiguous = "BINDING_LAYER_AMBIGUOUS"

    /// Binding layer is not an image layer (ty != 2)
    public static let bindingLayerNotImage = "BINDING_LAYER_NOT_IMAGE"

    /// Binding layer has no asset reference (refId empty or missing)
    public static let bindingLayerNoAsset = "BINDING_LAYER_NO_ASSET"

    // MARK: - Asset Errors

    /// Referenced image asset file is missing
    public static let assetMissing = "ASSET_MISSING"

    /// Precomp reference not found in assets
    public static let precompRefMissing = "PRECOMP_REF_MISSING"

    // MARK: - Unsupported Feature Errors

    /// Layer type not supported (ty not in {0, 2, 3, 4})
    public static let unsupportedLayerType = "UNSUPPORTED_LAYER_TYPE"

    /// Mask mode not supported (only a/s/i allowed)
    public static let unsupportedMaskMode = "UNSUPPORTED_MASK_MODE"

    /// Inverted mask not supported (legacy code, inv is now allowed)
    public static let unsupportedMaskInvert = "UNSUPPORTED_MASK_INVERT"

    /// Animated mask path not supported (pt.a == 1)
    public static let unsupportedMaskPathAnimated = "UNSUPPORTED_MASK_PATH_ANIMATED"

    /// Animated mask opacity not supported (o.a == 1)
    public static let unsupportedMaskOpacityAnimated = "UNSUPPORTED_MASK_OPACITY_ANIMATED"

    /// Track matte type not supported (tt not in {1, 2, 3, 4})
    public static let unsupportedMatteType = "UNSUPPORTED_MATTE_TYPE"

    /// Shape item type not supported in matte source
    public static let unsupportedShapeItem = "UNSUPPORTED_SHAPE_ITEM"

    /// Animated rectangle roundness not supported (topology changes between keyframes)
    public static let unsupportedRectRoundnessAnimated = "UNSUPPORTED_RECT_ROUNDNESS_ANIMATED"

    /// Rectangle position and size keyframes have mismatched count or times
    public static let unsupportedRectKeyframesMismatch = "UNSUPPORTED_RECT_KEYFRAMES_MISMATCH"

    /// Rectangle keyframe has invalid format (missing time or startValue)
    public static let unsupportedRectKeyframeFormat = "UNSUPPORTED_RECT_KEYFRAME_FORMAT"

    /// Ellipse position and size keyframes have mismatched count or times
    public static let unsupportedEllipseKeyframesMismatch = "UNSUPPORTED_ELLIPSE_KEYFRAMES_MISMATCH"

    /// Ellipse keyframe has invalid format (missing time, startValue, or unparseable)
    public static let unsupportedEllipseKeyframeFormat = "UNSUPPORTED_ELLIPSE_KEYFRAME_FORMAT"

    /// Ellipse has invalid size (width or height <= 0)
    public static let unsupportedEllipseInvalidSize = "UNSUPPORTED_ELLIPSE_INVALID_SIZE"

    /// Polystar has invalid star type (sy not 1 or 2)
    public static let unsupportedPolystarStarType = "UNSUPPORTED_POLYSTAR_STAR_TYPE"

    /// Polystar points are animated (pt.a == 1) - topology would change
    public static let unsupportedPolystarPointsAnimated = "UNSUPPORTED_POLYSTAR_POINTS_ANIMATED"

    /// Polystar points have invalid format (not a number)
    public static let unsupportedPolystarPointsFormat = "UNSUPPORTED_POLYSTAR_POINTS_FORMAT"

    /// Polystar points value is not an integer
    public static let unsupportedPolystarPointsNonInteger = "UNSUPPORTED_POLYSTAR_POINTS_NON_INTEGER"

    /// Polystar points value is invalid (< 3 or > 100)
    public static let unsupportedPolystarPointsInvalid = "UNSUPPORTED_POLYSTAR_POINTS_INVALID"

    /// Polystar roundness is animated (is.a or os.a == 1)
    public static let unsupportedPolystarRoundnessAnimated = "UNSUPPORTED_POLYSTAR_ROUNDNESS_ANIMATED"

    /// Polystar roundness is non-zero (not supported in PR-09)
    public static let unsupportedPolystarRoundnessNonzero = "UNSUPPORTED_POLYSTAR_ROUNDNESS_NONZERO"

    /// Polystar has invalid radius (or <= 0, or for star: ir <= 0 or ir >= or)
    public static let unsupportedPolystarInvalidRadius = "UNSUPPORTED_POLYSTAR_INVALID_RADIUS"

    /// Polystar animated keyframes have mismatched count or times
    public static let unsupportedPolystarKeyframesMismatch = "UNSUPPORTED_POLYSTAR_KEYFRAMES_MISMATCH"

    /// Polystar keyframe has invalid format (missing time, startValue, or unparseable)
    public static let unsupportedPolystarKeyframeFormat = "UNSUPPORTED_POLYSTAR_KEYFRAME_FORMAT"

    /// Path keyframes have mismatched topology (vertex count or closed flag differ)
    public static let pathTopologyMismatch = "PATH_TOPOLOGY_MISMATCH"

    /// Path keyframes are missing or invalid
    public static let pathKeyframesMissing = "PATH_KEYFRAMES_MISSING"

    // MARK: - Mask Expansion Errors

    /// Animated mask expansion not supported (x.a == 1)
    public static let unsupportedMaskExpansionAnimated = "UNSUPPORTED_MASK_EXPANSION_ANIMATED"

    /// Non-zero static mask expansion not supported (x.k != 0)
    public static let unsupportedMaskExpansionNonZero = "UNSUPPORTED_MASK_EXPANSION_NONZERO"

    /// Mask expansion value has invalid/unrecognized format
    public static let unsupportedMaskExpansionFormat = "UNSUPPORTED_MASK_EXPANSION_FORMAT"

    // MARK: - Forbidden Layer Flags

    /// 3D layer not supported (ddd == 1)
    public static let unsupportedLayer3D = "UNSUPPORTED_LAYER_3D"

    /// Auto-orient not supported (ao == 1)
    public static let unsupportedLayerAutoOrient = "UNSUPPORTED_LAYER_AUTO_ORIENT"

    /// Non-default time stretch not supported (sr != 1)
    public static let unsupportedLayerStretch = "UNSUPPORTED_LAYER_STRETCH"

    /// Collapse transform not supported (ct != 0)
    public static let unsupportedLayerCollapseTransform = "UNSUPPORTED_LAYER_COLLAPSE_TRANSFORM"

    /// Blend mode not supported (bm != 0)
    public static let unsupportedBlendMode = "UNSUPPORTED_BLEND_MODE"

    // MARK: - Transform Errors

    /// Skew transform not supported (sk != 0 or sk animated)
    public static let unsupportedSkew = "UNSUPPORTED_SKEW"

    // MARK: - Warnings

    /// Animation size does not match input rect size
    public static let warningAnimSizeMismatch = "WARNING_ANIM_SIZE_MISMATCH"
}
