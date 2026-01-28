Ниже — **каноническое ТЗ для PR-04: “Lottie decoding: Ellipse `ty:"el"`”**, с учётом уроков PR-03 (особенно про **корректный path в валидаторе** и обязательный тест на него).

---

# PR-04 — Lottie decoding: Ellipse (`ty:"el"`)

## 0) Цель PR

Добавить **релизное, полное декодирование** shape item Ellipse Path (`ty="el"`) в модель Lottie внутри `TVECore`.

PR-04 **не добавляет рендер/компиляцию** ellipse → path.
До PR-08 валидатор должен **fail-fast** на `.ellipse`, чтобы не было “тихо пропало”.

---

# 1) Scope PR-04

## 1.1 Что делаем

1. `LottieShape.swift`

   * добавить `LottieShapeEllipse` (Decodable/Equatable/Sendable)
   * добавить case `.ellipse(LottieShapeEllipse)` в `ShapeItem`
   * добавить `case "el":` в `ShapeItem.init(from:)`

2. `AnimValidator+Shapes.swift`

   * добавить обработку `.ellipse` с **fail-fast error** `unsupportedShapeItem`
   * использовать уже исправленную рекурсивную валидацию (как после PR-03) — **не возвращать старый баг**.

3. Тесты

   * decode-тесты на `ty:"el"`
   * validator-тесты:

     * ellipse на верхнем уровне shape layer → error + path
     * ellipse внутри `gr.it[]` → error + path `.it[0].ty`

## 1.2 Что НЕ делаем

* НЕ конвертируем ellipse в bezier (это PR-08)
* НЕ меняем Metal/AnimIR/Shape extraction
* НЕ меняем поведение валидатора для других shape items
* НЕ добавляем новые helper-утилиты/файлы

---

# 2) Изменения в модели (`LottieShape.swift`)

## 2.1 ShapeItem enum

Добавить:

```swift
case ellipse(LottieShapeEllipse)
```

В `ShapeItem.init(from:)` добавить:

```swift
case "el":
    let ellipse = try LottieShapeEllipse(from: decoder)
    self = .ellipse(ellipse)
```

## 2.2 Новый struct: `LottieShapeEllipse`

Файл: `TVECore/Sources/TVECore/Lottie/LottieShape.swift`

### Обязательные поля (релизные)

* `type: String` (`ty`) — `"el"`
* `name: String?` (`nm`)
* `matchName: String?` (`mn`)
* `hidden: Bool?` (`hd`)
* `index: Int?` (`ix`)
* `position: LottieAnimatedValue?` (`p`) — центр эллипса
* `size: LottieAnimatedValue?` (`s`) — `[w,h]`
* `direction: Int?` (`d`) — optional

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
    case direction = "d"
}
```

### Требование по типам `p/s`

* `p` и `s` — `LottieAnimatedValue?`
* static значение: ожидается `.array([Double])`
* animated: `.keyframes(...)` (как принято в вашем `LottieAnimatedValue`)

---

# 3) Валидатор (`AnimValidator+Shapes.swift`) — fail-fast (релизно)

## 3.1 Обязательное поведение

Для `.ellipse(...)` валидатор должен эмитить:

* `code: AnimValidationCode.unsupportedShapeItem`
* `severity: .error`
* `path: "\(basePath).ty"`
* message с указанием `el` и списка поддерживаемых на текущем этапе

Пример:
`"Shape type 'el' not supported. Supported: gr, sh, fl, tr"`

## 3.2 Критично: путь должен быть корректным (урок PR-03)

В этом PR **запрещено** трогать рекурсивный механизм построения путей, который уже исправлен в PR-03.

Требование:

* для вложенного элемента внутри группы путь обязан быть вида:
  `...shapes[0].it[0].ty`

---

# 4) Тесты

## 4.1 ShapeItemDecodeTests.swift

Добавить минимум 3 теста:

### (A) Static ellipse decode

JSON:

```json
{ "ty":"el", "p":{"a":0,"k":[100,200]}, "s":{"a":0,"k":[300,400]}, "d":1 }
```

Проверить:

* `.ellipse(let el)`
* `el.position != nil`, `el.size != nil`
* `el.direction == 1`

### (B) Animated position decode

`p: {a:1,k:[...2 keyframes...]}`
Проверить `el.position?.isAnimated == true`

### (C) Unknown shape test remains valid

Не ломать существующий тест unknown; при необходимости обновить ожидания, но без “обходных” проверок.

---

## 4.2 AnimValidatorTests.swift

Добавить 2 теста (обязательные) — аналогично rc, но для el:

### (A) `testValidate_ellipseShape_returnsErrorWithCorrectPath()`

Создать minimal anim JSON:

* один `ty=4` shape layer
* shapes: `[{"ty":"el", ...}]`
  Ожидания:
* есть ошибка `unsupportedShapeItem`
* message содержит `'el'`
* `path` содержит `.shapes[0].ty`

### (B) `testValidate_ellipseInGroupShape_returnsErrorWithCorrectNestedPath()`

Shape layer:

* shapes: `[{"ty":"gr","it":[{"ty":"el", ...},{"ty":"fl",...},{"ty":"tr",...}]}]`
  Ожидания:
* ошибка `unsupportedShapeItem` по ellipse
* `path` содержит `.it[0].ty` (и/или точный `...shapes[0].it[0].ty`)

> Важно: тест должен проверять path явно — это предотвращает возврат багов PR-03.

---

# 5) Нефункциональные требования

* Код компилируется без warnings
* Новые структуры соответствуют стилю проекта (`public`, `Sendable`, `Equatable`)
* Никакого дублирования логики распаковки значений — используем существующий `LottieAnimatedValue`
* Все существующие тесты + новые проходят

---

# 6) Acceptance Criteria

PR-04 принят, если:

1. `ShapeItem` декодирует `ty:"el"` в `.ellipse(LottieShapeEllipse)`
2. `LottieShapeEllipse` корректно декодит `p/s/d` (static + animated)
3. Валидатор выдаёт fail-fast error на `.ellipse` с корректным path
4. Есть тест на nested path `.it[0].ty`
5. Все тесты проекта проходят

---

Если программист сделает PR-04 по этому ТЗ — на ревью я буду смотреть прежде всего:

* что `el` не перепутан с `rc` (нет roundness `r`)
* что валидатор использует `basePath` и не ломает рекурсивный path
* что тесты реально ловят nested `.it[0].ty` path.
