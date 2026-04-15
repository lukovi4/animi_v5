import Foundation

/// Struct-of-closures for all I/O the session needs.
/// Test-friendly without protocol overhead.
/// Dependencies are assembled by `AppCompositionRoot` from its already-owned repositories.
@MainActor
struct EditorSessionDependencies {
    // Persistence (all async — go through actor)
    var saveActiveDraft: (ActiveDraftSlot) async throws -> Void
    var loadActiveDraft: () async -> ActiveDraftSlot?
    var deleteActiveDraft: () async throws -> Void
    var loadSavedProject: (UUID) async -> SavedProjectRecord?
    var materializeSavedProject: (ActiveDraftSlot) async throws -> ActiveDraftSlot

    // Media I/O gateways (injected from storageActor).
    // `mediaLocator` is the canonical registry-backed resolver — pass a
    // registry snapshot explicitly per call.
    var mediaLocator: any ProjectMediaLocator
    var mediaWriter: any ProjectMediaWriteGateway

    // Content
    var loadSceneLibrary: () async throws -> SceneLibrarySnapshot
    var sceneTypeDefaults: (_ templateId: String, _ library: SceneLibrarySnapshot) throws -> [SceneTypeDefault]
    var loadTemplateCatalog: () async -> Result<TemplateCatalogSnapshot, Error>

    // Background
    var backgroundPresetProvider: BackgroundPresetProviding

    // Stickers (PR10)
    var stickerProvider: StickerProviding = NullStickerProvider()
}

/// No-op sticker provider for tests and default fallback.
struct NullStickerProvider: StickerProviding {
    func loadFromBundle() throws {}
    func descriptor(for stickerId: String) -> StickerDescriptor? { nil }
    func resourceURL(for stickerId: String) -> URL? { nil }
    var allDescriptors: [StickerDescriptor] { [] }
    var count: Int { 0 }
}
