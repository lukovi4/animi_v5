import Foundation

// MARK: - Type Aliases

typealias TemplateID = String
typealias CategoryID = String

// MARK: - Template Open Behavior

/// Defines how a template opens when tapped in the catalog.
enum TemplateOpenBehavior: String, Codable {
    /// Opens Template Details screen first (full-screen preview).
    case previewFirst
    /// Opens Editor directly, skipping preview.
    case directToEditor
}

// MARK: - Template Descriptor

/// Describes a single template in the catalog.
struct TemplateDescriptor: Codable, Identifiable {
    let id: TemplateID
    let categoryId: CategoryID
    let order: Int
    let title: String
    let titleKey: String?
    /// Ordered list of scene type IDs that make up this template.
    let sceneTypeIds: [String]
    /// Optional preview asset filename (resolved to URL by loader).
    let previewAsset: String?
    let openBehavior: TemplateOpenBehavior

    /// Resolved URL for preview (set after manifest load).
    var previewURL: URL?

    enum CodingKeys: String, CodingKey {
        case id, categoryId, order, title, titleKey, sceneTypeIds, previewAsset, openBehavior
    }
}

// MARK: - Template Category

/// Describes a category of templates.
struct TemplateCategory: Codable, Identifiable {
    let id: CategoryID
    let title: String
    let titleKey: String?
    let order: Int
}

// MARK: - Catalog Manifest

/// Root structure of manifest.json.
struct CatalogManifest: Codable {
    let categories: [TemplateCategory]
    let templates: [TemplateDescriptor]
}

// MARK: - Catalog Snapshot

/// In-memory snapshot of the catalog with resolved URLs.
struct TemplateCatalogSnapshot {
    let categories: [TemplateCategory]
    let templates: [TemplateDescriptor]

    /// Categories sorted by order, excluding empty ones.
    func categoriesInOrder() -> [TemplateCategory] {
        let nonEmptyIds = Set(templates.map(\.categoryId))
        return categories
            .filter { nonEmptyIds.contains($0.id) }
            .sorted { $0.order < $1.order }
    }

    /// Templates for a specific category, sorted by order.
    func templates(for categoryId: CategoryID) -> [TemplateDescriptor] {
        templates
            .filter { $0.categoryId == categoryId }
            .sorted { $0.order < $1.order }
    }

    /// Find template by ID.
    func template(by id: TemplateID) -> TemplateDescriptor? {
        templates.first { $0.id == id }
    }

    /// Returns a new snapshot with templates whose sceneTypeIds are all present in the library.
    /// Categories that become empty after pruning are also removed.
    func pruned(against library: SceneLibrarySnapshot) -> TemplateCatalogSnapshot {
        let validTemplates = templates.filter { template in
            !template.sceneTypeIds.isEmpty &&
            template.sceneTypeIds.allSatisfy { library.scene(byId: $0) != nil }
        }
        let validCategoryIds = Set(validTemplates.map(\.categoryId))
        let validCategories = categories.filter { validCategoryIds.contains($0.id) }
        return TemplateCatalogSnapshot(categories: validCategories, templates: validTemplates)
    }
}

// MARK: - Load State

/// Generic loading state for UI.
enum LoadState<T> {
    case loading
    case content(T)
    case empty
    case error(String)
}
