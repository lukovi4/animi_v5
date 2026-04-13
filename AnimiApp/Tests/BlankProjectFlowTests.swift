import XCTest
@testable import AnimiApp

final class BlankProjectFlowTests: XCTestCase {

    // MARK: - BlankProjectFactory

    func testMakeDraft_setsBlankOrigin() throws {
        let library = makeLibrary(sceneId: "blank_starter", durationUs: 5_000_000)

        let draft = try BlankProjectFactory.makeDraft(starterSceneTypeId: "blank_starter", library: library)

        XCTAssertEqual(draft.origin, .blank(starterSceneTypeId: "blank_starter"))
    }

    func testMakeDraft_timelineIsNonEmpty() throws {
        let library = makeLibrary(sceneId: "blank_starter", durationUs: 5_000_000)

        let draft = try BlankProjectFactory.makeDraft(starterSceneTypeId: "blank_starter", library: library)

        XCTAssertFalse(draft.canonicalTimeline.sceneItems.isEmpty)
        XCTAssertEqual(draft.canonicalTimeline.sceneItems.count, 1)
    }

    func testMakeDraft_timelineContainsStarterScene() throws {
        let library = makeLibrary(sceneId: "blank_starter", durationUs: 5_000_000)

        let draft = try BlankProjectFactory.makeDraft(starterSceneTypeId: "blank_starter", library: library)

        let firstItem = try XCTUnwrap(draft.canonicalTimeline.sceneItems.first)
        let payload = draft.canonicalTimeline.payloads[firstItem.payloadId]
        if case .scene(let scenePayload) = payload {
            XCTAssertEqual(scenePayload.sceneTypeId, "blank_starter")
        } else {
            XCTFail("Expected scene payload, got \(String(describing: payload))")
        }
    }

    func testMakeDraft_usesSceneDuration() throws {
        let library = makeLibrary(sceneId: "blank_starter", durationUs: 7_000_000)

        let draft = try BlankProjectFactory.makeDraft(starterSceneTypeId: "blank_starter", library: library)

        let firstItem = try XCTUnwrap(draft.canonicalTimeline.sceneItems.first)
        XCTAssertEqual(firstItem.durationUs, 7_000_000)
    }

    func testMakeDraft_throwsWhenStarterSceneNotFound() {
        let library = makeLibrary(sceneId: "other_scene", durationUs: 5_000_000)

        XCTAssertThrowsError(
            try BlankProjectFactory.makeDraft(starterSceneTypeId: "blank_starter", library: library)
        ) { error in
            XCTAssertTrue(error is BlankProjectError)
        }
    }

    func testMakeDraft_usesDefaultStarterSceneTypeId() throws {
        let library = makeLibrary(sceneId: BlankProjectFactory.defaultStarterSceneTypeId, durationUs: 5_000_000)

        let draft = try BlankProjectFactory.makeDraft(library: library)

        if case .blank(let sceneTypeId) = draft.origin {
            XCTAssertEqual(sceneTypeId, BlankProjectFactory.defaultStarterSceneTypeId)
        } else {
            XCTFail("Expected blank origin")
        }
    }

    // MARK: - Helpers

    private func makeLibrary(sceneId: String, durationUs: Int64) -> SceneLibrarySnapshot {
        let scene = SceneTypeDescriptor(
            id: sceneId,
            order: 0,
            title: "Test Scene",
            baseDurationUs: durationUs,
            usage: .starterOnly
        )
        return SceneLibrarySnapshot(
            fps: 30,
            canvas: CanvasConfig(width: 1080, height: 1920),
            scenes: [scene]
        )
    }
}
