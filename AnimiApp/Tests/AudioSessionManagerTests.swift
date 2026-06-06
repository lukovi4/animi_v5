import XCTest
import Metal
import AVFAudio
import TVECore
@testable import AnimiApp

// MARK: - Mock Audio Session Manager

@MainActor
final class MockAudioSessionManager: AudioSessionManaging {
    var onEvent: ((AudioSessionEvent) -> Void)?

    var configureCallCount = 0
    var activateCallCount = 0
    var deactivateCallCount = 0
    var shouldFailActivation = false
    var activationError: Error?

    struct ActivationFailure: Error, LocalizedError {
        var errorDescription: String? { "Mock activation failed" }
    }

    func configureForPlayback() throws {
        configureCallCount += 1
    }

    func activateForPlayback() throws {
        activateCallCount += 1
        if shouldFailActivation {
            let error = activationError ?? ActivationFailure()
            throw error
        }
    }

    func deactivateAfterPlayback() throws {
        deactivateCallCount += 1
    }

    func simulateEvent(_ event: AudioSessionEvent) {
        onEvent?(event)
    }
}

// MARK: - Fake Session Adapter

@MainActor
final class FakeAudioSessionAdapter: AudioSessionAdapting {
    var category: AVAudioSession.Category = .ambient
    var mode: AVAudioSession.Mode = .default

    var setCategoryCallCount = 0
    var setActiveCallCount = 0
    var lastSetActiveValue: Bool?
    var lastSetActiveOptions: AVAudioSession.SetActiveOptions?
    var shouldFailSetActive = false
    var shouldFailDeactivation = false

    struct FakeError: Error, LocalizedError {
        var errorDescription: String? { "Fake setActive failure" }
    }

    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode) throws {
        setCategoryCallCount += 1
        self.category = category
        self.mode = mode
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        setActiveCallCount += 1
        lastSetActiveValue = active
        lastSetActiveOptions = options
        if shouldFailSetActive && active {
            throw FakeError()
        }
        if shouldFailDeactivation && !active {
            throw FakeError()
        }
    }
}

// MARK: - Runtime Integration Tests

@MainActor
final class AudioSessionManagerTests: XCTestCase {

    // MARK: - Helpers

    private func makeBootstrappedSession() async -> EditorSession {
        let deps = EditorSessionDependencies(
            saveActiveDraft: { _ in },
            loadActiveDraft: { nil },
            deleteActiveDraft: {},
            loadSavedProject: { _ in nil },
            materializeSavedProject: { $0 },
            mediaLocator: StubMediaLocatorForAudioTests(),
            mediaWriter: StubMediaWriterForAudioTests(),
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
            backgroundPresetProvider: StubPresetProviderForAudioTests()
        )
        let session = EditorSession(intent: .template(templateId: "tpl_1"), dependencies: deps)
        await session.bootstrap()
        return session
    }

    /// Minimal media-less render resources so the booted engine resolves the start frame.
    private func makeRenderableResources(sceneTypeId: String, durationFrames: Int, fps: Int = 30) -> SceneTypeResourcesCache.Resources {
        let canvas = Canvas(width: 1080, height: 1920, fps: fps, durationFrames: durationFrames)
        let scene = Scene(schemaVersion: "1.0", sceneId: sceneTypeId, canvas: canvas, background: nil, mediaBlocks: [])
        let runtime = SceneRuntime(scene: scene, canvas: canvas, blocks: [], durationFrames: durationFrames, fps: fps)
        let compiled = CompiledScene(
            runtime: runtime, mergedAssetIndex: AssetIndexIR(),
            pathRegistry: PathRegistry(), bindingAssetIds: []
        )
        return SceneTypeResourcesCache.Resources(
            sceneTypeId: sceneTypeId, compiled: compiled,
            resolver: CompositeAssetResolver(localIndex: .empty, sharedIndex: .empty),
            baseTextureProvider: InMemoryTextureProvider(), assetSizes: [:],
            pathRegistry: PathRegistry(),
            canvasSize: SizeD(width: Double(canvas.width), height: Double(canvas.height)),
            fps: fps, durationFrames: durationFrames
        )
    }

    /// Initial loaded scene result for `scene_1` (90 frames), media-less so it resolves.
    private func makeBootLoadResult(device: MTLDevice) -> EditorRuntime.InitialSceneLoadResult {
        let canvas = Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 90)
        let scene = Scene(schemaVersion: "1.0", sceneId: "scene_1", canvas: canvas, background: nil, mediaBlocks: [])
        let runtime = SceneRuntime(scene: scene, canvas: canvas, blocks: [], durationFrames: 90, fps: 30)
        let compiled = CompiledScene(
            runtime: runtime, mergedAssetIndex: AssetIndexIR(),
            pathRegistry: PathRegistry(), bindingAssetIds: []
        )
        let resolver = CompositeAssetResolver(localIndex: .empty, sharedIndex: .empty)
        let provider = ScenePackageTextureProvider(
            device: device, assetIndex: compiled.mergedAssetIndex,
            resolver: resolver, bindingAssetIds: compiled.bindingAssetIds
        )
        let player = ScenePlayer()
        let loaded = player.loadCompiledScene(compiled)
        return EditorRuntime.InitialSceneLoadResult(
            player: player, compiled: loaded, provider: provider, resolver: resolver, preloadStats: nil
        )
    }

    /// Boots a runtime through the production `configureAndBoot` path whose timeline
    /// engine RESOLVES the start frame, so production `startPlayback()` satisfies the
    /// render-payload hard gate. These are runtime-integration tests, so the production
    /// start path is retained. Returns nil if Metal is unavailable.
    private func makePlayableRuntime() async -> (EditorRuntime, MockAudioSessionManager, MockPreviewAudioController)? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        let session = await makeBootstrappedSession()
        guard let editorState = session.state else { return nil }

        let runtime = EditorRuntime(session: session)

        let metalContext = EditorRuntimeMetalContext(
            device: device, commandQueue: commandQueue, colorPixelFormat: .bgra8Unorm
        )
        let library = SceneLibrarySnapshot(
            fps: 30,
            canvas: CanvasConfig(width: 1080, height: 1920),
            scenes: [SceneTypeDescriptor(id: "scene_1", order: 0, title: "Test", baseDurationUs: 3_000_000)]
        )
        runtime.configureAndBoot(
            metalContext: metalContext,
            library: library,
            loadResult: makeBootLoadResult(device: device),
            editorState: editorState
        )
        runtime.testTimelineCompositionEngine?.resourcesCache.addToCache(
            makeRenderableResources(sceneTypeId: "scene_1", durationFrames: 90)
        )
        // Wait — real-time deadline — until the boot resolve installs the frame-0 render
        // source, so production startPlayback() resolves deterministically.
        await waitUntil(timeout: 2.0) {
            if case .timeline = runtime.currentRenderSource { return true }
            return false
        }

        let mockAudio = MockAudioSessionManager()
        runtime.audioSessionManager = mockAudio
        runtime.bindAudioSessionEvents(mockAudio)

        let mockPreview = MockPreviewAudioController()
        runtime.setPreviewAudioController(mockPreview)
        // `{ nil }` builder → no resolvable audio → `.noAudio` → boundary opens without
        // an audio build, matching these tests' "start runs" assertions.
        runtime.previewAudioPipelineBuilder = { nil }

        return (runtime, mockAudio, mockPreview)
    }

    @discardableResult
    private func waitUntil(timeout: TimeInterval, condition: @MainActor () -> Bool) async -> Bool {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        while CFAbsoluteTimeGetCurrent() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    /// Waits for an observable condition; FAILS with a phase message on timeout so a
    /// missed async runtime state change surfaces here, not at a later assertion.
    private func requireEventually(
        timeout: TimeInterval,
        _ message: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @MainActor () -> Bool
    ) async {
        if await waitUntil(timeout: timeout, condition: condition) { return }
        XCTFail("Timed out waiting for: \(message())", file: file, line: line)
    }

    /// Lets a start that is EXPECTED to be rejected settle, then is safe to assert
    /// `!isPlaying`. Waits until the start task is no longer pending (rejected/aborted),
    /// bounded; if it is still pending it simply means the negative assertion runs after
    /// a fair deadline.
    private func waitForStartToSettle(_ runtime: EditorRuntime, timeout: TimeInterval = 1.0) async {
        _ = await waitUntil(timeout: timeout) { runtime.isPlaying || !runtime.hasPlaybackStartTask }
    }

    // MARK: - Activation Success

    func testActivateSuccess_startsPlayback() async throws {
        guard let (runtime, mockAudio, _) = await makePlayableRuntime() else {
            throw XCTSkip("Metal unavailable")
        }

        runtime.startPlayback()
        await requireEventually(timeout: 2.0, "runtime.isPlaying after startPlayback") { runtime.isPlaying }

        XCTAssertEqual(mockAudio.activateCallCount, 1)
        XCTAssertTrue(runtime.isPlaying)
    }

    // MARK: - Activation Failure

    func testActivateFailure_doesNotStartPlayback() async throws {
        guard let (runtime, mockAudio, mockPreview) = await makePlayableRuntime() else {
            throw XCTSkip("Metal unavailable")
        }

        mockAudio.shouldFailActivation = true

        runtime.startPlayback()
        // Activation fails synchronously, so the start never becomes running; wait for
        // the (rejected) start to settle, then assert it did not run.
        await waitForStartToSettle(runtime)

        XCTAssertEqual(mockAudio.activateCallCount, 1)
        XCTAssertFalse(runtime.isPlaying)
        XCTAssertEqual(mockPreview.startPlaybackCallCount, 0)
    }

    // MARK: - No Manager = No Playback (Fix 2)

    func testStartPlayback_withoutAudioSessionManager_doesNotStart() async throws {
        let session = await makeBootstrappedSession()
        let runtime = EditorRuntime(session: session)
        runtime.bootForTesting(state: .timelinePreview)

        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal unavailable")
        }
        let engine = TimelineCompositionEngine(
            device: device, commandQueue: commandQueue, fps: 30,
            mediaLocator: StubMediaLocatorForAudioTests()
        )
        if let editorState = session.state {
            engine.setTimeline(
                editorState.canonicalTimeline,
                sceneStates: editorState.draft.sceneInstanceStates,
                assetRegistry: editorState.draft.assetRegistry.selfHealed(for: editorState.draft)
            )
        }
        runtime.injectTimelineCompositionEngine(engine)
        // audioSessionManager is NOT set (nil)

        let mockPreview = MockPreviewAudioController()
        runtime.setPreviewAudioController(mockPreview)

        runtime.startPlayback()
        // No audio session manager → the start is rejected; wait for it to settle.
        await waitForStartToSettle(runtime)

        XCTAssertFalse(runtime.isPlaying)
        XCTAssertEqual(mockPreview.startPlaybackCallCount, 0)
    }

    // MARK: - Media Services Reset (active playback)

    func testMediaServicesReset_stopsPlayback() async throws {
        guard let (runtime, mockAudio, mockPreview) = await makePlayableRuntime() else {
            throw XCTSkip("Metal unavailable")
        }

        runtime.startPlayback()
        await requireEventually(timeout: 2.0, "runtime.isPlaying before reset") { runtime.isPlaying }
        XCTAssertTrue(runtime.isPlaying)

        let genBefore = runtime.previewAudioGeneration

        mockAudio.simulateEvent(.mediaServicesReset)
        await Task.yield()

        XCTAssertFalse(runtime.isPlaying)
        XCTAssertTrue(runtime.previewAudioDirty)
        XCTAssertGreaterThan(runtime.previewAudioGeneration, genBefore)
        XCTAssertTrue(mockPreview.teardownCallCount > 0)
    }

    // MARK: - Media Services Reset During Pending Start (Fix 1)

    func testMediaServicesResetDuringPendingStart_cancelsStartup() async throws {
        guard let (runtime, mockAudio, mockPreview) = await makePlayableRuntime() else {
            throw XCTSkip("Metal unavailable")
        }

        // Gate holds playbackStartTask suspended BEFORE engine.prepareForPlayback
        let gateReached = expectation(description: "gate reached")
        runtime.playbackStartGate = {
            gateReached.fulfill()
            try? await Task.sleep(nanoseconds: 10_000_000_000) // block until cancelled
        }

        runtime.startPlayback()
        await fulfillment(of: [gateReached], timeout: 2.0)

        // At this point playbackStartTask is definitely pending (inside gate)
        XCTAssertTrue(runtime.hasPlaybackStartTask, "Start task must be active at gate")
        XCTAssertFalse(runtime.isPlaying, "isPlaying must still be false")

        // Trigger reset while startup is genuinely pending
        mockAudio.simulateEvent(.mediaServicesReset)
        await requireEventually(timeout: 2.0, "pending start to be cancelled by reset") {
            !runtime.hasPlaybackStartTask
        }

        XCTAssertFalse(runtime.isPlaying, "Playback must not start after reset during pending startup")
        XCTAssertFalse(runtime.hasPlaybackStartTask, "Start task must be cancelled")
        XCTAssertEqual(mockPreview.startPlaybackCallCount, 0, "Preview audio must not start")
        XCTAssertTrue(runtime.previewAudioDirty)
    }

    // MARK: - Interruption During Pending Start (Fix 1)

    func testInterruptionDuringPendingStart_cancelsStartup() async throws {
        guard let (runtime, mockAudio, mockPreview) = await makePlayableRuntime() else {
            throw XCTSkip("Metal unavailable")
        }

        let gateReached = expectation(description: "gate reached")
        runtime.playbackStartGate = {
            gateReached.fulfill()
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }

        runtime.startPlayback()
        await fulfillment(of: [gateReached], timeout: 2.0)

        XCTAssertTrue(runtime.hasPlaybackStartTask)
        XCTAssertFalse(runtime.isPlaying)

        mockAudio.simulateEvent(.interruptionBegan)
        await requireEventually(timeout: 2.0, "pending start to be cancelled by interruption") {
            !runtime.hasPlaybackStartTask
        }

        XCTAssertFalse(runtime.isPlaying)
        XCTAssertFalse(runtime.hasPlaybackStartTask)
        XCTAssertEqual(mockPreview.startPlaybackCallCount, 0)
    }

    // MARK: - Media Services Reset Invalidates Old Pipeline

    func testMediaServicesReset_oldPipelineNotReused() async throws {
        guard let (runtime, mockAudio, mockPreview) = await makePlayableRuntime() else {
            throw XCTSkip("Metal unavailable")
        }

        mockPreview.hasActivePipeline = true
        mockPreview.readiness = .ready

        let genBefore = runtime.previewAudioGeneration

        mockAudio.simulateEvent(.mediaServicesReset)
        await Task.yield()

        XCTAssertTrue(runtime.previewAudioDirty)
        XCTAssertGreaterThan(runtime.previewAudioGeneration, genBefore)
        XCTAssertFalse(mockPreview.hasActivePipeline)
    }

    // MARK: - Interruption Began Stops Active Playback

    func testInterruptionBegan_stopsPlayback() async throws {
        guard let (runtime, mockAudio, _) = await makePlayableRuntime() else {
            throw XCTSkip("Metal unavailable")
        }

        runtime.startPlayback()
        await requireEventually(timeout: 2.0, "runtime.isPlaying before interruption") { runtime.isPlaying }
        XCTAssertTrue(runtime.isPlaying)

        mockAudio.simulateEvent(.interruptionBegan)
        await requireEventually(timeout: 2.0, "playback to stop on interruption") { !runtime.isPlaying }

        XCTAssertFalse(runtime.isPlaying)
    }

    // MARK: - Route Change: Old Device Unavailable Stops Playback

    func testRouteChangeOldDeviceUnavailable_stopsPlayback() async throws {
        guard let (runtime, mockAudio, _) = await makePlayableRuntime() else {
            throw XCTSkip("Metal unavailable")
        }

        runtime.startPlayback()
        await requireEventually(timeout: 2.0, "runtime.isPlaying before route change") { runtime.isPlaying }
        XCTAssertTrue(runtime.isPlaying)

        mockAudio.simulateEvent(.routeChanged(reason: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue))
        await requireEventually(timeout: 2.0, "playback to stop on oldDeviceUnavailable") { !runtime.isPlaying }

        XCTAssertFalse(runtime.isPlaying)
    }

    func testRouteChangeOldDeviceUnavailableDuringPendingStart_cancelsStartup() async throws {
        guard let (runtime, mockAudio, mockPreview) = await makePlayableRuntime() else {
            throw XCTSkip("Metal unavailable")
        }

        let gateReached = expectation(description: "gate reached")
        runtime.playbackStartGate = {
            gateReached.fulfill()
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }

        runtime.startPlayback()
        await fulfillment(of: [gateReached], timeout: 2.0)

        XCTAssertTrue(runtime.hasPlaybackStartTask)
        XCTAssertFalse(runtime.isPlaying)

        mockAudio.simulateEvent(.routeChanged(reason: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue))
        await requireEventually(timeout: 2.0, "pending start to be cancelled by route change") {
            !runtime.hasPlaybackStartTask
        }

        XCTAssertFalse(runtime.isPlaying)
        XCTAssertFalse(runtime.hasPlaybackStartTask)
        XCTAssertEqual(mockPreview.startPlaybackCallCount, 0)
    }

    func testRouteChangeNewDeviceAvailable_restartsPreviewAudio() async throws {
        guard let (runtime, mockAudio, mockPreview) = await makePlayableRuntime() else {
            throw XCTSkip("Metal unavailable")
        }

        // Set up mock so coordinator's startForTimelinePlayback() reaches controller
        mockPreview.hasActivePipeline = true
        mockPreview.readiness = .primed
        runtime.previewAudio.dirty = false

        runtime.startPlayback()
        await requireEventually(timeout: 2.0, "runtime.isPlaying before route change") { runtime.isPlaying }
        XCTAssertTrue(runtime.isPlaying)

        let startCountBefore = mockPreview.startPlaybackCallCount
        let reprepareCountBefore = mockPreview.reprepareForRouteChangeCallCount

        mockAudio.simulateEvent(.routeChanged(reason: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue))
        await Task.yield()

        XCTAssertTrue(runtime.isPlaying, "Playback must continue")
        XCTAssertGreaterThan(mockPreview.reprepareForRouteChangeCallCount, reprepareCountBefore, "Engine graph must be recreated")
        XCTAssertGreaterThan(mockPreview.startPlaybackCallCount, startCountBefore, "Preview audio must restart")
    }

    func testRouteChangeOtherReason_doesNotStopPlayback() async throws {
        guard let (runtime, mockAudio, _) = await makePlayableRuntime() else {
            throw XCTSkip("Metal unavailable")
        }

        runtime.startPlayback()
        await requireEventually(timeout: 2.0, "runtime.isPlaying before route change") { runtime.isPlaying }
        XCTAssertTrue(runtime.isPlaying)

        mockAudio.simulateEvent(.routeChanged(reason: AVAudioSession.RouteChangeReason.categoryChange.rawValue))
        await Task.yield()

        XCTAssertTrue(runtime.isPlaying)
    }

    // MARK: - Deactivate on Stop

    func testStopPlayback_deactivatesSession() async throws {
        guard let (runtime, mockAudio, _) = await makePlayableRuntime() else {
            throw XCTSkip("Metal unavailable")
        }

        // Session deactivation is now part of the deferred idle resource reclaim
        // (warm pause keeps the session active on the immediate path). Shorten the
        // idle window for test speed; the deactivation behavior itself is unchanged.
        runtime.idleResourceReclaimDelayNanos = 50_000_000  // 50ms

        runtime.startPlayback()
        await requireEventually(timeout: 2.0, "runtime.isPlaying before stop") { runtime.isPlaying }
        XCTAssertTrue(runtime.isPlaying)

        runtime.stopPlayback()
        await requireEventually(timeout: 1.0, "audio session to deactivate after idle reclaim") {
            mockAudio.deactivateCallCount == 1
        }

        XCTAssertEqual(mockAudio.deactivateCallCount, 1,
            "Idle reclaim after a warm pause must eventually deactivate the audio session")
    }
}

// MARK: - AudioSessionManager Unit Tests (Adapter-based, Fix 3)

@MainActor
final class AudioSessionManagerAdapterTests: XCTestCase {

    func testConfigureForPlayback_setsCategory() throws {
        let fake = FakeAudioSessionAdapter()
        let manager = AudioSessionManager(session: fake, notificationCenter: NotificationCenter())

        try manager.configureForPlayback()

        XCTAssertEqual(fake.setCategoryCallCount, 1)
        XCTAssertEqual(fake.category, .playback)
        XCTAssertEqual(fake.mode, .moviePlayback)
    }

    func testConfigureForPlayback_idempotent() throws {
        let fake = FakeAudioSessionAdapter()
        let manager = AudioSessionManager(session: fake, notificationCenter: NotificationCenter())

        try manager.configureForPlayback()
        try manager.configureForPlayback()

        XCTAssertEqual(fake.setCategoryCallCount, 2)
        XCTAssertEqual(fake.category, .playback)
    }

    func testActivateForPlayback_configuresIfNotConfigured() throws {
        let fake = FakeAudioSessionAdapter()
        let manager = AudioSessionManager(session: fake, notificationCenter: NotificationCenter())

        try manager.activateForPlayback()

        XCTAssertEqual(fake.setCategoryCallCount, 1, "Should configure before activation")
        XCTAssertEqual(fake.setActiveCallCount, 1)
        XCTAssertEqual(fake.lastSetActiveValue, true)
    }

    func testActivateForPlayback_reconfiguresIfCategoryDrifted() throws {
        let fake = FakeAudioSessionAdapter()
        let manager = AudioSessionManager(session: fake, notificationCenter: NotificationCenter())

        try manager.configureForPlayback()
        XCTAssertEqual(fake.setCategoryCallCount, 1)
        // Simulate external category drift
        fake.category = .ambient
        try manager.activateForPlayback()

        // 1 initial configure + 1 re-configure on activation (category drifted)
        XCTAssertEqual(fake.setCategoryCallCount, 2)
        XCTAssertEqual(fake.category, .playback)
    }

    func testActivateForPlayback_throwsOnFailure() throws {
        let fake = FakeAudioSessionAdapter()
        fake.shouldFailSetActive = true
        let manager = AudioSessionManager(session: fake, notificationCenter: NotificationCenter())

        XCTAssertThrowsError(try manager.activateForPlayback())
    }

    func testActivateForPlayback_emitsActivationFailedEvent() throws {
        let fake = FakeAudioSessionAdapter()
        fake.shouldFailSetActive = true
        let manager = AudioSessionManager(session: fake, notificationCenter: NotificationCenter())

        var receivedEvent: AudioSessionEvent?
        manager.onEvent = { receivedEvent = $0 }

        _ = try? manager.activateForPlayback()

        if case .activationFailed = receivedEvent {
            // expected
        } else {
            XCTFail("Expected .activationFailed event, got \(String(describing: receivedEvent))")
        }
    }

    func testDeactivateAfterPlayback_callsSetActiveFalse() throws {
        let fake = FakeAudioSessionAdapter()
        let manager = AudioSessionManager(session: fake, notificationCenter: NotificationCenter())

        try manager.deactivateAfterPlayback()

        XCTAssertEqual(fake.lastSetActiveValue, false)
        XCTAssertEqual(fake.lastSetActiveOptions, .notifyOthersOnDeactivation)
    }

    func testDeactivateAfterPlayback_propagatesDeactivationFailure() throws {
        let fake = FakeAudioSessionAdapter()
        fake.shouldFailDeactivation = true
        let manager = AudioSessionManager(session: fake, notificationCenter: NotificationCenter())

        XCTAssertThrowsError(try manager.deactivateAfterPlayback()) { error in
            XCTAssertTrue(error is FakeAudioSessionAdapter.FakeError)
        }

        XCTAssertEqual(fake.lastSetActiveValue, false)
        XCTAssertEqual(fake.lastSetActiveOptions, .notifyOthersOnDeactivation)
    }

    func testMediaServicesReset_reconfiguresCategory() async throws {
        let fake = FakeAudioSessionAdapter()
        let nc = NotificationCenter()
        let manager = AudioSessionManager(session: fake, notificationCenter: nc)

        var receivedEvent: AudioSessionEvent?
        manager.onEvent = { receivedEvent = $0 }

        // Simulate category drift before reset
        fake.category = .ambient
        fake.mode = .default

        // Post reset notification
        nc.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)

        // Allow Task hop to deliver
        await Task.yield()
        await Task.yield()
        _ = manager // prevent deallocation before Task runs

        // Manager should have re-configured
        XCTAssertEqual(fake.category, .playback)
        XCTAssertEqual(fake.mode, .moviePlayback)
        if case .mediaServicesReset = receivedEvent {
            // expected
        } else {
            XCTFail("Expected .mediaServicesReset event")
        }
    }
}

// MARK: - Stubs

private struct StubMediaLocatorForAudioTests: ProjectMediaLocator {
    var rootDir: URL?
    func absoluteURL(for mediaRef: MediaRef, registry: ProjectAssetRegistry) async throws -> URL {
        URL(fileURLWithPath: "/tmp/stub")
    }
}

private struct StubMediaWriterForAudioTests: ProjectMediaWriteGateway {
    func saveBackgroundImage(from preparedFileURL: URL) async throws -> (MediaRef, URL) {
        (MediaRef(storagePath: "stub.jpg"), URL(fileURLWithPath: "/tmp/stub"))
    }
    func saveUserMedia(from fileURL: URL, mediaKind: MediaKind, filename: String) async throws -> (MediaRef, URL) {
        (MediaRef(storagePath: "stub.jpg"), URL(fileURLWithPath: "/tmp/stub"))
    }
    func deleteMediaFile(_ mediaRef: MediaRef) async throws {}
    func duplicateAssets(inDraft sourceDraft: ProjectDraft) async throws -> ProjectDraft { sourceDraft }
}

private struct StubPresetProviderForAudioTests: BackgroundPresetProviding {
    func loadFromBundle() throws {}
    func preset(for presetId: String) -> BackgroundPreset? { nil }
    func presetOrFallback(for presetId: String) -> BackgroundPreset? { nil }
    var allPresets: [BackgroundPreset] { [] }
    var count: Int { 0 }
}
