# PR5 — Sampling transforms (ks) + visibility window + parenting + computed matrix/opacity (без Metal)

## 0) Цель PR5

Сделать так, чтобы `AnimIR.renderCommands(frameIndex:)` (из PR4) **перестал быть “плейсхолдером”** и начал:

1. правильно **отсекать неактивные слои** по `ip/op/st` (visibility),
2. **семплить** `ks`-треки (static + keyframes) для `p/s/r/o/a`,
3. вычислять **local transform matrix** по каноническому Lottie-порядку,
4. вычислять **world transform** с учётом `parent`,
5. в командах RenderGraph выдавать:

   * `PushTransform(computedWorldMatrix)`
   * `DrawImage(assetId, opacity: computedOpacity)`
6. обеспечить **детерминизм**: одинаковый вход + одинаковый `frameIndex` → идентичные команды.

> В PR5 **не делаем Metal**, не делаем masks/mattes рендер, не делаем “корректное наследование через nested precomp” (это PR6), но **закладываем корректную временную модель и вычисление матриц/opacity**.

---

## 1) Scope / Non-scope

### Входит (обязательно)

* `AnimTrack.sample(frame:)` для `Double` и `Vec2D` (linear interpolation).
* Visibility: слой активен только если попадает в окно `[ip, op)`; учесть `st` в контексте precomp playback.
* Parenting: `world = parentWorld * local`.
* Матрица Lottie: `T(position) * R(rotation) * S(scale) * T(-anchor)` (см. раздел 4).
* Opacity: `o` 0..100 → 0..1.
* Локальный `frameIndex` для animRef: clamp политика Part 1 (см. раздел 2.2).
* Unit tests: на семплинг, visibility, parenting, матрицы, и конкретные ожидания Test Profile по кадрам 0/15/30/…/120.

### Не входит (строго)

* Правильное применение transforms родителя precomp к детям + “rootParentTransform не забывать” — это PR6. 
* Реальный рендер, клип, masks/mattes offscreen — PR7–PR9.
* Scene-level (block.rect/input.rect mapping) — позже, политика уже зафиксирована, но применять будем в SceneRenderer.

---

## 2) Временная модель (каноническая политика PR5)

### 2.1 FrameIndex источник

`frameIndex` — это **scene frame** (`0…scene.canvas.durationFrames-1`).

### 2.2 LocalFrameIndex для animRef (MUST)

На уровне `AnimIR` (для каждого animRef) вводим функцию:

```swift
public func localFrameIndex(sceneFrameIndex: Int, policy: DurationPolicy) -> Int
```

**Политика Part 1 (MUST):**

* `local = clamp(sceneFrameIndex, 0…(Int(anim.op) - 1))`.

> Вариантные параметры `ifAnimationShorter/ifAnimationLonger/loop` в spec существуют, но PR5 **не обязан** реализовывать весь policy engine. Минимум PR5 — clamping как выше, чтобы семплинг не выходил за `op`.

### 2.3 Visibility window (MUST)

Слой **рисуется**, если:

* `frame ∈ [ip, op)` (где `frame` — тот, по которому этот слой живёт в текущей композиции).

**Важно про `st`:**

* Для обычных слоёв (image/null/shape) — visibility проверяем по `frame` напрямую.
* Для precomp слоя (`ty=0`) — visibility так же по `frame ∈ [ip, op)`, **но** при входе внутрь дочерней композиции нужно передать **childFrame = frame - st** (это и есть “учёт st” для проигрывания precomp).

> На референсе `anim-2` видно `ip=30, op=330, st=30` у precomp слоя — это кейс, который должен корректно отрабатываться. 

---

## 3) Семплинг keyframes (AnimTrack) — точный контракт

### 3.1 Поддерживаемые треки

Только то, что Part 1 требует:

* position `p` (Vec2D)
* scale `s` (Vec2D, проценты)
* rotation `r` (Double, градусы)
* opacity `o` (Double, 0..100)
* anchor `a` (Vec2D)

### 3.2 Интерполяция (MUST)

PR5 использует **линейную интерполяцию** для всех треков.
(Не реализуем bezier easing/hold tangents в PR5 — это отдельное расширение. Но код должен быть расширяемым.)

Правила семплинга `AnimTrack<T>.sample(frame: Double)`:

* Если `.static(v)` → всегда `v`.
* Если `.keyframed([k0..kn])`:

  * если `frame <= k0.time` → `k0.value`
  * если `frame >= kn.time` → `kn.value`
  * иначе найти сегмент `[ki, ki+1]`, где `ki.time <= frame < ki+1.time`

    * `t = (frame - ki.time) / (ki+1.time - ki.time)`
    * `lerp(ki.value, ki+1.value, t)`

Edge cases (MUST):

* если `ki.time == ki+1.time` → брать `ki+1.value` (избежать деления на 0)
* если массив keyframes пуст → treat as error/unsupported (но это не должно происходить на валидном subset)

Performance (рекомендовано, но не over-engineer):

* в PR5 допускается линейный поиск сегмента; если хочется — бинарный (но не обязательно).

### 3.3 Нормализации значений (MUST)

* `opacity`: clamp в `0…100`, затем `/ 100.0` → `0…1`.
* `scale`: Lottie scale в процентах, т.е. `[100,100]` = 1.0.
  `sx = s.x / 100`, `sy = s.y / 100`.

---

## 4) Вычисление матрицы transform (каноническая формула)

Для каждого слоя вычисляем:

### 4.1 Local matrix (MUST)

Порядок Lottie (фиксируем как стандарт Part 1):
**Local = T(position) * R(rotation) * S(scale) * T(-anchor)**

Где:

* `position = sample(p)`
* `rotation = sample(r)` (в градусах; `Matrix2D.rotateDegrees`)
* `scale = sample(s)/100`
* `anchor = sample(a)`

> Это эквивалент “apply anchor → scale → rotation → position” из плана.

### 4.2 Parenting (MUST)

Если `layer.parent != nil`:

* `world = parentWorld * local`
  Иначе:
* `world = local`

**Требование:** parent должен быть в той же композиции (как в Lottie). Если parent id не найден:

* это `UnsupportedFeature(code: "PARENT_NOT_FOUND", context: "animRef/layerId")` или throw compiler error (выбрать один стиль и закрепить). В Part 1 лучше `UnsupportedFeature`, потому что без parent невозможно корректно получить кадр.

**Циклы parent chain (MUST)**

* если обнаружен цикл — `UnsupportedFeature(code:"PARENT_CYCLE")`.

---

## 5) Как меняем RenderGraph генерацию (AnimIR.renderCommands)

### 5.1 Новая сигнатура

Оставляем как есть:

```swift
public func renderCommands(frameIndex: Int) -> [RenderCommand]
```

но теперь:

* внутри вычисляем `frame = Double(localFrameIndex(sceneFrameIndex: frameIndex))` по clamping policy.

### 5.2 Генерация по композиции

При проходе слоёв в composition:

1. Проверить visibility: `frameInComp ∈ [ip, op)` → иначе слой пропускаем целиком.
2. Вычислить `worldMatrix` (через parent chain) по этому же `frameInComp`.
3. `PushTransform(worldMatrix)`
4. Если image layer → `DrawImage(assetId, opacity)` где opacity = sampledOpacity0to1.
5. Если precomp layer → рекурсивно вызвать генерацию команд для `refId` с:

   * `childFrame = frameInComp - st` (Double)
   * (visibility precomp children их собственная `[ip,op)` уже внутри той композиции)
6. `PopTransform`

> В PR5 матрица precomp-родителя применяется к subtree через PushTransform перед рекурсией — это уже даст базовую корректность; но “все нюансы наследования masks/mattes на разных уровнях” оставляем PR6. 

### 5.3 Opacity propagation (MUST)

**Пока** (PR5) не делаем “умножение opacity по цепочке” как отдельную фичу?
Фиксируем простое правило Part 1 (MUST):

* `effectiveOpacity = layerOpacity * parentOpacity` (если есть parent).
  Это критично для “fade-in” блоков из TP (anim-1) и для корректного поведения parented layer.

Технически:

* когда считаем worldMatrix, параллельно считаем `worldOpacity`.
* `DrawImage(..., opacity: worldOpacity)`.

---

## 6) Изменения в коде (конкретные задачи)

### 6.1 AnimIRTrack.swift

Добавить:

* `protocol Interpolatable` или просто overload:

  * `lerp(Double, Double, t)`
  * `lerp(Vec2D, Vec2D, t)`
* `AnimTrack.sample(frame: Double) -> T`

### 6.2 AnimIR.swift

* В `renderCommands(frameIndex:)` заменить placeholder:

  * `PushTransform(identity)` → computed `worldMatrix`
  * `DrawImage(opacity: 1)` → computed `worldOpacity`
* Ввести private helper:

  * `renderComposition(compId: CompID, frame: Double, parentWorld: Matrix2D, parentOpacity: Double, commands: inout [RenderCommand])`
* Helper для visibility:

  * `isVisible(layer, frameInComp)`

### 6.3 Matrix2D.swift

Убедиться, что есть:

* `static func translation(x:y:)`
* `static func scale(x:y:)`
* `static func rotationDegrees(_ deg: Double)`
* `func multiplied(by other: Matrix2D) -> Matrix2D` (с чётким порядком: `a*b` значит сначала b, потом a — закрепить и покрыть тестами!)

> Ошибка порядка матричного умножения = самый частый источник “почему всё в 0,0”. Тесты должны это зафиксировать.

---

## 7) Unit tests (MUST, минимальный набор)

### 7.1 AnimTrack sampling tests

* static double / static vec
* keyframed double (0→100) на frame=0/0.5/1.0
* keyframed vec2 (0,0→10,20)
* boundary clamp (before first / after last)

### 7.2 Visibility tests по Test Profile (обязательные)

По документу Test Profile:

* `anim-2`:

  * frame 0–29: **нет** `DrawImage` команд для consumer слоёв (ip=30)
  * frame 30: появляются команды
* `anim-3`:

  * frame 0–59: нет draw
  * frame 60+: есть draw
* `anim-4`:

  * frame 0–89: нет draw
  * frame 90+: есть draw

(Можно проверять по количеству `DrawImage` или по наличию `BeginGroup("Layer:...")` + Draw.)

### 7.3 Opacity tests по TP (обязательные)

TP4.1: anim-1 fade-in:

* frame 0: opacity ≈ 0 (или очень близко, если ключи так заданы)
* frame 15: 0 < opacity < 1
* frame 30+: opacity ≈ 1

Проверка: найти первую `DrawImage` в командах и смотреть `opacity`.

### 7.4 Parenting test (обязательный, можно synthetic)

Если не хотите зависеть от конкретного “slide-in” в anim-2:

* собрать маленький synthetic AnimIR (2 слоя: parent + child, parent position animated, child static)
* на кадре `t` проверить, что worldMatrix child = parentWorld * childLocal

### 7.5 Precomp st mapping test (обязательный, synthetic)

* precomp layer ip=30 op=60 st=30
* child внутри precomp имеет анимированный position, начиная с frame=0
* проверить: на scene frame 30 → child sampled как frame 0, на scene frame 40 → child sampled как frame 10

Это прямой тест “учёта st” из плана.

---

## 8) Интеграция в App (минимально)

В `PlayerViewController` добавить debug лог (без UI):

* для кадров из TP3 (0,15,30,45,60,75,90,105,120)
* вывести по каждому animRef:

  * количество `DrawImage`
  * opacity первого `DrawImage`
  * (опционально) worldMatrix первого слоя

Цель: быстрая ручная sanity-проверка до Metal PR7.

---

## 9) Definition of Done PR5 (жёстко)

PR5 принят, если:

1. `AnimTrack.sample()` работает для Double/Vec2D и покрыт тестами.
2. Visibility реализована: слой активен только в `[ip, op)`; precomp рекурсия использует `childFrame = frame - st`.
3. Матрица local соответствует `T(p) * R(r) * S(s) * T(-a)` и parenting `world = parentWorld * local`.
4. Opacity нормализована 0..1 и наследуется по parent chain.
5. На reference package команды начинают соответствовать TP ожиданиям по visibility/opacity:

   * anim-1: fade-in (0/15/30)
   * anim-2: появляется с 30
   * anim-3: появляется с 60
   * anim-4: появляется с 90
6. Все тесты зелёные, CI зелёный.