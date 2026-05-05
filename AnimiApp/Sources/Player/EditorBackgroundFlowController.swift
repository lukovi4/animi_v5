import UIKit
import PhotosUI
import TVECore
import os.log

private let logger = Logger(subsystem: "com.animi.app", category: "EditorBackground")

/// Owns background editor flow.
@MainActor
internal final class EditorBackgroundFlowController {
    unowned let viewController: EditorViewController

    var pendingBackgroundRegionId: String?
    weak var pendingBackgroundEditor: BackgroundEditorViewController?

    init(viewController: EditorViewController) {
        self.viewController = viewController
    }

    private func log(_ message: String) {
        logger.info("\(message)")
    }

    // MARK: - Background Tapped

    func backgroundTapped() {
        let vc = viewController
        guard vc.loadingState == .ready else {
            log("[Background] Template not ready")
            return
        }

        let scope: EditorRuntime.BackgroundEditScope
        if let rt = vc.runtime, case .sceneEdit(let instanceId) = rt.state {
            scope = .scene(instanceId: instanceId)
        } else {
            scope = .project
        }

        vc.runtime?.beginBackgroundEditorSession(scope: scope)

        let templateBackground = vc.runtime?.templateBackground
        let currentOverride = vc.runtime?.currentOverrideForEditScope() ?? vc.session.state?.draft.background ?? .empty
        let editor = BackgroundEditorViewController(
            presetLibrary: vc.session.backgroundPresetProvider,
            templateBackground: templateBackground,
            currentOverride: currentOverride
        )
        editor.delegate = vc
        pendingBackgroundEditor = editor

        let nav = UINavigationController(rootViewController: editor)
        nav.isModalInPresentation = true

        vc.present(nav, animated: true)
    }

    // MARK: - Background Image Picked

    func handleBackgroundImagePicked(result: PHPickerResult, regionId: String) {
        let vc = viewController
        pendingBackgroundEditor?.isImportInFlight = true
        Task { @MainActor in
            defer { self.pendingBackgroundEditor?.isImportInFlight = false }
            do {
                let picked = try await PickerAssetAdapter.extractPhoto(from: result)
                guard case .photo(let tempURL) = picked else { return }
                defer { try? FileManager.default.removeItem(at: tempURL) }
                try await self.saveAndSetBackgroundImage(from: tempURL, for: regionId)
            } catch {
                self.log("[Background] Failed to handle picked image: \(error.localizedDescription)")
            }
        }
    }

    func saveAndSetBackgroundImage(from sourceFileURL: URL, for regionId: String) async throws {
        let vc = viewController
        guard let rt = vc.runtime else { return }

        let editor = pendingBackgroundEditor
        do {
            try await rt.importBackgroundImage(
                sourceFileURL: sourceFileURL,
                regionId: regionId,
                setEditorImage: { [weak editor] regionId, ref in editor?.setImage(for: regionId, mediaRef: ref) }
            )
        } catch is BackgroundImportStaleError {
            log("[Background] Import stale — cleaned up by runtime")
            return
        }

        if !rt.hasActiveBackgroundEditor {
            pendingBackgroundEditor = nil
        }

        vc.requestRender()
    }

    // MARK: - BackgroundEditorDelegate Handlers

    func handleDidUpdateOverride(_ override: ProjectBackgroundOverride) {
        let vc = viewController
        vc.runtime?.applyBackgroundPreviewOverride(override)
        vc.requestRender()
    }

    func handleDidRequestImagePicker(for regionId: String) {
        let vc = viewController
        vc.runtime?.incrementBackgroundImportGeneration()

        pendingBackgroundRegionId = regionId
        if let nav = vc.presentedViewController as? UINavigationController,
           let editor = nav.viewControllers.first as? BackgroundEditorViewController {
            pendingBackgroundEditor = editor
        }

        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = vc
        picker.view.tag = 999

        if let presented = vc.presentedViewController {
            presented.present(picker, animated: true)
        } else {
            vc.present(picker, animated: true)
        }
    }

    func handleDidChangePreset(oldPresetId: String, newPresetId: String) {
        let vc = viewController
        vc.runtime?.handleBackgroundPresetChange(oldPresetId: oldPresetId, newPresetId: newPresetId)
        vc.requestRender()
    }

    func handleWillDismiss(override: ProjectBackgroundOverride, presetId: String) {
        let vc = viewController
        pendingBackgroundEditor = nil
        vc.runtime?.commitBackgroundEditorDismiss(override: override, presetId: presetId)
        vc.requestRender()
    }

    // MARK: - PHPicker Background Check

    func handlePickerResultIfBackground(_ picker: PHPickerViewController, _ result: PHPickerResult) -> Bool {
        guard picker.view.tag == 999, let regionId = pendingBackgroundRegionId else { return false }
        pendingBackgroundRegionId = nil
        handleBackgroundImagePicked(result: result, regionId: regionId)
        return true
    }
}
