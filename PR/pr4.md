## PR4 — Цель и границы

### Цель PR4

1. Ввести **AnimIR v1** (нативное IR-представление Lottie subset), которое хранит:

* composition tree (root + precomp refs),
* layers с timing (ip/op/st),
* transform pipeline (parent chain),
* mask/matte metadata. 

2. Ввести **RenderGraph контракт**: строгий список команд и правила генерации команд из AnimIR.

3. Реализовать **API**:

* `renderCommands(frameIndex) -> [RenderCommand]` (детерминированно).

> В PR4 **нет реального рисования Metal**. Мы только создаём структуры и генерируем командный список.

---

## Non-goals (строго НЕ делаем в PR4)

Эти штуки будут в следующих PR и **в PR4 их не реализуем**:

* **Сэмплинг transforms по кадру, visibility window, parenting math** → это PR5 
* Полная корректная логика nested precomp с inheritance (rootParentTransform и т.п.) → PR6 
* MetalRenderer baseline → PR7+ 

В PR4 мы **закладываем контракт и данные**, чтобы PR5/6/7 могли “подключить” вычисления и рендер без рефакторинга API.

---


## Директории и файлы (обязательная структура)

### TVECore/Sources/TVECore/

Добавить:

```
AnimIR/
  AnimIR.swift
  AnimIRTypes.swift
  AnimIRTrack.swift
  AnimIRPath.swift
  AnimIRCompiler.swift

RenderGraph/
  RenderCommand.swift
  RenderGraph.swift  (опционально)
  RenderCommand+Debug.swift (опционально)

Math/
  Matrix2D.swift
  GeometryMapping.swift
```

### TVECore/Tests/TVECoreTests/

Добавить:

```
AnimIRCompilerTests.swift
RenderGraphContractTests.swift
GeometryMappingTests.swift
```

---

## AnimIR v1 — строгая модель данных

### 1) Идентификаторы (стабильные, детерминированные)

* `typealias LayerID = Int` (из Lottie `ind` если есть; если нет — детерминированно назначить по порядку в comp.layers)
* `typealias CompID = String` (для root можно `"__root__"`, для precomp = `asset.id`)

> Важно: идентификаторы должны быть одинаковыми при одинаковом входном JSON (determinism). 

---

### 2) AnimIR root

```swift
public struct AnimIR: Sendable {
  public let meta: Meta
  public let rootComp: CompID
  public let comps: [CompID: Composition]
  public let assets: AssetIndexIR
  public let binding: BindingInfo

  public func renderCommands(frameIndex: Int) -> [RenderCommand]
}
```

#### Meta (обязательные поля)

* `w, h, fps, ip, op` (из Lottie root) — нужен для последующих PR.
* `sourceAnimRef: String` (для дебага path/ошибок)

#### assets (обязательные поля)

* `AssetIndexIR`: `assetId -> relativePath` (используем то, что уже есть в PR3 AssetIndex; но в AnimIR фиксируем “IR-шный” формат, чтобы не зависеть от Lottie types).

#### binding

* `BindingInfo(bindingKey: String, boundLayerId: LayerID, boundAssetId: String)`

  * Это тот слой `ty=2` с `nm==bindingKey`, уже проверенный валидатором PR3.

---

### 3) Composition

```swift
public struct Composition: Sendable {
  public let id: CompID
  public let size: SizeD // w/h
  public let layers: [Layer] // порядок как в Lottie JSON
}
```

**Порядок слоёв**:

* В PR4 фиксируем правило: `layers` идут **в том порядке, в котором они в JSON**, и RenderGraph проходит их **по возрастанию индекса (0…n-1)**. Это соответствует тому, как lottie-web в ряде мест итерирует слои `for(i=0; i<len; i+=1)` (мы фиксируем это как норму движка). ([skia.googlesource.com][1])
* Если позже обнаружится, что для “1-в-1” нужно reverse — это будет отдельная осознанная правка политики (но сейчас MUST выбрать одну). (И да: тесты PR4 должны “застолбить” выбранное поведение.)

---

### 4) Layer (поднабор Part 1)

```swift
public struct Layer: Sendable {
  public let id: LayerID
  public let name: String
  public let type: LayerType // precomp, image, null, shapeMatte
  public let timing: LayerTiming // ip/op/st
  public let parent: LayerID? // chain
  public let transform: TransformTrack // пока только хранение треков
  public let masks: [Mask] // masksProperties subset
  public let matte: MatteInfo? // связь consumer->source
  public let content: LayerContent // image/precompRef/shapes/none
}
```

#### LayerType

* `.precomp` (ty=0)
* `.image` (ty=2)
* `.null` (ty=3)
* `.shapeMatte` (ty=4) — только как источник matte (Part 1)

#### LayerTiming

* `ip: Double`, `op: Double`, `st: Double` (как в Lottie) — PR5 будет интерпретировать. 
  В PR4 просто храним.

---

### 5) TransformTrack (хранение, без вычисления)

```swift
public struct TransformTrack: Sendable {
  public let p:contentReference[oaicite:15]{index=15}c2D>
  public let scale: AnimTrack<Vec2D>
  public let rotation: AnimTrack<Double>
  public let opacity: AnimTrack<Double> // 0..100 (как в Lottie)
  public let anchor: AnimTrack<Vec2D>
}
```

#### AnimTrack<T>

* `.static(value)`
* `.keyframed([Keyframe<T>])`

PR4: **только парсинг/перекладка** из `LottieTransform (ks)` → `TransformTrack`.
PR5: расчёт значения на `frameIndex` + матрица.

---

### 6) Masks / Mattes — метаданные + форма, без рендера

#### Mask

Поддерживаемый subset (Part 1):

* `mode == "a"` (add)
* `inv == false`
* `o` opacity статический
* `pt` path **статический** (в PR3 валидатор уже запрещает animated path) 

AnimIR:

```swift
public struct Mask: Sendable {
  public let mode: MaskMode // только .add в PR4/Part1
  public let inverted: Bool
  public l:contentReference[oaicite:17]{index=17} 0..100
  public let path: AnimPath // в PR4 ожидаем static
}
```

#### AnimPath

В PR4 достаточно:

* `case staticBezier(BezierPath)`
* (опционально заложить `case keyframedBezier(...)`, но PR3 уже валидирует, что path animation unsupported, так что PR4 можно не реализовывать fully)

`BezierPath` должен быть “рендер-агностик”:

* vertices + inTangents + outTangents + closed

#### MatteInfo (важно)

Нужно зафиксировать связывание consumer ↔ matteSource:

* matte source layer: `td == 1`
* consumer layer: `tt == 1` (alpha) или `tt == 2` (inverted)

AnimIR хранит у consumer:

```swift
public struct MatteInfo: Sendable {
  public let mode: MatteMode // alpha / alphaInverted
  public let sourceLayerId: LayerID
}
```

А у matte source **нет** `MatteInfo` — он просто слой, помеченный `isMatteSource = true` (или выводится из `content`/`flags`).

> В PR4 мы обязаны правильно **построить пары matte**, потому что RenderGraph команды требуют `BeginMatteAlpha(...)` с ссылкой на source.

---

## AnimIRCompiler (PR4) — контракт компиляции

### API

```swift
public final class AnimIRCompiler {
  public func compile(
    lottie: LottieJSON,
    animRef: String,
    bindingKey: String,
    assetIndex: AssetIndex
  ) throws -> AnimIR
}
```

### Правила компиляции (обязательные)

1. Построить `comps`:

* root comp = `"__root__"` (layers из `lottie.layers`)
* precomp comps из `lottie.assets[].layers` (id = asset.id) 

2. Каждый layer преобразовать в AnimIR Layer:

* type по `ty`
* timing ip/op/st — переносим
* parent — переносим
* transform ks — переносим каerties → `[Mask]`
* shapes для ty=4 → `LayerContent.shapes(...)` (без рендера)

3. Matte pairing:

* внутри каждого comp пройти layers в порядке (см. выбранную политику)
* если layer имеет `td==1` → пометить как matteSource
* если следующий “потребитель” имеет `tt==1|2` → у consumer поставить `MatteInfo(sourceLayerId: matteSource.id, mode: ...)`
* matteSource **не должен** превращаться в Draw-команду обычного слоя в RenderGraph (он используется только как источник матте). Это прям риск из “Matte ordering” 

4. Binding info:

* найти replaceable image-layer `nm == bindingKey` (валидатор PR3 уже это гарантировал, но компилятор обязан либо:

  * довеимать `boundLayerId` из результата валидатора, **или**
  * повторно найти (cheap) и assert’нуть, иначе throw).
* зафиксировать `binding.boundLayerId` и `binding.boundAssetId`.

---

## RenderGraph контракт (PR4)

### RenderCommand enum (MUST список)

Ровно эти команды как публичный API (можно расширять позже, но PR4 обязан завести этот минимальный набор):

* `BeginGroup(name: String)`
* `EndGroup`
* `PushTransform(Matrix2D)`
* `PopTransform`
* `PushClipRect(RectD)`
* `PopClipRect`
* `DrawImage(assetId: String, opacity: Double)`
* `BeginMaskAdd(path: BezierPath)` / `EndMask`
* `BeginMatteAlpha(sourceLayerId: LayerID)` / `BeginMatteAlphaInverted(sourceLayerId: LayerID)` / `EndMatte`

> В PR4 команды — это “байткод контракта”, который потом исполнит MetalRenderer.

### Правила генерации команд из AnimIR (PR4)

#### Общая структура

`AnimIR.renderCommands(frameIndex)` возвращает команды **в координатах самой анимации (anim local space)**.
Scene-level трансформы/клип блока (block.rect, containerClip) в PR4 **не добавляем сюда** — это будет в SceneRenderer/Player на следующем шаге (PR7). Но PR4 обязан дать helper для geometry mapping (см. ниже). 

#### Алгоритм прохода

Для root comp:

1. `BeginGroup("AnimIR:\(animRef)")`
2. рекурсивный проход layers root comp:

   * `BeginGroup("Layer:\​:contentReference[oaicite:27]{index=27}d)")`
   * (PR4) `PushTransform(identity)` **или** `PushTransform(layer.localPlaceholderTransform)` (но это placeholder). Главное: стек должен быть в командах, чтобы PR5 просто заменил матрицу вычислением.
   * Masks:

     * если `layer.masks` не пусто → для каждого mask:

       * `BeginMaskAdd(path)`
     * затем content
     * `EndMask` в обратном порядке (LIFO)
   * Mattes:

     * если `layer.matte != nil` → перед отрисовкой content:

       * `BeginMatteAlpha(sourceLayerId)` или `BeginMatteAlphaInverted(sourceLayerId)`
     * после content → `EndMatte`
   * content:

     * image layer → `DrawImage(assetId, opacityPlaceholder)`
     * precomp layer → **в PR4 делаем рекурсивный проход** в precomp composition (`refId`) как subtree (да, PR6 потом поправит inheritance/parent transforms; но PR4 должен уметь представить дерево команд и не “терять” структуру). Цель — контракт и дерево.
     * null layer → не рисуем, но группа/трансформ остаются (для будущего parenting)
     * shapeMatte layer → **не рисуем как обычный слой** (если она участвует как matte source), но она должна быть доступна по `sourceLayerId` для дальнейшего исполнения matte в PR9. В PR4 достаточно: не эмитить DrawImage, но группа может быть.
   * `PopTransform`
   * `EndGroup`
3. `EndGroup`

#### Opacity в PR4

* Пока PR5 не считает keyframes, **opacity можно ставить 1.0** (placeholder).
* Но структуру нужно заложить так, чтобы PR5 легко подменил на computed opacity из track. 

---

## GeometryMapping helper (обязателен в PR4)

Нужно “застолбить” единую политику mapping anim → input.rect: **contain + центрирование**.

### API

```swift
public enum GeometryMapping {
  /// Returns matrix that maps anim local space (0..w, 0..h) into inputRect local space
  public static func animToInputContain(
    animSize: SizeD,
    inputRect: RectD
  ) -> Matrix2D
}
```

### Математика (MUST)

* `scale = min(input.w/anim.w, input.h/anim.h)`
* `scaledW = anim.w * scale`, `scaledH = anim.h * scale`
* `dx = input.x + (input.w - scaledW)/2`
* `dy = input.y + (input.h - scaledH)/2`
* matrix = Translate(dx,dy) * Scale(scale,scale)

В PR3 валидатор уже выдаёт warning при mismatch размеров, но рендер-политика всё равно MUST быть одна.

---

## Ошибки / UnsupportedFeature в PR4

В PR4 компилятор **может** бросать `UnsupportedFeature` (как концепт из плана) , но строго:

* без stack trace наружу,
* с человеко-читаемым message,
* с context/path (например `animRef/layerName`). ример)

```swift
public struct UnsupportedFeature: Error, Sendable {
  public let code: String
  public let message: String
  public let path: String
}
```

**Важно:** если PR3 AnimValidator уже гарантирует subset, то PR4 компилятор в нормальном потоке на reference package **не должен падать**.

---

## Тесты PR4 (обязательные)

### 1) GeometryMappingTests

Покрыть минимум 4 кейса:

* exact match (anim==input) → scale=1, translate=input.x/y
* input wider (200x100 vs 100x100) → центрирование по X
* input taller → центрирование по Y
* non-zero input.x/y

Ассерты на матрицу (с небольшим epsilon).

### 2) AnimIRCompilerTests

* Compile `anim-1..4.json` (из TestAssets example_4blocks) → **без ошибок**. 
* Проверить:

  * `AnimIR.meta.fps == 30` и т.п.
  * `AnimIR.comps` содержит root + нужные assets comps
  * `binding.boundLayerId` найден, `b

### 3) RenderGraphContractTests

На одном-двух anim (минимум anim-1 и anim-2):

* `renderCommands(0)` возвращает:

  * корректно сбалансированные пары `BeginGroup/EndGroup`, `Push/PopTransform`, `Begin/EndMask`, `Begin/EndMatte`
* anim-1 должен содержать `BeginMaskAdd` перед `DrawImage` (потому что “mask add на replaceable image layer” в TP)
* anim-2 должен содержать `BeginMatteAlpha(...) ... EndMatte` (потому что `tt=1`)

> Эти тесты фиксируют “контракт команд”, чтобы PR7+ не ломал структуру.

---

## Интеграция в AnimiApp (минимально, без рендера)

В `PlayerViewController` (или рядом) сделать debug путь:

* загрузили ScenePackage
* прошёл SceneValidator + AnimValidator
* скомпилили каждый animRef → AnimIR
* вызвали `renderCommands(frameIndex: 0)` и залогировали:

  * количество команд,
  * наличие mask/matte команд по animRef (для ручной sanity check)

---

## Definition of Done PR4 (без компромиссов)

PR4 считается принятым, если:

1. В репо есть **AnimIR v1 структуры** (composition tree, layers timing, parent chain, mask/matte metadata) 
2. Есть **RenderGraph контракт** с минимальным набором команд (ровно как в доке) 
3. Есть публичный API:
   `AnimIR.r:contentReference[oaicite:41]{index=41}ex: Int) -> [RenderCommand]`
4. Есть `GeometryM:contentReference[oaicite:43]{index=43}tain(...)` с тестами, фиксирующими contain+center политику
5. Все тесты зелёные в CI.

---

## Что я буду “жёстко” проверять на ревью PR4

* Детерминизм: одинаковый JSON + frameIndex → **одинаковый** командный список (включая порядок). 
* Matte ordering: matte source **не рендерится как обычный слой**, и consumer корректно получает `BeginMatte...` (без двойного прохода). rn5file8
* Нет “магии”: все правила (порядок слоёв, mapping policy) **явно зафиксированы** в коде и тестах. 
* Команды строго из списка MUST.