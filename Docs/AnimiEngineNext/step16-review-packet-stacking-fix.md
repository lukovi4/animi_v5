# Step-16 Review Packet — Composition Layer Stacking Fix (Task 004 / CP2 blocker)

Status: **AWAITING OWNER APPROVAL** for promotion of the new sealed run. No promotion performed.

## 1. What changed and why

AnimiEngineNext drew composition/precomp layers in **forward** array order, drawing
`comp.layers[0]` first (bottom). AE/Lottie/TVECore semantics: array index 0 is the **top-most**
layer, so the renderer must draw **bottom-to-top** (last array element first, first element last).

- TVECore reference: `TVECore/Sources/TVECore/AnimIR/AnimIR.swift:257` — `for layer in composition.layers.reversed()`.
- Bug: `full_image` `comp_0.layers = [plastik.png, media, hidden mediaInput]` → old forward order
  drew `plastik.png` (index 0) at the bottom, then `media` over it → decor rendered **under** the
  user photo.

### Fix (canonical, not a workaround, not template-specific)

`AnimiEngineNext/Sources/AnimiEngineRenderGraph/RenderGraphCompiler.swift`, `expandComposition`:

```swift
for layer in comp.layers.reversed() {   // was: for layer in comp.layers
```

- Applies to every composition and precomp recursively.
- No AnimiApp bridge workaround; no special-casing of `full_image`/`plastik.png`.
- Scene-level block ordering (`SceneSubplan.layers.sorted { localCompositionOrder < ... }`) is a
  different level and is **unchanged**.

### Why matte/mask/parent are unaffected (verified)

- Matte source is resolved by **explicit `matte.sourceLayerID`** via `layersByID` (id-keyed) —
  independent of iteration order.
- Matte-source layers are skipped in the main loop (`if layer.isMatteSource { continue }`) and
  rendered on demand inside their consumer — array position irrelevant.
- Parent chain (`worldWithinComp` / `opacityWithinComp`) walks by `parentLayerID`, not array order.

## 2. Old vs new run

| | Run ID | Generated with |
|---|---|---|
| OLD (invalid for stacking) | `694A5886-4ADC-4228-ABDC-F050C030B59E` | old forward order — **must NOT be promoted** |
| NEW (this packet) | `B8B16B14-08CE-43E2-9D0B-BF7710A9AE65` | live code with reversed (correct) order |

New run aggregate hash (`supplementalArtifactsSHA256`):
`2496537c0e5ed95e1e246a2ab80741eeb4fbd71ede709e9123835e14b442256c`

New run path: `AnimiEngineNext/.benchmark-runs/B8B16B14-08CE-43E2-9D0B-BF7710A9AE65`

Sealed-run verification (V-1…V-9): status `success`, candidate count **64**, aggregate hash matches
run-manifest, **no `references/` or `diffs/` dirs**, all rows `candidateOnly`, staging cleaned.

## 3. Stacking-affected groups (audit)

Templates whose old references were generated with the wrong order (≥2 visible image layers per comp):

- `full_image` — 2 visible image layers/comp (media + `plastik`)
- `polaroid_2` — 2
- `polaroid_shared_demo` — 3

Not order-affected (1 visible image layer/comp): `example_4blocks`, `6_frames_template`.
Per req 6, the reference set is regenerated as one coherent 64-PNG set regardless.

## 4. Visual review of affected groups (honest, no overclaim)

The Step-15 matrix renders synthetic media with **uniform-grey fills** for both the binding media
and authored assets (no real photo). Therefore the candidate PNGs show the **layered structure**
(decor framing the media region) but the decor and media are both flat grey, so a strict
top/bottom determination **cannot be made by colour** from these synthetic renders.

Reviewed candidates:
- `full_image__block_01__no-anim-tick0__t0.png` — two concentric grey regions (full-canvas decor
  framing the inner media region). Structure consistent with `plastik` over media; not colour-decisive.
- `polaroid_shared_demo__block_01__no-anim-tick0__t0.png` — grey media region within a white
  polaroid frame; frame edges present. Structure consistent; not colour-decisive.
- Structural fixtures confirm no matte/mask/shape regression:
  - `synthetic-matte__blk__alpha-matte__t0.png` — matte correctly clips the red fill (intact).
  - `synthetic-shape-stroke__blk__fill-stroke__t0.png` — fill + stroke composited correctly.

**Decisive stacking proof is NOT the synthetic colour render.** It is:
1. The objective graph-order regression test (command-level), which asserts the exact relative
   order of `drawImage` commands — passing (see §5).
2. The CP2 device smoke with a **real photo** (req 14) — pending, gives the human-visible proof.

This packet does **not** claim pixel-exactness of any affected row beyond the structural review above.

## 5. Tests

`AnimiEngineNext/Tests/AnimiEngineRenderGraphTests/CompositionLayerStackingTests.swift` (4 tests),
asserting **exact relative draw order** (not `contains`):

- `test_singleComp_topAuthoredAsset_drawsAfter_bottomBindingMedia` — bottom binding media draws
  before top authored asset.
- `test_nestedPrecomp_reversedOrderAppliesRecursively` — reversed order applies inside a precomp.
- `test_realTemplate_fullImage_drawsMediaBeforePlastik` — real `full_image`: media `drawImage`
  precedes `plastik` `drawImage`.
- `test_audit_orderAffectedTemplates` — audit of affected templates.

Failing-before/passing-after proven: reverting the fix fails 3/4; with the fix 4/4 pass.

## 6. Promotion decision

**STOPPED before promotion** per req 11. Promotion of run `B8B16B14-08CE-43E2-9D0B-BF7710A9AE65`
into `AnimiEngineNext/ReferenceData` (replacing the full 64-PNG set, `sourceRunID` = new run ID)
will proceed **only after explicit owner approval**. Old run `694A5886…` will not be promoted.
