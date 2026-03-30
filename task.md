**PR D: Residual Regression Tests For Hydration / Placement / Gesture Lifecycle**

**Цель**  
PR D больше не про архитектурный рефакторинг. После PR A + PR B + PR C система уже собрана.  
Каноничный scope PR D по текущему реальному коду: **закрыть оставшиеся regression gaps тестами**, без нового product/refactor scope.

**Текущее реальное состояние**
- Load-boundary hydration уже живет в [ProjectDraftHydrator.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Project/ProjectDraftHydrator.swift).
- Единственный engine-side hydration path для inactive scenes уже в [TimelineCompositionEngine.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/TimelineComposition/TimelineCompositionEngine.swift#L172).
- `isNearDefault` уже добавлен в [MediaPlacementState.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Project/MediaPlacementState.swift#L55).
- `SceneRuntimeStateApplier` order-тесты уже усилены в [SceneRuntimeStateApplierTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/SceneRuntimeStateApplierTests.swift).
- Значит PR D должен быть **маленьким test-lockdown PR**, а не новым системным переписыванием.

**Что реально осталось незакрытым**
1. Нет явного теста `variant switch preserves placement` при action [setBlockVariant](\
/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/Store/EditorReducer.swift#L788).
2. Нет теста на `duplicate scene` для **legacy un-hydrated SceneState** при [duplicateScene](\
/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/Store/EditorReducer.swift#L472) с последующей hydration через [ProjectDraftHydrator.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Project/ProjectDraftHydrator.swift).
3. Нет controller-level теста на simultaneous gesture lifecycle в [SceneEditInteractionController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/SceneEdit/SceneEditInteractionController.swift), особенно на ветку `sessionHadCancellation`.
4. Нет явного regression test-а на cold-cache hydration path в [TimelineCompositionEngine.updateSceneState(...)](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/TimelineComposition/TimelineCompositionEngine.swift#L172).

## Scope

### 1. Variant Switch Preserves Placement
**Файл:** [MediaPlacementReducerTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/MediaPlacementReducerTests.swift)

Добавить тест:
- `test_setBlockVariant_preservesMediaPlacement`

Сценарий:
- собрать `EditorState` с media slot и non-default `MediaPlacementState`
- dispatch `.setBlockVariant(sceneInstanceId:blockId:variantId:)`
- проверить:
  - `variantOverrides[blockId]` обновился
  - `slot.asset.placement` не изменился ни по `fitMode`, ни по `offset`, ни по `scale`, ни по `rotation`
  - `shouldPushSnapshot == true`

Почему именно тут:
- этот файл уже является каноничным набором reducer/regression тестов для media placement contract
- логика variant update сейчас действительно трогает только `sceneState.variantOverrides` в [EditorReducer.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/Store/EditorReducer.swift#L800)

### 2. Duplicate Legacy Un-Hydrated State Then Hydrate
**Файл:** [ProjectDraftHydratorTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/ProjectDraftHydratorTests.swift)

Добавить тест:
- `test_duplicateLegacyUnhydratedScene_hydratesOriginalAndDuplicate`

Сценарий:
- создать draft с одной сценой, у которой:
  - media slot есть
  - `slot.asset.placement == nil`
  - legacy `userTransforms[blockId]` присутствует
- прогнать duplicate через reducer `.duplicateScene(sceneItemId:)`
- до hydration проверить:
  - у original и duplicate состояние все еще legacy
  - duplicate получил verbatim copy `SceneState`
- затем прогнать hydrated draft через [ProjectDraftHydrator.hydrate(...)](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Project/ProjectDraftHydrator.swift#L31)
- после hydration проверить:
  - и original, и duplicate имеют non-nil `placement`
  - `userTransforms` очищены у обоих
  - fitMode взят из template `defaultFit`
  - `changedInstanceIds` содержит оба instance id

Почему именно тут:
- этот файл уже содержит реальные helpers для mini compiled scene packages
- test должен проверять связку `duplicateScene -> hydrator`, а не только reducer в отрыве

### 3. SceneEditInteractionController Lifecycle Regression
**Новый файл:** [SceneEditInteractionControllerTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/SceneEditInteractionControllerTests.swift)

Тестировать нужно именно controller, а не только [PlacementGestureSession.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/SceneEdit/PlacementGestureSession.swift).

Базовый harness:
- `getUIMode = { .sceneEdit(sceneInstanceId: someId) }`
- `getSelectedBlockId = { "block1" }`
- `getBaselinePlacement = { _ in baselinePlacement }`
- `getScenePlayer = { nil }`
  - это допустимо, потому что [isTransformAllowed(...)](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/SceneEdit/SceneEditInteractionController.swift#L256) в этом случае возвращает `true`
- `onPlacementChanged` пишет события в массив

Обязательные тесты:
- `test_simultaneousPanAndPinch_firstEnded_emitsChanged_notTerminal`
  - pan `.began`
  - pinch `.began`
  - pan `.changed`
  - pinch `.changed`
  - pan `.ended`
  - проверить, что terminal phase еще не было, а пришел только `.changed`
  - pinch `.ended`
  - только теперь приходит финальный `.ended`

- `test_simultaneousPanAndPinch_oneCancelled_finalTerminalCancelled`
  - pan `.began`
  - pinch `.began`
  - изменения по обоим
  - pan `.cancelled`
  - убедиться, что немедленного terminal apply нет, пока pinch еще активен
  - pinch `.ended`
  - финальное событие должно быть `.cancelled`
  - финальный placement должен равняться `baseline`, а не mid-gesture state

- `test_simultaneousSession_emitsBeganOnlyOnce`
  - несколько recognizer-ов в одной session
  - `.began` должен прийти ровно один раз

Почему нужен новый файл:
- сейчас нет controller-level test file для [SceneEditInteractionController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/SceneEdit/SceneEditInteractionController.swift)
- это отдельный lifecycle contract, не покрываемый session-only math tests

### 4. TimelineCompositionEngine Cold Hydration Regression
**Новый файл:** [TimelineCompositionEngineHydrationTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/TimelineCompositionEngineHydrationTests.swift)

Тестировать нужно именно текущий cold-path в [TimelineCompositionEngine.updateSceneState(...)](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/TimelineComposition/TimelineCompositionEngine.swift#L172), где engine:
- сначала ищет warm cache
- потом делает `preloadMetadata(sceneTypeId:)`
- потом гидратирует через `CompiledSceneMediaInputProvider`
- вызывает `onSceneStateHydrated`

Обязательные тесты:
- `test_updateSceneState_coldCache_preloadsMetadata_andHydrates`
  - cache пустой
  - `sceneURLProvider` настроен на реальный temp scene package
  - `sceneStates` содержит nil-placement state
  - после `await engine.updateSceneState(...)`:
    - `engine.sceneStates[instanceId]` уже hydrated
    - `placement` non-nil
    - `onSceneStateHydrated` fired
    - state больше не требует hydration

- `test_updateSceneState_metadataPreloadFailure_leavesStateUnchanged`
  - cache пустой
  - `sceneURLProvider` указывает на missing/invalid package
  - после `await engine.updateSceneState(...)`:
    - `sceneStates[instanceId]` остается исходным legacy state
    - `onSceneStateHydrated` не fired
    - тест проверяет failure tolerance, не лог capture

Harness:
- использовать существующий internal init `TimelineCompositionEngine(...)` с injected `resourcesCache` и `runtimeFactory`
- runtimeFactory может возвращать минимальный `SceneInstanceRuntime`, runtime создавать не нужно загруженным
- для scene package helpers можно либо:
  - локально продублировать минимальные helpers из [ProjectDraftHydratorTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/ProjectDraftHydratorTests.swift)
  - либо вынести их в маленький test-only helper file, **только если это реально сокращает дублирование**, без большого fixture refactor

## Что НЕ входит в PR D
- не менять production behavior preview/export/runtime
- не трогать [ProjectDraftHydrator.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Project/ProjectDraftHydrator.swift)
- не трогать [TimelineCompositionEngine.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/TimelineComposition/TimelineCompositionEngine.swift) кроме минимального testability seam, если вдруг без него нельзя
- не трогать gesture math в [PlacementGestureSession.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/SceneEdit/PlacementGestureSession.swift)
- не открывать новый архитектурный PR
- не менять audio scope

## Изменяемые файлы
- [MediaPlacementReducerTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/MediaPlacementReducerTests.swift)
- [ProjectDraftHydratorTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/ProjectDraftHydratorTests.swift)
- [SceneEditInteractionControllerTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/SceneEditInteractionControllerTests.swift) — новый
- [TimelineCompositionEngineHydrationTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/TimelineCompositionEngineHydrationTests.swift) — новый
- [project.pbxproj](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp.xcodeproj/project.pbxproj) — только для добавления новых test files

## Критерии приемки
- Все существующие тесты остаются зелеными
- Новые тесты закрывают 4 реальных незакрытых regression gap-а
- PR D не вносит новый product scope
- PR D не меняет persisted contract
- PR D не возвращает legacy behavior
- После PR D оставшийся backlog уже не архитектурный, а только точечный functional hardening при реальных багах

## Порядок выполнения
1. добавить `variant switch preserves placement`
2. добавить `duplicate legacy -> duplicate -> hydrate both`
3. добавить `SceneEditInteractionController` lifecycle tests
4. добавить `TimelineCompositionEngine.updateSceneState` cold hydration tests
5. прогнать полный suite

**Итог:** каноничный PR D по текущему реальному коду — это **чистый regression-lock PR на тесты**, без нового рефакторинга системы.