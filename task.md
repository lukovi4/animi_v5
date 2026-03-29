**PR Scope**
Это **один локальный архитектурный refactor**, не новый большой rewrite.  
Название PR: **Interactive Trim Preview Responsiveness**.

Цель:
- сделать live preview в trim mode действительно realtime во время drag
- сохранить текущий exact-still contract для `Done` / `Cancel` / poster / paused sync
- не вводить throttle-костыли и не трогать playback/export/store архитектуру

**Канонические решения**
1. **Разделить два режима явно**
- `exact still`
- `interactive trim preview`

2. **Не использовать текущий exact path для drag**
- текущий `requestStillTexture(...)` остаётся exact-only
- drag не должен идти через zero-tolerance extraction

3. **Не добавлять fixed throttle**
- никакого “не чаще 30Hz”
- вместо этого: **one in-flight + latest-pending coalescing**

4. **Во время drag использовать tolerant extraction**
- non-zero tolerance
- reusable `AVAssetImageGenerator`
- exact frame только на `drag end`, `Done`, `Cancel`, initial open

5. **Не смешивать cache**
- playback cache отдельно
- exact still cache отдельно
- interactive trim preview cache отдельно

**Файлы и изменения**

1. [VideoFrameProvider.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/UserMedia/VideoFrameProvider.swift)

Добавить новый interactive path.

Новые свойства:
- `private var interactiveStillGenerator: AVAssetImageGenerator?`
- `private var lastInteractiveStillTexture: MTLTexture?`
- `private var lastInteractiveStillVideoTime: CMTime = .invalid`
- `private static let interactivePreviewToleranceSeconds: Double = 1.0 / 30.0`

Новые методы:
- `public func requestInteractiveStillTexture(atVideoTime videoTimeSeconds: Double) async throws -> MTLTexture`
- `public func releaseInteractiveStillResources()`

Новые private helpers:
- `private func interactiveStillGenerator() -> AVAssetImageGenerator`
- `private func clearInteractiveStillCache()`

Поведение `requestInteractiveStillTexture(...)`:
- использовать существующий `videoTime(seconds:)` для clamp
- re-use одного `AVAssetImageGenerator` на provider/session
- `appliesPreferredTrackTransform = false`
- `requestedTimeToleranceBefore/After = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)`
- писать только в `lastInteractiveStillTexture` / `lastInteractiveStillVideoTime`
- **не** трогать `lastStillTexture`
- **не** трогать playback cache

Поведение `releaseInteractiveStillResources()`:
- `interactiveStillGenerator?.cancelAllCGImageGeneration()`
- `interactiveStillGenerator = nil`
- очистить interactive cache

Изменение `release()`:
- обязательно вызвать `releaseInteractiveStillResources()`

Что не менять:
- `requestStillTexture(...)` остаётся exact zero-tolerance path
- `requestPoster(...)` остаётся thin wrapper над exact still

2. [UserMediaService.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/UserMedia/UserMediaService.swift)

Расширить `VideoSetupProviding`:
- `func requestInteractiveStillTexture(atVideoTime videoTimeSeconds: Double) async throws -> MTLTexture`
- `func releaseInteractiveStillResources()`

Добавить новое trim-preview state:
- `private var trimPreviewTasksByBlock: [String: Task<Void, Never>] = [:]`
- `private var trimPreviewPendingTimeByBlock: [String: Double] = [:]`
- `private var trimPreviewGenerationByBlock: [String: UInt64] = [:]`

Новый public API:
- `public func updateInteractiveTrimPreview(blockId: String, draftSelection: PersistedVideoSelection, previewTime: Double)`
- `public func endInteractiveTrimPreview(blockId: String)`

Новый private helper:
- `private func runInteractiveTrimPreviewLoop(blockId: String, provider: VideoSetupProviding, player: ScenePlayerForMedia, generation: UInt64)`

Алгоритм `updateInteractiveTrimPreview(...)`:
- валидировать `draftSelection` тем же путём, что и текущий exact trim preview
- clamp `previewTime` в validated range
- записать `trimPreviewPendingTimeByBlock[blockId] = clampedTime`
- если loop task уже существует, **не** создавать новый task
- если task не существует, создать один loop task

Алгоритм `runInteractiveTrimPreviewLoop(...)`:
- пока для блока есть pending time:
- забрать **только последнее** pending value
- вызвать `provider.requestInteractiveStillTexture(...)`
- после возврата проверить generation / cancellation
- инжектить texture в binding assets
- вызвать `onStillFrameDelivered?()`
- если за время in-flight пришёл новый pending time, сразу перейти к нему
- если новых pending time нет, завершить task и удалить его из словаря

Алгоритм `endInteractiveTrimPreview(blockId:)`:
- увеличить `trimPreviewGenerationByBlock[blockId]`
- отменить и удалить `trimPreviewTasksByBlock[blockId]`
- удалить `trimPreviewPendingTimeByBlock[blockId]`
- вызвать `videoProviders[blockId]?.releaseInteractiveStillResources()`

Обязательный cleanup:
- `cleanupVideoResources(for:)` должен чистить interactive trim preview state
- `clear(blockId:)` и `clearAll()` не должны оставлять trim preview task/generator
- `releasePreviewResources()` тоже должен это чистить

Что оставить как есть:
- текущий exact still path для `updateVideoStillFrames(...)`
- текущий `requestStillForBlock(...)`
- текущий `awaitPendingStillFrames()`
- `onStillFrameDelivered` остаётся render-only callback; `onNeedsDisplay` не трогать

3. [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift)

Новый callback wiring:
- подключить `editorLayoutContainer.videoTrimBar.onDragEnded`

Новый method:
- `private func handleTrimDragEnded()`

Изменить:
- `handleTrimStartDrag(_:)`
- `handleTrimEndDrag(_:)`
- `handleTrimCursorDrag(_:)`

Новый contract:
- во время `.changed` они вызывают **только** `userMediaService?.updateInteractiveTrimPreview(...)`
- при этом продолжают обновлять `videoTrimSession.currentPreviewTime`

`enterVideoTrim(...)`:
- initial preview оставить exact:
- `previewVideoTrimFrame(...)` или, если хочешь naming clarity, переименовать его в `previewExactVideoTrimFrame(...)`
- interactive path на входе не нужен

`handleTrimDragEnded()`:
- после отпускания пальца делать exact preview на `session.currentPreviewTime`
- это финализирует текущий кадр после tolerant drag preview

`commitVideoTrim()`:
- сначала `userMediaService?.endInteractiveTrimPreview(blockId: session.blockId)`
- затем exact preview на `session.draftSelection.trimStart`
- затем store dispatch

`cancelVideoTrim()`:
- сначала `userMediaService?.endInteractiveTrimPreview(blockId: session.blockId)`
- затем `videoTrimSession = nil`
- затем `syncPausedVideoStill(force: true)`

`exitVideoTrim()`:
- как safety-net тоже завершать interactive trim preview для текущего session/block, если session ещё есть
- затем текущий cleanup UI state

Что не менять:
- `syncPausedVideoStill(...)`
- suppress guard `videoTrimSession == nil`
- store contract

4. [VideoTrimBarView.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/SceneEdit/VideoTrimBarView.swift)

Изменения минимальные.

Обязательное:
- оставить callbacks на `.changed` как есть
- `onDragEnded` должен вызываться на:
- `.ended`
- `.cancelled`
- `.failed`

Сейчас `.failed` не покрыт; это надо добавить.

Что не менять:
- layout
- hit testing
- handle/cursor geometry

5. [VideoTrimThumbnailProvider.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/SceneEdit/VideoTrimThumbnailProvider.swift)

Код менять не нужно.  
Но это **референс-паттерн**: reuse session-scoped `AVAssetImageGenerator` уже есть здесь, и interactive trim preview должен быть устроен в том же стиле.

**Naming**
Для release-quality лучше сделать явное именование:

- оставить `previewVideoTrimFrame(...)` как exact path и добавить `updateInteractiveTrimPreview(...)`
или
- переименовать текущий exact method в `previewExactVideoTrimFrame(...)`

Мой канонический выбор:
- exact method: `previewExactVideoTrimFrame(...)`
- drag method: `updateInteractiveTrimPreview(...)`

Это чище и убирает двусмысленность.

**Тесты**

1. [UserMediaServiceTrimPreviewTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/UserMediaServiceTrimPreviewTests.swift)

Добавить:
- `test_updateInteractiveTrimPreview_coalescesRapidDragToLatestPending`
- `test_updateInteractiveTrimPreview_doesNotMutateMediaState`
- `test_endInteractiveTrimPreview_cancelsLoopAndReleasesProviderResources`
- `test_dragEnded_exactPreviewUsesExactPathAfterInteractivePreview`

Тестовый fake provider должен уметь:
- отдельно считать `requestStillTexture(...)`
- отдельно считать `requestInteractiveStillTexture(...)`
- отдельно фиксировать `releaseInteractiveStillResources()`
- уметь блокировать interactive path continuation, чтобы доказать coalescing

Что нужно доказать тестами:
- три быстрых drag update не дают три независимых exact requests
- пока первый interactive request in-flight, новые события не спавнят бесконечные task’и
- после завершения первого запроса выполняется только **последнее** pending время
- inject texture реально происходит
- `endInteractiveTrimPreview` очищает state и вызывает release provider resources

2. Все fake `VideoSetupProviding`

Обновить во всех test targets:
- [UserMediaServiceReadinessTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/UserMediaServiceReadinessTests.swift)
- [UserMediaServiceTrimPreviewTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/UserMediaServiceTrimPreviewTests.swift)
- [UserMediaServiceStillFrameTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/UserMediaServiceStillFrameTests.swift)
- [MediaRestoreHelperVideoSelectionTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/MediaRestoreHelperVideoSelectionTests.swift)
- [UserMediaServiceBudgetTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/UserMediaServiceBudgetTests.swift)

Новые protocol stubs:
- `requestInteractiveStillTexture(...)`
- `releaseInteractiveStillResources()`

**PR Scope**
Один PR, без дробления.

Название:
- **PR 6: Interactive Trim Preview Responsiveness**

Входит:
- `VideoFrameProvider` interactive tolerant path
- `UserMediaService` coalescing trim-preview orchestration
- `PlayerViewController` drag-changed vs drag-ended split
- `VideoTrimBarView` `.failed` handling
- targeted tests
- protocol fake updates

Не входит:
- playback path
- timeline scrub outside trim mode
- export
- store/reducer changes
- persistence/model changes
- global throttle
- redesign UI

**Acceptance Criteria**
PR считается завершённым, только если выполняется всё ниже:

- при непрерывном drag левой ручки верхний preview обновляется **во время движения**
- при непрерывном drag правой ручки верхний preview обновляется **во время движения**
- при drag cursor preview тоже обновляется непрерывно
- отпускание пальца даёт более точный final frame
- `Done` по-прежнему показывает exact frame на новом `trimStart`
- `Cancel` по-прежнему восстанавливает paused scene-frame still
- во время trim `onNeedsDisplay` не затирает trim preview
- после выхода из trim не остаётся висящих preview task/generator state
- нет возврата к cancel/recreate storm на каждый drag tick

**Короткий итог**
Это **не костыль и не полный rewrite**.  
Это **канонический локальный refactor одного слоя**: отделить `interactive trim preview` от `exact still`, при этом сохранить всю остальную архитектуру без ломки.