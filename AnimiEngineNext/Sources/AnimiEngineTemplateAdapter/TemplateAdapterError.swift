/// Task-003 plan §4.1, §9 — typed error roots for the compiled-template adapter.
///
/// `TemplateAdapterError` is the module's error root. §9 names three adapter-owned domains:
/// `TemplatePackageError`, `CompiledTemplateDecodingError` and `TemplateConversionError`. §17 step 5
/// implements **decoding only**, so this file introduces `CompiledTemplateDecodingError`. The
/// package-loading and conversion domains are introduced alongside their owners in later steps
/// (§17 step 6+); they are intentionally absent here.
///
/// All errors are typed, `Equatable` and `Sendable` (§9). No layer substitutes a default variant,
/// placeholder, default easing/fit, or any silently-repaired value (§9 prohibitions).
public enum TemplateAdapterError: Error, Equatable, Sendable {
    /// A failure while decoding a compiled `.tve` envelope or its schema-2 payload.
    case decoding(CompiledTemplateDecodingError)
}

/// Structural decoding errors for the compiled `.tve` envelope and schema-2 payload
/// (Task-003 plan §5.2, §9).
///
/// These cover three layers, all fail-closed:
///   1. the binary `TVE1` envelope (magic, versions, header length, payload bounds, schema);
///   2. strict JSON lexing/typing of the payload;
///   3. schema-2 structural validity (required/unknown fields, duplicate ids, references, supported
///      compiled features).
///
/// The engine-version hash is **not** represented as an error: a mismatch is diagnostic metadata
/// and never changes decoding behaviour (§5.2).
public enum CompiledTemplateDecodingError: Error, Equatable, Sendable {

    // MARK: 1. Binary envelope (`CompiledTemplateEnvelope`)

    /// The data is shorter than the fixed prelude required to even read the header length.
    case envelopeTooShort(have: Int, need: Int)
    /// The leading four bytes are not the ASCII magic `TVE1`.
    case badMagic(found: [UInt8])
    /// The compiled format version is not a value this decoder supports.
    case unsupportedFormatVersion(found: UInt16)
    /// The header length field is neither the legacy `16` nor the schema-bearing `18`.
    case invalidHeaderLength(found: UInt16)
    /// `header + payload` does not exactly equal the data length (truncation or trailing bytes at
    /// the binary layer), or the payload length overflowed an addressable range.
    case payloadLengthMismatch(headerLength: Int, payloadLength: Int, dataLength: Int)
    /// The IR schema version is not exactly `2` (Task-003 supports schema 2 only).
    case unsupportedSchemaVersion(found: UInt16)
    /// A 16-byte legacy header carries no explicit IR schema, which Task-003 requires.
    case missingSchemaVersion

    // MARK: 2. Strict JSON (`CompiledTemplateStrictJSON`)

    /// The payload bytes are not valid UTF-8.
    case payloadNotUTF8
    /// The payload is not well-formed JSON (lexical/syntactic failure).
    case malformedJSON(reason: String)
    /// A JSON object contained the same key twice.
    case duplicateKey(key: String)
    /// Non-whitespace content followed the root JSON value (length ambiguity at the JSON layer).
    case trailingPayloadContent
    /// A required field was absent.
    case missingField(path: String, field: String)
    /// An object contained a field not present in the schema owned by this adapter.
    case unknownField(path: String, field: String)
    /// A field had the wrong primitive JSON type (e.g. string where an integer was required).
    case wrongType(path: String, expected: String)
    /// An integer field was malformed: a fraction/exponent, leading zero, `-0`, or out of `Int64`.
    case malformedInteger(path: String)
    /// A numeric field was non-finite (NaN/infinity) or otherwise unparseable as a finite `Double`.
    case malformedNumber(path: String)
    /// A field carried a literal `null`. No field in the owned schema is documented nullable, so a
    /// literal `null` is always rejected and is never silently treated as an absent field (item 5).
    case explicitNull(path: String)
    /// An enum-like **string** tag was not one of the schema's pinned tags (e.g. an unknown
    /// `hitTestMode`, `containerClip`, mask mode or fit mode).
    case unknownEnumTag(path: String, tag: String)
    /// An enum-like **integer** code was not one of the schema's pinned codes (e.g. an unknown
    /// layer-type or matte-mode code).
    case unknownEnumCode(path: String, code: Int)
    /// A numeric field fell outside the range pinned by the producer (e.g. `lineCap`/`lineJoin`,
    /// which the producer documents as `1...3`).
    case valueOutOfRange(path: String, detail: String)
    /// A layer's declared `type` is incompatible with its `content` kind (e.g. an image-type layer
    /// carrying shape content). The producer pairs each layer type with exactly one content kind.
    case layerContentMismatch(path: String, layerType: Int, contentKind: String)

    // MARK: 3. Schema-2 structure (`CompiledTemplateDTO` / `CompiledAnimIRDTO`)

    /// A structural identifier (variant id, block id, comp id, layer id, asset id, path id) was
    /// declared more than once where uniqueness is required.
    case duplicateIdentifier(kind: String, id: String, path: String)
    /// A reference pointed at an identifier that does not exist (e.g. a block's selected variant,
    /// a matte/parent layer, a precomp id, or an image asset not in the merged index).
    case danglingReference(kind: String, id: String, path: String)
    /// A discriminated union (content kind, value-track kind, path-track kind) carried zero or more
    /// than one variant key, so the intended case is ambiguous.
    case ambiguousUnion(path: String, keys: [String])
    /// A compiled feature is structurally well-formed but not supported by this decoder (e.g. an
    /// unrecognised layer type code or content kind). Fail closed — never silently skipped.
    case unsupportedCompiledFeature(path: String, detail: String)
    /// A scene-level value and the runtime value derived from it by the producer disagree (e.g. a
    /// runtime block's `rectCanvas` not equal to its scene block's `rect`, a `selectedVariantId`
    /// that is not the first authored scene variant, a non-`no-anim` `editVariantId`, or mismatched
    /// variant id sets / `animRef` / `bindingKey`). The producer derives the runtime block from the
    /// scene block, so a contradiction is a corrupt package (item 2).
    case sceneRuntimeInconsistency(path: String, detail: String)
    /// A layer-toggle invariant was violated: the scene toggle id set differs from the AnimIR
    /// `toggleId` set, a duplicate toggle id, a toggle layer used as matte source/consumer/parent,
    /// or toggles present without a non-empty `sceneId` (item 3).
    case layerToggleViolation(path: String, detail: String)
    /// The declared `bindingAssetIds` set does not exactly equal the set of every variant's AnimIR
    /// `binding.boundAssetId` — there is a missing or extra id (item 4).
    case bindingAssetSetMismatch(missing: [String], extra: [String], path: String)
}
