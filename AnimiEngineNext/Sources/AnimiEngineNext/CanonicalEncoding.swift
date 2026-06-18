import Foundation

/// Produces a **deterministic canonical byte form** of an ``EngineConfiguration``
/// (Task-001 plan, "Hashing").
///
/// The canonical form is a JSON document with:
///   * **lexicographically sorted object keys** at every depth,
///   * **fixed-format integer numbers** (no locale, no exponent, no trailing `.0`),
///   * **stable UTF-8 string encoding** with `/` left unescaped,
///   * **no insignificant whitespace**.
///
/// The bytes are produced from the typed value (not from re-serialized arbitrary JSON), so the
/// ordering and number formatting are fully under our control and reproducible across runs and
/// processes. This is the input to `ConfigurationHash`.
public enum CanonicalEncoding {
    /// The canonical UTF-8 bytes for `configuration`.
    public static func canonicalBytes(of configuration: EngineConfiguration) -> Data {
        let value = canonicalValue(of: configuration)
        var output = String()
        write(value, into: &output)
        return Data(output.utf8)
    }

    // MARK: - Canonical value model

    /// An ordering-agnostic value model. Objects are stored as key/value pairs and sorted at
    /// emit time, so construction order never affects the output.
    indirect enum CanonicalValue {
        case object([(String, CanonicalValue)])
        case array([CanonicalValue])
        case int(Int)
        case string(String)
    }

    private static func canonicalValue(of c: EngineConfiguration) -> CanonicalValue {
        .object([
            ("schemaVersion", .int(c.schemaVersion)),
            ("projectFrameRate", .int(c.projectFrameRate)),
            ("preview", .object([
                ("frameRateLadder", .array(c.preview.frameRateLadder.map(CanonicalValue.int)))
            ])),
            ("decoder", .object([
                ("backend", .string(c.decoder.backend)),
                ("poolLimit", .int(c.decoder.poolLimit))
            ])),
            ("proxy", .object([
                ("profiles", .array(c.proxy.profiles.map { p in
                    CanonicalValue.object([
                        ("name", .string(p.name)),
                        ("maxDimension", .int(p.maxDimension))
                    ])
                }))
            ])),
            ("cache", .object([
                ("frameCacheBudgetMiB", .int(c.cache.frameCacheBudgetMiB)),
                ("diskProxyBudgetMiB", .int(c.cache.diskProxyBudgetMiB))
            ])),
            ("renderQuality", .object([
                ("profiles", .array(c.renderQuality.profiles.map { p in
                    CanonicalValue.object([
                        ("name", .string(p.name)),
                        ("scalePercent", .int(p.scalePercent))
                    ])
                }))
            ])),
            ("memory", .object([
                ("softLimitMiB", .int(c.memory.softLimitMiB)),
                ("hardLimitMiB", .int(c.memory.hardLimitMiB))
            ])),
            ("export", .object([
                ("profiles", .array(c.export.profiles.map { p in
                    CanonicalValue.object([
                        ("name", .string(p.name)),
                        ("frameRate", .int(p.frameRate)),
                        ("bitrate", .int(p.bitrate))
                    ])
                }))
            ])),
            ("diagnostics", .object([
                ("samplingPercent", .int(c.diagnostics.samplingPercent)),
                ("output", .string(c.diagnostics.output))
            ]))
        ])
    }

    // MARK: - Emit

    private static func write(_ value: CanonicalValue, into output: inout String) {
        switch value {
        case .object(let pairs):
            output.append("{")
            let sorted = pairs.sorted { $0.0 < $1.0 }
            for (index, pair) in sorted.enumerated() {
                if index > 0 { output.append(",") }
                writeString(pair.0, into: &output)
                output.append(":")
                write(pair.1, into: &output)
            }
            output.append("}")

        case .array(let elements):
            output.append("[")
            for (index, element) in elements.enumerated() {
                if index > 0 { output.append(",") }
                write(element, into: &output)
            }
            output.append("]")

        case .int(let number):
            output.append(String(number))

        case .string(let string):
            writeString(string, into: &output)
        }
    }

    /// Emits a JSON string with the minimal, deterministic escape set (RFC 8259), leaving `/`
    /// unescaped and emitting control characters as `\u00XX`.
    private static func writeString(_ string: String, into output: inout String) {
        output.append("\"")
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"":  output.append("\\\"")
            case "\\":  output.append("\\\\")
            case "\u{08}": output.append("\\b")
            case "\u{0C}": output.append("\\f")
            case "\n":  output.append("\\n")
            case "\r":  output.append("\\r")
            case "\t":  output.append("\\t")
            default:
                if scalar.value < 0x20 {
                    output.append(String(format: "\\u%04x", scalar.value))
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output.append("\"")
    }
}
