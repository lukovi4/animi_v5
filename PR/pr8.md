# PR8 — Masks rendering pass (stencil) (Part 1)

## 0) Goal (что делаем)

Расширить `MetalRenderer` (из PR7) так, чтобы он **реально применял `BeginMaskAdd(path)…EndMask`** и корректно обрезал контент **внутри mask-group**.

**Поддерживаемая маска (Part 1, MUST):**

* `mode == "a"` (add)
* `inv == false`
* `o` (opacity) статический
* `pt` path статический (`pt.a == 0`) — архитектура должна позволить добавить animated позже, но в PR8 не делаем 
* Все остальное — не поддерживаем (но на PR8 можно считать, что валидатор уже отсеял). 

**DoD PR8 (обязательный):**

* На референс-пакете **anim-1 и anim-4** видно, что replaceable image **обрезана маской** (не прямоугольником).

---

## 1) Non-goals (что НЕ делаем в PR8)

* Track Mattes (`BeginMatte*`) — это PR9. 
* Shape rasterization как полноценный GPU path renderer.
* Animated masks (`pt.a==1`), inverted masks, mask modes кроме add.

---

## 2) Контракт исполнения RenderCommand (норматив)

`MetalRenderer` должен исполнять список `RenderCommand` (из `AnimIR.renderCommands(frameIndex:)`) и:

### 2.1 Поведение масок

* `BeginMaskAdd(path)` начинает “mask scope”.
* Все команды между `BeginMaskAdd` и соответствующим `EndMask` рендерятся как “subtree” и **результат subtree** применяет маску.
* Поддержать **вложенные маски** (nesting): `BeginMaskAdd` внутри mask-scope должен работать как пересечение (по факту через рекурсию, см. ниже).
* Баланс begin/end **обязан** быть проверен (как в PR7 тестах на no-op / unbalanced).

---

## 3) Архитектура (как именно делаем stencil mask)

Мы делаем маски **через offscreen passes** (Part 1) , но именно **с stencil-проходом**:

### 3.1 Текстуры и пулы (MUST)

Добавить простой `TexturePool`, чтобы не аллоцировать каждый кадр (риски Part 1). 

Нужны ресурсы:

* `contentTex`: BGRA8Unorm, `.renderTarget | .shaderRead`
* `maskTex`: A8Unorm (alpha-only), `.shaderRead` (создаётся из CPU bitmap, можно кэшировать)
* `stencilTex`: `depth32Float_stencil8` (или `stencil8`, если гарантированно renderable на iOS target), `.renderTarget`

### 3.2 Три шага исполнения mask-scope (MUST)

Для каждого `BeginMaskAdd(path)…EndMask`:

**Step A — Render subtree content → `contentTex`**

* Создать offscreen render pass:

  * color = `contentTex`, clear to transparent `(0,0,0,0)`
* Выполнить команды subtree **в `contentTex`** тем же baseline-исполнителем (DrawImage+transforms+clip). Маски внутри — обрабатываются рекурсией тем же механизмом.

**Step B — Stencil write из `maskTex`**

* Создать render pass на **parent target** (или на отдельный “mask-pass target”, см. ниже) с stencil attachment:

  * colorAttachment: parent target, `load = .load` (НЕ трём уже нарисованное)
  * stencilAttachment: `stencilTex`, `load = .clear (0)`
* Нарисовать fullscreen quad, который **семплит `maskTex`**:

  * если `maskAlpha > 0` → фрагмент проходит
  * stencil op = `replace`, reference = `1`
  * color writes выключены (colorWriteMask = 0), чтобы этот проход не менял цвет

**Step C — Composite `contentTex` в parent target под stencil test**

* В том же encoder (после Step B) или новым encoder:

  * stencil test: `equal 1`
  * рисуем fullscreen quad:

    * `out = content * (maskAlpha * maskOpacity)` (умножить и RGB, и A)
    * blending premultiplied alpha как в PR7 (src*1 + dst*(1-srcA))

> Почему так: это соответствует Part 1 рекомендациям “contentTex + maskTex + compose”, но добавляет stencil для ограничения области и будущей совместимости.

---

## 4) CPU rasterization maskTex (Part 1 allowed)

Рендер “path → alpha bitmap” делаем CPU (CoreGraphics) — это **разрешено для Part 1**. 

### 4.1 Требования к `MaskRasterizer`

Создать:

* `Sources/TVECore/MetalRenderer/MaskRasterizer.swift`

API:

```swift
struct MaskRasterizer {
  static func rasterize(
    path: BezierPath,
    transformToViewportPx: Matrix2D,
    targetSizePx: (Int, Int),
    fillRule: FillRule = .nonZero,
    antialias: Bool = true
  ) -> [UInt8] // alpha bytes (row-major)
}
```

Где:

* `transformToViewportPx` = `M_animToViewport * currentTransformStack` **на момент BeginMaskAdd**
  (важно: чтобы маска двигалась/вращалась вместе со слоем и его родителями)
* Результат — `A8` bytes, дальше грузим в `MTLTexture` (`r8Unorm` / `a8Unorm` в зависимости от поддержки).

### 4.2 Кэширование maskTex (MUST)

В `MetalRenderer` держим:

* `maskTextureCache: [MaskCacheKey: MTLTexture]`

`MaskCacheKey` включает:

* `pathHash` (детерминированный хэш точек/сегментов)
* `widthPx`, `heightPx`
* `transformHash` (минимум: округлённые элементы матрицы до, например, 1e-4)

  > В Part 1 path статический, но transform может быть разный по кадрам; если transform keyframed — маска меняется. В PR8 допускаем кэш “на кадр” (по transformHash) либо без кэша для динамического transform; но **на референс-пакете маски должны работать**.

---

## 5) Shader/Pipeline изменения (MUST)

### 5.1 Новые pipeline state

В `MetalRendererResources` добавить:

1. `stencilWritePipeline`

* fragment: семплит `maskTex`, делает `discard_fragment()` если alpha==0
* `colorWriteMask = 0`

2. `maskCompositePipeline`

* fragment: семплит `contentTex` и `maskTex`
* `out = content * (maskAlpha * maskOpacity)`
* blending premultiplied alpha включён

### 5.2 DepthStencil states

Добавить 2 `MTLDepthStencilState`:

* `dsWriteStencil`:

  * stencilCompare = `.always`
  * passOp = `.replace`
  * referenceValue = 1 (ставится через `setStencilReferenceValue(1)`)
* `dsTestStencil`:

  * stencilCompare = `.equal`
  * passOp = `.keep`

---

## 6) Изменения в исполнителе команд (MetalRenderer+Execute)

Нужно реализовать разбор mask-scope:

### 6.1 Парсинг команд

Добавить функцию:

```swift
func extractScope(
  commands: [RenderCommand],
  from index: Int,
  begin: RenderCommand,
  endMatcher: (RenderCommand) -> Bool
) throws -> (scopeCommands: [RenderCommand], endIndex: Int)
```

* Должна поддерживать вложенность: depth++ при BeginMaskAdd, depth-- при EndMask.

### 6.2 Выполнение mask-scope

При встрече `BeginMaskAdd(path)`:

1. извлечь `subcommands` до `EndMask`
2. `contentTex = pool.acquireColor(targetSizePx)`
3. `execute(subcommands, into: contentTex)` (baseline executor)
4. `maskTex = maskCache.getOrCreate(path, transformToViewportPx, targetSizePx)`
5. `compositeMasked(contentTex, maskTex, opacity, into parentTarget with stencil)`
6. release `contentTex` обратно в pool

**Важно:** в родительском исполнении **НЕ исполнять subcommands напрямую**, иначе будет double-render.

---

## 7) Интеграция с текущим демо (PlayerViewController)

После PR8:

* если AnimIR уже генерирует `BeginMaskAdd/EndMask` для anim-1/4, то в демо должно быть **видно обрезку**.
* Добавить простой UI toggle “Masks ON/OFF” (опционально). Если OFF — можно продолжать no-op как fallback для сравнения (не обязателен).

---

## 8) Тесты (MUST) — без “визуального гадания”

Добавить новый файл:

* `Tests/TVECoreTests/MetalRendererMaskTests.swift`

Минимум **6 тестов**:

1. `testMask_clipsImage_outsideIsTransparent`

* contentTex: белая текстура 64×64
* mask path: круг/треугольник (не прямоугольник!)
* рендер в 128×128
* пиксель внутри маски alpha > 0
* пиксель снаружи alpha == 0

2. `testMask_opacityAffectsResult`

* maskOpacity = 0.5
* внутри маски ожидаем alpha примерно в 2 раза меньше (с допуском)

3. `testNestedMasks_intersection`

* 2 маски подряд (nested): итог должен быть меньше области первой
* пиксель в области 1, но вне 2 → alpha == 0

4. `testMaskDeterminism_sameInputsSamePixels`

* два рендера → bytes identical (как в PR7), но уже с маской

5. `testMaskScope_balancedStacks`

* убедиться, что после выполнения маски transform/clip стеки не “сломаны” (можно просто прогнать команды: push/pop + mask + дальше draw — и проверить что второй draw на месте)

6. `testMask_unbalanced_throws`

* BeginMaskAdd без EndMask → должен бросить `invalidCommandStack`

### 8.1 Интеграционный тест на референс-пакете (обязателен)

Добавить:

* `testAnim1_frame30_maskActuallyClips`
  Процедура:
* загрузить `anim-1.json` из Resources референс пакета
* собрать AnimIR
* `commands = animIR.renderCommands(frameIndex: 30)`
* отрендерить offscreen
* найти в `commands` первый `BeginMaskAdd(path)` и вычислить bbox маски **в viewport pixels** (используя тот же `transformToViewportPx`, что и rasterizer)
* взять pointOutside = (bbox.maxX + 10, bbox.centerY) (clamp в bounds)
* ожидаем alpha в pointOutside == 0
  Это гарантирует “маска реально режет” без знания формы заранее.

---

## 9) Ошибки и репортинг (как в Part 1)

Если маску невозможно применить (например maskTex не создан/unsupported pixel format):

* бросать `MetalRendererError.maskFailed(...)` **или** добавить `RenderIssue` (warning/error) в `lastRenderIssues` — по тому же паттерну, что вы делали для parent errors.

Формат ошибок должен оставаться “code/message/path/severity” в духе Part 1. 

---

## 10) Definition of Done (чеклист приёмки PR8)

PR8 принимаю только если:

* ✅ Реализован pipeline “content offscreen + mask alpha + stencil composite” 
* ✅ Поддержан nesting масок
* ✅ Есть `TexturePool` для offscreen color и stencil (минимальный)
* ✅ Unit tests: все PR7 + новые mask tests зелёные
* ✅ Интеграционный тест: `anim-1` (и желательно `anim-4`) подтверждает clipping
* ✅ SwiftLint: 0 violations в затронутых файлах (как стандарт PR7)
* ✅ Детерминизм: одинаковый input → одинаковые bytes