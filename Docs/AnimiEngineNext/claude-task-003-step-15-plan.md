# Task 003 / Step 15 — Implementation Plan: produce a sealed candidate-reference benchmark run

**Revision:** 1 — PLAN ONLY; awaiting owner approval.
**Status:** NOT IMPLEMENTED. This planning pass creates exactly one file (this plan). No engine code, no
test, no runnable target, no `Package.swift`, no `*.xcodeproj`/`*.pbxproj`, and no forbidden path is
modified. **No reference is promoted; no reference root is written; no Step 16 work is started.**
**Scope gate:** Task 003 §17 step 15 — *"Produce a sealed candidate-reference benchmark run."*
**Predecessor:** Step 14 (the complete real-template/frame matrix + structural fixtures through the Step-13
evidence recorder) — **ACCEPTED**. `MatrixDriver` exists and drives the matrix into one `BenchmarkRun`,
grouped per catalog + one `structural` group, closing the run once (`MatrixDriver.swift`); `Step14MatrixTests`
asserts the full matrix renders/records, default verdict `candidateOnly`, 9 structural fixtures, transactional
poison, repeatability, with-reference path leaving the approved root byte-identical.
**Successor (DO NOT START):** Step 16 — *"Stop for explicit human review and reference approval."* Step 17 —
*"After approval, promote references through the guarded tool."* This plan ends at producing the sealed run.

**Carried-forward invariants (verified in code at plan time):** one `BenchmarkRun` per matrix run; staging →
atomic publish (`renamex_np(RENAME_EXCL)`); **`run-manifest.json` written last** as the commit marker over the
supplemental aggregate (`BenchmarkRun.performClose`, steps 4 & 6); per-file + aggregate SHA-256
(`artifacts-manifest.json` → `supplementalArtifactsSHA256` in `run-manifest.json`); poison-on-fault removes the
whole staging dir so the final dir never appears; every artifact written through
`BenchmarkRun.writeSupplementalArtifact` (the `EvidenceRecorder`/`MatrixDriver` already do this exclusively);
`ReferenceStore` is READ-ONLY (no write path exists on the type); typed errors only; **no self-blessing, no
approved-reference writes** (constraints 2/5/6).

Implementation must not begin until the owner approves this plan **and** resolves the §8 open decisions.

---

## 0. Decision classification key

- **[FIXED]** — pinned by an approved contract or committed code (verified at plan time, file:line cited).
- **[DERIVED]** — necessarily follows from a FIXED contract; no new product decision.
- **[NEW]** — what Step 15 adds (no existing equivalent).
- **[OPEN]** — a genuinely unresolved decision needing an explicit owner answer before implementation (§8).

---

## 1. Current-state audit (verified in code)

### 1.1 The matrix + evidence machinery is complete and accepted — [FIXED]

- `MatrixDriver.run(session:into:engineConfiguration:deviceInfo:) -> MatrixDriver.Result` enumerates real rows
  (`RealTemplateMatrix.enumerateRows`), groups by catalog, generates each candidate
  (`CandidateGenerator.generate`), records per group (`EvidenceRecorder.recordGroup`, no close), then records
  the 9 structural fixtures as the `structural` group, then **closes the run once** with `status: .success`
  (D3: `outOfBounds` is record-only, never gates). It enforces **global** candidate-id uniqueness across the
  whole matrix (`DriverError.duplicateCandidateID` = a typed STOP). (`MatrixDriver.swift:46-107`.)
- `EvidenceRecorder.recordGroup` writes, per group prefix `"<group>/"`: `candidates/<id>.png`,
  `references/<id>.png` (only if an approved reference exists), `diffs/<id>.diff.png` (only when a reference is
  present and the verdict ≠ `exactMatch`), `comparison/<id>.json`, one `<group>/contact-sheet.png`, and one
  `<group>/render-manifest.json` — all via `writeSupplementalArtifact`. (`EvidenceRecorder.swift:59-139`.)
- `MatrixDriver.Result` carries `enumeratedRowCount`, `realRowCount`, `skippedRowCount`, `structuralRowCount`,
  `candidateCount (== real + structural, unique)`, `groupManifests: [String: RenderEvidenceManifest]`, and
  `runDirectoryURL`. (`MatrixDriver.swift:22-30`.)
- `RealTemplateMatrix.catalogs = ["full_image","polaroid_shared_demo","polaroid_2","example_4blocks",
  "6_frames_template"]`; `enumerateRows` verifies the 5/14/25 inventory internally (else `inventoryMismatch`);
  the frame-time set is `{tick0, mid (if duration>2), last (duration−1), postRoll (if postRoll>0)}`,
  deduplicated. (`RealTemplateMatrix.swift:31,59-105`.)

### 1.2 Runs today are all driven from TEST harnesses — [FIXED]

Every existing `BenchmarkRun` construction (production target + tests) is in a unit test, built with
`TestIDGenerator`/`TestWallClock`/`TestMonotonicClock` and a **temporary parent directory**
(`Step14MatrixTests.makeRun`/`tempDir`, and the `…NextTests` suites). **There is no runnable entry point that
produces a sealed run as a durable artifact** outside the test process. This is the central gap Step 15 fills.

### 1.3 Production clock / id seams exist; the run-ID generator is UUID — [FIXED]

- `BenchmarkRun` has a **public** production initializer
  (`init(parentDirectoryURL:idGenerator:wallClock:monotonicClock:)`) that wires `DefaultRunFileSystem`
  internally. (`BenchmarkRun.swift:69-82`.)
- Production seams exist: `SystemWallClock`, `SystemMonotonicClock` (`Clocks.swift`), `UUIDRunIDGenerator`
  (`IDGenerator.swift:25-30`). **`UUIDRunIDGenerator` produces a UUID run-ID** — i.e. the run-ID is NOT a
  deterministic function of the matrix inputs. This is the **run-ID-policy tension** (D2, §8): the *artifacts
  inside* the run are byte-deterministic (proven by `Step14MatrixTests`/Step-13), but the *run directory name*
  is not. The owner must pin whether the sealed run keeps the production UUID id or uses a pinned/derived id.

### 1.4 No approved-reference root exists yet — [FIXED]

A repository search finds **no `references/` reference root** anywhere. `ReferenceApproval` is an empty stub
(Step-13 D5). Therefore, with no `ReferenceStore` (or an empty one), **every candidate's verdict is
`candidateOnly`** — exactly the §3 "absent references" behaviour the owner requires. (`ReferenceStore.swift`
has *no* write path; `referenceURL`/`hasReference`/`reference(for:)` are read-only.)

### 1.5 The matrix runs on the M2 Pro (macOS); device gate is app-hosted — [FIXED]

`MatrixDriver`/`CandidateGenerator` drive `MetalRenderSession` which runs on macOS; `Step14MatrixTests`
executes the full matrix on the M2 Pro. The iPhone 13 Pro path is the app-hosted `IPhoneDeviceGateTests`
(`AnimiEngineDeviceGateHost` test target) — the **only** place on-device execution happens. The macOS
SwiftPM `MetalRenderSession` cannot run on the device. (`Step14MatrixTests.swift`,
`IPhoneDeviceGateTests.swift:9-23`.)

---

## 2. What "produce a sealed candidate-reference benchmark run" means here — [DERIVED + NEW]

Step 14 *proved* the matrix records correctly inside a transient test run. Step 15 *produces the actual sealed
run as a durable, on-disk artifact* — the candidate set that Step 16 (human review) and Step 17 (guarded
promotion) will read. Concretely:

- One `BenchmarkRun` over the **complete** Step-14 matrix (real rows grouped per catalog + the `structural`
  group), driven by the **already-accepted** `MatrixDriver.run(...)` — Step 15 adds **no** new evidence
  primitive and changes **no** RenderGraph/canonical/payload contract.
- The run is **closed successfully** (`status: .success`, manifest-last) and **atomically published** to a
  durable output root, so the final run directory exists with `run-manifest.json` last and **no
  `.<runID>.staging` directory left behind**.
- **No approved references exist** (§1.4) → the store is absent/empty → **every candidate is `candidateOnly`**;
  **no `references/` or `diffs/` artifacts** are produced (constraint: "no references/diffs unless approved
  refs exist"). The run is "candidate-reference" in the §17 sense = *the candidate set against which references
  will later be approved*, not a run that already contains approved references.
- **No promotion, no self-blessing, no approved-root write** anywhere in Step 15.

The only genuinely new component is a **runnable entry point** (a small driver/harness — D1) that wires the
production clock/id seams + a durable output root + a `MetalRenderSession` and invokes `MatrixDriver.run`.

---

## 3. Reference behavior — [FIXED by instruction]

- **Approved reference root is read-only.** Step 15 passes `referenceStore: nil` for the default sealed run
  (no root exists, §1.4). If the owner pins a root location for *snapshotting only* (D4), it is opened with the
  existing READ-ONLY `ReferenceStore` (which has no write path) — and since the root is empty, behaviour is
  identical to `nil`. The store NEVER writes under the root.
- **Absent references ⇒ `candidateOnly`.** Every candidate's verdict is `candidateOnly`; no comparison against
  an approved baseline is claimed; **no `references/` snapshot and no `diffs/` image** are written (the
  recorder only emits those when `reference != nil`). (`EvidenceRecorder.swift:98-110`.)
- **No promotion.** `ReferenceApproval` stays an empty stub. Step 15 adds no promotion/activation path. The
  candidate PNGs are NEVER copied into any approved-reference set.
- **No self-blessing.** Nothing in the run is treated as an oracle; `outOfBounds` cannot occur (no references)
  and would be record-only regardless (D3, carried).

---

## 4. What "sealed" means (the explicit close contract) — [FIXED]

A run is **sealed** iff ALL hold (verified against `BenchmarkRun.performClose`, `MatrixDriver.run`):

1. **`BenchmarkRun` closed successfully** — `MatrixDriver.run` calls `run.close(…, status: .success)` exactly
   once after the last group; the run state reaches `.sealed`. (`MatrixDriver.swift:101`,
   `BenchmarkRun.swift:233-255`.)
2. **`run-manifest.json` written last** — `performClose` writes events → `engine-config.json` (re-read +
   re-hashed) → `artifacts-manifest.json` (supplemental aggregate) → `device.json`/`summary.json`/
   `failures.json` → **`run-manifest.json` LAST** → atomic publish. (`BenchmarkRun.swift:257-323`.)
3. **The supplemental aggregate hash covers ALL matrix artifacts** — `run-manifest.json`'s
   `supplementalArtifactsSHA256` is the SHA-256 of `artifacts-manifest.json`, which records the per-file size +
   SHA-256 of **every** supplemental write (all `candidates/`, `comparison/`, `contact-sheet.png`,
   `render-manifest.json` across every group). (`BenchmarkRun.swift:290-296,314-317`.)
4. **No partial staging dir remains** — on success the staging dir is atomically renamed to the final dir
   (`publishDirectoryExclusively`), so no `.<runID>.staging` survives; on any fault the run is poisoned and the
   **whole** staging dir is removed and the final dir never appears. Step 15 asserts neither a staging dir nor
   a partial final dir is left after the run. (`BenchmarkRun.swift:222-226,321-322`.)

---

## 5. Exact command(s), output root, run-ID policy, metadata, artifact layout — [NEW + DERIVED + OPEN]

### 5.1 Command(s) to produce the sealed run — [NEW, D1]

The sealed run is produced by invoking `MatrixDriver.run` with production seams. Step 15 adds a **runnable
seam** (D1 picks the form, recommendation = **a focused XCTest "producer" test** in the existing
`AnimiEngineMetalRenderTests` target — no new executable target, no `Package.swift` change):

```
# Recommended (D1 = producer test): runs on the M2 Pro, writes a durable sealed run, asserts §6 validation.
cd AnimiEngineNext
swift test --filter Step15SealedRunTests/testProduceSealedCandidateReferenceRun
```

- The producer wires `UUIDRunIDGenerator()` (or a pinned id per D2), `SystemWallClock()`,
  `SystemMonotonicClock()`, `DefaultRunFileSystem` (via the public `BenchmarkRun` initializer), a
  `MetalRenderSession`, `referenceStore: nil`, and the Step-14 `EvidenceRecorder.Policy(tolerances: .exact,
  diffAmplification: 4)` (matching `Step14MatrixTests.defaultPolicy`), under the durable output root (§5.2).
- **STOP** if producing a runnable seam requires an executable target / a `Package.swift` / pbxproj change
  (constraint: "No Package.swift/xcodeproj/pbxproj changes unless STOP"). The producer-test form avoids this.

### 5.2 Output root + run-ID policy — [DERIVED + OPEN, D2/D3]

- **Output root (parent dir passed to `BenchmarkRun`)** — a durable, git-ignored path **outside** any tracked
  source/forbidden path. Recommendation (D3): `AnimiEngineNext/.benchmark-runs/` (added to `.gitignore`;
  **`.gitignore` is not `Package.swift`/pbxproj, so editing it is allowed** — but confirm with the owner, D3).
  The published run directory is `<root>/<runID>/`.
- **Run-ID policy (D2)** — the production generator yields a **UUID** (§1.3). Options:
  - **(D2-a, recommended) Keep the production UUID run-ID** — honest about wall-clock provenance; the run's
    *internal artifacts* remain byte-deterministic; the *directory name* is a fresh UUID per run. Matches the
    production contract; Step 16 reviews by content, not by directory name.
  - **(D2-b) A pinned/derived run-ID** (e.g. `task003-step15` or a hash of the matrix inputs) for a stable
    directory name — makes the whole run path reproducible, but diverges from the production `UUIDRunIDGenerator`
    and risks `runDirectoryAlreadyExists` on re-run (the staging reservation is exclusive). If chosen, the
    producer must remove a prior same-id run first (an explicit, logged delete of a path it created).
  The owner pins D2. Either way, the **artifact bytes** are deterministic; only the directory *name* differs.

### 5.3 Device/config metadata — [DERIVED]

- **Engine config** — the run records `engine-config.json` (re-read + re-hashed) and the per-group
  `render-manifest.json` carries `engineConfigHash` (`ConfigurationHash.sha256Hex`). The producer passes a
  pinned `EngineConfiguration` (matching `Step14MatrixTests.minimalEngineConfig`, unless the owner pins a
  richer one — D5).
- **Device info** — `DeviceInfo(model:systemName:systemVersion:)`. For the M2 Pro sealed run, the producer
  records honest host metadata (recommendation D6: `model: "M2Pro"`, `systemName: "macOS"`, and the real OS
  version string rather than `"test"`, so the sealed artifact carries true provenance — distinct from the
  `Step14MatrixTests` placeholder).
- **Render configuration** — 1080×1920, 30/1, `intermediateProfile: .rgba16FloatLinear` (matching
  `Step14MatrixTests.config`), unless the owner pins otherwise (D5).

### 5.4 Artifact layout (the published sealed run) — [DERIVED]

```
<output-root>/<runID>/
  events.ndjson                              # streamed diagnostic events (may be empty)
  engine-config.json                         # re-read + re-hashed at close
  artifacts-manifest.json                    # supplemental aggregate (per-file size + SHA-256)
  device.json  summary.json  failures.json   # core metadata
  run-manifest.json                          # COMMIT MARKER, written LAST (carries the two aggregate hashes)
  full_image/        { candidates/<id>.png, comparison/<id>.json, contact-sheet.png, render-manifest.json }
  polaroid_shared_demo/  { … same … }
  polaroid_2/            { … same … }
  example_4blocks/       { … same … }
  6_frames_template/     { … same … }
  structural/            { candidates/<id>.png, comparison/<id>.json, contact-sheet.png, render-manifest.json }
```

- **No `references/` and no `diffs/` anywhere** (no approved refs → §3). Each group has exactly its
  `candidates/`, `comparison/`, one `contact-sheet.png`, one `render-manifest.json`.

---

## 6. Validation after run creation — [DERIVED + NEW]

The producer (and a companion validation test) assert, against the **published** run directory:

| # | Requirement | Assertion |
|---|---|---|
| V-1 | **Run sealed** | `MatrixDriver.run` returned without throwing; the final `<runID>/` dir exists; **no `.<runID>.staging` dir** remains (glob the parent for `.*.staging`). |
| V-2 | **`run-manifest.json` present and last** | `run-manifest.json` exists; its `supplementalArtifactsSHA256` equals the SHA-256 of the published `artifacts-manifest.json` (the aggregate covers all matrix artifacts, §4.3). |
| V-3 | **Expected candidate count = 64** | `result.candidateCount == 64` **unless the matrix changes by STOP** (see §6.1). `result.candidateCount == result.realRowCount + result.structuralRowCount`; `result.structuralRowCount == 9`; `result.realRowCount + result.skippedRowCount == result.enumeratedRowCount`. |
| V-4 | **Group manifests present** | for every group in `RealTemplateMatrix.catalogs + ["structural"]`, `<group>/render-manifest.json` exists and decodes to a `RenderEvidenceManifest`. |
| V-5 | **Contact sheets present** | every group has `<group>/contact-sheet.png` (a valid deterministic PNG). |
| V-6 | **Candidate PNGs present** | every manifest entry's `candidateArtifact` file exists on disk. |
| V-7 | **Comparison JSON for every candidate** | every manifest entry's `comparisonArtifact` file exists; its `verdict == "candidateOnly"`. |
| V-8 | **No references / diffs unless approved refs exist** | with no approved root: **no `references/` and no `diffs/` directories** exist under any group; every entry's `referenceArtifact`/`diffArtifact` is nil. |
| V-9 | **All `candidateOnly`** | every group manifest's candidates are all `verdict == "candidateOnly"`. |
| V-10 | **No promotion / approved-root write** | if a (read-only) reference root path is configured (D4), it is byte-identical before/after; otherwise no such path is touched. |

### 6.1 The expected candidate count (= 64) — [DERIVED + must be confirmed at implementation]

The owner pins **64** as the expected candidate count "unless matrix changes by STOP". `candidateCount =
realRowCount + structuralRowCount`, with `structuralRowCount = 9` (FIXED by `Step14MatrixTests`), so the plan
treats the real contribution as **55** (64 − 9). The real count is `Σ over the 25 (catalog,block,variant)
pairs of |frameTimes(duration, postRoll)|` **minus** rows that `compileOutcome` deterministically classifies
`.skippedInactive` (`MatrixDriver.swift:62-63`). The exact real count is a **pure function of the per-scene
`nominalDuration`/`postRollCapability`** and the skip classification — it is **read, not invented**, at
implementation: the producer asserts `candidateCount == 64` and, **if the actual count differs, that is a
STOP** (§7) — the matrix or the count expectation changed and the owner must reconcile, not Claude. (The
acceptance criterion is explicit: "expected candidate count = 64 unless matrix changes by STOP".)

> Plan-time note: `Step14MatrixTests` asserts `structuralRowCount == 9` and the row accounting identity, but
> does **not** pin a literal real-row total, so the **64** number is owner-supplied and must be verified by an
> actual run before the producer's `XCTAssertEqual(candidateCount, 64)` is committed. If the first real run
> yields a different number, Claude **STOPs and reports** the observed count + the per-scene frame-time/skip
> breakdown rather than changing 64.

---

## 7. iPhone 13 Pro role in Step 15 — [OPEN, D7]

Step 14's device subset (`IPhoneDeviceGateTests`, app-hosted) already proved a device-rendered candidate can be
encoded + recorded. For Step 15 the question is whether the **sealed run artifact** is **M2 Pro only** or also
requires a **device-captured sealed subset**.

- **Recommendation (D7-a): M2 Pro only.** The sealed candidate-reference run is produced on the M2 Pro (where
  the full matrix runs); the iPhone 13 Pro is **not** required to seal a run, because (i) Step 14 already
  device-verified candidate capture, and (ii) the macOS SwiftPM `MetalRenderSession` is the matrix executor.
  This keeps Step 15 to **zero project-file changes** (constraint).
- **(D7-b) Also a device-captured sealed subset.** If the owner requires on-device sealed evidence, it is
  produced **source-only** by extending the existing app-hosted `IPhoneDeviceGateTests` to seal a *small*
  `BenchmarkRun` (one real row + one structural fixture) into the app's writable container — **with no
  DeviceGateHost project-file change**. If a device sealed subset cannot be captured without a project-file
  change, that is a **STOP** (constraint: "if device is included, no project-file changes").

The owner pins D7. The recommendation (D7-a) is M2-Pro-only for the sealed artifact.

---

## 8. Open decisions (require an explicit owner answer before implementation)

| ID | Decision | Recommendation | Consequence |
|---|---|---|---|
| **D1** | Runnable seam form: producer **XCTest** in `AnimiEngineMetalRenderTests` vs a new executable target | **Producer XCTest** — needs no new target / no `Package.swift` change; reuses the proven test wiring. | An executable target would touch `Package.swift` ⇒ STOP per constraints. |
| **D2** | Run-ID policy: **production UUID** vs pinned/derived id | **Production UUID** (`UUIDRunIDGenerator`) — matches the shipping contract; artifacts stay byte-deterministic; directory name is per-run. | A pinned id reproduces the directory name but diverges from production and risks `runDirectoryAlreadyExists` on re-run. |
| **D3** | Durable output root location + `.gitignore` edit | **`AnimiEngineNext/.benchmark-runs/`, git-ignored** (editing `.gitignore` is allowed — it is not `Package.swift`/pbxproj). | A tracked root would commit large PNGs; a forbidden-path root is disallowed. Confirm the `.gitignore` edit is acceptable. |
| **D4** | Configure a read-only reference root for snapshotting | **No** — none exists (§1.4); pass `referenceStore: nil`. | Configuring an empty root changes nothing; a non-empty root would mean refs exist (they do not yet). |
| **D5** | Engine/render config richness for the sealed run | **Reuse the `Step14MatrixTests` minimal config + 1080×1920/30-1/rgba16FloatLinear** unless the owner pins a richer one. | A richer config changes only recorded metadata + the config hash, not the candidate bytes. |
| **D6** | `DeviceInfo` provenance for the sealed run | **Honest host metadata** (`M2Pro`/`macOS`/real OS version) rather than the test placeholder `"test"`. | The sealed artifact should carry true provenance for Step-16 review. |
| **D7** | iPhone 13 Pro: M2-Pro-only sealed run vs also a device-captured sealed subset (no project-file change) | **M2-Pro-only** (Step 14 already device-verified capture). | A device sealed subset adds device provenance but no Step-15 guarantee; must not touch project files (else STOP). |

All decisions carry a recommendation; **none** promotes a reference, writes an approved root, changes the
RenderGraph/canonical/payload contract, or starts Step 16. If the owner accepts the recommendations, D1–D7 are
taken as written, with **D2 (run-ID policy)**, **D3 (output root)**, and **D7 (device role)** explicitly
confirmed (they set the artifact's identity, location, and device scope).

---

## 9. Exact files expected to change/create — [estimate; finalized at implementation]

### 9.1 Create — tests (`AnimiEngineMetalRenderTests`)

| File | Responsibility |
|---|---|
| `Tests/AnimiEngineMetalRenderTests/Step15SealedRunTests.swift` | The producer seam (D1): wire production clock/id seams + durable output root (§5.2) + `MetalRenderSession`, invoke `MatrixDriver.run` with `referenceStore: nil`, then assert the §6 validation (V-1…V-10) against the **published** run, including `candidateCount == 64` (STOP on mismatch, §6.1). NEW. |

### 9.2 Modify — config (NON-`Package.swift`)

| File | Change |
|---|---|
| `.gitignore` | Add the durable output root (e.g. `AnimiEngineNext/.benchmark-runs/`) so sealed-run PNGs are not committed (D3). **Not** `Package.swift`/pbxproj — allowed, but owner-confirmed. |

### 9.3 Modify — docs

- `Docs/AnimiEngineNext/decision-register.md` (Step-15 entry recording D1–D7 as resolved).

### 9.4 Modify — tests (ONLY if D7-b)

| File | Change |
|---|---|
| `DeviceGateHost/.../IPhoneDeviceGateTests.swift` | **Only if the owner picks D7-b:** seal a small device subset run (one real row + one structural fixture) into the app's writable container, **source only**, no project-file change. Otherwise **unchanged**. |

### 9.5 NOT changed / forbidden

No `Package.swift`/`*.xcodeproj`/`*.pbxproj` (constraint — any need is a STOP); no `AnimiApp`/`TVECore`/
`SceneSources`/`SharedAssets`; no RenderModel/RenderGraph/canonical/payload change; no
Diagnostics/MetalRender/RenderTestSupport **production** change (Step 15 only *drives* the accepted Step-14
machinery); no reference promotion; no approved-reference write; no Step-16 behaviour. The approved reference
root (when one ever exists) is read-only.

---

## 10. STOP conditions (report immediately; do not invent a workaround)

1. Producing a runnable seam requires an **executable target / `Package.swift` / pbxproj** change — STOP
   (constraint: "No Package.swift/xcodeproj/pbxproj changes unless STOP").
2. The actual `candidateCount` from the real run **≠ 64** — STOP and report the observed count + the per-scene
   frame-time/skip breakdown (constraint: "expected candidate count = 64 unless matrix changes by STOP";
   §6.1). Do NOT silently change 64.
3. Any path would **write or update an approved reference**, snapshot into the approved root, or **self-bless**
   a candidate — STOP (constraints 2/5/6).
4. A `references/` or `diffs/` artifact would be produced **without an approved reference present** — STOP
   (constraint: "no references/diffs unless approved refs exist").
5. The **sealed** guarantees cannot be preserved — run not closed `.sealed`, `run-manifest.json` not last, the
   supplemental aggregate does not cover all matrix artifacts, or a `.<runID>.staging` dir remains — STOP (§4).
6. A matrix row cannot compile/render on the M2 Pro, or two rows collide on a candidate id
   (`DriverError.duplicateCandidateID`) — STOP.
7. The durable output root cannot be placed outside tracked/forbidden paths without a forbidden-path change —
   STOP (the root must be git-ignored and non-forbidden).
8. (D7-b only) The iPhone 13 Pro sealed subset cannot be captured **without** a DeviceGateHost project-file
   change — STOP (constraint: "if device is included, no project-file changes").
9. A required correction needs a file outside the §9 envelope — STOP.
10. Any temptation to start **Step 16** (human review / reference approval) or **Step 17** (promotion) — STOP
    (out of scope).

---

## 11. Unresolved decisions summary

Resolve **D1–D7 (§8)** before implementation. The three that materially shape the artifact and must be
explicitly confirmed: **D2** (run-ID policy — UUID vs pinned), **D3** (durable output root + `.gitignore`
edit), **D7** (iPhone 13 Pro role — M2-Pro-only vs device sealed subset). The **64** candidate-count
expectation (§6.1) is owner-supplied and is verified by an actual run; a mismatch is a STOP (#2), not a silent
edit.

---

## 12. Stop rule

This planning pass created exactly one file:
`Docs/AnimiEngineNext/claude-task-003-step-15-plan.md`. No engine source, no test, no runnable target, no
`Package.swift`, no `*.xcodeproj`/`*.pbxproj`, no `.gitignore`, no forbidden path was modified; no reference
was promoted; no approved-reference root was written; and no Step-16/Step-17 work was started.

**Claude stops here and waits for explicit owner approval** (and D1–D7 resolution) before implementing
Step 15. During implementation, Claude must **stop and report** rather than weaken scope on any §10 STOP
condition. Reference promotion/activation (Step 17), human-review staging (Step 16), and any change that writes
an approved reference must not be started.
