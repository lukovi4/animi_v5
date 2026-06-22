# CP7.8 — final report (texture-backed video + main-thread fix). STOP before commit.

**Scope finalized per lead decision.** CP7.8 is the texture-backed video core + direct CVMetalTexture
bind + bounded-scrub soft-skip + main-thread file-stat removed from the draw path. **Playback is smooth
on iPhone 13 Pro.** Remaining scrub unevenness is explicitly deferred to **CP7.9 (async decode / prewarm
outside the render queue)**. **No commit, no push.** ReferenceData/templates/resources untouched.

## Before → after (iPhone 13 Pro, device-measured)

| cost | before | after | how |
|---|--|--|---|
| CPU video bake (CGContext rotate/downsample) | p50 34 ms / max 231 ms per cold frame | **removed** | GPU CVMetalTexture bind |
| SHA-256 contentHash | p50 6.5 ms | **removed** | dynamic value descriptor, no byte hash |
| GPU `realize` (replaces bake) | n/a | p50 0 ms / max 4.3 ms | zero-copy map (direct bind, no blit) |
| main-thread `FileManager.attributesOfItem` | **p50 30 ms / max 59 ms, 12 stats/frame** (6 videos) | **0 ms, 0 stats/frame** | media (size,mtime) computed off-main at URL resolve, carried as values; `NextPreviewKey` value-only |
| main-thread `draw(in:)` total (6 videos) | many frames >16 ms; stat-bound | **p50 0.9 ms, draw>33ms = 0** | above |
| 6-video steady playback | "рывками / не запускаются" | **smooth** (owner-confirmed) | budget is scrub-only; playback unbounded so all 6 advance/tick |

## What shipped (production fixes kept)
1. **Value-only dynamic texture descriptor** (`RenderResourceKind.dynamicTexturePixelInput`,
   `ResolvedDynamicTextureInput`, `ResolvedLayerSource`) + **runtime `RenderRuntimeTextureBindings`** —
   GPU handles never enter the canonical model. `execute(_:)` oracle unchanged.
2. **Direct CVMetalTexture bind** (F3) — no owned blit, no second queue, no race; CV objects retained in
   the handle until the engine command buffer completes.
3. **`sourceID` includes PTS** (F4) — distinct frames have distinct canonical identity; runtime binding
   map keyed by `descriptor.id` (the red-screen `missingTextureBinding` regression, fixed + regression-tested).
4. **GPU orientation** folded into the normalize pass (bit-identical to CPU `rotateBGRA` for 0/90/180/270).
5. **Bounded-scrub soft-skip** (F1/F2) — during an interactive scrub, ≤K=2 cold decodes/tick, the rest
   reuse last-good; **playback is unbounded** (was wrongly bounded → starved videos; fixed). Export is exact.
6. **Main-thread fix B** — media stat off-main (`NextMediaStatCache`), `NextPreviewKey.init` value-only,
   draw path uses a pure cache lookup (`cachedOnly`, never disk).

## Remaining (deferred to CP7.9, NOT in CP7.8)
**6-video scrub still feels uneven** — owner: "скраб работает медленно и рывками". This is NOT main-thread
(now p50 0.9 ms) and NOT the bake (gone). It is two things, both render/decode-queue:
- the **bounded soft-skip**: during scrub 4/6 videos show last-good and catch up over ticks (visible jumps);
- the **synchronous forward decode** of each participating video on the single serial render queue.
**CP7.9 = async / concurrent video decode + prewarm OUTSIDE the render queue** (decode readers ahead into
the per-PTS texture cache so the render queue only binds ready textures), so a multi-video scrub neither
freezes nor soft-skips. This is an architectural item, intentionally not attempted as a CP7.8 patch (raising
K risks re-introducing the 3.3 s hard-scrub freeze).

## Verification — RESULTS (all green)
- App focused (sim): `NextPreviewCacheKeyTests` **23/23** (incl. value-only key, cachedOnly-no-disk,
  identity refresh, stale-media), `NextVideoTextureResolverTests` **5/5** (PTS sourceID, same-PTS cache,
  cold-decode classification, **bridge binding-id regression** — catches the red-screen bug),
  `NextGpuDirectPreviewTests` **7/7** (photo byte-parity — updated from video, which has no readback path),
  `NextVideoExportIntegrationTests` **3/3** (video via texture-readback — updated), `NextVideoFrameResolverTests`.
- Engine: `CP78DynamicTextureValueTests` **8/8**, `CP78TextureBindingTests` **7/7** (incl. orientation
  parity 0/90/180/270 bit-identical vs CPU oracle), **PostPromotionMatrix `exactMatch=84/84`** (oracle
  byte-identical — `execute(_:)` untouched).
- Two pre-CP7.8 tests UPDATED to the texture architecture (they asserted the removed bytes-readback video
  path) — coverage preserved, not weakened: byte-parity moved to photo (valid there), video content-advance
  moved to texture readback; video orientation parity covered by the engine test.
- Builds: app (sim + device) and engine package all green; probes removed (grep-clean).
- Device smoke (owner): 1-video smooth; **6-video playback smooth** (confirmed); 6-video scrub still uneven
  (soft-skip — known, CP7.9); no artifacts; OFF path unchanged.
- Known pre-existing (NOT CP7.8): `Step17PromoteReferencesTests` 6 failures = `candidateCountMismatch
  (expected:64, found:84)` stale fixture; files untouched by CP7.8.

## Changed files (CP7.8, production)
RenderModel: `RenderGraphCommands.swift`, `ResolvedFrameInput.swift`.
RenderGraph: `CompileContext.swift`, `RenderGraphCompiler.swift`, `RenderGraphValidator.swift`,
`RenderInputResolver.swift`.
MetalRender: `MetalGraphExecutor.swift`, `MetalRenderError.swift`, `MetalRenderSession.swift`,
`MetalResourceOwner.swift`, `MetalSourceNormalizer.swift`, `Shaders/AnimiEngineRender.metal`,
`RenderRuntimeTextureBindings.swift` (new).
App: `NextSingleSceneBridge.swift`, `NextTimelineBridge.swift`, `NextPreviewController.swift`,
`EditorViewController.swift`, `NextVideoTextureResolver.swift` (new).
Tests (new/updated): `CP78DynamicTextureValueTests.swift`, `CP78TextureBindingTests.swift`,
`NextVideoTextureResolverTests.swift`, `NextPreviewCacheKeyTests.swift`.
Docs/logs: this report + `cp7_8-video-pipeline-plan.md`, `cp7_8-corrective-NO-GO.md`, raw device logs.
**TEMP probes (`CP78PerfProbe.swift`, `CP78MainProbe.swift`, all markers): removed — grep-clean.**

## STATUS: STOP before commit
Awaiting explicit GO. Nothing staged. CP7.9 (async decode/prewarm) is the next chunk for smooth scrub.
