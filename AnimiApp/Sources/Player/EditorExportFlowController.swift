import UIKit
import TVECore
import os.log

private let logger = Logger(subsystem: "com.animi.app", category: "EditorExport")

/// Owns export UI, progress, and alerts.
@MainActor
internal final class EditorExportFlowController {
    unowned let viewController: EditorViewController

    weak var exportProgressVC: ExportProgressViewController?

    init(viewController: EditorViewController) {
        self.viewController = viewController
    }

    private func log(_ message: String) {
        logger.info("\(message)")
    }

    // MARK: - Export Tapped

    func exportTapped() {
        let vc = viewController
        guard !(vc.runtime?.isExporting ?? false) else {
            log("[Export] Export already in progress")
            return
        }
        guard vc.loadingState == .ready else {
            log("[Export] ERROR: Template not ready")
            return
        }
        guard vc.runtime != nil else { return }

        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Save to Photos", style: .default) { [weak self] _ in
            self?.beginExport(policy: .photoLibraryOnly)
        })
        sheet.addAction(UIAlertAction(title: "Save to Photos & Share", style: .default) { [weak self] _ in
            self?.beginExport(policy: .photoLibraryThenShare)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            let anchor = vc.editorLayoutContainer.exportPopoverAnchorView
            popover.sourceView = anchor
            popover.sourceRect = anchor.bounds
        }
        vc.present(sheet, animated: true)
    }

    func beginExport(policy: ExportDeliveryPolicy) {
        let vc = viewController
        guard let rt = vc.runtime else { return }
        rt.startExport(policy: policy)
        guard rt.state == .exporting else { return }
        Task { await rt.executeExport() }
    }

    // MARK: - Runtime Output Handlers

    func handleExportStarted() {
        let vc = viewController
        let progressVC = ExportProgressViewController()
        progressVC.modalPresentationStyle = .overFullScreen
        progressVC.modalTransitionStyle = .crossDissolve
        progressVC.onCancel = { [weak vc] in vc?.runtime?.cancelExport() }
        self.exportProgressVC = progressVC
        vc.present(progressVC, animated: true) { progressVC.updateState(.preparing) }
        vc.setMetalViewPaused(true)
    }

    func handleExportPreflightRecommendation(_ result: ExportPreflightResult) {
        let vc = viewController
        guard case .recommendLowerPreset(_, let preset, let sizePx) = result else { return }
        Task {
            let choice = await showLowerPresetAlert(suggestedPreset: preset, suggestedSizePx: sizePx)
            vc.runtime?.applyExportPreflightChoice(choice)
        }
    }

    func handleExportProgress(_ p: Float) {
        exportProgressVC?.updateState(.rendering(progress: Double(p)))
    }

    func handleExportFinishing() {
        exportProgressVC?.updateState(.finishing)
    }

    func handleExportRenderSucceeded(_ url: URL) {
        let vc = viewController
        vc.setMetalViewPaused(false)
        vc.requestRender()
        exportProgressVC?.updateState(.savingToPhotos)
    }

    func handleExportRenderFailed(_ error: Error) {
        let vc = viewController
        vc.setMetalViewPaused(false)
        vc.requestRender()
        dismissPresentedExportUIIfNeeded {
            self.presentExportError(error)
        }
    }

    func handleExportCancelled() {
        let vc = viewController
        vc.setMetalViewPaused(false)
        vc.requestRender()
        vc.dismiss(animated: true)
    }

    func handleExportDeliveryShareHandoff(_ fileURL: URL) {
        let vc = viewController
        dismissPresentedExportUIIfNeeded {
            let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            if let popover = activityVC.popoverPresentationController {
                let anchor = vc.editorLayoutContainer.exportPopoverAnchorView
                popover.sourceView = anchor
                popover.sourceRect = anchor.bounds
            }
            activityVC.completionWithItemsHandler = { [weak vc] _, _, _, _ in
                vc?.runtime?.confirmShareCompleted()
            }
            vc.present(activityVC, animated: true)
        }
    }

    func handleExportDeliveryCompleted(_ outcome: ExportDeliveryOutcome) {
        switch outcome {
        case .savedToPhotos:
            dismissPresentedExportUIIfNeeded {
                self.presentSavedToPhotosAlert()
            }
        case .showPermissionSettings:
            dismissPresentedExportUIIfNeeded {
                self.presentPhotoLibraryPermissionAlert()
            }
        case .showError(let e):
            dismissPresentedExportUIIfNeeded {
                self.presentExportError(e)
            }
        case .ignoredStale:
            break
        }
    }

    // MARK: - Export UI

    func showLowerPresetAlert(
        suggestedPreset: VideoQualityPreset,
        suggestedSizePx: (width: Int, height: Int)
    ) async -> EditorRuntime.ExportPreflightChoice {
        let vc = viewController
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(
                title: "Memory Warning",
                message: "This project may be too large to export at the current quality. We recommend reducing the quality to \(suggestedSizePx.width)x\(suggestedSizePx.height) for a stable export.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Reduce Quality", style: .default) { _ in
                continuation.resume(returning: .useRecommended(
                    preset: suggestedPreset,
                    sizePx: suggestedSizePx
                ))
            })
            alert.addAction(UIAlertAction(title: "Continue as-is", style: .default) { _ in
                continuation.resume(returning: .continueOriginal)
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                continuation.resume(returning: .cancel)
            })
            vc.present(alert, animated: true)
        }
    }

    func presentSavedToPhotosAlert() {
        let vc = viewController
        let alert = UIAlertController(title: "Saved to Photos",
            message: "Your video has been saved to the Photos library.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        vc.present(alert, animated: true)
    }

    func dismissPresentedExportUIIfNeeded(completion: @escaping () -> Void) {
        let vc = viewController
        if vc.presentedViewController != nil {
            vc.dismiss(animated: true, completion: completion)
        } else {
            completion()
        }
    }

    func presentPhotoLibraryPermissionAlert() {
        let vc = viewController
        let alert = UIAlertController(title: "Photos Access Required",
            message: "Animi needs permission to save videos to your Photos library.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        vc.present(alert, animated: true)
    }

    func presentExportError(_ error: Error) {
        let vc = viewController
        let alert = UIAlertController(
            title: "Export Failed",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        alert.addAction(UIAlertAction(title: "Copy Error Details", style: .default) { _ in
            UIPasteboard.general.string = error.localizedDescription
        })
        vc.present(alert, animated: true)
    }
}
