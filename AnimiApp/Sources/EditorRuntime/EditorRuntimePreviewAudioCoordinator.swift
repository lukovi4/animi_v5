import Foundation
import TVECore
import UIKit
import os.log

private let logger = Logger(subsystem: "com.animi.app", category: "EditorRuntimePreviewAudio")

/// Owns preview-audio pipeline lifecycle: build, install, teardown.
@MainActor
internal final class EditorRuntimePreviewAudioCoordinator {
    private weak var runtime: EditorRuntime?

    // MARK: - Stored Properties

    /// Preview-audio controller. Default = legacy `EnginePreviewAudioPlaybackController` (cheap; reads no
    /// toggle). The desired controller for the CURRENT `DebugPreviewAudioWithNextEngine` toggle value is
    /// selected deterministically at playback/prepare entry via `selectControllerForToggle()` — NOT lazily
    /// at first access (which raced the launch-argument read and could cache the wrong controller forever).
    /// EXPORT is never affected; the toggle gates preview only.
    var controller: PreviewAudioControlling = EnginePreviewAudioPlaybackController()

    #if DEBUG
    /// Stage-9.2: the canonical plan source backing the installed canonical controller, retained so the
    /// canonical start path can warm up video-original real audio-track durations (+ mediaLocator URLs)
    /// BEFORE `startPlayback`, so the first synchronous `currentAudioPlan()` build has them.
    private var canonicalPlanSource: RuntimeCanonicalAudioPlanSource?

    /// Set when a test injects a controller via `setPreviewAudioController` — suppresses toggle-driven
    /// reselection so mocks are never clobbered. Production never sets this.
    private var controllerWasExplicitlyInjected = false

    /// Mark the controller as test-injected (called from `EditorRuntime.setPreviewAudioController`).
    func markControllerExplicitlyInjected() { controllerWasExplicitlyInjected = true }

    /// Deterministically select the controller for the CURRENT toggle value at start/prepare time. Rebuilds
    /// only when the desired TYPE differs from the installed one. Never runs after a test injection or after
    /// the canonical error alert has fired (so a failed canonical epoch isn't silently rebuilt). Idempotent.
    private func selectControllerForToggle() {
        guard !controllerWasExplicitlyInjected else { return }
        guard !didShowCanonicalErrorAlert else { return }
        let wantCanonical = NextPreviewAudioEngineToggles.previewAudioWithNextEngine
        let haveCanonical = controller is CanonicalPreviewAudioController
        MemoryDiagnostics.event("preview.audio.select",
            "toggle=\(wantCanonical ? "ON" : "OFF") controller=\(haveCanonical ? "Canonical" : "Legacy")")
        guard wantCanonical != haveCanonical else { return }
        controller.teardown()
        controller = makeDefaultController()
        dirty = true
        installedPipelineGeneration = nil
    }
    #endif

    func makeDefaultController() -> PreviewAudioControlling {
        #if DEBUG
        if NextPreviewAudioEngineToggles.previewAudioWithNextEngine {
            MemoryDiagnostics.event("preview.audio.canonical.selected", "toggle=ON controller=CanonicalPreviewAudioController")
            let planSource = RuntimeCanonicalAudioPlanSource(runtime: runtime)
            self.canonicalPlanSource = planSource   // Stage-9.2: retain for pre-start duration/URL warm-up.
            let canonical = CanonicalPreviewAudioControllerFactory.makeProductionController(
                planSource: planSource)
            // Surface canonical audio start telemetry on device.
            canonical.onDiagnostic = { event, detail in
                MemoryDiagnostics.event(event, detail)
            }
            // NO LEGACY FALLBACK (debug): a canonical failure must SURFACE the real error in an alert, not be
            // masked by legacy audio. This makes canonical-path defects visible on device instead of silently
            // playing the old engine.
            canonical.onCanonicalUnavailable = { [weak self] reason in
                self?.presentCanonicalAudioErrorAlert(reason: reason)
            }
            return canonical
        }
        MemoryDiagnostics.event("preview.audio.canonical.selected", "toggle=OFF controller=EnginePreviewAudioPlaybackController")
        #endif
        return EnginePreviewAudioPlaybackController()
    }

    #if DEBUG
    /// Whether the canonical error alert has already been shown (one-shot per coordinator, so a per-chunk
    /// failure storm shows ONE alert, not dozens).
    private var didShowCanonicalErrorAlert = false

    /// Surface the REAL canonical-audio failure in an alert (no legacy fallback). Stops the canonical
    /// controller so it isn't left half-running, logs the reason, and presents the error to the operator.
    private func presentCanonicalAudioErrorAlert(reason: String) {
        guard !didShowCanonicalErrorAlert else { return }
        didShowCanonicalErrorAlert = true
        MemoryDiagnostics.event("preview.audio.canonical.errorAlert", "reason=\(reason)")
        controller.teardown()              // stop the failed canonical controller (no legacy swap)
        let alert = UIAlertController(
            title: "Canonical Audio Failed",
            message: reason,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        Self.topMostViewController()?.present(alert, animated: true)
    }

    /// Best-effort top-most presented view controller from the active foreground window scene (DEBUG alert).
    private static func topMostViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first
        let keyWindow = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        var top = keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
    #endif

    /// Toggle-selection test seam: build the controller for an explicit toggle value without a runtime.
    static func makeControllerForTesting(canonicalEnabled: Bool) -> PreviewAudioControlling {
        #if DEBUG
        if canonicalEnabled {
            return CanonicalPreviewAudioControllerFactory.makeProductionController(
                planSource: RuntimeCanonicalAudioPlanSource(runtime: nil))
        }
        #endif
        return EnginePreviewAudioPlaybackController()
    }
    var dirty: Bool = true
    var generation: UInt = 0
    var orchestrationTask: Task<Void, Never>?
    var buildTask: Task<BuiltAudioPipeline?, Never>?

    private var buildToken: UInt = 0
    private var activeBuildToken: UInt?
    private var activeBuildGeneration: UInt?
    private var activeBuildIsIdlePrepare: Bool = false
    private var pendingStartWhenReady: Bool = false
    private var scheduledPrepareTask: Task<Void, Never>?
    /// Generation at which the currently installed pipeline was built.
    /// Used to prevent reuse of a stale pipeline after markDirty.
    private var installedPipelineGeneration: UInt?

    #if DEBUG
    var pipelineBuilder: (() async -> BuiltAudioPipeline?)?
    var buildGate: (() async -> Void)?
    var installedPipelineGenerationForTesting: UInt? { installedPipelineGeneration }
    #endif

    init(runtime: EditorRuntime) {
        self.runtime = runtime
    }

    // MARK: - Public API

    func markDirty() {
        guard let runtime else { return }
        dirty = true
        generation &+= 1
        #if DEBUG
        MemoryDiagnostics.event("preview.audio.markDirty", "generation=\(generation) playing=\(runtime.isPlaying ? 1 : 0) state=\(String(describing: runtime.state))")
        #endif
        if runtime.isPlaying && runtime.state == .timelinePreview {
            startForTimelinePlayback()
        } else if runtime.state == .timelinePreview {
            scheduleIdlePrepare()
        }
    }

    /// Cancels active build tasks (orchestration + detached build).
    /// Does NOT cancel scheduled prepare.
    private func cancelActiveBuild() {
        orchestrationTask?.cancel()
        orchestrationTask = nil
        buildTask?.cancel()
        buildTask = nil
        activeBuildToken = nil
        activeBuildGeneration = nil
        activeBuildIsIdlePrepare = false
        pendingStartWhenReady = false
    }

    /// Cancels deferred idle prepare if waiting.
    private func cancelScheduledPrepare() {
        scheduledPrepareTask?.cancel()
        scheduledPrepareTask = nil
    }

    /// Full cancel: active build + scheduled prepare.
    func cancelBuild() {
        cancelActiveBuild()
        cancelScheduledPrepare()
    }

    /// Invalidates preview audio after media services reset.
    /// Tears down pipeline, cancels builds, marks dirty. Does NOT auto-rebuild.
    func invalidateForMediaServicesReset() {
        #if DEBUG
        MemoryDiagnostics.event("preview.audio.invalidateForMediaServicesReset", "genBefore=\(generation)")
        #endif
        controller.teardown()
        installedPipelineGeneration = nil
        cancelBuild()
        dirty = true
        generation &+= 1
    }

    /// Silent teardown for export: destroys pipeline, cancels build, marks dirty.
    /// Does NOT trigger rebuild — export owns the lifecycle until exit.
    func teardownForExport() {
        #if DEBUG
        MemoryDiagnostics.event("preview.audio.teardownForExport", "dirtyBefore=\(dirty ? 1 : 0) genBefore=\(generation)")
        #endif
        controller.teardown()
        installedPipelineGeneration = nil
        cancelBuild()
        dirty = true
        generation &+= 1
    }

    // MARK: - Preview Audio Build Result

    enum PreviewAudioBuildResult {
        case noResolvableAudio
        case failed
        case pipeline(BuiltAudioPipeline)
    }

    // MARK: - Playback Integration

    /// Stage-9.2: pre-play warm-up of video-original real audio-track durations + mediaLocator URLs. Called
    /// from `EditorRuntime.startPlayback()` BEFORE the display link / video start (so the first-frame signal
    /// cannot precede a built canonical plan). No-op when the canonical toggle is OFF or the installed
    /// controller is not canonical. Does NOT start audio, build a legacy pipeline, or touch first-frame state.
    func warmUpCanonicalAudioForPlaybackIfNeeded() async {
        #if DEBUG
        guard NextPreviewAudioEngineToggles.previewAudioWithNextEngine,
              controller is CanonicalPreviewAudioController,
              let planSource = canonicalPlanSource else { return }
        await planSource.warmUpVideoOriginalDurations()
        #endif
    }

    func startForTimelinePlayback() {
        guard let runtime else { return }
        guard runtime.state == .timelinePreview else { return }
        cancelScheduledPrepare()

        #if DEBUG
        // Deterministically pick the controller for the current toggle BEFORE any start logic, so the
        // launch-argument value (not a stale lazy cache) governs which path runs.
        selectControllerForToggle()
        #endif

        #if DEBUG
        MemoryDiagnostics.event("preview.audio.start", "dirty=\(dirty ? 1 : 0) hasPipeline=\(controller.hasActivePipeline ? 1 : 0) readiness=\(String(describing: controller.readiness))")

        // CANONICAL DIRECT START (Slice 005 cutover): when the toggle is ON and the canonical controller is
        // installed, canonical OWNS preview audio. It evaluates its OWN AudioPlan (RuntimeCanonicalAudioPlanSource)
        // and is driven straight from the playhead — the legacy build gate (buildPipeline /
        // buildAudioExportPlan) is NOT executed on this path. This breaks the dependency where an empty
        // legacy plan (`.noResolvableAudio`) silently cancelled the canonical start. Any canonical failure /
        // silent-epoch-with-audio routes through `onCanonicalUnavailable` → `presentCanonicalAudioErrorAlert`
        // (no legacy fallback). The first-frame barrier is still crossed by `signalFirstFrameReady`.
        if NextPreviewAudioEngineToggles.previewAudioWithNextEngine,
           controller is CanonicalPreviewAudioController {
            let seconds = usToSeconds(runtime.playbackCurrentProjectTimeUs)
            MemoryDiagnostics.event("preview.audio.canonical.legacyGateBypassed",
                "seconds=\(seconds) hostTime=\(runtime.playbackCurrentHostTime)")
            MemoryDiagnostics.event("preview.audio.canonical.startPlayback.call",
                "seconds=\(seconds)")
            dirty = false
            // Stage-9.2: `startPlayback` stays SYNCHRONOUS w.r.t. the first-frame barrier (wrapping it in an
            // async Task dropped the first-frame signal before `pendingSession` existed → silence). The
            // video-original duration/URL warm-up runs EARLIER, via `warmUpCanonicalAudioForPlaybackIfNeeded()`
            // called from `EditorRuntime.startPlayback()` BEFORE the display link / video start, so the
            // synchronous `currentAudioPlan()` build here already has the real duration + mediaLocator URL.
            controller.startPlayback(fromSeconds: seconds, hostTime: runtime.playbackCurrentHostTime)
            return
        }
        #endif

        if !dirty {
            if controller.hasActivePipeline,
               (controller.readiness == .ready || controller.readiness == .primed) {
                let seconds = usToSeconds(runtime.playbackCurrentProjectTimeUs)
                #if DEBUG
                MemoryDiagnostics.event("preview.audio.start.resume", "seconds=\(seconds) hostTime=\(runtime.playbackCurrentHostTime) generation=\(generation)")
                #endif
                controller.startPlayback(
                    fromSeconds: seconds, hostTime: runtime.playbackCurrentHostTime
                )
            } else {
                #if DEBUG
                MemoryDiagnostics.event("preview.audio.start.noop", "hasPipeline=\(controller.hasActivePipeline ? 1 : 0) readiness=\(String(describing: controller.readiness))")
                #endif
            }
            return
        }

        // Join in-flight idle prepare for same generation
        if activeBuildIsIdlePrepare,
           orchestrationTask != nil,
           activeBuildGeneration == generation {
            pendingStartWhenReady = true
            activeBuildIsIdlePrepare = false
            #if DEBUG
            MemoryDiagnostics.event("preview.audio.start.awaitBuild", "generation=\(generation)")
            #endif
            return
        }

        // Pipeline ready from finished prepare — reuse only if generation matches
        if controller.hasActivePipeline, installedPipelineGeneration == generation {
            switch controller.readiness {
            case .primed:
                dirty = false
                let seconds = usToSeconds(runtime.playbackCurrentProjectTimeUs)
                #if DEBUG
                MemoryDiagnostics.event("preview.audio.start.usePrepared", "seconds=\(seconds) pipelineGen=\(String(describing: installedPipelineGeneration))")
                #endif
                controller.startPlayback(
                    fromSeconds: seconds, hostTime: runtime.playbackCurrentHostTime
                )
                return
            case .ready:
                installCallbacks(generation: generation, startWhenReady: true)
                controller.prepareForImmediatePlayback()
                return
            case .preparing:
                installCallbacks(generation: generation, startWhenReady: true)
                #if DEBUG
                MemoryDiagnostics.event("preview.audio.start.awaitReady", "generation=\(generation) pipelineGen=\(String(describing: installedPipelineGeneration))")
                #endif
                return
            case .idle, .failed:
                break
            }
        }

        startBuild(startWhenReady: true, isIdlePrepare: false)
    }

    // MARK: - Idle Prepare

    /// Deferred idle prepare — cancels previous scheduled, yields, then starts prepare.
    private func scheduleIdlePrepare() {
        cancelScheduledPrepare()
        scheduledPrepareTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.scheduledPrepareTask = nil
            self.prepareForTimelinePreview()
        }
    }

    /// Starts idle build. Only when: dirty, timelinePreview, not playing.
    func prepareForTimelinePreview() {
        guard let runtime else { return }
        guard runtime.state == .timelinePreview else { return }
        guard dirty else { return }
        guard !runtime.isPlaying else { return }
        #if DEBUG
        selectControllerForToggle()
        // The canonical controller builds its plan synchronously on explicit play (no legacy AVComposition
        // prebuild). Skip the legacy idle build entirely on the canonical path — its only effect would be to
        // run buildPipeline/buildAudioExportPlan, which we deliberately keep off the canonical path.
        if NextPreviewAudioEngineToggles.previewAudioWithNextEngine,
           controller is CanonicalPreviewAudioController {
            MemoryDiagnostics.event("preview.audio.prepare", "canonicalIdlePrepareSkipped=1")
            return
        }
        MemoryDiagnostics.event("preview.audio.prepare", "dirty=\(dirty ? 1 : 0) hasPipeline=\(controller.hasActivePipeline ? 1 : 0) readiness=\(String(describing: controller.readiness))")
        #endif
        startBuild(startWhenReady: false, isIdlePrepare: true)
    }

    // MARK: - Build

    private func startBuild(startWhenReady: Bool, isIdlePrepare: Bool) {
        cancelActiveBuild()
        buildToken &+= 1
        let token = buildToken
        activeBuildToken = token
        activeBuildGeneration = generation
        activeBuildIsIdlePrepare = isIdlePrepare
        pendingStartWhenReady = startWhenReady
        controller.teardown()
        installedPipelineGeneration = nil
        let gen = generation

        orchestrationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let buildResult = await self.buildPipeline()
            defer {
                if self.activeBuildToken == token {
                    self.orchestrationTask = nil
                    self.activeBuildToken = nil
                    self.activeBuildGeneration = nil
                    self.activeBuildIsIdlePrepare = false
                }
            }
            guard self.activeBuildToken == token else { return }
            guard self.generation == gen else { return }
            guard let runtime = self.runtime else { return }

            let shouldStart = self.pendingStartWhenReady && runtime.isPlaying

            #if DEBUG
            switch buildResult {
            case .noResolvableAudio:
                MemoryDiagnostics.event("preview.audio.build.end", "result=noResolvableAudio tracks=0 mixInputs=0")
            case .failed:
                MemoryDiagnostics.event("preview.audio.build.end", "result=failed tracks=0 mixInputs=0")
            case .pipeline(let p):
                let tracks = p.composition.tracks(withMediaType: .audio).count
                let mixInputs = p.audioMix?.inputParameters.count ?? 0
                MemoryDiagnostics.event("preview.audio.build.end", "result=pipeline tracks=\(tracks) mixInputs=\(mixInputs)")
            }
            #endif

            switch buildResult {
            case .noResolvableAudio:
                self.dirty = false
            case .failed:
                break
            case .pipeline(let pipeline):
                self.installedPipelineGeneration = gen
                self.installCallbacks(generation: gen, startWhenReady: shouldStart)
                self.controller.replacePipeline(pipeline)
            }
        }
    }

    // MARK: - Private

    func buildConfig(includeOriginalFromVideoSlots: Bool) async -> AudioExportConfig? {
        guard let runtime else { return nil }
        let music = await runtime.buildProjectMusicTrackConfig()
        return AudioExportConfig(
            music: music,
            voiceover: nil,
            includeOriginalFromVideoSlots: includeOriginalFromVideoSlots
        )
    }

    private func buildPipeline() async -> PreviewAudioBuildResult {
        #if DEBUG
        if let builder = pipelineBuilder {
            if let p = await builder() { return .pipeline(p) }
            return .noResolvableAudio
        }
        #endif

        guard let runtime else { return .failed }
        let plan = await runtime.buildAudioExportPlan(includeOriginalFromVideoSlots: true)

        #if DEBUG
        MemoryDiagnostics.event("preview.audio.build.plan", "items=\(plan.items.count)")
        if let gate = buildGate { await gate() }
        #endif

        guard !Task.isCancelled else { return .failed }
        guard let engine = runtime.timelineCompositionEngine,
              let math = engine.transitionMath else { return .failed }

        let sceneData = await engine.buildAudioSceneDataForPreview()

        #if DEBUG
        MemoryDiagnostics.event("preview.audio.build.sceneData", "scenes=\(sceneData.count)")
        #endif

        let fps = Int(runtime.sceneFPS)
        let task = Task.detached { () -> BuiltAudioPipeline? in
            let builder = AudioCompositionBuilder()
            return try? builder.buildTimeline(
                sceneData: sceneData,
                transitionMath: math,
                fps: fps,
                plan: plan
            )
        }
        self.buildTask = task
        let result = await task.value
        self.buildTask = nil

        guard let result, !result.composition.tracks(withMediaType: .audio).isEmpty else {
            #if DEBUG
            let reason: String
            if plan.items.isEmpty && sceneData.isEmpty {
                reason = "emptyPlanAndSceneData"
            } else if result == nil {
                reason = "buildFailed"
            } else {
                reason = "emptyCompositionTracks"
            }
            MemoryDiagnostics.event("preview.audio.build.noAudio", "reason=\(reason) planItems=\(plan.items.count) scenes=\(sceneData.count)")
            #endif
            return .noResolvableAudio
        }
        return .pipeline(result)
    }

    private func installCallbacks(generation gen: UInt, startWhenReady: Bool) {
        controller.onReady = { [weak self] in
            guard let self, let runtime = self.runtime, self.generation == gen,
                  runtime.state == .timelinePreview else { return }
            #if DEBUG
            MemoryDiagnostics.event("preview.audio.ready", "generation=\(gen) startWhenReady=\(startWhenReady ? 1 : 0)")
            #endif
            self.controller.prepareForImmediatePlayback()
        }
        controller.onPrepareFinished = { [weak self] result in
            guard let self, let runtime = self.runtime, self.generation == gen,
                  runtime.state == .timelinePreview else { return }
            self.handlePrepareFinished(result: result, generation: gen, startWhenReady: startWhenReady)
        }
        controller.onFailure = { [weak self] reason in
            guard let self else { return }
            self.handleControllerFailure(reason: reason, generation: gen)
        }
    }

    private func handlePrepareFinished(
        result: PreviewAudioPrepareResult,
        generation gen: UInt,
        startWhenReady: Bool
    ) {
        #if DEBUG
        MemoryDiagnostics.event("preview.audio.prepareFinished", "generation=\(gen) result=\(result) startWhenReady=\(startWhenReady ? 1 : 0)")
        #endif

        switch result {
        case .primed:
            dirty = false
            guard startWhenReady else { return }
            guard let runtime else { return }
            guard runtime.isPlaying else { return }
            let seconds = usToSeconds(runtime.playbackCurrentProjectTimeUs)
            controller.startPlayback(
                fromSeconds: seconds, hostTime: runtime.playbackCurrentHostTime
            )
        }
    }

    private func handleControllerFailure(reason: PreviewAudioFailureReason, generation gen: UInt) {
        let stale = self.generation != gen
        #if DEBUG
        MemoryDiagnostics.event("preview.audio.controllerFailure", "reason=\(reason) generation=\(gen) currentGen=\(self.generation) stale=\(stale ? 1 : 0)")
        #endif
        guard !stale else { return }
        dirty = true
        installedPipelineGeneration = nil
    }
}
