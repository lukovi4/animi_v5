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
/// Release v1: Templates reference recipes, not compiled.tve files.
struct TemplateDescriptor: Codable, Identifiable {
    let id: TemplateID
    let categoryId: CategoryID
    let order: Int
    let title: String
    let titleKey: String?
    /// Path to recipe JSON (e.g., "Templates/Recipes/example_4blocks.json")
    let recipePath: String
    let previewVideoPath: String
    let openBehavior: TemplateOpenBehavior

    /// Resolved URL for recipe JSON (set after manifest load).
    var recipeURL: URL?
    /// Resolved URL for preview.mp4 (set after manifest load).
    var previewURL: URL?

    enum CodingKeys: String, CodingKey {
        case id, categoryId, order, title, titleKey, recipePath, previewVideoPath, openBehavior
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
}

// MARK: - Load State

/// Generic loading state for UI.
enum LoadState<T> {
    case loading
    case content(T)
    case empty
    case error(String)
}
