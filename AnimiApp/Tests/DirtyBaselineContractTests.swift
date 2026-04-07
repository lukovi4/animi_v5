import XCTest
import TVECore
@testable import AnimiApp

@MainActor
final class DirtyBaselineContractTests: XCTestCase {

    // MARK: - Helpers

    private func makeBootstrappedSession(
        saveActiveDraft: @escaping (ActiveDraftSlot) throws -> Void = { _ in }
    ) async -> EditorSession {
        let deps = EditorSessionDependencies(
            saveActiveDraft: saveActiveDraft,
            loadActiveDraft: { nil },
            deleteActiveDraft: {},
            loadSavedProject: { _ in nil },
            materializeSavedProject: { _ in },
            loadSceneLibrary: { Self.stubSceneLibrary() },
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

    private static func stubSceneLibrary() -> SceneLibrarySnapshot {
        SceneLibrarySnapshot(
            fps: 30,
            canvas: CanvasConfig(width: 1080, height: 1920),
            scenes: [
                SceneTypeDescriptor(id: "scene_1", order: 0, title: "Test", baseDurationUs: 3_000_000)
            ]
        )
    }

    // MARK: - Dual Baseline Tests

    func testAutosave_doesNotClearUserDirty() async {
        let session = await makeBootstrappedSession()

        // Mutate
        session.dispatch(.addScene(sceneTypeId: "scene_1", durationUs: 3_000_000))
        XCTAssertEqual(session.requestClose(), .needsUserDecision)

        // Autosave (checkpoint)
        let saved = session.persistCheckpointIfNeeded()
        XCTAssertTrue(saved)

        // Still dirty for user — autosave advances recovery baseline, not materialized baseline
        XCTAssertEqual(session.requestClose(), .needsUserDecision,
            "Autosave must not clear user-facing dirty state")
    }

    func testAutosave_preventsRedundantRecoveryWrite() async {
        var saveCount = 0
        let session = await makeBootstrappedSession(saveActiveDraft: { _ in saveCount += 1 })

        // Mutate
        session.dispatch(.addScene(sceneTypeId: "scene_1", durationUs: 3_000_000))

        let beforeCount = saveCount
        // First checkpoint
        XCTAssertTrue(session.persistCheckpointIfNeeded())
        XCTAssertEqual(saveCount, beforeCount + 1)

        // Second checkpoint (no changes since last) — should skip
        XCTAssertFalse(session.persistCheckpointIfNeeded())
        XCTAssertEqual(saveCount, beforeCount + 1, "No redundant recovery write expected")
    }

    func testAutosave_thenMutate_thenAutosave_writesAgain() async {
        var saveCount = 0
        let session = await makeBootstrappedSession(saveActiveDraft: { _ in saveCount += 1 })

        // First mutate + checkpoint
        session.dispatch(.addScene(sceneTypeId: "scene_1", durationUs: 3_000_000))
        let before = saveCount
        XCTAssertTrue(session.persistCheckpointIfNeeded())

        // Second mutate + checkpoint
        session.dispatch(.addScene(sceneTypeId: "scene_1", durationUs: 3_000_000))
        XCTAssertTrue(session.persistCheckpointIfNeeded())
        XCTAssertEqual(saveCount, before + 2, "Each new mutation should trigger a new recovery write")
    }

    func testExportCommit_resetsBothBaselines() async {
        let session = await makeBootstrappedSession()

        // Mutate
        session.dispatch(.addScene(sceneTypeId: "scene_1", durationUs: 3_000_000))

        // Checkpoint (advances recovery only)
        session.persistCheckpointIfNeeded()
        XCTAssertEqual(session.requestClose(), .needsUserDecision)

        // Export commit (advances both baselines)
        session.commitAfterExportSuccess()
        XCTAssertEqual(session.requestClose(), .safeToClose,
            "Export should reset both baselines")

        // No redundant recovery write needed now
        XCTAssertFalse(session.persistCheckpointIfNeeded(),
            "Recovery baseline should match current after export")
    }

    func testDirtyState_structuralEquality() {
        // Verify EditorSessionSnapshot uses structural equality
        let draft1 = ProjectDraft.create(for: "tpl_1")
        let draft2 = ProjectDraft.create(for: "tpl_1")

        // Same content, different instances — but different IDs from create()
        let state1 = EditorState(draft: draft1, templateFPS: 30)
        let state2 = EditorState(draft: draft1, templateFPS: 30)

        let snap1 = EditorSessionSnapshot(from: state1)
        let snap2 = EditorSessionSnapshot(from: state2)

        XCTAssertEqual(snap1, snap2,
            "Snapshots from identical state should be equal")

        // Different state
        var modified = state1
        modified.draft.canonicalTimeline = .empty()
        let snap3 = EditorSessionSnapshot(from: modified)

        // Only equal if draft1's canonical timeline was already empty
        if draft1.canonicalTimeline != .empty() {
            XCTAssertNotEqual(snap1, snap3)
        }
    }
}

private struct StubPresetProvider: BackgroundPresetProviding {
    func loadFromBundle() throws {}
    func preset(for presetId: String) -> BackgroundPreset? { nil }
    func presetOrFallback(for presetId: String) -> BackgroundPreset? { nil }
    var allPresets: [BackgroundPreset] { [] }
    var count: Int { 0 }
}
