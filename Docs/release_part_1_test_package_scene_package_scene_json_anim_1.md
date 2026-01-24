# Release Part 1 — Core Spec (универсально) + Test Profile (эталонный пакет)

Этот документ разделён на 2 части:
1) **Core Spec (универсально)** — релизный минимальный объём движка, который будет работать для **любого** шаблона, **если он укладывается в поддержанный поднабор Lottie-фич**.
2) **Test Profile: Reference Package v1** — описание **конкретного** шаблона (scene.json + anim-1..4 + images), на котором мы гарантированно тестируем реализацию Part 1.

---

# Part 1 — Core Spec (универсально)

## 1. Цель релиза
Сделать релизный «минимальный» компилятор и плеер, который:
- загружает ScenePackage,
- валидирует `scene.json` по Scene.json Spec v0.1,
- компилирует каждый `animRef` в нативный `AnimIR`,
- воспроизводит сцену в Metal **1-в-1 в пределах поддержанных Lottie-фич**, с приоритетом корректности **masks/mattes**,
- выдаёт детерминированный результат (одинаковый при одинаковом входе и `frameIndex`).

> Гарантия «для любого шаблона» действует только для шаблонов, которые **не выходят** за рамки поддержанного поднабора (см. раздел 4). Всё остальное должно фейлиться предсказуемой ошибкой `UnsupportedFeature`.

---

## 2. Входной формат

### 2.1 ScenePackage
ScenePackage — директория или zip. MUST содержать:
- `scene.json`
- набор `anim-*.json`, на которые ссылаются `mediaBlocks[].variants[].animRef`
- `images/` и другие ассеты, если анимации используют image assets

Loader MUST уметь работать с папкой и zip одинаково.

### 2.2 scene.json
`scene.json` MUST соответствовать Scene.json Spec v0.1:
- schemaVersion
- canvas (width/height/fps/durationFrames)
- mediaBlocks (rect, input, variants, timing, zIndex, maskRef, bindingKey, etc.)

---

## 3. Нормативные правила: Loader / Validator

### 3.1 ScenePackageLoader MUST
1) Открыть zip/директорию.
2) Прочитать и декодировать `scene.json`.
3) Собрать список `animRef` из `mediaBlocks[].variants[]`.
4) Для каждого `animRef`:
   - прочитать и декодировать JSON
   - собрать список image assets (`assets[]` с `u/p` или эквивалент)
5) Подготовить доступ к ассетам (`images/`):
   - проверка наличия файлов — MUST
   - lazy-декодинг изображения — допускается

Выход Loader:
- `SceneModel`
- `LottieByAnimRef: [AnimRef: LottieJSON]`
- `AssetIndex` (map: assetId → relativePath)

### 3.2 SceneValidator (v0.1) MUST
Validator обязан проверять:

1) **schemaVersion**
   - если версия не поддерживается → `SCENE_UNSUPPORTED_VERSION`

2) **FPS invariant**
   - `scene.canvas.fps` MUST == `anim.fr` для каждого `animRef`

3) **input.rect invariant**
   - `input.rect` MUST одинаковый для всех `variants` одного mediaBlock

4) **animRef existence**
   - каждый `variants[].animRef` MUST существовать в пакете

5) **Image assets resolvable**
   - каждый image asset, на который ссылается Lottie, MUST резолвиться в файл внутри ScenePackage
   - отсутствие → `ASSET_MISSING`

6) **Binding rule (универсально, Part 1)**
   - Для каждого `animRef` MUST существовать **ровно один** replaceable слой, где `nm == bindingKey`.
   - Если `bindingKey` не задан → default `"media"`.
   - Replaceable слой MUST быть **image layer** (`ty=2`) и MUST ссылаться на image asset.
   - Если найдено 0 → `BINDING_LAYER_NOT_FOUND`
   - Если найдено >1 → `BINDING_LAYER_AMBIGUOUS`

> Примечание: правило «ровно один слой» — сознательно строгий контракт Part 1. Позже оно расширяется (например, multi-binding), но Part 1 должен быть простым и детерминированным.

7) **Deterministic render order**
   - сортировка по `zIndex` (asc)
   - при равенстве — stable по порядку в `mediaBlocks` (как в scene.json)

8) **maskRef rule**
   - `maskRef` — только UI/hit-test; финальный рендер использует **только** masks/mattes из AnimIR/Lottie

9) **Геометрия: согласование координат (универсально)**
   Нужно зафиксировать ровно ОДНУ политику (MUST), иначе «1-в-1» развалится на разных темплейтах.

   **Политика Part 1 (простая и расширяемая):**
   - Весь `animRef` рисуется в координатах `variant.input.rect`.
   - Если `anim.w/h` != `input.rect.w/h`, то применяется uniform scale так, чтобы `anim` попал в `input.rect` по **contain** (без обрезки). Смещение по центру.

   Валидатор MUST:
   - если размеры не совпадают — выдавать `WARNING_ANIM_SIZE_MISMATCH` (warning), но не фейлить.

### 3.3 Формат ошибок
Ошибки MUST возвращаться как:
- `code` (stable)
- `message` (human-readable)
- `path` (краткий контекст: json-path или `animRef/layerName`)
- `severity` (error|warning)

Без stack trace и без внутренних деталей реализации.

---

## 4. AnimCompiler: Lottie → AnimIR (Part 1)

### 4.1 Цель AnimIR
AnimIR — нативный формат, который:
- вычисляет значения по кадрам детерминированно,
- генерирует список рендер-команд (RenderGraph),
- исполняется MetalRenderer без знания Lottie.

### 4.2 Поддерживаемый поднабор Lottie (универсально)
Компилятор MUST поддерживать:

#### 4.2.1 Композиции / Precomp
- root comp (`w/h/fr/ip/op`)
- `assets[].layers` и ссылки через layer `ty=0` + `refId`
- разворачивание precomp в render tree (логически), чтобы корректно применялись:
  - transforms родителя
  - masks/mattes на уровнях слоёв

#### 4.2.2 Layers
- `ty=0` precomp layer
- `ty=2` image layer
- `ty=3` null layer (как parent)
- `ty=4` shape layer **как источник matte**

#### 4.2.3 Transforms (ks)
MUST (static + keyframes):
- position (`p`)
- scale (`s`)
- rotation (`r`)
- opacity (`o`)
- anchor point (`a`)
- parenting (`parent`)

#### 4.2.4 Visibility window
MUST учитывать `ip/op/st`:
- слой рисуется только если `frameIndex` попадает в окно активности

#### 4.2.5 Временная модель
Источник тайминга — `scene.canvas`.

Политика Part 1 (MUST):
- `frameIndex` в ScenePlayer — целое `0…durationFrames-1`.
- Для каждого `animRef` используется `localFrameIndex = clamp(frameIndex, 0…(anim.op-1))`.
- Поведение при несовпадении длительностей управляется параметрами variant:
  - если анимация короче и `ifAnimationShorter == holdLastFrame` → clamp к последнему кадру
  - если анимация длиннее и `ifAnimationLonger == cut` → clamp к `durationFrames-1`

#### 4.2.6 Masks (masksProperties)
MUST поддержать:
- `masksProperties` на layer
- `mode == "a"` (add)
- `inv == false` (Part 1)
- `pt` path (Part 1 допускает `pt.a==0`, но архитектура MUST позволять добавить `pt.a==1` позже)
- `o` opacity (Part 1 статический)

#### 4.2.7 Track matte (td/tt)
MUST поддержать:
- matte source: layer с `td == 1`
- consumer: следующий слой с `tt == 1` или `tt == 2`
- интерпретация фиксируется (Part 1):
  - `tt == 1` → alpha matte
  - `tt == 2` → inverted alpha matte

#### 4.2.8 Shape layer как источник matte
В Part 1 shape поддерживается **только как matte**.

MUST поддержать внутри `ty=4`:
- `shapes[].ty == "gr"` (group)
- внутри group:
  - `ty == "sh"` (path)
  - `ty == "fl"` (fill) — достаточно альфа-канала
  - `ty == "tr"` (shape transform)

### 4.3 Неподдержанные фичи
Если встречается конструкция, без которой невозможно корректно отрендерить кадр в рамках 4.2, компилятор MUST вернуть:
- `UnsupportedFeature(code, context)`

Примеры кодов:
- `UNSUPPORTED_MASK_MODE`
- `UNSUPPORTED_MASK_INVERT`
- `UNSUPPORTED_MATTE_TYPE`
- `UNSUPPORTED_SHAPE_ITEM`
- `UNSUPPORTED_BLEND_MODE`
- `UNSUPPORTED_EFFECT`

---

## 5. RenderGraph и MetalRenderer (универсально)

### 5.1 Контракт RenderGraph (минимальный)
AnimIR на каждый кадр генерирует список команд.

Минимальные команды (MUST):
- `BeginGroup` / `EndGroup`
- `PushTransform(matrix)` / `PopTransform`
- `PushClipRect(rect)` / `PopClipRect`
- `DrawImage(assetId, opacity)`
- `BeginMaskAdd(path)` / `EndMask`
- `BeginMatteAlpha(matteSource)` / `BeginMatteAlphaInverted(matteSource)` / `EndMatte`

### 5.2 Реализация masks/mattes
MetalRenderer MUST реализовать masks/mattes через offscreen passes:
- mask add: offscreen content + offscreen mask alpha + compose
- track matte: offscreen matte alpha + apply to consumer (normal/inverted)

### 5.3 Детерминизм
Renderer MUST:
- соблюдать детерминированный порядок блоков (zIndex + stable)
- исполнять анимацию строго по `frameIndex` (без wall-clock)

---

## 6. ScenePlayer (универсально)

### 6.1 MUST функциональность
- Play / Pause
- Scrub по кадрам `0…durationFrames-1`
- Loop toggle
- Debug overlay: показать `block.rect` (не влияет на финальный рендер)

### 6.2 Округление времени в кадр
Если вводится время `t`, то `frameIndex` вычисляется строго по одной политике (MUST выбрать и зафиксировать):
- **Part 1:** `frameIndex = clamp(Int(round(t * fps)), 0…durationFrames-1)`

---

## 7. Definition of Done (Part 1 — Core)
Готово, если:
- ScenePackage загружается и валидируется по правилам 3.2
- все `animRef` компилируются в AnimIR или падают с понятной `UnsupportedFeature`
- ScenePlayer воспроизводит сцену (Play/Scrub/Loop) в `MTKView`
- masks/mattes (`mode=a`, `tt=1`, `tt=2`) работают корректно для любых входов, которые используют поддержанный поднабор
- порядок рендера детерминирован (zIndex + stable)

---

# Test Profile — Reference Package v1 (конкретный шаблон для тестов)

Эта часть описывает **конкретный** ScenePackage, на котором проверяем Part 1.

## TP1. Состав пакета
MUST присутствовать:
- `scene.json`
- `anim-1.json`, `anim-2.json`, `anim-3.json`, `anim-4.json`
- `images/`:
  - `img_1.png`, `img_2.png`, `img_3.png`, `img_4.png`

## TP2. Ожидаемые параметры scene.json
- canvas: 1080×1920
- fps: 30
- durationFrames: 300
- 4 блока 2×2:
  - (0,0,540,960) → anim-1
  - (540,0,540,960) → anim-2
  - (0,960,540,960) → anim-3
  - (540,960,540,960) → anim-4
- bindingKey везде: `media`
- containerClip: `slotRect`

## TP3. Набор проверочных кадров
Рекомендуемые кадры для golden-tests:
- 0, 15, 30, 45, 60, 75, 90, 105, 120

## TP4. Визуальные чекпоинты по блокам

### TP4.1 Block 01 (top-left) — anim-1
Суть: fade-in + mask add на replaceable image layer.
Ожидания:
- frame 0: блок невидим (opacity 0)
- frame 15: частично видим
- frame 30+: полностью видим
- изображение обрезано mask add (не прямоугольник)

### TP4.2 Block 02 (top-right) — anim-2
Суть: parented slide-in + track matte `tt=1`.
Ожидания:
- frame 0–29: блок не виден (ip=30)
- frame 30–60: движение сверху вниз (через parent)
- 60+: стабильно
- изображение видно только внутри matte (alpha)

### TP4.3 Block 03 (bottom-left) — anim-3
Суть: scale-in + inverted matte `tt=2`.
Ожидания:
- frame 0–59: блок не виден
- frame 60–90: scale 0→100 и применяется inverted matte
- 90+: стабильно

### TP4.4 Block 04 (bottom-right) — anim-4
Суть: scale-in + rotation + mask add.
Ожидания:
- frame 0–89: блок не виден
- frame 90–120: scale 0→100, rotation 0→360
- 120+: стабильно
- контент обрезан mask add

## TP5. DoD для Reference Package
Reference Package считается пройденным, если:
- все 4 анимации компилируются без ошибок
- все кадры из TP3 корректно отображают TP4.1–TP4.4
- golden-tests сохранены и используются для регрессии

