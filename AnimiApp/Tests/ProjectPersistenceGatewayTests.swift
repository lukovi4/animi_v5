import XCTest
import TVECore
@testable import AnimiApp

/// Integration tests for ProjectStorageActor conforming to ProjectPersistenceGateway.
/// All tests exercise the actor's async interface with real file-backed persistence.
final class ProjectPersistenceGatewayTests: XCTestCase {

    private var actor: ProjectStorageActor!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let persistence = FileProjectPersistenceStore(rootDirectoryURL: tempDir)
        let media = FileProjectMediaStore(rootDirectoryURL: tempDir)
        try! persistence.ensureDirectoriesExist()
        actor = ProjectStorageActor(persistence: persistence, media: media)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        actor = nil
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeDraft(
        origin: ProjectOrigin,
        projectId: UUID = UUID(),
        name: String? = nil,
        timeline: CanonicalTimeline = .empty()
    ) -> ProjectDraft {
        ProjectDraft(
            id: projectId,
            origin: origin,
            name: name,
            createdAt: Date(timeIntervalSince1970: 1705312800),
            updatedAt: Date(timeIntervalSince1970: 1705312800),
            canonicalTimeline: timeline
        )
    }

    private func makeSlot(draft: ProjectDraft) -> ActiveDraftSlot {
        ActiveDraftSlot(
            entryContext: .newProject(origin: draft.origin),
            linkedSavedProjectId: nil,
            draft: draft
        )
    }

    private func makeNonEmptyTimeline() -> CanonicalTimeline {
        var timeline = CanonicalTimeline.empty()
        let pid = UUID()
        timeline.payloads[pid] = .scene(ScenePayload(sceneTypeId: "scene_1"))
        timeline.tracks[0].items.append(TimelineItem(
            payloadId: pid,
            kind: .scene,
            startUs: nil,
            durationUs: 2_000_000
        ))
        return timeline
    }

    // MARK: - Active Draft Roundtrip: Template Origin

    func testActiveDraft_saveLoadDelete_templateOrigin() async throws {
        let projectId = UUID()
        let draft = makeDraft(origin: .template(templateId: "tpl_roundtrip"), projectId: projectId)
        let slot = makeSlot(draft: draft)

        try await actor.saveActiveDraft(slot)

        let loaded = await actor.loadActiveDraft()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.draft.id, projectId)
        XCTAssertEqual(loaded?.draft.origin, .template(templateId: "tpl_roundtrip"))
        XCTAssertEqual(loaded?.entryContext, .newProject(origin: .template(templateId: "tpl_roundtrip")))

        try await actor.deleteActiveDraft()

        let afterDelete = await actor.loadActiveDraft()
        XCTAssertNil(afterDelete)
    }

    // MARK: - Active Draft Roundtrip: Blank Origin

    func testActiveDraft_saveLoadDelete_blankOrigin() async throws {
        let projectId = UUID()
        let draft = makeDraft(origin: .blank(starterSceneTypeId: "scene_empty"), projectId: projectId)
        let slot = makeSlot(draft: draft)

        try await actor.saveActiveDraft(slot)

        let loaded = await actor.loadActiveDraft()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.draft.id, projectId)
        XCTAssertEqual(loaded?.draft.origin, .blank(starterSceneTypeId: "scene_empty"))

        try await actor.deleteActiveDraft()
        let afterDelete = await actor.loadActiveDraft()
        XCTAssertNil(afterDelete)
    }

    // MARK: - hasActiveDraft

    func testHasActiveDraft_correctness() async throws {
        let hasBefore = await actor.hasActiveDraft()
        XCTAssertFalse(hasBefore)

        let draft = makeDraft(origin: .template(templateId: "tpl_has"))
        let slot = makeSlot(draft: draft)
        try await actor.saveActiveDraft(slot)

        let hasAfterSave = await actor.hasActiveDraft()
        XCTAssertTrue(hasAfterSave)

        try await actor.deleteActiveDraft()
        let hasAfterDelete = await actor.hasActiveDraft()
        XCTAssertFalse(hasAfterDelete)
    }

    // MARK: - materializeSavedProject Roundtrip: Template

    func testMaterialize_templateOrigin_roundtrip() async throws {
        let projectId = UUID()
        let draft = makeDraft(origin: .template(templateId: "tpl_mat"), projectId: projectId)
        let slot = makeSlot(draft: draft)

        let materializedSlot = try await actor.materializeSavedProject(slot)

        XCTAssertEqual(materializedSlot.linkedSavedProjectId, projectId)

        let loaded = await actor.loadSavedProject(projectId: projectId)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.draft.id, projectId)
        XCTAssertEqual(loaded?.draft.origin, .template(templateId: "tpl_mat"))
    }

    // MARK: - materializeSavedProject Roundtrip: Blank

    func testMaterialize_blankOrigin_roundtrip() async throws {
        let projectId = UUID()
        let draft = makeDraft(origin: .blank(starterSceneTypeId: "scene_1"), projectId: projectId)
        let slot = makeSlot(draft: draft)

        let materializedSlot = try await actor.materializeSavedProject(slot)

        XCTAssertEqual(materializedSlot.linkedSavedProjectId, projectId)

        let loaded = await actor.loadSavedProject(projectId: projectId)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.draft.origin, .blank(starterSceneTypeId: "scene_1"))
    }

    // MARK: - materializeSavedProject Roundtrip: Duplicate

    func testMaterialize_duplicateOrigin_roundtrip() async throws {
        let sourceProjectId = UUID()
        let projectId = UUID()
        let draft = makeDraft(origin: .duplicate(sourceProjectId: sourceProjectId), projectId: projectId)
        let slot = makeSlot(draft: draft)

        let materializedSlot = try await actor.materializeSavedProject(slot)

        XCTAssertEqual(materializedSlot.linkedSavedProjectId, projectId)

        let loaded = await actor.loadSavedProject(projectId: projectId)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.draft.origin, .duplicate(sourceProjectId: sourceProjectId))
    }

    // MARK: - allSavedProjectSummaries Mixed Origins

    func testAllSummaries_mixedOrigins_returnsCorrectSummaries() async throws {
        let idTemplate = UUID()
        let idBlank = UUID()
        let sourceId = UUID()
        let idDuplicate = UUID()

        let draftT = makeDraft(origin: .template(templateId: "tpl_mix"), projectId: idTemplate, name: "Template Project")
        let draftB = makeDraft(origin: .blank(starterSceneTypeId: "scene_1"), projectId: idBlank)
        let draftD = makeDraft(origin: .duplicate(sourceProjectId: sourceId), projectId: idDuplicate, name: "Copy of Template")

        let _ = try await actor.materializeSavedProject(makeSlot(draft: draftT))
        let _ = try await actor.materializeSavedProject(makeSlot(draft: draftB))
        let _ = try await actor.materializeSavedProject(makeSlot(draft: draftD))

        let summaries = await actor.allSavedProjectSummaries()
        let summaryMap = Dictionary(uniqueKeysWithValues: summaries.map { ($0.projectId, $0) })

        let tSummary = try XCTUnwrap(summaryMap[idTemplate])
        XCTAssertEqual(tSummary.title, "Template Project")
        XCTAssertEqual(tSummary.origin, .template(templateId: "tpl_mix"))

        let bSummary = try XCTUnwrap(summaryMap[idBlank])
        XCTAssertEqual(bSummary.title, "Blank Project")
        XCTAssertEqual(bSummary.origin, .blank(starterSceneTypeId: "scene_1"))

        let dSummary = try XCTUnwrap(summaryMap[idDuplicate])
        XCTAssertEqual(dSummary.title, "Copy of Template")
        XCTAssertEqual(dSummary.origin, .duplicate(sourceProjectId: sourceId))
    }

    // MARK: - deleteSavedProject Removes From Summaries

    func testDeleteSavedProject_removesFromSummaries() async throws {
        let projectId = UUID()
        let draft = makeDraft(origin: .template(templateId: "tpl_del"), projectId: projectId)
        let _ = try await actor.materializeSavedProject(makeSlot(draft: draft))

        // Verify it exists
        let beforeSummaries = await actor.allSavedProjectSummaries()
        XCTAssertTrue(beforeSummaries.contains { $0.projectId == projectId })

        // Delete
        try await actor.deleteSavedProject(projectId: projectId)

        // Verify it's gone
        let afterSummaries = await actor.allSavedProjectSummaries()
        XCTAssertFalse(afterSummaries.contains { $0.projectId == projectId })
    }

    // MARK: - Non-Template Origin Open: Blank with Non-Empty Timeline

    func testBlankOrigin_nonEmptyTimeline_loadsSuccessfully() async throws {
        let projectId = UUID()
        let timeline = makeNonEmptyTimeline()
        let draft = makeDraft(
            origin: .blank(starterSceneTypeId: "scene_1"),
            projectId: projectId,
            timeline: timeline
        )
        let slot = makeSlot(draft: draft)

        let materializedSlot = try await actor.materializeSavedProject(slot)

        XCTAssertEqual(materializedSlot.linkedSavedProjectId, projectId)

        let loaded = await actor.loadSavedProject(projectId: projectId)
        XCTAssertNotNil(loaded, "Blank-origin project with non-empty timeline should load successfully")
        XCTAssertEqual(loaded?.draft.origin, .blank(starterSceneTypeId: "scene_1"))
        XCTAssertEqual(loaded?.draft.canonicalTimeline.tracks[0].items.count, 1)
        XCTAssertEqual(loaded?.draft.canonicalTimeline.payloads.count, 1)
    }

    // MARK: - Self-healing active draft

    func testLoadActiveDraft_decodeFailure_deletesFileAndReturnsNil() async throws {
        // Seed an invalid active_draft.json at the canonical path.
        let store = FileProjectPersistenceStore(rootDirectoryURL: tempDir)
        try store.ensureDirectoriesExist()
        let activeDraftURL = try store.projectsDirectoryURL()
            .appendingPathComponent(FileProjectPersistenceStore.activeDraftFileName)
        try Data("{not-json".utf8).write(to: activeDraftURL, options: .atomic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: activeDraftURL.path))

        let loaded = store.loadActiveDraft()
        XCTAssertNil(loaded, "Corrupt active draft should decode to nil")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: activeDraftURL.path),
            "Corrupt active draft should be self-healed (deleted)"
        )
    }

    func testHasActiveDraft_invalidFile_returnsFalseAndCleansUp() async throws {
        let store = FileProjectPersistenceStore(rootDirectoryURL: tempDir)
        try store.ensureDirectoriesExist()
        let activeDraftURL = try store.projectsDirectoryURL()
            .appendingPathComponent(FileProjectPersistenceStore.activeDraftFileName)
        try Data("{not-json".utf8).write(to: activeDraftURL, options: .atomic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: activeDraftURL.path))

        let has = store.hasActiveDraft()
        XCTAssertFalse(has, "hasActiveDraft should return false for undecodable draft")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: activeDraftURL.path),
            "Corrupt active draft should be self-healed (deleted)"
        )
    }

    // MARK: - Resume Draft with Duplicate Origin

    func testResumeDraft_duplicateOrigin_loadsSuccessfully() async throws {
        let sourceProjectId = UUID()
        let projectId = UUID()
        let timeline = makeNonEmptyTimeline()
        let draft = makeDraft(
            origin: .duplicate(sourceProjectId: sourceProjectId),
            projectId: projectId,
            name: "Duplicated Draft",
            timeline: timeline
        )
        let slot = ActiveDraftSlot(
            entryContext: .openSavedProject(projectId: projectId),
            linkedSavedProjectId: nil,
            draft: draft
        )

        try await actor.saveActiveDraft(slot)

        let loaded = await actor.loadActiveDraft()
        XCTAssertNotNil(loaded, "Duplicate-origin draft should load successfully via actor")
        XCTAssertEqual(loaded?.draft.origin, .duplicate(sourceProjectId: sourceProjectId))
        XCTAssertEqual(loaded?.draft.name, "Duplicated Draft")
        XCTAssertEqual(loaded?.draft.canonicalTimeline.tracks[0].items.count, 1)
        XCTAssertEqual(loaded?.entryContext, .openSavedProject(projectId: projectId))
    }
}
