Отвечаю чётко и фиксирую решения как техлид — чтобы ты мог без догадок начать PR2.

---

## 1) Нужны ли дополнения моделей PR1?

**Да, в PR2 нужно дополнить модели `Scene`/`MediaBlock`/`Variant`/`MediaInput` теми полями, которые валидируем.**

Правило: **валидатор не должен работать “по сырым JSON-словарям”**, он валидирует **типизированную модель**, иначе дальше всё расползётся.

### Обязательные добавления в PR2

**MediaInput**

* `allowedMedia` → сделать типизированным enum
* `maskRef: String?` → optional

**Variant**

* `defaultDurationFrames: Int?`
* `ifAnimationShorter: String?` / `ifAnimationLonger: String?` (или enum, если в spec фиксированный набор)
* `loop: Bool?`
* `loopRange: LoopRange?`

Если каких-то из этих полей нет в `scene.json` сейчас — всё равно добавь optional, чтобы:

* модель соответствовала spec и тест-профайлу,
* валидатор мог проверять, когда поля появятся в других сценах.

---

## 2) Инвариант input.rect “одинаковый для variants”

Ты прав: **при текущей структуре модели (input на уровне MediaBlock) это уже enforced**.

### Что делаем (решение)

**Не делаем “raw” модель и не пишем искусственный тест на невозможный кейс.**

Вместо этого:

* В `SceneValidator` добавляем **комментарий/guard**, что в v0.1 `input.rect` хранится на уровне блока и поэтому invariant выполняется структурно.
* Пишем тест **на стабильность контракта**: что `Scene` декодится из reference JSON и `input.rect` доступен и валиден (width/height > 0).
  То есть мы тестируем фактическую валидацию rect, а не “расхождение variants”.

Почему так: отдельная raw-структура ради теста “невозможного состояния” = лишняя сложность и риск. В Part 1 это не нужно.

Если в будущем появится `variant.inputRectOverride` — тогда это будет **spec vNext** и отдельный PR на расширение модели + тест на mismatch.

---

## 3) LoopRange — какая структура?

Фиксируем: **структура**, не массив.

```swift
public struct LoopRange: Decodable, Equatable, Sendable {
    public let startFrame: Int
    public let endFrame: Int
}
```

JSON keys:

* `startFrame`
* `endFrame`

Валидатор:

* `0 <= startFrame`
* `startFrame < endFrame`

Это соответствует тому, как мы хотим дальше работать с таймингом (явные имена, меньше ошибок).

---

## 4) MaskCatalog — когда реальная реализация?

В PR2 `MaskCatalog` нужен только как интерфейс, чтобы валидатор мог:

* warning если `maskRef` есть, а каталога нет
* warning если каталог есть, но ref не найден 

### Когда будет реализация?

**PR5 (или PR4, если удобнее), но до рендера UI-масок она может оставаться заглушкой.**

Пояснение по roadmap:

* **PR2**: scene validation + API
* **PR3**: anim JSON loader + anim-level validation
* **PR4+**: compiler/IR/renderer
* **MaskCatalog** реально понадобится, когда появится UI/Editor режим с `maskRef` (ты сама ранее говорила, что `maskRef` — UI/interaction, не финальный render). Поэтому:

  * в runtime для export это может быть вообще “not required”
  * но для редактора/превью — будет.

Так что: в PR2 оставляем `maskCatalog=nil` по умолчанию, но интерфейс фиксируем уже сейчас.

---

# Итог: что именно делать программисту в PR2

1. Дополнить модели optional-полями (Variant + MediaInput) и enum для `allowedMedia`.
2. Реализовать `SceneValidator` + `ValidationReport/Issue` и все MUST/WARN проверки (кроме “variant inputRect mismatch” — его не делаем).
3. Реализовать `LoopRange` как struct.
4. Добавить unit tests на коды ошибок.
5. Подключить валидатор в `AnimiApp` лог.


Если хочешь — я могу сразу дать **точный список значений** для `ifAnimationShorter/Longer` (если они у вас в spec фиксированы), чтобы ты сразу сделал enum и валидировал значения строго.

---

# PR2 — SceneValidator v0.1 (валидация `scene.json`)

## 0) Цель PR2

Добавить модуль **SceneValidator**, который проверяет `Scene` (из PR1) на соответствие **Scene.json Spec v0.1** и “Core Spec Part 1” правилам, возвращая **ValidationReport** с issues (`error|warning`) в стабильном формате: `code`, `message`, `path`, `severity`.

**Важно:** PR2 валидирует **только scene.json**. Проверки, требующие чтения/декодинга `anim-*.json` (FPS invariant с `anim.fr`, binding-layer existence и т.д.) — это PR3.

---

# 1) Deliverables (что должно появиться в коде)

## 1.1 Новый модуль/папка

В `TVECore/Sources/TVECore/SceneValidator/`:

* `SceneValidator.swift`
* `ValidationReport.swift`
* `ValidationIssue.swift`
* `SceneValidationCode.swift` (enum со стабильными кодами)

## 1.2 Публичный API (фиксируем сигнатуры)

```swift
public struct ValidationIssue: Equatable, Sendable {
    public enum Severity: String, Sendable { case error, warning }
    public let code: String          // stable
    public let severity: Severity    // error|warning
    public let path: String          // json-path
    public let message: String       // human-readable
}

public struct ValidationReport: Equatable, Sendable {
    public let issues: [ValidationIssue]
    public var errors: [ValidationIssue] { ... }
    public var warnings: [ValidationIssue] { ... }
    public var hasErrors: Bool { ... }
}
```

```swift
public protocol MaskCatalog {
    func contains(maskRef: String) -> Bool
}
```

```swift
public final class SceneValidator: Sendable {
    public struct Options: Sendable {
        public var supportedSchemaVersions: Set<String> = ["0.1"]
        public var supportedContainerClip: Set<ContainerClip> = [.none, .slotRect] // Part 1 subset
        public init() {}
    }

    public init(options: Options = .init(), maskCatalog: MaskCatalog? = nil)

    public func validate(scene: Scene) -> ValidationReport
}
```

**Почему так:** формат ошибок — строго как в docs (code/message/path/severity).
`maskCatalog` — опционален, чтобы сейчас можно было хотя бы выдавать warning “catalog unavailable” (требование плана PR2). 

---

# 2) Нормативные проверки PR2 (MUST/WARN)

Все проверки должны добавлять issue с **точным path** (см. раздел 3), а не “в целом что-то не так”.

## 2.1 Root / schemaVersion

**MUST**

* `scene.schemaVersion` должен быть в `supportedSchemaVersions`. Иначе `error`.

Код:

* `SCENE_UNSUPPORTED_VERSION`

Path:

* `$.schemaVersion`

## 2.2 Canvas

**MUST**

* `canvas.width > 0`, `canvas.height > 0`, `canvas.fps > 0`, `canvas.durationFrames > 0`.

Коды:

* `CANVAS_INVALID_DIMENSIONS`
* `CANVAS_INVALID_FPS`
* `CANVAS_INVALID_DURATION`

Paths:

* `$.canvas.width`, `$.canvas.height`, `$.canvas.fps`, `$.canvas.durationFrames`

## 2.3 MediaBlocks list + unique ids + stable order premise

**MUST**

* `mediaBlocks` не пуст.
* `blockId` уникален.

Коды:

* `BLOCKS_EMPTY`
* `BLOCK_ID_DUPLICATE`

Paths:

* `$.mediaBlocks`
* `$.mediaBlocks[i].blockId`

## 2.4 Геометрия Rect (block.rect и input.rect)

**MUST**

* Для каждого блока:

  * `block.rect.width > 0`, `block.rect.height > 0`
  * `input.rect.width > 0`, `input.rect.height > 0`
  * все значения finite (не NaN/inf).

Коды:

* `RECT_INVALID` (используем один код, но message уточняет что именно)
  Paths:
* `$.mediaBlocks[i].rect.*`
* `$.mediaBlocks[i].input.rect.*`

**Политика про “в пределах canvas”:**

* В Part 1: **НЕ фейлим**, если блок частично вне canvas (это допустимо), но при желании можно `warning` `BLOCK_OUTSIDE_CANVAS`. (Это не в MUST списке плана, так что не делаем error.) 

## 2.5 variants[]

**MUST**

* `variants` не пуст.
* `variants[].animRef` не пустая строка.

Коды:

* `VARIANTS_EMPTY`
* `VARIANT_ANIMREF_EMPTY`

Paths:

* `$.mediaBlocks[i].variants`
* `$.mediaBlocks[i].variants[j].animRef`

## 2.6 input.bindingKey

**MUST**

* `input.bindingKey` должен быть непустой строкой.
  (Да, spec говорит default "media", но наш `scene.json` уже хранит bindingKey в input; валидируем как must, как требует PR2 план. )

Код:

* `INPUT_BINDINGKEY_EMPTY`
  Path:
* `$.mediaBlocks[i].input.bindingKey`

## 2.7 containerClip (Part 1 subset)

**MUST**

* В Part 1 поддерживаем **только** `none` и `slotRect` (как в PR2 плане). Если встретили `slotRectAfterSettle` → `error`.

Код:

* `CONTAINERCLIP_UNSUPPORTED`
  Path:
* `$.mediaBlocks[i].containerClip`

## 2.8 invariant: input.rect одинаковый для всех variants одного блока

**MUST**

* `input.rect` MUST одинаковый для всех variants данного блока.
  В текущей модели input.rect хранится один раз, но правило всё равно должно быть enforced:
* если в JSON появится variant-level override (или при future-расширении) — валидатор должен ловить.
  Реализация в PR2: **просто фиксируем правило в validator**, и добавляем unit test на JSON, где variants имеют разные input.rect (через отдельную тестовую модель/ручной decode структуры “raw”). Это гарантирует, что правило не потеряется.

Код:

* `INPUT_RECT_VARIANT_MISMATCH`
  Path:
* `$.mediaBlocks[i].input.rect`

## 2.9 input.allowedMedia (enum values + не пуст)

**MUST**

* `allowedMedia` не пуст.
* каждое значение ∈ {`photo`, `video`, `color`} (строго как spec).
* дубликаты запрещены (warning или error — выбираем **error**, чтобы контракт был строгий).

Коды:

* `ALLOWEDMEDIA_EMPTY`
* `ALLOWEDMEDIA_INVALID_VALUE`
* `ALLOWEDMEDIA_DUPLICATE`

Paths:

* `$.mediaBlocks[i].input.allowedMedia`
* `$.mediaBlocks[i].input.allowedMedia[k]`

**Важно:** правило “active source ровно один” — runtime правило (не проверяется в PR2, только можно отразить в message/доках). 

## 2.10 timing

**MUST**
Если `timing` указан:

* `0 <= startFrame < endFrame <= canvas.durationFrames`.

Код:

* `TIMING_INVALID_RANGE`
  Path:
* `$.mediaBlocks[i].timing`

## 2.11 Variant duration policy (минимальная валидация полей variant)

В вашем реальном `scene.json` есть:

* `defaultDurationFrames`
* `ifAnimationShorter`, `ifAnimationLonger`
* `loop` (и потенциально `loopRange`)

**MUST**

* `defaultDurationFrames > 0` если поле присутствует.
* `loopRange` если присутствует: `startFrame < endFrame` и оба >= 0.

Коды:

* `VARIANT_DEFAULTDURATION_INVALID`
* `VARIANT_LOOPRANGE_INVALID`

Paths:

* `$.mediaBlocks[i].variants[j].defaultDurationFrames`
* `$.mediaBlocks[i].variants[j].loopRange`

## 2.12 maskRef (UI-only) + AssetCatalog availability

**WARNING**

* Если `input.maskRef` указан:

  * если `maskCatalog == nil` → warning “catalog unavailable”
  * если `maskCatalog != nil` и `contains(maskRef)==false` → warning “mask not found”
    Это прямо требование PR2 плана.

Коды:

* `MASKREF_CATALOG_UNAVAILABLE` (warning)
* `MASKREF_NOT_FOUND` (warning)

Path:

* `$.mediaBlocks[i].input.maskRef`

---

# 3) Стандарт json-path (обязательный)

Path формат **строго фиксируем**, чтобы тесты/лог не разваливались:

* Root: `$`
* Поля: `$.canvas.fps`
* Массивы: `$.mediaBlocks[0].variants[0].animRef`

Никаких “/canvas/fps” и никаких “mediaBlocks.0”.

---

# 4) Стабильные коды ошибок (обязательный список)

Коды — **строковые**, стабильные, без локализации.

### Errors

* `SCENE_UNSUPPORTED_VERSION`
* `CANVAS_INVALID_DIMENSIONS`
* `CANVAS_INVALID_FPS`
* `CANVAS_INVALID_DURATION`
* `BLOCKS_EMPTY`
* `BLOCK_ID_DUPLICATE`
* `RECT_INVALID`
* `VARIANTS_EMPTY`
* `VARIANT_ANIMREF_EMPTY`
* `INPUT_BINDINGKEY_EMPTY`
* `CONTAINERCLIP_UNSUPPORTED`
* `INPUT_RECT_VARIANT_MISMATCH`
* `ALLOWEDMEDIA_EMPTY`
* `ALLOWEDMEDIA_INVALID_VALUE`
* `ALLOWEDMEDIA_DUPLICATE`
* `TIMING_INVALID_RANGE`
* `VARIANT_DEFAULTDURATION_INVALID`
* `VARIANT_LOOPRANGE_INVALID`

### Warnings

* `BLOCK_OUTSIDE_CANVAS` (optional, если делаете)
* `MASKREF_CATALOG_UNAVAILABLE`
* `MASKREF_NOT_FOUND`

---

# 5) Интеграция в AnimiApp (обязательная)

В `PlayerViewController` после `ScenePackageLoader.load(...)`:

1. `let report = SceneValidator(...).validate(scene: package.scene)`
2. Логируем:

* “Validation: X errors, Y warnings”
* Далее список issues построчно:

  * `[ERROR] CODE path — message`
  * `[WARN ] CODE path — message`

3. Если `report.hasErrors == true`:

* Пишем “Scene is invalid — rendering disabled”
* (Никакого крэша/фатала)

---

# 6) Unit Tests (обязательные, минимум 10)

В `TVECoreTests`:

## 6.1 Happy path

* `testValidate_referenceScene_hasNoErrors()`

  * грузим ваш реальный `scene.json` 
  * ожидаем `hasErrors == false`
  * warnings допускаются (maskRef зависит от наличия)

## 6.2 schemaVersion

* `unsupportedVersion -> SCENE_UNSUPPORTED_VERSION`

## 6.3 Canvas

* width=0 -> CANVAS_INVALID_DIMENSIONS
* fps=0 -> CANVAS_INVALID_FPS
* durationFrames=0 -> CANVAS_INVALID_DURATION

## 6.4 blocks

* mediaBlocks=[] -> BLOCKS_EMPTY
* duplicate blockId -> BLOCK_ID_DUPLICATE

## 6.5 rect

* input.rect.width = 0 -> RECT_INVALID
* block.rect.height = -1 -> RECT_INVALID

## 6.6 variants

* variants=[] -> VARIANTS_EMPTY
* animRef="" -> VARIANT_ANIMREF_EMPTY

## 6.7 bindingKey

* bindingKey="" -> INPUT_BINDINGKEY_EMPTY

## 6.8 containerClip

* containerClip=slotRectAfterSettle -> CONTAINERCLIP_UNSUPPORTED (Part 1 subset)

## 6.9 allowedMedia

* allowedMedia=[] -> ALLOWEDMEDIA_EMPTY
* allowedMedia=["photo","banana"] -> ALLOWEDMEDIA_INVALID_VALUE
* allowedMedia=["photo","photo"] -> ALLOWEDMEDIA_DUPLICATE

## 6.10 timing

* timing.startFrame = 10, endFrame=10 -> TIMING_INVALID_RANGE
* timing.endFrame > canvas.durationFrames -> TIMING_INVALID_RANGE

### Примечание про тестовые сцены

Не обязаны создавать новые файлы на диске. Можно в тесте:

* декодить `Scene` из JSON-строки (удобнее для негативных кейсов)
* или грузить reference `scene.json` и мутировать модель.

---

# 7) Definition of Done (PR2)

PR2 считается готовым, если:

* `SceneValidator.validate(scene:)` возвращает `ValidationReport` в формате (code/message/path/severity).
* На reference package `scene.json` — **0 ошибок**.
* Негативные тесты покрывают все MUST-коды из списка (минимум 10 тестов).
* UI показывает отчёт и блокирует дальнейшие шаги при `hasErrors`.

---

## Важная оговорка (чтобы не было “мы уже сделали PR3 в PR2”)

PR2 **не читает anim-*.json** и не проверяет:

* fps invariant `scene.fps == anim.fr`
* binding-layer `nm == bindingKey`
* image assets resolvable
  Это всё начинается в PR3 по плану.