# AnimiEngineNext Decision Register

Status values:

- **APPROVED** - explicitly confirmed by the product owner.
- **ACCEPTED** - canonical technical decision accepted under owner authorization.
- **PENDING OWNER APPROVAL** - proposed technical choice; no implementation may rely on it.
- **BENCHMARK DECISION** - alternatives must be implemented and measured first.
- **OPEN PRODUCT QUESTION** - only when research and existing requirements do
  not define the visible product behavior.

## Approved

| ID | Decision | Status |
|---|---|---|
| D-001 | Build a new engine beside the current engine. | APPROVED |
| D-002 | Do not modify or gradually migrate the current engine during development. | APPROVED |
| D-003 | Initial development and tests do not use product UI. | APPROVED |
| D-004 | Real existing templates and their animations are mandatory tests. | APPROVED |
| D-005 | Support the composition model with up to 20 animated videos. | APPROVED |
| D-006 | Center scene transitions around the scene boundary. | APPROVED |
| D-007 | Outgoing scene continues playing through a slide transition. | APPROVED |
| D-008 | Under overload reduce the whole preview frame rate, not random individual layers. | APPROVED |
| D-009 | All tunable choices must be configurable and quickly testable. | APPROVED |
| D-010 | Tests, logs, measurements and comparisons are mandatory. | APPROVED |
| D-011 | Technical decisions require owner approval. | APPROVED |
| D-012 | No cloud backend is required for the initial engine. | APPROVED BY SPEC |
| D-013 | Initial product output is local 1080x1920, 30 fps, SDR MP4. | APPROVED BY SPEC |
| D-014 | Export is deterministic offline rendering from original media. | APPROVED BY SPEC |
| D-015 | Stale, mixed and partial published frames are forbidden. | APPROVED BY SPEC |
| D-016 | Transitions do not change total project duration. | APPROVED |
| D-017 | Both scenes continue their animation inside the centered transition window. | APPROVED |
| D-018 | Active timeline scrubbing is silent. | APPROVED |
| D-019 | All simultaneously active, unmuted audio sources are mixed, including scene overlap during a visual transition. | APPROVED |
| D-020 | Every active video contributes audio by default; user volume and mute control it independently of visual visibility. | APPROVED |
| D-021 | Project music plays once and never loops automatically. | APPROVED |
| D-022 | Interruption or relevant route change pauses playback; only an explicit user play action resumes it. | APPROVED |

## Architecture decisions

| ID | Proposal | Recommendation | Status |
|---|---|---|---|
| D-101 | Package boundary | Independent Swift package plus minimal iOS benchmark host. | APPROVED |
| D-102 | Dependency rule | New engine must not import `AnimiApp` or current playback/export modules. | APPROVED |
| D-103 | Existing template format | Initially load current compiled `.tve` through an isolated adapter. | APPROVED |
| D-104 | Project adapter | Keep current `ProjectDraft` conversion outside the new engine. | ACCEPTED 2026-06-25 |
| D-105 | Evaluation model | Pure evaluator creates immutable complete frame plans. | APPROVED |
| D-106 | Realtime authority | One scheduler owns clock, deadlines, grants, cancellation and degradation. | APPROVED |
| D-107 | Publication | Only the composed-frame publisher may update visible output. | APPROVED |
| D-108 | Identity model | Separate project revision, playback epoch, request, cache and export identities, as defined by ADR-005. | ACCEPTED 2026-06-25 |
| D-109 | Configuration | Versioned typed configuration with a stored hash in every run. | APPROVED |
| D-110 | Evidence storage | Store immutable run manifests, structured events and per-frame metrics. | APPROVED |
| D-111 | Concurrency boundary | Serialized scheduler ownership plus bounded decode/cache/render/audio workers, as defined by ADR-006. | ACCEPTED 2026-06-25 |
| D-112 | Development gates | No next subsystem until the previous gate has stored passing evidence. | ACCEPTED 2026-06-25 |
| D-113 | Master clock | Audio render clock is master for an audio-bearing playback epoch; otherwise use an injected monotonic clock. Never switch clocks inside an epoch. | ACCEPTED 2026-06-25 |
| D-114 | Canonical audio model | Immutable manifest audio data and pure `AudioPlan` are the single timing/mix source for preview and export, as defined by ADR-012. | ACCEPTED 2026-06-25 |
| D-115 | Audio execution | Streaming `AVAudioEngine` for preview and isolated manual offline rendering for export on a canonical 48 kHz Float32 stereo mix grid. | ACCEPTED 2026-06-25 |
| D-116 | Canonical audio schema | Project schema v3 requires normalized `sources`/`tracks`/`clips`, strict v1/v2 uplift, typed scene-layer references, role/asset validation, and encoder-owned deterministic ordering. | ACCEPTED 2026-06-25 |

## Benchmark decisions

| ID | Decision to measure | Required alternatives | Status |
|---|---|---|---|
| D-201 | Realtime decode backend | AVFoundation output vs VideoToolbox. | BENCHMARK DECISION |
| D-202 | Active decoder limits | Configured counts by device and workload. | BENCHMARK DECISION |
| D-203 | Proxy codec | ProRes Proxy vs short-GOP H.264 vs HEVC. | BENCHMARK DECISION |
| D-204 | Proxy pyramid | Resolution, quality, GOP and audio variants. | BENCHMARK DECISION |
| D-205 | Cache format | Candidate codecs/pixel formats and chunk sizes. | BENCHMARK DECISION |
| D-206 | Cache policy | Generation, invalidation, disk budget and eviction. | BENCHMARK DECISION |
| D-207 | Internal video path | Native YUV vs BGRA conversion points. | BENCHMARK DECISION |
| D-208 | High-precision intermediates | Scoped RGBA16F vs 8-bit intermediates. | BENCHMARK DECISION |
| D-209 | Text rendering | Whole-text cache vs glyph-atlas path by scenario. | BENCHMARK DECISION |
| D-210 | Preview thresholds | Resolution/proxy/cache changes and 30/24/15 fps thresholds. | BENCHMARK DECISION |
| D-211 | Device tiers | Supported iPhone floor and guarantees per tier. | BENCHMARK DECISION |
| D-212 | Export concurrency | Decoder/render concurrency and retry settings. | BENCHMARK DECISION |
| D-213 | Audio overload/output stage | Compare explicit deterministic hard saturation against a fixed safety limiter; require preview/export equivalence and device evidence. | ACCEPTED OFFLINE-PROVEN (2026-06-26) — selected: Candidate A explicit deterministic hard saturation `clamp(x,-1,+1)`; fallback: Candidate B fixed stateless safety limiter; preview/export equivalence + determinism proven offline (`d-213-audio-output-stage-benchmark.md`); device audible-quality confirmation pending in Slice 004. |

## ADR status by subsystem

Only ADRs required by the active roadmap slice must be accepted before that
slice begins. A future `NOT DRAFTED` ADR gates its own subsystem; it does not
block authorized earlier slices.

| ADR | Subject | Status |
|---|---|---|
| ADR-001 | Package and dependency boundaries | Accepted (Task 001) |
| ADR-002 | Project and template compatibility | Accepted; realized in Task 002 |
| ADR-003 | Canonical rational time | Accepted; realized in Task 002 |
| ADR-004 | Transition and material semantics | Accepted; realized in Task 002 + CP7.5 |
| ADR-005 | Identity, cancellation and frame publication | Accepted 2026-06-25 |
| ADR-006 | Scheduler and master-clock ownership | Accepted 2026-06-25 |
| ADR-007 | Decode backend interface | NOT DRAFTED |
| ADR-008 | Proxy system | NOT DRAFTED |
| ADR-009 | Render cache | NOT DRAFTED |
| ADR-010 | Render and color contract | NOT DRAFTED |
| ADR-011 | Text contract | NOT DRAFTED |
| ADR-012 | Canonical audio architecture | Accepted 2026-06-25 |
| ADR-013 | Export contract | NOT DRAFTED |
| ADR-014 | Diagnostics, evidence and comparison | Accepted foundation/reference subset; runtime extensions pending |

## Approved deviations

| Deviation | From | To | Status | Reference |
|---|---|---|---|---|
| Overlay-lookup complexity | §10.1 `O(log n + k)` | `O(log n + k log k)` (collect-then-sort) | APPROVED | Corrective plan C-8 (Option B); ADR-002 §8 |
| `ResolvedFrameInput.swift` location | §14 (file not enumerated) | new file in `AnimiEngineRenderModel` | APPROVED | Task-003 §17 step 8 (Stage-7); §4.1 owns resolved pixel inputs / final transform |
| Media transform representation | §6/D3-05 implied `Placement` (in `ResolvedMediaPlacement`) | new `FixedAffineTransform2D` (six checked fixed-point coefficients) | APPROVED | Task-003 §17 step 8 (Stage-7); `Placement`'s single isotropic scale cannot express `fill`'s anisotropic scale or the fit×user matrix composition |
| `ResolvedMediaPlacement` shape | `{fitMode, placement, crop}` | `{fitMode, transform, clip}` (ready destination-space clip, no baked source crop) | APPROVED | Task-003 §17 step 8 (Stage-7); D3-05 final transform/clip; `cover` is not a source crop |

The Stage-7 (§17 step 8) deviations above were approved by the product owner during implementation.
`FixedAffineTransform2D` is the smallest representation that holds an anisotropic `fill` scale together
with the fit→centre→user-transform composition (D3-05) without any `Float`/`Double`.

### Step-8 corrective deviations (Stage-7 REJECTED → corrective pass; owner-approved)

| Deviation | From | To | Status | Reference |
|---|---|---|---|---|
| Canonical media placement | implicit (outer `Placement` only) | new `AnimiEngineCore.MediaPlacement` (`MediaFitMode` + user offset/scale/arbitrary rotation), threaded through `SceneLayer`/`ActiveLayer`/strict codec/canonical hash/evaluator | APPROVED | corrective #1 |
| Fit selection source | external `fitModes` map at the resolver | authored `MediaPlacement` carried by `MediaBinding`; converter validates the chosen fit against `fitModesAllowed`, no implicit default | APPROVED | corrective #1, #1b |
| Fit baseline | media-input `placementRect` | binding-baseline `contentRect` (aperture kept separate; slotRect clip = `block.rectCanvas` per the TVECore oracle) | APPROVED | corrective #2 (oracle `TVECore/.../SceneRenderPlan.swift:111`) |
| `slotRectAfterSettle` | resolved to the slot rect | **typed failure** until settled-slot state is represented | APPROVED | corrective #2 |
| `ResolvedFrameInput` content | pixels + placements only | also retains the selected `RenderMaterialProgram`s + scene-bindings (embedded minimal `RenderMaterialTable`); validates `AnimationReference` vs program; structurally complete entries | APPROVED | corrective #3, #8 |
| Pixel descriptor | dimensions/format only | explicit `PixelOrientation` (canonical `up` for fixtures) in the descriptor and content hash | APPROVED | corrective #5 |
| Arbitrary rotation | 90°-only, deferred to Metal | exact fixed-point CORDIC (`FixedTrig`, Q32.32, 32 iterations, golden-protected tables; no `Float`/`Double`) | APPROVED | corrective #6 |
| Render fixed-point arithmetic | 64-bit intermediates + `precondition` | full-width 128-bit multiply/divide (`FixedPointMath`) + final narrowing; no public trap path | APPROVED | corrective #7 |

The container-clip policy is resolved once into a destination-space `ResolvedClip` (`slotRect` → the
block canvas rect; `slotRectAfterSettle` → typed failure; `none` → no clip); §17 step 9 carries it
verbatim and performs no further fit/clip mathematics. Pixel-input ids coalesce only when value-identical
(a content conflict on a shared id is a typed failure). All five real templates allow all three fit
modes, so the `fitModeNotAllowed` rejection path is covered by a synthetic narrowed-fit template.

### Step-8 second corrective (Stage-7 re-REJECTED → final narrow correction; owner-approved)

| Correction | Decision | Reference |
|---|---|---|
| `MediaPlacement.identity` | no `try!`/force; built through a private unchecked init with statically-valid values | corrective-2 #1 |
| `FixedPointMath.multiplyDivideRounding` | formally requires `divisor > 0` (zero/negative → typed `nonPositiveDenominator`); result sign computed on magnitudes so `Int64.min`/`Int64.max` operands never trap | corrective-2 #2 |
| `FixedTrig.cosSin` | normalizes `rotationRaw` modulo `360_000` **before** radian conversion (so `Int64.min`/`Int64.max` reduce without avoidable overflow); validates `linearUnitsPerOne > 0`; the **entire** CORDIC table is golden-protected; periodicity + an exhaustive all-360,000-angle accuracy test are pinned | corrective-2 #3 |
| Fixture orientation | `RenderInputResolver` rejects any fixture whose orientation ≠ `.up` with a typed error (no silent re-orientation) | corrective-2 #4 |
| Program dedup | `ResolvedFrameInput` coalesces only value-identical programs; the same `RenderMaterialID` with different content is a typed `conflictingProgram` | corrective-2 #5 |
| Entry key ownership | `ResolvedSceneLayerEntry` accepts only `.sceneLayer`; `ResolvedOverlayEntry` accepts only `.overlay`; both validate at construction | corrective-2 #6 |
| **Transform contract** | `ResolvedMediaPlacement.transform` is **source-pixel space → binding-baseline LOCAL space** only; §17 step 9 composes it with the sampled binding-world and block/canvas transforms to reach canvas space. The resolver also validates `ActiveLayer.placement.frame == program.mediaGeometry.blockRectCanvas` and rejects a mismatch | corrective-2 #7 |
| Dead error cases | removed `RenderGraphError.unsupportedOverlayContent` (unused) and `RenderGraphError.conflictingPixelInput` (duplicate of `RenderModelError.conflictingPixelInput`) | corrective-2 #8 |

The overlay interval-tree query collects matches in `O(log n + k)` and then applies a deterministic
`(zIndex, stableOrdinal, overlayID)` sort (`O(k log k)`). The technical lead approved keeping
collect-then-sort because the active-overlay count `k` per frame is small in v1; the ordered-emission
structure that would restore `O(log n + k)` is intentionally not implemented.

## Known conflict with the current engine

The approved transition behavior keeps total project duration unchanged. The
current implementation compresses the timeline by half the transition duration.
The new engine must follow D-016 and D-017; it must not copy this current-engine
behavior.

## §17 step 9 — RenderGraph compilation (Stage 8; owner-fixed, implemented)

| Decision | Resolution |
|---|---|
| Media transform composition (was undefined → owner-fixed) | `local = T(position)·R(rotation)·S(scale)·T(-anchor)`; `world(child) = world(parent)·local(child)` (parent chain root→child); `finalMedia = blockToCanvas · bindingWorld · sourceToBindingLocal`. Cycle / missing parent / overflow / ambiguous binding → typed error. |
| Mask/matte scope (owner-fixed) | Step 9 structurally supports all approved modes — Mask: add/subtract/intersect (`a`/`s`/`i`); Matte: alpha/alphaInverted/luma/lumaInverted (`1`/`2`/`3`/`4`). Step 9 owns types/links/order/balance; the pixel realisation is Metal (step 10). Any other value → typed `unsupportedLayerMode`. |
| Command payloads | `RenderCommand` now carries a field-level `RenderCommandPayload` per category (resources, sampled transform/opacity, clip/mask/matte scopes, transition params, overlay placement, final conversion/output). The graph hash covers every execution-relevant payload; dictionary order never affects bytes/hash. |
| Animation time | AnimIR keyframe times are frame numbers (`RationalSourceTime`); `AnimationPlaybackTime` (240,000 ticks/s) → frame via `meta.fps`. Requests: `.sample`/`.looped`(mod authored duration)/`.holdLast`(→outPoint)/`.inactive`(no draw). Video never frozen by holdLast. |
| Easing | linear=`t`, easeInOut=`3t²−2t³`, none=cut-only (rejected if evaluated as animated). Unknown easing → typed error. Cubic-bezier keyframe easing solved by deterministic fixed-point bisection. |
| Validator | `RenderGraphValidator` independently rejects every §7.4 condition: missing/duplicate resource, invalid order, unbalanced clip/mask/scene scope, invalid surface dependency, invalid dimensions, color-profile mismatch, incomplete final output. |

Deferred specifically to Metal (§17 step 10): pixel realisation of mask add/subtract/intersect and matte alpha/luma; offscreen-surface allocation and the actual matrix multiply into final canvas space (step 9 emits the composed transform and the scene/transition/overlay structure); premultiplied source-over compositing; linear↔sRGB conversion; readback. The `colorProfileMismatch` validator branch is a defensive backstop (the colour contract is pinned to `task003`, so a real mismatch is not constructible through the public API). ADR-010 is authored at §17 step 18, not step 9.

## §17 step 9 corrective (Stage 8 REJECTED → corrective; owner-fixed, implemented)

| Correction | Resolution |
|---|---|
| #1 self-contained graph | `RenderResourceDescriptor` for a `pixelInput` retains the owned `ResolvedPixelInput` (bytes + format/orientation/colour); identity stays by content hash so the graph hash is compact. No external provider/cache/URL. |
| #2 explicit surface flow | Every pass names source/target surfaces; single scene→`linearCanvas`; transition scenes→`outgoing`/`incoming` surfaces; fade/slide read those→`linearCanvas`; overlays read+write `linearCanvas`; finalLinearToSRGB `linearCanvas`→`sRGBSurface`; finalOutput reads `sRGBSurface`. No implicit current surface. Validator enforces write-before-read. |
| #3 full program tree | Compiled from `rootCompID`, recursively expanding precomps, authored layer order, image/shape/none content, hidden/toggle respected, type↔content alignment, fail-closed on unsupported. |
| #4 asset pixels (owner-fixed) | `ResolvedFrameInput` carries authored-asset pixels keyed `(RenderMaterialID, RenderAsset.id)`; value-identical dedup by `PixelInputID`; missing → typed `missingAssetPixels`. Binding layer draws user media; other authored image layers draw asset pixels. |
| #5 sampled mask paths | `beginMask` carries a `SampledBezier` (vertices/tangents/closed) sampled at the frame; `pathID` validated against declared path resources. |
| #6 matte source rendered | The matte source is rendered into an explicit offscreen surface (cleared then source pass) and linked to its consumer with that `sourceSurfaceID`; missing/self-cyclic/non-source rejected. |
| #7 complete transforms | **Superseded by Task 004 CP4 for scene media blocks.** Scene-media `blockToCanvas` now follows the TVECore block transform: `program.meta.width/height == canvasSize` → identity, otherwise `animToInputContain(animSize: program.meta.width/height, blockRectCanvas)`. (Rev-4: anim size is read from `RenderProgramMeta.width/height`, NOT a duplicate `mediaGeometry` field.) Overlay placement still uses source-pixel→frame sizing + origin + user scale/rotation. |
| #8 animation time | `RenderLayerTiming` inPoint/outPoint/startTime applied (inactive layers skipped); `holdLast` = `outPoint − 1 frame` (last representable instant); reference/request mismatch rejected; `normalizedPosition` overflow-free via 128-bit-safe rational arithmetic. |
| #9 dense ordering | Dense unique `localCompositionOrder`/`compositionOrder` (reject duplicates+gaps); `SceneRole` validated vs body position. |
| #10 validator + self-validate | Full `graph.configuration == configuration`; plan/config agreement at compile; declaration-before-use + exact kind; write-before-read; scene id/role begin/end match; command legality in/out scopes; final source/dest chain; descriptor invariants. Compiler validates the completed graph before returning. |

Golden graph bytes/hash updated for the corrected surface-flow payload schema (#12). `holdLast` golden updated to the last representable instant. Three misleading step-9 test files were replaced by corrective tests proving full-tree expansion, exact surface consumption, matte source rendering, and mutation-sensitivity. Still deferred to Metal (step 10): pixel realisation of masks/mattes/shapes, surface allocation and the actual matrix application, source-over compositing, linear↔sRGB, readback.

## §17 step 9 second corrective (Stage 8 re-REJECTED → narrow corrective; implemented)

| # | Correction |
|---|---|
| 1 | Shapes are never silently omitted: a typed `drawShape` command carries complete sampled geometry (`SampledBezier`), fill colour components, sampled stroke and opacity; a shape mutation changes the graph bytes/hash. |
| 2 | The compiler applies `parentLayerID` chains on its own path (`worldWithinComp`), sampling each parent at its own timing/startTime; missing parents and cycles are detected by the compiler. |
| 3 | A matte samples its source's own timing/transform/opacity/parent chain; a precomp matte source renders into the **matte** surface (never `frame.target`); the matte surface id includes scene/role/material-layer/comp/source context (no collision); matte-source layers are skipped in the ordinary visible pass; the source content is actually rendered (clear + source pass), not merely linked. |
| 4 | Historical `placementMatrix` origin fix retained as a geometry helper, but scene-media block placement is **superseded by Task 004 CP4**: `RenderGraphCompiler` derives `blockToCanvas` from `program.meta.width/height` (the AnimIR anim size) and `mediaGeometry.blockRectCanvas`, matching TVECore. *(Rev-4 cleanup: the short-lived duplicate `mediaGeometry.animSize*` field was removed — anim size is canonically carried by `RenderProgramMeta.width/height`.)* |
| 5 | Resource declarations precede all use (declarations emitted first); the validator checks declaration order in a single sequential pass; `beginScene`/`endScene` do not mark a surface written; scene/transition/matte surfaces are cleared before drawing; a draw's target must equal the open scene target (or a matte surface initialised in that scene). |
| 6 | Pixel-input format is separated from render-surface profile: linear-canvas/scene/transition/matte surfaces use `configuration.intermediateProfile`; the sRGB output surface uses `finalSRGB`. The validator enforces profile/role compatibility. |
| 7 | Authored asset draws compose pixel-space → authored `RenderAsset` dimensions → world transform (fixture pixel dimensions are not assumed equal to authored dimensions). |
| 8 | `lerp`/normalized-position arithmetic is full-width; the looped-modulo drops the overflow-prone `+ d` (non-negative input); animated transition progress requires `0 <= numerator < denominator`. |

Golden surface-flow bytes/hash were already updated in the prior pass; the offscreen descriptor now also carries `surfaceProfile`. Three misleading test files from the prior pass remain replaced; new defect tests cover placement matrices, shape commands + hash mutation, compiler parent chains + cycle, precomp/shape matte sources, matte-id collision, empty scene init, the rgba16FloatLinear descriptor, and Int64 boundary arithmetic. The real-template test now asserts the exact count of authored shapes/masks/mattes is represented.

## §17 step 9 final corrective (Stage 8 re-REJECTED → narrow final fix; implemented)

| # | Correction |
|---|---|
| 1 | `sampledShape` composes every `RenderShapeGroup.groupTransform` in authored order (`T(pos)·R·S·T(-anchor)`) and the checked fixed-point product of group opacities; `SampledShape` carries `groupTransform`+`groupOpacity`, so a group transform/opacity mutation changes the graph hash. |
| 2 | `lerp` is `(lo·(u−frac) + hi·frac)/u` via `FixedPointMath.weightedSumDivide` (no `hi−lo` intermediate, only the final result range-checked); rational subtraction is a new `RationalSourceTime.subtracting` that flips a 128-bit sign flag (no `Int64.min` negation). |
| 3 | Parent transforms use `AnimationSampler.layerTransformFrame` = exact `compFrame − startTime` always, independent of the parent's visible interval (the `?? compFrame` visibility coupling is removed). |
| 4 | A matte source is compiled through the **complete layer pipeline** (`compileAnimLayer`, own timing/parent/masks/nested matte/precomp) into its surface; matte-source layers are skipped in the ordinary visible pass (no double render); the validator tracks `drawnInto` and rejects a matteLink whose source surface was only cleared. |
| 5 | New `RenderSurfaceStorageFormat` (`bgra8SRGB`/`rgba16FloatLinear`); an offscreen descriptor carries the storage the profile implies — an `rgba16FloatLinear` surface is never labelled BGRA8; the validator enforces exact profile↔storage compatibility. |
| 6 | `assetSizing` has no identity fallback: a missing `RenderAsset` or non-positive authored dimensions is a typed `missingAuthoredAsset` error. |

Still deferred to Metal (step 10): pixel realisation of shapes (fill/stroke), masks/mattes; surface allocation and the actual matrix application + compositing; linear↔sRGB; readback. Step 9 emits the complete structure (sampled geometry/group transforms/paths/shapes, explicit surface flow + storage, scopes, real matte-source render passes) and validates it.

## §17 step 9 — final micro-correction (Stage-8 gate, no Metal / no step 10)

| # | Decision |
|---|----------|
| M1 | `RenderResourceDescriptor` carries an **optional** `pixelFormat: PixelByteFormat?`, present only for a `pixelInput` (its input byte format) and **`nil` for an `offscreen`** surface. An offscreen is described unambiguously by `surfaceProfile` + `surfaceStorage` alone; its canonical encoding emits `"pixelFormat":"n/a"` and never `"format":"bgra8"`, so an `rgba16FloatLinear` surface is never mislabelled with a BGRA8 byte format. The validator enforces the invariant: `pixelInput` ⇒ `pixelFormat != nil` & no surface profile/storage; `offscreen` ⇒ `pixelFormat == nil`. A new golden test pins the descriptor canonical bytes. |
| M2 | The parent-timing proof test samples a parent with **non-zero `startTime` (3)** and a **keyframed** X track (linear 0→200pt over frames 0→20), with `compFrame = 13` **outside** the parent's visible interval `[0,5)`; it asserts the child's world x = `200pt·(13−3)/20 = 100pt` exactly — distinguishing `compFrame − startTime` (=10 → 100pt) from `compFrame` (=13 → 130pt). |
| M3 | Explicit matte-chain cycle detection: `compileAnimLayer` threads a per-chain `matteChain: Set<Int>`; a source already present in the chain (e.g. A→B→A) is a typed `matteCycle`, caught independently of the depth-64 backstop. A real nested-matte test (consumer 1 → source 2 → source 3) verifies two distinct matte surfaces, two source render passes, two matte links and inner-before-outer ordering. |

## §17 step 11 — masks, mattes, authored shapes (Rev-4 FINAL, device-verified)

Step 11 makes the Step-9 graph execution-complete for authored fills/strokes, masks, and mattes on the
Metal executor — without importing the legacy engine and without a CPU renderer. Implemented exactly to
`Docs/AnimiEngineNext/claude-task-003-step-11-plan.md` (Revision 4). Verified on the physical iPhone 13 Pro
(`iPhone14,2`, Apple A15 GPU, iOS 26.5 / build 23F77).

| # | Decision |
|---|----------|
| S1 | **Producer mesh vs control path are distinct data.** Control Béziers stay in `SampledBezier`; fills/masks consume a separately sampled `SampledPathMesh` (producer-flattened `keyframePositions` + producer triangle `indices`); strokes consume the sampled producer polyline. Producer indices are NEVER attached to `SampledBezier`. New `PathResourceSampler` samples `keyframePositions` at an exact `RationalSourceTime` (hold/easing via `CubicBezierSampler`, full-width checked fixed-point, `positions.count == vertexCount*2`, indices revalidated). The compiler frame retains `pathResourcesByID`. |
| S2 | **Fill rule is producer-baked.** The compiled format stores triangles, not a fill-rule tag; the producer Earcut-triangulated with the rule already applied, so Metal never recomputes winding. The mandatory audit (30 authored JSON / 25 `fill.r==1` / 0 `fill.r==2` / 18 strokes all `lc==1`/`lj==1`) was verified before code changes; `fill.r==2` is a STOP condition (did not occur). |
| S3 | **Deterministic stroke meshing in the graph.** New `FixedVectorMath` (checked sub/add/dot/cross, 128-bit integer `isqrt`, rounded length, perpendicular half-width offset, line intersection, division-free miter-limit) + `StrokeMeshBuilder` (segment quads; butt/square/round caps; miter/round/bevel joins with miter-limit→bevel fallback; one fixed 1°-step round tessellation via `FixedTrig.cosSin` with offset-vector rotation + cross-sign sweep termination; path-local width → anisotropic under non-uniform transform; exact 180° reversal and degenerate/over-wide rejected typed). No new general triangulator; Metal builds no stroke geometry. |
| S4 | **Explicit mask group + matte isolation.** `beginMask(operations, contentSurfaceID, targetSurfaceID)` / `endMask(...)` replaces per-mask nesting: the whole layer contribution is isolated in a target-cloned content surface and masked once. `matteLink(mode, sourceLayerID, consumerLayerID, sourceSurfaceID, consumerSurfaceID, targetSurfaceID)` isolates BOTH source and consumer in target-cloned surfaces, links after both render. `CompileContext.declareIntermediateSurfaceLike` clones the real target descriptor (width/height/profile/storage) — never precomp dims. New validator checks: nonempty ops, closed meshes, declare/clear/write/read order, descriptor match, no aliasing, three distinct matte surfaces. New `RenderGraphError` cases: `missingPathResource`, `pathResourceMismatch`, `unsupportedStrokeGeometry`, `validatorSurfaceDescriptorMismatch`, `validatorSurfaceAlias`. |
| S5 | **Metal pixel contract.** 4× MSAA `r16Float` coverage (constant 1.0, blending disabled) resolved to single-sample (exact fractions 0/0.25/0.5/0.75/1.0); fill/stroke colour applied once after resolve (sRGB→linear, premultiplied source-over); overlapping triangles do not multiply colour. Mask combine reproduces the read-only TVECore oracle exactly (init add→0/sub→1/int→1; add=max, subtract=acc·(1−cov), intersect=min; order clamp→invert→opacity→mode) via two ping-pong `r16Float` accumulators; aggregate modulates premultiplied rgb AND alpha. Matte coverage = source alpha or **Rec.709 linear luma** (`0.2126R+0.7152G+0.0722B`), source already premultiplied so **no unpremultiply** (transparent-bright luma → zero coverage). One command buffer / one wait preserved. `device.supportsTextureSampleCount(4)` required at session construction (`MetalRenderError.requiredSampleCountUnsupported`); no fallback. After Step 11 only `fadeTransition`/`slideTransition`/`overlay` remain Step-12 deferred. |
| S6 | **Public API change stated truthfully.** `RenderCommandPayload`, `SampledShape`, `SampledStroke`, the new `SampledPathMesh`/`SampledTriangleMesh`/`SampledSRGBAColor`/`SampledMaskOperation` and stroke enums are public RenderModel API — changed intentionally; canonical bytes/golden hashes re-baked deliberately. `MetalRenderSession.execute(RenderGraph) -> RenderedFrame` public surface unchanged. Producer fill/stroke colour is RGB(3) or RGBA(4) — `SampledSRGBAColor(components:)` accepts both (3-component ⇒ implicit alpha 1.0; real alpha flows through fill/stroke opacity per the effective-style-alpha formula). |

## §17 step 11 — Final Corrective Pass (device-verified)

| # | Decision |
|---|----------|
| C1 | **No RGB→RGBA coercion in RenderModel.** `SampledSRGBAColor(components:)` accepts exactly four explicit `[r,g,b,a]`; any other count is `RenderModelError.unsupportedValue` (no fallback, no implicit alpha). Arity reconciliation is the adapter's job: `RenderGraphCompiler.fillSRGBA` requires exactly 4 (producer fill is RGBA); `RenderGraphCompiler.strokeSRGBA` requires exactly 3 (producer stroke is RGB) and sets `alpha = .one` explicitly, the authored stroke alpha flowing through stroke opacity. Both reject any other count typed. The audit across all five compiled.tve confirms the baseline: **25 fills = RGBA(4), 18 strokes = RGB(3)** (`RealTemplateGraphTests.testAuthoredFillStrokeColorArityBaseline`). Negative tests: fill RGB(3)/5 and stroke RGBA(4)/2 rejected (`RenderGraphCompilerCorrectiveTests`), and `SampledSRGBAColor` rejects every non-4 count. No canonical bytes changed (valid programs are unaffected; only malformed-colour rejection tightened). |
| C2 | **Rev-4 Metal matrix closed with real device pixel tests** (`MaskMatteShapeTests`): intersect-as-first (seed 1), authored `add→subtract ≠ subtract→add`, `invert→opacity→mode` ordering (inverted×0.5), nested mask groups, multiple draws masked once as a single contribution, translated+rotated mask, alphaInverted + lumaInverted mattes, stroke caps/joins/interior-exact/bounded-AA edges, 4× coverage quantization (0/0.25/0.5/0.75/1 quarter-steps), and transient-resource release after an injected command-buffer failure. The combined frame test genuinely contains drawShape + mask group + matteLink and asserts pixel result, bytes, and `rawOutputHash` repeatability. |

## §17 step 12 — cut, fade, slide, overlay execution (device-verified)

Step 12 adds Metal pixel execution for transitions and overlays, leaving the Step-9 graph and validator
unchanged (execution-only; no payload/value/canonical change). Implemented to
`Docs/AnimiEngineNext/claude-task-003-step-12-plan.md` (Rev 1) with R1–R6 as approved. Verified on the
physical iPhone 13 Pro (`iPhone14,2`, Apple A15 GPU, iOS 26.5 / 23F77).

| # | Decision |
|---|----------|
| T1 | **Cut** is unchanged (single scene → linearCanvas, executed since Step 10); Step 12 adds only a structural test (`.single` body emits no transition command) and a device cut frame. |
| T2 | **Fade** (R1/R3) — a single self-contained full-surface `.replace` pass (`fade_fragment`): `mix(outgoing, incoming, p)` on premultiplied RGBA in linear light. p=0 → outgoing, p=1 → incoming. The graph's eased `UnitInterval` drives `p`; the half-open progress invariant `0 ≤ num < den` is unchanged, so the evaluator never emits p=1 — `fade p=1` is proven only as a direct executor/shader boundary test using `UnitInterval.one`. |
| T3 | **Slide** (R1/R2/R3) — a single self-contained `.replace` pass (`slide_fragment`): the incoming surface, sampled shifted by the graph's exact canvas-raw offset (converted to a normalized-UV `float2` only at the shader boundary), composited premultiplied source-over a **stationary, still-animating** outgoing surface. Off-edge incoming samples are transparent via the clampToZero sampler. The outgoing does NOT translate (it keeps animating). |
| T4 | **Overlay** — reuses the existing `drawImage` path (image PSO, normalized overlay texture, opacity, premultiplied source-over) targeting `linearCanvas`, in graph `compositionOrder`, **above the body and before** the single final linear→sRGB conversion (graph-enforced ordering). No new overlay shader/pipeline. |
| T5 | **No graph/validator/canonical change** — the three command payloads, the compiler, and the validator are untouched; no golden re-bake (golden suite green unchanged). The executor classifier now returns `nil` for all categories (none deferred); `MetalResourceOwnershipTests` migrated from "rejected" to "executes". New `MetalTransitionCompositor` + two new fragments/PSOs (`fade`/`slide`, `.replace`, both intermediate formats, created at session construction). One command buffer / one wait, transient ownership, and final conversion last all preserved. |

## §17 step 13 — candidate generation, comparison, diff, contact sheet, evidence recording (device-verified)

Step 13 adds candidate-frame evidence on top of the Task-001 transactional run system, in the non-product
`AnimiEngineRenderTestSupport` target (no shipping product touched, no `Package.swift`/project change).
Implemented to `Docs/AnimiEngineNext/claude-task-003-step-13-plan.md` (Rev 1) with D1–D8 as approved (D7
override: device evidence now). Verified on the physical iPhone 13 Pro (`iPhone14,2`, A15, iOS 26.5 / 23F77).

| # | Decision |
|---|----------|
| E1 | **Deterministic PNG (D1)** — `DeterministicPNGEncoder`: BGRA8→RGBA8, scanline filter 0, **stored (uncompressed) DEFLATE** blocks, hand CRC-32 + Adler-32. No CoreGraphics/ImageIO. Identical pixels → byte-identical PNG (the property the transactional evidence aggregate-hash relies on). A matching minimal stored-block reader decodes our own references; any other PNG form is a typed `unsupported` error (no silent fallback). |
| E2 | **Deterministic candidate identity (constraint 6)** — `CandidateIdentity.candidateID` is a pure function of provenance (catalog/block/variant/projectTime), a sanitized `cat__blk__var__tN` slug; never a UUID or wall-clock. Distinct provenances never collide; the id is a valid `SupplementalArtifactPath` component. |
| E3 | **Comparison (D3/D4)** — `FrameComparator`: exact (byte-identical + equal hash) / withinBounds / outOfBounds / candidateOnly, using ONLY deterministic integer metrics (max per-channel delta + differing-pixel count) against pinned tolerances. `outOfBounds` records the verdict; it does NOT auto-fail the run (D4). No floating perceptual metric. |
| E4 | **Diff (D2)** — `DiffImage`: absolute per-channel delta `min(255, |c−r|·amp)` (black where equal), `amp` recorded in the comparison JSON; a pure deterministic function of its inputs. `ContactSheet`: a deterministic grid of candidate \| reference \| diff tiles. |
| E5 | **Reference behavior (D5; constraints 2/5)** — `ReferenceStore` is **READ-ONLY**: it has no write path; it reads an approved reference (keyed by candidateID) if present, snapshots it into the run as evidence, and the approved reference root is **byte-identical before/after a run** (proven). Missing reference → candidateOnly. `ReferenceApproval` stays the empty stub — no promotion, no approval schema. |
| E6 | **Transactional recording (constraints 4/5)** — `EvidenceRecorder` writes EVERY artifact (candidate/reference-snapshot/diff PNGs, comparison JSON, contact sheet, `render-manifest.json`) through `BenchmarkRun.writeSupplementalArtifact`; the run's `run-manifest.json` remains the manifest-last commit marker over the supplemental aggregate. An injected FS fault poisons the run and publishes nothing. Step-13 typed errors only (D6: PNG/diff/comparison/contact-sheet/recorder cases). |
| E7 | **Device evidence (D7 override)** — the iPhone 13 Pro gate gains `testStep13CandidatePNGEvidenceOnDevice`: a device-rendered frame is encoded to a deterministic PNG (byte-identical across encodes and across re-renders) and recorded as a device-evidence attachment. No comparison/promotion on device. The PNG encode is inlined in the editable host test source because the DeviceGateHost project links only `AnimiEngineMetalRender` and its project structure must not change (D8/constraint 3). |
| E8 | **No canonical/golden re-bake** — Step 13 adds artifacts only; RenderModel/graph canonical bytes and goldens are unchanged. References are never promoted; Step 14 not started. |

## §17 step 14 — complete real-template/frame matrix + structural fixtures (device-verified)

Step 14 runs every authored (catalog, block, variant) of the five real templates crossed with a
deterministic frame-time set, plus structural fixtures for cases real templates lack, recording all
candidate artifacts through the Step-13 evidence recorder into ONE transactional `BenchmarkRun`.
Implemented to `Docs/AnimiEngineNext/claude-task-003-step-14-plan.md` (Rev 1) with D1–D7 as approved.
Device-verified on iPhone 13 Pro (`iPhone14,2`, A15, iOS 26.5 / 23F77). All in the non-product
`AnimiEngineRenderTestSupport` + `AnimiEngineMetalRenderTests`; no `Package.swift`/project change.

| # | Decision |
|---|----------|
| X1 | **Inventory STOP-check (constraint 8)** — `RealTemplateMatrix.enumerateRows` re-verifies the baseline 5 catalogs / 14 blocks / 25 (block,variant) pairs and throws `inventoryMismatch` otherwise. Verified: matches exactly. |
| X2 | **Deterministic matrix (constraint 6)** — every row is `(catalog, block, variant, projectTimeTicks, frameKind)` in fixed authored order; frame-time set per row = {tick0, mid, last-representable, post-roll-if-capable} (D2). Real templates have postRoll 0 → {tick0, mid, last} = 3 times → 25×3 = **75 enumerated real rows**. Candidate ids derive only from provenance; GLOBAL uniqueness is enforced (constraint 7 STOP on collision). |
| X3 | **Authored-timing skips** — ⚠️ **SUPERSEDED by CP7.5 (2026-06-20).** *OLD policy:* a row whose selected variant has a matte source that is timing-inactive at a chosen frame time was deterministically SKIPPED (typed `unsupportedLayerMode("matte source is timing-inactive"/"hidden")`). *NEW policy:* a matte SOURCE bypasses the visible/timing/hidden gates and renders HELD at its last authored frame (TVECore oracle parity — `AnimIR.emitLayerForMatteSource`→`computeLayerWorld` applies no isVisible/isHidden check). The formerly-skipped `example_4blocks` mid/last rows are therefore now REAL candidates (the source is held, so the consumer stays matted/visible). **Candidate count is now 84** (was 64; +20 matte-held rows, promoted from run `6137C324-1B97-4978-9B34-7D90D9CF483C`). Any row that still legitimately skips must NOT rely on matte-source timing-inactive behavior unless separately justified. Row accounting `realRowCount + skippedRowCount == enumeratedRowCount` still holds; any other compile error is a STOP (`rowCompileFailed`). |
| X4 | **Structural fixtures (D4)** — 9 deterministic hand-built graphs with synthetic `synthetic-*` catalog ids: fade, slide, overlay, mask, matte, shape+stroke, **video exact-rational 30000/1001** (`drawVideoFrame`), post-roll holdLast, boundary. The post-roll frame equals the boundary (last-instant) frame (holdLast). |
| X5 | **Grouped recording, one run (D1)** — `MatrixDriver` records each catalog as a group and the structural fixtures as one group, all into a single `BenchmarkRun` via `EvidenceRecorder.recordGroup` (group-prefixed paths, non-closing); the run is closed once. Each group writes its own `<group>/contact-sheet.png` + `<group>/render-manifest.json`; the run's `run-manifest.json` remains the manifest-last commit over the aggregate. Contact-sheet tiles are deterministic bounded thumbnails (nearest-neighbor, ≤64px) so full-resolution candidate PNGs stay the real evidence while sheets stay small. |
| X6 | **Reference policy (D3/D7; constraints 2/5)** — `ReferenceStore` READ-ONLY; no approved reference exists yet → every row's default verdict is `candidateOnly`; `outOfBounds` (when references exist) is record-only, never gates the run; the approved reference root is byte-identical before/after a run; no promotion. |
| X7 | **Transactional preservation** — all artifact writes via `BenchmarkRun.writeSupplementalArtifact`; an injected fault poisons the matrix run and publishes nothing; manifest-last intact. New Step-14 typed errors only where needed (`RealTemplateMatrix.MatrixError`, `MatrixDriver.DriverError`). No canonical/golden re-bake. |
| X8 | **Device subset (D5)** — the iPhone 13 Pro gate gains `testStep14MatrixSubsetCandidateEvidenceOnDevice`: one real-content row (single-image scene) + one structural fixture (fade), each rendered on device and encoded to a deterministic candidate PNG recorded as evidence. No comparison/promotion on device. The host links only `AnimiEngineMetalRender` (no TemplateAdapter), so the device "real row" uses real-content graph shape, not a compiled.tve decode (which would need a forbidden project change). |

## §17 step 15 — produce a sealed candidate-reference benchmark run

Implemented to `Docs/AnimiEngineNext/claude-task-003-step-15-plan.md` with D1–D7 as approved.

| # | Decision |
|---|----------|
| Y1 | **Producer entrypoint (D1/D2)** — `Step15SealedRunTests.testProduceSealedCandidateReferenceRun` drives the accepted `MatrixDriver` into ONE `BenchmarkRun` wired with production seams (`UUIDRunIDGenerator`, `SystemWallClock`, `SystemMonotonicClock`, `DefaultRunFileSystem`). Default `swift test` → temp root; `ANIMI_STEP15_DURABLE_ROOT=1` → durable `AnimiEngineNext/.benchmark-runs/` (gitignored, D3). No `Package.swift`/project change. |
| Y2 | **Sealed contract** — run closed `.sealed` status success; `run-manifest.json` last; `supplementalArtifactsSHA256` covers all matrix artifacts; no `.<runID>.staging` remains. Candidate count == **64** (55 real + 9 structural; mismatch is STOP). `referenceStore: nil` → all candidateOnly; no references/diffs. Device provenance honest (M2Pro/macOS). |
| Y3 | **D7-b device subset = STOP #8 (owner: M2-Pro-only)** — the DeviceGateHost target links only `AnimiEngineMetalRender`, not `AnimiEngineDiagnostics`(`BenchmarkRun`)/`AnimiEngineRenderTestSupport`; a device sealed run would need a forbidden pbxproj product-dep. Owner chose M2-Pro-only; no device sealed subset. |

## §17 step 16 — human review + precomp/parent-opacity corrective fix

Step-16 review of the first sealed run (`2E4AED19…`) found a CONFIRMED render bug, fixed under owner approval; a new sealed run (`694A5886…`) was produced and APPROVED.

| # | Decision |
|---|----------|
| Z1 | **Bug: precomp/parent opacity dropped** — `RenderGraphCompiler.expandComposition` threaded `parentWorld` (transform) but not opacity, so a precomp/parent layer's opacity (incl. authored opacity keyframes) was discarded at the precomp boundary. Diagnosed read-only via temporary probes (transform animation worked; opacity did not). |
| Z2 | **Fix (behavioral only)** — added `parentOpacity: OpacityScalar` to `expandComposition`; new `opacityWithinComp` accumulates a layer's opacity along its parent chain (symmetric to `worldWithinComp`); `compileAnimLayer` uses it; the `.precomp` branch passes the precomp layer's accumulated opacity as the subtree's `parentOpacity`. Child draw opacity = parentChain × layer (checked fixed-point). **No RenderModel/canonical/payload/golden change** (805 tests pass; no golden re-bake). |
| Z3 | **Regression + targeted tests** — `PrecompParentOpacityTests` (precomp opacity 0→transparent, full→opaque, 0.5→scaled, keyframe interpolates, null-parent inherited); `Step16RealTemplateOpacityTests` (example_4blocks v4@t0 adds opacity-0 draw vs no-anim + hash differs; v1/v3@t0 too). |
| Z4 | **New sealed run `694A5886…`** — re-produced after the fix; aggregate `6137fe02…`; 64 candidates; 6 expected-transparent first frames (scale-from-zero / opacity fade-in / slide-in). Old `2E4AED19…` = rejected/obsolete (kept untouched). Step-16 v2 packet APPROVED; 0 static/no-anim blanks; manifest aggregate consistent; no refs/diffs/promotion. |

## §17 step 17 — guarded reference promotion

Implemented to `Docs/AnimiEngineNext/claude-task-003-step-17-plan.md` with D1/D2/D4/D6 as approved.

| # | Decision |
|---|----------|
| W1 | **Guarded promoter** — new `ReferencePromoter` (non-product `AnimiEngineRenderTestSupport`): guards G1–G9 (source status success; aggregate == `artifacts-manifest`; runID == approved `694A5886…` [rejects obsolete `2E4AED19…`]; count == 64; no references/diffs in source; all candidateOnly; per-file integrity [PNG sha vs artifacts-manifest AND decoded `rawOutputHash` vs render-manifest]; dirty-root; no overwrite unless byte-identical). Promotes ONLY the approved run; never renders/blesses; sealed run read-only. |
| W2 | **Transactional + git-reversible (D5)** — staging → atomic publish (`FileManager` atomic rename / `replaceItemAt`; `RunFileSystem` is package-scoped in Diagnostics, not visible from RenderTestSupport). On any failure the approved root is byte-identical. Idempotent same-byte re-promotion = no-op. **No auto-commit** — files written for the owner to commit; `git revert`/`checkout` reverses. |
| W3 | **Destination (D1/D7) + manifest (D4)** — flat `AnimiEngineNext/ReferenceData/references/<candidateID>.png` (64; matches `ReferenceStore.referenceURL`) + `approval-manifest.json` (canonical, self-hash `approvalManifestSHA256` last; `approvedAtISO8601`/`approvedBy` in body only, never affect PNG bytes). Committed (not gitignored). |
| W4 | **Entrypoint (D2) + ReferenceApproval (D6)** — guarded XCTest `Step17PromoteReferencesTests.testPromoteApprovedSealedRun`, env-gated `ANIMI_STEP17_PROMOTE=1` (else dry-run). `ReferenceApproval` given a minimal read-only typed `load(rootURL:)` model only (no workflow/UI/states). `ReferenceStore` gains `decodeForPromotion`. No `Package.swift`/pbxproj/canonical/Metal change. |
| W5 | **Verified** — 10 Step-17 tests pass (P-1 dry-run 64 / P-2 wrong runID / P-3 missing / P-4 changed bytes / P-5 idempotent / P-6 root-unchanged-on-failure / P-7 post-promotion exactMatch / P-8 no-self-blessing / P-9 manifest integrity). Opt-in promotion wrote 64 refs + manifest (`2aceb710…`). **Matrix rerun against the approved refs = 64/64 exactMatch, 0 non-exact.** Step 18 not started. |

## §17 step 18 — control documentation, ADR closure, implementation report (TASK 003 CLOSED)

Documentation/control/evidence only — no render/canonical/Metal change, no approved-reference/sealed-run
modification, no auto-commit. Implemented to `Docs/AnimiEngineNext/claude-task-003-step-18-plan.md` with
D1–D4 as approved.

| # | Decision |
|---|----------|
| V1 | **ADR placement (D1)** — the §17 "ADR-010" deliverable is a "Reference Promotion & Comparison Closure" section added to **`ADR-014`** (the topically correct diagnostics/evidence/comparison ADR). **No phantom `ADR-010` file** was created; the numbering mismatch is explained in the implementation report. |
| V2 | **Implementation report (D4)** — `Docs/AnimiEngineNext/claude-task-003-implementation-report.md`: steps 1–17, architecture decisions, honest deviations (ADR numbering; Step-14 device real-content shape; Step-15 D7-b M2-Pro-only; Step-16 opacity-bug fix + rejected run), final approved run `694A5886…` + manifest hashes, device-evidence summary (Steps 10–12, NOT re-run, D2), test counts, all run IDs, known limitations, G1–G9 mapping, audit results. |
| V3 | **Audits (read-only)** — forbidden-tree byte-identical to Step-15 (`a23d7cda…`); `Package.swift` (`da4ebf24…`) + 3 pbxproj unchanged; dependency-boundary tests pass; ReferenceData 64 PNG + manifest (tree `be021df5…`); approved run `694A5886…` (`6137fe02…`) + obsolete `2E4AED19…` (`3bfb2be3…`) untouched; no Task-004. |
| V4 | **Final verification** — `swift build` clean; full `swift test` **815 / 1 skip / 0 fail**; matrix exactMatch vs approved refs **64/64** (D3 temporary probe, deleted after — no regeneration/promotion/reference writes). **Step 19 / Task 004 NOT started.** |

## Task 004 — CP4 geometry/matte canonical cleanup (Rev-4)

| # | Decision |
|---|----------|
| C4-1 | **Anim size is single-source in `RenderProgramMeta.width/height`.** The short-lived Rev-3 duplicate `RenderMediaGeometry.animSizeWidth/animSizeHeight` (same `animIR.meta.size`) was REMOVED, with its canonical encoding entries and converter population. `RenderGraphCompiler.compileSceneLayer` reads anim size from `program.meta.width/height`: `== canvasSize` → identity `blockToCanvas`, else `animToInputContain(animSize: program.meta.width/height, blockRectCanvas)`. TVECore semantics unchanged; no new schema field. |
| C4-2 | **Group-opacity contract retained.** Shape group-transform opacity = unit 0…1 (`opacityUnitTrack`); layer/fill/mask opacity = percent 0…100. |
| C4-3 | **Parenting-opacity contract retained.** Layer parenting affects transform only; opacity propagates ONLY through the precomp container (`parentOpacity`), per AE/Lottie/TVECore (`AnimIR.computeWorldTransform`). |
| C4-4 | **Canonical hash changed; pixel output did not.** Golden material hash re-pinned to `78599fefe12714fc419a15ea0b418c8b0ad2fb356295b101caec65dc58155822` after removing duplicate `mediaGeometry.animSize*`. `PostPromotionMatrixRegressionTests` remains **64/64 exactMatch** because render pixels are byte-identical to the already promoted CP4 ReferenceData (`58E9FD0A…`). No ReferenceData re-promotion is required by this corrective pass; ReferenceData remains the previously approved CP4 set. |
