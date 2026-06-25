import XCTest
@testable import AnimiEngineCore

/// Slice 001 Stage B — typed audio identifier tests (plan §3.1, §9).
final class AudioIdentifierTests: XCTestCase {

    func testConstructionPreservesRaw() throws {
        XCTAssertEqual(try AudioSourceID("s1").raw, "s1")
        XCTAssertEqual(try AudioTrackID("t1").raw, "t1")
        XCTAssertEqual(try AudioClipID("c1").raw, "c1")
        XCTAssertEqual(try GlobalAudioAssetID("g1").raw, "g1")
    }

    func testEmptyIdentifierRejected() {
        XCTAssertThrowsError(try AudioSourceID("")) { XCTAssertEqual($0 as? ProjectValidationError, .emptyIdentifier) }
        XCTAssertThrowsError(try AudioTrackID("")) { XCTAssertEqual($0 as? ProjectValidationError, .emptyIdentifier) }
        XCTAssertThrowsError(try AudioClipID("")) { XCTAssertEqual($0 as? ProjectValidationError, .emptyIdentifier) }
        XCTAssertThrowsError(try GlobalAudioAssetID("")) { XCTAssertEqual($0 as? ProjectValidationError, .emptyIdentifier) }
    }

    func testOrdering() throws {
        // Comparable orders lexicographically by raw — required for deterministic encoder ordering.
        XCTAssertTrue(try AudioSourceID("a") < AudioSourceID("b"))
        XCTAssertTrue(try AudioTrackID("a") < AudioTrackID("b"))
        XCTAssertTrue(try AudioClipID("a") < AudioClipID("b"))
        XCTAssertTrue(try GlobalAudioAssetID("a") < GlobalAudioAssetID("b"))

        let unsorted = try [AudioSourceID("c"), AudioSourceID("a"), AudioSourceID("b")]
        XCTAssertEqual(unsorted.sorted().map(\.raw), ["a", "b", "c"])
    }

    func testEquatableAndHashable() throws {
        XCTAssertEqual(try AudioSourceID("x"), try AudioSourceID("x"))
        XCTAssertNotEqual(try AudioSourceID("x"), try AudioSourceID("y"))
        let set: Set<AudioTrackID> = try [AudioTrackID("a"), AudioTrackID("a"), AudioTrackID("b")]
        XCTAssertEqual(set.count, 2)
    }
}
