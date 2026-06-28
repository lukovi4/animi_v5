import Foundation
import AnimiEngineCore

/// Slice-005 Stage B — the pure app-side bridge that turns the app's current editor state into a
/// canonical `AudioPlan` through the **canonical** `AudioEvaluator` (plan §3.1 / Stage B).
///
/// It composes the Stage-A bridges with the canonical builders the Next *video* path already uses:
///
///   app audio items ──▶ AppAudioManifestBridge ──▶ populated AudioManifest
///   video CanonicalProjectDocument (manifest.audio == .empty)  ──┐
///                                                                 ├─▶ manifest WITH audio injected
///   AppAudioSourceDescriptorResolver ─▶ [ResolvedAudioSourceDescriptor]
///                                                                 ▼
///   TimelineIndex.requirements(for: coverage)  ─▶ EvaluationWindowRequirement
///                                                                 ▼
///   AudioEvaluationWindowBuilder.build(...)     ─▶ AudioEvaluationWindow
///                                                                 ▼
///   AudioEvaluator.evaluate(window:range:)      ─▶ AudioPlan
///
/// Stage B scope (STRICT): produce `AudioEvaluationWindow` + `AudioPlan` only. It does **NOT** wire any
/// playback lifecycle (play/pause/scrub), decode PCM, build the `PreviewAudioGraph`, touch export, or use
/// any legacy `AVMutableComposition`/`AVAudioMix`. It is pure, deterministic, fail-closed.
///
/// Canonical rules preserved structurally:
/// - playback policy is `.once` only (no loop / `loopToFit`) — enforced in `AppAudioManifestBridge`;
/// - no transition volume ramps are read or invented — the canonical audio model has no ramp concept, so
///   nothing here can approximate one; video-layer original audio is refused upstream (Stage A);
/// - no scrub audio — this bridge produces a plan value only; it starts nothing.
enum AppAudioEvaluationBridge {

    /// One evaluation result: the window the evaluator consumed and the plan it produced. Carrying the
    /// window lets the caller (Stage C) re-evaluate sub-ranges without rebuilding it.
    struct Result: Equatable {
        let window: AudioEvaluationWindow
        let plan: AudioPlan
    }

    /// Build the canonical `AudioEvaluationWindow` for the whole project, injecting the populated audio
    /// manifest into the video document's manifest (whose `audio` is `.empty`).
    ///
    /// - Parameters:
    ///   - videoDocument: the canonical project document the app already builds for video
    ///     (`NextTimelineBridge` path). Its `manifest.audio` is ignored/replaced.
    ///   - audioItems: the app audio items (Stage-A `Input`s).
    ///   - includeOriginalFromVideoSlots: must be `false` on Stage A/B (video-layer original audio is
    ///     refused upstream — no fake mapping).
    ///   - probe: injected source probe for descriptor resolution (fake in tests; AVFoundation behind it
    ///     in a later step).
    static func buildWindow(
        videoDocument: CanonicalProjectDocument,
        audioItems: [AppAudioManifestBridge.Input],
        includeOriginalFromVideoSlots: Bool,
        probe: AppAudioSourceDescriptorResolver.Probe
    ) throws -> AudioEvaluationWindow {
        // 1. Populated audio manifest from the app model (Stage A).
        let audioManifest = try AppAudioManifestBridge.buildManifest(
            items: audioItems, includeOriginalFromVideoSlots: includeOriginalFromVideoSlots)

        // 2. Inject the audio manifest into a copy of the video manifest (same video fields, audio added).
        let videoManifest = videoDocument.manifest
        let manifestWithAudio = CanonicalProjectManifest(
            schemaVersion: videoManifest.schemaVersion,
            output: videoManifest.output,
            scenes: videoManifest.scenes,
            boundaryTransitions: videoManifest.boundaryTransitions,
            overlays: videoManifest.overlays,
            audio: audioManifest)

        // 3. Resolve exactly-one descriptor per referenced source (Stage A; fail-closed on 0/many).
        let descriptors = try AppAudioSourceDescriptorResolver.resolve(manifest: audioManifest, probe: probe)

        // 4. Derive the requirement over full project coverage — the SAME path the video window uses.
        let index = try TimelineIndex(manifest: manifestWithAudio)
        let duration = try manifestWithAudio.projectDuration()
        let coverage = try ProjectTimeRange(start: .zero, end: try ProjectTime(ticks: duration.ticks))
        let requirement = try index.requirements(for: coverage)

        // 5. Build the canonical audio window.
        return try AudioEvaluationWindowBuilder.build(
            manifest: manifestWithAudio,
            requirement: requirement,
            scenes: videoDocument.scenePayloads,
            sourceDescriptors: descriptors)
    }

    /// Build the window and evaluate the whole project coverage, returning the window + `AudioPlan`.
    ///
    /// Empty app audio → a window with no clips → a **valid silent** `AudioPlan` (zero segments), NOT an
    /// error. Non-empty global music → a non-empty `AudioPlan`. The evaluator used is the canonical
    /// `AudioEvaluator` — never a legacy `AVMutableComposition`/`AVAudioMix`.
    static func evaluateWholeProject(
        videoDocument: CanonicalProjectDocument,
        audioItems: [AppAudioManifestBridge.Input],
        includeOriginalFromVideoSlots: Bool,
        probe: AppAudioSourceDescriptorResolver.Probe
    ) throws -> Result {
        let window = try buildWindow(
            videoDocument: videoDocument,
            audioItems: audioItems,
            includeOriginalFromVideoSlots: includeOriginalFromVideoSlots,
            probe: probe)
        let plan = try AudioEvaluator.evaluate(window: window, range: window.coverage)
        return Result(window: window, plan: plan)
    }
}
