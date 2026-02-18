import Foundation

// MARK: - Template Catalog

/// In-memory repository for template catalog.
/// Single source of truth for all template data.
@MainActor
final class TemplateCatalog {

    // MARK: - Singleton

    static let shared = TemplateCatalog()

    // MARK: - State

    private var snapshot: TemplateCatalogSnapshot?
    private var loadTask: Task<Result<TemplateCatalogSnapshot, Error>, Never>?

    private let loader = BundleTemplateCatalogLoader()

    private init() {}

    // MARK: - Loading

    /// Loads catalog from bundle. Safe to call multiple times.
    func load() async -> Result<TemplateCatalogSnapshot, Error> {
        // Return cached if available
        if let snapshot = snapshot {
            return .success(snapshot)
        }

        // If already loading, await existing task
        if let existingTask = loadTask {
            return await existingTask.value
        }

        // Create new load task
        let loader = self.loader
        loadTask = Task<Result<TemplateCatalogSnapshot, Error>, Never> {
            do {
                // Run IO on background thread
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try loader.loadManifest()
                }.value
                return .success(loaded)
            } catch {
                return .failure(error)
            }
        }

        let result = await loadTask!.value

        // Cache successful result
        if case .success(let loaded) = result {
            snapshot = loaded
        }

        loadTask = nil
        return result
    }

    /// Forces reload from bundle (clears cache).
    func reload() async -> Result<TemplateCatalogSnapshot, Error> {
        snapshot = nil
        loadTask = nil
        return await load()
    }

    // MARK: - Accessors

    /// Returns categories in display order (excludes empty).
    func categoriesInOrder() -> [TemplateCategory] {
        snapshot?.categoriesInOrder() ?? []
    }

    /// Returns templates for a category in display order.
    func templates(for categoryId: CategoryID) -> [TemplateDescriptor] {
        snapshot?.templates(for: categoryId) ?? []
    }

    /// Returns a single template by ID.
    func template(by id: TemplateID) -> TemplateDescriptor? {
        snapshot?.template(by: id)
    }

    /// Returns current snapshot if loaded.
    var currentSnapshot: TemplateCatalogSnapshot? {
        snapshot
    }
}
