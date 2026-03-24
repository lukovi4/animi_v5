import XCTest
@testable import AnimiApp

// MARK: - Mock

final class MockPhotoLibrarySaver: PhotoLibrarySaving {
    var stubbedResult: Result<Void, ExportDeliveryError> = .success(())

    private(set) var saveCallCount = 0
    private(set) var lastFileURL: URL?

    func save(fileURL: URL, completion: @escaping (Result<Void, ExportDeliveryError>) -> Void) {
        saveCallCount += 1
        lastFileURL = fileURL
        completion(stubbedResult)
    }
}

// MARK: - Tests

final class ExportDeliveryCoordinatorTests: XCTestCase {

    private var mockSaver: MockPhotoLibrarySaver!
    private var coordinator: ExportDeliveryCoordinator!
    private var tempFileURL: URL!

    override func setUp() {
        super.setUp()
        mockSaver = MockPhotoLibrarySaver()
        coordinator = ExportDeliveryCoordinator(saver: mockSaver)

        tempFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("delivery_test_\(UUID().uuidString).mp4")
        FileManager.default.createFile(atPath: tempFileURL.path, contents: Data([0x00]), attributes: nil)
    }

    override func tearDown() {
        // In case test didn't trigger cleanup
        try? FileManager.default.removeItem(at: tempFileURL)
        super.tearDown()
    }

    // MARK: - Scenarios

    func test_success_deletesTempFile() {
        mockSaver.stubbedResult = .success(())

        let exp = expectation(description: "deliver")
        coordinator.deliver(fileURL: tempFileURL, to: .photoLibrary) { result in
            if case .success = result {} else {
                XCTFail("Expected success, got \(result)")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempFileURL.path),
                       "Temp file should be deleted after successful delivery")
    }

    func test_permissionDenied_deletesTempFile() {
        mockSaver.stubbedResult = .failure(.permissionDenied)

        let exp = expectation(description: "deliver")
        coordinator.deliver(fileURL: tempFileURL, to: .photoLibrary) { result in
            if case .failure(.permissionDenied) = result {} else {
                XCTFail("Expected permissionDenied, got \(result)")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempFileURL.path),
                       "Temp file should be deleted even on permission denial")
    }

    func test_saveFailure_deletesTempFile() {
        let underlyingError = NSError(domain: "test", code: 99)
        mockSaver.stubbedResult = .failure(.saveFailed(underlying: underlyingError))

        let exp = expectation(description: "deliver")
        coordinator.deliver(fileURL: tempFileURL, to: .photoLibrary) { result in
            if case .failure(.saveFailed) = result {} else {
                XCTFail("Expected saveFailed, got \(result)")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempFileURL.path))
    }

    func test_completionFiresExactlyOnce() {
        mockSaver.stubbedResult = .success(())

        var completionCount = 0
        let exp = expectation(description: "deliver")
        coordinator.deliver(fileURL: tempFileURL, to: .photoLibrary) { _ in
            completionCount += 1
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(completionCount, 1, "Completion should fire exactly once")
        XCTAssertEqual(mockSaver.saveCallCount, 1, "Saver should be called exactly once")
    }
}
