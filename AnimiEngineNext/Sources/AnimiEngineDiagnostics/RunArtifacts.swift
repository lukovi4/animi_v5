import Foundation

/// The fixed set of **core** artifact file names written into a benchmark-run directory
/// (Task-001 plan, "Evidence contract"). These are the always-present run artifacts.
///
/// Richer validation evidence (`project-snapshot.json`/`render-manifest.json`/`output/…`, Task-003
/// §10.3) is written through the supplemental-artifact surface — see
/// ``BenchmarkRun/writeSupplementalArtifact(data:at:)`` — and indexed by ``supplementalManifest``,
/// not added as core cases here. The core names below are reserved against supplemental paths.
public enum RunArtifact: String, CaseIterable, Sendable {
    case runManifest = "run-manifest.json"
    case engineConfig = "engine-config.json"
    case device = "device.json"
    case events = "events.ndjson"
    case summary = "summary.json"
    case failures = "failures.json"

    /// The temporary staging name for the streaming `events.ndjson` (correction #3): events are
    /// appended here while the run is open and atomically renamed to ``events`` on close.
    public static let eventsStaging = "events.ndjson.partial"

    /// Task-003 plan §10.2 — the canonical manifest of supplemental artifacts. It is written inside
    /// staging at close (before the core artifacts) and its SHA-256 is recorded in the run manifest.
    /// Reserved like a core artifact: it may not be used as a supplemental path.
    public static let supplementalManifest = "artifacts-manifest.json"
}

/// Final success/failure status of a run, recorded in the manifest and summary.
public enum RunStatus: String, Sendable {
    case success
    case failure
}

/// Typed errors from the benchmark-run lifecycle (Task-001 plan, "Run-directory lifecycle").
public enum BenchmarkRunError: Error, Equatable, Sendable {
    /// The (final or staging) run directory already exists — runs never overwrite prior runs. On a
    /// publication collision the existing final directory remains unchanged; `BenchmarkRun` never
    /// creates or modifies it.
    case runDirectoryAlreadyExists(path: String)
    /// The generated `runID` is not a safe path component (Revision-5 amendment 2).
    case unsafeRunID(value: String)
    /// A diagnostic event carried a `runID` that does not match this run's `runID`.
    case foreignRunID(expected: String, found: String)
    /// The bytes written to `engine-config.json` did not re-hash to the manifest's recorded digest.
    case evidenceIntegrityFailure(reason: String)
    /// A write or re-open was attempted after the run was successfully **sealed** (closed).
    case runAlreadySealed
    /// A write or re-open was attempted after the run's close **failed** (distinct from sealed).
    case runPreviouslyFailed
    /// An underlying filesystem operation failed.
    case ioFailure(reason: String)
}

extension BenchmarkRunError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .runDirectoryAlreadyExists(let path):
            return "Benchmark run directory already exists: \(path)"
        case .unsafeRunID(let value):
            return "Unsafe benchmark runID (not a safe path component): \(value)"
        case .foreignRunID(let expected, let found):
            return "Diagnostic event runID \(found) does not match run \(expected)"
        case .evidenceIntegrityFailure(let reason):
            return "Evidence integrity failure: \(reason)"
        case .runAlreadySealed:
            return "Benchmark run is sealed; further writes/re-open are rejected"
        case .runPreviouslyFailed:
            return "Benchmark run previously failed to close; further writes/re-open are rejected"
        case .ioFailure(let reason):
            return "Benchmark run I/O failure: \(reason)"
        }
    }
}

/// Deterministic JSON body for `run-manifest.json`.
struct RunManifest {
    let engineConfigSHA256: String
    let runID: BenchmarkRunID
    let startWallClock: Date
    let endWallClock: Date
    let status: RunStatus
    /// Task-003 plan §10.2 — SHA-256 of the canonical `artifacts-manifest.json` bytes. An empty run
    /// records the hash of the canonical empty manifest, so this field is always present.
    let supplementalArtifactsSHA256: String

    /// Sorted-key JSON. Wall-clock times are emitted as fixed ISO-8601 (UTC) strings so the
    /// manifest is byte-stable under a deterministic `WallClock`. `engineConfigSHA256` links the
    /// manifest to the bytes actually written to `engine-config.json`; `supplementalArtifactsSHA256`
    /// links it to the bytes written to `artifacts-manifest.json`.
    func canonicalJSON() -> String {
        var output = "{"
        output += "\"engineConfigSHA256\":"; appendJSONString(engineConfigSHA256, into: &output)
        output += ",\"endWallClock\":"; appendJSONString(Self.iso8601(endWallClock), into: &output)
        output += ",\"runID\":"; appendJSONString(runID.rawValue, into: &output)
        output += ",\"startWallClock\":"; appendJSONString(Self.iso8601(startWallClock), into: &output)
        output += ",\"status\":"; appendJSONString(status.rawValue, into: &output)
        output += ",\"supplementalArtifactsSHA256\":"; appendJSONString(supplementalArtifactsSHA256, into: &output)
        output += "}"
        return output
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// Deterministic JSON body for `summary.json`.
struct RunSummary {
    let runID: BenchmarkRunID
    let status: RunStatus
    let eventCount: Int

    func canonicalJSON() -> String {
        var output = "{"
        output += "\"eventCount\":\(eventCount)"
        output += ",\"runID\":"; appendJSONString(runID.rawValue, into: &output)
        output += ",\"status\":"; appendJSONString(status.rawValue, into: &output)
        output += "}"
        return output
    }
}

/// Deterministic JSON body for `failures.json`.
struct RunFailures {
    let messages: [String]

    func canonicalJSON() -> String {
        var output = "{\"failures\":["
        for (index, message) in messages.enumerated() {
            if index > 0 { output += "," }
            appendJSONString(message, into: &output)
        }
        output += "]}"
        return output
    }
}
