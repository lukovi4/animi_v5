# CP4 — Multi-block geometry contract refactor plan — REVISION 4 (CANONICAL CLEANUP — IMPLEMENTED)

**Status: IMPLEMENTED (owner-approved corrective pass, 2026-06-18/19).** The Codex audit was correct:
the Rev-3 `RenderMediaGeometry.animSizeWidth/animSizeHeight` duplicated the already-canonical
`RenderMaterialProgram.meta.width/height` (both converted from the SAME `animIR.meta.size` via the same
`FixedPointConversion.canvasScalar`), giving two sources of truth for one coordinate-space fact.

**Resolution — the preferred (single-source) path was implemented:**

- **Anim size is represented by `RenderProgramMeta.width/height` — NOT duplicated in `RenderMediaGeometry`.**
  The duplicate `mediaGeometry.animSizeWidth/animSizeHeight` fields and their canonical encoding entries
  were **removed**.
- `CompiledTemplateConverter` no longer populates anim size into `mediaGeometry`; `meta.width/height`
  already carries it (`CompiledAnimationProgramConverter.convertMeta` ← `animIR.meta.{width,height}`).
- `RenderGraphCompiler.compileSceneLayer` derives `blockToCanvas` from `program.meta.width/height`:
  - `program.meta.{width,height} == canvasSize` → `blockToCanvas = .identity`;
  - else → `animToInputContain(animSize: program.meta.{width,height}, blockRectCanvas)`.
  TVECore block-transform semantics are unchanged; only the *source field* of `animSize` changed.
- `mediaGeometry.contentSize` stays the binding fit baseline — still DISTINCT from anim size (13/14 real
  blocks differ). The distinction is preserved; it is simply read from `program.meta` now.
- The group-opacity fix (group transform opacity = unit 0…1; layer/fill/mask = percent 0…100) and the
  parenting-opacity fix (parent chain → transform only; precomp container opacity via `parentOpacity`)
  are **unchanged**.

**Canonical hash / ReferenceData:** removing the duplicate encoding keys changes the material hash
(golden hash re-pinned to `78599fefe12714fc419a15ea0b418c8b0ad2fb356295b101caec65dc58155822`), but it
does **not** change rendered pixels. `PostPromotionMatrixRegressionTests` remains 64/64 exactMatch
against the already promoted CP4 ReferenceData (`58E9FD0A…`). No ReferenceData re-promotion is required
by this corrective pass, and no ReferenceData was touched by it.

The historical Rev-3 "NEW canonical field required" reasoning below is **superseded**: anim size did NOT
need a new `mediaGeometry` field — it was already canonical in `RenderProgramMeta.width/height`.

---

# CP4 — Multi-block geometry contract refactor plan — REVISION 3 (IMPLEMENTED)

**Status:** Owner-approved schema/geometry fix implemented, device-smoked on iPhone 13 Pro, and
ReferenceData re-promoted from run `58E9FD0A-F293-43CF-83F9-2D01F132CF70`. No
templates/SceneSources/SharedAssets/compiled.tve/export changes.

## REV3 — Implemented outcome

> **SUPERSEDED by REV4 (canonical cleanup).** The `RenderMediaGeometry.animSize*` field described below
> was a duplicate of `RenderProgramMeta.width/height` and has been REMOVED. Anim size is canonically
> represented by `RenderProgramMeta.width/height`. Read the REV4 header for the current contract.

- ~~`RenderMediaGeometry` now carries explicit `animSizeWidth/animSizeHeight` from AnimIR `meta.size`.~~
  *(REMOVED in Rev-4.)* Anim size is carried by `RenderProgramMeta.width/height` (same `animIR.meta.size`),
  intentionally distinct from binding-baseline `contentSize`.
- `RenderGraphCompiler` now mirrors TVECore block geometry: full-canvas animation size yields
  identity `blockToCanvas`; non-canvas animation size uses `animToInputContain(animSize, blockRect)`.
- Shape group opacity is converted as a unit value (0-1), while layer/fill/mask opacity remains percent
  where authored that way.
- Layer parenting propagates transform only, not opacity, matching AE/Lottie/TVECore. Precomp container
  opacity still propagates through `parentOpacity`.
- The CP4 multi-block engine tests now assert real `example_4blocks` and `6_frames_template`
  visibility, the single-source anim-size contract (`RenderProgramMeta.width/height`), and the block_02
  matte source/consumer surface regression.
- Post-fix ReferenceData was re-promoted as a coherent 64-PNG set; `PostPromotionMatrixRegressionTests`
  returned 64/64 exactMatch after promotion.

---

## REV2 — Verification findings (read-only, measured)

---

## REV2 — Verification findings (read-only, measured)

### A. STOP closed: `contentSize` is NOT `animIR.meta.size` → schema-free fix via `contentSize` is IMPOSSIBLE
Measured (`MultiBlockCompositeTests.testContentSizeEqualsAnimMetaSize`), selected variant per block:

| template / block | mediaGeometry.contentSize | TVECore animIR.meta.size | match |
|---|---|---|---|
| full_image / block_01 | 1080×1920 | 1080×1920 | ✅ |
| polaroid_shared_demo / block_01 | 680×960 | 1080×1920 | ❌ |
| polaroid_2 / block_01 | 680×900 | 1080×1920 | ❌ |
| polaroid_2 / block_02 | 680×900 | 1080×1920 | ❌ |
| example_4blocks / block_01 | 680×960 | 1080×1920 | ❌ |
| example_4blocks / block_02 | 540×960 | 1080×1920 | ❌ |
| example_4blocks / block_03 | 540×960 | 1080×1920 | ❌ |
| example_4blocks / block_04 | 540×960 | 1080×1920 | ❌ |
| 6_frames_template / block_01..06 | 540×640 | 1080×1920 | ❌ (all 6) |
| blank_starter | (no media binding — skipped) | — | — |

**13 mismatches / 14 blocks.** `mediaGeometry.contentSize` = the binding **baseline content rect** (block-specific); `animIR.meta.size` = the **whole authored animation** = **always the full canvas (1080×1920)**. They are different quantities. **A schema-free fix keyed on `contentSize` is impossible.**

### B. Corrected oracle understanding (this changes the fix direction)
Because `animIR.meta.size == canvasSize (1080×1920)` for **every** block, TVECore's `SceneTransforms.blockTransform` returns **`.identity`** (`SceneTransforms.swift:33`: identity when anim == canvas). So:
- **TVECore does NOT scale these blocks** — `blockTransform` is identity for all of them.
- The authored AnimIR layer positions are therefore **canvas-absolute** (the anim spans the full canvas; each block's content is authored at its canvas location).
- TVECore renders by applying those canvas-absolute positions directly (identity block transform), per block, with its clip rect.

**Therefore the new renderer's bug is NOT "missing anim→block contain-scale"** (the §2/§4 animToInputContain theory below is **superseded** — it only applies when anim ≠ canvas, which never happens for these templates). The real bug: the new renderer's `blockToCanvas = placementMatrix(Placement(frame: block.rect, scale: 1))` adds a **spurious block-origin translate** on top of authored positions that are **already canvas-absolute** → the block origin is applied **twice** (the doubling originally measured: block_02 world.tx=1080 = 2×540). The earlier "origin-strip" experiment was directionally right but was applied too broadly (it disturbed matte-source/mask coordinate relationships).

### C. Implication for the fix (CORRECTED in Rev-4)
The canonical fix is: when the block's anim is full-canvas (`animIR.meta.size == canvasSize`), `blockToCanvas` must be **identity** (TVECore behaviour), NOT `T(block.rect.origin)`. The block's clip/position then comes from the authored canvas-absolute positions + the block clip rect. This requires the compiler to know `animIR.meta.size` (the anim size).

> **CORRECTION (Rev-4):** the claim below that anim size was "NOT in the render model" and needed a "NEW canonical field" was **WRONG**. Anim size was already canonical in `RenderProgramMeta.width/height` (converted from `animIR.meta.size`). Rev-3 mistakenly added a SECOND copy (`mediaGeometry.animSize*`); Rev-4 removed that duplicate and reads anim size from `program.meta.width/height`. **No new field was needed; this is NOT a schema-expansion — it is a one-line interpretation change in the compiler.** (Removing the Rev-3 duplicate keys does change the material hash, but that is a cleanup, not a new field.)

~~The converter/compiler to know `animIR.meta.size` … → NEW canonical field required~~ — *superseded; see correction above.*

---

## REV2 — Corrected polaroid_2 / regression policy
- `full_image` (anim == canvas, contentSize == animSize == 1080×1920): block transform identity in both old and new → **expected UNCHANGED** by the fix. ✅
- `polaroid_2` (anim = full canvas, but it's a SINGLE-scene 2-block layout with non-trivial authored positions): under the corrected model, `polaroid_2`'s blocks are also affected by the spurious block-origin translate (block rects are full-canvas `(0,0,1080×1920)` per the ORACLE table, so `placementMatrix` origin = 0 → **no doubling for polaroid_2 specifically**, which is why it renders acceptably today). **But its output must still be validated against the TVECore oracle, NOT assumed equal to the old ReferenceData.** Device/regression gate wording (corrected): *polaroid_2 must match TVECore, not old ReferenceData.*

## REV2 — Test policy (clarified)
- Failing-before tests are allowed DURING implementation (e.g. `MultiBlockCompositeTests` red until fixed).
- **Final committed state must have NO failing normal tests.** ~~`PostPromotionMatrixRegressionTests`
  will fail after a correct fix because references encode the old bug → re-promotion STOP gate.~~
  **Superseded by Rev-4:** the current corrective cleanup changes canonical material hash only; rendered
  pixels remain byte-identical to the already promoted CP4 ReferenceData, so `PostPromotionMatrixRegressionTests`
  stays 64/64 exactMatch and no new re-promotion is required.
- **ReferenceData is not touched** in this corrective cleanup.

## REV2 — Implementation gate (decision)
- Schema-free proof **FAILED** (§A) → **STOP.** Do NOT implement via `mediaGeometry.contentSize`.
- ~~Implementation requires a canonical/schema change (add anim size to the material/geometry payload).~~
  **Superseded by Rev-4:** anim size already existed in `RenderProgramMeta.width/height`; adding a
  duplicate `mediaGeometry.animSize*` field was unnecessary and has been removed.

---

**Goal (unchanged):** mirror the TVECore oracle so multi-block templates render correctly without regressing single-block. **Below (§1–§7) is the ORIGINAL Rev-1 plan; §2/§4's `animToInputContain`-via-existing-fields path is SUPERSEDED by REV2 §B/§C — the fix needs the anim size (schema change), and for these templates reduces to "full-canvas anim ⇒ identity block transform".**

---

## 1. Current (broken) contract

### 1.1 Where the block placement is built
- `AnimiEngineTemplateAdapter/CompiledTemplateConverter.swift` → `placement(forRect:blockID:)`:
  ```swift
  return try Placement(frame: block.rect, scale: .one, rotation: .zero)
  ```
  → `SceneLayer.placement.frame == block.rect` (canvas rect), **scale = 1.0**. It does **not** scale the block's animation into the block rect.

### 1.2 How MediaFitResolver computes source → contentRect
- `AnimiEngineRenderGraph/MediaFitResolver.swift` → `resolve(...)`:
  - Fits source **pixels** into `contentRect` (the binding baseline, 1px→1pt) using fit mode (cover/contain/fill), **centres** within `contentRect`, then composes the user transform about the contentRect centre.
  - Returns `transform: source-pixel → binding-baseline LOCAL space` (its doc-comment explicitly: "does NOT include the block→canvas placement").

### 1.3 How RenderGraphCompiler composites
- `RenderGraphCompiler.swift` `compileSceneLayer`:
  - `blockToCanvas = placementMatrix(layer.placement)` — with `frame=block.rect, scale=1` this is essentially `T(block.rect.origin)` (a translate; the about-centre scale collapses at scale=1).
  - `expandComposition(root, parentWorld: blockToCanvas, …)`.
- `worldWithinComp(layer, parentWorld:)` = `parentWorld · local(root)·…·local(layer)`, where each `local = T(pos)·R·S·T(-anchor)` and `pos` is the **authored AnimIR position**.
- Binding media draw (`emitContent`, `.image` binding): `finalTransform = world · mediaPlacement.transform` (the MediaFitResolver output).

### 1.4 Why this breaks
Measured via `MultiBlockCompositeTests.testBlockTransformContractDiagnostic` (oracle data):

| Template / block | contentSize | blockRect | placementFrame |
|---|---|---|---|
| full_image/block_01 | 1080×1920 | (0,0,1080×1920) | (0,0,1080×1920) |
| polaroid_2/block_01 | 680×900 | (0,0,1080×1920) | (0,0,1080×1920) |
| example_4blocks/block_01 | **680×960** | (0,0,**540×960**) | (0,0,540×960) |
| example_4blocks/block_02 | 540×960 | (540,0,540×960) | (540,0,540×960) |
| 6_frames/block_0N | 540×640 | (…,540×640) | (…,540×640) |

- The authored layer `position` is **animation-LOCAL** (lives in `contentSize` space), but `blockToCanvas` only **translates** to the block origin — it never **scales** `contentSize`-space into `blockRect`. So:
  - When `contentSize ≠ blockRect` (example_4blocks block_01: 680 vs 540; polaroid_2: 680×900 vs 1080×1920), the content is mis-scaled and overflows/mis-positions.
  - Earlier measurements showed the binding draw landing at ~2× the block origin and matte sources missing their consumers → block_02 empty, block_03 matte misaligned, off-origin blocks off-canvas.
  - **6_frames worked by coincidence** only because `contentSize == blockRect` (scale would be 1).
- Two earlier point-fixes (origin-strip in compiler; replacing `blockToCanvas` with `animToInputContain` alone) each broke other pieces, proving the **three components are one coupled contract**.

---

## 2. Oracle contract (TVECore — the working renderer)

- `TVECore/Sources/TVECore/ScenePlayer/SceneTransforms.swift:26-41` `blockTransform(animSize, blockRect, canvasSize)`:
  - If `animSize == canvasSize` → `.identity`.
  - Else → `GeometryMapping.animToInputContain(animSize, blockRect)`.
- `TVECore/Sources/TVECore/Math/GeometryMapping.swift:70-100` `animToInputContain(animSize, inputRect)`:
  - `scale = min(inputRect.w/animW, inputRect.h/animH)` (uniform, contain).
  - `tx = inputRect.x + (inputRect.w − animW·scale)/2`, `ty = inputRect.y + (inputRect.h − animH·scale)/2`.
  - Matrix `(a=scale, d=scale, tx, ty)` — scale about anim origin (0,0), then centre+translate into the block rect.
- `TVECore/Sources/TVECore/AnimIR/AnimIR.swift:93-111` `computeLocalMatrix`: `T(position)·R(-rotation)·S(scale)·T(-anchor)`; **position is animation-local**.
- `TVECore/Sources/TVECore/ScenePlayer/SceneRenderPlan.swift:94-168`: per block — push clip, **push `blockTransform` once**, render layers/mattes, pop. The block transform is applied **once** on the stack; layer positions are anim-local.
- Matte source: `AnimIR.swift:412-457` / `:955-1008` — matte source rendered with its **own opacity** (`resolved.worldOpacity`); its alpha shape (modulated by that opacity) is the matte. (So matte-source opacity IS applied — confirmed; "force opaque" would be wrong.)

### Coordinate spaces (canonical)
1. **source pixels** → (MediaFitResolver) →
2. **binding/content local** (1px→1pt, fit + user transform within content baseline) → 
3. **animation local** (the comp's `animSize` space, where authored layer positions live) →
4. **block rect canvas** (via `animToInputContain(animSize, blockRect)`) →
5. **final canvas**.

The new renderer currently **collapses 3→4** into a plain translate (missing the anim→block contain-scale).

---

## 3. Proposed canonical contract for AnimiEngineNext

- **Owner of anim→block scale:** the **block transform** (`blockToCanvas`), which must become `animToInputContain(animSize, blockRect)`. `animSize` = the block's animation size = `mediaGeometry.contentSizeWidth/Height` (already present — see §4; needs verification that `contentSize == TVECore animIR.meta.size`).
- **`SceneLayer.placement`:** should represent the **block rect + the contain mapping**, OR be superseded by computing `blockToCanvas` from `(contentSize, blockRect)` directly in the compiler. (Decision in §4.)
- **`RenderMaterialProgram.mediaGeometry.contentRect`:** stays the **binding baseline** (content-local space) for `MediaFitResolver` — its meaning is unchanged. (Open: confirm `contentSize` used for the anim-scale equals the AnimIR meta size, not just the binding baseline.)
- **`blockRectCanvas`:** stays the block's canvas rect (the contain target + clip).
- **MediaFitResolver:** **unchanged** — keeps fitting source → contentRect (content-local). Its output stays content-local; the anim→block scale is applied by `blockToCanvas` upstream.
- **RenderGraphCompiler:** `blockToCanvas = animToInputContain(contentSize, blockRect)`; authored layer positions kept anim-local (no origin-strip hacks); `world = blockToCanvas · authoredLocalChain`; binding draw = `world · mediaPlacement.transform`.
- **masks/mattes/precomp/parent:** all derive from `world` (which now carries the correct anim→block scale), so they align automatically. Matte-source opacity behaviour unchanged (TVECore applies it).

---

## 4. Implementation plan

**Exact files / functions:**
1. `AnimiEngineNext/Sources/AnimiEngineRenderGraph/RenderGraphCompiler.swift`
   - Add `animToInputContain(animWidth:animHeight:blockRect:) -> FixedAffineTransform2D` (fixed-point; formula from §2; degenerate-size fallback = translate to block origin). *(Drafted+reverted this session; math verified.)*
   - In `compileSceneLayer`: replace `blockToCanvas = placementMatrix(layer.placement)` with `blockToCanvas = animToInputContain(animSize: program.mediaGeometry.contentSize…, blockRect: program.mediaGeometry.blockRectCanvas)`.
   - **Do NOT** strip origins or alter `worldWithinComp`/matte-source opacity.
2. (Likely none) `MediaFitResolver.swift` — expected unchanged. **Verify** its content-local output composes correctly under the new `blockToCanvas` (the earlier breakage was from changing only `blockToCanvas` while a stale assumption remained — must re-verify the full chain, not assume).

**Minimal field/semantic changes:**
- **Preferred (schema-free):** use existing `mediaGeometry.contentSizeWidth/Height` as `animSize`. **Requires verification** that `contentSize` (the binding baseline content size) **equals** the TVECore `animIR.meta.size` (the whole-anim size) for all templates. If they differ for any template → the anim size is a **new field** → **STOP** (schema/canonical change) and request approval.
- `placementMatrix`/`SceneLayer.placement` may become unused for block placement (keep or deprecate; no payload change if just unused).

**Schema/canonical bytes:** target = **no change** (interpretation-only). **STOP trigger:** if anim size must be added to `RenderMaterialProgram.mediaGeometry` (because `contentSize ≠ animIR.meta.size`), that changes canonical material bytes → STOP before adding.

**Payload structs:** target = no change.

---

## 5. Tests

1. **Oracle transform tests** (new) — assert AnimiEngineNext `blockToCanvas` ≈ TVECore `animToInputContain` (scale, tx, ty) for `full_image`, `polaroid_2`, `example_4blocks`, `6_frames_template` representative blocks. Prove current code fails for example_4blocks/polaroid_2.
2. **`MultiBlockCompositeTests`** (exists): `example_4blocks` all 4 blocks + mattes correct; `6_frames_template` 6/6; synthetic `testTwoMaskGroupsBothReachCanvas`/`testTwoMatteGroupsBothReachCanvas` stay green.
3. **Regression**: `full_image`/`polaroid_2` unchanged (oracle-compare + visual). ⚠️ polaroid_2 (contentSize 680×900 ≠ canvas) **will change** under the fix — must confirm new output matches TVECore (it's currently subtly wrong, just less visibly).
4. Matte-source alignment test; media fit/scale/rotation test under the new contract.
5. Existing engine suites (RenderGraph, MaskMatte, corrective, stacking, Step9) stay green.

---

## 6. ReferenceData impact

- **Which references change:** every multi-block / non-full-canvas-anim candidate — `example_4blocks` (all), `6_frames_template` (all), `polaroid_2` (anim 680×900 scaled into canvas), likely `polaroid_shared_demo`. Single full-canvas (`full_image`) likely unchanged.
- **`PostPromotionMatrixRegressionTests` WILL fail** after a correct fix (live output changes; references encode the old broken geometry). Earlier measured: a partial fix already dropped it to 33/64.
- **Re-promotion workflow (DO NOT RUN):** after fix verified correct on-device, regenerate the sealed run → guarded promote via the Step17 entrypoint (`ANIMI_STEP17_PROMOTE=1 ANIMI_STEP17_SOURCE_RUNID=<new>`), clean-root replace, then 64/64 exactMatch re-check. **Only with explicit owner approval.**

---

## 7. Device gate (after implementation)

Real iPhone 13 Pro, flag ON: `example_4blocks` all 4 photos + mattes correct; `6_frames_template` 6 photos visible; `full_image`/`polaroid_2` unchanged; live gesture/scrub OK. Flag OFF: old renderer unchanged.

---

## STOP points (explicit)
- **STOP** if anim size must become a new `mediaGeometry`/payload field (canonical bytes change).
- **STOP** before any ReferenceData re-promotion.
- No templates/SceneSources/SharedAssets/compiled.tve changes. No export/CP5. No commits.

## Confirmations
- No code changed (engine pristine, 64/64). No ReferenceData/template/resource change. No export/CP5. Not committed. CP4 app bridge stays uncommitted until engine geometry fixed.
