# Negative Test Cases (PR-01)

This directory contains minimal Lottie animations that should be **rejected** by the validator as unsupported features.

## Current Status

These test cases contain intentionally forbidden features. **Currently, most cases do NOT fail validation** because the validator does not yet check for these conditions. The validation rules will be added in **PR-02 (Validator)**.

## Test Cases

| Case | Forbidden Feature | JSON Field | Value | Expected to Fail After |
|------|-------------------|------------|-------|------------------------|
| `neg_trim_paths_tm` | Trim Paths | `shapes[].ty` | `"tm"` | PR-02 |
| `neg_mask_expansion_x` | Mask Expansion | `masksProperties[].x` | `10` (non-zero) | PR-02 |
| `neg_mask_opacity_animated` | Animated Mask Opacity | `masksProperties[].o.a` | `1` (animated) | Already fails (AnimValidator) |
| `neg_skew_sk_nonzero` | Skew Transform | `ks.sk` | `15` (non-zero) | PR-02 |
| `neg_layer_ddd_3d` | 3D Layer | `layers[].ddd` | `1` | PR-02 |
| `neg_layer_ao_auto_orient` | Auto-Orient | `layers[].ao` | `1` | PR-02 |
| `neg_layer_sr_stretch` | Time Stretch | `layers[].sr` | `2` (≠1) | PR-02 |
| `neg_layer_ct_collapse_transform` | Collapse Transform | `layers[].ct` | `1` | PR-02 |
| `neg_layer_bm_blend_mode` | Blend Mode | `layers[].bm` | `3` (≠0, multiply) | PR-02 |

## Design Principles

Each negative case follows these rules:
1. **Minimal** — 1 composition, 1 layer
2. **Single violation** — exactly one forbidden parameter per file
3. **Clear naming** — `neg_<feature>` pattern

## Canvas Specs

All negative cases use:
- 1080×1920 @ 30fps
- 90 frames duration
- Embedded 1×1 white pixel as data URI (no external files needed)

## Validation Error Codes (Expected)

After PR-02 implementation:

| Case | Expected Error Code |
|------|---------------------|
| `neg_trim_paths_tm` | `unsupportedShapeItem` |
| `neg_mask_expansion_x` | `unsupportedMaskExpansion` |
| `neg_mask_opacity_animated` | `unsupportedMaskOpacityAnimated` |
| `neg_skew_sk_nonzero` | `unsupportedSkew` |
| `neg_layer_ddd_3d` | `unsupported3DLayer` |
| `neg_layer_ao_auto_orient` | `unsupportedAutoOrient` |
| `neg_layer_sr_stretch` | `unsupportedStretch` |
| `neg_layer_ct_collapse_transform` | `unsupportedCollapseTransform` |
| `neg_layer_bm_blend_mode` | `unsupportedBlendMode` |
