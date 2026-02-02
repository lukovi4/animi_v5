# PR-20: Variant Switching V1 — Полный diff изменений

> Дата: 2026-02-02
> Тесты: 725 passed, 0 failures (включая 19 новых VariantSwitchTests)

---

## Список затронутых файлов

| # | Файл | Тип изменения |
|---|------|---------------|
| 1 | `Sources/TVECore/ScenePlayer/ScenePlayerTypes.swift` | MODIFIED — добавлен `VariantInfo` DTO |
| 2 | `Sources/TVECore/ScenePlayer/ScenePlayer.swift` | MODIFIED — storage + API + resolver + обновление call sites |
| 3 | `Sources/TVECore/ScenePlayer/SceneRenderPlan.swift` | MODIFIED — `variantOverrides` параметр + resolver |
| 4 | `Tests/TVECoreTests/VariantSwitchTests.swift` | NEW — 19 тестов |
| 5 | `Tests/TVECoreTests/Resources/variant_switch/scene.json` | NEW — тестовая сцена |
| 6 | `Tests/TVECoreTests/Resources/variant_switch/anim-v1.json` | NEW — вариант A (img_1.png) |
| 7 | `Tests/TVECoreTests/Resources/variant_switch/anim-v2.json` | NEW — вариант B (img_2.png) |
| 8 | `Tests/TVECoreTests/Resources/variant_switch/anim-b2.json` | NEW — анимация block_02 |
| 9 | `Tests/TVECoreTests/Resources/variant_switch/images/img_1.png` | NEW — копия тестового изображения |
| 10 | `Tests/TVECoreTests/Resources/variant_switch/images/img_2.png` | NEW — копия тестового изображения |

---

## 1. ScenePlayerTypes.swift

**Путь:** `Sources/TVECore/ScenePlayer/ScenePlayerTypes.swift`

### Было (после строки 223, конец `MediaInputOverlay`):

```swift
// MARK: - Variant Runtime

/// Runtime representation of a compiled animation variant
public struct VariantRuntime: Sendable {
```

### Стало (вставлен новый блок между `MediaInputOverlay` и `VariantRuntime`):

```swift
// MARK: - Variant Info (PR-20)

/// Lightweight variant descriptor for UI — does not expose AnimIR internals.
public struct VariantInfo: Sendable, Equatable {
    /// Variant identifier
    public let id: String

    /// Animation reference (filename)
    public let animRef: String

    public init(id: String, animRef: String) {
        self.id = id
        self.animRef = animRef
    }
}

// MARK: - Variant Runtime

/// Runtime representation of a compiled animation variant
public struct VariantRuntime: Sendable {
```

**Зачем:** Легковесный DTO для UI — возвращает только `id` + `animRef`, не раскрывая внутренности `VariantRuntime`/`AnimIR`.

---

## 2. ScenePlayer.swift

**Путь:** `Sources/TVECore/ScenePlayer/ScenePlayer.swift`

### 2.1 Новое хранилище `variantOverrides`

**Было (после `userTransforms`):**

```swift
    private var userTransforms: [String: Matrix2D] = [:]

    // MARK: - Initialization
```

**Стало:**

```swift
    private var userTransforms: [String: Matrix2D] = [:]

    /// Per-block variant overrides (PR-20).
    /// Key: blockId. Value: variantId chosen by user.
    /// Blocks without an entry use `BlockRuntime.selectedVariantId` (compilation default = first).
    /// Compiled data remains immutable — overrides live here.
    private var variantOverrides: [String: String] = [:]

    // MARK: - Initialization
```

---

### 2.2 Новая секция: Variant Selection API (6 методов)

**Было (после `resetAllUserTransforms()`):**

```swift
    public func resetAllUserTransforms() {
        userTransforms.removeAll()
    }

    // MARK: - Hit-Test & Overlay (PR-17)
```

**Стало (вставлена целая секция между `resetAllUserTransforms` и `Hit-Test`):**

```swift
    public func resetAllUserTransforms() {
        userTransforms.removeAll()
    }

    // MARK: - Variant Selection (PR-20)

    /// Returns available variants for a block.
    ///
    /// - Parameter blockId: Identifier of the media block
    /// - Returns: Array of `VariantInfo` (id + animRef), or empty if block not found
    public func availableVariants(blockId: String) -> [VariantInfo] {
        guard let compiled = compiledScene else { return [] }
        guard let block = compiled.runtime.blocks.first(where: { $0.blockId == blockId }) else {
            return []
        }
        return block.variants.map { VariantInfo(id: $0.variantId, animRef: $0.animRef) }
    }

    /// Returns the active variant ID for a block (override or compilation default).
    ///
    /// - Parameter blockId: Identifier of the media block
    /// - Returns: Active variant ID, or `nil` if block not found
    public func selectedVariantId(blockId: String) -> String? {
        guard let compiled = compiledScene else { return nil }
        guard let block = compiled.runtime.blocks.first(where: { $0.blockId == blockId }) else {
            return nil
        }
        return variantOverrides[blockId] ?? block.selectedVariantId
    }

    /// Sets the selected variant for a block.
    ///
    /// If `variantId` does not match any compiled variant, the override is removed
    /// and the block falls back to its compilation default.
    ///
    /// - Parameters:
    ///   - blockId: Identifier of the media block
    ///   - variantId: Variant to select
    public func setSelectedVariant(blockId: String, variantId: String) {
        guard let compiled = compiledScene else { return }
        guard let block = compiled.runtime.blocks.first(where: { $0.blockId == blockId }) else {
            return
        }
        // Validate variantId exists in this block
        if block.variants.contains(where: { $0.variantId == variantId }) {
            variantOverrides[blockId] = variantId
        } else {
            // Invalid variantId — remove override, fall back to default
            variantOverrides.removeValue(forKey: blockId)
        }
    }

    /// Applies a variant selection mapping to multiple blocks at once (scene preset).
    ///
    /// Each entry maps `blockId -> variantId`. Invalid entries are silently skipped.
    ///
    /// - Parameter mapping: Dictionary of blockId to variantId
    public func applyVariantSelection(_ mapping: [String: String]) {
        for (blockId, variantId) in mapping {
            setSelectedVariant(blockId: blockId, variantId: variantId)
        }
    }

    /// Removes the variant override for a block, reverting to the compilation default.
    ///
    /// - Parameter blockId: Identifier of the media block
    public func clearSelectedVariantOverride(blockId: String) {
        variantOverrides.removeValue(forKey: blockId)
    }

    /// Resolves the active `VariantRuntime` for a block, respecting overrides.
    ///
    /// Resolution order:
    /// 1. Override in `variantOverrides[blockId]`
    /// 2. Compilation default `block.selectedVariantId`
    /// 3. First variant as ultimate fallback
    private func resolveVariant(for block: BlockRuntime) -> VariantRuntime? {
        let activeId = variantOverrides[block.blockId] ?? block.selectedVariantId
        return block.variants.first(where: { $0.variantId == activeId }) ?? block.variants.first
    }

    // MARK: - Hit-Test & Overlay (PR-17)
```

---

### 2.3 Обновление `mediaInputHitPath` — использует resolver

**Было:**

```swift
        guard let block = runtime.blocks.first(where: { $0.blockId == blockId }),
              var variant = block.selectedVariant else {
            return nil
        }
```

**Стало:**

```swift
        guard let block = runtime.blocks.first(where: { $0.blockId == blockId }),
              var variant = resolveVariant(for: block) else {
            return nil
        }
```

**Зачем:** `block.selectedVariant` всегда возвращал compilation default. Теперь `resolveVariant()` учитывает override-map.

---

### 2.4 Обновление `renderCommands(sceneFrameIndex:)` — передаёт overrides

**Было:**

```swift
        return SceneRenderPlan.renderCommands(
            for: compiledScene.runtime,
            sceneFrameIndex: sceneFrameIndex,
            userTransforms: userTransforms
        )
```

**Стало:**

```swift
        return SceneRenderPlan.renderCommands(
            for: compiledScene.runtime,
            sceneFrameIndex: sceneFrameIndex,
            userTransforms: userTransforms,
            variantOverrides: variantOverrides
        )
```

---

### 2.5 Обновление `renderCommands(mode:sceneFrameIndex:)` — передаёт overrides

**Было:**

```swift
        return SceneRenderPlan.renderCommands(
            for: compiledScene.runtime,
            sceneFrameIndex: frameIndex,
            userTransforms: userTransforms,
            renderPolicy: policy
        )
```

**Стало:**

```swift
        return SceneRenderPlan.renderCommands(
            for: compiledScene.runtime,
            sceneFrameIndex: frameIndex,
            userTransforms: userTransforms,
            renderPolicy: policy,
            variantOverrides: variantOverrides
        )
```

---

## 3. SceneRenderPlan.swift

**Путь:** `Sources/TVECore/ScenePlayer/SceneRenderPlan.swift`

### 3.1 Новый параметр `variantOverrides` в сигнатуре

**Было:**

```swift
    ///   - renderPolicy: Render policy (PR-18). `.fullPreview` renders all layers;
    ///     `.editInputsOnly` renders only binding layers + dependencies.
    /// - Returns: Array of render commands for all visible blocks
    public static func renderCommands(
        for runtime: SceneRuntime,
        sceneFrameIndex: Int,
        userTransforms: [String: Matrix2D] = [:],
        renderPolicy: RenderPolicy = .fullPreview
    ) -> [RenderCommand] {
```

**Стало:**

```swift
    ///   - renderPolicy: Render policy (PR-18). `.fullPreview` renders all layers;
    ///     `.editInputsOnly` renders only binding layers + dependencies.
    ///   - variantOverrides: Per-block variant overrides keyed by blockId (PR-20).
    ///     Blocks not present use `block.selectedVariantId` (compilation default).
    /// - Returns: Array of render commands for all visible blocks
    public static func renderCommands(
        for runtime: SceneRuntime,
        sceneFrameIndex: Int,
        userTransforms: [String: Matrix2D] = [:],
        renderPolicy: RenderPolicy = .fullPreview,
        variantOverrides: [String: String] = [:]
    ) -> [RenderCommand] {
```

**Зачем:** `SceneRenderPlan` — static enum без состояния. Overrides передаются как параметр (паттерн, аналогичный `userTransforms`).

---

### 3.2 Resolver внутри цикла блоков

**Было:**

```swift
            // Get selected variant
            guard var variant = block.selectedVariant else {
                continue
            }
```

**Стало:**

```swift
            // Resolve active variant: override → compilation default → first (PR-20)
            let activeVariantId = variantOverrides[block.blockId] ?? block.selectedVariantId
            guard var variant = block.variants.first(where: { $0.variantId == activeVariantId })
                    ?? block.variants.first else {
                continue
            }
```

**Логика разрешения:**
1. `variantOverrides[block.blockId]` — пользовательский override
2. `block.selectedVariantId` — compilation default (первый вариант)
3. `block.variants.first` — ultimate fallback (на случай если selectedVariantId невалиден)

---

## 4. VariantSwitchTests.swift (NEW)

**Путь:** `Tests/TVECoreTests/VariantSwitchTests.swift`

Полностью новый файл. 19 тестов:

| # | Тест | Что проверяет |
|---|------|---------------|
| T1 | `testCompilation_block01HasTwoVariants` | block_01 компилирует 2 варианта (v1, v2) |
| T2 | `testCompilation_block02HasOneVariant` | block_02 компилирует 1 вариант |
| T3 | `testAvailableVariants_returnsCorrectVariantInfo` | `availableVariants()` возвращает `VariantInfo` с правильными id/animRef |
| T4 | `testAvailableVariants_unknownBlock_returnsEmpty` | Несуществующий блок -> пустой массив |
| T5 | `testSelectedVariantId_defaultIsFirstVariant` | После компиляции default = "v1" (первый) |
| T6 | `testSelectedVariantId_unknownBlock_returnsNil` | Несуществующий блок -> nil |
| T7 | `testSetSelectedVariant_changesActiveVariant` | v1 -> v2 -> v1 переключение работает |
| T8 | `testVariantSwitch_changesDrawImageAssetId` | Render: `anim-v1.json\|image_0` -> `anim-v2.json\|image_0` |
| T9 | `testVariantSwitch_doesNotAffectOtherBlocks` | Переключение block_01 не трогает block_02 |
| T10 | `testVariantSwitch_affectsEditMode` | Переключение работает через `.edit` renderPolicy |
| T11 | `testInvalidVariant_fallsBackToDefault` | Невалидный variantId -> fallback на compilation default |
| T12 | `testInvalidVariant_removesExistingOverride` | Невалидный variantId очищает существующий override |
| T13 | `testApplyVariantSelection_setsMultipleBlocks` | Batch-preset для нескольких блоков |
| T14 | `testApplyVariantSelection_skipsInvalidEntries` | Невалидные записи пропускаются |
| T15 | `testClearOverride_revertsToDefault` | `clearSelectedVariantOverride()` -> revert к default |
| T16 | `testCommandsBalanced_afterVariantSwitch` | Команды сбалансированы после переключения |
| T17 | `testDeterminism_sameVariantSameFrame` | Один вариант + один фрейм = детерминистичный результат |
| T18 | `testMergedAssetIndex_containsAllVariantAssets` | Merged index содержит ассеты всех вариантов |
| T19 | `testBeforeCompile_apiReturnsDefaults` | API безопасен до compile() — не крашится |

---

## 5. Тестовые ресурсы (NEW)

### 5.1 `Tests/TVECoreTests/Resources/variant_switch/scene.json`

Тестовая сцена с 2 блоками:
- **block_01**: 2 варианта (`v1` -> `anim-v1.json`, `v2` -> `anim-v2.json`)
- **block_02**: 1 вариант (`v1` -> `anim-b2.json`)

```json
{
  "schemaVersion": "0.1",
  "sceneId": "scene_variant_switch",
  "canvas": { "width": 1080, "height": 1920, "fps": 30, "durationFrames": 300 },
  "mediaBlocks": [
    {
      "blockId": "block_01",
      "zIndex": 0,
      "rect": { "x": 0.0, "y": 0.0, "width": 540.0, "height": 960.0 },
      "containerClip": "slotRect",
      "variants": [
        { "variantId": "v1", "animRef": "anim-v1.json", ... },
        { "variantId": "v2", "animRef": "anim-v2.json", ... }
      ]
    },
    {
      "blockId": "block_02",
      "zIndex": 1,
      "rect": { "x": 540.0, "y": 0.0, "width": 540.0, "height": 960.0 },
      "containerClip": "slotRect",
      "variants": [
        { "variantId": "v1", "animRef": "anim-b2.json", ... }
      ]
    }
  ]
}
```

### 5.2 `anim-v1.json` — Вариант A

Минимальный Lottie: 1080x1920, 30fps, 300 frames.
Precomp с одним image layer `nm: "media"`, ссылка на `images/img_1.png`.
После компиляции asset ID = `anim-v1.json|image_0`.

### 5.3 `anim-v2.json` — Вариант B

Идентичная структура, но ссылка на `images/img_2.png`.
После компиляции asset ID = `anim-v2.json|image_0`.

Различие в `"p"` внутри `assets[0]`:
- anim-v1.json: `"p": "img_1.png"`
- anim-v2.json: `"p": "img_2.png"`

### 5.4 `anim-b2.json` — Анимация block_02

Идентична anim-v1.json (ссылка на img_1.png). Используется для проверки изоляции блоков.

### 5.5 `images/img_1.png`, `images/img_2.png`

Копии из `Resources/example_4blocks/images/`. Нужны для корректной загрузки через `ScenePackageLoader`.

---

## Архитектурная схема

```
ScenePlayer                          SceneRenderPlan (static enum)
+------------------------------+     +----------------------------------+
| variantOverrides: [S: S]     |     | renderCommands(                  |
|                              |     |   for:, sceneFrameIndex:,        |
| setSelectedVariant(b, v)     |     |   userTransforms:,               |
|   -> validates v exists      |     |   renderPolicy:,                 |
|   -> variantOverrides[b] = v |     |   variantOverrides: [S: S] = [:] | <-- NEW param
|                              |     | )                                |
| renderCommands(frame:)       |---->|                                  |
|   passes variantOverrides    |     | for block in runtime.blocks:     |
|                              |     |   activeId = overrides[b]        |
| resolveVariant(for: block)   |     |     ?? block.selectedVariantId   |
|   overrides[b]               |     |   variant = block.variants       |
|     ?? block.selectedVariantId|    |     .first(where: id == activeId)|
|     -> .first fallback       |     |     ?? .first                    |
+------------------------------+     +----------------------------------+
```

Resolver-логика дублируется в двух местах:
1. **ScenePlayer.resolveVariant()** — для `mediaInputHitPath()` и других instance-методов
2. **SceneRenderPlan** (inline) — для static render pipeline

Обе точки используют идентичную цепочку: `override -> default -> first fallback`.
