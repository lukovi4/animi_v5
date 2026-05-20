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

    #if DEBUG
    var pipelineBuilder: (() async -> BuiltAudioPipeline?)?
    var buildGate: (() async -> Void)?
    #endif

    init(runtime: EditorRuntime) {
        self.runtime = runtime
    }

    // MARK: - Public API

    func markDirty() {
        dirty = true
        generation &+= 1
        if runtime.isPlaying && runtime.state == .timelinePreview {
            startForTimelinePlayback()
        }
    }

    func cancelBuild() {
        orchestrationTask?.cancel()
        orchestrationTask = nil
        buildTask?.cancel()
        buildTask = nil
    }

    /// Silent teardown for export: destroys pipeline, cancels build, marks dirty.
    /// Does NOT trigger rebuild — export owns the lifecycle until exit.
    func teardownForExport() {
        controller.teardown()
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

        cancelBuild()

        if !dirty {
            if controller.hasActivePipeline,
               controller.readiness == .ready {
                let seconds = usToSeconds(runtime.playbackCurrentProjectTimeUs)
                controller.startPlayback(
                    fromSeconds: seconds, hostTime: runtime.playbackCurrentHostTime
                )
            }
            return
        }

        controller.teardown()
        let gen = generation

        orchestrationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let buildResult = await self.buildPipeline()
            defer { self.orchestrationTask = nil }

            guard self.generation == gen else { return }
            guard self.runtime.isPlaying else { return }

            switch buildResult {
            case .noResolvableAudio:
                self.dirty = false
            case .failed:
                break
            case .pipeline(let pipeline):
                self.installOnReady(generation: gen)
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
        if let gate = buildGate { await gate() }
        #endif

        guard !Task.isCancelled else { return .failed }
        guard let engine = runtime.timelineCompositionEngine,
              let math = engine.transitionMath else { return .failed }

        let sceneData = await engine.buildAudioSceneDataForPreview()

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
            return .noResolvableAudio
        }
        return .pipeline(result)
    }

    private func installOnReady(generation gen: UInt) {
        controller.onReady = { [weak self] in
            guard let self else { return }
            guard self.generation == gen else { return }
            guard self.runtime.isPlaying else { return }
            guard self.runtime.state == .timelinePreview else { return }
            self.dirty = false
            let seconds = usToSeconds(self.runtime.playbackCurrentProjectTimeUs)
            self.controller.startPlayback(
                fromSeconds: seconds, hostTime: self.runtime.playbackCurrentHostTime
            )
        }
    }
}
