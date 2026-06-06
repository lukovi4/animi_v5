import Foundation
import TVECore
import os.log

private let logger = Logger(subsystem: "com.animi.app", category: "EditorRuntimePreviewAudio")

/// Owns preview-audio pipeline lifecycle: build, install, teardown.
@MainActor
internal final class EditorRuntimePreviewAudioCoordinator {
    private weak var runtime: EditorRuntime?

    // MARK: - Stored Properties

    lazy var controller: PreviewAudioControlling = EnginePreviewAudioPlaybackController()
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
    /// Test observable: whether any audio build/orchestration/scheduled-prepare is in
    /// flight. Tests use this to assert the boot-time audio prepare has fully settled
    /// before re-establishing the dirty start precondition.
    var hasActiveAudioWorkForTesting: Bool {
        orchestrationTask != nil || buildTask != nil || scheduledPrepareTask != nil
    }
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

    // MARK: - Epoch Audio Readiness (hard-gated start)

    /// Audio readiness outcome for a playback-start epoch.
    enum PreviewAudioEpochReadiness: Equatable {
        /// No audible preview audio is resolvable — the boundary may open without audio.
        case noAudio
        /// Audio is primed and can be scheduled at the epoch boundary.
        case ready
        /// Audio preparation failed — the boundary must NOT open best-effort.
        case failed
        /// The audio generation changed during preparation (an edit/markDirty raced the
        /// epoch). The boundary must NOT open and `dirty` must NOT be cleared from this
        /// stale result; a new Play must re-resolve audio.
        case stale
    }

    /// Resolves preview-audio readiness as an explicit participant of the playback-start
    /// epoch, BEFORE the shared boundary opens.
    ///
    /// Hard-gated contract: this prepares (building if dirty) and primes the audio
    /// pipeline, then returns. The caller opens the boundary only on `.noAudio` or
    /// `.ready`; on `.failed` it must hold the requested frame and not start best-effort.
    /// No playback is scheduled here — scheduling happens later via
    /// `startForTimelinePlayback(audioStart:)` from the captured epoch boundary, so audio
    /// never reads mutable runtime fields for the initial epoch start.
    func prepareAudioForEpochStart() async -> PreviewAudioEpochReadiness {
        guard let runtime, runtime.state == .timelinePreview else { return .noAudio }
        cancelScheduledPrepare()

        // Capture the audio generation for THIS epoch. Any `markDirty()`/edit during the
        // awaits below bumps `generation`; a stale result must not open the boundary or
        // clear `dirty`.
        let epochGen = generation

        // Fast path: a fresh, already-prepared pipeline can be used as-is.
        if !dirty {
            if controller.hasActivePipeline {
                switch controller.readiness {
                case .primed:
                    return .ready
                case .ready, .preparing:
                    return await primeForEpoch(epochGen: epochGen)
                case .idle, .failed:
                    break
                }
            } else {
                // Not dirty and no pipeline → nothing audible to gate on.
                return .noAudio
            }
        }

        // Join an in-flight build (e.g. an idle prepare) for the current generation
        // instead of starting a redundant one. Once it finishes it installs+primes the
        // pipeline via its own callbacks; we then reuse it through the readiness path.
        if let inFlight = orchestrationTask, activeBuildGeneration == epochGen {
            pendingStartWhenReady = false
            await inFlight.value
            guard generation == epochGen else { return .stale }
            if controller.hasActivePipeline, installedPipelineGeneration == epochGen {
                switch controller.readiness {
                case .primed:
                    dirty = false
                    return .ready
                case .ready, .preparing:
                    return await primeForEpoch(epochGen: epochGen)
                case .idle, .failed:
                    break
                }
            }
            // In-flight build resolved to no-audio / failure / stale → fall through to a
            // fresh resolve below (only if still current).
            guard generation == epochGen else { return .stale }
        }

        // Dirty (or idle/failed with stale pipeline): build, install, prime.
        let buildResult = await buildPipelineForEpoch()

        // If an edit raced the build, do not accept the stale result and do not clear
        // dirty — a new Play must re-resolve audio.
        guard generation == epochGen else { return .stale }

        switch buildResult {
        case .noResolvableAudio:
            dirty = false
            return .noAudio
        case .failed:
            // Leave dirty for retry; existing failure/dirty path, no new UI.
            dirty = true
            installedPipelineGeneration = nil
            return .failed
        case .pipeline(let pipeline):
            installedPipelineGeneration = epochGen
            controller.replacePipeline(pipeline)
            return await primeForEpoch(epochGen: epochGen)
        }
    }

    /// Primes the installed pipeline for the epoch and re-checks the audio generation
    /// after the await. On a generation change returns `.stale` (no boundary, dirty
    /// untouched); on success clears `dirty` and returns `.ready`.
    private func primeForEpoch(epochGen: UInt) async -> PreviewAudioEpochReadiness {
        let primed = await primeCurrentPipeline()
        guard generation == epochGen else { return .stale }
        if primed == .ready { dirty = false }
        return primed
    }

    /// Builds the preview-audio pipeline once for an epoch start, bridging the existing
    /// detached build to a single awaited result. Cancellation/teardown maps to `.failed`
    /// so the caller does not open a best-effort boundary.
    private func buildPipelineForEpoch() async -> PreviewAudioBuildResult {
        cancelActiveBuild()
        controller.teardown()
        installedPipelineGeneration = nil
        return await buildPipeline()
    }

    /// Primes the currently installed pipeline and awaits the `.primed` transition.
    /// Returns `.ready` on primed, `.failed` on controller failure.
    private func primeCurrentPipeline() async -> PreviewAudioEpochReadiness {
        guard controller.hasActivePipeline else { return .failed }
        if controller.readiness == .primed { return .ready }

        let gen = generation
        return await withCheckedContinuation { (cont: CheckedContinuation<PreviewAudioEpochReadiness, Never>) in
            var resumed = false
            let finish: (PreviewAudioEpochReadiness) -> Void = { outcome in
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: outcome)
            }
            controller.onReady = { [weak self] in
                guard let self, self.generation == gen else { finish(.failed); return }
                self.controller.prepareForImmediatePlayback()
            }
            controller.onPrepareFinished = { [weak self] result in
                guard let self, self.generation == gen else { finish(.failed); return }
                switch result {
                case .primed:
                    finish(.ready)
                }
            }
            controller.onFailure = { [weak self] reason in
                guard let self else { finish(.failed); return }
                self.handleControllerFailure(reason: reason, generation: gen)
                finish(.failed)
            }

            // Kick the prepare. If already `.ready`, prepare immediately; otherwise the
            // `.ready` callback above drives it once the PCM file is rendered/opened.
            if controller.readiness == .ready {
                controller.prepareForImmediatePlayback()
            }
        }
    }

    // MARK: - Playback Integration

    /// Starts preview audio for timeline playback.
    ///
    /// - Parameter audioStart: The epoch's shared boundary value. When provided
    ///   (initial epoch start), audio opens from exactly the same boundary as
    ///   transport / video / render. When `nil` (resume / audio-route change), audio
    ///   opens from the runtime's current live playback fields, which is correct for
    ///   joining playback already in progress.
    func startForTimelinePlayback(audioStart: PlaybackAudioStart? = nil) {
        guard let runtime else { return }
        guard runtime.state == .timelinePreview else { return }
        cancelScheduledPrepare()

        // Resolve the start position: prefer the explicit epoch boundary; otherwise
        // fall back to the runtime's live playback fields (resume/route-change).
        let startSeconds = audioStart?.fromSeconds ?? usToSeconds(runtime.playbackCurrentProjectTimeUs)
        let startHostTime = audioStart?.boundaryHostTime ?? runtime.playbackCurrentHostTime

        #if DEBUG
        MemoryDiagnostics.event("preview.audio.start", "dirty=\(dirty ? 1 : 0) hasPipeline=\(controller.hasActivePipeline ? 1 : 0) readiness=\(String(describing: controller.readiness)) epoch=\(audioStart != nil ? 1 : 0)")
        #endif

        if !dirty {
            if controller.hasActivePipeline,
               (controller.readiness == .ready || controller.readiness == .primed) {
                #if DEBUG
                MemoryDiagnostics.event("preview.audio.start.resume", "seconds=\(startSeconds) hostTime=\(startHostTime) generation=\(generation)")
                #endif
                controller.startPlayback(
                    fromSeconds: startSeconds, hostTime: startHostTime
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
                #if DEBUG
                MemoryDiagnostics.event("preview.audio.start.usePrepared", "seconds=\(startSeconds) pipelineGen=\(String(describing: installedPipelineGeneration))")
                #endif
                controller.startPlayback(
                    fromSeconds: startSeconds, hostTime: startHostTime
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
