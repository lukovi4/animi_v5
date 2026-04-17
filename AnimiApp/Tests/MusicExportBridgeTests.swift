import XCTest
import TVECore
@testable import AnimiApp

private struct StubMediaLocator: ProjectMediaLocator {
    let rootDir: URL
    func absoluteURL(for mediaRef: MediaRef, registry: ProjectAssetRegistry) async throws -> URL {
        if let path = registry.storagePath(for: mediaRef.assetId) {
            return rootDir.appendingPathComponent(path)
        }
        return rootDir.appendingPathComponent(mediaRef.storagePath)
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

/// Tests the real production export bridge (EditorRuntime.buildProjectMusicTrackConfig).
/// Uses EditorSession + EditorRuntime with stub deps to call the actual bridge method.
@MainActor
final class MusicExportBridgeTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func stubSceneLibrary() -> SceneLibrarySnapshot {
        SceneLibrarySnapshot(
            fps: 30,
            canvas: CanvasConfig(width: 1080, height: 1920),
            scenes: [
                SceneTypeDescriptor(
                    id: "scene_0",
                    order: 0,
                    title: "Test Scene",
                    baseDurationUs: 3_000_000
                )
            ]
        )
    }

    private func makeSession(draft: ProjectDraft) async -> EditorSession {
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
            loadSceneLibrary: { self.stubSceneLibrary() },
            sceneTypeDefaults: { _, _ in
                [SceneTypeDefault(sceneTypeId: "scene_0", baseDurationUs: 3_000_000)]
            },
            loadTemplateCatalog: {
                .success(TemplateCatalogSnapshot(categories: [], templates: []))
            },
            backgroundPresetProvider: StubPresetProvider()
        )
        let session = EditorSession(intent: .resumeDraft, dependencies: deps)
        await session.bootstrap()
        return session
    }

    private func makeRuntime(draft: ProjectDraft) async -> EditorRuntime {
        let session = await makeSession(draft: draft)
        let runtime = EditorRuntime(session: session)
        runtime.bootForTesting(state: .timelinePreview)
        return runtime
    }

    private func makeDraft(sceneDurations: [TimeUs]) -> ProjectDraft {
        var draft = ProjectDraft.create(origin: .template(templateId: "test-template"))
        var timeline = CanonicalTimeline.empty()
        var payloads: [UUID: TimelinePayload] = [:]
        for (index, duration) in sceneDurations.enumerated() {
            let payloadId = UUID()
            payloads[payloadId] = .scene(ScenePayload(sceneTypeId: "scene_\(index)"))
            let item = TimelineItem(payloadId: payloadId, kind: .scene, startUs: nil, durationUs: duration)
            timeline.tracks[0].items.append(item)
        }
        timeline.payloads = payloads
        draft.canonicalTimeline = timeline
        return draft
    }

    private func seedAudioFile(storagePath: String) throws {
        let fileURL = tempDir.appendingPathComponent(storagePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("stub_audio".utf8).write(to: fileURL)
    }

    private func addMusicToDraft(
        _ draft: inout ProjectDraft,
        assetId: ProjectAssetID,
        storagePath: String,
        sourceDurationUs: TimeUs = 10_000_000,
        trimStartUs: TimeUs = 0,
        trimEndUs: TimeUs = 10_000_000,
        volume: Float = 1.0
    ) {
        draft.assetRegistry.register(ProjectAssetDescriptor(
            assetId: assetId, mediaKind: .audio, storagePath: storagePath
        ))
        let audioPid = UUID()
        draft.canonicalTimeline.payloads[audioPid] = .audio(AudioPayload(
            assetRef: .imported(assetId: assetId, storagePath: storagePath),
            sourceDurationUs: sourceDurationUs,
            trimStartUs: trimStartUs,
            trimEndUs: trimEndUs,
            volume: volume
        ))
        var audioTrack = Track(kind: .audio)
        audioTrack.items.append(TimelineItem(
            payloadId: audioPid, kind: .audioClip, startUs: 0,
            durationUs: trimEndUs - trimStartUs
        ))
        draft.canonicalTimeline.tracks.append(audioTrack)
    }

    // MARK: - No Music → nil

    func testNoMusic_bridgeReturnsNil() async {
        let runtime = await makeRuntime(draft: makeDraft(sceneDurations: [3_000_000]))
        let config = await runtime.buildProjectMusicTrackConfig()
        XCTAssertNil(config)
    }

    // MARK: - Imported Music → Resolved Config with URL

    func testImportedMusic_bridgeReturnsResolvedConfig() async throws {
        let assetId = ProjectAssetID()
        let storagePath = "Media/UserMedia/\(UUID().uuidString).mp3"
        try seedAudioFile(storagePath: storagePath)

        var draft = makeDraft(sceneDurations: [5_000_000])
        addMusicToDraft(&draft, assetId: assetId, storagePath: storagePath)

        let runtime = await makeRuntime(draft: draft)
        let config = await runtime.buildProjectMusicTrackConfig()

        XCTAssertNotNil(config, "Production bridge should return config for imported music")
        XCTAssertTrue(FileManager.default.fileExists(atPath: config!.url.path),
                      "Resolved URL should point to existing file")
        XCTAssertEqual(config!.startTimeSeconds, 0.0, accuracy: 0.001)
        XCTAssertEqual(config!.volume, 1.0)
    }

    // MARK: - Trim + Volume Map Through Production Bridge

    func testTrimAndVolume_mapThroughProductionBridge() async throws {
        let assetId = ProjectAssetID()
        let storagePath = "Media/UserMedia/\(UUID().uuidString).mp3"
        try seedAudioFile(storagePath: storagePath)

        var draft = makeDraft(sceneDurations: [5_000_000])
        addMusicToDraft(
            &draft, assetId: assetId, storagePath: storagePath,
            sourceDurationUs: 10_000_000,
            trimStartUs: 2_000_000, trimEndUs: 8_000_000,
            volume: 0.6
        )

        let runtime = await makeRuntime(draft: draft)
        let config = await runtime.buildProjectMusicTrackConfig()!

        XCTAssertEqual(config.trimStartSeconds!, 2.0, accuracy: 0.001)
        XCTAssertEqual(config.trimEndSeconds!, 8.0, accuracy: 0.001)
        XCTAssertEqual(config.volume, 0.6)
        XCTAssertEqual(config.startTimeSeconds, 0.0, accuracy: 0.001)
    }

    // MARK: - Missing Registry → nil

    func testMissingRegistry_bridgeReturnsNil() async {
        var draft = makeDraft(sceneDurations: [5_000_000])
        // Add music but do NOT register asset or seed file
        let audioPid = UUID()
        draft.canonicalTimeline.payloads[audioPid] = .audio(AudioPayload(
            assetRef: .imported(assetId: ProjectAssetID(), storagePath: ""),
            sourceDurationUs: 10_000_000, trimStartUs: 0, trimEndUs: 10_000_000, volume: 1.0
        ))
        var audioTrack = Track(kind: .audio)
        audioTrack.items.append(TimelineItem(
            payloadId: audioPid, kind: .audioClip, startUs: 0, durationUs: 10_000_000
        ))
        draft.canonicalTimeline.tracks.append(audioTrack)

        let runtime = await makeRuntime(draft: draft)
        let config = await runtime.buildProjectMusicTrackConfig()
        XCTAssertNil(config, "Bridge should return nil when asset is not in registry")
    }

    // MARK: - Item Start Time Maps Correctly

    func testItemStartTime_mapsToConfig() async throws {
        let assetId = ProjectAssetID()
        let storagePath = "Media/UserMedia/\(UUID().uuidString).mp3"
        try seedAudioFile(storagePath: storagePath)

        var draft = makeDraft(sceneDurations: [5_000_000])
        addMusicToDraft(&draft, assetId: assetId, storagePath: storagePath)

        let runtime = await makeRuntime(draft: draft)
        let config = await runtime.buildProjectMusicTrackConfig()!

        // V1: music starts at 0
        XCTAssertEqual(config.startTimeSeconds, 0.0, accuracy: 0.001)
    }
}
