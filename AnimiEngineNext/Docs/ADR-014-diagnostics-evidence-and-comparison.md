# ADR-014 — Diagnostics, Evidence & Comparison

- **Status:** Accepted (foundation subset) — broader scope deferred.
- **Source decisions:** D-109 (versioned config + stored hash), D-110 (immutable evidence).
- **Realized in:** Task 001 (`claude-task-001-plan.md`, Revision 3; lifecycle hardened in Revision 5).

## Context

Before any media playback, the new engine needs a trustworthy evidence foundation: configuration must be
versioned and reproducibly hashable, and every benchmark run must produce a byte-stable set of artifacts
that is published transactionally (all-or-nothing) and can be compared across runs. "Immutable" here
means **write-once through `BenchmarkRun`** — the run is sealed and never re-opened by this package — not
a filesystem-enforced property.

## Decision

### Versioned configuration + canonical hash (D-109)

- `EngineConfiguration` is `Codable`, carries an explicit `schemaVersion`, and contains **placeholders
  only** — no value is declared "optimal."
- Decoding is **strict and recursive**: unknown fields at *any* nesting depth, out-of-range values, and
  unsupported schema versions are hard failures (`ConfigurationError`). This inverts TVECore's tolerant
  Lottie decoder so that unrecorded configuration changes are impossible.
- The configuration hash is **SHA-256 over canonical bytes** (sorted keys, fixed-format numbers, stable
  string encoding). Swift's `Hasher` and any `quantizedHash` approach are **forbidden** as non-portable
  and non-reproducible. A pinned golden-hash test fails CI on any silent encoding change.

### Write-once evidence (D-110) — transactional realization (Revision 5)

- One run = one **write-once** directory (sealed through `BenchmarkRun`, not filesystem-enforced).
  The Task-001 artifact subset is: `run-manifest.json`,
  `engine-config.json`, `device.json`, `events.ndjson`, `summary.json`, `failures.json`.
- A run is constructed from a caller-provided **parent** directory plus an injected `IDGenerator`.
  The `runID` is generated and validated as a safe path component (1…128 chars of
  `A-Z a-z 0-9 - _`); the final and staging paths are derived from it.
- The run is **reserved** by **exclusively creating a staging directory** (`.<runID>.staging`) under
  the parent. The **final** run directory (`<runID>`) is *not* created during the run.
- All artifacts are written **atomically** (temp file + atomic rename) **inside** the staging
  directory. `events.ndjson` is streamed to `events.ndjson.partial` and finalized inside staging.
- On close, `engine-config.json` is written, **read back, and re-hashed** through the single
  `ConfigurationHash.sha256Hex(ofCanonicalBytes:)`; the digest is recorded in the manifest as
  `engineConfigSHA256`. A mismatch aborts the close with `evidenceIntegrityFailure`.
- The run is **published** as the *last* step by a **single atomic, no-overwrite** directory move
  (`renamex_np(from, to, RENAME_EXCL)`). The final run becomes observable only on success. On a
  publication collision the **existing final directory remains unchanged** — `BenchmarkRun` never
  creates or modifies it — and the call throws `runDirectoryAlreadyExists`.
- **Lifecycle states:** `open → closing → sealed` (success) or `open → closing → failed`. On any
  close failure the staging directory is removed and the final path is never created. Calls after a
  **sealed** run throw `runAlreadySealed`; calls after a **failed** run throw `runPreviouslyFailed`
  (the two states are distinct). A run gets exactly one close attempt.
- A diagnostic event whose `runID` differs from the run's `runID` is rejected with `foreignRunID`.
- The manifest records **wall-clock** start/end, the explicit success/failure status, and
  `engineConfigSHA256`.

### Clocks & identity

- Three **separately injected** abstractions: `WallClock` (manifest timestamps only),
  `MonotonicClock` (each event stores elapsed monotonic ns since run start, never wall time), and
  `IDGenerator` (produces **only** the `BenchmarkRunID`). No logic reads `Date()`/`DispatchTime`
  directly; tests inject deterministic fakes so artifacts are byte-stable.

## Deferred / future scope

- Broader validation-contract artifacts — `media-manifest`, `frame-metrics`, `project-snapshot`,
  `output/` — are **later gates** and are not written here.
- The richer identity model (`ProjectRevision`/`PlaybackEpoch`/`FrameRequestID`/…) belongs to the
  pending **D-108** work and is out of Task-001 scope.

## Consequences

- Configurations are reproducibly comparable by digest across runs and processes; the manifest's
  `engineConfigSHA256` is verified against the on-disk `engine-config.json` at close time.
- Evidence is **transactionally published, no-overwrite, and sealed through `BenchmarkRun`**: an
  observer of the final path sees **either nothing or a complete, published run** — never a
  half-written directory — because the run is built in a staging directory and committed by a single
  atomic, no-overwrite directory move.
- Concurrent publication to the same final path is resolved by the kernel (`renamex_np` /
  `RENAME_EXCL`): exactly one publisher wins and the winner is never overwritten. Staging reservation
  is likewise a single atomic `mkdir`, so exactly one initializer can reserve a given staging path.

## Scope of the guarantee (what is and is not enforced)

- The integrity guarantees hold for evidence produced and committed **through `BenchmarkRun`**. This
  is **not** filesystem-enforced immutability and the artifacts are **not** tamper-evident: once
  published, the directory is an ordinary directory.
- **Out-of-band filesystem modification is not detected.** If a process edits, deletes, or replaces a
  published artifact directly on disk, `BenchmarkRun` does not observe it. The **one** integrity
  relationship that is recorded is the manifest's `engineConfigSHA256` versus `engine-config.json`:
  a later reader can recompute the canonical hash and compare. No other artifact carries such a
  relationship, and even that check is opt-in by the reader — nothing in this package re-validates a
  run after it is sealed.
- Determinism under injected clocks makes artifacts directly byte-comparable in tests; the
  `RunFileSystem` seam enables deterministic fault-injection of the publication path.

## Reference Promotion & Comparison Closure (Task 003 §17 steps 13–17)

- **Status:** Accepted. Realized in Task 003 (`claude-task-003-step-13`…`step-17` plans). This section is the
  ADR home for what the Task-003 plan §17 step 18 calls "ADR-010" — **no `ADR-010` file exists**; the
  diagnostics/evidence/comparison decision lives here, in ADR-014. The implementation report records the
  numbering mapping.

### Candidate generation → comparison → evidence (steps 13–14)
- A **candidate** is a `RenderedFrame` rendered by the completed Metal executor for a deterministic
  `(catalog, block, variant, projectTimeTicks)` input, captured as a byte-deterministic PNG
  (`DeterministicPNGEncoder`: stored DEFLATE + filter 0 + hand CRC32 — never CoreGraphics, so evidence is
  byte-stable across OS/SDK). `FrameComparator` yields `exactMatch` / `withinBounds` / `outOfBounds` /
  `candidateOnly`. Every candidate + comparison + contact sheet + per-group `render-manifest.json` is written
  through `BenchmarkRun.writeSupplementalArtifact` (the same transactional, manifest-last path as above).
- The complete real-template/frame matrix + structural fixtures run through ONE `BenchmarkRun`
  (`MatrixDriver`), grouped per catalog + one structural group; candidate count is **64** (55 real + 9
  structural). All artifact writes are transactional; an injected fault poisons the run and publishes nothing.

### Guarded reference promotion (step 17)
- **Promotion is the ONLY way an approved reference is created**, performed by `ReferencePromoter` from a
  single owner-approved sealed run. It promotes the run's candidate **bytes** (a byte copy of the
  deterministic PNGs) into the committed `AnimiEngineNext/ReferenceData/references/<candidateID>.png`, plus a
  canonical `approval-manifest.json` (per-reference `candidateID`/`rawOutputHash`/`graphHash`/`configHash`/
  material identity/`referenceSHA256`, the source runID + aggregate, optional approval attribution, and a
  body self-hash `approvalManifestSHA256` written last).
- **Guards (all must pass before any write):** source status success; run-manifest aggregate ==
  `artifacts-manifest`; source runID == the approved runID (the obsolete run is rejected); candidate count ==
  expected; no `references/`/`diffs/` already in the source; every verdict `candidateOnly`; per-file
  integrity (PNG SHA == artifacts-manifest AND decoded `rawOutputHash` == render-manifest); no dirty approved
  root; no overwrite unless byte-identical. Promotion is transactional (staging → atomic publish), idempotent
  for identical bytes, and **git-reversible** — it writes files but does **not** auto-commit; a
  `git revert`/`checkout` undoes it.

### No self-blessing (carried invariant)
- A comparison run **never** writes, creates, or updates an approved reference, and **never** copies current
  render output into the reference set. References are promoted bytes from an **approved** run only.
  `outOfBounds` is recorded, never auto-blessed; it does not gate a run (record-only) unless an explicit owner
  policy says otherwise. The READ-ONLY `ReferenceStore` has no write path at all.

### Device-gate policy
- The full matrix + comparison run on the **M2 Pro** (the Metal executor runs on macOS). The **iPhone 13 Pro**
  (`iPhone14,2`, A15) app-hosted `IPhoneDeviceGateTests` verifies only the device-specific facts the host
  cannot (physical-device assertion, `.private` staging upload + `uploadBlit` event order, GPU/OS evidence,
  4× MSAA, masks/mattes/transitions on device, a Step-14 candidate-evidence subset). The DeviceGateHost
  project structure is **frozen** (it links only `AnimiEngineMetalRender`); anything needing more linkage is a
  STOP rather than a project-file change. No comparison/promotion happens on device.
