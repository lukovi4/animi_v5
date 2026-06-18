/// Structural decoding errors: the document is not well-formed against the canonical schema
/// (Task-002 plan, §11.2, §15.2).
///
/// These are strictly distinct from ``ProjectValidationError`` (semantic) — a duplicate JSON key or
/// an unknown field is a `ProjectDecodingError`, while a duplicate scene id is a validation error.
public enum ProjectDecodingError: Error, Equatable, Sendable {
    /// The bytes are not valid JSON at all (lexical/syntactic failure).
    case malformedJSON(reason: String)
    /// A JSON object contained the same key twice.
    case duplicateKey(path: String, key: String)
    /// An object contained a field not present in the canonical schema.
    case unknownField(path: String, field: String)
    /// A required field was missing.
    case missingField(path: String, field: String)
    /// A field had the wrong primitive type.
    case wrongType(path: String, expected: String)
    /// An integer field was malformed (non-integer, out of `Int64` range, or had a fraction/exponent).
    case malformedInteger(path: String)
    /// An enum tag string was not one of the schema's pinned tags.
    case unknownEnumTag(path: String, tag: String)
}
