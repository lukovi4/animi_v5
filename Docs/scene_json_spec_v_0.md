# Scene.json Spec v0.1 — Example + Rules

Этот документ фиксирует **структуру одной сцены** (scene.json) и **нормативные правила**: что можно/нельзя, и откуда берутся данные.

> ВАЖНО: Поля `description*` в примере ниже присутствуют **только для документации**. В runtime-схеме движка они должны быть **удалены** или **игнорироваться**.

---

## 0) Версионирование схемы (MUST)

- `schemaVersion` MUST присутствовать в корне `scene.json`.
- Движок MUST уметь валидировать `schemaVersion` и отказывать в загрузке/рендере для неподдерживаемых версий.

---

## 1) Единый пример scene.json (2 блока)

```json
{
  "schemaVersion": "0.1",
  "sceneId": "scene_polaroid_01",

  "canvas": {
    "width": 1080,
    "height": 1920,
    "fps": 30,
    "durationFrames": 300,
    "description": "Scene timeline duration in frames. One scene = one timeline."
  },

  "background": {
    "type": "solid",
    "color": "#0B0D1A",
    "description": "Optional. If omitted, background is transparent (composited by template/app)."
  },

  "mediaBlocks": [
    {
      "blockId": "block_01",
      "zIndex": 0,
      "description": "MediaBlock defines a replaceable animated container in the scene.",

      "rect": {
        "description": "Block container rect on CANVAS (scene coordinates).",
        "x": 80.0,
        "y": 180.0,
        "width": 540.0,
        "height": 720.0
      },

      "containerClip": "slotRectAfterSettle",
      "containerClipDescription": "Clip mode for the block container. This does NOT affect final render masks; it is only a container clip policy.",

      "timing": {
        "startFrame": 0,
        "endFrame": 300,
        "description": "Block visibility/timeline range in scene frames."
      },

      "input": {
        "description": "Editable InputBlock slot inside the MediaBlock. This is what the user taps to add/replace media.",

        "rect": {
          "description": "Input slot rect in LOCAL coordinates of the MediaBlock (not canvas). Defines where the user media lives inside the block.",
          "x": 40.0,
          "y": 60.0,
          "width": 460.0,
          "height": 560.0
        },

        "bindingKey": "media",
        "bindingKeyDescription": "Stable key used to bind this input slot to the corresponding replaceable placeholder inside the compiled animation (AnimIR). Default: \"media\".",

        "maskRef": "mask_polaroid_rect",
        "maskRefDescription": "Reference to a static mask shape stored in the app (svg/pdf/etc.) via AppAssetCatalog. Used for UI hit-testing and edit preview. Final render uses masks/mattes from the compiled animation (AnimIR/Lottie).",

        "hitTest": "mask",
        "hitTestDescription": "Tap target uses the exact mask shape (not just bounding box).",

        "allowedMedia": ["photo", "video", "color"],
        "allowedMediaDescription": "Types allowed for this input slot (union). Exactly ONE source is active at a time: either 'photo' or 'video' or 'color'. 'color' MAY be included as a fallback/underlay, but it is never a second active media source.",

        "emptyPolicy": "hideWholeBlock",
        "emptyPolicyDescription": "If input has no media and no fallback color, the entire MediaBlock is not rendered.",

        "fitModesAllowed": ["cover", "contain", "fill"],
        "fitModesAllowedDescription": "How media fits within the input slot. Users can also pan/zoom/rotate when enabled below.",

        "userTransformsAllowed": {
          "pan": true,
          "zoom": true,
          "rotate": true
        },
        "userTransformsAllowedDescription": "Whether the user can interactively change content transform in editor.",

        "defaultFit": "cover",
        "defaultFitDescription": "Default fit mode for newly placed media.",

        "audio": {
          "enabled": false,
          "gain": 1.0,
          "description": "Optional. Only relevant if allowedMedia includes video and audio extraction is supported."
        }
      },

      "variants": [
        {
          "variantId": "v1",
          "animRef": "anim-1.json",
          "description": "Variant uses an animation compiled from Lottie (Bodymovin).",

          "defaultDurationFrames": 300,
          "ifAnimationShorter": "holdLastFrame",
          "ifAnimationLonger": "cut",
          "loop": false
        },
        {
          "variantId": "v2",
          "animRef": "anim-1_alt.json",
          "defaultDurationFrames": 300,
          "ifAnimationShorter": "holdLastFrame",
          "ifAnimationLonger": "cut",
          "loop": false
        }
      ]
    },

    {
      "blockId": "block_02",
      "zIndex": 1,

      "rect": {
        "x": 620.0,
        "y": 980.0,
        "width": 380.0,
        "height": 520.0
      },

      "containerClip": "slotRect",

      "timing": {
        "startFrame": 24,
        "endFrame": 300
      },

      "input": {
        "rect": {
          "x": 20.0,
          "y": 30.0,
          "width": 340.0,
          "height": 440.0
        },

        "bindingKey": "media",
        "bindingKeyDescription": "Stable key used to bind this input slot to the corresponding replaceable placeholder inside the compiled animation (AnimIR). Default: \"media\".",

        "maskRef": "mask_round",
        "hitTest": "rect",

        "allowedMedia": ["photo", "color"],
        "emptyPolicy": "renderWithColorFallback",
        "fitModesAllowed": ["cover", "contain"],
        "defaultFit": "contain",

        "userTransformsAllowed": {
          "pan": true,
          "zoom": true,
          "rotate": false
        }
      },

      "variants": [
        {
          "variantId": "v1",
          "animRef": "anim-2.json",
          "defaultDurationFrames": 276,
          "ifAnimationShorter": "loop",
          "ifAnimationLonger": "cut",
          "loop": true,
          "loopRange": { "startFrame": 24, "endFrame": 276 }
        }
      ]
    }
  ]
}
```

---

## 2) Что покрывает этот JSON (включая корнер-кейсы)

### Геометрия и клип

- `mediaBlock.rect` — положение блока на канвасе.
- `input.rect` — положение слота внутри блока (локальные координаты).
- `containerClip` — политика клипа контейнера.

### Тайминг

- Тайминг сцены — `canvas.durationFrames`.
- Тайминг блока — `timing.startFrame/endFrame`.

### Variants

- У блока может быть несколько вариантов анимации.
- Variants **могут иметь разную длину**.
- Смена варианта:
  - может менять **движение контейнера** (появление/движение/opacity/scale).
  - **НЕ должна менять mapping input** (input local rect + трактовка координат) — чтобы пользовательские трансформы переносились.
  - **MUST:** `input.rect` одинаковый для всех `variants` данного блока.

### Input

- `allowedMedia` описывает разрешённые типы: `photo`, `video`, `color`.
- `colorUsage: underlayAndFallback`:
  - цвет может быть **подложкой** под медиа (например при contain).
  - цвет может быть **заменой** медиа.
- `emptyPolicy`:
  - `hideWholeBlock` — не рендерим блок.
  - `renderWithColorFallback` — рендерим блок только с цветом.

### Background

- Опциональный фон сцены. Если отсутствует — фон прозрачный.

---

## 3) Что можно делать / что нельзя делать (Normative Rules)

### 3.1 Что можно

1. **Можно менять `variants` без потери user content transform:**

   - Пользовательские трансформы (pan/zoom/rotate) должны оставаться валидными при смене варианта.

2. **Можно иметь 1..N блоков** в одной сцене.

3. **Можно иметь разные `allowedMedia` для разных блоков**.

---

### 3.2 Что нельзя

1. **В runtime активен ровно один источник контента из `input.allowedMedia`.**

   `input.allowedMedia` — это список допустимых типов для выбора (union), а не “одновременная композиция”.
   Разрешено указывать `["photo","video","color"]`, но одновременно **нельзя** иметь два активных источника.

   Правило:
   - Active source MUST быть ровно один: `photo` XOR `video` XOR `color`.
   - Если `color` присутствует в `allowedMedia`, он считается fallback/underlay (например при contain или если медиа не задано), но не вторым активным медиа.

2. **Нельзя менять смысл `input.rect` между variants** (см. правило invariants).

3. **Нельзя недетерминированный порядок рендера**.

4. **Нельзя ссылаться на несуществующие ресурсы:**

   - `maskRef` MUST существовать в AppAssetCatalog.
   - `animRef` MUST существовать в нативном хранилище анимаций (AnimIR store).

5. **Input layer binding (MUST):**

   - В каждом `animRef` MUST существовать ровно один replaceable слой, имя которого `nm == input.bindingKey` (по умолчанию `"media"`).
   - Если replaceable слоёв с `nm == input.bindingKey` равно 0 или >1 — блок MUST считаться невалидным (или блок не рендерится с ошибкой в логах).

6. **Render order determinism (MUST):**

   - Рендер блоков MUST быть детерминированным.
   - Сортировка по `zIndex`.
   - При равенстве `zIndex` MUST использовать stable-sort по порядку в массиве `mediaBlocks`.

---

## 4) Откуда берутся данные (Source of Truth)

### Из `scene.json`

- Canvas параметры.
- MediaBlocks layout.
- Input контракт (allowedMedia, hitTest, maskRef, emptyPolicy, etc.).
- Variants выбор анимаций.

### Из AppAssetCatalog (глобально, вне scene.json)

- Реальные `maskRef` ресурсы.
- Реальные `animRef` ресурсы (AnimIR store).

### Из Lottie (`anim-x.json`) — только при импорте

- Слои, маски, матты, precomp, keyframes.

### Из AnimIR (compiled)

- Финальная структура рендера для Metal.
- Финальные маски/матты для output.

### Из Project / SceneInstance (пользовательский state)

- Что пользователь подставил в input.
- Пользовательские трансформы.
- Выбранные variants.
- Таймлайн изменения (если разрешено приложением).

---

## 5) Пояснение: почему некоторые «нельзя» не выражаются полями JSON

Некоторые ограничения — это **нормативные правила системы**, а не поля данных. Их проще и правильнее enforce'ить валидатором и контрактом движка.

