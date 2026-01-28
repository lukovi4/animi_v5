# Shape Test Cases (PR-01)

This directory contains test assets for shape primitives and related features.

## Current Status

These test cases are designed to validate shape primitive support. **Currently, these cases are expected to fail** because the decoder (`LottieShape.swift`) does not yet recognize `rc`, `el`, `sr`, `st` shape types — they will be decoded as `.unknown`.

## Test Cases

| Case | Shape Types | Description | Expected to Work After |
|------|-------------|-------------|------------------------|
| `shape_rc_grid` | `ty:"rc"` (Rectangle) | 3×4 grid of 12 rectangles as matte source | PR-03+ (ShapeItem rc/el/sr) |
| `shape_el_grid` | `ty:"el"` (Ellipse) | 3×4 grid of 12 ellipses as matte source | PR-03+ (ShapeItem rc/el/sr) |
| `shape_sr_grid` | `ty:"sr"` (Polystar) | 3×4 grid of 12 five-pointed stars as matte source | PR-03+ (ShapeItem rc/el/sr) |
| `shape_stroke_basic` | `ty:"st"` (Stroke) + `ty:"sh"` (Path) | Strokes with animated width (4→40px) | PR-04+ (ShapeItem st) |
| `shape_group_transform_animated` | `ty:"tr"` inside `ty:"gr"` | Group transform with keyframes (position + rotation + scale) | PR-05+ (Group transform support) |

## Grid Layout (for rc/el/sr cases)

Canvas: 1080×1920 @ 30fps, 90 frames

Tile positions (centers):
- Columns (X): 180, 540, 900
- Rows (Y): 240, 720, 1200, 1680
- Tile size: 360×480

## Structure

Each test case contains:
- `anim.json` — Lottie animation
- `images/solid_white_1x1.png` — 1×1 white pixel placeholder for media binding

For AnimiApp (`TestAssets/ScenePackages/`), each case also includes:
- `scene.json` — Scene descriptor with `bindingKey: "media"`

## Verification Checklist

After implementing shape support, verify:
- [ ] All 12 tiles visible on frame 0 for grid cases
- [ ] Stroke width animates correctly in `shape_stroke_basic`
- [ ] Group transform animates (position/rotation/scale) in `shape_group_transform_animated` — layer transform must remain static
