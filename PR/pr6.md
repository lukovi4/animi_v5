Ниже — **“железобетонное” ТЗ для PR6** (Nested precomp inheritance & transform propagation correctness). Цель — закрыть классическую ошибку “забыли rootParentTransform при входе в nested precomp” и гарантировать корректное наследование **transform/opacity/visibility + masks/mattes** при любой глубине вложенности precomp. 

---

## PR6 — Nested Precomp Inheritance & Transform Propagation Correctness

### 0) Контекст и границы PR

**Что уже есть (к PR5):**

* AnimIR умеет: sampling transform tracks (p/s/r/a/o), visibility `[ip, op)`, parenting worldMatrix/opacity, precomp `st` mapping (childFrame = frame - st), генерация RenderCommand (без Metal). 
* Поддержка masks/mattes на уровне контрактов и парсинга/валидации Lottie subset уже есть (masksProperties, td/tt, shapes gr/sh/fl/tr). 

**Границы PR6 (важно):**

* **НЕ делаем Metal / реальный рендер**.
* **НЕ меняем Scene.json / SceneValidator**.
* Работаем только в TVECore: **AnimIRCompiler + AnimIR.renderCommands + тестовые ассеты/тесты**.
* Итог проверяем через **детерминированные команды + матрицы/opacity**, а не пиксели.

---

## 1) Цель PR6 (Definition of Goal)

### 1.1 Главная цель

Сделать так, чтобы `ty=0` (precomp layer) **логически разворачивался в render tree** с корректным наследованием:

* `parentWorldMatrix/parentWorldOpacity` от контейнера (вложенного precomp-слоя),
* `st` сдвигов на каждом уровне,
* masks/mattes, заданных на уровне precomp-слоя, применялись ко всему содержимому вложенной композиции.

Ключевое: **не “забывать” transform контейнера при входе в nested comp**. 

### 1.2 Что именно считаем “корректностью”

Для любого кадра `frameIndex`:

1. **Frame mapping**: при входе в precomp-слой кадр для детей считается как:

* `childFrame = parentFrame - layer.st` (на каждом уровне рекурсии) (у вас уже было; надо, чтобы работало на N уровнях). 

2. **Visibility**: если precomp-слой невидим по `[ip, op)` — **не рендерим весь его subtree**. 
3. **Transform propagation**: worldMatrix каждого слоя внутри вложенной композиции =
   `containerWorldMatrix * worldMatrixWithinComp` (где `worldMatrixWithinComp` уже включает parenting внутри той композиции).
4. **Opacity propagation**: `worldOpacity = containerWorldOpacity * opacityWithinComp`.
5. **Masks on precomp-layer**: masksProperties на precomp-слое должны **оборачивать весь subtree** и иметь ту же transform-область, что и контент. 
6. **Mattes around precomp-layer consumer**: если consumer `tt=1|2` — matte применяется ко **всему результату subtree** (даже если внутри есть ещё precomp). 

---

## 2) Архитектурные требования (без лишнего переизобретения)

### 2.1 Render traversal API (внутренняя рекурсия)

Внутри `AnimIR.renderCommands(frameIndex:)` добавить/финализировать внутреннюю рекурсивную функцию вида:

* `renderComposition(compId:, frame:, containerWorld:, containerOpacity:, …)`

Где:

* `containerWorld: Matrix2D` — базовая матрица от “внешнего” precomp-слоя (по умолчанию identity),
* `containerOpacity: Double` — базовая opacity (по умолчанию 1).

**Правило умножения:**

* Для каждого слоя вычисляете `layerWorldWithinComp` (с учётом parenting в этом comp),
* Затем итоговая: `layerWorldFinal = containerWorld * layerWorldWithinComp`.

> Важно: это отдельная ось от parenting. Parenting — внутри композиции; containerWorld — сверху по цепочке вложенности.

### 2.2 Parenting внутри вложенной композиции

Текущая логика resolveParentChain остаётся, но применяется **в пределах одной композиции** (layerById для данной composition).

Ошибки parent chain (PARENT_NOT_FOUND / PARENT_CYCLE) — как вы уже сделали в PR5:
**skip layer + report issue** (не ломаем API) — оставить как есть.

### 2.3 Precomp ref resolution

* `ty=0` layer содержит `refId` на asset-композицию. 
  Нужно гарантировать:

1. refId резолвится в `assets` и даёт composition layers.
2. При рендере subtree используется **тот же pipeline**, что у root.

### 2.4 Защита от циклов precomp

Добавить **cycle detection** для precomp-дерева (на уровне `AnimIRCompiler` и/или runtime traversal):

* Если обнаружили цикл `comp_A -> comp_B -> … -> comp_A`, то:

  * subtree этого слоя **не рендерим**
  * репортим issue (severity: error) с понятным path (`animRef/.../refId`) и frameIndex.

Формат issue должен соответствовать уже принятому виду `code/message/path/severity`. 

**Коды (стабильные) для PR6:**

* `PRECOMP_CYCLE` (error)
* `PRECOMP_ASSET_NOT_FOUND` (error) — если по какой-то причине это проскочило мимо AnimValidator/loader.

---

## 3) Порядок команд и scoping (самое критичное)

### 3.1 Общий паттерн генерации команд для слоя

Для каждого “renderable” слоя (включая precomp consumer):

* `BeginGroup(layerId)`

  * `PushTransform(layerWorldFinal)`

    * (опционально) маски слоя (BeginMaskAdd…EndMask) — **оборачивают весь контент слоя**
    * (опционально) matte wrapper — **оборачивает весь контент слоя/поддерева**
    * контент:

      * если image layer: `DrawImage(assetId, opacityFinal)`
      * если precomp layer: renderComposition(childComp, childFrame, containerWorld: layerWorldFinal, containerOpacity: opacityFinal)
  * `PopTransform`
* `EndGroup`

**Маски precomp-layer** должны оборачивать **renderComposition** внутри той же transform-области.

### 3.2 Matte + precomp subtree

Если слой — consumer с `tt=1|2`, то matte применяется к результату слоя (image или precomp subtree):

* wrapper должен оборачивать subtree полностью.

В тестах это должно проявиться тем, что:

* `BeginMatte...` стоит “над” precomp subtree,
* matte source itself **не рисуется напрямую** (как уже сделано в PR4/PR5 концептуально).

---

## 4) Тестовые ассеты PR6 (обязательные)

Текущий reference package (anim-1..4) почти без вложенности (там root ty=0 → comp_0 → image). 
Для PR6 добавляем **новый пакет/анимацию специально под nested precomp**.

### 4.1 Новая тестовая анимация: `anim-nested-1.json`

Путь:

* `TestAssets/Anims/anim-nested-1.json` (или `TestAssets/ScenePackages/...` — на выбор, но стабильно и очевидно)

Состав (минимальный, но показательный):

* root comp (w/h/fr как у остальных, 1080×1920, fr=30).
* assets:

  * `comp_outer` (layers: содержит `ty=0` на `comp_inner`)
  * `comp_inner` (layers: содержит image layer `nm="media"` и **НЕ** identity transform: anchor != position или rotation != 0 или scale != 100)
  * image asset (img_1.png или отдельный, но лучше отдельный `img_nested.png`).

Root layers:

* `ty=0` precomp-layer на `comp_outer` с **явным** non-identity transform (position offset + rotation/scale).
* На этом root precomp-layer добавить **masksProperties mode="a"** (static path) — чтобы проверить mask-propagation на subtree. (как в anim-1/anim-4) 
* (опционально, но рекомендую) добавить рядом matte source + consumer:

  * matte source `ty=4` (shape) `td=1`
  * consumer = наш precomp-layer `tt=1` или `tt=2` (тогда precomp subtree должен быть заматчен) 

### 4.2 Новые картинки (если надо)

* `TestAssets/images/img_nested.png` (можно 1×1 placeholder как в PR3)

---

## 5) Юнит-тесты PR6 (обязательные и конкретные)

Создать файл:

* `TVECore/Tests/TVECoreTests/NestedPrecompPropagationTests.swift`

### 5.1 Тест 1 — Nested transform multiplication

**Given:** компилим `anim-nested-1.json` → `AnimIR`
**When:** `renderCommands(frameIndex: X)` на фиксированном кадре (например 0 или 30)
**Then:**

* Находим `DrawImage` для bindingKey “media”.
* Находим ближайший к нему `PushTransform(matrix)` (или тот, который применяется на draw, по вашему контракту).
* Проверяем, что `matrix != identity`.
* Проверяем **точное** равенство (или почти равенство по epsilon) матрицы:

  * `M_expected = M_rootPrecompLayer * M_outerInnerPrecompLayer * M_imageLayerLocal`
    (порядок ровно как в вашем Matrix2D contract из PR5).

### 5.2 Тест 2 — st mapping на двух уровнях

Сделать так, чтобы:

* root precomp-layer имеет `st = 10`
* inner precomp-layer (в comp_outer) имеет `st = 20`

**Проверка:**

* При `frameIndex = 35` у image layer должны семплиться keyframes как будто `localFrame = 35 - 10 - 20 = 5`.
* Для проверки — задайте в inner image opacity keyframes (например 0→100 на t=0..10) и проверьте ожидаемое значение на кадре 35.

### 5.3 Тест 3 — visibility cutoff на контейнере

* root precomp-layer `ip=30`
* при `frameIndex=0..29` **не должно быть** `DrawImage("media")` вообще.
* при `frameIndex=30` — должно появиться.

### 5.4 Тест 4 — mask on precomp-layer wraps subtree

Если в root precomp-layer есть `masksProperties`:

* команда `BeginMaskAdd` должна присутствовать,
* и `DrawImage(media)` должен находиться **между BeginMaskAdd и EndMask** (в корректной вложенности).

### 5.5 Тест 5 — matte wraps precomp subtree (если включили matte в anim-nested-1)

* consumer layer — precomp subtree с `tt=1` или `tt=2` 
* проверить, что `BeginMatteAlpha` (или inverted) стоит **над** subtree, и `DrawImage(media)` находится внутри matte scope.

### 5.6 Тест 6 — precomp cycle detection

Добавить маленький JSON (inline в тесте или отдельный файл `anim-precomp-cycle.json`):

* assets: comp_A включает layer ty=0 refId=comp_B
* comp_B включает layer ty=0 refId=comp_A

**Ожидание:**

* `renderCommands` не падает,
* `lastRenderIssues` содержит `PRECOMP_CYCLE` (severity error),
* `DrawImage` отсутствует.

---

## 6) Изменения в коде (по файлам)

### 6.1 AnimIRCompiler

* Убедиться, что компилирует compositions рекурсивно и строит корректные ссылки `CompID -> Composition`.
* Добавить precomp-cycle detection (на этапе компиляции **или** runtime traversal, но лучше компиляция).
* Если cycle — либо fail compilation (throw), либо компилировать, но помечать comp как invalid.
  **Рекомендация для Part 1:** не падать на runtime; лучше ошибка компиляции (throw) с code `PRECOMP_CYCLE`.

### 6.2 AnimIR.renderCommands

* Реализовать рекурсивный обход composition tree с параметрами `containerWorld/containerOpacity`.
* В месте обработки `ty=0`:

  * вычислить `layerWorldFinal/layerOpacityFinal`
  * посчитать `childFrame = frame - st`
  * вызвать `renderComposition(childComp, childFrame, layerWorldFinal, layerOpacityFinal)`

### 6.3 RenderIssue (если используется)

* Добавить новые коды:

  * `PRECOMP_CYCLE`
  * `PRECOMP_ASSET_NOT_FOUND`

---

## 7) Definition of Done (DoD) PR6

PR6 считается принятым, если:

1. **Nested precomp transform propagation работает** (по тестам 5.1–5.3).
2. **Masks на precomp-layer корректно оборачивают subtree** (тест 5.4).
3. **Mattes корректно оборачивают subtree** (если включено в test asset) (тест 5.5) — логика должна соответствовать правилам td/tt. 
4. **Cycle detection**: тест 5.6 проходит, нет крэшей, issue репортится.
5. Все тесты + SwiftLint зелёные.

---

## 8) Мини-правило для программиста (чтобы не было “двойного transform”)

**Запрет:** нельзя одновременно:

* “впихивать” containerWorld в children через “предмультипликацию” матриц при компиляции,
* и ещё раз домножать containerWorld во время renderCommands.

Выбираем **один** путь:

* либо flatten при компиляции,
* либо рекурсивно домножать при генерации команд.

В PR6 — **предпочтение: рекурсивный runtime traversal** (минимальные изменения, проще тестировать, ближе к контракту). 

---

Если хочешь — я могу дополнительно прямо “словами кода” описать **ожидаемую структуру anim-nested-1.json** (assets/layers поля, какие значения поставить для st/ip/op/ks), чтобы программист вообще не тратил время на догадки.
