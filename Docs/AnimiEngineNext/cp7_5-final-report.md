# CP7.5 — Final Report (for Codex review)

**Task 004 / CP7.5 — canonical two-clock stretched-scene support + matte-source held semantics in AnimiEngineNext.**
Status: engine + app implemented; ReferenceData re-promoted (84/84); matte fix oracle-backed; all
automated suites green. **NOT committed / NOT pushed.** BUG B (export perf) deferred to CP7.6.

---

## 1. Scope (owner-approved D1–D4 + corrective passes)

CP7.5 makes AnimiEngineNext render a STRETCHED scene (timeline span > native nominal) with a two-clock
model, and fixes matte-source timing to match the TVECore oracle. Built on CP7 (committed branch
`cp7/next-user-video`).

- **D1** schemaVersion 1→2, dual-path decode (v1 → `timelineSpan = nominalDuration`, writer emits v2).
- **D2** `SceneSubplan.scenePlaybackTime` → `mediaPlaybackTime`; new `visualPlaybackTime`.
- **D3** project duration / scene layout / transition boundary use `timelineSpan`; outgoing VISUAL
  clamps to nominal-1 ONLY when stretched; outgoing MEDIA continues; post-roll of an unstretched scene
  unchanged.
- **D4** project canonical hash may change (v2); ReferenceData render pixels for the original 64 are
  byte-identical; the 20 newly-renderable matte rows are re-promoted.

---

## 2. Two canonical fixes in this checkpoint

### A) Two-clock stretched scene (visual held / media continues)
- `SceneManifestEntry.timelineSpan` (≥ nominalDuration, default = nominal). `projectDuration()` sums
  span. `SceneSpanIndex` lays scenes out by span (boundary at span end). `RequiredSceneSpan.timelineSpan`.
- `TimelineEvaluator`: `clampVisual(media, nominal, timelineSpan)` holds visual at nominal-1 **only when
  `timelineSpan > nominalDuration`** (so post-roll of an unstretched scene still continues → `.holdLast`,
  NOT a clamped `.sample`). Emits both `visualPlaybackTime` + `mediaPlaybackTime`. Layers/animation use
  visual; video `SourceRequest` target uses media.
- `MaterialAvailabilityValidator`: video by media span (timelineSpan + post-roll); `.becomeInactive`
  animation by visual (nominal).
- DTO/encoder/validator threaded; `CompiledTemplateConverter.Request.timelineSpan`.

### B) Matte source held semantics (oracle-backed) — the block_02 fix
- **Oracle (proven):** TVECore renders a matte SOURCE via `AnimIR.emitLayerForMatteSource` →
  `computeLayerWorld` → `computeWorldTransform(at: frame)` with **NO `isVisible` (timing) and NO
  `isHidden` gate**. A matte source authored to a shorter `[in,out)` than its consumer still renders
  (transform tracks clamp to the last keyframe = hold-last), so the consumer stays matted/visible past
  the source's authored end. (`AnimIR.swift` normal path applies these gates at L270/273/287; the
  matte-source path does not.)
- **Bug:** AnimiEngineNext `RenderGraphCompiler.compileAnimLayer` applied the `layerLocalFrame`
  `[in,out)` gate AND `isHidden` to matte sources → source went inactive past out-point → block_02
  disappeared after ~1s (preview + export). A prior CP7.5 cut wrongly made this "transparent on
  inactive", masking it.
- **Fix (canonical, not a special clamp):** in `compileAnimLayer`, when `asMatteSource` the layer
  bypasses BOTH gates and renders at `layerTransformFrame` (non-gated, VISUAL clock, samplers clamp =
  held). An ordinary layer keeps both gates. Transparent source surface remains valid ONLY for a
  genuinely empty/non-drawing (fully-clipped) source, and the validator allows a clear-only matte
  isolation surface for that case (never-cleared source still rejected; consumer must be drawn).

---

## 3. ReferenceData re-promotion (guarded, owner-approved)

The matte fix makes 20 `example_4blocks` mid/last frames render the block VISIBLE (held) instead of
hidden — a legitimate pixel change. Re-sealed + re-promoted a coherent 84-PNG set.

- New sealed run **`6137C324-1B97-4978-9B34-7D90D9CF483C`**, aggregate SHA `4992722517…`.
- **Git-level proof the original 64 are untouched:** `git status AnimiEngineNext/ReferenceData/references`
  → **0 modified (M), 20 new (??)** of 64 tracked PNGs. The committed 64 are byte-identical.
- Promoted full set: `wrote=84`; idempotent re-promote `wrote=0/noOp` (self-consistent).
- approval-manifest: `sourceRunID = 6137C324` (NOT the obsolete 14B1BAF8), `candidateCount = 84`,
  `approvedBy = owner`, suppSHA `4992722517…`, manifestSHA `f9da68d1…`.
- **PostPromotionMatrix = 84/84 exactMatch** (live render vs the new block-visible refs).
- Step15 sealed candidate count = 84.

The promoter needed NO code change (count-agnostic, validates `expectedCandidateCount`). Test constants
bumped 64→84 (Step15; Step17 env-overridable `ANIMI_STEP17_EXPECTED_COUNT`; PostPromotionMatrix).

---

## 4. Exact changed files

### Engine — AnimiEngineNext/Sources (15)
ManifestEntries, CanonicalProjectManifest, RawProjectDTO, CanonicalProjectValueBuilder, ProjectValidator,
ProjectValidationError, TimelineIndex, EvaluationWindowRequirement, FramePlan (SceneSubplan two-clock),
TimelineEvaluator (two-clock + clampVisual stretch-gated), MaterialAvailabilityValidator (visual/media
split), RenderGraphCompiler (matte-source held), RenderGraphValidator (clear-only allowance),
CompiledTemplateConverter (+timelineSpan), TemplateConversionError (+invalidTimelineSpan).
Plus AnimiEngineTestSupport/CanonicalProjectFixtures (+timelineSpanTicks).

### Engine — AnimiEngineNext/Tests
NEW StretchedSceneTwoClockTests; MOD AnimatedTransitionTests (→ mediaPlaybackTime), CanonicalProjectEncodingTests
(v2 + v1-migration), ProjectValidationTests (v3 unsupported), GraphTestFixtures / RenderInputResolverTests /
Step9CorrectiveDefectTests / TransitionAndValidatorCorrectiveTests (SceneSubplan two-arg ctor),
Step9FinalCorrectiveTests (clear-only allowed + never-cleared rejected), RenderGraphCompilerCorrectiveTests
(timing-inactive matte source renders held), TemplateCanonicalConversionTests (→ mediaPlaybackTime),
Step15SealedRunTests / Step17PromoteReferencesTests / PostPromotionMatrixRegressionTests (64→84).

### ReferenceData
approval-manifest.json (M, sourceRunID=6137C324, count=84) + 20 new reference PNGs (??); original 64 unchanged (0 M).

### App — AnimiApp/Sources (7)
NextSingleSceneBridge (timelineSpan resolution, removed stretch guard, mediaPlaybackTime),
NextVideoFrameResolver (bake cache by sample PTS), NextPreviewController (timeline prerender + cache key),
EditorViewController (timeline prerender call + timelineDurationFrames), EditorRuntimeExportController
(totalFrames = stretched span + 1-scene route + audio span), VideoExporter (audio stretched span),
AudioCompositionBuilder (stretchedSceneDurationFrames).

(Plus CP7 app files already on branch `cp7/next-user-video`.)

---

## 5. Tests & results

- Engine non-GPU: Core **231/0**, RenderGraph **214/0**, TemplateAdapter **207/0**.
- GPU: Step15 sealed **84**, Step17 promote **wrote=84 / idempotent noOp**, **PostPromotionMatrix 84/84 exactMatch**.
- New: `StretchedSceneTwoClockTests` (12: visual holds / media continues / projectDuration by span /
  stretched transition boundary / material split / v1 migration / unstretched unchanged);
  `testTimingInactiveMatteSourceStillRendersHeld`; `testClearOnlyMatteSourceSurfaceAllowed` +
  `testMatteSourceSurfaceNeverClearedStillRejected`; v1-decode migration test.
- App focused (earlier this corrective): NextVideoFrameResolver / runner / cache-key / audio-slot /
  timeline-E2E green; full AnimiApp suite green.
- No TEMP probes: `rg "TEMP DIAG|cp75_|RenderGraphDebugSink|remove before commit"` → 0.

---

## 6. Device (iPhone 13 Pro, flags ON) — pending owner confirmation this pass
Build installed + launched with the matte-held fix. Owner to confirm: block_02 stays visible >1s
(preview + export); stretched video upright + plays to end; OFF path unchanged. (Export is still slow —
see BUG B.)

---

## 7. BUG B — export perf (DEFERRED to CP7.6, not fixed here)
Measured (device, pre-probe-removal): 73.4 ms/frame render = GPU execute + GPU→CPU readback to BGRA8
`Data` + CPU memcpy (`copyOpaque`). Old TVECore renders GPU-direct into the encoder CVPixelBuffer (no
readback). This is the BGRA8-`Data` bridge's architectural cost, flagged by Codex earlier. **CP7.6 =
GPU-direct export** via `MetalRenderSession.execute(into: CVPixelBuffer)` (CVMetalTextureCache),
eliminating the readback. Not started; CP7.5 perf fixes (single convert, resolver bake cache, timeline
prerender) help decode/preview but not the export per-frame readback.

---

## 8. Boundaries / confirmations
- No AnimiEngineNext schema change beyond the approved `timelineSpan` + two-clock model.
- No templates / SceneSources / SharedAssets / compiled.tve mutation.
- ReferenceData: original 64 byte-identical (git: 0 modified); 20 new + manifest = owner-approved re-promotion.
- All TEMP probes removed; stale "inactive matte → transparent" wording corrected in code comments +
  both prior Codex reports banner-superseded.
- Obsolete sealed run 14B1BAF8 superseded by 6137C324.
- CP8 not started. NOT committed, NOT pushed.

## 9. Suggested Codex review focus
1. `RenderGraphCompiler.compileAnimLayer` matte-source gate bypass — correctness for nested matte
   chains + matte source that is BOTH parent and source.
2. `clampVisual` stretch-gating — the post-roll vs stretch distinction (does any stretched-scene
   post-roll case need both?).
3. Re-promotion integrity: 64 byte-identical + 20 new = coherent 84; manifest sourceRunID/hash.
4. Validator clear-only allowance vs the now-held matte source (no longer the inactive case).
