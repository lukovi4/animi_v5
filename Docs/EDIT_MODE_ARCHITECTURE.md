# Edit Mode Architecture — Deep Audit

> TVECore + AnimiApp | Scene Template Editor
> Audit date: 2026-02-02

---

## 0. Scope

This document provides a complete architectural description of the **Edit mode** for the scene template editor.
It covers: file map, mode switching, render pipeline (preview vs edit), InputMedia block formation,
InputClip visual structure, hit-test system, overlay rendering, UserTransform pipeline,
coordinate spaces, and known limitations.

All references are verified against source code with exact file paths and line numbers.

---

## 1. Complete File Map

### 1.1 UI Layer (AnimiApp)

| # | File | Lines | Purpose |
|---|------|-------|---------|
| 1 | `AnimiApp/Sources/Editor/TemplateEditorController.swift` | 294 | State machine, mode switching, gesture handlers, hit-test coordination, canvas-to-view mapping |
| 2 | `AnimiApp/Sources/Editor/EditorOverlayView.swift` | 82 | CAShapeLayer-based transparent overlay for block outlines (selected/inactive) |

### 1.2 Engine Layer (TVECore — ScenePlayer)

| # | File | Lines | Purpose |
|---|------|-------|---------|
| 3 | `TVECore/.../ScenePlayer/ScenePlayer.swift` | 444 | Scene compilation, userTransform storage, hit-test API, overlays API, render command entry points |
| 4 | `TVECore/.../ScenePlayer/ScenePlayerTypes.swift` | 249 | TemplateMode, RenderPolicy, CompiledScene, SceneRuntime, BlockRuntime, BlockTiming, VariantRuntime, MediaInputOverlay, OverlayState |
| 5 | `TVECore/.../ScenePlayer/SceneRenderPlan.swift` | 217 | Render command generation per block — preview vs edit branches, editFrameIndex, localFrameIndex |
| 6 | `TVECore/.../ScenePlayer/SceneTransforms.swift` | 42 | `blockTransform()` — single shared formula for render pipeline and hit-test |

### 1.3 Engine Layer (TVECore — AnimIR)

| # | File | Lines | Purpose |
|---|------|-------|---------|
| 7 | `TVECore/.../AnimIR/AnimIR.swift` | 1209 | `renderEditCommands()`, edit traversal, InputClip emission, `mediaInputPath()`, `compContainsBinding()` cache |
| 8 | `TVECore/.../AnimIR/AnimIRTypes.swift` | ~500 | BindingInfo, InputGeometryInfo, Layer, Composition, LayerType, RenderContext |
| 9 | `TVECore/.../AnimIR/AnimIRPath.swift` | ~2500 | BezierPath, `cgPath` conversion, `contains(point:)` (even-odd fill rule), `applying(Matrix2D)` |

### 1.4 Models

| # | File | Lines | Purpose |
|---|------|-------|---------|
| 10 | `TVECore/.../Models/MediaInput.swift` | 128 | HitTestMode (.mask/.rect), UserTransformsAllowed, FitMode, EmptyPolicy, AudioConfig |
| 11 | `TVECore/.../Models/MediaBlock.swift` | 53 | Block structure: id, zIndex, rect, containerClip, input, variants |
| 12 | `TVECore/.../Models/ContainerClip.swift` | 13 | Enum: slotRect, slotRectAfterSettle, none |

### 1.5 Math

| # | File | Lines | Purpose |
|---|------|-------|---------|
| 13 | `TVECore/.../Math/GeometryMapping.swift` | 146 | `animToInputContain()` (aspect-fit), `viewportToNDC()` |
| 14 | `TVECore/.../Math/Matrix2D.swift` | ~100 | 2D affine: translation, scale, rotation, concatenating, apply(to:) |

### 1.6 Tests

| # | File | Lines | Purpose |
|---|------|-------|---------|
| 15 | `TVECore/Tests/.../TemplateModeTests.swift` | ~500 | Preview vs Edit: correct commands, frame ignoring, fewer commands, determinism |
| 16 | `TVECore/Tests/.../UserTransformPipelineTests.swift` | ~500 | Pan/zoom/rotation through full pipeline, isolation, backwards compat |
| 17 | `TVECore/Tests/.../HitTestOverlayTests.swift` | ~500 | Hit-test mask/rect, z-order, invisible blocks, overlay geometry |

---

## 2. Two Modes: Preview vs Edit

### 2.1 State Machine

**File:** `TemplateEditorController.swift:7-12`

```swift
struct TemplateEditorState {
    var mode: TemplateMode = .preview
    var selectedBlockId: String?
    var currentPreviewFrame: Int = 0
    var isPlaying: Bool = false
}
```

### 2.2 Mode Mapping

**File:** `ScenePlayerTypes.swift:162-180`

```
TemplateMode.preview  -->  RenderPolicy.fullPreview
TemplateMode.edit     -->  RenderPolicy.editInputsOnly
```

### 2.3 Comparison Table

| Aspect | Preview | Edit |
|--------|---------|------|
| Frame index | `sceneFrameIndex` (scrubber) | Always `editFrameIndex = 0` |
| Timing policy | Block timing respected | Ignored (frozen at frame 0) |
| Layers rendered | ALL layers | Binding layer + mask/matte dependencies only |
| AnimIR method | `renderCommands()` | `renderEditCommands()` |
| Playback | Active (displayLink) | Stopped |
| Gestures | None | Pan / Pinch / Rotate on selected block |
| Selection | None (overlay hidden) | Active (overlay visible) |
| User transforms | Applied to binding layer | Applied to binding layer |
| Block group tag | `"Block:xxx"` | `"Block:xxx(edit)"` |
| Command count | More (all layers) | Fewer (binding only) |

---

## 3. Mode Switching

### 3.1 Enter Preview

**File:** `TemplateEditorController.swift:78-84`

```swift
func enterPreview() {
    state.mode = .preview
    state.selectedBlockId = nil     // clear selection
    updateOverlay()                 // hide overlay
    requestDisplay()                // Metal redraw
    onStateChanged?(state)
}
```

### 3.2 Enter Edit

**File:** `TemplateEditorController.swift:87-93`

```swift
func enterEdit() {
    state.mode = .edit
    state.isPlaying = false         // stop playback
    updateOverlay()                 // show overlay
    requestDisplay()                // Metal redraw
    onStateChanged?(state)
}
```

### 3.3 Render Commands Selection

**File:** `TemplateEditorController.swift:98-106`

```swift
func currentRenderCommands() -> [RenderCommand]? {
    guard let player = player else { return nil }
    switch state.mode {
    case .preview:
        return player.renderCommands(mode: .preview, sceneFrameIndex: state.currentPreviewFrame)
    case .edit:
        return player.renderCommands(mode: .edit)
    }
}
```

**Invariant:** Playback only in preview. Gestures only in edit.

---

## 4. InputMedia Block Formation

### 4.1 Compilation: scene.json --> BlockRuntime

**File:** `ScenePlayer.swift:112-163` (`compileBlock`)

```
MediaBlock (scene.json)
  |-- id, zIndex, rect (canvas coordinates)
  |-- containerClip (slotRect / slotRectAfterSettle / none)
  |-- input: MediaInput
  |     |-- rect (block-local coordinates)
  |     |-- bindingKey ("media")
  |     |-- hitTest (.mask / .rect)
  |     |-- userTransformsAllowed { pan, zoom, rotate }
  |     |-- allowedMedia, emptyPolicy, fitModesAllowed, maskRef
  |     +-- audio
  |
  +-- variants: [Variant]
        +-- animRef --> AnimIRCompiler.compile() --> AnimIR
              |-- binding: BindingInfo { boundLayerId, boundCompId }
              +-- inputGeometry: InputGeometryInfo { layerId, pathId, animPath, compId }
```

Result: `BlockRuntime` with compiled `hitTestMode`, `rectCanvas`, `inputRect`, `[VariantRuntime]`.

**Key compilation steps:**

1. `BlockTiming` computed from optional `Timing` or defaults to full scene duration (`ScenePlayerTypes.swift:150-158`)
2. Blocks sorted by `(zIndex, orderIndex)` ascending for correct render order (`ScenePlayer.swift:85`)
3. `hitTestMode` propagated from `MediaInput.hitTest` into `BlockRuntime` (`ScenePlayer.swift:159`)
4. `selectedVariantId` defaults to first variant (`ScenePlayer.swift:149`)

### 4.2 BlockRuntime Structure

**File:** `ScenePlayerTypes.swift:62-122`

```swift
public struct BlockRuntime: Sendable {
    public let blockId: String
    public let zIndex: Int
    public let orderIndex: Int
    public let rectCanvas: RectD          // canvas-space position
    public let inputRect: RectD           // block-local input slot
    public let timing: BlockTiming        // visibility window
    public let containerClip: ContainerClip
    public let hitTestMode: HitTestMode?  // .mask | .rect | nil
    public let selectedVariantId: String
    public var variants: [VariantRuntime]

    public var selectedVariant: VariantRuntime? {
        variants.first { $0.variantId == selectedVariantId }
    }
}
```

---

## 5. Render Pipeline

### 5.1 Scene-Level Render Plan

**File:** `SceneRenderPlan.swift:22-83`

```
SceneRenderPlan.renderCommands(runtime, sceneFrameIndex, userTransforms, renderPolicy)
  |
  for each block (sorted by zIndex ascending):
    |-- skip if !block.timing.isVisible(at: sceneFrameIndex)
    |-- skip if no selectedVariant
    |-- lookup userTransform = userTransforms[blockId] ?? .identity
    |
    +-- switch renderPolicy:
          case .fullPreview:    --> renderBlockCommands(...)
          case .editInputsOnly: --> renderBlockEditCommands(...)
```

### 5.2 Preview Block Rendering

**File:** `SceneRenderPlan.swift:86-138`

```
beginGroup("Block:xxx")
  pushClipRect(blockRect)                          // containerClip
  pushTransform(blockTransform)                    // anim -> canvas
    animIR.renderCommands(localFrameIndex, userTransform)   // ALL layers
  popTransform
  popClipRect
endGroup
```

- Uses `localFrameIndex` with timing/loop policies
- Renders all layers (binding, decorative, effects)

### 5.3 Edit Block Rendering

**File:** `SceneRenderPlan.swift:145-189`

```
beginGroup("Block:xxx(edit)")
  pushClipRect(blockRect)                          // containerClip
  pushTransform(blockTransform)                    // anim -> canvas
    animIR.renderEditCommands(editFrameIndex=0, userTransform)  // BINDING ONLY
  popTransform
  popClipRect
endGroup
```

- Always uses `editFrameIndex = 0` (no timing/loop policies)
- Renders only binding layer + mask/matte dependencies
- Group tagged with `"(edit)"` suffix

### 5.4 Block Transform

**File:** `SceneTransforms.swift:26-41`

```swift
public static func blockTransform(
    animSize: SizeD, blockRect: RectD, canvasSize: SizeD
) -> Matrix2D {
    // If anim is full-canvas, use identity (clip does the work)
    if Quantization.isNearlyEqual(animSize.width, canvasSize.width) &&
       Quantization.isNearlyEqual(animSize.height, canvasSize.height) {
        return .identity
    }
    // Otherwise: contain (uniform scale + center)
    return GeometryMapping.animToInputContain(animSize: animSize, inputRect: blockRect)
}
```

**Critical:** This function is shared between render pipeline and hit-test pipeline,
guaranteeing bit-for-bit determinism.

---

## 6. InputClip — Visual Structure of the Binding Layer

### 6.1 Decision Point

**File:** `AnimIR.swift:739-740`

```swift
let needsInputClip = isBindingLayer(layer, context: context) && context.inputGeometry != nil
```

Only the binding layer with available inputGeometry gets the InputClip treatment.
All other layers follow the standard render path.

### 6.2 InputClip Command Structure

**File:** `AnimIR.swift:742-811`

```
beginGroup("Layer:media(inputClip)")
  pushTransform(mediaInputWorld)              // (1) fixed clip window
  beginMask(.intersect, mediaInputPathId)     // (2) clip to mediaInput shape
  popTransform                                // (3) pop clip window transform
  pushTransform(lottieWorld * userTransform)  // (4) media content + user edits
    [layer masks]                             // (5) AE masks on media layer
    drawImage(assetId, opacity)               // (6) actual content
  popTransform                                // (7) pop media transform
  endMask                                     // (8) end inputClip
endGroup
```

### 6.3 Transform Formula

**File:** `AnimIR.swift:779`

```swift
let mediaWorldWithUser = resolved.worldMatrix.concatenating(context.userTransform)
```

Formula: `M(t) = A(t) . U`

Where:
- `A(t)` = Lottie animation transform at frame `t` (layer world matrix)
- `U` = user transform (pan/zoom/rotate)
- `.concatenating()` = "apply right operand first, then left"
- Result: user transform applied first, animation plays on top

### 6.4 MediaInput World (Fixed Window)

**File:** `AnimIR.swift:849-875`

```swift
private mutating func computeMediaInputWorld(
    inputGeo: InputGeometryInfo, context: RenderContext
) -> Matrix2D
```

Computes the mediaInput layer's world matrix **without** userTransform.
This guarantees the clip window never moves — the user moves content inside the window,
not the window itself.

---

## 7. Edit Mode Traversal (AnimIR)

### 7.1 Entry Point

**File:** `AnimIR.swift:325-356` (`renderEditCommands`)

Creates `RenderContext` with `userTransform` and calls `renderEditComposition()`.
Always operates on `localFrameIndex` derived from `editFrameIndex = 0`.

### 7.2 Layer Filter Decision Tree

**File:** `AnimIR.swift:369-474` (`renderEditLayer`)

```
For each layer in composition:
  |
  |-- isMatteSource?  --> SKIP (rendered via matte scope when consumer is emitted)
  |-- isHidden?       --> SKIP (geometry-only, e.g. mediaInput layer)
  |
  |-- isBindingLayer? --> EMIT (full render path with inputClip/masks/userTransform)
  |
  |-- precomp containing binding?
  |     --> RECURSE into edit traversal
  |     --> precomp container masks ARE emitted (they affect binding visibility)
  |     --> matte scope wrapping if precomp is a matte consumer
  |
  +-- otherwise       --> SKIP (decorative layers not needed)
```

### 7.3 Critical Invariant: No Visibility Check

**File:** `AnimIR.swift:378-382`

> **Invariant (PR-18):** This method intentionally does NOT check layer visibility
> (`isVisible(at: frame)`). Edit mode renders the binding layer's "editing pose"
> regardless of animation timing -- the binding layer must always be reachable
> even if it would be invisible at the current frame in playback mode.
> Do not add an isVisible guard here.

### 7.4 Binding Containment Cache

`compContainsBinding()` uses a cached lookup to avoid O(N^2) traversal
in deeply nested precomp hierarchies during edit mode.

---

## 8. Hit-Test System

### 8.1 Coordinate Chain

```
View space (UIKit pixels)
    |  viewToCanvas() = invert aspect-fit
    v
Canvas space (e.g. 1080x1920)
    |  blockTransform = SceneTransforms.blockTransform()
    v
Anim space (Lottie local)
    |  world matrix = layer parent chain
    v
MediaInput path (BezierPath vertices)
```

### 8.2 View-to-Canvas Conversion

**File:** `TemplateEditorController.swift:260-289`

```swift
func canvasToViewTransform() -> CGAffineTransform {
    let targetRect = RectD(x: 0, y: 0,
                           width: Double(viewSize.width),
                           height: Double(viewSize.height))
    let m = GeometryMapping.animToInputContain(animSize: canvasSize, inputRect: targetRect)
    return CGAffineTransform(a: m.a, b: m.b, c: m.c, d: m.d, tx: m.tx, ty: m.ty)
}

private func viewToCanvas(_ viewPoint: CGPoint) -> CGPoint {
    canvasToViewTransform().inverted().applying(viewPoint)
}

private func viewDeltaToCanvas(_ delta: CGPoint) -> CGPoint {
    // uniform scale only (no offset) -- exact for contain mapping
    let containScale = min(viewSize.width / canvasSize.width,
                           viewSize.height / canvasSize.height)
    return CGPoint(x: delta.x / containScale, y: delta.y / containScale)
}
```

Uses the same `GeometryMapping.animToInputContain` formula as MetalRenderer,
guaranteeing overlay geometry matches the rendered frame pixel-for-pixel.

### 8.3 Hit-Test Algorithm

**File:** `ScenePlayer.swift:295-323`

```
hitTest(point: Vec2D, frame: Int) -> String?

1. Walk blocks in REVERSE zIndex order (topmost first)
2. Skip blocks where !timing.isVisible(at: frame)
3. For each block:
   a. If hitTestMode == .mask:
      - Get mediaInputHitPath(blockId, frame) -> BezierPath in canvas coords
      - Test hitPath.contains(point:) using even-odd fill rule
      - Shape miss = skip to next block (NO rect fallback)
      - If no mediaInput path available: fall through to rect test
   b. If hitTestMode == .rect or nil:
      - Test bounds: point in rectCanvas
4. Return first (topmost) hit blockId, or nil
```

### 8.4 MediaInput Hit Path

**File:** `ScenePlayer.swift:254-282`

```
mediaInputHitPath(blockId, frame) -> BezierPath?

1. animIR.mediaInputPath(frame)    --> BezierPath in composition space
2. SceneTransforms.blockTransform() --> Matrix2D (anim -> canvas)
3. compSpacePath.applying(blockTransform) --> BezierPath in canvas space
```

Uses the **same** `SceneTransforms.blockTransform()` as the render pipeline.

### 8.5 Point-in-Path Testing

**File:** `AnimIRPath.swift`

```swift
public func contains(point: Vec2D) -> Bool {
    guard closed, vertices.count >= 3 else { return false }
    return cgPath.contains(CGPoint(x: point.x, y: point.y), using: .evenOdd)
}
```

- Even-odd fill rule
- Requires closed path with 3+ vertices
- Converts BezierPath to CGPath with proper curve/line segment handling
- Deterministic: same BezierPath always produces same CGPath

### 8.6 HitTestMode

**File:** `MediaInput.swift:67-74`

```swift
public enum HitTestMode: String, Decodable, Equatable, Sendable {
    case mask   // exact shape hit-test via mediaInput BezierPath
    case rect   // axis-aligned bounding box hit-test
}
```

Configured per-block in scene.json, propagated through compilation:
`MediaInput.hitTest` -> `BlockRuntime.hitTestMode`.

---

## 9. Overlay System

### 9.1 Overlay Data Generation

**File:** `ScenePlayer.swift:334-362`

```swift
public func overlays(frame: Int) -> [MediaInputOverlay]
```

- Walks blocks top-to-bottom (reversed zIndex)
- For `.mask` mode: uses `mediaInputHitPath()` shape
- For `.rect` / `nil`: builds path from `rectToBezierPath(blockRect)`
- Returns `[MediaInputOverlay]` with hitPath in **canvas coordinates**

### 9.2 MediaInputOverlay Structure

**File:** `ScenePlayerTypes.swift:203-224`

```swift
public struct MediaInputOverlay: Sendable {
    public let blockId: String
    public let hitPath: BezierPath      // canvas coordinates
    public let rectCanvas: RectD        // block rect (fallback)
    public let state: OverlayState      // inactive / hover / selected
}
```

### 9.3 OverlayState

**File:** `ScenePlayerTypes.swift:186-195`

```swift
public enum OverlayState: String, Sendable, Equatable {
    case inactive   // visible but not selected
    case hover      // pointer hovering (defined but not used in v1)
    case selected   // selected with full outline
}
```

### 9.4 Overlay Rendering

**File:** `EditorOverlayView.swift:39-81`

```swift
func update(overlays: [MediaInputOverlay], selectedBlockId: String?)
```

For each overlay:
1. Convert `overlay.hitPath.cgPath` from canvas coords to view coords via `canvasToView` transform
2. Create `CAShapeLayer` with converted path
3. Style based on selection state:

| State | Stroke Color | Width | Pattern |
|-------|-------------|-------|---------|
| Selected | `UIColor.systemBlue` | 2.0 pt | Solid |
| Inactive | `UIColor.white` alpha 0.4 | 1.0 pt | Dashed (4-4) |

4. Selected layer added **last** (drawn on top of all inactive layers)

**Properties:**
- `isUserInteractionEnabled = false` -- gestures pass through to Metal view
- `backgroundColor = .clear` -- fully transparent
- `contentsScale = UIScreen.main.scale` -- retina-sharp lines

### 9.5 Overlay Update Flow

**File:** `TemplateEditorController.swift:244-254`

```swift
private func updateOverlay() {
    guard let overlayView = overlayView else { return }
    guard state.mode == .edit, let player = player else {
        overlayView.update(overlays: [], selectedBlockId: nil)  // hide in preview
        return
    }
    let overlays = player.overlays(frame: ScenePlayer.editFrameIndex)
    overlayView.update(overlays: overlays, selectedBlockId: state.selectedBlockId)
}
```

Called on: mode switch, tap (selection change), layout change (`refreshOverlayIfNeeded`).

---

## 10. UserTransform Pipeline

### 10.1 Storage

**File:** `ScenePlayer.swift:19-22`

```swift
private var userTransforms: [String: Matrix2D] = [:]
```

Per-block dictionary. Each block has exactly one `Matrix2D` representing cumulative pan/zoom/rotate.
Default: `.identity` (no transform) for blocks not in the dictionary.

### 10.2 API

**File:** `ScenePlayer.swift:224-239`

```swift
public func setUserTransform(blockId: String, transform: Matrix2D)
public func userTransform(blockId: String) -> Matrix2D       // .identity fallback
public func resetAllUserTransforms()
```

### 10.3 Gesture Handlers

**File:** `TemplateEditorController.swift:157-234`

#### State Machine

```swift
private var gestureBaseTransform: Matrix2D = .identity   // snapshot at .began
private var lastAppliedTransform: Matrix2D = .identity   // updated at .changed, committed at .ended
```

Strategy:
- `.began`: snapshot `player.userTransform(blockId:)` as `gestureBaseTransform`
- `.changed`: compute delta, combine as `gestureBaseTransform.concatenating(delta)`
- `.ended`: commit `lastAppliedTransform` (no re-computation, avoids double-apply)

#### Pan

```swift
let canvasDelta = viewDeltaToCanvas(translation)
let delta = Matrix2D.translation(x: canvasDelta.x, y: canvasDelta.y)
let combined = gestureBaseTransform.concatenating(delta)
```

No pivot needed.

#### Pinch (Scale)

```swift
let pivot = viewToCanvas(recognizer.location(in: view))
let s = Double(recognizer.scale)
let delta = Matrix2D.translation(x: pivot.x, y: pivot.y)
    .concatenating(Matrix2D.scale(s))
    .concatenating(Matrix2D.translation(x: -pivot.x, y: -pivot.y))
let combined = gestureBaseTransform.concatenating(delta)
```

Formula: `T(p) . Scale(s) . T(-p)` -- scale around gesture pivot point.
UIKit `recognizer.scale` reset to 1.0 on `.ended`.

#### Rotation

```swift
let pivot = viewToCanvas(recognizer.location(in: view))
let angle = Double(recognizer.rotation)
let delta = Matrix2D.translation(x: pivot.x, y: pivot.y)
    .concatenating(Matrix2D.rotation(angle))
    .concatenating(Matrix2D.translation(x: -pivot.x, y: -pivot.y))
let combined = gestureBaseTransform.concatenating(delta)
```

Formula: `T(p) . Rotate(angle) . T(-p)` -- rotate around gesture pivot point.
UIKit `recognizer.rotation` reset to 0.0 on `.ended`.

### 10.4 End-to-End Flow

```
Gesture (UIKit, view space)
  | handlePan/Pinch/Rotation()
  | viewToCanvas() / viewDeltaToCanvas()
  v
Matrix2D delta (canvas space)
  | gestureBaseTransform.concatenating(delta)
  v
player.setUserTransform(blockId, transform)
  | userTransforms[blockId] = Matrix2D
  v
SceneRenderPlan.renderCommands(..., userTransforms)
  | userTransforms[blockId] ?? .identity
  v
animIR.renderEditCommands(frameIndex, userTransform)
  | RenderContext.userTransform
  v
emitRegularLayerCommands() --> InputClip path
  | resolved.worldMatrix.concatenating(userTransform)
  v
RenderCommand: pushTransform(M(t) = A(t) . U)
  v
MetalRenderer executes transform stack
```

---

## 11. Coordinate Spaces

### 11.1 Space Hierarchy

```
View space       (UIKit points, e.g. 390x844)
  |
  |  canvasToViewTransform() = GeometryMapping.animToInputContain
  |  (aspect-fit: uniform scale + center)
  v
Canvas space     (scene coordinates, e.g. 1080x1920)
  |
  |  SceneTransforms.blockTransform()
  |  (identity if anim == canvas size, otherwise contain)
  v
Anim space       (Lottie local, e.g. 1080x1920 or different)
  |
  |  layer world matrix (parent chain)
  v
Layer space      (individual layer coordinates)
  |
  |  computeMediaInputWorld() -- no userTransform
  v
MediaInput space (clip window coordinates)
```

### 11.2 Transform Sharing Guarantees

| Operation | Transform Source | Shared? |
|-----------|-----------------|---------|
| Render: block placement | `SceneTransforms.blockTransform()` | Yes |
| Hit-test: hit path | `SceneTransforms.blockTransform()` | Same function |
| Overlay: canvas-to-view | `GeometryMapping.animToInputContain()` | Same function |
| Metal renderer: canvas-to-view | `GeometryMapping.animToInputContain()` | Same function |

All coordinate mappings use shared formulas, guaranteeing geometric consistency
between render output, hit-test regions, and overlay outlines.

---

## 12. Tap-to-Select Flow (End-to-End)

```
User taps view at (500, 750)
  |
  v
TemplateEditorController.handleTap(viewPoint:)
  | guard state.mode == .edit
  |
  v
viewToCanvas(CGPoint(500, 750))
  | invert aspect-fit transform
  | result: e.g. Vec2D(543.2, 812.5)
  |
  v
player.hitTest(point:, frame: editFrameIndex)
  |
  for each block (topmost zIndex first):
  |   |
  |   |-- timing.isVisible(at: 0)? skip if not
  |   |
  |   |-- hitTestMode == .mask?
  |   |     mediaInputHitPath(blockId, 0) -> BezierPath (canvas)
  |   |     hitPath.contains(point)? -> return blockId
  |   |
  |   +-- hitTestMode == .rect or nil?
  |         point inside rectCanvas? -> return blockId
  |
  v
state.selectedBlockId = "block-42" (or nil)
  |
  v
updateOverlay()
  | player.overlays(frame: 0) -> [MediaInputOverlay]
  |
  v
EditorOverlayView.update(overlays, selectedBlockId: "block-42")
  | for each overlay:
  |   BezierPath -> CGPath -> apply canvasToView -> CAShapeLayer
  |   selected: blue solid 2pt (on top)
  |   inactive: white dashed 1pt
  |
  v
requestDisplay() --> Metal redraw with edit mode commands
  |
  v
onStateChanged?(state) --> VC updates UI (labels, buttons)
```

---

## 13. Architectural Invariants

| # | Invariant | Where Enforced | Evidence |
|---|-----------|----------------|----------|
| 1 | Edit frame is always 0 | `SceneRenderPlan.editFrameIndex = 0` | Single `let` constant |
| 2 | blockTransform identical for render and hit-test | `SceneTransforms.blockTransform()` | Shared enum, used by both |
| 3 | canvasToView identical for overlay and Metal | `GeometryMapping.animToInputContain()` | Shared function |
| 4 | mediaInput window is immovable | `computeMediaInputWorld()` without userTransform | Separate computation |
| 5 | UserTransforms isolated per block | `[String: Matrix2D]` dictionary | Independent entries |
| 6 | Edit traversal skips visibility check | `renderEditLayer()` has no `isVisible` guard | Documented invariant in code |
| 7 | Binding layer always reachable in edit | `compContainsBinding()` cache | Precomp chain always traversed |
| 8 | Render commands deterministic | Same input -> same output | Tests verify (TemplateModeTests T5) |
| 9 | Overlay and hit-test use same geometry | Both call `mediaInputHitPath()` | Same BezierPath source |

---

## 14. Known Limitations (v1)

### L1. Blocks with timing.startFrame > 0 are not editable

**File:** `SceneRenderPlan.swift:42-44`

```swift
// v1 limitation (PR-18): in edit mode sceneFrameIndex == editFrameIndex (0),
// so blocks whose timing starts after frame 0 are NOT editable.
// This is intentional for v1 -- a future version may show all blocks in edit.
guard block.timing.isVisible(at: sceneFrameIndex) else { continue }
```

Edit mode renders at frame 0. Blocks visible only at later frames are skipped.

### L2. OverlayState.hover is defined but not used

**File:** `ScenePlayerTypes.swift:190-191`

The `hover` case exists in the enum but `EditorOverlayView` only handles `selected` and `inactive`.
No hover detection is wired up in `TemplateEditorController`.

### L3. UserTransformsAllowed is not enforced

**File:** `MediaInput.swift:98-113`

`UserTransformsAllowed { pan, zoom, rotate }` is defined in the model and decoded from scene.json,
but `TemplateEditorController` gesture handlers do **not** check these permissions.
All gestures are always allowed regardless of the `userTransformsAllowed` configuration.

### L4. FitMode is not applied in render pipeline

**File:** `MediaInput.swift:86-95`

`FitMode` (cover/contain/fill) is defined and decoded but the render pipeline always uses
`GeometryMapping.animToInputContain` (contain mode). There is no code path for cover or fill modes.

### L5. No undo/redo for user transforms

`TemplateEditorController` stores only the current transform per block.
There is no undo stack or transform history. `resetAllUserTransforms()` resets everything to identity.

### L6. Single selection only

`state.selectedBlockId` is a single `String?`. No multi-block selection is supported.

---

## 15. Dependency Graph

```
TemplateEditorController (AnimiApp)
  |-- imports TVECore
  |-- owns: TemplateEditorState
  |-- uses: ScenePlayer (weak via setPlayer)
  |-- uses: EditorOverlayView (weak)
  |-- calls: ScenePlayer.renderCommands(mode:)
  |-- calls: ScenePlayer.hitTest(point:frame:)
  |-- calls: ScenePlayer.overlays(frame:)
  |-- calls: ScenePlayer.setUserTransform(blockId:transform:)
  |-- calls: GeometryMapping.animToInputContain (for coordinate mapping)
  +-- callbacks: onNeedsDisplay, onStateChanged

EditorOverlayView (AnimiApp)
  |-- imports TVECore (for MediaInputOverlay, BezierPath)
  |-- receives: canvasToView transform from controller
  +-- receives: overlays array from controller

ScenePlayer (TVECore)
  |-- owns: CompiledScene, userTransforms
  |-- uses: AnimIRCompiler (compilation)
  |-- uses: SceneRenderPlan (command generation)
  |-- uses: SceneTransforms (block transform)
  +-- exposes: hitTest, overlays, renderCommands, setUserTransform

SceneRenderPlan (TVECore)
  |-- uses: SceneTransforms.blockTransform()
  |-- uses: AnimIR.renderCommands() / renderEditCommands()
  +-- owns: editFrameIndex constant

AnimIR (TVECore)
  |-- owns: binding (BindingInfo), inputGeometry (InputGeometryInfo)
  |-- produces: [RenderCommand] with inputClip structure
  |-- uses: computeMediaInputWorld() for clip window
  +-- uses: compContainsBinding() cache for edit traversal
```
