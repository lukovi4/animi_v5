import Foundation
import CryptoKit

/// Task-003 plan §10.1/§10.2 — the controlled supplemental-artifact surface for a ``BenchmarkRun``.
///
/// Task 003 (and later validation gates) need to write rich evidence — project snapshots, render
/// manifests, candidate PNGs, diff images, contact sheets — into the same write-once run directory
/// that Task-001 publishes atomically. No renderer or graph compiler is allowed to touch the
/// filesystem directly (D3-12); every byte flows through ``BenchmarkRun/writeSupplementalArtifact(data:at:)``
/// and is committed by the run manifest.
///
/// This file owns the *validated path* type, the typed error domain, and the canonical
/// supplemental-manifest encoding. The lifecycle integration (write gating, recording, manifest
/// emission at close) lives in ``BenchmarkRun``.

/// A normalized, relative, validated path for a supplemental artifact inside a run's staging
/// directory (Task-003 plan §10.1).
///
/// A value of this type can only be produced by ``init(_:)``, which enforces every rule the plan
/// lists. Once constructed it is guaranteed to be a safe, forward-slash-separated relative path with
/// at least one non-empty component, no `.`/`..`/empty components, no NUL, no platform separator,
/// and not colliding with a reserved core-artifact name.
public struct SupplementalArtifactPath: Hashable, Sendable, Comparable {
    /// The normalized relative path, always using `/` as the component separator.
    public let normalized: String

    /// The ordered, validated, non-empty path components.
    public let components: [String]

    /// Core artifact names that may never be used as supplemental paths (single-component reserve).
    /// These are the Task-001 published artifacts plus the Task-003 supplemental manifest itself.
    static let reservedNames: Set<String> = {
        var names = Set(RunArtifact.allCases.map { $0.rawValue })
        names.insert(RunArtifact.eventsStaging)
        names.insert(RunArtifact.supplementalManifest)
        return names
    }()

    /// Validate `rawPath` per Task-003 plan §10.1.
    ///
    /// Rejects: empty input; absolute paths (leading `/`); a backslash anywhere (platform separator);
    /// a NUL scalar anywhere; any empty component (e.g. `a//b`, trailing `/`); `.` or `..` as a
    /// component; and a single-component path that collides with a reserved core-artifact name.
    public init(_ rawPath: String) throws {
        guard !rawPath.isEmpty else {
            throw SupplementalArtifactError.invalidPath(path: rawPath, reason: "empty path")
        }
        guard !rawPath.unicodeScalars.contains("\u{00}") else {
            throw SupplementalArtifactError.invalidPath(path: rawPath, reason: "NUL scalar")
        }
        // Reject the platform separator outright; the canonical separator is `/` only.
        guard !rawPath.contains("\\") else {
            throw SupplementalArtifactError.invalidPath(path: rawPath, reason: "platform separator '\\'")
        }
        guard !rawPath.hasPrefix("/") else {
            throw SupplementalArtifactError.invalidPath(path: rawPath, reason: "absolute path")
        }

        let rawComponents = rawPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for component in rawComponents {
            if component.isEmpty {
                throw SupplementalArtifactError.invalidPath(path: rawPath, reason: "empty component")
            }
            if component == "." || component == ".." {
                throw SupplementalArtifactError.invalidPath(path: rawPath, reason: "'.'/'..' component")
            }
        }
        guard !rawComponents.isEmpty else {
            throw SupplementalArtifactError.invalidPath(path: rawPath, reason: "no components")
        }
        // A single-component path may not shadow a reserved core artifact.
        if rawComponents.count == 1, Self.reservedNames.contains(rawComponents[0]) {
            throw SupplementalArtifactError.reservedName(name: rawComponents[0])
        }

        self.components = rawComponents
        self.normalized = rawComponents.joined(separator: "/")
    }

    public static func < (lhs: SupplementalArtifactPath, rhs: SupplementalArtifactPath) -> Bool {
        lhs.normalized < rhs.normalized
    }
}

/// One recorded supplemental write (Task-003 plan §10.2): normalized path, byte size, SHA-256.
public struct SupplementalArtifactEntry: Equatable, Sendable {
    public let path: SupplementalArtifactPath
    public let byteSize: Int
    public let sha256: String

    public init(path: SupplementalArtifactPath, byteSize: Int, sha256: String) {
        self.path = path
        self.byteSize = byteSize
        self.sha256 = sha256
    }

    static func record(path: SupplementalArtifactPath, data: Data) -> SupplementalArtifactEntry {
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return SupplementalArtifactEntry(path: path, byteSize: data.count, sha256: hex)
    }

    /// Deterministic single-object JSON. Keys are emitted in fixed lexicographic order.
    func canonicalJSON() -> String {
        var output = "{"
        output += "\"path\":"; appendJSONString(path.normalized, into: &output)
        output += ",\"sha256\":"; appendJSONString(sha256, into: &output)
        output += ",\"size\":\(byteSize)"
        output += "}"
        return output
    }
}

/// The canonical `artifacts-manifest.json` body (Task-003 plan §10.2).
///
/// Entries are sorted by normalized path before emission, so the manifest — and therefore its
/// SHA-256, recorded as `supplementalArtifactsSHA256` in `run-manifest.json` — is byte-stable for a
/// given set of supplemental writes regardless of write order. An empty run still produces a
/// canonical manifest (an empty `entries` array) with a well-defined hash.
struct SupplementalArtifactsManifest {
    let entries: [SupplementalArtifactEntry]

    func canonicalJSON() -> String {
        let sorted = entries.sorted { $0.path < $1.path }
        var output = "{\"entries\":["
        for (index, entry) in sorted.enumerated() {
            if index > 0 { output += "," }
            output += entry.canonicalJSON()
        }
        output += "]}"
        return output
    }

    func canonicalBytes() -> Data {
        Data(canonicalJSON().utf8)
    }
}

/// Typed errors for the supplemental-artifact surface (Task-003 plan §9, §10.1).
///
/// These cover only the **pre-write, caller-fault** conditions that leave the run open because no
/// filesystem mutation occurred. Lifecycle violations reuse the canonical ``BenchmarkRunError``
/// (`runAlreadySealed`/`runPreviouslyFailed`); filesystem failures (including symlink-traversal and
/// overwrite rejections from the exclusive `O_NOFOLLOW`/`O_EXCL` write) surface as
/// `BenchmarkRunError.ioFailure`/`.runDirectoryAlreadyExists` and poison the run.
public enum SupplementalArtifactError: Error, Equatable, Sendable {
    /// The path failed validation (absolute, `.`/`..`, empty component, NUL, platform separator …).
    case invalidPath(path: String, reason: String)
    /// The single-component path collides with a reserved core-artifact name.
    case reservedName(name: String)
    /// The same supplemental path was written more than once within a run. Rejected before any
    /// filesystem mutation, so the run stays open.
    case duplicatePath(path: String)
}

extension SupplementalArtifactError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidPath(let path, let reason):
            return "Invalid supplemental artifact path '\(path)': \(reason)"
        case .reservedName(let name):
            return "Supplemental artifact path '\(name)' collides with a reserved core artifact name"
        case .duplicatePath(let path):
            return "Supplemental artifact path '\(path)' was already written (overwrite rejected)"
        }
    }
}
