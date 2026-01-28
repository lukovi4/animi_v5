Ниже — **каноническое детальное ТЗ для PR-03: “Lottie decoding: Rectangle `rc`”**.
Оно основано на **реальном текущем коде** (`TVECore/Sources/TVECore/Lottie/LottieShape.swift`, `TVECore/Sources/TVECore/AnimValidator/AnimValidator+Shapes.swift`, `TVECore/Tests/TVECoreTests/ShapeItemDecodeTests.swift`) и на нашем релизном принципе **fail-fast / no silent ignore**.

---

# PR-03 — Lottie decoding: Rectangle (`ty:"rc"`)

## 0) Цель PR

Добавить **полноценное декодирование** ShapeItem типа Rectangle Path (`ty="rc"`) из Lottie JSON в модель `TVECore`, **без изменения рендера/компиляции**.

Важное: до PR-07 (path extraction) прямоугольник **не считается поддержанным для финального результата**, поэтому валидатор **обязан продолжать fail-fast**, чтобы не получить “тихий неправильный рендер”.

---

# 1) Scope PR-03

## 1.1 Что делаем

1. В `LottieShape.swift`:

   * добавить новую модель `LottieShapeRect`
   * добавить новый case в `ShapeItem`: `.rect(LottieShapeRect)`
   * добавить `case "rc":` в `ShapeItem.init(from:)`

2. В `AnimValidator+Shapes.swift`:

   * добавить обработку `case .rect(...)`
   * **на этом шаге** валидатор должен эмитить ошибку “unsupported shape item” (fail-fast), т.к. рендера/компиляции ещё нет.

3. В тестах:

   * добавить unit-тесты на декодирование `ty:"rc"` → `.rect(...)`
   * добавить unit-тест, что валидатор на shape layer с `rc` возвращает `unsupportedShapeItem` (чтобы защититься от silent ignore между PR-03 и PR-07)

## 1.2 Что НЕ делаем (строго)

* НЕ добавлять конвертацию Rectangle → BezierPath / AnimPath (это PR-07)
* НЕ менять Metal renderer / AnimIR / Shape extraction
* НЕ менять “supported features” в смысле “начало рендериться” — PR-03 только про decoding + fail-fast в validator
* НЕ добавлять новые файлы/модули/утилиты вне текущих файлов (кроме тестов)

---

# 2) Изменения в модели Lottie (TVECore/Lottie)

## 2.1 ShapeItem enum

Файл: `TVECore/Sources/TVECore/Lottie/LottieShape.swift`

### Требование

Добавить новый case:

```swift
case rect(LottieShapeRect)
```

### Decoder switch

В `ShapeItem.init(from:)` добавить:

```swift
case "rc":
    let rect = try LottieShapeRect(from: decoder)
    self = .rect(rect)
```

---

## 2.2 Новый struct: LottieShapeRect

Файл: `TVECore/Sources/TVECore/Lottie/LottieShape.swift`

### Требования к полям (минимум релизного декодирования)

Добавить структуру, аналогичную стилю `LottieShapePath`, `LottieShapeFill`:

Обязательные поля:

* `type: String` (ty) — всегда `"rc"`
* `name: String?` (`nm`)
* `matchName: String?` (`mn`)
* `hidden: Bool?` (`hd`)
* `index: Int?` (`ix`)

Geometry-поля (ключевые для Rectangle Path):

* `position: LottieAnimatedValue?` (`p`) — центр прямоугольника в локальном пространстве shape group
* `size: LottieAnimatedValue?` (`s`) — ширина/высота `[w, h]`
* `roundness: LottieAnimatedValue?` (`r`) — радиус скругления (может быть 0, может быть анимирован)
* `direction: Int?` (`d`) — направление (если есть)

### CodingKeys

```swift
private enum CodingKeys: String, CodingKey {
    case type = "ty"
    case name = "nm"
    case matchName = "mn"
    case hidden = "hd"
    case index = "ix"
    case position = "p"
    case size = "s"
    case roundness = "r"
    case direction = "d"
}
```

### Важно про `r`

В проекте уже есть кейс “перегруженного `r`”:

* у fill (`ty:"fl"`) `r` — это `Int` fillRule
* у transform (`ty:"tr"`) `r` — это rotation (LottieAnimatedValue)
* у rect (`ty:"rc"`) `r` — это roundness (LottieAnimatedValue)

Никаких костылей/дубликатов не нужно — просто корректный `CodingKeys` и тип `LottieAnimatedValue?`.

---

# 3) Валидатор: fail-fast для rc до реализации рендера

Файл: `TVECore/Sources/TVECore/AnimValidator/AnimValidator+Shapes.swift`

## 3.1 Требование

Добавить case `.rect` в `validateShapeItem(...)`.

## 3.2 Поведение (релизное!)

До PR-07 Rectangle ещё **не поддержан для вывода**, поэтому валидатор обязан:

* эмитить `ValidationIssue` с:

  * `code: AnimValidationCode.unsupportedShapeItem`
  * `severity: .error`
  * `path: "\(basePath).ty"`
  * `message`: в стиле существующих сообщений, но с `rc`

Пример текста:
`"Shape type 'rc' not supported. Supported: gr, sh, fl, tr"`

> Это намеренно: PR-03 добавляет decoding, но не “support”. Без этого валидатор пропустит сцену, а рендер тихо не нарисует прямоугольники — это запрещено нашим правилом релиза.

---

# 4) Тесты

## 4.1 Decode tests

Файл: `TVECore/Tests/TVECoreTests/ShapeItemDecodeTests.swift`

Добавить минимум 2 теста:

### (A) `rc` декодируется в `.rect`

JSON должен содержать:

* `"ty":"rc"`
* `"p"`, `"s"` как static значения (`a:0`) с массивами
* `"r"` как static number (`a:0,k:12`) (roundness)

Проверки:

* `shape` = `.rect(let rect)`
* `rect.type == "rc"`
* `rect.position != nil`, `rect.size != nil`, `rect.roundness != nil`

### (B) `rc` roundness декодируется как animated value (a=1)

Дать `"r": {"a":1,"k":[...keyframes...]}` (можно пустой массив, если декодер это допускает, но лучше 2 keyframes).
Проверить:

* `rect.roundness?.isAnimated == true`

## 4.2 Validator fail-fast test (важно!)

Файл: `TVECore/Tests/TVECoreTests/AnimValidatorTests.swift`

Добавить тест, который создаёт minimal anim JSON:

* 1 layer `ty=4` shape layer
* shapes содержит один item `{"ty":"rc", ...}`

Запустить `validatePackage(sceneJSON:..., animJSON:...)` (как уже используется в тестах).
Ожидание:

* среди `report.errors` есть issue с `code == AnimValidationCode.unsupportedShapeItem`
* `path` содержит `.shapes[0].ty`
* message содержит `'rc'`

---

# 5) Нефункциональные требования (качество PR)

* Без новых “utility” классов/файлов ради парсинга: используем существующий `LottieAnimatedValue` и общий стиль моделей.
* Новые поля/структуры должны быть `Decodable, Equatable, Sendable` как остальные.
* Код должен собираться без предупреждений.
* Все текущие тесты + новые тесты проходят.

---

# 6) Acceptance Criteria (что значит PR-03 принят)

1. `ShapeItem` умеет декодировать `ty:"rc"` как `.rect(LottieShapeRect)`
2. `LottieShapeRect` содержит все обязательные поля и правильно декодит `p/s/r/d`
3. Валидатор не допускает silent ignore: при встрече `.rect` **возвращает error unsupportedShapeItem**
4. Добавлены unit-тесты:

   * на decode `.rect`
   * на validator fail-fast для `rc`
5. Все тесты в TVECore проходят

---

Если всё понятно — пусть программист присылает PR-03. На ревью я буду смотреть строго:

* `CodingKeys` и типы полей (`p/s/r` именно `LottieAnimatedValue?`)
* отсутствие лишних/дублирующих структур
* что валидатор реально выдаёт ошибку на `.rect` (до PR-07)
* что тесты минимальные и детерминированные (без “случайных” зависимостей от ассетов).
