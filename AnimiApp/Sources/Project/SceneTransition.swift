import Foundation

// MARK: - Scene Transition (v6 Schema)

/// Transition effect between two adjacent scenes.
/// Property of the boundary, not of individual scenes.
public struct SceneTransition: Codable, Equatable, Sendable {
    /// Type of transition effect.
    public var type: TransitionType

    /// Duration in frames (v1 default: 14 frames at 30fps).
    public var durationFrames: Int

    /// Easing preset (v1: fixed per transition type).
    public var easingPreset: EasingPreset

    public init(
        type: TransitionType = .none,
        durationFrames: Int = 14,
        easingPreset: EasingPreset = .easeInOut
    ) {
        self.type = type
        self.durationFrames = durationFrames
        self.easingPreset = easingPreset
    }

    /// No transition (instant cut).
    public static let none = SceneTransition(type: .none, durationFrames: 0, easingPreset: .linear)
}

// MARK: - Transition Type

/// Type of visual transition effect.
public enum TransitionType: Codable, Equatable, Sendable {
    /// No transition (instant cut).
    case none
    /// Cross-fade between scenes.
    case fade
    /// Scene B slides in from direction, A stays in place.
    case slide(direction: TransitionDirection)
    /// Scene B pushes A out (both move).
    case push(direction: TransitionDirection)
    /// Fade to black, then fade from black.
    case dipToBlack
    /// Fade to white, then fade from white.
    case dipToWhite
}

// MARK: - Transition Direction

/// Direction for slide/push transitions.
/// Semantics: direction is where incoming scene B comes FROM.
/// - `.left` means B enters from the left side
/// - `.right` means B enters from the right side
public enum TransitionDirection: String, Codable, Equatable, Sendable {
    case left
    case right
    case up
    case down
}

// MARK: - Easing Preset

/// Easing preset for transition animation.
/// v1: Fixed per transition type, not user-configurable.
public enum EasingPreset: String, Codable, Equatable, Sendable {
    /// Linear interpolation (used for fade).
    case linear
    /// Ease in-out curve (used for slide, push, dip).
    case easeInOut
}

// MARK: - Scene Boundary Key

/// Identifies a boundary between two adjacent scene instances.
/// Used as dictionary key for boundaryTransitions registry.
public struct SceneBoundaryKey: Hashable, Sendable {
    /// ID of the outgoing scene (scene A).
    public let fromSceneInstanceId: UUID
    /// ID of the incoming scene (scene B).
    public let toSceneInstanceId: UUID

    public init(_ from: UUID, _ to: UUID) {
        self.fromSceneInstanceId = from
        self.toSceneInstanceId = to
    }
}

// MARK: - Boundary Transition Record (Codable Helper)

/// On-disk representation of a boundary transition.
/// Used for JSON serialization (dictionary keys can't be complex types).
struct BoundaryTransitionRecord: Codable, Equatable, Sendable {
    let fromSceneInstanceId: UUID
    let toSceneInstanceId: UUID
    let transition: SceneTransition
}

// MARK: - TVECore Type Conversions (PR-F)

import enum TVECore.TransitionType
import enum TVECore.TransitionDirection
import enum TVECore.TransitionEasingPreset

// Typealiases to disambiguate from AnimiApp types (which have same names)
typealias TVETransitionType = TVECore.TransitionType
typealias TVETransitionDirection = TVECore.TransitionDirection
typealias TVETransitionEasingPreset = TVECore.TransitionEasingPreset

extension TransitionType {
    /// Converts AnimiApp TransitionType to TVECore TransitionType.
    func toTVECoreType() -> TVETransitionType {
        switch self {
        case .none:
            return TVETransitionType.none
        case .fade:
            return TVETransitionType.fade
        case .slide(let direction):
            return TVETransitionType.slide(direction: direction.toTVECoreType())
        case .push(let direction):
            return TVETransitionType.push(direction: direction.toTVECoreType())
        case .dipToBlack:
            return TVETransitionType.dipToBlack
        case .dipToWhite:
            return TVETransitionType.dipToWhite
        }
    }
}

extension TransitionDirection {
    /// Converts AnimiApp TransitionDirection to TVECore TransitionDirection.
    func toTVECoreType() -> TVETransitionDirection {
        switch self {
        case .left:
            return TVETransitionDirection.left
        case .right:
            return TVETransitionDirection.right
        case .up:
            return TVETransitionDirection.up
        case .down:
            return TVETransitionDirection.down
        }
    }
}

extension EasingPreset {
    /// Converts AnimiApp EasingPreset to TVECore TransitionEasingPreset.
    func toTVECoreType() -> TVETransitionEasingPreset {
        switch self {
        case .linear:
            return TVETransitionEasingPreset.linear
        case .easeInOut:
            return TVETransitionEasingPreset.easeInOut
        }
    }
}

extension SceneTransition {
    /// Access easing preset via TVECore-compatible property name.
    var easing: EasingPreset {
        easingPreset
    }
}
