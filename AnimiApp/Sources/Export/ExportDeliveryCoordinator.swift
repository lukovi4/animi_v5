import Foundation

enum ExportDeliveryDestination {
    case photoLibrary
}

enum ExportDeliveryPolicy {
    case photoLibraryOnly
    case photoLibraryThenShare
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
    private var shareHandoff: ((URL) -> Void)?
    private var pendingShareURL: URL?

    private let requestId: UUID
    private let policy: ExportDeliveryPolicy

    init(requestId: UUID,
         deliverer: ExportDelivering,
         policy: ExportDeliveryPolicy,
         isRequestActive: @escaping (UUID) -> Bool,
         clearRequestIfCurrent: @escaping (UUID) -> Void,
         completion: @escaping (ExportDeliveryOutcome) -> Void,
         shareHandoff: ((URL) -> Void)? = nil) {
        self.requestId = requestId
        self.deliverer = deliverer
        self.policy = policy
        self.isRequestActive = isRequestActive
        self.clearRequestIfCurrent = clearRequestIfCurrent
        self.completion = completion
        self.shareHandoff = shareHandoff
    }

    /// Starts delivery. Must be called exactly once.
    func start(fileURL: URL, destination: ExportDeliveryDestination) {
        #if DEBUG
        let deliveryStartNs = DispatchTime.now().uptimeNanoseconds
        #endif

        deliverer?.deliver(fileURL: fileURL, to: destination) { [self] result in
            #if DEBUG
            let deliveryEndNs = DispatchTime.now().uptimeNanoseconds
            let elapsedSec = Double(deliveryEndNs - deliveryStartNs) / 1_000_000_000.0
            let deliveryOutcome: String
            if case .success = result { deliveryOutcome = "success" } else { deliveryOutcome = "failure" }
            MemoryDiagnostics.event(
                "export.delivery.summary",
                String(format: "destination=photoLibrary policy=%@ duration=%.2fs outcome=%@",
                       String(describing: self.policy), elapsedSec, deliveryOutcome)
            )
            #endif
            guard let isRequestActive = self.isRequestActive,
                  let clearRequestIfCurrent = self.clearRequestIfCurrent,
                  let completion = self.completion else {
                return  // already fired or torn down
            }

            guard isRequestActive(self.requestId) else {
                try? FileManager.default.removeItem(at: fileURL)
                self.tearDown()
                completion(.ignoredStale)
                return
            }

            let outcome = Self.mapResult(result)
            guard case .savedToPhotos = outcome else {
                try? FileManager.default.removeItem(at: fileURL)
                clearRequestIfCurrent(self.requestId)
                self.tearDown()
                completion(outcome)
                return
            }

            switch self.policy {
            case .photoLibraryOnly:
                try? FileManager.default.removeItem(at: fileURL)
                clearRequestIfCurrent(self.requestId)
                self.tearDown()
                completion(.savedToPhotos)

            case .photoLibraryThenShare:
                self.pendingShareURL = fileURL
                if let shareHandoff = self.shareHandoff {
                    shareHandoff(fileURL)
                } else {
                    self.finalizeAfterShare()
                }
            }
        }
    }

    func finalizeAfterShare() {
        guard let url = pendingShareURL,
              let clearRequestIfCurrent = self.clearRequestIfCurrent,
              let completion = self.completion else {
            return
        }

        try? FileManager.default.removeItem(at: url)
        pendingShareURL = nil
        clearRequestIfCurrent(self.requestId)
        tearDown()
        completion(.savedToPhotos)
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
        shareHandoff = nil
        pendingShareURL = nil
    }

    deinit {
        if let pendingShareURL {
            try? FileManager.default.removeItem(at: pendingShareURL)
        }
    }
}
