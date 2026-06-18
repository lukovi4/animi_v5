import Foundation

/// The only public persistence entry point for canonical projects (Task-002 plan, §11).
///
/// Task-001's `CanonicalEncoding` is configuration-specific and is **not** reused. This codec
/// guarantees: sorted object keys, fixed base-10 integer formatting, pinned enum tags, sorted
/// transition parameters, deterministic payload-table order, and a byte-stable
/// `encode → decodeValidated → encode` round trip. ``decodeValidated(_:)`` is the only public
/// decode path; there is no `Codable` shortcut that bypasses strict validation.
public enum CanonicalProjectEncoding {

    /// Encodes a document to canonical UTF-8 bytes.
    ///
    /// The document is **validated first** (corrective plan C-5): encoding a semantically invalid
    /// document is rejected as a thrown ``ProjectValidationError``, guaranteeing
    /// `encode → decodeValidated → encode` symmetry (we never emit bytes `decodeValidated` would
    /// reject).
    public static func encode(_ document: CanonicalProjectDocument) throws -> Data {
        try ProjectValidator.validate(document)
        let value = try CanonicalProjectValueBuilder.build(document)
        var output = String()
        CanonicalJSONWriter.write(value, into: &output)
        return Data(output.utf8)
    }

    /// Strictly decodes and validates canonical bytes (Task-002 plan, §11.2).
    ///
    /// Pipeline: strict JSON parse → unknown-field / shape rejection → domain factories → semantic
    /// validation. Structural failures surface as `.decoding`; semantic failures as `.validation`.
    public static func decodeValidated(_ data: Data) throws -> CanonicalProjectDocument {
        let root: StrictJSONValue
        do {
            root = try StrictJSONParser.parse(Array(data))
        } catch let error as ProjectDecodingError {
            throw ProjectLoadError.decoding(error)
        }

        let document: CanonicalProjectDocument
        do {
            document = try RawProjectDecoder.decodeDocument(root)
        } catch let error as ProjectDecodingError {
            throw ProjectLoadError.decoding(error)
        } catch let error as ProjectValidationError {
            // Domain factories that fire during decode (e.g. empty id, bad range) are semantic.
            throw ProjectLoadError.validation(error)
        } catch let error as TimeError {
            throw ProjectLoadError.validation(.timeError(error))
        }

        do {
            try ProjectValidator.validate(document)
        } catch let error as ProjectValidationError {
            throw ProjectLoadError.validation(error)
        } catch let error as TimeError {
            throw ProjectLoadError.validation(.timeError(error))
        }

        return document
    }
}
