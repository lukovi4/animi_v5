import Foundation
import AnimiEngineNext

/// One run = one **write-once** directory (decision **D-110**, Task-001 plan "Evidence contract"),
/// realized transactionally per Revision 5.
///
/// "Write-once" means the run is built in a staging directory and committed atomically, then sealed
/// — `BenchmarkRun` never re-opens it. This is **not** filesystem-enforced immutability and the
/// artifacts are **not** tamper-evident: out-of-band edits to a published run are not detected. The
/// recorded integrity relationships are the manifest's `engineConfigSHA256` vs `engine-config.json`
/// and (Task-003 §10.2) its `supplementalArtifactsSHA256` vs `artifacts-manifest.json`, which in turn
/// records the per-artifact size and SHA-256 of every supplemental file written via
/// ``writeSupplementalArtifact(data:at:)``.
///
/// Lifecycle:
///   * `init` generates a `runID` from the injected `IDGenerator`, validates it as a safe path
///     component, derives the final + staging paths under the caller's **parent** directory, and
///     **exclusively creates the staging directory** (this is the run's reservation). The final run
///     directory is *not* created here.
///   * `appendEvent` streams events (after a `runID` guard) into the staging events file.
///   * `writeSupplementalArtifact` writes one evidence file into staging via an exclusive,
///     descriptor-relative (`O_NOFOLLOW`/`O_EXCL`) operation and records it for the supplemental
///     manifest. A filesystem failure here **poisons** the run (see below).
///   * `close` writes the supplemental manifest, the remaining core artifacts and (last) the run
///     manifest inside staging, verifies the config hash by reading `engine-config.json` back, then
///     **atomically publishes** the staging directory to the final path with a single no-overwrite
///     system call. Nothing final is observable until that publish succeeds.
///
/// States: `open → closing → sealed` (success) or `open → closing → failed`. The run also moves
/// directly to `failed` if a supplemental filesystem write fails — its events handle is closed and
/// the entire staging directory is removed, so the final directory never appears. After `failed`,
/// calls throw `runPreviouslyFailed`; after `sealed`/`closing`, calls throw `runAlreadySealed`.
///
/// This type is not thread-safe; a single run is driven from a single context.
public final class BenchmarkRun {
    /// Lifecycle state (Revision-5 §2.3).
    enum State {
        case open
        case closing
        case sealed
        case failed
    }

    public let runID: BenchmarkRunID
    public let directoryURL: URL          // the FINAL run directory (created only on publish)
    let stagingDirectoryURL: URL

    private let wallClock: WallClock
    private let monotonicClock: MonotonicClock
    private let fileSystem: RunFileSystem

    private let startWall: Date
    private let startMonotonic: UInt64

    private let eventsStagingURL: URL
    private var eventsHandle: FileHandle
    private var eventCount = 0

    /// Task-003 §10 — recorded supplemental writes, in write order. Sorted by path at close.
    private var supplementalEntries: [SupplementalArtifactEntry] = []
    /// Paths already written, for the write-once guard (D3-12, §10.1).
    private var writtenSupplementalPaths: Set<SupplementalArtifactPath> = []

    private(set) var state: State = .open

    // MARK: - Initialization

    /// Public production initializer — wires `DefaultRunFileSystem` internally.
    public convenience init(
        parentDirectoryURL: URL,
        idGenerator: IDGenerator,
        wallClock: WallClock,
        monotonicClock: MonotonicClock
    ) throws {
        try self.init(
            parentDirectoryURL: parentDirectoryURL,
            idGenerator: idGenerator,
            wallClock: wallClock,
            monotonicClock: monotonicClock,
            fileSystem: DefaultRunFileSystem()
        )
    }

    /// Package-scoped initializer accepting a `RunFileSystem` — used by tests for fault injection
    /// (Revision-5 amendment 3).
    package init(
        parentDirectoryURL: URL,
        idGenerator: IDGenerator,
        wallClock: WallClock,
        monotonicClock: MonotonicClock,
        fileSystem: RunFileSystem
    ) throws {
        let generatedRunID = idGenerator.makeRunID()
        try BenchmarkRun.validateRunID(generatedRunID)

        self.runID = generatedRunID
        self.directoryURL = parentDirectoryURL.appendingPathComponent(generatedRunID.rawValue, isDirectory: true)
        self.stagingDirectoryURL = parentDirectoryURL
            .appendingPathComponent(".\(generatedRunID.rawValue).staging", isDirectory: true)
        self.wallClock = wallClock
        self.monotonicClock = monotonicClock
        self.fileSystem = fileSystem

        // Exclusive staging creation = the reservation. Throws runDirectoryAlreadyExists if present.
        try fileSystem.createDirectoryExclusively(at: stagingDirectoryURL)

        // From here on, any failure must remove the staging directory (init-failure cleanup).
        self.startWall = wallClock.now()
        self.startMonotonic = monotonicClock.nanoseconds()
        self.eventsStagingURL = stagingDirectoryURL.appendingPathComponent(RunArtifact.eventsStaging)

        do {
            try fileSystem.createFile(at: eventsStagingURL)
            self.eventsHandle = try FileHandle(forWritingTo: eventsStagingURL)
        } catch {
            try? fileSystem.removeItem(at: stagingDirectoryURL)
            throw error
        }
    }

    // MARK: - runID validation (Revision-5 amendment 2)

    /// A `runID` is valid iff it is 1...128 ASCII characters drawn only from `A-Z a-z 0-9 - _`.
    static func validateRunID(_ runID: BenchmarkRunID) throws {
        let value = runID.rawValue
        guard (1...128).contains(value.count) else {
            throw BenchmarkRunError.unsafeRunID(value: value)
        }
        for scalar in value.unicodeScalars {
            let isAllowed =
                (scalar >= "A" && scalar <= "Z") ||
                (scalar >= "a" && scalar <= "z") ||
                (scalar >= "0" && scalar <= "9") ||
                scalar == "-" || scalar == "_"
            if !isAllowed {
                throw BenchmarkRunError.unsafeRunID(value: value)
            }
        }
    }

    // MARK: - Streaming events

    /// Appends one diagnostic event to the staging file. The event's `runID` must match this run's
    /// `runID`, else `BenchmarkRunError.foreignRunID` is thrown and nothing is written.
    public func appendEvent(_ event: DiagnosticEvent) throws {
        try ensureOpen()
        guard event.runID == runID else {
            throw BenchmarkRunError.foreignRunID(expected: runID.rawValue, found: event.runID.rawValue)
        }
        let line = event.canonicalLine() + "\n"
        do {
            try eventsHandle.write(contentsOf: Data(line.utf8))
        } catch {
            throw BenchmarkRunError.ioFailure(reason: "append event: \(error)")
        }
        eventCount += 1
    }

    /// Elapsed monotonic nanoseconds since this run started.
    public func elapsedNanoseconds() -> UInt64 {
        monotonicClock.nanoseconds() &- startMonotonic
    }

    // MARK: - Supplemental artifacts (Task-003 §10.1)

    /// Write one supplemental evidence artifact into the run's staging directory.
    ///
    /// This is the **only** sanctioned way for Task-003 (and later gates) to add evidence to a run;
    /// no renderer or graph compiler writes files directly (D3-12). The write is recorded for the
    /// supplemental manifest emitted at ``close(engineConfiguration:deviceInfo:status:failures:)`` and
    /// is never observable under the final run path until publication.
    ///
    /// Lifecycle and failure semantics (Task-003 corrective pass):
    ///   * the run uses the **same lifecycle contract** as every other write — `closing`/`sealed`
    ///     throw ``BenchmarkRunError/runAlreadySealed``; `failed` throws
    ///     ``BenchmarkRunError/runPreviouslyFailed``;
    ///   * `path` is already validated by ``SupplementalArtifactPath`` (relative, normalized,
    ///     no `.`/`..`/empty/NUL/separator, not a reserved core name);
    ///   * a duplicate path throws ``SupplementalArtifactError/duplicatePath(path:)`` **before any
    ///     filesystem mutation**, leaving the run open (no bytes were touched);
    ///   * the actual write is delegated to
    ///     ``RunFileSystem/writeSupplementalFileExclusively(relativeComponents:data:underStagingRoot:)``,
    ///     which walks descriptor-relative from the staging root with `O_NOFOLLOW`/`O_EXCL` — so
    ///     symlink traversal and overwrite are rejected by the kernel with no validate-then-write
    ///     window;
    ///   * **any filesystem failure poisons the run**: the events handle is closed, the entire
    ///     staging directory is removed, the final directory never appears, the state becomes
    ///     `failed`, and every subsequent `close`/`write` throws `runPreviouslyFailed`.
    ///
    /// The caller never receives the staging-directory URL.
    public func writeSupplementalArtifact(data: Data, at path: SupplementalArtifactPath) throws {
        // Lifecycle gate — reuse the canonical contract; no new error domain for "not open".
        try ensureOpen()

        // Pre-write validation: a duplicate is a caller error with NO filesystem mutation, so the
        // run stays open.
        guard !writtenSupplementalPaths.contains(path) else {
            throw SupplementalArtifactError.duplicatePath(path: path.normalized)
        }

        // The exclusive descriptor-relative write is the only filesystem mutation. Any throw from
        // here touched (or attempted to touch) the filesystem and must poison the run.
        do {
            try fileSystem.writeSupplementalFileExclusively(
                relativeComponents: path.components,
                data: data,
                underStagingRoot: stagingDirectoryURL
            )
        } catch {
            poison()
            throw error
        }

        writtenSupplementalPaths.insert(path)
        supplementalEntries.append(SupplementalArtifactEntry.record(path: path, data: data))
    }

    /// Poison the run after a filesystem mutation failed outside `close()`: close the events handle,
    /// remove the entire staging directory, and transition to `failed` so the final directory never
    /// appears and all subsequent `close`/`write` calls throw `runPreviouslyFailed`. Idempotent and
    /// best-effort on cleanup (a cleanup failure must not mask the original error).
    private func poison() {
        state = .failed
        try? eventsHandle.close()
        try? fileSystem.removeItem(at: stagingDirectoryURL)
    }

    // MARK: - Closing / publishing

    /// Writes all artifacts inside staging, verifies the config hash via read-back, and atomically
    /// publishes the run. On any failure the staging directory is removed and the final run path is
    /// never created; the run transitions to `failed`.
    public func close(
        engineConfiguration: EngineConfiguration,
        deviceInfo: DeviceInfo,
        status: RunStatus,
        failures: [String] = []
    ) throws {
        try ensureOpen()
        state = .closing
        do {
            try performClose(
                engineConfiguration: engineConfiguration,
                deviceInfo: deviceInfo,
                status: status,
                failures: failures
            )
            state = .sealed
        } catch {
            state = .failed
            try? eventsHandle.close()
            try? fileSystem.removeItem(at: stagingDirectoryURL)
            throw error
        }
    }

    private func performClose(
        engineConfiguration: EngineConfiguration,
        deviceInfo: DeviceInfo,
        status: RunStatus,
        failures: [String]
    ) throws {
        // 1. Finalize the events stream inside staging.
        do {
            try eventsHandle.close()
        } catch {
            throw BenchmarkRunError.ioFailure(reason: "close events staging: \(error)")
        }
        let eventsFinalURL = stagingDirectoryURL.appendingPathComponent(RunArtifact.events.rawValue)
        try fileSystem.renameWithinDirectory(from: eventsStagingURL, to: eventsFinalURL)

        // 2. Compute the config hash from canonical bytes (single hash entry point).
        let configBytes = CanonicalEncoding.canonicalBytes(of: engineConfiguration)
        let hashInMemory = ConfigurationHash.sha256Hex(ofCanonicalBytes: configBytes)

        // 3. Write engine-config.json, read it back, and re-hash through the SAME implementation.
        let engineConfigURL = stagingDirectoryURL.appendingPathComponent(RunArtifact.engineConfig.rawValue)
        try fileSystem.write(configBytes, to: engineConfigURL)
        let readBack = try fileSystem.contentsOfFile(at: engineConfigURL)
        let hashOnDisk = ConfigurationHash.sha256Hex(ofCanonicalBytes: readBack)
        guard hashOnDisk == hashInMemory else {
            throw BenchmarkRunError.evidenceIntegrityFailure(
                reason: "engine-config.json re-hash \(hashOnDisk) ≠ computed \(hashInMemory)"
            )
        }

        // 4. Write the supplemental artifacts manifest (Task-003 §10.2): entries sorted by path,
        //    canonical `artifacts-manifest.json` written inside staging, its SHA-256 recorded for the
        //    run manifest. An empty run still records the canonical hash of an empty manifest.
        let supplementalManifest = SupplementalArtifactsManifest(entries: supplementalEntries)
        let supplementalBytes = supplementalManifest.canonicalBytes()
        let supplementalHash = ConfigurationHash.sha256Hex(ofCanonicalBytes: supplementalBytes)
        try fileSystem.write(
            supplementalBytes,
            to: stagingDirectoryURL.appendingPathComponent(RunArtifact.supplementalManifest)
        )

        // 5. Write the remaining non-manifest core artifacts.
        try fileSystem.write(Data(deviceInfo.canonicalJSON().utf8),
                             to: stagingDirectoryURL.appendingPathComponent(RunArtifact.device.rawValue))
        let summary = RunSummary(runID: runID, status: status, eventCount: eventCount)
        try fileSystem.write(Data(summary.canonicalJSON().utf8),
                             to: stagingDirectoryURL.appendingPathComponent(RunArtifact.summary.rawValue))
        try fileSystem.write(Data(RunFailures(messages: failures).canonicalJSON().utf8),
                             to: stagingDirectoryURL.appendingPathComponent(RunArtifact.failures.rawValue))

        // 6. Write the manifest LAST — it carries the verified config hash, the supplemental-manifest
        //    hash, and is the commit marker.
        let endWall = wallClock.now()
        let manifest = RunManifest(
            engineConfigSHA256: hashInMemory,
            runID: runID,
            startWallClock: startWall,
            endWallClock: endWall,
            status: status,
            supplementalArtifactsSHA256: supplementalHash
        )
        try fileSystem.write(Data(manifest.canonicalJSON().utf8),
                             to: stagingDirectoryURL.appendingPathComponent(RunArtifact.runManifest.rawValue))

        // 7. Publish atomically with no overwrite. Only here does the final run become observable.
        try fileSystem.publishDirectoryExclusively(from: stagingDirectoryURL, to: directoryURL)
    }

    // MARK: - State gating

    private func ensureOpen() throws {
        switch state {
        case .open:
            return
        case .closing, .sealed:
            throw BenchmarkRunError.runAlreadySealed
        case .failed:
            throw BenchmarkRunError.runPreviouslyFailed
        }
    }
}
