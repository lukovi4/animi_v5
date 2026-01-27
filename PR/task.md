Ниже — **полное техническое задание (ТЗ) “под код”** для интеграции **GPU mask-texture (R8) + boolean ops** так, чтобы:

* **не сломать текущую логику** (track matte + masks работают правильно сейчас),
* убрать **CPU-raster masks** из “горячего пути”,
* получить корректные **add/subtract/intersect + inverted** + несколько масок на один слой,
* корректно работать при **любом масштабе preview** и при **export 1080×1920** (и будущих).

---

# 1) Цель и ограничения

## Цель

Заменить текущий CPU fallback для masks на **GPU-генерацию маски** в `R8Unorm` текстуру и **комбинирование boolean ops** (AE mask modes) на GPU, затем применять маску при композите.

## Важно сохранить

1. **Track matte pipeline** (alpha/alpha inverted + luma/luma inverted) должен продолжить работать **без изменений поведения**.
2. Существующая “маска как scope” (`beginMask…` → inner → `endMask`) должна продолжить корректно работать в render-graph (в т.ч. вложенности/группы/трансформ-стек).

## Вне скоупа (сейчас)

* Feather/blur для masks (можно оставить расширяемость, но не реализовывать).
* Глобальная замена shape CPU-raster на GPU (можно позже; сейчас делаем только masks).

---

# 2) Текущее состояние в коде (куда встраиваемся)

## Где сейчас “болит” CPU-raster

* `TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift`

  * `renderMaskScope(...)`:

    * рендерит innerCommands в offscreen `contentTex`
    * потом делает `maskCache.texture(...)` → это CPU-raster через `MaskRasterizer`
    * потом `compositeWithStencilMask(...)` (stencil-проходы)
* `TVECore/Sources/TVECore/MetalRenderer/MaskRasterizer.swift` — CoreGraphics raster.
* `TVECore/Sources/TVECore/MetalRenderer/MaskCache.swift` — кэш CPU-raster текстур.

## Что сейчас по mask-модам

* `RenderCommand` поддерживает только `.beginMaskAdd(...)` / `.endMask` (см. `TVECore/Sources/TVECore/RenderGraph/RenderCommand.swift`).
* `AnimIR` при генерации команд эмитит **несколько beginMaskAdd** для layer.masks, и потом **LIFO endMask** (см. `TVECore/Sources/TVECore/AnimIR/AnimIR.swift`).
* `AnimIRTypes.MaskMode` сейчас только `add` (см. `TVECore/Sources/TVECore/AnimIR/AnimIRTypes.swift`).

---

# 3) Новая архитектура (как должно работать)

## 3.1 Высокоуровневая схема

Для каждого mask-scope (на уровне RenderCommand исполнения):

1. **Собрать список всех масок**, которые должны применяться к одному и тому же innerCommands (в порядке AE).
2. Посчитать **bbox** объединения масок в пикселях **target** (с учётом animToViewport и текущего transform стека), затем пересечь с текущим scissor (clipStack).
3. На GPU:

   * построить `maskAccumTex` (`R8Unorm`, размер = bbox)
   * для каждой маски по очереди:

     * нарисовать `coverageTex` (`R8Unorm`) треугольниками PathResource (с учётом анимации пути на кадре)
     * если inverted → инвертировать coverage
     * умножить coverage на opacity
     * применить boolean op к `maskAccumTex` (add/subtract/intersect)
4. Отрендерить innerCommands в `contentTex` (желательно с scissor=bbox для экономии fillrate).
5. Скомпозить `contentTex` в target **с применением `maskAccumTex`** (alpha multiply / premultiplied корректно), с учётом scissor.

## 3.2 Почему НЕ stencil в финале

Stencil-clip ломает “мягкое” покрытие (AA/coverage), потому что превращает маску в бинарный тест.
Для будущего качества (и чтобы не спорить с AA) — **применяем maskTex в фрагменте** (умножение alpha), без stencil.

---

# 4) Изменения в данных и RenderCommand (чтобы поддержать все mask modes)

## 4.1 AnimIRTypes: расширить MaskMode

Файл: `TVECore/Sources/TVECore/AnimIR/AnimIRTypes.swift`

Сделать:

* `public enum MaskMode: String` добавить:

  * `add` (уже есть)
  * `subtract`
  * `intersect`
    (и если нужно на будущее — `none`, но сейчас не обязательно)

Маппинг из Lottie/AE строк (важно для совместимости bodymovin):

* add: `"a"`
* subtract: `"s"`
* intersect: `"i"`
* (если встречается в ваших json ещё что-то — добавить с явной ошибкой компиляции/валидации)

## 4.2 RenderCommand: новый beginMask, поддержка mode + inverted

Файл: `TVECore/Sources/TVECore/RenderGraph/RenderCommand.swift`

Заменить/расширить:

* было: `.beginMaskAdd(pathId:opacity:frame:)`
* станет: `.beginMask(mode: MaskMode, inverted: Bool, pathId: PathID, opacity: Double, frame: Double)`
* `.endMask` оставить.

**Важно:** старый `.beginMaskAdd` можно оставить временно как deprecated, но **execution** должен работать через новый кейс.
(Иначе вы навсегда застрянете в add-only.)

## 4.3 AnimIR.renderCommands: порядок масок (чтобы соответствовать AE)

Файл: `TVECore/Sources/TVECore/AnimIR/AnimIR.swift`

Сейчас вы эмитите masks в прямом порядке и закрываете LIFO — это даёт эффект “AND” только для add и ломает порядок для subtract/intersect.

Нужно:

* эмитить beginMask **в обратном порядке** массива `layer.masks`, чтобы применение шло как в AE:

  * begin maskN
  * begin maskN-1
  * …
  * begin mask1
  * content
  * end x N

Так внутренний (последний begin) применяется первым → итоговый порядок применения становится 1..N (как в AE).

И вместо `beginMaskAdd` использовать `beginMask(mode:inverted:pathId:opacity:frame:)`.

---

# 5) Extraction: собрать “MaskGroupScope”, а не один mask scope

Сейчас:

* `extractMaskScope(from:startIndex:)` возвращает `MaskScope` только для **одного beginMask** и innerCommands содержит остальные beginMask → фактически строится каскад offscreen-композитов.

Нужно заменить на extraction, которая **схлопывает вложенные маски** в один “групповой” scope.

Файл: `TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift`

## 5.1 Новая структура

```swift
struct MaskOp {
  let mode: MaskMode
  let inverted: Bool
  let pathId: PathID
  let opacity: Double
  let frame: Double
}

struct MaskGroupScope {
  let startIndex: Int
  let endIndex: Int
  let opsInAeOrder: [MaskOp]   // 1..N
  let innerCommands: [RenderCommand] // без mask-wrapper
}
```

## 5.2 Правило схлопывания

Если scope выглядит так:

* beginMask(X)

  * beginMask(Y)

    * beginMask(Z)

      * inner content...
    * endMask
  * endMask
* endMask

Extraction должна:

* собрать ops: `[Z, Y, X]` (в порядке применения)
* innerCommands = “самый внутренний контент без mask-обёрток”.

Это даёт возможность:

* сделать **один** `contentTex`
* сделать **один** `maskAccumTex`
* сделать **один** composite.

---

# 6) GPU pipeline: текстуры, шейдеры, compute boolean ops

## 6.1 Новые ресурсы/пулы текстур

Файл: `TVECore/Sources/TVECore/MetalRenderer/TexturePool.swift` (или где у вас pool; в snapshot видно `texturePool.acquireColorTexture(...)` и `acquireStencilTexture(...)` — расширяем там же)

Добавить:

* `acquireR8Texture(size: (w,h)) -> MTLTexture?`
* (опционально) `acquireR8TextureMSAA(size, sampleCount:4)` если решите AA через MSAA.

Требования:

* `pixelFormat = .r8Unorm`
* `usage = [.renderTarget, .shaderRead, .shaderWrite]` (shaderWrite если compute пишет напрямую)
* storageMode: `.private`

## 6.2 Шейдеры

Файл: `TVECore/Sources/TVECore/MetalRenderer/MetalRendererResources.swift` (там уже `shaderSource` строка)

Нужно добавить:

### A) Coverage render (рисуем треугольники пути в R8)

* vertex: принимает `float2 position` (в **anim space** или уже в viewport px — выберите одно и зафиксируйте)
* uniform: `mvp` (как сейчас для quad), плюс опционально `coverageScale` (opacity)
* fragment: возвращает `float`/`half` = coverage (обычно 1.0 * opacity)

PipelineState:

* colorAttachment pixelFormat: `.r8Unorm`
* blending: выключено (перерисовка = 1.0)
* depth/stencil: не нужен

### B) Masked composite (умножение контента на mask)

Новый fragment:

* texture0 = contentTex (bgra)
* texture1 = maskAccumTex (r8)
* sample mask → `mask = mask.r`
* output = content * mask (в premultiplied логике: rgb и a умножить на mask)

PipelineState:

* colorAttachment как основной рендер (`bgra8Unorm`)
* blending как сейчас (premultiplied)

### C) Compute kernel: boolean combine

Compute shader, который читает:

* `maskAccumTex` (read-write)

* `coverageTex` (read)
  и применяет op:

* add: `acc = max(acc, cov)`

* subtract: `acc = acc * (1 - cov)`

* intersect: `acc = min(acc, cov)`

Важно: “инициализация acc” зависит от первого op (см. 6.3).

---

## 6.3 Инициализация maskAccum (важно для корректности первого SUBTRACT)

AE-логика по сути применяет маски “на пустом или полном” в зависимости от первого режима.

Правило:

* если первая маска `subtract` → стартовое acc = 1.0
* иначе → стартовое acc = 0.0

Реализация:

* при старте построения `maskAccumTex`:

  * clear = 1.0 если first == subtract
  * clear = 0.0 иначе

---

# 7) Sampling PathResource на кадре (без BezierPath)

Сейчас `samplePath(resource:frame:)` делает CPU интерполяцию positions и превращает в BezierPath.

Для GPU coverage вам нужно **positions[] и indices[]**.

Сделать новую функцию в `MetalRenderer+Execute.swift`:

* `samplePathPositions(resource: PathResource, frame: Double) -> [Float]?`

  * та же логика, что в `samplePath`, только возвращает flattened `[x0,y0,...]`
* `indices` берём из `resource.indices`

Так вы не зависите от `BezierPath` и не теряете triangulation.

---

# 8) Bounding box и scissor (обязательное ускорение + корректность на preview scale)

## 8.1 Как считать bbox

Для каждой maskOp:

* берём `positions` на кадре
* прогоняем через transform:

  * `pathToViewportPx = ctx.animToViewport.concatenating(currentTransform)`
    (как сейчас делаете для CPU raster)
* считаем min/max по всем вершинам
* объединяем bbox всех масок

Потом:

* clamp bbox к `target.sizePx`
* расширить bbox на 1–2 px (чтобы не обрезать AA по краю)
* пересечь bbox со `currentScissor` (если clipStack активен)

Если bbox пустой:

* если итоговая маска по логике должна быть “пустая” → пропускаем композит
* если по логике должна быть “полная” (например subtract единственной маской с пустым coverage) → просто композитим content как есть
  (это редкие edge cases, но их надо описать и обработать детерминированно)

## 8.2 Рендер в bbox-локальную текстуру

`maskAccumTex` и `coverageTex` имеют размер bbox.

Нужна матрица:

* anim → viewportPx (как раньше)
* viewportPx → bboxLocalPx (translate -bboxMin)
* bboxLocalPx → NDC (через `GeometryMapping.viewportToNDC(width:bboxW,height:bboxH)`)

Именно эту MVP использовать в coverage pipeline.

---

# 9) Изменения в исполнителе MetalRenderer

Файл: `TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift`

## 9.1 Заменить renderMaskScope на renderMaskGroupScope

Новый метод:

`func renderMaskGroupScope(scope: MaskGroupScope, ctx: MaskScopeContext, inheritedState: ExecutionState) throws`

Шаги:

1. собрать ops, sample positions для bbox
2. создать `maskAccumTex`, `coverageTex` (из pool)
3. clear `maskAccumTex` стартовым значением (см. 6.3)
4. для каждой op:

   * нарисовать coverageTex (clear=0)
   * если inverted: в coverage fragment можно сделать `cov = 1 - cov` или отдельный compute-pass; проще — во fragment.
   * coverage *= opacity
   * compute combine → maskAccumTex
5. отрендерить innerCommands в `contentTex` (желательно с scissor=bbox∩currentScissor)
6. composite contentTex → target с maskAccumTex (masked fragment), scissor= currentScissor (или bbox∩currentScissor)

## 9.2 Не трогать Matte

`renderMatteScope(...)` / `compositeWithMatte(...)` оставить как есть, только убедиться, что новая mask логика не конфликтует со state stacks.

---

# 10) Backward compatibility / безопасный rollout

Добавить в `MetalRendererOptions` (файл `MetalRenderer.swift` или где у вас options):

* `maskBackend: MaskBackend = .gpuTextureOps`
  где:
* `.gpuTextureOps` — новый путь
* `.cpuRasterStencil` — старый путь (оставить как fallback на время релиза)

В `renderMask…` выбирать по опции.

---

# 11) Тесты и критерии приёмки

## 11.1 Обновить/добавить unit+integration тесты

Файл: `TVECore/Tests/TVECoreTests/MetalRendererMaskTests.swift`

Добавить тесты:

1. **ADD**: белый квадрат, маска-квадрат → внутри видно, снаружи прозрачно.
2. **SUBTRACT**: старт “полный” и вычесть квадрат → снаружи видно, внутри пусто.
3. **INTERSECT**: две add/intersect маски (например пересечение двух прямоугольников) → видна только общая область.
4. **INVERTED** для каждого mode (минимум для add и subtract).
5. **Несколько масок на один слой** с цепочкой режимов (add → subtract → intersect) и проверкой пары пикселей.
6. **Маска + matte**: слой под matte scope содержит masks — результат стабилен (не ломаем матты).

## 11.2 Критерии приёмки (must)

* Ни один существующий тест не должен начать флапать.
* Сцены из TestAssets, где “masks/mattes сейчас правильно”, должны давать **визуально тот же результат** (побайтно сравнивать можно позже; сейчас хотя бы pixel probes + golden images).
* В профайле:

  * не должно быть CoreGraphics raster в hot path (MaskRasterizer не вызывается при `.gpuTextureOps`)
  * время кадра при множественных масках не деградирует относительно текущего “CPU-raster + stencil”, и должно улучшиться на реальных сценах с анимированными масками.

---

# 12) Edge cases (чтобы у разработчика “не было вопросов”)

1. **Пустой path / degenerate (vertexCount < 3)**:

   * для add/intersect: coverage = 0
   * для subtract при старте acc=1: `acc = 1 * (1 - 0) = 1` (т.е. не влияет)
2. **Opacity=0**: mask-op не влияет.
3. **Opacity<1**:

   * add: даёт частичное покрытие (если вы делаете coverage=1*opacity)
   * subtract: вычитает частично (acc*=1-cov) — корректно и расширяемо
4. **Current scissor**:

   * bbox обязательно пересекать с scissor
   * если пересечение пустое — можно early exit
5. **Preview scale**:

   * bbox считается в пикселях текущего target
   * никаких “привязок” к 1080×1920 в preview
6. **Export 1080×1920**:

   * target фиксированный, bbox работает так же
7. **Детерминизм**:

   * никакой зависимости от UIScreen scale внутри оффскрина (как сейчас у вас в `RenderTarget.drawableScale` — использовать только там, где нужно)

---

# 13) Список конкретных файлов, которые будут затронуты

**Обязательные:**

* `TVECore/Sources/TVECore/RenderGraph/RenderCommand.swift` — новый beginMask (mode+inverted).
* `TVECore/Sources/TVECore/AnimIR/AnimIRTypes.swift` — MaskMode add/subtract/intersect.
* `TVECore/Sources/TVECore/AnimIR/AnimIR.swift` — эмит масок в обратном порядке + новый beginMask.
* `TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift` — extraction в MaskGroupScope + renderMaskGroupScope + GPU sampling positions + bbox.
* `TVECore/Sources/TVECore/MetalRenderer/MetalRendererResources.swift` — новые shaders + pipeline states + compute pipeline.

**Желательные:**

* `TVECore/Sources/TVECore/MetalRenderer/MaskRasterizer.swift`, `MaskCache.swift` — оставить как fallback/для дебага, но убрать из default-path.

**Тесты:**

* `TVECore/Tests/TVECoreTests/MetalRendererMaskTests.swift` — расширить кейсы на modes/invert/цепочки.

---

Если хочешь, я могу дополнить это ТЗ **прямо “по вашему стилю PR”**: разложить на 3 PR’а (infra/shaders → command+compiler → renderer+tests) и написать чек-лист ревью для каждого PR (что именно я буду проверять как техлид).
