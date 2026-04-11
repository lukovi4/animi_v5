import XCTest
@testable import AnimiApp

/// Tests for MediaRef new schema: assetId, mediaKind, storagePath.
final class MediaRefMediaKindTests: XCTestCase {

    // MARK: - Encoding

    func test_encode_includesAssetId_mediaKind_storagePath() throws {
        let assetId = ProjectAssetID()
        let ref = MediaRef(storagePath: "Media/UserMedia/photo.jpg", mediaKind: .photo, assetId: assetId)
        let data = try JSONEncoder().encode(ref)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(dict?["assetId"], "Encoded JSON must contain 'assetId'")
        XCTAssertEqual(dict?["mediaKind"] as? String, "photo")
        XCTAssertEqual(dict?["storagePath"] as? String, "Media/UserMedia/photo.jpg")
    }

    func test_encode_video_includesMediaKind() throws {
        let ref = MediaRef(storagePath: "Media/UserMedia/clip.mov", mediaKind: .video)
        let data = try JSONEncoder().encode(ref)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(dict?["mediaKind"] as? String, "video")
    }

    // MARK: - Decoding from new format

    func test_decode_newFormat_photo() throws {
        let assetId = ProjectAssetID()
        let json = """
        {"assetId": {"rawValue": "\(assetId.rawValue.uuidString)"}, "mediaKind": "photo", "storagePath": "Media/UserMedia/photo.jpg"}
        """
        let data = Data(json.utf8)
        let ref = try JSONDecoder().decode(MediaRef.self, from: data)

        XCTAssertEqual(ref.assetId, assetId)
        XCTAssertEqual(ref.storagePath, "Media/UserMedia/photo.jpg")
        XCTAssertEqual(ref.mediaKind, .photo)
    }

    // MARK: - Round-Trip

    func test_roundTrip_photo_preservesAllFields() throws {
        let original = MediaRef(storagePath: "Media/UserMedia/photo.heic", mediaKind: .photo)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MediaRef.self, from: data)

        XCTAssertEqual(decoded.assetId, original.assetId)
        XCTAssertEqual(decoded.storagePath, original.storagePath)
        XCTAssertEqual(decoded.mediaKind, original.mediaKind)
        XCTAssertEqual(decoded, original)
    }

    func test_roundTrip_video_preservesAllFields() throws {
        let original = MediaRef(storagePath: "Media/UserMedia/clip.mov", mediaKind: .video)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MediaRef.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.mediaKind, MediaKind.video)
        XCTAssertEqual(decoded.storagePath, "Media/UserMedia/clip.mov")
    }

    // MARK: - Factory Methods

    func test_fileFactory_defaultsToPhoto() {
        let ref = MediaRef.file("Media/UserMedia/photo.jpg")
        XCTAssertEqual(ref.mediaKind, .photo)
        XCTAssertEqual(ref.storagePath, "Media/UserMedia/photo.jpg")
    }

    func test_fileFactory_explicitVideo() {
        let ref = MediaRef.file("Media/UserMedia/clip.mov", mediaKind: .video)
        XCTAssertEqual(ref.mediaKind, .video)
        XCTAssertEqual(ref.storagePath, "Media/UserMedia/clip.mov")
    }

    func test_fileFactory_generatesUniqueAssetIds() {
        let ref1 = MediaRef.file("Media/UserMedia/photo.jpg")
        let ref2 = MediaRef.file("Media/UserMedia/photo.jpg")
        XCTAssertNotEqual(ref1.assetId, ref2.assetId)
    }

    // MARK: - Equality by assetId

    func test_equality_isByAssetId_notByStoragePath() {
        let assetId = ProjectAssetID()
        let ref1 = MediaRef(storagePath: "Media/path/a.jpg", mediaKind: .photo, assetId: assetId)
        let ref2 = MediaRef(storagePath: "Media/path/b.jpg", mediaKind: .photo, assetId: assetId)

        XCTAssertEqual(ref1, ref2, "Two refs with same assetId must be equal regardless of storagePath")
    }

    func test_inequality_differentAssetIds() {
        let ref1 = MediaRef(storagePath: "Media/UserMedia/photo.jpg", mediaKind: .photo)
        let ref2 = MediaRef(storagePath: "Media/UserMedia/photo.jpg", mediaKind: .photo)

        XCTAssertNotEqual(ref1, ref2, "Refs with different auto-generated assetIds must not be equal")
    }

    // MARK: - Hash by assetId

    func test_hash_isByAssetId() {
        let assetId = ProjectAssetID()
        let ref1 = MediaRef(storagePath: "Media/path/a.jpg", mediaKind: .photo, assetId: assetId)
        let ref2 = MediaRef(storagePath: "Media/path/z.mp4", mediaKind: .video, assetId: assetId)

        var hasher1 = Hasher()
        ref1.hash(into: &hasher1)
        var hasher2 = Hasher()
        ref2.hash(into: &hasher2)

        XCTAssertEqual(hasher1.finalize(), hasher2.finalize(), "Hash must be the same for same assetId")
    }

    func test_usableAsSetElement_deduplicatesByAssetId() {
        let assetId = ProjectAssetID()
        let ref1 = MediaRef(storagePath: "Media/path/a.jpg", mediaKind: .photo, assetId: assetId)
        let ref2 = MediaRef(storagePath: "Media/path/b.jpg", mediaKind: .photo, assetId: assetId)

        let set: Set<MediaRef> = [ref1, ref2]
        XCTAssertEqual(set.count, 1, "Set must deduplicate refs with same assetId")
    }
}
