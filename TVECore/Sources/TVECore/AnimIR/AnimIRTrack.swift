import Foundation

// swiftlint:disable line_length

// MARK: - Keyframe

/// Single keyframe in an animation track
public struct Keyframe<T: Sendable & Equatable>: Sendable, Equatable {
    // Note: Codable conformance via conditional extension below
    /// Time in frames
    public let time: Double

    /// Value at this keyframe
    public let value: T

    /// Easing in tangent (bezier control point)
    public let inTangent: Vec2D?

    /// Easing out tangent (bezier control point)
    public let outTangent: Vec2D?

    /// Hold flag - if true, value holds until next keyframe (no interpolation)
    public let hold: Bool

    public init(
        time: Double,
        value: T,
        inTangent: Vec2D? = nil,
        outTangent: Vec2D? = nil,
        hold: Bool = false
    ) {
        self.time = time
        self.value = value
        self.inTangent = inTangent
        self.outTangent = outTangent
        self.hold = hold
    }
}

// MARK: - Keyframe Codable

extension Keyframe: Codable where T: Codable {}

// MARK: - Animation Track

/// Animated or static value track
public enum AnimTrack<T: Sendable & Equatable>: Sendable, Equatable {
    // Note: Codable conformance via conditional extension below
    /// Static (non-animated) value
    case `static`(T)

    /// Keyframed animation
    case keyframed([Keyframe<T>])

    /// Returns true if this track has animation
    public var isAnimated: Bool {
        switch self {
        case .static:
            return false
        case .keyframed(let keyframes):
            return keyframes.count > 1
        }
    }

    /// Returns the static value or the first keyframe value
    public var staticValue: T? {
        switch self {
        case .static(let value):
            return value
        case .keyframed(let keyframes):
            return keyframes.first?.value
        }
    }
}

// MARK: - AnimTrack Codable

extension AnimTrack: Codable where T: Codable {}

// MARK: - Linear Interpolation

/// Linear interpolation for Double values
public func lerp(_ from: Double, _ to: Double, _ factor: Double) -> Double {
    from + (to - from) * factor
}

/// Linear interpolation for Vec2D values
public func lerp(_ from: Vec2D, _ to: Vec2D, _ factor: Double) -> Vec2D {
    Vec2D(
        x: lerp(from.x, to.x, factor),
        y: lerp(from.y, to.y, factor)
    )
}

// MARK: - AnimTrack Sampling

extension AnimTrack where T == Double {
    /// Samples the track at the given frame using linear interpolation
    /// - Parameter frame: Frame number (can be fractional)
    /// - Returns: Interpolated value at the given frame
    public func sample(frame: Double) -> Double {
        switch self {
        case .static(let value):
            return value
        case .keyframed(let keyframes):
            return sampleKeyframes(keyframes, at: frame)
        }
    }

    private func sampleKeyframes(_ keyframes: [Keyframe<Double>], at frame: Double) -> Double {
        guard !keyframes.isEmpty else { return 0 }

        // Before first keyframe
        if frame <= keyframes[0].time {
            return keyframes[0].value
        }

        // After last keyframe
        if frame >= keyframes[keyframes.count - 1].time {
            return keyframes[keyframes.count - 1].value
        }

        // Find segment containing frame
        for i in 0..<(keyframes.count - 1) {
            let k0 = keyframes[i]
            let k1 = keyframes[i + 1]

            if frame >= k0.time && frame < k1.time {
                // Avoid division by zero
                let duration = k1.time - k0.time
                if duration <= 0 {
                    return k1.value
                }

                let progress = (frame - k0.time) / duration
                return lerp(k0.value, k1.value, progress)
            }
        }

        // Fallback (should not reach here)
        return keyframes[keyframes.count - 1].value
    }
}

extension AnimTrack where T == Vec2D {
    /// Samples the track at the given frame using linear interpolation
    /// - Parameter frame: Frame number (can be fractional)
    /// - Returns: Interpolated value at the given frame
    public func sample(frame: Double) -> Vec2D {
        switch self {
        case .static(let value):
            return value
        case .keyframed(let keyframes):
            return sampleKeyframes(keyframes, at: frame)
        }
    }

    private func sampleKeyframes(_ keyframes: [Keyframe<Vec2D>], at frame: Double) -> Vec2D {
        guard !keyframes.isEmpty else { return .zero }

        // Before first keyframe
        if frame <= keyframes[0].time {
            return keyframes[0].value
        }

        // After last keyframe
        if frame >= keyframes[keyframes.count - 1].time {
            return keyframes[keyframes.count - 1].value
        }

        // Find segment containing frame
        for i in 0..<(keyframes.count - 1) {
            let k0 = keyframes[i]
            let k1 = keyframes[i + 1]

            if frame >= k0.time && frame < k1.time {
                // Avoid division by zero
                let duration = k1.time - k0.time
                if duration <= 0 {
                    return k1.value
                }

                let progress = (frame - k0.time) / duration
                return lerp(k0.value, k1.value, progress)
            }
        }

        // Fallback (should not reach here)
        return keyframes[keyframes.count - 1].value
    }
}

// MARK: - Transform Track

/// Complete transform track for a layer
public struct TransformTrack: Sendable, Equatable, Codable {
    /// Position track [x, y]
    public let position: AnimTrack<Vec2D>

    /// Scale track [x, y] in percentage (100 = 100%)
    public let scale: AnimTrack<Vec2D>

    /// Rotation track in degrees
    public let rotation: AnimTrack<Double>

    /// Opacity track (0-100)
    public let opacity: AnimTrack<Double>

    /// Anchor point track [x, y]
    public let anchor: AnimTrack<Vec2D>

    public init(
        position: AnimTrack<Vec2D>,
        scale: AnimTrack<Vec2D>,
        rotation: AnimTrack<Double>,
        opacity: AnimTrack<Double>,
        anchor: AnimTrack<Vec2D>
    ) {
        self.position = position
        self.scale = scale
        self.rotation = rotation
        self.opacity = opacity
        self.anchor = anchor
    }

    /// Default transform (identity)
    public static let identity = Self(
        position: .static(.zero),
        scale: .static(Vec2D(x: 100, y: 100)),
        rotation: .static(0),
        opacity: .static(100),
        anchor: .static(.zero)
    )
}

// swiftlint:enable line_length
