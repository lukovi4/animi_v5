import Photos

// MARK: - Photo Library Abstraction

/// Abstraction over PHPhotoLibrary for testability.
protocol PhotoLibraryAccessing {
    func currentAuthorizationStatus() -> PHAuthorizationStatus
    func requestAddOnlyAuthorization(completion: @escaping (PHAuthorizationStatus) -> Void)
    func saveVideo(at fileURL: URL, completion: @escaping (Bool, Error?) -> Void)
}

/// Production implementation using the system Photos framework.
struct SystemPhotoLibrary: PhotoLibraryAccessing {
    func currentAuthorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .addOnly)
    }

    func requestAddOnlyAuthorization(completion: @escaping (PHAuthorizationStatus) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            completion(status)
        }
    }

    func saveVideo(at fileURL: URL, completion: @escaping (Bool, Error?) -> Void) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
        }, completionHandler: completion)
    }
}

// MARK: - Save Service

/// Protocol for saving a video file to the photo library.
protocol PhotoLibrarySaving {
    func save(fileURL: URL, completion: @escaping (Result<Void, ExportDeliveryError>) -> Void)
}

/// Saves a video to the Photos library with permission handling.
final class PhotoLibraryVideoSaveService: PhotoLibrarySaving {

    private let library: PhotoLibraryAccessing

    init(library: PhotoLibraryAccessing = SystemPhotoLibrary()) {
        self.library = library
    }

    func save(fileURL: URL, completion: @escaping (Result<Void, ExportDeliveryError>) -> Void) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            completion(.failure(.exportFileMissing))
            return
        }

        let status = library.currentAuthorizationStatus()
        switch status {
        case .notDetermined:
            // Strong capture: the caller (ExportDeliveryFlow) retains us, but the system
            // authorization prompt may outlive the call-site scope. Capture self strongly
            // so the completion chain cannot break during the first permission dialog.
            library.requestAddOnlyAuthorization { [self] newStatus in
                self.handleAuthorized(status: newStatus, fileURL: fileURL, completion: completion)
            }
        default:
            handleAuthorized(status: status, fileURL: fileURL, completion: completion)
        }
    }

    private func handleAuthorized(status: PHAuthorizationStatus, fileURL: URL,
                                  completion: @escaping (Result<Void, ExportDeliveryError>) -> Void) {
        switch status {
        case .authorized, .limited:
            library.saveVideo(at: fileURL) { success, error in
                if success {
                    completion(.success(()))
                } else {
                    completion(.failure(.saveFailed(underlying: error)))
                }
            }
        case .denied:
            completion(.failure(.permissionDenied))
        case .restricted:
            completion(.failure(.permissionRestricted))
        default:
            completion(.failure(.authorizationFailed))
        }
    }
}
