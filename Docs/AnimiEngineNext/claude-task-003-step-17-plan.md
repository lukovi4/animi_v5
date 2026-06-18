# Task 003 / Step 17 — Implementation Plan: promote references through a guarded tool, then rerun the complete suite

**Revision:** 1 — PLAN ONLY; awaiting owner approval.
**Status:** NOT IMPLEMENTED. This planning pass creates exactly one file (this plan). No code, no test, no
`Package.swift`, no `*.xcodeproj`/`*.pbxproj`, no reference is written, no candidate is promoted, the sealed
run is not mutated, and `ReferenceApproval` stays an empty stub until (and only if) the owner approves this
plan.
**Scope gate:** Task 003 §17 step 17 — *"After approval, promote references through the guarded tool and
rerun the complete suite."*
**Predecessor:** Step 16 v2 — **APPROVED**. Approved sealed run:
`AnimiEngineNext/.benchmark-runs/694A5886-4ADC-4228-ABDC-F050C030B59E` (64 candidateOnly candidates, status
success, aggregate `6137fe02f884cbe800c131ab92070bd42ae3f550bd6d44db4cf039a96e157225`). The corrective
precomp/parent-opacity fix (`RenderGraphCompiler`) is in place and verified (805 tests).
**Obsolete:** run `2E4AED19…` (pre-fix) is rejected/obsolete and MUST NOT be a promotion source.

**Carried-forward invariants:** transactional staging → atomic publish (`renamex_np(RENAME_EXCL)`);
write-once exclusive descriptor-relative writes (`O_NOFOLLOW`/`O_EXCL`); manifest written last as commit
marker; per-file + aggregate SHA-256; typed errors only; **no self-blessing** (promote only the approved
sealed run's bytes); **read-only sealed run**; **git-reversible** (the approved-reference root is committed
files — a `git revert`/`git checkout` fully undoes a promotion).

Implementation must not begin until the owner approves this plan and resolves the §9 open decisions.

---

## 0. Decision classification key
- **[FIXED]** — pinned by an approved contract or committed code (verified at plan time, file:line cited).
- **[DERIVED]** — necessarily follows from a FIXED contract.
- **[NEW]** — what Step 17 adds.
- **[OPEN]** — needs an explicit owner answer before implementation (§9).

---

## 1. Source run + candidate set — [FIXED]

- **Source run (the ONLY promotion source):** `AnimiEngineNext/.benchmark-runs/694A5886-4ADC-4228-ABDC-F050C030B59E`.
- **Candidate set:** the **64** `candidateOnly` candidates, one PNG each, laid out **grouped** as
  `<group>/candidates/<candidateID>.png` across the six groups (`full_image`, `polaroid_shared_demo`,
  `polaroid_2`, `example_4blocks`, `6_frames_template`, `structural`). `candidateID` is globally unique
  (it embeds the catalog), so a flat reference store keyed by `candidateID` is unambiguous.
- **Per-candidate metadata available** (from each group's `render-manifest.json`, `CandidateEntry`):
  `candidateID`, `rawOutputHash`, `source` (`catalogID`, `blockID`, `variantID`, `projectTimeTicks`,
  `configHash`, `graphHash`), `candidateArtifact` path, `verdict == "candidateOnly"`. Run-level:
  `run-manifest.json` (`runID`, `status`, `engineConfigSHA256`, `supplementalArtifactsSHA256`),
  `artifacts-manifest.json` (per-file size + SHA-256 of every supplemental).

---

## 2. Destination approved-reference layout — [DERIVED + NEW]

The approved-reference root is the **committed** repository directory the READ-ONLY `ReferenceStore` already
reads from (`ReferenceStore.referenceURL(for:) = <root>/references/<candidateID>.png`,
`ReferenceStore.swift:28-30`). Step 17 writes that layout **once** under owner approval:

```
<approved-reference-root>/                       (committed to git; D1 fixes the exact path)
  references/<candidateID>.png                   one per promoted candidate (flat; candidateID is unique) — 64 files
  approval-manifest.json                         canonical, sorted-keys; the auditable promotion record (§5)
```

- **D1 (root location):** recommended `AnimiEngineNext/ReferenceData/` (a committed, NON-`.gitignore`d path,
  outside every forbidden path and outside `.benchmark-runs/`). It must be readable by `ReferenceStore` via a
  `TemplateRepositoryRoot`-style locator (resolved from the package root, like the template fixtures). The
  matrix rerun (§8) points `MatrixDriver.referenceStore` at this root.
- The reference PNG bytes are the **exact** candidate PNG bytes from the sealed run (byte-for-byte copy via the
  deterministic encoder's output already on disk — no re-encode), so a later comparison is byte-identical.

---

## 3. Promotion command / test entrypoint — [NEW, D2]

Promotion is performed by a **guarded promotion tool** invoked through an explicit, owner-gated entrypoint.
Two forms (D2):

- **D2-a (recommended): a guarded XCTest entrypoint** in the existing `AnimiEngineMetalRenderTests` target
  (no new target / no `Package.swift`), run ONLY with an explicit opt-in env var so it never promotes during
  an ordinary `swift test`:
  ```
  cd AnimiEngineNext
  ANIMI_STEP17_PROMOTE=1 \
  ANIMI_STEP17_SOURCE_RUNID=694A5886-4ADC-4228-ABDC-F050C030B59E \
  swift test --filter Step17PromoteReferencesTests/testPromoteApprovedSealedRun
  ```
  Without `ANIMI_STEP17_PROMOTE=1` the test runs in **dry-run** (validates + reports, writes nothing).
- **D2-b: a tiny SwiftPM executable target** (`reference-promote`) — cleaner CLI, but adds a `Package.swift`
  product → **STOP per constraints unless the owner explicitly allows the `Package.swift` edit**.

The promotion logic itself lives in `AnimiEngineRenderTestSupport` (the §14.6 home for "guarded reference
promotion"), as a new `ReferencePromoter` type the entrypoint drives.

---

## 4. Guard checks (ALL must pass before ANY write) — [NEW]

`ReferencePromoter` validates, in order, and throws a typed `PromotionError` (no write on any failure):

| # | Guard | Check |
|---|---|---|
| G1 | **Source run status success** | `run-manifest.json` `status == "success"`. |
| G2 | **Aggregate matches** | SHA-256(`artifacts-manifest.json`) == `run-manifest.json.supplementalArtifactsSHA256`. |
| G3 | **Candidate count == 64** | sum of all groups' `render-manifest.json` candidates == 64; PNG files on disk == 64. |
| G4 | **No diffs/references in source** | no `*/references/` and no `*/diffs/` directory exists in the source run (it must be a pure candidateOnly run; a source carrying references would mean it already self-blessed). |
| G5 | **Source runID == approved runID** | the run's `runID` and the directory name == `ANIMI_STEP17_SOURCE_RUNID` (== the owner-approved `694A5886…`). A mismatch is a STOP (wrong/obsolete run, e.g. `2E4AED19…`). |
| G6 | **All candidateOnly** | every `CandidateEntry.verdict == "candidateOnly"` (nothing pre-judged). |
| G7 | **Per-file integrity** | each candidate PNG's on-disk SHA-256 == its `artifacts-manifest.json` entry, AND the decoded frame's `rawOutputHash` == the manifest `rawOutputHash` (the bytes are the ones the manifest attests). |
| G8 | **No dirty/changed approved refs** | if the approved-reference root already exists, every file in it must either be absent (fresh promotion) or **byte-identical** to what would be written (idempotent); any pre-existing file that differs is a STOP unless `ANIMI_STEP17_ALLOW_OVERWRITE=1` is explicitly set (D3) — and even then, only same-`candidateID` files, never a delete of unrelated files. |
| G9 | **No overwrite without identical bytes** | a write to an existing reference path proceeds only when the new bytes equal the existing bytes (idempotent); differing bytes → STOP (G8). |

---

## 5. Reference metadata — `approval-manifest.json` — [NEW]

A canonical (sorted-keys, byte-stable) audit record written alongside the references:

```json
{
  "approvalManifestVersion": 1,
  "sourceRunID": "694A5886-4ADC-4228-ABDC-F050C030B59E",
  "sourceSupplementalArtifactsSHA256": "6137fe02…",
  "sourceEngineConfigSHA256": "ced0783a…",
  "approvedAtISO8601": "<from an injected WallClock; D4>",
  "approvedBy": "<owner id if required; D4>",
  "candidateCount": 64,
  "references": [
    {
      "candidateID": "...",
      "rawOutputHash": "...",
      "graphHash": "...",         // from CandidateSource
      "configHash": "...",        // from CandidateSource
      "catalogID": "...", "blockID": "...", "variantID": "...", "projectTimeTicks": 0,
      "referencePath": "references/<candidateID>.png",
      "referenceSHA256": "<sha256 of the promoted PNG bytes>"
    }
    // × 64, sorted by candidateID
  ],
  "approvalManifestSHA256": "<self-hash over the canonical bytes of everything above, last>"
}
```

- Metadata is taken verbatim from the source run's manifests — **no recomputation of pixels**. `referenceSHA256`
  is computed over the exact promoted bytes (== source candidate bytes).
- `approvalManifestSHA256` is the manifest's own integrity self-hash, written last (mirrors the run's
  manifest-last commit-marker discipline).
- **D4 (timestamp/user):** recommended — include `approvedAtISO8601` from an **injected** `WallClock` (so a
  test pins it deterministically) and an optional `approvedBy` only if the owner wants attribution. If omitted,
  the manifest stays fully deterministic; if included, the timestamp/user are the only non-deterministic
  fields and are isolated to this manifest (the reference PNGs stay byte-deterministic).

---

## 6. Atomic / transactional write strategy — [DERIVED]

Reuse the proven `RunFileSystem` primitives (`RunFileSystem.swift`) — no new transactional machinery:

1. Reserve a **staging** dir `<root>/.promote-<sourceRunID>.staging` via `createDirectoryExclusively` (the
   reservation; a concurrent promotion fails fast).
2. Write each reference PNG + `approval-manifest.json` into staging via `writeSupplementalFileExclusively`
   (descriptor-relative, `O_NOFOLLOW`/`O_EXCL`, write-once), **manifest last**.
3. **Atomic publish:** `publishDirectoryExclusively(from: staging, to: <root>)` (`renamex_np(RENAME_EXCL)`) —
   the approved-reference root becomes observable only on success. For an **idempotent re-promotion onto an
   existing root** (D3), the strategy is: build staging, verify every file byte-identical to the existing root
   (G8/G9), and if all identical, treat as a **no-op success** (remove staging, leave the committed root
   untouched) rather than republishing.
4. **On any failure:** the staging dir is removed; the approved root is **never** partially written; the run
   stays as-is.
5. **Git-reversibility:** because the approved root is committed files, `git revert`/`git checkout --
   <root>` fully reverses a promotion. The plan does NOT auto-commit; it writes the files and reports the exact
   list for the owner to commit (D5).

`ReferenceApproval` becomes **real only if needed** (D6): the recommended approach uses
`approval-manifest.json` + `ReferencePromoter`, leaving `ReferenceApproval` an empty stub. It is given a real
(read-only metadata) shape ONLY if the owner wants the approval record modeled as a typed value the engine
parses — in which case it gains parsing only, never a promotion path.

---

## 7. Tests — [NEW]

| # | Test | Assertion |
|---|---|---|
| P-1 | **Dry-run** (no `ANIMI_STEP17_PROMOTE`) | validates G1–G9, writes NOTHING; approved root unchanged/absent; reports the 64 planned references. |
| P-2 | **Reject wrong runID** | source/env runID ≠ approved (e.g. `2E4AED19…`) → `PromotionError.runIDMismatch`; no write. |
| P-3 | **Reject missing candidate** | a source missing one of the 64 PNGs → `PromotionError.candidateCountMismatch`/`missingCandidate`; no write. |
| P-4 | **Reject changed bytes** | a candidate PNG whose bytes ≠ its `artifacts-manifest` SHA → `PromotionError.integrityMismatch`; no write. |
| P-5 | **Idempotent same-byte promotion** | promoting twice onto a root already holding byte-identical refs → success no-op; root byte-identical before/after the second run. |
| P-6 | **Approved root unchanged on failure** | inject a staging/write fault mid-promotion → staging removed, approved root byte-identical/absent (transactional). |
| P-7 | **Post-promotion comparison == exactMatch** | after promotion, `FrameComparator.compare(candidate:reference:)` for each of the 64 returns `exactMatch` (the promoted ref equals the candidate it came from). |
| P-8 | **No self-blessing audit** | the promoter only ever reads the source run + writes the approved root; it never writes back into the sealed run, and never promotes a candidate whose verdict ≠ candidateOnly. |
| P-9 | **approval-manifest integrity** | `approvalManifestSHA256` verifies over the canonical bytes; `referenceSHA256` per entry == on-disk PNG SHA. |

All tests use a **temp approved root** (and a temp copy of the sealed run for the fault/mutation cases) so the
real committed root and the real sealed run are never touched by the test suite.

---

## 8. Full verification after promotion — [NEW]

1. `swift build` — clean, 0 warnings.
2. `swift test` — full suite green (the new Step-17 tests + the existing 805).
3. **Rerun the matrix against the approved refs:** run `MatrixDriver` with
   `referenceStore: ReferenceStore(rootURL: <approved-root>)` into a fresh `BenchmarkRun`, producing a
   **with-reference** run (now `references/` snapshots + comparisons appear). Assert **all 64 candidates
   return `exactMatch`** — OR an explicitly justified verdict (see below).
4. **Verdict expectation:** all 64 must be `exactMatch` because the references ARE the (same-device,
   deterministic) candidate bytes. Any `withinBounds`/`outOfBounds` would mean non-determinism crept in →
   **STOP and report** (it must not happen on the same M2 Pro; if a device/SDK change perturbs bytes, that is
   an explicitly justified deviation the owner must accept, not a silent pass).
5. Report: approved-root path, 64 reference files, `approval-manifest.json` hash, the with-reference run path,
   and the 64 exactMatch verdicts.

---

## 9. Open decisions — [OPEN]

| ID | Decision | Recommendation |
|---|---|---|
| **D1** | Approved-reference root path | `AnimiEngineNext/ReferenceData/` (committed, non-gitignored, non-forbidden), read by a `TemplateRepositoryRoot`-style locator. |
| **D2** | Entrypoint form | Guarded **XCTest** with `ANIMI_STEP17_PROMOTE=1` opt-in (no `Package.swift`). An executable target needs an explicit `Package.swift` allowance. |
| **D3** | Overwrite policy on a pre-existing root | Idempotent same-byte = no-op success; differing bytes = STOP unless `ANIMI_STEP17_ALLOW_OVERWRITE=1`; never delete unrelated files. |
| **D4** | Timestamp/user in approval manifest | Include `approvedAtISO8601` (injected `WallClock`) + optional `approvedBy`; isolated to the manifest, PNGs stay deterministic. |
| **D5** | Auto-commit the approved root? | **No** — write files + report exact list; the owner commits (keeps promotion git-reversible and human-gated). |
| **D6** | Make `ReferenceApproval` real? | Only if the owner wants the approval record as a typed parsed value; otherwise leave it an empty stub and use `approval-manifest.json` + `ReferencePromoter`. |
| **D7** | Flat vs grouped reference layout | **Flat** `references/<candidateID>.png` (matches the existing `ReferenceStore`; candidateID is globally unique). |

---

## 10. STOP conditions (report immediately; do not work around)

1. Source runID ≠ approved `694A5886…` (e.g. the obsolete `2E4AED19…`) — STOP (G5).
2. Any guard G1–G9 fails (status, aggregate mismatch, count ≠ 64, pre-existing diffs/refs in source, non-
   candidateOnly verdict, per-file integrity, dirty approved root, non-identical overwrite) — STOP.
3. The transactional/atomic guarantees cannot be preserved (no atomic publish, partial root possible) — STOP.
4. Promotion would require a `Package.swift`/xcodeproj/pbxproj change (e.g. an executable target, D2-b without
   allowance) — STOP.
5. The post-promotion matrix rerun yields any non-`exactMatch` verdict on the same device — STOP (non-
   determinism; do not bless).
6. Any path would write into the sealed run, or promote from anything other than the approved run — STOP (no
   self-blessing, read-only sealed run).
7. A correction needs a file outside the §11 envelope — STOP.

---

## 11. Exact changed-file list expected — [estimate; finalized at implementation]

### Create — non-product (`AnimiEngineRenderTestSupport`)
| File | Responsibility |
|---|---|
| `Sources/AnimiEngineRenderTestSupport/ReferencePromoter.swift` | The guarded promoter: guard checks (§4), transactional staging→publish (§6), `approval-manifest.json` (§5), typed `PromotionError`. NEW. |
| `Sources/AnimiEngineRenderTestSupport/ApprovalManifest.swift` | Canonical `approval-manifest.json` model + self-hash. NEW. |

### Create — tests (`AnimiEngineMetalRenderTests`)
| File | Responsibility |
|---|---|
| `Tests/AnimiEngineMetalRenderTests/Step17PromoteReferencesTests.swift` | The §7 P-1…P-9 tests + the guarded entrypoint (`testPromoteApprovedSealedRun`, env-gated). NEW. |

### Modify — non-product (only if D6 = yes)
| File | Change |
|---|---|
| `Sources/AnimiEngineRenderTestSupport/ReferenceApproval.swift` | Give it a real read-only metadata shape (parsing only, NO promotion path). Otherwise **unchanged**. |

### Create — committed data (the promotion OUTPUT, written by the approved run, then committed by the owner)
| Path | Content |
|---|---|
| `AnimiEngineNext/ReferenceData/references/<candidateID>.png` × 64 | The approved reference PNGs (D1). |
| `AnimiEngineNext/ReferenceData/approval-manifest.json` | The audit manifest (§5). |

### Modify — docs
- `Docs/AnimiEngineNext/decision-register.md` (Step-17 entry, D1–D7 resolved).

### NOT changed / forbidden
No `Package.swift`/`*.xcodeproj`/`*.pbxproj` (unless D2-b explicitly allowed); no `AnimiApp`/`TVECore`/
`SceneSources`/`SharedAssets`; no RenderModel/RenderGraph/canonical/payload change; no Metal change; the sealed
run `694A5886…` is read-only; the obsolete run `2E4AED19…` is untouched.

---

## 12. Stop rule

This planning pass created exactly one file:
`Docs/AnimiEngineNext/claude-task-003-step-17-plan.md`. No code, no test, no `Package.swift`, no
`*.xcodeproj`/`*.pbxproj`, no reference written, no candidate promoted, the sealed run not mutated, and
`ReferenceApproval` still an empty stub.

**Claude stops here and waits for explicit owner approval** (and D1–D7 resolution) before implementing
Step 17. During implementation, Claude must **stop and report** rather than weaken scope on any §10 STOP
condition. No promotion, no approved-reference write, and no `Package.swift` change occurs before approval.
