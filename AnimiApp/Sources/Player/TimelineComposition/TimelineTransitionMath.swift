import Foundation

// MARK: - Timeline Transition Math

/// Pure math layer for computing compressed timeline positions and transition windows.
/// All time calculations are in frames (not microseconds).
/// Input must be validated before use (no overlapping transitions).
public struct TimelineTransitionMath: Sendable {

    // MARK: - Inputs

    /// Scene items from timeline (in order).
    public let sceneItems: [TimelineItem]

    /// Boundary transitions registry.
    public let boundaryTransitions: [SceneBoundaryKey: SceneTransition]

    /// Frames per second (v1: always 30).
    public let fps: Int

    // MARK: - Initialization

    public init(
        sceneItems: [TimelineItem],
        boundaryTransitions: [SceneBoundaryKey: SceneTransition],
        fps: Int
    ) {
        self.sceneItems = sceneItems
        self.boundaryTransitions = boundaryTransitions
        self.fps = fps
    }

    // MARK: - Computed: Scene Durations in Frames

    /// Returns duration in frames for scene item.
    public func durationFrames(for item: TimelineItem) -> Int {
        // Convert microseconds to frames: frames = us * fps / 1_000_000
        Int((item.durationUs * Int64(fps)) / 1_000_000)
    }

    /// Returns duration in frames for scene at index.
    public func durationFrames(forSceneAt index: Int) -> Int {
        guard index >= 0 && index < sceneItems.count else { return 0 }
        return durationFrames(for: sceneItems[index])
    }

    // MARK: - Computed: Compressed Duration

    /// Total compressed duration in frames.
    /// Compressed = uncompressed - (compressionPerTransition * transitionCount)
    public var compressedDurationFrames: Int {
        let uncompressed = sceneItems.reduce(0) { $0 + durationFrames(for: $1) }

        // Guard: need at least 2 scenes for transitions
        guard sceneItems.count > 1 else {
            return uncompressed
        }

        var compressionFrames = 0
        for i in 0..<(sceneItems.count - 1) {
            let key = SceneBoundaryKey(sceneItems[i].id, sceneItems[i + 1].id)
            if let transition = boundaryTransitions[key], transition.type != .none {
                // Compression = durationFrames / 2 (half of transition duration)
                compressionFrames += transition.durationFrames / 2
            }
        }

        return uncompressed - compressionFrames
    }

    // MARK: - Scene Start Frames (Compressed)

    /// Returns compressed start frame for scene at index.
    /// Scene 0 always starts at frame 0.
    /// Each subsequent scene starts earlier due to transition overlap.
    public func compressedStartFrame(forSceneAt index: Int) -> Int {
        guard index > 0 && index < sceneItems.count else { return 0 }

        var startFrame = 0
        for i in 0..<index {
            // Add scene duration
            startFrame += durationFrames(forSceneAt: i)

            // Subtract compression from transition to next scene
            let key = SceneBoundaryKey(sceneItems[i].id, sceneItems[i + 1].id)
            if let transition = boundaryTransitions[key], transition.type != .none {
                startFrame -= transition.durationFrames / 2
            }
        }

        return startFrame
    }

    // MARK: - Transition Windows

    /// Describes a transition window in compressed timeline.
    public struct TransitionWindow: Equatable, Sendable {
        /// Index of outgoing scene (A).
        public let fromSceneIndex: Int
        /// Index of incoming scene (B).
        public let toSceneIndex: Int
        /// Start frame in compressed timeline.
        public let startFrame: Int
        /// End frame in compressed timeline (exclusive).
        public let endFrame: Int
        /// Transition parameters.
        public let transition: SceneTransition
    }

    /// Returns all transition windows in compressed timeline.
    public var allTransitionWindows: [TransitionWindow] {
        // Guard: need at least 2 scenes for transitions
        guard sceneItems.count > 1 else {
            return []
        }

        var windows: [TransitionWindow] = []

        for i in 0..<(sceneItems.count - 1) {
            let key = SceneBoundaryKey(sceneItems[i].id, sceneItems[i + 1].id)
            guard let transition = boundaryTransitions[key], transition.type != .none else {
                continue
            }

            // Transition window starts at: compressed start of scene B
            let sceneAStart = compressedStartFrame(forSceneAt: i)
            let sceneADuration = durationFrames(forSceneAt: i)
            let windowStart = sceneAStart + sceneADuration - transition.durationFrames / 2
            let windowEnd = windowStart + transition.durationFrames

            windows.append(TransitionWindow(
                fromSceneIndex: i,
                toSceneIndex: i + 1,
                startFrame: windowStart,
                endFrame: windowEnd,
                transition: transition
            ))
        }

        return windows
    }

    /// Returns transition window containing the given compressed frame, if any.
    /// Returns nil if frame is not in any transition.
    public func transitionWindow(at compressedFrame: Int) -> TransitionWindow? {
        for window in allTransitionWindows {
            if compressedFrame >= window.startFrame && compressedFrame < window.endFrame {
                return window
            }
        }
        return nil
    }

    // MARK: - Local Frame Mapping

    /// Maps compressed global frame to scene-local frame(s).
    public struct FrameMapping: Equatable, Sendable {
        /// Primary scene index.
        public let sceneIndex: Int
        /// Local frame within primary scene.
        public let localFrame: Int
        /// True if frame is within a transition window.
        public let isInTransition: Bool
        /// Transition progress 0.0 to 1.0 (nil if not in transition).
        public let transitionProgress: Double?
        /// Index of transition partner scene (nil if not in transition).
        public let transitionPartnerIndex: Int?
    }

    /// Maps compressed global frame to local scene frame(s).
    /// Returns nil for empty timeline.
    public func frameMapping(for compressedFrame: Int) -> FrameMapping? {
        // Guard: empty timeline has no valid mapping
        guard !sceneItems.isEmpty else {
            return nil
        }

        // Check if in transition
        if let window = transitionWindow(at: compressedFrame) {
            let progress = Double(compressedFrame - window.startFrame) / Double(window.transition.durationFrames)

            // During transition, primary scene is the one that has more visual prominence
            // First half: A is primary, second half: B is primary
            let primaryIsA = progress < 0.5
            let primaryIndex = primaryIsA ? window.fromSceneIndex : window.toSceneIndex
            let partnerIndex = primaryIsA ? window.toSceneIndex : window.fromSceneIndex

            // Calculate local frame for primary scene
            let sceneStart = compressedStartFrame(forSceneAt: primaryIndex)
            let localFrame = compressedFrame - sceneStart

            return FrameMapping(
                sceneIndex: primaryIndex,
                localFrame: localFrame,
                isInTransition: true,
                transitionProgress: progress,
                transitionPartnerIndex: partnerIndex
            )
        }

        // Not in transition - find which scene contains this frame
        for i in 0..<sceneItems.count {
            let sceneStart = compressedStartFrame(forSceneAt: i)
            let sceneDuration = durationFrames(forSceneAt: i)
            let sceneEnd = sceneStart + sceneDuration

            if compressedFrame >= sceneStart && compressedFrame < sceneEnd {
                return FrameMapping(
                    sceneIndex: i,
                    localFrame: compressedFrame - sceneStart,
                    isInTransition: false,
                    transitionProgress: nil,
                    transitionPartnerIndex: nil
                )
            }
        }

        // Fallback: clamp to last frame of last scene
        let lastIndex = sceneItems.count - 1
        let lastSceneDuration = durationFrames(forSceneAt: lastIndex)
        return FrameMapping(
            sceneIndex: lastIndex,
            localFrame: max(0, lastSceneDuration - 1),
            isInTransition: false,
            transitionProgress: nil,
            transitionPartnerIndex: nil
        )
    }

    // MARK: - Render Mode

    /// Render mode for a frame.
    public enum RenderMode: Equatable, Sendable {
        /// Single scene rendering.
        case single(sceneIndex: Int, localFrame: Int)
        /// Transition rendering with two scenes.
        case transition(
            sceneAIndex: Int, localFrameA: Int,
            sceneBIndex: Int, localFrameB: Int,
            transition: SceneTransition,
            progress: Double
        )
    }

    /// Returns render mode for compressed global frame.
    /// Returns nil for empty timeline.
    public func renderMode(for compressedFrame: Int) -> RenderMode? {
        // Guard: empty timeline has no valid render mode
        guard !sceneItems.isEmpty else {
            return nil
        }

        if let window = transitionWindow(at: compressedFrame) {
            let progress = Double(compressedFrame - window.startFrame) / Double(window.transition.durationFrames)

            // Calculate local frames for both scenes
            let sceneAStart = compressedStartFrame(forSceneAt: window.fromSceneIndex)
            let sceneBStart = compressedStartFrame(forSceneAt: window.toSceneIndex)

            var localFrameA = compressedFrame - sceneAStart
            var localFrameB = compressedFrame - sceneBStart

            // Clamp scene A: after its nominal end, hold last frame
            let sceneADuration = durationFrames(forSceneAt: window.fromSceneIndex)
            if localFrameA >= sceneADuration {
                localFrameA = sceneADuration - 1
            }

            // Clamp scene B: before frame 0, use frame 0
            if localFrameB < 0 {
                localFrameB = 0
            }

            return .transition(
                sceneAIndex: window.fromSceneIndex,
                localFrameA: localFrameA,
                sceneBIndex: window.toSceneIndex,
                localFrameB: localFrameB,
                transition: window.transition,
                progress: progress
            )
        }

        // Single scene - frameMapping guaranteed non-nil when sceneItems is non-empty
        let mapping = frameMapping(for: compressedFrame)!
        return .single(sceneIndex: mapping.sceneIndex, localFrame: mapping.localFrame)
    }

    // MARK: - Audio Mapping

    /// Converts uncompressed frame to compressed frame for a scene.
    /// Used by AudioCompositionBuilder.
    ///
    /// - Parameters:
    ///   - uncompressed: Frame index relative to scene start (uncompressed).
    ///   - sceneIndex: Index of the scene.
    /// - Returns: Compressed global frame.
    public func compressedFrame(forUncompressedFrame uncompressed: Int, inSceneAt sceneIndex: Int) -> Int {
        // Compressed start of this scene
        let sceneStart = compressedStartFrame(forSceneAt: sceneIndex)
        return sceneStart + uncompressed
    }

    /// Converts uncompressed global frame (sum of all scene durations) to compressed frame.
    /// Accounts for all transition compressions up to that point.
    public func compressedFrameFromUncompressedGlobal(_ uncompressedGlobal: Int) -> Int {
        // Guard: need at least 2 scenes for transitions
        guard sceneItems.count > 1 else {
            return uncompressedGlobal
        }

        var compressed = uncompressedGlobal
        var uncompressedPosition = 0

        for i in 0..<(sceneItems.count - 1) {
            let sceneDuration = durationFrames(forSceneAt: i)
            uncompressedPosition += sceneDuration

            // If we've passed this boundary, subtract compression
            if uncompressedGlobal >= uncompressedPosition {
                let key = SceneBoundaryKey(sceneItems[i].id, sceneItems[i + 1].id)
                if let transition = boundaryTransitions[key], transition.type != .none {
                    compressed -= transition.durationFrames / 2
                }
            } else {
                break
            }
        }

        return compressed
    }
}
