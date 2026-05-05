import UIKit
import TVECore
import os.log

private let logger = Logger(subsystem: "com.animi.app", category: "EditorPresentation")

/// Owns close/save, fullscreen, scene catalog, text/sticker/music modals.
@MainActor
internal final class EditorPresentationController {
    unowned let viewController: EditorViewController

    weak var fullScreenPreviewVC: FullScreenPreviewViewController? {
        get { viewController.fullScreenPreviewVC }
        set { viewController.fullScreenPreviewVC = newValue }
    }

    init(viewController: EditorViewController) {
        self.viewController = viewController
    }

    private func log(_ message: String) {
        logger.info("\(message)")
    }

    // MARK: - Close/Save

    func handleEditorClose() {
        let vc = viewController
        vc.runtime?.stopPlayback()
        let action = vc.session.requestClose()
        switch action {
        case .safeToClose:
            vc.userMadeExplicitCloseChoice = true
            vc.navigationController?.popViewController(animated: true)
        case .needsUserDecision:
            presentCloseAlert()
        }
    }

    func presentCloseAlert() {
        let vc = viewController
        let alert = UIAlertController(title: nil, message: "Save changes?", preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            self?.saveAndClose()
        })
        alert.addAction(UIAlertAction(title: "Don't Save", style: .destructive) { [weak self] _ in
            self?.discardAndClose()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = vc.view
            popover.sourceRect = CGRect(x: vc.view.bounds.midX, y: vc.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        vc.present(alert, animated: true)
    }

    func saveAndClose() {
        let vc = viewController
        vc.userMadeExplicitCloseChoice = true
        Task {
            do {
                try await vc.session.executeSaveAndClose()
            } catch {
                log("[Close] Save failed: \(error)")
                presentSaveError(error)
                return
            }
            vc.navigationController?.popViewController(animated: true)
        }
    }

    func discardAndClose() {
        let vc = viewController
        vc.userMadeExplicitCloseChoice = true
        Task {
            try? await vc.session.executeDiscardAndClose()
            vc.navigationController?.popViewController(animated: true)
        }
    }

    func presentSaveError(_ error: Error) {
        let vc = viewController
        let alert = UIAlertController(
            title: "Save Failed",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        vc.present(alert, animated: true)
    }

    // MARK: - Fullscreen Preview

    func handleFullScreenPreview() {
        let vc = viewController
        let uiMode = vc.session.state?.uiMode ?? .timeline
        guard case .timeline = uiMode else {
            assertionFailure("handleFullScreenPreview called outside timeline mode")
            return
        }

        let fullScreenVC = FullScreenPreviewViewController()
        fullScreenVC.modalPresentationStyle = .fullScreen
        fullScreenPreviewVC = fullScreenVC

        let compressedFrame = vc.session.state?.playheadCompressedFrame ?? 0
        fullScreenVC.configure(compressedFrame: compressedFrame, isPlaying: vc.runtime?.isPlaying ?? false)

        vc.transferMetalViewToFullscreen(fullScreenVC)

        fullScreenVC.onClose = { [weak vc] returnedCompressedFrame in
            guard let vc = vc else { return }

            vc.presentationController_.fullScreenPreviewVC = nil

            vc.returnMetalViewFromFullscreen()

            vc.dismiss(animated: true) {
                vc.session.dispatch(.setPlayhead(compressedFrame: returnedCompressedFrame))
                vc.requestRender()
            }
        }

        fullScreenVC.onPlayPause = { [weak vc] in
            vc?.playPauseTapped()
        }

        vc.present(fullScreenVC, animated: true)
    }

    // MARK: - Playback State

    func handlePlaybackStateChanged(_ isPlaying: Bool) {
        let vc = viewController
        vc.editorLayoutContainer.setPlaying(isPlaying)
        fullScreenPreviewVC?.setPlaying(isPlaying)
    }

    // MARK: - Transition Picker

    func presentTransitionPicker(fromSceneId: UUID, toSceneId: UUID, anchorRect: CGRect) {
        let vc = viewController
        let key = SceneBoundaryKey(fromSceneId, toSceneId)
        let current = vc.session.state?.canonicalTimeline.boundaryTransitions[key] ?? .none

        let handler = EditorViewController.makeBoundaryTransitionDispatchHandler(
            fromSceneId: fromSceneId,
            toSceneId: toSceneId
        ) { [weak vc] action in
            vc?.session.dispatch(action)
        }

        let picker = EditorViewController.makeTransitionPicker(
            currentType: current.type,
            onSelect: handler
        )

        let nav = UINavigationController(rootViewController: picker)

        if vc.traitCollection.userInterfaceIdiom == .pad {
            nav.modalPresentationStyle = .popover
            if let popover = nav.popoverPresentationController {
                popover.sourceView = vc.editorLayoutContainer.timelineView
                popover.sourceRect = anchorRect
            }
        } else {
            nav.modalPresentationStyle = .pageSheet
            if let sheet = nav.sheetPresentationController {
                sheet.detents = [.medium()]
                sheet.prefersGrabberVisible = true
            }
        }

        vc.present(nav, animated: true)
    }

    // MARK: - Editor Notice

    func handleEditorNotice(_ notice: EditorNotice) {
        let vc = viewController
        switch notice {
        case .boundaryTransitionsReset:
            let alert = EditorViewController.makeBoundaryTransitionsResetAlert()
            vc.present(alert, animated: true)
        }
    }

    // MARK: - Scene Catalog

    func presentSceneCatalog() {
        let vc = viewController
        guard let library = vc.sceneLibrarySnapshot else {
            log("[SceneCatalog] presentSceneCatalog: sceneLibrarySnapshot is nil")
            let alert = UIAlertController(
                title: "Scenes Unavailable",
                message: "Scene library could not be loaded. Please try again.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            vc.present(alert, animated: true)
            return
        }

        let catalogVC = SceneCatalogViewController(sceneLibrary: library)
        catalogVC.onSelectScene = { [weak self] sceneTypeId, baseDurationUs in
            self?.handleAddScene(sceneTypeId: sceneTypeId, baseDurationUs: baseDurationUs)
        }

        let navController = UINavigationController(rootViewController: catalogVC)
        vc.present(navController, animated: true)
    }

    func handleAddScene(sceneTypeId: String, baseDurationUs: TimeUs) {
        let vc = viewController
        vc.session.dispatch(.addScene(sceneTypeId: sceneTypeId, durationUs: baseDurationUs))
        log("[SceneCatalog] Added scene: \(sceneTypeId) duration=\(baseDurationUs)us")
    }

    // MARK: - Text Editor

    func presentTextEditor(existingPayload: TextPayload?, itemId: UUID?) {
        let vc = viewController
        let editor = TextEditorViewController(payload: existingPayload)
        editor.onCommit = { [weak vc] payload in
            guard let vc = vc else { return }
            if let itemId = itemId {
                vc.session.dispatch(.updateTextPayload(itemId: itemId, payload: payload))
            } else {
                let playheadFrame = vc.session.state?.playheadCompressedFrame ?? 0
                let mapper = vc.session.state?.makePlayheadMapper()
                let startUs = mapper?.nominalTimeUs(forCompressedFrame: playheadFrame) ?? 0
                let defaultDuration: TimeUs = 3_000_000
                vc.session.dispatch(.addTextOverlay(
                    text: payload.text,
                    fontSize: payload.fontSize ?? 32,
                    colorHex: payload.colorHex ?? "#FFFFFF",
                    fontFamily: payload.fontFamily,
                    startUs: startUs,
                    durationUs: defaultDuration
                ))
            }
        }
        let nav = UINavigationController(rootViewController: editor)
        vc.present(nav, animated: true)
    }

    // MARK: - Sticker Picker

    func presentStickerPicker(changingItemId: UUID?) {
        let vc = viewController
        let picker = StickerPickerViewController(stickerProvider: vc.session.stickerProvider)
        picker.onStickerSelected = { [weak vc] stickerId in
            guard let vc = vc else { return }
            if let itemId = changingItemId {
                var payload = vc.session.state?.canonicalTimeline.stickerPayload(for: itemId) ?? StickerPayload(stickerId: stickerId)
                payload.stickerId = stickerId
                vc.session.dispatch(.updateStickerPayload(itemId: itemId, payload: payload))
            } else {
                let playheadFrame = vc.session.state?.playheadCompressedFrame ?? 0
                let mapper = vc.session.state?.makePlayheadMapper()
                let startUs = mapper?.nominalTimeUs(forCompressedFrame: playheadFrame) ?? 0
                let defaultDuration: TimeUs = 3_000_000
                vc.session.dispatch(.addStickerOverlay(
                    stickerId: stickerId,
                    startUs: startUs,
                    durationUs: defaultDuration
                ))
            }
        }
        vc.present(picker, animated: true)
    }

    // MARK: - Music Picker

    func presentMusicPicker() {
        let vc = viewController
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio])
        picker.delegate = vc
        picker.allowsMultipleSelection = false
        vc.present(picker, animated: true)
    }

    // MARK: - Music Volume

    func presentMusicVolumeSlider(itemId: UUID) {
        let vc = viewController
        guard let payload = vc.session.state?.canonicalTimeline.audioPayload(for: itemId),
              payload.role == .music else { return }

        let alert = UIAlertController(
            title: "Music Volume",
            message: "\n\n",
            preferredStyle: .alert
        )

        let slider = UISlider()
        slider.minimumValue = 0.0
        slider.maximumValue = 1.0
        slider.value = payload.volume
        slider.translatesAutoresizingMaskIntoConstraints = false

        alert.view.addSubview(slider)
        NSLayoutConstraint.activate([
            slider.leadingAnchor.constraint(equalTo: alert.view.leadingAnchor, constant: 20),
            slider.trailingAnchor.constraint(equalTo: alert.view.trailingAnchor, constant: -20),
            slider.topAnchor.constraint(equalTo: alert.view.topAnchor, constant: 60),
        ])

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Done", style: .default) { [weak vc] _ in
            vc?.session.dispatch(.setProjectMusicVolume(itemId: itemId, volume: slider.value))
        })

        vc.present(alert, animated: true)
    }

    // MARK: - Music Trim

    func presentMusicTrimEditor(itemId: UUID) {
        let vc = viewController
        guard let payload = vc.session.state?.canonicalTimeline.audioPayload(for: itemId),
              payload.role == .music else { return }

        let sourceDurationSec = usToSeconds(payload.sourceDurationUs)
        let currentStartSec = usToSeconds(payload.trimStartUs)
        let currentEndSec = usToSeconds(payload.trimEndUs)

        let alert = UIAlertController(
            title: "Trim Music",
            message: String(format: "Source duration: %.1fs", sourceDurationSec),
            preferredStyle: .alert
        )

        alert.addTextField { field in
            field.placeholder = "Start (seconds)"
            field.text = String(format: "%.1f", currentStartSec)
            field.keyboardType = .decimalPad
        }

        alert.addTextField { field in
            field.placeholder = "End (seconds)"
            field.text = String(format: "%.1f", currentEndSec)
            field.keyboardType = .decimalPad
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Done", style: .default) { [weak vc] _ in
            guard let vc,
                  let startText = alert.textFields?[0].text,
                  let endText = alert.textFields?[1].text,
                  let startSec = Double(startText),
                  let endSec = Double(endText) else { return }

            let clampedStartSec = max(0, min(startSec, sourceDurationSec))
            let clampedEndSec = max(clampedStartSec, min(endSec, sourceDurationSec))
            let trimStartUs = secondsToUs(clampedStartSec)
            let trimEndUs = secondsToUs(clampedEndSec)

            vc.session.dispatch(.setProjectMusicTrim(
                itemId: itemId,
                trimStartUs: trimStartUs,
                trimEndUs: trimEndUs
            ))
        })

        vc.present(alert, animated: true)
    }

    // MARK: - Error Alerts

    func presentRuntimeFailedAlert(_ msg: String) {
        let vc = viewController
        let alert = UIAlertController(title: "Runtime Error", message: msg, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        vc.present(alert, animated: true)
    }

    func presentGenericErrorAlert(_ msg: String) {
        let vc = viewController
        let alert = UIAlertController(title: "Error", message: msg, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        vc.present(alert, animated: true)
    }
}
