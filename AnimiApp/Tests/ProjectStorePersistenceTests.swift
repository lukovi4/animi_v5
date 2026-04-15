import XCTest
import TVECore
@testable import AnimiApp

/// Disk-roundtrip tests for ProjectStore + SavedProjectRecord + ActiveDraftSlot (v9 schema).
/// Validates current-schema persistence contract with SavedProjects API.
final class ProjectStorePersistenceTests: XCTestCase {

    private var store: ProjectStore!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = ProjectStore(rootDirectoryURL: tempDir)
        try! store.ensureDirectoriesExist()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        store = nil
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Helper

    /// Builds a maximally-populated ProjectDraft exercising all payload discriminators,
    /// background region types, scene instance state fields, and transition slots.
    private func makeFullDraft(origin: ProjectOrigin, projectId: UUID) -> ProjectDraft {
        // Fixed whole-second dates (ISO8601 safe)
        let created = Date(timeIntervalSince1970: 1705312800) // 2024-01-15T12:00:00Z
        let updated = Date(timeIntervalSince1970: 1705316400) // 2024-01-15T13:00:00Z

        // --- Timeline ---
        var timeline = CanonicalTimeline.empty()
        var payloads: [UUID: TimelinePayload] = [:]

        // Scene sequence track (3 scenes)
        let scenePayloadIds = (0..<3).map { _ in UUID() }
        for (i, pid) in scenePayloadIds.enumerated() {
            payloads[pid] = .scene(ScenePayload(sceneTypeId: "scene_type_\(i)"))
            let item = TimelineItem(
                payloadId: pid,
                kind: .scene,
                startUs: nil,
                durationUs: 2_000_000
            )
            timeline.tracks[0].items.append(item)
        }

        // Audio track (1 clip)
        let audioPayloadId = UUID()
        payloads[audioPayloadId] = .audio(AudioPayload(
            assetRef: .bundled(id: "track_01"),
            sourceDurationUs: 6_000_000,
            trimStartUs: 500_000,
            trimEndUs: 5_500_000,
            volume: 0.8
        ))
        var audioTrack = Track(kind: .audio)
        audioTrack.items.append(TimelineItem(
            payloadId: audioPayloadId,
            kind: .audioClip,
            startUs: 0,
            durationUs: 6_000_000
        ))
        timeline.tracks.append(audioTrack)

        // Overlay track (1 sticker + 1 text)
        let stickerPayloadId = UUID()
        payloads[stickerPayloadId] = .sticker(StickerPayload(stickerId: "emoji_heart"))
        let textPayloadId = UUID()
        payloads[textPayloadId] = .text(TextPayload(
            text: "Hello TT-11",
            fontFamily: "Helvetica",
            fontSize: 32,
            colorHex: "#FF00FF"
        ))
        var overlayTrack = Track(kind: .overlay)
        overlayTrack.items.append(TimelineItem(
            payloadId: stickerPayloadId,
            kind: .sticker,
            startUs: 500_000,
            durationUs: 1_000_000
        ))
        overlayTrack.items.append(TimelineItem(
            payloadId: textPayloadId,
            kind: .text,
            startUs: 1_000_000,
            durationUs: 2_000_000
        ))
        timeline.tracks.append(overlayTrack)

        timeline.payloads = payloads

        // Boundary transitions (2 distinct types)
        let sceneItems = timeline.sceneItems
        let key01 = SceneBoundaryKey(sceneItems[0].id, sceneItems[1].id)
        timeline.boundaryTransitions[key01] = SceneTransition(
            type: .fade,
            durationFrames: 14,
            easingPreset: .linear
        )
        let key12 = SceneBoundaryKey(sceneItems[1].id, sceneItems[2].id)
        timeline.boundaryTransitions[key12] = SceneTransition(
            type: .push(direction: .left),
            durationFrames: 10,
            easingPreset: .easeInOut
        )

        // Intro + outro
        timeline.introTransition = SceneTransition(
            type: .dipToBlack,
            durationFrames: 15,
            easingPreset: .easeInOut
        )
        timeline.outroTransition = SceneTransition(
            type: .fade,
            durationFrames: 12,
            easingPreset: .linear
        )

        // --- Scene instance states ---
        var states: [UUID: SceneState] = [:]
        for (i, item) in sceneItems.enumerated() {
            var s = SceneState.empty
            s.variantOverrides = ["block_\(i)": "variant_\(i)"]
            s.layerToggles = ["block_\(i)": ["visible": true, "shadow": false]]
            s.mediaSlotsByBlockId = ["block_\(i)": .photo(mediaRef: MediaRef.file("Media/UserMedia/img_\(i).jpg"), visibility: i % 2 == 0, placement: .default(fitMode: .cover))]
            states[item.id] = s
        }

        // --- Background ---
        let background = ProjectBackgroundOverride(
            selectedPresetId: "sunset_01",
            regions: [
                "gradient_region": RegionOverride(source: .gradient(GradientOverride(
                    stops: [
                        GradientStopOverride(t: 0.0, colorHex: "#FF0000"),
                        GradientStopOverride(t: 1.0, colorHex: "#0000FF")
                    ],
                    p0: Point2(x: 0.0, y: 0.0),
                    p1: Point2(x: 1.0, y: 1.0)
                ))),
                "image_region": RegionOverride(source: .image(ImageOverride(
                    mediaRef: MediaRef.file("Media/Background/bg_img.jpg"),
                    transform: BgImageTransformOverride(
                        pan: Point2(x: 0.1, y: 0.2),
                        zoom: 1.5,
                        rotationRadians: 0.3,
                        flipX: true,
                        flipY: false,
                        fitMode: "fill"
                    )
                )))
            ]
        )

        return ProjectDraft(
            schemaVersion: ProjectDraft.currentSchemaVersion,
            id: projectId,
            origin: origin,
            name: "TT-11 Full Draft",
            createdAt: created,
            updatedAt: updated,
            background: background,
            canonicalTimeline: timeline,
            sceneInstanceStates: states
        )
    }

    // MARK: - Tests

    /// Full draft save → load roundtrip through SavedProjectRecord.
    func testSavedProjectRecord_roundtrip_preservesCurrentSchemaDraft() throws {
        let origin = ProjectOrigin.template(templateId: "tt11-\(UUID())")
        let projectId = UUID()
        let draft = makeFullDraft(origin: origin, projectId: projectId)

        // Materialize via ActiveDraftSlot
        let slot = ActiveDraftSlot(
            entryContext: .newProject(origin: origin),
            linkedSavedProjectId: nil,
            draft: draft
        )
        let materializedSlot = try store.materializeSavedProject(slot)

        // Load
        let loaded = store.loadSavedProject(projectId: projectId)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.draft, draft)

        // Identity invariant
        XCTAssertEqual(loaded?.id, draft.id)
        XCTAssertEqual(materializedSlot.linkedSavedProjectId, projectId)

        // Spot-checks for key fields
        let l = try XCTUnwrap(loaded)
        XCTAssertEqual(l.draft.schemaVersion, ProjectDraft.currentSchemaVersion)
        XCTAssertEqual(l.draft.name, "TT-11 Full Draft")
        XCTAssertEqual(l.draft.canonicalTimeline.tracks.count, 3)
        XCTAssertEqual(l.draft.canonicalTimeline.boundaryTransitions.count, 2)
        XCTAssertNotNil(l.draft.canonicalTimeline.introTransition)
        XCTAssertNotNil(l.draft.canonicalTimeline.outroTransition)
        XCTAssertEqual(l.draft.sceneInstanceStates.count, 3)
        XCTAssertEqual(l.draft.background.selectedPresetId, "sunset_01")
        XCTAssertEqual(l.draft.background.regions.count, 2)

        // Verify all 4 payload discriminators present
        let payloadTypes = Set(l.draft.canonicalTimeline.payloads.values.map { payload -> String in
            switch payload {
            case .scene: return "scene"
            case .audio: return "audio"
            case .sticker: return "sticker"
            case .text: return "text"
            }
        })
        XCTAssertEqual(payloadTypes, ["scene", "audio", "sticker", "text"])
    }

    /// ActiveDraftSlot roundtrip.
    func testActiveDraftSlot_roundtrip() throws {
        let origin = ProjectOrigin.template(templateId: "tt11-\(UUID())")
        let projectId = UUID()
        let draft = makeFullDraft(origin: origin, projectId: projectId)

        let slot = ActiveDraftSlot(
            entryContext: .newProject(origin: origin),
            linkedSavedProjectId: nil,
            draft: draft
        )

        try store.saveActiveDraft(slot)

        XCTAssertTrue(store.hasActiveDraft())

        let loaded = store.loadActiveDraft()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.draft, draft)
        XCTAssertEqual(loaded?.entryContext, .newProject(origin: origin))
        XCTAssertNil(loaded?.linkedSavedProjectId)
    }

    /// Multiple saved projects with same origin.
    func testMultipleSavedProjects_sameTemplate() throws {
        let origin = ProjectOrigin.template(templateId: "tt11-\(UUID())")

        let id1 = UUID()
        let id2 = UUID()
        let draft1 = ProjectDraft.create(origin: origin, projectId: id1)
        let draft2 = ProjectDraft.create(origin: origin, projectId: id2)

        let slot1 = ActiveDraftSlot(
            entryContext: .newProject(origin: origin),
            linkedSavedProjectId: nil,
            draft: draft1
        )
        let _ = try store.materializeSavedProject(slot1)

        let slot2 = ActiveDraftSlot(
            entryContext: .newProject(origin: origin),
            linkedSavedProjectId: nil,
            draft: draft2
        )
        let _ = try store.materializeSavedProject(slot2)

        let entries = store.allSavedProjectEntries()
        let projectIds = Set(entries.map(\.projectId))
        XCTAssertTrue(projectIds.contains(id1))
        XCTAssertTrue(projectIds.contains(id2))
    }

    /// allSavedProjectEntries returns entries with projectId.
    func testAllSavedProjectEntries_containsProjectId() throws {
        let origin = ProjectOrigin.template(templateId: "tt11-\(UUID())")
        let projectId = UUID()
        let draft = ProjectDraft.create(origin: origin, projectId: projectId)

        let slot = ActiveDraftSlot(
            entryContext: .newProject(origin: origin),
            linkedSavedProjectId: nil,
            draft: draft
        )
        let _ = try store.materializeSavedProject(slot)

        let entries = store.allSavedProjectEntries()
        let entry = entries.first { $0.projectId == projectId }
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.origin, origin)
    }

    /// hasActiveDraft is correct.
    func testHasActiveDraft_correctness() throws {
        XCTAssertFalse(store.hasActiveDraft())

        let origin = ProjectOrigin.template(templateId: "test-template")
        let draft = ProjectDraft.create(origin: origin)
        let slot = ActiveDraftSlot(
            entryContext: .newProject(origin: origin),
            linkedSavedProjectId: nil,
            draft: draft
        )
        try store.saveActiveDraft(slot)
        XCTAssertTrue(store.hasActiveDraft())

        try store.deleteActiveDraft()
        XCTAssertFalse(store.hasActiveDraft())
    }

    /// Incompatible index.json (e.g., v8 format) is wiped, orphan project files deleted, returns empty.
    func testLoadSavedIndex_incompatibleFormat_wipesAndReturnsEmpty() throws {
        let persistence = FileProjectPersistenceStore(rootDirectoryURL: tempDir)
        try persistence.ensureDirectoriesExist()

        // Write a v8-format index.json with sourceTemplateId (incompatible with v9 SavedProjectsIndex)
        let indexURL = try persistence.projectsDirectoryURL()
            .appendingPathComponent(FileProjectPersistenceStore.indexFileName)
        let v8JSON = """
        {
            "sourceTemplateId": "old_template",
            "entries": [{"id": "00000000-0000-0000-0000-000000000001"}]
        }
        """
        try v8JSON.data(using: .utf8)!.write(to: indexURL, options: .atomic)

        // Write a fake orphan project file
        let orphanId = UUID()
        let orphanURL = try persistence.projectsDirectoryURL()
            .appendingPathComponent("\(orphanId.uuidString).json")
        try "{}".data(using: .utf8)!.write(to: orphanURL, options: .atomic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanURL.path))

        // Clear cache so loadSavedIndex reads from disk
        persistence.clearCache()

        // Load should detect incompatible format, wipe, and return empty
        let index = try persistence.loadSavedIndex()
        XCTAssertTrue(index.projects.isEmpty, "Incompatible index should return empty")
        XCTAssertTrue(persistence.didWipeIncompatibleData, "Flag should be set after wipe")

        // Index file should be deleted
        XCTAssertFalse(FileManager.default.fileExists(atPath: indexURL.path),
                       "Incompatible index file should be deleted")

        // Orphan project file should be deleted
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path),
                       "Orphan project file should be deleted by wipeOrphanProjectFiles")
    }

    /// Empty draft roundtrips correctly through SavedProjectRecord.
    func testSavedProjectRecord_emptyDraft_roundtrip() throws {
        let origin = ProjectOrigin.template(templateId: "tt11-\(UUID())")
        let projectId = UUID()
        // Use whole-second dates to survive ISO8601 roundtrip
        let now = Date(timeIntervalSince1970: 1705312800)
        let draft = ProjectDraft(
            id: projectId,
            origin: origin,
            createdAt: now,
            updatedAt: now
        )

        let slot = ActiveDraftSlot(
            entryContext: .newProject(origin: origin),
            linkedSavedProjectId: nil,
            draft: draft
        )
        let _ = try store.materializeSavedProject(slot)

        let loaded = store.loadSavedProject(projectId: projectId)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.draft, draft)
    }
}
