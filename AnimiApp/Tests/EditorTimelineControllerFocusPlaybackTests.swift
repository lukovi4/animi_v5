import XCTest
import TVECore
@testable import AnimiApp

/// Regression coverage for: a scene tap during preview must stop playback before
/// scene focus is applied (mirrors the existing scrub/trim interaction guard).
///
/// Drives the production controller path
/// `EditorTimelineController.handleTimelineEvent(.focusScene(...))` with an attached
/// runtime simulated as "playing" via DEBUG seams, and asserts that:
///   - playback is stopped (`runtime.isPlaying == false`);
///   - focus still takes effect (the store selects the focused scene).
@MainActor
final class EditorTimelineControllerFocusPlaybackTests: XCTestCase {

    // MARK: - Stubs

    private struct StubMediaLocator: ProjectMediaLocator {
        func absoluteURL(for mediaRef: MediaRef, registry: ProjectAssetRegistry) async throws -> URL {
            URL(fileURLWithPath: "/tmp/stub")
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

    // MARK: - Helpers

    private func makeSession() async -> EditorSession {
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

    /// Loads a deterministic two-scene project into the session's store so the test
    /// has known scene IDs and a predictable playhead position.
    private func loadTwoSceneProject(into session: EditorSession) -> (scene1: UUID, scene2: UUID) {
        var draft = ProjectDraft.create(origin: .template(templateId: "test-template"))
        var timeline = CanonicalTimeline.empty()
        var payloads: [UUID: TimelinePayload] = [:]
        for index in 0..<2 {
            let payloadId = UUID()
            payloads[payloadId] = .scene(ScenePayload(sceneTypeId: "test_scene_\(index)"))
            let item = TimelineItem(payloadId: payloadId, kind: .scene, startUs: nil, durationUs: 1_000_000)
            timeline.tracks[0].items.append(item)
        }
        timeline.payloads = payloads
        draft.canonicalTimeline = timeline

        let defaults = (0..<2).map {
            SceneTypeDefault(sceneTypeId: "test_scene_\($0)", baseDurationUs: 1_000_000)
        }
        session.dispatch(.loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: defaults))

        let scenes = session.state?.sceneItems ?? []
        return (scenes[0].id, scenes[1].id)
    }

    /// Polls a condition with real time delays to allow detached tasks to complete.
    private func waitUntil(timeout: TimeInterval, condition: @MainActor () -> Bool) async {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        while !condition() && CFAbsoluteTimeGetCurrent() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
    }

    // MARK: - Tests

    /// Tapping a *different* scene during playback stops playback and still focuses.
    func test_focusScene_differentScene_duringPlayback_stopsPlayback_andFocuses() async {
        #if DEBUG
        let session = await makeSession()
        let (_, scene2) = loadTwoSceneProject(into: session)

        let vc = EditorViewController(session: session)
        let runtime = EditorRuntime(session: session)
        runtime.bootForTesting(state: .timelinePreview)
        vc.runtime = runtime

        // Simulate active preview playback.
        runtime.setPlayingForTesting(true)
        XCTAssertTrue(runtime.isPlaying, "Pre-condition: preview must be playing")

        // User taps a different scene in the timeline.
        vc.timelineController.handleTimelineEvent(.focusScene(sceneId: scene2))

        // Playback must have stopped.
        XCTAssertFalse(runtime.isPlaying, "Scene tap during playback must stop preview")

        // Focus must still have been applied (store selects the focused scene).
        XCTAssertEqual(session.state?.selection, .scene(id: scene2),
                       "Focus must still apply after stopping playback")
        XCTAssertEqual(session.state?.sceneIdAtPlayhead(), scene2,
                       "Playhead must move to the focused scene")
        #endif
    }

    /// Tapping the scene already under the playhead during playback still stops
    /// playback while preserving the no-jump focus behavior.
    func test_focusScene_sceneUnderPlayhead_duringPlayback_stopsPlayback_noJump() async {
        #if DEBUG
        let session = await makeSession()
        let (scene1, _) = loadTwoSceneProject(into: session)

        // Playhead starts at frame 0 → scene 1 is under the playhead.
        let playheadBefore = session.state?.playheadCompressedFrame
        XCTAssertEqual(session.state?.sceneIdAtPlayhead(), scene1,
                       "Pre-condition: scene 1 is under the playhead")

        let vc = EditorViewController(session: session)
        let runtime = EditorRuntime(session: session)
        runtime.bootForTesting(state: .timelinePreview)
        vc.runtime = runtime

        runtime.setPlayingForTesting(true)
        XCTAssertTrue(runtime.isPlaying)

        // Tap the scene already under the playhead.
        vc.timelineController.handleTimelineEvent(.focusScene(sceneId: scene1))

        // Playback stops regardless of which scene was tapped.
        XCTAssertFalse(runtime.isPlaying, "Scene tap during playback must stop preview")

        // No-jump behavior preserved: playhead does not move for the under-playhead scene.
        XCTAssertEqual(session.state?.playheadCompressedFrame, playheadBefore,
                       "Tapping the under-playhead scene must not move the playhead")
        XCTAssertEqual(session.state?.selection, .scene(id: scene1))
        #endif
    }

    // MARK: - playing -> scrub began responsiveness (Repair)

    /// Warm interactive pause: `stopPlayback()` silences audio synchronously
    /// (warm `pausePlaybackImmediately`) and does NOT run heavy cleanup on the
    /// immediate path. Heavy reclaim is scheduled behind a real idle window; if no
    /// interaction follows it eventually runs, ordered after the urgent stop.
    func test_stopPlayback_warmPause_defersHeavyCleanupBehindIdleWindow() async {
        #if DEBUG
        let session = await makeSession()
        _ = loadTwoSceneProject(into: session)

        let runtime = EditorRuntime(session: session)
        runtime.bootForTesting(state: .timelinePreview)

        let mockAudio = MockPreviewAudioController()
        runtime.setPreviewAudioController(mockAudio)
        runtime.idleResourceReclaimDelayNanos = 50_000_000  // 50ms
        runtime.setPlayingForTesting(true)
        runtime.resetPlaybackStopOrdering()

        runtime.stopPlayback()

        // Immediately after the synchronous warm pause: silenced, NO heavy cleanup.
        XCTAssertEqual(mockAudio.pauseImmediateCallCount, 1,
            "Warm pause must silence output via pausePlaybackImmediately")
        XCTAssertEqual(mockAudio.pauseCallCount, 0,
            "Heavy audio engine teardown must NOT run synchronously on warm pause")
        XCTAssertEqual(runtime.playbackStopOrdering.first, .urgentStop)
        XCTAssertFalse(runtime.playbackStopOrdering.contains(.heavyCleanup),
            "Heavy cleanup must not run synchronously")

        // With no interaction, idle reclaim eventually runs, ordered after urgent stop.
        await waitUntil(timeout: 1.0) { runtime.playbackStopOrdering.contains(.heavyCleanup) }
        XCTAssertEqual(mockAudio.pauseCallCount, 1,
            "Idle reclaim must perform the heavy audio engine pause exactly once")
        XCTAssertLessThan(
            runtime.playbackStopOrdering.firstIndex(of: .urgentStop) ?? .max,
            runtime.playbackStopOrdering.firstIndex(of: .heavyCleanup) ?? .min,
            "Urgent stop must be ordered before heavy cleanup")
        #endif
    }

    /// The core freeze fix: when a scrub interaction begins within the idle window
    /// after a warm pause, the heavy reclaim is CANCELLED — it must not run inside
    /// the first scrub presentation window.
    func test_stopPlayback_thenScrubBegan_cancelsHeavyCleanup() async {
        #if DEBUG
        let session = await makeSession()
        _ = loadTwoSceneProject(into: session)

        let runtime = EditorRuntime(session: session)
        runtime.bootForTesting(state: .timelinePreview)

        let mockAudio = MockPreviewAudioController()
        runtime.setPreviewAudioController(mockAudio)
        runtime.idleResourceReclaimDelayNanos = 80_000_000  // 80ms
        runtime.setPlayingForTesting(true)
        runtime.resetPlaybackStopOrdering()

        // Pause, then immediately begin a scrub (the failing user scenario).
        runtime.stopPlayback()
        runtime.setScrubInteractionActive(true)

        // Wait well past the idle delay — heavy cleanup must have been cancelled.
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(mockAudio.pauseCallCount, 0,
            "Scrub began within the idle window must cancel heavy audio reclaim")
        XCTAssertFalse(runtime.playbackStopOrdering.contains(.heavyCleanup),
            "Heavy cleanup must not run when interaction follows the warm pause")
        #endif
    }

    /// PRODUCTION ORDER (the actual failing case): `.scrub(.began)` while playing
    /// runs `setScrubInteractionActive(true)` BEFORE `stopPlayback()`, then dispatches
    /// the playhead. When the scrub begins on the CURRENT frame, the store emits no
    /// `onPlayheadChanged`, so nothing cancels reclaim via the playhead path. The
    /// runtime hard-guard must ensure no heavy reclaim is armed while scrub is active.
    func test_scrubBeganOnCurrentFrame_duringPlayback_doesNotArmHeavyCleanup() async {
        #if DEBUG
        let session = await makeSession()
        _ = loadTwoSceneProject(into: session)

        let vc = EditorViewController(session: session)
        let runtime = EditorRuntime(session: session)
        runtime.bootForTesting(state: .timelinePreview)
        let mockAudio = MockPreviewAudioController()
        runtime.setPreviewAudioController(mockAudio)
        runtime.idleResourceReclaimDelayNanos = 60_000_000  // 60ms
        vc.runtime = runtime
        runtime.setPlayingForTesting(true)

        // Scrub begins on the CURRENT playhead frame → store emits no playhead change.
        let currentFrame = session.state?.playheadCompressedFrame ?? 0
        vc.timelineController.handleTimelineEvent(
            .scrub(compressedFrame: currentFrame, phase: .began))

        XCTAssertTrue(runtime.isScrubInteractionActive,
            "Pre-condition: scrub interaction must be active after .began")
        XCTAssertFalse(runtime.isPlaying, "Scrub began during playback must stop playback")

        // Wait well past the idle delay. No heavy reclaim may run during active scrub.
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(mockAudio.pauseCallCount, 0,
            "Heavy audio engine teardown must NOT run while scrub is active (production order)")
        XCTAssertEqual(mockAudio.pauseImmediateCallCount, 1,
            "Warm pause must still have silenced audio once on scrub began")
        XCTAssertFalse(runtime.playbackStopOrdering.contains(.heavyCleanup),
            "No heavy cleanup may be recorded while scrub is active")
        #endif
    }

    /// Resuming playback within the idle window also cancels heavy reclaim.
    func test_stopPlayback_thenStartPlayback_cancelsHeavyCleanup() async {
        #if DEBUG
        let session = await makeSession()
        _ = loadTwoSceneProject(into: session)

        let runtime = EditorRuntime(session: session)
        runtime.bootForTesting(state: .timelinePreview)

        let mockAudio = MockPreviewAudioController()
        runtime.setPreviewAudioController(mockAudio)
        runtime.idleResourceReclaimDelayNanos = 80_000_000  // 80ms
        runtime.setPlayingForTesting(true)
        runtime.resetPlaybackStopOrdering()

        runtime.stopPlayback()
        // Resume quickly (no engine bound in this harness; cancellation still fires).
        runtime.setPlayingForTesting(false)
        runtime.startPlayback()

        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(mockAudio.pauseCallCount, 0,
            "Resuming playback within the idle window must cancel heavy audio reclaim")
        #endif
    }

    /// When preview is not playing, a scene tap focuses without touching playback state.
    func test_focusScene_whileStopped_focusesWithoutPlaybackChange() async {
        #if DEBUG
        let session = await makeSession()
        let (_, scene2) = loadTwoSceneProject(into: session)

        let vc = EditorViewController(session: session)
        let runtime = EditorRuntime(session: session)
        runtime.bootForTesting(state: .timelinePreview)
        vc.runtime = runtime

        XCTAssertFalse(runtime.isPlaying, "Pre-condition: preview is stopped")

        vc.timelineController.handleTimelineEvent(.focusScene(sceneId: scene2))

        XCTAssertFalse(runtime.isPlaying, "Stopped preview stays stopped")
        XCTAssertEqual(session.state?.selection, .scene(id: scene2),
                       "Focus still applies when not playing")
        #endif
    }
}
