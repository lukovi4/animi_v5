# Task 003 / Step 18 — Implementation Plan: final control documentation, ADR, implementation report, acceptance audit

**Revision:** 1 — PLAN ONLY; awaiting owner approval.
**Status:** NOT IMPLEMENTED. This planning pass creates exactly one file (this plan). No documentation is
written yet, no code/canonical/Metal behavior changes, no approved reference is modified (read-only audit
only), nothing is committed, nothing is promoted or regenerated, and Step 19 / Task 004 is not started.
**Scope gate:** Task 003 §17 step 18 — *"Write ADR-010, update control documents and produce the
implementation report."* (§17 step 19 is "Stop. Do not start Task 004" — out of scope here.)
**Predecessor:** Step 17 — **APPROVED**. References promoted into `AnimiEngineNext/ReferenceData/` (64 PNG +
`approval-manifest.json`), 64/64 exactMatch on matrix rerun, full suite **815 pass / 1 skip / 0 fail**.

**Nature of Step 18:** documentation / control / evidence ONLY. It writes the closing records of Task 003 and
runs read-only audits. It changes **no** render/canonical/Metal behavior, modifies **no** approved reference
(reads only), starts **no** new architecture, and does **not** auto-commit. The single exception the owner
allowed: if an audit surfaces a **blocking inconsistency**, the plan reports it and stops for an explicit
decision rather than silently "fixing" it.

Implementation must not begin until the owner approves this plan and resolves the §6 open decisions.

---

## 0. Decision classification key
- **[FIXED]** — verified in repo/data at plan time (cited).
- **[DERIVED]** — follows from a FIXED fact.
- **[NEW]** — a document Step 18 adds.
- **[OPEN]** — needs an explicit owner answer (§6).

---

## 1. Current-state audit (verified) — [FIXED]

- **Existing control docs** (`Docs/AnimiEngineNext/`): `README.md`, `decision-register.md` (now carries §17
  steps 1–17, including the Step-15/16/17 entries Y/Z/W just added), `source-traceability.md`,
  `validation-contract.md`.
- **Existing ADRs** (`AnimiEngineNext/Docs/`): `ADR-001` package/dependency boundaries, `ADR-002`
  project/template compatibility, `ADR-003` canonical time, `ADR-004` transition/material semantics,
  `ADR-014` diagnostics/evidence/comparison. **There is NO `ADR-010`.** §17 step 18 literally says "Write
  ADR-010", but the on-disk numbering is 001–004 + 014 — a **doc-numbering inconsistency** the plan must
  resolve (D1).
- **Approved evidence (read-only facts for the report):**
  - Approved sealed run: `694A5886-4ADC-4228-ABDC-F050C030B59E`, status success, aggregate
    `6137fe02f884cbe800c131ab92070bd42ae3f550bd6d44db4cf039a96e157225`.
  - Obsolete/rejected run: `2E4AED19-6835-49D5-B557-36F0F4829751` (kept untouched, aggregate `3bfb2be3…`).
  - `AnimiEngineNext/ReferenceData/`: 64 reference PNGs + `approval-manifest.json`; whole-file SHA-256 of the
    manifest `0dfcb57bef5b45988637d9617cc2b97996642779ab72b8b1afcf9ab1150caa9b`; its internal body self-hash
    `approvalManifestSHA256 = 2aceb71069440b8417304d61cf2f3f29eeaec1d9829d6a88f1727d65f947124b`; ReferenceData
    tree hash `be021df5e5b479b4de65e1e65cf8dcea70c3d03842a9666d007899c6ed12b4f1`.
  - Forbidden-tree hash now `a23d7cdacf6dd2b1c5a642d3468b8996d7e59146fae92c8367bf46e37ca2130e` == the
    Step-15 snapshot → isolation preserved.
- **Acceptance gates** to audit against are Task-003 §18 G1–G9 + the §18 evidence/report checklist (initial &
  final forbidden snapshots, exact commands, build/test counts, requirement-to-test mapping, all benchmark
  run IDs, reference approval record, known limitations, Task-004-not-started confirmation).

---

## 2. The Step-18 documents — [NEW]

### 2.1 Final Task 003 implementation report — [NEW]
A new `Docs/AnimiEngineNext/claude-task-003-implementation-report.md` covering (§17 step 18 + §18 checklist):
- **Stages/steps completed** — steps 1–17 with one-line outcomes (decode/convert/compile/Metal/masks-mattes/
  transitions/evidence/matrix/sealed-run/opacity-fix/promotion), each pointing at its decision-register entry.
- **Major architecture decisions** — package/dependency isolation (ADR-001), canonical time (ADR-003),
  transition/material semantics (ADR-004), diagnostics/evidence (ADR-014), one-command-buffer/explicit-surface
  /linear-premultiplied Metal contract, deterministic PNG/evidence, guarded promotion.
- **Known deviations from the original plan + why** (§1 deviations, honest):
  - *Step-14 device subset* used a real-content graph shape, not a compiled.tve decode, because the
    DeviceGateHost target links only `AnimiEngineMetalRender` (a compiled.tve decode would need a forbidden
    project change). (Decision-register X8.)
  - *Step-15 D7-b* (on-device sealed run) was a STOP (#8) for the same linkage reason; owner chose M2-Pro-only.
    (Y3.)
  - *Step-16* surfaced and fixed a real precomp/parent-opacity compiler bug found during review; the first
    sealed run (`2E4AED19…`) was rejected and a corrected run (`694A5886…`) produced. (Z1–Z4.)
  - *"ADR-010"* naming vs the on-disk ADR numbering (D1).
  - Each deviation is justified as **necessary** (forbidden-path / linkage constraints, or a correctness bug),
    not a scope weakening.
- **Final approved runID + reference manifest hash** — `694A5886…`; approval manifest body self-hash
  `2aceb710…` (and whole-file SHA `0dfcb57b…`); source aggregate `6137fe02…`.
- **Device evidence summary** — the iPhone 13 Pro (`iPhone14,2`, A15) gate facts already captured in prior
  steps (execution-event order incl. `uploadBlit`, 4× MSAA, masks/mattes/transitions on device, Step-14
  candidate-evidence subset). **Summarized from existing evidence; the device gate is NOT rerun** unless the
  owner requires it (D2).
- **Test counts** — full macOS suite **815 pass / 1 skip / 0 fail**; the 1 skip named and explained.
- **All benchmark run IDs** — `2E4AED19…` (obsolete/rejected), `694A5886…` (approved).
- **Known limitations** — synthetic-faithful transitions/overlays/video (no real authoring); matrix renders
  one block per candidate in the canvas TL region (Step-14 isolation property); device sealed subset deferred.

### 2.2 ADR — promotion / evidence closure — [NEW, D1]
The §17 "ADR-010" deliverable. **D1 resolves the number/placement:**
- **D1-a (recommended):** extend the existing **`ADR-014`** (diagnostics/evidence/comparison) with an
  accepted "Reference promotion & comparison closure" section — it is the topically correct home and avoids a
  phantom ADR-010. A short note records that the plan's "ADR-010" label maps to ADR-014's promotion section.
- **D1-b:** create a literal **`ADR-010-reference-promotion.md`** to match the plan's wording verbatim.
The ADR content (either placement) states, as Accepted: the guarded-promotion policy, the no-self-blessing
rule, the device-gate policy, and the canonical-architecture summary pointers (§2.3).

### 2.3 Control-doc updates — [NEW]
- `decision-register.md` — already carries the Step-15/16/17 entries (Y/Z/W); Step 18 adds a short "Task 003
  closed" status line. No re-litigation.
- `README.md` / `validation-contract.md` / `source-traceability.md` — append: the canonical architecture
  summary, the **reference promotion policy** (only via `ReferencePromoter`, only the approved run, git-
  reversible, no auto-commit), the **device-gate policy** (M2 Pro for full matrix; iPhone 13 Pro for the
  device-only facts; project structure frozen), and the **no-self-blessing rule** (references are promoted
  bytes from an approved run, never current render output; `outOfBounds` never auto-blesses).

---

## 3. Final audits (read-only) — [NEW]

| # | Audit | Method |
|---|---|---|
| A1 | **Forbidden-path comparison** | initial snapshot (`a23d7cda…`, Step-15) vs final `git ls-files TVECore SceneSources SharedAssets AnimiApp | sha`; must be byte-identical. |
| A2 | **Package.swift / pbxproj summary** | confirm `AnimiEngineNext/Package.swift` and all three tracked `*.pbxproj` are unchanged by Task-003's render work (vs their recorded snapshots); report any baseline-dirty status honestly. |
| A3 | **Dependency-boundary verification** | run the existing `Task003DependencyBoundaryTests` / `Task003BoundaryParserTests`; no import/dep on `TVECore`/`TVECompilerCore`/`AnimiApp` (G1). |
| A4 | **Approved ReferenceData count/hash** | 64 PNG + manifest; tree hash `be021df5…`; manifest whole-file `0dfcb57b…`; body self-hash `2aceb710…` re-verified via `ReferenceApproval.load`. |
| A5 | **Sealed run + references integrity** | `694A5886…` aggregate `6137fe02…` unchanged; `2E4AED19…` aggregate `3bfb2be3…` unchanged; ReferenceData unchanged by the audit (read-only). |
| A6 | **No Step-19 / next-task work** | confirm no Task-004 file/dir exists and no Step-18 change touches runtime integration. |
| A7 | **Acceptance-gate mapping** | a G1–G9 table mapping each gate to the test(s)/evidence that satisfies it (report artifact, not new tests). |

These audits **read** the repo and the approved artifacts; they write nothing into ReferenceData or the runs.

---

## 4. Verification commands — [DERIVED]

1. `cd AnimiEngineNext && swift build` — clean, 0 warnings.
2. `swift test` — full suite (expected **815 / 1 skip / 0 fail**).
3. **Matrix exactMatch against approved refs** — the with-reference matrix rerun (the Step-17 verification:
   64/64 exactMatch). The plan re-runs it ONCE to attach a fresh figure to the report (a temporary,
   deleted-after probe, identical to Step-17's), OR cites the Step-17 result if the owner prefers no rerun
   (D3).
4. **Device gate** — summarized from existing evidence; **not rerun** unless the owner requires it (D2).

No verification step changes behavior, references, or the sealed run.

---

## 5. Expected changed files — [DERIVED]

**Docs only** (no code/canonical/Metal/reference change):
| File | Change |
|---|---|
| `Docs/AnimiEngineNext/claude-task-003-implementation-report.md` | NEW — the final report (§2.1). |
| `AnimiEngineNext/Docs/ADR-014-…md` (D1-a) **or** `AnimiEngineNext/Docs/ADR-010-reference-promotion.md` (D1-b) | the promotion/closure ADR (§2.2). |
| `Docs/AnimiEngineNext/decision-register.md` | a "Task 003 closed" status line. |
| `Docs/AnimiEngineNext/README.md`, `validation-contract.md`, `source-traceability.md` | policy/summary appends (§2.3). |

**NOT changed:** any `Sources/**` (no render/canonical/Metal), `AnimiEngineNext/ReferenceData/**` (read-only),
`.benchmark-runs/**` (read-only), `Package.swift`, `*.xcodeproj`/`*.pbxproj`, `TVECore`/`SceneSources`/
`SharedAssets`/`AnimiApp`. No auto-commit. If an audit (A1–A7) reveals a blocking inconsistency that needs a
non-doc change, that is a **STOP** — report and wait (§7).

---

## 6. Open decisions — [OPEN]

| ID | Decision | Recommendation |
|---|---|---|
| **D1** | "ADR-010" number vs on-disk ADRs (001–004, 014) | **D1-a:** add a promotion/closure section to **ADR-014** (topically correct) + a note that "ADR-010" maps to it. (D1-b: a literal ADR-010 file if the owner wants the plan's wording verbatim.) |
| **D2** | Re-run the iPhone 13 Pro device gate for the report? | **No** — summarize existing device evidence; the device facts are unchanged by docs. Re-run only if the owner wants a fresh capture. |
| **D3** | Re-run the with-reference matrix for a fresh report figure? | **Yes, once** (temporary probe, deleted after) to attach a current 64/64 exactMatch line; OR cite the Step-17 figure if the owner prefers zero reruns. |
| **D4** | Where the implementation report lives | `Docs/AnimiEngineNext/claude-task-003-implementation-report.md` (next to the step plans). |

---

## 7. STOP conditions

1. An audit (A1–A7) shows a real inconsistency requiring a **non-documentation** change (e.g. forbidden-tree
   drift, a dependency-boundary violation, a reference/run integrity mismatch) — STOP and report; do NOT
   "fix" render/canonical/reference state under a documentation step.
2. Writing the docs would require changing render/canonical/Metal behavior or modifying an approved reference
   — STOP (Step 18 is docs/control/evidence only).
3. Any temptation to start Step 19 / Task 004, auto-commit, or re-promote/regenerate references — STOP.
4. A correction needs a file outside the §5 docs envelope — STOP.

---

## 8. Stop rule

This planning pass created exactly one file:
`Docs/AnimiEngineNext/claude-task-003-step-18-plan.md`. No documentation was written, no code/canonical/Metal
changed, no approved reference modified, nothing committed, promoted, or regenerated, and Step 19 / Task 004
not started.

**Claude stops here and waits for explicit owner approval** (and D1–D4 resolution) before writing the Step-18
documentation. During implementation, Claude must **stop and report** rather than weaken scope on any §7 STOP
condition.
