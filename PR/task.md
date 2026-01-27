Да, понял. Ниже — **полное детальное ТЗ** для фикса **“Вариант B (лучший, “навсегда правильный”): глобальные PathID сразу при компиляции”** на базе текущего кода проекта.

---

## 0) Цель изменения

Сделать так, чтобы:

1. **PathID назначались один раз, детерминированно, на этапе компиляции** Lottie → AnimIR
2. **Был один Scene-level PathRegistry** (на сцену), без “склейки” на рантайме и без дублирования данных между AnimIR
3. **Switch variant на лету** работал без пересборки registry / без re-registerPaths
4. Убрать “размазанную ответственность”: сейчас часть логики “глобализации PathID” живёт в `ScenePlayer.compile`, часть — в `AnimIR.registerPaths(into:)`, плюс есть вводящая в заблуждение `SceneRuntime.mergedPathRegistry`.

---

## 1) Проблема текущей реализации (что фиксируем)

### 1.1 Дублирование ответственности

Сейчас `ScenePlayer.compile()` создаёт `mergedPathRegistry` и делает:

* компилирует каждый `AnimIR` (без pathId)
* затем **вторым проходом** вызывает `animIR.registerPaths(into: &mergedPathRegistry)` для всех variants всех blocks
* при этом `AnimIR.registerPaths(into:)` **в конце делает `pathRegistry = registry`**, то есть **каждый AnimIR начинает хранить внутри себя ссылочно/структурно “весь merged registry”**, что:

  * размножает данные (структурно копируется массив `paths`, т.к. `struct`)
  * создаёт путаницу: “чей” registry? сцены или анимации?

### 1.2 SceneRuntime.mergedPathRegistry сейчас неправильный

`SceneRuntime.mergedPathRegistry` прямо говорит TODO и фактически берёт только selectedVariant, что **ломает** идею “один registry для всей сцены”.

---

## 2) Новый контракт (итоговая архитектура)

### 2.1 Единственный источник правды для paths

* **`ScenePlayer`** (или будущий `SceneCompiler`) хранит:

  * `blockRuntimes`
  * **`mergedPathRegistry: PathRegistry`** — один на сцену

### 2.2 AnimIR больше НЕ владеет PathRegistry

* `AnimIR` по-прежнему содержит `mask.pathId` и `shapeGroup.pathId`
* но **не хранит внутри себя `pathRegistry.paths`** (допустимо оставить поле, но оно должно быть пустым/локальным и не использоваться в рендере)
* Рендер (`MetalRenderer`) получает **scene-level registry** всегда извне.

---

## 3) Требования (MUST)

### MUST-1: Глобальные PathID при компиляции

`PathID` назначается в момент построения `Mask` и `ShapeGroup` (matte shapes) внутри компилятора.

### MUST-2: Детерминированность

Одинаковый вход → одинаковые PathID.
Детерминированный порядок регистрации:

* порядок mediaBlocks из `scene.json`
* внутри блока — порядок variants
* внутри анимации — порядок layers/masks как в JSON
* precomps — как сейчас: компилируются из `lottie.assets` (в порядке JSON)

### MUST-3: Variant switch без пересборки registry

Переключение variants не требует `registerPaths()`, не требует мерджа, PathID уже валидны в общем registry сцены.

### MUST-4: Никаких post-pass registerPaths в ScenePlayer

`ScenePlayer.compile()` **не делает** второго прохода с `registerPaths`.

### MUST-5: Ошибка вместо “тихого игнора” (рекомендовано как релизное поведение)

Если маска/shapeMatte присутствует, но `PathResourceBuilder.build(...)` вернул `nil` (топология/триангуляция/мало вершин) — **компиляция должна падать** (иначе мы молча потеряем маску и получим неверный рендер).

---

## 4) Изменения API и кода (по файлам)

### 4.1 `AnimIRCompiler` — расширить сигнатуру compile

**Файл:** `TVECore/Sources/TVECore/AnimIR/AnimIRCompiler.swift`

#### Было:

```swift
public func compile(lottie: LottieJSON, animRef: String, bindingKey: String, assetIndex: AssetIndex) throws -> AnimIR
```

#### Стало (MUST):

```swift
public func compile(
    lottie: LottieJSON,
    animRef: String,
    bindingKey: String,
    assetIndex: AssetIndex,
    pathRegistry: inout PathRegistry
) throws -> AnimIR
```

**Смысл:** compiler получает scene-level registry (общий для всех variants/blocks) и **в процессе компиляции** регистрирует туда все пути, выставляя `pathId` в masks и shapeGroup.

---

### 4.2 Компиляция masks с назначением pathId

**Файл:** `AnimIRCompiler.swift`

#### Было:

```swift
private func compileMasks(from lottieMasks: [LottieMask]?) -> [Mask]
```

#### Стало:

```swift
private func compileMasks(
    from lottieMasks: [LottieMask]?,
    animRef: String,
    layerName: String,
    pathRegistry: inout PathRegistry
) throws -> [Mask]
```

#### Логика (MUST):

Для каждой `Mask(from:)`:

1. Собрали `Mask` (с `path: AnimPath`, `pathId == nil`)
2. Построили `PathResource`:

   * `PathResourceBuilder.build(from: mask.path, pathId: PathID(0))` (id всё равно перепишется внутри `register`)
3. Если build вернул nil → **throw UnsupportedFeature**

   * code: `"MASK_PATH_BUILD_FAILED"`
   * message: “Cannot triangulate/flatten mask path (topology mismatch or too few vertices)”
   * path: `"anim(\(animRef)).layer(\(layerName)).mask[\(index)]"`
4. Зарегистрировали:

   * `let assignedId = pathRegistry.register(resource)`
5. Положили:

   * `mask.pathId = assignedId`

> Примечание: `PathRegistry.register()` сам проставляет id = index. Поэтому в builder можно передавать `PathID(0)`.

---

### 4.3 Компиляция shapeMatte (матт-источник) с назначением pathId

**Файл:** `AnimIRCompiler.swift`

Сейчас `compileContent` делает:

* `ShapePathExtractor.extractAnimPath(...)`
* создаёт `ShapeGroup(animPath:..., pathId:nil)`

#### Изменение (MUST):

`compileContent` должен принимать `pathRegistry` и при `.shapeMatte`:

* если `animPath != nil`:

  * build resource `PathResourceBuilder.build(from: animPath, pathId: PathID(0))`
  * если nil → throw UnsupportedFeature

    * code: `"MATTE_PATH_BUILD_FAILED"`
    * path: `"anim(\(animRef)).layer(\(layerName)).shapeMatte"`
  * `shapeGroup.pathId = pathRegistry.register(resource)`

Сигнатура:

```swift
private func compileContent(
    from lottie: LottieLayer,
    layerType: LayerType,
    animRef: String,
    layerName: String,
    pathRegistry: inout PathRegistry
) throws -> LayerContent
```

---

### 4.4 Протянуть registry в compileLayer / compileLayers / compile

**Файл:** `AnimIRCompiler.swift`

* `compile(...)` принимает `inout PathRegistry`
* `compileLayers(...)` принимает `inout PathRegistry`
* `compileLayer(...)` принимает `inout PathRegistry`

И использует:

* `compileMasks(..., pathRegistry: &pathRegistry)`
* `compileContent(..., pathRegistry: &pathRegistry)`

---

### 4.5 `AnimIR.registerPaths()` — больше не используется

**Файл:** `TVECore/Sources/TVECore/AnimIR/AnimIR.swift`

Варианты действий (выбрать релизно-оптимальный):

**MUST (для Part 1 релиза):**

* `ScenePlayer` больше не вызывает `registerPaths` вообще.
* `registerPaths` можно оставить для тестов/отладки, но:

  * **убрать строку `pathRegistry = registry`** в `registerPaths(into:)` (иначе мы снова “заливаем” в AnimIR глобальный registry).
  * либо сделать поведение: `pathRegistry` остаётся локальным и содержит только локальные paths (но локальные ids тогда не должны конфликтовать — это отдельная тема).

**Рекомендую релизное правило:**

* `AnimIR.pathRegistry` считается **deprecated/unused** в сценовом пайплайне.
* `AnimIR.registerPaths()` оставить только для unit-тестов “одной анимации” (и там он может регистрировать в `self.pathRegistry`, а НЕ в внешний).

---

### 4.6 `ScenePlayer.compile()` — единый registry, без post-pass

**Файл:** `TVECore/Sources/TVECore/ScenePlayer/ScenePlayer.swift`

#### Было:

* компиляция variants
* потом отдельный проход `registerPaths(into: &mergedPathRegistry)`

#### Стало (MUST):

1. В начале `compile()`:

```swift
var mergedPathRegistry = PathRegistry()
```

2. При компиляции каждого variant вызывать:

```swift
let animIR = try compiler.compile(..., pathRegistry: &mergedPathRegistry)
```

3. После компиляции всех блоков:

* `self.mergedPathRegistry = mergedPathRegistry`

4. Полностью удалить блок:

```swift
for i in 0..<blockRuntimes.count { ... registerPaths ... }
```

---

### 4.7 Убрать/починить `SceneRuntime.mergedPathRegistry`

**Файл:** `TVECore/Sources/TVECore/ScenePlayer/ScenePlayerTypes.swift`

Сейчас там неверная реализация + TODO.

**MUST:**

* удалить `public var mergedPathRegistry: PathRegistry` из `SceneRuntime` целиком
  **или**
* сделать его строгим прокси к тому, что реально собрал `ScenePlayer` (но сейчас `SceneRuntime` не хранит registry).

Самый чистый релизный вариант: **удалить**, чтобы не было двух “источников правды”.

---

## 5) Изменения тестов (обязательно)

### 5.1 Тесты, которые сейчас делают `ir.registerPaths()`

Найдено в проекте:

* `TestProfileTransformsTests.swift`
* `MetalRendererAnimatedMatteMorphTests.swift`
* возможно и другие

**Новый паттерн:**

```swift
var registry = PathRegistry()
let ir = try compiler.compile(..., pathRegistry: &registry)
// НЕ вызываем registerPaths()
let commands = ir.renderCommands(...)
renderer.draw(..., pathRegistry: registry)
```

### 5.2 Добавить новый unit-тест на “глобальность id”

**Новый тест (MUST):** `GlobalPathIdTests`

Сценарий:

* компилируем **две** разные анимации с масками в **один** `registry`
* проверяем:

  * все `mask.pathId` не nil
  * ids второй анимации **не начинаются с 0**, а идут дальше (или хотя бы `maxId(anim1) < minId(anim2)` при детерминированном порядке компиляции)

---

## 6) Acceptance Criteria (DoD)

Готово, если:

1. `ScenePlayer.compile()` компилирует сцену **без** вызовов `registerPaths()`.
2. `mergedPathRegistry.count > 0` для сцен с масками/маттами.
3. У всех `Mask` в поддержанном subset `mask.pathId != nil`.
4. У shape matte источников (LayerType.shapeMatte) `shapeGroup.pathId != nil`.
5. Переключение variant не требует пересборки registry (никаких side effects).
6. Тесты обновлены и проходят.
7. В профиле памяти:

   * нет N-кратного копирования `paths` внутри каждого `AnimIR`.

---

## 7) Доп. замечания для “финального релизного” качества

* Если сейчас где-то ещё используется `animIR.pathRegistry` (кроме тестов) — это баг, нужно перейти на scene-level registry.
* `AnimIR.registerPaths(into:)` в текущем виде опасен именно строкой `pathRegistry = registry` — она почти гарантированно вернёт проблему дублирования.

---

Если хочешь — я могу **сразу сформулировать конкретный PR-план** (по коммитам/порядку правок) и чеклист ревью для программиста, чтобы ты просто отправила ему “делай 1→2→3” и потом мы жёстко прогнали по DoD.
