import Foundation

enum ExportDeliveryDestination {
    case photoLibrary
}

/// Delivery outcome for UI routing — no UIKit dependency.
enum ExportDeliveryOutcome {
    case ignoredStale
    case savedToPhotos
    case showPermissionSettings
    case showError(Error)
}

/// Protocol for delivering an exported video to a destination.
protocol ExportDelivering {
    func deliver(fileURL: URL, to destination: ExportDeliveryDestination,
                 completion: @escaping (Result<Void, ExportDeliveryError>) -> Void)
}

/// Coordinates post-export delivery (e.g. saving to Photos) and temp file cleanup.
final class ExportDeliveryCoordinator: ExportDelivering {

    private let saver: PhotoLibrarySaving

    init(saver: PhotoLibrarySaving = PhotoLibraryVideoSaveService()) {
        self.saver = saver
    }

    /// Delivers the exported video to the given destination, then cleans up the temp file.
    func deliver(fileURL: URL, to destination: ExportDeliveryDestination,
                 completion: @escaping (Result<Void, ExportDeliveryError>) -> Void) {
        switch destination {
        case .photoLibrary:
            saver.save(fileURL: fileURL) { result in
                // Always clean up temp file regardless of outcome
                try? FileManager.default.removeItem(at: fileURL)

                DispatchQueue.main.async {
                    completion(result)
                }
            }
        }
    }
}

// MARK: - Export Delivery Flow

/// One-shot owner for a single post-export delivery operation.
///
/// Strongly retains the deliverer until terminal completion, applies request gating,
/// and maps raw delivery results to `ExportDeliveryOutcome` for UI routing.
/// The caller must retain this object for the duration of delivery.
final class ExportDeliveryFlow {

    private var deliverer: ExportDelivering?
    private var isRequestActive: ((UUID) -> Bool)?
    private var clearRequestIfCurrent: ((UUID) -> Void)?
    private var completion: ((ExportDeliveryOutcome) -> Void)?

    private let requestId: UUID

    init(requestId: UUID,
         deliverer: ExportDelivering,
         isRequestActive: @escaping (UUID) -> Bool,
         clearRequestIfCurrent: @escaping (UUID) -> Void,
         completion: @escaping (ExportDeliveryOutcome) -> Void) {
        self.requestId = requestId
        self.deliverer = deliverer
        self.isRequestActive = isRequestActive
        self.clearRequestIfCurrent = clearRequestIfCurrent
        self.completion = completion
    }

    /// Starts delivery. Must be called exactly once.
    func start(fileURL: URL, destination: ExportDeliveryDestination) {
        deliverer?.deliver(fileURL: fileURL, to: destination) { [self] result in
            guard let isRequestActive = self.isRequestActive,
                  let clearRequestIfCurrent = self.clearRequestIfCurrent,
                  let completion = self.completion else {
                return  // already fired or torn down
            }

            guard isRequestActive(self.requestId) else {
                self.tearDown()
                completion(.ignoredStale)
                return
            }

            clearRequestIfCurrent(self.requestId)
            let outcome = Self.mapResult(result)
            self.tearDown()
            completion(outcome)
        }
    }

    private static func mapResult(_ result: Result<Void, ExportDeliveryError>) -> ExportDeliveryOutcome {
        switch result {
        case .success:
            return .savedToPhotos
        case .failure(.permissionDenied), .failure(.permissionRestricted):
            return .showPermissionSettings
        case .failure(let error):
            return .showError(error)
        }
    }

    private func tearDown() {
        deliverer = nil
        isRequestActive = nil
        clearRequestIfCurrent = nil
        completion = nil
    }
}
