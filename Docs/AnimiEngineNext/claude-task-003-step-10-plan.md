# Task 003 — Step 10 Implementation Plan: Metal Executor and Basic Image Composition

**Revision:** 4 — FINAL / APPROVED
**Status:** R1–R4 APPROVED; IMPLEMENTATION NOT STARTED (awaiting owner GO)
**Scope gate:** Task 003 §17 step 10 — "Implement Metal color contract and basic image composition."
**Parent plan:** `Docs/AnimiEngineNext/claude-task-003-plan.md` (Revision 2, approved).
**Predecessor:** §17 step 9 (RenderGraph compilation) — approved. `swift build` green; `swift test` 643 executed, 1 skipped, 0 failures.

This is a **PLAN ONLY** document. No production code, test, `Package.swift`, ADR, fixture, documentation
or project file is modified by this planning pass. The only file written is this plan.

Implementation must not begin until the product owner instructs Claude Code to start.

### Approved decisions (R1–R4) — owner-approved, now [FIXED]

| ID | Approved decision | Section |
|---|---|---|
| **R1** | Texture sampling: **bilinear min/mag, `addressMode=.clampToZero`, no mipmaps** | §7.8 |
| **R2** | Shaders: **runtime source compilation behind `ShaderLibraryLoader` + `RuntimeSourceShaderLoader`** | §9.3 |
| **R3** | Concurrency: **internal non-blocking execution guard** (`executionAlreadyInProgress` on overlap) | §4.2 |
| **R4** | Clip edges: **R4-A hard pixel-center clipping** (no fractional coverage, no Float) | §7.5 |

There are **no remaining [RECOMMENDED FOR APPROVAL] decisions**; R1–R4 are [FIXED — approved] and remain so
in Revision 4 (this revision changes no decision).

### Revision 4 changelog (owner corrections 1–6 — documentation-only)

1. **File counts corrected:** 11 new Swift production files **+ 1 Metal shader = 12 production files**;
   2 new test files; **total created = 14** (was mis-stated as 13); **total modified = 5** (§11).
2. **Stale Rev-2 claim removed:** the statement that `minimumLinearTextureAlignment(for:)` is the blit-row
   alignment API is **explicitly superseded** (Rev-2 changelog item 3 annotated; §1.5 finding annotated).
   The blit-row alignment is the documented 256 B from the Feature Set Tables (§8.5).
3. **`StubFailingSubmitter` is test-only:** production `CommandSubmitter.swift` contains **only**
   `CommandSubmitter`, `CommandCompletion`, `RealCommandSubmitter`; `StubFailingSubmitter` lives in
   `MetalResourceOwnershipTests.swift` (§10, §11.1, §13.2).
4. **Implementation checkpoints fixed:** Stage 1 does **not** round-trip a frame (no allocator/readback yet)
   — it covers build, shader loading, preflight, unsupported-command, framesInFlight and execution-guard;
   the clear/final round-trip begins in **Stage 2** (§14).
5. **Empty clip skips enclosed draws:** an empty clip intersection **skips** the enclosed draw commands
   rather than relying on a zero-sized `MTLScissorRect` (not proven valid by official docs) (§7.5).
6. **`ceilDiv` never negates `Int64.min`:** quotient/remainder-based checked arithmetic; Int64-boundary
   tests added (§7.5, §13).

### Revision 3 changelog (owner corrections 1–9, atop the Rev-2 corrections 1–15)

1. **Private-texture upload sequencing fixed:** fill staging buffers → create command buffer → encode
   buffer→texture upload blits → render passes → final texture→readback blit → commit + wait once. No claim
   a private upload "completes" before a command buffer exists (§8.1, §8.6).
2. **Blit-row alignment uses a documented conservative 256 B** from the Metal Feature Set Tables ("Buffer
   alignment for copying an existing texture to a buffer"); `minimumLinearTextureAlignment(for:)` is **not**
   used as a blit-row API (it governs linear-texture creation). Probes are supplementary only (§8.1, §8.5, §17).
3. **"before any GPU object exists" → "before any per-execution texture, buffer, command buffer, or encoded
   GPU work"** — the session already owns device/queue/pipelines (§3.2, §4.1, §15 A8).
4. **`maxTextureDim` removed:** dimension validation checks positivity, exact integer conversion and checked
   arithmetic only; a capability limit surfaces as a typed texture-allocation failure (§7.7, §8.4).
5. **Concurrency wording corrected:** `MetalRenderSession` is **not `Sendable`** and is **not** safely
   transferable across Swift concurrency domains; the guard prevents overlapping execution within permitted
   synchronous/legacy-thread access (§4.2).
6. **R4-A defined without Float:** half-open clip `[x0,x1)×[y0,y1)`, include pixel `p` iff `p+0.5` inside;
   exact fixed-point ceil/clamp for `MTLScissorRect` and nested intersection (§7.5).
7. **No `PrecompiledMetallibLoader` in Step 10** — only `ShaderLibraryLoader` + `RuntimeSourceShaderLoader`;
   the precompiled implementation stays deferred (§9.3, §11.1).
8. **Test expectations corrected:** any CPU-vs-GPU comparison through `pow()`, partial alpha, transfer
   conversion, rotation or bilinear sampling uses **bounded** assertions; exact bytes only for analytically
   exact endpoint/integer-aligned cases and same-device repeatability (§13).
9. **File counts reconciled** so prose and the create/modify tables agree exactly (§11).

(Rev-2 corrections 1–15 remain in force and unchanged except where a Rev-3 correction refines them.)

### Revision 2 changelog (owner corrections 1–15) — retained for history

1. **Compositing is fixed-function premultiplied source-over** (`add`/`one`/`oneMinusSourceAlpha`), never
   read-and-write of the same texture (§5.2, §7.4). Verified against official sRGB-attachment blend
   behavior and a disposable probe.
2. **Final UNORM quantization** is `q = floor(clamp(c,0,1)*255 + 0.5)/255`, written as a normalized float
   to `.bgra8Unorm`; shaders output RGBA-**semantic** values and the format controls physical BGRA byte
   order — no manual channel swizzle (§5.3, §6).
3. **Upload/readback alignment** ~~uses `device.minimumLinearTextureAlignment(for:)`~~ — **SUPERSEDED by
   Revision 3 (correction #2): this API is NOT the blit-row alignment**; the documented conservative 256 B
   from the Feature Set Tables is used instead (§8.5). Staging strides are aligned, output repacked tight
   row-by-row; odd widths and arbitrary input strides handled (§8).
4. **Exact command-buffer sequence** defined: allocate readback buffer → encode all passes incl. blit →
   commit → wait once → validate → read → construct frame (§8.6).
5. **No hardcoded 1080×1920** in the executor — all dimensions are derived from validated descriptors (§5,
   §8, §13).
6. **Whole-graph preflight** before any GPU mutation (§4.1).
7. **`clearBackground` colour domain** proven and constrained — non-zero non-transparent clears fail closed
   in Step 10 (§5.5).
8. **Fractional clip coverage** reclassified **[RECOMMENDED FOR APPROVAL — R4]** with a hard-clip
   alternative (§7.5).
9. **No exact CPU-vs-GPU bytes for rotated bilinear** — bounded invariants there, exact only for
   integer-aligned and same-device repeatability (§7.8, §13).
10. **R3** becomes an **internal execution guard** with a typed `executionAlreadyInProgress` error (§4.2).
11. **Command-buffer failure seam** is a concrete `CommandSubmitter` abstraction injecting a deterministic
    failed completion result — no claim that a real `MTLCommandBuffer` is hand-marked failed (§13.2).
12. **No claim of a general render-target format-support API** — capability is proven via pipeline/texture
    creation success/failure (§5.4, §6).
13. **Shader-library loading is behind a `ShaderLibraryLoader` abstraction** so a precompiled `.metallib`
    can replace runtime compilation without touching `MetalRenderSession` (§9.3).
14. **Decision accounting fixed:** there are **four** [RECOMMENDED FOR APPROVAL] decisions — R1 (filtering),
    R2 (shader loading), R3 (execution guard), R4 (clip-edge policy) — listed consistently (§0, §20).
15. Test matrix, file responsibilities, implementation sequence, risks and acceptance gates updated to match
    (§13–§16).

---

## 0. Decision classification key

Every decision below is tagged:

- **[FIXED]** — approved by the architecture, the Task-003 plan, an ADR, the decision register, pinned by
  existing committed code, or **owner-approved in this revision (R1–R4)**.
- **[DERIVED]** — necessarily follows from an approved contract or from the existing model/graph code;
  no new product or architecture choice.
- **[DEFERRED]** — belongs to Step 11 (masks/mattes/shapes) or Step 12 (transitions/overlays) or later.

There are **no [RECOMMENDED FOR APPROVAL] decisions** in Revision 3. R1–R4 are approved and recorded as
[FIXED]; §20 lists them with their approved values.

---

## 1. Current-state audit (concrete references)

### 1.1 Module and dependency state — [FIXED]

`AnimiEngineMetalRender` exists as a target (`Package.swift:108–113`) depending on exactly
`AnimiEngineRenderModel` + `AnimiEngineRenderGraph`. It currently contains a single file,
`Sources/AnimiEngineMetalRender/MetalRenderError.swift`, holding an **empty** typed error enum
(`MetalRenderError.swift:6–7`). No Metal object, pipeline, allocator, uploader, compositor, color
converter or readback exists yet.

The test target `AnimiEngineMetalRenderTests` (`Package.swift:177–186`) depends on
`AnimiEngineRenderModel`, `AnimiEngineRenderGraph`, `AnimiEngineMetalRender`,
`AnimiEngineRenderTestSupport`. It currently contains three files:

- `MetalTestEnvironment.swift` — `MetalTestEnvironment.makeDevice()` / `requireDevice(...)` (a guarded
  default `MTLDevice` that **skips** the test via `XCTSkip` when no device exists) plus a module-link smoke
  test (`MetalTestEnvironment.swift:16–37`).
- `ColorAlphaContractTests.swift` — currently proves only the **value-model** contract descriptors and
  `PremultipliedColor` invariants; its header explicitly states the **execution** proofs (transfer
  function, premultiplication arithmetic, source-over, readback) "require the executor and are §17 step 10;
  they are not implemented in Stage 3" (`ColorAlphaContractTests.swift:6–9`). Step 10 fills exactly those.
- `IntermediateProfileTests.swift` — proves both profiles are explicit value-model cases and that
  `RenderConfiguration` preserves the chosen profile; its header defers the "no silent profile
  substitution **during execution**" proof to step 10 (`IntermediateProfileTests.swift:6–10`).

### 1.2 The contract the executor consumes — [FIXED]

`MetalRenderSession.execute(_ graph: RenderGraph) throws -> RenderedFrame` is the only entry point
(parent plan §8, lines 606–631). The inputs are completely defined by committed model code:

- **`RenderGraph`** (`RenderGraph.swift`): an immutable, hashable value carrying a `RenderConfiguration`
  and an **ordered** `[RenderCommand]`. Construction already guarantees dense contiguous ordinals,
  exactly one `finalOutput` (last), exactly one `finalLinearToSRGB` (immediately before it)
  (`RenderGraph.swift:21–58`).
- **`RenderCommand`** = `{ ordinal, payload }`; `category` is derived from the payload so the two cannot
  disagree (`RenderGraphCommands.swift:400–423`).
- **`RenderCommandPayload`** — the closed, field-level command set (`RenderGraphCommands.swift:283–319`).
  Each case carries pure fixed-point values (no `Float`/`Double`): `FixedAffineTransform2D`,
  `OpacityScalar`, `PremultipliedColor`, `SampledBezier`, `SampledShape`, surface ids, etc.
- **`RenderResourceDescriptor`** (`RenderGraphCommands.swift:86–162`): a `pixelInput` retains its owned
  `ResolvedPixelInput` (bytes + descriptor + content hash); an `offscreen` carries a `RenderSurfaceProfile`
  + `RenderSurfaceStorageFormat` and **no** byte format. So **execute() is self-contained** — it needs no
  URL, provider, cache or lookup to obtain pixels (corrective #1).
- **`ResolvedPixelInput` / `PixelDimensions`** (`ResolvedPixelInput.swift`): owned `Data`, validated
  `width`/`height`/`bytesPerRow`/`format`/`orientation`/`requiredByteCount`; `format` is `.bgra8`
  (4 bytes/pixel), `orientation` is `.up` for fixtures.
- **`RenderColorContract` / profiles** (`RenderColorContract.swift`): `.task003` = BGRA8 / sRGB / SDR /
  premultiplied; `IntermediateProfile` ∈ {`bgra8SRGB`, `rgba16FloatLinear`}.
- **`RenderConfiguration`** (`RenderConfiguration.swift`): `output` (canvas + frame rate),
  `colorContract`, `intermediateProfile`, `framesInFlight` (Task-003 = 1).
- **`RenderedFrame`** (`RenderedFrame.swift`): the only output — owned BGRA8 bytes, color contract, and a
  `rawOutputHash` (SHA-256 over dimensions/format/color + bytes). Construction rejects a byte count that
  disagrees with `requiredByteCount` and any non-BGRA8 format.

### 1.3 Validation already performed by the graph layer — [FIXED]

`RenderGraphValidator.validate(_:configuration:)` (`RenderGraphValidator.swift`) already, **before any
Metal**, guarantees on a compiled graph:

- full `graph.configuration == configuration`; color contract is `.task003` (`:25–33`);
- the **first** non-declaration command clears `linearCanvas`, cleared exactly once (`:37–54`);
- exactly one `finalLinearToSRGB` (`linearCanvas`→`sRGBSurface`) immediately before exactly one
  `finalOutput` (reads `sRGBSurface`), last (`:55–73`);
- declare-before-use, exact resource **kind** per reference, **write-before-read** for every surface
  (`requireWritten`, `:114–119`), balanced scene/clip/mask scopes, draw target equals the open scene
  target (or an initialised matte surface), profile↔storage compatibility (`:120–243`).

**[DERIVED] consequence for Step 10:** the executor calls `RenderGraphValidator.validate` once up front
(belt-and-suspenders, the compiler also runs it) and may then **trust ordering, surface lifetime, scope
balance and the final chain**. The executor does not re-derive these; it re-checks only the small set of
properties the validator does **not** cover (R-prefixed, §"What the executor still validates").

### 1.4 Geometry/units facts pinned by committed code — [DERIVED]

- **Offscreen surface descriptor dimensions are in `CanvasScalar` raw units** (×65,536 per point), not
  pixels: the compiler declares `linearCanvas`/`sRGBSurface` with `canvasRaw(width/height)` =
  `points * CanvasScalar.unitsPerPoint` (`RenderGraphCompiler.swift:39–42, 93–95`;
  `CanvasScalar.swift:10`). **A `pixelInput` descriptor's dimensions are in pixels**
  (`Int64(pixels.dimensions.width)`, `RenderGraphCommands.swift:116–117`). The executor MUST therefore
  divide an offscreen surface's `width`/`height` by `CanvasScalar.unitsPerPoint` (checked, exact, no
  remainder) to obtain the integer pixel grid it allocates, and MUST take pixel-input dimensions as-is.
  This asymmetry is a load-bearing contract; §8.4 specifies the exact conversion and its failure case.
- **`FixedAffineTransform2D`** maps a point with
  `x' = (a·x + c·y)/1_000_000 + tx`, `y' = (b·x + d·y)/1_000_000 + ty`; `a,b,c,d` are
  `linearUnitsPerOne = 1_000_000` per 1.0; `tx,ty` are `CanvasScalar` raw units
  (`FixedAffineTransform2D.swift:24–60`). The transform in a `drawImage`/`drawVideoFrame` payload is the
  **final source-pixel → target-surface (canvas) transform** already composed by step 9 (decision register
  §"step 9", `finalMedia = blockToCanvas · bindingWorld · sourceToBindingLocal`). The executor applies it
  verbatim and **does not reinterpret fit mode or template geometry**.
- **Clip** is a destination-space `FixedRect` (`beginClip(rect:)`), width/height strictly positive
  (`FixedGeometry.swift:16–34`), in `CanvasScalar` raw units.

### 1.5 Metal toolchain feasibility — verified by disposable `/tmp` probe (now removed)

On this machine (Apple M2 Pro, Swift 6.2, SDK 26.0, Metal toolchain present) a throwaway SwiftPM package
proved:

1. `.process("Shaders")` on a target **copies the `.metal` file into the resource bundle as source**
   (`ProbeLib_ProbeLib.bundle/Probe.metal`) — SwiftPM does **not** compile it to a `.metallib`.
   Consequently `device.makeDefaultLibrary(bundle: .module)` **fails** with
   `MTLLibraryErrorDomain Code=6 "no default library was found"`.
2. The reliable path under plain `swift test` is: locate the bundled source with
   `Bundle.module.url(forResource:"AnimiEngineRender", withExtension:"metal")`, read it, and compile at
   runtime with `device.makeLibrary(source:options:)`. This **passed**, and a render pipeline state built
   with `.bgra8Unorm_srgb`.
3. `.bgra8Unorm_srgb`, `.bgra8Unorm` and `.rgba16Float` textures all allocate; a render-target (private)
   → blit → shared buffer readback completes with `cb.status == .completed`, `cb.error == nil`.

A second disposable probe (Revision 2, also removed) additionally proved:

4. **Fixed-function premultiplied source-over** (`add`/`one`/`oneMinusSourceAlpha`) blended into **both**
   `.rgba16Float` and `.bgra8Unorm_srgb` matches a CPU **linear-premultiplied** source-over oracle within
   tolerance — i.e. the `_srgb` attachment blends in linear light and no texture is read+written in one pass
   (drives §5.2/§7.4, correction #1).
5. (Supplementary only — **not** the alignment the plan relies on.) `device.minimumLinearTextureAlignment(for:
   .bgra8Unorm)` returned **16** on this M2 Pro, confirming `width*4` is not a generally legal blit stride.
   The plan instead uses the **documented conservative 256-byte** "Buffer alignment for copying an existing
   texture to a buffer" from the **Metal Feature Set Tables** (§8.5, correction #2); the 16-byte probe value
   is a consistent subset and is recorded as supplementary evidence, never as the source of the constant.

This evidence drives R2 (§9.3), §5.2 (blend) and §8 (allocation/upload/readback) as **supplementary
corroboration**; the load-bearing facts are the cited official sources (§17). Both probes modified nothing
in the repository.

---

## 2. Exact Step 10 scope and explicit non-scope

### 2.1 In scope (parent prompt items 1–17) — [FIXED]

Metal device/queue/library/pipeline ownership; graph validation before allocation/execution; pixel
upload from `ResolvedPixelInput`; explicit offscreen-surface allocation; clear; `beginScene`/`endScene`
structural execution; `drawImage`; `drawVideoFrame` (already-resolved still-frame); `FixedAffineTransform2D`
application; rectangular destination-space `beginClip`/`endClip`; premultiplied source-over in linear
light; both intermediate profiles (`bgra8SRGB`, `rgba16FloatLinear`); `finalLinearToSRGB`; `finalOutput`;
canonical BGRA8/sRGB/premultiplied readback; typed failures with no partial `RenderedFrame`; exact
same-environment repeatability tests.

### 2.2 Explicit non-scope — [DEFERRED]

| Command / concern | Step | Step-10 behavior |
|---|---|---|
| `drawShape` | 11 | typed `unsupportedCommand` error |
| `beginMask` / `endMask` | 11 | typed `unsupportedCommand` error |
| `matteLink` | 11 | typed `unsupportedCommand` error |
| `fadeTransition` | 12 | typed `unsupportedCommand` error |
| `slideTransition` | 12 | typed `unsupportedCommand` error |
| `overlay` | 12 | typed `unsupportedCommand` error |
| Realtime pooling, decoder, scheduler, caching, video decode, export, audio, UI, perf optimization | later | not implemented; no stub |

Also out of scope (parent §3.2 / §8): multi-frame-in-flight (Task-003 = 1), texture pooling beyond a
trivial session-local allocator, no global/process Metal state.

**No empty mask/matte/transition compositor stubs are created.** The deferred files
`MetalMaskMatteCompositor.swift` and `MetalTransitionCompositor.swift` from parent §14.5 are **not** created
in Step 10 (see §11). Their commands are rejected by an explicit typed error in the dispatcher, never
ignored, approximated, replaced, or rendered as a black/transparent placeholder.

---

## 3. Supported-command table — [DERIVED from §1.2/§1.3]

| Category | Step-10 execution |
|---|---|
| `declareResource` (pixelInput) | Upload owned bytes → an `MTLTexture`; index by `resourceID`. |
| `offscreenSurface` | Allocate an `MTLTexture` of the surface's pixel grid + storage format; index by `resourceID`. |
| `clearBackground` | Render pass `loadAction=.clear`; clear colour = transparent black only — any non-transparent clear fails closed (§5.5, correction #7). |
| `beginScene` / `endScene` | Structural: push/pop the open target context; no pixels (matches the validator's "scene begin/end do not mark written"). |
| `drawImage` | Sample the bound pixel texture, apply the payload transform + opacity; the shader outputs linear premultiplied source and the **fixed-function blend unit** does source-over (§5.2). |
| `drawVideoFrame` | Identical to `drawImage` (an already-resolved still-frame pixel input). |
| `beginClip` / `endClip` | Set/restore a rectangular destination-space scissor; fractional-edge behavior per approved R4 (§7.5). |
| `finalLinearToSRGB` | Full-screen pass: read `linearCanvas` (linear premultiplied), encode to sRGB premultiplied, write `sRGBSurface`. |
| `finalOutput` | Read back `sRGBSurface` to canonical tightly-packed BGRA8 bytes → `RenderedFrame`. |

### 3.2 Unsupported-command table — [DEFERRED] / typed-failure behavior

For each of `drawShape`, `beginMask`, `endMask`, `matteLink`, `fadeTransition`, `slideTransition`,
`overlay` the **preflight** (§4.1) throws `MetalRenderError.unsupportedCommand(category:step:reason:)`
**before any per-execution texture, buffer, command buffer, or encoded GPU work** (correction #6; the
session already owns the device/queue/pipelines) and returns **no** `RenderedFrame`. The error names the
category and the owning step (11 or 12). There is no placeholder, black fill, transparent fill, skip, or
approximation (parent §9, parent prompt "Commands not implemented").

---

## 4. Metal ownership / lifecycle architecture — [FIXED by parent §8]

```
MetalRenderSession  (owns everything; nothing process-global)
 ├─ MTLDevice                 (injected for tests; optional convenience creation)
 ├─ MTLCommandQueue           (exactly one, session-owned)
 ├─ MetalPipelineLibrary      (built via a ShaderLibraryLoader; caches MTLRenderPipelineState/MTLSamplerState)
 ├─ ShaderLibraryLoader       (R2 runtime source loader only; precompiled .metallib deferred — §9.3)
 ├─ CommandSubmitter          (commit/wait-once vs status-mapping seam — §8.6 / correction #11)
 ├─ execution guard           (one execute() at a time → executionAlreadyInProgress — §4.2 / R3)
 ├─ MetalResourceOwner        (per-execute: resourceID → MTLTexture; lifetime = the execute() call)
 ├─ MetalTextureAllocator     (session-owned; makes textures from descriptors; alignment-aware)
 ├─ MetalResourceUploader     (uploads ResolvedPixelInput bytes → texture; arbitrary stride, odd width)
 ├─ MetalGraphExecutor        (per-execute: preflight + ordered dispatch; owns the single command buffer)
 ├─ MetalSceneCompositor      (encodes clear/image draws via fixed-function blend + clip scissor)
 ├─ MetalColorConverter       (encodes the final linear→sRGB .replace full-screen pass)
 └─ MetalFrameReadback        (blit final surface → aligned staging buffer → tight repack → RenderedFrame)
```

- **[FIXED]** No process-global device, queue, pipeline, cache, allocator or mutable state. The pipeline
  library and sampler/PSO caches live **inside the session** and are built once per session.
- **[DERIVED]** Resource lifetime: each `execute()` creates a fresh `MetalResourceOwner` and a fresh command
  buffer; textures are retained until `commandBuffer.waitUntilCompleted()` returns, then released by
  dropping the owner. This satisfies "resource lifetime through command completion" and "release after
  completion" (parent §8, prompt items 22, 26).
- **[DERIVED]** `execute()` is **synchronous**: it commits one command buffer and blocks on
  `waitUntilCompleted()` exactly once before reading back (parent §8). The exact sequence is pinned in §8.6.

### 4.1 Whole-graph preflight before per-execution GPU work (corrections #3, #6) — [DERIVED]

`execute()` runs a **pure, side-effect-free preflight** over the entire graph **before any per-execution
texture, buffer, command buffer, or encoded GPU work**. (The session already owns the device, queue,
pipeline library and sampler; the preflight creates none of those and mutates no per-execution state.) The
preflight, in order:

1. `RenderGraphValidator.validate(graph, configuration: graph.configuration)` (re-checks §1.3 invariants).
2. `framesInFlight == 1` (parent §8; Task-003 static). Otherwise `MetalRenderError.unsupportedFramesInFlight`.
3. **Reject every Step-11/12 command** (`drawShape`, `beginMask`, `endMask`, `matteLink`, `fadeTransition`,
   `slideTransition`, `overlay`) → `MetalRenderError.unsupportedCommand`. This scan happens **here**, so an
   unsupported command fails **before any per-execution texture, buffer, command buffer, or encoded GPU
   work** (correction #3/#6, parent prompt "must fail before … partial GPU work").
4. **Verify required resources and supported profiles:** every referenced `resourceID` is declared; each
   offscreen surface's `surfaceStorage` maps to the expected `MTLPixelFormat` for its role (§6); each
   pixelInput is `.bgra8` (§5.1); the `clearBackground` colour domain is admissible (§5.5); offscreen
   canvas-raw dimensions convert **exactly** (no remainder) to a **positive** pixel grid (§8.4 — positivity
   and integer conversion only; no `maxTextureDim`).

Only after the preflight returns cleanly does the executor allocate per-execution textures/buffers and a
command buffer. Any preflight failure throws a typed `MetalRenderError` and returns **no** `RenderedFrame`,
with **zero per-execution GPU objects created**.

### 4.2 Execution guard and concurrency — [FIXED — approved R3] (corrections #5, #10)

`MetalRenderSession` is a **`final class`** holding non-`Sendable` Metal objects. It is **not `Sendable`**
and must **not** be described as safely transferable between Swift concurrency domains (e.g. passed into an
`actor` or across an `async` boundary as if thread-safe); it has no compiler-enforced isolation. The
**approved (R3)** design adds an **internal non-blocking execution guard** so overlapping execution cannot
race when the session is reached through permitted **synchronous / legacy-thread** access:

- a private lock (`os_unfair_lock` / `NSLock`) is taken with **`tryLock`** semantics at the top of
  `execute()`;
- if the guard is already held — a **concurrent or reentrant** `execute()` — the call returns the typed
  `MetalRenderError.executionAlreadyInProgress` **immediately**: it does **not** block, deadlock, or race;
- the guard is released on every exit path (success or throw) via `defer`;
- **no `@unchecked Sendable`**; no data race on the per-execute owner.

**Consequence:** only one render runs at a time — exactly the Task-003 one-frame-in-flight contract
(parent §8) — and the type's non-`Sendable` status is honest. This is the conventional pattern for a
non-`Sendable` GPU session; it adds no realtime scheduler (parent §3.2 defers that). The guard makes
overlapping access a typed error rather than undefined behaviour, but it does **not** confer
Swift-concurrency `Sendable` safety, and the plan does not claim it does.

---

## 5. Full color and alpha pipeline — [FIXED contract, DERIVED implementation]

The mandatory contract (parent §"Mandatory color contract", parent §D3-08) is implemented **explicitly in
the shader**, never relying on ambiguous fixed-function GPU behavior. Composition is premultiplied
source-over **in linear light**:

```
out.rgb = src.rgb + dst.rgb * (1 - src.a)
out.a   = src.a   + dst.a   * (1 - src.a)
```

### 5.1 Input decode: conventional BGRA8 sRGB premultiplied → linear premultiplied — [DERIVED]

`ResolvedPixelInput` bytes are **conventional BGRA8, sRGB-encoded, premultiplied** (parent §D3-08;
`ResolvedPixelInput` format `.bgra8`). Per parent's mandatory step 2, before linear-light composition the
shader, for each texel:

1. **Recover straight sRGB color when alpha > 0:** `straight_srgb = premul_srgb / a` (per channel). When
   `a == 0`, force `straight_srgb = 0` (parent: "alpha == 0 must produce zero RGB").
2. **Apply the exact sRGB→linear transfer function** to each straight channel
   (constants from IEC 61966-2-1 / the sRGB definition):
   ```
   c_lin = (c_s <= 0.04045) ? (c_s / 12.92)
                            : pow((c_s + 0.055) / 1.055, 2.4)
   ```
3. **Premultiply again in linear light:** `premul_lin = c_lin * a`.
4. Alpha passes through unchanged (`a` is a linear quantity).

To make this **unambiguous**, the upload binds the source texture as a **non-sRGB** format
(`.bgra8Unorm`, §6) so the GPU performs **no** implicit sRGB decode — the shader does the entire decode.
This is the core guard against "double sRGB decoding" (parent item 5): exactly one decode, in the shader.

### 5.2 Compositing: fixed-function premultiplied source-over in linear light (correction #1) — [FIXED contract, DERIVED + probe-verified]

**The Revision-1 "sample the current render target while writing to it" design is removed.** Reading and
writing the same texture in one pass is **not** a valid universal Metal path and is forbidden here. Instead,
Step 10 uses the **fixed-function blend unit** for premultiplied source-over:

| Blend descriptor field | Value |
|---|---|
| `isBlendingEnabled` | `true` |
| `rgbBlendOperation` / `alphaBlendOperation` | `.add` |
| `sourceRGBBlendFactor` / `sourceAlphaBlendFactor` | `.one` |
| `destinationRGBBlendFactor` / `destinationAlphaBlendFactor` | `.oneMinusSourceAlpha` |

The fragment shader **outputs linear-light premultiplied source** `(src.rgb, src.a)`. The blend unit then
computes `out = src·1 + dst·(1 − src.a)`, i.e. exactly `out.rgb = src.rgb + dst.rgb·(1−src.a)`,
`out.a = src.a + dst.a·(1−src.a)` — the mandated equation (parent §D3-08). **No texture is read and written
in the same pass.**

**Official sRGB-attachment behavior (verified).** On an `_srgb` color attachment the GPU **decodes
sRGB→linear when reading the destination into the blend unit, performs the blend in linear light, and
encodes linear→sRGB on store** (Apple `MTLPixelFormat` sRGB semantics; corroborated by a disposable probe in
which fixed-function `add`/`one`/`oneMinusSourceAlpha` blending into both `.rgba16Float` and
`.bgra8Unorm_srgb` matched a CPU linear-premultiplied source-over oracle within tolerance — probe removed).
Therefore the **blend is always in linear light** for both profiles, with no read-modify-write of a texture.

This drives the storage choice for `IntermediateProfile`:

- **`rgba16FloatLinear`** → `MTLPixelFormat.rgba16Float`, **raw linear** floats; the blend unit operates
  directly on linear values. Correctness reference (parent §D3-08); 16-bit float preserves linear-light
  blending essentially exactly across the SDR range.
- **`bgra8SRGB`** → `MTLPixelFormat.bgra8Unorm_srgb`; the blend unit's automatic sRGB↔linear conversion on
  the attachment keeps blending in linear light while *storing* 8-bit sRGB — which is how 8-bit linear-light
  fidelity is preserved despite quantization (parent item 6). Bytes may differ from `rgba16FloatLinear`
  purely from quantization, but **both follow identical color semantics** (parent item 8).

**No silent fallback (parent item 7, correction #12).** `rgba16FloatLinear` maps to **exactly**
`MTLPixelFormat.rgba16Float`. The executor does **not** claim a general "device reports render-target format
support" API (none with that exact contract is relied upon). Instead, capability is proven by **construction
success/failure**: if `makeTexture`/`makeRenderPipelineState` for `.rgba16Float` fails, that throwing call
surfaces a typed `MetalRenderError` (`textureAllocationFailed` / `pipelineCreationFailed`); the executor
**never** substitutes 8-bit. (`.rgba16Float` is universally available as a render target on the supported
Apple-silicon floor; the failure path exists only as honest defense.)

### 5.3 Final conversion: linear premultiplied → canonical sRGB BGRA8 (correction #2) — [DERIVED]

`finalLinearToSRGB` reads the `linearCanvas` intermediate (linear premultiplied) and writes `sRGBSurface`.
This is a **full-surface pass with blending disabled** (`.replace`) — it writes, never blends, and never
reads the surface it writes. The shader:

1. **Recover straight linear color when alpha > 0:** `straight_lin = premul_lin / a`; `a == 0` → `0`.
2. **Apply the exact linear→sRGB encoding function** (sRGB OETF):
   ```
   c_s = (c_lin <= 0.0031308) ? (12.92 * c_lin)
                              : (1.055 * pow(c_lin, 1.0/2.4) - 0.055)
   ```
3. **Premultiply in the final sRGB domain:** `out_srgb = c_s * a`.
4. **UNORM quantization policy (correction #2) [DERIVED, explicit]:** the executor writes `sRGBSurface` as
   `MTLPixelFormat.bgra8Unorm` (a **plain** 8-bit format, **not** `_srgb`), so the shader's already-encoded
   sRGB value is stored **without a second fixed-function encode** (guards "double sRGB encoding", parent
   item 5). The shader emits a **normalized float in `[0,1]`** computed with the exact rounding the contract
   pins:
   ```
   q = floor(clamp(c, 0.0, 1.0) * 255.0 + 0.5) / 255.0
   ```
   The shader returns `q` (a normalized float), and the `.bgra8Unorm` attachment performs the normalized
   float→byte store. **It does NOT write integer `0…255` into the normalized float attachment** — that
   Revision-1 statement was wrong and is corrected. The `*255+0.5, floor, /255` makes the quantization
   *break-points* deterministic and CPU-oracle-comparable; the attachment's own normalized store of an
   already-snapped value is then a no-op rounding.
5. **Channel semantics (correction #2):** the shader's `float4` return value is **RGBA-semantic**
   (`.rgba` = red, green, blue, alpha). The **`.bgra8Unorm` pixel format alone** determines the physical
   **BGRA byte order** in memory; there is **no manual channel swizzle** in the shader. Readback then copies
   those physical BGRA bytes verbatim (§8.5), which is exactly the canonical `.bgra8` output (parent §D3-08).

Reading `linearCanvas`: when the profile is `bgra8SRGB`, the canvas is `bgra8Unorm_srgb`, so the GPU decodes
sRGB→linear on read — the converter always receives **linear** input regardless of profile, and the same
converter math applies to both. When the profile is `rgba16FloatLinear`, the canvas is read as raw linear
floats. Either way the converter input is linear premultiplied (parent item 8).

### 5.4 Why no implicit/ambiguous behavior — [DERIVED]

- **Source decode** is shader-explicit (source texture bound **non-sRGB**, §5.1) → exactly one decode.
- **Compositing** is fixed-function premultiplied source-over; the attachment's sRGB/linear conversion is
  the **only** hardware colour behavior relied on for `bgra8SRGB`, and the blend always runs in linear light
  (§5.2). No texture is read+written in one pass.
- **`rgba16FloatLinear`** uses no transfer hardware at all → unambiguous.
- **Final encode** is shader-explicit and stored to a **non-`_srgb`** byte format → no double encode.
- **Format capability** is proven by construction, not by an assumed support-query API (correction #12).

### 5.5 `clearBackground` colour domain (correction #7) — [DERIVED, fail-closed]

`clearBackground` carries a `PremultipliedColor` (`RenderGraphCommands.swift`,
`RenderCommandPayload.clearBackground(color:targetSurfaceID:)`). **Proven from committed code:** the
compiler emits **only** `PremultipliedColor.transparentBlack` for both the linear-canvas clear and every
scene/matte-surface clear (`RenderGraphCompiler.swift:45,121`); `transparentBlack` is the unique all-zero
premultiplied colour (`RenderColorContract.swift:85–86`). The Step-9 colour domain for clears is therefore
**transparent black only**.

The plan must **not silently interpret** a non-zero clear colour, because the domain (which intermediate
colour space the non-zero components live in — linear vs sRGB — is undefined for clears at this stage).
**Step-10 policy:** the clear value is mapped to a Metal `clearColor` only when it is
`PremultipliedColor.transparentBlack`; **any non-transparent-black clear fails closed** with
`MetalRenderError.unsupportedClearColor(detail:)`. This is admissible because no current graph produces such
a value, and it keeps the executor from inventing a colour-space interpretation. (When a non-zero clear is
genuinely needed in a later step, its domain will be pinned then.)

---

## 6. Surface / profile / MTLPixelFormat mapping — [DERIVED]

| Render-model entity | Step-10 `MTLPixelFormat` | Bound as | Notes |
|---|---|---|---|
| `pixelInput` source texture | `.bgra8Unorm` | shader-read, sampled | non-sRGB so the shader owns the entire sRGB decode (§5.1). Physical bytes are BGRA8 as stored. |
| Intermediate `bgra8SRGB` surface (incl. `linearCanvas`) | `.bgra8Unorm_srgb` | render-target (fixed-function blend) | blend unit converts sRGB↔linear automatically; source-over runs in linear light (§5.2). |
| Intermediate `rgba16FloatLinear` surface (incl. `linearCanvas`) | `.rgba16Float` | render-target (fixed-function blend) | raw linear; blend in linear light directly. |
| `sRGBSurface` (final output, `RenderSurfaceProfile.finalSRGB`) | `.bgra8Unorm` | render-target (`.replace`) → blit-readback | plain 8-bit; the shader already produced the sRGB-encoded normalized value (§5.3) — no second encode. |

This mapping is enforced against `RenderSurfaceStorageFormat`: `bgra8SRGB` → one of the two BGRA8 variants
above by role (intermediate vs final), `rgba16FloatLinear` → `.rgba16Float`. A descriptor whose
`surfaceStorage` does not match its role's expected `MTLPixelFormat` is a typed
`MetalRenderError.surfaceStorageMismatch` (defense in depth; the validator already enforces
profile↔storage at `RenderGraphValidator.swift:120–133`, so this branch is a backstop).

**Format-capability stance (correction #12):** the executor does **not** call a presumed "is this format a
supported render target" device API. A format is exercised by **actually creating** the texture and the
render-pipeline state; a genuine capability gap surfaces as a thrown `MetalRenderError` from those throwing
constructors — never a silent substitution.

**No manual channel swizzle (correction #2):** every shader returns **RGBA-semantic** `float4`. Physical
BGRA byte order in memory is produced **solely** by the `.bgra8Unorm` / `.bgra8Unorm_srgb` pixel format. The
`finalSRGB` surface is stored as **plain** `bgra8Unorm` (not `_srgb`) on purpose (§5.3 item 4): its model
`RenderSurfaceStorageFormat` is `bgra8SRGB` (`RenderGraphCommands.swift:69–75`), which the executor maps to
the plain `bgra8Unorm` attachment for the final write because the sRGB *encoding* is done in-shader. This
detail lives in `MetalColorConverter` and is pinned by the §13 channel-order test.

---

## 7. Geometry, sampling, clipping and coordinate conventions

### 7.1 Coordinate systems — [DERIVED]

- **Source pixel space:** integer pixel grid of a `ResolvedPixelInput`, origin at the **top-left**, pixel
  centers at `(i+0.5, j+0.5)`, `x` right, `y` down. Orientation is `.up` (already display-oriented;
  `ResolvedPixelInput.swift:17–27`), so no re-orientation.
- **Canvas / target-surface space:** top-left origin, `x` right, `y` down, in **points** (the transform
  outputs `CanvasScalar` raw units; §7.3 converts to pixels). This matches Task-002 placement geometry and
  the compiler's canvas (`RenderGraphCompiler.swift`).
- **Pixel-center convention:** a target pixel `(px,py)` samples at center `(px+0.5, py+0.5)`.
- **Texture-coordinate orientation:** Metal's default sample space is top-left origin `(0,0)`,
  bottom-right `(1,1)` — matching the canvas top-left convention, so **no vertical flip on sampling**. The
  one place a flip can be introduced is NDC (§7.2); §7.6 pins the orientation with an asymmetric test.
- **Canvas→NDC:** Metal clip space is `x∈[-1,1]` left→right, `y∈[-1,1]` **bottom→top**. A full-surface pass
  uses the standard mapping `ndc.x = 2·u - 1`, `ndc.y = 1 - 2·v` (v top-left), which flips y exactly once so
  that top-left canvas maps to top-left framebuffer. This single, explicit flip is the only orientation
  transform and is asserted by the 2×2 vertical-flip test.

### 7.2 Drawing a transformed image — [DERIVED]

Each `drawImage`/`drawVideoFrame` draws a unit quad covering the image's source rectangle, transformed by
the payload `FixedAffineTransform2D` (source-pixel → canvas), then canvas → NDC. The executor:

1. Computes the four source-rect corners in source-pixel space: `(0,0),(W,0),(W,H),(0,H)` (W,H = pixel
   dims), in `CanvasScalar` units (`corner_point * CanvasScalar.unitsPerPoint`? — no: source pixels are
   integer pixels; they are fed to the transform as **`CanvasScalar`-scaled** values consistent with the
   transform's input space). **[DERIVED]** Since `FixedAffineTransform2D.apply` treats inputs and the `tx,ty`
   translation as `CanvasScalar` raw units and the linear part as dimensionless, the executor maps each
   source-pixel corner to a canvas point via the **same fixed-point `apply`** used by the model
   (`FixedAffineTransform2D.swift:137–145`), computed **on the CPU in fixed point** for the four corners
   only (exact, deterministic), then divides by `CanvasScalar.unitsPerPoint` to obtain canvas points, then
   maps to NDC. Per-pixel interpolation inside the quad is the GPU's affine rasterization of those four
   exact corners; texture coordinates are the unit square. This keeps the **transform math in exact
   fixed-point** (no `Float` transform), converting to `Float` only for the four NDC corner positions at the
   upload boundary (parent §5.4: Metal `Float` only at the executor boundary).
2. Binds the source texture + a sampler (R1) + the layer `opacity` (as a `Float` uniform, derived from
   `OpacityScalar.rawValue / 1_000_000`).
3. The fragment shader samples straight→decodes→premultiplies-linear (§5.1), multiplies by `opacity`
   (premultiplied: scale rgb **and** a by opacity), and **outputs linear-light premultiplied source**. The
   **fixed-function blend unit** (§5.2) then performs source-over against the existing target — the shader
   never reads the target (§7.4). Clipping is the **hard pixel-center `MTLScissorRect`** (approved R4-A,
   §7.5); there is **no** shader-side clip coverage.

### 7.3 Fixed-point → shader-value conversion — [DERIVED]

- **Transform** is applied in fixed point on the CPU for the four quad corners (§7.2 item 1); only the
  resulting NDC positions become `Float`. Determinism: identical fixed-point inputs → identical corner
  points → identical `Float` bit patterns (the division and the canonical `* (2/ w)` mapping are pinned).
- **Opacity / colors:** `raw / 1_000_000` → `Float` uniform, computed once per command.
- **Clip rect:** converted to an integer pixel `MTLScissorRect` entirely in **fixed-point integer
  arithmetic** — no `Float` (§7.5, correction #6).
- **No fixed-point value is converted to `Float` and then back** into canonical state (parent §5.4).

### 7.4 Source-over compositing path (correction #1) — [FIXED]

Premultiplied source-over is performed by the **fixed-function blend unit** with the descriptor in §5.2.
The fragment shader **outputs linear-light premultiplied source only** and **never reads the target
texture**; the GPU blends it against the existing attachment contents. This is a valid universal Metal path
on every supported device and removes the Revision-1 read-and-write-same-texture design entirely.

Each scene writes into **one** offscreen target across its draws within a single render-command encoder, so
ordering is the encoder's draw order (the validator already guarantees draw target = the open scene target,
§1.3). **No ping-pong textures are required** because no pass reads the texture it writes. (Were a future
effect to genuinely need the just-written result as an input, the plan would mandate **separate
source/destination textures (ping-pong)** — never a same-texture read+write — but Step 10's image
composition does not need this.)

### 7.5 Rectangular clip — hard pixel-center, fixed-point (approved R4-A; Rev-2 #8, Rev-4 #5/#6) — [FIXED — approved]

`beginClip(rect:)`/`endClip` bound subsequent draws to a destination-space rectangle (`CanvasScalar` raw
units, 65,536 per point; strictly positive, `FixedGeometry.swift:16–34`). The **approved (R4-A)** policy is
a **hard pixel-center clip** realised by an integer `MTLScissorRect` — **no shader coverage, no
anti-aliasing, no `Float`**.

**Half-open inclusion rule.** Treat the clip as the half-open canvas rectangle `[x0, x1) × [y0, y1)` where
`x0 = rect.x`, `x1 = rect.x + rect.width`, `y0 = rect.y`, `y1 = rect.y + rect.height` (all `CanvasScalar`
raw). A target pixel column `px` (its center at canvas coordinate `px + 0.5` points, i.e. raw
`px·U + U/2` with `U = CanvasScalar.unitsPerPoint = 65 536`, so `U/2 = 32 768`) is **included** iff its
center lies in `[x0, x1)`:

```
include(px)  ⟺  x0 ≤ px·U + 32768  <  x1
```

Solving the two half-planes in **pure integer arithmetic** (no Float) gives the scissor bounds:

```
let U  = 65_536, H = 32_768                       // CanvasScalar.unitsPerPoint, half-pixel
// smallest px with px·U + H ≥ x0  ⟺  px ≥ (x0 − H)/U  ⟹  px_min = ceilDiv(x0 − H, U)
let pxMin = ceilDiv(x0 - H, U)
// largest px with px·U + H < x1   ⟺  px <  (x1 − H)/U ⟹  px_max = ceilDiv(x1 − H, U) − 1
let pxMax = ceilDiv(x1 - H, U) - 1
// clamp to the target's pixel grid [0, surfaceWidthPx):
let sx     = clamp(pxMin, 0, surfaceWidthPx)
let sxEnd  = clamp(pxMax + 1, 0, surfaceWidthPx)  // half-open end
let width  = max(0, sxEnd - sx)                    // 0 ⇒ EMPTY clip (no pixels) — see skip rule below
```

**`ceilDiv` without negating `Int64.min` (Rev-4 correction #6).** `ceilDiv(a, b)` for `b > 0` is defined via
**quotient/remainder**, never `-((-a)/b)` (which traps when `a == Int64.min`):
```
// q, r from Swift's truncating division: a == q*b + r, r has the sign of a, |r| < b.
let q = a / b, r = a % b              // both checked; b > 0 so neither traps
let ceil = (r > 0) ? q + 1 : q       // round toward +∞ only when there is a positive remainder
```
This is exact for every `Int64 a` including `Int64.min` (no negation of `a`), and the `q + 1` add is checked
(`CheckedInt64`). `Int64`-boundary tests pin `a ∈ {Int64.min, Int64.min+1, -1, 0, 1, Int64.max-1, Int64.max}`
for representative `b` (§13 #14b). The same formulas apply to `y0,y1 → sy, height`.

**Empty clip skips enclosed draws (Rev-4 correction #5).** When the computed clip is **empty**
(`width == 0 || height == 0`, or the nested intersection below collapses), the executor **does not set a
zero-sized `MTLScissorRect`** (a zero extent is **not** documented by Apple as a valid scissor and is not
relied upon). Instead the open clip scope records an **`isEmpty` flag**, and the dispatcher **skips every
draw command enclosed by that scope** (encodes nothing for them) until the matching `endClip`. The result —
no pixels written under an empty clip — is exact hard-clip semantics, achieved by omitting the draws, not by
trusting a degenerate scissor. `endClip` restores the previous scope's scissor (or the full-surface scissor
`(0,0,surfaceWidthPx,surfaceHeightPx)` at the outermost level).

**Nested clips:** the validator-balanced scope stack is respected; multiple open clips **intersect** as
integer scissor rects — `sx' = max(sxₐ,sx_b)`, `sxEnd' = min(sxEndₐ,sxEnd_b)`, `width' = max(0, sxEnd'−sx')`
— deterministically, still without Float. If `width' == 0 || height' == 0` the intersection is **empty** and
the enclosed draws are **skipped** by the same rule (never a zero-sized scissor). Step-10 fixtures exercise a
single clip; nested clipping has no real-template case in basic image composition, but the intersection +
empty-skip rules are defined and unit-tested.

**Why R4-A is faithful:** Task-003 fixtures are exact-pixel oracles (parent §13); real templates clip to
`slotRect` = a block canvas rect (decision register, Step-8 corrective #2) authored at whole/near-whole
points. Hard pixel-center inclusion gives **exact, integer-oracle bytes** at the clip edge and invents no
anti-aliasing the contract never asked for.

### 7.6 Behavior outside source bounds — [DERIVED]

Sampling outside `[0,1]` texture coordinates returns **transparent black** (clamp-to-zero / border).
**[DERIVED]** The sampler uses `addressMode = .clampToZero` (transparent border) so a transformed image that
does not cover a pixel contributes nothing (premultiplied transparent), which is the correct
"transparent sampling outside source bounds" behavior (test #15). This is independent of R1 (filtering).

### 7.7 Overflow and invalid coordinates — [DERIVED]

All corner transform math is the model's checked fixed-point `apply` (throws `integerOverflow` via
`FixedPointMath`), surfaced as `MetalRenderError.geometryOverflow(detail:)`. Non-finite or NaN never arise
(no `Double` in the transform). A clip rect with non-positive extent is already impossible
(`FixedRect` rejects it). A surface whose canvas-raw dimensions do not divide evenly by
`CanvasScalar.unitsPerPoint`, or whose pixel grid is non-positive, is a typed
`MetalRenderError.invalidSurfaceDimensions` (§8.4). **There is no `maxTextureDim` check** (correction #4):
the executor validates only **positivity, exact integer conversion, and checked arithmetic**; if a (valid,
positive) size exceeds the device's real texture limit, `device.makeTexture(descriptor:)` returns `nil` and
the executor reports the typed capability failure `MetalRenderError.textureAllocationFailed` — it does not
hardcode or guess a maximum.

### 7.8 Texture filtering — [FIXED — approved R1]

**Approved:** **bilinear (linear) min/mag filtering**, `addressMode = .clampToZero`, **no mipmaps**. Linear
is the conventional image-composition filter, matches scaled/rotated media expectations, and is what the
production renderer ultimately needs. (The render model/graph carry no filtering hint; this is now pinned by
R1.) **Test consequence (aligned with correction #8):**

- **Integer-aligned transforms** (identity, integer translation, integer-factor scale) where bilinear
  collapses to an exact texel copy are asserted with **exact bytes**.
- **Rotated / fractional bilinear** cases are **NOT** asserted against exact CPU-vs-GPU bytes — hardware
  filtering precision can differ. They use **bounded numeric/pixel invariants** (interior pixels within a
  tolerance of a CPU bilinear oracle; alpha monotonic across a known edge; corner pixels transparent).
  Exactness for these cases is proven only as **same-device repeatability** (§13 #23), separately from
  correctness.

---

## 8. Upload and readback design

### 8.1 Pixel upload (`MetalResourceUploader`) (corrections #1, #2) — [DERIVED, alignment from Feature Set Tables]

For each `pixelInput` descriptor (dimensions in **pixels**; `width` may be **odd**) the uploader allocates
an `MTLTexture` (`.bgra8Unorm`, `width×height`, `usage=[.shaderRead]`, storage per §8.3) and prepares its
CPU-side data **before** any command buffer exists; the **GPU copy** is encoded later, inside the single
command buffer (§8.6):

- **`.shared` path (macOS dev):** `replaceRegion(_:mipmapLevel:withBytes:bytesPerRow:)` with the input's own
  **`bytesPerRow`** verbatim. `replaceRegion` accepts an arbitrary source stride ≥ `width*4`, so a padded
  input stride and an odd width are handled directly (`PixelDimensions` validates `bytesPerRow ≥ width*4`,
  `ResolvedPixelInput.swift:60–75`). This path needs no command buffer; the texture is host-populated.
- **`.private` path (iOS / GPU-only textures) — staged, no "completes before a command buffer" claim
  (correction #1):**
  1. **Before** encoding: compute `tight = width*4`, `aligned = roundUp(tight, BLIT_ROW_ALIGN)`
     (`BLIT_ROW_ALIGN = 256`, §8.5 / correction #2); allocate a **`.shared` staging `MTLBuffer`** of
     `aligned*height`; **fill it row-by-row** on the CPU, copying **only the active `tight` bytes** of each
     source row (honoring the input's `bytesPerRow` to skip source padding) into each `aligned` destination
     row — **never copying source padding into the texture**.
  2. **During** encoding (step 7 of §8.6): the executor encodes a **buffer→texture upload blit**
     (`copy(from: stagingBuffer, sourceBytesPerRow: aligned … to: texture …)`) as the **first** encoded
     work in the command buffer, **before** the render passes.
  3. The private texture is therefore populated by the **same** command buffer that renders and reads back;
     the plan does **not** claim the upload finishes before a command buffer is created. The staging buffer
     is retained until completion (§8.6 step 11).
- **Failures:** allocation → `MetalRenderError.textureAllocationFailed`; any copy arithmetic overflow →
  `MetalRenderError.uploadFailed`.

Two tests pin this: **odd-width** upload and **padded-input-`bytesPerRow`** upload (§13 #9, #9b).

### 8.2 Offscreen allocation (`MetalTextureAllocator`) — [DERIVED]

For each `offscreenSurface` descriptor: convert canvas-raw dims to pixels (§8.4), choose the
`MTLPixelFormat` from `surfaceStorage`/role (§6), set `usage=[.renderTarget, .shaderRead]`, storage per
§8.3, and create the texture. Index by `resourceID` in the per-execute `MetalResourceOwner`.

### 8.3 Storage modes — [DERIVED]

- **iOS (device):** render targets and source textures use `.private` (GPU-only) with staging buffers for
  upload/readback; intermediate surfaces are `.private`. (`.memoryless` is **not** used — the readback path
  must blit from the final surface.)
- **macOS (M2 Pro dev):** source textures may use `.shared` for direct `replaceRegion`; render targets use
  `.private`. The final-surface readback staging buffer uses `.shared`.
- The choice is a compile-time `#if os(iOS)` / `#else` switch in the allocator/uploader; both paths are
  exercised on the M2 Pro dev build for storage that is identical, and iOS-only paths are verified at the
  later device-verification gate (parent: "Final iPhone verification is later").

### 8.4 Canvas-raw → pixel conversion — [DERIVED, load-bearing]

For an offscreen surface descriptor with `width`/`height` in `CanvasScalar` raw units (§1.4) — validation is
**positivity + exact integer conversion only**, no `maxTextureDim` (correction #4):

```
guard width  % CanvasScalar.unitsPerPoint == 0,
      height % CanvasScalar.unitsPerPoint == 0          else throw .invalidSurfaceDimensions
let pxW = width  / CanvasScalar.unitsPerPoint            // exact (remainder already ruled out)
let pxH = height / CanvasScalar.unitsPerPoint
guard pxW > 0, pxH > 0                                   else throw .invalidSurfaceDimensions
// No maximum-dimension check here. If pxW/pxH (Int64 → Int) overflow or exceed the device's real
// texture limit, the Int conversion throws (→ invalidSurfaceDimensions) or makeTexture returns nil
// (→ textureAllocationFailed). The executor never hardcodes or guesses a device maximum.
```

A `pixelInput` descriptor's `width`/`height` are **already pixels** and are used directly. This asymmetry
is the single most error-prone point and is pinned by a dedicated test (the canvas is 1080×1920; the
surface descriptor is `1080*65536 × 1920*65536`).

### 8.5 Blit-row alignment + final readback (`MetalFrameReadback`) (corrections #2, #5) — [DERIVED, documented alignment]

**Blit-row alignment constant `BLIT_ROW_ALIGN = 256` (correction #2).** Apple's **Metal Feature Set
Tables** list an implementation limit *"Buffer alignment for copying an existing texture to a buffer"*
that is **256 bytes on some GPU families and 16 bytes on others**. The executor uses the **conservative
256-byte** value as a single named constant, which satisfies **every supported iOS/macOS GPU family** for
both texture↔buffer blit directions. **`device.minimumLinearTextureAlignment(for:)` is NOT used as a
blit-row API** — per the SDK headers it governs the row alignment for *creating a linear texture from a
buffer*, a different operation. The earlier `/tmp` probe (which observed 16 on this M2 Pro) is **supplementary
evidence only** and is consistent with 256 being a safe superset; the plan does not derive the alignment
from the probe.

**Dimensions are derived from the validated final-surface descriptor (correction #5) — never hardcoded.**
The output `width`/`height` come from the `finalOutput` source surface's descriptor (its canvas-raw dims →
pixels via §8.4). Task-003 real output is 1080×1920, but a smaller valid canvas (unit tests) flows through
identically.

The blit destination stride is **aligned**, and the canonical output is **tight**, so the two differ:

- `tight = width*4`; `aligned = roundUp(tight, BLIT_ROW_ALIGN)` (= round up to 256). `width*4` is **not**
  assumed legal.
- Allocate a **`.shared`** staging `MTLBuffer` of `aligned * height` **before encoding** (§8.6 step 5).
- The texture→buffer blit `copy(from: finalTexture … to: staging …, destinationBytesPerRow: aligned,
  destinationBytesPerImage: aligned*height)` is encoded **inside the single command buffer**, as the **last**
  encoded work, before commit (§8.6 step 7).
- **After** validated completion (§8.6 step 10), **repack row-by-row** into a tight `Data` of `tight*height`:
  for each row, copy the first `tight` bytes of the `aligned`-strided staging row, dropping the alignment
  padding → canonical tightly-packed `width*4` output bytes (parent prompt "canonical tightly packed output
  bytes", "bytesPerRow policy").
- Construct `PixelDimensions(width:height:bytesPerRow: width*4, format:.bgra8, orientation:.up)` and
  `RenderedFrame(dimensions:colorContract:.task003, bytes:)`; `RenderedFrame`'s init re-validates the byte
  count and BGRA8-ness (`RenderedFrame.swift:17–34`).
- **Vertical orientation:** the canvas→NDC mapping flips y exactly once (§7.1), so framebuffer row 0 = canvas
  top; the blit produces rows top→bottom with **no extra flip**. The 2×2 asymmetric test (#8) proves no
  inadvertent flip and the **physical BGRA** byte order (not RGBA).
- **Failure handling:** a non-`.completed` status, a non-nil command-buffer error, or a byte-count mismatch
  throws a typed `MetalRenderError` and returns **no** frame.

### 8.6 Exact command-buffer sequence (correction #4) — [DERIVED]

`execute()` performs **exactly** this order (correction #1: upload blits are encoded **inside** the command
buffer, **before** the render passes; the final readback blit is encoded **last**; there is no
"complete first, then encode" ambiguity and no claim a private upload finishes before a command buffer
exists):

```
1. preflight(graph)                          // §4.1 — pure; NO per-execution texture/buffer/cmdbuf/encoded work
2. take execution guard (R3, tryLock)        // §4.2 — or throw executionAlreadyInProgress
3. allocate all pixelInput textures;         // §8.1 — host-fill .shared, OR prepare+fill .shared STAGING
   prepare CPU data / staging buffers        //        BUFFERS for .private (filled, not yet blitted)
4. allocate all offscreen + final textures   // §8.2 / §8.4
5. derive output (width,height) from the final-surface descriptor; aligned = roundUp(width*4,256); // §8.5
   ALLOCATE the readback staging MTLBuffer    // (allocated BEFORE encoding)
6. commandBuffer = submitter.makeCommandBuffer()
7. encode into the ONE command buffer, in this order:
     a. for each .private pixelInput: buffer→texture UPLOAD BLIT   // FIRST (correction #1)
     b. clears; scene begin/end (structural); image draws (fixed-function blend);
        hard-clip MTLScissorRect set/restore (R4-A); finalLinearToSRGB (full-surface .replace)
     c. final texture→staging-buffer READBACK BLIT                  // LAST
8. submitter.commitAndWait(commandBuffer)      // commit, then waitUntilCompleted EXACTLY ONCE
9. map submitter result → CommandCompletion; if .failed → throw commandBufferFailed, return no frame
10. ONLY NOW read the readback staging buffer, repack tight (§8.5), construct RenderedFrame
11. release the per-execute owner (textures, staging buffers); release the guard (defer)
```

Steps 1–5 create **no encoded GPU work**; step 7 encodes **upload blits first, then rendering, then the
readback blit**, all in one command buffer; the buffer is **committed and waited on exactly once** (step 8);
buffer memory is read **only after** validated completion (step 10). `.shared` (macOS) pixel uploads are
host-populated in step 3 and need no upload blit. This is the implementable contract behind §8.1/§8.5/§13.2.

---

## 9. Shader functions and pipeline states

### 9.1 `Shaders/AnimiEngineRender.metal` — [DERIVED]

Functions (one library, compiled once per session):

- `fullscreen_vertex(vid)` — emits a full-surface triangle/quad with top-left-correct UVs (§7.1).
- `image_vertex(...)` — transforms the four quad corners' NDC positions (positions supplied as a small
  vertex/uniform buffer computed on the CPU in fixed point, §7.2) and passes UVs.
- `image_fragment(...)` — samples source (non-sRGB), straight-decode (§5.1), sRGB→linear, premultiply
  linear, multiply by opacity, and **outputs linear-light premultiplied source**. It does **not** read the
  target — fixed-function source-over blends it (§5.2/§7.4). It carries **no** clip coverage: clipping is the
  hard `MTLScissorRect` (approved R4-A, §7.5).
- `final_srgb_fragment(...)` — full-surface; reads `linearCanvas`, straight linear, linear→sRGB encode
  (§5.3), premultiply, explicit `floor(clamp·255+0.5)/255` normalized-float quantization, outputs the
  normalized RGBA-semantic value to the `bgra8Unorm` attachment (no swizzle).
- Helper inlines: `srgb_to_linear(c)`, `linear_to_srgb(c)`, `unpremul(rgb,a)`, `premul(rgb,a)` — all using
  the exact constants from §5.1/§5.3 so the shader matches the CPU oracle bit-policy.

A missing shader function (`makeFunction(name:)` returns nil) is a typed
`MetalRenderError.missingShaderFunction(name:)`.

### 9.2 Pipeline / sampler states (`MetalPipelineLibrary`) — [DERIVED]

Built once and cached in the session, keyed by **render target `MTLPixelFormat`** (since `bgra8SRGB` and
`rgba16FloatLinear` canvases need distinct PSOs):

- `imagePSO[format]` — `image_vertex` + `image_fragment`, **fixed-function premultiplied source-over
  blending enabled** (the §5.2 descriptor: `add`/`one`/`oneMinusSourceAlpha`), color attachment 0 = the
  target format.
- `finalPSO` — `fullscreen_vertex` + `final_srgb_fragment`, target = `bgra8Unorm`, blending **disabled**
  (`.replace`; the final pass writes, never blends, §5.3).
- `sampler` — min/mag = **linear** (approved R1), `addressMode = .clampToZero`, no mip.

Pipeline creation uses `device.makeRenderPipelineState(descriptor:)` (throwing). Any failure →
`MetalRenderError.pipelineCreationFailed(detail:)`; this throwing path is also how a format-capability gap
is detected (§6, correction #12). **All pipeline creation/caching is inside the session; no global state**
(parent §8).

### 9.3 Library loading behind a `ShaderLibraryLoader` abstraction — [FIXED — approved R2] (corrections #7, #13)

**Approved (R2): runtime source compilation behind a `ShaderLibraryLoader` seam.** The `MTLLibrary` is
obtained through an **internal protocol** so a precompiled `.metallib` can replace runtime compilation later
**without touching `MetalRenderSession`**. **Step 10 implements only the protocol and the runtime loader —
NOT the precompiled loader (correction #7):**

```swift
protocol ShaderLibraryLoader {                    // package-internal
    func makeLibrary(device: MTLDevice) throws -> MTLLibrary
}
struct RuntimeSourceShaderLoader: ShaderLibraryLoader { … }   // R2: compiles the bundled .metal source — IMPLEMENTED in Step 10
// A precompiled-.metallib loader is DEFERRED: it is NOT implemented, declared, or stubbed in Step 10.
```

`MetalPipelineLibrary` takes a `ShaderLibraryLoader` (default = `RuntimeSourceShaderLoader`). The deferred
precompiled implementation will be added in a later (realtime/perf) gate by writing a new conformer and
passing it in — the executor's API and all callers stay unchanged.

**`RuntimeSourceShaderLoader` (Step 10).** Probe evidence (§1.5): under SwiftPM, `.process("Shaders")` ships
the `.metal` as **source** and `makeDefaultLibrary(bundle:)` **fails**; runtime
`device.makeLibrary(source:options:)` from the bundled source **works** and is verified green under plain
`swift test` on this toolchain. `Package.swift` adds `resources: [.process("Shaders")]` to the
`AnimiEngineMetalRender` target; `RuntimeSourceShaderLoader` reads
`Bundle.module.url(forResource:"AnimiEngineRender", withExtension:"metal")` and compiles once per session.
Resource-not-found → `MetalRenderError.shaderSourceUnavailable`; compile error →
`MetalRenderError.shaderCompilationFailed(detail:)`. Consequence: a sub-second one-time compile per session,
acceptable for Task-003's non-realtime, no-perf-claim scope (parent §1, §13).

---

## 10. Public / internal API signatures — [DERIVED]

```swift
// MetalRenderSession.swift  — the only public entry point (parent §8).
public final class MetalRenderSession {                       // NOT Sendable; internal execution guard (R3)
    /// Inject a device for tests (prompt: "explicit MTLDevice injection for tests").
    public convenience init(device: MTLDevice) throws
    /// Optional convenience (prompt: "optional convenience device creation, if justified").
    public static func makeDefault() throws -> MetalRenderSession    // MTLCreateSystemDefaultDevice, throws noMetalDevice if nil
    /// The sole contract (parent §8). Synchronous; returns only after successful GPU completion.
    /// A concurrent/reentrant call throws `executionAlreadyInProgress` (R3) — never a data race.
    public func execute(_ graph: RenderGraph) throws -> RenderedFrame

    // Package-internal designated init for tests: inject the shader loader and the command submitter
    // seam (R2 / correction #11). The public inits use the defaults.
    init(device: MTLDevice, shaderLoader: ShaderLibraryLoader, submitter: CommandSubmitter) throws
}

// CommandSubmitter.swift  (package-internal) — correction #11: separates commit/wait from status mapping
// so tests can inject a deterministic FAILED completion result without claiming to mark a real
// MTLCommandBuffer failed.
protocol CommandSubmitter {
    func makeCommandBuffer() throws -> MTLCommandBuffer
    /// Commits, waits exactly once (§8.6), and returns a mapped completion result.
    func commitAndWait(_ buffer: MTLCommandBuffer) -> CommandCompletion
}
enum CommandCompletion: Equatable { case completed; case failed(status: String, detail: String) }
struct RealCommandSubmitter: CommandSubmitter { … }            // wraps the session's MTLCommandQueue
// NOTE (Rev-4 correction #3): production CommandSubmitter.swift contains ONLY the protocol,
// CommandCompletion, and RealCommandSubmitter. The test-only StubFailingSubmitter (returns .failed
// deterministically) lives in Tests/.../MetalResourceOwnershipTests.swift, NOT in production Sources.

// ShaderLibraryLoader.swift  (package-internal, §9.3): protocol + RuntimeSourceShaderLoader ONLY.
// No PrecompiledMetallibLoader is implemented, declared, or stubbed in Step 10 (correction #7, deferred).

// MetalPipelineLibrary.swift  (package-internal)
final class MetalPipelineLibrary {
    init(device: MTLDevice, loader: ShaderLibraryLoader) throws   // compiles the library (RuntimeSourceShaderLoader by default)
    func imagePipeline(for: MTLPixelFormat) throws -> MTLRenderPipelineState   // fixed-function blend (§9.2)
    func finalPipeline() throws -> MTLRenderPipelineState
    func sampler() -> MTLSamplerState
}

// MetalTextureAllocator.swift, MetalResourceUploader.swift, MetalResourceOwner.swift,
// MetalGraphExecutor.swift, MetalSceneCompositor.swift, MetalColorConverter.swift,
// MetalFrameReadback.swift  — all package-internal (no public surface beyond the session).

// MetalRenderError.swift  (public; fills the currently-empty enum)
public enum MetalRenderError: Error, Equatable, Sendable {
    case noMetalDevice
    case executionAlreadyInProgress                                 // R3 (correction #10): concurrent/reentrant execute()
    case unsupportedFramesInFlight(value: Int)                      // preflight: framesInFlight != 1 (correction #6)
    case shaderSourceUnavailable
    case shaderCompilationFailed(detail: String)
    case missingShaderFunction(name: String)
    case pipelineCreationFailed(detail: String)                    // also the format-capability failure path (#12)
    case unsupportedCommand(category: String, step: Int, reason: String)   // deferred shape/mask/matte/transition/overlay
    case unsupportedClearColor(detail: String)                     // non-transparent-black clear (correction #7)
    case surfaceStorageMismatch(resourceID: String, detail: String)
    case invalidSurfaceDimensions(resourceID: String, width: Int64, height: Int64)
    case missingResource(resourceID: String)                        // preflight/executor backstop
    case textureAllocationFailed(resourceID: String)                // also a format-capability failure path (#12)
    case uploadFailed(resourceID: String, detail: String)
    case geometryOverflow(detail: String)
    case commandBufferFailed(status: String, detail: String)        // mapped from CommandCompletion.failed (#11)
    case readbackFailed(detail: String)
    case incompleteFrame(detail: String)                            // no partial RenderedFrame (test #20)
}
```

All payload-carried values are `Equatable`/`Sendable`; the enum is `Equatable, Sendable` (parent §9).

---

## 11. Exact files to create and modify

**File-count summary (Rev-4 correction #1):** Step 10 **creates 12 new production files** — **11 new Swift
source files + 1 Metal shader** — **modifies 1 existing production source file** (`MetalRenderError.swift`),
**modifies 1 manifest** (`Package.swift`), **modifies 3 existing test files**, and **creates 2 new test
files**. Totals:

- **Created = 14** (12 production + 2 test).
- **Modified = 5** (1 production source + 1 manifest + 3 test).

The tables below enumerate exactly these and nothing else.

### 11.1 Create — production sources in `Sources/AnimiEngineMetalRender/` (11 `.swift` + 1 shader = 12)

| # | File | Responsibility |
|---|---|---|
| 1 | `MetalRenderSession.swift` | Public entry; owns device, queue, pipeline library; preflight → execute → readback; execution guard (R3). |
| 2 | `MetalPipelineLibrary.swift` | Builds the library via a `ShaderLibraryLoader`; caches PSOs (fixed-function blend) + sampler. |
| 3 | `ShaderLibraryLoader.swift` | Loader protocol + `RuntimeSourceShaderLoader` (R2) **only**; no precompiled loader (§9.3, corrections #7/#13). |
| 4 | `CommandSubmitter.swift` | Commit/wait-once vs status-mapping seam (§8.6): the `CommandSubmitter` protocol, `CommandCompletion`, and `RealCommandSubmitter` **only**. The test-only `StubFailingSubmitter` is **not** here — it lives in `MetalResourceOwnershipTests.swift` (Rev-4 correction #3). |
| 5 | `MetalResourceOwner.swift` | Per-execute `resourceID → MTLTexture`/staging-buffer map; lifetime through completion. |
| 6 | `MetalTextureAllocator.swift` | Texture creation from descriptors; canvas-raw→pixel conversion (§8.4, positivity + exact integer only); format/usage/storage. |
| 7 | `MetalResourceUploader.swift` | `ResolvedPixelInput` bytes → texture; arbitrary/padded stride, odd widths, 256-aligned staging, active-bytes-only copy (§8.1). |
| 8 | `MetalGraphExecutor.swift` | Whole-graph preflight (§4.1); ordered dispatch; rejects deferred commands; owns the single command buffer + exact sequence (§8.6). |
| 9 | `MetalSceneCompositor.swift` | Encodes clear / image draws (fixed-function blend) / hard-clip `MTLScissorRect` (R4-A) (§7). |
| 10 | `MetalColorConverter.swift` | Encodes the final linear→sRGB `.replace` pass (§5.3). |
| 11 | `MetalFrameReadback.swift` | Final-surface blit → 256-aligned staging buffer → tight repack → `RenderedFrame` (§8.5). |
| (shader) | `Shaders/AnimiEngineRender.metal` | The MSL shader source (§9.1). |

`MetalRenderError.swift` is **not** in this create list — it already exists and is **modified** (§11.2).

**Not created in Step 10** (deferred, §2.2): `MetalMaskMatteCompositor.swift` (Step 11),
`MetalTransitionCompositor.swift` (Step 12), and any precompiled-`.metallib` loader (correction #7). No empty
stub is created for any of them. `ShaderLibraryLoader.swift` and `CommandSubmitter.swift` are **additions**
to the parent §14.5 list, justified by corrections #13 and #11 — the file-list correction the parent allows
when a necessary seam is required.

### 11.2 Modify — production + manifest (2)

| File | Change |
|---|---|
| `AnimiEngineNext/Package.swift` | Add `resources: [.process("Shaders")]` to the `AnimiEngineMetalRender` target (R2). No new target, product, or dependency edge. |
| `Sources/AnimiEngineMetalRender/MetalRenderError.swift` | Replace the empty enum with the §10 cases. |

### 11.3 Modify — existing test files (3)

| File | Change |
|---|---|
| `Tests/AnimiEngineMetalRenderTests/ColorAlphaContractTests.swift` | Add the execution proofs its header defers to step 10 (transfer/premultiply/source-over/readback). |
| `Tests/AnimiEngineMetalRenderTests/IntermediateProfileTests.swift` | Add the execution proof that profile selection is not silently substituted (both profiles render with the documented semantics). |
| `Tests/AnimiEngineMetalRenderTests/MetalTestEnvironment.swift` | Extend with a shared CPU colour/source-over/transfer oracle + small-fixture helpers (kept here per the approved file list). |

### 11.4 Create — new test files (2)

| File | Covers |
|---|---|
| `Tests/AnimiEngineMetalRenderTests/MetalResourceOwnershipTests.swift` | Lifecycle, ownership, release, no partial frame, unsupported/missing/clear-colour/framesInFlight typed errors, `CommandSubmitter` failure seam, execution guard. **Defines the test-only `StubFailingSubmitter`** (Rev-4 correction #3). |
| `Tests/AnimiEngineMetalRenderTests/MetalRepeatabilityTests.swift` | Same-device byte + `rawOutputHash` repeatability; repeated execution without stale resources. |

These two are named in the parent test list (parent §13 rows "Metal lifecycle", "Same-environment
repeatability"; parent §14.8). The geometry/colour/profile matrix lives in the three modified files above
plus these two, per the parent's "use or extend the approved test files" instruction.

### 11.5 No other files

No production source outside `Sources/AnimiEngineMetalRender/` is created or modified. No ADR, fixture,
`Resources/References/`, doc, or project file is touched in Step 10 (ADR-010 is authored at parent §17
step 18; references are promoted at step 17).

---

## 12. Complete typed error model — [DERIVED, parent §9]

The §10 `MetalRenderError` cases cover every failure surface: device, **execution-in-progress (R3)**,
**framesInFlight ≠ 1**, shader source/compile/function, pipeline (and the format-capability path, #12),
**unsupported (deferred) command**, **unsupported clear colour (#7)**, surface storage/dimensions, missing
resource, texture allocation, upload, geometry overflow, command-buffer status/error (mapped from
`CommandCompletion`, #11), readback, and "incomplete frame". On **any** error the executor stops before/at
the failing point, releases the per-execute owner (textures, buffers), releases the execution guard, and
returns the thrown error — **never** a partial `RenderedFrame`, a black frame, a previous frame, or a
placeholder (parent §9). There is **no** `try!`/`fatalError`/`precondition` on any execution path;
fixed-point math already throws (`FixedPointMath`). Every unsupported command is rejected in **preflight**
(§4.1), **before any per-execution texture, buffer, command buffer, or encoded GPU work** (correction #3/#6).

---

## 13. Test matrix — each requirement mapped to a named test

CPU oracles are independent re-implementations (parent §D3-02 allows isolated CPU reference math for
source-over and transfer functions). All Metal tests **skip** (not fail) when `MetalTestEnvironment.requireDevice`
finds no device (parent: "Metal-dependent tests may skip only when no Metal device exists"); the report
distinguishes executed / failed / skipped.

| # | Requirement (parent prompt + corrections) | Test (file → case) | Assertion kind |
|---|---|---|---|
| 1 | Exact opaque 1×1 color | `ColorAlphaContractTests.testOpaque1x1ExactColor` | exact bytes |
| 2 | Transparent pixel | `ColorAlphaContractTests.testTransparentPixelProducesTransparentOutput` | exact bytes |
| 3 | Partial-alpha premultiplied input (via `pow`/transfer) | `ColorAlphaContractTests.testPartialAlphaPremultipliedSourceOver` | **bounded** (both profiles) |
| 4 | Independent CPU oracle (source-over + sRGB transfer) | `MetalTestEnvironment.ColorOracle` (used by #1–#3, #5, #10–#14) | — |
| 5 | Multiple draw ordering (fixed-function blend) | `ColorAlphaContractTests.testMultipleDrawOrderingOverlap` | **bounded** (both profiles) |
| 6 | Both intermediate profiles | `IntermediateProfileTests.testBothProfilesRenderWithSameSemantics` | per-profile bounded oracle |
| 7 | Profile not silently substituted | `IntermediateProfileTests.testProfileSelectionIsHonoredNotSubstituted` | structural |
| 8 | Asymmetric 2×2 (physical BGRA order + vertical flip) | `ColorAlphaContractTests.testAsymmetric2x2ChannelAndOrientation` | exact bytes (opaque endpoints) |
| 9 | Padded source `bytesPerRow` | `MetalResourceOwnershipTests.testPaddedBytesPerRowUpload` | exact bytes (opaque) |
| 9b | **Odd-width** upload + 256-aligned staging (correction #2) | `MetalResourceOwnershipTests.testOddWidthUploadAndReadback` | exact bytes (opaque) |
| 10 | Identity transform | `ColorAlphaContractTests.testIdentityTransform` | exact bytes (opaque) |
| 11 | Integer translation | `ColorAlphaContractTests.testIntegerTranslation` | exact bytes (opaque) |
| 12 | Integer-factor scaling | `ColorAlphaContractTests.testIntegerScale` | exact bytes (opaque) |
| 13 | Rotation (fractional bilinear, correction #8) | `ColorAlphaContractTests.testRotationBoundedInvariants` | **bounded invariants, not exact CPU-vs-GPU bytes** |
| 14 | Rectangular clipping (hard pixel-center, R4-A) | `ColorAlphaContractTests.testHardPixelCenterClip` | **exact bytes** (opaque source; integer scissor) |
| 14a | **Empty clip skips enclosed draws** (no zero-sized scissor, Rev-4 #5) | `ColorAlphaContractTests.testEmptyClipSkipsEnclosedDraws` | exact bytes (untouched target) |
| 14b | **`ceilDiv` Int64 boundaries** (no `Int64.min` negation, Rev-4 #6) | `MetalResourceOwnershipTests.testClipCeilDivInt64Boundaries` | exact integer values |
| 15 | Transparent sampling outside source bounds | `ColorAlphaContractTests.testSamplingOutsideSourceIsTransparent` | exact bytes |
| 16 | Clear-to-transparent-black | `ColorAlphaContractTests.testClearToTransparentBlack` | exact bytes |
| 16b | Non-transparent clear fails closed (correction #7) | `MetalResourceOwnershipTests.testNonTransparentClearThrows` | typed error |
| 17 | Unsupported-command typed errors (fail in preflight) | `MetalResourceOwnershipTests.testUnsupportedCommandsThrowTyped` (shape/mask/matte/fade/slide/overlay) | typed error, no GPU work |
| 18 | Missing shader / resource typed errors | `MetalResourceOwnershipTests.testMissing{ShaderFunction,Resource}Typed` | typed error |
| 19 | Command-buffer failure via `CommandSubmitter` stub (correction #11) | `MetalResourceOwnershipTests.testCommandBufferFailureSurfacesTyped` | typed error, no frame |
| 20 | No partial frame on failure | `MetalResourceOwnershipTests.testNoPartialFrameOnFailure` | nil/throw |
| 21 | Repeated execution without stale resources | `MetalRepeatabilityTests.testRepeatedExecutionNoStaleResources` | exact bytes equal |
| 22 | Resource ownership / release after completion | `MetalResourceOwnershipTests.testResourcesReleasedAfterCompletion` | structural |
| 23 | Exact byte + `rawOutputHash` same-device repeatability | `MetalRepeatabilityTests.testExactByteAndHashRepeatability` (incl. the rotated case) | exact bytes equal |
| 24 | No wall-clock perf assertions | (negative — no timing asserts anywhere) | — |
| 25 | **framesInFlight ≠ 1 rejected** (correction #6) | `MetalResourceOwnershipTests.testFramesInFlightMustBeOne` | typed error |
| 26 | **Non-1080×1920 canvas renders** (correction #5) | `ColorAlphaContractTests.testSmallCanvasDerivedDimensions` (e.g. 7×3) | exact bytes |
| 27 | **Concurrent/reentrant execute() rejected** (correction #10, R3) | `MetalResourceOwnershipTests.testExecutionAlreadyInProgress` | typed error |

**Command-buffer-failure seam (#19) — correction #11:** the session's designated init injects a
`CommandSubmitter`. The test supplies `StubFailingSubmitter`, whose `commitAndWait` returns
`CommandCompletion.failed(...)` **deterministically**. The executor maps that to
`MetalRenderError.commandBufferFailed` and returns no frame. **No claim is made that a real
`MTLCommandBuffer` is hand-marked failed** — the abstraction separates commit/wait from status mapping, and
only the *mapping* is exercised with an injected failed result.

**Execution-guard seam (#27) — correction #10/R3:** the test injects a `CommandSubmitter` whose
`commitAndWait` blocks on a signal, starts an `execute()` on a background thread, then calls `execute()`
again on the main thread and asserts it throws `executionAlreadyInProgress` (no deadlock, no race); then
releases the signal and asserts the first call completes.

**Assertion-policy note (correction #8) — exact vs bounded.** Exact CPU-vs-GPU byte equality is asserted
**only** where the result is analytically exact:

- **Exact bytes:** opaque, integer-aligned endpoints — opaque solid colours (#1, #2, #16), opaque
  integer-aligned transforms (#8–#12), the hard pixel-center clip on an opaque source (#14, integer
  scissor), and derived-dimension/orientation/upload cases on opaque data (#9/#9b/#26). These avoid `pow`,
  partial-alpha division, and fractional filtering, so the GPU and the CPU oracle agree bit-for-bit.
- **Bounded assertions:** **any** path through `pow()` (sRGB transfer), partial-alpha unpremultiply/
  premultiply, rotation, or fractional bilinear sampling (#3, #5, #6, #13). These use a tolerance against the
  CPU oracle (tighter for `rgba16FloatLinear`, an 8-bit-quantization band for `bgra8SRGB`) and interval/
  monotonicity invariants — **never** exact CPU-vs-GPU bytes, because hardware `pow`/filtering precision can
  differ.
- **Same-device repeatability (#21, #23):** the **exact** guarantee for the bounded cases (including
  rotation) is that *re-running on the same device/build/OS reproduces identical bytes* — asserted
  separately from correctness.

With the approved **linear** filter (R1) integer-aligned transforms collapse to exact texel copies; the
approved **hard pixel-center clip** (R4-A) makes #14 an exact integer-scissor case (no coverage oracle).

---

## 14. Implementation order with green-build checkpoints — [DERIVED]

Each numbered step ends with `swift build` green and the **named** new tests green (Metal tests skip with
no device; on the M2 Pro dev box they run).

1. **Errors + seams + preflight + session skeleton (no frame yet).** Fill `MetalRenderError`; add
   `ShaderLibraryLoader` + `RuntimeSourceShaderLoader` (R2) and the production `CommandSubmitter` +
   `RealCommandSubmitter` (the test-only `StubFailingSubmitter` is added later, in the test file, Stage 6);
   add `MetalRenderSession` with the **whole-graph preflight** (§4.1: validate, framesInFlight==1, reject
   Step-11/12 commands, resource/profile/clear checks) and the **non-blocking execution guard** (R3); add
   `Package.swift` `resources: [.process("Shaders")]` + a minimal `AnimiEngineRender.metal` (fullscreen
   functions). **No allocator/readback exists yet, so Stage 1 does NOT render or round-trip a frame**
   (Rev-4 correction #4). Checkpoint: module builds; library loads (R2); tests #17 (unsupported→preflight),
   #25 (framesInFlight), #16b (clear-colour preflight rejection — no GPU work), #27 (execution guard).
2. **Allocation + clear + readback (exact §8.6 sequence) — first frame round-trip here.** `MetalTextureAllocator`
   (§8.4 conversion, positivity + exact integer only), `MetalResourceOwner`, `MetalFrameReadback` (256-aligned
   staging → tight repack), the §8.6 command sequence. **The clear/final-only frame round-trip begins in this
   stage** (Rev-4 correction #4). Checkpoint: tests #16 (clear→transparent round-trip), #26 (small
   non-1080×1920 canvas), #23 on a cleared canvas, #20/#22.
3. **Upload + image draw + fixed-function blend + colour path.** `MetalResourceUploader` (arbitrary/padded
   stride, odd width, 256-aligned staging, upload-blit-first per §8.6), `MetalSceneCompositor` image draw with
   the §5.2 blend descriptor, the `image_*` + `final_srgb_*` shaders, `MetalColorConverter`. Checkpoint:
   tests #1–#3, #5, #8–#13, #15, #18.
4. **Both profiles.** Wire `rgba16Float` and `bgra8Unorm_srgb` canvas paths + PSO-per-format. Checkpoint:
   tests #6, #7.
5. **Clipping (R4-A hard pixel-center).** Integer fixed-point `MTLScissorRect` (quotient/remainder `ceilDiv`,
   no `Int64.min` negation) + nested intersection + **empty-clip-skips-enclosed-draws** rule (§7.5); no shader
   coverage, no zero-sized scissor. Checkpoint: tests #14, #14a (empty-clip skip), #14b (ceilDiv Int64
   boundaries).
6. **Failure seam + repeatability hardening.** `StubFailingSubmitter` path, missing/overflow paths.
   Checkpoint: tests #19, #21; full `swift test` green; #24 audited (no timing asserts).

At every checkpoint the **entire** existing suite (643 + new) must remain green with 0 failures (parent
G2 regression).

---

## 15. Acceptance gates — [FIXED, parent §18 G5 specialized to Step 10]

- **A1 Isolation:** `AnimiEngineMetalRender` imports only `Metal`, `Foundation`, `AnimiEngineRenderModel`,
  `AnimiEngineRenderGraph`. No `TVECore`/`TVECompilerCore`/`AnimiApp`/`AnimiEngineTemplateAdapter`. No
  forbidden path changed.
- **A2 Build/regression:** `swift build` green, no new warnings; full `swift test` green (≥ 643 prior +
  new), 0 failures; only Metal-device-absent skips allowed.
- **A3 Color correctness:** #1–#8 pass against the CPU oracle; compositing is **fixed-function premultiplied
  source-over in linear light** (§5.2 descriptor) with **no same-texture read+write**; final UNORM
  quantization is `floor(clamp·255+0.5)/255` into `.bgra8Unorm` with **no manual swizzle** (§5.3); both
  profiles honor identical semantics (#6/#7); no double sRGB decode/encode.
- **A4 Geometry:** #10–#15, #14a, #14b, #26 pass; integer-aligned transforms and the **hard pixel-center
  clip (R4-A)** exact; an **empty clip skips enclosed draws** (no zero-sized scissor, #14a) and `ceilDiv`
  handles `Int64` boundaries without negating `Int64.min` (#14b); **rotated/fractional bilinear and any
  `pow`/partial-alpha path use bounded invariants, not exact CPU-vs-GPU bytes** (#3, #5, #13, Rev-2 #8);
  transform applied verbatim, no fit/template reinterpretation; transparent outside source bounds;
  dimensions **derived**, never hardcoded.
- **A5 Lifecycle/failure:** complete frame only after a single validated completion (§8.6); unsupported/
  missing/overflow/clear-colour/command-buffer/framesInFlight failures are typed with **no** partial frame
  (#16b–#20, #22, #25).
- **A6 Repeatability:** exact bytes + `rawOutputHash` reproduce on this device/build/OS (#21, #23), including
  the rotated case (which is exact only as same-device repeatability).
- **A7 No perf claim:** no wall-clock assertion (#24).
- **A8 Preflight + guard + sequence (corrections #1/#3/#4/#6/#10):** every unsupported command and bad input
  fails in preflight **before any per-execution texture, buffer, command buffer, or encoded GPU work**; the
  readback buffer is allocated before encoding; upload blits are encoded first and the readback blit last in
  one command buffer; commit/wait happen once (§8.6); a concurrent/reentrant `execute()` returns
  `executionAlreadyInProgress` (#27) with no data race and no `@unchecked Sendable`; clip uses a 256-aligned
  blit stride from the Feature Set Tables (correction #2).

---

## 16. Risks and deferred responsibilities

| Risk | Mitigation |
|---|---|
| `bgra8SRGB` 8-bit quantization ≠ `rgba16FloatLinear` bytes | Expected (parent item 8); tests assert **per-profile** oracles, never cross-profile byte equality. |
| Fixed-function blend on an `_srgb` attachment must blend in linear light | Verified by official sRGB-attachment semantics **and** a disposable probe (fixed-function `add`/`one`/`oneMinusSourceAlpha` into `.rgba16Float` and `.bgra8Unorm_srgb` matched the CPU linear-premultiplied source-over oracle). No same-texture read+write anywhere. |
| Hardware `pow`/bilinear precision differs from a CPU oracle | Rotation, partial-alpha and transfer paths use **bounded invariants** (correction #8); exactness for them is proven only as same-device repeatability (#23). Exact bytes are asserted solely for opaque, integer-aligned, hard-clip endpoints. |
| Blit/upload stride alignment | Uses the documented **256-byte** "Buffer alignment for copying an existing texture to a buffer" from the **Metal Feature Set Tables** (correction #2); `minimumLinearTextureAlignment(for:)` is **not** used as a blit-row API; `width*4` is never assumed legal; output is repacked tight (§8.1/§8.5). The 16-byte probe value is supplementary only. |
| Private-texture upload sequencing | Staging buffers are filled before encoding; the buffer→texture upload blit is encoded **first** in the single command buffer, before render passes (§8.1/§8.6); no claim a private upload completes before a command buffer exists (correction #1). |
| `makeLibrary(source:)` compile latency | Acceptable for non-realtime Task-003 (no perf claim); the `ShaderLibraryLoader` seam (corrections #7/#13) lets a precompiled `.metallib` replace it in a later gate with no executor change — that loader is **not** implemented in Step 10. |
| iOS-only storage paths unverified on dev box | Dev verification on M2 Pro now; **final iPhone verification deferred** (parent). `#if os(iOS)` paths are structurally present and reviewed. |
| Concurrent/reentrant `execute()` | Internal **non-blocking** execution guard returns `executionAlreadyInProgress` (R3, corrections #5/#10); the type stays non-`Sendable` and is not claimed safely transferable across concurrency domains; no data race, no `@unchecked Sendable`. |

**Deferred to Step 11:** `drawShape`, `beginMask`/`endMask`, `matteLink` pixel realization;
`MetalMaskMatteCompositor.swift`. **Deferred to Step 12:** `fadeTransition`, `slideTransition`, `overlay`;
`MetalTransitionCompositor.swift`. **Deferred later:** pooling, decoder, scheduler, cache, audio, export,
realtime, the **precompiled-`.metallib` loader** (not implemented in Step 10), perf tuning, D-208
intermediate-format winner.

---

## 17. Official primary-source bibliography

Citations used to ground the design. The **load-bearing evidence is the official Apple sources below**
(notably the Feature Set Tables for blit alignment and the MSL/pixel-format/blend docs); the disposable
`/tmp` SwiftPM probes (§1.5) are **supplementary corroboration only**. Apple's HTML doc bodies are
JS-rendered and were not always machine-readable via fetch, so some are cited by canonical URL.

1. **Metal Shading Language Specification** (Apple), PDF —
   `https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf` — MSL syntax, texture
   sampling, `[[vertex_id]]`, fragment I/O, half/float semantics (§9 shader).
2. **`MTLDevice.makeLibrary(source:options:)`** (Apple Developer Documentation) —
   `https://developer.apple.com/documentation/metal/mtldevice/1433431-makelibrary` — **synchronously**
   compiles MSL source from a string into an `MTLLibrary`, throwing on failure (approved R2). Empirically
   verified green by the probe.
3. **Building a shader library by precompiling source files** (Apple) —
   `https://developer.apple.com/documentation/metal/building-a-shader-library-by-precompiling-source-files`
   — the precompiled-`.metallib` path the `ShaderLibraryLoader` seam can adopt later (deferred; **not**
   implemented in Step 10, correction #7).
4. **`MTLPixelFormat` / `bgra8Unorm_srgb`** (Apple) —
   `https://developer.apple.com/documentation/metal/mtlpixelformat` /
   `…/mtlpixelformat/bgra8unorm_srgb` — `_srgb` variants convert between sRGB and linear; the **blend** on an
   sRGB attachment is performed in **linear** light (decode-on-read, blend-linear, encode-on-store) — the
   documented basis for §5.2/§7.4 (correction #1), corroborated by the second probe.
5. **`MTLRenderPipelineColorAttachmentDescriptor`** (Apple) —
   `https://developer.apple.com/documentation/metal/mtlrenderpipelinecolorattachmentdescriptor` — blend
   operation/factors (`.add`, `.one`, `.oneMinusSourceAlpha`) for fixed-function premultiplied source-over
   (§5.2).
6. **Metal Feature Set Tables** (Apple), PDF —
   `https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf` — implementation limit **"Buffer
   alignment for copying an existing texture to a buffer"** = **256 B** on some GPU families / 16 B on
   others; the executor uses the conservative **256 B** for the texture↔buffer blit row stride (§8.1/§8.5,
   correction #2). `minimumLinearTextureAlignment(for:)` (which governs *linear-texture creation*, **not**
   blit rows) is deliberately **not** used for this. The 16-byte probe value on the M2 Pro is supplementary
   only and consistent with 256 being a safe superset.
7. **`MTLTexture.replaceRegion(_:mipmapLevel:withBytes:bytesPerRow:)`** &
   **`MTLBlitCommandEncoder.copy(from:…to:…)`** (Apple) —
   `https://developer.apple.com/documentation/metal/mtltexture` /
   `https://developer.apple.com/documentation/metal/mtlblitcommandencoder` — arbitrary-stride host upload
   (§8.1, `.shared`) and buffer↔texture / texture→buffer blits (§8.1 `.private`, §8.5). Verified by the probe.
8. **`MTLCommandBuffer` status & `waitUntilCompleted()`** (Apple) —
   `https://developer.apple.com/documentation/metal/mtlcommandbuffer` — synchronous completion and
   `status`/`error` validation (§8.6, parent §8).
9. **`MTLRenderPassDescriptor` / `MTLScissorRect`** (Apple) —
   `https://developer.apple.com/documentation/metal/mtlrenderpassdescriptor` /
   `…/mtlscissorrect` — clear load/store actions (§3) and clip scissor (§7.5).
10. **IEC 61966-2-1 sRGB transfer functions** (canonical sRGB definition) — sRGB↔linear constants
    (thresholds 0.04045 / 0.0031308; 12.92; 1.055/0.055; exponents 2.4 / 1/2.4) used verbatim in §5.1/§5.3.
11. **Swift Package Manager — bundling resources / `Bundle.module`** (Apple/Swift) —
    `https://developer.apple.com/documentation/xcode/bundling-resources-with-a-swift-package` —
    `.process(_:)` resource handling and `Bundle.module` access (approved R2); the **observed** SwiftPM
    behavior (source copied, not compiled to `.metallib`) is recorded from the probe.

---

## 18. Forbidden-path confirmation — [FIXED]

Step 10 changes **only** files under `AnimiEngineNext/Sources/AnimiEngineMetalRender/`,
`AnimiEngineNext/Tests/AnimiEngineMetalRenderTests/`, and `AnimiEngineNext/Package.swift` (the one
`resources:` line). It does **not** touch, and only reads where the plan says:

- `TVECore/`, `AnimiApp/`, `SceneSources/`, `SharedAssets/`, any `*.xcodeproj`, any `*.pbxproj` — untouched.
- `AnimiEngineTemplateAdapter`, `TVECore`, `TVECompilerCore`, `AnimiApp` — **not** imported by
  `AnimiEngineMetalRender` (dependency edges in `Package.swift:108–113` are unchanged: RenderModel +
  RenderGraph only).
- Task-001, Task-002, Steps 1–9 contracts, `decision-register.md`, ADRs — **not** redesigned or modified.

The implementation step (not this planning pass) will record the parent §15 dirty-tree snapshot and prove
no forbidden-path byte changed.

---

## 20. Approved decisions R1–R4 — [FIXED — owner-approved]

All four are **approved**; there are **no remaining [RECOMMENDED FOR APPROVAL] decisions**. The executor
implements exactly the approved option in each case and ships no alternative fallback.

| ID | Approved decision | Section |
|---|---|---|
| **R1** | Texture sampling: **bilinear min/mag, `addressMode=.clampToZero`, no mipmaps** | §7.8 |
| **R2** | Shaders: **runtime source compilation** behind `ShaderLibraryLoader` + `RuntimeSourceShaderLoader` (no precompiled loader in Step 10) | §9.3 |
| **R3** | Concurrency: **internal non-blocking execution guard**; overlap → `executionAlreadyInProgress`; type stays non-`Sendable`; no `@unchecked Sendable` | §4.2 |
| **R4** | Clip edges: **R4-A hard pixel-center clipping** (`[x0,x1)×[y0,y1)`, include iff `p+0.5` inside; exact fixed-point scissor via quotient/remainder `ceilDiv`; an empty clip **skips** enclosed draws, never a zero-sized scissor; no Float, no AA) | §7.5 |

---

## 21. Stop rule — [FIXED]

This planning pass (Revision 4 — documentation-only) modified exactly one file:
`Docs/AnimiEngineNext/claude-task-003-step-10-plan.md`. No source, test, `Package.swift`, ADR, fixture,
documentation, or forbidden path was modified. All disposable `/tmp` feasibility probes have been removed;
they changed nothing in the repository.

**R1–R4 are recorded as owner-approved ([FIXED]).** Claude **stops here** and awaits the owner's explicit GO
to begin implementing Step 10. Implementation must not begin, and Step 11 (masks/mattes/shapes), Step 12
(transitions/overlays) and Task 004 must not be started, until that instruction is given.
