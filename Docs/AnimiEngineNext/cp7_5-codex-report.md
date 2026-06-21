> **SUPERSEDED (2026-06-20).** The matte-in-timeline analysis here is OUTDATED. Final canonical
> resolution: a matte SOURCE bypasses the visible/timing AND hidden gates and renders HELD at its last
> authored frame (TVECore oracle parity) — NOT "transparent when inactive". A timing-inactive/hidden
> matte source is NOT skipped/transparent. See the implemented fix in `RenderGraphCompiler` and the
> updated `cp7_5-codex-report-2.md` conclusion. BUG B (export perf) remains valid → CP7.6 GPU-direct.

# CP7.5 — Codex report: two open bugs (perf + matte-in-timeline)

**Status:** CP7.5 (canonical two-clock stretched-scene support) is implemented engine+bridge, all automated tests green (engine 373/0, full AnimiApp suite 0 fail). Device E2E: video works, **audio fixed & owner-confirmed**. TWO bugs remain, found only on device (not in automated coverage). NOT committed. NO templates/ReferenceData/CP8 touched.

Asking Codex to diagnose/fix these two precisely — I have hypotheses but am not confident enough to change code without a second pass (owner instruction).

---

## Architecture recap (what CP7.5 changed)

Two-clock model for a STRETCHED scene (timeline span > native nominal duration), approved by owner (D1–D4):
- `SceneManifestEntry.timelineSpan` (>= nominalDuration). `projectDuration()` sums span. schemaVersion 1→2, dual-path decode.
- `SceneSpanIndex` lays scenes out by `timelineSpan` (boundary at span end).
- `SceneSubplan`: renamed `scenePlaybackTime` → `mediaPlaybackTime`, **added** `visualPlaybackTime`.
- `TimelineEvaluator`: `visualPlaybackTime = min(sceneTime, nominalDuration-1)` (held), `mediaPlaybackTime = sceneTime` (continues). **Layer visibility (activeRange) + `animationRequest` use VISUAL; video SourceRequest target uses MEDIA.** (`TimelineEvaluator.swift` `buildSceneSubplan` / `activeContent(atMediaTime:)` / `animationRequest(atVisualTime:)`.)
- `MaterialAvailabilityValidator.checkSceneLayers(mediaInterval:visualEnd:bodyEnd:)`: video by media span, `.becomeInactive` animation by visual (nominal).
- Bridge: removed `stretchedSceneUnsupported`; `decodeMedia` resolves span ticks; `convertScene` passes `timelineSpan` to `CompiledTemplateConverter`; export `totalFrames = preparedContext.totalFrames` (span); audio extended via `AudioCompositionBuilder.build(stretchedSceneDurationFrames:)`; video resolver samples at `mediaPlaybackTime`.

---

## BUG 1 — Render ~10× slower than expected (UNRESOLVED, partial fix applied)

**Symptom:** owner reports preview/export render of a stretched scene is ~5–10× slower than it should be. A stretched 5s→10s scene legitimately renders 2× the frames (300 vs 150) — but 10× is far beyond that.

**Fix already applied (real, but insufficient):** my CP7.5 first cut added a SECOND full `CompiledTemplateConverter.convert` in `NextSingleSceneBridge.decodeMedia` (a "native-probe" + a "real-probe with span"). I removed it → single convert (span ticks computed from the one probe's document). BUT `decodeMedia` runs ONCE per media cache key (`NextPreviewController` caches `decodedMedia` by `MediaKey`), so doubling it cannot explain a PER-FRAME 10×. Owner still sees 10× after this fix → the cost is per-frame, not yet root-caused.

**Where to look (hypotheses, unverified):**
1. **Per-frame re-assemble / re-decode in the stretched path.** `NextPreviewController.requestFrame`/`requestTimelineFrame` reuse `context`/`decodedMedia` only when the key matches. Does a stretched scene churn the key per frame (e.g. `timelineDurationFrames` or some placement-free field varying)? Check `NextPreviewKey`/`MediaKey` stability across frames for a stretched scene.
2. **Video resolver reseek thrash.** `NextVideoBlockResolver` is forward-stream; a BACKWARD target rebuilds the AVAssetReader. In the stretched tail the target clamps to `winEnd - 1/600` (constant plateau) → should be monotonic (no reseek). But verify: does `mediaPlaybackTime` ever go backward frame-to-frame during scrub/playback of a stretched scene, causing a reader rebuild EVERY frame? That would be ~10×. File: `NextVideoFrameResolver.swift` `resolve(scenePlaybackSeconds:)` + `startReader(fromSeconds:)`.
3. **Window/evaluator cost scaling with span.** `buildWindow` builds an `EvaluationWindow` over `[0, projectDuration)`. For a stretched scene projectDuration doubled — does any O(n) per-frame structure scale with span ticks? Unlikely but check `EvaluationWindowBuilder` / `TimelineIndex.requirements`.
4. **Export vs preview:** is the 10× on preview, export, or both? (Owner said "render" — likely both.) Export totalFrames=300 is correct (2×); anything beyond 2× there points to per-frame cost too.

**Recommended Codex first step:** add a per-stage timing probe (decode ms / assemble ms / per-frame render ms) for a stretched vs unstretched single scene on device or sim, and compare. The ratio localizes the cost. I did NOT add probes (didn't want to guess-instrument).

---

## BUG 2 — Matte template in a timeline FAILS: "matte source is timing-inactive" (UNRESOLVED, not fixed)

**Exact error (device):**
```
Render error: Next bridge engine error:
compile: unsupportedLayerMode(field: "scene[cp5-inst-1].layer[block_02].comp[__root__].animLayer[2].matte.source",
                               value: "matte source is timing-inactive")
```

**Throw site:** `RenderGraphCompiler.swift:317`:
```swift
guard let localFrame = try AnimationSampler.layerLocalFrame(layer.timing, compFrame: compFrame) else {
    // A timing-inactive matte source cannot satisfy its consumer; an ordinary layer just skips.
    if asMatteSource { throw RenderGraphError.unsupportedLayerMode(field: "\(field).matte.source", value: "matte source is timing-inactive") }
    return
}
```
`layerLocalFrame` returns nil when `compFrame >= timing.outPoint` (or `< inPoint`). So the matte SOURCE sublayer (`animLayer[2]` inside block_02's `__root__` comp) is inactive at the comp time used for this frame.

**How compFrame is derived (the CP7.5-relevant chain):**
- `RenderGraphCompiler.compileSceneLayer` → `sceneFrame = AnimationSampler.frameTime(for: layer.animationRequest, meta:, authoredTicks:)` (line 160) → fed as `compFrame` into `expandComposition`/`compileAnimLayer`.
- `layer.animationRequest` is built by `TimelineEvaluator.animationRequest(atVisualTime:)` — i.e. **VISUAL** clock (CP7.5).
- `cp5-inst-1` = the SECOND scene instance of a CP5 timeline (`NextSceneIdentity.cp5Timeline(index: 1)`).

**Key unknowns (need Codex + maybe owner project detail):**
1. **Is `cp5-inst-1` STRETCHED?** If NOT stretched, `visualPlaybackTime == mediaPlaybackTime == old scenePlaybackTime`, so the animationRequest is identical to pre-CP7.5 → this would be a **pre-existing, never-tested** matte-in-Next-timeline issue (the CP5 E2E tests use `full_image`, which has NO matte; matte templates like block_02 were only ever device-smoked in SINGLE-scene CP4). If stretched, CP7.5's visual holdLast-clamp could push the matte source past its `outPoint`.
2. **Should a matte SOURCE use the visual or the media clock?** CP7.5 routes ALL template/animation timing (incl. matte source layers, since they're template anim layers) through the VISUAL clock. The matte source is a template element → visual is intended. But if the matte source's `outPoint` is exactly at nominal end and the visual clamp lands at `nominal-1`, an off-by-one could make it inactive. Check `frameTime` holdLast: it returns `outPoint - 1 frame` of the PROGRAM meta — but the matte SUBLAYER has its own `timing.outPoint` independent of the program meta. The interaction between (program-level holdLast comp frame) and (sublayer timing.outPoint) under the new clamp is the suspect.
3. **Is this incoming-scene hold-first related?** During a transition, the incoming scene (`cp5-inst-1`) has visual/media time near 0 (hold-first). At time 0 a matte source with `inPoint > 0` would be inactive (`compFrame < inPoint`). Did CP7.5 change the incoming scene's time at all vs the approved `incomingSceneTime`? CP7.5 added `incomingVisualTime = clampVisual(incomingMediaTime, nominal)` — for an unstretched incoming this is a no-op, so it should match old behavior. Verify the incoming animationRequest is unchanged for non-stretched.

**Recommended Codex first step:** add an AnimiEngineNext unit test that compiles a MATTE template (not full_image) as the INCOMING scene of a 2-scene timeline at the transition (and as a sole scene), BOTH non-stretched and stretched, and see which case throws `matte source is timing-inactive`. That isolates pre-existing vs CP7.5-regression and visual-vs-media clock choice. There is an existing `MaskMatteShapeTests` / `CompositionLayerStackingTests` in the engine for matte fixtures to build from.

**Do NOT** blindly route the matte source to the media clock to "fix" it — that would desync the matte from the held template animation. The correct clock for a template matte source is almost certainly VISUAL; the bug is more likely an off-by-one in the holdLast/outPoint interaction or a pre-existing timeline-matte gap.

---

## Files changed in CP7.5 (for review)

Engine (AnimiEngineNext): ManifestEntries, CanonicalProjectManifest, RawProjectDTO, CanonicalProjectValueBuilder, ProjectValidator(+Error), TimelineIndex, EvaluationWindowRequirement, FramePlan(SceneSubplan), TimelineEvaluator, MaterialAvailabilityValidator, CompiledTemplateConverter(+Error). Tests: AnimatedTransitionTests + 4 fixture/encoding sites updated; new StretchedSceneTwoClockTests (12).
App bridge: NextSingleSceneBridge (span resolution, removed guard, mediaPlaybackTime), NextTimelineBridge, NextPreviewController (doc), EditorRuntimeExportController (totalFrames=span), VideoExporter (audio span), AudioCompositionBuilder (stretchedSceneDurationFrames). Tests: NextVideoExportRunnerTests (stretch tests rewritten), AudioCompositionBuilderVideoSlotTests (+1).

## What is verified working
- Engine two-clock unit tests (visual holds / media continues / projectDuration by span / stretched transition boundary / material split / v1 migration / unstretched unchanged): all pass.
- Bridge: stretched scene decodes, assembles totalFrames=span, renders 0/native-end/span-end without outsideProject (sim).
- Device: video renders correctly across stretched span; audio extends to full span (owner-confirmed).
- Full AnimiApp suite + engine swift test: 0 failures.

## What is NOT verified / open
- Render performance for stretched scenes (~10× — root cause unknown).
- Matte template inside a timeline (single-scene matte was fine in CP4; timeline+matte throws).
