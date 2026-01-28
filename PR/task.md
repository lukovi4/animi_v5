Ниже — **каноническое финальное ТЗ для PR-06: “Lottie decoding: Stroke `ty:"st"`”**. Оно строго следует шаблону PR-03/04/05: **decode → fail-fast в валидаторе → тесты с проверкой path**, без рендера и без временных решений.

---

# PR-06 — Lottie decoding: Stroke (`ty="st"`)

## 0) Цель PR

Добавить **полное релизное декодирование** shape item Stroke (`ty="st"`) в модель Lottie (`TVECore`).

Важно:

* PR-06 **не делает** рендер stroke / outline / triangulation (это PR-10).
* До PR-10 валидатор обязан **fail-fast** на `.stroke`, чтобы не было silent ignore (иначе обводка “пропадёт”).

---

# 1) Scope PR-06

## 1.1 Что делаем

1. `TVECore/Sources/TVECore/Lottie/LottieShape.swift`

   * добавить `LottieShapeStroke`
   * добавить case `.stroke(LottieShapeStroke)` в `ShapeItem`
   * добавить `case "st":` в `ShapeItem.init(from:)`

2. `TVECore/Sources/TVECore/AnimValidator/AnimValidator+Shapes.swift`

   * добавить обработку `.stroke` → `unsupportedShapeItem` (fail-fast)
   * не менять рекурсивную схему `basePath` / `.it[i]`

3. Тесты

   * decode tests на `st` (static + animated width)
   * validator tests (top-level и nested group) с проверкой path

## 1.2 Что НЕ делаем

* Не реализуем dash patterns
* Не реализуем line cap/join поведение (это для рендера)
* Не реализуем stroke → filled outline geometry
* Не меняем AnimIR/Metal/ShapePathExtractor

---

# 2) Модель `LottieShapeStroke` (LottieShape.swift)

## 2.1 ShapeItem enum

Добавить:

```swift
case stroke(LottieShapeStroke)
```

В декодере:

```swift
case "st":
    let stroke = try LottieShapeStroke(from: decoder)
    self = .stroke(stroke)
```

## 2.2 Новый struct: `LottieShapeStroke`

Файл: `TVECore/Sources/TVECore/Lottie/LottieShape.swift`

### Обязательные поля (релизный decode)

Метаданные:

* `type: String` (`ty`) — `"st"`
* `name: String?` (`nm`)
* `matchName: String?` (`mn`)
* `hidden: Bool?` (`hd`)
* `index: Int?` (`ix`)

Stroke свойства (ключевые и реально используемые):

* `color: LottieAnimatedValue?` (`c`) — цвет (обычно `[r,g,b]` 0..1 или 0..255 в зависимости от source; мы просто декодим как есть)
* `opacity: LottieAnimatedValue?` (`o`) — 0..100
* `width: LottieAnimatedValue?` (`w`) — stroke width (важно: может быть animated)
* `lineCap: Int?` (`lc`) — 1..3 (butt/round/square)
* `lineJoin: Int?` (`lj`) — 1..3 (miter/round/bevel)
* `miterLimit: Double?` (`ml`) — miter limit
* `dash: [LottieShapeStrokeDash]?` (`d`) — **декодируем**, но **считаем unsupported позже** (см. валидатор ниже)
* `dashOffset: LottieAnimatedValue?` (`d` элемент с `n:"o"` или отдельное поле в зависимости от export) — см. примечание

### CodingKeys

```swift
private enum CodingKeys: String, CodingKey {
    case type = "ty"
    case name = "nm"
    case matchName = "mn"
    case hidden = "hd"
    case index = "ix"

    case color = "c"
    case opacity = "o"
    case width = "w"
    case lineCap = "lc"
    case lineJoin = "lj"
    case miterLimit = "ml"
    case dash = "d"
}
```

### Примечание про dash format (важно для релиза)

Lottie stroke dash обычно приходит как массив объектов в `"d"`:

* элементы вида `{ "n": "d", "v": { ... } }` (dash length),
* `{ "n": "g", "v": { ... } }` (gap length),
* `{ "n": "o", "v": { ... } }` (offset)

Поэтому нужно **декодировать “d” как массив структур**, а не как `LottieAnimatedValue`.

✅ В PR-06 требуется реализовать декодирование этого массива корректно, **но** мы пока не поддерживаем dash в рендере — значит валидатор должен fail-fast при наличии dash (см. ниже).

---

## 2.3 Структура dash item (если `d` присутствует)

Добавить:

```swift
public struct LottieShapeStrokeDash: Decodable, Equatable, Sendable {
    public let name: String?   // "n"
    public let value: LottieAnimatedValue? // "v"

    private enum CodingKeys: String, CodingKey {
        case name = "n"
        case value = "v"
    }
}
```

> Это релизно: мы не делаем рендер dash, но мы должны корректно декодировать и валидировать входные данные, а не терять их.

---

# 3) Валидатор: fail-fast для `st` до PR-10

Файл: `TVECore/Sources/TVECore/AnimValidator/AnimValidator+Shapes.swift`

## 3.1 Поведение для `.stroke`

До реализации рендера stroke (PR-10), любое `st` должно давать:

* `code: AnimValidationCode.unsupportedShapeItem`
* `severity: .error`
* `path: "\(basePath).ty"`
* message: `"Shape type 'st' not supported. Supported: gr, sh, fl, tr"`

## 3.2 Дополнительное релизное правило для dash (важно!)

Даже после того как stroke станет поддержан (позже), **dash пока не в scope**.
Поэтому уже сейчас стоит подготовить fail-fast правило на dash:

Если `LottieShapeStroke.dash` **не пустой** и содержит элементы с `name in {"d","g","o"}` → это **отдельный** валидаторский error “unsupported stroke dash”.

Но чтобы не вводить новую семантику до того, как stroke вообще поддержан, в PR-06 можно сделать проще:

✅ В PR-06 (пока `st` сам unsupported) — достаточно общего `unsupportedShapeItem`.

🟦 Рекомендация (не обязательна в PR-06, но хорошо для релиза):
добавить отдельный код на dash уже сейчас, чтобы потом, когда `st` станет supported, dash не стал silent-ignore.

Если решаем сделать сразу (предпочтительно):

* добавить в `AnimValidationCode.swift`:

  * `UNSUPPORTED_STROKE_DASH`
* и в `validateShapeItemRecursive` для `.stroke(let s)`:

  * если `s.dash?.isEmpty == false` → добавить issue `UNSUPPORTED_STROKE_DASH` path `\(basePath).d`

Но это опционально; если хочешь строго минимально — оставить на PR-10/следующий.

---

# 4) Тесты

## 4.1 ShapeItemDecodeTests.swift

Добавить минимум 4 теста:

### (A) Static stroke decode

JSON:

```json
{
  "ty":"st",
  "c":{"a":0,"k":[1,0,0]},
  "o":{"a":0,"k":100},
  "w":{"a":0,"k":12},
  "lc":2,
  "lj":1,
  "ml":4
}
```

Проверить:

* `.stroke(let s)`
* `s.width != nil`, `s.opacity != nil`, `s.color != nil`
* `s.lineCap == 2`, `s.lineJoin == 1`, `s.miterLimit == 4`

### (B) Animated width decode

`"w": {"a":1,"k":[...2 keyframes...]}` → `s.width?.isAnimated == true`

### (C) Dash array decode

JSON с `d`:

```json
"d":[{"n":"d","v":{"a":0,"k":10}}, {"n":"g","v":{"a":0,"k":5}}, {"n":"o","v":{"a":0,"k":0}}]
```

Проверить:

* `s.dash?.count == 3`
* `dash[0].name == "d"`, `dash[0].value != nil`

### (D) Update unknown test

Убрать `"st"` из `unknownTypes`.

---

## 4.2 AnimValidatorTests.swift

Добавить 2 теста с проверкой path (как делали для rc/el/sr):

### (A) `testValidate_strokeShape_returnsErrorWithCorrectPath()`

Shape layer `ty=4`, shapes[0] = stroke `{"ty":"st", ...}`
Ожидаем:

* `unsupportedShapeItem`
* `path` содержит `.shapes[0].ty`
* message содержит `'st'`

### (B) `testValidate_strokeInGroupShape_returnsErrorWithCorrectNestedPath()`

Group → `it[0]` = stroke
Ожидаем:

* `path` содержит `.it[0].ty`

Если вы добавите отдельный код `UNSUPPORTED_STROKE_DASH`, добавьте третий тест:

* stroke с `"d":[...]` → error `UNSUPPORTED_STROKE_DASH` path `.d`

---

# 5) Нефункциональные требования

* Никакого изменения существующих архитектурных частей
* Никаких новых “общих” парсеров: используем текущие типы `LottieAnimatedValue`
* Код соответствует стилю: `Decodable, Equatable, Sendable`
* Все тесты TVECore проходят

---

# 6) Acceptance Criteria

PR-06 принят, если:

1. `ShapeItem` декодирует `ty:"st"` → `.stroke(LottieShapeStroke)`
2. `LottieShapeStroke` корректно декодит `c/o/w/lc/lj/ml` и `d` как массив dash items
3. Валидатор fail-fast для `.stroke` (и path корректный, включая nested `.it[i].ty`)
4. Тесты: decode (включая dash), validator (включая path), unknown test обновлён (убран `st`)
5. Все тесты проекта проходят

---

Если хочешь, я сразу зафиксирую решение по dash: **делаем отдельный `UNSUPPORTED_STROKE_DASH` уже в PR-06 или переносим на PR-10**. Но базовый канонический вариант выше уже релизный и безопасный (потому что stroke пока всё равно fail-fast как unsupported).
