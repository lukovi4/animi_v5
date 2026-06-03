import Foundation

// MARK: - Preview Audio Readiness

enum PreviewAudioReadiness: Equatable {
    case idle       // no pipeline loaded
    case preparing  // render in progress
    case ready      // PCM file rendered/opened
    case primed     // engine graph prepared
    case failed
}

// MARK: - Preview Audio Failure Reason

enum PreviewAudioFailureReason: Equatable {
    case playerFailed(error: String?)
    case renderFailed(error: String?)
}

// MARK: - Preview Audio Prepare Result

enum PreviewAudioPrepareResult: Equatable {
    case primed
}

// MARK: - Preview Audio Controlling Protocol

@MainActor
protocol PreviewAudioControlling: AnyObject {
    /// Replace the current audio pipeline. Does not start playback.
    func replacePipeline(_ pipeline: BuiltAudioPipeline)
    /// Start (or resume) playback from the given time, synchronized to transport host time.
    func startPlayback(fromSeconds: Double, hostTime: CFTimeInterval)
    /// Teardown-style pause: silences output AND releases prepared engine
    /// resources (engine stop). Reserved for idle reclaim / teardown — NOT the
    /// immediate Pause/scrub handoff. The pipeline/file/cache stay alive.
    func pause()
    /// Warm interactive pause for the `Pause` / `scrub .began` handoff: silences
    /// output quickly while KEEPING the audio engine prepared (no HAL teardown),
    /// so the first scrub frame is not blocked and resume is fast. Semantics
    /// preserved: the next `startPlayback` resumes/re-starts the engine if needed.
    func pausePlaybackImmediately()
    /// Tear down player entirely (discard pipeline).
    func teardown()
    /// Whether the controller currently holds a pipeline.
    var hasActivePipeline: Bool { get }
    /// Current readiness state.
    var readiness: PreviewAudioReadiness { get }
    /// Callback fired (at most once) when readiness transitions to `.ready`.
    var onReady: (@MainActor () -> Void)? { get set }
    /// Callback fired when the controller fails.
    var onFailure: (@MainActor (PreviewAudioFailureReason) -> Void)? { get set }
    /// Callback fired when prepare completes.
    var onPrepareFinished: (@MainActor (PreviewAudioPrepareResult) -> Void)? { get set }
    /// Prepares the engine graph for instant playback.
    func prepareForImmediatePlayback()
    /// Recreate engine graph after audio route change (e.g. headphones connected).
    func reprepareForRouteChange()
}
