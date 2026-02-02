# PR-23 — Apply shape groupTransforms to inputClip world transform

## Summary

Fixes wrong size/position of anim-1.1, 1.2, 1.3 in preview (anim-1.4 was correct) by including shape group transforms in the `computeMediaInputWorld` result. The inputClip mask was rendering at the wrong position because the mediaInput layer's shape group transform (the `"tr"` element) was missing from the world matrix.

**Root cause:** `computeMediaInputWorld` returned only the layer's world transform (position/anchor/rotation/scale from parent chain), ignoring the shape group transforms inside `inputLayer.content`. Since paths are stored in shape-local coordinates (PR-11 contract: group transforms NOT baked into vertices), the group transforms must be composed at render time. This was already done for regular shape rendering in `renderLayerContent`, but was missing for the inputClip mask path.

**Build:** OK | **Tests:** 748 passed, 0 failures, 5 skipped (+4 new tests)

---

## File (A): `TVECore/Sources/TVECore/AnimIR/AnimIR.swift` — MODIFIED

### Fix: `computeMediaInputWorld` now includes shape groupTransforms

**SECTION:** `computeMediaInputWorld(inputGeo:context:)` (line ~892)

**WAS:**
```swift
        // Compute world transform without userTransform
        guard let (matrix, _) = computeWorldTransform(
            for: inputLayer,
            at: context.frame,
            baseWorldMatrix: .identity,
            baseWorldOpacity: 1.0,
            layerById: layerById,
            sceneFrameIndex: context.frameIndex
        ) else {
            return .identity
        }

        return matrix
    }
```

**NOW:**
```swift
        // Compute world transform without userTransform
        guard let (matrix, _) = computeWorldTransform(
            for: inputLayer,
            at: context.frame,
            baseWorldMatrix: .identity,
            baseWorldOpacity: 1.0,
            layerById: layerById,
            sceneFrameIndex: context.frameIndex
        ) else {
            return .identity
        }

        // PR-23: Apply shape groupTransforms for mediaInput geometry (PR-11 contract).
        // Paths are stored in LOCAL coords; group transforms must be applied at render time.
        // This matches the pattern in renderLayerContent for regular shape layers.
        switch inputLayer.content {
        case .shapes(let shapeGroup):
            var composed = matrix
            for gt in shapeGroup.groupTransforms {
                composed = composed.concatenating(gt.matrix(at: context.frame))
            }
            return composed
        default:
            return matrix
        }
    }
```

### Numeric example (anim-1.1)

**Before (missing group transform):**
```
inputLayerWorld = layerTransform only
                = translate(270, 480)
mask bbox in comp space: (71, 66) -> (611, 1026)  // WRONG, shifted
```

**After (with group transform):**
```
inputLayerWorld = layerTransform * groupTransform
                = translate(270, 480) * translate(-71.094, -65.998)
                = translate(198.906, 414.002)
mask bbox in comp space: (0, 0) -> (540, 960)     // CORRECT
```

### Why PR-22 inverse compensation is automatically correct

- `clip.world` now = `layerWorld * groupTransform` (correct)
- `clip.inverse` = `inverse(layerWorld * groupTransform)` (computed by `Matrix2D.inverse`)
- `world * inverse = identity` (verified by test)
- Scope balance unchanged (validator passes)

---

## File (B): `TVECore/Tests/TVECoreTests/InputClipGroupTransformTests.swift` — NEW

New test file: 4 integration tests via `renderCommands`.

**Tests:**

1. `testInputClipWorld_includesGroupTransforms`
   — mediaInput p=(100,200), groupTransform p=(-30,-50)
   — verifies pushTransform matrix = translate(70, 150)

2. `testInputClipInverse_matchesGroupTransformWorld`
   — verifies world * inverse = identity (exact cancellation)

3. `testInputClipWithGroupTransforms_validatorPasses`
   — verifies emitted commands pass RenderCommandValidator

4. `testInputClipWorld_anim11ProductionValues`
   — verifies exact anim-1.1 production values:
     mediaInput p=(270,480), groupTransform p=(-71.094,-65.998)
   — expects tx=198.906, ty=414.002

**Test approach:** compiles inline Lottie JSON with configurable mediaInput position/anchor and group transform, then inspects emitted RenderCommands directly. No private API access needed.

---

## Files NOT changed

- `AnimIRCompiler.swift` — no changes (InputGeometryInfo compilation unchanged)
- `MetalRenderer+Execute.swift` — no changes (rendering pipeline unchanged)
- `MetalRenderer+MaskRender.swift` — no changes (mask rendering unchanged)
- `RenderCommandValidator.swift` — no changes (PR-22 validation unchanged)
- `RenderIssue.swift` — no changes
- `MetalRenderer.swift` — no changes

---

## Test results

```
748 passed, 0 failures, 5 skipped
+4 new tests (InputClipGroupTransformTests)
```

---

## Acceptance criteria

| Criterion | Status |
|-----------|--------|
| anim-1.1/1.2/1.3 no longer have shifted/wrong size | Done: inputClipWorld now includes groupTransforms |
| anim-1.4 no regression (no mediaInput, standard path) | Done: standard path unchanged |
| PR-22 inverse compensation remains valid | Done: verified by test (world * inverse = identity) |
| RenderCommandValidator passes | Done: verified by test |
| New tests green | Done: 4/4 passed |
