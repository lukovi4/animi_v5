# Task 001 — Revision 5 Corrective Plan (Transactional Evidence, Final)

> **Gate status:** Corrective plan only. Task 001 is **NOT accepted**. No code is written until the
> technical lead explicitly approves Revision 5. Supersedes Revision 4; incorporates the lead's eight
> mandatory corrections. **Approved decisions carried in:** AD-001 (staging + atomic publish),
> AD-002 (`RunFileSystem`), AD-003 (injected `IDGenerator`), AD-004 (one-shot close, **with `failed`
> and `sealed` as distinct states**).
>
> **Scope:** `AnimiEngineNext/` package only. **No** changes to `TVECore`, `AnimiApp`,
> `SceneSources/`, any `*.pbxproj`/`*.xcodeproj`, or any existing product file.

---

## 0. How the eight corrections map into this plan

| Lead correction | Where addressed |
|---|---|
| 1. Accept `parentDirectoryURL`; generate `runID`; derive final/staging paths from it; staging = reservation; reject unsafe `runID`. | §2.1 |
| 2. Publication atomic **and** no-overwrite via dedicated `publishDirectoryExclusively`. | §2.2, §2.6 |
| 3. `RunFileSystem` uses Swift `package` access; public prod init + `package` init taking `RunFileSystem`. | §2.6, §3 |
| 4. Explicit states `open → closing → sealed` / `open → closing → failed`; post-failure calls throw `runPreviouslyFailed`. | §2.3 |
| 5. `ConfigurationHash.sha256Hex(ofCanonicalBytes:)`; single impl for in-memory + read-back. | §2.4, §3 |
| 6. Fault injection targets **semantic op + path/artifact**, not "Nth call". | §2.6, §4 |
| 7. Init-failure cleanup tests + atomic no-overwrite publication tests. | §4 |
| 8. ADR-014 in changed-file list and updated to new lifecycle. | §3, §5 |

---

## 1. Defects corrected (unchanged from R4, restated)

- **C-1** manifest stores + verifies config SHA-256 against on-disk `engine-config.json`.
- **C-2** `close()` is all-or-nothing; no final run/artifacts visible on failure.
- **C-3** foreign-`runID` events rejected with a typed error.
- **C-4** `runID` comes from an injected `IDGenerator`.
- **C-5** fault-injection proves interrupted close publishes nothing.
- **C-6** tests for hash integrity, foreign-`runID`, deterministic injected IDs.

---

## 2. Exact design

### 2.1 Construction: parent dir + generated runID + derived paths (correction 1)

`BenchmarkRun.init` no longer accepts a run directory or a `runID`. It accepts a **parent** directory
and an `IDGenerator`:

```
public init(
    parentDirectoryURL: URL,
    idGenerator: IDGenerator,
    wallClock: WallClock,
    monotonicClock: MonotonicClock
)                                  // public production initializer (uses DefaultRunFileSystem)

package init(
    parentDirectoryURL: URL,
    idGenerator: IDGenerator,
    wallClock: WallClock,
    monotonicClock: MonotonicClock,
    fileSystem: RunFileSystem
)                                  // package-scoped, used by tests for fault injection
```

Steps in `init`:

1. `let runID = idGenerator.makeRunID()` — C-4 by construction.
2. **Validate `runID` as a path-safe component** (see §2.5). Unsafe → `BenchmarkRunError.unsafeRunID(value:)`.
   No directory is created in this case.
3. Derive paths under `parentDirectoryURL`:
   - `finalRunDirURL  = parent/<runID>`
   - `stagingDirURL   = parent/.<runID>.staging`
4. **Exclusive staging creation = the reservation:** create `stagingDirURL` with
   `withIntermediateDirectories: false`. If it already exists, throw
   `BenchmarkRunError.runDirectoryAlreadyExists(path:)`. (The *final* path is checked for non-existence
   at publish time, §2.2 — staging creation is what reserves the run.)
5. Open `events.ndjson.partial` inside staging. State = **`open`**.
6. Capture `startWall` / `startMonotonic`.

If any step after staging creation throws, `init` **removes the staging dir** before rethrowing
(init-failure cleanup, tested in §4 T-IN*). The final path is never created.

### 2.2 Transactional, no-overwrite publication (corrections 1, 2)

`close(engineConfiguration:deviceInfo:status:failures:)` performs, entirely inside staging:

1. State → **`closing`** (guard: only legal from `open`).
2. Close events handle; rename `events.ndjson.partial` → `events.ndjson` **inside staging**.
3. `let bytes = CanonicalEncoding.canonicalBytes(of: engineConfiguration)`;
   `let hashInMemory = ConfigurationHash.sha256Hex(ofCanonicalBytes: bytes)` (§2.4).
4. Atomic-write `engine-config.json` (staging) from `bytes`.
5. **Read back** `engine-config.json` via `fileSystem.contentsOfFile`; `hashOnDisk =
   ConfigurationHash.sha256Hex(ofCanonicalBytes: readBack)`. If `hashOnDisk != hashInMemory` →
   `evidenceIntegrityFailure(reason:)`.
6. Atomic-write `device.json`, `summary.json`, `failures.json` (staging).
7. Atomic-write `run-manifest.json` **last**, carrying `engineConfigSHA256 = hashInMemory`.
8. **Publish:** `fileSystem.publishDirectoryExclusively(from: stagingDirURL, to: finalRunDirURL)` — a
   **single atomic, no-overwrite** directory move. If `finalRunDirURL` already exists, it throws
   `runDirectoryAlreadyExists` and **does not overwrite** (correction 2). On success the complete run
   becomes observable atomically.
9. State → **`sealed`**.

**On any thrown error in steps 1–8:** state → **`failed`**, staging dir removed (best-effort), final
path never created. The error propagates to the caller.

### 2.3 Explicit lifecycle states (correction 4)

```
enum State { case open, closing, sealed, failed }
```

Transitions: `open → closing → sealed` (success) or `open → closing → failed` (any close error).

Call gating:
| Call when state… | `open` | `closing` | `sealed` | `failed` |
|---|---|---|---|---|
| `appendEvent` | append (after C-3 guard) | `runAlreadySealed`* | `runAlreadySealed` | `runPreviouslyFailed` |
| `close` | run close | `runAlreadySealed`* | `runAlreadySealed` | `runPreviouslyFailed` |

\* `closing` is transient/non-reentrant within a single context; reaching it from another call is
treated as already-consumed (`runAlreadySealed`). One-shot close (AD-004) is preserved, but **`failed`
is now a first-class state distinct from `sealed`** and post-failure calls throw the new
`BenchmarkRunError.runPreviouslyFailed` — not `runAlreadySealed` (correction 4).

### 2.4 Single hash entry point (correction 5)

Add to `ConfigurationHash.swift`:

```
public static func sha256Hex(ofCanonicalBytes bytes: Data) -> String
```

Refactor the existing `sha256Hex(of:)` to call it:
`sha256Hex(of: c) = sha256Hex(ofCanonicalBytes: CanonicalEncoding.canonicalBytes(of: c))`.
`BenchmarkRun.close` uses **only** `sha256Hex(ofCanonicalBytes:)` for both the in-memory bytes and the
read-back bytes — one implementation, no divergence (correction 5).

### 2.5 Unsafe-runID rejection (correction 1)

A `runID.rawValue` is **path-safe** iff it is non-empty and contains none of: `/`, `\`, the components
`.`/`..`, NUL, any path separator, leading dot, or whitespace-only. Concretely reject when the value:
is empty; equals `.` or `..`; contains `/`, `\`, `\0`; begins with `.`; or differs from its own
`lastPathComponent` (catches embedded separators). Unsafe → `unsafeRunID(value:)`. Production
`UUIDRunIDGenerator` yields safe UUIDs; the guard defends against custom/injected generators.

### 2.6 `RunFileSystem` seam, `package` access, semantic faults (corrections 2, 3, 6)

`RunFileSystem` (Swift **`package`** access, so the separate `AnimiEngineTestSupport` target can
implement it):

```
package protocol RunFileSystem: Sendable {
    func createDirectoryExclusively(at: URL) throws
    func createFile(at: URL) throws
    func write(_ data: Data, to: URL) throws            // atomic temp+rename
    func renameWithinDirectory(from: URL, to: URL) throws
    func contentsOfFile(at: URL) throws -> Data
    func removeItem(at: URL) throws
    func fileExists(at: URL) -> Bool
    func publishDirectoryExclusively(from: URL, to: URL) throws   // atomic + no-overwrite (corr. 2)
}
```

- **`DefaultRunFileSystem`** — production impl over `FileManager`/`Data`. `publishDirectoryExclusively`
  checks `to` non-existence then `moveItem`; on collision throws `runDirectoryAlreadyExists`.
- **`FaultInjectingRunFileSystem`** (in `AnimiEngineTestSupport`) — forwards to a wrapped
  `DefaultRunFileSystem` but fails when a **semantic predicate** matches: `(operation, artifact/path)`
  — e.g. `.fail(.write, artifact: .runManifest)`, `.fail(.publish, finalPathSuffix: <runID>)`,
  `.fail(.readBack, artifact: .engineConfig)`, `.corruptReadBack(artifact: .engineConfig)`. Faults are
  keyed by **what** operation on **which** artifact/path, not by a brittle global call index
  (correction 6). A `.corruptReadBack` variant returns altered bytes to drive the C-1 integrity path.

The `package` initializer injects any `RunFileSystem`; the `public` initializer hard-wires
`DefaultRunFileSystem` (correction 3).

---

## 3. Exact files changed / created

### Changed (existing, all under `AnimiEngineNext/`)

| File | Change |
|---|---|
| `Sources/AnimiEngineNext/ConfigurationHash.swift` | Add `sha256Hex(ofCanonicalBytes:)`; refactor `sha256Hex(of:)` to delegate (correction 5). |
| `Sources/AnimiEngineDiagnostics/BenchmarkRun.swift` | `parentDirectoryURL` + derived paths; `public` + `package` inits (correction 3); generate+validate `runID`; staging reservation; `State` machine `open/closing/sealed/failed` (correction 4); transactional close with read-back hash verify; `appendEvent` foreign-`runID` guard; publish via `publishDirectoryExclusively`; init-failure + close-failure staging cleanup. |
| `Sources/AnimiEngineDiagnostics/RunArtifacts.swift` | `RunManifest` gains `engineConfigSHA256`; new `BenchmarkRunError` cases: `unsafeRunID(value:)`, `evidenceIntegrityFailure(reason:)`, `foreignRunID(expected:found:)`, `runPreviouslyFailed` (+ `errorDescription`s). |
| `Docs/ADR-014-diagnostics-evidence-and-comparison.md` | Update lifecycle to staging-reservation + atomic no-overwrite publish + four states; record manifest `engineConfigSHA256` + read-back verification (correction 8). |

### Created (new, all under `AnimiEngineNext/`)

| File | Purpose |
|---|---|
| `Sources/AnimiEngineDiagnostics/RunFileSystem.swift` | `package` protocol + `public`/`package` `DefaultRunFileSystem`; `publishDirectoryExclusively`. |
| `Sources/AnimiEngineTestSupport/FaultInjectingRunFileSystem.swift` | Semantic `(operation, artifact/path)` fault injection + read-back corruption. |
| `Tests/AnimiEngineNextTests/EvidenceIntegrityTests.swift` | C-1 hash-in-manifest + read-back verification. |
| `Tests/AnimiEngineNextTests/TransactionalCloseTests.swift` | C-2/C-5 interrupted close + init-failure cleanup + no-overwrite publish. |
| `Tests/AnimiEngineNextTests/EventRunIDTests.swift` | C-3 foreign-`runID` rejection. |
| `Tests/AnimiEngineNextTests/RunIDGenerationTests.swift` | C-4 deterministic injected ID + unsafe-runID rejection. |
| `Tests/AnimiEngineNextTests/RunLifecycleStateTests.swift` | Correction 4: `sealed` vs `failed`; `runPreviouslyFailed` after failure. |

### Migrated existing tests (due to `init` signature change)

| File | Change |
|---|---|
| `Tests/AnimiEngineNextTests/EvidenceArtifactTests.swift` | Build runs via `parentDirectoryURL` + `TestIDGenerator`; assert manifest carries `engineConfigSHA256`. |
| `Tests/AnimiEngineNextTests/RunDirectorySealingTests.swift` | `init` migration; exclusive **staging** reservation; final path absent until publish; no-overwrite at publish. |

**Not touched:** `Sources/AnimiEngineNext/{EngineConfiguration,ConfigurationError,ConfigurationDecoder,CanonicalEncoding}.swift`,
`TemplateFixtureIndex`/`CopiedFixture`/`TemplateRepositoryRoot`/fixture tests, `Clocks.swift`,
`IDGenerator.swift`, `DeviceInfo.swift`, `DiagnosticEvent.swift`, `Package.swift` (no new
targets/products — new files land in existing targets), `ADR-001`, `README.md`.

---

## 4. Test matrix

| ID | Test | Proves | Mechanism |
|---|---|---|---|
| T-C1a | normal close: read-back hash == manifest `engineConfigSHA256` | C-1 on-disk integrity | parse manifest + re-hash file |
| T-C1b | manifest field == `ConfigurationHash.sha256Hex(of: reference)` | C-1 correctness | parse manifest |
| T-C1c | `.corruptReadBack(.engineConfig)` → `evidenceIntegrityFailure`; final path absent | C-1 enforcement | fault inject |
| T-C2a | `.fail(.publish, runID)` → final dir absent, staging removed, error thrown | C-2/C-5 | semantic fault on publish |
| T-C2b | `.fail(.write, .runManifest)` → final dir absent; no final `events.ndjson` anywhere | C-2/C-5 | semantic fault on manifest write |
| T-C2c | `.fail(.write, .device)` → final dir absent | C-2/C-5 | semantic fault on device write |
| T-C2d | `.fail(.renameWithinDirectory)` (events publish-in-staging) → final dir absent | C-2/C-5 | semantic fault |
| T-PUB1 | publish when final path **already exists** → `runDirectoryAlreadyExists`, existing dir **unmodified**, staging removed | correction 2 (no-overwrite) | pre-create final dir |
| T-PUB2 | successful close → final dir present, staging gone, all six artifacts present | C-2 happy path | normal close |
| T-IN1 | `init`: `.fail(.createFile, eventsStaging)` → staging dir removed, final path absent, error thrown | correction 7 (init cleanup) | fault inject in init |
| T-IN2 | `init`: staging already exists → `runDirectoryAlreadyExists`, nothing created/removed wrongly | correction 7 | pre-create staging |
| T-C3a | foreign `runID` event → `foreignRunID(expected:found:)`; `eventCount` unchanged; staging events file unchanged | C-3 | mismatched event |
| T-C3b | matching `runID` event → appended | C-3 regression | matching event |
| T-C4a | `TestIDGenerator(ids:["run-A",…])` → `run.runID == "run-A"`; final dir name == `run-A` | C-4 + path derivation | inspect run + fs |
| T-C4b | two sequential runs → successive scripted ids | C-4 injection used | two runs |
| T-C4c | manifest/summary/events carry the generated id | C-4 wiring | parse artifacts |
| T-ID1 | unsafe runIDs (`""`, `".."`, `"a/b"`, `".hidden"`, `"a\\b"`) → `unsafeRunID`; nothing created | correction 1 | inject bad generator |
| T-ST1 | after successful close, `appendEvent`/`close` → `runAlreadySealed` | state `sealed` | sequence |
| T-ST2 | after a *failed* close, `appendEvent`/`close` → `runPreviouslyFailed` (NOT `runAlreadySealed`) | state `failed` (correction 4) | fault then re-call |
| (reg) | full Revision-3 suite re-run post-migration | no regression | `swift test` |

Fault tests assert on **final-path absence**, **typed error**, and **staging cleanup** — never on
partial-byte content — so they stay deterministic cross-platform.

---

## 5. ADR-014 update (correction 8 — included in changed-file list)

ADR-014 will be amended to state:
- run is **reserved** by exclusive creation of a **staging** directory derived from a generated
  `runID`; the **final** run directory is created only by an **atomic, no-overwrite** publish at the
  end of `close()`;
- lifecycle states **`open → closing → sealed | failed`**; failed runs are distinct from sealed and
  reject further calls with `runPreviouslyFailed`;
- `run-manifest.json` records `engineConfigSHA256`, verified by reading `engine-config.json` back and
  re-hashing through the single `ConfigurationHash.sha256Hex(ofCanonicalBytes:)`.

No new *decision* beyond D-110's intent — this realizes immutability/atomicity more strictly. ADR-001
is unchanged.

---

## 6. Architectural notes (already-approved; no new approval requested)

AD-001…AD-004 are approved; AD-004 is refined per correction 4 (`failed` ≠ `sealed`,
`runPreviouslyFailed`). No new architectural decisions are introduced by Revision 5. If implementation
uncovers a forced new decision, I will stop and re-plan that slice.

## 7. Verification (after approval — not now)

1. `cd AnimiEngineNext && swift build`.
2. `cd AnimiEngineNext && swift test` (full suite incl. all T-* families).
3. `git status` shows only modified/new files under `AnimiEngineNext/` + this plan doc under
   `Docs/AnimiEngineNext/`.
4. Report: changed-file list, exact commands, full test output, known gaps.

## 8. Out of scope / unchanged

- No decoder/renderer/proxy/cache/audio/export/UI; no device host; no `*.pbxproj`.
- No edits to `TVECore`, `AnimiApp`, `SceneSources/`, templates, lint/Makefile/Scripts.
- Config decode/encode/hash *logic* unchanged; only the new `ofCanonicalBytes:` entry point and where
  the hash is recorded/verified change.

**STOP — awaiting explicit approval of Revision 5 before any implementation.**
