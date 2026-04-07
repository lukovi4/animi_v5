import XCTest
@testable import AnimiApp

final class BackgroundPresetRepositoryTests: XCTestCase {

    func testRepositoryDelegatesToFreshLibrary() {
        let library = BackgroundPresetLibrary(bundle: .main)
        let repo = BackgroundPresetRepository(library: library)

        // Fresh library instance (not .shared) — count should be 0 before load
        XCTAssertEqual(repo.count, 0)
        XCTAssertTrue(repo.allPresets.isEmpty)
        XCTAssertNil(repo.preset(for: "nonexistent"))
    }

    func testRepositoryConformsToProtocol() {
        let library = BackgroundPresetLibrary(bundle: .main)
        let repo: BackgroundPresetProviding = BackgroundPresetRepository(library: library)
        XCTAssertEqual(repo.count, 0)
    }

    func testRepositoryLoadsFromBundle() throws {
        let library = BackgroundPresetLibrary(bundle: .main)
        let repo = BackgroundPresetRepository(library: library)
        try repo.loadFromBundle()
        XCTAssertGreaterThan(repo.count, 0)
        XCTAssertFalse(repo.allPresets.isEmpty)
    }

    func testPresetOrFallbackReturnsPresetAfterLoad() throws {
        let library = BackgroundPresetLibrary(bundle: .main)
        let repo = BackgroundPresetRepository(library: library)
        try repo.loadFromBundle()

        let fallback = repo.presetOrFallback(for: "nonexistent_id")
        // Should return fallback preset if available
        if repo.count > 0 {
            XCTAssertNotNil(fallback)
        }
    }
}
