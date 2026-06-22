#include <metal_stdlib>
using namespace metal;

// Task-003 plan §9.1, §5.1, §5.3, §7 + corrective §1 — Step-10 Metal shaders.
//
// Colour contract (plan §D3-08, §5; corrective §1):
//   * raw source textures are bound NON-sRGB (.bgra8Unorm) and read by EXACT integer coordinate in a
//     one-time normalization pass (no sampler/UV), producing an rgba16Float linear-premultiplied texture
//     (corrective §1.2/§1.2a). The shader owns the entire sRGB decode there — exactly one decode;
//   * draws sample the NORMALIZED texture with the approved R1 bilinear sampler, now in the correct
//     linear-premultiplied domain (corrective §1.1 fix);
//   * compositing is fixed-function premultiplied source-over in linear light (plan §5.2): fragments
//     output linear-light premultiplied source, the blend unit does add/one/oneMinusSourceAlpha;
//   * the final pass encodes linear→sRGB in-shader and writes a normalized value to a plain .bgra8Unorm
//     attachment (no second encode; explicit quantization), shader returns RGBA-semantic values and the
//     pixel format alone yields physical BGRA order (plan §5.3, no manual swizzle).

// Exact sRGB transfer functions (IEC 61966-2-1; plan §5.1/§5.3, constants verbatim).
static inline float srgb_to_linear(float c) {
    return (c <= 0.04045f) ? (c / 12.92f) : pow((c + 0.055f) / 1.055f, 2.4f);
}
static inline float linear_to_srgb(float c) {
    return (c <= 0.0031308f) ? (12.92f * c) : (1.055f * pow(c, 1.0f / 2.4f) - 0.055f);
}

// ---- Image draw -------------------------------------------------------------------------------------

struct ImageVertexIn {
    // NDC position of one of the four quad corners, computed CPU-side in exact fixed point (plan §7.2/§7.3).
    float2 ndc;
    float2 uv;
};

struct ImageVertexOut {
    float4 position [[position]];
    float2 uv;
};

// Four-corner quad: the CPU supplies 4 vertices (a triangle strip) with NDC + UV. The transform is
// already applied on the CPU in fixed point; the GPU only rasterizes the affine quad (plan §7.2).
vertex ImageVertexOut image_vertex(uint vid [[vertex_id]],
                                   const device ImageVertexIn *verts [[buffer(0)]]) {
    ImageVertexOut out;
    out.position = float4(verts[vid].ndc, 0.0f, 1.0f);
    out.uv = verts[vid].uv;
    return out;
}

fragment float4 image_fragment(ImageVertexOut in [[stage_in]],
                               texture2d<float> normalizedSrc [[texture(0)]],
                               sampler samp [[sampler(0)]],
                               constant float &opacity [[buffer(0)]]) {
    // The bound texture is the NORMALIZED rgba16Float texture: it already holds linear-light premultiplied
    // values (corrective §1.2). Bilinear sampling here is therefore in the correct domain — NO decode,
    // NO unpremultiply, NO pow (corrective §1.1 fix).
    float4 premul_lin = normalizedSrc.sample(samp, in.uv);
    // Layer opacity scales premultiplied rgb AND alpha (plan §7.2 item 3).
    premul_lin *= opacity;
    // Output linear-light premultiplied source; the fixed-function blend unit composites (plan §5.2).
    return premul_lin;
}

// ---- Full-surface final conversion -----------------------------------------------------------------

struct FullscreenOut {
    float4 position [[position]];
    float2 uv;
};

// A full-surface triangle covering NDC; UVs are top-left origin (plan §7.1). vid 0,1,2.
vertex FullscreenOut fullscreen_vertex(uint vid [[vertex_id]]) {
    // Oversized triangle: positions (-1,-1),(-1,3),(3,-1) cover the [-1,1]^2 viewport.
    float2 pos[3] = { float2(-1.0f, -1.0f), float2(-1.0f, 3.0f), float2(3.0f, -1.0f) };
    // UVs chosen so the visible [-1,1] region maps to [0,1] with v top-left (row 0 = canvas top).
    float2 uv[3] = { float2(0.0f, 1.0f), float2(0.0f, -1.0f), float2(2.0f, 1.0f) };
    FullscreenOut out;
    out.position = float4(pos[vid], 0.0f, 1.0f);
    out.uv = uv[vid];
    return out;
}

// ---- Source normalization (corrective §1.2/§1.2a) --------------------------------------------------
//
// One pass per uploaded pixel resource: reads the raw .bgra8Unorm premultiplied-sRGB texel by EXACT
// integer coordinate (no sampler, no UV) and writes the rgba16Float linear-light premultiplied value.
// The executor sets the viewport to the full normalized size, so each fragment's pixel-center
// `in.position.xy == (x+0.5, y+0.5)` truncates to exactly `uint2(x, y)` — a bijective 1:1 texel map
// (§1.2a). `raw` and `normalized` share dimensions, so the read is always in bounds.
// CP7.8 — orientation parameters (must match Swift `MetalSourceNormalizer.NormalizeParams`). For
// `quarterTurns == 0` the source map is identity (`src == dst`), byte-identical to the pre-CP7.8 pass.
struct NormalizeParams {
    uint quarterTurns;   // 0/1/2/3 clockwise (raw → display)
    uint rawWidth;
    uint rawHeight;
    uint pad;
};

fragment float4 normalize_fragment(FullscreenOut in [[stage_in]],
                                   texture2d<float, access::read> raw [[texture(0)]],
                                   constant NormalizeParams &params [[buffer(0)]]) {
    uint2 d = uint2(in.position.xy);        // destination (display/normalized) texel index
    // Map the DISPLAY texel back to the RAW source texel by the INVERSE clockwise quarter-turn — the
    // exact inverse of the CPU oracle `NextVideoBlockResolver.rotateBGRA` (top-first index remap), so the
    // GPU-oriented output is bit-identical in layout to the CPU bake for 0/90/180/270. quarterTurns==0 is
    // the identity map (every bytes input) — pixel-for-pixel the pre-CP7.8 pass.
    uint w = params.rawWidth, h = params.rawHeight;
    uint2 p;
    switch (params.quarterTurns) {
        case 1u: p = uint2(d.y, (h - 1u) - d.x); break;            // 90° CW : dst(dx,dy) ← src(dy, h-1-dx)
        case 2u: p = uint2((w - 1u) - d.x, (h - 1u) - d.y); break; // 180°
        case 3u: p = uint2((w - 1u) - d.y, d.x); break;            // 270° CW
        default: p = d; break;                                      // 0° : identity (bytes path)
    }
    float4 t = raw.read(p);                 // EXACT integer read; no sampler, no UV, no filtering
    float a = t.a;
    // alpha == 0 ⇒ zero RGBA (corrective §1.2 / plan §5.1 item 1/2).
    float3 straight = (a > 0.0f) ? (t.rgb / a) : float3(0.0f);    // unpremultiply sRGB
    float3 lin = float3(srgb_to_linear(straight.r),
                        srgb_to_linear(straight.g),
                        srgb_to_linear(straight.b));               // exact sRGB EOTF
    return float4(lin * a, a);                                     // premultiply in linear light
}

// ---- Step-11: shape/mask coverage + apply, matte (Rev-4 §7/§8) -------------------------------------
//
// Coverage geometry (fills, strokes, mask paths) is rasterized into a 4x-MSAA single-channel r16Float
// target writing constant 1.0, blending DISABLED (replacement). The MSAA resolve to a single-sample
// r16Float texture yields exact resolve fractions 0/0.25/0.5/0.75/1.0 for 0..4 covered samples. The
// resolved coverage then modulates colour (fill/stroke) or content (mask) or matte in a separate pass.

struct CoverageVertexIn {
    float2 ndc;     // pre-transformed NDC position (CPU fixed-point → NDC, like the image quad)
};

struct CoverageVertexOut {
    float4 position [[position]];
};

vertex CoverageVertexOut coverage_vertex(uint vid [[vertex_id]],
                                         const device CoverageVertexIn *verts [[buffer(0)]]) {
    CoverageVertexOut out;
    out.position = float4(verts[vid].ndc, 0.0f, 1.0f);
    return out;
}

// Writes constant coverage 1.0 (the MSAA unit resolves partial edge samples). Single channel.
fragment float coverage_fragment(CoverageVertexOut in [[stage_in]]) {
    return 1.0f;
}

// Fill/stroke colour application: a full-surface pass that reads the resolved coverage at the fragment
// and the authored straight-sRGB colour + effective alpha (premultiplied source-over composites it).
struct ShapeApplyParams {
    float r;        // straight sRGB red   [0,1]
    float g;        // straight sRGB green [0,1]
    float b;        // straight sRGB blue  [0,1]
    float alpha;    // effective alpha (colour alpha × style opacity × group opacity × draw opacity)
};

fragment float4 shape_apply_fragment(FullscreenOut in [[stage_in]],
                                     texture2d<float, access::read> coverage [[texture(0)]],
                                     constant ShapeApplyParams &params [[buffer(0)]]) {
    uint2 p = uint2(in.position.xy);
    float cov = clamp(coverage.read(p).r, 0.0f, 1.0f);
    // sRGB → linear, premultiply by (alpha × coverage). Output linear-premultiplied source.
    float3 lin = float3(srgb_to_linear(params.r), srgb_to_linear(params.g), srgb_to_linear(params.b));
    float a = params.alpha * cov;
    return float4(lin * a, a);
}

// Mask combine: reads the running accumulator and this operation's resolved coverage, applies the fixed
// order (clamp → invert → opacity → mode), writes the new accumulator. Reproduces the TVECore oracle.
struct MaskCombineParams {
    int mode;       // 0=add, 1=subtract, 2=intersect
    int inverted;   // 1 → coverage = 1 - coverage
    float opacity;  // coverage *= opacity
    int isFirst;    // 1 → ignore accumIn and seed by mode (add→0, subtract/intersect→1)
};

fragment float mask_combine_fragment(FullscreenOut in [[stage_in]],
                                     texture2d<float, access::read> coverageTex [[texture(0)]],
                                     texture2d<float, access::read> accumInTex [[texture(1)]],
                                     constant MaskCombineParams &params [[buffer(0)]]) {
    uint2 gid = uint2(in.position.xy);
    float cov = clamp(coverageTex.read(gid).r, 0.0f, 1.0f);
    if (params.inverted != 0) { cov = 1.0f - cov; }
    cov *= params.opacity;
    float acc;
    if (params.isFirst != 0) {
        acc = (params.mode == 0) ? 0.0f : 1.0f;   // add→0, subtract/intersect→1
    } else {
        acc = accumInTex.read(gid).r;
    }
    float result;
    if (params.mode == 0)      { result = max(acc, cov); }       // add
    else if (params.mode == 1) { result = acc * (1.0f - cov); }  // subtract
    else                       { result = min(acc, cov); }       // intersect
    return result;
}

// Mask content application: multiply the isolated content's premultiplied rgb AND alpha by the aggregate
// coverage, output linear-premultiplied source (the blend unit source-over composites into target).
fragment float4 mask_apply_fragment(FullscreenOut in [[stage_in]],
                                    texture2d<float> content [[texture(0)]],
                                    sampler samp [[sampler(0)]],
                                    texture2d<float, access::read> coverage [[texture(1)]]) {
    uint2 p = uint2(in.position.xy);
    float cov = clamp(coverage.read(p).r, 0.0f, 1.0f);
    float4 c = content.sample(samp, in.uv);   // linear-premultiplied content
    return c * cov;                            // modulate premultiplied rgb AND alpha by coverage
}

// Matte application: coverage from the source surface (alpha or Rec.709 linear luma, possibly inverted),
// multiply the consumer's premultiplied rgb AND alpha by it. Source is already premultiplied → NO
// unpremultiply (a transparent bright source contributes zero coverage).
struct MatteParams {
    int mode;       // 1=alpha, 2=alphaInverted, 3=luma, 4=lumaInverted
};

fragment float4 matte_apply_fragment(FullscreenOut in [[stage_in]],
                                    texture2d<float> consumer [[texture(0)]],
                                    sampler samp [[sampler(0)]],
                                    texture2d<float> source [[texture(1)]],
                                    constant MatteParams &params [[buffer(0)]]) {
    float4 src = source.sample(samp, in.uv);       // already linear-premultiplied
    float4 con = consumer.sample(samp, in.uv);     // already linear-premultiplied
    float cov;
    if (params.mode == 1) {            // alpha
        cov = src.a;
    } else if (params.mode == 2) {     // alphaInverted
        cov = 1.0f - src.a;
    } else if (params.mode == 3) {     // luma — Rec.709 in linear light, NO unpremultiply
        cov = 0.2126f * src.r + 0.7152f * src.g + 0.0722f * src.b;
    } else {                           // lumaInverted
        cov = 1.0f - (0.2126f * src.r + 0.7152f * src.g + 0.0722f * src.b);
    }
    cov = clamp(cov, 0.0f, 1.0f);
    return con * cov;                  // modulate premultiplied rgb AND alpha; blend unit source-over
}

// ---- Step-12: fade / slide transition composites (Rev-1 §3.2/§3.3, R1/R2/R3) ----------------------
//
// Both are SINGLE full-surface `.replace` passes (R1): the fragment reads both already-rendered scene
// surfaces (linear-premultiplied) and emits the final composited value itself; the target attachment uses
// `.clear`/`.store` with blending disabled, so there is no double-counting. No sRGB decode here — the one
// final conversion pass remains the only encode.

// Fade: a premultiplied cross-dissolve. `progress` is the graph's eased UnitInterval in [0,1]. Because both
// inputs are premultiplied, the straight linear interpolation of premultiplied RGBA is the correct
// dissolve (a transparent region contributes nothing). progress 0 → outgoing; progress 1 → incoming.
fragment float4 fade_fragment(FullscreenOut in [[stage_in]],
                              texture2d<float> outgoing [[texture(0)]],
                              sampler samp [[sampler(0)]],
                              texture2d<float> incoming [[texture(1)]],
                              constant float &progress [[buffer(0)]]) {
    float4 out0 = outgoing.sample(samp, in.uv);   // linear-premultiplied
    float4 in1 = incoming.sample(samp, in.uv);    // linear-premultiplied
    return mix(out0, in1, clamp(progress, 0.0f, 1.0f));
}

// Slide (R2): the outgoing surface stays in place; the incoming surface is sampled SHIFTED by `offsetUV`
// (normalized UV, derived CPU-side from the graph's exact canvas-raw offset). Off-edge samples of the
// shifted incoming are transparent via the clampToZero sampler. The incoming is composited source-over the
// stationary outgoing, in linear-premultiplied light: `src + bg·(1 − src.a)`.
fragment float4 slide_fragment(FullscreenOut in [[stage_in]],
                               texture2d<float> outgoing [[texture(0)]],
                               sampler samp [[sampler(0)]],
                               texture2d<float> incoming [[texture(1)]],
                               constant float2 &offsetUV [[buffer(0)]]) {
    float4 bg = outgoing.sample(samp, in.uv);                 // stationary outgoing (linear-premultiplied)
    float4 src = incoming.sample(samp, in.uv - offsetUV);     // shifted incoming; clampToZero → 0 off-edge
    return src + bg * (1.0f - src.a);                          // premultiplied source-over
}

// CP5.5 push: BOTH scenes move. offsets.xy shifts outgoing, offsets.zw shifts incoming (UV space).
// Each surface is sampled at `uv - offset`, so a positive offset moves that surface in the positive
// direction; off-edge samples are transparent (clampToZero). The incoming composites source-over the
// (also-moving) outgoing in premultiplied space.
fragment float4 push_fragment(FullscreenOut in [[stage_in]],
                              texture2d<float> outgoing [[texture(0)]],
                              sampler samp [[sampler(0)]],
                              texture2d<float> incoming [[texture(1)]],
                              constant float4 &offsets [[buffer(0)]]) {
    float4 bg = outgoing.sample(samp, in.uv - offsets.xy);    // shifted outgoing (linear-premultiplied)
    float4 src = incoming.sample(samp, in.uv - offsets.zw);   // shifted incoming (linear-premultiplied)
    return src + bg * (1.0f - src.a);                          // premultiplied source-over (B over A)
}

// CP5.5 dip: dip through a solid premultiplied colour. params.x is eased progress; params.yzw are the
// dip rgb; dipAlpha is its alpha. Two-phase (oracle): p<0.5 → mix(A, dip, p*2); else mix(dip, B, (p-0.5)*2).
// All operands are linear-premultiplied (black/white are linear-invariant), so the mix is correct.
fragment float4 dip_fragment(FullscreenOut in [[stage_in]],
                             texture2d<float> outgoing [[texture(0)]],
                             sampler samp [[sampler(0)]],
                             texture2d<float> incoming [[texture(1)]],
                             constant float4 &params [[buffer(0)]],
                             constant float &dipAlpha [[buffer(1)]]) {
    float4 a = outgoing.sample(samp, in.uv);   // linear-premultiplied
    float4 b = incoming.sample(samp, in.uv);   // linear-premultiplied
    float4 dip = float4(params.y, params.z, params.w, dipAlpha);
    float p = clamp(params.x, 0.0f, 1.0f);
    if (p < 0.5f) {
        return mix(a, dip, p * 2.0f);
    } else {
        return mix(dip, b, (p - 0.5f) * 2.0f);
    }
}

fragment float4 final_srgb_fragment(FullscreenOut in [[stage_in]],
                                    texture2d<float> linearCanvas [[texture(0)]],
                                    sampler samp [[sampler(0)]]) {
    // linearCanvas holds linear-light premultiplied values. (When the intermediate profile is bgra8SRGB
    // the attachment is _srgb and the GPU decodes sRGB→linear on read, so this is linear either way —
    // plan §5.3.)
    float4 c = linearCanvas.sample(samp, in.uv);
    float a = c.a;
    // Recover straight linear colour when alpha > 0; alpha == 0 ⇒ 0 (plan §5.3 item 1).
    float3 straight_lin = (a > 0.0f) ? (c.rgb / a) : float3(0.0f);
    // Exact linear→sRGB encode (plan §5.3 item 2).
    float3 enc = float3(linear_to_srgb(straight_lin.r),
                        linear_to_srgb(straight_lin.g),
                        linear_to_srgb(straight_lin.b));
    // Premultiply in the final sRGB domain (plan §5.3 item 3).
    float3 premul_srgb = enc * a;
    // Explicit UNORM quantization q = floor(clamp(c,0,1)*255 + 0.5)/255 (plan §5.3 item 4, correction #2).
    // Shader returns a normalized float; .bgra8Unorm does the normalized store (no integer 0..255 write).
    float4 outc = float4(premul_srgb, a);
    outc = clamp(outc, 0.0f, 1.0f);
    outc = floor(outc * 255.0f + 0.5f) / 255.0f;
    // RGBA-semantic return; .bgra8Unorm yields physical BGRA order (plan §5.3 item 5, no swizzle).
    return outc;
}

// ---- CP7.6a external-target copy ------------------------------------------------------------------
//
// Copies the already-final sRGB output surface (plain .bgra8Unorm, premultiplied sRGB, produced by
// final_srgb_fragment) into an external caller-supplied .bgra8Unorm texture, with no colour change.
// `forceOpaque != 0` forces alpha = 1.0 while keeping the premultiplied B/G/R — the GPU equivalent of
// the export CPU `compositeOpaque` (premultiplied-over-transparent composited onto opaque black).
// `forceOpaque == 0` is a straight passthrough, byte-identical to the source surface.
//
// The source is sampled with the same UVs/sampler as final_srgb_fragment; because src and target share
// the exact canvas dimensions (validated in Swift), the bilinear sample at each pixel-center hits the
// matching source texel 1:1 (no scaling). The values are already UNORM-quantized in the source, so the
// passthrough store reproduces them exactly.
fragment float4 external_copy_fragment(FullscreenOut in [[stage_in]],
                                       texture2d<float> source [[texture(0)]],
                                       sampler samp [[sampler(0)]],
                                       constant uint &forceOpaque [[buffer(0)]]) {
    float4 c = source.sample(samp, in.uv);
    if (forceOpaque != 0u) {
        c.a = 1.0f;
    }
    return c;
}
