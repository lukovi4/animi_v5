import XCTest
@testable import AnimiApp

/// Tests for MediaRef.mediaKind backward-compatible Codable and extension inference.
final class MediaRefMediaKindTests: XCTestCase {

    // MARK: - Backward-Compatible Decode

    func test_decode_withoutMediaKind_infersPhoto() throws {
        // JSON without mediaKind field (old format)
        let json = """
        {"kind": "file", "id": "Media/UserMedia/photo.jpg"}
        """
        let data = Data(json.utf8)
        let ref = try JSONDecoder().decode(MediaRef.self, from: data)

        XCTAssertEqual(ref.kind, .file)
        XCTAssertEqual(ref.id, "Media/UserMedia/photo.jpg")
        XCTAssertEqual(ref.mediaKind, .photo, "Should infer .photo from .jpg extension")
    }

    func test_decode_withoutMediaKind_infersVideo_mov() throws {
        let json = """
        {"kind": "file", "id": "Media/UserMedia/clip.mov"}
        """
        let data = Data(json.utf8)
        let ref = try JSONDecoder().decode(MediaRef.self, from: data)

        XCTAssertEqual(ref.mediaKind, .video, "Should infer .video from .mov extension")
    }

    func test_decode_withoutMediaKind_infersVideo_mp4() throws {
        let json = """
        {"kind": "file", "id": "Media/UserMedia/clip.mp4"}
        """
        let data = Data(json.utf8)
        let ref = try JSONDecoder().decode(MediaRef.self, from: data)

        XCTAssertEqual(ref.mediaKind, .video, "Should infer .video from .mp4 extension")
    }

    func test_decode_withoutMediaKind_infersVideo_m4v() throws {
        let json = """
        {"kind": "file", "id": "Media/UserMedia/clip.m4v"}
        """
        let data = Data(json.utf8)
        let ref = try JSONDecoder().decode(MediaRef.self, from: data)

        XCTAssertEqual(ref.mediaKind, .video, "Should infer .video from .m4v extension")
    }

    func test_decode_withoutMediaKind_infersPhoto_heic() throws {
        let json = """
        {"kind": "file", "id": "Media/UserMedia/photo.heic"}
        """
        let data = Data(json.utf8)
        let ref = try JSONDecoder().decode(MediaRef.self, from: data)

        XCTAssertEqual(ref.mediaKind, .photo, "Should infer .photo from .heic extension")
    }

    func test_decode_withoutMediaKind_infersPhoto_png() throws {
        let json = """
        {"kind": "file", "id": "Media/Background/bg.png"}
        """
        let data = Data(json.utf8)
        let ref = try JSONDecoder().decode(MediaRef.self, from: data)

        XCTAssertEqual(ref.mediaKind, .photo, "Should infer .photo from .png extension")
    }

    // MARK: - New Encode Includes mediaKind

    func test_encode_includesMediaKind() throws {
        let ref = MediaRef(kind: .file, id: "Media/UserMedia/photo.jpg", mediaKind: .photo)
        let data = try JSONEncoder().encode(ref)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(dict?["mediaKind"] as? String, "photo")
    }

    func test_encode_video_includesMediaKind() throws {
        let ref = MediaRef(kind: .file, id: "Media/UserMedia/clip.mov", mediaKind: .video)
        let data = try JSONEncoder().encode(ref)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(dict?["mediaKind"] as? String, "video")
    }

    // MARK: - Decode With mediaKind Present

    func test_decode_withMediaKind_usesExplicit() throws {
        let json = """
        {"kind": "file", "id": "Media/UserMedia/file.dat", "mediaKind": "video"}
        """
        let data = Data(json.utf8)
        let ref = try JSONDecoder().decode(MediaRef.self, from: data)

        XCTAssertEqual(ref.mediaKind, .video, "Should use explicit mediaKind, not infer from extension")
    }

    // MARK: - Round-Trip

    func test_roundTrip_preservesMediaKind() throws {
        let original = MediaRef(kind: .file, id: "Media/UserMedia/clip.mov", mediaKind: .video)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MediaRef.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    // MARK: - Factory Methods

    func test_fileFactory_defaultsToPhoto() {
        let ref = MediaRef.file("Media/UserMedia/photo.jpg")
        XCTAssertEqual(ref.mediaKind, .photo)
    }

    func test_fileFactory_explicitVideo() {
        let ref = MediaRef.file("Media/UserMedia/clip.mov", mediaKind: .video)
        XCTAssertEqual(ref.mediaKind, .video)
    }

    func test_initFactory_defaultsToPhoto() {
        let ref = MediaRef(kind: .file, id: "Media/UserMedia/photo.jpg")
        XCTAssertEqual(ref.mediaKind, .photo)
    }
}
