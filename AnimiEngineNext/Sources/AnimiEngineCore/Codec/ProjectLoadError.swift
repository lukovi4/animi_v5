/// The single error type surfaced by ``CanonicalProjectEncoding/decodeValidated(_:)``
/// (Task-002 plan, §11.2).
///
/// Decoding failures and semantic validation failures remain separate categories, wrapped here so a
/// caller can distinguish "malformed bytes" from "well-formed but invalid project".
public enum ProjectLoadError: Error, Equatable, Sendable {
    case decoding(ProjectDecodingError)
    case validation(ProjectValidationError)
}
