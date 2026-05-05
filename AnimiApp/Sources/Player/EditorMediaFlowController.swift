import UIKit
import PhotosUI
import UniformTypeIdentifiers
import TVECore
import os.log

private let logger = Logger(subsystem: "com.animi.app", category: "EditorMedia")

/// Owns media ingest, photo picker routing, and music import.
@MainActor
internal final class EditorMediaFlowController {
    unowned let viewController: EditorViewController

    lazy var musicImportCoordinator: ProjectMusicImportCoordinator = {
        ProjectMusicImportCoordinator(session: viewController.session)
    }()

    init(viewController: EditorViewController) {
        self.viewController = viewController
    }

    private func log(_ message: String) {
        logger.info("\(message)")
    }

    // MARK: - Add Photo

    func addPhotoTapped() {
        let vc = viewController
        guard vc.session.state?.selectedBlockId != nil else { return }
        presentPhotoPicker(for: .images)
    }

    // MARK: - Ingest Complete

    @MainActor
    func handleIngestComplete(_ result: IngestResult) async {
        let vc = viewController
        let timeline = vc.session.state?.canonicalTimeline

        guard let sceneItem = timeline?.sceneItems.first(where: { $0.id == result.sceneInstanceId }) else {
            vc.session.unregisterAssetBookkeeping(result.mediaRef.assetId)
            try? FileManager.default.removeItem(at: result.persistedURL)
            log("[UserMedia] Ingest completed for deleted scene \(result.sceneInstanceId), cleaned up orphan")
            return
        }

        let defaultFit: FitMode = await resolveDefaultFitAsync(
            sceneItem: sceneItem,
            timeline: timeline,
            blockId: result.blockId
        )

        let currentTimeline = vc.session.state?.canonicalTimeline
        guard currentTimeline?.sceneItems.contains(where: { $0.id == result.sceneInstanceId }) == true else {
            vc.session.unregisterAssetBookkeeping(result.mediaRef.assetId)
            try? FileManager.default.removeItem(at: result.persistedURL)
            log("[UserMedia] Scene \(result.sceneInstanceId) deleted during defaultFit resolution, cleaned up orphan")
            return
        }

        let placement = MediaPlacementState.default(fitMode: defaultFit)

        let slot: SceneMediaSlot
        switch result.mediaKind {
        case .photo:
            slot = .photo(mediaRef: result.mediaRef, placement: placement)
        case .video:
            guard let videoWindow = result.videoWindow else {
                assertionFailure("[UserMedia] Video ingest missing videoWindow")
                vc.session.unregisterAssetBookkeeping(result.mediaRef.assetId)
                try? FileManager.default.removeItem(at: result.persistedURL)
                log("[UserMedia] Video ingest missing videoWindow, cleaned up orphan")
                return
            }
            slot = .video(mediaRef: result.mediaRef, placement: placement, videoWindow: videoWindow)
        }

        let oldAssetId = vc.session.state?.draft
            .sceneInstanceStates[result.sceneInstanceId]?
            .mediaSlotsByBlockId?[result.blockId]?.mediaRef.assetId

        vc.session.dispatch(.setMediaSlot(
            sceneInstanceId: result.sceneInstanceId,
            blockId: result.blockId,
            slot: slot
        ))

        if let oldAssetId, oldAssetId != result.mediaRef.assetId {
            vc.session.unregisterAssetIfUnreferenced(oldAssetId)
        }

        log("[UserMedia] Ingest complete for block '\(result.blockId)'@\(result.sceneInstanceId): \(result.mediaRef.storagePath)")
    }

    // MARK: - Default Fit Resolution

    func resolveDefaultFitAsync(
        sceneItem: TimelineItem,
        timeline: CanonicalTimeline?,
        blockId: String
    ) async -> FitMode {
        let vc = viewController
        guard let payload = timeline?.payloads[sceneItem.payloadId],
              case .scene(let scenePayload) = payload,
              let rt = vc.runtime else {
            return .cover
        }
        return await rt.resolveDefaultFitMode(sceneTypeId: scenePayload.sceneTypeId, blockId: blockId)
    }

    // MARK: - Photo Picker

    func presentPhotoPicker(for filter: PHPickerFilter) {
        let vc = viewController
        var config = PHPickerConfiguration()
        config.filter = filter
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = vc
        vc.present(picker, animated: true)
    }

    // MARK: - Media Type Mismatch

    func showMediaTypeMismatchAlert() {
        let vc = viewController
        let alert = UIAlertController(
            title: "Wrong Media Type",
            message: "Please select the correct type of media.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        vc.present(alert, animated: true)
    }

    // MARK: - Music Import

    func importProjectMusic(tempURL: URL, originalExtension: String) {
        musicImportCoordinator.importProjectMusic(tempURL: tempURL, originalExtension: originalExtension)
    }

    // MARK: - Document Picked

    func handleDocumentPicked(urls: [URL]) {
        let vc = viewController
        guard let url = urls.first else { return }
        guard url.startAccessingSecurityScopedResource() else {
            log("[Music] Failed to access security-scoped resource")
            return
        }

        let ext = url.pathExtension
        let tempFilename = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(tempFilename)
        do {
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try FileManager.default.removeItem(at: tempURL)
            }
            try FileManager.default.copyItem(at: url, to: tempURL)
        } catch {
            url.stopAccessingSecurityScopedResource()
            log("[Music] Failed to copy to temp: \(error)")
            return
        }

        url.stopAccessingSecurityScopedResource()

        importProjectMusic(tempURL: tempURL, originalExtension: ext)
    }

    // MARK: - Scene Media Picked (from PHPicker)

    func handleSceneMediaPicked(_ result: PHPickerResult) {
        let vc = viewController
        guard let key = vc.sceneEditModule?.consumePendingPickerRequest() else {
            log("[UserMedia] No pending picker request, skipping ingest")
            return
        }
        vc.mediaIngestCoordinator.ingest(pickerResult: result, key: key)
    }
}
