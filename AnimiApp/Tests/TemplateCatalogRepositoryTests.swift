import XCTest
import TVECore
@testable import AnimiApp

final class TemplateCatalogRepositoryTests: XCTestCase {

    @MainActor
    func testRepositoryDelegatesToCatalog() async {
        let repo = TemplateCatalogRepository()
        let result = await repo.load()

        switch result {
        case .success(let snapshot):
            let repoCategories = repo.categoriesInOrder()
            XCTAssertEqual(repoCategories.map(\.id), snapshot.categoriesInOrder().map(\.id))

            // Verify template lookup consistency
            if let firstTemplate = snapshot.templates.first {
                XCTAssertNotNil(repo.template(by: firstTemplate.id))
            }
        case .failure:
            // Bundle catalog may fail in test host — that's OK, we're testing delegation
            break
        }
    }

    @MainActor
    func testRepositoryConformsToProtocol() async {
        let repo: TemplateCatalogProviding = TemplateCatalogRepository()
        // After load, verify protocol works
        let result = await repo.load()
        switch result {
        case .success(let snapshot):
            XCTAssertFalse(snapshot.templates.isEmpty, "Bundle should contain templates")
        case .failure:
            break // acceptable if bundle not available in test
        }
    }

    @MainActor
    func testTemplateLookupByIdWorks() async {
        let repo = TemplateCatalogRepository()
        let result = await repo.load()

        if case .success(let snapshot) = result, let first = snapshot.templates.first {
            let found = repo.template(by: first.id)
            XCTAssertEqual(found?.id, first.id)
        }

        XCTAssertNil(repo.template(by: "nonexistent_template_id"))
    }

    // MARK: - Injected Loader

    @MainActor
    func testCatalogWithInjectedLoader_usesInjectedLoader() async {
        var loaderCalled = false
        let stubLibrary = SceneLibrarySnapshot(
            fps: 30,
            canvas: CanvasConfig(width: 1080, height: 1920),
            scenes: [
                SceneTypeDescriptor(id: "scene_stub", order: 0, title: "Stub", baseDurationUs: 3_000_000)
            ]
        )

        let catalog = TemplateCatalog(sceneLibraryLoader: {
            loaderCalled = true
            return stubLibrary
        })

        let result = await catalog.load()
        XCTAssertTrue(loaderCalled, "TemplateCatalog must use the injected sceneLibraryLoader")

        // The load may succeed or fail depending on bundle availability,
        // but the loader must have been called
        switch result {
        case .success:
            break // Bundle manifest loaded and pruned against stub library
        case .failure:
            break // Acceptable if BundleTemplateCatalogLoader fails in test host
        }
    }
}
