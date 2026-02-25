import Foundation

// MARK: - Template Recipe Errors

public enum TemplateRecipeError: Error, LocalizedError {
    case recipeNotFound(String)
    case decodingFailed(String, Error)
    case emptyRecipe(String)
    case sceneNotFound(SceneTypeID, String)

    public var errorDescription: String? {
        switch self {
        case .recipeNotFound(let templateId):
            return "Recipe not found for template: \(templateId)"
        case .decodingFailed(let templateId, let error):
            return "Failed to decode recipe for \(templateId): \(error.localizedDescription)"
        case .emptyRecipe(let templateId):
            return "Recipe for \(templateId) has no scenes"
        case .sceneNotFound(let sceneId, let templateId):
            return "Scene '\(sceneId)' referenced in template '\(templateId)' not found in library"
        }
    }
}

// MARK: - Bundle Template Recipe Loader

/// Loads template recipes from app bundle.
public final class BundleTemplateRecipeLoader {

    private let bundle: Bundle

    public init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    /// Loads a template recipe by template ID.
    /// - Parameter templateId: Template identifier
    /// - Returns: Loaded template recipe
    /// - Throws: `TemplateRecipeError` on failure
    public func load(templateId: String) throws -> TemplateRecipe {
        // Look for recipe at Templates/Recipes/<templateId>.json
        guard let recipeURL = bundle.url(
            forResource: templateId,
            withExtension: "json",
            subdirectory: "Templates/Recipes"
        ) else {
            #if DEBUG
            print("[RecipeLoader] ERROR: Recipe not found for \(templateId)")
            #endif
            throw TemplateRecipeError.recipeNotFound(templateId)
        }

        #if DEBUG
        print("[RecipeLoader] Found recipe at: \(recipeURL.path)")
        #endif

        // Decode recipe
        let data = try Data(contentsOf: recipeURL)
        let decoder = JSONDecoder()
        let recipe: TemplateRecipe
        do {
            recipe = try decoder.decode(TemplateRecipe.self, from: data)
        } catch {
            throw TemplateRecipeError.decodingFailed(templateId, error)
        }

        // Validate recipe has at least one scene
        guard !recipe.sceneTypeIds.isEmpty else {
            throw TemplateRecipeError.emptyRecipe(templateId)
        }

        return recipe
    }

    /// Loads a recipe and resolves scene defaults from the library.
    /// - Parameters:
    ///   - templateId: Template identifier
    ///   - library: Scene library snapshot for resolving scene info
    /// - Returns: Array of scene type defaults for initializing a project
    /// - Throws: `TemplateRecipeError` on failure
    public func loadWithDefaults(
        templateId: String,
        library: SceneLibrarySnapshot
    ) throws -> [SceneTypeDefault] {
        let recipe = try load(templateId: templateId)

        var defaults: [SceneTypeDefault] = []

        for sceneTypeId in recipe.sceneTypeIds {
            guard let scene = library.scene(byId: sceneTypeId) else {
                throw TemplateRecipeError.sceneNotFound(sceneTypeId, templateId)
            }

            defaults.append(SceneTypeDefault(
                sceneTypeId: sceneTypeId,
                baseDurationUs: scene.baseDurationUs
            ))
        }

        return defaults
    }
}
