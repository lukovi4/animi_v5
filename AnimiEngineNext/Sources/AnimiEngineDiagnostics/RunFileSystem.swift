import Foundation
import AnimiEngineDiagnosticsCShim
#if canImport(Darwin)
import Darwin
#endif

/// The semantic filesystem operations a ``BenchmarkRun`` performs. Used both to route production
/// I/O and to drive **semantic** fault injection in tests (Revision-5 §2.6, amendment 6) — faults
/// target an *operation on an artifact/path*, never a brittle "Nth call".
package enum RunFileOperation: String, Sendable {
    case createDirectoryExclusively
    case createFile
    case write
    case renameWithinDirectory
    case readBack
    case removeItem
    case publish
    /// Task-003 §10.1 — write one supplemental file exclusively, walking descriptor-relative from the
    /// staging root (no path reconstruction, no symlink following, no overwrite).
    case writeSupplementalFileExclusively
}

/// Minimal filesystem seam for benchmark-run I/O.
///
/// Declared with Swift **`package`** access so the separate `AnimiEngineTestSupport` target (same
/// package) can supply a fault-injecting implementation, while the seam stays off the public
/// product surface (Revision-5 amendment 3).
package protocol RunFileSystem: Sendable {
    /// Create a directory, failing if it already exists (no intermediate creation).
    func createDirectoryExclusively(at url: URL) throws

    /// Create an empty file at `url` (used for the events staging file).
    func createFile(at url: URL) throws

    /// Atomically write `data` to `url` (temp file + atomic rename into place).
    func write(_ data: Data, to url: URL) throws

    /// Rename a file within the same directory (used to finalize the events staging file).
    func renameWithinDirectory(from source: URL, to destination: URL) throws

    /// Read the full contents of a file (used to read `engine-config.json` back for verification).
    func contentsOfFile(at url: URL) throws -> Data

    /// Remove an item (best-effort cleanup of the staging directory).
    func removeItem(at url: URL) throws

    /// Task-003 §10.1 — write one supplemental file **exclusively**, walking descriptor-relative from
    /// the staging root.
    ///
    /// `relativeComponents` is the already-validated, normalized component list (≥ 1 component; no
    /// `.`/`..`/empty). The implementation must:
    ///   * open the staging root as a directory with `O_DIRECTORY | O_NOFOLLOW`;
    ///   * for each parent component, `mkdirat` (tolerating an existing directory) then `openat` with
    ///     `O_DIRECTORY | O_NOFOLLOW` so a symlinked component is rejected (`ELOOP`) — no absolute
    ///     path is ever reconstructed or re-walked;
    ///   * create the final file with `O_CREAT | O_EXCL | O_NOFOLLOW` so an existing target is never
    ///     overwritten and a symlinked leaf is rejected;
    ///   * write the complete buffer with a checked loop;
    ///   * close every descriptor on every return path.
    ///
    /// This is TOCTOU-free by construction: there is no validate-then-write window because the kernel
    /// resolves each component relative to a held directory descriptor with `O_NOFOLLOW`. An existing
    /// target throws `BenchmarkRunError.runDirectoryAlreadyExists`; any other failure throws
    /// `ioFailure`. The caller treats any throw as a poisoning filesystem fault.
    func writeSupplementalFileExclusively(relativeComponents: [String], data: Data, underStagingRoot stagingRoot: URL) throws

    /// Whether an item exists at `url`.
    func fileExists(at url: URL) -> Bool

    /// **Atomically** publish a directory by moving `source` to `destination` with a single
    /// no-overwrite system call. On collision the existing `destination` is left **unchanged** and
    /// `BenchmarkRunError.runDirectoryAlreadyExists` is thrown (Revision-5 amendment 1 & 5).
    func publishDirectoryExclusively(from source: URL, to destination: URL) throws
}

/// Production `RunFileSystem` over `FileManager`/`Data`. **`package`-scoped** (amendment 3): it is
/// not part of the public product surface; the public `BenchmarkRun` initializer wires it
/// internally.
package struct DefaultRunFileSystem: RunFileSystem, @unchecked Sendable {
    private let fileManager: FileManager

    /// One atomic `mkdir(2)` — **no** `fileExists` pre-check (which would race). `EEXIST` →
    /// `runDirectoryAlreadyExists`; any other errno → `ioFailure`. This makes staging reservation a
    /// single atomic operation so exactly one concurrent initializer can win.
    package func createDirectoryExclusively(at url: URL) throws {
        #if canImport(Darwin)
        let result = url.withUnsafeFileSystemRepresentation { ptr in
            mkdir(ptr, 0o755)
        }
        if result != 0 {
            let err = errno
            if err == EEXIST {
                throw BenchmarkRunError.runDirectoryAlreadyExists(path: url.path)
            }
            let message = String(cString: strerror(err))
            throw BenchmarkRunError.ioFailure(reason: "mkdir \(url.path): \(message) (errno \(err))")
        }
        #else
        throw BenchmarkRunError.ioFailure(reason: "createDirectoryExclusively requires Darwin (atomic mkdir)")
        #endif
    }

    package func createFile(at url: URL) throws {
        guard fileManager.createFile(atPath: url.path, contents: Data()) else {
            throw BenchmarkRunError.ioFailure(reason: "createFile \(url.path)")
        }
    }

    package func write(_ data: Data, to url: URL) throws {
        let tempURL = url.appendingPathExtension("tmp")
        do {
            if fileManager.fileExists(atPath: tempURL.path) {
                try fileManager.removeItem(at: tempURL)
            }
            try data.write(to: tempURL, options: .atomic)
            try fileManager.moveItem(at: tempURL, to: url)
        } catch {
            throw BenchmarkRunError.ioFailure(reason: "write \(url.lastPathComponent): \(error)")
        }
    }

    package func renameWithinDirectory(from source: URL, to destination: URL) throws {
        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            throw BenchmarkRunError.ioFailure(
                reason: "rename \(source.lastPathComponent) → \(destination.lastPathComponent): \(error)"
            )
        }
    }

    package func contentsOfFile(at url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw BenchmarkRunError.ioFailure(reason: "read \(url.lastPathComponent): \(error)")
        }
    }

    package func removeItem(at url: URL) throws {
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw BenchmarkRunError.ioFailure(reason: "remove \(url.lastPathComponent): \(error)")
        }
    }

    /// A deterministic test seam: invoked **immediately before** the shim performs its atomic
    /// descriptor-relative walk — i.e. before the staging root is even opened. This is exactly the
    /// validate-then-write window: a test can mutate the tree here (e.g. swap a component for a
    /// symlink) and assert the exclusive `O_NOFOLLOW` walk still rejects traversal. `nil` in
    /// production. The argument is the `stagingRoot` URL passed to the write (for the test's
    /// convenience only — production never re-walks paths in Swift).
    package var supplementalPreWriteHook: (@Sendable (_ stagingRoot: URL) -> Void)?

    package init(fileManager: FileManager = .default,
                 supplementalPreWriteHook: (@Sendable (_ stagingRoot: URL) -> Void)? = nil) {
        self.fileManager = fileManager
        self.supplementalPreWriteHook = supplementalPreWriteHook
    }

    package func writeSupplementalFileExclusively(
        relativeComponents: [String],
        data: Data,
        underStagingRoot stagingRoot: URL
    ) throws {
        precondition(!relativeComponents.isEmpty, "relativeComponents must be non-empty")

        // Deterministic test seam: fire BEFORE the shim's atomic descriptor-relative walk. This is
        // exactly the validate-then-write window — a test can swap a component to a symlink here, and
        // the shim's O_NOFOLLOW must still reject it. `nil` in production.
        supplementalPreWriteHook?(stagingRoot)

        let result = Self.callShim(
            relativeComponents: relativeComponents, data: data, stagingRoot: stagingRoot)

        guard result.op == AEN_OP_OK else {
            // An existing leaf (no overwrite) is reported as a directory-collision error to reuse the
            // canonical lifecycle vocabulary; every other failure is a typed ioFailure naming the step.
            if result.op == AEN_OP_OPEN_LEAF, result.err == EEXIST {
                throw BenchmarkRunError.runDirectoryAlreadyExists(
                    path: stagingRoot.appendingPathComponent(relativeComponents.joined(separator: "/")).path)
            }
            throw Self.shimError(result)
        }
    }

    /// Bind the staging-root path, the component C-string array, and the data buffer, then call the
    /// shim. Component pointers are bound by a recursive helper so every `[CChar]`'s storage stays
    /// valid for the duration of the call (no escaping `baseAddress`).
    private static func callShim(
        relativeComponents: [String],
        data: Data,
        stagingRoot: URL
    ) -> aen_shim_result {
        stagingRoot.withUnsafeFileSystemRepresentation { rootPtr in
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                withArrayOfCStrings(relativeComponents) { ptrBuffer in
                    aen_write_supplemental_file_exclusively(
                        rootPtr,
                        ptrBuffer,
                        relativeComponents.count,
                        raw.bindMemory(to: UInt8.self).baseAddress,
                        raw.count
                    )
                }
            }
        }
    }

    /// Invoke `body` with a `const char *const *` view of `strings`. Built recursively so each
    /// component's C-string storage is alive for the whole call.
    private static func withArrayOfCStrings<R>(
        _ strings: [String],
        _ body: (UnsafePointer<UnsafePointer<CChar>?>?) -> R
    ) -> R {
        var pointers = [UnsafePointer<CChar>?](repeating: nil, count: strings.count)
        func bind(_ index: Int) -> R {
            if index == strings.count {
                return pointers.withUnsafeBufferPointer { body($0.baseAddress) }
            }
            return strings[index].withCString { cstr in
                pointers[index] = cstr
                return bind(index + 1)
            }
        }
        return bind(0)
    }

    private static func shimError(_ result: aen_shim_result) -> BenchmarkRunError {
        let step: String
        switch result.op {
        case AEN_OP_OK: step = "ok"
        case AEN_OP_OPEN_ROOT: step = "open staging root"
        case AEN_OP_MKDIRAT: step = "mkdirat component"
        case AEN_OP_OPEN_DIR: step = "openat directory component (O_NOFOLLOW)"
        case AEN_OP_OPEN_LEAF: step = "openat leaf (O_CREAT|O_EXCL|O_NOFOLLOW)"
        case AEN_OP_WRITE: step = "write supplemental bytes"
        case AEN_OP_FSYNC: step = "fsync leaf"
        case AEN_OP_CLOSE: step = "close leaf"
        case AEN_OP_INVALID_ARG: step = "invalid argument"
        default: step = "unknown shim op \(result.op.rawValue)"
        }
        let message = String(cString: strerror(result.err))
        return BenchmarkRunError.ioFailure(reason: "supplemental \(step): \(message) (errno \(result.err))")
    }

    package func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    /// Atomic, no-overwrite directory publication via the single Apple system call
    /// `renamex_np(from, to, RENAME_EXCL)` (Revision-5 amendment 1). **No** `fileExists` +
    /// `moveItem` fallback. `EEXIST` → `runDirectoryAlreadyExists`; everything else → typed
    /// `ioFailure`.
    package func publishDirectoryExclusively(from source: URL, to destination: URL) throws {
        #if canImport(Darwin)
        let result = source.withUnsafeFileSystemRepresentation { sourcePtr in
            destination.withUnsafeFileSystemRepresentation { destPtr in
                renamex_np(sourcePtr, destPtr, UInt32(RENAME_EXCL))
            }
        }
        if result != 0 {
            let err = errno
            if err == EEXIST || err == ENOTEMPTY {
                throw BenchmarkRunError.runDirectoryAlreadyExists(path: destination.path)
            }
            let message = String(cString: strerror(err))
            throw BenchmarkRunError.ioFailure(
                reason: "renamex_np(RENAME_EXCL) \(source.lastPathComponent) → \(destination.lastPathComponent): \(message) (errno \(err))"
            )
        }
        #else
        throw BenchmarkRunError.ioFailure(reason: "publishDirectoryExclusively requires Darwin (renamex_np)")
        #endif
    }
}
