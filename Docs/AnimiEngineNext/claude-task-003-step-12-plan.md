# Task 003 / Step 12 — Implementation Plan: cut, fade, slide, overlay execution

**Revision:** 1 — PLAN ONLY; awaiting owner approval.
**Status:** NOT IMPLEMENTED. This planning pass creates exactly one file (this plan). No engine code, no
test, no `Package.swift`, no `*.xcodeproj`/`*.pbxproj`, and no forbidden path is modified. No evidence /
reference workflow is started.
**Scope gate:** Task 003 §17 step 12 — *"Add cut, fade, slide and overlay execution."* Pixel realization on
the Metal executor of `fadeTransition`, `slideTransition`, and `overlay`; cut (single-scene) is already
executed by Step 10 and is verified, not re-implemented.
**Predecessor:** Step 11 (masks/mattes/shapes) — closed and device-verified (iPhone 13 Pro, `iPhone14,2`,
Apple A15 GPU, iOS 26.5 / 23F77). macOS `swift test` 761 / 1 skip / 0 fail.
**Approved invariants carried forward (Step 10/11):** one command buffer, one wait; explicit surface flow
(no implicit current surface); normalize-before-scenes; linear-premultiplied source-over; fixed-function
premultiplied blend; final linear→sRGB last; no CPU renderer; no silent substitution; typed errors only;
checked fixed-point geometry; per-execution resource ownership released at completion.

Implementation must not begin until the owner approves this plan and instructs Claude Code to start.

---

## 0. Decision classification key

- **[FIXED]** — pinned by an approved contract (Step-9 graph structure, decision register, Step-10/11
  invariants) or by committed code (verified at plan time, file:line cited).
- **[DERIVED]** — necessarily follows from a FIXED contract / existing code; no new product decision.
- **[CONTRACT CHANGE]** — a deliberate change to a committed RenderModel/RenderGraph value type; re-bakes
  canonical bytes + golden hashes. **Step 12 introduces NONE** (§6) unless an owner decision in §11 forces it.
- **[OPEN]** — a genuinely unresolved decision needing an explicit owner answer before implementation (§11).

---

## 1. Current-state audit (verified in code)

### 1.1 The graph ALREADY emits all three Step-12 commands — [FIXED]

Step 9 is execution-complete for transitions and overlays; only the Metal pixel realization is deferred.

- **Body dispatch** (`RenderGraphCompiler.swift` L53–77):
  - `.single(subplan)` (the **cut**) → one scene compiled directly into `RenderSurface.linearCanvas`.
  - `.transition(transition)` → declares `surface\u{1F}outgoing\u{1F}<sceneID>` and
    `surface\u{1F}incoming\u{1F}<sceneID>` (both intermediate profile, canvas-sized); compiles **both
    complete scenes** into their own surfaces (the outgoing scene continues rendering through the window,
    §7.3 / architecture-proposal L44/L338); then `TransitionGraphBuilder.emitTransition` composites them into
    `linearCanvas`.
- **`TransitionGraphBuilder.emitTransition`** (`TransitionGraphBuilder.swift` L14–39): emits
  - `fadeTransition(easedProgress, outgoingSurfaceID, incomingSurfaceID, targetSurfaceID)`, or
  - `slideTransition(direction, easedProgress, offsetX, offsetY, outgoingSurfaceID, incomingSurfaceID,
    targetSurfaceID)`.
  Easing is already resolved in the graph (`TransitionEasing`: `linear` ⇒ `t`; `easeInOut` ⇒ `3t²−2t³`
  smoothstep; `none` is cut-only and never reaches an animated transition). The slide **offset** is already
  computed: at eased progress `p` the incoming surface offset is `(1−p)·extent` along the entry axis
  (`slideOffset`, L53–67), negative for `.left`/`.up`, positive for `.right`/`.down`.
- **`OverlayGraphBuilder.build`** (`OverlayGraphBuilder.swift` L14–36): after the body, in **dense unique
  `compositionOrder`**, emits `overlay(resourceID, transform, opacity:.opaque, compositionOrder,
  targetSurfaceID: linearCanvas)` for each overlay, with the source-pixel→frame sizing transform; an active
  overlay animation or a missing pixel is a typed failure.
- **Final chain** (`RenderGraphCompiler.swift` L83–84): `finalLinearToSRGB(linearCanvas → sRGB)` then
  `finalOutput(sRGB)`.

### 1.2 The validator ALREADY enforces the surface flow — [FIXED]

`RenderGraphValidator` (single sequential pass) enforces for all three (`RenderGraphValidator.swift`):
- `fadeTransition` / `slideTransition` (L284–290): `stack.isEmpty` (not inside any scene/clip/mask scope);
  `requireWritten(outgoing)`; `requireWritten(incoming)`; `requireSurface(target)`; then `written.insert(target)`.
- `overlay` (L280–282): `stack.isEmpty`; `requirePixel(resourceID)` (must be a `pixelInput`, not an
  offscreen); `requireWritten(target)`; then `written.insert(target)`.
- Final-chain exactness (L55–72): exactly one `finalLinearToSRGB` (reads `linearCanvas`, writes `sRGB`)
  immediately followed by exactly one `finalOutput` (reads `sRGB`), as the last two commands.
- "written" = a surface that received an actual draw/composite; "drawnInto" is tracked for matte sources
  (Step 11) but transitions/overlays only require `requireWritten`.

So Step 12 **does not** add or change graph emission or validation. It adds Metal execution only.

### 1.3 The Metal executor currently REJECTS all three — [FIXED]

- `MetalSceneCompositor.unsupportedCommand(for:)` (`MetalSceneCompositor.swift` L17–32): returns
  `(category, 12)` for `.fadeTransition` / `.slideTransition` / `.overlay`; `nil` for everything else
  (Step 10/11 categories are supported).
- `MetalGraphExecutor.metalPreflight` (L170–174): the classifier path throws
  `MetalRenderError.unsupportedCommand(category:, step: 12, …)` **before any GPU work**; an explicit
  unreachable case (L224–228) fails closed.
- `MetalGraphExecutor.encodeRenderWork` (L375–379): `case .fadeTransition, .slideTransition, .overlay`
  throws `unsupportedCommand(step: 12)`.

### 1.4 The execution model Step 12 extends — [FIXED]

- Whole-frame sequence (`execute`): preflight → allocate textures/surfaces → one command buffer → upload
  blits → normalization passes → `encodeRenderWork` → readback blit last → one commit, one wait.
- Surface-flow helpers in `encodeRenderWork`: `clearSurface(id)` (own `.clear` pass), `openSceneEncoder` /
  `ensureEncoder` (`.load`/`.store` retargetable scene encoder), `endEncoderIfOpen` (closes before a
  multi-pass op). Step-11 shape/mask/matte already end the open encoder and run their own passes — the
  same pattern Step-12 commands use.
- **`MetalColorConverter`** (`MetalColorConverter.swift`, whole file) is the canonical **full-surface
  composite pass** template: a `fullscreen_vertex` + fragment pass that reads source texture(s) with the
  bilinear clamp-to-zero sampler and writes a target, used today for `finalLinearToSRGB`. Fade/slide/overlay
  are structurally the same kind of full-surface pass.
- **`MetalPipelineLibrary`** creates all PSOs at construction (no lazy creation in `execute`); the existing
  `makeApplyPipeline(fragment:format:detail:)` builds a `fullscreen_vertex` + fragment PSO with
  fixed-function **premultiplied source-over** for `.rgba16Float` and `.bgra8Unorm_srgb`. The bilinear
  `clampToZero` sampler is shared.
- **`MetalTextureAllocator.makeOffscreenTexture`** allocates `.private` `[.renderTarget, .shaderRead]`
  surfaces; the outgoing/incoming surfaces are already so allocated by the existing offscreen path. No new
  texture kind is required (slide samples a translated UV of an existing surface; clampToZero gives
  transparent off-edge).

### 1.5 What is already TESTED at the graph level — [FIXED]

`TransitionAndValidatorCorrectiveTests`: fade scenes write the exact consumed surfaces; slide every
direction; outgoing scene continues rendering; missing slide direction rejected; unsupported effect
rejected; validator read-before-write / config / profile / draw-outside-scene rejections.
`Step9CorrectiveDefectTests`: empty transition scene surface still cleared; transition progress `0 ≤ p < 1`.
`MetalResourceOwnershipTests.testReachableDeferredFamiliesRejectedByExecutor` builds validator-valid
fade / slide / overlay graphs that the **executor currently rejects** — these are exactly the graphs Step 12
must instead **execute** (so that test migrates from "rejected" to "executed", §7).

### 1.6 Real-template coverage reality — [FIXED, drives §7.5 + §11-R3]

All five real compiled templates produce a **`.single` body** (cut) only
(`RealTemplateGraphTests` asserts `case .single`). Transitions are produced by `TimelineEvaluator`
(`buildTransition`) only when an active transition window exists; **no real fixture has two scenes with a
transition**. Overlays: the real templates' overlay coverage is whatever the catalog payloads carry (the
overlay path is exercised by `RealTemplateGraphTests` compilation, but no real overlay *pixel* output has
been device-verified). The plan therefore distinguishes **real-template** coverage (cut + any real overlays)
from **synthetic-but-faithful** coverage (fade/slide between two real scenes assembled in a test), and states
this honestly (no overstated "real" claim).

---

## 2. Exact Step 12 scope and explicit non-scope

### 2.1 In scope — [FIXED]

Metal pixel execution, preserving every Step-10/11 invariant, of:

1. **Cut** — already executed (single scene → `linearCanvas`). Step 12 adds **explicit verification** that a
   cut frame is correct/repeatable on device (no code change for the cut path) and a structural test that a
   `.single` body emits no transition command.
2. **`fadeTransition`** — composite the **incoming** surface over the **outgoing** surface at the eased
   progress into `targetSurfaceID`, in linear-premultiplied light.
3. **`slideTransition`** — the outgoing surface stays in place; the incoming surface is composited
   translated by `(offsetX, offsetY)` (canvas-raw units, already computed by the graph) into
   `targetSurfaceID`; off-edge samples are transparent (clampToZero).
4. **`overlay`** — composite a pre-resolved overlay pixel input above the body, in `compositionOrder`, into
   `targetSurfaceID` (= `linearCanvas`), then the existing final conversion runs.

All four keep: one command buffer / one wait; linear-premultiplied source-over; explicit surface flow;
typed errors; transient-resource release at completion; final conversion last.

### 2.2 Non-scope — [OUT]

| Concern | Disposition |
|---|---|
| New transition effects beyond fade/slide (wipe, dissolve, push, …) | Out — `unsupportedTransitionEffect` stays (graph already rejects). |
| Animated overlays (active overlay animation) | Out — graph already throws `unsupportedOverlayAnimation`; Step 12 does not relax it. |
| Audio, text engine, realtime pooling, decoder, scheduler, export | Out (later tasks). |
| Any graph-emission / validator change | Out — Step 12 is execution-only (§1.1/§1.2). |
| Task 004, reference promotion, CPU renderer | Out. |

No transition/overlay command is silently ignored; an unimplemented sub-case fails closed with a typed error.

---

## 3. Pixel execution design (GPU-first, full-surface composite passes)

Every Step-12 command is a **full-surface composite pass** mirroring `MetalColorConverter`:
`fullscreen_vertex` + a dedicated fragment, reading one or two source surfaces with the bilinear
clampToZero sampler, writing the target surface. All colour math is in **linear-premultiplied** light; the
final linear→sRGB conversion remains the single existing last pass (unchanged). The executor ends any open
scene encoder (`endEncoderIfOpen`) before each Step-12 pass, exactly as Step-11 shape/mask/matte already do.

### 3.1 Cut (single scene) — [DERIVED, no code change]

The cut path is already executed by Step 10: the single scene renders into `linearCanvas`, then overlays
(§3.5), then `finalLinearToSRGB`/`finalOutput`. Step 12 adds **only tests** (structural: a `.single` body
emits no transition command; device: a cut frame is correct + repeatable). No executor change.

### 3.2 Fade — [DERIVED + R1]

Inputs (validated): `outgoing`, `incoming` surfaces (both written), `targetSurfaceID`, `easedProgress p`
(`UnitInterval`, already eased in the graph). Both surfaces hold **linear-premultiplied** content.

Composite, per pixel, into the target (the cleared target receives one full-surface pass; blending **disabled
/ `.replace`**, since the fade fragment produces the final composited value itself):

```
out = outgoing·(1 − p) + incoming·p          // component-wise on premultiplied RGBA, linear light
```

- This is a **premultiplied cross-dissolve**: because both inputs are premultiplied, the straight linear
  cross-fade of premultiplied RGBA is correct (a fully-transparent region of one surface contributes 0).
- The fragment reads `outgoing` (texture 0) and `incoming` (texture 1) at the fragment UV, reads `p` from a
  constant buffer, and outputs `mix(outgoing, incoming, p)` on the full premultiplied float4.
- **Target load action: `.clear`** (the target is the linear canvas, which the body did NOT write in the
  transition path — the scenes wrote the outgoing/incoming surfaces). The pass writes the full surface, so
  `.replace` (blending disabled) is exact; **R1** confirms the target is exclusively owned by this pass (it
  must NOT also be source-over-blended, or it would double-count). *Owner-decision R1 in §11 pins the target
  load/blend.*

### 3.3 Slide — [DERIVED + R2]

Inputs (validated): `outgoing`, `incoming`, `targetSurfaceID`, `direction`, `(offsetX, offsetY)` in
**canvas-raw** units (already computed: incoming enters from the declared edge; offset → 0 as `p → 1`).

Composite into the target in two conceptual layers (single full-surface pass):

```
// per target pixel (x, y), canvas-raw coordinate = (x·U + U/2, y·U + U/2):
bg  = outgoing.sample(uv)                                   // outgoing stays in place
src = incoming.sample(uv − offsetUV)                        // incoming shifted by (offsetX, offsetY)
out = src  over  bg                                          // premultiplied source-over: src + bg·(1 − src.a)
```

- `offsetUV` is `(offsetX, offsetY)` converted from canvas-raw to normalized UV using the surface pixel
  size (exact: `offsetX / (U · widthPx)`), computed CPU-side and passed as a `float2` constant (the only
  `Float` at the boundary, like the image-quad NDC conversion).
- Off-edge samples of the shifted incoming surface are **transparent** via the existing `clampToZero`
  sampler (no wrap, no clamp-to-edge), so the incoming slides in over the outgoing with a transparent
  leading gap exactly as it animates 0→1.
- **The outgoing scene continues rendering** (architecture L44/L338) — this is already true: the graph
  renders the outgoing scene fully into `outgoing` each frame; the executor just composites it.
- **R2 (§11):** the precise compositing — *incoming source-over outgoing* (the standard slide where the
  incoming covers the outgoing as it enters) vs a push (both translate). The architecture says "outgoing
  continues **playing**" (keeps animating), not that it translates; so the recommended semantics is
  **incoming slides in over a stationary, still-animating outgoing**. R2 pins this against the producer's
  intended slide.

### 3.4 Overlay — [DERIVED]

Inputs (validated): `resourceID` (a declared `pixelInput`), `transform` (`FixedAffineTransform2D`, includes
source-pixel→frame sizing + placement), `opacity`, `compositionOrder`, `targetSurfaceID` (= `linearCanvas`,
already written by the body). The overlay pixels are **normalized** to linear-premultiplied by the existing
normalization pass (every declared `pixelInput` is normalized before scenes), so the overlay samples the
**normalized** texture — identical to `drawImage`.

Execution = **exactly the existing `drawImage` path** (`MetalSceneCompositor.imageQuad` + the image PSO with
fixed-function premultiplied source-over), targeting `linearCanvas`, in `compositionOrder` (the graph already
ordered them). Composite over the existing body content with `.load`/source-over.

- This means overlay needs **no new shader or pipeline** — it reuses `image_vertex`/`image_fragment`, the
  image PSO, the bilinear sampler, the normalized overlay texture, and the opacity uniform.
- The executor opens (or retargets) a scene-style encoder on `linearCanvas` and encodes the overlay quad
  exactly as an image draw.

### 3.5 Overlay ordering relative to body / final conversion — [FIXED]

The graph already places overlays **after the body and before the final conversion** (`RenderGraphCompiler`
L80 then L83–84), in dense unique `compositionOrder` (`OverlayGraphBuilder`). The executor preserves emit
order, so overlays composite above the cut/transition result and **before** `finalLinearToSRGB`. No ordering
logic is added in Metal; the executor follows the command list. The validator already guarantees overlays
are outside any scope and the target is written. The single final conversion stays last (validator-enforced
final chain).

### 3.6 Pipelines + shaders — [DERIVED + R3]

| Pass | Vertex | Fragment | PSO blend | New? |
|---|---|---|---|---|
| Fade | `fullscreen_vertex` (reuse) | **`fade_fragment` (NEW)** — `mix(outgoing, incoming, p)` on premult float4 | `.replace` (target cleared, full-surface) — R1 | shader+PSO |
| Slide | `fullscreen_vertex` (reuse) | **`slide_fragment` (NEW)** — `incoming.sample(uv−offset)` source-over `outgoing.sample(uv)` | `.replace` (the fragment does the over itself, full-surface) — R1/R2 | shader+PSO |
| Overlay | `image_vertex` (reuse) | `image_fragment` (reuse) | premultiplied source-over (existing image PSO) | none |

- Both new fragments read **linear-premultiplied** inputs and output linear-premultiplied; no sRGB decode in
  the composite (consistent with §4). The final conversion remains the only encode.
- Both new PSOs are created at `MetalPipelineLibrary` construction for **both** intermediate target formats
  (`.rgba16Float`, `.bgra8Unorm_srgb`), like the Step-11 apply pipelines — never lazily in `execute`. A
  creation/capability failure is a typed `pipelineCreationFailed`.
- **R3 (§11):** whether fade/slide composite into the target with a self-contained `.replace` pass (the
  fragment reads both surfaces and emits the final value) — recommended, simplest, exact — versus two
  source-over passes. The recommendation is the single `.replace` full-surface pass per command.

### 3.7 New compositor file — [DERIVED]

A new `MetalTransitionCompositor.swift` (mirroring `MetalColorConverter` / `MetalShapeCompositor`) owns the
fade and slide pass encoding (read two surfaces by ID from the owner, set the PSO for the target format,
bind the eased-progress / offset constant, draw the full-surface triangle). Overlay reuses the existing
image-draw encoding in `MetalGraphExecutor` (no new compositor needed for overlay).

---

## 4. Color contract preservation — [FIXED]

- Fade/slide operate on **linear-premultiplied** surface content and output linear-premultiplied; overlay
  composites the **normalized** (linear-premultiplied) overlay texture with fixed-function premultiplied
  source-over — identical to image draws.
- No sRGB decode/encode inside any composite pass; the single `finalLinearToSRGB` remains the only encode
  and stays last (validator-enforced).
- Intermediate surfaces stay `rgba16Float` (or `bgra8SRGB` per configuration); the slide offset is computed
  in exact fixed point and converted to a `Float` UV only at the shader boundary (same discipline as the
  image-quad NDC conversion).
- One command buffer / one wait preserved; each Step-12 pass is encoded into the same command buffer between
  the body and the final conversion.

---

## 5. Typed error model — [FIXED, reuse-first]

| Case | Status | Reason |
|---|---|---|
| `unsupportedTransitionEffect` / `unsupportedSlideDirection` (`RenderGraphError`) | reuse | non-fade/slide effect or bad direction — already rejected at graph compile, never reaches Metal. |
| `unsupportedOverlayAnimation` (`RenderGraphError`) | reuse | active overlay animation — rejected at graph compile. |
| `missingResource` (`MetalRenderError`) | reuse | a fade/slide surface id or an overlay pixel id not registered in the owner. |
| `encodingFailed` (`MetalRenderError`) | reuse | a fade/slide/overlay render encoder could not be created. |
| `pipelineCreationFailed` (`MetalRenderError`) | reuse | a fade/slide PSO could not be created at session construction. |
| `geometryOverflow` (`MetalRenderError`) | reuse | checked offset→UV / overlay-quad arithmetic overflow. |
| `unsupportedCommand(step:12)` | **removed for these three** | the three categories become supported; only their migration from "rejected" to "executed" (§7); the classifier returns `nil` for them after Step 12. |

**No NEW error case is anticipated.** If the slide direction needs a distinct execution-side failure not
expressed by the above, it would be added then — flagged as the only possible new case (§11-R4). No silent
substitution, no fallback, no force-unwrap, no `try?`, no trap. All offset/UV arithmetic is checked
(`CheckedInt64`/`FixedPointMath`).

---

## 6. Canonical / golden impact — [FIXED]

**Step 12 changes NO payload, NO value type, NO canonical encoding.** The three command payloads
(`fadeTransition`/`slideTransition`/`overlay`) are unchanged (verified §1.1); the graph compiler and
validator are untouched. Therefore:

- **No canonical bytes change. No graph golden hash changes.** Existing transition/overlay graph goldens
  stay byte-identical (asserted unchanged).
- The only test churn is in the Metal executor's classification (the three move from "deferred" to
  "supported") and the device `rawOutputHash` for newly-rendered transition/overlay frames (new goldens,
  not re-bakes).
- Forbidden-path snapshot stays byte-identical (AG9).

If implementation discovers a genuine need to change a payload (e.g. a slide needs a value the graph does not
already carry), that is a **STOP** (§10) — the plan's premise is execution-only.

---

## 7. Test plan (real-template, structural, Metal, device)

### 7.1 Structural / graph (no new graph code; assert existing emission stays correct)

| # | Requirement | Assertion |
|---|---|---|
| S-1 | `.single` body (cut) emits NO transition command and writes `linearCanvas` directly | structural over the compiled graph |
| S-2 | `.transition` body emits two scene surfaces + exactly one fade/slide command into `linearCanvas` | structural (already covered; reaffirm) |
| S-3 | overlays emit after the body, before `finalLinearToSRGB`, in dense `compositionOrder` | structural ordering |
| S-4 | the executor classifier now returns `nil` (supported) for fade/slide/overlay; only … no Step-12 category remains | classifier test (migrates `testUnsupportedCommandClassificationStep12Only`) |

### 7.2 Metal pixel tests (M2 Pro; exact for opaque/integer-aligned, bounded for partial-alpha/AA)

| # | Requirement | Assertion |
|---|---|---|
| M-1 | **fade p=0** → output equals the outgoing surface exactly | exact bytes (opaque fixture) |
| M-2 | **fade p=1** → output equals the incoming surface exactly | exact bytes |
| M-3 | **fade p=0.5** → premultiplied cross-dissolve midpoint | bounded vs linear CPU oracle |
| M-4 | **fade with a partial-alpha region** in one surface | bounded; two-sided (catches non-premultiplied blend) |
| M-5 | **slide left/right/up/down** at p=0.5 → incoming shifted by the exact offset; outgoing stationary | exact for the opaque shifted block boundary; off-edge transparent |
| M-6 | **slide p=1** → incoming fully in place over outgoing (offset 0) | exact bytes |
| M-7 | **slide off-edge is transparent** (clampToZero), revealing the outgoing underneath | exact at the leading gap |
| M-8 | **overlay** composites a pixel input above the body in `compositionOrder` (two overlays: order respected) | exact opaque / bounded partial-alpha |
| M-9 | **overlay over a transition result** (overlay above fade/slide) — ordering body→overlay→final | exact/bounded |
| M-10 | **cut** frame correctness (single scene → canvas → final) unchanged | exact (regression) |
| M-11 | one command buffer / one wait preserved with fade/slide/overlay passes | structural execution-event order |
| M-12 | fade/slide/overlay frame **same-device byte + `rawOutputHash` repeatability** | exact equal |
| M-13 | fade/slide transient encoders/resources released after success AND injected failure | lifecycle (owner observer) |
| M-14 | production audit clean (no `try?`/`try!`/force-unwrap/trap/silent fallback) in changed files | grep classification |
| M-15 | the three categories REMOVED from the executor "unsupported" tests; only nothing remains deferred at step 12 (or document the next deferred set) | migration |

`MetalResourceOwnershipTests.testReachableDeferredFamiliesRejectedByExecutor` (which today rejects all three)
is **migrated**: its fade/slide/overlay graphs now **execute** and assert correct pixels, leaving zero
Step-12-deferred families.

### 7.3 Real-template tests — [honest scope]

- **Cut + real overlays:** the five real templates (all `.single`) render end-to-end and (if any carry real
  overlays) the overlay path executes — device-verified frame + repeatability for at least one real
  template that exercises overlays (or, if none carry overlays, this is stated explicitly and the overlay
  device test uses a synthetic overlay pixel input).
- **Fade/slide between two real scenes:** because no real fixture carries a transition (§1.6), the
  transition device/Metal tests assemble a **synthetic-but-faithful** `.transition` body from two real
  compiled scenes (or two real single-scene graphs rendered into the outgoing/incoming surfaces). The plan
  states plainly: transition pixel coverage is **synthetic composition of real scene content**, not a real
  authored transition (none exists). No overstated "real transition" claim is made.

### 7.4 iPhone 13 Pro device gate — [FIXED]

Update the existing DeviceGateHost test **source only** (project structure unchanged, §9.4-style): add
device cases that render (a) a fade frame, (b) a slide frame, (c) an overlay-over-body frame; each asserts
pixel correctness, the private upload path active, the execution-event order, and same-device byte +
`rawOutputHash` repeatability. Re-run the existing Step-10/11 device cases (must stay green). Capture device
identity (`iPhone14,2` / Apple A15 / iOS build) and output hashes as evidence attachments. No simulator
substitute.

---

## 8. Acceptance gates

- **AG1 Cut:** single-scene frame correct + repeatable on device; `.single` body emits no transition (S-1, M-10).
- **AG2 Fade:** M-1…M-4 — endpoints exact, midpoint bounded vs linear CPU oracle, partial-alpha two-sided.
- **AG3 Slide:** M-5…M-7 — every direction offset exact, p=1 exact, off-edge transparent over stationary
  outgoing.
- **AG4 Overlay + ordering:** M-8/M-9/S-3 — overlays composite above the body in `compositionOrder`, before
  the single final conversion.
- **AG5 Structure preserved:** M-11 — one command buffer / one wait; normalize-before-scenes; final
  conversion last; explicit surface flow; no implicit current surface.
- **AG6 Errors/lifecycle:** M-13/M-14 — typed failures, transient release on success+failure, audit clean.
- **AG7 Determinism:** M-12 — same-device byte + `rawOutputHash` repeatability for fade/slide/overlay frames.
- **AG8 Canonical unchanged:** no payload/golden re-bake (§6); existing transition/overlay graph goldens
  byte-identical; only new device frame goldens.
- **AG9 Device:** iPhone 13 Pro gate re-runs all prior cases green **plus** fade/slide/overlay device cases.
- **AG10 Repository envelope:** no `Package.swift`/`*.pbxproj`/forbidden-path change; forbidden-path snapshot
  byte-identical; changed files within §9.

---

## 9. Exact files (estimate; finalized at implementation)

### 9.1 Create — production

| File | Responsibility |
|---|---|
| `Sources/AnimiEngineMetalRender/MetalTransitionCompositor.swift` | Encode the fade pass and the slide pass (read outgoing/incoming surfaces by id, bind eased-progress / offset, full-surface draw into the target). |

### 9.2 Modify — production

| File | Change |
|---|---|
| `Shaders/AnimiEngineRender.metal` | Add `fade_fragment` (premultiplied cross-dissolve) and `slide_fragment` (shifted incoming source-over outgoing). No change to image/overlay shaders. |
| `MetalPipelineLibrary.swift` | Load the two new functions; create fade + slide PSOs for both target formats at construction; add accessors. |
| `MetalSceneCompositor.swift` | `unsupportedCommand(for:)` returns `nil` for fade/slide/overlay (now supported); add the slide offset→UV conversion helper (checked). |
| `MetalGraphExecutor.swift` | Replace the three `unsupportedCommand(step:12)` throws (preflight + encode) with: fade/slide dispatch to `MetalTransitionCompositor`; overlay dispatch to the existing image-draw path on `linearCanvas`; keep one-buffer/one-wait, transient ownership, and the final conversion last. |
| `MetalTextureAllocator.swift` | Likely **unchanged** (outgoing/incoming/overlay surfaces already allocated). Listed only if a slide needs an explicit intermediate; current design needs none. |

### 9.3 Create — tests

| File | Responsibility |
|---|---|
| `Tests/AnimiEngineMetalRenderTests/TransitionOverlayTests.swift` | The §7.2 Metal matrix (fade/slide/overlay pixel + ordering + determinism + lifecycle). |

### 9.4 Modify — tests

| File | Change |
|---|---|
| `Tests/AnimiEngineMetalRenderTests/MetalResourceOwnershipTests.swift` | Migrate `testReachableDeferredFamiliesRejectedByExecutor` (fade/slide/overlay now execute) and `testUnsupportedCommandClassificationStep12Only` (no Step-12 category remains). |
| `Tests/AnimiEngineRenderGraphTests/TransitionAndValidatorCorrectiveTests.swift` | Add the cut-emits-no-transition structural test (S-1) if not already covered. |
| `DeviceGateHost/.../IPhoneDeviceGateTests.swift` | Add fade/slide/overlay device cases (source only; project unchanged). |

### 9.5 Documentation

- Update `Docs/AnimiEngineNext/decision-register.md` (Step-12 entry).
- Do not rewrite the master plan or this Step-12 plan during implementation.

### 9.6 NOT changed / forbidden

No `Package.swift` target/product/dep change; no `*.xcodeproj`/`*.pbxproj`; no `AnimiApp`/`TVECore`/
`SceneSources`/`SharedAssets`; no graph compiler/validator change; no public RenderModel API change; no CPU
renderer; DeviceGateHost project structure untouched (source only).

---

## 10. STOP conditions (report immediately, do not invent a workaround)

1. A payload/value-type/canonical change is genuinely required to execute fade/slide/overlay (the plan's
   execution-only premise is false) — STOP.
2. The producer's intended **slide** semantics (R2) cannot be matched without the outgoing also translating
   (a "push"), i.e. the graph's single incoming offset is insufficient — STOP (a graph change would be
   needed).
3. A real authored template is found that carries a **transition** or an **animated overlay** that the
   current graph rejects — STOP (scope/contract question).
4. The M2 Pro or iPhone 13 Pro cannot create the fade/slide PSOs for a required target format — STOP (typed
   `pipelineCreationFailed`; no fallback).
5. The DeviceGateHost cannot run the new Step-12 cases without a project-file change — STOP.
6. A correction needs a file outside the §9 envelope — STOP.
7. Fade/slide pixel results cannot be made same-device repeatable — STOP.

---

## 11. Unresolved decisions (require an explicit owner answer before implementation)

| ID | Decision | Recommendation | Consequence if wrong |
|---|---|---|---|
| **R1** | Fade/slide composite into the target via a single self-contained **`.replace`** full-surface pass (fragment reads both surfaces, emits the final value) vs two source-over passes into a cleared target. | **Single `.replace` pass** (simplest, exact, one encoder per command). | Double-counting / wrong blend if the target is also source-over-blended. |
| **R2** | **Slide** semantics: incoming **slides in over a stationary (still-animating) outgoing** vs a **push** (both translate). The graph supplies only the incoming offset; architecture says outgoing "continues playing", not "translates". | **Incoming-over-stationary-outgoing** (matches the single-offset graph contract and the architecture wording). | A push would need a graph change (outgoing offset) → out of execution-only scope (STOP #2). |
| **R3** | New shaders/PSOs for fade+slide (recommended) vs trying to reuse `matte_apply`/`image` for fade/slide. | **Two new fragments + PSOs** (`fade_fragment`, `slide_fragment`); overlay reuses the image path. | Reuse hacks would obscure the linear-premultiplied cross-dissolve / shifted-sample semantics. |
| **R4** | Whether any **new typed error case** is needed for a slide/overlay execution failure. | **None** — reuse `missingResource`/`encodingFailed`/`pipelineCreationFailed`/`geometryOverflow`. | A genuinely distinct failure surface would justify one focused case (decide at implementation). |
| **R5** | **Real-template transition coverage**: synthetic `.transition` assembled from two real scenes (recommended, since no real fixture has a transition) vs authoring a new transition fixture. | **Synthetic-but-faithful** (no new authored asset; stated honestly). | Authoring a fixture touches `SceneSources` (forbidden) → not allowed. |
| **R6** | **Overlay device coverage** if no real template carries an overlay: synthetic overlay pixel input on device vs skip. | **Synthetic overlay pixel input** on device (the overlay execution path is identical regardless of source). | Skipping would leave overlay pixels device-unverified. |

All six carry a recommendation; none changes the graph/validator/canonical contract. If the owner accepts
the recommendations, R1–R6 are taken as written at implementation time.

---

## 12. Stop rule

This planning pass created exactly one file:
`Docs/AnimiEngineNext/claude-task-003-step-12-plan.md`. No engine source, no test, no `Package.swift`, no
`*.xcodeproj`/`*.pbxproj`, no forbidden path, and no evidence/reference workflow was modified or started.

**Claude stops here and waits for explicit owner approval** (and R1–R6 resolution) before implementing
Step 12. During implementation, Claude must **stop and report** rather than weaken scope on any §10 STOP
condition. Step 13+ / Task 004, a CPU renderer, reference promotion, and new transition effects beyond
fade/slide must not be started.
