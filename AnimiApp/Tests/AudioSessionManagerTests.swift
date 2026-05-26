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

    private func makePlayableRuntime() async -> (EditorRuntime, MockAudioSessionManager, MockPreviewAudioController)? {
        let session = await makeBootstrappedSession()
        let runtime = EditorRuntime(session: session)
        runtime.bootForTesting(state: .timelinePreview)

        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        let engine = TimelineCompositionEngine(
            device: device,
            commandQueue: commandQueue,
            fps: 30,
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

        let mockAudio = MockAudioSessionManager()
        runtime.audioSessionManager = mockAudio
        runtime.bindAudioSessionEvents(mockAudio)

        let mockPreview = MockPreviewAudioController()
        runtime.setPreviewAudioController(mockPreview)
        runtime.previewAudioPipelineBuilder = { nil }

        return (runtime, mockAudio, mockPreview)
    }

    private func waitUntil(timeout: TimeInterval, condition: @MainActor () -> Bool) async {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        while !condition() && CFAbsoluteTimeGetCurrent() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Activation Success

    func testActivateSuccess_startsPlayback() async throws {
        guard let (runtime, mockAudio, _) = await makePlayableRuntime() else {
            throw XCTSkip("Metal unavailable")
        }

        runtime.startPlayback()
        try await Task.sleep(nanoseconds: 50_000_000)

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
        try await Task.sleep(nanoseconds: 50_000_000)

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
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(runtime.isPlaying)
        XCTAssertEqual(mockPreview.startPlaybackCallCount, 0)
    }

    // MARK: - Media Services Reset (active playback)

    func testMediaServicesReset_stopsPlayback() async throws {
        guard let (runtime, mockAudio, mockPreview) = await makePlayableRuntime() else {
            throw XCTSkip("Metal unavailable")
        }

        runtime.startPlayback()
        try await Task.sleep(nanoseconds: 50_000_000)
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
        await Task.yield()
        try await Task.sleep(nanoseconds: 50_000_000)

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
        await Task.yield()
        try await Task.sleep(nanoseconds: 50_000_000)

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
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(runtime.isPlaying)

        mockAudio.simulateEvent(.interruptionBegan)
        await Task.yield()

        XCTAssertFalse(runtime.isPlaying)
    }

    // MARK: - Route Change: Old Device Unavailable Stops Playback

    func testRouteChangeOldDeviceUnavailable_stopsPlayback() async throws {
        guard let (runtime, mockAudio, _) = await makePlayableRuntime() else {
            throw XCTSkip("Metal unavailable")
        }

        runtime.startPlayback()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(runtime.isPlaying)

        mockAudio.simulateEvent(.routeChanged(reason: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue))
        await Task.yield()

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
        await Task.yield()
        try await Task.sleep(nanoseconds: 50_000_000)

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
        try await Task.sleep(nanoseconds: 50_000_000)
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
        try await Task.sleep(nanoseconds: 50_000_000)
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

        runtime.startPlayback()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(runtime.isPlaying)

        runtime.stopPlayback()
        await waitUntil(timeout: 1.0) { mockAudio.deactivateCallCount == 1 }

        XCTAssertEqual(mockAudio.deactivateCallCount, 1)
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
