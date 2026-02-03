Да, сейчас самое время **сделать “cleanup PR” отдельной задачей**: ваш новый контракт уже закреплён тестами, значит можно безопасно вычищать хвосты, не боясь сломать поведение.

Ниже — как правильно подойти и **какую задачу поставить программисту**, без воды.

---

## Как правильно чистить legacy: стратегия “2 PR”

### PR-A (уже сделан): функциональные изменения + тесты

Он у вас есть: edit = no-anim full render, override clip, фиксы mediaInputPath, userTransform и т.д.

### PR-B (новая задача): **только удаление/упрощение**, без изменения поведения

Это критично: cleanup не должен снова менять семантику.
Мы опираемся на текущие тесты (`758 tests`) как “страховку”.

---

## Задача для программиста: “TVECore Legacy Cleanup after Edit/No-Anim Refactor”

**Цель:** удалить устаревший/мёртвый код, который больше не используется после перехода на:

* edit mode = full render `no-anim` variant
* `InputClipOverride` как блоковый клип для anim-variants
* mediaInputPath/mediaInputWorldMatrix = общие helpers + правильные tangent transforms

**Запрет:** не менять публичное поведение и формат данных (scene.json, no-anim контракт). Только cleanup, re-org, и небольшие refactors, которые не меняют логику.

---

## Что конкретно чистим (по смысловым блокам)

### 1) Удалить “двойные” API/ветки, которые были нужны для старого edit режима

Проверьте по проекту, но обычно после ваших PR уже должно быть удалено:

* любые ветки “editInputsOnly / binding-only traversal”
* любые helper’ы вида `renderEdit...`, `emitEdit...`, `compContainsBinding...` (если что-то осталось)
* любые док-комменты и naming, которые до сих пор говорят “edit = binding only”

**Acceptance:** в коде не осталось упоминаний прежней модели edit mode.

---

### 2) Консолидировать вычисление mediaInput transform/path в одно место

Сейчас вы уже сделали:

* `computeMediaInputComposedMatrix`
* `computeMediaInputComposedMatrixForRootSpace`
* `resolvePrecompChainTransform`
* `mediaInputInCompWorldMatrix`
* `mediaInputPath` через `basePath.applying()`

Задача cleanup PR:

* **убрать любые альтернативные/дублирующие способы** вычислять mediaInput матрицы и пути (если остались).
* убедиться, что:

  * hit-test/overlay используют **root space**
  * clip override использует **in-comp space**
  * render clip (когда inputGeometry есть) использует **in-comp** (stack уже содержит precomp chain)

**Acceptance:** нет “второй реализации” mediaInput path/матриц в других местах.

---

### 3) Привести “контракт mediaInput” к единому месту в коде

Сейчас “mediaInput only in no-anim” задекларирован в:

* compile-time validation (ScenePlayer.compileBlock)
* runtime behavior (InputClipOverride)
* тесты

Cleanup PR должен:

* собрать все “контрактные” doc-comments в **одно место** (например, рядом с компиляцией/валидацией или в `ScenePlayerTypes`), а не размазывать по AnimIR.
* убрать устаревшие комментарии, которые подразумевают, что mediaInput живёт в каждом варианте.

**Acceptance:** есть один канонический комментарий “PR-xx контракт” и нет противоречий.

---

### 4) Упростить SceneRenderPlan и RenderContext после стабилизации

Теперь у вас в рендере есть:

* `inputGeometry`
* `inputClipOverride`
* `userTransform`

Cleanup PR:

* проверить, нет ли ещё “legacy параметров” в цепочке `renderCommands` (например, старые аргументы, которые больше нигде не используются).
* если есть устаревшие поля контекста или параметры, которые всегда `.identity` / всегда nil — удалить.

**Acceptance:** `RenderContext` минимален, только то, что реально нужно.

---

### 5) Удалить “fallback поведение”, которое теперь считается невозможным — но только под DEBUG

Например: сейчас override строится “best effort”.
По контракту он должен быть всегда, иначе сцена невалидна.

Правильный cleanup:

* в релизе оставить safe fallback (не крэшить приложение),
* но в DEBUG добавить `assertionFailure` / `preconditionFailure` **в тех местах**, где контракт нарушен (например, если anim variant без inputGeometry и override == nil).

**Acceptance:** контрактные нарушения ловятся в debug, но релиз не падает.

---

## Чёткие критерии готовности (Definition of Done)

1. Все тесты проходят (те же `758 tests`, 0 failures).
2. Удалён мёртвый код старого edit traversal и любые неиспользуемые helpers.
3. Поиск по репо не находит устаревших ключевых строк (типа `renderEdit`, `editInputsOnly`, `compContainsBinding` и т.п. — по факту вашего текущего дерева).
4. Никаких изменений в форматах `scene.json` / `no-anim.json`.
5. Никаких изменений в UI/behavior (ручная проверка: preview/edit, hit-test, overlays, клип, userTransform).

---

## Как сформулировать задачу одной карточкой (готовый текст)

**Title:** TVECore Cleanup: remove legacy edit-mode code & consolidate mediaInput pipeline
**Goal:** Remove dead/legacy code after перехода на edit=no-anim + InputClipOverride, без изменения поведения.
**Scope:**

* удалить оставшиеся edit-specific traversal/ветки/комменты
* консолидировать mediaInput matrix/path logic (одна реализация)
* минимизировать RenderContext/SceneRenderPlan сигнатуры
* добавить DEBUG asserts на нарушение контракта override/no-anim
  **DoD:** tests green, no behavior changes, no format changes.

---

Если ты хочешь, я могу сделать ещё жёстче: “что именно grep’ать и какие файлы точно должны поменяться” — но это уже зависит от текущего состояния репозитория после последнего PR.
