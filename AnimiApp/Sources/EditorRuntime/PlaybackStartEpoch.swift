import Foundation

// MARK: - Playback Start Contract
//
// One authoritative model for "Play from compressed frame N".
//
// Before this model, the first visual frame had no single owner: it could be
// re-derived through compressed → nominal → project → host → AVPlayer item time
// → trim clamp → texture binding, so different layers could win the start race
// and present file-zero, N+3, or N-1. These value types make the start frame an
// immutable snapshot that transport, video providers, preview audio, and render
// all consume, instead of each recomputing it.
//
// See `.codex-local/tasks/2026-06-05-playback-start-contract` for the contract.

/// Identity of a single Play request.
///
/// `requestedCompressedFrame` is the exact compressed timeline frame the user
/// asked to start from. No layer may recover a different first visual frame by
/// converting through elapsed host time or lossy nominal-time mapping.
public struct PlaybackStartRequest: Equatable, Sendable {
    public let id: UUID
    public let requestedCompressedFrame: Int
    public let fps: Int
    /// Scrub/timeline generation captured at request time. A later edit/seek that
    /// changes the generation invalidates this request's epoch.
    public let timelineGeneration: UInt64?

    public init(id: UUID, requestedCompressedFrame: Int, fps: Int, timelineGeneration: UInt64?) {
        self.id = id
        self.requestedCompressedFrame = requestedCompressedFrame
        self.fps = fps
        self.timelineGeneration = timelineGeneration
    }
}

/// The single shared host-time boundary after which transport, preview audio,
/// video providers, and render ticks may advance. Before this boundary, render
/// holds `requestedCompressedFrame`.
public struct PlaybackStartBoundary: Equatable, Sendable {
    public let hostTime: CFTimeInterval
    public let requestedCompressedFrame: Int
    /// Nominal frame for `requestedCompressedFrame`. Transport advances by frame
    /// delta from this value so the first frame is never recomputed through time.
    public let requestedNominalFrame: Int
    /// Project time (microseconds) for the start frame — a reporting projection,
    /// not the owner of first-frame identity.
    public let requestedProjectTimeUs: TimeUs

    public init(
        hostTime: CFTimeInterval,
        requestedCompressedFrame: Int,
        requestedNominalFrame: Int,
        requestedProjectTimeUs: TimeUs
    ) {
        self.hostTime = hostTime
        self.requestedCompressedFrame = requestedCompressedFrame
        self.requestedNominalFrame = requestedNominalFrame
        self.requestedProjectTimeUs = requestedProjectTimeUs
    }
}

/// The captured render-participant snapshot for the start frame. Captured once so
/// active participant identity and grants cannot drift between prepare / start /
/// first tick.
///
/// `resolvedFrame` is the concrete timeline render frame for `compressedFrame`,
/// captured at snapshot time. It makes render payload ownership first-class: the
/// playback-start epoch owns the exact `ResolvedTimelineFrame` that Metal consumes
/// for `N`, instead of leaving the first visual frame to be (re)computed later by the
/// async `resolveAndPresentTimelineFrame -> applyResolvedTimelineFrame` path.
/// `EditorRuntime` builds the `TimelineRenderSourcePayload` from this resolved frame
/// and installs it as `currentRenderSource` before the shared boundary opens.
///
/// It is required, not optional: a snapshot only exists when the start frame
/// resolved. If `makePlaybackStartFrameSnapshot` cannot resolve `N`, it returns nil
/// and the start hard-gates (boundary stays closed) rather than opening playback that
/// would leave the first visual frame to a later async resolve.
public struct PlaybackStartFrameSnapshot: Sendable {
    public let compressedFrame: Int
    public let mode: TimelineTransitionMath.RenderMode
    public let localFramesByInstanceId: [UUID: Int]
    public let grantsByInstanceId: [UUID: Set<String>]
    /// The frozen render frame for `compressedFrame`. The epoch owns this so the first
    /// visible payload after Play is `N`, not a stale async resolve.
    public let resolvedFrame: ResolvedTimelineFrame

    public init(
        compressedFrame: Int,
        mode: TimelineTransitionMath.RenderMode,
        localFramesByInstanceId: [UUID: Int],
        grantsByInstanceId: [UUID: Set<String>],
        resolvedFrame: ResolvedTimelineFrame
    ) {
        self.compressedFrame = compressedFrame
        self.mode = mode
        self.localFramesByInstanceId = localFramesByInstanceId
        self.grantsByInstanceId = grantsByInstanceId
        self.resolvedFrame = resolvedFrame
    }
}

/// Immutable start epoch: request + boundary + frame snapshot. Owned by
/// `EditorRuntime`; transport / video / audio consume it instead of recreating
/// the start state.
public struct PlaybackStartEpoch: Sendable {
    public let request: PlaybackStartRequest
    public let boundary: PlaybackStartBoundary
    public let frameSnapshot: PlaybackStartFrameSnapshot

    public init(
        request: PlaybackStartRequest,
        boundary: PlaybackStartBoundary,
        frameSnapshot: PlaybackStartFrameSnapshot
    ) {
        self.request = request
        self.boundary = boundary
        self.frameSnapshot = frameSnapshot
    }
}

/// Result of preparing exact start media for the active visual participants.
///
/// Under the approved hard-gated start contract, a `.failed` result must prevent
/// the shared boundary from opening — playback may not silently start best-effort
/// and catch up later. `.noVisibleVideo` means there is no active visual video
/// participant to gate on (e.g. a photo-only start frame), so the boundary may
/// open. `.cancelled` means the start was superseded/torn down before completing.
public enum PlaybackStartMediaResult: Equatable, Sendable {
    case prepared
    case noVisibleVideo
    case failed(instanceId: UUID, blockId: String)
    case cancelled

    /// Whether this result permits opening the shared playback boundary.
    public var allowsBoundaryOpen: Bool {
        switch self {
        case .prepared, .noVisibleVideo:
            return true
        case .failed, .cancelled:
            return false
        }
    }
}

/// Minimal value handed to preview audio so it opens from the same boundary as
/// transport / video / render, instead of reading mutable runtime fields.
public struct PlaybackAudioStart: Equatable, Sendable {
    /// Start position in seconds (from the epoch project time).
    public let fromSeconds: Double
    /// The shared boundary host time.
    public let boundaryHostTime: CFTimeInterval

    public init(fromSeconds: Double, boundaryHostTime: CFTimeInterval) {
        self.fromSeconds = fromSeconds
        self.boundaryHostTime = boundaryHostTime
    }
}
