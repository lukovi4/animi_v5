import Foundation
import AnimiEngineCore

/// App-side source location resolved from the editor registry for canonical audio rendering.
///
/// This is intentionally only a locator. It does not imply that decoding happens on the live Play path.
/// The correct architecture is:
///
///   AudioPlan -> background/offline PCM renderer/prewarm/cache -> PreviewMixSource -> PreviewAudioGraph
///
/// `AVAssetReader` may be used by a future background renderer/export path, but not as a live
/// `startPlayback` dependency.
struct CanonicalResolvedAudioSource: Equatable, Sendable {
    let url: URL
}

/// Request for preparing a bounded canonical preview preroll from an already evaluated `AudioPlan`.
///
/// The implementation behind this protocol must be a renderer/prewarm/cache boundary. It must not block
/// the UI thread and must not perform synchronous compressed-media reads in the live Play path.
struct CanonicalAudioRenderRequest: Sendable {
    let plan: AudioPlan
    let revision: ProjectRevision
    let epoch: PlaybackEpoch
    let anchor: PreviewAudioScheduleAnchor
    let range: AudioSampleRange
    let resolvedSourcesByID: [String: CanonicalResolvedAudioSource]
}

/// Canonical preview-audio render boundary.
///
/// This replaces the rejected live `AVAssetReader` backend. Unit tests can inject a deterministic
/// renderer that returns `PreviewMixSource`s; production must eventually provide a background/prewarmed PCM
/// renderer/cache implementation.
protocol CanonicalAudioRenderPipeline: Sendable {
    func prepareInitialPreroll(
        _ request: CanonicalAudioRenderRequest,
        onDiagnostic: (@MainActor (_ event: String, _ detail: String) -> Void)?
    ) async throws -> [PreviewMixSource]
}

/// Safe production placeholder while the real background PCM renderer/cache is not implemented.
///
/// Non-empty audio fails visibly and routes through the existing canonical-unavailable handling instead of
/// pretending that an unrendered plan is silence.
struct UnavailableCanonicalAudioRenderPipeline: CanonicalAudioRenderPipeline {
    func prepareInitialPreroll(
        _ request: CanonicalAudioRenderRequest,
        onDiagnostic: (@MainActor (_ event: String, _ detail: String) -> Void)?
    ) async throws -> [PreviewMixSource] {
        if request.plan.segments.isEmpty { return [] }
        await onDiagnostic?(
            "preview.audio.canonical.render.unavailable",
            "segments=\(request.plan.segments.count) sources=\(request.resolvedSourcesByID.count)")
        throw AppRealtimeAudioIntegrationError.audioRenderPipelineUnavailable(
            reason: "background PCM renderer/cache is not implemented")
    }
}
