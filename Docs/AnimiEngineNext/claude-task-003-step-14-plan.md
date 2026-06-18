# Task 003 / Step 14 — Implementation Plan: run the complete real-template/frame matrix and structural fixtures

**Revision:** 1 — PLAN ONLY; awaiting owner approval.
**Status:** NOT IMPLEMENTED. This planning pass creates exactly one file (this plan). No engine code, no
test, no `Package.swift`, no `*.xcodeproj`/`*.pbxproj`, and no forbidden path is modified. No reference is
promoted; no Step 15 work is started.
**Scope gate:** Task 003 §17 step 14 — *"Run the complete real-template/frame matrix and structural
fixtures."*
**Predecessor:** Step 13 (candidate generation, comparison, diff, contact sheet, evidence recording) —
closed and device-verified (iPhone 13 Pro `iPhone14,2`, A15, iOS 26.5 / 23F77). macOS `swift test` 788 / 1
skip / 0 fail.
**Carried-forward invariants:** one command buffer / one wait; explicit surface flow; linear-premultiplied
composition; final conversion last; deterministic candidate IDs (no UUID/wall-clock); deterministic
PNG/diff/contact-sheet/manifest bytes; all artifact writes through `BenchmarkRun.writeSupplementalArtifact`;
manifest-last transactional commit; typed errors only; **no self-blessing, no approved-reference writes**.

Implementation must not begin until the owner approves this plan and instructs Claude Code to start.

---

## 0. Decision classification key

- **[FIXED]** — pinned by an approved contract or committed code (verified at plan time, file:line/data cited).
- **[DERIVED]** — necessarily follows from a FIXED contract; no new product decision.
- **[NEW]** — a new matrix/fixture component Step 14 adds.
- **[OPEN]** — a genuinely unresolved decision needing an explicit owner answer before implementation (§10).

---

## 1. Current-state audit (verified in code/data)

### 1.1 The five mandatory real compiled templates + exact variant inventory — [FIXED]

All five exist as binary `compiled.tve` under `AnimiApp/Resources/Scenes/<catalog>/compiled.tve`. The
authoritative inventory is the three-way-verified golden table in
`Tests/AnimiEngineTemplateAdapterTests/CompiledVariantInventoryTests.swift` (decoded via
`CompiledTemplateDecoder` + `TemplateVariantInventory`, exactly as `RealTemplateGraphTests` does):

| Catalog | Blocks | Authored variants (per block) | Variant count |
|---|---|---|---|
| `full_image` | `block_01` | no-anim, anim-1 | 2 |
| `polaroid_shared_demo` | `block_01` | no-anim, anim-1 | 2 |
| `polaroid_2` | `block_01`, `block_02` | each: no-anim, anim | 4 |
| `example_4blocks` | `block_01`(5), `block_02`(2), `block_03`(2), `block_04`(2) | block_01: no-anim,v1,v2,v3,v4; others: no-anim,vN | 11 |
| `6_frames_template` | `block_01..06` | each: no-anim | 6 |

**Totals: 5 catalogs, 14 blocks, 25 authored (block, variant) pairs** (2+2+4+11+6). Every block's
`selectedVariantID` = `editVariantID` = `"no-anim"`.

### 1.2 What real templates DO contain — [FIXED]

- **Single scene (`.single` body) only.** `CompiledTemplateConverter` emits a manifest with
  `boundaryTransitions: []` and `overlays: []`; `RealTemplateGraphTests` asserts `case .single(subplan)`.
- **Image media only** (`.image(reference:…)` bindings); **no video**.
- **Shapes / masks / mattes / strokes ARE real** (Step-11 audit: 25 fills, 18 strokes across the templates,
  all `lc==1`/`lj==1`; masks/mattes per authored layers). `RealTemplateGraphTests` already asserts every
  authored shape/mask/matte is represented in the compiled graph.
- **Frame rate 30/1**, 1080×1920 canvas, 150-frame nominal duration; project time evaluated at tick 0 in
  the existing test.

### 1.3 What real templates DO NOT contain (must be structural/synthetic-faithful) — [FIXED]

- **Transitions** (cut/fade/slide) — none authored; synthetic-faithful (Step-12 device-verified path).
- **Overlays** — none authored; synthetic-faithful (Step-12 device-verified path).
- **Video / exact-rational frame rates** (e.g. 30000/1001) — `FrameRate(numerator:denominator:)` and the
  `drawVideoFrame`/`SourceRequest.video`/`SourceTimeMapping` path exist end-to-end but are unused by real
  templates → synthetic-faithful.
- **Post-roll continuation / boundary frames** — `SceneManifestEntry` carries `nominalDuration` +
  `postRollCapability`; the `holdLast` policy exists (`AnimationRequest`). Real templates are evaluated only
  at tick 0 today; boundary/post-roll frame times must be added by the matrix (deterministic ticks).

### 1.4 Deterministic inputs available — [FIXED]

- **Media fixtures** are deterministic: `px()` builds a 32×32 BGRA8 `ResolvedPixelInput`, `bytesPerRow 128`,
  constant `0x80` fill (no clock/randomness). The matrix reuses this deterministic fixture form.
- **Frame/project times** are exact (`ProjectTime(ticks:)`, `TickClock` 240 000 ticks/s, exact-rational
  `FrameRate`). Boundary ticks are derived deterministically from each scene's `nominalDuration` /
  `postRollCapability`.

### 1.5 The Step-13 evidence recorder is the artifact path — [FIXED]

`CandidateGenerator.generate(graph:session:catalogID:blockID:variantID:projectTimeTicks:configHash:) ->
CandidateFrame` (deterministic `candidateID` = `catalog__block__variant__tN`); `EvidenceRecorder.record(
candidates:referenceStore:policy:into:engineConfiguration:deviceInfo:) -> RenderEvidenceManifest` (writes
candidate/reference-snapshot/diff PNGs + comparison JSON + contact sheet + `render-manifest.json` through
`BenchmarkRun.writeSupplementalArtifact`, manifest-last, rejecting duplicate candidate IDs);
`ReferenceStore` is READ-ONLY; `FrameComparator` yields exact/withinBounds/outOfBounds/candidateOnly.
Step 14 **drives** this API; it adds no new evidence primitive.

---

## 2. The complete real-template/frame matrix — [NEW]

A **matrix row** is a deterministic `(catalog, blockID, variantID, projectTimeTicks)` tuple that compiles to
an immutable `RenderGraph`, renders to a `CandidateFrame`, and records evidence. The matrix is enumerated by
a deterministic, pure function (no wall-clock, no set iteration order) so the row list and candidate IDs are
reproducible.

### 2.1 Real rows — every authored block/variant — [DERIVED]

For **each of the 25 (block, variant) pairs** (§1.1), the matrix selects that variant for its block (and the
block's `selectedVariantID` for the others), binds deterministic media fixtures, and evaluates at a
deterministic set of **frame times** (§2.2). The selection is the same `TemplateVariantInventory.Selection`
+ `CompiledTemplateConverter` path `RealTemplateGraphTests.convert` already uses — extended from
"selected variant only" to "every authored variant".

### 2.2 Deterministic frame/project times per row — [DERIVED + OPEN-D2]

Per (catalog, block, variant), the matrix evaluates a **fixed, deterministic frame-time set** derived from
the scene span:

1. **tick 0** — the project/frame start (the time the existing real-template test uses).
2. **last representable authored instant** — `nominalDuration − 1 frame` (the `holdLast` clamp boundary).
3. **a mid frame** — a deterministic interior tick (e.g. `nominalDuration / 2`, exact-rational).
4. **post-roll continuation tick** — a tick inside `postRollCapability` past `nominalDuration` (exercises
   the `holdLast` policy past the authored end), **only when** `postRollCapability > 0` for that scene.

The exact tick formula is **D2 (§10)** (the recommendation is the four above; the owner may pin a different
set). Every tick is an exact `ProjectTime(ticks:)` value; no wall-clock. A row whose variant is
timing-static at every chosen tick still produces a valid candidate (it just holds the same frame).

### 2.3 Real-row count — [DERIVED]

`25 (block,variant) pairs × {tick0, last, mid, postRoll?}`. With the recommended 4 times (post-roll only
where capable), the count is **bounded and deterministic** — the plan pins the exact expected count at
implementation once the per-scene `postRollCapability` values are read (an audit assertion, §8/§9). The
matrix enumeration test asserts the exact row count and that **every candidate ID is unique** (§9).

### 2.4 Cut / fade / slide / overlay coverage — [DERIVED]

- **Cut** is covered by **real rows** (every real template is a single-scene cut).
- **Fade / slide / overlay** have no real authoring (§1.3), so the matrix adds **synthetic-faithful rows**
  built from real scene content (two real single-scene graphs composited into outgoing/incoming surfaces for
  a transition; a real scene + a deterministic overlay pixel input for overlay) — the Step-12
  device-verified execution path. These rows are recorded as candidates exactly like real rows; their
  provenance marks them synthetic (e.g. `catalog = "synthetic-fade"`), so no row overstates "real
  transition" (honest provenance, R5 from Step 12 carried forward).

---

## 3. Structural fixtures (cases not present in real templates) — [NEW]

Structural fixtures are deterministic, hand-built graphs that cover the cases §1.3 lists, each recorded as a
candidate (candidateOnly unless an approved reference exists). They reuse the Step-10/11/12 builders already
proven on device. Each fixture asserts the expected **graph/metadata** structure (the row compiles to the
expected command categories) AND records a candidate PNG + comparison JSON.

| Fixture group | Coverage | Expected graph structure |
|---|---|---|
| **Transitions** | fade (p=0/mid/p=1-boundary), slide (4 directions, off-edge, p=1-boundary) | two scene surfaces + one fade/slide command into linearCanvas |
| **Overlays** | one overlay; two overlays (composition order); overlay above a transition | `overlay` command(s) after the body, before final conversion |
| **Masks / mattes / shapes / strokes** | explicit add/subtract/intersect masks; alpha/luma mattes; fill + stroke shapes (caps/joins) | `beginMask`/`endMask` groups, `matteLink`, `drawShape` |
| **Video exact-rational targets** | a `drawVideoFrame` layer at an exact-rational frame rate (e.g. 30000/1001) with a deterministic still video pixel input | `drawVideoFrame` command; `RenderConfiguration.output.frameRate` denominator ≠ 1 |
| **Post-roll continuation** | a scene evaluated past `nominalDuration` within `postRollCapability` (`holdLast`) | the layer holds its last representable authored frame |
| **Boundary frames** | tick 0, last representable instant, the exclusive end is rejected/clamped | deterministic frame-time mapping at the boundaries |

These fixtures are **synthetic-faithful**: where they use real content (e.g. a real scene's compiled graph),
provenance says so; where they are hand-built (e.g. a synthetic video still), provenance marks them
synthetic. None claims to be a real authored transition/overlay/video (none exists).

---

## 4. Output layout + expected counts — [DERIVED + NEW]

The matrix runs under a single Step-13 `BenchmarkRun`; every row records through `EvidenceRecorder.record`.
Within the published run directory (the Step-13 layout, unchanged):

```
candidates/<candidateID>.png            // one per matrix row (real + synthetic)
references/<candidateID>.png            // only where an approved reference exists (READ-ONLY snapshot)
diffs/<candidateID>.diff.png            // only where a reference is compared and not exact
comparison/<candidateID>.json           // one per matrix row
contact-sheet.png                       // one per recorder invocation (see D1: one sheet per run vs per group)
render-manifest.json                    // the Step-13 render manifest (supplemental)
run-manifest.json                       // the manifest-last commit marker (existing)
```

- **Expected counts** (asserted in tests): `candidates/` and `comparison/` each have exactly **N** files,
  where **N = (real rows) + (structural-fixture rows)** — the exact N is pinned once D2 (frame-time set) and
  the structural-fixture list (§3) are fixed; the matrix-enumeration test asserts the count and uniqueness.
- **One recorder invocation may exceed the contact-sheet's practical size** for N rows; **D1 (§10)** decides
  whether the matrix records as one big run (one contact sheet) or **groups** rows (e.g. one sub-recording
  per catalog + one for structural fixtures) — recommended: **group by catalog + a structural group**, so
  each contact sheet is bounded and the run holds multiple `render-manifest`-style groups. (Each group still
  uses the same transactional run; grouping only affects how candidates are batched into `record` calls and
  contact sheets.)

---

## 5. Reference behavior + no self-blessing — [FIXED by instruction]

- **No approved-reference promotion or writes** anywhere in Step 14. The matrix run uses the Step-13
  `ReferenceStore` strictly READ-ONLY: where an approved reference exists for a candidate ID, it is read,
  snapshotted into the run, and compared; where it does not, the candidate is recorded `candidateOnly`.
- **No self-blessing:** `outOfBounds` is recorded (it does not auto-fail the run — Step-13 D4 carried
  forward, unless the owner pins a gating mode, D3); a candidate is never copied into the approved reference
  set; `ReferenceApproval` stays an empty stub.
- Because no approved references exist yet (reference activation is a later step), **the expected verdict for
  every matrix row in the default run is `candidateOnly`** — the matrix proves the candidates render and
  record deterministically; it does not yet judge them against an approved baseline. A with-reference run is
  exercised by a structural test that supplies a synthetic reference (proving the comparison/diff path and
  that the approved root is unchanged), not by promoting anything.

---

## 6. Transactional + determinism guarantees preserved — [FIXED]

- Every artifact write goes through `BenchmarkRun.writeSupplementalArtifact`; the run's `run-manifest.json`
  remains the manifest-last commit marker over the supplemental aggregate; an injected fault poisons the run
  and publishes nothing (Step-13 behaviour, untouched).
- Matrix enumeration, candidate IDs, PNG/diff/contact-sheet/manifest bytes are pure deterministic functions
  of the inputs (templates, fixtures, frame times). Re-running the matrix on the same device yields identical
  candidate IDs and identical artifact bytes (same-device repeatability, already proven per-frame in Steps
  10–13).
- Typed errors only; no fallback, no silent substitution, no force-unwrap/`try?`/trap. Duplicate candidate
  IDs are rejected by the recorder (`RecorderError.duplicateCandidateID`).

---

## 7. Where the code lives — [FIXED]

All Step-14 production code lives in the **non-product `AnimiEngineRenderTestSupport`** target (the Step-13
home), and the driving tests in **`AnimiEngineMetalRenderTests`** (which reaches RenderTestSupport +
Diagnostics + TestSupport + MetalRender transitively, as proven in Step 13). **No `Package.swift` /
xcodeproj / pbxproj change** (constraint 7); if the matrix is found to require one, that is a **STOP** (§10).
The iPhone 13 Pro device subset extends the existing DeviceGateHost test **source only** (project structure
frozen), reusing the inlined deterministic PNG encoder from Step 13.

---

## 8. Exact files (estimate; finalized at implementation)

### 8.1 Create — non-product (`AnimiEngineRenderTestSupport`)

| File | Responsibility |
|---|---|
| `Sources/AnimiEngineRenderTestSupport/RealTemplateMatrix.swift` | Deterministic enumeration of all real (catalog, block, variant, tick) rows from the five compiled templates + the frame-time set; compiles each to a `RenderGraph`. NEW. |
| `Sources/AnimiEngineRenderTestSupport/StructuralFixtures.swift` | Deterministic hand-built graphs for transitions/overlays/masks/mattes/shapes/strokes/video-exact-rational/post-roll/boundary fixtures. NEW. |
| `Sources/AnimiEngineRenderTestSupport/MatrixDriver.swift` | Drives the matrix: build candidate set(s) via `CandidateGenerator`, record via `EvidenceRecorder` (grouped per D1), READ-ONLY reference store. NEW. |

(Each is non-product test-support; no shipping product changes.)

### 8.2 Create — tests (`AnimiEngineMetalRenderTests`)

| File | Responsibility |
|---|---|
| `Tests/AnimiEngineMetalRenderTests/Step14MatrixTests.swift` | The §9 test matrix (enumeration determinism, no duplicate IDs, every row renders + records, candidateOnly with no reference, with-reference structural case, structural-fixture graph/metadata assertions). |

### 8.3 Modify — tests

| File | Change |
|---|---|
| `DeviceGateHost/.../IPhoneDeviceGateTests.swift` | Add the required device subset (D5): record candidate PNG evidence on device for at least one real row + one structural fixture. Source only; project unchanged. |

### 8.4 Modify — docs

- `Docs/AnimiEngineNext/decision-register.md` (Step-14 entry).

### 8.5 NOT changed / forbidden

No `Package.swift`/`*.xcodeproj`/`*.pbxproj`; no `AnimiApp`/`TVECore`/`SceneSources`/`SharedAssets`; no
RenderModel/graph/canonical/payload change; no Diagnostics/MetalRender product change; no reference
promotion; no Step-15 behaviour. The approved reference root (when one exists) is read-only.

---

## 9. Tests

| # | Requirement | Assertion |
|---|---|---|
| M-1 | **Matrix enumeration determinism** — enumerating twice yields the identical ordered row list | exact equality |
| M-2 | **No duplicate candidate IDs** — every (catalog, block, variant, tick) → a unique candidate ID across the whole matrix | set size == row count; recorder accepts the set |
| M-3 | **Exact row count** — the matrix has exactly the pinned N rows (25 real (block,variant) pairs × the D2 frame-time set + the structural-fixture count) | count equals the pinned expectation; per-scene `postRollCapability` audit |
| M-4 | **Every matrix row renders** — each row compiles to a valid `RenderGraph` and executes to a `RenderedFrame` (no STOP) | non-empty frame per row |
| M-5 | **Every row records candidate PNG + comparison JSON** — `candidates/<id>.png` and `comparison/<id>.json` exist for every row; PNG is deterministic | file presence + byte-stable PNG |
| M-6 | **Missing reference ⇒ candidateOnly** — with no approved reference, every row's verdict is `candidateOnly`; no diff produced | verdict + absence of `diffs/` |
| M-7 | **With-reference structural case** — a supplied synthetic reference produces exact/withinBounds/diff; the approved root is **byte-identical** before/after | verdict + reference-root unchanged |
| M-8 | **Structural fixtures produce expected graph/metadata** — each transition/overlay/mask/matte/shape/stroke/video/post-roll/boundary fixture compiles to the expected command categories | structural over the compiled graph |
| M-9 | **Video exact-rational target** — a synthetic video fixture at 30000/1001 emits `drawVideoFrame` and records a candidate | command presence + candidate recorded |
| M-10 | **Post-roll continuation** — a fixture evaluated past `nominalDuration` within `postRollCapability` holds the last authored frame (`holdLast`) | deterministic frame equality vs the last-instant frame |
| M-11 | **Boundary frames** — tick 0 and the last representable instant render; the exclusive end clamps/rejects per contract | deterministic boundary behaviour |
| M-12 | **Transactional preservation** — an injected fault during the matrix run poisons the run; nothing published | `runPreviouslyFailed`/`ioFailure`; final dir absent |
| M-13 | **Same-device matrix repeatability** — re-running yields identical candidate IDs + identical artifact bytes | exact equality |
| M-14 | **No reference promotion / approved-root write** — a filesystem audit shows the approved reference root unchanged by any matrix run | reference root byte-identical |
| M-15 | **iPhone 13 Pro device subset (D5)** — at least one real row + one structural fixture render on device, encode a deterministic candidate PNG, and record device evidence (no comparison/promotion) | device gate green |

### 9.1 Acceptance gates

- **AG1 Real coverage:** all 25 (block,variant) pairs × the frame-time set render + record (M-3/M-4/M-5).
- **AG2 Structural coverage:** every §3 case has a fixture that compiles to the expected structure (M-8/M-9/M-10/M-11).
- **AG3 Determinism:** enumeration + candidate IDs + artifact bytes deterministic (M-1/M-2/M-13).
- **AG4 Reference policy:** candidateOnly by default; with-reference path works; **no promotion / no
  approved-root write** (M-6/M-7/M-14).
- **AG5 Transactional:** manifest-last preserved; fault poisons (M-12); all writes via supplemental.
- **AG6 Device:** required device subset records candidate PNG evidence on iPhone 13 Pro (M-15).
- **AG7 Regression + envelope:** `swift build`/`swift test` green/0 warnings; golden/canonical unchanged (no
  re-bake); no `Package.swift`/pbxproj/forbidden-path change; forbidden-path snapshot byte-identical.

---

## 10. STOP conditions & unresolved decisions

### 10.1 STOP conditions (report immediately, do not invent a workaround)

1. A real template cannot be decoded / its inventory disagrees with the §1.1 golden table — STOP.
2. A matrix row cannot be compiled to a valid `RenderGraph` or rendered to a frame on the M2 Pro — STOP.
3. Two distinct matrix rows collide to the same candidate ID — STOP (the deterministic id is insufficient).
4. The matrix requires a `Package.swift`/xcodeproj/pbxproj change to run — STOP (constraint 7).
5. Any path would write or update an approved reference, or self-bless a candidate — STOP.
6. The transactional manifest-last / write-once / atomic-publish guarantees cannot be preserved across the
   full matrix — STOP.
7. The required iPhone 13 Pro device subset cannot be captured without a DeviceGateHost project-file change —
   STOP.
8. A correction needs a file outside the §8 envelope — STOP.

### 10.2 Unresolved decisions

| ID | Decision | Recommendation | Consequence |
|---|---|---|---|
| **D1** | One recorder invocation for the whole matrix (one contact sheet) vs **grouping** (per-catalog + structural) | **Group by catalog + a structural group** — bounded contact sheets, still one transactional run. | A single sheet over ~100 candidates is unwieldy; grouping keeps each sheet readable. |
| **D2** | The deterministic frame-time set per row | **{tick 0, last representable instant, mid, post-roll-if-capable}** — pinned exact ticks from each scene's `nominalDuration`/`postRollCapability`. | Fewer times → thinner coverage; more → larger run. The owner may pin a different set. |
| **D3** | Does any `outOfBounds` (once references exist) gate the matrix run? | **No** — record-only (Step-13 D4 carried forward); gating is a later policy. | Auto-failing changes run semantics before references are activated. |
| **D4** | Synthetic-faithful transition/overlay/video provenance naming | **Mark synthetic rows with a distinct `catalogID` prefix** (e.g. `synthetic-fade`, `synthetic-video`) so no row overstates "real". | Reusing a real catalog id would misrepresent coverage. |
| **D5** | iPhone 13 Pro device subset size | **One real row + one structural fixture** (candidate PNG evidence only; no comparison/promotion). | A larger device subset is slower with no extra guarantee for Step 14. |
| **D6** | New typed errors for matrix enumeration / fixture construction | **Add focused Step-14 typed cases** where a genuinely new failure surface exists (e.g. matrix-row-compile failure); otherwise reuse Step-13/graph errors. | Reusing an ill-fitting case obscures the failure. |
| **D7** | Reference root location for the (currently empty) approved-reference set | **A read-only repository path resolved like `TemplateRepositoryRoot`**; absent today → all candidateOnly. | Must never be written; only read. |

All decisions carry a recommendation; none promotes a reference, writes an approved root, or changes the
RenderGraph/canonical contract. If the owner accepts the recommendations, D1–D7 are taken as written, with
D2 (frame-time set) and D5 (device subset) explicitly confirmed (they set the matrix size and device scope).

---

## 11. Stop rule

This planning pass created exactly one file:
`Docs/AnimiEngineNext/claude-task-003-step-14-plan.md`. No engine source, no test, no `Package.swift`, no
`*.xcodeproj`/`*.pbxproj`, no forbidden path was modified, no reference was promoted, and no Step-15 work was
started.

**Claude stops here and waits for explicit owner approval** (and D1–D7 resolution) before implementing
Step 14. During implementation, Claude must **stop and report** rather than weaken scope on any §10.1 STOP
condition. Reference promotion/activation, Step 15, and any change that writes an approved reference during
a matrix run must not be started.
