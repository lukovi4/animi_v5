# Task 001 — Revision 4 Corrective Plan (Evidence Integrity & Transactional Publication)

> **Gate status:** This is a **corrective plan only**. Task 001 is **NOT accepted**. No code is
> written until the technical lead explicitly approves this Revision 4. The Revision 3 package is
> already implemented and green (24/24 `swift test`); this revision *modifies* that package to close
> six integrity gaps the lead identified.
>
> **Scope of change:** `AnimiEngineNext/` package only. **No** changes to `TVECore`, `AnimiApp`,
> `SceneSources/`, any `project.pbxproj`/`*.xcodeproj`, or any existing product file.

---

## 1. Defects being corrected (lead's six points)

| # | Defect (as-built in Revision 3) | Required corrective behaviour |
|---|---|---|
| C-1 | `run-manifest.json` does **not** store the config SHA-256; no integrity link between manifest and `engine-config.json`. | Manifest stores `engineConfigSHA256`; on close it is computed once, written, and **re-verified** against the bytes actually written to `engine-config.json`. |
| C-2 | `close()` is **not transactional**: `events.ndjson` is published by rename *before* the other five artifacts are written. A failure mid-`close()` leaves a visible run dir with partial evidence. | Publication is **all-or-nothing**: if `close()` fails at any step, **no** final run and **no** final artifacts are observable. |
| C-3 | `appendEvent` writes any event, even one whose `runID` ≠ the run's `runID`. | A foreign `runID` is rejected with a **typed error**; nothing is written for it. |
| C-4 | `IDGenerator` exists but `BenchmarkRun` never uses it — the caller passes a `runID` directly. | `BenchmarkRun` **obtains its `runID` from an injected `IDGenerator`**; tests inject a deterministic generator. |
| C-5 | No failure-injection coverage; "interrupted close never publishes" is unproven. | Add fault-injection tests proving an interrupted `close()` publishes **nothing** final. |
| C-6 | No tests for hash integrity, foreign-`runID` rejection, or deterministic injected ID generation. | Add the three test families. |

---

## 2. Exact design

### 2.1 Transactional publication (C-2) — **staging-directory + atomic directory publish**

**Decision (needs approval — see §5, AD-001):** replace the "create the final run dir up front,
write files into it" model with a **staging directory** that is **atomically renamed into the final
run path as the last step of `close()`**.

Lifecycle becomes:

1. **`init`** — exclusively reserve the **final** run path (fail if it exists), but do **not** create
   it. Create a sibling **staging** directory `…/<runName>.staging-<runID>` and open
   `events.ndjson.partial` inside it. The final run path never exists while the run is open.
2. **`appendEvent`** — append to the staging events file (after the C-3 `runID` guard).
3. **`close(...)`** — entirely inside the staging dir:
   1. close the events handle; rename `events.ndjson.partial` → `events.ndjson` (still inside staging);
   2. compute `engineConfigBytes = CanonicalEncoding.canonicalBytes(of:)` and
      `engineConfigSHA256 = ConfigurationHash.sha256Hex(of:)`;
   3. write `engine-config.json` (atomic, inside staging); **read it back and re-hash**; assert equal
      to `engineConfigSHA256` (C-1 integrity), else throw `evidenceIntegrityFailure`;
   4. write `device.json`, `summary.json`, `failures.json` (atomic, inside staging);
   5. write `run-manifest.json` **last** — it now carries `engineConfigSHA256` and is the commit
      marker;
   6. **publish**: `moveItem(at: stagingDir, to: finalRunDir)` — a **single atomic directory rename**.
      Only here does the final run become observable.
   7. mark sealed.
4. **On any thrown error in `close()`** — the staging dir is removed (best-effort) and the final run
   path is **never created**. Re-`close()`/`appendEvent` after a *successful* close throws
   `runAlreadySealed`; after a *failed* close the run is marked **`failed`/poisoned** and further
   calls throw `runAlreadySealed` too (a run gets exactly one close attempt).

Why a directory rename: `rename(2)` of a directory within the same filesystem is atomic, so observers
of the final path see **either nothing or the complete run** — never a half-written dir. Staging and
final dirs are created under the **same parent** (the caller-provided `directoryURL`'s parent) to keep
the rename intra-filesystem.

> **Alternative considered (AD-001 option B):** keep the in-place dir but gate visibility on a
> `COMPLETED` sentinel written last. Rejected as default because the run *directory* is still visible
> with partial files; "no final run visible" is only true if every reader honours the sentinel. The
> staging-rename gives the property structurally. Lead may override — see §5.

### 2.2 Config-hash in manifest + verification (C-1)

- `RunManifest` gains `engineConfigSHA256: String`; emitted as a sorted-key field
  `"engineConfigSHA256"` (sorts before `endWallClock`). New manifest key order:
  `engineConfigSHA256, endWallClock, runID, startWallClock, status`.
- In `close()`: hash is computed from the canonical bytes, those **same bytes** are written to
  `engine-config.json`, then the file is **read back and re-hashed**; mismatch →
  `BenchmarkRunError.evidenceIntegrityFailure(reason:)`. This proves the manifest's hash matches the
  on-disk config, not merely the in-memory value.
- The golden-hash test already pins the reference config digest; a new test (T-C1b) asserts the
  manifest field equals `ConfigurationHash.sha256Hex(of: referenceConfiguration())`.

### 2.3 Foreign-`runID` rejection (C-3)

- `appendEvent` first checks `event.runID == self.runID`; if not, throw
  `BenchmarkRunError.foreignRunID(expected:found:)` **before** any write; `eventCount` unchanged.

### 2.4 Inject & use `IDGenerator` (C-4)

- `BenchmarkRun.init` signature changes from taking `runID:` to taking `idGenerator: IDGenerator`.
  `runID` is assigned from `idGenerator.makeRunID()` and remains a public `let`.
- Production callers pass `UUIDRunIDGenerator()`; tests pass `TestIDGenerator(ids:)`.
- `TestIDGenerator` already exists (`AnimiEngineTestSupport/TestClocks.swift`) and is deterministic.

### 2.5 Fault injection for tests (C-5) — **injected file-operations seam**

**Decision (needs approval — see §5, AD-002):** introduce a minimal internal protocol
`RunFileSystem` wrapping only the operations `BenchmarkRun` performs (`createDirectory`,
`createFile`, `write(data:to:)`, `moveItem`, `removeItem`, `fileExists`, `contentsOfFile`). Production
uses `DefaultRunFileSystem` (thin `FileManager`/`Data` wrapper). Tests use a
`FaultInjectingRunFileSystem` (in `AnimiEngineTestSupport`) that forwards to the default but throws on
the **Nth call to a named operation** (e.g. "fail the `moveItem` that publishes the run", "fail the
`write` of `run-manifest.json`"). This is the only way to deterministically prove C-2/C-5 without real
disk faults. The seam is internal to the package; no product surface changes.

> The protocol is intentionally tiny and **not** a general VFS. If the lead prefers, AD-002 option B
> is "subclass `FileManager` and override two methods" — rejected because `Data.write(to:options:)`
> bypasses `FileManager`, so a subclass cannot intercept the artifact writes; the protocol seam is
> needed for honest fault injection.

---

## 3. Exact files changed / created

### Changed (existing package files — all under `AnimiEngineNext/`)

| File | Change |
|---|---|
| `Sources/AnimiEngineDiagnostics/BenchmarkRun.swift` | `init` takes `idGenerator:` (not `runID:`); staging-dir lifecycle; transactional `close()` with directory-rename publish + staging cleanup on failure; `appendEvent` foreign-`runID` guard; route all FS ops through injected `RunFileSystem`; compute+verify config hash. |
| `Sources/AnimiEngineDiagnostics/RunArtifacts.swift` | `RunManifest` gains `engineConfigSHA256`; new `BenchmarkRunError` cases `foreignRunID(expected:found:)` and `evidenceIntegrityFailure(reason:)` + their `errorDescription`. |

### Created (new package files — all under `AnimiEngineNext/`)

| File | Purpose |
|---|---|
| `Sources/AnimiEngineDiagnostics/RunFileSystem.swift` | `RunFileSystem` protocol + `DefaultRunFileSystem` production impl. |
| `Sources/AnimiEngineTestSupport/FaultInjectingRunFileSystem.swift` | Test double: forwards to default, throws on the Nth call to a named op. |
| `Tests/AnimiEngineNextTests/EvidenceIntegrityTests.swift` | C-1 hash-in-manifest + read-back verification tests (T-C1a/b). |
| `Tests/AnimiEngineNextTests/TransactionalCloseTests.swift` | C-2/C-5 fault-injection: interrupted close publishes nothing (T-C2*). |
| `Tests/AnimiEngineNextTests/EventRunIDTests.swift` | C-3 foreign-`runID` rejection tests (T-C3*). |
| `Tests/AnimiEngineNextTests/RunIDGenerationTests.swift` | C-4 deterministic injected ID generation tests (T-C4*). |

### Updated tests (existing, due to `init` signature change)

| File | Change |
|---|---|
| `Tests/AnimiEngineNextTests/EvidenceArtifactTests.swift` | Construct runs via `TestIDGenerator(ids:)`; assert manifest now carries `engineConfigSHA256`. |
| `Tests/AnimiEngineNextTests/RunDirectorySealingTests.swift` | Same `init` migration; "exclusive create" now asserts the **final** path is reserved and absent until publish. |

**Not touched:** every `AnimiEngineNext/Sources/AnimiEngineNext/*` file (config/hash logic unchanged),
`TemplateFixtureIndex` and fixture tests, both ADRs (will be amended only if the lead approves
AD-001/AD-002 — see §5), `Package.swift` (no new targets/products; new files land in existing targets).

---

## 4. Test matrix

| ID | Test | Proves | Mechanism |
|---|---|---|---|
| T-C1a | `engine-config.json` re-hash on close equals computed hash | C-1 on-disk integrity | normal close, read-back hash == manifest field |
| T-C1b | manifest `engineConfigSHA256` == `ConfigurationHash.sha256Hex(of: reference)` | C-1 correctness | parse manifest JSON |
| T-C1c | tampering injected: config bytes written ≠ hashed → `evidenceIntegrityFailure`; nothing published | C-1 enforcement | `FaultInjectingRunFileSystem` returns altered bytes from `contentsOfFile` |
| T-C2a | `moveItem` (publish rename) fails → final run dir **absent**, staging removed, `ioFailure` thrown | C-2/C-5 | fault on publish op |
| T-C2b | `write` of `run-manifest.json` fails → final run dir **absent**, no `events.ndjson` anywhere final | C-2/C-5 | fault on manifest write |
| T-C2c | `write` of `device.json` fails → final run dir **absent** | C-2/C-5 | fault on Nth write |
| T-C2d | after a failed `close()`, a second `close()`/`appendEvent` throws `runAlreadySealed` | one-shot close | sequential calls |
| T-C2e | successful close → final dir present, staging gone, all six artifacts present (regression) | C-2 happy path | normal close |
| T-C3a | `appendEvent` with foreign `runID` → `foreignRunID(expected:found:)`, `eventCount` unchanged, staging events file unchanged | C-3 | mismatched event |
| T-C3b | `appendEvent` with matching `runID` → appended (regression) | C-3 | matching event |
| T-C4a | `TestIDGenerator(ids:["run-A","run-B"])` → first run's `runID == "run-A"` | C-4 determinism | inspect `run.runID` |
| T-C4b | two sequential runs from same generator get successive scripted ids | C-4 injection actually used | two runs |
| T-C4c | manifest/summary/events all carry the **generated** id | C-4 wiring | parse artifacts |
| (regression) | full Revision-3 suite re-run after `init` migration | no behavioural regression | `swift test` |

**Determinism note:** fault-injection tests assert on *final-path absence* and *error type*, not on
byte content of partial staging files, so they remain stable across platforms.

---

## 5. New architectural decisions requiring tech-lead approval

- **AD-001 — Transactional publication via staging-directory rename.**
  Adopt "build in `…​.staging-<runID>`, publish by one atomic directory `rename` as the final step of
  `close()`." The final run path does not exist until the complete run is ready.
  *Option B (rejected as default):* in-place dir + `COMPLETED` sentinel.
  **Impact:** changes the run-directory lifecycle described in ADR-014 ("exclusively creates the run
  directory" → "exclusively reserves the final path; creates a staging dir; publishes atomically").
  If approved, ADR-014 is amended accordingly (no new decision beyond D-110's intent — this *realizes*
  immutability more strictly).

- **AD-002 — Internal `RunFileSystem` seam for fault injection.**
  Introduce a tiny package-internal file-operations protocol so failure paths in `close()` are
  deterministically testable. Not a public product API; lives in `AnimiEngineDiagnostics` with a
  test-only fault-injecting impl in `AnimiEngineTestSupport`.
  *Option B (rejected):* `FileManager` subclass — cannot intercept `Data.write(to:)`.

- **AD-003 — `BenchmarkRun.init` API change (`runID:` → `idGenerator:`).**
  Source-breaking for any caller; the only callers today are this package's tests. Confirms C-4 by
  construction (a run cannot be made without a generator).

- **AD-004 — One-shot close semantics.**
  A run permits exactly one `close()` attempt; a *failed* close poisons the run (no retry/republish).
  This keeps "no partial publish" simple and avoids half-committed retries. Flagged in case the lead
  wants retryable close instead.

If any of AD-001…AD-004 is rejected, I will re-plan that slice before implementing.

---

## 6. Verification (to run after approval — not now)

1. `cd AnimiEngineNext && swift build`.
2. `cd AnimiEngineNext && swift test` — full suite incl. new T-C* families.
3. `git status` shows only modified/new files under `AnimiEngineNext/` (plus this plan doc under
   `Docs/AnimiEngineNext/`).
4. Report: changed-file list, exact commands, full test output, known gaps.

## 7. Out of scope / unchanged

- No decoder/renderer/proxy/cache/audio/export/UI.
- No device-benchmark host, no `.xcodeproj`/`pbxproj`.
- No edits to `TVECore`, `AnimiApp`, `SceneSources/`, templates, lint/Makefile/Scripts.
- Configuration decode/encode/hash logic itself is unchanged (only *where the hash is recorded and
  verified* changes).

**STOP — awaiting explicit approval of Revision 4 (and AD-001…AD-004) before any implementation.**
