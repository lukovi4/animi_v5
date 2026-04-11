import XCTest
@testable import AnimiApp

/// Tests for SceneMediaSlot Codable roundtrip.
final class SceneMediaSlotCodableTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    // MARK: - Roundtrip

    func test_photo_roundtrip() throws {
        let slot = SceneMediaSlot.photo(
            mediaRef: .file("Media/UserMedia/abc.jpg", mediaKind: .photo),
            visibility: true,
            placement: .defaultCover
        )

        let data = try encoder.encode(slot)
        let decoded = try decoder.decode(SceneMediaSlot.self, from: data)

        XCTAssertEqual(decoded.visibility, true)
        XCTAssertEqual(decoded.mediaRef.storagePath, "Media/UserMedia/abc.jpg")
        XCTAssertEqual(decoded.mediaRef.mediaKind, .photo)
        XCTAssertNil(decoded.videoWindow)
        XCTAssertTrue(decoded.placement.isDefault)
    }

    func test_video_roundtrip() throws {
        let slot = SceneMediaSlot.video(
            mediaRef: .file("Media/UserMedia/clip.mp4", mediaKind: .video),
            visibility: false,
            placement: .defaultCover,
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

    func test_withPlacement_roundtrip() throws {
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

        XCTAssertEqual(decoded.placement.fitMode, .contain)
        XCTAssertEqual(decoded.placement.offsetX, 10)
        XCTAssertEqual(decoded.placement.offsetY, -5)
        XCTAssertEqual(decoded.placement.userScale, 2.0)
        XCTAssertEqual(decoded.placement.rotationDegrees, 45)
    }

    // MARK: - Encode Format

    func test_encode_alwaysWritesNewFormat_withAssetKey() throws {
        let slot = SceneMediaSlot.photo(
            mediaRef: .file("Media/UserMedia/test.jpg", mediaKind: .photo),
            placement: .defaultCover
        )

        let data = try encoder.encode(slot)
        let jsonString = String(data: data, encoding: .utf8)!

        XCTAssertTrue(jsonString.contains("\"asset\""), "Encoded JSON must contain 'asset' key")
        XCTAssertTrue(jsonString.contains("\"visibility\""), "Encoded JSON must contain 'visibility'")
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
                placement: .defaultCover,
                videoWindow: PersistedVideoSelection(trimStart: 0, trimEnd: 5.0)
            )
        ]

        let data = try encoder.encode(state)
        let decoded = try decoder.decode(SceneState.self, from: data)

        let photoSlot = decoded.mediaSlotsByBlockId?["block1"]
        XCTAssertNotNil(photoSlot)
        XCTAssertEqual(photoSlot?.placement.fitMode, .cover)
        XCTAssertTrue(photoSlot?.placement.isDefault ?? false)

        let videoSlot = decoded.mediaSlotsByBlockId?["block2"]
        XCTAssertNotNil(videoSlot)
        XCTAssertTrue(videoSlot?.placement.isDefault ?? false)
        XCTAssertEqual(videoSlot?.videoWindow?.trimEnd, 5.0)
    }
}
