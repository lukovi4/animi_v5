import Foundation

// MARK: - Playback Time Sample

/// A single time sample produced by PlaybackTransport.
/// Contains all representations of the current playback position.
public struct PlaybackTimeSample: Equatable, Sendable {
    /// Core Animation media time (seconds, from CACurrentMediaTime / CADisplayLink).
    /// This is NOT an AVPlayer host-clock CMTime. Conversion to host-clock time
    /// happens only at the AVPlayer boundary (VideoFrameProvider.scheduledHostClockTime).
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
///
/// Playback-start contract: transport stores the start-frame identity
/// (`startCompressedFrame`, `startNominalFrame`, `boundaryHostTime`) captured at
/// start, and advances by integer frame delta from the boundary. It never
/// recomputes the FIRST visual frame through elapsed-time mapping — that would
/// reintroduce the lossy compressed → time → compressed roundtrip the contract
/// removes. Project time remains a reporting projection, not the owner of
/// first-frame identity.
@MainActor
public final class PlaybackTransport {

    // MARK: - State

    /// Shared boundary host time. Before this, sampling holds the start frame.
    private var boundaryHostTime: CFTimeInterval = 0
    /// Captured start project time (microseconds) — reporting projection.
    private var startProjectTimeUs: TimeUs = 0
    /// Captured exact start compressed frame. Returned verbatim before the
    /// boundary and for the sub-frame first post-boundary sample.
    private var startCompressedFrame: Int = 0
    /// Captured start nominal frame. Post-boundary advancement is
    /// `startNominalFrame + advanceFrames`, mapped back to compressed.
    private var startNominalFrame: Int = 0
    private var fps: Int = 30
    /// True once start-frame identity (compressed/nominal) has been resolved.
    /// The legacy `start(atProjectTimeUs:)` entry point resolves it lazily on the
    /// first sample (it has no mapper at start); the epoch entry point captures it
    /// eagerly at start.
    private var startFrameIdentityResolved: Bool = false
    private(set) var isRunning: Bool = false

    /// Whether the most recent `sample(...)` is still presenting the exact captured
    /// start frame — i.e. the callback was at/before the shared boundary, or the
    /// first post-boundary callback whose sub-frame elapsed floors to zero advance.
    ///
    /// This is the authoritative "transport is holding the start frame" signal the
    /// playback-start render-freeze contract gates on: while it is true, render must
    /// preserve the epoch-owned frozen payload for `N` and must not launch a stale
    /// async resolve that could overwrite it. It is a projection of the last sample,
    /// not a separate source of truth — equality of frame indices is intentionally
    /// NOT used because compressed/quantized timeline regions can make `N` ambiguous.
    ///
    /// Defaults to `false` (no sample taken yet / not running). Set on every
    /// `sample(...)` return so it always reflects the latest tick.
    private(set) var isHoldingStartFrame: Bool = false

    // MARK: - API

    /// Starts the transport at a given project time (legacy entry point).
    ///
    /// Start-frame identity (compressed/nominal) is resolved from the mapper on the
    /// first `sample(...)` call, because this entry point has no mapper. The
    /// resolution happens exactly once and is then held, so the first presented
    /// frame is stable.
    ///
    /// - Parameters:
    ///   - atProjectTimeUs: Starting project time in microseconds
    ///   - hostTime: Shared boundary host time (from CADisplayLink or caller)
    ///   - fps: Template FPS for frame quantization
    func start(atProjectTimeUs: TimeUs, hostTime: CFTimeInterval, fps: Int) {
        self.boundaryHostTime = hostTime
        self.startProjectTimeUs = atProjectTimeUs
        self.fps = fps
        self.startFrameIdentityResolved = false
        self.isRunning = true
        self.isHoldingStartFrame = true
    }

    /// Starts the transport from a captured playback-start boundary (epoch path).
    ///
    /// The start frame identity is captured eagerly from the boundary, so no layer
    /// re-derives the first visual frame through elapsed time.
    func start(boundary: PlaybackStartBoundary, fps: Int) {
        self.boundaryHostTime = boundary.hostTime
        self.startProjectTimeUs = boundary.requestedProjectTimeUs
        self.startCompressedFrame = boundary.requestedCompressedFrame
        self.startNominalFrame = boundary.requestedNominalFrame
        self.fps = fps
        self.startFrameIdentityResolved = true
        self.isRunning = true
        self.isHoldingStartFrame = true
    }

    /// Stops the transport.
    func stop() {
        isRunning = false
        isHoldingStartFrame = false
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
        guard isRunning else {
            isHoldingStartFrame = false
            return nil
        }

        // Resolve start-frame identity once (legacy entry point). The epoch entry
        // point already captured it. This is the only place compressed/nominal are
        // derived from time, and it happens for the START frame exactly once — never
        // per tick — so the first presented frame is stable.
        if !startFrameIdentityResolved {
            startCompressedFrame = min(
                mapper.compressedFrame(forTimeUs: startProjectTimeUs, quantize: .playback),
                maxCompressedFrame
            )
            startNominalFrame = mapper.nominalFrame(forCompressedFrame: startCompressedFrame)
            startFrameIdentityResolved = true
        }

        let clampedStartFrame = min(startCompressedFrame, maxCompressedFrame)

        // Pre-start boundary: any callback at or before the shared boundary presents
        // the exact captured start frame, never a negative/advanced elapsed sample.
        guard hostTime > boundaryHostTime else {
            isHoldingStartFrame = true
            return PlaybackTimeSample(
                hostTime: hostTime,
                projectTimeUs: startProjectTimeUs,
                compressedFrame: clampedStartFrame
            )
        }

        // Post-boundary: advance by integer frame delta from the boundary. The first
        // post-boundary callback with sub-frame elapsed time floors to 0 advance and
        // therefore still returns the exact start frame.
        let elapsed = hostTime - boundaryHostTime
        let advanceFrames = fps > 0 ? Int(floor(elapsed * Double(fps))) : 0

        guard advanceFrames > 0 else {
            isHoldingStartFrame = true
            return PlaybackTimeSample(
                hostTime: hostTime,
                projectTimeUs: startProjectTimeUs,
                compressedFrame: clampedStartFrame
            )
        }

        let nominal = startNominalFrame + advanceFrames
        let compressedFrame = min(
            mapper.compressedFrame(forNominalFrame: nominal, quantize: .playback),
            maxCompressedFrame
        )

        // Project time is a reporting projection derived from elapsed time; it does
        // not own first-frame identity.
        let elapsedUs = TimeUs((elapsed * 1_000_000).rounded())
        let projectTimeUs = startProjectTimeUs + elapsedUs

        // Transport has advanced past the start frame; the render-freeze hold is over.
        isHoldingStartFrame = false

        return PlaybackTimeSample(
            hostTime: hostTime,
            projectTimeUs: projectTimeUs,
            compressedFrame: compressedFrame
        )
    }
}
