import XCTest
import TVECore
@testable import AnimiApp

@MainActor
final class MissingMediaSessionNoticeTests: XCTestCase {

    // MARK: - Helpers

    private func makeBootstrappedSession() async -> EditorSession {
        let deps = EditorSessionDependencies(
            saveActiveDraft: { _ in },
            loadActiveDraft: { nil },
            deleteActiveDraft: {},
            loadSavedProject: { _ in nil },
            materializeSavedProject: { _ in },
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

    // MARK: - Missing Media Summary

    func testMissingMediaSummary_initiallyNil() async {
        let session = await makeBootstrappedSession()
        XCTAssertNil(session.missingMediaSummary)
    }

    func testUpdateMissingMedia_accumulatesAcrossScenes() async {
        let session = await makeBootstrappedSession()
        let sceneA = UUID(), sceneB = UUID()
        session.updateMissingMedia(for: sceneA, failures: ["block_1"])
        session.updateMissingMedia(for: sceneB, failures: ["block_2"])
        XCTAssertEqual(session.missingMediaSummary?.failedSlots.count, 2)
        XCTAssertTrue(session.missingMediaSummary!.isBlockFailed(sceneInstanceId: sceneA, blockId: "block_1"))
        XCTAssertTrue(session.missingMediaSummary!.isBlockFailed(sceneInstanceId: sceneB, blockId: "block_2"))
    }

    func testUpdateMissingMedia_sameBlockIdDifferentScenes_noCollision() async {
        let session = await makeBootstrappedSession()
        let sceneA = UUID(), sceneB = UUID()
        session.updateMissingMedia(for: sceneA, failures: ["photo"])
        session.updateMissingMedia(for: sceneB, failures: ["photo"])
        XCTAssertEqual(session.missingMediaSummary?.failedSlots.count, 2)
    }

    func testUpdateMissingMedia_clearOnFix() async {
        let session = await makeBootstrappedSession()
        let sceneA = UUID()
        session.updateMissingMedia(for: sceneA, failures: ["block_1", "block_2"])
        XCTAssertEqual(session.missingMediaSummary?.failedSlots.count, 2)
        // User fixes block_1
        session.updateMissingMedia(for: sceneA, failures: ["block_2"])
        XCTAssertEqual(session.missingMediaSummary?.failedSlots.count, 1)
        XCTAssertFalse(session.missingMediaSummary!.isBlockFailed(sceneInstanceId: sceneA, blockId: "block_1"))
    }

    func testUpdateMissingMedia_clearOnFix_preservesOtherScenes() async {
        let session = await makeBootstrappedSession()
        let sceneA = UUID(), sceneB = UUID()
        session.updateMissingMedia(for: sceneA, failures: ["block_1"])
        session.updateMissingMedia(for: sceneB, failures: ["block_2"])
        // Fix sceneA
        session.updateMissingMedia(for: sceneA, failures: [])
        XCTAssertEqual(session.missingMediaSummary?.failedSlots.count, 1)
        XCTAssertTrue(session.missingMediaSummary!.isBlockFailed(sceneInstanceId: sceneB, blockId: "block_2"))
    }

    func testUpdateMissingMedia_allFixed_summaryCleared() async {
        let session = await makeBootstrappedSession()
        let sceneA = UUID()
        session.updateMissingMedia(for: sceneA, failures: ["block_1"])
        session.updateMissingMedia(for: sceneA, failures: [])
        XCTAssertNil(session.missingMediaSummary)
    }

    func testUpdateMissingMedia_emitsOutput() async {
        let session = await makeBootstrappedSession()
        var emitted: MissingMediaSummary?
        session.onOutput = { if case .missingMediaDetected(let s) = $0 { emitted = s } }
        session.updateMissingMedia(for: UUID(), failures: ["b1"])
        XCTAssertNotNil(emitted)
    }

    func testUpdateMissingMedia_emitsOutputOnlyOnce() async {
        let session = await makeBootstrappedSession()
        var emitCount = 0
        session.onOutput = { if case .missingMediaDetected = $0 { emitCount += 1 } }
        session.updateMissingMedia(for: UUID(), failures: ["b1"])
        session.updateMissingMedia(for: UUID(), failures: ["b2"])
        XCTAssertEqual(emitCount, 1, "Should emit missingMediaDetected only once before ack")
    }

    func testMarkMissingMediaNoticePresented_preventsReemission() async {
        let session = await makeBootstrappedSession()
        var emitCount = 0
        session.onOutput = { if case .missingMediaDetected = $0 { emitCount += 1 } }
        session.updateMissingMedia(for: UUID(), failures: ["b1"])
        XCTAssertTrue(session.hasPendingMissingMediaNotice)
        session.markMissingMediaNoticePresented()
        XCTAssertFalse(session.hasPendingMissingMediaNotice)
        // New detection after ack — should not re-emit
        session.updateMissingMedia(for: UUID(), failures: ["b2"])
        XCTAssertEqual(emitCount, 1, "Should not re-emit after ack")
    }

    func testHasPendingMissingMediaNotice_initiallyFalse() async {
        let session = await makeBootstrappedSession()
        XCTAssertFalse(session.hasPendingMissingMediaNotice)
    }

    func testPendingSummaryReflectsLatestFailures() async {
        let session = await makeBootstrappedSession()
        var lastEmittedSummary: MissingMediaSummary?
        session.onOutput = { if case .missingMediaDetected(let s) = $0 { lastEmittedSummary = s } }
        // First detection — emits output with 1 slot
        session.updateMissingMedia(for: UUID(), failures: ["b1"])
        XCTAssertEqual(lastEmittedSummary?.failedSlots.count, 1)
        // Second detection — no re-emission, but live summary has 2 slots
        session.updateMissingMedia(for: UUID(), failures: ["b2"])
        XCTAssertEqual(session.missingMediaSummary?.failedSlots.count, 2,
                        "Live summary must reflect all accumulated failures, not just the first emission")
    }

    func testAllFailuresClearedBeforePresentation_pendingCleared() async {
        let session = await makeBootstrappedSession()
        let sceneA = UUID()
        session.onOutput = { _ in }
        session.updateMissingMedia(for: sceneA, failures: ["b1"])
        XCTAssertTrue(session.hasPendingMissingMediaNotice)
        // All failures resolved before controller gets to present
        session.updateMissingMedia(for: sceneA, failures: [])
        XCTAssertFalse(session.hasPendingMissingMediaNotice,
                        "Pending notice must be cleared when all failures are resolved")
        XCTAssertNil(session.missingMediaSummary)
    }

    func testMarkMissingMediaNoticePresented_onlyAfterExplicitAck() async {
        let session = await makeBootstrappedSession()
        session.onOutput = { _ in }
        session.updateMissingMedia(for: UUID(), failures: ["b1"])
        XCTAssertTrue(session.hasPendingMissingMediaNotice)
        // Before ack: pending remains true, delivered remains false
        XCTAssertNotNil(session.missingMediaSummary)
        // Simulate controller ack after successful present
        session.markMissingMediaNoticePresented()
        XCTAssertFalse(session.hasPendingMissingMediaNotice)
        // After ack: new detections should not re-emit
        var emitCount = 0
        session.onOutput = { if case .missingMediaDetected = $0 { emitCount += 1 } }
        session.updateMissingMedia(for: UUID(), failures: ["b2"])
        XCTAssertEqual(emitCount, 0, "No re-emission after delivery ack")
    }

    func testMissingMediaSummary_survivesCheckpointAndExport() async {
        let session = await makeBootstrappedSession()
        session.updateMissingMedia(for: UUID(), failures: ["block_x"])
        session.dispatch(.addScene(sceneTypeId: "scene_1", durationUs: 3_000_000))
        session.persistCheckpointIfNeeded()
        session.commitAfterExportSuccess()
        XCTAssertNotNil(session.missingMediaSummary)
    }

    func testMissingMediaSummary_emptyFailedSlots_hasNoFailedMedia() {
        let summary = MissingMediaSummary(failedSlots: [])
        XCTAssertFalse(summary.hasFailedMedia)
    }

    func testEditorSessionOutput_missingMediaDetected() async {
        let sceneId = UUID()
        let summary = MissingMediaSummary(failedSlots: [MissingMediaSlotKey(sceneInstanceId: sceneId, blockId: "block_1")])
        let output = EditorSessionOutput.missingMediaDetected(summary)
        if case .missingMediaDetected(let s) = output {
            XCTAssertEqual(s, summary)
        } else {
            XCTFail("Expected missingMediaDetected output")
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
