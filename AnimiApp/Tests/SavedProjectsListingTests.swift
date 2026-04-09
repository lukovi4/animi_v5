import XCTest
import TVECore
@testable import AnimiApp

/// Tests for saved-project summary construction and listing via FileProjectPersistenceStore.
final class SavedProjectsListingTests: XCTestCase {

    private var store: FileProjectPersistenceStore!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = FileProjectPersistenceStore(rootDirectoryURL: tempDir)
        try! store.ensureDirectoriesExist()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        store = nil
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeDraft(
        origin: ProjectOrigin,
        projectId: UUID = UUID(),
        name: String? = nil
    ) -> ProjectDraft {
        ProjectDraft(
            id: projectId,
            origin: origin,
            name: name,
            createdAt: Date(timeIntervalSince1970: 1705312800),
            updatedAt: Date(timeIntervalSince1970: 1705312800)
        )
    }

    private func makeSlot(draft: ProjectDraft) -> ActiveDraftSlot {
        ActiveDraftSlot(
            entryContext: .newProject(origin: draft.origin),
            linkedSavedProjectId: nil,
            draft: draft
        )
    }

    // MARK: - Title Fallback Tests

    func testSummary_templateOrigin_nameNil_fallsBackToDisplayTitle() throws {
        let projectId = UUID()
        let draft = makeDraft(origin: .template(templateId: "tpl_sunset"), projectId: projectId, name: nil)
        let slot = makeSlot(draft: draft)
        let materializedSlot = try store.materializeSavedProject(slot)

        let summaries = store.allSavedProjectSummaries()
        let summary = summaries.first { $0.projectId == projectId }
        XCTAssertNotNil(summary)
        XCTAssertEqual(summary?.title, "tpl_sunset", "Title should fall back to origin.displayTitle when name is nil")
        XCTAssertEqual(summary?.origin, .template(templateId: "tpl_sunset"))
        _ = materializedSlot
    }

    func testSummary_templateOrigin_namePresent_usesName() throws {
        let projectId = UUID()
        let draft = makeDraft(origin: .template(templateId: "tpl_sunset"), projectId: projectId, name: "My Cool Video")
        let slot = makeSlot(draft: draft)
        let materializedSlot = try store.materializeSavedProject(slot)

        let summaries = store.allSavedProjectSummaries()
        let summary = summaries.first { $0.projectId == projectId }
        XCTAssertNotNil(summary)
        XCTAssertEqual(summary?.title, "My Cool Video", "Title should use draft.name when present")
        _ = materializedSlot
    }

    func testSummary_blankOrigin_correctDisplayTitle() throws {
        let projectId = UUID()
        let draft = makeDraft(origin: .blank(starterSceneTypeId: "scene_1"), projectId: projectId)
        let slot = makeSlot(draft: draft)
        let materializedSlot = try store.materializeSavedProject(slot)

        let summaries = store.allSavedProjectSummaries()
        let summary = summaries.first { $0.projectId == projectId }
        XCTAssertNotNil(summary)
        XCTAssertEqual(summary?.title, "Blank Project")
        XCTAssertEqual(summary?.origin, .blank(starterSceneTypeId: "scene_1"))
        _ = materializedSlot
    }

    func testSummary_duplicateOrigin_correctDisplayTitle() throws {
        let sourceId = UUID()
        let projectId = UUID()
        let draft = makeDraft(origin: .duplicate(sourceProjectId: sourceId), projectId: projectId)
        let slot = makeSlot(draft: draft)
        let materializedSlot = try store.materializeSavedProject(slot)

        let summaries = store.allSavedProjectSummaries()
        let summary = summaries.first { $0.projectId == projectId }
        XCTAssertNotNil(summary)
        XCTAssertEqual(summary?.title, "Duplicated Project")
        XCTAssertEqual(summary?.origin, .duplicate(sourceProjectId: sourceId))
        _ = materializedSlot
    }

    // MARK: - Sort Order

    func testListing_sortedMostRecentFirst() throws {
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()

        let draft1 = makeDraft(origin: .template(templateId: "tpl_1"), projectId: id1)
        let draft2 = makeDraft(origin: .blank(starterSceneTypeId: "scene_1"), projectId: id2)
        let draft3 = makeDraft(origin: .template(templateId: "tpl_2"), projectId: id3)

        // Build records with explicit, controlled timestamps — no Thread.sleep needed
        let record1 = SavedProjectRecord(savedAt: Date(timeIntervalSince1970: 1000), draft: draft1)
        let record2 = SavedProjectRecord(savedAt: Date(timeIntervalSince1970: 2000), draft: draft2)
        let record3 = SavedProjectRecord(savedAt: Date(timeIntervalSince1970: 3000), draft: draft3)

        try store.saveSavedProjectRecord(record1)
        try store.saveSavedProjectRecord(record2)
        try store.saveSavedProjectRecord(record3)

        var index = try store.loadSavedIndex()
        index.projects[id1] = SavedProjectIndexEntry(projectId: id1, origin: draft1.origin, title: nil, savedAt: record1.savedAt)
        index.projects[id2] = SavedProjectIndexEntry(projectId: id2, origin: draft2.origin, title: nil, savedAt: record2.savedAt)
        index.projects[id3] = SavedProjectIndexEntry(projectId: id3, origin: draft3.origin, title: nil, savedAt: record3.savedAt)
        try store.saveSavedIndex(index)

        let summaries = store.allSavedProjectSummaries()
        let ids = summaries.map(\.projectId)

        guard let idx1 = ids.firstIndex(of: id1),
              let idx2 = ids.firstIndex(of: id2),
              let idx3 = ids.firstIndex(of: id3) else {
            XCTFail("Expected all three project IDs in summaries")
            return
        }

        XCTAssertTrue(idx3 < idx2, "id3 (most recent) should appear before id2")
        XCTAssertTrue(idx2 < idx1, "id2 should appear before id1 (oldest)")
    }

    // MARK: - Empty State

    func testListing_emptyState_returnsEmptyArray() {
        let summaries = store.allSavedProjectSummaries()
        XCTAssertTrue(summaries.isEmpty, "Fresh isolated store should have no summaries")
    }

    // MARK: - materializeSavedProject

    func testMaterialize_blankOrigin_producesSummary() throws {
        let projectId = UUID()
        let draft = makeDraft(origin: .blank(starterSceneTypeId: "scene_empty"), projectId: projectId)
        let slot = makeSlot(draft: draft)
        let materializedSlot = try store.materializeSavedProject(slot)

        XCTAssertEqual(materializedSlot.linkedSavedProjectId, projectId)

        let summaries = store.allSavedProjectSummaries()
        let summary = summaries.first { $0.projectId == projectId }
        XCTAssertNotNil(summary, "Materialized blank-origin project should appear in summaries")
        XCTAssertEqual(summary?.origin, .blank(starterSceneTypeId: "scene_empty"))
        XCTAssertEqual(summary?.title, "Blank Project")
    }
}
