# PR-29 — Implicit `tp` Matte Sources + Matte Chains (Release Canonical Spec)

## 0) Контекст и причина

В production-шаблонах (пример: `polaroid_full.json`) встречается валидная топология, где `tp` у matte consumer указывает на слой, который **не помечен `td=1`**, но должен выступать matte source (implicit). Сейчас после PR-27 такой кейс падает в компиляторе с `matteTargetNotSource`. 

Конкретно в `comp_0`:

* `mask` (ind=2) — explicit matte source (`td=1`)
* `plastik` (ind=3) — consumer (`tt=1`, `tp=2`)
* `media` (ind=4) — consumer (`tt=1`, `tp=2`)
* `mediaInput` (ind=5) — consumer (`tt=1`, `tp=3`), но `tp=3` указывает на `plastik`, у которого нет `td=1` 

Это **должно поддерживаться** как “matte chain” и “implicit source by tp”.

---

## 1) Goal

Поддержать matte-связи вида `tp → targetLayer(ind)` даже если target:

* не имеет `td=1`
* сам является matte consumer другого matte (цепочка)

При этом:

* tp-based остаётся приоритетом
* порядок (source раньше consumer по array index) остаётся строгим
* отсутствие target по `tp` остаётся ошибкой
* визуальная семантика: слой-источник, используемый как matte source (explicit или implicit), **не должен рисоваться в основном проходе**, но **должен** рисоваться внутри matte scope.

---

## 2) Definitions

* **Explicit matte source**: слой с `td=1`
* **Implicit matte source**: слой, на который кто-то ссылается через `tp` (target of tp), даже если `td != 1`
* **Matte consumer**: слой с `tt != nil`
* **Matte chain**: matte source сам может быть consumer другого matte (например, `plastik` consumer от `mask`, но одновременно source для `mediaInput`) 

---

## 3) Canonical Runtime/Compiler Semantics

### 3.1 Matte binding (tp-based)

Для каждого consumer слоя `L` с `tt != nil`:

1. Если `tp != nil`:

   * резолвим target по `ind` в пределах текущей composition
   * проверяем `targetArrayIndex < consumerArrayIndex` (строго)
   * устанавливаем `MatteInfo(sourceLayerId: targetLayerId, mode: ...)`
   * помечаем target как **implicit matte source** (если не explicit)

2. Если `tp == nil`:

   * legacy adjacency fallback (как PR-27): предыдущий слой `td=1` → source

### 3.2 Ошибки (tp-ветка)

* `tp` не резолвится в ind → **error** `MATTE_TARGET_NOT_FOUND` (fatal)
* порядок неверный (`targetArrayIndex >= consumerArrayIndex`) → **error** `MATTE_TARGET_INVALID_ORDER` (fatal)
* **НЕ** проверяем `td==1` как обязательное условие для `tp` (больше нет fatal `MATTE_TARGET_NOT_SOURCE` в tp-ветке)

### 3.3 Рендеринг matte sources

Любой слой, который является matte source (explicit `td=1` или implicit `tp-target`), **не рисуется в основном проходе** (draw list), чтобы избежать “двойного” отображения.

Но внутри matte scope слой **обязан** рендериться как источник matte-маски.

### 3.4 Matte chains

Если matte source слой сам является consumer другого matte, при рендере matte scope должны применяться его собственные matte-пары (цепочка должна работать). На примере `polaroid_full.json`: `mediaInput` использует `plastik` как source, а `plastik` сам заматчен `mask`. 

---

## 4) Validator Semantics (Release)

Валидатор должен:

* для `tp`-ветки проверять только:

  * existence target
  * order
* не требовать `td==1` у target для `tp`

Опционально: добавить **warning/info** код (не error) “implicit matte source used” для диагностики пайплайна.

---

## 5) Acceptance Criteria

1. `polaroid_full.json` компилируется без `matteTargetNotSource` и без ошибок matte-валидации (кроме unrelated, например bm=3). 
2. Маттинг цепочки работает корректно:

   * `mediaInput` consumer получает matte source = `plastik` (ind=3)
   * `plastik` корректно использует matte source = `mask` (ind=2)
3. Любой `tp`-target слой не рисуется в main pass (если он является implicit/explicit matte source), но рисуется в matte scope.
4. Ошибки `MATTE_TARGET_NOT_FOUND` и `MATTE_TARGET_INVALID_ORDER` продолжают быть fatal.

---

# Diff-plan по файлам (PR-29)

## A) Production code

### A1) `TVECore/Sources/TVECore/AnimIR/AnimIRCompiler.swift`

**Изменения:**

1. В tp-ветке first pass (где строится `matteSourceForConsumer`):

* удалить проверку `td==1` как условие ошибки `matteTargetNotSource`
* сохранить проверки:

  * `tp` найден по ind
  * порядок array index

2. Собрать `implicitMatteSourceLayerIds`:

* `implicitMatteSourceLayerIds.insert(sourceLayerId)` для каждого `tp`-target

3. Прокинуть в IR признак matte-source-any:

* вариант (рекомендуемый): добавить в LayerIR флаг `isMatteSourceAny` или два флага explicit/implicit (см. A2)
* при сборке слоя выставлять:

  * `isMatteSourceExplicit = (td==1)`
  * `isMatteSourceImplicit = implicitSet.contains(layerId)`
  * `isMatteSourceAny = explicit || implicit`

4. Обновить/удалить error case:

* `AnimIRCompilerError.matteTargetNotSource` больше не должен триггериться для tp-ветки.
* Можно оставить case для обратной совместимости, но он становится “unused” и должен быть удалён/помечен TODO (лучше удалить, чтобы не было мёртвого кода).

---

### A2) `TVECore/Sources/TVECore/AnimIR/AnimIRTypes.swift` (или файл с Layer/LayerIR)

**Добавить поля в Layer representation**, чтобы рендер мог различать:

* `isMatteSourceExplicit: Bool`
* `isMatteSourceImplicit: Bool`
  или минимум:
* `isMatteSource: Bool` (расширить семантику: explicit || implicit)

**Рекомендация TL:** два флага (explicit/implicit) полезны для диагностики, но можно 1 флаг если хотите минимальный diff.

---

### A3) `TVECore/Sources/TVECore/AnimIR/AnimIR.swift`

**Цель:** корректно рендерить implicit sources: не рисовать в main pass, но рендерить в matte scope.

1. В main pass (`renderLayer` или эквивалент):

* текущий guard `guard !layer.isMatteSource else { return }` должен считаться истинным и для implicit sources

  * если внедрили `isMatteSourceAny` → использовать его

2. В matte scope (`emitMatteScope` / рендер источника matte):

* убедиться, что вызов рендера source-слоя **не скипается** тем же guard’ом
* при необходимости: разделить рендер на два пути:

  * `renderLayerMainPass(...)` (скипает matte sources)
  * `renderLayerForMatte(...)` (НЕ скипает matte sources)

3. Поддержать matte chain:

* рендер source-слоя в matte scope должен идти через тот же pipeline, который применяет matte к source-слою, если он consumer другого matte (как `plastik`). 

---

### A4) `TVECore/Sources/TVECore/AnimValidator/AnimValidator.swift`

**Изменения:**

1. В `validateMattePairs` tp-ветке:

* убрать “target must be td==1” как error
* оставить:

  * `MATTE_TARGET_NOT_FOUND`
  * `MATTE_TARGET_INVALID_ORDER`

2. `MATTE_TARGET_NOT_SOURCE`:

* больше не эмитить в tp-ветке
* можно оставить для legacy adjacency (если там вообще требуется), но если не используется — удалить.

---

### A5) `TVECore/Sources/TVECore/AnimValidator/AnimValidationCode.swift`

**Изменения:**

* `MATTE_TARGET_NOT_SOURCE`:

  * либо оставить (но не использовать для tp)
  * либо удалить
* (опционально) добавить warning:

  * `MATTE_TARGET_IMPLICIT_SOURCE` (severity warning/info)

TL-рекомендация: добавить warning полезно для пайплайна, но не обязательно для релиза.

---

## B) Tests

### B1) Новый test fixture

Добавить `polaroid_full.json` как golden fixture в тестовые ресурсы (уже у вас есть файл). 

### B2) Новые тесты (обязательно)

Новый файл: `TVECore/Tests/TVECoreTests/ImplicitMatteSourcesTests.swift`

Тесты:

1. `testCompiler_tpTargetWithoutTd_isAccepted_andBecomesImplicitSource`

   * синтетика: tp → target без td
   * assert: consumer.matte.sourceLayerId == targetId
   * assert: targetLayer.isMatteSourceImplicit == true (или isMatteSource == true)

2. `testCompiler_matteChain_tpTargetIsConsumer_itself_compiles`

   * синтетика: A consumer of mask, and B uses A as tp source

3. `testGoldenFixture_polaroidFull_compilesMatteChain`

   * компилируем `polaroid_full.json`
   * assert: нет ошибки `matteTargetNotSource`
   * assert: у `mediaInput` matte source = `plastik`
   * assert: у `plastik` matte source = `mask`

4. `testValidator_tpTargetWithoutTd_noError`

   * валидатор не выдаёт `MATTE_TARGET_NOT_SOURCE` для tp

5. Негативные тесты (сохранить строгие ошибки):

   * `tp target not found` → error
   * `tp invalid order` → error

---

## C) Migration notes (для PR description)

* Контракт PR-27 “tp target должен быть td=1” отменён как несовместимый с production экспорта.
* Новая политика: `tp` допускает implicit sources.
* Это расширение не ломает старые сцены (explicit td=1 продолжает работать).

---

# Дополнительная заметка (не часть PR-29, но важно)

В `polaroid_full.json` присутствует `bm=3` (blend mode Screen) на `plastik`. Валидатор сейчас считает blend mode ≠ 0 ошибкой, значит для запуска в AnimiApp нужно либо:

* временно выставить `bm=0` в тестовом пакете, либо
* отдельно делать PR на поддержку/понижение severity blend modes.

Это **не относится** к PR-29 и не должно смешиваться со scope matte. 

---

Если нужно, я могу сразу оформить короткий “PR-29 GitHub description” (Motivation / Changes / Tests / Risk) на базе этого ТЗ.
