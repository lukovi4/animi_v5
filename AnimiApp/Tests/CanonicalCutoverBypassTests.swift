import XCTest
import Metal
import AVFoundation
import TVECore
import AnimiEngineCore
@testable import AnimiApp

// MARK: - Local stubs (private to this file; other test files have their own private copies)

private struct CutoverStubMediaLocator: ProjectMediaLocator {
    func absoluteURL(for mediaRef: MediaRef, registry: ProjectAssetRegistry) async throws -> URL {
        URL(fileURLWithPath: "/tmp/stub")
    }
}

private struct CutoverStubMediaWriter: ProjectMediaWriteGateway {
    func saveBackgroundImage(from preparedFileURL: URL) async throws -> (MediaRef, URL) {
        (MediaRef(storagePath: "stub.jpg"), URL(fileURLWithPath: "/tmp/stub"))
    }
    func saveUserMedia(from fileURL: URL, mediaKind: MediaKind, filename: String) async throws -> (MediaRef, URL) {
        (MediaRef(storagePath: "stub.jpg"), URL(fileURLWithPath: "/tmp/stub"))
    }
    func deleteMediaFile(_ mediaRef: MediaRef) async throws {}
    func duplicateAssets(inDraft sourceDraft: ProjectDraft) async throws -> ProjectDraft { sourceDraft }
}

private struct CutoverStubPresetProvider: BackgroundPresetProviding {
    func loadFromBundle() throws {}
    func preset(for presetId: String) -> BackgroundPreset? { nil }
    func presetOrFallback(for presetId: String) -> BackgroundPreset? { nil }
    var allPresets: [BackgroundPreset] { [] }
    var count: Int { 0 }
}

/// Slice-005 cutover — proof at the COORDINATOR seam (not just the controller) that when
/// `DebugPreviewAudioWithNextEngine` is ON the canonical controller is driven DIRECTLY from the playhead,
/// the legacy build gate (`buildPipeline`/`buildAudioExportPlan`) is NOT executed on the canonical path,
/// and toggle OFF keeps the legacy build path byte-for-byte. Also: the lazy controller stale-cache is gone.
@MainActor
final class CanonicalCutoverBypassTests: XCTestCase {

    private let toggleKey = "DebugPreviewAudioWithNextEngine"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: toggleKey)
        super.tearDown()
    }

    // MARK: - Fakes for a real (factory-assembled) CanonicalPreviewAudioController

    private final class RecordingSink: PreviewAudioOutputSink, @unchecked Sendable {
        func configure(outputFormat: AudioOutputFormat, route: AudioOutputRoute) throws {}
        func scheduleMixed(range: AudioSampleRange, samples: [Float32], at outputSampleTime: Int64) throws {}
    }

    private final class FakeSession: AudioSessionAdapter, @unchecked Sendable {
        private(set) var isActive = false
        private let q: AudioOutputQuery
        init(query: AudioOutputQuery) { self.q = query }
        func activate() throws { isActive = true }
        func deactivate() throws { isActive = false }
        func queryActualOutput() throws -> AudioOutputQuery {
            guard isActive else { throw RealtimeAudioBoundaryError.queryBeforeActivation }
            return q
        }
    }

    private final class FixtureRenderPipeline: CanonicalAudioRenderPipeline, @unchecked Sendable {
        func prepareInitialPreroll(
            _ request: CanonicalAudioRenderRequest,
            onDiagnostic: (@MainActor (_ event: String, _ detail: String) -> Void)?
        ) async throws -> [PreviewMixSource] {
            let count = Int(request.range.sampleCount)
            var reqAlloc = MonotonicRequestIDAllocator()
            let buffer = try PreparedAudioBuffer(
                revision: request.revision,
                epoch: request.epoch,
                request: reqAlloc.nextAudioRequest(),
                sourceID: try AudioSourceID("s0"),
                chunkRange: request.range,
                streamIdentity: try AudioStreamIdentity("stream-0"),
                sourceSampleRate: 48_000,
                channelLayout: .mono,
                isMuted: false,
                gain: .unity,
                payload: try PreparedAudioPayloadHandle(identifier: "fixture-render:s0"))
            return [PreviewMixSource(buffer: buffer, samples: Array(repeating: 0.25, count: count))]
        }
    }

    private final class FakePlanSource: ProductionPreviewAudioPlanSource {
        let plan: AudioPlan?
        init(plan: AudioPlan?) { self.plan = plan }
        func currentAudioPlan() throws -> AudioPlan? { plan }
    }

    private func query() throws -> AudioOutputQuery {
        AudioOutputQuery(format: try AudioOutputFormat(sampleRate: 48_000, channelLayout: .stereo),
                         route: try AudioOutputRoute(identifier: "speaker"))
    }

    private func musicPlan() throws -> AudioPlan {
        let interval = try AudioSampleRange.from(projectTicks:
            ProjectTimeRange(start: .zero, end: try ProjectTime(ticks: 8 * AudioSampleGrid.ticksPerSample)))
        let seg = AudioSegmentPlan(
            clipID: try AudioClipID("c0"), sourceID: try AudioSourceID("s0"), trackID: try AudioTrackID("t0"),
            role: .music, destinationSamples: interval, sourceStart: .zero,
            sourceEnd: try RationalSourceTime(numerator: 1, denominator: 1),
            effectiveTrim: try RationalSourceRange(start: .zero, end: try RationalSourceTime(numerator: 1, denominator: 1)),
            isMuted: false, gain: .unity, sourceSampleRate: 48_000, channelLayout: .mono,
            streamIdentity: try AudioStreamIdentity("stream-0"), sceneID: nil)
        return AudioPlan(sampleInterval: interval, segments: [seg])
    }

    private func makeCanonical(plan: AudioPlan?) throws -> CanonicalPreviewAudioController {
        return CanonicalPreviewAudioControllerFactory.makeController(
            planSource: FakePlanSource(plan: plan),
            sink: RecordingSink(),
            adapter: try FakeSession(query: query()),
            renderPipeline: FixtureRenderPipeline())
    }

    private func makeRuntime() async -> EditorRuntime {
        let deps = EditorSessionDependencies(
            saveActiveDraft: { _ in }, loadActiveDraft: { nil }, deleteActiveDraft: {},
            loadSavedProject: { _ in nil }, materializeSavedProject: { $0 },
            mediaLocator: CutoverStubMediaLocator(), mediaWriter: CutoverStubMediaWriter(),
            loadSceneLibrary: {
                SceneLibrarySnapshot(fps: 30, canvas: CanvasConfig(width: 1080, height: 1920),
                    scenes: [SceneTypeDescriptor(id: "scene_1", order: 0, title: "T", baseDurationUs: 3_000_000)])
            },
            sceneTypeDefaults: { _, _ in [SceneTypeDefault(sceneTypeId: "scene_1", baseDurationUs: 3_000_000)] },
            loadTemplateCatalog: { .success(TemplateCatalogSnapshot(categories: [], templates: [])) },
            backgroundPresetProvider: CutoverStubPresetProvider())
        let session = EditorSession(intent: .template(templateId: "tpl_1"), dependencies: deps)
        await session.bootstrap()
        let runtime = EditorRuntime(session: session)
        runtime.audioSessionManager = MockPreviewAudioSessionManager()
        runtime.bootForTesting(state: EditorRuntimeState.timelinePreview)
        return runtime
    }

    // MARK: - ACCEPTANCE 1+2: toggle ON drives canonical.startPlayback directly, NO legacy build gate

    func test_toggleON_callsCanonicalStartPlaybackDirectly_withoutLegacyBuildGate() async throws {
        UserDefaults.standard.set(true, forKey: toggleKey)
        let runtime = await makeRuntime()

        // Spy: if the legacy build path runs, this injected builder is invoked. It must NOT be.
        var legacyBuilderInvoked = false
        runtime.previewAudioPipelineBuilder = { legacyBuilderInvoked = true; return nil }

        // Install a REAL canonical controller (with a non-empty plan) as the active preview-audio controller.
        let canonical = try makeCanonical(plan: try musicPlan())
        runtime.setPreviewAudioController(canonical)

        // Drive the playback entry directly.
        runtime.previewAudio.startForTimelinePlayback()

        // Canonical PHASE 1 ran (epoch prepared, awaiting the first-frame barrier) — proof startPlayback was
        // called on the canonical controller straight from the playhead.
        #if DEBUG
        XCTAssertTrue(canonical.hasPendingSessionAwaitingFirstFrame,
            "toggle ON must call CanonicalPreviewAudioController.startPlayback directly (epoch pending)")
        #endif
        XCTAssertFalse(legacyBuilderInvoked,
            "legacy build gate (buildPipeline/buildAudioExportPlan) must NOT run on the canonical path")

        // Drain the async preroll render, then the first-frame barrier crosses the
        // canonical start (the render path delivers the frame signal on device).
        #if DEBUG
        for _ in 0..<200 { if !canonical.hasInFlightPrerollTask { break }; await Task.yield() }
        #endif
        canonical.signalFirstFrameReady()
        XCTAssertNotNil(canonical.activeSession, "first frame starts the canonical session")
    }

    // MARK: - ACCEPTANCE 1+2 (PRODUCTION selection): toggle ON, NO injection → coordinator selects canonical
    //         and takes the direct branch; legacy builder never runs.

    /// Closes the exact PRODUCTION path: `toggle ON → selectControllerForToggle() → canonical direct start →
    /// no buildPipeline/buildAudioExportPlan`. Unlike the injected variant, the controller here is built by
    /// the coordinator itself (production `makeDefaultController`), so this proves the real selection seam.
    func test_toggleON_productionSelection_directBranch_noLegacyBuilder() async throws {
        UserDefaults.standard.set(true, forKey: toggleKey)
        let runtime = await makeRuntime()

        // Spy: flips ONLY if the legacy build path (buildPipeline → builder) runs. It must NOT.
        var legacyBuilderInvoked = false
        runtime.previewAudioPipelineBuilder = { legacyBuilderInvoked = true; return nil }

        // NO setPreviewAudioController — the coordinator must SELECT canonical itself at start time.
        XCTAssertFalse(runtime.previewAudio.controller is CanonicalPreviewAudioController,
            "precondition: starts as the cheap legacy default before selection")

        runtime.previewAudio.startForTimelinePlayback()
        // Give any (erroneously scheduled) legacy orchestration task a chance to run — it must not exist.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(runtime.previewAudio.controller is CanonicalPreviewAudioController,
            "toggle ON selects the canonical controller via selectControllerForToggle()")
        XCTAssertFalse(legacyBuilderInvoked,
            "canonical direct branch runs BEFORE the legacy build gate — buildPipeline/buildAudioExportPlan never run")
    }

    // MARK: - ACCEPTANCE 3: toggle OFF keeps the legacy build path (build gate runs, no canonical)

    func test_toggleOFF_runsLegacyBuildPath_unchanged() async throws {
        UserDefaults.standard.set(false, forKey: toggleKey)
        let runtime = await makeRuntime()

        var legacyBuilderInvoked = false
        runtime.previewAudioPipelineBuilder = { legacyBuilderInvoked = true; return nil }

        let mock = MockPreviewAudioController()
        runtime.setPreviewAudioController(mock)

        runtime.previewAudio.startForTimelinePlayback()
        // Allow the orchestration task (build) to run.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(legacyBuilderInvoked, "toggle OFF must run the legacy build path (gate executes)")
    }

    // MARK: - ACCEPTANCE: lazy controller stale-cache is impossible (selection reflects the toggle at start)

    func test_noLazyStaleCache_selectionReflectsToggleAtStart() async throws {
        // Toggle ON, but NO explicit injection → the coordinator must select canonical at start time, not
        // cache a legacy controller from an earlier (toggle-OFF) access.
        UserDefaults.standard.set(false, forKey: toggleKey)
        let runtime = await makeRuntime()
        // Touch the controller while OFF (this used to lazily cache legacy forever).
        _ = runtime.previewAudio.controller
        XCTAssertTrue(runtime.previewAudio.controller is EnginePreviewAudioPlaybackController)

        // Flip ON and enter the start path: selection must now yield canonical.
        UserDefaults.standard.set(true, forKey: toggleKey)
        runtime.previewAudio.startForTimelinePlayback()
        XCTAssertTrue(runtime.previewAudio.controller is CanonicalPreviewAudioController,
            "selection must reflect the CURRENT toggle at start — no stale lazy legacy cache")
    }

    // MARK: - Injected controller is never clobbered by toggle reselection

    func test_injectedControllerNotClobberedByReselection() async throws {
        UserDefaults.standard.set(true, forKey: toggleKey)
        let runtime = await makeRuntime()
        let mock = MockPreviewAudioController()
        runtime.setPreviewAudioController(mock)
        runtime.previewAudio.startForTimelinePlayback()
        XCTAssertTrue(runtime.previewAudio.controller === mock,
            "a test-injected controller must survive toggle-driven reselection")
    }

    // MARK: - Stage 4 STRUCTURAL: canonical start needs no BuiltAudioPipeline; export symbols intact

    /// The canonical controller starts via `startPlayback` directly — it needs NO `BuiltAudioPipeline` and
    /// NO `replacePipeline` to begin an epoch. (No fake pipeline, no `primeForDirectStart`.) A real canonical
    /// controller, driven straight, reaches a pending session purely from its own plan source.
    func test_canonicalStartsWithoutBuiltAudioPipeline() async throws {
        UserDefaults.standard.set(true, forKey: toggleKey)
        let runtime = await makeRuntime()
        let canonical = try makeCanonical(plan: try musicPlan())
        runtime.setPreviewAudioController(canonical)
        runtime.previewAudio.startForTimelinePlayback()   // no pipeline built/installed
        #if DEBUG
        XCTAssertTrue(canonical.hasPendingSessionAwaitingFirstFrame,
            "canonical reached a pending session with NO BuiltAudioPipeline / replacePipeline")
        #endif
        withExtendedLifetime(runtime) {}
    }

    /// Structural source-scan: the coordinator's canonical DIRECT-START branch bypasses the legacy gate, and
    /// the legacy `buildAudioExportPlan` is confined to `buildPipeline` (the toggle-OFF/fallback path) — the
    /// canonical branch returns before `startBuild`. Also confirms `primeForDirectStart` is absent entirely.
    func test_structural_canonicalBranchBypassesLegacyGate_andNoPrimeForDirectStart() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/EditorRuntime/EditorRuntimePreviewAudioCoordinator.swift")
            .standardizedFileURL
        let raw = try String(contentsOf: url, encoding: .utf8)
        // Strip line comments so prose mentioning a symbol doesn't false-positive.
        let src = raw.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if let r = line.range(of: "//") { return String(line[line.startIndex..<r.lowerBound]) }
            return String(line)
        }.joined(separator: "\n")

        XCTAssertTrue(src.contains("legacyGateBypassed"), "canonical direct-start branch present")
        XCTAssertTrue(src.contains("controller.startPlayback(fromSeconds: seconds"),
            "canonical branch calls startPlayback directly")
        XCTAssertFalse(src.contains("primeForDirectStart"), "no primeForDirectStart anywhere")
        // `buildAudioExportPlan` may appear ONCE (legacy buildPipeline); it must NOT be inside the canonical
        // branch. The canonical branch ends with `return` before any build path — assert the bypass `return`
        // precedes the first `buildAudioExportPlan` reference.
        if let bypassIdx = src.range(of: "legacyGateBypassed")?.lowerBound,
           let buildIdx = src.range(of: "buildAudioExportPlan")?.lowerBound {
            XCTAssertTrue(bypassIdx < buildIdx,
                "canonical bypass branch precedes (and returns before) the legacy buildAudioExportPlan path")
        }
    }

    /// Read-only export non-regression: the export-side audio builder symbols still exist and are NOT used by
    /// the preview canonical path. (We only assert presence — Stage 4 does not touch export.)
    func test_exportSymbolsUnchanged_readOnly() throws {
        let coordURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/EditorRuntime/EditorRuntimePreviewAudioCoordinator.swift")
            .standardizedFileURL
        let src = try String(contentsOf: coordURL, encoding: .utf8)
        // The legacy build path (used by toggle OFF + fallback + the export plan source) is still present.
        XCTAssertTrue(src.contains("AudioCompositionBuilder"), "legacy/export builder retained for OFF/fallback")
        XCTAssertTrue(src.contains("buildAudioExportPlan"), "export plan call retained for the legacy path")
    }
}
