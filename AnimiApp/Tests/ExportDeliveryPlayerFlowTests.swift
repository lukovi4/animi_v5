import XCTest
@testable import AnimiApp

/// Mock deliverer that returns a stubbable result synchronously via the ExportDelivering protocol.
private final class MockDeliverer: ExportDelivering {
    var stubbedResult: Result<Void, ExportDeliveryError> = .success(())
    private(set) var deliverCalled = false

    func deliver(fileURL: URL, to destination: ExportDeliveryDestination,
                 completion: @escaping (Result<Void, ExportDeliveryError>) -> Void) {
        deliverCalled = true
        DispatchQueue.main.async { completion(self.stubbedResult) }
    }
}

/// Tests the real ExportDeliveryFlow production helper — request gating, outcome routing,
/// and cleanup — not a local simulation.
final class ExportDeliveryPlayerFlowTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a temp file and returns its URL.
    private func makeTempFile() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow_test_\(UUID().uuidString).mp4")
        FileManager.default.createFile(atPath: url.path, contents: Data([0x00]), attributes: nil)
        return url
    }

    // MARK: - 1. Current request + success → .savedToPhotos

    func test_currentRequest_success_savedToPhotos() {
        let deliverer = MockDeliverer()
        deliverer.stubbedResult = .success(())

        let requestId = UUID()
        var activeRequestId: UUID? = requestId
        var clearedId: UUID?

        let exp = expectation(description: "outcome")
        var receivedOutcome: ExportDeliveryOutcome?

        let flow = ExportDeliveryFlow(
            requestId: requestId,
            deliverer: deliverer,
            policy: .photoLibraryOnly,
            isRequestActive: { id in activeRequestId == id },
            clearRequestIfCurrent: { id in
                clearedId = id
                activeRequestId = nil
            },
            completion: { outcome in
                receivedOutcome = outcome
                exp.fulfill()
            }
        )

        let tempURL = makeTempFile()
        flow.start(fileURL: tempURL, destination: .photoLibrary)
        wait(for: [exp], timeout: 2)

        if case .savedToPhotos = receivedOutcome {} else {
            XCTFail("Expected .savedToPhotos, got \(String(describing: receivedOutcome))")
        }
        XCTAssertEqual(clearedId, requestId, "clearRequestIfCurrent should be called with requestId")
        XCTAssertTrue(deliverer.deliverCalled)
    }

    // MARK: - 2. Current request + permissionDenied → .showPermissionSettings

    func test_currentRequest_denied_showPermissionSettings() {
        let deliverer = MockDeliverer()
        deliverer.stubbedResult = .failure(.permissionDenied)

        let requestId = UUID()
        var activeRequestId: UUID? = requestId

        let exp = expectation(description: "outcome")
        var receivedOutcome: ExportDeliveryOutcome?

        let flow = ExportDeliveryFlow(
            requestId: requestId,
            deliverer: deliverer,
            policy: .photoLibraryOnly,
            isRequestActive: { id in activeRequestId == id },
            clearRequestIfCurrent: { id in activeRequestId = nil },
            completion: { outcome in
                receivedOutcome = outcome
                exp.fulfill()
            }
        )

        flow.start(fileURL: makeTempFile(), destination: .photoLibrary)
        wait(for: [exp], timeout: 2)

        if case .showPermissionSettings = receivedOutcome {} else {
            XCTFail("Expected .showPermissionSettings, got \(String(describing: receivedOutcome))")
        }
    }

    // MARK: - 3. Current request + saveFailed → .showError

    func test_currentRequest_saveFailed_showError() {
        let deliverer = MockDeliverer()
        let underlyingError = NSError(domain: "test", code: 77)
        deliverer.stubbedResult = .failure(.saveFailed(underlying: underlyingError))

        let requestId = UUID()
        var activeRequestId: UUID? = requestId

        let exp = expectation(description: "outcome")
        var receivedOutcome: ExportDeliveryOutcome?

        let flow = ExportDeliveryFlow(
            requestId: requestId,
            deliverer: deliverer,
            policy: .photoLibraryOnly,
            isRequestActive: { id in activeRequestId == id },
            clearRequestIfCurrent: { id in activeRequestId = nil },
            completion: { outcome in
                receivedOutcome = outcome
                exp.fulfill()
            }
        )

        flow.start(fileURL: makeTempFile(), destination: .photoLibrary)
        wait(for: [exp], timeout: 2)

        if case .showError = receivedOutcome {} else {
            XCTFail("Expected .showError, got \(String(describing: receivedOutcome))")
        }
    }

    // MARK: - 4. Stale request → .ignoredStale, no clearRequest call

    func test_staleRequest_ignoredStale() {
        let deliverer = MockDeliverer()
        deliverer.stubbedResult = .success(())

        let requestA = UUID()
        let requestB = UUID()  // B replaced A
        var activeRequestId: UUID? = requestB
        var clearCalled = false

        let exp = expectation(description: "outcome")
        var receivedOutcome: ExportDeliveryOutcome?

        let flow = ExportDeliveryFlow(
            requestId: requestA,  // flow belongs to stale request A
            deliverer: deliverer,
            policy: .photoLibraryOnly,
            isRequestActive: { id in activeRequestId == id },
            clearRequestIfCurrent: { _ in clearCalled = true },
            completion: { outcome in
                receivedOutcome = outcome
                exp.fulfill()
            }
        )

        flow.start(fileURL: makeTempFile(), destination: .photoLibrary)
        wait(for: [exp], timeout: 2)

        if case .ignoredStale = receivedOutcome {} else {
            XCTFail("Expected .ignoredStale, got \(String(describing: receivedOutcome))")
        }
        XCTAssertFalse(clearCalled, "clearRequestIfCurrent must NOT be called for stale request")
        XCTAssertEqual(activeRequestId, requestB, "Active request B must not be disturbed")
    }

    // MARK: - 5. Stale permission-denied → .ignoredStale (not .showPermissionSettings)

    func test_staleRequest_denied_stillIgnoredStale() {
        let deliverer = MockDeliverer()
        deliverer.stubbedResult = .failure(.permissionDenied)

        let requestA = UUID()
        var activeRequestId: UUID? = nil  // request was cleared/cancelled

        let exp = expectation(description: "outcome")
        var receivedOutcome: ExportDeliveryOutcome?

        let flow = ExportDeliveryFlow(
            requestId: requestA,
            deliverer: deliverer,
            policy: .photoLibraryOnly,
            isRequestActive: { id in activeRequestId == id },
            clearRequestIfCurrent: { _ in },
            completion: { outcome in
                receivedOutcome = outcome
                exp.fulfill()
            }
        )

        flow.start(fileURL: makeTempFile(), destination: .photoLibrary)
        wait(for: [exp], timeout: 2)

        if case .ignoredStale = receivedOutcome {} else {
            XCTFail("Expected .ignoredStale even with denied result, got \(String(describing: receivedOutcome))")
        }
    }

    // MARK: - 6. clearRequestIfCurrent called exactly once on success

    func test_clearRequestCalledExactlyOnce() {
        let deliverer = MockDeliverer()
        deliverer.stubbedResult = .success(())

        let requestId = UUID()
        var activeRequestId: UUID? = requestId
        var clearCount = 0

        let exp = expectation(description: "outcome")

        let flow = ExportDeliveryFlow(
            requestId: requestId,
            deliverer: deliverer,
            policy: .photoLibraryOnly,
            isRequestActive: { id in activeRequestId == id },
            clearRequestIfCurrent: { id in
                clearCount += 1
                activeRequestId = nil
            },
            completion: { _ in exp.fulfill() }
        )

        flow.start(fileURL: makeTempFile(), destination: .photoLibrary)
        wait(for: [exp], timeout: 2)

        XCTAssertEqual(clearCount, 1, "clearRequestIfCurrent must be called exactly once")
    }

    // MARK: - 7. Temp file cleaned up after delivery

    func test_tempFileDeletedAfterDelivery() {
        let deliverer = MockDeliverer()
        deliverer.stubbedResult = .success(())

        let requestId = UUID()
        var activeRequestId: UUID? = requestId

        let tempURL = makeTempFile()
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path), "Precondition: temp file exists")

        let exp = expectation(description: "outcome")

        let flow = ExportDeliveryFlow(
            requestId: requestId,
            deliverer: deliverer,
            policy: .photoLibraryOnly,
            isRequestActive: { id in activeRequestId == id },
            clearRequestIfCurrent: { _ in activeRequestId = nil },
            completion: { _ in exp.fulfill() }
        )

        flow.start(fileURL: tempURL, destination: .photoLibrary)
        wait(for: [exp], timeout: 2)

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path),
                       "Temp file should be deleted by flow")
    }

    func test_photoLibraryThenShare_success_callsShareHandoff() {
        let deliverer = MockDeliverer()
        deliverer.stubbedResult = .success(())

        let requestId = UUID()
        var activeRequestId: UUID? = requestId
        let tempURL = makeTempFile()

        let exp = expectation(description: "share handoff")
        var handoffURL: URL?

        let flow = ExportDeliveryFlow(
            requestId: requestId,
            deliverer: deliverer,
            policy: .photoLibraryThenShare,
            isRequestActive: { id in activeRequestId == id },
            clearRequestIfCurrent: { _ in activeRequestId = nil },
            completion: { _ in XCTFail("Completion should wait for finalizeAfterShare()") },
            shareHandoff: { url in
                handoffURL = url
                exp.fulfill()
            }
        )

        flow.start(fileURL: tempURL, destination: .photoLibrary)
        wait(for: [exp], timeout: 2)

        XCTAssertEqual(handoffURL, tempURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path),
                      "Temp file must stay alive until share completion")
        XCTAssertEqual(activeRequestId, requestId, "Active request must remain until share finalization")
    }

    func test_photoLibraryThenShare_success_fileNotDeletedUntilFinalize() {
        let deliverer = MockDeliverer()
        deliverer.stubbedResult = .success(())

        let requestId = UUID()
        var activeRequestId: UUID? = requestId
        let tempURL = makeTempFile()

        let exp = expectation(description: "share handoff")
        let flow = ExportDeliveryFlow(
            requestId: requestId,
            deliverer: deliverer,
            policy: .photoLibraryThenShare,
            isRequestActive: { id in activeRequestId == id },
            clearRequestIfCurrent: { _ in activeRequestId = nil },
            completion: { _ in XCTFail("Completion should wait for finalizeAfterShare()") },
            shareHandoff: { _ in exp.fulfill() }
        )

        flow.start(fileURL: tempURL, destination: .photoLibrary)
        wait(for: [exp], timeout: 2)

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path),
                      "Temp file must still exist after Photos save and before finalizeAfterShare()")
    }

    func test_photoLibraryThenShare_finalizeAfterShare_deletesFile() {
        let deliverer = MockDeliverer()
        deliverer.stubbedResult = .success(())

        let requestId = UUID()
        var activeRequestId: UUID? = requestId
        let tempURL = makeTempFile()

        let handoffExpectation = expectation(description: "share handoff")
        let completionExpectation = expectation(description: "final completion")
        var receivedOutcome: ExportDeliveryOutcome?

        let flow = ExportDeliveryFlow(
            requestId: requestId,
            deliverer: deliverer,
            policy: .photoLibraryThenShare,
            isRequestActive: { id in activeRequestId == id },
            clearRequestIfCurrent: { _ in activeRequestId = nil },
            completion: { outcome in
                receivedOutcome = outcome
                completionExpectation.fulfill()
            },
            shareHandoff: { _ in handoffExpectation.fulfill() }
        )

        flow.start(fileURL: tempURL, destination: .photoLibrary)
        wait(for: [handoffExpectation], timeout: 2)

        flow.finalizeAfterShare()
        wait(for: [completionExpectation], timeout: 2)

        if case .savedToPhotos = receivedOutcome {} else {
            XCTFail("Expected .savedToPhotos after finalizeAfterShare(), got \(String(describing: receivedOutcome))")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path),
                       "Temp file should be deleted after finalizeAfterShare()")
        XCTAssertNil(activeRequestId, "Active request must be cleared after share finalization")
    }

    func test_photoLibraryThenShare_failure_noShareHandoff() {
        let deliverer = MockDeliverer()
        let underlyingError = NSError(domain: "test", code: 88)
        deliverer.stubbedResult = .failure(.saveFailed(underlying: underlyingError))

        let requestId = UUID()
        var activeRequestId: UUID? = requestId
        let tempURL = makeTempFile()

        let exp = expectation(description: "outcome")
        var receivedOutcome: ExportDeliveryOutcome?
        var shareHandoffCalled = false

        let flow = ExportDeliveryFlow(
            requestId: requestId,
            deliverer: deliverer,
            policy: .photoLibraryThenShare,
            isRequestActive: { id in activeRequestId == id },
            clearRequestIfCurrent: { _ in activeRequestId = nil },
            completion: { outcome in
                receivedOutcome = outcome
                exp.fulfill()
            },
            shareHandoff: { _ in shareHandoffCalled = true }
        )

        flow.start(fileURL: tempURL, destination: .photoLibrary)
        wait(for: [exp], timeout: 2)

        if case .showError = receivedOutcome {} else {
            XCTFail("Expected .showError after failed Photos save, got \(String(describing: receivedOutcome))")
        }
        XCTAssertFalse(shareHandoffCalled, "Share handoff must not fire if Photos save fails")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path),
                       "Temp file should be deleted after failed Photos save")
        XCTAssertNil(activeRequestId, "Active request must be cleared after failed Photos save")
    }

    func test_deinit_cleansPendingShareFile() {
        let deliverer = MockDeliverer()
        deliverer.stubbedResult = .success(())

        let requestId = UUID()
        var activeRequestId: UUID? = requestId
        let tempURL = makeTempFile()

        let exp = expectation(description: "share handoff")
        var flow: ExportDeliveryFlow? = ExportDeliveryFlow(
            requestId: requestId,
            deliverer: deliverer,
            policy: .photoLibraryThenShare,
            isRequestActive: { id in activeRequestId == id },
            clearRequestIfCurrent: { _ in activeRequestId = nil },
            completion: { _ in XCTFail("Completion should not fire during deinit cleanup") },
            shareHandoff: { _ in exp.fulfill() }
        )

        flow?.start(fileURL: tempURL, destination: .photoLibrary)
        wait(for: [exp], timeout: 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path),
                      "Precondition: temp file should still exist before deinit")

        flow = nil

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path),
                       "deinit safety net should remove a pending share file")
    }
}
