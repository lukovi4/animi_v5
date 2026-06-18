# Task 003 — Implementation Report

**Status:** Task 003 implementation complete through §17 step 17 (guarded reference promotion). Step 18
(this report + control-doc/ADR closure) is documentation/control/evidence only. **Step 19 / Task 004 NOT
started.**
**Engine:** `AnimiEngineNext` (a clean-room render engine isolated from `TVECore`/`TVECompilerCore`/`AnimiApp`).
**Host of record:** macOS M2 Pro (full matrix + comparison); iPhone 13 Pro (`iPhone14,2`, A15) for device-only
facts.

---

## 1. Stages / steps completed

| Step | Outcome | Register |
|---|---|---|
| 1 | Initial dirty-tree snapshot recorded. | — |
| 2 | Transactional supplemental-artifact extension + fault-injection tests (`BenchmarkRun`). | ADR-014 |
| 3 | Package targets + dependency-boundary tests (no `TVECore`/`TVECompilerCore`/`AnimiApp`). | ADR-001 |
| 4 | Render-model values + canonical encoding/hashing. | — |
| 5 | `.tve` envelope + strict schema-2 decoding. | ADR-002 |
| 6 | All five real compiled-template variant inventories enumerated & validated (5/14/25). | — |
| 7 | Compiled templates → Task-002 canonical payloads + render materials. | ADR-002/004 |
| 8 | Complete fixture pixel + media-fit resolution. | — |
| 9 | Deterministic RenderGraph compilation without Metal. | — |
| 10 | Metal color contract + basic image composition (device-verified). | — |
| 11 | Masks, mattes, authored animation sampling, graph execution (device-verified). | — |
| 12 | Cut, fade, slide, overlay execution (device-verified). | reg §17 step 12 |
| 13 | Candidate generation, comparison, diff, contact sheet, evidence recording. | reg §17 step 13 |
| 14 | Complete real-template/frame matrix + structural fixtures (one `BenchmarkRun`). | reg X1–X8 |
| 15 | Sealed candidate-reference benchmark run (M2 Pro, production seams). | reg Y1–Y3 |
| 16 | Human review → **found & fixed** a precomp/parent-opacity compiler bug; produced a corrected sealed run; review v2 APPROVED. | reg Z1–Z4 |
| 17 | Guarded reference promotion (64 refs + approval manifest); matrix rerun 64/64 exactMatch. | reg W1–W5 |

---

## 2. Major architecture decisions

- **Isolation (ADR-001):** no import/dependency on `TVECore`/`TVECompilerCore`/`AnimiApp`; clean package
  boundary; dependency-boundary tests enforce it.
- **Canonical time (ADR-003):** exact-rational `RationalSourceTime`, `TickClock` (240 000 ticks/s), checked
  fixed-point — no floating drift.
- **Template/transition/material semantics (ADR-002/004):** strict schema-2 `.tve` decode (unknown fields are
  hard errors); compiled templates convert to Task-002 canonical payloads.
- **Deterministic RenderGraph compiler:** pure, no IO/Metal/mutable lookup; parent-chain transform **and**
  opacity composition (the latter fixed in step 16); fail-closed typed errors.
- **Metal contract:** one command buffer / one wait; explicit surface flow; linear-premultiplied composition;
  final sRGB conversion last; complete-output-only (no partial publication); same-environment byte
  repeatability.
- **Diagnostics/evidence (ADR-014):** versioned config + SHA-256-over-canonical-bytes; transactional
  `BenchmarkRun` (staging → atomic publish, manifest-last, poison-on-fault); deterministic PNG/diff/contact
  sheet (stored DEFLATE, never CoreGraphics).
- **Guarded promotion (ADR-014 closure section):** references are promoted bytes from one approved run via
  `ReferencePromoter`, guarded/auditable/git-reversible; no self-blessing.

---

## 3. Known deviations from the original plan (and why each was necessary)

1. **ADR numbering — "ADR-010" vs ADR-014.** §17 step 18 says "Write ADR-010", but the on-disk ADRs are
   001–004 + 014 and **no ADR-010 exists**. The diagnostics/evidence/comparison decision (which is what the
   step-18 ADR is about) already lives in **ADR-014**, so the promotion/closure decision was added there as a
   section rather than minting a phantom ADR-010. *Necessary* to avoid a misleading duplicate ADR; this report
   records the mapping (owner decision D1).
2. **Step-14 device subset uses a real-content graph shape, not a compiled.tve decode.** The DeviceGateHost
   target links only `AnimiEngineMetalRender` (not `AnimiEngineTemplateAdapter`), so decoding a real
   `compiled.tve` on device would require a forbidden project-file change. The device subset therefore renders
   a real-content graph shape. *Necessary* — the project structure is frozen (constraint). (Register X8.)
3. **Step-15 D7-b (on-device sealed run) was a STOP, resolved M2-Pro-only.** A device-side `BenchmarkRun`
   would need `AnimiEngineDiagnostics`/`AnimiEngineRenderTestSupport` product-deps in the device pbxproj — a
   forbidden project change. The owner chose M2-Pro-only; the device gate already proves on-device candidate
   capture. *Necessary* — same linkage/forbidden-path constraint. (Register Y3.)
4. **Step-16 correctness fix mid-task.** Human review of the first sealed run found a real compiler bug
   (precomp/parent-layer opacity dropped at the precomp boundary). It was fixed (behavioral only, no
   canonical/Metal/golden change), the first run (`2E4AED19…`) was **rejected/obsolete**, and a corrected run
   (`694A5886…`) was produced and approved. *Necessary* — a real defect; promoting the buggy run would have
   blessed incorrect output. (Register Z1–Z4.)

None of these weakened scope; each is a forbidden-path/linkage constraint or a correctness correction.

---

## 4. Final approved run + reference manifest

- **Final approved sealed run:** `694A5886-4ADC-4228-ABDC-F050C030B59E` — status success, supplemental
  aggregate `6137fe02f884cbe800c131ab92070bd42ae3f550bd6d44db4cf039a96e157225`, engine-config SHA
  `ced0783a7c401dea98c3dbba6c8e34e33498161e660af03092db955d90267c4a`.
- **Obsolete/rejected run:** `2E4AED19-6835-49D5-B557-36F0F4829751` (pre-opacity-fix), aggregate
  `3bfb2be3…` — kept untouched, must never be promoted.
- **Approved references (`AnimiEngineNext/ReferenceData/`):** **64** PNG + `approval-manifest.json`.
  - approval-manifest body self-hash (`approvalManifestSHA256`):
    `2aceb71069440b8417304d61cf2f3f29eeaec1d9829d6a88f1727d65f947124b`
  - approval-manifest whole-file SHA-256:
    `0dfcb57bef5b45988637d9617cc2b97996642779ab72b8b1afcf9ab1150caa9b`
  - ReferenceData tree hash: `be021df5e5b479b4de65e1e65cf8dcea70c3d03842a9666d007899c6ed12b4f1`
  - These files are written but **NOT git-committed** (no auto-commit; the owner commits).

---

## 5. Device evidence summary (iPhone 13 Pro — summarized, NOT re-run)

From the device-verified Steps 10–12 + the Step-14 subset (`IPhoneDeviceGateTests`, app-hosted), already
captured; **not re-run for this report** (owner decision D2 — no doc/audit contradiction surfaced):
- D0 physical device, not simulator (hard-fails on simulator).
- D1 iOS `.private` staging upload path active.
- D2 execution-event order including `uploadBlit` (iOS-only); same-device byte + `rawOutputHash` repeatability.
- D3 device/GPU/OS evidence (`MTLDevice.name`, registryID, `iPhone14,2`, iOS version/build).
- D4/D5 4× MSAA r16Float coverage; combined shape + ordered masks + matte frame on device.
- D6 fade transition on device; Step-14 candidate-evidence subset (one real-content row + one structural
  fixture) encoded to deterministic PNG on device.

---

## 6. Test counts + verification (this report)

| Command | Result |
|---|---|
| `cd AnimiEngineNext && swift build` | clean, 0 warnings |
| `swift test` (full macOS suite) | **815 pass / 1 skip / 0 fail** |
| matrix exactMatch vs approved refs (temporary probe, deleted after) | **64 / 64 exactMatch, 0 non-exact** |

The 1 skip is the synthetic/optional case skipped on this host (no failure). All Task-001/002/003 tests are in
the single SwiftPM suite; no Task-001/002 behavior was weakened.

---

## 7. Acceptance-gate mapping (Task 003 §18)

| Gate | Satisfied by |
|---|---|
| G1 Isolation | `Task003DependencyBoundaryTests`/`Task003BoundaryParserTests` (no `TVECore`/`TVECompilerCore`/`AnimiApp`); forbidden-tree byte-identical to the Step-15 snapshot (`a23d7cda…`). |
| G2 Build & regression | `swift build` clean; full `swift test` 815/1 skip/0 fail; no Task-001/002 weakening. |
| G3 Adapter completeness | step 6 inventory (5/14/25) + step 7 canonical conversion + typed-error decode tests. |
| G4 RenderGraph correctness | deterministic compiler tests; complete + independently validated graph; no IO/Metal/mutable lookup. |
| G5 Metal correctness | color/alpha analytic + same-environment repeatability + complete-output-only tests (device-verified). |
| G6 Transition semantics | cut/fade/slide/overlay matrices; incoming hold-first; outgoing continuation; duration/timing unchanged. |
| G7 Evidence | all writes via `BenchmarkRun.writeSupplementalArtifact`; aggregate in run-manifest; injected fault publishes nothing; per-candidate config/device/template/material/graph/pixel identity. |
| G8 References | normal tests cannot write refs (`ReferenceStore` read-only); contact sheets/diffs reviewed; approval metadata recorded (`approval-manifest.json`); promotion only via the guarded `ReferencePromoter` from the approved run; the approved suite reruns 64/64 exactMatch. |
| G9 Structural scale | structural fixtures (transitions/overlays/masks/mattes/shapes/strokes/video-NTSC/post-roll/boundary) produce complete frames. |

---

## 8. Final audits (read-only)

| Audit | Result |
|---|---|
| Forbidden-path comparison | byte-identical to Step-15 snapshot: `a23d7cdacf6dd2b1c5a642d3468b8996d7e59146fae92c8367bf46e37ca2130e`. |
| `Package.swift` | unchanged (`da4ebf24…`). |
| pbxproj (3 tracked) | unchanged: AnimiApp `d528bfc6…`, DeviceGateHost `d57dfa5a…`, animi `ff0d2b5d…`. |
| Dependency boundary | `Task003DependencyBoundaryTests` pass (no forbidden imports/deps). |
| Approved ReferenceData | 64 PNG + `approval-manifest.json`; tree `be021df5…`. |
| Sealed run integrity | approved `694A5886…` `6137fe02…`; obsolete `2E4AED19…` `3bfb2be3…` — both untouched. |
| Task 004 | not started (no Task-004 file/dir). |

---

## 9. Known limitations

- **Synthetic-faithful** transitions/overlays/video: the five real templates author none of these (single
  scene, image media only), so those cases are covered by hand-built fixtures with `synthetic-*` provenance —
  honestly marked, never claimed as real authoring.
- **Matrix isolation shape:** each matrix candidate renders one block's content (in the canvas TL region for
  `example_4blocks` quarters) rather than a full multi-block composite — a Step-14 per-(block,variant)
  isolation property, deterministic and intended.
- **Device sealed subset deferred:** producing a *sealed `BenchmarkRun`* on the iPhone would need a frozen-
  project change; the device gate captures candidate evidence only (M2-Pro-only sealed run by owner decision).
- **References not committed:** `ReferenceData/` is written but left for the owner to `git add`/commit (no
  auto-commit; promotion is git-reversible).

---

## 10. Closure

Task 003 is implemented and verified through guarded reference promotion. Documentation, the ADR-014 promotion
/closure section, the decision register (steps 1–17 + closed status), and the control docs record the final
state. **Step 19 / Task 004 has not been started.** No render/canonical/Metal behavior was changed by Step 18;
no approved reference, sealed run, `Package.swift`, or pbxproj was modified; nothing was auto-committed.
