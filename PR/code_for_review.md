# PR-C2: GPU Mask Rendering Pipeline — Code for Review (v4 Final)

## Summary

Реализация PR-C2 для GPU-based mask rendering с boolean операциями:
- `renderMaskGroupScope` — главная функция рендера mask group
- Helper functions: `clearR8Texture`, `clearColorTexture`, `renderCoverage`, `combineMask`, `compositeMaskedQuad`
- Интеграция в execute loop: прямая замена старого CPU path на новый GPU path
- `overrideAnimToViewport` параметр в `drawInternal` для bbox-local rendering

## Fixes Applied (v4 — Final Review)

| Fix | Status |
|-----|--------|
| 🔴 M1: Malformed scope fallback (no crash) | ✅ Fixed |
| 🔴 M2: R8 textures have `.renderTarget` | ✅ Verified (already correct) |
| 🟠 Matrix concatenation order | ✅ Fixed (v2) |
| 🟠 TODO for buffer allocation optimization (I4) | ✅ Added (v2) |
| 📝 Doc-comment contract for `skipMalformedMaskScope` | ✅ Added (v4) |
| 📝 Verify `renderSegment(nil)` is safe for matte/clipStack | ✅ Verified (v4) |
| 📝 Improve M1 test with pixel check | ✅ Added (v4) |

---

## v4 Changes (Final Review Comments)

### 1) Doc-comment contract for `skipMalformedMaskScope`

```swift
/// Skips a malformed mask scope and extracts inner commands for fallback rendering.
///
/// Used when `extractMaskGroupScope` returns nil (malformed structure).
/// Finds all commands between beginMask chain and matching endMask(s),
/// returning them for rendering without mask.
///
/// **Contract:**
/// - Nested beginMask inside inner content is NOT supported in normal path,
///   but here we simply count depth and render inner WITHOUT mask up to first endMask.
/// - Goal: **do not crash render**, not guarantee visual equivalence.
/// - This is best-effort fallback for malformed command streams.
///
/// - Parameters:
///   - commands: Full command stream
///   - startIndex: Index of first beginMask command
/// - Returns: Tuple of (innerCommands to render, endIndex after scope)
```

### 2) Verification: `renderSegment(..., renderPassDescriptor: nil)` is safe

**Analysis:**
- `renderSegment` with `nil` creates new descriptor with `loadAction: .load`, `storeAction: .store`
- Uses `state.currentScissor` or `state.clipStack[0]` for initial scissor
- Calls `executeCommand` for each command

**clipStack:**
- `pushClipRect` → `state.pushClip(...)` — modifies clipStack
- `popClipRect` → `state.popClip()` — modifies clipStack
- This is **correct behavior** — if innerCommands contain clip commands, they should be processed

**matte:**
- `beginMatte` → `state.matteDepth += 1` (counter only)
- `endMatte` → `state.matteDepth -= 1` (counter only)
- Actual matte rendering happens in main execute loop via `extractMatteScope`
- Counters don't affect fallback behavior

**Conclusion:** ✅ Safe. `renderSegment` with `nil` does not break matte behavior or corrupt clipStack.

### 3) Improved M1 test with pixel check

```swift
func testUnbalancedMaskDoesNotCrash() throws {
    // M1-fallback: malformed scope (missing endMask) should NOT throw.
    // Instead, it should render inner commands without mask.
    let provider = InMemoryTextureProvider()
    let maskPath = createRectPath(xPos: 0, yPos: 0, width: 10, height: 10)
    var registry = PathRegistry()
    let pathId = registerPath(maskPath, in: &registry)

    // Add a test texture so drawImage doesn't fail
    let col = MaskTestColor(red: 255, green: 0, blue: 0, alpha: 255)
    let tex = try XCTUnwrap(createSolidColorTexture(device: device, color: col, size: 32))
    provider.register(tex, for: "test")

    // BeginMaskAdd without EndMask
    let cmds: [RenderCommand] = [
        .beginGroup(name: "test"),
        .beginMaskAdd(pathId: pathId, opacity: 1.0, frame: 0),
        .drawImage(assetId: "test", opacity: 1.0),
        // Missing .endMask - malformed scope
        .endGroup
    ]

    // Should NOT throw - fallback renders content without mask
    let result = try renderer.drawOffscreen(
        commands: cmds, device: device, sizePx: (32, 32),
        animSize: SizeD(width: 32, height: 32), textureProvider: provider,
        pathRegistry: registry
    )

    // Verify render completed (content was drawn without mask)
    XCTAssertNotNil(result, "Render should complete successfully with fallback")

    // Verify content was actually rendered (red color from texture)
    let centerPixel = readPixel(from: result, at: MaskTestPoint(xPos: 16, yPos: 16))
    XCTAssertGreaterThan(centerPixel.alpha, 0, "Fallback should render content")
    XCTAssertGreaterThan(centerPixel.red, 200, "Content should be red (from test texture)")
}
```

---

## M1 Fix: Malformed Scope Fallback

### Problem
Original code threw `MetalRendererError.invalidCommandStack` when `extractMaskGroupScope` returned nil (malformed structure). This caused the entire render to fail.

### Solution
Changed to fallback behavior: skip to matching endMask and render inner content without mask.

### MetalRenderer+Execute.swift — execute loop

```swift
case .mask:
    // GPU mask rendering path (PR-C2)
    if let scope = extractMaskGroupScope(from: commands, startIndex: index) {
        let scopeCtx = MaskScopeContext(
            target: target,
            textureProvider: textureProvider,
            commandBuffer: commandBuffer,
            animToViewport: animToViewport,
            viewportToNDC: viewportToNDC,
            assetSizes: assetSizes,
            pathRegistry: pathRegistry
        )
        try renderMaskGroupScope(scope: scope, ctx: scopeCtx, inheritedState: state)
        index = scope.endIndex
    } else {
        // M1-fallback: malformed scope - skip to matching endMask and render inner without mask
        // This is safer than crashing the entire render
        let (innerCommands, endIdx) = skipMalformedMaskScope(from: commands, startIndex: index)
        if !innerCommands.isEmpty {
            try renderSegment(
                commands: innerCommands,
                target: target,
                textureProvider: textureProvider,
                commandBuffer: commandBuffer,
                animToViewport: animToViewport,
                viewportToNDC: viewportToNDC,
                assetSizes: assetSizes,
                pathRegistry: pathRegistry,
                state: &state,
                renderPassDescriptor: nil
            )
        }
        index = endIdx
    }
    isFirstPass = false
```

---

## M2 Verification: R8 Textures Have `.renderTarget`

### TexturePool.swift — `acquireR8Texture` (already correct)

```swift
func acquireR8Texture(size: (width: Int, height: Int)) -> MTLTexture? {
    // ... pool lookup logic ...

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .r8Unorm,
        width: size.width,
        height: size.height,
        mipmapped: false
    )
    descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]  // ✅ Has .renderTarget
    descriptor.storageMode = .private

    return device.makeTexture(descriptor: descriptor)
}
```

**Status:** Already correct. R8 textures are created with `.renderTarget` usage, which is required for `clearR8Texture` render pass.

---

## Previously Fixed (v2)

### Matrix Concatenation Order

**Семантика:** `A.concatenating(B)` = `A ∘ B` — применяет **B первым**, затем **A**.

```swift
// Transform chain: point → pathToViewport → viewportToBbox → bboxToNDC
// With A.concatenating(B) = "B first, then A", we build right-to-left:
let pathToNDC = bboxToNDC.concatenating(viewportToBbox.concatenating(pathToViewport))

// For inner content:
let bboxAnimToViewport = viewportToBbox.concatenating(ctx.animToViewport)
```

### TODO for I4-perf

```swift
// TODO: [I4-perf] Cache vertex/index buffers to avoid per-frame allocations.
// - indexBuffer is stable per PathResource, can be cached in PathResource or a pool
// - vertexBuffer changes per frame for animated paths, consider ring buffer or pool
```

---

## Test Results

```
swift build: OK (no warnings)
swift test: 367 tests passed, 0 failures
```

---

## Files Changed Summary (v4 Final)

| File | Change |
|------|--------|
| `MetalRenderer+Execute.swift` | **M1-fix** — malformed scope fallback + **doc-comment contract** |
| `MetalRendererMaskTests.swift` | **Updated** — test for M1-fallback with pixel verification |
| `MetalRenderer+MaskRender.swift` | **Fixed (v2)** — matrix concatenation order |
| `MetalRenderer+MaskHelpers.swift` | **Added (v2)** — TODO for I4-perf |

---

## PR-C2 Acceptance Criteria Checklist (Final)

- [x] `renderMaskGroupScope` implements full algorithm per task.md
- [x] **FIXED (v2)**: Matrix concatenation order matches transform chain semantics
- [x] BBox computation uses `computeMaskGroupBboxFloat` + `roundClampIntersectBBoxToPixels` from PR-C1
- [x] Texture allocation: coverage, accumA, accumB (R8), content (BGRA)
- [x] Accumulator initialization via `initialAccumulatorValue` from PR-C1
- [x] `clearR8Texture` uses render pass with loadAction = .clear
- [x] `renderCoverage` draws triangulated path to R8 texture
- [x] `combineMask` uses compute pipeline with ping-pong (accIn !== accOut)
- [x] Inner content rendered to bbox-sized texture with shifted animToViewport
- [x] Scissor: bbox-local for coverage/content, parent for final composite
- [x] `compositeMaskedQuad` draws content × mask to main target
- [x] Fallback path for degenerate bbox or allocation failure
- [x] Execute loop integration: direct replacement of old CPU path
- [x] **ADDED (v2)**: TODO for I4-perf buffer allocation optimization
- [x] **FIXED (v3)**: M1 — malformed scope fallback (no crash)
- [x] **VERIFIED (v3)**: M2 — R8 textures have `.renderTarget` usage
- [x] **ADDED (v4)**: Doc-comment contract for `skipMalformedMaskScope`
- [x] **VERIFIED (v4)**: `renderSegment(nil)` is safe for matte/clipStack
- [x] **IMPROVED (v4)**: M1 test with pixel verification
- [x] `swift build` → OK
- [x] `swift test` → 367 tests passed, 0 failures
