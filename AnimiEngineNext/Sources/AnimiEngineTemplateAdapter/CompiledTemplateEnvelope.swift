/// The compiled `.tve` binary envelope (Task-003 plan §2 D3-01, §5.2).
///
/// Layout — all multi-byte integer fields are little-endian:
///
/// ```text
///   offset  size  field
///   0       4     magic           ASCII "TVE1"
///   4       2     formatVersion   UInt16, must be 1
///   6       2     headerLength    UInt16, 16 (legacy) or 18 (schema-bearing)
///   8       4     payloadLength   UInt32
///   12      4     engineHash      UInt32, diagnostic only
///   16      2     schemaVersion   UInt16, present only in the 18-byte header
///   ----          payload         headerLength ..< headerLength + payloadLength
/// ```
///
/// Parsing is pure: `Data -> CompiledTemplateEnvelope`. No filesystem or bundle IO (§5.2). Every
/// arithmetic step is overflow-checked and every slice is bounds-checked; the parser rejects
/// truncation, trailing bytes and any length ambiguity, and requires the IR schema to be exactly 2.
public struct CompiledTemplateEnvelope: Equatable, Sendable {
    /// The little-endian compiled format version (always `1` for accepted data).
    public let formatVersion: UInt16
    /// The header length actually read: `16` or `18`.
    public let headerLength: Int
    /// The engine-version hash. **Diagnostic metadata only** — it never alters decoding (§5.2).
    public let engineHash: UInt32
    /// The IR schema version (always `2` for accepted data).
    public let schemaVersion: UInt16
    /// The exact payload byte range that follows the header. Length equals the header's payload
    /// length and the range ends exactly at the end of the data (no trailing bytes).
    public let payload: [UInt8]

    /// The only compiled format version Task-003 accepts.
    public static let supportedFormatVersion: UInt16 = 1
    /// The legacy header length (no explicit IR schema).
    public static let legacyHeaderLength = 16
    /// The schema-bearing header length (explicit IR schema at offset 16).
    public static let schemaHeaderLength = 18
    /// The only IR schema version Task-003 accepts.
    public static let supportedSchemaVersion: UInt16 = 2
    /// ASCII `TVE1`.
    public static let magic: [UInt8] = [0x54, 0x56, 0x45, 0x31]

    /// Parses an envelope from raw bytes, validating the binary layer end-to-end.
    public static func parse(_ data: [UInt8]) throws -> CompiledTemplateEnvelope {
        // Minimum prelude: magic(4) + formatVersion(2) + headerLength(2) + payloadLength(4) +
        // engineHash(4) = 16 bytes, which is also the smallest legal header.
        let preludeLength = 16
        guard data.count >= preludeLength else {
            throw CompiledTemplateDecodingError.envelopeTooShort(have: data.count, need: preludeLength)
        }

        let magic = Array(data[0..<4])
        guard magic == Self.magic else {
            throw CompiledTemplateDecodingError.badMagic(found: magic)
        }

        let formatVersion = readUInt16LE(data, 4)
        guard formatVersion == Self.supportedFormatVersion else {
            throw CompiledTemplateDecodingError.unsupportedFormatVersion(found: formatVersion)
        }

        let headerLengthField = readUInt16LE(data, 6)
        let headerLength = Int(headerLengthField)
        guard headerLength == Self.legacyHeaderLength || headerLength == Self.schemaHeaderLength else {
            throw CompiledTemplateDecodingError.invalidHeaderLength(found: headerLengthField)
        }

        let payloadLength = Int(readUInt32LE(data, 8))
        let engineHash = readUInt32LE(data, 12)

        // Schema version: only the 18-byte header carries one, and we require it.
        let schemaVersion: UInt16
        if headerLength == Self.schemaHeaderLength {
            // The 18-byte header is fully present iff data.count >= 18; the prelude guarantees only 16.
            guard data.count >= Self.schemaHeaderLength else {
                throw CompiledTemplateDecodingError.envelopeTooShort(
                    have: data.count, need: Self.schemaHeaderLength
                )
            }
            schemaVersion = readUInt16LE(data, 16)
        } else {
            // Legacy 16-byte header: no explicit schema, which Task-003 requires.
            throw CompiledTemplateDecodingError.missingSchemaVersion
        }
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw CompiledTemplateDecodingError.unsupportedSchemaVersion(found: schemaVersion)
        }

        // Exact total-length check: header + payload must equal data.count, with overflow guarded.
        let (total, overflow) = headerLength.addingReportingOverflow(payloadLength)
        guard !overflow, total == data.count else {
            throw CompiledTemplateDecodingError.payloadLengthMismatch(
                headerLength: headerLength,
                payloadLength: payloadLength,
                dataLength: data.count
            )
        }

        let payload = Array(data[headerLength..<total])
        return CompiledTemplateEnvelope(
            formatVersion: formatVersion,
            headerLength: headerLength,
            engineHash: engineHash,
            schemaVersion: schemaVersion,
            payload: payload
        )
    }

    // MARK: - Little-endian field readers

    private static func readUInt16LE(_ data: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
