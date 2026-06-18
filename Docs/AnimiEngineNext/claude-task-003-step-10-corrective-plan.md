# Task 003 — Step 10 CORRECTIVE Implementation Plan

**Revision:** 3 — FINAL / APPROVED CANDIDATE (Step-10 implementation REJECTED pending correction)
**Status:** PLAN ONLY; awaiting owner GO. No source/test/`Package.swift`/approved-plan change in this pass.
**Approved plan it corrects:** `Docs/AnimiEngineNext/claude-task-003-step-10-plan.md` (Revision 4 — FINAL / APPROVED).
**Approved decisions preserved:** R1 (bilinear, clampToZero, no mip), R2 (runtime shader compilation behind
`ShaderLibraryLoader`), R3 (internal non-blocking execution guard), R4 (hard pixel-center clipping). **None
is reopened.**

### Revision 3 changelog (documentation-only)

1. Removed the stale §13 paragraph ("All three have clear recommended defaults …") that contradicted the
   closed status of C1–C5.
2. Pinned the normalization-pass **exact 1:1 mapping invariants** (§1.2a): viewport = full normalized size;
   `raw` and `normalized` identically sized; fragment pixel-center `(x+0.5)` over `0.5 … (size−0.5)` maps to
   the exact `uint2(x)` texel index; threaded the equal-dims assertion + viewport mandate through §1.6/§11,
   and added `testNormalization1to1MappingExact` on small **and odd** sizes (C-2a).

**Closed corrective decisions (no open decisions remain):**

| ID | Decision | Resolution |
|---|---|---|
| **C1** | Normalization mechanism | **APPROVED: render-pass normalization** (fragment shader), reading **exact texels** via `texture.read(uint2)` (correction #1) |
| **C2** | Error case for guarded encoding/base-address paths | **APPROVED: reuse `uploadFailed`/`readbackFailed`**; add **`encodingFailed`** only for render/vertex encoder-creation failures (correction #2/§12) |
| **C3** | Lifecycle proof seam | **APPROVED: package-internal `deinit` observer** on `MetalResourceOwner` proving release of engine-owned references (correction #6/#7) |

This document is a corrective plan only. It creates/updates exactly one file
(`Docs/AnimiEngineNext/claude-task-003-step-10-corrective-plan.md`) and changes no production source, test,
`Package.swift`, fixture, ADR, the approved Step-10 plan, or any forbidden path. Implementation must not
begin until the product owner instructs Claude Code to start.

All file/line references below are to the **current rejected** Step-10 implementation as committed in the
working tree.

### Revision 2 changelog (owner corrections 1–12, documentation-only)

1. Normalization reads **exact texels** (`texture.read(uint2(in.position.xy))`), never a nearest sampler /
   normalized UVs (§1.2, probe-verified).
2. Raw + normalized textures stored in a structural `PixelResourceTextures {raw, normalized}` keyed by the
   **original `resourceID`**; no synthetic ids; scene draws access **only** `normalized` (§1.4).
3. The CPU colour oracle starts from the **actual canonical `ResolvedPixelInput` bytes** (incl.
   premultiplication + 8-bit rounding) and accounts for `rgba16Float` storage precision via a justified
   tolerance (§1.5).
4. Deferred-command testing recognises **seven** categories; `endMask` is unreachable through a
   validator-valid public graph, so a **pure classification function** is extracted and unit-tested for all
   seven, plus the reachable families are tested through public `execute()` (§5).
5. Missing-resource tests are honest: undeclared resource through public `execute()` ⇒ exact
   `RenderGraphError`; `MetalRenderError.missingResource` is an **execution backstop** tested via an internal
   seam (§6).
6. Lifecycle guarantee is precise: proves release of **engine-owned references** (owner `deinit` observer)
   after success **and** failure; no claim of physical `MTLTexture`/`MTLBuffer` destruction (§7).
7. An explicit package-internal **execution-event observer** records the encoder/commit order
   (uploadBlit / normalize(resourceID) / sceneRender / finalConversion / readbackBlit / commit / completion);
   inert when nil; `CommandSubmitter` alone cannot observe encoder ordering (§7b).
8. File counts corrected: **1 created, 8 modified production** (incl. `MetalRenderError.swift`), **4 test
   files modified**, **`Package.swift` unchanged** (§11).
9. Checked-arithmetic audit extended to **every** graph/media-derived `Int` op; the report lists each
   remaining site and why it is constant-bounded or checked (§3, §9).
10. The “grep returns zero” claim is replaced by an honest code audit: comments may contain forbidden tokens;
    every match is classified as code or comment; **executable production matches must be zero** (§9).
11. Normalization regression tests prove **both** sides: corrected output within the linear-domain oracle
    tolerance **and** the old filter-first/decode-later oracle **outside** it (§1.5, C-1/C-2).
12. No open decisions remain; preserved: one command buffer, one wait, upload-first, normalization-before-
    scenes, readback-last, R1–R4, Step-11/12 exclusion (§10, §13).

---

## 0. Why the implementation is rejected (one-paragraph summary)

The colour pipeline interpolates in the wrong domain (Issue 1): `image_fragment` runs **hardware bilinear
filtering on conventional premultiplied-sRGB texels** and only *afterwards* unpremultiplies and applies the
sRGB EOTF, so scaled/rotated edges of partial-alpha media blend sRGB-encoded premultiplied bytes instead of
linear-light premultiplied values — a direct violation of the mandatory colour contract (approved plan
§5.1–§5.2, §D3-08). In addition the production code still contains force unwraps, a `try?`-with-silent-format
fallback, several trap-capable `Int` arithmetic sites on graph/media-derived sizes, a missing surface-geometry
preflight (silent resample), and tests that accept "graph construction failed" as equivalent to a typed
runtime rejection, use bare `XCTAssertThrowsError` without asserting the error type, and "prove" resource
release only by re-running. Each is corrected below with root cause, design, exact files, and tests.

---

## 1. Issue 1 — Critical colour defect: filter-first, decode-later

### 1.1 Root cause

`Sources/AnimiEngineMetalRender/Shaders/AnimiEngineRender.metal` `image_fragment` (lines 46–67):

```metal
float4 texel = src.sample(samp, in.uv);   // HARDWARE BILINEAR on premultiplied-sRGB bytes
float a = texel.a;
float3 straight_srgb = (a > 0) ? texel.rgb / a : 0;  // unpremultiply AFTER filtering
... srgb_to_linear(...) ... premul_lin = lin * a;     // decode AFTER filtering
```

The source texture is `.bgra8Unorm` (non-sRGB) holding **conventional premultiplied-sRGB** bytes (the
canonical `ResolvedPixelInput` form). `src.sample` with the approved R1 **linear** sampler performs the
bilinear weighted average **in that stored domain**. The mandatory contract (approved plan §5.1 items 1–3,
§5.2) requires source values to be **normalized to linear-light premultiplied** *before* any
interpolation/composition. Filtering premultiplied-sRGB and decoding afterwards is mathematically different
at every fractional sample (the sRGB EOTF is non-linear and unpremultiply is a per-texel division), so
partial-alpha colour edges under scaling/rotation are wrong. The per-fragment `4×pow` work also repeats the
decode for every output fragment rather than once per source texel.

This was masked in the current suite because every colour-exact test uses **opaque, integer-aligned**
fixtures where bilinear collapses to an exact texel copy (no fractional taps), and the one rotation test
asserts only a loose "centre is substantially red" bound.

### 1.2 GPU-first correction — render-pass normalization with EXACT integer reads (C1 APPROVED; correction #1)

Insert a **one-time GPU normalization render pass per uploaded pixel resource**, producing an immutable
`rgba16Float` **linear-premultiplied** source texture that the draw pass samples with the approved R1
bilinear sampler. The pipeline becomes exactly the owner-mandated chain:

```
raw BGRA8 premultiplied-sRGB texture  (.bgra8Unorm, upload target, bound access::read)
  → per-texel normalization render pass   (GPU, one pass per resource, after upload, before scenes)
  → RGBA16Float linear-premultiplied source texture  (immutable after normalization)
  → approved R1 hardware bilinear sampling (now in linear-premultiplied space — correct)
  → fixed-function linear-light source-over (unchanged, approved §5.2)
```

**Exact integer-coordinate read — NOT a nearest sampler (correction #1).** The normalization fragment runs
once per **destination texel** of the 1:1 normalized texture (a full-surface triangle covers the grid) and
reads its corresponding source texel by **integer coordinate**, never via a sampler/normalized UV:

```metal
fragment float4 normalize_fragment(FullscreenOut in [[stage_in]],
                                   texture2d<float, access::read> raw [[texture(0)]]) {
    uint2 p = uint2(in.position.xy);        // fragment pixel position → exact source texel index
    float4 t = raw.read(p);                 // EXACT integer read; no sampler, no UV, no filtering
    float a = t.a;
    float3 straight = (a > 0.0f) ? (t.rgb / a) : float3(0.0f);          // unpremultiply sRGB
    float3 lin = float3(srgb_to_linear(straight.r),
                        srgb_to_linear(straight.g),
                        srgb_to_linear(straight.b));                    // exact sRGB EOTF
    return float4(lin * a, a);                                          // premultiply in linear light
}
```

Per the §5.1 contract, for each source texel `(b,g,r,a)`: `a == 0` → **zero RGBA**; else unpremultiply the
sRGB channels, apply the exact sRGB EOTF (`srgb_to_linear`, constants unchanged), premultiply in linear
light, and write to the `rgba16Float` normalized texture. **This was verified by a disposable `/tmp` probe
on the M2 Pro** (`access::read` + `raw.read(uint2(in.position.xy))` → an `rgba16Float` render target
produced the exact linear-premultiplied value; probe removed). Because the read is by integer index, the
normalization pass does **no** interpolation — there is no sampler and no normalized-UV rounding to introduce
error.

#### 1.2a Exact 1:1 mapping invariants (correction #2 — fixed)

The normalization pass is a **strict 1:1 texel copy** with these pinned invariants. The implementation must
honour all four:

1. **Equal dimensions.** The `normalized` texture is allocated at **exactly** the `raw` texture's pixel
   dimensions (`makeNormalizedTexture(width: raw.width, height: raw.height)`); the executor asserts
   `normalized.width == raw.width && normalized.height == raw.height` for each pixel resource before encoding
   (a typed `MetalRenderError.surfaceDimensionMismatch` otherwise — fail closed, no silent resample).
2. **Viewport = full normalized size.** The normalization render pass sets its `MTLViewport` to the full
   `normalized` texture: `MTLViewport(originX: 0, originY: 0, width: Double(normalized.width), height:
   Double(normalized.height), znear: 0, zfar: 1)`. The full-surface triangle (`fullscreen_vertex`) covers the
   entire `[0, width)×[0, height)` framebuffer, so the fragment shader runs **once per destination texel**.
3. **Pixel-center → exact texel index.** With this viewport, each fragment's `in.position.xy` is the pixel
   **center**, i.e. for column/row `(x, y)` it is `(x + 0.5, y + 0.5)` over the range `0.5 … (size − 0.5)`.
   The shader computes `uint2(in.position.xy)`, whose `floor` truncation maps `x + 0.5` → exactly `x` (and
   `y + 0.5` → `y`) for every integer `x, y` in range — i.e. a **bijective** destination-texel → source-texel
   index. Because `raw` and `normalized` share dimensions (invariant 1), this index is in bounds for every
   fragment; no clamp, wrap, or out-of-range read can occur.
4. **No sampler, no normalized UV.** `raw` is bound `access::read`; `raw.read(uint2)` indexes the exact texel.
   There is no sampler state, no `[0,1]` UV, and therefore no filtering or coordinate-rounding error.

These invariants make the normalization pass an exact per-texel transform (the only arithmetic is the colour
math), so the **sole** interpolation in the whole pipeline is the approved R1 bilinear sampling of the
`normalized` texture in the draw pass — performed in the correct linear-premultiplied domain.

**Test (correction #2):** `ColorAlphaContractTests.testNormalization1to1MappingExact` proves the bijective
mapping on a **small and odd-sized** source. Build a source whose texels carry **distinct, position-encoded
opaque** colours (e.g. `r = f(x,y)`, `a = 255`) at sizes **3×1**, **1×3**, **3×3**, and **5×3** (odd widths
and heights). Draw with the **identity** transform into a canvas of the same size (opaque, integer-aligned →
exact bytes per approved Rev-4 correction #8) and assert **each** output texel equals the opaque round-trip of
**its own** source texel — proving texel `(x,y)` maps to source `(x,y)` with no off-by-one shift, flip, or
neighbour bleed. (Odd dimensions specifically catch a half-pixel/rounding error that even dimensions could
mask.)

After this pass the normalized texture holds linear-light premultiplied values, so the approved R1 **bilinear
sampling** in the draw pass is now applied **in the correct domain**, and `image_fragment` no longer decodes
— it only samples (bilinear) the normalized texture, multiplies by opacity (rgb **and** a), and outputs (the
blend unit composites). **No `pow`/unpremultiply in `image_fragment` at all.**

### 1.3 Render pass vs compute (C1 APPROVED: render pass)

**C1 is APPROVED as the render-pass (fragment-shader) normalization.** Rationale (kept for the record): the
normalization is a strict **1:1 per-texel** map; Apple guidance and community measurements show a naïve 1:1
compute kernel is **not** faster than a fragment shader for this shape (fragment shaders benefit from the
texture cache and graphics tuning; compute wins when a thread processes several items/images at once — Apple
Developer Forums, "computeEncoders vs renderEncoder", "Metal Shader Performance"). The render pass adds **no
new pipeline-state type** beyond the render PSOs already built and is **universally supported**. A compute
variant is **deferred** behind the `MetalSourceNormalizer`/`MetalPipelineLibrary` seam (replaceable later with
no executor change). **No open decision remains here.**

### 1.4 Structural raw+normalized storage, keyed by the original resourceID (correction #2)

Raw and normalized textures are stored **structurally**, never as two synthetic string keys that could
collide:

```swift
struct PixelResourceTextures {           // package-internal value
    let raw: MTLTexture                  // .bgra8Unorm upload target; bound access::read by normalization ONLY
    let normalized: MTLTexture           // .rgba16Float linear-premultiplied; the ONLY texture scene draws read
}
```

`MetalResourceOwner` holds `pixelResources: [String: PixelResourceTextures]` keyed by the **original
`resourceID`** from the `declareResource` descriptor — **no synthetic ids** are generated. (Offscreen
surfaces keep their existing `[String: MTLTexture]` map keyed by surface id.) The lifecycle:

- **session/execution-owned** — both textures allocated per `execute()` and held in the owner;
- **`normalized` immutable after normalization** — written exactly once by the normalization pass, then only
  read by `drawImage`/`drawVideoFrame`; never re-written;
- **retained through completion** — held until `commitAndWait` returns;
- **scene draws may access ONLY `normalized`** — `encodeImageDraw` binds `pixelResources[resourceID].normalized`;
  the `raw` texture is the normalization input and is **never** sampled by a scene draw. A draw that cannot
  find `pixelResources[resourceID]` throws `MetalRenderError.missingResource` (execution backstop, §6).

`usage` flags: `raw` = `[.shaderRead]` (read by normalization via `access::read`); `normalized` =
`[.renderTarget, .shaderRead]`.

### 1.5 Two-sided regression test starting from canonical bytes (corrections #3, #11)

Add partial-alpha colour-edge tests (scaling and rotation) that **catch** the rejected implementation. Both
the test and its oracle start from the **actual canonical `ResolvedPixelInput` bytes** (correction #3):

- The fixture is built through the existing `makePixelInput(...)` helper, which premultiplies the straight
  sRGB channels by alpha with **8-bit rounding** and stores conventional BGRA8 premultiplied bytes — exactly
  what the GPU uploads. The oracle reads **those stored bytes back** (`ResolvedPixelInput.bytes`), not the
  original straight colours, so the test accounts for the upload-domain premultiplication and quantization.
- Fixture: a small source (e.g. 2×2 or 4×4) with a **sharp partial-alpha colour edge** — column 0 opaque
  saturated colour `a=255`, column 1 a *different* colour at `a≈64`. Drawn **upscaled** (×3) and, separately,
  **rotated** by a non-trivial angle so bilinear taps straddle the edge.

Two CPU oracles over the **stored canonical bytes**:

1. **`linearDomainOracle`** (correct): per texel `a==0 → 0`, else unpremultiply (byte/255 ÷ a), sRGB→linear,
   premultiply-linear; **bilinearly interpolate in that linear-premultiplied domain**; composite over the
   transparent canvas; linear→sRGB encode; quantize.
2. **`filterFirstOracle`** (the rejected behaviour): bilinearly interpolate the **stored premultiplied-sRGB
   bytes first**, then unpremultiply + sRGB→linear (the current `image_fragment` order).

The tests assert **both** sides (correction #11), with a tolerance `T` that accounts for `rgba16Float`
storage precision (justified, §1.5a):

- the corrected GPU output is **within `T`** of `linearDomainOracle` (the pipeline is right), **and**
- `filterFirstOracle` differs from `linearDomainOracle` by **more than `T`** at the edge texels (so a
  filter-first implementation would be **outside** `T` and the test would fail it).

This proves the test would actually catch the rejected implementation. Named:
`ColorAlphaContractTests.testPartialAlphaColorEdgeBilinearInLinearDomain` (scaling),
`...RotationInLinearDomain` (rotation); each header states it fails under filter-first decoding and asserts
the two-sided property.

#### 1.5a Tolerance justification (correction #3)

`T` accounts for two precision sources, not for the colour math (which the oracle reproduces exactly): (a)
`rgba16Float` (IEEE half) stores the normalized linear-premultiplied values with ~10–11 bits of mantissa —
relative error ≤ 2⁻¹⁰ over `[0,1]`, i.e. ≤ ~1 LSB in the final 8-bit output for most values; (b) the
final 8-bit quantization (`floor(c*255+0.5)`) contributes ≤ 1 LSB. `T` is therefore set to a small fixed
per-channel byte tolerance (e.g. **±2/255**, refined empirically against the measured M2 Pro half-float
result and pinned in the test). The **domain gap** at a 255-vs-64 alpha colour edge under ×3 upscaling is
tens of 8-bit levels — far larger than `T` — so the two-sided assertion is unambiguous. The test documents
the measured corrected-vs-oracle max error and the measured filter-first-vs-oracle gap to show `T` separates
them with margin.

### 1.6 Files / shaders / API for Issue 1

- **Modify** `Shaders/AnimiEngineRender.metal`: add `normalize_fragment` (binds `texture2d<float,
  access::read>`, reads by `uint2(in.position.xy)` — **no sampler**, performs the §1.2 normalization, writes
  `rgba16Float`); reuse `fullscreen_vertex` for the normalization pass; **simplify** `image_fragment` to
  sample the **normalized** texture (R1 bilinear) → `×opacity` (rgb and a) → output (no unpremultiply, no
  `srgb_to_linear`, no `pow`).
- **Modify** `MetalPipelineLibrary.swift`: add `normalizePipeline()` (target `rgba16Float`, blending disabled
  `.replace`). **No nearest sampler is added** — the normalization reads by integer coordinate, so it needs
  no sampler at all (correction #1).
- **Add (new file)** `MetalSourceNormalizer.swift`: owns the per-resource normalization render-pass encoding
  (`encodeNormalization(into:raw:normalized:resourceID:) throws`). It **sets the viewport to the full
  `normalized` size** (§1.2a invariant 2) before drawing the full-surface triangle, and reports
  `encodingFailed` on encoder failure (C2). It does **not** assert equal dimensions itself — the executor
  pins that invariant in preflight (next bullet).
- **Modify** `MetalTextureAllocator.swift`: `makeNormalizedTexture(width:height:)` → `rgba16Float`,
  `[.renderTarget,.shaderRead]`, `.private`; the raw upload texture creator keeps `[.shaderRead]` (its sole
  consumer is the normalizer). The executor calls it with the **raw texture's exact pixel dimensions** so the
  two textures are identically sized (§1.2a invariant 1).
- **Modify** `MetalResourceOwner.swift`: add the structural `pixelResources: [String: PixelResourceTextures]`
  map (correction #2) + the `deinit` observer (C3, §7).
- **Modify** `MetalGraphExecutor.swift`: allocate raw + normalized per pixel resource at **equal pixel
  dimensions** and assert `normalized.width == raw.width && normalized.height == raw.height` (else typed
  `surfaceDimensionMismatch`, §1.2a invariant 1) before encoding; register the `PixelResourceTextures`; encode
  normalization passes **after** upload blits and **before** scenes (§10); `encodeImageDraw` binds the
  **normalized** texture; emit the `normalize(resourceID)` execution event (§7b).

No CPU renderer is introduced; normalization is GPU. The colour contract is unchanged — it is now *honoured*.

---

## 2. Issue 2 — Production force unwraps and silent fallbacks

### 2.1 Root cause + exact occurrences

| # | Location | Construct | Root cause |
|---|---|---|---|
| 2a | `MetalPipelineLibrary.swift:63` | `pd.colorAttachments[0]!` | force-unwrap of an implicitly-optional subscript |
| 2b | `MetalPipelineLibrary.swift:85` | `pd.colorAttachments[0]!` | same, final pipeline |
| 2c | `MetalResourceUploader.swift:34` | `raw.baseAddress!` | force-unwrap of `withUnsafeBytes` base |
| 2d | `MetalResourceUploader.swift:59` | `raw.baseAddress!` | same, staged upload |
| 2e | `MetalGraphExecutor.swift:313` | `raw.baseAddress!` | vertex bytes base |
| 2f | `MetalFrameReadback.swift:70` | `dstRaw.baseAddress!` | readback repack base |
| 2g | `MetalGraphExecutor.swift:322–324` | `(try? owner.texture(for: target))?.pixelFormat ?? .bgra8Unorm_srgb` | `try?` swallow **and** silent default format |

### 2.2 Remediation

- **2a/2b (colorAttachments[0]!):** bind via a non-throwing guard helper:
  `guard let attachment = pd.colorAttachments[0] else { throw MetalRenderError.pipelineCreationFailed(detail:
  "no color attachment 0") }`. (Apple's API returns a non-null index-0 attachment in practice; the guard makes
  the absence a typed failure rather than a trap.)
- **2c–2f (baseAddress!):** `withUnsafeBytes`/`withUnsafeMutableBytes` yield a `nil` base only for an
  **empty** buffer. Each call site already knows the size (`requiredByteCount`, `tightBytesPerRow*height`),
  which the model guarantees > 0; nonetheless replace `!` with `guard let base = raw.baseAddress else { throw
  MetalRenderError.uploadFailed/.readbackFailed(... "empty buffer") }`. For `setVertexBytes` (2e) the quad is
  always 4 vertices, but still guard and throw `geometryOverflow`/a new `encodingFailed` typed case.
- **2g (silent format default):** **the worst defect** — remove the `try?` and the `?? .bgra8Unorm_srgb`
  entirely. The render-target format must be **resolved explicitly**: the executor already knows the open
  scene's target texture (it holds `state.encoder` for a specific `target` id whose texture is in the owner).
  Resolve the format by `try owner.texture(for: target).pixelFormat` (propagating `missingResource`), and
  **fail closed** if the target is absent. There is no default. (See also §4: the target's format is further
  constrained to the profile-implied format, so a mismatch is impossible past preflight.)

### 2.3 Tests

- `MetalResourceOwnershipTests.testTargetFormatResolvedExplicitlyNoDefault`: drive an internal seam (or a
  graph whose scene target is the linearCanvas) and assert the chosen PSO format equals the linearCanvas
  texture's actual `pixelFormat` for **both** profiles (proving no `.bgra8Unorm_srgb` default leaks when the
  profile is `rgba16FloatLinear`). A draw whose target id is unresolved must throw `missingResource`, not
  silently pick a format.
- Pipeline-attachment guard: covered indirectly (any successful render proves attachment 0 exists); no force
  unwrap remains.

---

## 3. Issue 3 — Unchecked size/stride arithmetic on untrusted dimensions

### 3.1 Root cause + exact occurrences

Surface/pixel dimensions originate in the graph (and, for pixel inputs, in media). They must be treated as
untrusted; every multiply/add that can overflow `Int` must be checked.

**Complete enumeration (correction #9): every graph/media-derived `Int` arithmetic site in the module is
classified below as already-checked, to-be-checked, or constant-bounded.** This table is the master list; the
implementation report reproduces it with the final state of each site.

| # | Location | Expression | Origin | Classification → remediation |
|---|---|---|---|---|
| 3a | `MetalResourceUploader.swift:80` | `value + (alignment - r)` in `roundUp` | media width | unchecked `+` → **`roundUp` becomes `throws`**, checked add |
| 3b | `MetalResourceUploader.swift:61` | `row * dims.bytesPerRow` | media | unchecked `*` → checked offset |
| 3c | `MetalResourceUploader.swift:62` | `row * aligned` | media | unchecked `*` → checked offset |
| 3d | `MetalFrameReadback.swift:61` | `alignedBytesPerRow * height` | canvas | unchecked `*` → checked product |
| 3e | `MetalFrameReadback.swift:67` | `tightBytesPerRow * height` (`Data(count:)`) | canvas | unchecked `*` → checked product |
| 3f | `MetalFrameReadback.swift:72` | `row * alignedBytesPerRow` | canvas | unchecked `*` → checked offset |
| 3g | `MetalFrameReadback.swift:73` | `row * tightBytesPerRow` | canvas | unchecked `*` → checked offset |
| 3h | `MetalSceneCompositor.swift:78` | `a.x + a.width`, `b.x + b.width` | clip/canvas | unchecked `+` → checked (`intersect` becomes `throws`) |
| 3i | `MetalSceneCompositor.swift:79` | `a.y + a.height`, `b.y + b.height` | clip/canvas | unchecked `+` → checked |
| 3j | `MetalResourceUploader.swift:45,50` | `Int64(width)*4`, `Int64(aligned)*Int64(height)` | media/canvas | **already `CheckedInt64`** (kept) |
| 3k | `MetalFrameReadback.swift:34,39` | `Int64(width)*4`, `Int64(aligned)*Int64(height)` | canvas | **already `CheckedInt64`** (kept) |
| 3l | `MetalTextureAllocator.swift` `surfacePixelSize` | `raw % U`, `raw / U`, `Int(exactly:)` | graph surface | **already checked** (modulo/divide + `Int(exactly:)`) |
| 3m | `MetalSceneCompositor.swift` `imageQuad` corner products | `Int64(px)*U`, `transform.apply` | source px | **already `CheckedInt64`/`FixedPointMath`** (throws `geometryOverflow`) |
| 3n | `MetalSceneCompositor.swift` `axisSpan` | `lo - H`, `ceilDiv` (`q+1`) | clip raw | **already `CheckedInt64`/checked `ceilDiv`** |
| 3o | **NEW** normalization-texture dims | `makeNormalizedTexture(width:height:)` from descriptor pixel size | graph surface | reuse `surfacePixelSize` (checked, `Int(exactly:)`); positive by construction |
| 3p | **NEW** `vertexData` length / `setVertexBytes(length:)` | `quad.count * 4 * MemoryLayout<Float>.size` | constant (4 vertices) | **constant-bounded** (always 4 vertices → 64 bytes); documented as such, no graph input |
| 3q | `MemoryLayout<Float>.size` opacity bytes | constant `4` | constant | **constant-bounded** |

(Sites 3j–3n are *already* checked in the rejected tree; they are listed so the enumeration is complete and
the report can confirm none regressed. 3p/3q are genuinely constant and need no check; the report states why.)

### 3.2 Remediation

- Introduce a small checked-`Int` helper `CheckedInt.mul/add(_:_:_:) throws` wrapping
  `multipliedReportingOverflow`/`addingReportingOverflow` (or compute offsets in `Int64` via `CheckedInt64`
  and convert with `Int(exactly:)`). **`roundUp` becomes `throws`** (3a); an overflow throws
  `uploadFailed`/`readbackFailed`. All current callers already throw, so propagation is clean.
- Row offsets and products (3b–3g) use the checked helper; the pointer advance uses the checked offset;
  `Data(count:)` and `destinationBytesPerImage` use the checked product.
- Clip intersection (3h/3i): computed checked; `intersect` becomes `throws`, `pushClip`/`encodeImageDraw`
  propagate. (These cannot overflow in practice — `axisSpan` clamps to `[0, sizePx]` — but the checked form
  makes that a typed failure regardless of input.)
- Constant-bounded sites (3p/3q) are left as-is **and documented** in code comments as constant (4-vertex
  quad / fixed `Float` size); the report justifies each.

### 3.3 Tests

- `MetalResourceOwnershipTests.testRoundUpOverflowThrows`: `roundUp(Int.max - 3, to: 256)` throws (not traps).
- `...testReadbackStrideArithmeticChecked` / `...testUploadStrideArithmeticChecked`: drive the checked offset
  helper at `Int`/`Int64` boundaries and assert a typed throw, no trap.
- `...testClipIntersectionArithmeticChecked`: feed `ScissorBounds` near `Int.max` extents and assert the
  intersection helper throws rather than traps. (Pure value-level tests; no device needed.)

---

## 4. Issue 4 — Preflight surface geometry (silent resample)

### 4.1 Root cause

`RenderGraphValidator` checks only **positivity** of surface dims (`RenderGraphValidator.swift:157,166`); it
does **not** assert that `linearCanvas`/`sRGBSurface` equal the configuration output canvas, nor that scene
targets match. The executor's `final_srgb_fragment` samples the linear canvas with **normalized UVs** over a
full-surface triangle, so if the linear-canvas texture and the sRGB surface differ in size, the final pass
**silently resamples** (stretches) instead of a 1:1 copy — an undetected geometry defect. Likewise a scene
target whose dimensions differ from the canvas would draw into the wrong grid.

### 4.2 Remediation — executor preflight (plan §4.1), typed errors

Add to `MetalGraphExecutor.preflight` (before any GPU object), using the descriptors already gathered:

1. `linearCanvas` pixel dims **must equal** `configuration.output.canvas` (width,height) → else
   `MetalRenderError.surfaceDimensionMismatch(resourceID:..., expected:..., actual:...)`.
2. `sRGBSurface` pixel dims **must equal** `linearCanvas` pixel dims → same typed error.
3. **Every Step-10 scene target** (the `beginScene`/draw target) must be a declared offscreen whose pixel
   dims equal the canvas → same typed error. (In Step 10 the only scene target is the linearCanvas, but the
   check is general and fail-closed.)
4. The `finalLinearToSRGB` source/target pair must be `linearCanvas`→`sRGBSurface` (the validator already
   pins this); the executor additionally asserts their **pixel dims are equal**, so the final conversion is a
   guaranteed 1:1 copy and **never silently resamples**.

These are pure descriptor comparisons (canvas-raw → pixels via the existing exact conversion); no GPU object
is created during the check.

### 4.3 Typed error change

Add `case surfaceDimensionMismatch(resourceID: String, expectedWidth: Int64, expectedHeight: Int64,
actualWidth: Int64, actualHeight: Int64)` to `MetalRenderError` (Equatable/Sendable, like the rest).

### 4.4 Tests (negative)

- `MetalResourceOwnershipTests.testLinearCanvasMustMatchConfigurationCanvas`: a graph whose linearCanvas is
  declared at the wrong size → `surfaceDimensionMismatch` (asserted by case).
- `...testFinalSRGBMustMatchLinearCanvas`: sRGB surface declared at a different size → typed mismatch.
- `...testSceneTargetDimensionsChecked`: a scene target sized ≠ canvas → typed mismatch.
- `...testFinalConversionNeverResamples`: positive control — equal dims render a 1:1 frame (existing
  small-canvas test reused/extended).

(If the graph validator is the right home for some of these, see §6.3 on the RenderGraphError-vs-MetalRenderError
boundary; the corrective plan keeps **execution-time** geometry checks in `MetalRenderError` because they are
the executor's contract with the GPU, and leaves the structural validator unchanged.)

---

## 5. Issue 5 — Correct deferred-command testing (seven categories; classification function)

### 5.1 Root cause

`MetalResourceOwnershipTests.testUnsupportedCommandsThrowTyped` (lines 117–134) tests **only `drawShape`**
and accepts the `else` branch (`try? graphWith(...)` returning nil → "graph construction failed instead") as
equivalent evidence (line 131–133). That does not prove the **executor** rejects each deferred category.

**There are seven deferred command categories**, not six: `drawShape`, `beginMask`, `endMask`, `matteLink`,
`fadeTransition`, `slideTransition`, `overlay`. A key reachability fact (correction #4): **`endMask` can
never be reached through a validator-valid public graph**, because any balanced mask scope places `beginMask`
**before** `endMask`, and the executor's preflight scan rejects `beginMask` first. So `endMask`'s rejection
cannot be observed end-to-end through `execute()`.

### 5.2 Remediation — extract a pure classification function + two-tier testing

**(a) Extract a pure function** from the current inline preflight switch:

```swift
// MetalGraphExecutor.swift (or a small free function): pure, total, no device/IO.
static func unsupportedCommand(for payload: RenderCommandPayload)
    -> (category: String, step: Int)?    // nil ⇒ supported in Step 10
```

It returns the exact `(category.rawValue, step)` for each of the **seven** deferred categories and `nil` for
the supported set. The executor's preflight calls this for every command and throws
`MetalRenderError.unsupportedCommand` when non-nil — so production behaviour is unchanged, only refactored to
be unit-testable.

**(b) Unit-test the classification for ALL SEVEN categories — including `endMask`** (the only way to cover
`endMask` honestly):

`MetalResourceOwnershipTests.testUnsupportedCommandClassificationAllSeven` builds one payload per category
(value-model construction only — no graph, no device) and asserts the exact `(category, step)`:

| Category | step |
|---|---|
| `drawShape` | 11 |
| `beginMask` | 11 |
| `endMask` | 11 |
| `matteLink` | 11 |
| `fadeTransition` | 12 |
| `slideTransition` | 12 |
| `overlay` | 12 |

And the supported categories (`clearBackground`, `declareResource`, `offscreenSurface`, `beginScene`,
`endScene`, `drawImage`, `drawVideoFrame`, `beginClip`, `endClip`, `finalLinearToSRGB`, `finalOutput`) → `nil`.

**(c) End-to-end test the reachable feature families through public `execute()`** on **valid** graphs, each
carrying exactly one deferred command, asserting `MetalRenderError.unsupportedCommand` with the exact
`(category, step)`. The reachable families (where a validator-valid graph can place the deferred command
first in its scope) are:

| Reachable family (validator-valid graph) | Category asserted | step |
|---|---|---|
| shape draw in a scene | `drawShape` | 11 |
| mask scope (`beginMask` rejected first) | `beginMask` | 11 |
| matte link (with its required source surface) | `matteLink` | 11 |
| fade transition (two scene surfaces) | `fadeTransition` | 12 |
| slide transition (two scene surfaces) | `slideTransition` | 12 |
| overlay above the body | `overlay` | 12 |

`testReachableDeferredFamiliesRejectedByExecutor` builds the **minimal surrounding structure** each family's
validator requires so the graph genuinely constructs, then asserts the executor throws. **The test fails if
construction throws** — it never accepts "graph construction failed" as executor evidence (correction #4).
`endMask` is intentionally **absent** from the end-to-end set (unreachable) and is covered only by the
classification test (b).

> Stop rule (§17) applies if a reachable family genuinely cannot form a validator-valid graph without
> Step-11/12 graph features that do not yet exist: stop and report rather than weaken the test. (The
> classification test (b) covers all seven regardless.)

---

## 6. Issue 6 — Strengthen typed-error tests + define the error-domain boundary

### 6.1 Root cause

- `testMissingResourceTyped` (line 211) and `testMissingResource…` use bare `XCTAssertThrowsError(try
  session.execute(graph))` with **no** error-type closure, and accept a construction-time throw as equivalent
  (line 212–214).
- `IntermediateProfileTests:86` uses a bare `XCTAssertThrowsError(try { … }())` with no type check.
- The boundary between `RenderGraphError` (structural validation) and `MetalRenderError` (execution) is not
  stated, so "missing resource" could surface as either.

### 6.2 Remediation — honest missing-resource testing (correction #5)

The current `testMissingResourceTyped` is dishonest in two ways: it uses a bare untyped throw, and it
pretends a structurally valid public graph can naturally reach `MetalRenderError.missingResource`. It cannot:
the `RenderGraphValidator` (run first in preflight) rejects any draw referencing an undeclared resource as a
**`RenderGraphError`**, so `MetalRenderError.missingResource` is genuinely an **execution backstop** that a
valid public graph never reaches. The corrected tests separate the two paths:

- **Public-path test — exact `RenderGraphError`.** `testUndeclaredResourceIsRenderGraphError`: a graph whose
  `drawImage` references an undeclared resource is run through public `execute()`; assert it throws the
  **specific `RenderGraphError`** validator case (e.g. `validatorMissingResource(resourceID:)`), **not**
  `MetalRenderError`. This is the honest end-to-end behaviour.
- **Backstop test — `MetalRenderError.missingResource` via an internal seam.** `testMissingResourceBackstopViaSeam`:
  exercise `MetalResourceOwner.texture(for:)` / the executor's resource-lookup path **directly** (package-internal
  seam) with an id that was never registered, and assert `MetalRenderError.missingResource(resourceID:)` with
  the exact id. The test header states this is an internal-invariant backstop that a structurally valid public
  graph cannot reach, and does **not** claim otherwise.

Additionally: every `XCTAssertThrowsError` in the Metal test target gains a `guard case` closure asserting the
**exact** typed error — `geometryOverflow` for `ceilDiv(_,0)`/`(_,-1)`, the specific `MetalRenderError` for
profile/dimension/clear/framesInFlight cases, and the `RenderModelError`/`RenderGraphError` cases for
value-model and validator throws. No bare `XCTAssertThrowsError` remains.

### 6.3 Error-domain boundary [DECISION — fixed; no longer open]

**Rule:** *structural* graph defects are `RenderGraphError`, surfaced by `RenderGraphValidator.validate`
which the executor calls **first** in preflight. *Execution/capability* failures (device, allocation,
pipeline, format-capability, dimension mismatch vs configuration, unsupported command, clear-colour, upload,
readback) are `MetalRenderError`. The executor **does not** catch-and-remap `RenderGraphError` into
`MetalRenderError`; it lets the validator's `RenderGraphError` propagate unchanged. So:

- a *structurally invalid* graph (e.g. a draw referencing an undeclared resource) → the specific
  `RenderGraphError` validator case (public path);
- an *execution/capability* failure, or an internal-invariant violation reachable only via a seam (e.g. an
  unregistered resource in the owner) → the specific `MetalRenderError`.

Each missing/mismatch test states which domain it expects and asserts that exact case (correction #5).

---

## 7. Issue 7 — Precise lifecycle guarantee (C3 APPROVED; correction #6)

### 7.1 Root cause

`testResourcesReleasedAfterCompletion` (lines 83–94) executes the same graph twice and asserts byte equality.
That proves **repeatability**, not **deallocation** — stale resources could persist and still yield equal
bytes.

### 7.2 Remediation — `deinit` observer proving release of ENGINE-OWNED references (C3)

**C3 is APPROVED: a package-internal `deinit` observer on `MetalResourceOwner`.** The guarantee is precisely
stated (correction #6): the engine releases **all strong ownership it holds** (the `MetalResourceOwner` and
everything it retains — `PixelResourceTextures` raw+normalized, offscreen/final textures, staging buffers)
after `execute()` returns, on **both** the success and failure paths.

**Explicit non-claim (correction #6):** the test does **not** assert physical `MTLTexture`/`MTLBuffer`
destruction. Metal/the driver may retain internal references after command completion; that is outside the
engine's control. The proof is that the **engine's** strong references are gone.

Mechanism:

- `MetalResourceOwner` gains a package-internal `var onDeinit: (() -> Void)?` set only by tests; its `deinit`
  calls it. When the owner is deallocated, all resources it strongly held are released (ARC drops them with
  the owner). The test sets `onDeinit` to fulfil an expectation.
- The executor/session exposes a **minimal package-internal seam** `var onOwnerCreated: ((MetalResourceOwner)
  -> Void)?` (inert when nil) so the test can attach `onDeinit` to the exact owner that `execute()` creates,
  without changing the public API or production behaviour.

Two tests:

- `testEngineOwnedResourcesReleasedAfterSuccess`: run a real graph through `execute()`; the owner's `deinit`
  fires by the time `execute()` returns (assert via the expectation). A `weak` reference to the owner captured
  in `onOwnerCreated` is `nil` after the call.
- `testEngineOwnedResourcesReleasedAfterFailure`: inject `StubFailingSubmitter`; `execute()` throws; the
  owner's `deinit` still fires (no leak on the failure path) and the weak owner reference is `nil`.

Both test headers state the precise guarantee (engine-owned references released) and the explicit non-claim
(no assertion about driver-internal `MTLTexture`/`MTLBuffer` retention).

### 7b. Issue 7b — Explicit execution-event observer for the sequence test (correction #7)

The §8.6 ordering (one buffer, upload-first, normalize-mid, readback-last, one wait) cannot be observed by
`CommandSubmitter` alone — the submitter sees only `makeCommandBuffer`/`commitAndWait`, not the encoder order
**inside** the buffer. Add a dedicated **package-internal execution-event observer**:

```swift
enum ExecutionEvent: Equatable {              // package-internal
    case uploadBlit
    case normalize(resourceID: String)
    case sceneRender
    case finalConversion
    case readbackBlit
    case commit
    case completion
}
// On MetalGraphExecutor/MetalRenderSession, package-internal and INERT WHEN NIL:
var onExecutionEvent: ((ExecutionEvent) -> Void)?
```

The executor calls `onExecutionEvent?(…)` at each milestone (when it encodes the upload blit, each
normalization pass with its resourceID, the scene render work, the final conversion, the readback blit, and
around `commitAndWait`'s commit/completion). When `onExecutionEvent` is `nil` (production), the calls are
no-ops — **no public API change, no production behaviour change** (a single optional-closure call per
milestone, all `nil` in production).

Test `testExecutionEventOrder`: attach an observer that appends events to an array; run a graph with one pixel
resource; assert the recorded order is exactly
`[uploadBlit, normalize("<id>"), sceneRender, finalConversion, readbackBlit, commit, completion]` (with
`normalize` before `sceneRender` and `readbackBlit` after `finalConversion`). A clear-only graph (no pixel
resource) records `[sceneRender?, finalConversion, readbackBlit, commit, completion]` without an
`uploadBlit`/`normalize` (asserted accordingly). This proves the preserved invariants (§10) structurally.

---

## 8. Issue 8 — Strengthen profile-selection evidence (exact allocator mapping)

### 8.1 Root cause

`IntermediateProfileTests.testProfileSelectionIsHonoredNotSubstituted` proves only that *rendering succeeds*
for each profile and that one mismatched graph throws (bare, untyped). Successful rendering does not prove the
allocator chose the exact `MTLPixelFormat`.

### 8.2 Remediation — assert the mapping directly

`MetalTextureAllocator.surfaceFormat(for:)` is a pure, package-internal function. Test it **directly** at the
value level (no device needed for the mapping assertions):

| Descriptor | Expected `MTLPixelFormat` |
|---|---|
| intermediate `rgba16FloatLinear` surface | `.rgba16Float` |
| intermediate `bgra8SRGB` surface (linearCanvas) | `.bgra8Unorm_srgb` |
| final sRGB surface (`RenderSurface.sRGBSurface`, storage bgra8SRGB) | `.bgra8Unorm` |
| pixel-input source texture | `.bgra8Unorm` (`pixelInputFormat`) |
| **normalized** source texture (Issue 1) | `.rgba16Float` |

And **mismatch fails closed**:

- a final sRGB descriptor whose storage ≠ bgra8SRGB → `surfaceStorageMismatch` (assert the case);
- an intermediate descriptor with no `surfaceStorage` → `surfaceStorageMismatch`.

Named: `IntermediateProfileTests.testAllocatorFormatMappingExact` (+ the mismatch cases). The existing
end-to-end render tests stay as corroboration, but the **mapping** is now proven structurally.

---

## 9. Issue 9 — Full production audit (every occurrence + remediation)

The complete audit of `Sources/AnimiEngineMetalRender/` (current rejected tree):

| Construct | Occurrences (file:line) | Remediation |
|---|---|---|
| `try?` | `MetalGraphExecutor.swift:324` (format fallback) | remove; resolve format explicitly via `try owner.texture(for:).pixelFormat`, fail closed (Issue 2g) |
| `try!` | **none** | — |
| force unwrap `!` | `MetalPipelineLibrary.swift:63,85` (`colorAttachments[0]!`); `MetalResourceUploader.swift:34,59` (`baseAddress!`); `MetalGraphExecutor.swift:313` (`baseAddress!`); `MetalFrameReadback.swift:70` (`baseAddress!`) | replace each with `guard let … else { throw <typed> }` (Issue 2) |
| `fatalError` | **none** | — |
| `precondition` | **none** (removed in the original implementation) | — |
| `assertionFailure` | **none** | — |
| unchecked overflow (`*`/`+`) | `MetalResourceUploader.swift:61,62,80`; `MetalFrameReadback.swift:61,67,72,73`; `MetalSceneCompositor.swift:78,79` | checked arithmetic, `roundUp`/`intersect` become `throws` (Issue 3) |
| silent default / fallback | `MetalGraphExecutor.swift:324` (`?? .bgra8Unorm_srgb`) | remove the default; explicit resolution (Issue 2g) |
| silent resample | `final_srgb_fragment` full-surface sample with no size check | preflight surface-dimension equality (Issue 4) |
| wrong-domain filtering | `image_fragment` (whole function) | normalization pass + simplified `image_fragment` (Issue 1) |

After remediation the production module contains **zero executable** `try?`, `try!`, force unwrap on
optionals, `fatalError`, `precondition`, `assertionFailure`, unchecked trap-capable arithmetic on untrusted
sizes, or silent default/fallback. (The implicitly-unwrapped `colorAttachments[0]` becomes an explicit guard.)

**Honest audit, not a "grep returns zero" claim (correction #10).** Comments and doc-strings legitimately
contain forbidden tokens (e.g. this module's headers say "no `try!`/`fatalError`/`precondition`/trap"). The
acceptance audit therefore **lists every grep match and classifies each as executable code or comment**; the
requirement is **zero executable production matches**, not zero textual matches. The implementation report
includes:

```
# 1. Raw matches (textual — comments included):
grep -rn "try?\|try!\|fatalError\|precondition\|assertionFailure" Sources/AnimiEngineMetalRender/
grep -rn "baseAddress!\|colorAttachments\[0\]!\|\.first!\|\.last!\| as! " Sources/AnimiEngineMetalRender/
# 2. Each match is then classified in a table: file:line | token | CODE or COMMENT | justification.
```

Acceptance: **every CODE-classified match is zero**; COMMENT matches are listed with their text so the
classification is auditable (e.g. the `MetalRenderError.swift` header sentence, the audit-comment in a checked
arithmetic site). The report's classification table is the evidence, replacing any blanket "grep is clean"
assertion.

---

## 10. Preserved invariants + updated command-buffer sequence (Issue 10)

**Preserved exactly:** R1–R4; **one** command buffer and **one** `commitAndWait`; **upload blits first**;
**readback blit last**; **no Step 11/12 implementation**; **no CPU renderer**; **no forbidden-path changes**.

**New invariant:** **normalization passes run after upload and before scene rendering.** Updated §8.6 sequence:

```
1. preflight(graph)                              // §4.1 + Issue-4 surface-geometry checks; NO per-exec GPU objects
2. take execution guard (R3, tryLock)
3. allocate raw pixel textures; allocate NORMALIZED textures; allocate offscreen+final; prepare staging
4. derive output dims from the final surface; allocate readback staging buffer (before encoding)
5. commandBuffer = submitter.makeCommandBuffer()
6. encode, in ONE command buffer, in order:
     a. upload blits (buffer→raw texture)               // FIRST  (unchanged)
     b. NORMALIZATION passes (raw → normalized rgba16F)  // NEW: after upload, before scenes
     c. clears; scenes; image draws (sample NORMALIZED, bilinear, fixed-function source-over);
        hard-clip scissor; finalLinearToSRGB (.replace)
     d. readback blit (final → staging)                  // LAST  (unchanged)
7. submitter.commitAndWait(commandBuffer)                // commit + wait EXACTLY ONCE (unchanged)
8. map completion; on failure throw, no frame
9. read staging, repack tight (checked), build RenderedFrame
10. release per-execution owner (raw + normalized textures, staging buffers); release guard (defer)
```

Normalization (6b) writes each normalized texture exactly once; draws (6c) only read it. The raw upload
textures are never sampled by a scene draw. Everything else (one buffer, one wait, upload-first,
readback-last) is unchanged.

---

## 11. Exact files to create / modify (correction #8)

**Counts: 1 production file created; 8 Swift production files modified (incl. `MetalRenderError.swift`) plus
the `.metal` shader modified; 4 test files modified; `Package.swift` unchanged.** (The shader is the module's
only non-`.swift` production source; it is counted separately from the 8 Swift files, exactly as the approved
plan counted "11 Swift + 1 shader" in §11.)

### 11.1 Create — production (1 new Swift file)

| File | Responsibility |
|---|---|
| `Sources/AnimiEngineMetalRender/MetalSourceNormalizer.swift` | Encodes the per-resource normalization render pass (raw `.bgra8Unorm` read by integer coord → `rgba16Float` linear-premultiplied), **viewport = full `normalized` size** (§1.2a inv. 2), `.replace`, **no sampler** (exact `texture.read`). Reports `encodingFailed` on encoder failure. |

### 11.2 Modify — production (8 Swift files + 1 shader)

| # | File | Change |
|---|---|---|
| — | `Shaders/AnimiEngineRender.metal` *(shader, counted separately)* | Add `normalize_fragment` (binds `texture2d<float, access::read>`, reads by `uint2(in.position.xy)` — **no sampler**); reuse `fullscreen_vertex`; simplify `image_fragment` to sample the **normalized** texture (R1 bilinear) → ×opacity → output (no decode/`pow`). |
| 1 | `MetalPipelineLibrary.swift` | Add `normalizePipeline()` (target `rgba16Float`, `.replace`); guard `colorAttachments[0]` (no force unwrap). **No nearest sampler** (integer read needs none). |
| 2 | `MetalTextureAllocator.swift` | Add `makeNormalizedTexture(width:height:)` → `rgba16Float` `[.renderTarget,.shaderRead]`; raw creator keeps `[.shaderRead]`; checked dim conversions intact (3l/3o). |
| 3 | `MetalResourceOwner.swift` | Add structural `pixelResources: [String: PixelResourceTextures]` keyed by original `resourceID` (correction #2); add the `deinit` observer (C3). |
| 4 | `MetalResourceUploader.swift` | `roundUp` → `throws` (checked); checked row offsets; guard `baseAddress` (no force unwrap). |
| 5 | `MetalFrameReadback.swift` | Checked `bytesPerImage`/`Data(count:)`/row offsets; guard `baseAddress` (no force unwrap). |
| 6 | `MetalSceneCompositor.swift` | `intersect` → checked additions (`throws`); the pure `unsupportedCommand(for:)` classifier (§5a) lives here as a static free function; clip math otherwise unchanged. |
| 7 | `MetalGraphExecutor.swift` | Issue-4 surface-geometry preflight; allocate raw+normalized at **equal dims** and assert `normalized.{w,h} == raw.{w,h}` (§1.2a inv. 1, typed `surfaceDimensionMismatch`); register `PixelResourceTextures`; encode normalization (6b) before scenes; bind **normalized** texture in draws; explicit target-format resolution (remove `try?`/`??`); guard vertex `baseAddress`; propagate checked `intersect`; emit `ExecutionEvent`s (§7b); expose `onOwnerCreated` (§7). |
| 8 | `MetalRenderError.swift` | Add `surfaceDimensionMismatch(...)` (Issue 4) and `encodingFailed(detail:)` (C2 — render/vertex encoder-creation failures only). Guarded base-address paths **reuse** `uploadFailed`/`readbackFailed` (C2). |

`MetalColorConverter.swift` and `MetalRenderSession.swift` are **not** in the modified set (no change needed —
the session only gains the package-internal `onOwnerCreated`/`onExecutionEvent` seams, which are added on
`MetalGraphExecutor`; if a seam must live on the session, the report notes it and the count is restated, but
the design places the seams on the executor to keep the session untouched).

### 11.3 Modify — tests (4 files)

| File | Change |
|---|---|
| `MetalTestEnvironment.swift` | Add the partial-alpha colour-edge fixture builder reading **stored canonical bytes**; the `linearDomainOracle` and `filterFirstOracle` (correction #3/#11); minimal graph builders for the reachable deferred families (§5c); the `onOwnerCreated`/`onExecutionEvent` seam helpers. |
| `ColorAlphaContractTests.swift` | Add `testPartialAlphaColorEdgeBilinearInLinearDomain` + `...RotationInLinearDomain` (two-sided, §1.5); add `testNormalization1to1MappingExact` (3×1, 1×3, 3×3, 5×3 — §1.2a, correction #2); add typed closures to the value-model throws. |
| `IntermediateProfileTests.swift` | Add `testAllocatorFormatMappingExact` + mismatch cases (Issue 8); type the bare throw at line 86. |
| `MetalResourceOwnershipTests.swift` | Replace `testUnsupportedCommandsThrowTyped` → `testUnsupportedCommandClassificationAllSeven` + `testReachableDeferredFamiliesRejectedByExecutor` (§5); add typed closures to every `XCTAssertThrowsError`; add Issue-3 boundary tests; Issue-4 negative geometry tests; honest missing-resource tests (§6); replace `testResourcesReleasedAfterCompletion` → `testEngineOwnedResourcesReleasedAfterSuccess` + `...AfterFailure` (deinit observer, §7); `testExecutionEventOrder` (§7b); `testTargetFormatResolvedExplicitlyNoDefault` (§2g). |

### 11.5 Modify — `Package.swift`

**No change (correction #8).** `MetalSourceNormalizer.swift` lives in the already-declared
`AnimiEngineMetalRender` target; the shader is already bundled via `.process("Shaders")`. All seams are
package-internal Swift — no manifest change.

### 11.6 Forbidden / not touched

No change to `TVECore/`, `AnimiApp/`, `SceneSources/`, `SharedAssets/`, any `*.xcodeproj`/`*.pbxproj`, the
approved Step-10 plan, Task-001/002 sources, the RenderModel/RenderGraph value model, or the
`RenderGraphValidator` (the corrective work is entirely within `AnimiEngineMetalRender` + its tests). No new
package product, target, or dependency edge.

---

## 12. Typed error changes (summary; C2 closed)

| Error case | Status | Reason |
|---|---|---|
| `surfaceDimensionMismatch(resourceID:expectedWidth:expectedHeight:actualWidth:actualHeight:)` | **NEW** | Issue 4 surface-geometry preflight |
| `encodingFailed(detail: String)` | **NEW (C2 APPROVED)** | render/vertex encoder-creation failures only (e.g. `makeRenderCommandEncoder` nil); replaces the ad-hoc reuse of `pipelineCreationFailed` for encoder-creation |
| guarded `baseAddress` paths | **REUSE (C2 APPROVED)** | reuse `uploadFailed`/`readbackFailed`; **no** dedicated `emptyBuffer` case is added |
| existing cases (`missingResource`, `pipelineCreationFailed`, `unsupportedCommand`, `surfaceStorageMismatch`, `uploadFailed`, `readbackFailed`, `geometryOverflow`, `unsupportedClearColor`, `unsupportedFramesInFlight`, `textureAllocationFailed`, …) | unchanged | reused for the remediations above |

`RenderGraphError` is **unchanged**; the executor lets validator errors propagate (Issue 6.3 boundary). All
`MetalRenderError` cases remain `Equatable`/`Sendable`.

---

## 13. Closed decisions (no open decisions remain — correction #12)

| ID | Decision | Resolution (APPROVED / fixed) |
|---|---|---|
| **C1** | Normalization mechanism | **APPROVED: render pass** (fragment shader, exact integer read), §1.2–§1.3 |
| **C2** | Guarded-encoding error shape | **APPROVED: reuse `uploadFailed`/`readbackFailed`** for base-address guards; add **`encodingFailed`** only for encoder-creation failures, §12 |
| **C3** | Lifecycle-proof seam | **APPROVED: package-internal `deinit` observer** on `MetalResourceOwner` (+ `onOwnerCreated` hook), proving release of engine-owned references, §7 |
| **C4** | Classifier home / checked-`intersect` home | **fixed:** `unsupportedCommand(for:)` lives as a static free function in `MetalSceneCompositor.swift`; `intersect` becomes checked-`throws` there; the executor propagates (§11.2) |
| **C5** | Execution-event observer | **fixed:** package-internal `onExecutionEvent` on the executor, inert when nil; no public-API/production change (§7b) |

**No `[RECOMMENDED FOR APPROVAL]` decision remains.** Preserved exactly (correction #12): one command buffer,
one `commitAndWait`, upload-first, **normalization-before-scenes**, readback-last, R1–R4, and the Step-11/12
exclusion (typed `unsupportedCommand`). No CPU renderer; no forbidden-path change.

---

## 14. Regression matrix (corrective)

All Metal tests execute on the available device (Apple M2 Pro) and **skip only** when no Metal device exists;
every skip is reported explicitly. The full pre-existing suite must stay green (regression).

| # | Requirement | Test | Assertion kind |
|---|---|---|---|
| C-1 | Partial-alpha colour edge under **scaling** bilinear-in-linear; **two-sided** (Issue 1, #3/#11) | `ColorAlphaContractTests.testPartialAlphaColorEdgeBilinearInLinearDomain` | corrected ≤ T vs `linearDomainOracle` **AND** `filterFirstOracle` > T (catches the rejected impl) |
| C-2 | Same under **rotation**; two-sided | `...testPartialAlphaColorEdgeRotationInLinearDomain` | corrected ≤ T **AND** filter-first > T |
| C-2a | Normalization **1:1 texel mapping** on small + odd sizes (3×1,1×3,3×3,5×3; §1.2a, correction #2) | `ColorAlphaContractTests.testNormalization1to1MappingExact` | exact bytes (opaque, per-texel position-encoded) |
| C-3 | Existing opaque/integer-aligned exactness still holds (no regression) | existing #1–#16, #26 | exact (opaque) / bounded |
| C-4 | Scene draws sample **normalized** texture; raw never scene-sampled (correction #2) | `MetalResourceOwnershipTests.testDrawSamplesNormalizedTexture` (event/seam) | structural |
| C-5 | Allocator format mapping exact incl. **normalized→rgba16Float** (Issue 8) | `IntermediateProfileTests.testAllocatorFormatMappingExact` (+mismatch) | exact mapping / typed `surfaceStorageMismatch` |
| C-6 | Target format resolved explicitly, no default (Issue 2g) | `...testTargetFormatResolvedExplicitlyNoDefault` | structural / typed |
| C-7a | `roundUp` overflow → typed throw (Issue 3a) | `...testRoundUpOverflowThrows` | typed throw, no trap |
| C-7b | Upload/readback stride+offset overflow → typed throw (3b–3g) | `...testStrideArithmeticChecked` | typed throw, no trap |
| C-7c | Clip-intersection overflow → typed throw (3h/3i) | `...testClipIntersectionArithmeticChecked` | typed throw, no trap |
| C-8 | linearCanvas ≠ configuration canvas → `surfaceDimensionMismatch` (Issue 4) | `...testLinearCanvasMustMatchConfigurationCanvas` | typed (case asserted) |
| C-9 | sRGB ≠ linearCanvas → mismatch (Issue 4) | `...testFinalSRGBMustMatchLinearCanvas` | typed (case) |
| C-10 | scene target ≠ canvas → mismatch (Issue 4) | `...testSceneTargetDimensionsChecked` | typed (case) |
| C-11 | Final conversion never resamples (Issue 4 positive) | `...testFinalConversionNeverResamples` | exact 1:1 |
| C-12a | Classifier maps **all seven** categories incl. `endMask` (Issue 5b) | `...testUnsupportedCommandClassificationAllSeven` | exact (category, step) × 7 + supported→nil |
| C-12b | Reachable families rejected by the **executor** on valid graphs (Issue 5c) | `...testReachableDeferredFamiliesRejectedByExecutor` | typed `unsupportedCommand` (category+step); fails if construction throws |
| C-13a | Undeclared resource via public `execute()` → exact **RenderGraphError** (Issue 6) | `...testUndeclaredResourceIsRenderGraphError` | typed (validator case) |
| C-13b | `MetalRenderError.missingResource` backstop via internal seam (Issue 6) | `...testMissingResourceBackstopViaSeam` | typed (case + id) |
| C-14 | Error-domain boundary honoured (Issue 6.3) | C-13a/C-13b + per-test domain assertions | typed (domain asserted) |
| C-15 | Engine-owned references released after **success** (Issue 7, C3) | `...testEngineOwnedResourcesReleasedAfterSuccess` | owner `deinit` fired; weak owner == nil |
| C-16 | Engine-owned references released after **failure** (Issue 7, C3) | `...testEngineOwnedResourcesReleasedAfterFailure` | owner `deinit` fired; weak owner == nil |
| C-17 | Execution-event order: upload→normalize→scene→final→readback→commit→completion (Issue 7b/§10) | `...testExecutionEventOrder` | structural order (observed) |
| C-18 | Same-device byte/hash repeatability incl. rotated normalized path | existing `MetalRepeatabilityTests` (extended) | exact equal |
| C-19 | No wall-clock perf assertion anywhere | negative | — |
| C-20 | Production audit honest: every grep match classified; zero **executable** matches (Issue 9/#10) | the §9 classification table | code/comment classification |

Existing Step-10 tests are retained except `testUnsupportedCommandsThrowTyped`,
`testResourcesReleasedAfterCompletion`, and the bare-throw `testMissingResourceTyped`, which are **replaced**
by their strengthened forms (C-12a/b, C-15/16, C-13a/b).

---

## 15. Acceptance gates (corrective)

- **AC1 Colour domain (two-sided) + 1:1 normalization:** C-1/C-2 pass — corrected output within `T` of the
  linear-domain oracle **and** the filter-first oracle outside `T` (the test catches the rejected impl);
  C-2a proves the **exact 1:1 texel mapping** (viewport = full normalized size, equal raw/normalized dims,
  pixel-center `(x+0.5)` → exact `uint2(x)`) on small/odd sizes; `image_fragment` contains **no**
  `pow`/unpremultiply; normalization (exact integer read) is the only decode site; scene draws sample the
  `rgba16Float` **normalized** texture.
- **AC2 No forbidden constructs (honest audit):** the §9 classification table shows **zero executable**
  matches; every former force unwrap/`try?`/silent fallback is a typed failure; comment matches are listed.
- **AC3 Checked arithmetic:** C-7a/b/c pass; `roundUp`/stride/offset/`intersect` throw on overflow; the §3
  enumeration's every site is checked or justified constant-bounded.
- **AC4 Surface geometry:** C-8…C-11 pass; the final conversion is a proven 1:1 copy; mismatches fail closed
  in preflight before any per-execution GPU object.
- **AC5 Deferred rejection (seven categories):** C-12a classifies all seven (incl. `endMask`) and C-12b
  rejects every reachable family through `execute()` on **valid** graphs (no construction-fallback acceptance).
- **AC6 Typed errors + boundary:** C-13a/b assert the exact `RenderGraphError` (public) vs
  `MetalRenderError.missingResource` (seam backstop); every `XCTAssertThrowsError` asserts a specific case.
- **AC7 Lifetime (engine-owned only):** C-15/C-16 prove the owner's `deinit` fires after success **and**
  failure (engine-owned references released); **no** claim about driver-internal `MTLTexture`/`MTLBuffer`
  retention.
- **AC8 Profile mapping:** C-5 proves the exact allocator format mapping (incl. normalized→`rgba16Float`) and
  its fail-closed mismatches.
- **AC9 Preserved invariants:** C-17 (execution-event order) confirms one buffer / one wait / upload-first /
  **normalize-before-scenes** / readback-last; R1–R4 unchanged; no CPU renderer; no Step 11/12; no
  forbidden-path change.
- **AC10 Regression:** `swift build` green, no warnings; the **complete** `swift test` suite green, 0
  failures; only the pre-existing non-Metal skip; every Metal test executes on the device.

---

## 16. Known limitations (carried, unchanged scope)

- iOS `.private` upload/normalization/storage paths remain structurally present (`#if os(iOS)`); **final
  iPhone verification is deferred** (approved plan). Corrective verification is on the available M2 Pro.
- The compute-kernel normalization alternative is **not** implemented (C1 APPROVED: render pass); it remains a
  later perf option behind the `MetalSourceNormalizer`/`MetalPipelineLibrary` seam — a deferred option, not an
  open decision.
- The lifecycle guarantee is **release of engine-owned references** (owner `deinit`); it makes **no** claim
  about physical `MTLTexture`/`MTLBuffer` destruction, which the Metal driver controls (correction #6).
- `endMask`'s executor rejection is unreachable through a validator-valid public graph; it is covered only by
  the pure classification test (C-12a), which is the honest, complete cover for all seven categories.
- Masks/mattes/shapes (Step 11) and transitions/overlays (Step 12) remain unimplemented and are rejected with
  typed `unsupportedCommand`; this corrective pass adds **no** Step-11/12 pixel behaviour.
- Bounded colour assertions remain bounded where `pow`/partial-alpha/bilinear are involved (approved Rev-4
  correction #8); the Issue-1 tests set `T` (rgba16Float + 8-bit precision) tight enough to catch the
  wrong-domain defect but do not claim exact CPU-vs-GPU bytes for fractional cases.
- Cross-device/cross-OS numeric thresholds and reference promotion remain deferred (approved plan).

---

## 17. Stop rule

This planning pass (Revision 3 — documentation-only) modified exactly one file:
`Docs/AnimiEngineNext/claude-task-003-step-10-corrective-plan.md`. No source, test, `Package.swift`, fixture,
ADR, the approved Step-10 plan, or any forbidden path was modified. **No open decision remains** (C1–C5
closed, §13).

During corrective **implementation** (after owner GO), Claude must **stop and report** rather than weaken
scope if any of the following arises:

- a **reachable** deferred family (Issue 5c) genuinely cannot be expressed as a validator-valid graph without
  not-yet-existing Step-11/12 graph features (the classification test C-12a still covers all seven);
- the normalization render-target format or the normalized-texture bilinear path cannot satisfy the colour
  contract on the available device (would require a new architecture decision);
- making any arithmetic checked or any geometry preflight strict would require changing the RenderModel/
  RenderGraph value model or the approved plan;
- proving release of engine-owned references requires a public-API change rather than a package-internal seam.

Claude must not silently narrow a test, accept "construction failed" as a typed-rejection substitute,
reintroduce a fallback, claim physical Metal-object destruction, or begin Step 11/12, a CPU renderer,
device-evidence promotion, or performance optimization. **Stop after this corrective plan; do not implement
until instructed.**
