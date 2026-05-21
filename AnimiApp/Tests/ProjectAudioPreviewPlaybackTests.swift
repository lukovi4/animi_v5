import XCTest
import Metal
import CoreMedia
@preconcurrency import AVFoundation
import TVECore
@testable import AnimiApp

// MARK: - Mock Controller

@MainActor
final class MockPreviewAudioController: PreviewAudioControlling {
    var replacePipelineCallCount = 0
    var startPlaybackCallCount = 0
    var pauseCallCount = 0
    var teardownCallCount = 0
    var prepareForImmediatePlaybackCallCount = 0
    var lastStartFromSeconds: Double?
    var lastStartHostTime: CFTimeInterval?
    var hasActivePipeline = false
    var readiness: PreviewAudioReadiness = .idle
    var onReady: (@MainActor () -> Void)?
    var onFailure: (@MainActor (PreviewAudioFailureReason) -> Void)?
    var onPrerollFinished: (@MainActor (PreviewAudioPrerollResult) -> Void)?
    var simulateImmediateReady = true

    func replacePipeline(_ pipeline: BuiltAudioPipeline) {
        replacePipelineCallCount += 1
        hasActivePipeline = true
        readiness = .preparing
        if simulateImmediateReady {
            readiness = .ready
            let cb = onReady
            onReady = nil
            cb?()
        }
    }
    func startPlayback(fromSeconds: Double, hostTime: CFTimeInterval) {
        startPlaybackCallCount += 1
        lastStartFromSeconds = fromSeconds
        lastStartHostTime = hostTime
    }
    func pause() { pauseCallCount += 1 }
    func teardown() {
        teardownCallCount += 1
        hasActivePipeline = false
        readiness = .idle
        onReady = nil
        onPrerollFinished = nil
        onFailure = nil
    }

    func prepareForImmediatePlayback() {
        prepareForImmediatePlaybackCallCount += 1
        if simulateImmediateReady {
            readiness = .primed
            let cb = onPrerollFinished
            onPrerollFinished = nil
            cb?(.primed)
        } else {
            readiness = .prerolling
        }
    }

    func simulateReady() {
        readiness = .ready
        let cb = onReady
        onReady = nil
        cb?()
    }

    func simulatePrimed() {
        readiness = .primed
        let cb = onPrerollFinished
        onPrerollFinished = nil
        cb?(.primed)
    }

    func simulatePrerollFailed() {
        readiness = .ready
        let cb = onPrerollFinished
        onPrerollFinished = nil
        cb?(.readyFallback)
    }

    func simulatePlayerNotReady() {
        let cb = onPrerollFinished
        onPrerollFinished = nil
        cb?(.deferredPlayerNotReady)
    }

    func simulateFailed() {
        readiness = .failed
        onReady = nil
        onFailure?(.itemFailed(error: "mock failure"))
    }
}

// MARK: - Mock Audio Session (for existing playback tests)

@MainActor
final class MockPreviewAudioSessionManager: AudioSessionManaging {
    var onEvent: ((AudioSessionEvent) -> Void)?
    func configureForPlayback() throws {}
    func activateForPlayback() throws {}
    func deactivateAfterPlayback() throws {}
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
        runtime.audioSessionManager = MockPreviewAudioSessionManager()
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
        runtime.audioSessionManager = MockPreviewAudioSessionManager()
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

    /// Creates a real audio pipeline with ~0.1s of PCM silence.
    /// Returns (pipeline, wavURL). Caller must clean up wavURL.
    private func makeRealSilentAudioPipeline() async throws -> (BuiltAudioPipeline, URL) {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw XCTSkip("Could not create audio track in composition")
        }

        let sampleRate: Double = 44100
        let numSamples = Int(sampleRate * 0.1)
        let bytesPerSample = 2
        let dataSize = numSamples * bytesPerSample

        var header = Data()
        header.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        let fileSz = UInt32(36 + dataSize)
        header.append(contentsOf: withUnsafeBytes(of: fileSz.littleEndian) { Array($0) })
        header.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        header.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // PCM
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // mono
        header.append(contentsOf: withUnsafeBytes(of: UInt32(44100).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(44100 * 2).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) }) // block align
        header.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) }) // bits/sample
        header.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        header.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })
        header.append(Data(count: dataSize))

        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PR2_silence_\(UUID().uuidString).wav")
        try header.write(to: wavURL)

        let asset = AVURLAsset(url: wavURL)
        let assetTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let sourceTrack = assetTracks.first else {
            try? FileManager.default.removeItem(at: wavURL)
            throw XCTSkip("WAV file has no audio track")
        }
        let duration = try await asset.load(.duration)
        try track.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: sourceTrack,
            at: .zero
        )

        return (BuiltAudioPipeline(composition: composition, audioMix: nil), wavURL)
    }

    /// Creates a real PreviewAudioPlaybackController in `.ready` state with a real audio composition.
    /// Returns (controller, wavURL). Caller must clean up wavURL and call controller.teardown().
    private func makeReadyProductionController() async throws -> (PreviewAudioPlaybackController, URL) {
        let (pipeline, wavURL) = try await makeRealSilentAudioPipeline()
        let controller = PreviewAudioPlaybackController()
        controller.replacePipeline(pipeline)

        await waitUntil(timeout: 2.0) { controller.readiness == .ready }
        guard controller.readiness == .ready else {
            try? FileManager.default.removeItem(at: wavURL)
            throw XCTSkip("Real audio composition did not become ready in time")
        }
        return (controller, wavURL)
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

    /// Polls a condition with real time delays to allow detached tasks to complete.
    private func waitUntil(timeout: TimeInterval, condition: @MainActor () -> Bool) async {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        while !condition() && CFAbsoluteTimeGetCurrent() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
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

        await runtime.simulateEnterExportMode()

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

    // MARK: - Test 9: sceneEdit mode → startPlayback is complete no-op

    func test_sceneEditMode_doesNotStartAnyPlayback() async throws {
        guard let (session, runtime) = await makePlayableRuntime() else {
            throw XCTSkip("Metal device not available")
        }

        // Transition session to sceneEdit via real store dispatch
        guard let sceneId = session.state?.sceneItems.first?.id else {
            XCTFail("Test timeline must contain a scene")
            return
        }
        session.dispatch(.enterSceneEdit(sceneId: sceneId))
        runtime.bootForTesting(state: .sceneEdit(instanceId: sceneId))

        // Verify precondition: session uiMode is .sceneEdit
        if case .sceneEdit = session.state?.uiMode {} else {
            XCTFail("session.state.uiMode must be .sceneEdit after dispatch")
            return
        }

        let mock = MockPreviewAudioController()
        runtime.setPreviewAudioController(mock)
        runtime.previewAudioPipelineBuilder = { nil }

        var emittedPlaybackStart = false
        runtime.onOutput = { output in
            if case .playbackStateChanged(let isPlaying) = output, isPlaying {
                emittedPlaybackStart = true
            }
        }

        runtime.startPlayback()
        for _ in 0..<5 { await Task.yield() }

        XCTAssertFalse(runtime.isPlaying,
                       "startPlayback must be no-op in sceneEdit — isPlaying must stay false")
        XCTAssertFalse(emittedPlaybackStart,
                       "No .playbackStateChanged(true) must be emitted in sceneEdit")
        XCTAssertEqual(mock.replacePipelineCallCount, 0,
                       "Preview audio pipeline must not build in sceneEdit")
        XCTAssertEqual(mock.startPlaybackCallCount, 0,
                       "Preview audio must not start in sceneEdit")
        XCTAssertEqual(mock.teardownCallCount, 0,
                       "No teardown because startPlayback is a no-op")
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

    // MARK: - Test 19: production controller uses direct scheduled start (no seek-completion chain)

    func test_productionController_directScheduledStart_noSeekChain() async throws {
        let controller = PreviewAudioPlaybackController()
        let pipeline = makeDummyPipeline()
        controller.replacePipeline(pipeline)

        // Empty AVComposition should become ready synchronously in post-observe check
        guard controller.readiness == .ready else {
            throw XCTSkip("Empty composition did not become ready synchronously")
        }

        var scheduleCallCount = 0
        var seekCallCount = 0

        controller.onSchedulePlayback = { rate, time, hostTime in
            scheduleCallCount += 1
            XCTAssertEqual(rate, 1.0)
        }
        controller.onSeek = { (_: CMTime, completion: @escaping (Bool) -> Void) in
            seekCallCount += 1
            completion(true)
        }

        // drift = 0.05 < 0.15 threshold → direct path
        controller.startPlayback(fromSeconds: 0.05, hostTime: CACurrentMediaTime())

        XCTAssertEqual(scheduleCallCount, 1,
                       "startPlayback must call schedulePlayback exactly once")
        XCTAssertEqual(seekCallCount, 0,
                       "startPlayback must NOT call seek — direct scheduled start only")

        controller.teardown()
    }

    // MARK: - Test 20: startPlayback on non-ready controller is safe no-op

    func test_startPlayback_onNonReadyController_isNoOp() async {
        let controller = PreviewAudioPlaybackController()
        let pipeline = makeDummyPipeline()

        var scheduleCallCount = 0
        controller.onSchedulePlayback = { _, _, _ in
            scheduleCallCount += 1
        }

        // replacePipeline may become ready synchronously for empty compositions.
        // If so, force back to .preparing to test the guard.
        controller.replacePipeline(pipeline)
        if controller.readiness == .ready {
            // Controller is already ready — the guard is still exercised by the
            // production assertion; verify the guard code exists by checking
            // that startPlayback on a fresh controller (no pipeline) is a no-op.
            let freshController = PreviewAudioPlaybackController()
            freshController.onSchedulePlayback = { _, _, _ in
                scheduleCallCount += 1
            }
            freshController.startPlayback(fromSeconds: 0.0, hostTime: CACurrentMediaTime())
            XCTAssertEqual(scheduleCallCount, 0,
                           "startPlayback with no player must not schedule")
        } else {
            // Controller is .preparing — test the readiness guard directly
            controller.startPlayback(fromSeconds: 0.0, hostTime: CACurrentMediaTime())
            XCTAssertEqual(scheduleCallCount, 0,
                           "startPlayback when readiness != .ready must not schedule")
        }
        controller.teardown()
    }

    // MARK: - Test 21: dirty rebuild defers start until preroll finishes

    func test_dirtyRebuild_defersStartUntilPrerollFinished() async throws {
        guard let (_, runtime) = await makePlayableRuntime() else {
            throw XCTSkip("Metal device not available")
        }
        let mock = MockPreviewAudioController()
        mock.simulateImmediateReady = false
        runtime.setPreviewAudioController(mock)
        let controllable = ControllablePipelineBuilder()
        runtime.previewAudioPipelineBuilder = controllable.builder

        runtime.startPlayback()
        await waitForPlaybackStart(runtime)
        XCTAssertTrue(runtime.isPlaying)

        // Allow rebuild task to reach builder
        for _ in 0..<10 {
            await Task.yield()
            if controllable.pendingCount >= 1 { break }
        }
        XCTAssertGreaterThanOrEqual(controllable.pendingCount, 1)

        // Complete the build → replacePipeline called but start deferred
        controllable.completeNext(with: makeDummyPipeline())
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(mock.replacePipelineCallCount, 1, "Pipeline should be replaced")
        XCTAssertEqual(mock.startPlaybackCallCount, 0,
                       "startPlayback must be deferred until preroll finishes")
        XCTAssertTrue(runtime.previewAudioDirty,
                      "dirty must remain true until preroll finishes")

        // Simulate readiness → onReady fires → prepareForImmediatePlayback (stays prerolling)
        mock.simulateReady()
        XCTAssertEqual(mock.prepareForImmediatePlaybackCallCount, 1)
        XCTAssertEqual(mock.startPlaybackCallCount, 0,
                       "startPlayback must still be deferred during preroll")

        // Simulate preroll complete → startPlayback called
        mock.simulatePrimed()

        XCTAssertEqual(mock.startPlaybackCallCount, 1,
                       "startPlayback must be called after preroll finishes")
        XCTAssertFalse(runtime.previewAudioDirty,
                       "dirty must be cleared on successful preroll")

        runtime.stopPlayback()
        controllable.drainAll()
    }

    // MARK: - Test 22: preroll finish uses fresh transport time

    func test_prerollFinish_usesFreshTransportTime() async throws {
        guard let (_, runtime) = await makePlayableRuntime() else {
            throw XCTSkip("Metal device not available")
        }
        let mock = MockPreviewAudioController()
        mock.simulateImmediateReady = false
        runtime.setPreviewAudioController(mock)
        let controllable = ControllablePipelineBuilder()
        runtime.previewAudioPipelineBuilder = controllable.builder

        runtime.startPlayback()
        await waitForPlaybackStart(runtime)

        for _ in 0..<10 {
            await Task.yield()
            if controllable.pendingCount >= 1 { break }
        }

        controllable.completeNext(with: makeDummyPipeline())
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(mock.startPlaybackCallCount, 0, "Start deferred")

        // Simulate ready → preroll starts
        mock.simulateReady()
        XCTAssertEqual(mock.startPlaybackCallCount, 0, "Start still deferred during preroll")

        // Inject fresh transport time before preroll finishes
        runtime.setPreviewAudioPlaybackTimeForTesting(
            projectTimeUs: 2_000_000, hostTime: CACurrentMediaTime()
        )

        mock.simulatePrimed()

        XCTAssertEqual(mock.startPlaybackCallCount, 1)
        XCTAssertNotNil(mock.lastStartFromSeconds)
        XCTAssertEqual(mock.lastStartFromSeconds!, 2.0, accuracy: 0.001,
                       "preroll finish must use fresh transport time, not stale captured values")

        runtime.stopPlayback()
        controllable.drainAll()
    }

    // MARK: - Test 23: stop before readiness prevents start

    func test_stopBeforeReadiness_preventsStart() async throws {
        guard let (_, runtime) = await makePlayableRuntime() else {
            throw XCTSkip("Metal device not available")
        }
        let mock = MockPreviewAudioController()
        mock.simulateImmediateReady = false
        runtime.setPreviewAudioController(mock)
        let controllable = ControllablePipelineBuilder()
        runtime.previewAudioPipelineBuilder = controllable.builder

        runtime.startPlayback()
        await waitForPlaybackStart(runtime)

        for _ in 0..<10 {
            await Task.yield()
            if controllable.pendingCount >= 1 { break }
        }

        controllable.completeNext(with: makeDummyPipeline())
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(mock.replacePipelineCallCount, 1)
        mock.startPlaybackCallCount = 0

        // Stop bumps generation
        runtime.stopPlayback()

        // Simulate readiness after stop → generation guard prevents start
        mock.simulateReady()

        XCTAssertEqual(mock.startPlaybackCallCount, 0,
                       "onReady after stop must not call startPlayback (generation guard)")

        controllable.drainAll()
    }

    // MARK: - Test 24: failed readiness leaves dirty=true for retry

    func test_failedReadiness_leavesDirtyForRetry() async throws {
        guard let (_, runtime) = await makePlayableRuntime() else {
            throw XCTSkip("Metal device not available")
        }
        let mock = MockPreviewAudioController()
        mock.simulateImmediateReady = false
        runtime.setPreviewAudioController(mock)
        let controllable = ControllablePipelineBuilder()
        runtime.previewAudioPipelineBuilder = controllable.builder

        runtime.startPlayback()
        await waitForPlaybackStart(runtime)

        for _ in 0..<10 {
            await Task.yield()
            if controllable.pendingCount >= 1 { break }
        }

        controllable.completeNext(with: makeDummyPipeline())
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(mock.replacePipelineCallCount, 1)

        // Simulate failure — onReady cleared, no startPlayback
        mock.simulateFailed()

        XCTAssertEqual(mock.startPlaybackCallCount, 0,
                       "Failed readiness must not start playback")
        XCTAssertTrue(runtime.previewAudioDirty,
                      "Failed readiness must leave dirty=true for retry")

        runtime.stopPlayback()
        controllable.drainAll()
    }

    // MARK: - Test 25: teardown clears onReady

    func test_teardown_clearsOnReady() async {
        let mock = MockPreviewAudioController()
        var callbackFired = false
        mock.onReady = { callbackFired = true }
        mock.readiness = .preparing

        mock.teardown()

        XCTAssertNil(mock.onReady, "teardown must clear onReady")
        XCTAssertEqual(mock.readiness, .idle, "teardown must reset readiness to .idle")
        XCTAssertFalse(callbackFired, "onReady must not fire during teardown")
    }

    // MARK: - Test 26: PR3 unresolved import clears dirty (no churn)

    func testPreviewNoChurn_unresolvedImportClearsDirty() async {
        guard let (session, runtime) = await makePlayableRuntime() else {
            return // Metal unavailable — skip
        }
        let mock = MockPreviewAudioController()
        runtime.setPreviewAudioController(mock)

        // Add music with an unresolvable asset (empty storage path, no file seeded)
        session.dispatch(.setProjectMusic(
            assetRef: .imported(assetId: ProjectAssetID(), storagePath: ""),
            sourceDurationUs: 5_000_000
        ))

        XCTAssertTrue(runtime.previewAudioDirty)

        // First play — unresolvable audio → .noResolvableAudio → clears dirty
        runtime.startPlayback()
        // Let orchestrationTask complete (includes detached build + main actor hop back)
        await waitUntil(timeout: 2.0) { !runtime.previewAudioDirty }

        XCTAssertFalse(runtime.previewAudioDirty,
                       "Unresolvable audio should clear dirty to prevent rebuild churn")
        XCTAssertEqual(mock.replacePipelineCallCount, 0,
                       "No pipeline should be installed for unresolvable audio")

        // Second play — should NOT trigger a rebuild since dirty is false
        runtime.stopPlayback()
        let buildCountBefore = mock.replacePipelineCallCount
        runtime.startPlayback()
        await waitUntil(timeout: 1.0) { runtime.hasActivePreviewAudioOrchestration == false }

        XCTAssertEqual(mock.replacePipelineCallCount, buildCountBefore,
                       "Second play should not trigger rebuild when dirty is false")

        runtime.stopPlayback()
    }

    // MARK: - Video Slot Audio Dirty Marking

    func test_videoSelectionChange_marksPreviewAudioDirty() async {
        let (_, runtime) = await makeBootedRuntime()
        let genBefore = runtime.previewAudioGeneration

        let selection = PersistedVideoSelection(trimStart: 0, trimEnd: 1.0, isMuted: false, volume: 1.0)
        try? runtime.sceneEdit.applyPersistedVideoSelection(blockId: "block-1", selection)

        XCTAssertGreaterThan(runtime.previewAudioGeneration, genBefore,
                            "applyPersistedVideoSelection should bump generation via markPreviewAudioDirty")
    }

    func test_videoSelectionToEngine_marksPreviewAudioDirty() async {
        let (_, runtime) = await makeBootedRuntime()
        let genBefore = runtime.previewAudioGeneration

        let selection = PersistedVideoSelection(trimStart: 0, trimEnd: 1.0, isMuted: false, volume: 1.0)
        runtime.sceneEdit.applyVideoSelectionToEngine(selection: selection, blockId: "block-1", instanceId: UUID())

        XCTAssertGreaterThan(runtime.previewAudioGeneration, genBefore,
                            "applyVideoSelectionToEngine should bump generation via markPreviewAudioDirty")
    }

    func test_mediaVisibilityChange_marksPreviewAudioDirty() async {
        let (_, runtime) = await makeBootedRuntime()
        let genBefore = runtime.previewAudioGeneration

        _ = runtime.sceneEdit.applyMediaVisibilityChange(instanceId: UUID(), blockId: "block-1", visible: false)

        XCTAssertGreaterThan(runtime.previewAudioGeneration, genBefore,
                            "applyMediaVisibilityChange should bump generation via markPreviewAudioDirty")
    }

    func test_mediaSlotChange_marksPreviewAudioDirty() async throws {
        let (session, runtime) = await makeBootedRuntime()

        // Get the real instance ID from bootstrapped session (has sceneInstanceStates entry)
        guard let editorState = session.state,
              let instanceId = editorState.canonicalTimeline.sceneItems.first?.id else {
            XCTFail("Bootstrapped session should have at least one scene item")
            return
        }

        // Ensure sceneInstanceStates has an entry for this instance
        // (bootstrap flow should have created one)
        guard editorState.draft.sceneInstanceStates[instanceId] != nil else {
            throw XCTSkip("Bootstrapped session has no sceneInstanceStates — cannot test async dirty path")
        }

        let genBefore = runtime.previewAudioGeneration

        // applyMediaSlotChange with nil slot (remove) — triggers engine update Task
        runtime.sceneEdit.applyMediaSlotChange(instanceId: instanceId, blockId: "block-1", slot: nil)

        // The dirty mark happens inside a Task — yield to let it execute
        for _ in 0..<20 { await Task.yield() }

        XCTAssertGreaterThan(runtime.previewAudioGeneration, genBefore,
                            "applyMediaSlotChange should bump generation via markPreviewAudioDirty")
    }

    // MARK: - teardownForExport

    func test_teardownForExport_invalidatesForRebuild() async throws {
        guard let (_, runtime) = await makePlayableRuntime() else {
            throw XCTSkip("Metal device not available")
        }
        let mock = MockPreviewAudioController()
        runtime.setPreviewAudioController(mock)

        let controllable = ControllablePipelineBuilder()
        runtime.previewAudioPipelineBuilder = controllable.builder

        // Build a pipeline so dirty becomes false
        runtime.startPlayback()
        await waitForPlaybackStart(runtime)
        for _ in 0..<10 {
            await Task.yield()
            if controllable.pendingCount >= 1 { break }
        }
        controllable.completeNext(with: makeDummyPipeline())
        for _ in 0..<5 { await Task.yield() }

        XCTAssertFalse(runtime.previewAudioDirty, "Should be clean after build")
        XCTAssertTrue(mock.hasActivePipeline, "Should have active pipeline")
        let teardownBefore = mock.teardownCallCount

        runtime.stopPlayback()

        // Act: teardownForExport
        runtime.previewAudio.teardownForExport()

        // Assert: dirty, torn down, no active pipeline
        XCTAssertTrue(runtime.previewAudioDirty, "teardownForExport should mark dirty")
        XCTAssertEqual(mock.teardownCallCount, teardownBefore + 1, "teardownForExport should call controller.teardown()")
        XCTAssertFalse(mock.hasActivePipeline, "Pipeline should be torn down")

        // Now resume playback — should rebuild
        let replaceBefore = mock.replacePipelineCallCount
        runtime.startPlayback()
        await waitForPlaybackStart(runtime)
        for _ in 0..<10 {
            await Task.yield()
            if controllable.pendingCount >= 1 { break }
        }
        XCTAssertGreaterThanOrEqual(controllable.pendingCount, 1, "Should trigger a new build")

        controllable.completeNext(with: makeDummyPipeline())
        for _ in 0..<5 { await Task.yield() }

        XCTAssertGreaterThan(mock.replacePipelineCallCount, replaceBefore,
                             "Should install new pipeline after rebuild")
        XCTAssertFalse(runtime.previewAudioDirty, "Should be clean after rebuild")

        runtime.stopPlayback()
        controllable.drainAll()
    }

    // MARK: - Drift Tests (Phase 1)

    func test_startPlaybackSeeksWhenDriftExceedsThreshold() async throws {
        let controller = PreviewAudioPlaybackController()
        let pipeline = makeDummyPipeline()
        controller.replacePipeline(pipeline)

        guard controller.readiness == .ready else {
            throw XCTSkip("Empty composition did not become ready synchronously")
        }

        var seekCallCount = 0
        var scheduleCallCount = 0

        controller.onSeek = { (_: CMTime, completion: @escaping (Bool) -> Void) in
            seekCallCount += 1
            completion(true)
        }
        controller.onSchedulePlayback = { _, _, _ in
            scheduleCallCount += 1
        }

        // drift = 5.0 > 0.15 threshold → seek path
        controller.startPlayback(fromSeconds: 5.0, hostTime: CACurrentMediaTime())
        XCTAssertEqual(seekCallCount, 1, "Should seek when drift exceeds threshold")

        // Yield for DispatchQueue.main.async in seek completion
        for _ in 0..<10 { await Task.yield() }
        let exp = expectation(description: "mainQ")
        DispatchQueue.main.async { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 1.0)

        XCTAssertEqual(scheduleCallCount, 1, "Should schedule playback after seek completes")

        controller.teardown()
    }

    func test_startPlaybackDirectScheduleWhenWithinThreshold() async throws {
        let controller = PreviewAudioPlaybackController()
        let pipeline = makeDummyPipeline()
        controller.replacePipeline(pipeline)

        guard controller.readiness == .ready else {
            throw XCTSkip("Empty composition did not become ready synchronously")
        }

        var seekCallCount = 0
        var scheduleCallCount = 0

        controller.onSeek = { (_: CMTime, completion: @escaping (Bool) -> Void) in
            seekCallCount += 1
            completion(true)
        }
        controller.onSchedulePlayback = { _, _, _ in
            scheduleCallCount += 1
        }

        // drift = 0.05 < 0.15 threshold → direct path
        controller.startPlayback(fromSeconds: 0.05, hostTime: CACurrentMediaTime())
        XCTAssertEqual(seekCallCount, 0, "Should NOT seek when within threshold")
        XCTAssertEqual(scheduleCallCount, 1, "Should schedule directly")

        controller.teardown()
    }

    func test_staleSeekDoesNotStartPlayback() async throws {
        let controller = PreviewAudioPlaybackController()
        let pipeline = makeDummyPipeline()
        controller.replacePipeline(pipeline)

        guard controller.readiness == .ready else {
            throw XCTSkip("Empty composition did not become ready synchronously")
        }

        var seekCallCount = 0
        var scheduleCallCount = 0
        var capturedCompletion: ((Bool) -> Void)?

        controller.onSeek = { (_: CMTime, completion: @escaping (Bool) -> Void) in
            seekCallCount += 1
            capturedCompletion = completion
        }
        controller.onSchedulePlayback = { _, _, _ in
            scheduleCallCount += 1
        }

        controller.startPlayback(fromSeconds: 5.0, hostTime: CACurrentMediaTime())
        XCTAssertEqual(seekCallCount, 1)
        XCTAssertEqual(scheduleCallCount, 0, "Should not schedule before seek completes")

        // Invalidate by tearing down
        controller.teardown()

        // Now call captured completion — should be stale
        capturedCompletion?(true)
        let exp = expectation(description: "mainQ")
        DispatchQueue.main.async { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 1.0)

        XCTAssertEqual(scheduleCallCount, 0, "Stale seek must not schedule playback")
    }

    func test_seekFinishedFalseDoesNotStartPlayback() async throws {
        let controller = PreviewAudioPlaybackController()
        let pipeline = makeDummyPipeline()
        controller.replacePipeline(pipeline)

        guard controller.readiness == .ready else {
            throw XCTSkip("Empty composition did not become ready synchronously")
        }

        var seekCallCount = 0
        var scheduleCallCount = 0

        controller.onSeek = { (_: CMTime, completion: @escaping (Bool) -> Void) in
            seekCallCount += 1
            completion(false) // seek cancelled
        }
        controller.onSchedulePlayback = { _, _, _ in
            scheduleCallCount += 1
        }

        controller.startPlayback(fromSeconds: 5.0, hostTime: CACurrentMediaTime())

        let exp = expectation(description: "mainQ")
        DispatchQueue.main.async { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 1.0)

        XCTAssertEqual(seekCallCount, 1)
        XCTAssertEqual(scheduleCallCount, 0, "Cancelled seek must not schedule playback")

        controller.teardown()
    }

    // MARK: - Prebuild Tests (Phase 2)

    func test_prepareBuildsWithoutStarting() async throws {
        guard let (_, runtime) = await makePlayableRuntime() else {
            throw XCTSkip("Metal device not available")
        }
        let mock = MockPreviewAudioController()
        mock.simulateImmediateReady = true
        runtime.setPreviewAudioController(mock)
        let controllable = ControllablePipelineBuilder()
        runtime.previewAudioPipelineBuilder = controllable.builder

        // Prepare while idle (not playing)
        runtime.previewAudio.prepareForTimelinePreview()

        for _ in 0..<10 {
            await Task.yield()
            if controllable.pendingCount >= 1 { break }
        }
        XCTAssertGreaterThanOrEqual(controllable.pendingCount, 1, "Should start build")

        controllable.completeNext(with: makeDummyPipeline())
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(mock.replacePipelineCallCount, 1, "Should install pipeline")
        XCTAssertEqual(mock.startPlaybackCallCount, 0, "Should NOT start playback (idle prepare)")
        XCTAssertFalse(runtime.previewAudioDirty, "Should be clean after prepare")

        controllable.drainAll()
    }

    func test_playJoinsInFlightPrepare() async throws {
        guard let (_, runtime) = await makePlayableRuntime() else {
            throw XCTSkip("Metal device not available")
        }
        let mock = MockPreviewAudioController()
        mock.simulateImmediateReady = false
        runtime.setPreviewAudioController(mock)
        let controllable = ControllablePipelineBuilder()
        runtime.previewAudioPipelineBuilder = controllable.builder

        // Start idle prepare
        runtime.previewAudio.prepareForTimelinePreview()

        for _ in 0..<10 {
            await Task.yield()
            if controllable.pendingCount >= 1 { break }
        }
        XCTAssertGreaterThanOrEqual(controllable.pendingCount, 1, "Prepare should start build")
        let buildCountAfterPrepare = controllable.buildCallCount

        // Now start playback — should join, not start second build
        runtime.startPlayback()
        await waitForPlaybackStart(runtime)
        for _ in 0..<5 { await Task.yield() }

        XCTAssertEqual(controllable.buildCallCount, buildCountAfterPrepare,
                       "Play should join in-flight prepare, not start a new build")

        // Complete the build
        controllable.completeNext(with: makeDummyPipeline())
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(mock.replacePipelineCallCount, 1, "Should install pipeline once")

        // Simulate ready → triggers prepareForImmediatePlayback (stays prerolling)
        mock.simulateReady()
        XCTAssertEqual(mock.startPlaybackCallCount, 0, "Start deferred during preroll")

        // Simulate preroll complete → starts playback
        mock.simulatePrimed()

        XCTAssertEqual(mock.startPlaybackCallCount, 1, "Should start playback after preroll completes")

        runtime.stopPlayback()
        controllable.drainAll()
    }

    func test_teardownForExportDoesNotStartPrepare() async throws {
        guard let (_, runtime) = await makePlayableRuntime() else {
            throw XCTSkip("Metal device not available")
        }
        let mock = MockPreviewAudioController()
        runtime.setPreviewAudioController(mock)

        runtime.previewAudio.teardownForExport()
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(mock.replacePipelineCallCount, 0, "No pipeline after export teardown")
        XCTAssertTrue(runtime.previewAudioDirty, "Should be dirty")
        XCTAssertNil(runtime.previewAudio.orchestrationTask, "No active build")
    }

    func test_postExportPrepare_thenPlay_immediateAudio() async throws {
        guard let (_, runtime) = await makePlayableRuntime() else {
            throw XCTSkip("Metal device not available")
        }
        let mock = MockPreviewAudioController()
        mock.simulateImmediateReady = true
        runtime.setPreviewAudioController(mock)
        let controllable = ControllablePipelineBuilder()
        runtime.previewAudioPipelineBuilder = controllable.builder

        // Build pipeline via playback
        runtime.startPlayback()
        await waitForPlaybackStart(runtime)
        for _ in 0..<10 {
            await Task.yield()
            if controllable.pendingCount >= 1 { break }
        }
        controllable.completeNext(with: makeDummyPipeline())
        for _ in 0..<10 { await Task.yield() }
        runtime.stopPlayback()

        XCTAssertFalse(runtime.previewAudioDirty)

        // Export teardown
        runtime.previewAudio.teardownForExport()
        XCTAssertTrue(runtime.previewAudioDirty)

        // Simulate post-export restore → prepare fires
        runtime.previewAudio.prepareForTimelinePreview()
        for _ in 0..<10 {
            await Task.yield()
            if controllable.pendingCount >= 1 { break }
        }
        controllable.completeNext(with: makeDummyPipeline())
        for _ in 0..<10 { await Task.yield() }

        XCTAssertFalse(runtime.previewAudioDirty, "Prepare should clear dirty")
        let startCountBefore = mock.startPlaybackCallCount

        // Now play — should use prepared pipeline immediately
        runtime.startPlayback()
        await waitForPlaybackStart(runtime)
        for _ in 0..<5 { await Task.yield() }

        XCTAssertEqual(mock.startPlaybackCallCount, startCountBefore + 1,
                       "Should start playback immediately from prepared pipeline")

        runtime.stopPlayback()
        controllable.drainAll()
    }

    // MARK: - Generation Ownership Tests

    func test_dirtyWithOldReadyPipeline_doesNotStartStaleAudio() async throws {
        guard let (_, runtime) = await makePlayableRuntime() else {
            throw XCTSkip("Metal device not available")
        }
        let mock = MockPreviewAudioController()
        mock.simulateImmediateReady = true
        runtime.setPreviewAudioController(mock)
        let controllable = ControllablePipelineBuilder()
        runtime.previewAudioPipelineBuilder = controllable.builder

        // Build pipeline via idle prepare
        runtime.previewAudio.prepareForTimelinePreview()
        for _ in 0..<10 {
            await Task.yield()
            if controllable.pendingCount >= 1 { break }
        }
        controllable.completeNext(with: makeDummyPipeline())
        for _ in 0..<10 { await Task.yield() }

        XCTAssertFalse(runtime.previewAudioDirty, "Prepare should clear dirty")
        XCTAssertEqual(mock.replacePipelineCallCount, 1, "Pipeline installed")
        XCTAssertEqual(mock.startPlaybackCallCount, 0, "No playback from idle prepare")

        // markDirty bumps generation — pipeline is now stale
        runtime.previewAudio.markDirty()
        XCTAssertTrue(runtime.previewAudioDirty)
        let genAfterDirty = runtime.previewAudioGeneration

        // Start playback — must NOT reuse the old ready pipeline
        mock.startPlaybackCallCount = 0
        runtime.startPlayback()
        await waitForPlaybackStart(runtime)
        for _ in 0..<10 {
            await Task.yield()
            if controllable.pendingCount >= 1 { break }
        }

        // Should have started a new build, not reused old pipeline
        XCTAssertGreaterThanOrEqual(controllable.buildCallCount, 2,
                                    "Must rebuild, not reuse stale pipeline")
        XCTAssertEqual(mock.startPlaybackCallCount, 0,
                       "Must NOT start stale pipeline audio")

        // Complete new build
        controllable.completeNext(with: makeDummyPipeline())
        for _ in 0..<10 { await Task.yield() }

        // Now it should play with fresh pipeline
        XCTAssertEqual(mock.startPlaybackCallCount, 1,
                       "Should start playback with fresh pipeline")
        XCTAssertFalse(runtime.previewAudioDirty)

        runtime.stopPlayback()
        controllable.drainAll()
    }

    func test_dirtyWithOldPreparingPipeline_doesNotStartStaleAudio() async throws {
        guard let (_, runtime) = await makePlayableRuntime() else {
            throw XCTSkip("Metal device not available")
        }
        let mock = MockPreviewAudioController()
        mock.simulateImmediateReady = false
        runtime.setPreviewAudioController(mock)
        let controllable = ControllablePipelineBuilder()
        runtime.previewAudioPipelineBuilder = controllable.builder

        // Build pipeline via idle prepare, but don't simulate ready
        runtime.previewAudio.prepareForTimelinePreview()
        for _ in 0..<10 {
            await Task.yield()
            if controllable.pendingCount >= 1 { break }
        }
        controllable.completeNext(with: makeDummyPipeline())
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(mock.replacePipelineCallCount, 1, "Pipeline installed")
        XCTAssertEqual(mock.readiness, .preparing, "Pipeline not yet ready")

        // markDirty bumps generation — pipeline is now stale
        runtime.previewAudio.markDirty()
        XCTAssertTrue(runtime.previewAudioDirty)

        // Start playback — must NOT await the old preparing pipeline
        runtime.startPlayback()
        await waitForPlaybackStart(runtime)
        for _ in 0..<10 {
            await Task.yield()
            if controllable.pendingCount >= 1 { break }
        }

        // Should have started a new build
        XCTAssertGreaterThanOrEqual(controllable.buildCallCount, 2,
                                    "Must rebuild, not wait on stale preparing pipeline")

        // Old pipeline becomes ready after new build starts — must NOT trigger stale playback
        mock.startPlaybackCallCount = 0
        mock.simulateReady()
        XCTAssertEqual(mock.startPlaybackCallCount, 0,
                       "Old pipeline ready must NOT start playback (generation mismatch)")

        runtime.stopPlayback()
        controllable.drainAll()
    }

    // MARK: - Overlapping Seek Test

    func test_overlappingSeek_onlyLastStartSchedules() async throws {
        let controller = PreviewAudioPlaybackController()
        let pipeline = makeDummyPipeline()
        controller.replacePipeline(pipeline)

        guard controller.readiness == .ready else {
            throw XCTSkip("Empty composition did not become ready synchronously")
        }

        var scheduleCallCount = 0
        var capturedCompletions: [(Bool) -> Void] = []

        controller.onSeek = { (_: CMTime, completion: @escaping (Bool) -> Void) in
            capturedCompletions.append(completion)
        }
        controller.onSchedulePlayback = { _, _, _ in
            scheduleCallCount += 1
        }

        // First start — triggers seek (drift > threshold)
        controller.startPlayback(fromSeconds: 5.0, hostTime: CACurrentMediaTime())
        XCTAssertEqual(capturedCompletions.count, 1)

        // Second start — triggers another seek, supersedes first
        controller.startPlayback(fromSeconds: 10.0, hostTime: CACurrentMediaTime())
        XCTAssertEqual(capturedCompletions.count, 2)

        // Complete first seek — should be stale (startToken advanced)
        capturedCompletions[0](true)
        let exp1 = expectation(description: "mainQ1")
        DispatchQueue.main.async { exp1.fulfill() }
        await fulfillment(of: [exp1], timeout: 1.0)
        XCTAssertEqual(scheduleCallCount, 0,
                       "First seek completion must NOT schedule (superseded by second start)")

        // Complete second seek — should schedule
        capturedCompletions[1](true)
        let exp2 = expectation(description: "mainQ2")
        DispatchQueue.main.async { exp2.fulfill() }
        await fulfillment(of: [exp2], timeout: 1.0)
        XCTAssertEqual(scheduleCallCount, 1,
                       "Only the last seek should schedule playback")

        controller.teardown()
    }

    func test_pauseDuringPendingSeekDoesNotRestartPlayback() async throws {
        let controller = PreviewAudioPlaybackController()
        let pipeline = makeDummyPipeline()
        controller.replacePipeline(pipeline)

        guard controller.readiness == .ready else {
            throw XCTSkip("Empty composition did not become ready synchronously")
        }

        var scheduleCallCount = 0
        var cancelSeeksCallCount = 0
        var capturedCompletion: ((Bool) -> Void)?

        controller.onSeek = { (_: CMTime, completion: @escaping (Bool) -> Void) in
            capturedCompletion = completion
        }
        controller.onSchedulePlayback = { _, _, _ in
            scheduleCallCount += 1
        }
        controller.onCancelPendingSeeks = {
            cancelSeeksCallCount += 1
        }

        // Start playback — triggers seek (drift > threshold)
        // cancelPendingSeeks called once at start of startPlayback
        let cancelBefore = cancelSeeksCallCount
        controller.startPlayback(fromSeconds: 5.0, hostTime: CACurrentMediaTime())
        XCTAssertNotNil(capturedCompletion, "Seek should have been initiated")
        XCTAssertEqual(cancelSeeksCallCount, cancelBefore + 1,
                       "startPlayback should cancel pending seeks before new seek")

        // Pause — cancels pending seeks and invalidates token
        controller.pause()
        XCTAssertEqual(cancelSeeksCallCount, cancelBefore + 2,
                       "pause must cancel pending seeks")

        // Seek completes after pause — stale token, must not schedule
        capturedCompletion?(true)
        let exp = expectation(description: "mainQ")
        DispatchQueue.main.async { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 1.0)

        XCTAssertEqual(scheduleCallCount, 0,
                       "Seek completion after pause must NOT schedule playback")

        controller.teardown()
    }

    func test_stopPlaybackDuringPendingSeekDoesNotRestartPreviewAudio() async throws {
        guard let (_, runtime) = await makePlayableRuntime() else {
            throw XCTSkip("Metal device not available")
        }
        let mock = MockPreviewAudioController()
        mock.simulateImmediateReady = true
        runtime.setPreviewAudioController(mock)
        let controllable = ControllablePipelineBuilder()
        runtime.previewAudioPipelineBuilder = controllable.builder

        // Build pipeline
        runtime.startPlayback()
        await waitForPlaybackStart(runtime)
        for _ in 0..<10 {
            await Task.yield()
            if controllable.pendingCount >= 1 { break }
        }
        controllable.completeNext(with: makeDummyPipeline())
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(runtime.previewAudioDirty)

        // Stop → start again (pipeline not dirty, resume path)
        runtime.stopPlayback()
        let startCountBefore = mock.startPlaybackCallCount

        runtime.startPlayback()
        await waitForPlaybackStart(runtime)
        for _ in 0..<5 { await Task.yield() }

        // Resume calls startPlayback on mock (via coordinator resume path)
        XCTAssertEqual(mock.startPlaybackCallCount, startCountBefore + 1,
                       "Resume should call startPlayback")

        // Now stop — this must invalidate any pending seek
        runtime.stopPlayback()
        let countAfterStop = mock.startPlaybackCallCount

        // Pause was called which increments playbackStartToken —
        // any pending seek from the previous startPlayback is now stale
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(mock.startPlaybackCallCount, countAfterStop,
                       "No additional startPlayback after stop")

        controllable.drainAll()
    }

    func test_teardownForExport_doesNotTriggerImmediateRebuild() async throws {
        guard let (_, runtime) = await makePlayableRuntime() else {
            throw XCTSkip("Metal device not available")
        }
        let mock = MockPreviewAudioController()
        runtime.setPreviewAudioController(mock)

        let controllable = ControllablePipelineBuilder()
        runtime.previewAudioPipelineBuilder = controllable.builder

        // Set up playing state
        runtime.startPlayback()
        await waitForPlaybackStart(runtime)
        for _ in 0..<10 {
            await Task.yield()
            if controllable.pendingCount >= 1 { break }
        }
        controllable.completeNext(with: makeDummyPipeline())
        for _ in 0..<5 { await Task.yield() }

        // Stop playback but keep isPlaying check possible
        runtime.stopPlayback()

        // Simulate export scenario: runtime is stopped, call teardownForExport
        runtime.previewAudio.teardownForExport()

        // Assert: no orchestration task spawned
        XCTAssertNil(runtime.previewAudio.orchestrationTask,
                     "teardownForExport should NOT spawn an orchestration task")
        XCTAssertTrue(runtime.previewAudioDirty,
                      "Dirty flag should be set for later rebuild")

        controllable.drainAll()
    }

    // MARK: - PR-2: Failure Ownership Tests

    // T1: itemFailedAfterReady fires onFailure and dirties coordinator
    func test_itemFailedAfterReady_firesOnFailure() async throws {
        guard let (_, runtime) = await makePlayableRuntime() else {
            throw XCTSkip("Metal device not available")
        }
        let mock = MockPreviewAudioController()
        mock.simulateImmediateReady = true
        runtime.setPreviewAudioController(mock)
        let controllable = ControllablePipelineBuilder()
        runtime.previewAudioPipelineBuilder = controllable.builder

        // Build pipeline → ready → dirty=false
        runtime.startPlayback()
        await waitForPlaybackStart(runtime)
        for _ in 0..<10 {
            await Task.yield()
            if controllable.pendingCount >= 1 { break }
        }
        controllable.completeNext(with: makeDummyPipeline())
        for _ in 0..<10 { await Task.yield() }

        XCTAssertFalse(runtime.previewAudioDirty, "Should be clean after build")

        // Simulate failure after ready
        mock.simulateFailed()

        XCTAssertTrue(runtime.previewAudioDirty, "Failure should mark dirty")
        XCTAssertNil(runtime.previewAudio.installedPipelineGenerationForTesting,
                     "Failure should clear installedPipelineGeneration")

        runtime.stopPlayback()
        controllable.drainAll()
    }

    // T2: startOnFailedItem is no-op — coordinator does not resume a failed controller
    func test_startOnFailedItem_isNoOp() async throws {
        guard let (_, runtime) = await makePlayableRuntime() else {
            throw XCTSkip("Metal device not available")
        }
        let mock = MockPreviewAudioController()
        mock.simulateImmediateReady = true
        runtime.setPreviewAudioController(mock)
        let controllable = ControllablePipelineBuilder()
        runtime.previewAudioPipelineBuilder = controllable.builder

        // Build pipeline → ready
        runtime.startPlayback()
        await waitForPlaybackStart(runtime)
        for _ in 0..<10 {
            await Task.yield()
            if controllable.pendingCount >= 1 { break }
        }
        controllable.completeNext(with: makeDummyPipeline())
        for _ in 0..<10 { await Task.yield() }

        XCTAssertFalse(runtime.previewAudioDirty)

        // Simulate failure while playing → coordinator marks dirty
        mock.simulateFailed()
        XCTAssertTrue(runtime.previewAudioDirty, "Failure should mark dirty")

        runtime.stopPlayback()
        mock.startPlaybackCallCount = 0

        // Try to start playback again — dirty=true → rebuild, not resume
        runtime.startPlayback()
        await waitForPlaybackStart(runtime)
        for _ in 0..<5 { await Task.yield() }

        XCTAssertEqual(mock.startPlaybackCallCount, 0,
                       "Should not call startPlayback on a failed controller (rebuild path instead)")

        runtime.stopPlayback()
        controllable.drainAll()
    }

    // T3: failedPreparedPipeline not reused
    func test_failedPreparedPipelineNotReused() async throws {
        guard let (_, runtime) = await makePlayableRuntime() else {
            throw XCTSkip("Metal device not available")
        }
        let mock = MockPreviewAudioController()
        mock.simulateImmediateReady = true
        runtime.setPreviewAudioController(mock)
        let controllable = ControllablePipelineBuilder()
        runtime.previewAudioPipelineBuilder = controllable.builder

        // Build pipeline → ready
        runtime.startPlayback()
        await waitForPlaybackStart(runtime)
        for _ in 0..<10 {
            await Task.yield()
            if controllable.pendingCount >= 1 { break }
        }
        controllable.completeNext(with: makeDummyPipeline())
        for _ in 0..<10 { await Task.yield() }

        XCTAssertFalse(runtime.previewAudioDirty)

        // Simulate failure while still playing → dirty, installedPipelineGeneration cleared
        mock.simulateFailed()
        XCTAssertTrue(runtime.previewAudioDirty)

        runtime.stopPlayback()

        let replaceBefore = mock.replacePipelineCallCount

        // Start playback again → dirty=true → should go through rebuild path
        runtime.startPlayback()
        await waitForPlaybackStart(runtime)
        for _ in 0..<10 {
            await Task.yield()
            if controllable.pendingCount >= 1 { break }
        }
        XCTAssertGreaterThanOrEqual(controllable.pendingCount, 1,
                                     "Should start a new build, not reuse failed pipeline")

        // Complete rebuild
        controllable.completeNext(with: makeDummyPipeline())
        for _ in 0..<10 { await Task.yield() }

        XCTAssertGreaterThan(mock.replacePipelineCallCount, replaceBefore,
                             "New pipeline should be installed after rebuild")

        runtime.stopPlayback()
        controllable.drainAll()
    }

    // T4: stale failure callback does not dirty new generation
    func test_staleFailureCallbackDoesNotDirtyNewGeneration() async throws {
        guard let (_, runtime) = await makePlayableRuntime() else {
            throw XCTSkip("Metal device not available")
        }
        let mock = MockPreviewAudioController()
        mock.simulateImmediateReady = true
        runtime.setPreviewAudioController(mock)
        let controllable = ControllablePipelineBuilder()
        runtime.previewAudioPipelineBuilder = controllable.builder

        // Build gen0 → ready
        runtime.startPlayback()
        await waitForPlaybackStart(runtime)
        for _ in 0..<10 {
            await Task.yield()
            if controllable.pendingCount >= 1 { break }
        }
        controllable.completeNext(with: makeDummyPipeline())
        for _ in 0..<10 { await Task.yield() }

        XCTAssertFalse(runtime.previewAudioDirty)

        // Capture the old onFailure closure
        let oldOnFailure = mock.onFailure

        // Trigger new build (markDirty → gen1)
        runtime.markPreviewAudioDirty()
        for _ in 0..<10 {
            await Task.yield()
            if controllable.pendingCount >= 1 { break }
        }
        controllable.completeNext(with: makeDummyPipeline())
        for _ in 0..<10 { await Task.yield() }

        XCTAssertFalse(runtime.previewAudioDirty, "Gen1 build should clear dirty")

        // Fire the stale gen0 onFailure
        oldOnFailure?(.itemFailed(error: "stale"))

        XCTAssertFalse(runtime.previewAudioDirty,
                       "Stale generation failure must not dirty the new generation")

        // Verify current pipeline is still usable
        mock.startPlaybackCallCount = 0
        runtime.stopPlayback()
        runtime.startPlayback()
        await waitForPlaybackStart(runtime)
        for _ in 0..<5 { await Task.yield() }

        XCTAssertGreaterThanOrEqual(mock.startPlaybackCallCount, 1,
                                     "Current pipeline should still be usable (resume path)")

        runtime.stopPlayback()
        controllable.drainAll()
    }

    // T5: mock simulateFailed invokes onFailure
    func test_mockSimulateFailed_invokesOnFailure() async {
        let mock = MockPreviewAudioController()
        var receivedReason: PreviewAudioFailureReason?
        mock.onFailure = { reason in
            receivedReason = reason
        }
        mock.readiness = .ready

        mock.simulateFailed()

        XCTAssertEqual(receivedReason, .itemFailed(error: "mock failure"),
                       "simulateFailed must fire onFailure with correct reason")
        XCTAssertEqual(mock.readiness, .failed)
    }

    // T6: teardown clears onFailure
    func test_teardownClearsOnFailure() async {
        let mock = MockPreviewAudioController()
        mock.onFailure = { _ in }

        mock.teardown()

        XCTAssertNil(mock.onFailure, "teardown must clear onFailure")
    }

    // T7: status observation survives ready (production controller)
    func test_statusObservationSurvivesReady() async throws {
        let (controller, wavURL) = try await makeReadyProductionController()
        defer {
            controller.teardown()
            try? FileManager.default.removeItem(at: wavURL)
        }

        XCTAssertTrue(controller.hasActiveStatusObservation,
                      "KVO observation must survive .readyToPlay — needed to catch post-ready failures")
    }

    // MARK: - PR-2 Fixes: Post-Seek Item Guard Tests

    // T1: production invalid item start is no-op
    func test_productionInvalidItemStart_isNoOp() async throws {
        let (controller, wavURL) = try await makeReadyProductionController()
        defer {
            controller.teardown()
            try? FileManager.default.removeItem(at: wavURL)
        }

        // Invalidate item while readiness is still .ready
        controller.invalidateCurrentItemForTesting()

        var seekCallCount = 0
        var scheduleCallCount = 0
        var failureReason: PreviewAudioFailureReason?

        controller.onSeek = { _, completion in
            seekCallCount += 1
            completion(true)
        }
        controller.onSchedulePlayback = { _, _, _ in
            scheduleCallCount += 1
        }
        controller.onFailure = { reason in
            failureReason = reason
        }

        controller.startPlayback(fromSeconds: 0.0, hostTime: CACurrentMediaTime())

        XCTAssertEqual(seekCallCount, 0, "Must not seek on invalid item")
        XCTAssertEqual(scheduleCallCount, 0, "Must not schedule on invalid item")
        XCTAssertEqual(failureReason, .startOnFailedItem, "Must fire onFailure with .startOnFailedItem")
        XCTAssertEqual(controller.readiness, .failed, "Must transition to .failed")
        XCTAssertFalse(controller.hasActiveStatusObservation,
                       "Status observation must be nil after terminal failure")
        XCTAssertNil(controller.onReady, "onReady must be nil after terminal failure")
    }

    // T2: item invalidation during pending seek does not schedule
    func test_itemFailureDuringPendingSeek_doesNotSchedule() async throws {
        let (controller, wavURL) = try await makeReadyProductionController()
        defer {
            controller.teardown()
            try? FileManager.default.removeItem(at: wavURL)
        }

        var seekCallCount = 0
        var scheduleCallCount = 0
        var capturedSeekCompletion: ((Bool) -> Void)?
        var failureReason: PreviewAudioFailureReason?

        controller.onSeek = { _, completion in
            seekCallCount += 1
            capturedSeekCompletion = completion
        }
        controller.onSchedulePlayback = { _, _, _ in
            scheduleCallCount += 1
        }
        controller.onFailure = { reason in
            failureReason = reason
        }

        // Trigger seek path (drift > threshold)
        controller.startPlayback(fromSeconds: 5.0, hostTime: CACurrentMediaTime())
        XCTAssertEqual(seekCallCount, 1, "Should initiate seek")
        XCTAssertEqual(scheduleCallCount, 0, "Should not schedule before seek completes")

        // Invalidate item during pending seek
        controller.invalidateCurrentItemForTesting()

        // Complete the seek — post-seek guard should catch the invalid item
        capturedSeekCompletion?(true)

        // Flush main queue (seek completion dispatches to main)
        let exp = expectation(description: "mainQ")
        DispatchQueue.main.async { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 1.0)

        XCTAssertEqual(scheduleCallCount, 0, "Must not schedule after item invalidated during seek")
        XCTAssertEqual(failureReason, .startOnFailedItem,
                       "Must fire onFailure when item invalid at post-seek")
        XCTAssertEqual(controller.readiness, .failed, "Must be in failed state")
    }

    // T3: terminal failure cleanup is consistent across all paths
    func test_terminalFailureCleanup_isConsistent() async throws {
        let (controller, wavURL) = try await makeReadyProductionController()
        defer {
            controller.teardown()
            try? FileManager.default.removeItem(at: wavURL)
        }

        // Set callback to verify it gets cleaned
        var readyFired = false
        controller.onReady = { readyFired = true }

        // Invalidate item then trigger failure via startPlayback guard
        controller.invalidateCurrentItemForTesting()
        controller.startPlayback(fromSeconds: 0.0, hostTime: CACurrentMediaTime())

        XCTAssertNil(controller.onReady,
                     "onReady must be nil after terminal failure")
        XCTAssertFalse(controller.hasActiveStatusObservation,
                       "statusObservation must be nil after terminal failure")
        XCTAssertEqual(controller.readiness, .failed,
                       "readiness must be .failed after terminal failure")
        XCTAssertFalse(readyFired,
                       "onReady must not fire during failure transition")
    }

    // MARK: - Preroll Tests

    // T1: prepareForImmediatePlayback transitions to prerolling then primed
    func test_prepareForImmediatePlayback_transitionsToPrerollingOrPrimed() async throws {
        let (controller, wavURL) = try await makeReadyProductionController()
        defer {
            controller.teardown()
            try? FileManager.default.removeItem(at: wavURL)
        }

        XCTAssertEqual(controller.readiness, .ready)
        controller.prepareForImmediatePlayback()

        // Preroll completes async — wait for .primed
        await waitUntil(timeout: 2.0) { controller.readiness == .primed }
        XCTAssertEqual(controller.readiness, .primed,
                       "prepareForImmediatePlayback must reach .primed after preroll completes")
    }

    // T2: preroll completion true fires onPrerollFinished(.primed)
    func test_preroll_completionTrue_firesOnPrerollFinished() async throws {
        let (controller, wavURL) = try await makeReadyProductionController()
        defer {
            controller.teardown()
            try? FileManager.default.removeItem(at: wavURL)
        }

        var capturedCompletion: ((Bool) -> Void)?
        controller.onPreroll = { rate, completion in
            XCTAssertEqual(rate, 1.0)
            capturedCompletion = completion
        }

        var prerollResult: PreviewAudioPrerollResult?
        controller.onPrerollFinished = { result in
            prerollResult = result
        }

        controller.prepareForImmediatePlayback()
        XCTAssertEqual(controller.readiness, .prerolling)
        XCTAssertNotNil(capturedCompletion, "onPreroll must capture the completion")

        capturedCompletion?(true)
        XCTAssertEqual(controller.readiness, .primed)
        XCTAssertEqual(prerollResult, .primed, "onPrerollFinished must fire with .primed")
    }

    // T3: preroll completion false falls back to .ready
    func test_preroll_completionFalse_fallsBackToReady() async throws {
        let (controller, wavURL) = try await makeReadyProductionController()
        defer {
            controller.teardown()
            try? FileManager.default.removeItem(at: wavURL)
        }

        var capturedCompletion: ((Bool) -> Void)?
        controller.onPreroll = { _, completion in
            capturedCompletion = completion
        }

        var prerollResult: PreviewAudioPrerollResult?
        controller.onPrerollFinished = { result in
            prerollResult = result
        }

        controller.prepareForImmediatePlayback()
        XCTAssertEqual(controller.readiness, .prerolling)

        capturedCompletion?(false)
        XCTAssertEqual(controller.readiness, .ready,
                       "Preroll false must fall back to .ready")
        XCTAssertEqual(prerollResult, .readyFallback, "onPrerollFinished must fire with .readyFallback")
    }

    // T4: stale preroll token is ignored
    func test_preroll_staleToken_ignored() async throws {
        let (controller, wavURL) = try await makeReadyProductionController()
        defer {
            controller.teardown()
            try? FileManager.default.removeItem(at: wavURL)
        }

        var capturedCompletion: ((Bool) -> Void)?
        controller.onPreroll = { _, completion in
            capturedCompletion = completion
        }

        var prerollFired = false
        controller.onPrerollFinished = { _ in
            prerollFired = true
        }

        controller.prepareForImmediatePlayback()
        XCTAssertEqual(controller.readiness, .prerolling)

        // pause() bumps preroll token, invalidating the pending completion
        controller.pause()

        // Fire the old completion — should be ignored
        capturedCompletion?(true)
        XCTAssertFalse(prerollFired, "Stale preroll completion must not fire onPrerollFinished")
        XCTAssertNotEqual(controller.readiness, .primed, "Must not transition to primed on stale token")
    }

    // T5: failed item during preroll transitions to failed
    func test_preroll_failedItemDuringPreroll_transitionsFailed() async throws {
        let (controller, wavURL) = try await makeReadyProductionController()
        defer {
            controller.teardown()
            try? FileManager.default.removeItem(at: wavURL)
        }

        var capturedCompletion: ((Bool) -> Void)?
        controller.onPreroll = { _, completion in
            capturedCompletion = completion
        }

        var failureReason: PreviewAudioFailureReason?
        controller.onFailure = { reason in
            failureReason = reason
        }

        controller.prepareForImmediatePlayback()
        XCTAssertEqual(controller.readiness, .prerolling)

        // Invalidate item, then fire completion with true
        controller.invalidateCurrentItemForTesting()
        capturedCompletion?(true)

        XCTAssertEqual(controller.readiness, .failed,
                       "Must transition to failed when item invalidated during preroll")
        XCTAssertEqual(failureReason, .startOnFailedItem)
    }

    // T6: startPlayback accepts .primed state
    func test_startPlayback_acceptsPrimed() async throws {
        let (controller, wavURL) = try await makeReadyProductionController()
        defer {
            controller.teardown()
            try? FileManager.default.removeItem(at: wavURL)
        }

        // Get to primed
        controller.prepareForImmediatePlayback()
        await waitUntil(timeout: 2.0) { controller.readiness == .primed }
        guard controller.readiness == .primed else {
            throw XCTSkip("Could not reach primed state")
        }

        var playImmediatelyCount = 0
        controller.onPlayImmediately = { _ in
            playImmediatelyCount += 1
        }

        controller.startPlayback(fromSeconds: 0.0, hostTime: CACurrentMediaTime())
        XCTAssertEqual(playImmediatelyCount, 1,
                       "startPlayback must use playImmediately from .primed state")
    }

    // T7: startPlayback rejects .prerolling state
    func test_startPlayback_rejectsPrerolling() async throws {
        let (controller, wavURL) = try await makeReadyProductionController()
        defer {
            controller.teardown()
            try? FileManager.default.removeItem(at: wavURL)
        }

        controller.onPreroll = { _, _ in
            // Hold — never call completion
        }

        controller.prepareForImmediatePlayback()
        XCTAssertEqual(controller.readiness, .prerolling)

        var scheduleCallCount = 0
        controller.onSchedulePlayback = { _, _, _ in
            scheduleCallCount += 1
        }

        controller.startPlayback(fromSeconds: 0.0, hostTime: CACurrentMediaTime())
        XCTAssertEqual(scheduleCallCount, 0,
                       "startPlayback must be no-op while prerolling")
    }

    // T7b: pause during preroll calls cancelPendingPrerolls
    func test_pause_duringPreroll_callsCancelPendingPrerolls() async throws {
        let (controller, wavURL) = try await makeReadyProductionController()
        defer {
            controller.teardown()
            try? FileManager.default.removeItem(at: wavURL)
        }

        controller.onPreroll = { _, _ in
            // Hold — never call completion
        }

        controller.prepareForImmediatePlayback()
        XCTAssertEqual(controller.readiness, .prerolling)

        var cancelPrerollCallCount = 0
        controller.onCancelPendingPrerolls = {
            cancelPrerollCallCount += 1
        }

        controller.pause()
        XCTAssertEqual(cancelPrerollCallCount, 1,
                       "pause() must call cancelPendingPrerolls via cancelPendingPrerollAndInvalidate")
    }

    // T7c: startPlayback during primed calls cancelPendingPrerolls
    func test_startPlayback_fromPrimed_callsCancelPendingPrerolls() async throws {
        let (controller, wavURL) = try await makeReadyProductionController()
        defer {
            controller.teardown()
            try? FileManager.default.removeItem(at: wavURL)
        }

        controller.prepareForImmediatePlayback()
        await waitUntil(timeout: 2.0) { controller.readiness == .primed }
        guard controller.readiness == .primed else {
            throw XCTSkip("Could not reach primed state")
        }

        var cancelPrerollCallCount = 0
        controller.onCancelPendingPrerolls = {
            cancelPrerollCallCount += 1
        }
        controller.onSchedulePlayback = { _, _, _ in }

        controller.startPlayback(fromSeconds: 0.0, hostTime: CACurrentMediaTime())
        XCTAssertGreaterThanOrEqual(cancelPrerollCallCount, 1,
                       "startPlayback must call cancelPendingPrerolls before scheduling")
    }

    // T8: coordinator onReady triggers preroll
    func test_coordinator_onReady_triggersPreroll() async throws {
        guard let (_, runtime) = await makePlayableRuntime() else {
            throw XCTSkip("Metal device not available")
        }
        let mock = MockPreviewAudioController()
        mock.simulateImmediateReady = false
        runtime.setPreviewAudioController(mock)
        let controllable = ControllablePipelineBuilder()
        runtime.previewAudioPipelineBuilder = controllable.builder

        runtime.startPlayback()
        await waitForPlaybackStart(runtime)

        for _ in 0..<10 {
            await Task.yield()
            if controllable.pendingCount >= 1 { break }
        }
        XCTAssertGreaterThanOrEqual(controllable.pendingCount, 1)

        // Complete build → replacePipeline called but simulateImmediateReady=false
        controllable.completeNext(with: makeDummyPipeline())
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(mock.replacePipelineCallCount, 1)
        XCTAssertEqual(mock.prepareForImmediatePlaybackCallCount, 0,
                       "Preroll should not happen until ready")

        // Simulate ready → onReady fires → prepareForImmediatePlayback called
        mock.simulateReady()
        XCTAssertEqual(mock.prepareForImmediatePlaybackCallCount, 1,
                       "onReady must trigger prepareForImmediatePlayback")

        runtime.stopPlayback()
        controllable.drainAll()
    }

    // T9: coordinator prerollFinished marks clean and starts playback
    func test_coordinator_prerollFinished_marksCleanAndStartsPlayback() async throws {
        guard let (_, runtime) = await makePlayableRuntime() else {
            throw XCTSkip("Metal device not available")
        }
        let mock = MockPreviewAudioController()
        mock.simulateImmediateReady = false
        runtime.setPreviewAudioController(mock)
        let controllable = ControllablePipelineBuilder()
        runtime.previewAudioPipelineBuilder = controllable.builder

        runtime.startPlayback()
        await waitForPlaybackStart(runtime)

        for _ in 0..<10 {
            await Task.yield()
            if controllable.pendingCount >= 1 { break }
        }
        controllable.completeNext(with: makeDummyPipeline())
        for _ in 0..<10 { await Task.yield() }

        XCTAssertTrue(runtime.previewAudioDirty, "dirty must remain true until preroll finishes")
        XCTAssertEqual(mock.startPlaybackCallCount, 0)

        // Simulate ready → prepareForImmediatePlayback (stays prerolling) → simulate primed
        mock.simulateReady()
        XCTAssertEqual(mock.readiness, .prerolling)

        mock.simulatePrimed()

        XCTAssertFalse(runtime.previewAudioDirty, "dirty must be false after preroll finishes")
        XCTAssertEqual(mock.startPlaybackCallCount, 1,
                       "startPlayback must be called after preroll finishes while playing")

        runtime.stopPlayback()
        controllable.drainAll()
    }

    // T10: coordinator prerollFalse still starts playback
    func test_coordinator_prerollFalse_stillStartsPlayback() async throws {
        guard let (_, runtime) = await makePlayableRuntime() else {
            throw XCTSkip("Metal device not available")
        }
        let mock = MockPreviewAudioController()
        mock.simulateImmediateReady = false
        runtime.setPreviewAudioController(mock)
        let controllable = ControllablePipelineBuilder()
        runtime.previewAudioPipelineBuilder = controllable.builder

        runtime.startPlayback()
        await waitForPlaybackStart(runtime)

        for _ in 0..<10 {
            await Task.yield()
            if controllable.pendingCount >= 1 { break }
        }
        controllable.completeNext(with: makeDummyPipeline())
        for _ in 0..<10 { await Task.yield() }

        // Simulate ready → prepareForImmediatePlayback (stays prerolling)
        mock.simulateReady()
        XCTAssertEqual(mock.readiness, .prerolling)

        // Simulate preroll failure (falls back to .ready)
        mock.simulatePrerollFailed()

        XCTAssertFalse(runtime.previewAudioDirty, "dirty must be false even on preroll fallback")
        XCTAssertEqual(mock.startPlaybackCallCount, 1,
                       "startPlayback must be called even when preroll falls back to .ready")

        runtime.stopPlayback()
        controllable.drainAll()
    }

    // T11: deferredPlayerNotReady during idle prepare does NOT mark clean
    func test_prerollPlayerUnknown_idlePrepare_doesNotMarkClean() async throws {
        guard let (_, runtime) = await makePlayableRuntime() else {
            throw XCTSkip("Metal device not available")
        }
        let mock = MockPreviewAudioController()
        mock.simulateImmediateReady = false
        runtime.setPreviewAudioController(mock)
        let controllable = ControllablePipelineBuilder()
        runtime.previewAudioPipelineBuilder = controllable.builder

        // Idle prepare (not playing)
        runtime.previewAudio.prepareForTimelinePreview()

        for _ in 0..<10 {
            await Task.yield()
            if controllable.pendingCount >= 1 { break }
        }
        controllable.completeNext(with: makeDummyPipeline())
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(mock.replacePipelineCallCount, 1)

        // Simulate ready → prepareForImmediatePlayback (stays prerolling)
        mock.simulateReady()
        XCTAssertEqual(mock.prepareForImmediatePlaybackCallCount, 1)

        // Simulate player.status == .unknown → deferredPlayerNotReady
        mock.simulatePlayerNotReady()

        XCTAssertTrue(runtime.previewAudioDirty,
                      "deferredPlayerNotReady during idle prepare must NOT clear dirty")
        XCTAssertEqual(mock.startPlaybackCallCount, 0,
                       "Must not start playback during idle prepare")

        controllable.drainAll()
    }

    // T12: deferredPlayerNotReady during active play starts fallback playback
    func test_prerollPlayerUnknown_activePlay_startsFallbackPlayback() async throws {
        guard let (_, runtime) = await makePlayableRuntime() else {
            throw XCTSkip("Metal device not available")
        }
        let mock = MockPreviewAudioController()
        mock.simulateImmediateReady = false
        runtime.setPreviewAudioController(mock)
        let controllable = ControllablePipelineBuilder()
        runtime.previewAudioPipelineBuilder = controllable.builder

        runtime.startPlayback()
        await waitForPlaybackStart(runtime)

        for _ in 0..<10 {
            await Task.yield()
            if controllable.pendingCount >= 1 { break }
        }
        controllable.completeNext(with: makeDummyPipeline())
        for _ in 0..<10 { await Task.yield() }

        // Simulate ready → prepareForImmediatePlayback (stays prerolling)
        mock.simulateReady()
        XCTAssertEqual(mock.startPlaybackCallCount, 0, "Not started yet")

        // Simulate player.status == .unknown → deferredPlayerNotReady
        mock.simulatePlayerNotReady()

        XCTAssertEqual(mock.startPlaybackCallCount, 1,
                       "deferredPlayerNotReady during active play must start fallback playback")
        XCTAssertTrue(runtime.previewAudioDirty,
                      "dirty must remain true so next cycle retries preroll")

        runtime.stopPlayback()
        controllable.drainAll()
    }

    // T13: readyFallback marks clean and starts playback
    func test_prerollResult_readyFallback_marksCleanAndStartsPlayback() async throws {
        guard let (_, runtime) = await makePlayableRuntime() else {
            throw XCTSkip("Metal device not available")
        }
        let mock = MockPreviewAudioController()
        mock.simulateImmediateReady = false
        runtime.setPreviewAudioController(mock)
        let controllable = ControllablePipelineBuilder()
        runtime.previewAudioPipelineBuilder = controllable.builder

        runtime.startPlayback()
        await waitForPlaybackStart(runtime)

        for _ in 0..<10 {
            await Task.yield()
            if controllable.pendingCount >= 1 { break }
        }
        controllable.completeNext(with: makeDummyPipeline())
        for _ in 0..<10 { await Task.yield() }

        // Simulate ready → preroll starts
        mock.simulateReady()

        // Simulate preroll interrupted but item still valid → readyFallback
        mock.simulatePrerollFailed()

        XCTAssertFalse(runtime.previewAudioDirty,
                       "readyFallback must mark dirty=false")
        XCTAssertEqual(mock.startPlaybackCallCount, 1,
                       "readyFallback must start playback")

        runtime.stopPlayback()
        controllable.drainAll()
    }

    // MARK: - PR-4: Immediate Start For Primed Preview Audio

    func test_startPlayback_fromPrimedDirect_usesPlayImmediately() async throws {
        let (controller, wavURL) = try await makeReadyProductionController()
        defer {
            controller.teardown()
            try? FileManager.default.removeItem(at: wavURL)
        }

        // Transition to .primed via test seam
        var prerollCompletion: ((Bool) -> Void)?
        controller.onPreroll = { _, completion in
            prerollCompletion = completion
        }
        controller.prepareForImmediatePlayback()
        XCTAssertEqual(controller.readiness, .prerolling)
        prerollCompletion?(true)
        XCTAssertEqual(controller.readiness, .primed)

        var playImmediatelyCount = 0
        var scheduleCount = 0
        controller.onPlayImmediately = { rate in
            XCTAssertEqual(rate, 1.0)
            playImmediatelyCount += 1
        }
        controller.onSchedulePlayback = { _, _, _ in
            scheduleCount += 1
        }

        // drift = 0.0 < 0.15 → direct path, primed → playImmediately
        controller.startPlayback(fromSeconds: 0.0, hostTime: CACurrentMediaTime())

        XCTAssertEqual(playImmediatelyCount, 1,
                       "Primed direct path must use playImmediately")
        XCTAssertEqual(scheduleCount, 0,
                       "Primed direct path must NOT use scheduled start")
    }

    func test_startPlayback_fromPrimedAfterSeek_usesPlayImmediately() async throws {
        let (controller, wavURL) = try await makeReadyProductionController()
        defer {
            controller.teardown()
            try? FileManager.default.removeItem(at: wavURL)
        }

        // Transition to .primed
        var prerollCompletion: ((Bool) -> Void)?
        controller.onPreroll = { _, completion in
            prerollCompletion = completion
        }
        controller.prepareForImmediatePlayback()
        prerollCompletion?(true)
        XCTAssertEqual(controller.readiness, .primed)

        var seekCount = 0
        var playImmediatelyCount = 0
        var scheduleCount = 0
        var capturedSeekCompletion: ((Bool) -> Void)?

        controller.onSeek = { (_: CMTime, completion: @escaping (Bool) -> Void) in
            seekCount += 1
            capturedSeekCompletion = completion
        }
        controller.onPlayImmediately = { _ in
            playImmediatelyCount += 1
        }
        controller.onSchedulePlayback = { _, _, _ in
            scheduleCount += 1
        }

        // drift = 5.0 > 0.15 → seek path
        controller.startPlayback(fromSeconds: 5.0, hostTime: CACurrentMediaTime())
        XCTAssertEqual(seekCount, 1, "Must seek when drift exceeds threshold")

        // Complete seek
        capturedSeekCompletion?(true)
        // Yield for DispatchQueue.main.async in seek completion
        for _ in 0..<10 { await Task.yield() }
        let exp = expectation(description: "mainQ")
        DispatchQueue.main.async { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 1.0)

        XCTAssertEqual(playImmediatelyCount, 1,
                       "Primed seek path must use playImmediately after seek")
        XCTAssertEqual(scheduleCount, 0,
                       "Primed seek path must NOT use scheduled start")
    }

    func test_startPlayback_fromReadyDirect_keepsScheduledStart() async throws {
        let (controller, wavURL) = try await makeReadyProductionController()
        defer {
            controller.teardown()
            try? FileManager.default.removeItem(at: wavURL)
        }

        // Stay in .ready — do NOT preroll

        var playImmediatelyCount = 0
        var scheduleCount = 0
        controller.onPlayImmediately = { _ in
            playImmediatelyCount += 1
        }
        controller.onSchedulePlayback = { rate, _, _ in
            XCTAssertEqual(rate, 1.0)
            scheduleCount += 1
        }

        // drift = 0.0 < 0.15 → direct path, ready → scheduled
        controller.startPlayback(fromSeconds: 0.0, hostTime: CACurrentMediaTime())

        XCTAssertEqual(scheduleCount, 1,
                       "Ready direct path must use scheduled start")
        XCTAssertEqual(playImmediatelyCount, 0,
                       "Ready direct path must NOT use playImmediately")
    }

    func test_startPlayback_fromReadyAfterSeek_keepsScheduledStart() async throws {
        let (controller, wavURL) = try await makeReadyProductionController()
        defer {
            controller.teardown()
            try? FileManager.default.removeItem(at: wavURL)
        }

        // Stay in .ready — do NOT preroll

        var seekCount = 0
        var playImmediatelyCount = 0
        var scheduleCount = 0
        var capturedSeekCompletion: ((Bool) -> Void)?

        controller.onSeek = { (_: CMTime, completion: @escaping (Bool) -> Void) in
            seekCount += 1
            capturedSeekCompletion = completion
        }
        controller.onPlayImmediately = { _ in
            playImmediatelyCount += 1
        }
        controller.onSchedulePlayback = { _, _, _ in
            scheduleCount += 1
        }

        // drift = 5.0 > 0.15 → seek path
        controller.startPlayback(fromSeconds: 5.0, hostTime: CACurrentMediaTime())
        XCTAssertEqual(seekCount, 1, "Must seek when drift exceeds threshold")

        // Complete seek
        capturedSeekCompletion?(true)
        for _ in 0..<10 { await Task.yield() }
        let exp = expectation(description: "mainQ")
        DispatchQueue.main.async { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 1.0)

        XCTAssertEqual(scheduleCount, 1,
                       "Ready seek path must use scheduled start")
        XCTAssertEqual(playImmediatelyCount, 0,
                       "Ready seek path must NOT use playImmediately")
    }

    // MARK: - Engine Controller Tests

    /// Creates an EnginePreviewAudioPlaybackController with a real silent audio pipeline,
    /// waits for render to complete and readiness == .ready.
    /// Returns (controller, wavURL). Caller must call controller.teardown() and clean up wavURL.
    private func makeReadyEngineController() async throws -> (EnginePreviewAudioPlaybackController, URL) {
        let (pipeline, wavURL) = try await makeRealSilentAudioPipeline()
        let controller = EnginePreviewAudioPlaybackController()
        controller.replacePipeline(pipeline)

        await waitUntil(timeout: 5.0) { controller.readiness == .ready }
        if controller.readiness != .ready {
            controller.teardown()
            try? FileManager.default.removeItem(at: wavURL)
            XCTFail("Engine controller did not become ready in time (readiness=\(controller.readiness))")
        }
        return (controller, wavURL)
    }

    // MARK: - Engine Test 1: replacePipeline renders and becomes ready

    func test_engineController_replacePipeline_rendersAndBecomesReady() async throws {
        let (pipeline, wavURL) = try await makeRealSilentAudioPipeline()
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let controller = EnginePreviewAudioPlaybackController()
        defer { controller.teardown() }

        var readyFired = false
        controller.onReady = { readyFired = true }
        controller.replacePipeline(pipeline)

        XCTAssertEqual(controller.readiness, .preparing)

        await waitUntil(timeout: 5.0) { controller.readiness == .ready }

        XCTAssertEqual(controller.readiness, .ready)
        XCTAssertTrue(readyFired)
        XCTAssertTrue(controller.hasActivePipeline)
    }

    // MARK: - Engine Test 2: prepareForImmediatePlayback becomes primed

    func test_engineController_prepareForImmediatePlayback_becomesPrimed() async throws {
        let (controller, wavURL) = try await makeReadyEngineController()
        defer {
            controller.teardown()
            try? FileManager.default.removeItem(at: wavURL)
        }

        var prerollResult: PreviewAudioPrerollResult?
        controller.onPrerollFinished = { result in prerollResult = result }
        controller.prepareForImmediatePlayback()

        XCTAssertEqual(controller.readiness, .primed)
        XCTAssertEqual(prerollResult, .primed)
    }

    // MARK: - Engine Test 3: startPlayback plays from offset

    func test_engineController_startPlayback_playsFromOffset() async throws {
        let (controller, wavURL) = try await makeReadyEngineController()
        defer {
            controller.teardown()
            try? FileManager.default.removeItem(at: wavURL)
        }

        controller.prepareForImmediatePlayback()
        XCTAssertEqual(controller.readiness, .primed)

        var segmentFrame: AVAudioFramePosition?
        var segmentCount: AVAudioFrameCount?
        var playFired = false
        controller.onScheduleSegment = { frame, count in
            segmentFrame = frame
            segmentCount = count
        }
        controller.onPlayerPlay = { playFired = true }

        controller.startPlayback(fromSeconds: 0.05, hostTime: CACurrentMediaTime())

        XCTAssertNotNil(segmentFrame)
        XCTAssertNotNil(segmentCount)
        XCTAssertTrue(playFired)
        // 0.05s * 44100 = 2205
        XCTAssertEqual(segmentFrame, AVAudioFramePosition(0.05 * 44100))
    }

    // MARK: - Engine Test 4: startPlayback clamps frame

    func test_engineController_startPlayback_clampsFrame() async throws {
        let (controller, wavURL) = try await makeReadyEngineController()
        defer {
            controller.teardown()
            try? FileManager.default.removeItem(at: wavURL)
        }

        controller.prepareForImmediatePlayback()
        XCTAssertEqual(controller.readiness, .primed)

        var segmentFrame: AVAudioFramePosition?
        controller.onScheduleSegment = { frame, _ in segmentFrame = frame }

        // Request playback far beyond duration — should clamp
        controller.startPlayback(fromSeconds: 999.0, hostTime: CACurrentMediaTime())

        // Should have clamped to totalFrames - 1
        XCTAssertNotNil(segmentFrame)
    }

    // MARK: - Engine Test 5: pause keeps engine alive

    func test_engineController_pause_keepsEngineAlive() async throws {
        let (controller, wavURL) = try await makeReadyEngineController()
        defer {
            controller.teardown()
            try? FileManager.default.removeItem(at: wavURL)
        }

        controller.prepareForImmediatePlayback()
        controller.startPlayback(fromSeconds: 0, hostTime: CACurrentMediaTime())
        controller.pause()

        XCTAssertTrue(controller.hasActivePipeline)
    }

    // MARK: - Engine Test 6: teardown deletes cache

    func test_engineController_teardown_deletesCache() async throws {
        let (controller, wavURL) = try await makeReadyEngineController()
        defer { try? FileManager.default.removeItem(at: wavURL) }

        var cacheURL: URL?
        controller.onRenderComplete = { url in cacheURL = url }

        // Re-replace to capture the cache URL via test seam
        let (pipeline2, wavURL2) = try await makeRealSilentAudioPipeline()
        defer { try? FileManager.default.removeItem(at: wavURL2) }
        controller.replacePipeline(pipeline2)
        await waitUntil(timeout: 5.0) { controller.readiness == .ready }

        let capturedURL = try XCTUnwrap(cacheURL, "Render did not produce cache URL")
        XCTAssertTrue(FileManager.default.fileExists(atPath: capturedURL.path))

        controller.teardown()

        XCTAssertFalse(FileManager.default.fileExists(atPath: capturedURL.path))
        XCTAssertEqual(controller.readiness, .idle)
    }

    // MARK: - Engine Test 7: replacePipeline cancels in-flight render

    func test_engineController_replacePipeline_cancelsInFlightRender() async throws {
        let (pipeline1, wavURL1) = try await makeRealSilentAudioPipeline()
        defer { try? FileManager.default.removeItem(at: wavURL1) }
        let (pipeline2, wavURL2) = try await makeRealSilentAudioPipeline()
        defer { try? FileManager.default.removeItem(at: wavURL2) }

        let controller = EnginePreviewAudioPlaybackController()
        defer { controller.teardown() }

        var readyCount = 0
        controller.onReady = { readyCount += 1 }

        controller.replacePipeline(pipeline1)
        // Immediately replace again — first render should be cancelled
        controller.replacePipeline(pipeline2)

        await waitUntil(timeout: 5.0) { controller.readiness == .ready }

        // Only one ready callback should fire (from the second pipeline)
        XCTAssertEqual(readyCount, 1)
        XCTAssertEqual(controller.readiness, .ready)
    }

    // MARK: - Engine Test 8: stale render ignored after teardown (deterministic)

    func test_engineController_staleRenderIgnored() async throws {
        let (pipeline, wavURL) = try await makeRealSilentAudioPipeline()
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let controller = EnginePreviewAudioPlaybackController()

        // Start render — let it complete fully
        controller.replacePipeline(pipeline)
        await waitUntil(timeout: 5.0) { controller.readiness == .ready }
        if controller.readiness != .ready {
            controller.teardown()
            XCTFail("Engine controller did not become ready")
            return
        }

        // Now start a second render, teardown immediately — the token bump
        // in teardown() must prevent the stale success callback from resurrecting state.
        let (pipeline2, wavURL2) = try await makeRealSilentAudioPipeline()
        defer { try? FileManager.default.removeItem(at: wavURL2) }

        controller.replacePipeline(pipeline2)
        XCTAssertEqual(controller.readiness, .preparing)

        // Teardown while render is in flight — bumps readinessToken
        controller.teardown()
        XCTAssertEqual(controller.readiness, .idle)

        // Wait for the detached render task to complete and attempt its MainActor callback
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s

        // Stale callback must NOT have resurrected state
        XCTAssertEqual(controller.readiness, .idle, "Stale render must not change readiness after teardown")
        XCTAssertFalse(controller.hasActivePipeline, "Stale render must not set audioFile after teardown")
    }

    // MARK: - Engine Test 9: render failure clears renderTask and pipeline state

    func test_engineController_renderFailureClearsRenderTaskAndPipelineState() async throws {
        let controller = EnginePreviewAudioPlaybackController()
        defer { controller.teardown() }

        // Create a pipeline with empty composition — no audio tracks → render will fail
        let emptyComposition = AVMutableComposition()
        let pipeline = BuiltAudioPipeline(composition: emptyComposition, audioMix: nil)

        var failureReason: PreviewAudioFailureReason?
        controller.onFailure = { reason in failureReason = reason }
        controller.replacePipeline(pipeline)

        await waitUntil(timeout: 5.0) { controller.readiness == .failed }

        XCTAssertEqual(controller.readiness, .failed)
        XCTAssertFalse(controller.hasActivePipeline)
        XCTAssertNotNil(failureReason)
    }

    // MARK: - Engine Test 10: render failure reports renderFailed reason

    func test_engineController_renderFailureReportsRenderFailed() async throws {
        let controller = EnginePreviewAudioPlaybackController()
        defer { controller.teardown() }

        let emptyComposition = AVMutableComposition()
        let pipeline = BuiltAudioPipeline(composition: emptyComposition, audioMix: nil)

        var failureReason: PreviewAudioFailureReason?
        controller.onFailure = { reason in failureReason = reason }
        controller.replacePipeline(pipeline)

        await waitUntil(timeout: 5.0) { controller.readiness == .failed }

        // Must be .renderFailed, not .itemFailed
        if case .renderFailed = failureReason {
            // expected
        } else {
            XCTFail("Expected .renderFailed, got \(String(describing: failureReason))")
        }
    }

    // MARK: - Engine Test 11: startPlayback schedules debug probes

    func test_engineController_startPlaybackSchedulesDebugProbes() async throws {
        let (controller, wavURL) = try await makeReadyEngineController()
        defer {
            controller.teardown()
            try? FileManager.default.removeItem(at: wavURL)
        }

        controller.prepareForImmediatePlayback()
        XCTAssertEqual(controller.readiness, .primed)

        var probeDelays: [Int] = []
        controller.onProbe = { delay in probeDelays.append(delay) }

        controller.startPlayback(fromSeconds: 0, hostTime: CACurrentMediaTime())

        // Wait for all probes to fire (last at 2000ms + margin)
        await waitUntil(timeout: 3.0) { probeDelays.count >= 4 }

        XCTAssertEqual(probeDelays.sorted(), [100, 500, 1000, 2000])
    }
}
