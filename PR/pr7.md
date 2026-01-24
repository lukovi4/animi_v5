Ниже — **очень чёткое и детальное ТЗ для PR7**: *Metal baseline executor для RenderCommand без masks/mattes*.

Это ровно тот шаг из плана: **“MetalRenderer baseline: DrawImage + transforms + clipRect”**  — то есть мы строим минимальный, но **детерминированный** исполнитель RenderGraph, который уже умеет рисовать текстурный quad, применять матрицы и scissor. Маски/матты пока **не рендерим** (они пойдут PR8/PR9). 

---

# PR7 — Metal baseline executor (RenderCommand → Metal) без masks/mattes

## 0) Цель PR7 (Definition of Goal)

Сделать **MetalRenderer baseline**, который:

1. принимает список `RenderCommand` от `AnimIR.renderCommands(frameIndex:)` 
2. исполняет **только**:

* `BeginGroup/EndGroup` (как no-op, но проверяем баланс)
* `PushTransform/PopTransform` (transform stack)
* `PushClipRect/PopClipRect` (scissor stack)
* `DrawImage(assetId, opacity)` (один drawcall textured quad + premultiplied alpha) 

3. **игнорирует** команды masks/mattes (`BeginMaskAdd/EndMask`, `BeginMatte*/EndMatte`) — *без падения, без крэша*, но **обязателен баланс** begin/end (иначе это баг генерации команд).

**DoD PR7:** “рисует простой кадр без masks/mattes” и “одинаковый frameIndex → одинаковый пиксельный результат” 

---

## 1) Неграницы PR7 (Non-goals)

В PR7 **НЕ делаем**:

* реальную поддержку masks/mattes (это PR8/PR9) 
* shape rasterization
* Scene-level композицию 4 блоков 2×2 (это будет позже в ScenePlayer/TP harness)
* оптимизации: texture pool, batching, instancing, atlases (не раньше PR8+)

---

## 2) Новые сущности и файлы (ожидаемая структура)

### 2.1 TVECore / MetalRenderer

Создать папку:

* `Sources/TVECore/MetalRenderer/`

Файлы:

1. `MetalRenderer.swift`
2. `MetalRendererResources.swift` (pipeline state, buffers, samplers)
3. `MetalRenderer+Execute.swift` (исполнение команд)
4. `Shaders/QuadShaders.metal` (vertex+fragment)

> Важно: без UIKit. Разрешено `import Metal`, `MetalKit`, `simd`.

### 2.2 Протоколы для тестируемости

Чтобы unit-тесты не зависели от реального ScenePackage:

* `protocol TextureProvider { func texture(for assetId: String) -> MTLTexture? }`
* `final class ScenePackageTextureProvider: TextureProvider`

  * грузит png из `imagesRootURL` через `MTKTextureLoader`
  * кэширует по assetId

---

## 3) Публичный API (чтобы не было вопросов)

### 3.1 MetalRenderer (основной)

```swift
public final class MetalRenderer {
  public struct Options: Sendable {
    public var clearColorRGBA: (Double, Double, Double, Double) // default (0,0,0,0)
    public var enableWarningsForUnsupportedCommands: Bool       // default true
  }

  public init(device: MTLDevice, colorPixelFormat: MTLPixelFormat, options: Options = .init())

  /// Draws into an MTKView currentDrawable (on-screen)
  public func draw(
    commands: [RenderCommand],
    target: RenderTarget,
    textureProvider: TextureProvider
  ) throws
}
```

### 3.2 RenderTarget (унификация on-screen / offscreen)

```swift
public struct RenderTarget {
  public let texture: MTLTexture
  public let sizePx: (width: Int, height: Int)     // from texture
  public let drawableScale: Double                 // for MTKView, usually UIScreen scale; tests can set 1
  public let animSize: (width: Double, height: Double) // lottie.w/h for mapping
}
```

> `animSize` нужно для “contain policy” (см. Geometry mapping). 

### 3.3 Errors (минимум)

Добавить `MetalRendererError`:

* `noTextureForAsset(assetId)`
* `failedToCreateCommandBuffer`
* `failedToCreatePipeline`
* `invalidCommandStack(reason)`

---

## 4) Геометрия и математика (самое важно)

### 4.1 Координатные пространства

* `AnimIR` отдаёт матрицы в **координатах анимации** (`0..anim.w`, `0..anim.h`) 
* Metal рисует в NDC `(-1..1)`.

Значит для каждого `DrawImage` нужна итоговая матрица:
**M_ndc = M_viewportToNDC * M_animToViewport * M_currentStack**

Где:

* `M_currentStack` — результат transform-stack из `PushTransform/PopTransform` (в anim space)
* `M_animToViewport` — contain + center, чтобы anim вписался в target (uniform scale) 
* `M_viewportToNDC` — перевод пикселей target → NDC

### 4.2 Политика mapping (MUST, Part 1)

**Contain + center**: если `anim.w/h` != `target.w/h`, масштабируем uniform так, чтобы **вписать без обрезки** и центрировать. 

> В PR7 мы не учитываем `input.rect` и сцену — это появится позже. Здесь baseline: *один anim → один target*.

### 4.3 Реализация mapping

Использовать уже существующий `GeometryMapping` / `Matrix2D` (из PR4).
Если там нет готового `animToViewportContain(...)` — добавить в `GeometryMapping.swift`, но **минимально**.

---

## 5) Исполнение RenderCommand (контракт поведения)

### 5.1 Transform stack (MUST)

* Инициализация: `transformStack = [.identity]`
* На `PushTransform(m)`:

  * `current = current.concatenating(m)` (ваш контракт: a.concatenating(b) = a*b)
  * push current
* На `PopTransform`:

  * pop (нельзя уходить ниже 1; иначе error)

> Это ровно то, что вы уже симулировали в PR6 тестах — используем тот же подход как “истина”.

### 5.2 ClipRect stack (MUST)

* Инициализация: `clipStack = [fullTargetRectPx]`
* `PushClipRect(rect)`:

  * rect приходит в **координатах target** (как и написано в плане PR7: scissor rect “в координатах target”) 
  * интерсектим с текущим clip
  * ставим `encoder.setScissorRect(...)`
* `PopClipRect`:

  * восстанавливаем предыдущий scissor

> Если сейчас ваши RenderCommands генерируют clipRect в anim-space — тогда в PR7 добавить helper `clipRectAnimToTarget(rectAnim)` и вызывать его на стороне, где генерируете commands для тестов/демо. Но **сам MetalRenderer** ожидает clipRect уже в target-space (чёткий контракт PR7). 

### 5.3 Group / Mask / Matte команды

* `BeginGroup/EndGroup`: no-op, но вести счетчик баланса (и при ошибке — `invalidCommandStack`)
* `BeginMaskAdd/EndMask`: **no-op** (PR8)
* `BeginMatte*/EndMatte`: **no-op** (PR9)

Если `Options.enableWarningsForUnsupportedCommands == true`:

* за кадр можно один раз добавить warning (print/log) “Masks/mattes are not rendered in PR7 baseline”.
  Но **не спамить** на каждый слой.

---

## 6) DrawImage (обязательная точность)

### 6.1 Какой quad рисуем

Для `DrawImage(assetId, opacity)` рисуем quad в **локальных координатах слоя**:

* `(0,0) .. (assetWidth, assetHeight)`
  (ширина/высота берётся из `AnimIR` asset metadata, который пришёл из Lottie assets `w/h`). В `anim-1.json` это явно есть. 

Если в IR asset size отсутствует (не должно), fallback = `animSize`.

### 6.2 Blending (MUST)

Pipeline должен использовать **premultiplied alpha blending** (как в плане PR7). 
Стандартная формула:

* rgb: `src * 1 + dst * (1 - src.a)`
* a:   `src.a * 1 + dst.a * (1 - src.a)`

Texture loader должен загружать PNG как premultiplied (MTKTextureLoader обычно так и делает для sRGB/normal; если нужно — явно задать опции).

### 6.3 Uniforms

В shader передаём:

* `float4x4 mvp;`
* `float opacity;` (0..1)

Fragment:

* `outColor = texSample * opacity;` (opacity умножает и rgb, и a — так ожидается по IR)

---

## 7) Интеграция в AnimiApp (демо-экран)

В `PlayerViewController` (или отдельном `MetalBaselinePlayerVC`):

* загрузить текущий test package
* взять любой один anim (например `anim-1.json`)
* собрать `AnimIR`
* на `draw(in:)`:

  * `commands = animIR.renderCommands(frameIndex: currentFrame)`
  * `renderer.draw(commands, target: RenderTarget(drawable.texture,... animSize...), textureProvider: ...)`

Минимальный UI:

* slider `frameIndex` (0..durationFrames-1)
* кнопки Play/Pause (можно минимально)
* label текущего frameIndex

> Это соответствует траектории к PR10/PR11, но в PR7 достаточно “ручного” просмотра кадра.

---

## 8) Unit / Integration tests (обязательные)

Metal сложно тестировать на CI, поэтому делаем **offscreen tests** без MTKView.

### 8.1 Offscreen executor path (MUST)

Добавить публичный метод (или internal для тестов):

```swift
public func drawOffscreen(
  commands: [RenderCommand],
  device: MTLDevice,
  sizePx: (Int, Int),
  animSize: (Double, Double),
  textureProvider: TextureProvider
) throws -> MTLTexture
```

### 8.2 Тесты (минимум 6)

Файл: `Tests/TVECoreTests/MetalRendererBaselineTests.swift`

Тесты должны **не сравнивать с PNG**, но проверять “не чёрный кадр / детерминизм”:

1. `testDrawImage_writesNonZeroPixels`

* создать 1×1 белую texture in-memory (без файлов)
* commands: push identity, draw image opacity 1
* отрендерить в 32×32
* считать пиксель [16,16] → ожидаем alpha > 0

2. `testOpacityZero_drawsNothing`

* то же, но opacity 0
* ожидаем alpha == 0

3. `testTransformTranslation_movesQuad`

* draw 1×1 texture
* pushTransform translate (например x=10)
* проверить, что пиксель в одной точке изменился, а в другой — нет (простая проверка)

4. `testClipRect_scissorsDrawing`

* clip rect маленький (например 0..8)
* draw
* пиксель внутри clip имеет alpha > 0, снаружи == 0

5. `testDeterminism_sameInputsSamePixels`

* два рендера подряд в чистую offscreen texture
* readback bytes → identical

6. `testStacksBalanced_invalidPopThrows`

* commands: PopTransform в начале → должен бросить `invalidCommandStack`

> Если `MTLCreateSystemDefaultDevice()` == nil (редко), тесты могут быть skipped с явной причиной.

---

## 9) DoD PR7 (что я проверяю на ревью)

PR7 принимаю, если:

1. **Рисует textured quad** в `MTKView` (демо живое). 
2. **Transform stack работает**: rotation/scale/anchor из IR визуально меняют картинку (хотя бы на nested_precomp тесте).
3. **PushClipRect = scissor** в координатах target (реально режет draw). 
4. **Masks/mattes команды не ломают кадр** (no-op) и баланс begin/end не нарушен.
5. **Determinism**: одинаковый input+frameIndex → одинаковый offscreen buffer (unit test). 
6. Все тесты + SwiftLint зелёные.

---

## 10) Порядок реализации (чтобы не расползлось)

1. Shaders + pipeline + sampler + vertex buffer
2. Transform stack + MVP сборка + DrawImage
3. ClipRect scissor stack
4. TextureProvider + MTKTextureLoader cache
5. Offscreen render path + readback helper (только для тестов)
6. Unit tests (6 шт)
7. Demo VC integration

---

Если хочешь, я могу в следующем сообщении дать **конкретные значения scissor и матриц для тестов** (цифры), чтобы программист вообще не гадал, куда “сдвинулось” и почему.
