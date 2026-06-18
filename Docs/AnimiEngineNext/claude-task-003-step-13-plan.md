# Task 003 / Step 13 — Implementation Plan: candidate generation, comparison, diff, contact sheet, evidence recording

**Revision:** 1 — PLAN ONLY; awaiting owner approval.
**Status:** NOT IMPLEMENTED. This planning pass creates exactly one file (this plan). No engine code, no
test, no `Package.swift`, no `*.xcodeproj`/`*.pbxproj`, and no forbidden path is modified. No reference is
promoted; no Step 14 work is started.
**Scope gate:** Task 003 §17 step 13 — *"Implement candidate generation, comparison, diff, contact sheet
and evidence recording."*
**Predecessor:** Step 12 (cut/fade/slide/overlay) — closed and device-verified (iPhone 13 Pro `iPhone14,2`,
Apple A15, iOS 26.5 / 23F77). macOS `swift test` 776 / 1 skip / 0 fail.
**Carried-forward invariants (Task 001 evidence system + Task 003):** transactional run directory (staging →
atomic publish); supplemental artifacts written through the exclusive descriptor-relative path; **manifest
written last** as the commit marker; per-file + aggregate SHA-256; no partial final artifacts; typed errors
only; deterministic canonical JSON (sorted keys, ISO-8601 UTC, byte-stable); no Swift `Hasher` in evidence.

Implementation must not begin until the owner approves this plan and instructs Claude Code to start.

---

## 0. Decision classification key

- **[FIXED]** — pinned by an approved contract or committed code (verified at plan time, file:line cited).
- **[DERIVED]** — necessarily follows from a FIXED contract; no new product decision.
- **[NEW]** — a new component Step 13 adds (no existing equivalent).
- **[OPEN]** — a genuinely unresolved decision needing an explicit owner answer before implementation (§9).

---

## 1. Current-state audit (verified in code)

### 1.1 The transactional evidence system ALREADY EXISTS — [FIXED]

`AnimiEngineDiagnostics` (product target) provides the complete transactional run/artifact machinery Step 13
builds on, **unchanged**:

- **`BenchmarkRun`** (`BenchmarkRun.swift`): lifecycle `open → closing → sealed/failed`; created with an
  injected `IDGenerator` / `WallClock` / `MonotonicClock`; exclusively reserves a `.<runID>.staging`
  directory; `writeSupplementalArtifact(data:at:)`; `appendEvent`; `close(engineConfiguration:deviceInfo:
  status:failures:)`. On any FS failure the run is **poisoned** (staging removed, state `failed`).
- **Close order (the commit sequence)**: events → `engine-config.json` (written, **re-read, re-hashed**,
  integrity-checked) → `artifacts-manifest.json` (supplemental manifest, sorted by path, per-file SHA-256) →
  `device.json`/`summary.json`/`failures.json` → **`run-manifest.json` LAST** (carries config SHA + the
  supplemental-manifest SHA) → **atomic publish** of staging → final via `renamex_np(RENAME_EXCL)`. The final
  run directory is **never observable** until publish succeeds.
- **`SupplementalArtifact`** (`SupplementalArtifact.swift`): `SupplementalArtifactPath` (validated, relative,
  no `..`/absolute/NUL/separator, reserved-name guard); `SupplementalArtifactEntry` (path/byteSize/sha256);
  the manifest. **Write-once per path**; pre-write errors throw **before any FS mutation** (run stays open).
- **`RunFileSystem`** (`RunFileSystem.swift`): temp-file + atomic rename writes; `writeSupplementalFileExclusively`
  is descriptor-relative with `O_DIRECTORY|O_NOFOLLOW` + `O_CREAT|O_EXCL|O_NOFOLLOW` (symlink/TOCTOU-safe via
  the `AnimiEngineDiagnosticsCShim` C target); `publishDirectoryExclusively` is the single atomic publish.
  A fault-injecting variant (`FaultInjectingRunFileSystem`, in `AnimiEngineTestSupport`) drives failure tests.
- **Metadata**: `DeviceInfo` (model/systemName/systemVersion), `DiagnosticEvent` (runID/elapsed-monotonic/
  subsystem/eventType/fields, NDJSON), `EngineConfiguration` + `ConfigurationHash.sha256Hex(...)`, canonical
  JSON encoding.

**Existing guarantees Step 13 must preserve** (proven by the Diagnostics test suite — `EvidenceArtifactTests`,
`EvidenceIntegrityTests`, `RunDirectorySealingTests`, `SupplementalArtifactTests`,
`SupplementalArtifactTransactionTests`, `RunLifecycleStateTests`, `RunIDGenerationTests`, `EventRunIDTests`):
manifest-last commit; write-once per path; exclusive descriptor-relative writes; poison-on-fault; lifecycle
gating; integrity re-hash; aggregate-hash sensitivity; deterministic hashing.

### 1.2 The Metal executor produces a complete `RenderedFrame` — [FIXED]

`RenderedFrame` (`RenderedFrame.swift`): `dimensions: PixelDimensions`, `colorContract`, `bytes: Data`
(canonical **BGRA8 sRGB premultiplied**, defensive copy), `rawOutputHash` (SHA-256 over domain-tagged
dims/format/colour + pixels). Produced only on successful command completion; no partial form. This is the
**candidate-frame source** for Step 13. `MetalRenderSession.execute(_ graph:) -> RenderedFrame` is the entry.

### 1.3 What is ABSENT (Step 13 must build) — [FIXED]

Verified by an exhaustive search: there is **no** PNG encoder, image diff, contact sheet, comparison, or
reference-read code anywhere in `Sources/`. The only related artifacts are:
- `AnimiEngineRenderTestSupport.ReferenceApproval` — an **empty stub** (its fields are deliberately undefined
  until the reference-promotion stage, §11.3 — a LATER step). Step 13 must NOT define promotion.
- A comment in `SupplementalArtifact.swift` naming "candidate PNGs, diff images, contact sheets" as future
  work.

### 1.4 The home target — [FIXED]

`AnimiEngineRenderTestSupport` (a **non-product** target; depends on Core, RenderModel, TemplateAdapter,
RenderGraph, MetalRender, Diagnostics, TestSupport) is the §14.6-designated home for "repository roots,
fixtures, comparators, PNG codec, evidence recorder and guarded reference promotion." Step 13's candidate
generation + PNG + diff + contact sheet + comparison + evidence recording live here, keeping this machinery
**out of the shipping products** (Diagnostics/MetalRender stay clean). No new package target/product/dep is
added (no `Package.swift` change) — all new files go under the existing `AnimiEngineRenderTestSupport`.

---

## 2. Candidate-frame generation — [DERIVED + NEW]

A **candidate** is a frame rendered by the completed Metal executor for a specific (template, variant,
project-time) input, captured deterministically for comparison and evidence.

- **Source:** `MetalRenderSession.execute(graph) -> RenderedFrame`. The candidate generator does NOT change
  the render pipeline; it drives the existing decode → convert → evaluate → resolve → compile → execute chain
  (the same path the real-template tests already use) and captures the resulting `RenderedFrame`.
- **Determinism:** generation is a pure function of (compiled template bytes, variant selection, media
  fixtures, project time, `RenderConfiguration`). The same inputs on the same device produce a byte-identical
  `RenderedFrame` (already proven by Step-10/11/12 repeatability tests). The candidate captures `bytes`,
  `dimensions`, `colorContract`, and `rawOutputHash`.
- **A candidate set** is an ordered list of `(candidateID, RenderedFrame, sourceMetadata)` — `candidateID` is
  a stable, deterministic identifier derived from (catalogID, blockID, variantID, projectTimeTicks); never a
  UUID or wall-clock value (so the manifest is reproducible).
- **No device dependency for generation on macOS:** candidates generate on the M2 Pro (the Metal executor
  runs on macOS). The iPhone 13 Pro path is for the device evidence capture (§7.5), not required for the core
  comparison/diff logic.

`CandidateFrame` (NEW value type, non-product): `{ candidateID: String, frame: RenderedFrame,
source: CandidateSource }` where `CandidateSource` carries the deterministic provenance (catalogID, blockID,
variantID, projectTimeTicks, configHash, graphHash). All fields are deterministic.

---

## 3. Deterministic artifact layout — [DERIVED + NEW]

All Step-13 artifacts are written as **supplemental artifacts** (§1.1) under deterministic, validated paths,
so the existing manifest-last / write-once / atomic-publish guarantees apply automatically. The layout under
the run directory:

```
candidates/<candidateID>.png            // candidate PNG (BGRA8 → RGBA8 PNG, deterministic encoder)
references/<candidateID>.png            // READ-ONLY copy of the approved reference, IF present (see §5)
diffs/<candidateID>.diff.png            // deterministic diff image (only when a reference is compared)
comparison/<candidateID>.json           // per-candidate comparison result (policy, verdict, metrics)
contact-sheet.png                       // one contact sheet for the run (grid of candidate|reference|diff)
render-manifest.json                    // Step-13 render manifest (see below) — a supplemental artifact
```

- **`render-manifest.json`** (a *supplemental* artifact, distinct from the run's `run-manifest.json`): the
  ordered list of candidates with, per candidate: `candidateID`, `rawOutputHash`, dimensions, `configHash`,
  `graphHash`, the comparison verdict + which artifact files exist (candidate/reference/diff). Plus run-level
  metadata: device (`DeviceInfo`), engine config hash, the material/graph metadata, and the contact-sheet
  hash. It is byte-stable canonical JSON (sorted keys). It is written as a supplemental artifact **before**
  `close()`, so the run's own `run-manifest.json` (carrying the supplemental-manifest SHA over ALL these
  files) is still the final commit marker — Step 13 does **not** introduce a second "last" manifest; the
  Step-13 `render-manifest.json` is just one more supplemental file covered by the existing aggregate hash.
- **PNG bytes are deterministic** (§4.2): identical candidate bytes → byte-identical PNG → stable per-file
  SHA-256 in the supplemental manifest.
- **Hashes/config/device/material/graph metadata:** the run's existing `engine-config.json` + `device.json` +
  `run-manifest.json` carry config/device; Step 13's `render-manifest.json` adds the per-candidate
  `rawOutputHash`, `configHash`, `graphHash`, and material identity (catalogID/blockID/variantID). All are
  deterministic strings; none is wall-clock-derived.

---

## 4. Comparison policy — [DERIVED + NEW + OPEN]

### 4.1 Comparison verdicts — [DERIVED]

Per candidate, against a reference (when present, §5):

- **exactMatch** — byte-identical candidate vs reference (and equal `rawOutputHash`). Used where the content
  is analytically exact (opaque/integer-aligned).
- **withinBounds** — not byte-identical, but every pixel's per-channel delta and the chosen perceptual metric
  are within pinned tolerances (for partial-alpha / `pow` / AA edges that are bounded, not exact, per the
  Step-10/11/12 oracle policy). A deterministic diff image is produced.
- **outOfBounds** — a real difference beyond the tolerance; a diff image is produced; the verdict is recorded;
  **the run does not self-bless** (§4.4) — it records the failure, it does not update the reference.
- **candidateOnly** — no reference present (§5); the candidate + its hash are recorded, no verdict against a
  reference is claimed.

### 4.2 Deterministic PNG + diff — [DERIVED + OPEN-D1]

- **PNG encoder (NEW):** a self-contained, deterministic PNG encoder that converts `RenderedFrame.bytes`
  (BGRA8) to a standard 8-bit RGBA PNG. To keep evidence byte-stable across OS/SDK versions, the encoder uses
  **stored (uncompressed) DEFLATE blocks + a fixed filter (filter type 0)** and a hand-computed CRC32 — NOT
  CoreGraphics/ImageIO (which are non-deterministic across OS versions and would break byte-stable evidence).
  This is **D1 (§9)**. The PNG is valid and viewable; it is large-but-deterministic (acceptable for evidence).
- **Diff image (NEW):** a deterministic per-pixel diff. The recommended form (D2): an RGBA image where each
  pixel encodes the absolute per-channel delta `|candidate − reference|` (so equal pixels are black,
  differences are visible), plus a pinned amplification factor recorded in the comparison JSON. The diff is a
  pure function of the two inputs (no random colour, no timestamp). Produced only for `withinBounds` /
  `outOfBounds`.
- **Metrics (NEW):** per comparison, the JSON records: max per-channel delta, count of differing pixels,
  the perceptual metric value (D3), the tolerance thresholds applied, and the verdict. All integer/exact-
  rational where possible; any floating metric is recorded with a pinned format.

### 4.3 Comparison JSON — [DERIVED]

`comparison/<candidateID>.json` (canonical, sorted keys): `{ candidateID, mode (exact|bounded),
referencePresent, verdict, candidateHash, referenceHash?, maxChannelDelta, differingPixelCount,
perceptualMetric?, thresholds, diffArtifact? }`. Byte-stable; recorded as a supplemental artifact.

### 4.4 No self-blessing — [FIXED]

A comparison run **never** writes, creates, or updates an approved reference, and **never** copies a
candidate into the reference set. `outOfBounds` is recorded as a failure verdict in the comparison JSON and
surfaced (and may drive the run `status: failure` if the owner wants a gating mode — D4). Reference promotion
is an entirely separate, owner-approved, later-step action (§5, §1.3) that Step 13 does not implement.

---

## 5. Reference behavior — [FIXED by instruction]

- **Read, never write (normal run):** a normal Step-13 run **may READ** an approved reference for a candidate
  **if present**, to produce a comparison verdict. It **MUST NOT write or update** any approved reference.
  The reference set is treated as read-only input.
- **Reference location:** approved references live in a repository reference root (read via the existing
  `TemplateRepositoryRoot`-style locator, read-only). The reference for a candidate is keyed by the same
  deterministic `candidateID`. The run copies the reference PNG into `references/<candidateID>.png` **only as
  a read-only evidence snapshot inside the run directory** (a supplemental artifact), never back into the
  approved reference root.
- **Missing reference → candidate-only:** when no approved reference exists for a candidate, the run records
  the candidate + hash with verdict **candidateOnly** and produces no diff/verdict-against-reference. This is
  the "until activation" state — the candidate is captured but not yet judged against an approved baseline.
- **No promotion:** `ReferenceApproval` stays an empty stub (or gains only read-only metadata *parsing* if a
  reference root already carries approval metadata — D5); Step 13 adds **no** promotion/activation path.

---

## 6. Transactional evidence guarantees preserved — [FIXED]

- **All writes through supplemental artifacts:** every candidate PNG, reference snapshot, diff PNG, comparison
  JSON, contact sheet, and the `render-manifest.json` is written via `BenchmarkRun.writeSupplementalArtifact
  (data:at:)` — i.e. the exclusive, descriptor-relative, write-once, symlink-safe path. No direct filesystem
  writes.
- **No partial final artifacts:** all artifacts stage; the run publishes atomically; on any failure the run is
  poisoned and the final directory never appears (existing behaviour, untouched).
- **Manifest written last:** the run's `run-manifest.json` remains the final commit marker, carrying the
  aggregate SHA over the supplemental manifest (which now includes the Step-13 files). Step 13 introduces no
  competing "last" write.
- **Typed errors only:** Step 13 reuses `BenchmarkRunError` / `SupplementalArtifactError` and adds focused
  typed cases ONLY for genuinely new failure surfaces (e.g. PNG-encode failure, diff-dimension mismatch,
  comparison policy violation) — D6. No fallback, no silent substitution, no force-unwrap, no `try?`, no trap.
- **Determinism:** PNG/diff/contact-sheet/manifest bytes are pure functions of the inputs; identical inputs
  → identical bytes → identical per-file SHA-256 (so the aggregate-hash-sensitivity test still holds).

---

## 7. Test matrix

### 7.1 Structural artifact tests

| # | Requirement | Assertion |
|---|---|---|
| S-1 | A candidate set produces exactly the expected supplemental layout (candidates/, comparison/, render-manifest.json, contact-sheet.png) | structural: declared supplemental entries match the layout |
| S-2 | `render-manifest.json` is canonical (sorted keys), lists every candidate with hash/config/graph/material metadata | byte-stable; field presence |
| S-3 | The run's `run-manifest.json` aggregate SHA covers the Step-13 supplemental files (manifest-last preserved) | integrity: aggregate hash includes the new files |
| S-4 | Candidate PNG round-trips: decoding the deterministic PNG yields the original BGRA8 pixels | exact pixel equality |
| S-5 | Contact sheet exists and is a valid deterministic PNG of the expected grid dimensions | structural + byte-stable |

### 7.2 Transaction / failure tests (reuse the fault-injecting FS)

| # | Requirement | Assertion |
|---|---|---|
| T-1 | An injected FS fault during a candidate/diff/contact-sheet write poisons the run; nothing published | `runPreviouslyFailed`; final dir absent |
| T-2 | A duplicate candidate path is rejected pre-write without poisoning | `duplicatePath`; run stays open |
| T-3 | A write after `close()`/seal throws `runAlreadySealed` | typed |
| T-4 | A PNG-encode / diff-dimension failure is a typed error, run not partially published | typed; no partial |
| T-5 | Aggregate supplemental hash changes if any candidate/diff byte changes | hash sensitivity (extends the existing test) |

### 7.3 Candidate generation tests

| # | Requirement | Assertion |
|---|---|---|
| C-1 | Candidate generation is deterministic: same inputs → byte-identical `RenderedFrame` + identical `candidateID` | exact bytes + id equality |
| C-2 | `candidateID` is derived only from deterministic provenance (catalog/block/variant/projectTime), never UUID/wall-clock | structural |
| C-3 | A candidate set over the five real templates (cut bodies) generates a frame per selected variant | count + non-empty bytes |

### 7.4 Comparison / diff tests

| # | Requirement | Assertion |
|---|---|---|
| K-1 | exactMatch when candidate bytes == reference bytes (and hashes equal) | verdict exactMatch; no diff produced |
| K-2 | withinBounds when within tolerance; a deterministic diff image is produced | verdict + diff exists; diff is a pure function of inputs |
| K-3 | outOfBounds when beyond tolerance; verdict recorded; **no reference write** | verdict outOfBounds; reference root byte-identical before/after |
| K-4 | Diff image is deterministic (two identical comparisons → identical diff bytes) | exact bytes |
| K-5 | A named known-incorrect candidate lies OUTSIDE the bound (no blessing of GPU output into the oracle) | bounded test discipline |

### 7.5 No-reference vs with-reference modes

| # | Requirement | Assertion |
|---|---|---|
| R-1 | No reference present → verdict candidateOnly; candidate + hash recorded; no diff/verdict-against-reference | structural |
| R-2 | Reference present → it is READ and snapshotted into `references/`; the approved reference root is **never written** | reference root byte-identical before/after the run |
| R-3 | A normal run does not create/update any approved reference under any path | filesystem audit: reference root unchanged |

### 7.6 iPhone 13 Pro evidence capture (if required) — [conditional]

If the owner requires on-device evidence: extend the existing DeviceGateHost test (source only) to render one
candidate on the iPhone 13 Pro, encode its PNG deterministically, and attach the candidate + hash as device
evidence (no comparison/promotion on device). The core comparison/diff/contact-sheet logic is verified on the
M2 Pro; the device capture only proves a device-rendered candidate can be recorded. **D7 (§9)** decides
whether device evidence is in scope for Step 13 or deferred to the reference-activation step.

### 7.7 Determinism / audit

`swift build` green / 0 warnings; full `swift test` green; production forbidden-token audit clean on changed
files; the golden/canonical suites unchanged (Step 13 adds artifacts, it does not change RenderModel/graph
canonical bytes); forbidden-path snapshot byte-identical.

---

## 8. Exact files (estimate; finalized at implementation)

### 8.1 Create — non-product (`AnimiEngineRenderTestSupport`)

| File | Responsibility |
|---|---|
| `Sources/AnimiEngineRenderTestSupport/DeterministicPNGEncoder.swift` | BGRA8 → deterministic 8-bit RGBA PNG (stored DEFLATE, fixed filter, hand CRC32). NEW. |
| `Sources/AnimiEngineRenderTestSupport/CandidateFrame.swift` | `CandidateFrame` + `CandidateSource` + deterministic `candidateID` derivation. NEW. |
| `Sources/AnimiEngineRenderTestSupport/CandidateGenerator.swift` | Drives decode→…→execute to produce a candidate set from real templates. NEW. |
| `Sources/AnimiEngineRenderTestSupport/FrameComparator.swift` | exact/bounded comparison policy + verdict + metrics. NEW. |
| `Sources/AnimiEngineRenderTestSupport/DiffImage.swift` | Deterministic per-pixel diff image generation. NEW. |
| `Sources/AnimiEngineRenderTestSupport/ContactSheet.swift` | Deterministic contact-sheet PNG (grid of candidate|reference|diff). NEW. |
| `Sources/AnimiEngineRenderTestSupport/ReferenceStore.swift` | READ-ONLY approved-reference lookup by candidateID (no write/promotion). NEW. |
| `Sources/AnimiEngineRenderTestSupport/EvidenceRecorder.swift` | Orchestrates: generate → compare → write all artifacts as supplementals → render-manifest → close. NEW. |
| `Sources/AnimiEngineRenderTestSupport/RenderEvidenceManifest.swift` | Canonical Step-13 `render-manifest.json` model. NEW. |

### 8.2 Modify — non-product

| File | Change |
|---|---|
| `Sources/AnimiEngineRenderTestSupport/ReferenceApproval.swift` | At most: read-only parsing of existing approval metadata IF a reference root carries it (D5). NO promotion. Likely **unchanged**. |

### 8.3 Create — tests (`AnimiEngineRenderTestSupportTests`, new test target — D8) OR an existing test target

| File | Responsibility |
|---|---|
| PNG encoder tests | §7.1 S-4 round-trip + byte-stability. |
| Candidate generation tests | §7.3. |
| Comparison/diff tests | §7.4. |
| Reference-mode tests | §7.5. |
| Evidence transaction tests | §7.2 (reuse `FaultInjectingRunFileSystem`). |

If a **new test target** is required, that touches `Package.swift` — see **D8 (§9)** (the only thing that
could force a `Package.swift` change; if disallowed, tests go in an existing target). No production target/
product/dependency change is needed (all production code lands in the existing `AnimiEngineRenderTestSupport`).

### 8.4 Modify — docs

- `Docs/AnimiEngineNext/decision-register.md` (Step-13 entry).
- Do not modify this plan during implementation.

### 8.5 NOT changed / forbidden

No change to `AnimiEngineDiagnostics`/`AnimiEngineMetalRender`/`AnimiEngineRenderModel`/`AnimiEngineRenderGraph`
production code; no `RenderGraph`/canonical/payload change; no reference promotion; no `Package.swift` target/
product/dependency change for production; no `*.xcodeproj`/`*.pbxproj`/`AnimiApp`/`TVECore`/`SceneSources`/
`SharedAssets` change; no Step-14 behaviour. The approved reference root (wherever it lives) is read-only.

---

## 9. STOP conditions & unresolved decisions

### 9.1 STOP conditions (report immediately, do not invent a workaround)

1. A deterministic, dependency-free PNG that is byte-stable across OS/SDK cannot be produced without
   CoreGraphics/ImageIO (which are non-deterministic) — STOP (the evidence byte-stability premise fails).
2. Candidate generation cannot be made byte-deterministic on the M2 Pro for a given input — STOP.
3. The transactional evidence guarantees (manifest-last, write-once, atomic publish, poison-on-fault) cannot
   be preserved while adding the Step-13 artifacts — STOP.
4. Recording the Step-13 artifacts requires a `Package.swift` production target/product/dependency change —
   STOP (it must fit the existing `AnimiEngineRenderTestSupport`).
5. Any path would write or update an approved reference during a normal run — STOP (no self-blessing).
6. A required correction needs a file outside the §8 envelope — STOP.
7. The iPhone 13 Pro device evidence (if in scope per D7) cannot be captured without a DeviceGateHost
   project-file change — STOP.

### 9.2 Unresolved decisions (require an explicit owner answer before implementation)

| ID | Decision | Recommendation | Consequence |
|---|---|---|---|
| **D1** | PNG encoder strategy | **Self-contained deterministic encoder** (stored DEFLATE + fixed filter + hand CRC32); NOT CoreGraphics/ImageIO. | CoreGraphics output is non-deterministic across OS → breaks byte-stable evidence. |
| **D2** | Diff image form | **Absolute per-channel delta image** (black = equal) with a pinned amplification recorded in JSON. | A different visualization is fine but must stay a pure deterministic function. |
| **D3** | Perceptual metric (for bounded comparisons) | **A simple, deterministic, integer/fixed-point metric** (e.g. max per-channel delta + differing-pixel count); avoid a floating perceptual model unless the owner needs SSIM-like behaviour. | A floating perceptual metric adds non-determinism risk + a pinned-format burden. |
| **D4** | Does `outOfBounds` set the run `status: failure` (gating) or just record the verdict (reporting)? | **Record the verdict; do NOT auto-fail the run** in Step 13 (gating is a policy the owner sets). | Auto-failing changes run semantics; recommend reporting-only until the owner asks for a gate. |
| **D5** | `ReferenceApproval` | **Leave it an empty stub**; at most add read-only parsing if an approval file already exists in the reference root. **No promotion.** | Defining promotion now prejudges the reference-activation step (§11.3). |
| **D6** | New typed error cases (PNG-encode, diff-dimension-mismatch, comparison-policy) | **Add focused cases** in a Step-13 error type (or reuse where a surface genuinely matches). | Reusing an ill-fitting case would obscure the failure surface. |
| **D7** | iPhone 13 Pro device evidence in Step 13? | **Defer device evidence capture** to the reference-activation step (the comparison/diff logic is device-independent and proven on M2 Pro); OR capture one device candidate if the owner wants it now. | If deferred, Step 13 verification is M2-Pro-only (no device gate). |
| **D8** | A new `AnimiEngineRenderTestSupportTests` test target (touches `Package.swift`) vs putting Step-13 tests in an existing test target | **Owner decision** — if `Package.swift` must stay frozen, tests go in an existing target; otherwise a dedicated test target is cleaner. | A new test target is the only thing that could require a `Package.swift` edit (STOP #4 otherwise). |

All decisions carry a recommendation; none changes the RenderGraph/canonical contract or promotes a reference.
If the owner accepts the recommendations, D1–D8 are taken as written at implementation time, with D7/D8
explicitly confirmed (they affect device scope and `Package.swift`).

---

## 10. Stop rule

This planning pass created exactly one file:
`Docs/AnimiEngineNext/claude-task-003-step-13-plan.md`. No engine source, no test, no `Package.swift`, no
`*.xcodeproj`/`*.pbxproj`, no forbidden path was modified, no reference was promoted, and no Step-14 work was
started.

**Claude stops here and waits for explicit owner approval** (and D1–D8 resolution) before implementing
Step 13. During implementation, Claude must **stop and report** rather than weaken scope on any §9.1 STOP
condition. Reference promotion/activation (§11.3), Step 14, and any change that writes an approved reference
during a normal run must not be started.
