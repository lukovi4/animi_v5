import Foundation

// MARK: - Template Recipe

/// Defines a template as a sequence of scene types.
/// Templates are what users see in the catalog.
/// Each template references one or more SceneTypes from the SceneLibrary.
public struct TemplateRecipe: Codable, Equatable, Sendable {
    /// Template identifier (matches TemplateDescriptor.id).
    public let templateId: String
    /// Ordered list of scene type IDs that make up this template.
    public let sceneTypeIds: [SceneTypeID]

    public init(templateId: String, sceneTypeIds: [SceneTypeID]) {
        self.templateId = templateId
        self.sceneTypeIds = sceneTypeIds
    }
}

// MARK: - Scene Type Default

/// Default scene configuration for initializing a project from a recipe.
public struct SceneTypeDefault: Equatable, Sendable {
    /// Scene type identifier.
    public let sceneTypeId: SceneTypeID
    /// Base duration from scene library.
    public let baseDurationUs: TimeUs

    public init(sceneTypeId: SceneTypeID, baseDurationUs: TimeUs) {
        self.sceneTypeId = sceneTypeId
        self.baseDurationUs = baseDurationUs
    }
}
