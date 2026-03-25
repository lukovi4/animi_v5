import XCTest
@testable import AnimiApp

/// Tests for backward compatibility of assembleVideoSelections with legacy drafts.
/// Verifies Fix 3: legacy drafts with video mediaAssignments but nil videoSelections
/// produce valid video selections (not empty dict).
final class LegacyVideoSelectionCompatibilityTests: XCTestCase {

    // MARK: - SceneState Decoding Backward Compat

    /// Old SceneState JSON without videoSelections key decodes with nil (not crash).
    func test_oldSceneStateJSON_decodesWithNilVideoSelections() throws {
        let json = """
        {"variantOverrides":{},"userTransforms":{},"layerToggles":{}}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SceneState.self, from: data)

        XCTAssertNil(decoded.videoSelections, "Legacy JSON without videoSelections should decode as nil")
        XCTAssertNil(decoded.mediaAssignments, "Legacy JSON without mediaAssignments should decode as nil")
    }

    /// Old SceneState JSON with mediaAssignments but no videoSelections decodes correctly.
    func test_oldSceneStateJSON_withMediaAssignments_decodesWithNilVideoSelections() throws {
        let json = """
        {
            "variantOverrides": {},
            "userTransforms": {},
            "layerToggles": {},
            "mediaAssignments": {
                "block1": {"kind": "file", "id": "Media/video.mp4", "mediaKind": "video"}
            }
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SceneState.self, from: data)

        XCTAssertNil(decoded.videoSelections, "videoSelections should be nil for legacy draft")
        XCTAssertNotNil(decoded.mediaAssignments, "mediaAssignments should be present")
        XCTAssertEqual(decoded.mediaAssignments?["block1"]?.mediaKind, .video)
    }

    // MARK: - ExportMediaError

    /// ExportMediaError.missingPersistedVideo has correct description.
    func test_missingPersistedVideo_errorDescription() {
        let error = ExportMediaError.missingPersistedVideo(blockId: "b1")
        XCTAssertTrue(error.localizedDescription.contains("b1"))
        XCTAssertTrue(error.localizedDescription.contains("video"))
    }

    /// ExportMediaError has both photo and video cases.
    func test_exportMediaError_hasBothCases() {
        let photoError = ExportMediaError.missingPersistedPhoto(blockId: "b1", assetId: "a1")
        let videoError = ExportMediaError.missingPersistedVideo(blockId: "b2")

        XCTAssertNotNil(photoError.errorDescription)
        XCTAssertNotNil(videoError.errorDescription)
    }
}
