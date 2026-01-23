import Foundation

/// Variant represents an animation variant for a media block
public struct Variant: Decodable, Equatable, Sendable {
    /// Unique identifier for this variant
    public let id: String

    /// Reference to the animation file (e.g., "anim-1.json")
    public let animRef: String

    /// Default duration in frames
    public let defaultDurationFrames: Int?

    /// Behavior when animation is shorter than scene duration
    public let ifAnimationShorter: AnimationDurationBehavior?

    /// Behavior when animation is longer than scene duration
    public let ifAnimationLonger: AnimationDurationBehavior?

    /// Whether the animation should loop
    public let loop: Bool?

    /// Loop range for looping animations
    public let loopRange: LoopRange?

    public init(
        id: String,
        animRef: String,
        defaultDurationFrames: Int? = nil,
        ifAnimationShorter: AnimationDurationBehavior? = nil,
        ifAnimationLonger: AnimationDurationBehavior? = nil,
        loop: Bool? = nil,
        loopRange: LoopRange? = nil
    ) {
        self.id = id
        self.animRef = animRef
        self.defaultDurationFrames = defaultDurationFrames
        self.ifAnimationShorter = ifAnimationShorter
        self.ifAnimationLonger = ifAnimationLonger
        self.loop = loop
        self.loopRange = loopRange
    }

    private enum CodingKeys: String, CodingKey {
        case id = "variantId"
        case animRef
        case defaultDurationFrames
        case ifAnimationShorter
        case ifAnimationLonger
        case loop
        case loopRange
    }
}

/// Behavior when animation duration doesn't match scene duration
public enum AnimationDurationBehavior: String, Decodable, Equatable, Sendable {
    /// Hold the last frame
    case holdLastFrame

    /// Cut the animation at the boundary
    case cut

    /// Loop the animation
    case loop
}

/// Range for looping animations
public struct LoopRange: Decodable, Equatable, Sendable {
    /// Start frame for the loop
    public let startFrame: Int

    /// End frame for the loop
    public let endFrame: Int

    public init(startFrame: Int, endFrame: Int) {
        self.startFrame = startFrame
        self.endFrame = endFrame
    }
}
