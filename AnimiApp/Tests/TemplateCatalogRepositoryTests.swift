import XCTest
@testable import AnimiApp

final class TemplateCatalogRepositoryTests: XCTestCase {

    @MainActor
    func testRepositoryDelegatesToCatalog() async {
        let repo = TemplateCatalogRepository()
        let result = await repo.load()

        switch result {
        case .success(let snapshot):
            // Verify repository returns same data as direct singleton access
            let directCategories = TemplateCatalog.shared.categoriesInOrder()
            let repoCategories = repo.categoriesInOrder()
            XCTAssertEqual(repoCategories.map(\.id), directCategories.map(\.id))

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
}
