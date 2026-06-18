import Foundation

/// A single structured diagnostic event (Task-001 plan, "Evidence contract").
///
/// Each event carries: the ``BenchmarkRunID``, **elapsed monotonic time** (ns since run start —
/// never wall time), the subsystem, the event type, and structured string fields. Serialization
/// is deterministic (sorted keys, one event per NDJSON line) for byte-comparison in tests.
public struct DiagnosticEvent: Equatable, Sendable {
    public let runID: BenchmarkRunID
    /// Nanoseconds elapsed since the run started, from the monotonic clock.
    public let elapsedNanoseconds: UInt64
    public let subsystem: String
    public let eventType: String
    /// Structured fields. Kept as `[String: String]` so the line is fully deterministic; ordering
    /// is normalized at serialization time by sorting keys.
    public let fields: [String: String]

    public init(
        runID: BenchmarkRunID,
        elapsedNanoseconds: UInt64,
        subsystem: String,
        eventType: String,
        fields: [String: String]
    ) {
        self.runID = runID
        self.elapsedNanoseconds = elapsedNanoseconds
        self.subsystem = subsystem
        self.eventType = eventType
        self.fields = fields
    }

    /// The deterministic single-line JSON encoding of this event (no trailing newline).
    ///
    /// Top-level keys are emitted in a fixed order; the nested `fields` object has its keys sorted
    /// lexicographically. This makes `events.ndjson` byte-stable under deterministic test clocks.
    public func canonicalLine() -> String {
        var output = "{"
        output += "\"runID\":"; appendJSONString(runID.rawValue, into: &output)
        output += ",\"elapsedNanoseconds\":\(elapsedNanoseconds)"
        output += ",\"subsystem\":"; appendJSONString(subsystem, into: &output)
        output += ",\"eventType\":"; appendJSONString(eventType, into: &output)
        output += ",\"fields\":{"
        for (index, key) in fields.keys.sorted().enumerated() {
            if index > 0 { output += "," }
            appendJSONString(key, into: &output)
            output += ":"
            appendJSONString(fields[key]!, into: &output)
        }
        output += "}}"
        return output
    }
}

/// Emits a JSON string with the minimal deterministic escape set (RFC 8259).
func appendJSONString(_ string: String, into output: inout String) {
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
