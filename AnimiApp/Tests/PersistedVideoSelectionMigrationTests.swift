import XCTest
@testable import AnimiApp

/// Tests for legacy offset migration in PersistedVideoSelection Codable.
final class PersistedVideoSelectionMigrationTests: XCTestCase {

    // MARK: - Legacy Decode

    func test_legacyDecode_migratesOffset() throws {
        let json = """
        {"trimStart": 1.0, "trimEnd": 5.0, "offset": 2.0, "isMuted": false, "volume": 1.0}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PersistedVideoSelection.self, from: data)

        XCTAssertEqual(decoded.trimStart, 3.0, "trimStart should be shifted by offset")
        XCTAssertEqual(decoded.trimEnd, 7.0, "trimEnd should be shifted by offset")
    }

    func test_legacyDecode_zeroOffset_noShift() throws {
        let json = """
        {"trimStart": 1.0, "trimEnd": 5.0, "offset": 0, "isMuted": false, "volume": 1.0}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PersistedVideoSelection.self, from: data)

        XCTAssertEqual(decoded.trimStart, 1.0)
        XCTAssertEqual(decoded.trimEnd, 5.0)
    }

    func test_legacyDecode_noOffsetKey_noShift() throws {
        let json = """
        {"trimStart": 1.0, "trimEnd": 5.0, "isMuted": false, "volume": 1.0}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PersistedVideoSelection.self, from: data)

        XCTAssertEqual(decoded.trimStart, 1.0)
        XCTAssertEqual(decoded.trimEnd, 5.0)
    }

    // MARK: - Encode

    func test_encode_doesNotWriteOffset() throws {
        let pvs = PersistedVideoSelection(trimStart: 2.0, trimEnd: 8.0)
        let data = try JSONEncoder().encode(pvs)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertNil(dict["offset"], "Encoded JSON should not contain offset key")
    }

    // MARK: - Round-Trip

    func test_roundTrip_newFormat() throws {
        let original = PersistedVideoSelection(trimStart: 3.5, trimEnd: 9.2, isMuted: true, volume: 0.6)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PersistedVideoSelection.self, from: data)

        XCTAssertEqual(decoded.trimStart, 3.5, accuracy: 1e-12)
        XCTAssertEqual(decoded.trimEnd, 9.2, accuracy: 1e-12)
        XCTAssertEqual(decoded.isMuted, true)
        XCTAssertEqual(decoded.volume, 0.6, accuracy: 0.001)
    }

    // MARK: - Negative Offset

    func test_legacyDecode_negativeOffset() throws {
        let json = """
        {"trimStart": 3.0, "trimEnd": 7.0, "offset": -1.5, "isMuted": false, "volume": 1.0}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PersistedVideoSelection.self, from: data)

        XCTAssertEqual(decoded.trimStart, 1.5, accuracy: 1e-12, "trimStart should be shifted by negative offset")
        XCTAssertEqual(decoded.trimEnd, 5.5, accuracy: 1e-12, "trimEnd should be shifted by negative offset")
    }
}
