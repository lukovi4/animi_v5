import XCTest
import Metal
import TVECore
@testable import AnimiApp

// MARK: - Mock Controller

@MainActor
final class MockPreviewAudioController: PreviewAudioControlling {
    var replacePipelineCallCount = 0
    var startPlaybackCallCount = 0
    var pauseCallCount = 0
    var teardownCallCount = 0
    var lastStartFromSeconds: Double?
    var lastStartHostTime: CFTimeInterval?
    var hasActivePipeline = false

    func replacePipeline(_ pipeline: BuiltAudioPipeline) {
        replacePipelineCallCount += 1
        hasActivePipeline = true
    }
    func startPlayback(fromSeconds: Double, hostTime: CFTimeInterval) {
        startPlaybackCallCount += 1
        lastStartFromSeconds = fromSeconds
        lastStartHostTime = hostTime
    }
    func pause() { pauseCallCount += 1 }
    func teardown() { teardownCallCount += 1; hasActivePipeline = false }
}

// MARK: - Controllable Pipeline Builder

@MainActor
final class ControllablePipelineBuilder {
    private var pendingContinuations: [CheckedContinuation<BuiltAudioPipeline?, Never>] = []
    var buildCallCount = 0

    var builder: (() async -> BuiltAudioPipeline?) {
        { [weak self] in
            self?.buildCallCount += 1
            return await withCheckedContinuation { cont in
                self?.pendingContinuations.append(cont)
            }
        }
    }

    var pendingCount: Int { pendingContinuations.count }

    func completeNext(with pipeline: BuiltAudioPipeline?) {
        guard !pendingContinuations.isEmpty else { return }
        let cont = pendingContinuations.removeFirst()
        cont.resume(returning: pipeline)
    }

    func complete(at index: Int, with pipeline: BuiltAudioPipeline?) {
        guard index < pendingContinuations.count else { return }
        let cont = pendingContinuations.remove(at: index)
        cont.resume(returning: pipeline)
    }

    func drainAll() {
        while !pendingContinuations.isEmpty {
            completeNext(with: nil)
        }
    }
}

// MARK: - Stub Helpers

private struct StubMediaLocator: ProjectMediaLocator {
    var rootDir: URL?
    func absoluteURL(for mediaRef: MediaRef, registry: ProjectAssetRegistry) async throws -> URL {
        if let root = rootDir {
            if let path = registry.storagePath(for: mediaRef.assetId) {
                return root.appendingPathComponent(path)
            }
            return root.appendingPathComponent(mediaRef.storagePath)
        }
        return URL(fileURLWithPath: "/tmp/stub")
    }
}

private struct StubMediaWriter: ProjectMediaWriteGateway {
    func saveBackgroundImage(from preparedFileURL: URL) async throws -> (MediaRef, URL) {
        (MediaRef(storagePath: "stub.jpg"), URL(fileURLWithPath: "/tmp/stub"))
    }
    func saveUserMedia(from fileURL: URL, mediaKind: MediaKind, filename: String) async throws -> (MediaRef, URL) {
        (MediaRef(storagePath: "stub.jpg"), URL(fileURLWithPath: "/tmp/stub"))
    }
    func deleteMediaFile(_ mediaRef: MediaRef) async throws {}
    func duplicateAssets(inDraft sourceDraft: ProjectDraft) async throws -> ProjectDraft { sourceDraft }
}

private struct StubPresetProvider: BackgroundPresetProviding {
    func loadFromBundle() throws {}
    func preset(for presetId: String) -> BackgroundPreset? { nil }
    func presetOrFallback(for presetId: String) -> BackgroundPreset? { nil }
    var allPresets: [BackgroundPreset] { [] }
    var count: Int { 0 }
}

// MARK: - Tests

@MainActor
final class ProjectAudioPreviewPlaybackTests: XCTestCase {

    // MARK: - Helpers

    private func makeBootstrappedSession() async -> EditorSession {
        let deps = EditorSessionDependencies(
            saveActiveDraft: { _ in },
            loadActiveDraft: { nil },
            deleteActiveDraft: {},
            loadSavedProject: { _ in nil },
            materializeSavedProject: { $0 },
            mediaLocator: StubMediaLocator(),
            mediaWriter: StubMediaWriter(),
            loadSceneLibrary: {
                SceneLibrarySnapshot(
                    fps: 30,
                    canvas: CanvasConfig(width: 1080, height: 1920),
                    scenes: [
                        SceneTypeDescriptor(id: "scene_1", order: 0, title: "Test", baseDurationUs: 3_000_000)
                    ]
                )
            },
            sceneTypeDefaults: { _, _ in
                [SceneTypeDefault(sceneTypeId: "scene_1", baseDurationUs: 3_000_000)]
            },
            loadTemplateCatalog: {
                .success(TemplateCatalogSnapshot(categories: [], templates: []))
            },
            backgroundPresetProvider: StubPresetProvider()
        )
        let session = EditorSession(intent: .template(templateId: "tpl_1"), dependencies: deps)
        await session.bootstrap()
        return session
    }

    private func makeBootedRuntime(state: EditorRuntimeState = .timelinePreview) async -> (EditorSession, EditorRuntime) {
        let session = await makeBootstrappedSession()
        let runtime = EditorRuntime(session: session)
        runtime.bootForTesting(state: state)
        return (session, runtime)
    }

    /// Creates a seeded TimelineCompositionEngine with transitionMath populated.
    /// Returns nil if Metal is unavailable.
    private func makeSeededEngine(session: EditorSession) -> TimelineCompositionEngine? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        let engine = TimelineCompositionEngine(
            device: device,
            commandQueue: commandQueue,
            fps: 30,
            mediaLocator: StubMediaLocator()
        )
        if let editorState = session.state {
            engine.setTimeline(
                editorState.canonicalTimeline,
                sceneStates: editorState.draft.sceneInstanceStates,
                assetRegistry: editorState.draft.assetRegistry.selfHealed(for: editorState.draft)
            )
        }
        return engine
    }

    /// Creates a runtime with a real, seeded TimelineCompositionEngine injected,
    /// so `startPlayback()` passes the engine guard and runs the full production path
    /// with active transitionMath.
    /// Returns nil if Metal is unavailable (test will be skipped).
    private func makePlayableRuntime(state: EditorRuntimeState = .timelinePreview) async -> (EditorSession, EditorRuntime)? {
        let (session, runtime) = await makeBootedRuntime(state: state)
        guard let engine = makeSeededEngine(session: session) else { return nil }
        runtime.injectTimelineCompositionEngine(engine)
        return (session, runtime)
    }

    /// Creates a runtime with a real audio item so `buildPreviewAudioConfig` returns music.
    /// Uses production `buildPreviewAudioPipeline()` (no injected builder).
    /// Returns (runtime, tempDir) or nil if Metal unavailable. Caller must clean up tempDir.
    private func makePlayableRuntimeWithAudio() async throws -> (EditorRuntime, URL)? {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PR3bTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let storagePath = "audio/test_music.m4a"
        let audioFileURL = tempDir.appendingPathComponent(storagePath)
        try FileManager.default.createDirectory(
            at: audioFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not_real_audio".utf8).write(to: audioFileURL)

        let assetId = ProjectAssetID()
        var draft = ProjectDraft.create(origin: .template(templateId: "test-template"))
        let scenePid = UUID()
        draft.canonicalTimeline.payloads[scenePid] = .scene(ScenePayload(sceneTypeId: "scene_1"))
        draft.canonicalTimeline.tracks[0].items.append(
            TimelineItem(payloadId: scenePid, kind: .scene, startUs: nil, durationUs: 3_000_000)
        )
        draft.assetRegistry.register(ProjectAssetDescriptor(
            assetId: assetId, mediaKind: .audio, storagePath: storagePath
        ))
        let audioPid = UUID()
        draft.canonicalTimeline.payloads[audioPid] = .audio(AudioPayload(
            assetRef: .imported(assetId: assetId, storagePath: storagePath),
            sourceDurationUs: 5_000_000,
            trimStartUs: 0,
            trimEndUs: 5_000_000,
            volume: 1.0
        ))
        var audioTrack = Track(kind: .audio)
        audioTrack.items.append(TimelineItem(
            payloadId: audioPid, kind: .audioClip, startUs: 0, durationUs: 5_000_000
        ))
        draft.canonicalTimeline.tracks.append(audioTrack)

        let slot = ActiveDraftSlot(
            entryContext: .newProject(origin: draft.origin),
            linkedSavedProjectId: nil,
            draft: draft
        )
        let deps = EditorSessionDependencies(
            saveActiveDraft: { _ in },
            loadActiveDraft: { slot },
            deleteActiveDraft: {},
            loadSavedProject: { _ in nil },
            materializeSavedProject: { $0 },
            mediaLocator: StubMediaLocator(rootDir: tempDir),
            mediaWriter: StubMediaWriter(),
            loadSceneLibrary: {
                SceneLibrarySnapshot(
                    fps: 30,
                    canvas: CanvasConfig(width: 1080, height: 1920),
                    scenes: [
                        SceneTypeDescriptor(id: "scene_1", order: 0, title: "Test", baseDurationUs: 3_000_000)
                    ]
                )
            },
            sceneTypeDefaults: { _, _ in
                [SceneTypeDefault(sceneTypeId: "scene_1", baseDurationUs: 3_000_000)]
            },
            loadTemplateCatalog: {
                .success(TemplateCatalogSnapshot(categories: [], templates: []))
            },
            backgroundPresetProvider: StubPresetProvider()
        )
        let session = EditorSession(intent: .resumeDraft, dependencies: deps)
        await session.bootstrap()

        let runtime = EditorRuntime(session: session)
        runtime.bootForTesting(state: .timelinePreview)

        guard let engine = makeSeededEngine(session: session) else {
            try? FileManager.default.removeItem(at: tempDir)
            return nil
        }
        runtime.injectTimelineCompositionEngine(engine)
        return (runtime, tempDir)
    }

    private func makeDummyPipeline() -> BuiltAudioPipeline {
        BuiltAudioPipeline(composition: .init(), audioMix: nil)
    }

    /// Waits for the `playbackStartTask` to complete (engine.prepareForPlayback is async).
    private func waitForPlaybackStart(_ runtime: EditorRuntime) async {
        // playbackStartTask is a Task that calls prepareForPlayback then sets isPlaying.
        // With nil transitionMath, prepareForPlayback returns immediately, but
        // the Task still needs a yield to execute.
        for _ in 0..<5 {
            await Task.yield()
            if runtime.isPlaying { break }
        }
    }

    // MARK: - Test 1: stopPlayback pauses preview audio

    func test_stopPlayback_pausesPreviewAudio() async {
        let (_, runtime) = await makeBootedRuntime()
        let mock = MockPreviewAudioController()
        runtime.setPreviewAudioController(mock)

        runtime.stopPlayback()

        XCTAssertEqual(mock.pauseCallCount, 1)
    }

    // MARK: - Test 2: stopPlayback bumps generation

    func test_stopPlayback_bumpsGeneration() async {
        let (_, runtime) = await makeBootedRuntime()
        let genBefore = runtime.previewAudioGeneration

        runtime.stopPlayback()

        XCTAssertGreaterThan(runtime.previewAudioGeneration, genBefore)
    }

    // MARK: - Test 3: enterExportMode tears down preview audio

    func test_enterExportMode_tearsDownPreviewAudio() async {
        let (_, runtime) = await makeBootedRuntime()
        let mock = MockPreviewAudioController()
        runtime.setPreviewAudioController(mock)

        runtime.simulateEnterExportMode()

        XCTAssertGreaterThanOrEqual(mock.teardownCallCount, 1)
    }

    // MARK: - Test 4: markDirty when not playing → no immediate rebuild

    func test_markPreviewAudioDirty_notPlaying_noImmediateRebuild() async {
        let (_, runtime) = await makeBootedRuntime()
        let mock = MockPreviewAudioController()
        runtime.setPreviewAudioController(mock)

        runtime.markPreviewAudioDirty()

        XCTAssertEqual(mock.teardownCallCount, 0)
        XCTAssertEqual(mock.replacePipelineCallCount, 0)
        XCTAssertTrue(runtime.previewAudioDirty)
    }

    // MARK: - Test 5: markDirty while playing → triggers rebuild

    func test_markPreviewAudioDirty_whilePlaying_rebuildsImmediately() async throws {
        guard let (_, runtime) = await makePlayableRuntime() else {
            throw XCTSkip("Metal device not available")
        }
        let mock = MockPreviewAudioController()
        runtime.setPreviewAudioController(mock)
        runtime.previewAudioPipelineBuilder = { nil }

        // Start real playback through production path
        runtime.startPlayback()
        await waitForPlaybackStart(runtime)
        XCTAssertTrue(runtime.isPlaying, "Runtime should be playing via production startPlayback()")

        // Reset mock counts from initial startPlayback audio trigger
        let teardownBefore = mock.teardownCallCount

        runtime.markPreviewAudioDirty()

        // teardown is called during rebuild path (dirty + playing → startPreviewAudioForTimelinePlayback → teardown)
        XCTAssertGreaterThan(mock.teardownCallCount, teardownBefore)

        runtime.stopPlayback()
    }

    // MARK: - Test 6: buildPreviewAudioConfig preview excludes video slots

    func test_buildPreviewAudioConfig_previewExcludesVideoSlots() async {
        let (_, runtime) = await makeBootedRuntime()

        let config = await runtime.buildPreviewAudioConfig(includeOriginalFromVideoSlots: false)
        XCTAssertNotNil(config)
        XCTAssertFalse(config!.includeOriginalFromVideoSlots)
    }

    // MARK: - Test 7: buildPreviewAudioConfig export includes video slots

    func test_buildPreviewAudioConfig_exportIncludesVideoSlots() async {
        let (_, runtime) = await makeBootedRuntime()

        let config = await runtime.buildPreviewAudioConfig(includeOriginalFromVideoSlots: true)
        XCTAssertNotNil(config)
        XCTAssertTrue(config!.includeOriginalFromVideoSlots)
    }

    // MARK: - Test 8: pause then play resumes without rebuilding pipeline

    func test_pauseThenPlay_resumesFromCurrentPlayhead() async throws {
        guard let (_, runtime) = await makePlayableRuntime() else {
            throw XCTSkip("Metal device not available")
        }
        let mock = MockPreviewAudioController()
        runtime.setPreviewAudioController(mock)

        // Use controllable builder so we can complete the initial build to set dirty=false
        let controllable = ControllablePipelineBuilder()
        runtime.previewAudioPipelineBuilder = controllable.builder

        // 1) Start playback → triggers async pipeline build (dirty=true path)
        runtime.startPlayback()
        await waitForPlaybackStart(runtime)
        XCTAssertTrue(runtime.isPlaying)

        // Allow rebuild task to reach builder
        for _ in 0..<10 {
            await Task.yield()
            if controllable.pendingCount >= 1 { break }
        }
        XCTAssertGreaterThanOrEqual(controllable.pendingCount, 1, "Builder should have been called")

        // Complete the initial build with a real pipeline → dirty becomes false
        let pipeline = makeDummyPipeline()
        controllable.completeNext(with: pipeline)
        for _ in 0..<5 { await Task.yield() }

        XCTAssertFalse(runtime.previewAudioDirty, "Dirty should be false after successful pipeline build")
        XCTAssertEqual(mock.replacePipelineCallCount, 1, "Pipeline should have been replaced once")
        let startCountAfterFirstPlay = mock.startPlaybackCallCount

        // 2) Stop → pauses without teardown
        //    Note: startPreviewAudioForTimelinePlayback tears down before rebuild (teardownCount == 1 from step 1),
        //    but stopPlayback should only add a pause, not another teardown.
        let teardownBefore = mock.teardownCallCount
        runtime.stopPlayback()
        XCTAssertEqual(mock.teardownCallCount, teardownBefore,
                       "Stop should pause, not add another teardown")

        // 3) Resume playback → !dirty + hasActivePipeline → just startPlayback, no rebuild
        let replaceCountBefore = mock.replacePipelineCallCount
        runtime.startPlayback()
        await waitForPlaybackStart(runtime)
        await Task.yield()

        // startPreviewAudioForTimelinePlayback sees !dirty + hasActivePipeline → direct resume
        XCTAssertEqual(mock.replacePipelineCallCount, replaceCountBefore,
                       "Resume path should NOT rebuild pipeline")
        XCTAssertGreaterThan(mock.startPlaybackCallCount, startCountAfterFirstPlay,
                             "Resume path should call startPlayback(fromSeconds:)")

        runtime.stopPlayback()
        controllable.drainAll()
    }

    // MARK: - Test 9: sceneEdit mode doesn't start preview audio (via real startPlayback)

    func test_sceneEditMode_doesNotStartPreviewAudio() async throws {
        guard let (_, runtime) = await makePlayableRuntime(state: .sceneEdit(instanceId: UUID())) else {
            throw XCTSkip("Metal device not available")
        }
        let mock = MockPreviewAudioController()
        runtime.setPreviewAudioController(mock)
        runtime.previewAudioPipelineBuilder = { nil }

        // Call real startPlayback() — passes engine guard.
        // Note: startPlayback() hardcodes EditorRenderContract.isPlaybackAllowed(in: .timeline),
        // so it proceeds regardless of runtime state. Preview audio guard is in
        // startPreviewAudioForTimelinePlayback (state == .timelinePreview).
        runtime.startPlayback()
        await waitForPlaybackStart(runtime)

        // Audio controller should NOT have been touched
        XCTAssertEqual(mock.replacePipelineCallCount, 0, "Preview audio must not build pipeline in sceneEdit mode")
        XCTAssertEqual(mock.startPlaybackCallCount, 0, "Preview audio must not start in sceneEdit mode")
        XCTAssertEqual(mock.teardownCallCount, 0, "No teardown because startPreviewAudioForTimelinePlayback is not entered")

        // Also verify markPreviewAudioDirty is no-op in sceneEdit even while playing
        runtime.simulateSetPlaying(true)
        runtime.markPreviewAudioDirty()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(mock.replacePipelineCallCount, 0, "markDirty in sceneEdit must not trigger rebuild")

        runtime.stopPlayback()
    }

    // MARK: - Test 10: double dirty while playing — only last pipeline plays

    func test_doubleDirtyWhilePlaying_onlyLastPipelinePlays() async throws {
        guard let (_, runtime) = await makePlayableRuntime() else {
            throw XCTSkip("Metal device not available")
        }
        let mock = MockPreviewAudioController()
        runtime.setPreviewAudioController(mock)
        let controllable = ControllablePipelineBuilder()
        runtime.previewAudioPipelineBuilder = controllable.builder

        // Start real playback
        runtime.startPlayback()
        await waitForPlaybackStart(runtime)
        XCTAssertTrue(runtime.isPlaying)

        // Allow rebuild task to reach builder
        for _ in 0..<10 {
            await Task.yield()
            if controllable.pendingCount >= 1 { break }
        }
        XCTAssertGreaterThanOrEqual(controllable.pendingCount, 1, "First build should be pending")

        // First markPreviewAudioDirty while first build is in-flight → cancels first, starts second
        let genAfterStart = runtime.previewAudioGeneration
        runtime.markPreviewAudioDirty()
        XCTAssertGreaterThan(runtime.previewAudioGeneration, genAfterStart, "Generation should bump on dirty")

        // Allow second rebuild task to reach builder
        for _ in 0..<10 { await Task.yield() }

        // Second markPreviewAudioDirty → cancels second, starts third
        let genAfterFirst = runtime.previewAudioGeneration
        runtime.markPreviewAudioDirty()
        XCTAssertGreaterThan(runtime.previewAudioGeneration, genAfterFirst, "Generation should bump again")

        // Allow third rebuild task to reach builder
        for _ in 0..<10 { await Task.yield() }

        // Now complete all pending builds (stale ones should be rejected by generation guard)
        mock.replacePipelineCallCount = 0
        mock.startPlaybackCallCount = 0
        let pipeline = makeDummyPipeline()

        // Complete stale builds — they should not apply because generation mismatches
        while controllable.pendingCount > 1 {
            controllable.completeNext(with: pipeline)
            for _ in 0..<5 { await Task.yield() }
        }
        XCTAssertEqual(mock.replacePipelineCallCount, 0, "Stale builds must not replace pipeline")

        // Complete the last (current) build
        controllable.completeNext(with: pipeline)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(mock.replacePipelineCallCount, 1, "Only the latest build should replace pipeline")

        runtime.stopPlayback()
        controllable.drainAll()
    }

    // MARK: - Test 11: stop during inflight rebuild does not start audio

    func test_stopDuringInflightRebuild_doesNotStartAudio() async throws {
        guard let (_, runtime) = await makePlayableRuntime() else {
            throw XCTSkip("Metal device not available")
        }
        let mock = MockPreviewAudioController()
        runtime.setPreviewAudioController(mock)
        let controllable = ControllablePipelineBuilder()
        runtime.previewAudioPipelineBuilder = controllable.builder

        // Start real playback → triggers pipeline build
        runtime.startPlayback()
        await waitForPlaybackStart(runtime)
        XCTAssertTrue(runtime.isPlaying)

        // Allow rebuild task to reach builder
        for _ in 0..<10 {
            await Task.yield()
            if controllable.pendingCount >= 1 { break }
        }
        XCTAssertGreaterThanOrEqual(controllable.pendingCount, 1, "Build should be pending")

        // Reset counters after start
        mock.replacePipelineCallCount = 0
        mock.startPlaybackCallCount = 0

        // Stop → cancels rebuild task, bumps generation, isPlaying=false
        runtime.stopPlayback()
        XCTAssertFalse(runtime.isPlaying)

        // Complete the pending build — guard should reject (gen mismatch + !isPlaying)
        controllable.completeNext(with: makeDummyPipeline())
        for _ in 0..<5 { await Task.yield() }

        XCTAssertEqual(mock.replacePipelineCallCount, 0, "Stale build after stop must not replace pipeline")
        XCTAssertEqual(mock.startPlaybackCallCount, 0, "Stale build after stop must not start playback")

        controllable.drainAll()
    }

    // MARK: - Test 12: no music content → dirty cleared, second play has no rebuild churn

    func test_noMusicContent_noRebuildChurnOnSecondPlay() async throws {
        guard let (_, runtime) = await makePlayableRuntime() else {
            throw XCTSkip("Metal device not available")
        }
        let mock = MockPreviewAudioController()
        runtime.setPreviewAudioController(mock)
        let controllable = ControllablePipelineBuilder()
        runtime.previewAudioPipelineBuilder = controllable.builder

        XCTAssertTrue(runtime.previewAudioDirty)

        // 1) First play → triggers build → builder returns nil (no music content)
        runtime.startPlayback()
        await waitForPlaybackStart(runtime)
        for _ in 0..<10 {
            await Task.yield()
            if controllable.pendingCount >= 1 { break }
        }
        XCTAssertGreaterThanOrEqual(controllable.pendingCount, 1, "First play must trigger build")
        controllable.completeNext(with: nil)
        for _ in 0..<10 { await Task.yield() }

        XCTAssertFalse(runtime.previewAudioDirty, "No music content: dirty must be cleared")
        XCTAssertEqual(mock.replacePipelineCallCount, 0)
        let buildCountAfterFirst = controllable.buildCallCount

        // 2) Stop + replay → no rebuild (clean + no pipeline = idle)
        runtime.stopPlayback()
        runtime.startPlayback()
        await waitForPlaybackStart(runtime)
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(controllable.buildCallCount, buildCountAfterFirst,
                       "Second play must NOT trigger rebuild when clean + no music")
        XCTAssertEqual(mock.replacePipelineCallCount, 0,
                       "No pipeline should be replaced on second play")
        XCTAssertEqual(mock.teardownCallCount, 1,
                       "Only the first play's dirty-path teardown should have occurred")

        runtime.stopPlayback()
        controllable.drainAll()
    }

    // MARK: - Test 13: startPlayback does not block on audio pipeline build

    func test_startPlayback_doesNotAwaitAudioPipelineBuild() async throws {
        guard let (_, runtime) = await makePlayableRuntime() else {
            throw XCTSkip("Metal device not available")
        }
        let mock = MockPreviewAudioController()
        runtime.setPreviewAudioController(mock)
        let controllable = ControllablePipelineBuilder()
        runtime.previewAudioPipelineBuilder = controllable.builder

        var playbackStarted = false
        runtime.onOutput = { output in
            if case .playbackStateChanged(let isPlaying) = output, isPlaying {
                playbackStarted = true
            }
        }

        runtime.startPlayback()
        await waitForPlaybackStart(runtime)

        // Playback should have started (isPlaying=true, output emitted)
        // BEFORE the audio pipeline builder completes
        XCTAssertTrue(runtime.isPlaying, "Video playback must start without waiting for audio pipeline")
        XCTAssertTrue(playbackStarted, "playbackStateChanged(isPlaying: true) must be emitted before audio build completes")
        XCTAssertEqual(mock.replacePipelineCallCount, 0, "Audio pipeline should not yet be replaced (builder still pending)")

        // Allow the rebuild task to reach the builder await
        for _ in 0..<10 {
            await Task.yield()
            if controllable.pendingCount >= 1 { break }
        }
        XCTAssertGreaterThanOrEqual(controllable.pendingCount, 1, "Builder should be suspended")

        // Now complete the builder → pipeline should be applied
        controllable.completeNext(with: makeDummyPipeline())
        for _ in 0..<5 { await Task.yield() }

        XCTAssertEqual(mock.replacePipelineCallCount, 1, "Pipeline should be applied after builder completes")
        XCTAssertGreaterThanOrEqual(mock.startPlaybackCallCount, 1, "Audio playback should start after pipeline is ready")

        runtime.stopPlayback()
        controllable.drainAll()
    }

    // MARK: - Test 14: stop cancels startPlayback-triggered audio build

    func test_stopCancelsStartPlaybackTriggeredAudioBuild() async throws {
        guard let (_, runtime) = await makePlayableRuntime() else {
            throw XCTSkip("Metal device not available")
        }
        let mock = MockPreviewAudioController()
        runtime.setPreviewAudioController(mock)
        let controllable = ControllablePipelineBuilder()
        runtime.previewAudioPipelineBuilder = controllable.builder

        // Start real playback → triggers async pipeline build
        runtime.startPlayback()
        await waitForPlaybackStart(runtime)
        XCTAssertTrue(runtime.isPlaying)

        // Allow rebuild task to reach builder
        for _ in 0..<10 {
            await Task.yield()
            if controllable.pendingCount >= 1 { break }
        }
        XCTAssertGreaterThanOrEqual(controllable.pendingCount, 1, "Builder should be pending")

        // Reset counters
        mock.replacePipelineCallCount = 0
        mock.startPlaybackCallCount = 0

        // Stop → cancels rebuild task and bumps generation
        runtime.stopPlayback()

        // Complete the pending build — it should be rejected
        controllable.completeNext(with: makeDummyPipeline())
        for _ in 0..<5 { await Task.yield() }

        XCTAssertEqual(mock.replacePipelineCallCount, 0, "Cancelled build must not replace pipeline")
        XCTAssertEqual(mock.startPlaybackCallCount, 0, "Cancelled build must not start audio playback")

        controllable.drainAll()
    }

    // MARK: - Test 15: cancelPreviewAudioBuild cancels both orchestration and detached build tasks

    func test_cancelPreviewAudioBuild_cancelsBothTasks() async throws {
        guard let (_, runtime) = await makePlayableRuntime() else {
            throw XCTSkip("Metal device not available")
        }
        let mock = MockPreviewAudioController()
        runtime.setPreviewAudioController(mock)
        let controllable = ControllablePipelineBuilder()
        runtime.previewAudioPipelineBuilder = controllable.builder

        // Start playback → triggers rebuild task
        runtime.startPlayback()
        await waitForPlaybackStart(runtime)

        // Allow rebuild task to reach builder
        for _ in 0..<10 {
            await Task.yield()
            if controllable.pendingCount >= 1 { break }
        }
        XCTAssertGreaterThanOrEqual(controllable.pendingCount, 1)

        // stopPlayback calls cancelPreviewAudioBuild which nils both task handles
        runtime.stopPlayback()
        XCTAssertFalse(runtime.hasActivePreviewAudioOrchestration,
                       "Both task handles must be nil'd after cancel")

        controllable.drainAll()
    }

    // MARK: - Test 16: production build path — gate-held build rejected on stop

    func test_productionBuildPath_detachedTaskOwnedAndCancelled() async throws {
        guard let (runtime, tempDir) = try await makePlayableRuntimeWithAudio() else {
            throw XCTSkip("Metal device not available")
        }
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mock = MockPreviewAudioController()
        runtime.setPreviewAudioController(mock)

        // Verify config has music (production path resolves the audio item)
        let config = await runtime.buildPreviewAudioConfig(includeOriginalFromVideoSlots: false)
        XCTAssertNotNil(config?.music, "Config must have music for production build path test")

        // Install build gate: suspends production buildPreviewAudioPipeline after plan
        // resolution but BEFORE the detached build task is launched.
        var gateContinuation: CheckedContinuation<Void, Never>?
        runtime.previewAudioBuildGate = {
            await withCheckedContinuation { cont in
                gateContinuation = cont
            }
        }

        // Start playback → rebuild → buildPreviewAudioPipeline → plan resolves → gate suspends
        runtime.startPlayback()
        await waitForPlaybackStart(runtime)
        XCTAssertTrue(runtime.isPlaying)

        for _ in 0..<20 {
            await Task.yield()
            if gateContinuation != nil { break }
        }
        XCTAssertNotNil(gateContinuation, "Production build must reach the build gate")
        XCTAssertFalse(runtime.hasActivePreviewAudioBuildTask,
                       "Detached build task should not exist yet (gate is before it)")

        // Stop → cancels rebuild task + bumps generation
        runtime.stopPlayback()
        XCTAssertFalse(runtime.isPlaying)

        // Release the gate — generation check after gate rejects, detached task not created
        gateContinuation?.resume()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(mock.replacePipelineCallCount, 0,
                       "Stale production build must not replace pipeline after stop")
        XCTAssertEqual(mock.startPlaybackCallCount, 0,
                       "Stale production build must not start audio playback after stop")
        XCTAssertFalse(runtime.hasActivePreviewAudioBuildTask,
                       "Build task handle must be clean after rejected build")
    }

    // MARK: - Test 17: production build normal completion clears build task handle

    func test_productionBuildNormalCompletion_clearsBuildTaskHandle() async throws {
        guard let (runtime, tempDir) = try await makePlayableRuntimeWithAudio() else {
            throw XCTSkip("Metal device not available")
        }
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mock = MockPreviewAudioController()
        runtime.setPreviewAudioController(mock)
        // NO injected builder — uses real production buildPreviewAudioPipeline()
        // The stub audio file will cause AudioCompositionBuilder to throw,
        // which is caught and returns nil. The important thing: handle is cleaned up.

        runtime.startPlayback()
        await waitForPlaybackStart(runtime)

        // Wait for the full production build cycle to complete:
        // rebuild task → plan resolution → detached build → AVFoundation error → defer cleanup
        for _ in 0..<50 {
            await Task.yield()
            if !runtime.hasActivePreviewAudioBuildTask { break }
        }

        // After build completes (error → nil), handle should be clean
        XCTAssertFalse(runtime.hasActivePreviewAudioBuildTask,
                       "Build task handle must be nil after production build completion")

        runtime.stopPlayback()
    }

    // MARK: - Test 18: stop during plan resolution prevents detached build

    func test_stopDuringPlanResolution_preventsDetachedBuild() async throws {
        guard let (runtime, tempDir) = try await makePlayableRuntimeWithAudio() else {
            throw XCTSkip("Metal device not available")
        }
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mock = MockPreviewAudioController()
        runtime.setPreviewAudioController(mock)
        // NO injected builder and NO gate — production path runs freely.
        // Generation check after plan resolution catches the stale wave.

        // Start playback to get into playing state
        runtime.startPlayback()
        await waitForPlaybackStart(runtime)
        XCTAssertTrue(runtime.isPlaying)

        // Stop immediately — bumps generation while plan resolution may be in-flight
        // (buildPreviewAudioConfig does async file resolution via mediaLocator).
        // The generation captured before first await no longer matches after plan resolves.
        runtime.stopPlayback()

        // Let any in-flight work complete
        for _ in 0..<20 { await Task.yield() }

        // Verify: no pipeline applied and no dangling build task
        XCTAssertEqual(mock.replacePipelineCallCount, 0,
                       "Stop during plan resolution must prevent pipeline apply")
        XCTAssertFalse(runtime.hasActivePreviewAudioBuildTask,
                       "No detached build should be created after generation mismatch")
    }
}
