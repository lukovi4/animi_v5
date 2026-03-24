import XCTest
import Photos
@testable import AnimiApp

// MARK: - Mock

final class MockPhotoLibrary: PhotoLibraryAccessing {
    var stubbedStatus: PHAuthorizationStatus = .authorized
    var stubbedRequestResult: PHAuthorizationStatus = .authorized
    var stubbedSaveSuccess: Bool = true
    var stubbedSaveError: Error? = nil

    private(set) var requestAuthorizationCalled = false
    private(set) var saveVideoCalled = false

    /// When non-nil, requestAddOnlyAuthorization stores its callback here
    /// instead of calling it immediately. The test calls it manually later.
    var deferredAuthorizationCallback: ((PHAuthorizationStatus) -> Void)?
    var deferAuthorization = false

    func currentAuthorizationStatus() -> PHAuthorizationStatus {
        stubbedStatus
    }

    func requestAddOnlyAuthorization(completion: @escaping (PHAuthorizationStatus) -> Void) {
        requestAuthorizationCalled = true
        if deferAuthorization {
            deferredAuthorizationCallback = completion
        } else {
            completion(stubbedRequestResult)
        }
    }

    func saveVideo(at fileURL: URL, completion: @escaping (Bool, Error?) -> Void) {
        saveVideoCalled = true
        completion(stubbedSaveSuccess, stubbedSaveError)
    }
}

// MARK: - Tests

final class PhotoLibraryVideoSaveServiceTests: XCTestCase {

    private var mockLibrary: MockPhotoLibrary!
    private var service: PhotoLibraryVideoSaveService!
    private var tempFileURL: URL!

    override func setUp() {
        super.setUp()
        mockLibrary = MockPhotoLibrary()
        service = PhotoLibraryVideoSaveService(library: mockLibrary)

        tempFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(UUID().uuidString).mp4")
        FileManager.default.createFile(atPath: tempFileURL.path, contents: Data([0x00]), attributes: nil)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempFileURL)
        super.tearDown()
    }

    // MARK: - Scenarios

    func test_authorized_savesSuccessfully() {
        mockLibrary.stubbedStatus = .authorized

        let exp = expectation(description: "save")
        service.save(fileURL: tempFileURL) { result in
            if case .success = result {} else {
                XCTFail("Expected success, got \(result)")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
        XCTAssertTrue(mockLibrary.saveVideoCalled)
        XCTAssertFalse(mockLibrary.requestAuthorizationCalled)
    }

    func test_notDetermined_requestsAuth_thenSaves() {
        mockLibrary.stubbedStatus = .notDetermined
        mockLibrary.stubbedRequestResult = .authorized

        let exp = expectation(description: "save")
        service.save(fileURL: tempFileURL) { result in
            if case .success = result {} else {
                XCTFail("Expected success, got \(result)")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
        XCTAssertTrue(mockLibrary.requestAuthorizationCalled)
        XCTAssertTrue(mockLibrary.saveVideoCalled)
    }

    func test_denied_returnsPermissionDenied() {
        mockLibrary.stubbedStatus = .denied

        let exp = expectation(description: "save")
        service.save(fileURL: tempFileURL) { result in
            if case .failure(.permissionDenied) = result {} else {
                XCTFail("Expected permissionDenied, got \(result)")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
        XCTAssertFalse(mockLibrary.saveVideoCalled)
    }

    func test_restricted_returnsPermissionRestricted() {
        mockLibrary.stubbedStatus = .restricted

        let exp = expectation(description: "save")
        service.save(fileURL: tempFileURL) { result in
            if case .failure(.permissionRestricted) = result {} else {
                XCTFail("Expected permissionRestricted, got \(result)")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    func test_saveFailed_returnsError() {
        mockLibrary.stubbedStatus = .authorized
        mockLibrary.stubbedSaveSuccess = false
        mockLibrary.stubbedSaveError = NSError(domain: "test", code: 42)

        let exp = expectation(description: "save")
        service.save(fileURL: tempFileURL) { result in
            if case .failure(.saveFailed(let underlying)) = result {
                XCTAssertEqual((underlying as? NSError)?.code, 42)
            } else {
                XCTFail("Expected saveFailed, got \(result)")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    func test_missingFile_returnsExportFileMissing() {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent_\(UUID().uuidString).mp4")

        let exp = expectation(description: "save")
        service.save(fileURL: missingURL) { result in
            if case .failure(.exportFileMissing) = result {} else {
                XCTFail("Expected exportFileMissing, got \(result)")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    // MARK: - Regression: async authorization must not break on service deallocation

    /// Verifies that the authorization→save chain completes even when the external
    /// strong reference to the service is released before the auth callback fires.
    /// This regresses the old [weak self] capture in the .notDetermined branch.
    func test_notDetermined_asyncAuthorizationStillContinuesSave() {
        let mockLib = MockPhotoLibrary()
        mockLib.stubbedStatus = .notDetermined
        mockLib.stubbedRequestResult = .authorized
        mockLib.deferAuthorization = true

        var service: PhotoLibraryVideoSaveService? = PhotoLibraryVideoSaveService(library: mockLib)

        let exp = expectation(description: "save completes after deferred auth")
        service!.save(fileURL: tempFileURL) { result in
            if case .success = result {} else {
                XCTFail("Expected success after deferred authorization, got \(result)")
            }
            exp.fulfill()
        }

        // Drop external strong reference — old [weak self] would nil out here
        service = nil

        // Now fire the deferred authorization callback
        XCTAssertNotNil(mockLib.deferredAuthorizationCallback,
                        "Authorization callback should have been captured")
        mockLib.deferredAuthorizationCallback?(.authorized)

        wait(for: [exp], timeout: 2)
        XCTAssertTrue(mockLib.saveVideoCalled,
                      "saveVideo must be called even after external reference is released")
    }
}
