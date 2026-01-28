Ниже — **каноническое финальное ТЗ для PR-05: “Lottie decoding: Polystar `ty:"sr"`”**. Оно повторяет проверенную схему PR-03/PR-04 (decode + fail-fast + тесты с проверкой path), без временных решений и без лишнего кода.

---

# PR-05 — Lottie decoding: Polystar (`ty:"sr"`)

## 0) Цель PR

Добавить **полное релизное декодирование** shape item Polystar/Polygon (`ty="sr"`) в модель Lottie `TVECore`.

Важно:

* PR-05 **не реализует** конвертацию polystar → bezier/path (это будет PR-09).
* До PR-09 валидатор обязан **fail-fast** на `.polystar`, чтобы не было silent ignore.

---

# 1) Scope PR-05

## 1.1 Что делаем

1. `TVECore/Sources/TVECore/Lottie/LottieShape.swift`

   * добавить `LottieShapePolystar`
   * добавить case `.polystar(LottieShapePolystar)` в `ShapeItem`
   * добавить `case "sr":` в `ShapeItem.init(from:)`

2. `TVECore/Sources/TVECore/AnimValidator/AnimValidator+Shapes.swift`

   * добавить обработку `.polystar` → `unsupportedShapeItem` (fail-fast)
   * **не трогать** существующую рекурсивную логику path (`basePath` + `.it[i]`)

3. Тесты

   * decode tests на `sr` (static + animated)
   * validator tests:

     * top-level `sr` → error + `.shapes[0].ty`
     * nested `sr` в группе → error + `.it[0].ty`

## 1.2 Что НЕ делаем

* Не добавлять поддержку рендера/AnimIR/ShapePathExtractor
* Не менять правила валидатора для других shape items
* Не добавлять новые хелперы/файлы, кроме минимальных тестов

---

# 2) Модель `LottieShapePolystar` (LottieShape.swift)

## 2.1 ShapeItem enum

Добавить:

```swift
case polystar(LottieShapePolystar)
```

В декодере:

```swift
case "sr":
    let star = try LottieShapePolystar(from: decoder)
    self = .polystar(star)
```

## 2.2 Новый struct: `LottieShapePolystar`

Файл: `TVECore/Sources/TVECore/Lottie/LottieShape.swift`

### Обязательные поля (релизные, полный decode)

Метаданные:

* `type: String` (`ty`) — `"sr"`
* `name: String?` (`nm`)
* `matchName: String?` (`mn`)
* `hidden: Bool?` (`hd`)
* `index: Int?` (`ix`)

Polystar параметры (как в Bodymovin/Lottie):

* `starType: Int?` (`sy`)

  * `1` = star, `2` = polygon (встречается)
* `position: LottieAnimatedValue?` (`p`)
* `rotation: LottieAnimatedValue?` (`r`)
* `points: LottieAnimatedValue?` (`pt`) — число вершин/лучей (может быть анимированное)
* `innerRadius: LottieAnimatedValue?` (`ir`) — для star
* `outerRadius: LottieAnimatedValue?` (`or`)
* `innerRoundness: LottieAnimatedValue?` (`is`) — проценты 0..100
* `outerRoundness: LottieAnimatedValue?` (`os`) — проценты 0..100
* `direction: Int?` (`d`)

### CodingKeys

```swift
private enum CodingKeys: String, CodingKey {
    case type = "ty"
    case name = "nm"
    case matchName = "mn"
    case hidden = "hd"
    case index = "ix"

    case starType = "sy"
    case position = "p"
    case rotation = "r"
    case points = "pt"
    case innerRadius = "ir"
    case outerRadius = "or"
    case innerRoundness = "is"
    case outerRoundness = "os"
    case direction = "d"
}
```

### Требование по типам

Все геометрические поля — `LottieAnimatedValue?`, как в остальном коде.

> Да, тут тоже есть “overloaded” поля по ключам (`r` уже используется в transform как rotation, но это другой struct — конфликтов быть не должно, как в PR-03).

---

# 3) Валидатор: fail-fast для `sr` до PR-09

Файл: `TVECore/Sources/TVECore/AnimValidator/AnimValidator+Shapes.swift`

## 3.1 Требование

Добавить:

```swift
case .polystar:
    issues.append(ValidationIssue(
        code: AnimValidationCode.unsupportedShapeItem,
        severity: .error,
        path: "\(basePath).ty",
        message: "Shape type 'sr' not supported. Supported: gr, sh, fl, tr"
    ))
```

### Критично

* `path` должен быть **ровно** `\(basePath).ty`
* Вложенные items должны давать путь вида `.it[0].ty` (фикс PR-03 не ломать)

---

# 4) Тесты

## 4.1 ShapeItemDecodeTests.swift

Добавить минимум 3 теста:

### (A) Static decode (полный набор ключей)

Минимальный JSON:

```json
{
  "ty":"sr",
  "sy":1,
  "p":{"a":0,"k":[100,200]},
  "r":{"a":0,"k":0},
  "pt":{"a":0,"k":5},
  "ir":{"a":0,"k":40},
  "or":{"a":0,"k":80},
  "is":{"a":0,"k":0},
  "os":{"a":0,"k":0},
  "d":1
}
```

Проверить:

* `.polystar(let s)`
* `s.starType == 1`
* ключевые поля не nil: `position/points/outerRadius`

### (B) Animated points decode

`pt` как animated (`a:1,k:[...]`) → `s.points?.isAnimated == true`

### (C) Minimal fields decode

JSON только с `"ty":"sr"` и одним параметром (например `pt`) — должен декодироваться.

### Обновить unknown test

Удалить `"sr"` из массива unknownTypes (как делали для rc/el).

---

## 4.2 AnimValidatorTests.swift

Добавить 2 теста (обязательные) с проверкой path:

### (A) `testValidate_polystarShape_returnsErrorWithCorrectPath()`

* shape layer `ty=4`
* shapes[0] = `{"ty":"sr", ...}`
  Ожидаем:
* `unsupportedShapeItem`
* `path` содержит `.shapes[0].ty`
* message содержит `'sr'`

### (B) `testValidate_polystarInGroupShape_returnsErrorWithCorrectNestedPath()`

* shapes[0] = group `{"ty":"gr","it":[{"ty":"sr",...}, ...]}`
  Ожидаем:
* `path` содержит `.it[0].ty`

---

# 5) Нефункциональные требования

* Никаких новых файлов в `Sources` кроме добавления struct/case в существующий `LottieShape.swift`
* Никаких дубликатов валидатора; использовать текущий рекурсивный helper
* Все тесты TVECore проходят

---

# 6) Acceptance Criteria

PR-05 принят, если:

1. `ShapeItem` декодит `ty:"sr"` → `.polystar(LottieShapePolystar)`
2. `LottieShapePolystar` покрывает ключи `sy,p,r,pt,ir,or,is,os,d` корректными типами
3. Валидатор fail-fast для `.polystar` с `unsupportedShapeItem` и корректными path’ами (включая nested `.it[i].ty`)
4. Добавлены тесты decode + validator (с явной проверкой path)
5. Обновлён unknown test (убран `sr`)
6. Все тесты проходят

---

Если всё ок — программист делает PR-05 по этому ТЗ. После мержа логичный следующий шаг — **PR-06 (Stroke `st` decode)**.
