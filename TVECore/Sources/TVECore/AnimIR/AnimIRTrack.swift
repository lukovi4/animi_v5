import Foundation

// swiftlint:disable line_length

// MARK: - Keyframe

/// Single keyframe in an animation track
public struct Keyframe<T: Sendable & Equatable>: Sendable, Equatable {
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

// MARK: - Animation Track

/// Animated or static value track
public enum AnimTrack<T: Sendable & Equatable>: Sendable, Equatable {
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
public struct TransformTrack: Sendable, Equatable {
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

// MARK: - Transform Track Conversion from Lottie

extension TransformTrack {
    /// Creates TransformTrack from LottieTransform
    public init(from lottie: LottieTransform?) {
        guard let lottie = lottie else {
            self = .identity
            return
        }

        self.position = Self.convertVec2D(from: lottie.position, default: .zero)
        self.scale = Self.convertVec2D(from: lottie.scale, default: Vec2D(x: 100, y: 100))
        self.rotation = Self.convertDouble(from: lottie.rotation, default: 0)
        self.opacity = Self.convertDouble(from: lottie.opacity, default: 100)
        self.anchor = Self.convertVec2D(from: lottie.anchor, default: .zero)
    }

    private static func convertVec2D(from value: LottieAnimatedValue?, default defaultValue: Vec2D) -> AnimTrack<Vec2D> {
        guard let value = value else {
            return .static(defaultValue)
        }

        if value.isAnimated {
            let keyframes = extractVec2DKeyframes(from: value)
            if keyframes.isEmpty {
                return .static(defaultValue)
            }
            return .keyframed(keyframes)
        } else {
            let vec = extractStaticVec2D(from: value) ?? defaultValue
            return .static(vec)
        }
    }

    private static func convertDouble(from value: LottieAnimatedValue?, default defaultValue: Double) -> AnimTrack<Double> {
        guard let value = value else {
            return .static(defaultValue)
        }

        if value.isAnimated {
            let keyframes = extractDoubleKeyframes(from: value)
            if keyframes.isEmpty {
                return .static(defaultValue)
            }
            return .keyframed(keyframes)
        } else {
            let num = extractStaticDouble(from: value) ?? defaultValue
            return .static(num)
        }
    }

    private static func extractStaticVec2D(from value: LottieAnimatedValue) -> Vec2D? {
        guard let data = value.value else { return nil }

        switch data {
        case .array(let arr) where arr.count >= 2:
            return Vec2D(x: arr[0], y: arr[1])
        case .number(let num):
            return Vec2D(x: num, y: num)
        default:
            return nil
        }
    }

    private static func extractStaticDouble(from value: LottieAnimatedValue) -> Double? {
        guard let data = value.value else { return nil }

        switch data {
        case .number(let num):
            return num
        case .array(let arr) where !arr.isEmpty:
            return arr[0]
        default:
            return nil
        }
    }

    private static func extractVec2DKeyframes(from value: LottieAnimatedValue) -> [Keyframe<Vec2D>] {
        guard let data = value.value, case .keyframes(let lottieKeyframes) = data else {
            return []
        }

        return lottieKeyframes.compactMap { kf -> Keyframe<Vec2D>? in
            guard let time = kf.time else { return nil }

            // Get value from startValue (modern format) or assume zero
            let vec: Vec2D
            if let startArr = kf.startValue, startArr.count >= 2 {
                vec = Vec2D(x: startArr[0], y: startArr[1])
            } else {
                return nil
            }

            let inTan = extractTangent(from: kf.inTangent)
            let outTan = extractTangent(from: kf.outTangent)
            let hold = (kf.hold ?? 0) == 1

            return Keyframe(time: time, value: vec, inTangent: inTan, outTangent: outTan, hold: hold)
        }
    }

    private static func extractDoubleKeyframes(from value: LottieAnimatedValue) -> [Keyframe<Double>] {
        guard let data = value.value, case .keyframes(let lottieKeyframes) = data else {
            return []
        }

        return lottieKeyframes.compactMap { kf -> Keyframe<Double>? in
            guard let time = kf.time else { return nil }

            // Get value from startValue
            let num: Double
            if let startArr = kf.startValue, !startArr.isEmpty {
                num = startArr[0]
            } else {
                return nil
            }

            let inTan = extractTangent(from: kf.inTangent)
            let outTan = extractTangent(from: kf.outTangent)
            let hold = (kf.hold ?? 0) == 1

            return Keyframe(time: time, value: num, inTangent: inTan, outTangent: outTan, hold: hold)
        }
    }

    private static func extractTangent(from tangent: LottieTangent?) -> Vec2D? {
        guard let tangent = tangent else { return nil }

        let x: Double
        let y: Double

        switch tangent.x {
        case .single(let val):
            x = val
        case .array(let arr) where !arr.isEmpty:
            x = arr[0]
        default:
            x = 0
        }

        switch tangent.y {
        case .single(let val):
            y = val
        case .array(let arr) where !arr.isEmpty:
            y = arr[0]
        default:
            y = 0
        }

        return Vec2D(x: x, y: y)
    }
}

// swiftlint:enable line_length
