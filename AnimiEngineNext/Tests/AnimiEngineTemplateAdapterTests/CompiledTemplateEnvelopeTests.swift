import XCTest
@testable import AnimiEngineTemplateAdapter

/// Task-003 plan §5.2, §13 row "`.tve` envelope" — binary `TVE1` envelope invariants.
///
/// Every rejection branch is exercised with a **synthetic** byte buffer built around a trivial JSON
/// payload, so the test owns the malformed input precisely. A single positive round-trip against a
/// real fixture (via `CompiledTemplateFixtureBytes`) proves the layout matches production data.
final class CompiledTemplateEnvelopeTests: XCTestCase {

    // A minimal valid JSON payload — the envelope layer never inspects payload contents.
    private static let payload: [UInt8] = Array(#"{"k":1}"#.utf8)

    /// Builds a `TVE1` buffer with overridable fields. Defaults produce a valid 18-byte-header
    /// envelope whose total length equals header + payload.
    private func makeEnvelope(
        magic: [UInt8] = CompiledTemplateEnvelope.magic,
        formatVersion: UInt16 = 1,
        headerLength: UInt16 = 18,
        payloadLength: UInt32? = nil,
        engineHash: UInt32 = 0x2f9921b1,
        schemaVersion: UInt16 = 2,
        payload: [UInt8] = payload,
        appendTrailing: [UInt8] = [],
        includeSchemaField: Bool = true
    ) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: magic)
        bytes.append(contentsOf: le16(formatVersion))
        bytes.append(contentsOf: le16(headerLength))
        bytes.append(contentsOf: le32(payloadLength ?? UInt32(payload.count)))
        bytes.append(contentsOf: le32(engineHash))
        if includeSchemaField { bytes.append(contentsOf: le16(schemaVersion)) }
        bytes.append(contentsOf: payload)
        bytes.append(contentsOf: appendTrailing)
        return bytes
    }

    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
    }

    private func expect(
        _ bytes: [UInt8],
        _ expected: CompiledTemplateDecodingError,
        _ message: String,
        file: StaticString = #file, line: UInt = #line
    ) {
        XCTAssertThrowsError(try CompiledTemplateEnvelope.parse(bytes), message, file: file, line: line) {
            XCTAssertEqual($0 as? CompiledTemplateDecodingError, expected, message, file: file, line: line)
        }
    }

    // MARK: - Positive

    func testValidEnvelopeParses() throws {
        let env = try CompiledTemplateEnvelope.parse(makeEnvelope())
        XCTAssertEqual(env.formatVersion, 1)
        XCTAssertEqual(env.headerLength, 18)
        XCTAssertEqual(env.schemaVersion, 2)
        XCTAssertEqual(env.engineHash, 0x2f9921b1)
        XCTAssertEqual(env.payload, Self.payload)
    }

    func testEngineHashIsDiagnosticOnlyAndDoesNotAffectParsing() throws {
        // Any engine hash is accepted; it is recorded but never gates decoding (§5.2).
        let a = try CompiledTemplateEnvelope.parse(makeEnvelope(engineHash: 0))
        let b = try CompiledTemplateEnvelope.parse(makeEnvelope(engineHash: 0xffffffff))
        XCTAssertEqual(a.payload, b.payload)
        XCTAssertEqual(a.engineHash, 0)
        XCTAssertEqual(b.engineHash, 0xffffffff)
    }

    // MARK: - Magic

    func testBadMagicRejected() {
        var bytes = makeEnvelope()
        bytes[0] = 0x54; bytes[1] = 0x56; bytes[2] = 0x45; bytes[3] = 0x32   // "TVE2"
        expect(bytes, .badMagic(found: [0x54, 0x56, 0x45, 0x32]), "wrong magic must fail closed")
    }

    func testEmptyDataRejected() {
        expect([], .envelopeTooShort(have: 0, need: 16), "empty data must fail closed")
    }

    func testTruncatedPreludeRejected() {
        let bytes = Array(makeEnvelope().prefix(12))   // only 12 of the 16-byte prelude
        expect(bytes, .envelopeTooShort(have: 12, need: 16), "short prelude must fail closed")
    }

    // MARK: - Format version

    func testUnsupportedFormatVersionRejected() {
        expect(makeEnvelope(formatVersion: 2), .unsupportedFormatVersion(found: 2),
               "format version != 1 must fail closed")
        expect(makeEnvelope(formatVersion: 0), .unsupportedFormatVersion(found: 0),
               "format version 0 must fail closed")
    }

    // MARK: - Header length

    func testInvalidHeaderLengthRejected() {
        expect(makeEnvelope(headerLength: 17), .invalidHeaderLength(found: 17),
               "header length 17 must fail closed")
        expect(makeEnvelope(headerLength: 20), .invalidHeaderLength(found: 20),
               "header length 20 must fail closed")
    }

    func testLegacy16ByteHeaderRejectedForMissingSchema() {
        // A 16-byte header carries no IR schema, which Task-003 requires.
        let bytes = makeEnvelope(headerLength: 16, includeSchemaField: false)
        expect(bytes, .missingSchemaVersion, "legacy 16-byte header must be rejected (no schema)")
    }

    func testSchemaHeaderDeclaredButBytesTruncatedRejected() {
        // headerLength says 18 but only 16 bytes are present before the payload region.
        var bytes = makeEnvelope(includeSchemaField: false)   // 16-byte body + payload
        // Fix the payload-length field to match the bytes that remain so the only fault is the
        // missing schema word.
        // bytes currently: 16-byte header (no schema) + payload. Force total to 16 so parse reads
        // headerLength 18 but data.count is 16 + payload; we instead truncate to exactly 16.
        bytes = Array(bytes.prefix(16))
        expect(bytes, .envelopeTooShort(have: 16, need: 18),
               "18-byte header declared but truncated must fail closed")
    }

    // MARK: - Schema version

    func testUnsupportedSchemaVersionRejected() {
        expect(makeEnvelope(schemaVersion: 1), .unsupportedSchemaVersion(found: 1),
               "schema 1 must fail closed")
        expect(makeEnvelope(schemaVersion: 3), .unsupportedSchemaVersion(found: 3),
               "schema 3 must fail closed")
    }

    // MARK: - Payload length bounds and ambiguity

    func testPayloadLengthTooLargeRejected() {
        let bytes = makeEnvelope(payloadLength: UInt32(Self.payload.count + 1))
        expect(bytes,
               .payloadLengthMismatch(headerLength: 18, payloadLength: Self.payload.count + 1,
                                      dataLength: 18 + Self.payload.count),
               "payload length exceeding data must fail closed")
    }

    func testPayloadLengthTooSmallLeavesTrailingBytesRejected() {
        let bytes = makeEnvelope(payloadLength: UInt32(Self.payload.count - 1))
        expect(bytes,
               .payloadLengthMismatch(headerLength: 18, payloadLength: Self.payload.count - 1,
                                      dataLength: 18 + Self.payload.count),
               "payload length shorter than data must fail closed (no trailing ambiguity)")
    }

    func testTrailingBytesAfterPayloadRejected() {
        // Append junk without changing the payload-length field: total no longer matches.
        let bytes = makeEnvelope(appendTrailing: [0x00, 0x01, 0x02])
        expect(bytes,
               .payloadLengthMismatch(headerLength: 18, payloadLength: Self.payload.count,
                                      dataLength: 18 + Self.payload.count + 3),
               "trailing bytes must fail closed")
    }

    func testMaxPayloadLengthOverflowGuarded() {
        // payloadLength = UInt32.max with an 18-byte header would overflow naive Int addition on
        // 32-bit, and certainly cannot match the tiny data buffer here.
        let bytes = makeEnvelope(payloadLength: .max)
        XCTAssertThrowsError(try CompiledTemplateEnvelope.parse(bytes)) {
            XCTAssertEqual($0 as? CompiledTemplateDecodingError,
                           .payloadLengthMismatch(headerLength: 18,
                                                  payloadLength: Int(UInt32.max),
                                                  dataLength: bytes.count),
                           "overflowing payload length must fail closed")
        }
    }

    // MARK: - Real fixtures

    func testAllRealFixtureEnvelopesParse() throws {
        for id in CompiledTemplateFixtureBytes.mandatoryIDs {
            let data = try CompiledTemplateFixtureBytes.bytes(id)
            let env = try CompiledTemplateEnvelope.parse(Array(data))
            XCTAssertEqual(env.formatVersion, 1, "\(id) format version")
            XCTAssertEqual(env.headerLength, 18, "\(id) header length")
            XCTAssertEqual(env.schemaVersion, 2, "\(id) schema")
            XCTAssertEqual(env.headerLength + env.payload.count, data.count, "\(id) exact total length")
            XCTAssertFalse(env.payload.isEmpty, "\(id) payload present")
        }
    }
}
