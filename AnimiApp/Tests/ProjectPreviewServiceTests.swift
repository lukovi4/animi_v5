import XCTest
@testable import AnimiApp

private func makeTemplateDescriptor(id: TemplateID, previewURL: URL? = nil) -> TemplateDescriptor {
    var desc = TemplateDescriptor(
        id: id,
        categoryId: "test-cat",
        order: 0,
        title: "Test",
        titleKey: nil,
        sceneTypeIds: [],
        previewAsset: nil,
        openBehavior: .previewFirst
    )
    desc.previewURL = previewURL
    return desc
}

/// Stub catalog provider for testing ProjectPreviewService.
@MainActor
private final class StubCatalogProvider: TemplateCatalogProviding {
    var templates: [TemplateID: TemplateDescriptor] = [:]

    func load() async -> Result<TemplateCatalogSnapshot, Error> {
        .success(TemplateCatalogSnapshot(categories: [], templates: []))
    }

    func categoriesInOrder() -> [TemplateCategory] { [] }

    func templates(for categoryId: CategoryID) -> [TemplateDescriptor] { [] }

    func template(by id: TemplateID) -> TemplateDescriptor? {
        templates[id]
    }

    func sceneTypeDefaults(
        for templateId: TemplateID,
        library: SceneLibrarySnapshot
    ) throws -> [SceneTypeDefault] {
        []
    }
}

/// Tests ProjectPreviewService template preview resolution.
final class ProjectPreviewServiceTests: XCTestCase {

    @MainActor
    func test_resolveTemplatePreview_withURL_returnsVideoReady() {
        let provider = StubCatalogProvider()
        let templateId: TemplateID = "test-template"
        let url = URL(fileURLWithPath: "/tmp/preview.mp4")

        provider.templates[templateId] = makeTemplateDescriptor(id: templateId, previewURL: url)

        let service = ProjectPreviewService(catalogProvider: provider)
        let result = service.resolveTemplatePreview(templateId: templateId)

        if case .videoReady(let resolvedURL) = result {
            XCTAssertEqual(resolvedURL, url)
        } else {
            XCTFail("Expected .videoReady")
        }
    }

    @MainActor
    func test_resolveTemplatePreview_nilURL_returnsNotAvailable() {
        let provider = StubCatalogProvider()
        let templateId: TemplateID = "no-preview"

        provider.templates[templateId] = makeTemplateDescriptor(id: templateId)

        let service = ProjectPreviewService(catalogProvider: provider)
        let result = service.resolveTemplatePreview(templateId: templateId)

        if case .notAvailable = result {
            // pass
        } else {
            XCTFail("Expected .notAvailable")
        }
    }

    @MainActor
    func test_resolveTemplatePreview_unknownId_returnsNotAvailable() {
        let provider = StubCatalogProvider()
        let service = ProjectPreviewService(catalogProvider: provider)
        let result = service.resolveTemplatePreview(templateId: "unknown")

        if case .notAvailable = result {
            // pass
        } else {
            XCTFail("Expected .notAvailable")
        }
    }
}
