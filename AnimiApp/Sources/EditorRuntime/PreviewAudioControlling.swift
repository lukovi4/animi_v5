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
    /// Pause playback without discarding the pipeline.
    func pause()
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
}
