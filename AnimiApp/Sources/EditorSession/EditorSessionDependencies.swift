import Foundation

/// Struct-of-closures for all I/O the session needs.
/// Test-friendly without protocol overhead.
/// Dependencies are assembled by `AppCompositionRoot` from its already-owned repositories.
@MainActor
struct EditorSessionDependencies {
    // Persistence
    var saveActiveDraft: (ActiveDraftSlot) throws -> Void
    var loadActiveDraft: () -> ActiveDraftSlot?
    var deleteActiveDraft: () throws -> Void
    var loadSavedProject: (UUID) -> SavedProjectRecord?
    var materializeSavedProject: (_ slot: inout ActiveDraftSlot) throws -> Void

    // Content
    var loadSceneLibrary: () async throws -> SceneLibrarySnapshot
    var sceneTypeDefaults: (_ templateId: String, _ library: SceneLibrarySnapshot) throws -> [SceneTypeDefault]
    var loadTemplateCatalog: () async -> Result<TemplateCatalogSnapshot, Error>

    // Background
    var backgroundPresetProvider: BackgroundPresetProviding
}
