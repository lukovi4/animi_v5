import Foundation

/// Abstracts access to the template catalog for feature controllers.
/// Feature code depends on this protocol, not on `TemplateCatalog` directly.
@MainActor
protocol TemplateCatalogProviding {
    func load() async -> Result<TemplateCatalogSnapshot, Error>
    func categoriesInOrder() -> [TemplateCategory]
    func templates(for categoryId: CategoryID) -> [TemplateDescriptor]
    func template(by id: TemplateID) -> TemplateDescriptor?
    func sceneTypeDefaults(
        for templateId: TemplateID,
        library: SceneLibrarySnapshot
    ) throws -> [SceneTypeDefault]
}

/// Default implementation that owns a `TemplateCatalog` instance.
/// The `SceneLibrary.shared` singleton is referenced only here, keeping
/// `TemplateCatalog` itself fully decoupled from any singleton.
@MainActor
final class TemplateCatalogRepository: TemplateCatalogProviding {

    private let catalog: TemplateCatalog

    init(catalog: TemplateCatalog) {
        self.catalog = catalog
    }

    convenience init() {
        self.init(catalog: TemplateCatalog(sceneLibraryLoader: { try await SceneLibrary.shared.load() }))
    }

    func load() async -> Result<TemplateCatalogSnapshot, Error> {
        await catalog.load()
    }

    func categoriesInOrder() -> [TemplateCategory] {
        catalog.categoriesInOrder()
    }

    func templates(for categoryId: CategoryID) -> [TemplateDescriptor] {
        catalog.templates(for: categoryId)
    }

    func template(by id: TemplateID) -> TemplateDescriptor? {
        catalog.template(by: id)
    }

    func sceneTypeDefaults(
        for templateId: TemplateID,
        library: SceneLibrarySnapshot
    ) throws -> [SceneTypeDefault] {
        try catalog.sceneTypeDefaults(for: templateId, library: library)
    }
}
