import XCTest
@testable import AnimiApp

/// Tests for v7 SceneMediaSlot persistence and ExportMediaError cases.
/// Legacy backward compat tests removed — v7 schema invalidates old drafts.
final class LegacyVideoSelectionCompatibilityTests: XCTestCase {

    // MARK: - SceneState v7 Media Slots

    /// SceneState JSON without mediaSlotsByBlockId decodes with nil slots.
    func test_sceneStateJSON_decodesWithNilMediaSlots() throws {
        let json = """
        {"variantOverrides":{},"userTransforms":{},"layerToggles":{}}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SceneState.self, from: data)

        XCTAssertNil(decoded.mediaSlotsByBlockId, "JSON without mediaSlotsByBlockId should decode as nil")
    }

    /// SceneState with mediaSlotsByBlockId containing a video slot roundtrips correctly.
    func test_sceneStateJSON_withVideoSlot_roundtrips() throws {
        var state = SceneState.empty
        state.mediaSlotsByBlockId = [
            "block1": .video(
                mediaRef: MediaRef(kind: .file, id: "Media/video.mp4", mediaKind: .video),
                visibility: true,
                videoWindow: PersistedVideoSelection(trimStart: 1.0, trimEnd: 8.0)
            )
        ]

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SceneState.self, from: data)

        XCTAssertNotNil(decoded.mediaSlotsByBlockId, "mediaSlotsByBlockId should be present")
        let slot = decoded.mediaSlotsByBlockId?["block1"]
        XCTAssertNotNil(slot)
        XCTAssertEqual(slot?.mediaRef.mediaKind, .video)
        XCTAssertEqual(slot?.visibility, true)
        XCTAssertEqual(slot?.videoWindow?.trimStart, 1.0)
        XCTAssertEqual(slot?.videoWindow?.trimEnd, 8.0)
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
