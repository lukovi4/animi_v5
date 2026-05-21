import Foundation
import TVECore
import os.log

private let logger = Logger(subsystem: "com.animi.app", category: "EditorRuntimePreviewAudio")

/// Owns preview-audio pipeline lifecycle: build, install, teardown.
@MainActor
internal final class EditorRuntimePreviewAudioCoordinator {
    unowned let runtime: EditorRuntime

    // MARK: - Stored Properties

    lazy var controller: PreviewAudioControlling = PreviewAudioPlaybackController()
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

    func startForTimelinePlayback() {
        guard runtime.state == .timelinePreview else { return }
        cancelScheduledPrepare()

        #if DEBUG
        MemoryDiagnostics.event("preview.audio.start", "dirty=\(dirty ? 1 : 0) hasPipeline=\(controller.hasActivePipeline ? 1 : 0) readiness=\(String(describing: controller.readiness))")
        #endif

        if !dirty {
            if controller.hasActivePipeline,
               controller.readiness == .ready {
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
            case .ready:
                dirty = false
                let seconds = usToSeconds(runtime.playbackCurrentProjectTimeUs)
                #if DEBUG
                MemoryDiagnostics.event("preview.audio.start.usePrepared", "seconds=\(seconds) pipelineGen=\(String(describing: installedPipelineGeneration))")
                #endif
                controller.startPlayback(
                    fromSeconds: seconds, hostTime: runtime.playbackCurrentHostTime
                )
                return
            case .preparing:
                installOnReady(generation: generation, startWhenReady: true)
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

            let shouldStart = self.pendingStartWhenReady
            if shouldStart {
                guard self.runtime.isPlaying else { return }
            }

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
                self.installOnReady(generation: gen, startWhenReady: shouldStart)
                self.controller.replacePipeline(pipeline)
            }
        }
    }

    // MARK: - Private

    func buildConfig(includeOriginalFromVideoSlots: Bool) async -> AudioExportConfig? {
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

    private func installOnReady(generation gen: UInt, startWhenReady: Bool) {
        controller.onReady = { [weak self] in
            guard let self, self.generation == gen,
                  self.runtime.state == .timelinePreview else { return }
            self.dirty = false
            #if DEBUG
            MemoryDiagnostics.event("preview.audio.ready", "generation=\(gen) startWhenReady=\(startWhenReady ? 1 : 0)")
            #endif
            guard startWhenReady else { return }
            guard self.runtime.isPlaying else { return }
            let seconds = usToSeconds(self.runtime.playbackCurrentProjectTimeUs)
            self.controller.startPlayback(
                fromSeconds: seconds, hostTime: self.runtime.playbackCurrentHostTime
            )
        }
        controller.onFailure = { [weak self] reason in
            guard let self else { return }
            self.handleControllerFailure(reason: reason, generation: gen)
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
