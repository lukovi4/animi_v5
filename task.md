**Техническое задание**

**Цель**
Исправить логику timeline selection так, чтобы сцена становилась активной только после явного выбора пользователя, а не автоматически от одного лишь положения playhead.

Итоговое продуктовое поведение должно быть таким:
- если пользователь ничего не выбрал, движение timeline / scrub / playback не активирует сцены автоматически
- если пользователь явно выбрал сцену, включается follow-режим, и дальше active scene может меняться вслед за playhead
- если пользователь снял выделение, follow-режим выключается
- нижний navbar должен переключаться по факту явного выбора, а не по одному лишь playhead

---

**Что сейчас неправильно по реальному коду**
Сейчас код реализует другую архитектуру: в `timeline mode` selection автоматически выводится из playhead.

Это зашито в нескольких местах:
- [EditorState.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/Store/EditorState.swift#L104) содержит helper `activeSceneIdAtPlayhead()` и [EditorState.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/Store/EditorState.swift#L115) `timelineSelectionForCurrentPlayhead()`, который всегда мапит playhead в `.scene(...)`
- [EditorReducer.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/Store/EditorReducer.swift#L52) в `.setPlayhead` автоматически пересчитывает `selection` из playhead
- [EditorReducer.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/Store/EditorReducer.swift#L229) `loadProject` сразу активирует первую сцену на frame 0
- [EditorReducer.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/Store/EditorReducer.swift#L918) `exitSceneEdit` тоже всегда нормализует selection из playhead
- [EditorStore.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/Store/EditorStore.swift#L283) `restoreNormalizedSnapshot` принудительно делает то же самое после undo/redo
- [TimelineView.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/TimelineView.swift#L224) tap по сцене уже переведён на `focusScene`
- [TimelineView.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/TimelineView.swift#L835) tap по audio/empty space всё ещё идёт через `.selection(.audio/.none)`
- [EditorLayoutContainerView.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/EditorLayoutContainerView.swift#L658) нижний bar сейчас принудительно всегда показывает `TimelineModeActionBar`
- [TimelineModeActionBar.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/TimelineModeActionBar.swift) был добавлен именно под неверную модель “scene always selected by playhead”

Это и есть legacy, которое надо убрать.

---

**Каноническая архитектура**
В `timeline mode` должны существовать **два разных понятия**, которые сейчас смешаны:

1. `scene under playhead`
- чисто вычисляемое состояние
- зависит только от `playheadCompressedFrame`
- не означает автоматически, что сцена selected

2. `explicit scene selection mode`
- пользовательский режим
- включается только после явного выбора сцены
- пока он включён, selection может follow-ить playhead
- после clear selection он выключается

Каноническая модель:
- `playhead` сам по себе не выбирает сцену
- выбор сцены должен быть user-driven
- auto-follow scene selection работает только после явного scene tap
- clear selection или audio selection выключают follow mode

---

**Новая state-модель**
В [EditorState.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/Store/EditorState.swift) нужно добавить отдельное timeline UI state для режима scene-follow.

Канонический вариант:
```swift
public enum TimelineSceneSelectionMode: Equatable, Sendable {
    case inactive
    case followPlayhead
}
```

И добавить в `EditorState`:
```swift
public var timelineSceneSelectionMode: TimelineSceneSelectionMode
```

Инварианты:
- если `timelineSceneSelectionMode == .followPlayhead`, то `selection` обязан быть `.scene(id: ...)`
- если `selection == .none` или `selection == .audio`, то `timelineSceneSelectionMode` обязан быть `.inactive`
- `uiMode == .sceneEdit(...)` не меняет смысл этого флага, но timeline-specific пересчёты не должны происходить в `sceneEdit`

---

**Правильные helper-ы**
В [EditorState.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/Store/EditorState.swift) нужно оставить только pure helper для сцены под playhead, но убрать helper, который напрямую превращает это в selection.

Сделать так:
- переименовать `activeSceneIdAtPlayhead()` в что-то нейтральное и точное, например `sceneIdAtPlayhead()`
- удалить `timelineSelectionForCurrentPlayhead()`, потому что он кодирует неправильную архитектуру

Причина:
- “scene at playhead” и “selected scene” больше не одно и то же

---

**Изменения в reducer**
Файл: [EditorReducer.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/Store/EditorReducer.swift)

1. `loadProject`
- больше не выбирать первую сцену автоматически
- initial state должен быть:
  - `selection = .none`
  - `timelineSceneSelectionMode = .inactive`
  - `playheadCompressedFrame = 0`

2. `.setPlayhead`
- clamp оставить как есть
- но selection менять **только если**
  - `uiMode == .timeline`
  - `timelineSceneSelectionMode == .followPlayhead`
- в этом случае selection должен стать `.scene(id: sceneAtPlayhead)`
- если `timelineSceneSelectionMode == .inactive`, `.setPlayhead` не должен трогать selection вообще

3. `.focusScene(sceneId:)`
- сохранить как единственный канонический scene-tap action
- он должен:
  - найти сцену
  - перевести playhead на её boundary start
  - выставить `selection = .scene(id: sceneId)`
  - выставить `timelineSceneSelectionMode = .followPlayhead`
- selection тут должна ставиться явно, а не через старый helper “selection from playhead”

4. `.select(.none)`
- должен очищать selection
- должен выставлять `timelineSceneSelectionMode = .inactive`

5. `.select(.audio)`
- должен оставаться допустимым explicit selection path
- должен выставлять `timelineSceneSelectionMode = .inactive`

6. `.select(.scene(id:))`
- как и сейчас, не должен быть обычным path в timeline mode
- оставить debug-warning/no-op
- канонический path выбора сцены в timeline mode остаётся только `focusScene(sceneId:)`

7. `exitSceneEdit`
- после restore playhead не должен безусловно нормализовать selection из playhead
- он должен делать это **только если**
  - `timelineSceneSelectionMode == .followPlayhead`
- если mode `.inactive`, selection должен остаться тем, чем был до выхода

---

**Изменения в store / snapshot restore**
Файл: [EditorStore.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/Store/EditorStore.swift)

В `restoreNormalizedSnapshot(...)` нельзя больше делать unconditional:
- “в timeline mode selection = scene under playhead”

Новая логика:
- restore snapshot
- apply invariants
- если `uiMode == .timeline && timelineSceneSelectionMode == .followPlayhead`
  - rebind `selection` к сцене под playhead
- иначе selection не пересчитывать

---

**Изменения в snapshot model**
Файл: [EditorState.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/Store/EditorState.swift)

Так как в текущем коде `selection` уже входит в `EditorSnapshot`, новый `timelineSceneSelectionMode` тоже должен входить в snapshot и restore path.

Обновить:
- `EditorSnapshot`
- `EditorSnapshot.init(from:)`
- `EditorState.restore(from:)`

Причина:
- текущая архитектура undo/redo уже хранит selection в snapshot
- нельзя ввести новый selection-related state и не синхронизировать его с этим контрактом

---

**Изменения в TimelineView**
Файл: [TimelineView.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/TimelineView.swift)

1. Scene tap
- оставить текущий path `focusScene(sceneId:)`
- он уже соответствует новой архитектуре

2. Audio tap
- оставить explicit `.selection(.audio)`
- но это должно означать:
  - audio selected
  - scene follow mode выключен

3. Empty tap
- оставить `.selection(.none)`
- это должно означать:
  - clear scene selection
  - scene follow mode выключен

4. Optimistic local selection
- не возвращать
- selection должен оставаться store-driven

---

**Изменения в PlayerViewController**
Файл: [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift)

1. `handleTimelineEvent(_:)`
- `focusScene(sceneId:)` оставить
- `selection(.audio/.none)` оставить

2. `handleTimelineSelectionChanged(_:)`
- оставить guard, блокирующий прямой `.scene` dispatch в timeline mode
- `.audio` и `.none` по-прежнему должны идти в `.select(selection:)`

3. `handleTimelineModePlayheadChanged(_:)`
- оставить timeline scroll sync через `setCurrentCompressedFrame(...)`
- это движение playhead, а не выбор сцены
- selection изменится только если store сам решит это сделать при `timelineSceneSelectionMode == .followPlayhead`

4. `handleSelectionChanged(_:)`
- убрать логику feed-а в unified bar
- никаких `setActiveSceneForBar(...)` больше не должно остаться

---

**Нижний navbar: каноническая архитектура**
Текущая unified bar архитектура неверна для нового продукта.

Сейчас:
- [EditorLayoutContainerView.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/EditorLayoutContainerView.swift#L658) всегда показывает `TimelineModeActionBar`
- это было правильно только для уже отвергнутой модели “scene always selected by playhead”

Нужно вернуть чистую явную схему:
- `GlobalActionBar` показывается, когда `selection == .none`
- `ContextBar` показывается, когда `selection == .scene(...)`
- `ContextBar` также остаётся для `.audio` placeholder path, потому что это текущее реальное поведение кода и в этой задаче новый audio UI не проектируется
- `SceneEditBar` и `MediaBlockActionBar` в scene edit mode не меняются

Это означает:

1. Удалить [TimelineModeActionBar.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/TimelineModeActionBar.swift)
2. Удалить все его wiring/constraints/build entries из:
- [EditorLayoutContainerView.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/EditorLayoutContainerView.swift)
- [project.pbxproj](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/AnimiApp.xcodeproj/project.pbxproj)
3. Удалить `setActiveSceneForBar(_:)`
4. Восстановить `updateBottomBar()` как selection-based switch:
- `.none` -> `GlobalActionBar`
- `.scene`, `.audio` -> `ContextBar`

Это снова приводит систему в соответствие с реальным продуктовым смыслом:
- `Scene` доступно только в обычном timeline mode без выбранной сцены
- `Edit / Duplicate / Delete` доступны только когда сцена действительно выбрана пользователем

---

**ContextBar / GlobalActionBar**
Файлы:
- [ContextBar.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/ContextBar.swift)
- [GlobalActionBar.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/GlobalActionBar.swift)

Что оставить:
- `ContextBar` current scene actions
- delete disabled when sceneCount == 1
- current audio placeholder branch
- `GlobalActionBar` current add actions, включая `Scene`

Что не делать в этой задаче:
- не придумывать новый audio-specific bottom bar
- не расширять placeholder-кнопки `Text/Music/Sticker/Media`, если они не входят в текущий scope

---

**Legacy cleanup — обязательно удалить**
Нужно удалить или переписать весь код, который жёстко кодирует неверную модель “playhead always selects scene”:

1. Удалить [TimelineModeActionBar.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/TimelineModeActionBar.swift)
2. Удалить из [EditorLayoutContainerView.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/EditorLayoutContainerView.swift):
- property `timelineModeActionBar`
- constraints
- callbacks
- `setActiveSceneForBar(_:)`
- `updateBottomBar()` always-show logic
3. Удалить из [EditorState.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/Store/EditorState.swift):
- `timelineSelectionForCurrentPlayhead()`
- или переписать/rename `activeSceneIdAtPlayhead()` в нейтральный helper
4. Удалить unconditional selection derivation из:
- `.setPlayhead`
- `loadProject`
- `exitSceneEdit`
- `restoreNormalizedSnapshot`
5. Удалить/переписать тесты, которые закрепляют неверную модель
- текущий [EditorReducerPlayheadSelectionTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/EditorReducerPlayheadSelectionTests.swift) должен быть переписан целиком или заменён новым файлом
- особенно неверны тесты:
  - auto-select first scene on load
  - auto-select on every playhead change
  - `test_select_audio_inTimelineMode_works` в его текущем смысле

---

**Новые тесты**
Нужен новый reducer-level test suite на уточнённую модель. Либо заменить текущий файл, либо создать новый с осмысленным именем, например `EditorReducerSceneSelectionModeTests.swift`.

Обязательные сценарии:

1. `loadProject`
- после load:
  - `selection == .none`
  - `timelineSceneSelectionMode == .inactive`

2. `focusScene(sceneId)`
- move playhead to boundary
- `selection == .scene(id)`
- `timelineSceneSelectionMode == .followPlayhead`

3. `setPlayhead` при `timelineSceneSelectionMode == .inactive`
- selection не меняется

4. `setPlayhead` при `timelineSceneSelectionMode == .followPlayhead`
- selection обновляется на сцену под playhead

5. `.select(.none)`
- очищает selection
- выключает follow mode

6. `.select(.audio)`
- ставит `.audio`
- выключает follow mode
- дальнейший `setPlayhead` не превращает selection в `.scene(...)`

7. `exitSceneEdit`
- если mode `.followPlayhead`, selection после restore playhead rebinding-ится к сцене под этим playhead
- если mode `.inactive`, automatic scene activation не происходит

8. `restoreNormalizedSnapshot`
- при `.inactive` не авто-активирует сцену
- при `.followPlayhead` корректно rebinding-ит selected scene

9. Invalid `focusScene(sceneId)`
- no-op

10. Bottom bar behavior
- если есть существующие view tests/seam tests, добавить минимум:
  - `.none` -> `GlobalActionBar`
  - `.scene` -> `ContextBar`
  - `.audio` -> `ContextBar`
  - `TimelineModeActionBar` не существует в проекте

---

**Acceptance Criteria**
Финальная реализация принимается только если выполняются все пункты:

- При открытии editor ни одна сцена не selected автоматически.
- Просто движение timeline не активирует сцены, пока пользователь явно не выбрал сцену.
- Tap по scene clip:
  - переводит playhead на начало сцены
  - включает scene selection
  - включает follow mode
- После этого scrub / scroll / playback могут менять selected scene вслед за playhead.
- Tap в пустое место:
  - очищает selection
  - выключает follow mode
- После clear selection любое дальнейшее движение timeline не активирует сцены автоматически.
- `Edit / Duplicate / Delete` доступны только когда сцена действительно selected пользователем.
- `Scene` остаётся доступной только в обычном timeline mode без выбранной сцены.
- `Delete` disabled only when sceneCount == 1.
- Scene edit flow не ломается:
  - enter from selected scene
  - exit restores playhead correctly
  - auto-rebind after exit происходит только если follow mode был активен
- В коде не остаётся legacy логики “selection always derived from playhead”.
- В проекте не остаётся `TimelineModeActionBar`.

---

**Итог**
Это не локальный bugfix, а рефакторинг selection-архитектуры timeline mode.

Каноническая конечная модель должна быть такой:
- `scene under playhead` — вычисляемое состояние
- `selected scene` — явное пользовательское состояние
- `followPlayhead` — отдельный режим, который включается только после explicit scene selection
- нижний navbar переключается по explicit selection, а не по одному playhead
- весь код и тесты, закрепляющие старую модель, должны быть удалены или переписаны

Если хочешь, следующим сообщением я превращу это в пошаговый implementation plan по файлам и методам в порядке безопасного рефакторинга.