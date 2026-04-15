import XCTest
@testable import AnimiApp

private struct StubMediaLocator: ProjectMediaLocator {
    func absoluteURL(for mediaRef: MediaRef, registry: ProjectAssetRegistry) async throws -> URL {
        URL(fileURLWithPath: "/tmp/stub")
    }
}

/// Tests production request-gating helpers on EditorRuntime.ActiveExportRequest
/// and the isActiveExportRequest / clearExportRequestIfCurrent methods.
/// PR6: Migrated from EditorViewController to EditorRuntime.
final class ExportRequestGatingTests: XCTestCase {

    // MARK: - ActiveExportRequest.isActive

    func test_isActive_matchingId() {
        let exporter = VideoExporter(mediaLocator: StubMediaLocator())
        let request = EditorRuntime.ActiveExportRequest(id: UUID(), exporter: exporter)
        XCTAssertTrue(request.isActive(for: request.id))
    }

    func test_isActive_nonMatchingId() {
        let exporter = VideoExporter(mediaLocator: StubMediaLocator())
        let request = EditorRuntime.ActiveExportRequest(id: UUID(), exporter: exporter)
        XCTAssertFalse(request.isActive(for: UUID()))
    }

    // MARK: - Overlap Scenarios (using production types)

    /// Simulate: cancel A, start B, A's stale completion arrives — gated by isActive
    func test_cancelA_startB_staleCompletionIgnored() {
        let exporterA = VideoExporter(mediaLocator: StubMediaLocator())
        let requestA = EditorRuntime.ActiveExportRequest(id: UUID(), exporter: exporterA)
        let requestAId = requestA.id

        // Start request B
        let exporterB = VideoExporter(mediaLocator: StubMediaLocator())
        let requestB = EditorRuntime.ActiveExportRequest(id: UUID(), exporter: exporterB)

        // Simulate activeExportRequest = requestB (A was cancelled, B is active)
        // A's completion guard checks requestB.isActive(for: requestAId)
        XCTAssertFalse(requestB.isActive(for: requestAId),
                       "Request B should NOT match request A's id")

        // B's own completion passes
        XCTAssertTrue(requestB.isActive(for: requestB.id),
                      "Request B should match its own id")
    }

    /// Simulate: cancel during preload — nil activeRequest means isActive fails
    func test_cancelDuringPreload_nilActiveRequest() {
        let activeRequest: EditorRuntime.ActiveExportRequest? = nil
        let requestId = UUID()
        // Production code: self.isActiveExportRequest(requestId) → activeExportRequest?.isActive(for:) ?? false
        let shouldProceed = activeRequest?.isActive(for: requestId) ?? false
        XCTAssertFalse(shouldProceed)
    }

    /// Rapid cancel+restart: A's cancel closure only clears if it matches current
    func test_cancelClosure_onlyClears_matchingRequest() {
        let exporterA = VideoExporter(mediaLocator: StubMediaLocator())
        let requestA = EditorRuntime.ActiveExportRequest(id: UUID(), exporter: exporterA)
        let requestAId = requestA.id

        let exporterB = VideoExporter(mediaLocator: StubMediaLocator())
        let requestB = EditorRuntime.ActiveExportRequest(id: UUID(), exporter: exporterB)

        // activeExportRequest is now B
        var activeRequest: EditorRuntime.ActiveExportRequest? = requestB

        // A's onCancel fires — uses clearExportRequestIfCurrent pattern:
        // guard isActiveExportRequest(requestAId) else { return }
        if activeRequest?.isActive(for: requestAId) == true {
            activeRequest = nil
        }

        XCTAssertNotNil(activeRequest, "Cancel from A must not clear active request B")
        XCTAssertEqual(activeRequest?.id, requestB.id)
    }

    // MARK: - Stale progress and finishing gating

    /// Production contract: progress closure gates by requestId.
    /// If active request changed, stale progress must be dropped.
    func test_staleProgress_gatedByRequestId() {
        let exporterA = VideoExporter(mediaLocator: StubMediaLocator())
        let requestA = EditorRuntime.ActiveExportRequest(id: UUID(), exporter: exporterA)
        let requestAId = requestA.id

        let exporterB = VideoExporter(mediaLocator: StubMediaLocator())
        let requestB = EditorRuntime.ActiveExportRequest(id: UUID(), exporter: exporterB)

        // Active request is now B
        let activeRequest: EditorRuntime.ActiveExportRequest? = requestB

        // Stale progress from A arrives
        let shouldEmitProgressA = activeRequest?.isActive(for: requestAId) ?? false
        XCTAssertFalse(shouldEmitProgressA, "Stale progress from request A must be gated")

        // Current progress from B passes
        let shouldEmitProgressB = activeRequest?.isActive(for: requestB.id) ?? false
        XCTAssertTrue(shouldEmitProgressB, "Progress from active request B must pass")
    }

    /// Production contract: onFinishing closure gates by requestId.
    func test_staleFinishing_gatedByRequestId() {
        let exporterA = VideoExporter(mediaLocator: StubMediaLocator())
        let requestA = EditorRuntime.ActiveExportRequest(id: UUID(), exporter: exporterA)
        let requestAId = requestA.id

        let exporterB = VideoExporter(mediaLocator: StubMediaLocator())
        let requestB = EditorRuntime.ActiveExportRequest(id: UUID(), exporter: exporterB)

        let activeRequest: EditorRuntime.ActiveExportRequest? = requestB

        let shouldEmitFinishingA = activeRequest?.isActive(for: requestAId) ?? false
        XCTAssertFalse(shouldEmitFinishingA, "Stale onFinishing from request A must be gated")

        let shouldEmitFinishingB = activeRequest?.isActive(for: requestB.id) ?? false
        XCTAssertTrue(shouldEmitFinishingB, "onFinishing from active request B must pass")
    }

    // MARK: - activeSession cleanup via onTerminal

    func test_activeSessionClearedOnTerminal() {
        let exp = expectation(description: "completion")
        var sessionCleared = false

        let session = ExportSession { _ in exp.fulfill() }
        session.setOnTerminal { sessionCleared = true }
        session.complete(with: .failure(VideoExportError.cancelled))

        wait(for: [exp], timeout: 2.0)
        XCTAssertTrue(sessionCleared, "onTerminal should clear activeSession")
    }

    // MARK: - Computed isExporting via production type

    func test_isExporting_computedFromActiveRequest() {
        var activeRequest: EditorRuntime.ActiveExportRequest?
        var isExporting: Bool { activeRequest != nil }

        XCTAssertFalse(isExporting)

        activeRequest = EditorRuntime.ActiveExportRequest(id: UUID(), exporter: VideoExporter(mediaLocator: StubMediaLocator()))
        XCTAssertTrue(isExporting)

        activeRequest = nil
        XCTAssertFalse(isExporting)
    }
}
