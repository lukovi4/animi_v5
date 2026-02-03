# Edit Mode Refactor: Full Diff (Было / Стало)

> Суть: Edit mode переходит от "binding-only" render traversal к полному рендеру
> статического `no-anim` варианта на фрейме 0. Старый edit-specific код удален.

**Итого: 482 строк добавлено, 599 строк удалено**

---

## 1. `TVECore/Sources/TVECore/ScenePlayer/ScenePlayerError.swift`

**Что:** +4 новых ошибки компиляции для валидации контракта no-anim.

### Было
```swift
/// Invalid block timing configuration
case invalidBlockTiming(blockId: String, startFrame: Int, endFrame: Int)
}
```

### Стало
```swift
/// Invalid block timing configuration
case invalidBlockTiming(blockId: String, startFrame: Int, endFrame: Int)

/// Block is missing the required `no-anim` variant for edit mode
case missingNoAnimVariant(blockId: String)

/// The `no-anim` variant is missing the `mediaInput` shape layer
case noAnimMissingMediaInput(blockId: String, animRef: String)

/// The `no-anim` variant is missing the binding layer for the given key
case noAnimMissingBindingLayer(blockId: String, animRef: String, bindingKey: String)

/// The binding layer in `no-anim` variant is not visible at editFrameIndex
case noAnimBindingNotVisibleAtEditFrame(blockId: String, animRef: String, editFrameIndex: Int)
}
```

Плюс соответствующие `errorDescription` в extension `LocalizedError`:
```swift
case .missingNoAnimVariant(let blockId):
    return "Block '\(blockId)' is missing required 'no-anim' variant for edit mode"
case .noAnimMissingMediaInput(let blockId, let animRef):
    return "no-anim variant '\(animRef)' for block '\(blockId)' is missing 'mediaInput' shape layer"
case .noAnimMissingBindingLayer(let blockId, let animRef, let bindingKey):
    return "no-anim variant '\(animRef)' for block '\(blockId)' is missing binding layer '\(bindingKey)'"
case .noAnimBindingNotVisibleAtEditFrame(let blockId, let animRef, let editFrameIndex):
    return "Binding layer in no-anim variant '\(animRef)' for block '\(blockId)' is not visible at edit frame \(editFrameIndex)"
```

---

## 2. `TVECore/Sources/TVECore/ScenePlayer/ScenePlayerTypes.swift`

**Что:** +`editVariantId` в BlockRuntime, assertionFailure в resolvedVariant, удален enum RenderPolicy.

### 2a. BlockRuntime: новое поле `editVariantId`

#### Было
```swift
public struct BlockRuntime: Sendable {
    ...
    public let selectedVariantId: String
    public var variants: [VariantRuntime]
    ...
}
```

#### Стало
```swift
public struct BlockRuntime: Sendable {
    ...
    public let selectedVariantId: String

    /// Variant ID used for edit mode (always "no-anim").
    /// Guaranteed to exist after compilation (validated in compileBlock).
    public let editVariantId: String

    public var variants: [VariantRuntime]
    ...
}
```

### 2b. resolvedVariant: добавлен assertionFailure

#### Было
```swift
public func resolvedVariant(overrides: [String: String]) -> VariantRuntime? {
    let activeId = overrides[blockId] ?? selectedVariantId
    return variants.first(where: { $0.variantId == activeId }) ?? variants.first
}
```

#### Стало
```swift
public func resolvedVariant(overrides: [String: String]) -> VariantRuntime? {
    let activeId = overrides[blockId] ?? selectedVariantId
    let resolved = variants.first(where: { $0.variantId == activeId })
    if resolved == nil {
        assertionFailure("Variant '\(activeId)' not found for block '\(blockId)'. Falling back to first variant.")
    }
    return resolved ?? variants.first
}
```

### 2c. init: добавлен параметр editVariantId

#### Было
```swift
public init(
    ...
    selectedVariantId: String,
    variants: [VariantRuntime]
)
```

#### Стало
```swift
public init(
    ...
    selectedVariantId: String,
    editVariantId: String,
    variants: [VariantRuntime]
)
```

### 2d. TemplateMode doc-comment обновлен

#### Было
```swift
/// - `edit`: Static editing mode — time frozen at `editFrameIndex`, only binding layers visible.
```

#### Стало
```swift
/// - `edit`: Static editing mode. Time frozen at `editFrameIndex`.
///   Renders the full `no-anim` variant for each block.
///   `mediaInput` from `no-anim` defines hit-test and overlay geometry.
```

### 2e. RenderPolicy: удален целиком

#### Было
```swift
/// Render policy derived from `TemplateMode`.
public enum RenderPolicy: Sendable, Equatable {
    case fullPreview
    case editInputsOnly
}
```

#### Стало
*(удалено полностью)*

---

## 3. `TVECore/Sources/TVECore/ScenePlayer/ScenePlayer.swift`

**Что:** Compile-time валидация no-anim, рефакторинг renderCommands, mode в hitTest/overlays.

### 3a. compileBlock: валидация no-anim (новый код после строки 157)

#### Было
```swift
let selectedVariantId = mediaBlock.variants.first?.id ?? ""

return BlockRuntime(
    blockId: mediaBlock.id,
    ...
    selectedVariantId: selectedVariantId,
    variants: variantRuntimes
)
```

#### Стало
```swift
let selectedVariantId = mediaBlock.variants.first?.id ?? ""

// Resolve edit variant (must be "no-anim")
guard let editVariant = variantRuntimes.first(where: { $0.variantId == "no-anim" }) else {
    throw ScenePlayerError.missingNoAnimVariant(blockId: mediaBlock.id)
}

// Validate no-anim: must have mediaInput (inputGeometry)
guard editVariant.animIR.inputGeometry != nil else {
    throw ScenePlayerError.noAnimMissingMediaInput(
        blockId: mediaBlock.id,
        animRef: editVariant.animRef
    )
}

// Validate no-anim: binding layer must exist
let bindingLayerId = editVariant.animIR.binding.boundLayerId
let bindingCompId = editVariant.animIR.binding.boundCompId
guard let bindingComp = editVariant.animIR.comps[bindingCompId],
      let bindingLayer = bindingComp.layers.first(where: { $0.id == bindingLayerId }) else {
    throw ScenePlayerError.noAnimMissingBindingLayer(
        blockId: mediaBlock.id,
        animRef: editVariant.animRef,
        bindingKey: mediaBlock.input.bindingKey
    )
}

// Validate no-anim: binding layer must be visible at edit frame 0
let editFrame = Double(SceneRenderPlan.editFrameIndex)
guard AnimIR.isVisible(bindingLayer, at: editFrame) else {
    throw ScenePlayerError.noAnimBindingNotVisibleAtEditFrame(
        blockId: mediaBlock.id,
        animRef: editVariant.animRef,
        editFrameIndex: SceneRenderPlan.editFrameIndex
    )
}

return BlockRuntime(
    blockId: mediaBlock.id,
    ...
    selectedVariantId: selectedVariantId,
    editVariantId: editVariant.variantId,
    variants: variantRuntimes
)
```

### 3b. resolveVariant: поддержка mode

#### Было
```swift
private func resolveVariant(for block: BlockRuntime) -> VariantRuntime? {
    block.resolvedVariant(overrides: variantOverrides)
}
```

#### Стало
```swift
private func resolveVariant(for block: BlockRuntime, mode: TemplateMode = .preview) -> VariantRuntime? {
    switch mode {
    case .edit:
        return block.resolvedVariant(overrides: [block.blockId: block.editVariantId])
    case .preview:
        return block.resolvedVariant(overrides: variantOverrides)
    }
}
```

### 3c. hitTest, overlays, mediaInputHitPath: +mode параметр

#### Было
```swift
public func mediaInputHitPath(blockId: String, frame: Int = 0) -> BezierPath?
public func hitTest(point: Vec2D, frame: Int) -> String?
public func overlays(frame: Int) -> [MediaInputOverlay]
```

#### Стало
```swift
public func mediaInputHitPath(blockId: String, frame: Int = 0, mode: TemplateMode = .preview) -> BezierPath?
public func hitTest(point: Vec2D, frame: Int, mode: TemplateMode = .preview) -> String?
public func overlays(frame: Int, mode: TemplateMode = .preview) -> [MediaInputOverlay]
```

Внутри каждого метода `resolveVariant(for:)` заменен на `resolveVariant(for:mode:)`.

### 3d. renderCommands(mode:): рефакторинг с RenderPolicy на override map

#### Было
```swift
let policy: RenderPolicy
let frameIndex: Int

switch mode {
case .preview:
    policy = .fullPreview
    frameIndex = sceneFrameIndex
case .edit:
    policy = .editInputsOnly
    frameIndex = Self.editFrameIndex
}

return SceneRenderPlan.renderCommands(
    for: compiledScene.runtime,
    sceneFrameIndex: frameIndex,
    userTransforms: userTransforms,
    renderPolicy: policy,
    variantOverrides: variantOverrides
)
```

#### Стало
```swift
let frameIndex: Int
let overrides: [String: String]

switch mode {
case .preview:
    frameIndex = sceneFrameIndex
    overrides = variantOverrides
case .edit:
    frameIndex = Self.editFrameIndex
    // Build edit override map: every block -> its editVariantId
    overrides = Dictionary(
        uniqueKeysWithValues: compiledScene.runtime.blocks.map {
            ($0.blockId, $0.editVariantId)
        }
    )
}

return SceneRenderPlan.renderCommands(
    for: compiledScene.runtime,
    sceneFrameIndex: frameIndex,
    userTransforms: userTransforms,
    variantOverrides: overrides
)
```

---

## 4. `TVECore/Sources/TVECore/ScenePlayer/SceneRenderPlan.swift`

**Что:** Удален `renderPolicy` параметр, удален `renderBlockEditCommands` (~50 строк), убран switch.

### 4a. renderCommands signature: убран renderPolicy

#### Было
```swift
public static func renderCommands(
    for runtime: SceneRuntime,
    sceneFrameIndex: Int,
    userTransforms: [String: Matrix2D] = [:],
    renderPolicy: RenderPolicy = .fullPreview,
    variantOverrides: [String: String] = [:]
) -> [RenderCommand]
```

#### Стало
```swift
public static func renderCommands(
    for runtime: SceneRuntime,
    sceneFrameIndex: Int,
    userTransforms: [String: Matrix2D] = [:],
    variantOverrides: [String: String] = [:]
) -> [RenderCommand]
```

### 4b. Тело: switch renderPolicy заменен на прямой вызов

#### Было
```swift
let blockCommands: [RenderCommand]
switch renderPolicy {
case .fullPreview:
    blockCommands = renderBlockCommands(
        block: block, variant: &variant,
        sceneFrameIndex: sceneFrameIndex,
        canvasSize: canvasSize, userTransform: userTransform
    )
case .editInputsOnly:
    blockCommands = renderBlockEditCommands(
        block: block, variant: &variant,
        canvasSize: canvasSize, userTransform: userTransform
    )
}
```

#### Стало
```swift
let blockCommands = renderBlockCommands(
    block: block, variant: &variant,
    sceneFrameIndex: sceneFrameIndex,
    canvasSize: canvasSize, userTransform: userTransform
)
```

### 4c. renderBlockEditCommands: удален целиком (~50 строк)

#### Было
```swift
private static func renderBlockEditCommands(
    block: BlockRuntime,
    variant: inout VariantRuntime,
    canvasSize: SizeD,
    userTransform: Matrix2D
) -> [RenderCommand] {
    // ... ~50 строк: beginGroup("(edit)"), pushClipRect, pushTransform,
    // animIR.renderEditCommands(...), popTransform, popClipRect, endGroup
}
```

#### Стало
*(удалено полностью)*

---

## 5. `TVECore/Sources/TVECore/AnimIR/AnimIR.swift`

**Что:** Удалена вся edit-ветка: ~284 строки кода.

### Удалено

1. **`compContainsBindingCache`** — поле кэша:
```swift
// УДАЛЕНО:
private var compContainsBindingCache: [CompID: Bool] = [:]
```

2. **`renderEditCommands(frameIndex:userTransform:)`** — точка входа edit рендера (~30 строк)

3. **`renderEditComposition(_:context:commands:)`** — обход composition в edit mode (~5 строк)

4. **`renderEditLayer(_:context:commands:)`** — фильтр слоев для edit: binding layer, precomp chain, skip all else (~80 строк)

5. **`emitEditPrecompMatteScope(...)`** — matte scope для precomp контейнера в edit (~60 строк)

6. **`compContainsBinding(_:)`** — кэшированная проверка, содержит ли composition binding layer (~5 строк)

7. **`computeCompContainsBinding(_:)`** — рекурсивная реализация проверки (~15 строк)

8. Из `==` оператора убрана ссылка на `compContainsBindingCache`:
```swift
// Было: Exclude lastRenderIssues and compContainsBindingCache from comparison
// Стало: Exclude lastRenderIssues from comparison
```

---

## 6. `AnimiApp/Sources/Editor/TemplateEditorController.swift`

**Что:** hitTest и overlays теперь вызываются с `mode: .edit`.

### 6a. handleTap

#### Было
```swift
let hit = player.hitTest(
    point: Vec2D(x: Double(canvasPoint.x), y: Double(canvasPoint.y)),
    frame: ScenePlayer.editFrameIndex
)
```

#### Стало
```swift
let hit = player.hitTest(
    point: Vec2D(x: Double(canvasPoint.x), y: Double(canvasPoint.y)),
    frame: ScenePlayer.editFrameIndex,
    mode: .edit
)
```

### 6b. updateOverlay

#### Было
```swift
let overlays = player.overlays(frame: ScenePlayer.editFrameIndex)
```

#### Стало
```swift
let overlays = player.overlays(frame: ScenePlayer.editFrameIndex, mode: .edit)
```

---

## 7. `TVECore/Tests/TVECoreTests/TemplateModeTests.swift`

**Что:** Полностью переписан. Новая структура тестов:

| Тест | Было | Стало |
|------|------|-------|
| T1 | Preview renders full scene | Preview renders full scene *(без изменений)* |
| T1b | Preview matches legacy API | Preview matches legacy API *(без изменений)* |
| T2 | Edit renders only binding layers | **Edit renders full no-anim variant** |
| T2b | Edit has fewer drawImages than preview | **Edit uses inputClip from no-anim** |
| T3 | Edit ignores sceneFrameIndex | Edit ignores sceneFrameIndex *(без изменений)* |
| T3b | editFrameIndex is 0 | editFrameIndex is 0 *(без изменений)* |
| T4 | Edit fewer commands than preview | **Edit uses no-anim regardless of selection** |
| T4b | Edit excludes decorative layers | **Edit assets are subset of compiled** |
| T5 | Determinism (edit) | Determinism (edit) *(без изменений)* |
| T5b | Determinism (preview) | Determinism (preview) *(без изменений)* |
| T6a | *(не было)* | **missingNoAnimVariant throws** |
| T7 | *(не было)* | **Edit overlays use no-anim variant** |
| RenderPolicy cases | Проверка enum | **Удален** |
| assertShapesOnlyInMatteOrMaskScope | helper для T2 | **Удален** |

---

## 8. `TVECore/Tests/TVECoreTests/HitTestOverlayTests.swift`

**Что:** Добавлен `no-anim` variant во все тестовые сцены.

- Добавлен `private static let noAnimRef = "no-anim-test"`
- `makeScenePackage`: variants `[Variant(id: "v1", ...)]` -> `[Variant(id: "v1", ...), Variant(id: "no-anim", ...)]`
- `makeTwoBlockScene`: аналогично для обоих блоков
- `LoadedAnimations`: добавлен `noAnimRef: lottie` и `noAnimRef: assetIndex`
- `testBackwardsCompat_blockRuntimeDefaultHitTestMode`: добавлен `editVariantId: "no-anim"` в init

---

## 9. `TVECore/Tests/TVECoreTests/UserTransformPipelineTests.swift`

**Что:** Добавлен `no-anim` variant во все тестовые сцены (аналогично HitTestOverlayTests).

- Добавлен `private static let noAnimRef = "no-anim-test"`
- `makeScenePackage`: variants `[Variant(id: "v1", ...)]` -> `[Variant(id: "v1", ...), Variant(id: "no-anim", ...)]`
- `makeTwoBlockScenePackage`: аналогично для обоих блоков
- `LoadedAnimations`: добавлен `noAnimRef: lottie` и `noAnimRef: assetIndex`

---

## 10. `TVECore/Tests/TVECoreTests/VariantSwitchTests.swift`

**Что:** Обновлены assertions для новых variant counts + edit mode тест.

| Assertion | Было | Стало |
|-----------|------|-------|
| block_01 variants.count | 2 | **3** (v1, v2, no-anim) |
| block_02 variants.count | 1 | **2** (v1, no-anim) |
| availableVariants count | 2 | **3** |
| `testVariantSwitch_affectsEditMode` | edit follows selection | **`testEditMode_alwaysUsesNoAnimVariant`** |

Тест T6 переписан:
```swift
// Было: edit рендерит выбранный вариант
XCTAssertTrue(editAssetsV1.contains("anim-v1.json|image_0"))
// Стало: edit всегда рендерит no-anim
XCTAssertTrue(editAssetsDefault.contains("no-anim-b1.json|image_0"))
XCTAssertFalse(editAssetsAfterSwitch.contains("anim-v2.json|image_0"))
```

---

## 11. `TVECore/Tests/TVECoreTests/ScenePackageLoaderTests.swift`

**Что:** Обновлены assertions для fixture с no-anim вариантами.

| Assertion | Было | Стало |
|-----------|------|-------|
| `animFilesByRef.count` | 4 | **8** (4 anim + 4 no-anim) |
| `block1.variants.count` | 1 | **2** (v1 + no-anim) |

---

## 12. Тестовые fixture JSON: обновлены scene.json

### `example_4blocks/scene.json`

Каждый из 4 блоков получил дополнительный вариант:
```json
{
  "variantId": "no-anim",
  "animRef": "no-anim-N.json",
  "defaultDurationFrames": 1,
  "ifAnimationShorter": "holdLastFrame",
  "ifAnimationLonger": "cut",
  "loop": false
}
```

### `variant_switch/scene.json`

- block_01: добавлен `no-anim` -> `no-anim-b1.json`
- block_02: добавлен `no-anim` -> `no-anim-b2.json`

---

## 13. Новые файлы: no-anim Lottie JSON

Все файлы имеют одинаковую структуру: 1 фрейм (`op: 1`), hidden `mediaInput` shape layer (ty=4, hd=true) + `media` image layer (ty=2).

### `example_4blocks/` (4 файла)
- `no-anim-1.json` — w=540, h=960, asset img_1.png
- `no-anim-2.json` — w=540, h=960, asset img_2.png
- `no-anim-3.json` — w=540, h=960, asset img_3.png
- `no-anim-4.json` — w=540, h=960, asset img_4.png

### `variant_switch/` (2 файла)
- `no-anim-b1.json` — w=1080, h=1920, asset img_1.png
- `no-anim-b2.json` — w=1080, h=1920, asset img_1.png

Структура каждого файла:
```json
{
  "v": "5.12.1", "fr": 30, "ip": 0, "op": 1,
  "w": <width>, "h": <height>,
  "assets": [{ "id": "image_0", ... }],
  "layers": [
    { "ty": 4, "nm": "mediaInput", "hd": true, "shapes": [<rect path>], ... },
    { "ty": 2, "nm": "media", "refId": "image_0", ... }
  ]
}
```

---

## Результат сборки и тестов

```
Build complete! (2.63s) — 0 errors
Executed 749 tests, with 5 tests skipped and 0 failures (0 unexpected)
```
