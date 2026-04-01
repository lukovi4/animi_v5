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

    private init() {}

    // MARK: - Loading

    /// Loads catalog from bundle. Safe to call multiple times.
    /// Uses SceneLibrary.shared as the authoritative source for hardened scene data.
    /// Concurrent callers coalesce into a single load operation.
    func load() async -> Result<TemplateCatalogSnapshot, Error> {
        // Return cached if available
        if let snapshot = snapshot {
            return .success(snapshot)
        }

        // If already loading, await existing task
        if let existingTask = loadTask {
            return await existingTask.value
        }

        // Assign loadTask immediately before any suspension point
        // so concurrent callers coalesce into this single task.
        loadTask = Task<Result<TemplateCatalogSnapshot, Error>, Never> {
            do {
                // Get hardened library on @MainActor (no duplicate probe)
                let library = try await SceneLibrary.shared.load()

                // Load raw catalog manifest on background, prune against hardened library
                let loaded = try await Task.detached(priority: .userInitiated) {
                    let rawCatalog = try BundleTemplateCatalogLoader().loadManifest()
                    return rawCatalog.pruned(against: library)
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

    // MARK: - Scene Defaults Resolution

    /// Resolves scene type defaults for a template by looking up sceneTypeIds in the scene library.
    /// Replaces the old recipe-based loading flow.
    /// - Parameters:
    ///   - templateId: Template identifier
    ///   - library: Scene library snapshot for resolving scene info
    /// - Returns: Array of scene type defaults for initializing a project
    func sceneTypeDefaults(
        for templateId: TemplateID,
        library: SceneLibrarySnapshot
    ) throws -> [SceneTypeDefault] {
        guard let template = snapshot?.template(by: templateId) else {
            throw TemplateCatalogError.templateNotFound(templateId)
        }

        guard !template.sceneTypeIds.isEmpty else {
            throw TemplateCatalogError.emptySceneList(templateId)
        }

        var defaults: [SceneTypeDefault] = []
        for sceneTypeId in template.sceneTypeIds {
            guard let scene = library.scene(byId: sceneTypeId) else {
                throw TemplateCatalogError.sceneNotInLibrary(sceneTypeId, templateId)
            }
            defaults.append(SceneTypeDefault(
                sceneTypeId: sceneTypeId,
                baseDurationUs: scene.baseDurationUs
            ))
        }
        return defaults
    }
}

// MARK: - Template Catalog Errors

enum TemplateCatalogError: Error, LocalizedError {
    case templateNotFound(String)
    case emptySceneList(String)
    case sceneNotInLibrary(SceneTypeID, String)

    var errorDescription: String? {
        switch self {
        case .templateNotFound(let id):
            return "Template not found in catalog: \(id)"
        case .emptySceneList(let id):
            return "Template '\(id)' has no scenes"
        case .sceneNotInLibrary(let sceneId, let templateId):
            return "Scene '\(sceneId)' referenced in template '\(templateId)' not found in library"
        }
    }
}
