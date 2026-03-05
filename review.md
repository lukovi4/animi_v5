Ок, отвечаю **по реальному коду из snapshot.zip** (AnimiApp + TVECore), по каждому пункту 1–8.

---

## 1) BlockVisibilityPolicy vs `mode` в hitTest/overlays — что именно менять?

**Да, ты понял правильно: нужны оба изменения.**

### (1) `SceneRenderPlan.renderCommands(...)`

Сейчас в `TVECore/ScenePlayer/SceneRenderPlan.swift` фильтр **всегда** режет блоки по timing:
`guard block.timing.isVisible(at: sceneFrameIndex) else { continue }` (стр. 49–54).
➡️ Чтобы обходить это в edit, нужен доп. параметр (visibility или mode). В ТЗ это `BlockVisibilityPolicy` — ок.

### (2) `ScenePlayer.hitTest` и `ScenePlayer.overlays`

Обе функции уже принимают `mode: TemplateMode`, но **в текущем коде mode не влияет на timing**:

* `hitTest`: `guard block.timing.isVisible(at: frame) else { continue }` на строке ~520
* `overlays`: `guard block.timing.isVisible(at: frame) else { continue }` на строке ~563

➡️ Поэтому нужно изменить **именно эти строки** на:

* `if mode == .preview { guard timing.isVisible }`
* а в `.edit` timing не проверять.

---

## 2) Где применять `userMediaPresent` при восстановлении: внутри applyMediaAssignments или после?

По текущему коду:

* `applySceneInstanceState(instanceId:)` (PlayerViewController.swift ~1165+) применяет:

  1. variants
  2. transforms
  3. toggles
  4. `applyMediaAssignments` (сейчас photo-only)

`applyMediaAssignments(_:)` (стр. 1197–1229) **не знает про SceneState целиком**, только про `[blockId: MediaRef]`.

✅ Канонически (и проще всего) сделать так:

* `applyMediaAssignments(...)` остаётся “чистым” методом назначения медиа (setPhoto/setVideo).
* **А `userMediaPresent` применять в `applySceneInstanceState` сразу после `applyMediaAssignments`**, потому что только там у нас есть весь `SceneState`.

Порядок правильный:

1. `applyMediaAssignments` → `UserMediaService.setPhoto/setVideo` сами ставят `player.setUserMediaPresent(..., true)` (видео — после poster gating)
2. затем “перебиваем” persisted override’ом:

   * `for (blockId, present) in state.userMediaPresent { player.setUserMediaPresent(blockId: present) }`

---

## 3) setVideo ownership — это breaking change или extension? (и что делать с cleanup)

Строго по текущему `UserMediaService.swift`:

* сейчас есть только `setVideo(blockId: tempURL:)` (стр. 289+)
* temp URL сохраняется в `tempVideoURLByBlockId[blockId] = tempURL` (стр. 306)
* при cleanup удаляется файл: `FileManager.removeItem(at: tempURL)` внутри `cleanupVideoResources` (видно по реализации clean-up блока)

✅ Поэтому правильная реализация из ТЗ — **это extension API**, не ломая call sites:

1. Добавляем новый метод:

```swift
setVideo(blockId: String, url: URL, ownership: MediaOwnership)
```

2. Старый `setVideo(blockId:tempURL:)` остаётся как wrapper:

* вызывает новый с `.temporaryOwnedByService`

3. В cleanup удаляем файл **только если ownership == temporary**.

Это полностью согласуется с текущим контрактом “temp управляется сервисом” и решает data-loss для persisted video.

---

## 4) guardToken helper — это новый функционал или рефакторинг? Есть ли места без проверок?

В текущем `setVideo` уже есть token checks:

* после `await requestPoster`: guard на строках ~328–333
* перед “commit” side effects: guard на строках ~355–361

То есть **helper не обязателен для функциональности**, это **рефакторинг для единообразия**.

Но есть важный нюанс по реальному коду:

* после финального guard (стр. ~355–361) дальше идут **синхронные side effects** (mediaState assignment, setTexture, setUserMediaPresent, onNeedsDisplay) без await.
* если отмена таска (`cancel`) прилетит **после** guard’а, код не проверит `Task.isCancelled` снова и может успеть “закоммитить”.

✅ Самый релизный вариант:

* оставить существующие guards,
* **и добавить ещё одну проверку прямо перед первой записью в состояние** (перед `mediaState[blockId] = .video(selection)`), чтобы закрыть микро-окно отмены.
  Helper `guardToken()` — удобный способ не дублировать guard.

---

## 5) `SceneState.userMediaPresent`: default false vs “automatic logic” — это не противоречие?

По реальному TVECore `SceneRenderPlan`:

* `hasUserMedia = userMediaPresent[blockId] ?? false` (стр. ~65)
  То есть если ключ отсутствует — **binding layer скрыт**.

И это корректно.

Фраза “follows automatic logic from UserMediaService” означает следующее (строго по текущей архитектуре):

* `UserMediaService.setPhoto` и `setVideo` **сами вызывают** `player.setUserMediaPresent(blockId: present: true)` (видео — после poster gating)
* `UserMediaService.clear(blockId:)` ставит present false

То есть “автоматическая логика” — это **runtime side effects**, а не значение по умолчанию в render plan.

✅ Каноническая семантика для persisted `SceneState.userMediaPresent`:

* **ключ отсутствует = нет persisted override**, мы не трогаем present вручную
* фактический present становится true только если реально применили assignment (`setPhoto/setVideo`)
* disable/enable — это уже persisted override (true/false)

---

## 6) Удаление TemplateEditorController — что делать с `wireEditorController()` / `syncUIWithState`?

По реальному `PlayerViewController.swift`:

* `wireEditorController()` вызывается в `viewDidLoad` (стр. ~517–523)
* он делает:

  * `editorController.setOverlayView(overlayView)`
  * `editorController.onNeedsDisplay -> requestMetalRender()`
  * `editorController.onStateChanged -> syncUIWithState(state)` (стр. 1678–1689)
* `syncUIWithState(_:)` реально существует (стр. ~2423+) и синхронизирует dev UI (playbackContainer, инспекторы и т.д.)

✅ Ответ:

* Да, **всё это — часть старого редактора**.
* В PR-E это удаляется целиком: `TemplateEditorController`, `wireEditorController()`, `syncUIWithState`, и вызовы `editorController.setCurrentTimeUs(...)`, `editorController.selectTimeline(...)` (см. handlePlayheadChanged/handleSelectionChanged).

В релизном Scene Edit это заменяется на:

* `SceneEditInteractionController` + embed overlay в `EditorLayoutContainerView` + новое wiring через `EditorStore` callbacks.

---

## 7) TimelinePlaybackCoordinator в Scene Edit — flow верный?

Да, flow описан верно и подтверждается текущим кодом `PlayerViewController.handlePlayheadChanged`:

* `EditorStore.onPlayheadChanged` вызывает `handlePlayheadChanged`
* `handlePlayheadChanged` вызывает:

  * sync path: `coordinator.syncSetGlobalTimeUs(timeUs)` (стр. ~1244)
  * иначе async: `await coordinator.setGlobalTimeUs(requestedTimeUs)` (стр. ~1275)
* coordinator при смене сцены вызывает `onActiveSceneChanged`, а `PlayerVC.handleActiveSceneChanged` делает:

  * `resetRuntimeForSceneInstanceChange()`
  * `applySceneInstanceState(instanceId:)`

✅ Итог:

* Явный “force re-apply” при входе в Scene Edit не нужен.
* Coordinator остаётся source of truth для renderCommands даже в Scene Edit (`currentRenderCommands(mode:)` в coordinator просто прокидывает `scene.player.renderCommands(mode:sceneFrameIndex:)`).

---

## 8) PR-A scope: входит ли расширение `setBlockMedia` для auto userMediaPresent?

Да. Это **изменение модели/редьюсера AnimiApp**, значит логически относится к PR-A:

* `SceneState.userMediaPresent` добавляется в PR-A
* `EditorReducer.setBlockMedia(...)` сейчас меняет только `mediaAssignments` (стр. 655–683 EditorReducer.swift)
* расширение “при add -> present=true, при remove -> present=false” должно быть сделано **там же**, иначе:

  * persisted state будет неполным,
  * disable/enable станет неустойчивым после undo/restore.

✅ Поэтому: **да, в PR-A**.