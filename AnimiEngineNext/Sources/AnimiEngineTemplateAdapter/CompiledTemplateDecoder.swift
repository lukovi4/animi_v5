import Foundation

/// The pure compiled-template decoder (Task-003 plan §5.2).
///
/// ```text
///   Data -> DecodedCompiledTemplate
/// ```
///
/// This is the only public entry point for §17 step 5. It is a pure transformation: no filesystem,
/// bundle or network IO; no wall clock; no mutable global state. It performs, in order:
///
///   1. `CompiledTemplateEnvelope.parse` — validates the binary `TVE1` envelope (magic, format
///      version, header length, payload bounds, exact total length, IR schema == 2) and extracts
///      the payload bytes;
///   2. `CompiledJSONParser.parse` — strict JSON lexing of the payload (UTF-8, duplicate-key
///      rejection, no trailing content);
///   3. `CompiledTemplatePayloadDTO.decode` — strict schema-2 structural decoding: required fields,
///      exact types, recursive unknown-field rejection, integer-vs-floating discipline, duplicate
///      structural ids, reference resolution and unsupported-feature rejection.
///
/// The engine-version hash from the envelope is carried into `DecodedCompiledTemplate.envelope` as
/// **diagnostic metadata only**; it never changes any decoding decision (§5.2). There is no
/// fallback, default variant, coercion or silent repair anywhere in the path (§9).
///
/// Out of scope for step 5 (kept for step 6+): variant inventory enumeration, canonical project /
/// render-material conversion, render-unit numeric conversion, and asset loading.
public enum CompiledTemplateDecoder {

    /// Decodes raw `.tve` bytes into a validated `DecodedCompiledTemplate`.
    public static func decode(_ data: Data) throws -> DecodedCompiledTemplate {
        let envelope = try CompiledTemplateEnvelope.parse(Array(data))
        let root = try CompiledJSONParser.parse(Data(envelope.payload))
        let payload = try CompiledTemplatePayloadDTO.decode(root)
        return DecodedCompiledTemplate(envelope: envelope, payload: payload)
    }
}
