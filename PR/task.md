Ниже — **каноническое финальное ТЗ для PR-10: “Stroke `st` → render/path pipeline”** (релизное решение, без “потом доделаем”). Я специально **встроил все уже встреченные грабли** (fallback’и, mismatch keyframes, unparseable animated, синхронизация валидатора/экстрактора, корректные `path` для nested `.it[]`, актуализация “Supported: …” сообщений).

---

# PR-10 — Stroke `st` → Render/Path Pipeline (Canonical Spec)

## 0) Цель PR

Добавить **полную поддержку stroke-элемента Lottie Shape** (`ty:"st"`) в пайплайн:

**Lottie JSON → Decode → Validate (fail-fast) → AnimIR → RenderGraph → MetalRenderer**

Чтобы stroke **реально рендерился** (а не только декодился), и поведение было:

* детерминированным,
* безопасным (без silent ignore),
* согласованным между **validator** и **extractor**,
* покрытым тестами (unit-level).

---

## 1) Входные данные и контекст

### 1.1 Уже сделано ранее

* PR-06: `st` **декодится** в `ShapeItem.stroke(LottieShapeStroke)` + `LottieShapeStrokeDash`.
* PR-07/08/09: построение `BezierPath/AnimPath` для `rc/el/sr` + строгие правила:

  * **NO FALLBACKS**
  * **keyframes count/time match**
  * **fail-fast validator** (в т.ч. “isAnimated==true, но keyframes не распарсились”)

### 1.2 Текущее состояние до PR-10

* Validator сейчас либо:

  * всё ещё блокирует `st` как unsupported (если не обновляли), либо
  * сообщает unsupported только для dash (если добавляли позже).
* RenderGraph/MetalRenderer **не умеют** рисовать stroke как отдельный примитив.

---

## 2) Область работ (Scope)

### 2.1 MUST: что PR-10 обязан сделать

1. **Разблокировать** `ty:"st"` в validator (stroke теперь “supported for rendering”).
2. Добавить **render-команду** для stroke и её выполнение в MetalRenderer.
3. Добавить **AnimIR-представление stroke** (стили + анимируемые параметры, если поддерживаем).
4. Реализовать **rasterization/caching** stroke (аналогично shape fill), без деградации детерминизма.
5. Добавить **строгую валидацию stroke**, включая **dash** (чтобы не было “stroke supported, но dash silently ignored”).
6. Тесты:

   * validator tests (валидные/невалидные сценарии, path для nested),
   * extractor/render-graph level tests (минимальный smoke: stroke попадает в команды),
   * (опционально) renderer baseline test, если уже есть инфраструктура.

### 2.2 MUST NOT (явно не делаем в PR-10)

* Trim Paths (`tm`)
* Gradient Stroke (`gs`)
* Dash rendering (dash остаётся **unsupported**, но должен **валидироваться** и fail-fast)
* Roundness stroke join special cases beyond CoreGraphics default (кроме lc/lj/ml)
* Stroke over open-path semantics если текущий пайплайн поддерживает только closed (см. ниже — если `BezierPath.closed` уже есть, поддержим; иначе валидатор запрещает open).

---

## 3) Поддерживаемый поднабор stroke (Release constraints)

### 3.1 Поддерживаемые поля `st`

* `c` (color) — **static only** (в PR-10)
* `o` (opacity) — **static only** (в PR-10)
* `w` (width) — **animated allowed** (обязательно, т.к. есть тест-ассет `shape_stroke_basic`)
* `lc` (lineCap: 1/2/3) — static
* `lj` (lineJoin: 1/2/3) — static
* `ml` (miterLimit) — static

### 3.2 Жёсткие запреты (fail-fast)

* `d` (dash array) — **запрещён**, любая непустая `d` → ошибка `UNSUPPORTED_STROKE_DASH`
* `c` animated (`c.a==1`) → `UNSUPPORTED_STROKE_COLOR_ANIMATED`
* `o` animated (`o.a==1`) → `UNSUPPORTED_STROKE_OPACITY_ANIMATED`
* `w`:

  * `w` отсутствует → `UNSUPPORTED_STROKE_WIDTH_MISSING`
  * `w <= 0` (static или любой keyframe) → `UNSUPPORTED_STROKE_WIDTH_INVALID`
  * `w.a==1`, но keyframes не распарсились / формат не keyframes → `UNSUPPORTED_STROKE_WIDTH_KEYFRAME_FORMAT`
* `lc` not in {1,2,3} → `UNSUPPORTED_STROKE_LINECAP`
* `lj` not in {1,2,3} → `UNSUPPORTED_STROKE_LINEJOIN`
* `ml <= 0` → `UNSUPPORTED_STROKE_MITERLIMIT`

### 3.3 Ограничение безопасности по ширине

Чтобы предотвратить pathological input:

* `w` MUST be `<= MAX_STROKE_WIDTH` (канонически: `2048`).
  Иначе `UNSUPPORTED_STROKE_WIDTH_INVALID` (в сообщении указать фактическое значение).

> Важно: это правило должно быть **и в validator, и в extractor** (как урок из PR-09: pt<=100 синхронизировали).

---

## 4) Изменения в коде (каноническая архитектура)

### 4.1 AnimValidationCode.swift

Добавить новые коды (минимальный набор, без лишней грануляции):

* `UNSUPPORTED_STROKE_DASH`
* `UNSUPPORTED_STROKE_COLOR_ANIMATED`
* `UNSUPPORTED_STROKE_OPACITY_ANIMATED`
* `UNSUPPORTED_STROKE_WIDTH_MISSING`
* `UNSUPPORTED_STROKE_WIDTH_INVALID`
* `UNSUPPORTED_STROKE_WIDTH_KEYFRAME_FORMAT`
* `UNSUPPORTED_STROKE_LINECAP`
* `UNSUPPORTED_STROKE_LINEJOIN`
* `UNSUPPORTED_STROKE_MITERLIMIT`

**Сообщения** должны быть однозначными и fail-fast ориентированными (“not supported”, “must be …”).

---

### 4.2 AnimValidator+Shapes.swift

#### A) Убрать fail-fast “unsupportedShapeItem” для `.stroke`

Вместо этого — **полная validateStroke(...)**.

#### B) ValidateStroke: правила

Функция `validateStroke(stroke: LottieShapeStroke, basePath: String, issues: inout [ValidationIssue])`:

1. Dash:

* если `stroke.dash != nil` и массив не пустой → `UNSUPPORTED_STROKE_DASH`
* если dash есть, но пустой — разрешить (или трактовать как запрещён тоже; канонически лучше: **любое наличие `d` = ошибка**, чтобы не было ambiguous)

2. Color `c`:

* `c` MUST exist и быть static numbers[3] (RGB) либо numbers[4] (RGBA) — если ваш декодер возвращает 3, то фиксируем 3.
* если `c.isAnimated == true` → `UNSUPPORTED_STROKE_COLOR_ANIMATED`
* если формат не распарсился → `UNSUPPORTED_STROKE_COLOR_ANIMATED` или отдельный `FORMAT` (можно без отдельного, но сообщение “unrecognized format” MUST быть)

3. Opacity `o`:

* MUST exist, static only (0…100)
* animated → `UNSUPPORTED_STROKE_OPACITY_ANIMATED`

4. Width `w`:

* MUST exist, static или keyframed
* если static → `w > 0 && w <= MAX_STROKE_WIDTH`
* если animated:

  * **fail-fast** если `isAnimated==true`, но не удалось извлечь keyframes (`k` не keyframes array) → `UNSUPPORTED_STROKE_WIDTH_KEYFRAME_FORMAT`
  * каждый keyframe MUST иметь `t` и `s`
  * каждое `s` должно быть number и `0 < s <= MAX_STROKE_WIDTH`

> Это повторяет “v3 fix” из PR-07: animated flag без распарсенных keyframes не может “молчаливо пройти”.

5. LineCap/LineJoin/MiterLimit:

* `lc ∈ {1,2,3}`, иначе `UNSUPPORTED_STROKE_LINECAP`
* `lj ∈ {1,2,3}`, иначе `UNSUPPORTED_STROKE_LINEJOIN`
* `ml` MUST be `> 0`, иначе `UNSUPPORTED_STROKE_MITERLIMIT`

#### C) Обновить “Supported: …” сообщения

Во всех местах, где формируется сообщение `unsupportedShapeItem` для других типов (`sr`, `unknown`, etc.) — список Supported обязан включать актуальные:
`gr, sh, fl, tr, rc, el, sr, st` (в зависимости от текущего статуса).
Это уже всплывало в PR-08 fixes — здесь закрепляем как MUST.

---

### 4.3 AnimIR: модель stroke и генерация команд

#### A) AnimIRTypes.swift

Добавить структуру стиля stroke, которую можно семплить по кадру:

```swift
public struct StrokeStyle: Equatable, Sendable {
    public let color: [Double]          // static RGB (0...1)
    public let opacity: Double          // static 0...1
    public let width: AnimTrack<Double> // static или keyframed
    public let lineCap: Int             // 1/2/3
    public let lineJoin: Int            // 1/2/3
    public let miterLimit: Double
}
```

`ShapeGroup` расширить:

* либо добавить `stroke: StrokeStyle?`
* либо (если ShapeGroup переиспользуется только для matte) — ввести новый контейнер (но канонически проще: расширить `ShapeGroup`).

#### B) AnimIRPath.swift / extractor

Добавить extraction stroke из shape items:

* `extractStrokeFromShapeGroup(_ group: LottieShapeGroup) -> LottieShapeStroke?`
* `extractStrokeStyle(...) -> StrokeStyle?` (с конвертацией width в `AnimTrack<Double>`)

Правила экстрактора:

* **никаких fallback’ов** (`?? default`) для обязательных значений
* если validator гарантирует формат — экстрактор может `guard` и возвращать `nil` только при невозможности (но в идеале это не должно происходить на валидных данных)

#### C) AnimIRCompiler.swift

При компиляции shape layer:

* Если есть `fill` → как раньше: `drawShape`
* Если есть `stroke` → добавить `strokeStyle` и обеспечить, что pathId существует (stroke должен “привязаться” к тому же path)

> Если в shape group есть stroke, но нет path/rect/el/sr — это ошибка валидатора уровня shapes (можно reuse existing “missing path” error или добавить новый, но лучше добавить: `UNSUPPORTED_STROKE_NO_PATH` — опционально).

---

### 4.4 RenderGraph / RenderCommand

#### A) RenderCommand.swift

Добавить новый кейс:

```swift
case drawStroke(
  pathId: PathID,
  transform: CGAffineTransform,
  strokeColor: [Double],
  strokeOpacity: Double,
  strokeWidth: Double,
  lineCap: Int,
  lineJoin: Int,
  miterLimit: Double
)
```

(Цвет/opacity — уже нормализованные 0…1.)

#### B) Генерация команд в AnimIR.swift (frame evaluation)

На каждом кадре:

* `strokeWidth = shapeGroup.stroke.width.value(frame)`
* добавить `drawStroke(...)` в тот же список команд, где уже рисуется fill.

**Порядок отрисовки (канон):**

* если есть fill и stroke на одном path:

  1. fill
  2. stroke
     Это соответствует типичному ожиданию и минимизирует сюрпризы.

---

### 4.5 MetalRenderer: выполнение drawStroke

#### A) MetalRenderer+Execute.swift

Добавить обработку `case .drawStroke` аналогично `.drawShape`:

1. Сэмплить `BezierPath` через `pathRegistry.resource(for:)` + `samplePath(...)` (как сейчас).
2. Получить `strokeTexture` из `ShapeCache` (новый метод).
3. Отрисовать текстуру тем же пайплайном (quad), как сейчас для fill shape.

> Важно: stroke должен уважать `transform` и clip stack так же, как fill.

---

### 4.6 ShapeCache + Rasterizer

#### A) ShapeCache.swift

Добавить:

* `struct StrokeCacheKey` (или расширить существующий ключ) включая:

  * `pathId`
  * `frameIndex`
  * `transform` (или `transformHash`)
  * `strokeColor`, `strokeOpacity`
  * `strokeWidth`
  * `lineCap`, `lineJoin`, `miterLimit`

Добавить метод:

* `func strokeTexture(forStrokeCommand..., bezierPath: BezierPath, ...) -> MTLTexture?`

#### B) Rasterization stroke (CoreGraphics)

Добавить в rasterizer (или новый `ShapeRasterizer`):

* построение `CGPath` из `BezierPath` (у вас уже есть для fill/alpha)
* настройка:

  * `ctx.setLineWidth(strokeWidth)`
  * `ctx.setLineCap(...)`
  * `ctx.setLineJoin(...)`
  * `ctx.setMiterLimit(...)`
  * AA включён (как и для fill)
* рисование:

  * `ctx.addPath(path)`
  * `ctx.strokePath()`

Output: alpha mask → затем сконвертировать в BGRA с premultiplied alpha **точно так же**, как сейчас для fill.

---

## 5) Валидатор vs Экстрактор: канонические анти-грабли (MUST)

Это прям “уроки PR-07/08/09”, фиксируем для PR-10:

1. **NO FALLBACKS** в extractor/renderer (никаких `?? .zero`, `?? 100`).
2. Если `isAnimated==true`, но keyframes:

   * не keyframes array,
   * не распарсились,
   * нет `t`/`s`,
     → валидатор обязан вернуть **ошибку**, иначе shape “исчезнет” молча.
3. Любые “safety bounds” (например, `MAX_STROKE_WIDTH`) должны быть:

   * и в validator,
   * и в extractor.
4. Пути ошибок (`issue.path`) обязаны быть корректными для nested shapes:

   * `.shapes[i].it[j].ty` и т.п.
     (Т.е. используется подход из PR-03 fix: рекурсивный `basePath`, без дублирования `context`.)

---

## 6) Тесты (Acceptance)

### 6.1 Unit tests — decoding (уже есть в PR-06)

Не трогаем, но при необходимости дополняем.

### 6.2 Validator tests (MUST)

Добавить тесты:

1. **Valid stroke with animated width** → **NO errors**
2. `dash` присутствует → `UNSUPPORTED_STROKE_DASH`
3. `w` отсутствует → `UNSUPPORTED_STROKE_WIDTH_MISSING`
4. `w=0` static → `UNSUPPORTED_STROKE_WIDTH_INVALID`
5. `w.a=1`, но `k` не keyframes array → `UNSUPPORTED_STROKE_WIDTH_KEYFRAME_FORMAT`
6. `c.a=1` → `UNSUPPORTED_STROKE_COLOR_ANIMATED`
7. `lc=99` → `UNSUPPORTED_STROKE_LINECAP`
8. Nested stroke inside group → ошибка/успех + **проверка path содержит `.it[0]...`**

### 6.3 Extractor / RenderGraph tests (MUST)

Минимальный smoke:

* собрать мини-анимацию с одним shape layer:

  * path (например, `rc`) + stroke
  * сгенерировать AnimIR
  * построить команды на кадр
  * assert: присутствует `.drawStroke(...)` и его параметры корректны (width семплится).

### 6.4 Renderer baseline (опционально, но желательно)

Если у вас есть baseline infra:

* отрендерить 1 кадр со stroke и проверить:

  * картинка не пустая (есть non-transparent пиксели)
  * и/или snapshot compare.

---

## 7) Definition of Done (Merge checklist)

PR-10 считается готовым только если:

* ✅ `st` реально **рендерится** через новый `drawStroke` путь
* ✅ Validator: fail-fast на dash, анимированные color/opacity, invalid width, invalid lc/lj/ml, unparseable width keyframes
* ✅ Никаких fallback’ов в новом коде
* ✅ “Supported: …” сообщения обновлены (включают `rc, el, sr, st`)
* ✅ Тесты:

  * validator tests покрывают edge cases + nested path correctness
  * render-graph smoke test подтверждает появление `drawStroke`
* ✅ `swift test` / `swift build` без warning’ов/ошибок

---

## 8) Явные продуктовые ограничения (зафиксировать в README/Spec)

В `README` для shapes (tests/resources) добавить таблицу:

* Stroke supported: **YES** (PR-10)
* Dash: **NO** (валидатор блокирует)
* Animated width: **YES**
* Animated color/opacity: **NO**
* Trim paths: **NO**
* Gradient stroke: **NO**
