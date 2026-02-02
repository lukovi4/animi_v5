# PR-22 — Scope-balanced inputClip emission + RenderCommand validator

## Summary

Fixes the "Unbalanced transforms" runtime crash (introduced by PR-21 exposing a pre-existing latent defect) by replacing the cross-boundary `popTransform` inside inputClip mask scope with an inverse-compensation pattern. Fix keeps mask world positioning while preventing clip transform from affecting inner content; all stacks balanced per scope.

Adds `RenderCommandValidator` as a safety net that detects cross-boundary stack issues in DEBUG before render execution (`assertionFailure` on structural violations).

**Root cause:** AnimIR inputClip path emitted `pushTransform(inputLayerWorld)` before `beginMask` and `popTransform` inside the scope. This defect was latent — it was masked by the old renderer fallback path which used `&state` (inout), so the pop modified the outer state correctly by accident. PR-21's more correct scope-based `renderMaskGroupScope` runs inner commands in isolated context, exposing the structural violation.

**Build:** OK | **Tests:** 739 passed, 0 failures, 7 skipped (+15 new tests)

---

## File (A): `TVECore/Sources/TVECore/AnimIR/AnimIR.swift` — MODIFIED

### Core fix: inputClip emission — inverse transform compensation

**SECTION:** `emitRegularLayerCommands`, inputClip path (was lines 742-811)

**CHANGE 1:** Pre-compute inverse before the if/else branch

**ADDED** (between `let needsInputClip = ...` and the `if` branch):

```swift
        // PR-22: Pre-compute inverse for scope-balanced inputClip emission.
        // The inverse compensates inputLayerWorld so content inside the mask scope
        // is not affected by the mask-positioning transform, while keeping all
        // push/pop transforms balanced within the mask scope boundary.
        let inputClipTransforms: (world: Matrix2D, inverse: Matrix2D)?
        if needsInputClip, let inputGeo = context.inputGeometry {
            let world = computeMediaInputWorld(inputGeo: inputGeo, context: context)
            if let inv = world.inverse {
                inputClipTransforms = (world, inv)
            } else {
                inputClipTransforms = nil
                lastRenderIssues.append(RenderIssue(
                    severity: .warning,
                    code: RenderIssue.codeInputClipNonInvertible,
                    path: "anim(\(meta.sourceAnimRef)).layers[id=\(layer.id)]",
                    message: "inputLayerWorld not invertible (det≈0), skipping inputClip for layer \(layer.name)",
                    frameIndex: context.frameIndex
                ))
            }
        } else {
            inputClipTransforms = nil
        }
```

**CHANGE 2:** If condition changed

**БЫЛО:**
```swift
        if needsInputClip, let inputGeo = context.inputGeometry {
```

**СТАЛО:**
```swift
        if let inputGeo = context.inputGeometry, let clip = inputClipTransforms {
```

**CHANGE 3:** Comment block updated

**БЫЛО:**
```swift
            // === InputClip path for binding layer ===
            //
            // Structure (per ТЗ section 2.3):
            //   beginGroup(layer: media (inputClip))
            //     pushTransform(world(mediaInput, t))    ← mediaInput transform (fixed window)
            //     beginMask(mode: .intersect, pathId: mediaInputPathId)
            //     popTransform
            //     pushTransform(world(media, t) * userTransform)   ← media + user edits
            //       [masks + content]
            //     popTransform
            //     endMask
            //   endGroup
```

**СТАЛО:**
```swift
            // === InputClip path for binding layer (scope-balanced, PR-22) ===
            //
            // Structure (fixes cross-boundary transforms from original emission):
            //   beginGroup(layer: media (inputClip))
            //     pushTransform(inputLayerWorld)             ← outside scope
            //     beginMask(mode: .intersect, pathId: mediaInputPathId)
            //       pushTransform(inverse(inputLayerWorld))  ← compensation (balanced in scope)
            //       pushTransform(mediaWorld * userTransform)
            //         [masks + content]
            //       popTransform(mediaWorld)
            //       popTransform(inverse)                    ← balanced within scope
            //     endMask
            //     popTransform(inputLayerWorld)              ← outside scope, balanced
            //   endGroup
```

**CHANGE 4:** Command emission restructured

**БЫЛО (steps 1-5, the problematic cross-boundary):**
```swift
            commands.append(.beginGroup(name: "Layer:\(layer.name)(\(layer.id))(inputClip)"))

            // 1) Compute mediaInput world transform (fixed window, no userTransform)
            let inputLayerWorld = computeMediaInputWorld(inputGeo: inputGeo, context: context)

            // 2) Push mediaInput transform for the mask path
            commands.append(.pushTransform(inputLayerWorld))

            // 3) Begin inputClip mask ...
            commands.append(.beginMask(...))

            // 4) Pop mediaInput transform
            commands.append(.popTransform)                    // ❌ CROSS-BOUNDARY

            // 5) Push media world transform with userTransform
            let mediaWorldWithUser = resolved.worldMatrix.concatenating(context.userTransform)
            commands.append(.pushTransform(mediaWorldWithUser))
```

**СТАЛО (steps 1-4, scope-balanced):**
```swift
            commands.append(.beginGroup(name: "Layer:\(layer.name)(\(layer.id))(inputClip)"))

            // 1) Push inputLayerWorld (outside mask scope — positions the mask path)
            commands.append(.pushTransform(clip.world))

            // 2) Begin inputClip mask ...
            commands.append(.beginMask(...))

            // 3) Compensate: push inverse(inputLayerWorld) so content doesn't inherit
            //    the mask-positioning transform.
            commands.append(.pushTransform(clip.inverse))     // ✅ balanced in scope

            // 4) Push media world transform with userTransform
            let mediaWorldWithUser = resolved.worldMatrix.concatenating(context.userTransform)
            commands.append(.pushTransform(mediaWorldWithUser))
```

**CHANGE 5:** Closing commands restructured

**БЫЛО (steps 9-11):**
```swift
            // 9) Pop media transform
            commands.append(.popTransform)

            // 10) End inputClip mask
            commands.append(.endMask)

            // 11) End group
            commands.append(.endGroup)
```

**СТАЛО (steps 8-12):**
```swift
            // 8) Pop media transform
            commands.append(.popTransform)

            // 9) Pop inverse compensation (balanced within scope)
            commands.append(.popTransform)

            // 10) End inputClip mask
            commands.append(.endMask)

            // 11) Pop inputLayerWorld (outside scope — balanced with step 1)
            commands.append(.popTransform)

            // 12) End group
            commands.append(.endGroup)
```

### Transform flow summary

**Before (cross-boundary, broke with PR-21):**
```
pushTransform(inputLayerWorld)          // OUTSIDE
beginMask(inputClip)                    // scope start
  popTransform ← CROSSES BOUNDARY      // tries to close outer push
  pushTransform(mediaWorld)
    [content]
  popTransform(mediaWorld)
endMask                                 // scope end
```

**After (scope-balanced, PR-22):**
```
pushTransform(inputLayerWorld)          // OUTSIDE
beginMask(inputClip)                    // scope start
  pushTransform(inverse(inputLayerWorld))  // compensation
  pushTransform(mediaWorld)
    [content]
  popTransform(mediaWorld)
  popTransform(inverse)                 // balanced within scope
endMask                                 // scope end
popTransform(inputLayerWorld)           // OUTSIDE, balanced
```

---

## File (B): `TVECore/Sources/TVECore/RenderGraph/RenderIssue.swift` — MODIFIED

### Added issue code for non-invertible inputClip

**ADDED:**
```swift
    /// InputClip transform is not invertible (degenerate, e.g. scale=0)
    public static let codeInputClipNonInvertible = "INPUT_CLIP_NON_INVERTIBLE"
```

---

## File (C): `TVECore/Sources/TVECore/MetalRenderer/RenderCommandValidator.swift` — NEW

New file: structural validator for `RenderCommand` sequences.

Validates that transform, clip, and group stacks are balanced within each mask/matte scope. In DEBUG, prints a diagnostic window (5 commands before/after) around each detected error.

**Key method:** `RenderCommandValidator.validateScopeBalance(_ commands: [RenderCommand]) -> [ValidationError]`

**Static flag:** `assertOnFailure: Bool` — controls whether validation failures trigger `assertionFailure`. Defaults to `true`. Set to `false` in tests that deliberately pass invalid command sequences.

**Checks:**
- Cross-boundary transforms in mask scopes (push outside, pop inside)
- Cross-boundary clips in mask scopes
- Cross-boundary transforms/clips in matte scopes
- Unmatched endMask/endMatte without corresponding begin
- Unclosed scopes at end of stream
- Pop below zero (stack underflow) — transforms, clips, groups
- Final depth != 0 (unbalanced overall) — transforms, clips, groups

---

## File (D): `TVECore/Sources/TVECore/MetalRenderer/MetalRenderer.swift` — MODIFIED

### Added validator calls in both render entry points (DEBUG only, with assertionFailure)

**CHANGE 1:** In `draw(commands:target:...)` — on-screen path

**ADDED** (after `perfFrameIndex += 1`, before `let renderPassDescriptor`):
```swift
        // PR-22: Validate command structure in DEBUG before execution.
        // Catches cross-boundary transform/clip issues at the source.
        #if DEBUG
        let validationErrors = RenderCommandValidator.validateScopeBalance(commands)
        if !validationErrors.isEmpty {
            for err in validationErrors {
                print("[TVECore] ❌ RenderCommandValidator: \(err)")
            }
            if RenderCommandValidator.assertOnFailure {
                assertionFailure("[TVECore] RenderCommand structural validation failed (\(validationErrors.count) error(s))")
            }
        }
        #endif
```

**CHANGE 2:** In offscreen render path — same pattern with `offscreenValidationErrors`.

---

## File (E): `TVECore/Tests/TVECoreTests/RenderCommandValidatorTests.swift` — NEW

New test file: 15 tests for `RenderCommandValidator`.

**Valid sequences (6 tests):**
1. `testValidator_balancedScope_noErrors` — simple balanced mask scope
2. `testValidator_pr22InputClipPattern_noErrors` — full PR-22 canonical pattern
3. `testValidator_pr22WithNestedLayerMasks_noErrors` — PR-22 with layer masks inside inputClip
4. `testValidator_nestedMaskBalanced_noErrors` — nested mask containers
5. `testValidator_matteScope_balanced_noErrors` — matte scope balanced
6. `testValidator_balancedGroups_noErrors` — nested beginGroup/endGroup

**Invalid sequences (9 tests):**
7. `testValidator_crossBoundaryTransform_detectsError` — old-style cross-boundary (the exact bug)
8. `testValidator_crossBoundaryClip_detectsError` — cross-boundary clip
9. `testValidator_unbalancedFinal_detectsError` — push without pop at end
10. `testValidator_unmatchedEndMask_detectsError` — endMask without beginMask
11. `testValidator_unmatchedEndMatte_detectsError` — endMatte without beginMatte
12. `testValidator_unclosedScope_detectsError` — beginMask without endMask
13. `testValidator_popBelowZero_detectsError` — popTransform on empty stack
14. `testValidator_unbalancedGroups_detectsError` — beginGroup without endGroup
15. `testValidator_endGroupBelowZero_detectsError` — endGroup on empty stack

---

## File (F): `TVECore/Tests/TVECoreTests/MetalRendererBaselineTests.swift` — MODIFIED

### Added `assertOnFailure = false` guard to tests that deliberately create invalid commands

**CHANGE 1:** `testStacksBalanced_invalidPopThrows`

**ADDED** (at start of function):
```swift
        RenderCommandValidator.assertOnFailure = false
        defer { RenderCommandValidator.assertOnFailure = true }
```

**CHANGE 2:** `testUnbalancedMask_throws` — same guard added.

---

## File (G): `TVECore/Tests/TVECoreTests/MetalRendererMaskTests.swift` — MODIFIED

### Added `assertOnFailure = false` guard

**CHANGE:** `testUnbalancedMaskDoesNotCrash` — same guard added.

---

## File (H): `TVECore/Tests/TVECoreTests/MetalRendererMatteTests.swift` — MODIFIED

### Added `assertOnFailure = false` guard

**CHANGE:** `testUnbalancedMatteThrows` — same guard added.

---

## Files NOT changed (verified)

- `MetalRenderer+Execute.swift` — no changes in this PR (PR-21 changes from previous PR remain)
- `MetalRenderer+MaskRender.swift` — no changes
- `MaskTypes.swift` — no changes (PR-21 docstring remains)
- `RenderCommand.swift` — no changes to enum
- `MaskExtractionTests.swift` — no changes (PR-21 tests remain)
- `Matrix2D.swift` — no changes (existing `inverse` property used as-is)

---

## Test results

```
739 passed, 0 failures, 7 skipped
+15 new tests (RenderCommandValidatorTests)
```

---

## Lead review items addressed

| Item | Status |
|------|--------|
| A) `inverse == nil` → RenderIssue instead of print | Done: `INPUT_CLIP_NON_INVERTIBLE` warning |
| B) Validator assertionFailure in DEBUG | Done: `assertOnFailure` flag, 4 tests guarded |
| C) Validator: all stack-affecting commands | Done: added `beginGroup`/`endGroup` tracking |
