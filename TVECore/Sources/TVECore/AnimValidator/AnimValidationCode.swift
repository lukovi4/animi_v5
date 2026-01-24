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

    /// Mask mode not supported (mode != "a")
    public static let unsupportedMaskMode = "UNSUPPORTED_MASK_MODE"

    /// Inverted mask not supported (inv == true)
    public static let unsupportedMaskInvert = "UNSUPPORTED_MASK_INVERT"

    /// Animated mask path not supported (pt.a == 1)
    public static let unsupportedMaskPathAnimated = "UNSUPPORTED_MASK_PATH_ANIMATED"

    /// Animated mask opacity not supported (o.a == 1)
    public static let unsupportedMaskOpacityAnimated = "UNSUPPORTED_MASK_OPACITY_ANIMATED"

    /// Track matte type not supported (tt not in {1, 2})
    public static let unsupportedMatteType = "UNSUPPORTED_MATTE_TYPE"

    /// Shape item type not supported in matte source
    public static let unsupportedShapeItem = "UNSUPPORTED_SHAPE_ITEM"

    // MARK: - Warnings

    /// Animation size does not match input rect size
    public static let warningAnimSizeMismatch = "WARNING_ANIM_SIZE_MISMATCH"
}
