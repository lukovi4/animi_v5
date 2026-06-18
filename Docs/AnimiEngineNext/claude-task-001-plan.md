# Task 001 — Isolated Engine Skeleton & Evidence Foundation (Implementation Plan)

> **Gate status:** This document IS the "Required Claude Code response" demanded by
> `Docs/AnimiEngineNext/claude-task-001-proposal.md` (§ "Required Claude Code response").
> **No code is written until the technical lead explicitly accepts this plan.**
>
> **Revision 3 — FINAL / APPROVED** — incorporates the lead's 12 corrections plus 4 final corrections
> (platform strings, TestSupport deps, NDJSON staging+atomic-publish, copied-fixture symlink/dotfile
> tests, IDGenerator scoped to BenchmarkRunID only). **Task 001 implementation is approved.**

## Context

The product owner approved (`approval-request.md`, 2026-06-12) building a *new* video engine
`AnimiEngineNext` **beside** the current product, with an **evidence system first** — before any
media playback. Task 001 lays only the foundation: an isolated package, a versioned typed
configuration with a stable hash, an immutable benchmark-run evidence writer, and a real-template
fixture index that **hashes but does not load or render** templates. No decoder, renderer, proxy,
cache, audio, export, or UI code is in scope.

Approved decisions in force: **D-101** (independent package), **D-102** (no import of `AnimiApp`
or current playback/export), **D-103** (future `.tve` adapter — *not* this task), **D-105/106/107**
(evaluator/scheduler/publisher contracts — *not* implemented here), **D-109** (versioned config +
stored hash), **D-110** (immutable evidence). Pending decisions (D-104, D-108, D-111, D-112) and all
benchmark decisions (D-2xx) are **not** assumed or implemented.

## Confirmed design choices

1. **Placement:** a new **top-level package** `AnimiEngineNext/` beside `TVECore/`, own `Package.swift`.
2. **Device benchmark host:** **deferred.** Task 001 ships only the SPM package + Level-1 unit tests
   (`swift test`). **No `.xcodeproj`/`project.pbxproj` edits.**
3. **Fixtures:** index real templates by **catalog directory ID + relative path + SHA-256 content
   hash**. **No copying of assets, no template edits** (Forbidden scope).
4. **Lint/boundary wiring:** **deferred** (not a Task-001 deliverable; recorded as a follow-up only).

## Zero-dependency stance

The package has **no product dependencies** — it does **not** depend on `TVECore` and **must not**
import `AnimiApp`. D-103's `.tve` adapter is a *later* gate; Task 001 only proves fixtures can be
*identified and hashed*, never loaded.

## Platform & toolchain (correction #1)

- `Package.swift`: **swift-tools 5.9**, platforms declared as **version strings**:
  **`.iOS("18.0")`** and **`.macOS("15.0")`** for host-side `swift test`. **Do not use the
  `.v18`/`.v15` enum constants.** **Minimum iOS is 18, not 16.** (Diverges from TVECore's iOS 16 floor
  by design.)

## Proposed package layout

```
AnimiEngineNext/
  Package.swift                          # tools 5.9, .iOS("18.0") / .macOS("15.0")
  README.md                              # how to run the tests
  Docs/
    ADR-001-package-and-dependency-boundaries.md
    ADR-014-diagnostics-evidence-and-comparison.md
  Sources/
    AnimiEngineNext/                     # PUBLIC product: contracts + versioned typed configuration
      EngineConfiguration.swift          # Codable, schemaVersion, placeholders (see contract below)
      ConfigurationError.swift           # typed errors: unknownField(path) / outOfRange / unsupportedSchema
      ConfigurationDecoder.swift         # recursive strict decode — rejects unknown keys at any depth
      CanonicalEncoding.swift            # deterministic canonical byte form (sorted keys, fixed numbers)
      ConfigurationHash.swift            # SHA-256 over canonical bytes (NO Hasher / NO quantizedHash)
    AnimiEngineDiagnostics/              # PUBLIC product: immutable run manifests + structured events
      BenchmarkRun.swift                 # exclusive-create dir, atomic writes, seal on close
      RunArtifacts.swift                 # run-manifest/engine-config/device/events/summary/failures
      DiagnosticEvent.swift              # runID, elapsed monotonic ns, subsystem, eventType, fields
      DeviceInfo.swift                   # device.json payload (no media calls)
      Clocks.swift                       # WallClock + MonotonicClock protocols (separate)
      IDGenerator.swift                  # BenchmarkRunID source only (injected; deterministic in tests)
    AnimiEngineTestSupport/              # NON-PUBLIC target (no .library product) — see #9
                                         # depends on AnimiEngineNext + AnimiEngineDiagnostics
      TemplateFixtureIndex.swift         # 5 real templates: catalog ID + relative path + SHA-256
      TemplateRepositoryRoot.swift       # injected root abstraction (no CWD dependence)
      CopiedFixture.swift                # copies a fixture to a temp dir for mutation-based tests
      TestClocks.swift                   # deterministic WallClock/MonotonicClock/IDGenerator fakes
  Tests/
    AnimiEngineNextTests/                # pure Level-1 unit tests (XCTest, mirror TVECore)
      ConfigurationTests.swift
      ConfigurationHashGoldenTests.swift
      EvidenceArtifactTests.swift
      RunDirectorySealingTests.swift
      TemplateFixtureIndexTests.swift
```

**Targets & products (correction #9):**
- `.library` products: **`AnimiEngineNext`** and **`AnimiEngineDiagnostics`** only.
- **`AnimiEngineTestSupport` is a plain `.target`, NOT exposed as a package product** — it is a
  test/dev-only dependency consumed by `AnimiEngineNextTests`, never published.
- **`AnimiEngineTestSupport` depends on BOTH `AnimiEngineNext` AND `AnimiEngineDiagnostics`**
  (correction #2) — `TestClocks` implements the diagnostics `WallClock`/`MonotonicClock`/`IDGenerator`
  protocols, so it must see the `Diagnostics` target.
- Internal direction: `Diagnostics` → `AnimiEngineNext`; `TestSupport` → `AnimiEngineNext` +
  `AnimiEngineDiagnostics`; `Tests` → all three; none → `TVECore`/`AnimiApp`.

## Clocks & identity (correction #3)

Three **separately injected** abstractions, never a single combined clock:

- **`WallClock`** → returns calendar/wall time; used **only** for the run **manifest** timestamp.
- **`MonotonicClock`** → returns a monotonic instant; each `DiagnosticEvent` stores **elapsed monotonic
  time** (ns since run start), never wall time.
- **`IDGenerator`** → produces **only the `BenchmarkRunID`** for this task; injected so tests are
  deterministic. **No other identity types are introduced.** The separate
  `ProjectRevision`/`PlaybackEpoch`/`FrameRequestID`/`MediaRequestID`/`CacheArtifactID`/`ExportJobID`
  identities belong to the **pending D-108** identity model and are explicitly out of Task-001 scope.

No `Date()`/`Date.now`/`DispatchTime` is read directly inside logic; production wires real
implementations, tests wire deterministic fakes (`TestClocks`). This keeps every artifact byte-stable
under test (acceptance #4/#6).

## Configuration contract (D-109)

`EngineConfiguration` is `Codable`, carries an explicit `schemaVersion`, and contains **placeholders
only** — no value is declared "optimal." Fields cover: project frame rate; preview frame-rate ladder;
decoder backend + pool limits; proxy profiles; cache profiles; render-quality profiles; memory limits;
export profiles; diagnostics sampling + output.

**Strict recursive rejection (correction #8):** decoding **fails** on unknown fields **at any nesting
depth**, on out-of-range values, and on unsupported schema versions. `ConfigurationDecoder` validates
every keyed container (top-level *and* nested objects/arrays-of-objects) against its known key set and
throws `ConfigurationError.unknownField(path:)` with the full key path. This deliberately inverts
TVECore's *tolerant* Lottie decoder, satisfying validation-contract §7 ("unrecorded configuration
changes: 0"). Typed-error pattern mirrors `TVECore/Sources/TVECompilerCore/Loader/ScenePackageLoadError.swift`
(enum + `LocalizedError`).

**Hashing (correction #2):** `ConfigurationHash` = **SHA-256 over canonical bytes**. `CanonicalEncoding`
emits a deterministic byte form (sorted keys, fixed-format numbers, stable string encoding). **Swift
`Hasher` and any `quantizedHash` approach are explicitly forbidden** (non-portable / non-reproducible
across runs and processes). A **fixed golden-hash test** pins the SHA-256 of a known reference config to
a hard-coded expected digest, so any silent encoding change fails CI (acceptance #4).

## Evidence contract (D-110)

One run = one **immutable** directory. Task-001 subset: `run-manifest.json`, `engine-config.json`,
`device.json`, `events.ndjson`, `summary.json`, `failures.json`. (Broader validation-contract artifacts
— `media-manifest`/`frame-metrics`/`project-snapshot`/`output/` — are later gates, not written here.)

**Run-directory lifecycle (correction #4):** `BenchmarkRun`
- **exclusively creates** the run directory (fails if it already exists — no overwrite of prior runs);
- writes each artifact **atomically** (write to a temp file, then atomic rename into place);
- **seals** the run on completion: after close, the run is marked finished and **any further write or
  re-open attempt is rejected** with a typed error.
- Manifest records **wall-clock** start/end (via `WallClock`) and the explicit success/failure status
  (acceptance #5).

**`events.ndjson` staging + atomic publish (correction #3):** events are appended to a **temporary
staging file** (e.g. `events.ndjson.partial`) *during* the run; the final `events.ndjson` is
**published by atomic rename only when the run closes**. The incomplete staging file is never the final
artifact — at no point does a readable `events.ndjson` exist while the run is still open. A test
asserts that mid-run the final path is absent (only the `.partial` staging file exists), and that after
close the final `events.ndjson` appears atomically with the staging file gone.

Every `DiagnosticEvent` carries: `BenchmarkRunID`, **elapsed monotonic time**, subsystem, eventType,
structured fields (acceptance #6). Serialization is deterministic (sorted keys, NDJSON one-event-per-line)
for byte-comparison in tests.

## Real-template fixture index (D-004)

`TemplateFixtureIndex` enumerates the five mandatory templates under the **injected repository root**
(correction #5 — `TemplateRepositoryRoot`, never `FileManager` CWD / `#file` heuristics in production
logic): `full_image`, `polaroid_shared_demo`, `polaroid_2`, `example_4blocks`, `6_frames_template`,
each resolved under `SceneSources/<id>/`.

**Canonical fixture ID (correction #7):** the **catalog directory ID** (e.g. `example_4blocks`) is the
canonical key. The internal `sceneId` (e.g. `scene_test_2x2_4blocks`) is captured **only as optional
metadata**, stored as an opaque string without parsing template semantics.

**Hash formula (correction #6):** the template content hash is **SHA-256** computed over, for each
included file in **sorted relative-path order**: the **relative path bytes**, the **file size**, then
the **file bytes**. Rules:
- **ignore hidden/system files** (dotfiles such as `.DS_Store`, and OS metadata);
- **reject symlinks** — encountering a symlink inside a template is a typed error (no following);
- **exclude** the redundant compiled `AnimiApp/Resources/Scenes/<id>/compiled.tve`.

The index **only** identifies and hashes — it never loads/parses/renders (acceptance #7, #9).

**Mutation-based tests use copied fixtures (correction #4):** the symlink-rejection and dotfile-ignore
tests must **copy a fixture into a temporary directory** (`CopiedFixture` helper) and plant the
symlink / dotfile **there**. Tests **never create, modify, or delete anything inside `SceneSources/`**.
The real `SceneSources/` is read-only input for the index; only the temp copy is mutated.

## ADR documentation (correction #11)

Two ADRs added **inside the package** at `AnimiEngineNext/Docs/`, **strictly reflecting already-approved
decisions** (no new technical choices, no benchmark presumptions):

- **`ADR-001-package-and-dependency-boundaries.md`** — records D-101/D-102: independent Swift package;
  zero dependency on `AnimiApp` or current playback/export/timeline; `AnimiEngineTestSupport` is
  non-public; minimum iOS 18. States explicitly that the `.tve` adapter (D-103) is a later gate.
- **`ADR-014-diagnostics-evidence-and-comparison.md`** — records D-109/D-110 as realized here:
  versioned config + SHA-256 canonical hash; immutable exclusively-created, atomically-written, sealed
  run directory; separate WallClock/MonotonicClock/IDGenerator; the six Task-001 artifacts and the
  required event fields. Notes the deferred artifacts as future scope.

Both ADRs cite the source decisions and carry status "Accepted (foundation subset) — broader scope
deferred," so they do not pre-empt the still-pending ADRs.

## Exact files to CREATE (all new; nothing existing modified)

- `AnimiEngineNext/Package.swift`
- `AnimiEngineNext/README.md`
- `AnimiEngineNext/Docs/ADR-001-package-and-dependency-boundaries.md`
- `AnimiEngineNext/Docs/ADR-014-diagnostics-evidence-and-comparison.md`
- `AnimiEngineNext/Sources/AnimiEngineNext/EngineConfiguration.swift`
- `AnimiEngineNext/Sources/AnimiEngineNext/ConfigurationError.swift`
- `AnimiEngineNext/Sources/AnimiEngineNext/ConfigurationDecoder.swift`
- `AnimiEngineNext/Sources/AnimiEngineNext/CanonicalEncoding.swift`
- `AnimiEngineNext/Sources/AnimiEngineNext/ConfigurationHash.swift`
- `AnimiEngineNext/Sources/AnimiEngineDiagnostics/BenchmarkRun.swift`
- `AnimiEngineNext/Sources/AnimiEngineDiagnostics/RunArtifacts.swift`
- `AnimiEngineNext/Sources/AnimiEngineDiagnostics/DiagnosticEvent.swift`
- `AnimiEngineNext/Sources/AnimiEngineDiagnostics/DeviceInfo.swift`
- `AnimiEngineNext/Sources/AnimiEngineDiagnostics/Clocks.swift`
- `AnimiEngineNext/Sources/AnimiEngineDiagnostics/IDGenerator.swift`
- `AnimiEngineNext/Sources/AnimiEngineTestSupport/TemplateFixtureIndex.swift`
- `AnimiEngineNext/Sources/AnimiEngineTestSupport/TemplateRepositoryRoot.swift`
- `AnimiEngineNext/Sources/AnimiEngineTestSupport/CopiedFixture.swift`
- `AnimiEngineNext/Sources/AnimiEngineTestSupport/TestClocks.swift`
- `AnimiEngineNext/Tests/AnimiEngineNextTests/ConfigurationTests.swift`
- `AnimiEngineNext/Tests/AnimiEngineNextTests/ConfigurationHashGoldenTests.swift`
- `AnimiEngineNext/Tests/AnimiEngineNextTests/EvidenceArtifactTests.swift`
- `AnimiEngineNext/Tests/AnimiEngineNextTests/RunDirectorySealingTests.swift`
- `AnimiEngineNext/Tests/AnimiEngineNextTests/TemplateFixtureIndexTests.swift`

## Files I will NOT touch (correction #12 — acceptance criterion #1)

- **No** edits to `AnimiApp/**`, `TVECore/**`, `SceneSources/**`, `animi.xcodeproj`,
  `AnimiApp/AnimiApp.xcodeproj`, any `project.pbxproj`, or any template asset.
- **No** edits to current playback/renderer/export/project/UI code.
- **No** edits to `.swiftlint.yml`, `Makefile`, or `Scripts/` (lint/boundary wiring deferred).

## Verification

1. `cd AnimiEngineNext && swift build` — package builds independently (acceptance #2).
2. `cd AnimiEngineNext && swift test` — Level-1 units pass (acceptance #3):
   - identical config → identical SHA-256; reordered keys → identical SHA-256; **golden-hash test**
     matches the pinned digest (#4);
   - unknown field at **top level and nested** → `unknownField(path:)`; out-of-range → error; bad
     schema version → error (#8);
   - a run **exclusively creates** its dir; writes are atomic; after close, re-open/extra-write is
     **rejected**; overwriting an existing run dir is **rejected** (#5, #4);
   - **mid-run the final `events.ndjson` is absent** (only the `.partial` staging file exists); after
     close it is **published atomically** and the staging file is gone (correction #3);
   - manifest carries wall-clock start/end; events carry **elapsed monotonic** time + required fields;
     `events.ndjson` is valid NDJSON (#6);
   - all five fixtures resolve under the **injected root**; hashes are stable & non-empty; on a
     **temp-copied** fixture, a planted symlink is rejected and a planted dotfile is ignored —
     `SceneSources/` is never written to (#6, #7, correction #4).
3. `git status` shows only new files under `AnimiEngineNext/` (plus this plan) — proves #1/#12.
4. I will report: changed-file list, exact commands run, full test output, and known gaps (#10).

## Open conflicts / notes for the technical lead

1. **ADRs:** ADR-001 and ADR-014 are authored here as the *foundation subset* of the broader
   ADR-001…014 set listed in `decision-register.md`; they record only already-approved decisions and do
   not pre-empt the still-pending ADRs.
2. **Platform divergence:** package floor is **iOS 18**, intentionally higher than TVECore's iOS 16.
3. **Zero-dependency choice** departs from a depend-on-TVECore suggestion; D-103's `.tve` adapter is a
   later gate.
4. **Duration-compression conflict** (decision-register §"Known conflict": current engine halves the
   timeline by ½ transition; D-016/017 forbid this) — **out of scope** for Task 001 (no evaluator),
   recorded only so it isn't lost.
