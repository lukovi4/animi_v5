import Foundation

// MARK: - Playback Time Sample

/// A single time sample produced by PlaybackTransport.
/// Contains all representations of the current playback position.
public struct PlaybackTimeSample: Equatable, Sendable {
    /// Host time (CACurrentMediaTime-based) at which this sample was produced.
    public let hostTime: CFTimeInterval
    /// Project time in microseconds (nominal timeline).
    public let projectTimeUs: TimeUs
    /// Compressed frame index for the timeline engine.
    public let compressedFrame: Int
}

// MARK: - Playback Transport

/// Runtime-owned source of truth for playback time.
///
/// During timeline preview playback, this is the single owner of time.
/// Host time always comes from outside (CADisplayLink or caller);
/// transport never calls CACurrentMediaTime() internally.
@MainActor
public final class PlaybackTransport {

    // MARK: - State

    private var startHostTime: CFTimeInterval = 0
    private var startProjectTimeUs: TimeUs = 0
    private var fps: Int = 30
    private(set) var isRunning: Bool = false

    // MARK: - API

    /// Starts the transport at a given project time.
    ///
    /// - Parameters:
    ///   - atProjectTimeUs: Starting project time in microseconds
    ///   - hostTime: Host time at start (from CADisplayLink or caller)
    ///   - fps: Template FPS for frame quantization
    func start(atProjectTimeUs: TimeUs, hostTime: CFTimeInterval, fps: Int) {
        self.startHostTime = hostTime
        self.startProjectTimeUs = atProjectTimeUs
        self.fps = fps
        self.isRunning = true
    }

    /// Stops the transport.
    func stop() {
        isRunning = false
    }

    /// Samples the current playback position.
    ///
    /// - Parameters:
    ///   - mapper: Playhead mapper for compressed frame conversion
    ///   - maxCompressedFrame: Maximum valid compressed frame (timeline end)
    ///   - hostTime: Current host time (from CADisplayLink tick)
    /// - Returns: Time sample with all representations, or nil if not running
    func sample(
        mapper: TimelinePlayheadMapper,
        maxCompressedFrame: Int,
        hostTime: CFTimeInterval
    ) -> PlaybackTimeSample? {
        guard isRunning else { return nil }

        let elapsed = hostTime - startHostTime
        let elapsedUs = TimeUs((elapsed * 1_000_000).rounded())
        let projectTimeUs = startProjectTimeUs + elapsedUs

        let compressedFrame = min(
            mapper.compressedFrame(forTimeUs: projectTimeUs, quantize: .playback),
            maxCompressedFrame
        )

        return PlaybackTimeSample(
            hostTime: hostTime,
            projectTimeUs: projectTimeUs,
            compressedFrame: compressedFrame
        )
    }
}
