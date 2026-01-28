# BUG: Базовые векторные примитивы не поддерживаются

## Summary

При тестировании alpha_matte_test сцены обнаружено, что из 12 shape layers рендерится только 1. Причина: **Rectangle shape (`ty="rc"`) не поддерживается** — парсится как `unknown` и игнорируется.

Дополнительный анализ показал, что **другие базовые примитивы тоже не поддерживаются**.

---

## Текущая поддержка Shape Types

### ✅ Поддерживаются:

| Lottie Type | Swift Case | Описание |
|-------------|------------|----------|
| `gr` | `.group` | Группа shape items |
| `sh` | `.path` | Произвольный Bezier path |
| `fl` | `.fill` | Заливка цветом |
| `tr` | `.transform` | Трансформация группы |

### ❌ НЕ поддерживаются (падают в `.unknown`):

| Lottie Type | Описание | Частота использования |
|-------------|----------|----------------------|
| `rc` | **Rectangle** (прямоугольник) | Очень часто |
| `el` | **Ellipse** (круг/эллипс) | Очень часто |
| `sr` | **Polystar** (звезда/многоугольник) | Часто |
| `rd` | Rounded Corners | Средне |
| `st` | Stroke (обводка) | Часто |
| `gs` | Gradient Stroke | Редко |
| `gf` | Gradient Fill | Средне |
| `tm` | Trim Path | Средне |
| `mm` | Merge Paths | Редко |
| `rp` | Repeater | Редко |

---

## Конкретный симптом

В AnimiApp сцена `alpha_matte_test` показывает только 1 черный тайл (нижний правый) вместо 12.

**Ожидаемое поведение:** На frame 0 должны быть видны все 12 черных тайлов в сетке 3x4.

---

## Анализ Lottie файла

Файл: `TestAssets/ScenePackages/alpha_matte_test/anim.json`

Структура comp_0 (matte source):
```
Shape Layer 12: ty="sh" (Path)      ← РАБОТАЕТ
Shape Layer 11: ty="rc" (Rectangle) ← НЕ РАБОТАЕТ
Shape Layer 10: ty="rc" (Rectangle) ← НЕ РАБОТАЕТ
Shape Layer 9:  ty="rc" (Rectangle) ← НЕ РАБОТАЕТ
...
Shape Layer 1:  ty="rc" (Rectangle) ← НЕ РАБОТАЕТ
```

**Вывод:** 11 из 12 слоёв используют `ty="rc"` (Rectangle), который не поддерживается.

---

## Подтверждение в коде

### 1. ShapeItem enum — только 4 типа

**Файл:** `TVECore/Sources/TVECore/Lottie/LottieShape.swift`, строки 7-13

```swift
public enum ShapeItem: Equatable, Sendable {
    case group(LottieShapeGroup)     // ty="gr"
    case path(LottieShapePath)       // ty="sh"
    case fill(LottieShapeFill)       // ty="fl"
    case transform(LottieShapeTransform) // ty="tr"
    case unknown(type: String)       // ← ВСЕ ОСТАЛЬНЫЕ падают сюда!
}
```

### 2. Декодер парсит неизвестные типы как unknown

**Файл:** `TVECore/Sources/TVECore/Lottie/LottieShape.swift`, строки 26-41

```swift
switch type {
case "gr": self = .group(...)
case "sh": self = .path(...)
case "fl": self = .fill(...)
case "tr": self = .transform(...)
default:
    self = .unknown(type: type)  // ← "rc", "el", "sr" попадают сюда
}
```

### 3. extractAnimPathFromShape() игнорирует unknown

**Файл:** `TVECore/Sources/TVECore/AnimIR/AnimIRPath.swift`, строки 625-658

```swift
private static func extractAnimPathFromShape(_ shape: ShapeItem) -> AnimPath? {
    switch shape {
    case .path(let pathShape):
        // ... обрабатывает path
    case .group(let shapeGroup):
        // ... обрабатывает group (рекурсивно)
    default:
        return nil  // ← .unknown возвращает nil!
    }
}
```

**Результат:** Слои с rectangle/ellipse/polystar не генерируют `DrawShape` команду и не рендерятся.

---

## Предлагаемое решение

### Минимальное (для текущего бага):

Добавить поддержку Rectangle (`ty="rc"`):

1. **LottieShape.swift:**
   - Добавить `LottieShapeRect` struct
   - Добавить `.rect(LottieShapeRect)` case
   - Добавить `case "rc":` в декодер

2. **AnimIRPath.swift:**
   - Добавить `case .rect(...)` в `extractAnimPathFromShape()`
   - Конвертировать rectangle → BezierPath (4 вершины)

### Расширенное (для полной совместимости):

Добавить также Ellipse (`ty="el"`) и Polystar (`ty="sr"`):
- Ellipse → BezierPath с 4 точками и кривыми Безье для аппроксимации круга
- Polystar → BezierPath с N вершинами

---

## Дополнительная информация

В анимации есть **анимированные rectangles** — поле `s` (size) может иметь keyframes:

```json
"s": {
  "a": 1,
  "k": [
    {"t": 20, "s": [360, 480]},
    {"t": 40, "s": [360, 0]}
  ]
}
```

---

## Вопросы к лиду

1. Достаточно ли сейчас добавить только Rectangle (`rc`), или нужны и Ellipse (`el`) / Polystar (`sr`)?
2. Нужна ли поддержка анимированных параметров (size, position) для примитивов?
3. Нужна ли поддержка Stroke (`st`) для обводок?

---

## Оценка трудозатрат

| Scope | Строк кода | Файлов |
|-------|------------|--------|
| Только Rectangle | ~60-80 | 2 |
| + Ellipse | ~100-120 | 2 |
| + Polystar | ~150-180 | 2 |
| + Анимация параметров | +50-80 | 1 |
