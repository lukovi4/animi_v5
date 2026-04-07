import XCTest
@testable import AnimiApp

final class SceneLibraryRepositoryTests: XCTestCase {

    @MainActor
    func testRepositoryDelegatesToLibrary() async throws {
        let repo = SceneLibraryRepository()

        // fps has a fallback of 30 even if not loaded
        XCTAssertEqual(repo.fps, 30)

        let snapshot = try await repo.load()
        XCTAssertNotNil(repo.cachedSnapshot)
        XCTAssertEqual(repo.fps, snapshot.fps)
        XCTAssertGreaterThan(snapshot.scenesById.count, 0)
    }

    @MainActor
    func testRepositoryConformsToProtocol() {
        let repo: SceneLibraryProviding = SceneLibraryRepository()
        // fps fallback works via protocol
        XCTAssertEqual(repo.fps, 30)
    }

    @MainActor
    func testSceneByIdReturnsLoadedScene() async throws {
        let repo = SceneLibraryRepository()
        let snapshot = try await repo.load()

        if let firstId = snapshot.orderedIds.first {
            XCTAssertNotNil(repo.scene(byId: firstId))
        }

        XCTAssertNil(repo.scene(byId: "nonexistent_scene_id"))
    }
}
