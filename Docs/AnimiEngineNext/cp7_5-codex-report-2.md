> **BUG A RESOLVED (2026-06-20).** Oracle confirmed case (a): old TVECore SHOWS block_02 after 1s
> because `emitLayerForMatteSource`→`computeLayerWorld` renders the matte source with NO isVisible/
> isHidden gate (transform clamps to last keyframe = held). FIX: `RenderGraphCompiler.compileAnimLayer`
> — a matte SOURCE now bypasses the timing-active + hidden gates and renders HELD at `layerTransformFrame`
> (visual clock). This is a general matte-source rule, not a per-source clamp, and not "transparent on
> inactive". Consequence: the 20 `example_4blocks` mid/last reference rows legitimately change (block_02
> now visible) → re-seal + re-promote 84 (owner-approved). BUG B (export perf) stands → CP7.6.

# CP7.5 — Codex report #2: matte-disappears + export perf (with device data)

Both bugs now have **hard device measurements** (no guessing). I'm NOT 100% confident on the matte fix and the perf is architectural — reporting per owner instruction.

State: CP7.5 two-clock engine + bridge done; ReferenceData promoted 84/84 exactMatch (owner-approved, old 64 byte-identical); stretched video preview/export works; audio fixed. These two remain.

---

## BUG A — matte block_02 disappears after ~1s (PREVIEW + EXPORT). Likely a CP7.5 regression.

### Device data (`cp75_matte_diag.log`, real device)
```
frame=180 MATTE-INACTIVE scene[cp5-inst-1].layer[block_02].comp[__root__].animLayer[2] compFrame=30/1 in=0/1 out=30/1
frame=181 ...                                                                           compFrame=31/1 in=0/1 out=30/1
frame=182 ...                                                                           compFrame=32/1 ...
... (continues for every frame past compFrame 30)
```
- The matte SOURCE sublayer (`animLayer[2]`) is authored active `[in=0, out=30)` frames (≈0–1s @30fps).
- Once the scene's `compFrame` reaches **30/1 and beyond**, the sublayer is timing-inactive → (after my CP7.5 matte fix) its source surface is transparent → `.alpha` matte fully masks the consumer → **block_02 vanishes** and never returns.
- `cp5-inst-1` = the SECOND scene instance of a CP5 **timeline** (`NextSceneIdentity.cp5Timeline(index:1)`).
- Note `compFrame` keeps **advancing** (30,31,32…) — it is NOT clamped to a holdLast frame.

### Why this is (probably) a CP7.5 regression, not pre-existing
- In CP4 the SAME matte template (block_02) was device-verified in **single-scene** and held correctly.
- The `compFrame` fed to the template graph comes from `RenderGraphCompiler.compileSceneLayer` →
  `AnimationSampler.frameTime(for: layer.animationRequest, ...)`. `animationRequest` is built by the
  evaluator. CP7.5 changed this to `animationRequest(atVisualTime:)`.
- For an UNSTRETCHED scene CP7.5 makes `visualPlaybackTime == mediaPlaybackTime` (the clamp is gated
  on `timelineSpan > nominalDuration` — see `TimelineEvaluator.clampVisual`). So the visual clock
  CONTINUES (does not hold) past the sublayer's outPoint, advancing `compFrame` to 30,31,… → the
  authored sublayer goes inactive.
- BEFORE my matte fix this would have THROWN ("matte source is timing-inactive"); my fix turned the
  throw into a transparent surface, which is correct for genuinely-inactive sources but here it
  **masks a deeper question**: should `compFrame` for the matte source advance past 30 at all, or
  should the program's `holdLast` policy hold the whole comp (incl. the matte source sublayer) at its
  last authored frame?

### The real question for Codex
What is the correct comp-time for a template whose PROGRAM animation policy is `holdLast` but whose
matte-SOURCE sublayer has a shorter authored `[in,out)`?
- TVECore oracle: `AnimIR.emitLayerForMatteSource` → `computeLayerWorld` returns nil for an inactive
  sublayer → empty (transparent) matte source. BUT does TVECore's comp-time for a holdLast program
  CLAMP to the program's last authored frame (so the sublayer never goes inactive), or does it also
  advance and drop the sublayer? **This determines whether block_02 should hold-last (visible) or
  legitimately vanish.** Needs oracle confirmation against old-app behavior for this exact template.
- Hypothesis: the program-level `holdLast` should clamp `compFrame` to the program's authored last
  frame (`meta.outPoint − 1`), so a 0–30 sublayer inside a holdLast program stays at frame 29 (active)
  forever, not advance to 30+. If so, the bug is in how `frameTime(.holdLast)` / the per-scene time is
  fed: for an incoming timeline scene the request may be `.sample(advancing)` when it should be
  `.holdLast` once past authored end.

### What I changed that's relevant (and might be wrong)
- `TimelineEvaluator.animationRequest(atVisualTime:)` — uses visual clock.
- `clampVisual` gated on stretch only (so unstretched incoming scene advances). This FIXED the post-roll
  holdLast regression (TemplateAdapter test) but may be WRONG for the matte-source-in-incoming-scene
  case. The two requirements may conflict and need a more precise rule.
- `RenderGraphCompiler` inactive matte source → transparent (the throw→transparent fix). This is
  oracle-correct in isolation but exposes the above.

### Do NOT
- Do not just clamp the matte source's compFrame independently (would desync it from the rest of the
  comp). The fix must be a coherent per-scene/per-comp time policy.

---

## BUG B — export ~much slower than TVECore. ARCHITECTURAL (per Codex's earlier note).

### Device data (`cp75_export_perf.log`, real device, stretched scene)
```
NEXT EXPORT PERF frames=450 wall=41100ms render=33028ms copy=7700ms enqueue=3ms perFrameRender=73.4ms
```
- **render = 33.0s (73.4ms/frame)** — the dominant cost. This is `NextSingleSceneBridge/NextTimelineBridge.renderFrameBGRA` = evaluate→resolve→compile→`MetalRenderSession.execute` (GPU render) **+ GPU→CPU readback to BGRA8 `Data`**.
- copy = 7.7s (17ms/frame, `copyOpaque` CPU memcpy into CVPixelBuffer).
- enqueue ≈ 0.
- 450 frames because this was a stretched scene (legit 2× frame count is part of it, but per-frame 73ms render is the issue).

### Root cause (confirmed, not guessed)
The CP7 architecture renders each frame on the GPU, **reads it back to CPU `Data`**, then re-uploads
(memcpy) into the encoder's CVPixelBuffer. Old TVECore export renders on the GPU **directly into the
encoder's CVPixelBuffer** (no readback, no CPU round-trip). The 73ms/frame is GPU execute + readback;
the 17ms/frame copy is the CPU memcpy of an 8MB BGRA buffer. Both are inherent to the BGRA8-`Data`
bridge.

Per Codex's own CP7 note: *"BGRA8 CPU decoder + Data upload is functional CP7 architecture, not final
high-performance video architecture. Any shared MTLTexture/GPU path is a separate STOP task."* This is
that STOP. To match TVECore export perf, the Next export needs to render **directly into a Metal
texture wrapping the encoder's CVPixelBuffer** (CVMetalTextureCache), eliminating readback+memcpy. That
is a non-trivial architecture change to `MetalRenderSession`/`NextVideoExportRunner` (the engine
currently only returns `RenderedFrame.bytes`).

### Already-applied perf fixes (helped, insufficient)
- Removed doubled convert in `decodeMedia`.
- Video resolver bake cache (held tail / repeated time → no rebake).
- Timeline prerender (preview only; doesn't help export wall time).
These cut decode/preview cost but NOT the per-frame GPU-render+readback that dominates export.

### Options for Codex/owner
1. Accept CP7-architecture export perf for now (functional, slower); ship; defer GPU-direct export to a
   separate task. (Matches Codex's earlier STOP framing.)
2. Implement GPU-direct export: add a `MetalRenderSession.execute(into: CVPixelBuffer via
   CVMetalTextureCache)` path so the final composite writes straight into the encoder buffer (no
   `.bytes` readback, no `copyOpaque`). Biggest win (~removes 90ms/frame). Larger engine change.

---

## TEMP probes currently in tree (DEBUG-gated, MUST be removed before commit)
- `NextVideoExportRunner.swift` — `cp75_export_perf.log` per-stage timing.
- `RenderGraphDebugSink.swift` (new file) + `RenderGraphCompiler` inactive-matte recording.
- `NextTimelineBridge`/`NextSingleSceneBridge` `renderFrameBGRA` — drain sink → `cp75_matte_diag.log`.

## Verified-green (unchanged by these bugs)
- Engine 373/0 (Core/RenderGraph/TemplateAdapter), incl. two-clock + matte-transparent + post-roll holdLast.
- ReferenceData 84/84 exactMatch post-promotion.
- Stretched video preview/export functional; audio extends to span.

## NOT done / open
- BUG A (matte source in incoming timeline scene disappearing) — needs the comp-time/holdLast policy
  decision above. Likely CP7.5 regression.
- BUG B (export perf) — architectural; needs owner decision (accept vs GPU-direct export task).
- Device gate not passable until BUG A fixed.
- NOT committed. CP8 not started. Templates/SceneSources/compiled.tve untouched.
