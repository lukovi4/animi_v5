import Foundation
import AVFoundation
import AnimiEngineCore

/// Slice-005 Stage C — builds the production `CanonicalPreviewAudioController.Dependencies` from real
/// app boundaries (AVAudioSession-backed session adapter + the canonical `AVAudioEnginePreviewSink`),
/// so flipping the `DebugPreviewAudioWithNextEngine` toggle ON installs a live canonical controller.
///
/// The plan and preroll are **injected** (`planSource`) so the controller can build a REAL `AudioPlan`
/// from current editor state — the factory does NOT hardcode `nil`/`[]`. The seconds→sample anchor and
/// the start-barrier first-frame gating live in the controller; this factory only assembles boundaries.
///
/// SCOPE (honest): live `AVAssetReader` decoding has been removed from the Play path. Production preroll is
/// now behind the REAL `CachedCanonicalAudioRenderPipeline` (Stage 4):
///
///   AudioPlan → CachedCanonicalAudioRenderPipeline → CanonicalPCMRenderCache
///             → BackgroundCanonicalPCMRenderer → AVFoundationPCMAssetDecoder → [PreviewMixSource]
///
/// AV decode is confined to `AVFoundationPCMAssetDecoder` (this factory never touches `AVAssetReader`). The
/// `UnavailableCanonicalAudioRenderPipeline` placeholder is no longer the production default — it survives
/// only as the fail-CLOSED (throws, never silence) degenerate fallback if cache construction itself fails.
@MainActor
enum CanonicalPreviewAudioControllerFactory {

    /// Conservative bounded runtime config (OD-2 final values are a device-gate decision).
    static let maxChunkSamples: Int64 = 48_000          // ≤ 1 s at 48 kHz (CONTINUOUS chunk size)
    /// Stage-8 fix A: the INITIAL preroll is smaller than a continuous chunk so the first buffer decodes +
    /// schedules faster (Play→audible latency). 9_600 frames = 200 ms @ 48 kHz. Continuous chunks stay
    /// `maxChunkSamples` (the first continuous chunk begins exactly at the preroll's end, so coverage is
    /// contiguous — no gap, no dropout as long as the next chunk schedules in time).
    static let initialPrerollSamples: Int64 = 9_600     // 200 ms at 48 kHz
    static let startTimeoutTicks: Int64 = 240_000 * 5   // 5 s of project ticks

    /// Named bounded PCM render-cache capacity (number of cached bounded chunks). NOT an inline magic value.
    /// Bounded so the prewarm/cache cannot grow unboundedly; eviction is LRU (see `CanonicalPCMRenderCache`).
    /// `nonisolated` pure constants so they can seed the (nonisolated) default arguments below.
    nonisolated static let renderCacheCapacity: Int = 8
    /// Hard per-decode timeout for the background decoder (5 s ceiling; bounded chunks are ≤ ~1 s of audio).
    nonisolated static let decoderTimeoutNanos: UInt64 = 5_000_000_000

    /// Build the REAL production canonical render pipeline (Stage 4). Throwing because cache construction is
    /// fail-closed on a non-positive capacity (`CanonicalPCMRenderCache.make`); no force-try, no silent clamp.
    nonisolated static func makeProductionRenderPipeline(
        cacheCapacity: Int = renderCacheCapacity,
        decoderTimeoutNanos: UInt64 = decoderTimeoutNanos
    ) throws -> CanonicalAudioRenderPipeline {
        let decoder = AVFoundationPCMAssetDecoder(timeoutNanos: decoderTimeoutNanos)
        let renderer = BackgroundCanonicalPCMRenderer(decoder: decoder)
        let cache = try CanonicalPCMRenderCache.make(capacity: cacheCapacity, renderer: renderer)
        return CachedCanonicalAudioRenderPipeline(cache: cache)
    }

    /// Build the production controller from the live runtime plan source. The session adapter + sink are
    /// the real AVFoundation boundaries; the plan comes from `planSource` (real evaluation of current
    /// editor state), while preroll PCM is delegated to the canonical render pipeline.
    ///
    /// `renderPipeline` defaults to `nil` → the factory builds the REAL cached pipeline. Tests inject a fake.
    /// If the real pipeline cannot be constructed (only possible for a misconfigured non-positive capacity),
    /// the factory emits a diagnostic and falls back to the fail-CLOSED `UnavailableCanonicalAudioRenderPipeline`
    /// (which THROWS for non-empty audio → legacy fallback) — it never crashes and never produces silence.
    static func makeProductionController(
        planSource: RuntimeCanonicalAudioPlanSource,
        renderPipeline injectedPipeline: CanonicalAudioRenderPipeline? = nil
    ) -> CanonicalPreviewAudioController {
        let renderPipeline: CanonicalAudioRenderPipeline
        if let injectedPipeline {
            renderPipeline = injectedPipeline
        } else {
            do {
                renderPipeline = try makeProductionRenderPipeline()
            } catch {
                MemoryDiagnostics.event(
                    "preview.audio.canonical.renderPipeline.constructFailed",
                    "error=\(error) → fail-closed unavailable placeholder")
                renderPipeline = UnavailableCanonicalAudioRenderPipeline()
            }
        }
        let adapter = AppAudioSessionAdapter(probe: AVAudioSessionOutputProbe())
        let sink = AVAudioEnginePreviewSink()
        // SAFETY predicate for the silent-epoch fallback: "does the project actually have audio?" read
        // straight from editor state (imported/bundled music OR video-original), independent of the legacy
        // build plan — so a canonical silent epoch over a project WITH audio routes to the legacy fallback.
        let runtime = planSource.runtime
        let projectHasAudio: () -> Bool = { [weak runtime] in
            guard let runtime, let state = runtime.session.state else { return false }
            let hasTimelineAudio = !state.canonicalTimeline.allAudioItems.isEmpty
            // Detect video-original audio the SAME way the plan source does (visible video slots under each
            // scene instance), so this safety predicate agrees with what `currentAudioPlan` actually builds —
            // not the legacy `blockIdsWithVideo` view (which can disagree).
            let hasVideo = state.canonicalTimeline.sceneItems.contains { item in
                guard let slots = state.draft.sceneInstanceStates[item.id]?.mediaSlotsByBlockId else { return false }
                return slots.values.contains { $0.visibility && $0.mediaRef.mediaKind == .video && $0.videoWindow != nil }
            }
            return hasTimelineAudio || hasVideo
        }
        return makeController(planSource: planSource, sink: sink, adapter: adapter, renderPipeline: renderPipeline,
                              resolvedSources: { [weak planSource] in planSource?.resolvedSourcesByID ?? [:] },
                              projectHasAudio: projectHasAudio)
    }

    /// Assemble a controller from already-built boundaries (shared by production + tests).
    static func makeController(
        planSource: ProductionPreviewAudioPlanSource,
        sink: PreviewAudioOutputSink,
        adapter: AudioSessionAdapter,
        renderPipeline: CanonicalAudioRenderPipeline,
        resolvedSources: @escaping () -> [String: CanonicalResolvedAudioSource] = { [:] },
        projectHasAudio: @escaping () -> Bool = { false }
    ) -> CanonicalPreviewAudioController {
        let deps = CanonicalPreviewAudioController.Dependencies(
            evaluatePlan: {
                // REAL evaluation from current editor state. Empty audio → nil (silent); non-empty audio
                // → a non-empty plan, or a typed failure. NEVER a silent nil for non-empty audio.
                try planSource.currentAudioPlan()
            },
            buildInitialPrerollAsync: { plan, revision, epoch, anchor, range, onDiagnostic in
                // Production preroll: delegate to the renderer/cache boundary. The rejected live
                // AVAssetReader backend is deliberately not assembled here.
                let request = CanonicalAudioRenderRequest(
                    plan: plan, revision: revision, epoch: epoch, anchor: anchor, range: range,
                    resolvedSourcesByID: resolvedSources())
                return try await renderPipeline.prepareInitialPreroll(request, onDiagnostic: onDiagnostic)
            },
            sessionAdapter: adapter,
            sink: sink,
            makeAudioClock: { anchorProjectTime in
                AudioSampleMasterClock(anchorProjectTime: anchorProjectTime, currentSampleTime: { 0 })
            },
            maxChunkSamples: maxChunkSamples,
            initialPrerollSamples: initialPrerollSamples,
            startTimeoutTicks: startTimeoutTicks,
            projectHasAudio: projectHasAudio)
        return CanonicalPreviewAudioController(dependencies: deps)
    }
}

/// The injected source of a canonical `AudioPlan` from current editor state (the controller no longer
/// hardcodes a nil plan). The coordinator implements this with access to the runtime.
@MainActor
protocol ProductionPreviewAudioPlanSource {
    /// The current project's canonical audio plan, or `nil` when there is genuinely no resolvable audio
    /// (legitimate silence). A project that HAS audio must return a non-empty plan or throw — never `nil`.
    func currentAudioPlan() throws -> AudioPlan?
}

/// The real `AVAudioSession`-backed output probe behind `AppAudioSessionAdapter.OutputProbe`. The only
/// AVFoundation surface of the Stage-C session adapter; isolated app-side (never in `AnimiEngineCore`).
///
/// `nonisolated` / `@unchecked Sendable`: `OutputProbe` is a non-isolated protocol, and `AVAudioSession`
/// calls are thread-safe, so this conformance must not be `@MainActor` (which would cross actor isolation
/// — a Swift 6 data-race error).
final class AVAudioSessionOutputProbe: AppAudioSessionAdapter.OutputProbe, @unchecked Sendable {
    // SESSION-NEUTRAL: the app owns `AVAudioSession` activation/category via `AudioSessionManager`
    // (`activateForPlayback`). This probe must NOT `setActive(true/false)` on the shared session —
    // doing so on every play/pause/scrub silenced the WHOLE app (including video audio). It only READS
    // the actual output; activation is a no-op (the adapter tracks its own query-ordering flag).
    func activate() throws {}
    func deactivate() throws {}
    func currentOutput() throws -> AppAudioSessionAdapter.RawOutput {
        let session = AVAudioSession.sharedInstance()
        let port = session.currentRoute.outputs.first
        return AppAudioSessionAdapter.RawOutput(
            sampleRate: session.sampleRate,
            channelCount: session.outputNumberOfChannels,
            routeIdentifier: port?.uid ?? port?.portName ?? "unknown-output")
    }
}
