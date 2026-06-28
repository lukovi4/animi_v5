import XCTest
import TVECore
import AnimiEngineCore
@testable import AnimiApp

/// Slice-005 Stage C.5 fixes — real source-duration descriptors (blocker 1) + outward coverage
/// projection that never shrinks app intervals (blocker 2).
@MainActor
final class RuntimeCanonicalAudioPlanSourceTests: XCTestCase {

    // MARK: - Blocker 1: real source duration (not synthesized 1/1)

    private func manifest(sourceRaw: String) throws -> AudioManifest {
        let sid = try AudioSourceID(sourceRaw)
        return AudioManifest(
            sources: [AudioSourceEntry(id: sid, asset: .globalAudio(try GlobalAudioAssetID("g")))],
            tracks: [AudioTrackEntry(id: try AudioTrackID("t"), role: .music)],
            clips: [AudioClipEntry(
                id: try AudioClipID("c"), trackID: try AudioTrackID("t"), sourceID: sid, videoLayer: nil,
                destination: try ProjectTimeRange(start: .zero, end: try ProjectTime(ticks: 240_000)),
                sourceTrim: try RationalSourceRange(start: .zero, end: try RationalSourceTime(numerator: 1, denominator: 1)),
                gain: .unity, isMuted: false, playbackPolicy: .once)])
    }

    func testDescriptorUsesRealSourceDurationNotOneOverOne() throws {
        let m = try manifest(sourceRaw: "app.audio.source.imported:abc")
        // sourceDurationUs = 3_333_333 µs (a real, non-1s, non-grid duration).
        let descriptors = try RuntimeCanonicalAudioPlanSource.makeDescriptors(
            for: m, durationUsBySource: ["app.audio.source.imported:abc": 3_333_333])
        XCTAssertEqual(descriptors.count, 1)
        let d = descriptors.first!
        // Exact rational seconds 3_333_333 / 1_000_000 (auto-reduced) — NOT 1/1.
        XCTAssertEqual(d.sourceDuration, try RationalSourceTime(numerator: 3_333_333, denominator: 1_000_000))
        XCTAssertNotEqual(d.sourceDuration, try RationalSourceTime(numerator: 1, denominator: 1),
            "duration must be the real source duration, not a synthesized 1/1")
        XCTAssertEqual(d.sampleRate, 48_000, "renderer output domain is 48 kHz mono")
        XCTAssertEqual(d.channelLayout, .mono)
    }

    func testDescriptorRealDurationExactForVariousValues() throws {
        for us: Int64 in [500_000, 1_500_000, 2_000_001, 44_100] {
            let m = try manifest(sourceRaw: "s")
            let d = try RuntimeCanonicalAudioPlanSource.makeDescriptors(
                for: m, durationUsBySource: ["s": us]).first!
            XCTAssertEqual(d.sourceDuration, try RationalSourceTime(numerator: us, denominator: 1_000_000),
                "duration \(us)µs maps to exact rational seconds")
        }
    }

    func testDescriptorMissingDurationFailsClosed() throws {
        let m = try manifest(sourceRaw: "s")
        XCTAssertThrowsError(try RuntimeCanonicalAudioPlanSource.makeDescriptors(
            for: m, durationUsBySource: [:])) { error in
            guard case .mediaUnsupported? = error as? AppRealtimeAudioIntegrationError else {
                return XCTFail("expected mediaUnsupported, got \(error)")
            }
        }
    }

    // MARK: - Bundled audio resolves to a Bundle URL or fails visibly (no silent drop)

    func testBundledAudioUnknownIdReturnsNilForVisibleFailure() {
        // A bundled id that is not in the app/test bundle returns nil → the plan source throws a typed
        // `audioAssetUnresolvable` (which triggers the legacy fallback), never a silent drop.
        XCTAssertNil(RuntimeCanonicalAudioPlanSource.bundledResourceURL(id: "definitely-not-a-bundled-sound-xyz"))
    }

    // MARK: - Blocker 2: shared outward projection never shrinks app intervals

    func testProjectionFloorStartCeilEnd() {
        // 1 µs → ticks: floor(1*6/25)=0, ceil(1*6/25)=1.
        XCTAssertEqual(Slice005TickProjection.floorTicks(1), 0)
        XCTAssertEqual(Slice005TickProjection.ceilTicks(1), 1)
    }

    func testGridAlignedProjectionUnchanged() {
        // 1_000_000 µs = 1 s = exactly 240_000 ticks: floor == ceil == exact (no widening).
        XCTAssertEqual(Slice005TickProjection.floorTicks(1_000_000), 240_000)
        XCTAssertEqual(Slice005TickProjection.ceilTicks(1_000_000), 240_000)
    }

    func testCeilNeverShrinksBelowFloorForSameMicros() {
        for us: Int64 in [1, 7, 100, 500_111, 3_333_333, 999_999] {
            let f = Slice005TickProjection.floorTicks(us)!
            let c = Slice005TickProjection.ceilTicks(us)!
            XCTAssertGreaterThanOrEqual(c, f, "ceil >= floor for \(us)")
            // ceil covers the exact value: c*25 >= us*6 (no shrink).
            XCTAssertGreaterThanOrEqual(c * 25, us * 6, "ceil-end covers the exact µs end for \(us)")
        }
    }

    /// The core no-shrink guarantee: a project whose duration ends at a non-grid `endUs` (coverage = ceil)
    /// covers an audio destination ending at the same `endUs` (destination end = ceil). Same policy →
    /// project coverage end == audio destination end → no tail truncation.
    func testProjectCoverageCoversAudioTailAtSameEnd() throws {
        let endUs: Int64 = 3_833_444   // non-25µs-aligned project/audio end
        // Audio destination end (AppAudioManifestBridge uses ceil): build via the manifest bridge.
        let manifest = try AppAudioManifestBridge.buildManifest(
            items: [.init(index: 0, startUs: 0, durationUs: endUs,
                          payload: AudioPayload(assetRef: .bundled(id: "a"), sourceDurationUs: endUs,
                                                trimStartUs: 0, trimEndUs: endUs, volume: 1.0, role: .music))],
            includeOriginalFromVideoSlots: false)
        let audioEnd = manifest.clips.first!.destination.end.ticks
        // Project coverage end uses the SAME ceil policy for the scene duration.
        let coverageEnd = Slice005TickProjection.ceilTicks(endUs)!
        XCTAssertEqual(coverageEnd, audioEnd, "project coverage end == audio destination end (no shrink)")
        XCTAssertGreaterThanOrEqual(coverageEnd, audioEnd, "coverage never shorter than the audio tail")
    }

    // MARK: - Production-path: real EditorState, scene state keyed by item.id (NOT payloadId)

    /// Build a real `EditorRuntime` whose single scene carries one user video block under
    /// `sceneInstanceStates[item.id]` (the scene INSTANCE id, distinct from `payloadId`). The injected
    /// `resolveURL` returns a fixture URL so the synchronous path resolves without disk.
    private func makeRuntimeWithVideoBlock(
        visibility: Bool, blockID: String = "block_01",
        trimStart: Double = 0, trimEnd: Double = 3, volume: Float = 1, isMuted: Bool = false,
        sceneDurationUs: Int64 = 3_000_000
    ) async throws -> (EditorRuntime, RuntimeCanonicalAudioPlanSource) {
        let deps = EditorSessionDependencies(
            saveActiveDraft: { _ in }, loadActiveDraft: { nil }, deleteActiveDraft: {},
            loadSavedProject: { _ in nil }, materializeSavedProject: { $0 },
            mediaLocator: PlanSrcStubMediaLocator(), mediaWriter: PlanSrcStubMediaWriter(),
            loadSceneLibrary: {
                SceneLibrarySnapshot(fps: 30, canvas: CanvasConfig(width: 1080, height: 1920),
                    scenes: [SceneTypeDescriptor(id: "scene_1", order: 0, title: "T", baseDurationUs: sceneDurationUs)])
            },
            sceneTypeDefaults: { _, _ in [SceneTypeDefault(sceneTypeId: "scene_1", baseDurationUs: sceneDurationUs)] },
            loadTemplateCatalog: { .success(TemplateCatalogSnapshot(categories: [], templates: [])) },
            backgroundPresetProvider: PlanSrcStubPresetProvider())
        let session = EditorSession(intent: .template(templateId: "t"), dependencies: deps)
        await session.bootstrap()

        // Read the REAL scene instance id bootstrap produced (item.id of the seeded scene; ≠ payloadId), and
        // register a video asset + attach the video slot via the PRODUCTION `setMediaSlot` action. This keys
        // the slot under the live scene INSTANCE id — exercising the `item.id` lookup the fix depends on.
        let item = try XCTUnwrap(session.state?.canonicalTimeline.sceneItems.first, "bootstrap seeds one scene")
        XCTAssertNotEqual(item.id, item.payloadId, "precondition: scene item id != payloadId")
        let assetId = ProjectAssetID()
        session.registerAssetBookkeeping(ProjectAssetDescriptor(
            assetId: assetId, mediaKind: .video, storagePath: "video/\(blockID).mov"))
        let slot = SceneMediaSlot(
            visibility: visibility,
            asset: .video(
                mediaRef: MediaRef(storagePath: "video/\(blockID).mov", mediaKind: .video, assetId: assetId),
                placement: MediaPlacementState.defaultCover,
                videoWindow: PersistedVideoSelection(trimStart: trimStart, trimEnd: trimEnd, isMuted: isMuted, volume: volume)))
        session.dispatch(.setMediaSlot(sceneInstanceId: item.id, blockId: blockID, slot: slot))

        // Assert the slot landed in live state (catches any bootstrap/timeline mismatch at SETUP, so a
        // failure is a clear setup error here — not a confusing nil from currentAudioPlan downstream).
        let landed = session.state?.draft.sceneInstanceStates[item.id]?.mediaSlotsByBlockId?[blockID]
        XCTAssertNotNil(landed, "video slot must be present in live state under scene instance \(item.id)")
        XCTAssertEqual(landed?.visibility, visibility, "slot visibility preserved")

        let runtime = EditorRuntime(session: session)
        runtime.audioSessionManager = MockPreviewAudioSessionManager()
        runtime.bootForTesting(state: .timelinePreview)
        // Inject a resolver that returns a fixture URL for the video asset (no disk dependency).
        let planSource = RuntimeCanonicalAudioPlanSource(
            runtime: runtime, resolveURL: { _, _, _ in URL(fileURLWithPath: "/tmp/fixture.mov") })
        return (runtime, planSource)
    }

    /// #1: with `item.id != payloadId`, a VIDEO-ONLY project produces a NON-EMPTY plan with a videoLayer
    /// segment. (Under the old `payloadId` keying this returned nil/silent — the regression guard.)
    func test_videoOnly_realState_itemIdKeying_producesNonEmptyVideoLayerPlan() async throws {
        // RETAIN the runtime through the whole call: `RuntimeCanonicalAudioPlanSource.runtime` is `weak`, so
        // discarding it would let it deallocate before `currentAudioPlan()` (→ `guard let runtime` → nil).
        let (runtime, planSource) = try await makeRuntimeWithVideoBlock(visibility: true)
        let plan = try planSource.currentAudioPlan()
        let segments = try XCTUnwrap(plan).segments
        XCTAssertFalse(segments.isEmpty, "video-only project (item.id keying) must produce a non-empty plan")
        XCTAssertTrue(segments.contains { $0.role == .videoLayer }, "a videoLayer segment is present")
        withExtendedLifetime(runtime) {}   // keep `runtime` alive until after the plan evaluation above
    }

    /// #2: a HIDDEN video slot contributes NO audio (no videoLayer clip/segment) → silent.
    func test_hiddenVideoSlot_producesNoVideoLayerAudio() async throws {
        let (runtime, planSource) = try await makeRuntimeWithVideoBlock(visibility: false)
        let plan = try planSource.currentAudioPlan()
        // No global audio + only a hidden video → genuinely silent (nil) OR a plan with no videoLayer segment.
        if let segments = plan?.segments {
            XCTAssertFalse(segments.contains { $0.role == .videoLayer }, "hidden video must not produce videoLayer audio")
        }
        withExtendedLifetime(runtime) {}
    }

    // MARK: - Stage-7 S6: cumulative scene destination ticks are CHECKED + fail-closed (no silent -1/0)

    private func sceneItem(durationUs: Int64) -> TimelineItem {
        TimelineItem(payloadId: UUID(), kind: .scene, durationUs: durationUs)
    }

    /// Normal case: spans accumulate with the `max(1, ceilTicks)` basis exactly like the media-active domain.
    /// The known S6 repro: a non-tick-aligned scene-0 (8_766_667 µs) → ceil 2_104_001; scene-1 start == that.
    func test_cumulativeSceneDestinationTicks_matchesCeilSumDomainBasis() throws {
        let items = [sceneItem(durationUs: 8_766_667), sceneItem(durationUs: 5_000_000)]
        let spans = try RuntimeCanonicalAudioPlanSource.cumulativeSceneDestinationTicks(items)
        XCTAssertEqual(spans.count, 2)
        // scene-0: [0, ceil(8_766_667)) = [0, 2_104_001)
        XCTAssertEqual(spans[0].start, 0)
        XCTAssertEqual(spans[0].end, 2_104_001)
        // scene-1 start == Σ preceding ceil == 2_104_001 (the domain.start the validator compares against).
        XCTAssertEqual(spans[1].start, 2_104_001, "scene-1 start == Σ ceilTicks(preceding), the domain basis")
        XCTAssertEqual(spans[1].end, 2_104_001 + 1_200_000, "scene-1 end == start + ceil(5_000_000)")
    }

    /// A zero-duration scene still gets a `max(1, ...)` span (mirrors the manifest's `nominalDuration`); never 0.
    func test_cumulativeSceneDestinationTicks_zeroDurationGetsMinimumOneTick() throws {
        let spans = try RuntimeCanonicalAudioPlanSource.cumulativeSceneDestinationTicks([sceneItem(durationUs: 0)])
        XCTAssertEqual(spans[0].start, 0)
        XCTAssertEqual(spans[0].end, 1, "zero-duration scene → span clamped to 1 tick, not 0")
    }

    /// FAIL-CLOSED on overflow: a duration whose `ceilTicks` overflows must throw `.anchorArithmeticOverflow`,
    /// NOT silently become -1/0 (the audit blocker). `Int64.max` µs overflows `us·6` in the projection.
    func test_cumulativeSceneDestinationTicks_overflowFailsClosed() {
        let items = [sceneItem(durationUs: Int64.max)]
        XCTAssertThrowsError(try RuntimeCanonicalAudioPlanSource.cumulativeSceneDestinationTicks(items)) { error in
            guard case .anchorArithmeticOverflow? = error as? AppRealtimeAudioIntegrationError else {
                return XCTFail("expected .anchorArithmeticOverflow, got \(error)")
            }
        }
    }

    /// FAIL-CLOSED on a CUMULATIVE add overflow: many large (but individually projectable) scenes whose tick
    /// sum overflows Int64 must throw at the `addingReportingOverflow`, never wrap. Each scene's tick span is
    /// `~0.24·durationUs`; with `durationUs` near the per-scene projection ceiling, enough scenes overflow the
    /// running total. This proves the cumulative add is checked (the audit's "acc += unchecked" concern).
    func test_cumulativeSceneDestinationTicks_cumulativeAddOverflowFailsClosed() {
        // Largest durationUs that still projects (us·6 must not overflow): Int64.max/6.
        let maxProjectableUs = Int64.max / 6                 // ceilTicks(this) ≈ 0.24·that ≈ 3.69e17 ticks
        // Three such spans (~1.1e18 ticks) stay under Int64.max individually, but ~25 of them overflow the sum.
        let items = Array(repeating: sceneItem(durationUs: maxProjectableUs), count: 30)
        XCTAssertThrowsError(try RuntimeCanonicalAudioPlanSource.cumulativeSceneDestinationTicks(items)) { error in
            guard case .anchorArithmeticOverflow? = error as? AppRealtimeAudioIntegrationError else {
                return XCTFail("expected .anchorArithmeticOverflow on cumulative add, got \(error)")
            }
        }
    }
}

// MARK: - Local stubs

private struct PlanSrcStubMediaLocator: ProjectMediaLocator {
    func absoluteURL(for mediaRef: MediaRef, registry: ProjectAssetRegistry) async throws -> URL {
        URL(fileURLWithPath: "/tmp/stub")
    }
}
private struct PlanSrcStubMediaWriter: ProjectMediaWriteGateway {
    func saveBackgroundImage(from preparedFileURL: URL) async throws -> (MediaRef, URL) {
        (MediaRef(storagePath: "s.jpg"), URL(fileURLWithPath: "/tmp/stub"))
    }
    func saveUserMedia(from fileURL: URL, mediaKind: MediaKind, filename: String) async throws -> (MediaRef, URL) {
        (MediaRef(storagePath: "s.jpg"), URL(fileURLWithPath: "/tmp/stub"))
    }
    func deleteMediaFile(_ mediaRef: MediaRef) async throws {}
    func duplicateAssets(inDraft sourceDraft: ProjectDraft) async throws -> ProjectDraft { sourceDraft }
}
private struct PlanSrcStubPresetProvider: BackgroundPresetProviding {
    func loadFromBundle() throws {}
    func preset(for presetId: String) -> BackgroundPreset? { nil }
    func presetOrFallback(for presetId: String) -> BackgroundPreset? { nil }
    var allPresets: [BackgroundPreset] { [] }
    var count: Int { 0 }
}
