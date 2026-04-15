import UIKit

/// Central owner of app-level dependencies and root navigation.
///
/// Creates view controllers with injected dependencies and routing callbacks.
/// Feature controllers never create `PlayerViewController` or access singletons directly.
@MainActor
final class AppCompositionRoot {

    // MARK: - Dependencies

    let templateCatalogRepository: TemplateCatalogRepository
    let sceneLibraryRepository: SceneLibraryRepository
    let backgroundPresetRepository: BackgroundPresetRepository
    let stickerRepository: StickerRepository
    let storageActor: ProjectStorageActor
    let previewService: ProjectPreviewService

    private weak var navigationController: UINavigationController?
    private var launchRouter: AppLaunchRouter?

    // MARK: - Init

    init() {
        self.templateCatalogRepository = TemplateCatalogRepository()
        self.sceneLibraryRepository = SceneLibraryRepository()
        self.backgroundPresetRepository = BackgroundPresetRepository()
        self.stickerRepository = StickerRepository()
        self.storageActor = ProjectStorageActor()
        self.previewService = ProjectPreviewService(catalogProvider: templateCatalogRepository)
    }

    // MARK: - Bootstrap

    /// Loads background presets (fail-fast) and builds the initial window root.
    /// Returns the navigation controller to set as `window.rootViewController`.
    func bootstrap() -> UINavigationController {
        loadBackgroundPresets()
        loadStickers()

        let homeVC = makeHomeViewController()
        let nav = UINavigationController(rootViewController: homeVC)
        self.navigationController = nav
        return nav
    }

    /// Runs the launch router that decides recovery vs. home flow.
    /// The router is retained until the user makes a choice.
    func handleLaunchRecovery(presenter: UIViewController) {
        let router = AppLaunchRouter(
            hasActiveDraft: { [storageActor] in await storageActor.hasActiveDraft() },
            clearActiveDraft: { [storageActor] in try await storageActor.deleteActiveDraft() },
            onOpenEditor: { [weak self] intent in
                self?.launchRouter = nil
                self?.openEditor(intent)
            },
            onDismiss: { [weak self] in
                self?.launchRouter = nil
            }
        )
        self.launchRouter = router
        router.handleLaunch(presenter: presenter)
    }

    // MARK: - Editor Routing

    func openEditor(_ intent: EditorLaunchIntent) {

        let deps = EditorSessionDependencies(
            saveActiveDraft: { [storageActor] in try await storageActor.saveActiveDraft($0) },
            loadActiveDraft: { [storageActor] in await storageActor.loadActiveDraft() },
            deleteActiveDraft: { [storageActor] in try await storageActor.deleteActiveDraft() },
            loadSavedProject: { [storageActor] in await storageActor.loadSavedProject(projectId: $0) },
            materializeSavedProject: { [storageActor] in try await storageActor.materializeSavedProject($0) },
            mediaLocator: storageActor,
            mediaWriter: storageActor,
            loadSceneLibrary: { [sceneLibraryRepository] in
                try await sceneLibraryRepository.load()
            },
            sceneTypeDefaults: { [templateCatalogRepository] templateId, library in
                try templateCatalogRepository.sceneTypeDefaults(for: templateId, library: library)
            },
            loadTemplateCatalog: { [templateCatalogRepository] in
                await templateCatalogRepository.load()
            },
            backgroundPresetProvider: backgroundPresetRepository,
            stickerProvider: stickerRepository
        )
        let session = EditorSession(intent: intent, dependencies: deps)
        let editorVC = PlayerViewController(session: session)
        navigationController?.pushViewController(editorVC, animated: true)
    }

    // MARK: - View Controller Factories

    private func makeHomeViewController() -> TemplatesHomeViewController {
        TemplatesHomeViewController(
            catalogRepository: templateCatalogRepository,
            previewService: previewService,
            onOpenEditor: { [weak self] intent in
                self?.openEditor(intent)
            },
            onOpenTemplateDetails: { [weak self] templateId in
                self?.openTemplateDetails(templateId)
            },
            onOpenCategory: { [weak self] category in
                self?.openCategory(category)
            },
            onOpenMyProjects: { [weak self] in
                self?.openMyProjects()
            }
        )
    }

    private func openTemplateDetails(_ templateId: TemplateID) {
        let detailsVC = TemplateDetailsViewController(
            templateId: templateId,
            catalogRepository: templateCatalogRepository,
            previewService: previewService,
            onOpenEditor: { [weak self] intent in
                self?.openEditor(intent)
            }
        )
        navigationController?.pushViewController(detailsVC, animated: true)
    }

    private func openCategory(_ category: TemplateCategory) {
        let categoryVC = CategoryTemplatesViewController(
            category: category,
            catalogRepository: templateCatalogRepository,
            previewService: previewService,
            onOpenEditor: { [weak self] intent in
                self?.openEditor(intent)
            },
            onOpenTemplateDetails: { [weak self] templateId in
                self?.openTemplateDetails(templateId)
            }
        )
        navigationController?.pushViewController(categoryVC, animated: true)
    }

    private func openMyProjects() {
        let duplication = ProjectDuplicationUseCase(
            persistence: storageActor,
            mediaWriter: storageActor
        )
        let service = SavedProjectsService(
            persistence: storageActor,
            duplication: duplication
        )
        let myProjectsVC = MyProjectsViewController(
            savedProjectsService: service,
            onOpenEditor: { [weak self] intent in
                self?.openEditor(intent)
            }
        )
        navigationController?.pushViewController(myProjectsVC, animated: true)
    }

    // MARK: - Private

    private func loadStickers() {
        do {
            try stickerRepository.loadFromBundle()
            #if DEBUG
            print("[AppCompositionRoot] Loaded \(stickerRepository.count) stickers")
            #endif
        } catch {
            #if DEBUG
            assertionFailure("[AppCompositionRoot] Failed to load stickers: \(error)")
            #else
            print("[AppCompositionRoot] ERROR: Failed to load stickers: \(error)")
            #endif
        }
    }

    private func loadBackgroundPresets() {
        do {
            try backgroundPresetRepository.loadFromBundle()
            #if DEBUG
            print("[AppCompositionRoot] Loaded \(backgroundPresetRepository.count) background presets")
            #endif
        } catch {
            #if DEBUG
            assertionFailure("[AppCompositionRoot] Failed to load background presets: \(error)")
            #else
            print("[AppCompositionRoot] ERROR: Failed to load background presets: \(error)")
            #endif
        }
    }
}
