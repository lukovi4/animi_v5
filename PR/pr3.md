# PR3 — Lottie loader (subset) + anim-level validation

## 0) Цель PR3

Сделать слой, который:

1. **читает и декодит** каждый `animRef` (Lottie JSON) в **минимальный Codable subset**,
2. строит **AssetIndex** (assetId → relativePath) по image assets,
3. валидирует `animRef` **в контексте сцены**: FPS invariant, binding-layer, assets resolvable, size mismatch warning, + минимальный “subset scan” на неподдержанные конструкции.

Результат PR3 — мы можем на reference package загрузить `scene.json` + `anim-1..4.json`, получить:

* `LottieByAnimRef: [AnimRef: LottieJSON]`
* `AssetIndexByAnimRef` (или общий index)
* `AnimValidationReport` (0 errors на reference package; warnings допустимы/ожидаемы).

---

## 1) Scope / Non-scope

### Входит

* Lottie Codable subset модели (root/assets/layers/ks/masks/shapes subset) 
* AnimLoader: read+decode anim json по `ScenePackage.animFilesByRef`
* AssetIndex: извлечение image assets (`assets[]` с `u/p`) и проверка существования файлов `images/...`
* AnimValidator: проверки из Core 3.2 + минимальный 4.2 scan (нужное для Part 1 masks/mattes)
* Интеграция в `PlayerViewController`: грузим анимки, валидируем, логируем отчёт

### Не входит (строго)

* Компиляция в AnimIR, трансформ-сэмплинг, parenting, visibility — это PR4/PR5 
* Metal renderer — позже
* Zip loader — отдельно (не смешиваем)

---

## 2) Новые типы и API

### 2.1 Lottie subset модели (TVECore/Sources/TVECore/Lottie/)

Создать папку `Lottie/` и файлы:

* `LottieJSON.swift`
* `LottieAsset.swift`
* `LottieLayer.swift`
* `LottieTransform.swift` (ks)
* `LottieMask.swift`
* `LottieShape.swift` (subset для matte-source)

**Требование:** модели должны быть максимально tolerant:

* все поля optional, где возможно
* неизвестные поля игнорируются (стандартный Decodable)
* если в JSON встречается тип, который мы не поддерживаем — мы **не падаем при decode**, а ловим на этапе validation как `UNSUPPORTED_*`.

### 2.2 AnimLoader

Файлы: `TVECore/Sources/TVECore/AnimLoader/AnimLoader.swift`

```swift
public struct LoadedAnimations: Sendable {
    public let lottieByAnimRef: [String: LottieJSON]
    public let assetIndexByAnimRef: [String: AssetIndex]
}

public struct AssetIndex: Sendable, Equatable {
    public let byId: [String: String]  // assetId -> relativePath (e.g. "images/img_1.png")
}

public enum AnimLoadError: Error, Equatable {
    case animJSONReadFailed(animRef: String, reason: String)
    case animJSONDecodeFailed(animRef: String, reason: String)
}

public final class AnimLoader: Sendable {
    public init(fileManager: FileManager = .default)
    public func loadAnimations(from package: ScenePackage) throws -> LoadedAnimations
}
```

Правила:

* `animRef` ключ = ровно то, что в `scene.json` (например `anim-1.json`). 
* `AssetIndex` строится по **image assets** root-level `assets[]` где есть `id`, `u`, `p`. Пример: `"u":"images/", "p":"img_1.png"` → `"images/img_1.png"`. 

### 2.3 AnimValidation

Папка `TVECore/Sources/TVECore/AnimValidator/`

Файлы:

* `AnimValidationCode.swift` (stable codes)
* `AnimValidator.swift`

API:

```swift
public final class AnimValidator: Sendable {
    public struct Options: Sendable {
        public var requireExactlyOneBindingLayer: Bool = true  // Part 1 strict
        public var allowAnimatedMaskPath: Bool = false         // Part 1: pt.a==0 only
        public init() {}
    }

    public init(options: Options = .init(), fileManager: FileManager = .default)

    public func validate(
        scene: Scene,
        package: ScenePackage,
        loaded: LoadedAnimations
    ) -> ValidationReport
}
```

**Важно:** используем **тот же `ValidationIssue/ValidationReport`** из PR2 (единый формат). 

---

## 3) Формат `path` для anim issues (фиксируем)

Чтобы не было хаоса, вводим единый путь:

* root: `anim(<animRef>)`
* далее json-path в стиле `.assets[0].p`, `.layers[3].tt`, `.assetsById[image_0]`

Примеры:

* `anim(anim-1.json).fr`
* `anim(anim-2.json).layers[3].tt`
* `anim(anim-1.json).assets[id=image_0].p`

Сообщения — human readable, без stack trace. 

---

## 4) Anim-level validation rules (нормативные)

Ниже — точный список правил, severity, коды и где брать данные. Основано на plan PR3  и Core Spec 3.2 .

### 4.1 FPS invariant (MUST ERROR)

Для каждого `animRef`:

* `scene.canvas.fps MUST == anim.fr`

**Code:** `ANIM_FPS_MISMATCH`
**Path:** `anim(<ref>).fr`
**Message:** `"scene fps=30 != anim fr=25 for anim-1.json"`

### 4.2 Root sanity (MUST ERROR)

* `anim.w>0`, `anim.h>0`, `anim.fr>0`, `anim.op>anim.ip`
  **Code:** `ANIM_ROOT_INVALID`
  **Paths:** `anim(<ref>).w/h/fr/ip/op`

### 4.3 Size mismatch (WARNING)

Если `anim.w/h != input.rect.width/height` → warning.
(На вашем reference package это **ожидаемо**, потому что root comp 1080×1920, а input.rect 540×960. )

**Code:** `WARNING_ANIM_SIZE_MISMATCH`
**Path:** `anim(<ref>).w` (или `.h`) + также можно указать `$.mediaBlocks[i].input.rect` в message
**Message:** `"anim 1080x1920 != inputRect 540x960 (contain policy will apply)"` 

### 4.4 Binding rule (Part 1 strict) (MUST ERROR)

Для каждого блока и его `bindingKey` (default `"media"` если отсутствует) :

В `animRef` MUST существовать **ровно один** слой:

* `ty == 2` (image layer)
* `nm == bindingKey`
* и он MUST ссылаться на image asset через `refId`.

Ошибки:

* если найдено 0 → `BINDING_LAYER_NOT_FOUND`
* если >1 → `BINDING_LAYER_AMBIGUOUS`
* если слой найден, но `ty != 2` → `BINDING_LAYER_NOT_IMAGE`
* если `refId` пуст/нет → `BINDING_LAYER_NO_ASSET`

**Path:**

* `anim(<ref>).layers[*].nm` (или конкретный индекс/asset comp index)
* В message указать bindingKey и найденные кандидаты

**Важно по поиску:** binding-layer может быть внутри precomp asset layers (как в ваших anim-*.json: `assets.comp_0.layers[0].nm="media"`).
Поэтому поиск делаем по:

* root `layers`
* всем `assets[].layers` (precomp definitions)

### 4.5 Asset presence / resolvable (MUST ERROR)

Для каждого image asset:

* если `assets[].p` задан, то файл `rootURL/<u>/<p>` MUST существовать.

**Code:** `ASSET_MISSING`
**Path:** `anim(<ref>).assets[id=<id>].p`
**Message:** `"Missing file images/img_2.png for asset image_0"`

> В reference profile ожидаются `images/img_1.png..img_4.png` — их надо добавить в репо как минимальные png (1×1 достаточно). 

### 4.6 Precomp ref integrity (MUST ERROR)

Если слой `ty==0` (precomp) и имеет `refId`, то в `assets[]` MUST существовать asset с `id == refId` и у него MUST быть `layers`.

**Code:** `PRECOMP_REF_MISSING`
**Path:** `anim(<ref>).layers[i].refId`
**Message:** `"Precomp refId comp_0 not found in assets"`

### 4.7 Minimal “subset scan” на неподдержанное (MUST ERROR)

Задача: заранее поймать то, что Part 1 не сможет отрендерить корректно (или точно не планируем поддерживать).

#### 4.7.1 Layer types

Поддерживаем только:

* `ty ∈ {0,2,3,4}` 

**Code:** `UNSUPPORTED_LAYER_TYPE`
**Path:** `anim(<ref>).layers[i].ty`

#### 4.7.2 Masks

Если у layer есть `masksProperties`:

* `mode MUST == "a"` (add)
* `inv MUST == false`
* `pt.a MUST == 0` (Part 1)
* `o.a MUST == 0` (opacity static)

Коды:

* `UNSUPPORTED_MASK_MODE`
* `UNSUPPORTED_MASK_INVERT`
* `UNSUPPORTED_MASK_PATH_ANIMATED`
* `UNSUPPORTED_MASK_OPACITY_ANIMATED`

Paths:

* `anim(<ref>).layers[i].masksProperties[m].mode`
* etc.

#### 4.7.3 Track matte

* matte source: `td == 1` допустимо
* consumer: `tt == 1` или `tt == 2` допустимо
* другие значения → unsupported

Коды:

* `UNSUPPORTED_MATTE_TYPE`

Path:

* `anim(<ref>).layers[i].tt` / `.td`

#### 4.7.4 Shape items (только как matte source)

Если `ty==4` и `td==1` (matte source shape layer), то внутри `shapes` разрешаем только:

* `gr` group, внутри `it`: `sh`, `fl`, `tr`

Коды:

* `UNSUPPORTED_SHAPE_ITEM`

Paths:

* `anim(<ref>).layers[i].shapes[*].ty`

> В reference package `anim-3` использует `ty=4` как matte source — это MUST пройти. 

---

## 5) Интеграция в App (обязательная)

В `PlayerViewController` pipeline:

1. `package = ScenePackageLoader.load(from:)`
2. `sceneReport = SceneValidator.validate(scene:)` (PR2)
3. Если `sceneReport.hasErrors` → лог и stop
4. `loaded = AnimLoader.loadAnimations(from: package)`
5. `animReport = AnimValidator.validate(scene: package.scene, package: package, loaded: loaded)`
6. Лог:

* “AnimValidation: X errors, Y warnings”
* Все issues построчно `[ERROR] CODE path — message` / `[WARN] …`

7. Если `animReport.hasErrors` → “Animations invalid — rendering disabled”

---

## 6) Unit Tests (обязательные, минимум 20)

Файл: `AnimValidatorTests.swift` (+ отдельные `AnimLoaderTests.swift`)

### 6.1 Loader tests

* `testLoadAnimations_referencePackage_success()`

  * загружает anim-1..4, `lottieByAnimRef.count == 4`
* `testAssetIndex_buildsRelativePaths()` (u+p → images/xxx)
* `testMissingAnimFile_throws()` (использовать temp dir)

### 6.2 Validator happy path

* `testValidate_referencePackage_noErrors()`

  * ошибки = 0
  * warnings допускаются; минимум проверить наличие `WARNING_ANIM_SIZE_MISMATCH` (ожидаем, т.к. anim 1080×1920 vs input 540×960).

### 6.3 FPS mismatch

* подменить `anim.fr` в JSON string → `ANIM_FPS_MISMATCH`

### 6.4 Binding cases

* 0 binding layer → `BINDING_LAYER_NOT_FOUND`
* 2 binding layers → `BINDING_LAYER_AMBIGUOUS`
* binding layer `ty != 2` → `BINDING_LAYER_NOT_IMAGE`
* binding layer без `refId` → `BINDING_LAYER_NO_ASSET`

### 6.5 Asset missing

* удалить `images/img_1.png` → `ASSET_MISSING` 

### 6.6 Unsupported scan

* layer ty=1 → `UNSUPPORTED_LAYER_TYPE`
* mask mode="s" → `UNSUPPORTED_MASK_MODE`
* mask inv=true → `UNSUPPORTED_MASK_INVERT`
* pt.a=1 → `UNSUPPORTED_MASK_PATH_ANIMATED`
* tt=3 → `UNSUPPORTED_MATTE_TYPE`
* shape item ty="st" (stroke) → `UNSUPPORTED_SHAPE_ITEM`

---

## 7) Обязательные изменения в TestAssets

Чтобы `ASSET_MISSING` не падал на reference package, в репо должны быть:

* `TestAssets/ScenePackages/example_4blocks/images/img_1.png`
* `img_2.png`
* `img_3.png`
* `img_4.png` 

Файлы могут быть минимальные 1×1 PNG (содержимое не важно для PR3).

---

## 8) Definition of Done PR3

PR3 принят, если:

* `AnimLoader` декодит `anim-1..4.json` и строит `AssetIndex`
* `AnimValidator`:

  * ловит FPS mismatch как **error** 
  * ловит binding layer и строго проверяет “ровно один”
  * проверяет наличие image assets и репортит `ASSET_MISSING`
  * выдаёт warning на size mismatch
  * делает subset scan (mask/matte/shape) и репортит `UNSUPPORTED_*` на неподдержанное
* На reference package: **0 errors**, warnings допустимы (и ожидаемы по size mismatch)
* UI логирует оба отчёта (SceneValidation + AnimValidation)

---

## A) Матрица покрытия: что именно проверяет PR3 на ваших `anim-1..4.json`

Референс-сцена: `scene.json` — canvas 1080×1920, fps=30, durationFrames=300; 4 блока по 540×960, у всех `bindingKey="media"`, `animRef=anim-1..4.json`, `containerClip="slotRect"`.

### 1) Общие инварианты (для всех anim-1..4)

* `anim.w/h = 1080×1920`, `anim.fr = 30`, `ip=0`, `op=300` — должны проходить root sanity + fps invariant.
* **Size mismatch warning ожидаем всегда**, потому что `input.rect` = 540×960, а `anim` = 1080×1920.
* Binding layer `"media"` находится **внутри precomp asset `comp_0`**, слой `ty=2`, `nm="media"`, `refId="image_0"` — валидатор обязан искать binding не только в root layers, но и в `assets[].layers`.
* В каждом anim есть image asset `id="image_0"` с `u="images/"` и `p="img_N.png"` — нужен check на существование файла.

---

## B) Таблица “какой anim что покрывает” (обязательная для понимания subset scan)

| Anim          | Где binding layer `"media"`                             | Masks                                                                                           | Track Matte                                                       | Shape matte source          | Что PR3 обязан проверить                                                                                                        |
| ------------- | ------------------------------------------------------- | ----------------------------------------------------------------------------------------------- | ----------------------------------------------------------------- | --------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `anim-1.json` | `assets[id=comp_0].layers[0]` (`ty=2`, `refId=image_0`) | ✅ есть `masksProperties` на **binding image-layer** (mode `"a"`, inv=false, pt.a=0, o.a=0)      | ❌                                                                 | ❌                           | mask rules: mode/ inv / no animated pt/o; binding layer поиск внутри assets; assets file exists (`images/img_1.png`)            |
| `anim-2.json` | `assets[id=comp_0].layers[0]`                           | ❌                                                                                               | ✅ `td=1` на shape layer + `tt=1` на consumer (normal alpha matte) | ✅ `ty=4` (shape) **с td=1** | matte rules: tt∈{1,2}, td==1; shape subset для matte source (gr/sh/fl/tr); assets file exists (`img_2.png`)                     |
| `anim-3.json` | `assets[id=comp_0].layers[0]`                           | ❌                                                                                               | ✅ `td=1` + `tt=2` (inverted matte)                                | ✅ `ty=4` (shape) **с td=1** | то же что anim-2 + проверка inverted matte (`tt=2`); assets file exists (`img_3.png`)                                           |
| `anim-4.json` | `assets[id=comp_0].layers[0]`                           | ✅ `masksProperties` на **precomp layer** в root (`ty=0`) (mode `"a"`, inv=false, pt.a=0, o.a=0) | ❌                                                                 | ❌                           | masks должны валидироваться на любом `ty` (не только на image layer), т.е. precomp layer тоже; assets file exists (`img_4.png`) |

Источники по фактам: `anim-1..4.json`.

---

## C) Ожидаемый вывод валидатора PR3 на reference package (строго)

На текущем референсе:

### Errors

* **0 ошибок** (FPS совпадает, binding layer существует, mask/matte в рамках subset).

### Warnings

* **4× `WARNING_ANIM_SIZE_MISMATCH`** (для каждого animRef), потому что `anim 1080×1920` vs `inputRect 540×960`.
* **0 warnings по assets**, если вы добавили `images/img_1..img_4.png` в пакет. (Если картинок нет — это должно быть **ERROR `ASSET_MISSING`**, не warning.)

---

## D) Обязательные правки в TestAssets для PR3 (чтобы не было ложных ошибок)

В вашем пакете сейчас есть ссылки на:

* `images/img_1.png`
* `images/img_2.png`
* `images/img_3.png`
* `images/img_4.png`

**Нужно добавить эти файлы в репозиторий**:

* `TestAssets/ScenePackages/example_4blocks/images/img_1.png..img_4.png`

Файлы могут быть **1×1 PNG** (контент неважен). Важно: чтобы asset existence check работал и PR3 не валился на референсе.

И не забудьте:

* чтобы они попали в **Bundle** для app (через Resources),
* и были доступны тестам (если тесты читают из `Bundle.module` / filesystem).

---

## E) Жёсткие “implementation notes” (чтобы не накосячить)

### 1) Binding-layer поиск обязан проходить precomp assets

Во всех ваших anim-1..4 binding `"media"` находится **не в root layers**, а внутри `assets[id=comp_0].layers[0]`.
**Значит валидатор должен обходить:**

* `anim.layers[]`
* `anim.assets[].layers[]` (только assets где есть `layers`)

И считать кандидаты `ty==2 && nm==bindingKey`.

### 2) Masks проверяются на любом `layer.ty`

`anim-4` показывает маску на `ty=0` (precomp layer) — валидатор не должен предполагать, что mask бывает только на image-layer. 

### 3) Shape subset нужен минимум для matte-source

`anim-2` и `anim-3` matte source — это `ty=4` shape layer с `td=1`, внутри shapes используются `gr/sh/fl/tr`.
Тут важно: **мы не рендерим shapes в PR3**, но должны валидировать, что это не stroke/trim/path-ops и т.п.

### 4) allowedMedia как `[String]` + validation, НЕ `enum` в decode

Так же, как в PR2: если сделать `allowedMedia: [AllowedMediaType]`, то decode будет падать раньше валидатора. Поэтому decode — строками, а валидатор проверяет значения.

---

## F) Ревью-чеклист техлида для PR3 (по нему буду принимать)

1. `AnimLoader` декодит 4 файла и возвращает `LoadedAnimations`.
2. `AnimValidator` даёт **0 errors** на reference package.
3. На reference package есть **ровно 4 warnings size mismatch**.
4. Binding-layer находится в assets `comp_0` — и валидатор это реально видит (есть тест).
5. Masks:

   * mode только `"a"`, inv=false, pt.a=0, o.a=0 (есть тесты на нарушения).
6. Mattes:

   * допускаем `tt=1` и `tt=2`, `td=1` (есть тест на `tt=3` → unsupported).
7. Asset check:

   * удаление `images/img_2.png` в temp package даёт **ERROR `ASSET_MISSING`**.
8. App UI логирует SceneValidation (PR2) + AnimValidation (PR3) и “останавливается”, если есть errors.