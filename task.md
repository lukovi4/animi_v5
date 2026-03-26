**Финальное каноническое ТЗ: Phase 3 — Video Ingest Rewrite**

Это **финальная редакция** Phase 3.  
Она уже включает ответы на все вопросы, которые возникали по ходу обсуждения.  
Программист должен исправлять **только этот scope**, без самовольного добавления UI-фаз, export-рефакторинга или дополнительных архитектурных изменений.

---

## **1. Цель Phase 3**

Переписать **scene user-video ingest path** на канонический контракт:

`PHPicker file representation -> single persistent copy -> persisted metadata validation -> persisted SceneMediaSlot(videoWindow required) -> runtime bind from persisted URL`

Главная цель фазы:
- убрать double-copy видео;
- сделать persisted video contract строгим;
- убрать legacy API и transitional параметры из runtime video path;
- зафиксировать, что post-assign trim edits живут **отдельно** от ingest.

---

## **2. Зафиксированные решения по продукту и поведению**

Ниже решения уже утверждены и **не обсуждаются заново**:

1. **Phase 3 не включает новый video settings UI.**  
   Никакого нового экрана confirm/trim/settings в этой фазе не делаем.  
   Это **plumbing-only phase**.

2. **Из-за отсутствия нового UI в Phase 3 video commit остаётся immediate.**  
   То есть после успешного ingest и validation видео по-прежнему сразу попадает в slot/runtime, **но уже через правильный технический контракт**.

3. **После первого назначения видео дальнейшие trim/offset/audio edits не должны вызывать повторный `setVideo()` и не должны запускать повторный ingest.**  
   Это отдельное обновление persisted state через:
   - [EditorAction.swift:126](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/Store/EditorAction.swift:126)
   - [EditorReducer.swift:156](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/Store/EditorReducer.swift:156)

4. **Если persisted trim/window выходит за фактическую длительность файла, блок должен жёстко падать в failed.**  
   Никакого silent clamp, никакого auto-fix.

5. **Если metadata validation упала уже после persistent copy, файл удаляется сразу.**  
   Не через GC, не “потом”.

6. **`VideoPreparePipeline` должен возвращать готовый default `PersistedVideoSelection`, а не просто `duration`.**

7. **Future UI constraint зафиксирован на будущее, но не реализуется сейчас:**  
   когда позже появится video settings screen, новый pick во время открытого settings screen должен быть **запрещён**, а не auto-replace.  
   В текущей Phase 3 это **не реализуется**, потому что самого экрана нет.

---

## **3. Что подтверждено текущим кодом и почему Phase 3 нужна**

### **3.1 Double-copy video ingest существует сейчас**
- В [PickerAssetAdapter.swift:88](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/MediaIngest/PickerAssetAdapter.swift:88) видео из `PHPicker` копируется в `temporaryDirectory`.
- В [MediaAssetStore.swift:54](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/MediaIngest/MediaAssetStore.swift:54) потом тот же файл копируется ещё раз в persistent store.

Это надо удалить.

### **3.2 Video validation сейчас нестрогая**
- [VideoPreparePipeline.swift:19](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/MediaIngest/VideoPreparePipeline.swift:19) фактически ничего не валидирует.
- [VideoPreparePipeline.swift:27](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/MediaIngest/VideoPreparePipeline.swift:27) на metadata error возвращает `0`.
- [MediaIngestCoordinator.swift:175](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/MediaIngest/MediaIngestCoordinator.swift:175) превращает это в `videoWindow = nil`.

Это нельзя оставлять.

### **3.3 Persisted video slot contract сейчас допускает невалидное состояние**
- [SceneMediaSlot.swift:22](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/MediaIngest/SceneMediaSlot.swift:22) хранит `videoWindow` как optional.
- [MediaRestoreCoordinator.swift:65](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/MediaIngest/MediaRestoreCoordinator.swift:65) позволяет restore video slot без persisted selection.

Для persisted video это нужно запретить.

### **3.4 Runtime video API содержит мёртвый и transitional legacy**
- [UserMediaService.swift:173](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/UserMedia/UserMediaService.swift:173) `MediaOwnership` — legacy compat.
- [UserMediaService.swift:534](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/UserMedia/UserMediaService.swift:534) `setVideo(...)` всё ещё принимает:
  - `ownership`
  - `emitSelectionPersistence`
  - `pendingPersistedSelection`
- `emitSelectionPersistence` реально **мёртвый**: в коде он больше нигде не используется, кроме сигнатуры и комментария.

Это надо убрать.

### **3.5 Post-assign trim path уже существует отдельно**
- [EditorAction.swift:126](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/Store/EditorAction.swift:126) `setVideoSelection`
- [EditorReducer.swift:156](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/Store/EditorReducer.swift:156)
- [UserMediaService.swift:1302](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/UserMedia/UserMediaService.swift:1302) `applyPersistedVideoSelection`

Значит trim edits должны быть привязаны именно к этому пути, а не к re-ingest.

---

## **4. Финальный scope Phase 3**

### **Входит в scope**
- video picker extraction
- video persistent copy
- video metadata validation
- strict `SceneMediaSlot.videoWindow` contract
- runtime `setVideo(...)` API cleanup
- `ProjectDraft` schema bump
- update tests under new contract

### **Не входит в scope**
- новый video settings screen
- trim UI / scrubber / handles / audio controls
- apply/cancel candidate flow
- export parity / export snapshot rewrite
- background media
- video playback budget logic
- `VideoPosterCache`
- full runtime trim editor flow

---

## **5. Канонический технический контракт после Phase 3**

После завершения фазы должно быть так:

1. Пользователь выбирает видео через `PHPicker`.
2. Приложение **один раз** копирует файл в persistent store `Media/UserMedia/`.
3. По persisted URL выполняется metadata validation.
4. Если validation успешна:
   - строится `PersistedVideoSelection(trimStart: 0, trimEnd: duration, offset: 0, ...)`
   - строится `SceneMediaSlot.video(mediaRef:, videoWindow:)`
   - slot сразу коммитится в draft
   - если сцена активна, runtime получает `setVideo(...)`
5. Если validation неуспешна:
   - persisted файл удаляется сразу
   - slot не коммитится
   - runtime не вызывается
   - ingest status = failed
6. Когда в будущем пользователь меняет trim/offset/audio уже назначенного видео:
   - это **не ingest**
   - это update существующего slot через `setVideoSelection`

---

## **6. Обязательные изменения по файлам**

### **6.1 [PickerAssetAdapter.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/MediaIngest/PickerAssetAdapter.swift)**

#### **Что сделать**
Photo path не трогать.  
Video path переписать так, чтобы убрать промежуточную temp-copy.

#### **Требование**
Новый канонический video API adapter’а должен позволять **непосредственно использовать ephemeral picker URL внутри callback** для immediate persistent copy.

Допустимая форма API:
- closure-based helper по смыслу:
  - `withVideoFileRepresentation(from: PHPickerResult, perform: (URL) throws -> T) async throws -> T`
- или эквивалентный API, который гарантирует:
  - video file не копируется в `temporaryDirectory`
  - persistent copy происходит, пока picker URL ещё валиден

#### **Что удалить**
- `loadVideoRepresentation(provider:)` в нынешнем виде
- intermediate `tempURL` для video path
- `videoCopyFailed` как ошибка именно temp-copy шага, если temp-copy path исчезает

#### **Что оставить**
- `mediaKind(of:)`
- photo path
- общий PHPicker classifier

#### **Запрещено**
- Нельзя возвращать наружу video URL, который живёт только до конца picker callback и ещё не persisted.
- Нельзя повторно вводить temp video file как промежуточный этап ingest.

---

### **6.2 [MediaAssetStore.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/MediaIngest/MediaAssetStore.swift)**

#### **Что сделать**
Оставить `MediaAssetStore` единственным persistence API для scene user media.

#### **Новый контракт**
Для video:
- `saveMedia(...)` должен быть тем **единственным durable copy**, который переносит файл из picker representation в canonical persistent storage.

#### **Что важно**
- Видео persist’ится “как есть”, без transcoding.
- Persistent path и naming contract можно оставить текущий:
  - `Media/UserMedia/<sceneId>_<blockId>_<uuid>.<ext>`

#### **Комментарии**
Обновить комментарии: это уже не “copy from temp picker copy”, а прямой single-copy persist.

---

### **6.3 [VideoPreparePipeline.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/MediaIngest/VideoPreparePipeline.swift)**

#### **Что сделать**
Переписать файл в строгий metadata-validation layer.

#### **Удалить**
- `import UIKit`
- no-op `prepare(sourceURL:)`

#### **Новый API**
Канонический API pipeline должен принимать **persisted URL** и возвращать **готовый default `PersistedVideoSelection`**.

По смыслу:
```swift
validatePersistedVideo(at url: URL) async throws -> PersistedVideoSelection
```

#### **Обязательная логика**
- использовать `AVURLAsset`
- асинхронно загрузить duration
- duration должна быть:
  - finite
  - > минимального порога
- на успехе вернуть:
  - `PersistedVideoSelection(trimStart: 0, trimEnd: duration, offset: 0, isMuted: false, volume: 1.0)`
- на любой ошибке или invalid duration — throw

#### **Запрещено**
- Возвращать `0` вместо ошибки
- silently создавать default persisted selection из invalid duration

---

### **6.4 [MediaIngestCoordinator.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/MediaIngest/MediaIngestCoordinator.swift)**

#### **Что сделать**
Переписать только video branch ingest.

#### **Старый path удалить**
- `.video(let tempURL)`
- temp file cleanup через `defer`
- `assetStore.saveMedia(from: tempURL, ...)`

#### **Новый path**
1. получить picker video file representation без temp-copy
2. сразу сделать persistent copy через `MediaAssetStore`
3. получить `persistedURL`
4. прогнать `VideoPreparePipeline.validatePersistedVideo(at:)`
5. построить:
   - `SceneMediaSlot.video(mediaRef: mediaRef, videoWindow: validatedSelection)`

#### **Обязательный инвариант**
Успешный video ingest **всегда** заканчивается slot’ом с валидным `videoWindow`.  
`videoWindow == nil` в `IngestResult` для `.video` недопустим.

#### **На error после persist**
- удалить persisted файл немедленно через orphan cleanup
- `onIngestComplete` не вызывать
- status -> `.failed`

#### **Concurrency**
Video persist и metadata validation должны выполняться вне `MainActor`.

На `MainActor` остаются только:
- generation checks
- status updates
- bookkeeping
- `onIngestComplete`

---

### **6.5 [SceneMediaSlot.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/MediaIngest/SceneMediaSlot.swift)**

#### **Что сделать**
Оставить `videoWindow` property optional на уровне общей модели, потому что photo slots её не имеют.  
Но ужесточить contract:

- для photo: `videoWindow == nil`
- для video: `videoWindow != nil`

#### **Конкретные изменения**
- `SceneMediaSlot.video(...)` должен требовать **неoptional** `videoWindow`
- комментарии обновить:
  - persisted video slot без `videoWindow` больше не считается валидным состоянием

---

### **6.6 [SceneState.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Project/SceneState.swift)**

#### **Что сделать**
Оставить `PersistedVideoSelection` текущей persisted-моделью.  
Новый формат не вводить.

#### **Допустимое улучшение**
Если удобно, можно добавить helper для default full-duration selection, но это не обязательно.  
Главное: source of truth для persisted video trim остаётся именно `PersistedVideoSelection`.

---

### **6.7 [UserMediaService.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/UserMedia/UserMediaService.swift)**

#### **Что сделать**
Упростить runtime video API до persisted-only contract.

#### **Удалить из API**
- `MediaOwnership`
- `ownership`
- `emitSelectionPersistence`
- `pendingPersistedSelection`

#### **Почему**
- `emitSelectionPersistence` уже мёртвый
- `MediaOwnership` уже legacy compat
- persisted-only path уже является фактическим production direction

#### **Новый production signature**
По смыслу:
```swift
setVideo(
  blockId: String,
  url: URL,
  presentOnReady: Bool = true,
  persistedSelection: PersistedVideoSelection
) -> Bool
```

#### **Что должен делать метод**
- создать provider
- poster-gated async setup
- когда provider готов:
  - получить фактическую duration
  - собрать runtime `VideoSelection` через `persistedSelection.toVideoSelection(url:)`
  - проверить, что selection валидна относительно фактической длительности
- только потом:
  - записать `mediaState[blockId] = .video(selection)`
  - инжектить poster
  - выставить `userMediaPresent(blockId: presentOnReady)`
  - `blockReadinessState = .ready`

#### **Если persisted selection невалидна**
- вызвать failure cleanup path
- слот не должен silently корректироваться

#### **Что оставить**
- `applyPersistedVideoSelection(blockId:_:)` оставить
- это и есть канонический путь для future trim edits после первого назначения

#### **Что важно**
После Phase 3 `setVideo()` вызывается только:
- при первом назначении видео
- при замене файла на другой файл

При обычном trim/offset/audio редактировании `setVideo()` больше не должен быть частью flow.

---

### **6.8 [MediaRestoreCoordinator.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/MediaIngest/MediaRestoreCoordinator.swift)**

#### **Что сделать**
Сделать video restore строгим.

#### **Новый контракт**
Если:
- `slot.mediaRef.mediaKind == .video`
- и `slot.videoWindow == nil`

то restore обязан:
- вызвать `service.markRestoreFailed(...)`
- не пытаться запускать `setVideo(...)`

#### **Вызов runtime**
Перевести на новый `setVideo(..., persistedSelection:)` signature.

#### **Что удалить**
- implicit default-runtime-selection semantics для persisted video slot без `videoWindow`

---

### **6.9 [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift)**

#### **Что сделать**
Поскольку UI-фаза отложена, текущий immediate commit остаётся, но с новым строгим contract.

В `handleIngestComplete(_:)`:
- video branch должна вызывать новый `setVideo(..., persistedSelection:)`
- selection берётся только из `result.slot.videoWindow`
- `result.slot.videoWindow` должен уже гарантированно существовать

#### **Что не менять**
- не вводить candidate UI
- не вводить apply/cancel flow
- не добавлять новый settings screen
- не менять photo path

---

### **6.10 [EditorAction.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/Store/EditorAction.swift)** и [EditorReducer.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/Store/EditorReducer.swift)

#### **Что сделать**
Зафиксировать `setVideoSelection` как единственный persisted path для trim/offset/audio edits уже назначенного видео.

#### **Обязательное ужесточение**
В [EditorReducer.swift:156](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/Store/EditorReducer.swift:156) `setVideoSelection` сейчас обновляет `existingSlot.videoWindow = selection` без проверки media kind.

Это нужно исправить:
- если slot отсутствует -> no-op
- если slot существует, но `mediaRef.mediaKind != .video` -> no-op
- только существующий video slot можно обновлять через `setVideoSelection`

#### **Почему**
Это часть строгого video contract и future trim-edit path.

---

### **6.11 [ProjectStore.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Project/ProjectStore.swift)**

#### **Что сделать**
Удалить [ProjectStore.swift:568](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Project/ProjectStore.swift:568) `saveUserVideo(...)`.

#### **Почему**
После Phase 3 у scene user-video persistence должен остаться только один официальный путь: `MediaAssetStore`.

---

### **6.12 [ProjectDraft.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Project/ProjectDraft.swift)**

#### **Что сделать**
Bump schema version:
- `7 -> 8`

#### **Почему**
Persisted video-slot contract ужесточается:
- persisted video slot без `videoWindow` становится невалидным состоянием

#### **Что не делать**
- не писать migration
- не делать compatibility shim

Старые drafts invalidated существующим schema gate + purge lifecycle.

---

## **7. Тесты**

### **7.1 Новый `VideoPreparePipelineTests`**
Обязательные кейсы:
- valid video -> returns default `PersistedVideoSelection`
- missing file -> throws
- corrupt/unreadable video -> throws
- zero/invalid duration -> throws

### **7.2 Обновить [MediaRestoreHelperVideoSelectionTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/MediaRestoreHelperVideoSelectionTests.swift)**
Убрать старый контракт:
- `videoWindow == nil` для video restore -> default selection

Заменить на новый:
- `videoWindow == nil` для video slot -> explicit failure

Оставить:
- visibility through `presentOnReady`
- persisted trim/offset/audio restore for valid video slot

### **7.3 Обновить [UserMediaServiceReadinessTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/UserMediaServiceReadinessTests.swift)**
Переписать `setVideo(...)` tests под новый signature.

Обязательные кейсы:
- valid persisted selection -> `.ready`
- invalid persisted selection vs actual duration -> `.failed`
- missing file -> `.failed`
- unreadable file -> `.failed`
- replace pending video with another video -> generation safety preserved
- `presentOnReady: false` respected
- trim updates after initial assign не re-call `setVideo()`

### **7.4 Обновить ingest tests**
Если меняется public/testable seam у coordinator, покрыть:
- success video ingest -> slot has non-nil `videoWindow`
- metadata failure after persist -> file deleted immediately
- no temp-copy path in video ingest

### **7.5 Обновить reducer tests**
Добавить/обновить:
- `setVideoSelection` on photo slot -> no-op
- `setVideoSelection` on missing slot -> no-op
- `setVideoSelection` on existing video slot -> updates `videoWindow`

### **7.6 Schema tests**
- ожидания schema version -> `8`
- incompatible old video drafts do not leak through saved project list

---

## **8. Точечные статические проверки**

После реализации должны выполняться:

1. `MediaOwnership` отсутствует в production code:
```sh
rg -n "MediaOwnership" /Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources
```

2. `saveUserVideo(` отсутствует как живой API/callsite:
```sh
rg -n "saveUserVideo\\(" /Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp
```

3. В `PickerAssetAdapter` нет temp video copy:
```sh
rg -n "temporaryDirectory|copyItem\\(at: sourceURL, to: tempURL\\)|videoCopyFailed" /Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/MediaIngest/PickerAssetAdapter.swift
```

4. В production code нет legacy video API params:
```sh
rg -n "ownership:|emitSelectionPersistence|pendingPersistedSelection" /Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources
```

5. В production code нет persisted video slot construction с `videoWindow: nil`:
```sh
rg -n "\\.video\\(.*videoWindow:\\s*nil" /Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources
```

---

## **9. Verification**

1. `xcodebuild build`
2. `xcodebuild test`
3. targeted test suites:
- `VideoPreparePipelineTests`
- `UserMediaServiceReadinessTests`
- `MediaRestoreCoordinatorVideoSelectionTests`
- reducer tests for `setVideoSelection`
- schema/persistence tests for v8

4. manual sanity:
- выбрать валидное видео -> оно сразу применяется в block с full-duration default selection
- выбрать битое/нечитаемое видео -> block не меняется, файл не остаётся на диске
- reopen project -> persisted video slot restore only with valid `videoWindow`
- trim update future path still uses `setVideoSelection`, not re-ingest

---

## **10. Жёсткие запреты**

В этой фазе **запрещено**:
- добавлять новый video settings screen
- добавлять candidate/apply/cancel flow
- менять export code
- silently clamp persisted trim/window к shorter file
- оставлять persisted video slot без `videoWindow`
- оставлять temp-copy video ingest
- re-call `setVideo()` при обычном trim edit
- оставлять `MediaOwnership`, `emitSelectionPersistence`, `pendingPersistedSelection`
- решать эту фазу через workaround в `PlayerViewController` вместо нормального contract cleanup

---

## **11. Definition of Done**

Phase 3 считается завершённой только если одновременно выполнено всё:

- video ingest больше не делает temp-copy перед persist
- durable copy для video ровно один
- success video ingest всегда создаёт persisted slot с валидным `videoWindow`
- metadata failure после persist немедленно удаляет файл
- `MediaRestoreCoordinator` больше не допускает video slot без `videoWindow`
- `UserMediaService.setVideo` переведён на persisted-only contract без legacy параметров
- `setVideoSelection` является единственным persisted path для post-assign trim edits
- `ProjectStore.saveUserVideo(...)` удалён
- schema bumped до `v8`
- Phase 3 не добавила новый UI и не полезла в export

Это и есть финальное каноническое ТЗ для Phase 3.