import Foundation
import TVECore

// MARK: - Transform Track Conversion from Lottie

extension TransformTrack {
    /// Creates TransformTrack from LottieTransform
    public init(from lottie: LottieTransform?) {
        guard let lottie = lottie else {
            self = .identity
            return
        }

        let position = Self.convertVec2D(from: lottie.position, default: .zero)
        let scale = Self.convertVec2D(from: lottie.scale, default: Vec2D(x: 100, y: 100))
        let rotation = Self.convertDouble(from: lottie.rotation, default: 0)
        let opacity = Self.convertDouble(from: lottie.opacity, default: 100)
        let anchor = Self.convertVec2D(from: lottie.anchor, default: .zero)

        self.init(position: position, scale: scale, rotation: rotation, opacity: opacity, anchor: anchor)
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

            // Get value from startValue (modern format) - must be numbers type
            let vec: Vec2D
            if case .numbers(let arr) = kf.startValue, arr.count >= 2 {
                vec = Vec2D(x: arr[0], y: arr[1])
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

            // Get value from startValue - must be numbers type
            let num: Double
            if case .numbers(let arr) = kf.startValue, !arr.isEmpty {
                num = arr[0]
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
