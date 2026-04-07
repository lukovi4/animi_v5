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

    private weak var navigationController: UINavigationController?
    private var launchRouter: AppLaunchRouter?

    // MARK: - Init

    init() {
        self.templateCatalogRepository = TemplateCatalogRepository()
        self.sceneLibraryRepository = SceneLibraryRepository()
        self.backgroundPresetRepository = BackgroundPresetRepository()
    }

    // MARK: - Bootstrap

    /// Loads background presets (fail-fast) and builds the initial window root.
    /// Returns the navigation controller to set as `window.rootViewController`.
    func bootstrap() -> UINavigationController {
        loadBackgroundPresets()

        let homeVC = makeHomeViewController()
        let nav = UINavigationController(rootViewController: homeVC)
        self.navigationController = nav
        return nav
    }

    /// Runs the launch router that decides recovery vs. home flow.
    /// The router is retained until the user makes a choice.
    func handleLaunchRecovery(presenter: UIViewController) {
        let router = AppLaunchRouter(
            hasActiveDraft: { ProjectStore.shared.hasActiveDraft() },
            clearActiveDraft: { try ProjectStore.shared.deleteActiveDraft() },
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
        if case .blankProject = intent { return }  // PR 7

        let deps = EditorSessionDependencies(
            saveActiveDraft: { try ProjectStore.shared.saveActiveDraft($0) },
            loadActiveDraft: { ProjectStore.shared.loadActiveDraft() },
            deleteActiveDraft: { try ProjectStore.shared.deleteActiveDraft() },
            loadSavedProject: { ProjectStore.shared.loadSavedProject(projectId: $0) },
            materializeSavedProject: { try ProjectStore.shared.materializeSavedProject(from: &$0) },
            loadSceneLibrary: { [sceneLibraryRepository] in
                try await sceneLibraryRepository.load()
            },
            sceneTypeDefaults: { [templateCatalogRepository] templateId, library in
                try templateCatalogRepository.sceneTypeDefaults(for: templateId, library: library)
            },
            loadTemplateCatalog: { [templateCatalogRepository] in
                await templateCatalogRepository.load()
            }
        )
        let session = EditorSession(intent: intent, dependencies: deps)
        let editorVC = PlayerViewController(session: session)
        navigationController?.pushViewController(editorVC, animated: true)
    }

    // MARK: - View Controller Factories

    private func makeHomeViewController() -> TemplatesHomeViewController {
        TemplatesHomeViewController(
            catalogRepository: templateCatalogRepository,
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
        let myProjectsVC = MyProjectsViewController(
            catalogRepository: templateCatalogRepository,
            onOpenEditor: { [weak self] intent in
                self?.openEditor(intent)
            }
        )
        navigationController?.pushViewController(myProjectsVC, animated: true)
    }

    // MARK: - Private

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
