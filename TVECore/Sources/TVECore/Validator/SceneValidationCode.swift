import Foundation

/// Stable validation error and warning codes for scene validation
public enum SceneValidationCode {
    // MARK: - Errors

    /// Schema version is not supported
    public static let sceneUnsupportedVersion = "SCENE_UNSUPPORTED_VERSION"

    /// Canvas width or height is invalid (zero or negative)
    public static let canvasInvalidDimensions = "CANVAS_INVALID_DIMENSIONS"

    /// Canvas FPS is invalid (zero or negative)
    public static let canvasInvalidFPS = "CANVAS_INVALID_FPS"

    /// Canvas duration is invalid (zero or negative)
    public static let canvasInvalidDuration = "CANVAS_INVALID_DURATION"

    /// MediaBlocks array is empty
    public static let blocksEmpty = "BLOCKS_EMPTY"

    /// Duplicate block ID found
    public static let blockIdDuplicate = "BLOCK_ID_DUPLICATE"

    /// Rect has invalid dimensions (zero, negative, or non-finite values)
    public static let rectInvalid = "RECT_INVALID"

    /// Variants array is empty
    public static let variantsEmpty = "VARIANTS_EMPTY"

    /// Variant animRef is empty
    public static let variantAnimRefEmpty = "VARIANT_ANIMREF_EMPTY"

    /// Input bindingKey is empty
    public static let inputBindingKeyEmpty = "INPUT_BINDINGKEY_EMPTY"

    /// ContainerClip value is not supported in Part 1
    public static let containerClipUnsupported = "CONTAINERCLIP_UNSUPPORTED"

    /// AllowedMedia array is empty
    public static let allowedMediaEmpty = "ALLOWEDMEDIA_EMPTY"

    /// AllowedMedia contains an invalid value
    public static let allowedMediaInvalidValue = "ALLOWEDMEDIA_INVALID_VALUE"

    /// AllowedMedia contains duplicate values
    public static let allowedMediaDuplicate = "ALLOWEDMEDIA_DUPLICATE"

    /// Timing range is invalid
    public static let timingInvalidRange = "TIMING_INVALID_RANGE"

    /// Variant defaultDurationFrames is invalid (zero or negative)
    public static let variantDefaultDurationInvalid = "VARIANT_DEFAULTDURATION_INVALID"

    /// Variant loopRange is invalid
    public static let variantLoopRangeInvalid = "VARIANT_LOOPRANGE_INVALID"

    // MARK: - Warnings

    /// Block extends outside canvas bounds
    public static let blockOutsideCanvas = "BLOCK_OUTSIDE_CANVAS"

    /// MaskRef specified but mask catalog is not available
    public static let maskRefCatalogUnavailable = "MASKREF_CATALOG_UNAVAILABLE"

    /// MaskRef not found in the mask catalog
    public static let maskRefNotFound = "MASKREF_NOT_FOUND"
}
