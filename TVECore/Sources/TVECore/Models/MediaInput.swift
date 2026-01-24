import Foundation

/// MediaInput defines the editable input slot within a media block
public struct MediaInput: Decodable, Equatable, Sendable {
    /// Rectangle defining the input slot position in local block coordinates
    public let rect: Rect

    /// Key used to bind this input to the replaceable placeholder in the animation
    public let bindingKey: String

    /// Hit test mode for tap detection
    public let hitTest: HitTestMode?

    /// Allowed media types for this input slot
    public let allowedMedia: [String]

    /// Policy for handling empty input
    public let emptyPolicy: EmptyPolicy?

    /// Allowed fit modes for media placement
    public let fitModesAllowed: [FitMode]?

    /// Default fit mode for newly placed media
    public let defaultFit: FitMode?

    /// User transform permissions
    public let userTransformsAllowed: UserTransformsAllowed?

    /// Audio configuration
    public let audio: AudioConfig?

    /// Reference to a mask asset for UI interaction (optional)
    public let maskRef: String?

    public init(
        rect: Rect,
        bindingKey: String,
        hitTest: HitTestMode? = nil,
        allowedMedia: [String],
        emptyPolicy: EmptyPolicy? = nil,
        fitModesAllowed: [FitMode]? = nil,
        defaultFit: FitMode? = nil,
        userTransformsAllowed: UserTransformsAllowed? = nil,
        audio: AudioConfig? = nil,
        maskRef: String? = nil
    ) {
        self.rect = rect
        self.bindingKey = bindingKey
        self.hitTest = hitTest
        self.allowedMedia = allowedMedia
        self.emptyPolicy = emptyPolicy
        self.fitModesAllowed = fitModesAllowed
        self.defaultFit = defaultFit
        self.userTransformsAllowed = userTransformsAllowed
        self.audio = audio
        self.maskRef = maskRef
    }
}

/// Allowed media types for input slots
public enum AllowedMediaType: String, CaseIterable, Sendable {
    case photo
    case video
    case color
}

/// Hit test mode for tap detection
public enum HitTestMode: String, Decodable, Equatable, Sendable {
    /// Use exact mask shape for hit testing
    case mask

    /// Use bounding rectangle for hit testing
    case rect
}

/// Policy for handling empty input slots
public enum EmptyPolicy: String, Decodable, Equatable, Sendable {
    /// Hide the entire block when input is empty
    case hideWholeBlock

    /// Render with color fallback when input is empty
    case renderWithColorFallback
}

/// Media fit modes
public enum FitMode: String, Decodable, Equatable, Sendable {
    /// Scale to cover the entire area (may crop)
    case cover

    /// Scale to fit within the area (may letterbox)
    case contain

    /// Stretch to fill the area exactly
    case fill
}

/// User transform permissions
public struct UserTransformsAllowed: Decodable, Equatable, Sendable {
    /// Whether panning is allowed
    public let pan: Bool

    /// Whether zooming is allowed
    public let zoom: Bool

    /// Whether rotation is allowed
    public let rotate: Bool

    public init(pan: Bool, zoom: Bool, rotate: Bool) {
        self.pan = pan
        self.zoom = zoom
        self.rotate = rotate
    }
}

/// Audio configuration for video inputs
public struct AudioConfig: Decodable, Equatable, Sendable {
    /// Whether audio is enabled
    public let enabled: Bool

    /// Audio gain multiplier
    public let gain: Double

    public init(enabled: Bool, gain: Double = 1.0) {
        self.enabled = enabled
        self.gain = gain
    }
}
