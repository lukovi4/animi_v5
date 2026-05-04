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
            let pipeline = await self.buildPipeline()
            defer { self.orchestrationTask = nil }

            guard self.generation == gen else { return }
            guard self.runtime.isPlaying else { return }

            guard let pipeline else {
                if !self.hasContent {
                    self.dirty = false
                }
                return
            }

            self.installOnReady(generation: gen)
            self.controller.replacePipeline(pipeline)
        }
    }

    // MARK: - Private

    private var hasContent: Bool {
        guard let state = runtime.session.state,
              let _ = state.canonicalTimeline.musicItem,
              let payload = state.canonicalTimeline.musicPayload(),
              case .imported = payload.assetRef else {
            return false
        }
        return true
    }

    func buildConfig(includeOriginalFromVideoSlots: Bool) async -> AudioExportConfig? {
        let music = await runtime.buildProjectMusicTrackConfig()
        return AudioExportConfig(
            music: music,
            voiceover: nil,
            includeOriginalFromVideoSlots: includeOriginalFromVideoSlots
        )
    }

    private func buildPipeline() async -> BuiltAudioPipeline? {
        #if DEBUG
        if let builder = pipelineBuilder {
            return await builder()
        }
        #endif

        let config = await buildConfig(includeOriginalFromVideoSlots: false)
        guard let config, config.music != nil else { return nil }

        #if DEBUG
        if let gate = buildGate { await gate() }
        #endif

        guard !Task.isCancelled else { return nil }
        guard let engine = runtime.timelineCompositionEngine,
              let math = engine.transitionMath else { return nil }

        let fps = Int(runtime.sceneFPS)
        let task = Task.detached { () -> BuiltAudioPipeline? in
            let builder = AudioCompositionBuilder()
            return try? builder.buildTimeline(
                sceneData: [],
                transitionMath: math,
                fps: fps,
                config: config
            )
        }
        self.buildTask = task
        let result = await task.value
        self.buildTask = nil
        return result
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
