import Foundation
import AnimiEngineDiagnostics

/// A `RunFileSystem` test double that forwards to a real `DefaultRunFileSystem` but injects a fault
/// when a **semantic** predicate matches — keyed by *which operation* on *which artifact/path*, not
/// by a brittle global call index (Revision-5 amendment 6).
///
/// It can also corrupt a read-back to drive the evidence-integrity path (`engine-config.json`).
package final class FaultInjectingRunFileSystem: RunFileSystem, @unchecked Sendable {

    /// Describes a single fault to inject.
    package struct Fault: Sendable {
        package enum Match: Sendable {
            /// Match an operation whose target URL's last path component equals `artifactFileName`.
            case artifact(operation: RunFileOperation, artifactFileName: String)
            /// Match the publish operation whose destination path ends with `finalPathSuffix`.
            case publish(finalPathSuffix: String)
            /// Corrupt the bytes returned by a read-back of `artifactFileName` (no throw).
            case corruptReadBack(artifactFileName: String)
        }
        package let match: Match
        package init(_ match: Match) { self.match = match }
    }

    private let base: DefaultRunFileSystem
    private let faults: [Fault]

    /// Records the semantic operations actually attempted, for test assertions.
    package private(set) var attempted: [(operation: RunFileOperation, path: String)] = []

    package init(base: DefaultRunFileSystem = DefaultRunFileSystem(), faults: [Fault]) {
        self.base = base
        self.faults = faults
    }

    // MARK: - Fault matching

    private func shouldThrow(_ operation: RunFileOperation, _ url: URL) -> Bool {
        faults.contains { fault in
            switch fault.match {
            case .artifact(let op, let name):
                return op == operation && url.lastPathComponent == name
            case .publish(let suffix):
                return operation == .publish && url.path.hasSuffix(suffix)
            case .corruptReadBack:
                return false
            }
        }
    }

    private func corruptionByteSuffix(for url: URL) -> Data? {
        for fault in faults {
            if case .corruptReadBack(let name) = fault.match, url.lastPathComponent == name {
                return Data("/*tamper*/".utf8)
            }
        }
        return nil
    }

    private func record(_ operation: RunFileOperation, _ url: URL) {
        attempted.append((operation, url.path))
    }

    // MARK: - RunFileSystem

    package func createDirectoryExclusively(at url: URL) throws {
        record(.createDirectoryExclusively, url)
        if shouldThrow(.createDirectoryExclusively, url) {
            throw BenchmarkRunError.ioFailure(reason: "injected fault: createDirectoryExclusively \(url.lastPathComponent)")
        }
        try base.createDirectoryExclusively(at: url)
    }

    package func createFile(at url: URL) throws {
        record(.createFile, url)
        if shouldThrow(.createFile, url) {
            throw BenchmarkRunError.ioFailure(reason: "injected fault: createFile \(url.lastPathComponent)")
        }
        try base.createFile(at: url)
    }

    package func write(_ data: Data, to url: URL) throws {
        record(.write, url)
        if shouldThrow(.write, url) {
            throw BenchmarkRunError.ioFailure(reason: "injected fault: write \(url.lastPathComponent)")
        }
        try base.write(data, to: url)
    }

    package func renameWithinDirectory(from source: URL, to destination: URL) throws {
        record(.renameWithinDirectory, destination)
        if shouldThrow(.renameWithinDirectory, destination) || shouldThrow(.renameWithinDirectory, source) {
            throw BenchmarkRunError.ioFailure(reason: "injected fault: renameWithinDirectory \(destination.lastPathComponent)")
        }
        try base.renameWithinDirectory(from: source, to: destination)
    }

    package func contentsOfFile(at url: URL) throws -> Data {
        record(.readBack, url)
        if shouldThrow(.readBack, url) {
            throw BenchmarkRunError.ioFailure(reason: "injected fault: readBack \(url.lastPathComponent)")
        }
        let real = try base.contentsOfFile(at: url)
        if let tamper = corruptionByteSuffix(for: url) {
            return real + tamper
        }
        return real
    }

    package func removeItem(at url: URL) throws {
        record(.removeItem, url)
        try base.removeItem(at: url)
    }

    package func writeSupplementalFileExclusively(
        relativeComponents: [String],
        data: Data,
        underStagingRoot stagingRoot: URL
    ) throws {
        // Reconstruct the leaf URL for recording / leaf-name fault matching only.
        var leafURL = stagingRoot
        for component in relativeComponents { leafURL = leafURL.appendingPathComponent(component) }
        record(.writeSupplementalFileExclusively, leafURL)
        if shouldThrow(.writeSupplementalFileExclusively, leafURL) {
            throw BenchmarkRunError.ioFailure(
                reason: "injected fault: writeSupplementalFileExclusively \(leafURL.lastPathComponent)")
        }
        try base.writeSupplementalFileExclusively(
            relativeComponents: relativeComponents, data: data, underStagingRoot: stagingRoot)
    }

    package func fileExists(at url: URL) -> Bool {
        base.fileExists(at: url)
    }

    package func publishDirectoryExclusively(from source: URL, to destination: URL) throws {
        record(.publish, destination)
        if shouldThrow(.publish, destination) {
            throw BenchmarkRunError.ioFailure(reason: "injected fault: publish \(destination.lastPathComponent)")
        }
        try base.publishDirectoryExclusively(from: source, to: destination)
    }
}
