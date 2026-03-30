import XCTest
@testable import AnimiApp

/// Tests for SceneMediaSlot backward-compatible Codable.
final class SceneMediaSlotCodableTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    // MARK: - New Format Roundtrip

    func test_newFormat_photo_roundtrip() throws {
        let slot = SceneMediaSlot.photo(
            mediaRef: .file("Media/UserMedia/abc.jpg", mediaKind: .photo),
            visibility: true
        )

        let data = try encoder.encode(slot)
        let decoded = try decoder.decode(SceneMediaSlot.self, from: data)

        XCTAssertEqual(decoded.visibility, true)
        XCTAssertEqual(decoded.mediaRef.id, "Media/UserMedia/abc.jpg")
        XCTAssertEqual(decoded.mediaRef.mediaKind, .photo)
        XCTAssertNil(decoded.videoWindow)
        XCTAssertNil(decoded.placement, "New photo without explicit placement should have nil placement")
    }

    func test_newFormat_video_roundtrip() throws {
        let slot = SceneMediaSlot.video(
            mediaRef: .file("Media/UserMedia/clip.mp4", mediaKind: .video),
            visibility: false,
            videoWindow: PersistedVideoSelection(trimStart: 1.0, trimEnd: 10.0, isMuted: true, volume: 0.5)
        )

        let data = try encoder.encode(slot)
        let decoded = try decoder.decode(SceneMediaSlot.self, from: data)

        XCTAssertEqual(decoded.visibility, false)
        XCTAssertEqual(decoded.mediaRef.mediaKind, .video)
        XCTAssertEqual(decoded.videoWindow?.trimStart, 1.0)
        XCTAssertEqual(decoded.videoWindow?.trimEnd, 10.0)
        XCTAssertEqual(decoded.videoWindow?.isMuted, true)
        XCTAssertEqual(decoded.videoWindow?.volume, 0.5)
    }

    func test_newFormat_withPlacement_roundtrip() throws {
        let placement = MediaPlacementState(
            fitMode: .contain,
            offsetX: 10,
            offsetY: -5,
            userScale: 2.0,
            rotationDegrees: 45
        )
        let slot = SceneMediaSlot.photo(
            mediaRef: .file("Media/UserMedia/photo.heic", mediaKind: .photo),
            placement: placement
        )

        let data = try encoder.encode(slot)
        let decoded = try decoder.decode(SceneMediaSlot.self, from: data)

        XCTAssertNotNil(decoded.placement)
        XCTAssertEqual(decoded.placement?.fitMode, .contain)
        XCTAssertEqual(decoded.placement?.offsetX, 10)
        XCTAssertEqual(decoded.placement?.offsetY, -5)
        XCTAssertEqual(decoded.placement?.userScale, 2.0)
        XCTAssertEqual(decoded.placement?.rotationDegrees, 45)
    }

    // MARK: - Legacy v8 Flat Format Decode

    func test_legacyFlatFormat_photo_decodesWithNilPlacement() throws {
        let json = """
        {
            "mediaRef": {"kind": "file", "id": "Media/UserMedia/old.jpg", "mediaKind": "photo"},
            "visibility": true
        }
        """
        let data = Data(json.utf8)
        let decoded = try decoder.decode(SceneMediaSlot.self, from: data)

        XCTAssertEqual(decoded.visibility, true)
        XCTAssertEqual(decoded.mediaRef.id, "Media/UserMedia/old.jpg")
        XCTAssertEqual(decoded.mediaRef.mediaKind, .photo)
        XCTAssertNil(decoded.placement, "Legacy format must decode with nil placement")
        XCTAssertNil(decoded.videoWindow)
    }

    func test_legacyFlatFormat_video_decodesWithNilPlacement() throws {
        let json = """
        {
            "mediaRef": {"kind": "file", "id": "Media/UserMedia/old.mp4", "mediaKind": "video"},
            "visibility": false,
            "videoWindow": {"trimStart": 2.0, "trimEnd": 15.0, "isMuted": false, "volume": 1.0}
        }
        """
        let data = Data(json.utf8)
        let decoded = try decoder.decode(SceneMediaSlot.self, from: data)

        XCTAssertEqual(decoded.visibility, false)
        XCTAssertEqual(decoded.mediaRef.mediaKind, .video)
        XCTAssertNil(decoded.placement, "Legacy format must decode with nil placement")
        XCTAssertEqual(decoded.videoWindow?.trimStart, 2.0)
        XCTAssertEqual(decoded.videoWindow?.trimEnd, 15.0)
    }

    // MARK: - Encode Always Writes New Format

    func test_encode_alwaysWritesNewFormat_withAssetKey() throws {
        let slot = SceneMediaSlot.photo(
            mediaRef: .file("Media/UserMedia/test.jpg", mediaKind: .photo)
        )

        let data = try encoder.encode(slot)
        let jsonString = String(data: data, encoding: .utf8)!

        XCTAssertTrue(jsonString.contains("\"asset\""), "Encoded JSON must contain 'asset' key (new format)")
        XCTAssertTrue(jsonString.contains("\"visibility\""), "Encoded JSON must contain 'visibility'")
        // Should NOT contain top-level 'mediaRef' (that's inside asset now)
        // The key "mediaRef" will appear, but nested inside "asset"
    }

    // MARK: - SceneState Integration

    func test_sceneState_withNewSlotFormat_roundtrips() throws {
        var state = SceneState.empty
        state.mediaSlotsByBlockId = [
            "block1": .photo(
                mediaRef: .file("Media/UserMedia/pic.jpg", mediaKind: .photo),
                placement: .default(fitMode: .cover)
            ),
            "block2": .video(
                mediaRef: .file("Media/UserMedia/vid.mp4", mediaKind: .video),
                videoWindow: PersistedVideoSelection(trimStart: 0, trimEnd: 5.0)
            )
        ]

        let data = try encoder.encode(state)
        let decoded = try decoder.decode(SceneState.self, from: data)

        let photoSlot = decoded.mediaSlotsByBlockId?["block1"]
        XCTAssertNotNil(photoSlot)
        XCTAssertEqual(photoSlot?.placement?.fitMode, .cover)
        XCTAssertTrue(photoSlot?.placement?.isDefault ?? false)

        let videoSlot = decoded.mediaSlotsByBlockId?["block2"]
        XCTAssertNotNil(videoSlot)
        XCTAssertNil(videoSlot?.placement, "Video slot without explicit placement should have nil")
        XCTAssertEqual(videoSlot?.videoWindow?.trimEnd, 5.0)
    }

    func test_sceneState_withLegacySlotJSON_decodesCorrectly() throws {
        // Simulates a full SceneState JSON with legacy slot format
        let json = """
        {
            "variantOverrides": {},
            "userTransforms": {},
            "layerToggles": {},
            "mediaSlotsByBlockId": {
                "block1": {
                    "mediaRef": {"kind": "file", "id": "Media/UserMedia/old.jpg"},
                    "visibility": true
                }
            }
        }
        """
        let data = Data(json.utf8)
        let decoded = try decoder.decode(SceneState.self, from: data)

        let slot = decoded.mediaSlotsByBlockId?["block1"]
        XCTAssertNotNil(slot)
        XCTAssertEqual(slot?.mediaRef.id, "Media/UserMedia/old.jpg")
        XCTAssertNil(slot?.placement, "Legacy slot inside SceneState must have nil placement")
    }
}
