# Release Part 1 — Detailed Implementation Plan (Tech Lead)

Цель: реализовать **минимальный релизный движок** (Loader → Validator → AnimCompiler → AnimIR → RenderGraph → MetalRenderer → ScenePlayer), который:
- грузит ScenePackage,
- валидирует `scene.json` по Scene.json Spec v0.1,
- компилирует каждый `animRef` (Lottie JSON) в нативный `AnimIR`,
- воспроизводит сцену в `MTKView` детерминированно по `frameIndex`,
- **корректно** поддерживает **masks + track mattes** в рамках поддержанного поднабора Part 1,
- всё остальное падает предсказуемо `UnsupportedFeature(code, context)`.

---

## 0) Общее устройство (модули и границы ответственности)

### 0.1 Модули (рекомендуемая структура)
1) **ScenePackage**
   - `ScenePackageLoader`
   - `AssetIndex` (map assetId/ref → relativePath)
   - I/O (директория / zip)

2) **SceneModel**
   - Codable модели `scene.json` (runtime schema: без description-полей)

3) **SceneValidator**
   - валидация `scene.json` (Spec v0.1)
   - валидация `animRef` (Lottie subset scan + bindingKey + assets)
   - единый формат ошибок/варнингов

4) **LottieModel (Subset)**
   - минимальные Codable модели для Lottie JSON, только нужные поля Part 1

5) **AnimCompiler**
   - Lottie → `AnimIR`
   - precomp expansion (логически)
   - transforms sampling (static + keyframes)
   - visibility (ip/op/st)
   - masks/mattes IR

6) **AnimIR + RenderGraph**
   - `AnimIR` (структуры для вычисления значений по кадрам)
   - генерация `RenderGraph` команд для MetalRenderer

7) **MetalRenderer**
   - исполнение RenderGraph
   - offscreen passes для masks/mattes
   - texture pool / caching

8) **ScenePlayer**
   - Play/Pause/Loop/Scrub
   - mapping time→frameIndex
   - debug overlay (границы блоков)

9) **Tests**
   - unit tests (validator, compiler)
   - integration + golden tests (TP)

---

## 1) PR-план (логические шаги, последовательность)

### PR1 — Scene.json runtime модели + базовый Loader
**Deliverables**
- `Scene` Codable модели: canvas, background, mediaBlocks, variants, input, rect.
- `ScenePackageLoader` (директория) :
  - читает `scene.json`
  - собирает `animRefs` из `mediaBlocks[].variants[]`
  - возвращает `LoadedScenePackage { scene, animRefPaths[] }`

**DoD**
- Загружает текущий test package без краша.
- Ошибки I/O оформлены в единый тип `ScenePackageError`.

---

### PR2 — SceneValidator v0.1 (scene.json)
**Implement MUST checks (Core Spec 3.2 + Spec v0.1)**
- `schemaVersion` supported.
- canvas: width/height/fps/durationFrames > 0.
- `mediaBlocks[]` не пуст, уникальные `id`.
- `block.rect` валиден (не NaN/inf, w/h>0, в пределах canvas либо допускаем partial, но минимум w/h>0).
- `input.rect` валиден (w/h>0).
- `variants[]` не пуст.
- `variants[].animRef` не пуст.
- `bindingKey` не пуст.
- `zIndex` default = 0; рендер-сортировка stable.
- `containerClip` поддерживается: `none | slotRect` (Part 1).
- Правило: **input.rect одинаковый для всех variants одного блока**.
- `maskRef`: только UI/hit-test (Part 1), поэтому:
  - если указан → **warning** если не найден в каталоге (если каталога ещё нет — warning “catalog unavailable”).

**Error format**
- `code` (stable)
- `message`
- `path` (json-path)
- `severity` (error|warning)

**DoD**
- На неправильных сценах выдаёт понятные ошибки.
- На test package возвращает 0 errors (допустимы warnings).

---

### PR3 — Lottie loader + минимальные модели (Subset) + anim-level validation
**Deliverables**
- `LottieJSON` Codable subset:
  - root: `w,h,fr,ip,op,assets,layers`
  - assets: `id,w,h,u,p,layers`
  - layer subset: `ty,nm,refId,ip,op,st,ks,parent,tt,td,masksProperties,shapes`
  - ks: `p,s,r,o,a` (static + keyframes)
  - masksProperties: `mode,inv,o,pt`
  - shapes subset (для matte source): `gr`, `sh`, `fl`, `tr`.

**Anim validation (Core 3.2 + 4.2 scan)**
- FPS invariant: `scene.canvas.fps == anim.fr`.
- Size mismatch: если `anim.w/h != input.rect.w/h` → warning.
- BindingKey:
  - в каждом `animRef` MUST существовать replaceable image layer `ty=2` с `nm == bindingKey`.
- Asset presence:
  - все image assets (`assets[]` с `p`) должны резолвиться в package (если нет — error или warning по политике проекта).

**DoD**
- Загружает anim-1..4.
- Валидатор находит binding-layer и корректно проверяет fr/w/h.

---

### PR4 — AnimIR v1 (минимум) + RenderGraph контракт
**AnimIR (минимум Part 1)**
- `AnimIR` хранит:
  - composition tree (root + precomp refs)
  - список слоёв с таймингом (ip/op/st)
  - transform pipeline (parent chain)
  - mask/matte metadata
- RenderGraph commands (MUST):
  - `BeginGroup/EndGroup`
  - `PushTransform(matrix)/PopTransform`
  - `PushClipRect(rect)/PopClipRect`
  - `DrawImage(assetId, opacity)`
  - `BeginMaskAdd(path)/EndMask`
  - `BeginMatteAlpha(matteId)` / `BeginMatteAlphaInverted(matteId)` / `EndMatte`

**DoD**
- Есть чистые структуры + протокол `renderCommands(frameIndex) -> [Command]`.

---

### PR5 — Transform sampling (ks) + visibility window + parenting
**Implement**
- Visibility: слой активен только если `frameIndex ∈ [ip, op)` с учётом `st`.
- Keyframes:
  - линейная интерполяция для `p,s,r,o,a`.
  - `opacity` 0..100 → 0..1.
- Parenting:
  - вычисление world transform = parentWorld * local.
- Матрица:
  - apply anchor → scale → rotation → position (стандарт Lottie).

**DoD**
- Можно получить детерминированный transform на любой `frameIndex`.

---

### PR6 — Precomp expansion (логическое) + корректное наследование transforms/masks/mattes
**Implement**
- `ty=0` precomp layer с `refId`:
  - на этапе компиляции строим дерево (или flatten pipeline) так, чтобы:
    - transforms родителя применялись к детям
    - masks/mattes, заданные на уровне слоя, корректно действовали внутри nested comp
- Важно: не “забывать” rootParentTransform при входе в precomp.

**DoD**
- Корректная позиция/маски в nested пре-компах (архитектурно).

---

### PR7 — MetalRenderer baseline: DrawImage + transforms + clipRect
**Implement**
- `MTKView` pipeline:
  - textured quad
  - premultiplied alpha blending
- `PushTransform`: матрица в uniform.
- `PushClipRect`: scissor rect (в координатах target).
- `DrawImage`: draw call с opacity.

**DoD**
- Рисует простой кадр без masks/mattes.
- Детерминизм: одинаковый `frameIndex` → одинаковый пиксельный результат.

---

### PR8 — Masks (mode=a) через offscreen pass (Part 1)
**Goal**: `masksProperties` на layer, `mode=="a"`, `inv==false`, `o` статический.

**Recommended implementation**
- Offscreen textures: `contentTex`, `maskTex` (alpha-only), `resultTex` (можно сразу композить в target).
- Steps:
  1) Render layer content → `contentTex`.
  2) Render mask path → `maskTex` (alpha fill).
  3) Composite: `contentTex.alpha *= maskTex.alpha` (в shader) и вывести в target.

**Path rendering strategy (Part 1)**
- `pt.a==0` (static):
  - построить path один раз, закэшировать (триангуляция или raster alpha).
- Допустимо для Part 1:
  - rasterize mask в CPU (CoreGraphics) в alpha bitmap и грузить в Metal texture (кэшировать),
  - при этом сам композит делаем в Metal.

**DoD**
- anim-1 и anim-4: контент обрезан mask add (не прямоугольник).

---

### PR9 — Track Mattes (tt/td) через offscreen pass (Part 1)
**Goal**: `td==1` matte source, следующий слой consumer с `tt==1` (alpha) или `tt==2` (inverted).

**Implementation**
- Render matte source → `matteTex` (alpha).
- Render consumer content → `consumerTex`.
- Composite:
  - alpha matte: `consumerAlpha *= matteAlpha`
  - inverted: `consumerAlpha *= (1 - matteAlpha)`

**Shape layer as matte source (ty=4)**
- Поддержать внутри `shapes`:
  - `gr` group
  - `sh` path
  - `fl` fill (достаточно альфа)
  - `tr` transform
- Рендер shape matte в alpha (как и mask).

**DoD**
- anim-2: `tt=1` работает.
- anim-3: `tt=2` работает.

---

### PR10 — ScenePlayer (Play/Pause/Scrub/Loop) + time→frameIndex policy + debug overlay
**Implement**
- `ScenePlayer` state: `frameIndex`, `isPlaying`, `isLooping`.
- Timer/DisplayLink обновляет `frameIndex`.
- Policy Part 1:
  - `frameIndex = clamp(Int(round(t * fps)), 0…durationFrames-1)`.
- Scrub: внешний сет `frameIndex` мгновенно перерисовывает.
- Debug overlay (не влияет на финальный рендер):
  - рисовать прямоугольники `block.rect` поверх (отдельным debug pass).

**DoD**
- В `MTKView` можно играть, паузить, скрабить, лупать.

---

### PR11 — TP harness + Golden tests (Reference Package v1)
**TP requirements**
- Рендер кадров: 0, 15, 30, 45, 60, 75, 90, 105, 120.
- Проверки визуальных чекпоинтов по блокам:
  - block1: fade-in + mask
  - block2: появляется с 30 + parented slide + alpha matte
  - block3: появляется с 60 + scale + inverted matte
  - block4: появляется с 90 + scale + rotation + mask

**Golden tests**
- Генерировать PNG кадров в тестовом раннере.
- Сравнение с baseline:
  - строгий pixel match (0 tolerance) для детерминизма.
  - опционально режим “diff image” для дебага.

**DoD**
- TP пройден согласно документу:
  - все 4 anim компилируются без ошибок
  - TP-кадры соответствуют ожиданиям
  - baseline хранится и используется в CI как регрессия

---

## 2) Политики и решения, которые MUST быть зафиксированы в коде (без «магии»)

### 2.1 UnsupportedFeature
- Любая конструкция вне subset Part 1 → `UnsupportedFeature(code, context)`.
- Примеры кодов: `UNSUPPORTED_MASK_MODE`, `UNSUPPORTED_SHAPE_ITEM`, `UNSUPPORTED_EFFECT`, и т.д.

### 2.2 Determinism
- Никакой зависимости от wall-clock при вычислении кадра.
- Только вход: `scene + animIR + assets + frameIndex`.

### 2.3 Stable render order
- Сортировка блоков: `zIndex asc`, при равенстве — stable по порядку в JSON (или по `id`, но тогда это MUST быть зафиксировано).

### 2.4 Geometry mapping (block → input)
- `animRef` рисуется в координатах `input.rect`.
- Если размеры не совпали:
  - uniform scale contain + центрирование,
  - warning `WARNING_ANIM_SIZE_MISMATCH`.

---

## 3) Риски (и как не завалить релиз)

1) **Матрицы/parenting**: чаще всего баги именно здесь → писать unit tests на математику (несколько кадров, несколько слоёв).
2) **Matte ordering**: matte source не рисуется как обычный слой, а используется только как mask для следующего → аккуратно в компиляции и графе.
3) **Offscreen allocation**: без texture pool всё начнёт лагать → вводим простой `TexturePool` уже в PR8/PR9.
4) **Shape path fill**: самый опасный кусок. Для Part 1 допускаем static path + кэш.

---

## 4) Мини-чеклист для code review (я буду проверять в PR)

- Нет “второго рендера” того же subtree (двойной transform, двойной проход).
- Все ошибки проходят через единый `ValidationIssue` формат (code/message/path/severity).
- Любые допущения оформлены как явные политики (enum/константа), а не спрятаны в коде.
- Никаких «умных» оптимизаций до корректности.
- Маски/матты реализованы через явные offscreen passes.
- Детерминизм: одна и та же функция `render(frameIndex)` всегда даёт одинаковый результат.

---

## 5) Что разработчик должен прислать мне на контроль после каждого PR

- Список файлов/изменений.
- Короткое описание: что сделано, какие решения приняты.
- Как воспроизвести (demo screen / unit tests / golden output).
- Скриншоты/PNG кадров (для PR8+).
- Список известных ограничений/UnsupportedFeature.

