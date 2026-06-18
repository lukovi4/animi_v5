import Foundation
import CryptoKit

/// Task-003 plan D3-11, D3-12, §12.3 — deterministic canonical byte encoding and SHA-256 hashing for
/// render-model values.
///
/// Guarantees (mirroring the Task-002 codec idiom, but for render-model values):
///   * **order independence** — object keys are emitted lexicographically sorted, so construction
///     order never affects the bytes; collections that are semantically unordered are sorted by their
///     stable key before emission;
///   * **fixed integer formatting** — base-10, no exponent, no trailing `.0`; there is no float in
///     canonical state to format;
///   * **hashes derive only from canonical bytes** — every SHA-256 in the render model is taken over
///     the bytes this encoder produces (or, for pixels, the explicit dimensions+bytes layout below),
///     never over in-memory layout, `Hasher`, or `Codable` output.
public enum RenderCanonicalEncoding {

    /// Hash-domain / schema identifiers (item 7). Every domain-scoped hash prepends one of these tags
    /// into the canonical bytes, so a value encoded for one domain can never collide with structurally
    /// similar bytes from another (e.g. a pixel-content hash vs a material-table hash). The version
    /// suffix lets the schema evolve without silent hash reuse.
    public enum HashDomain: String, Sendable {
        case renderConfiguration = "aen.renderConfiguration.v1"
        case animationProgram   = "aen.animationProgram.v1"
        case materialTable      = "aen.materialTable.v1"
        case renderGraph        = "aen.renderGraph.v1"
        /// §17 step 8 — the resolved frame-input identity (resolved pixels, layer bindings and final
        /// media transforms/clips). Distinct domain so a frame-input hash never collides with a
        /// render-graph or material-table hash carrying coincident fields.
        case frameInput         = "aen.frameInput.v1"
        case pixelInput         = "aen.pixelInput.v1"
        case renderedFrame      = "aen.renderedFrame.v1"
        /// §17 step 7 — the compiled-template → canonical conversion identity (the converted scene,
        /// selection and material set). Distinct domain so a template hash never collides with a
        /// material-table or render-graph hash carrying coincident fields.
        case templateConversion = "aen.templateConversion.v1"
    }

    // MARK: - Canonical value tree

    /// An ordering-agnostic canonical value. Objects are key/value pairs; an object is rejected at
    /// build time if it carries a duplicate key (see ``object(_:)``). Arrays preserve order (used only
    /// where order is semantic, e.g. ordered command lists).
    public indirect enum Value: Sendable {
        case object([(String, Value)])
        case array([Value])
        case int(Int64)
        case string(String)
        case bool(Bool)
    }

    /// Builds an object value, **failing closed on duplicate keys** (item 7). Constructing canonical
    /// objects through this factory makes a duplicate key impossible to encode rather than silently
    /// resolving to a last-writer-wins ambiguity.
    public static func object(_ pairs: [(String, Value)]) throws -> Value {
        var seen = Set<String>()
        for (key, _) in pairs where !seen.insert(key).inserted {
            throw RenderModelError.duplicateIdentity(field: "canonicalObjectKey", value: key)
        }
        return .object(pairs)
    }

    /// Writes a ``Value`` deterministically: lexicographically sorted object keys, fixed base-10
    /// integers, minimal string escaping.
    ///
    /// **Transactional and fail-closed (no traps):** the complete recursive `Value` is validated for
    /// duplicate keys (at every nesting depth) *before* any mutation, then encoded into private
    /// temporary storage, and only appended to `output` after success. Therefore on any
    /// validation/encoding error the caller's `output` remains **byte-for-byte unchanged**. A
    /// duplicate key — even one introduced by directly constructing `.object` and bypassing
    /// ``object(_:)`` — throws ``RenderModelError/duplicateIdentity(field:value:)``.
    public static func write(_ value: Value, into output: inout String) throws {
        // Phase 1: validate the entire tree before touching `output`.
        try validate(value)
        // Phase 2: render into private temporary storage (cannot fail after validation).
        var scratch = String()
        render(value, into: &scratch)
        // Phase 3: commit atomically — the only mutation of the caller's buffer.
        output.append(scratch)
    }

    /// Recursively validates that every object level has unique keys. Throws on the first duplicate;
    /// performs no encoding and no caller-visible mutation.
    private static func validate(_ value: Value) throws {
        switch value {
        case .object(let pairs):
            var seen = Set<String>()
            for (key, _) in pairs where !seen.insert(key).inserted {
                throw RenderModelError.duplicateIdentity(field: "canonicalObjectKey", value: key)
            }
            for (_, nested) in pairs { try validate(nested) }
        case .array(let elements):
            for element in elements { try validate(element) }
        case .int, .string, .bool:
            break
        }
    }

    /// Renders a pre-validated value into `output`. Never throws and never traps: validation has
    /// already guaranteed unique keys at every level, so the byte output here is identical to the
    /// prior implementation (canonical bytes and all golden hashes are preserved).
    private static func render(_ value: Value, into output: inout String) {
        switch value {
        case .object(let pairs):
            output.append("{")
            let sorted = pairs.sorted { $0.0 < $1.0 }
            for (index, pair) in sorted.enumerated() {
                if index > 0 { output.append(",") }
                writeString(pair.0, into: &output)
                output.append(":")
                render(pair.1, into: &output)
            }
            output.append("}")
        case .array(let elements):
            output.append("[")
            for (index, element) in elements.enumerated() {
                if index > 0 { output.append(",") }
                render(element, into: &output)
            }
            output.append("]")
        case .int(let number):
            output.append(String(number))
        case .string(let string):
            writeString(string, into: &output)
        case .bool(let flag):
            output.append(flag ? "true" : "false")
        }
    }

    private static func writeString(_ string: String, into output: inout String) {
        output.append("\"")
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output.append("\\\"")
            case "\\": output.append("\\\\")
            case "\u{08}": output.append("\\b")
            case "\u{0C}": output.append("\\f")
            case "\n": output.append("\\n")
            case "\r": output.append("\\r")
            case "\t": output.append("\\t")
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    let padded = String(repeating: "0", count: 4 - hex.count) + hex
                    output.append("\\u" + padded)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output.append("\"")
    }

    /// Canonical UTF-8 bytes for a value. Throws if any nested object carries a duplicate key
    /// (fail closed, item 1).
    public static func canonicalBytes(_ value: Value) throws -> Data {
        var output = String()
        try write(value, into: &output)
        return Data(output.utf8)
    }

    // MARK: - SHA-256

    /// Lowercase hex SHA-256 over arbitrary bytes. The single hashing primitive.
    public static func sha256Hex(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Domain-scoped canonical bytes: the hash-domain tag is prepended as a `__domain` field so two
    /// different value kinds never share canonical bytes even if their other fields coincide (item 7).
    public static func domainBytes(_ value: Value, domain: HashDomain) throws -> Data {
        let wrapped = try object([
            ("__domain", .string(domain.rawValue)),
            ("value", value)
        ])
        return try canonicalBytes(wrapped)
    }

    /// Lowercase hex SHA-256 over a value's domain-scoped canonical bytes (D3-11, item 7).
    public static func sha256Hex(of value: Value, domain: HashDomain) throws -> String {
        sha256Hex(try domainBytes(value, domain: domain))
    }

    // MARK: - Pixel content hash (§8 raw-output identity)

    /// SHA-256 over a pixel buffer's identity: a domain-tagged canonical header (dimensions/format)
    /// followed by the raw pixel bytes (§8). The header is encoded canonically first so two buffers
    /// with identical pixels but different layout never collide.
    public static func pixelContentHash(dimensions: PixelDimensions, bytes: Data) throws -> String {
        let header = try domainBytes(.object([
            ("bytesPerRow", .int(Int64(dimensions.bytesPerRow))),
            ("format", .string(dimensions.format.rawValue)),
            ("height", .int(Int64(dimensions.height))),
            ("orientation", .string(dimensions.orientation.rawValue)),
            ("width", .int(Int64(dimensions.width)))
        ]), domain: .pixelInput)
        var combined = header
        combined.append(bytes)
        return sha256Hex(combined)
    }

    /// SHA-256 over a rendered frame's raw-output identity: a domain-tagged header of dimensions,
    /// format **and full colour contract** metadata, followed by the raw pixel bytes (§8). Distinct
    /// from `pixelContentHash` by both domain tag and the colour-contract fields.
    public static func rawOutputHash(
        dimensions: PixelDimensions,
        colorContract: RenderColorContract,
        bytes: Data
    ) throws -> String {
        let header = try domainBytes(.object([
            ("alphaStorage", .string(colorContract.alphaStorage.rawValue)),
            ("bytesPerRow", .int(Int64(dimensions.bytesPerRow))),
            ("colorSpace", .string(colorContract.colorSpace.rawValue)),
            ("dynamicRange", .string(colorContract.dynamicRange.rawValue)),
            ("format", .string(dimensions.format.rawValue)),
            ("height", .int(Int64(dimensions.height))),
            ("orientation", .string(dimensions.orientation.rawValue)),
            ("outputFormat", .string(colorContract.outputFormat.rawValue)),
            ("width", .int(Int64(dimensions.width)))
        ]), domain: .renderedFrame)
        var combined = header
        combined.append(bytes)
        return sha256Hex(combined)
    }

    // MARK: - Checked integer arithmetic for render-model sizing (item 1)

    /// Checked `Int` multiply that throws ``RenderModelError/integerOverflow(operation:)`` rather than
    /// trapping. Used for pixel-size arithmetic where `Int.max` inputs must fail closed.
    public static func multiply(_ a: Int, _ b: Int, _ operation: String) throws -> Int {
        let (result, overflow) = a.multipliedReportingOverflow(by: b)
        if overflow { throw RenderModelError.integerOverflow(operation: operation) }
        return result
    }

    /// Checked `Int` add that throws ``RenderModelError/integerOverflow(operation:)``.
    public static func add(_ a: Int, _ b: Int, _ operation: String) throws -> Int {
        let (result, overflow) = a.addingReportingOverflow(b)
        if overflow { throw RenderModelError.integerOverflow(operation: operation) }
        return result
    }
}
