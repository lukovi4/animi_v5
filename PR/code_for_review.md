# PR-10: Stroke (ty:st) Rendering — Code for Review (v2)

## Summary

Реализация PR-10: полная поддержка `st` (stroke) от валидации до GPU рендера.

**Ключевые изменения:**
- 9 новых кодов ошибок `UNSUPPORTED_STROKE_*` для детальной диагностики
- `StrokeStyle` тип в AnimIRTypes с AnimTrack<Double> для animated width
- `extractStrokeStyle()` extraction с fail-fast для невалидных параметров
- `drawStroke` RenderCommand с полным набором stroke параметров
- CoreGraphics rasterization для stroke (lineCap, lineJoin, miterLimit)
- StrokeCacheKey и strokeTexture в ShapeCache для кеширования
- Порядок отрисовки: fill → stroke

**Ограничения PR-10:**
- Dash pattern запрещён
- Color (c) и Opacity (o) только static
- Width (w) может быть animated
- Максимальная ширина: 2048px (в validator И extractor)

---

## Review Fix (v2)

### Блокер 1 — strokeWidth не масштабировался transform'ом (FIXED)

**Проблема:** strokeWidth передавался в "сырых" единицах Lottie, не учитывая animToViewport scale.

**Исправление:**
1. Добавлена функция `computeUniformScale(from:)` — вычисляет uniform scale как `hypot(a, b)` (длина X-базиса)
2. В `strokeTexture()` вычисляется `scaledStrokeWidth = strokeWidth * uniformScale`
3. Квантизация ширины для cache key: `(scaledStrokeWidth * 8).rounded() / 8` (1/8 пикселя точность)
4. В `rasterizeStroke()` используется уже масштабированная ширина

**Файл:** `ShapeCache.swift`

```swift
/// Computes uniform scale factor from transform matrix (length of X-basis vector)
static func computeUniformScale(from transform: Matrix2D) -> Double {
    return hypot(transform.a, transform.b)
}

// В strokeTexture():
let uniformScale = Self.computeUniformScale(from: transform)
let scaledStrokeWidth = strokeWidth * uniformScale
let quantizedWidth = (scaledStrokeWidth * 8).rounded() / 8  // Для cache key
```

### Блокер 2 — extractAnimatedWidth не был fail-fast (FIXED)

**Проблема:** При отсутствии `time` или `startValue` в keyframe использовался `continue` вместо `return nil`.

**Исправление:**
- `guard let time = kf.time else { return nil }` (было: `continue`)
- `guard let startValue = kf.startValue else { return nil }` (было: `continue`)
- Неверный формат startValue → `return nil` (было: `continue`)
- `isAnimated == true` но `value` не `.keyframes` → `return nil`
- Пустой массив keyframes → `return nil`

**Файл:** `AnimIRPath.swift`

```swift
/// Extracts animated width track from LottieAnimatedValue
/// Fail-fast: returns nil if any keyframe is invalid
private static func extractAnimatedWidth(from value: LottieAnimatedValue) -> AnimTrack<Double>? {
    guard let data = value.value,
          case .keyframes(let lottieKeyframes) = data else {
        return nil
    }
    guard !lottieKeyframes.isEmpty else { return nil }

    for kf in lottieKeyframes {
        guard let time = kf.time else { return nil }        // NO continue!
        guard let startValue = kf.startValue else { return nil }  // NO continue!
        // ...
    }
}
```

### Non-blocking fixes (v2)

1. **StrokeCacheKey квантизация** — DONE
   - `quantizedWidth = (scaledStrokeWidth * 8).rounded() / 8`
   - Уменьшает cache misses при animated width

2. **computeMaxAlpha debug helper** — REMOVED
   - Удалён неиспользуемый debug code из MetalRenderer+Execute.swift

### Новые тесты (v2)

**`ShapePathExtractorTests.swift`** — +3 теста:
```swift
func testStroke_animatedWidthMissingTime_returnsNil()       // keyframe без t → nil
func testStroke_animatedWidthMissingStartValue_returnsNil() // keyframe без s → nil
func testStroke_animatedWidthInvalidFormat_returnsNil()     // s = path вместо number → nil
```

**`AnimValidatorTests.swift`** — +2 теста:
```swift
func testValidate_strokeAnimatedWidthMissingTime_returnsError()      // KEYFRAME_FORMAT error
func testValidate_strokeAnimatedWidthMissingStartValue_returnsError() // KEYFRAME_FORMAT error
```

---

## Files Changed

| File | Change |
|------|--------|
| `AnimValidationCode.swift` | +9 новых кодов `STROKE_*` |
| `AnimValidator+Shapes.swift` | `st` разрешён, добавлена `validateStroke()` |
| `AnimIRTypes.swift` | +`StrokeStyle` struct, `ShapeGroup` расширен `stroke` полем |
| `AnimIRPath.swift` | +`extractStrokeStyle()`, `extractAnimatedWidth()` (fail-fast v2) |
| `AnimIRCompiler.swift` | Extraction stroke в shapeMatte |
| `AnimIR.swift` | Генерация `drawStroke` команды в render |
| `RenderCommand.swift` | +`case drawStroke(...)` |
| `ShapeCache.swift` | +`StrokeCacheKey`, `strokeTexture()`, `computeUniformScale()`, квантизация (v2) |
| `MetalRenderer+Execute.swift` | +`drawStroke()` execution, удалён computeMaxAlpha (v2) |
| `AnimValidatorTests.swift` | +15 тестов для stroke validation (включая 2 новых v2) |
| `ShapePathExtractorTests.swift` | +18 тестов для stroke extraction (включая 3 новых v2) |

---

## Key Code Changes

### 1. `AnimValidationCode.swift` — New error codes

```swift
// MARK: - Stroke Errors

public static let unsupportedStrokeDash = "UNSUPPORTED_STROKE_DASH"
public static let unsupportedStrokeColorAnimated = "UNSUPPORTED_STROKE_COLOR_ANIMATED"
public static let unsupportedStrokeOpacityAnimated = "UNSUPPORTED_STROKE_OPACITY_ANIMATED"
public static let unsupportedStrokeWidthMissing = "UNSUPPORTED_STROKE_WIDTH_MISSING"
public static let unsupportedStrokeWidthInvalid = "UNSUPPORTED_STROKE_WIDTH_INVALID"
public static let unsupportedStrokeWidthKeyframeFormat = "UNSUPPORTED_STROKE_WIDTH_KEYFRAME_FORMAT"
public static let unsupportedStrokeLinecap = "UNSUPPORTED_STROKE_LINECAP"
public static let unsupportedStrokeLinejoin = "UNSUPPORTED_STROKE_LINEJOIN"
public static let unsupportedStrokeMiterlimit = "UNSUPPORTED_STROKE_MITERLIMIT"
```

---

### 2. `AnimValidator+Shapes.swift` — Stroke validation

```swift
case .stroke(let stroke):
    validateStroke(stroke: stroke, basePath: basePath, issues: &issues)
```

Validates:
1. Dash must be absent
2. Color must be static
3. Opacity must be static
4. Width must exist, > 0, <= 2048 (static or animated with valid keyframes)
5. LineCap must be 1, 2, or 3
6. LineJoin must be 1, 2, or 3
7. MiterLimit must be > 0

---

### 3. `AnimIRTypes.swift` — StrokeStyle type

```swift
public struct StrokeStyle: Sendable, Equatable {
    public let color: [Double]           // RGB 0...1
    public let opacity: Double           // 0...1
    public let width: AnimTrack<Double>  // static or animated
    public let lineCap: Int              // 1/2/3
    public let lineJoin: Int             // 1/2/3
    public let miterLimit: Double
}
```

---

### 4. `ShapeCache.swift` — Stroke width scaling (v2)

```swift
/// Computes uniform scale factor from transform matrix
static func computeUniformScale(from transform: Matrix2D) -> Double {
    return hypot(transform.a, transform.b)
}

func strokeTexture(...) -> MTLTexture? {
    // Scale stroke width by transform
    let uniformScale = Self.computeUniformScale(from: transform)
    let scaledStrokeWidth = strokeWidth * uniformScale

    // Quantize for cache key (1/8 pixel precision)
    let quantizedWidth = (scaledStrokeWidth * 8).rounded() / 8

    let key = StrokeCacheKey(
        ...,
        strokeWidth: quantizedWidth,  // Quantized for cache
        ...
    )

    // Rasterize with actual scaled width (not quantized)
    let bgraBytes = rasterizeStroke(
        ...,
        scaledStrokeWidth: scaledStrokeWidth,
        ...
    )
}
```

---

### 5. `AnimIRPath.swift` — extractAnimatedWidth fail-fast (v2)

```swift
private static func extractAnimatedWidth(from value: LottieAnimatedValue) -> AnimTrack<Double>? {
    // Fail-fast: not keyframes
    guard let data = value.value,
          case .keyframes(let lottieKeyframes) = data else {
        return nil
    }

    // Fail-fast: empty keyframes
    guard !lottieKeyframes.isEmpty else { return nil }

    for kf in lottieKeyframes {
        // Fail-fast: missing time (NO continue!)
        guard let time = kf.time else { return nil }

        // Fail-fast: missing startValue (NO continue!)
        guard let startValue = kf.startValue else { return nil }

        // Fail-fast: invalid format (NO continue!)
        switch startValue {
        case .numbers(let arr) where !arr.isEmpty:
            widthValue = arr[0]
        default:
            return nil
        }

        // Fail-fast: invalid width
        guard widthValue > 0, widthValue <= maxStrokeWidth else {
            return nil
        }
        // ...
    }
}
```

---

### 6. `RenderCommand.swift` — drawStroke command

```swift
case drawStroke(
    pathId: PathID,
    strokeColor: [Double],
    strokeOpacity: Double,
    strokeWidth: Double,
    lineCap: Int,
    lineJoin: Int,
    miterLimit: Double,
    layerOpacity: Double,
    frame: Double
)
```

---

### 7. `AnimIR.swift` — Render order: fill → stroke

```swift
case .shapes(let shapeGroup):
    if let pathId = shapeGroup.pathId {
        // Draw fill first
        if shapeGroup.fillColor != nil {
            commands.append(.drawShape(...))
        }
        // Draw stroke on top
        if let stroke = shapeGroup.stroke {
            let strokeWidth = stroke.width.sample(frame: context.frame)
            commands.append(.drawStroke(...))
        }
    }
```

---

## Build & Test Results

```
swift build: OK (0 warnings)
swift test: 526 tests passed, 5 skipped (MaskCacheTests), 0 failures
```

---

## Comparison: v1 vs v2

| Issue | v1 | v2 |
|-------|----|----|
| strokeWidth scaling | Not scaled by transform | `hypot(a,b)` uniform scale |
| Cache key | Raw strokeWidth | Quantized `(w*8).rounded()/8` |
| extractAnimatedWidth | `continue` on invalid kf | `return nil` (fail-fast) |
| computeMaxAlpha | Present (dead code) | Removed |
| Keyframe format tests | 0 | +5 new tests |

---

## READY FOR REVIEW (v2)

Все требования PR-10 v2 выполнены:
1. **strokeWidth масштабируется** через `computeUniformScale(from: pathToViewport)`
2. **extractAnimatedWidth строго fail-fast** — никаких `continue`, любая невалидность → `nil`
3. **StrokeCacheKey квантизация** — `(scaledStrokeWidth * 8).rounded() / 8`
4. **computeMaxAlpha удалён** — dead code убран
5. **+5 новых тестов** для invalid keyframe format (3 extractor + 2 validator)
6. Все 526 тестов проходят
