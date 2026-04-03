**PR E: Functional Stabilization / Manual Product Pass**

**Цель**  
Провести финальный продуктовый stabilization pass поверх уже собранной архитектуры media/photo/video pipeline и закрыть только реальные пользовательские дефекты.  
Этот этап **не открывает новый архитектурный рефакторинг**. Основа уже собрана в текущем коде:
- persisted media contract: [SceneMediaSlot.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/MediaIngest/SceneMediaSlot.swift), [SceneMediaAsset.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Project/SceneMediaAsset.swift), [MediaPlacementState.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Project/MediaPlacementState.swift)
- migration/hydration: [SceneStateMigrationHelper.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Project/SceneStateMigrationHelper.swift), [ProjectDraftHydrator.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Project/ProjectDraftHydrator.swift)
- placement math/runtime apply: [MediaPlacementResolver.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Project/MediaPlacementResolver.swift), [SceneRuntimeStateApplier.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/SceneRuntimeStateApplier.swift)
- timeline/export orchestration: [TimelineCompositionEngine.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/TimelineComposition/TimelineCompositionEngine.swift)
- scene-edit gestures: [PlacementGestureSession.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/SceneEdit/PlacementGestureSession.swift), [SceneEditInteractionController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/SceneEdit/SceneEditInteractionController.swift)
- photo master/proxy: [MediaAssetStore.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/MediaIngest/MediaAssetStore.swift), [PhotoProxyCache.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/MediaIngest/PhotoProxyCache.swift), [UserMediaService.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/UserMedia/UserMediaService.swift)

**Платформа и scope**
- Платформа: **только iPhone**
- Формат: **manual product pass + точечные исправления**
- Допустимы:
  - user-visible bug fixes
  - дешевые локальные cleanup/perf fixes, если они возникают по пути
  - targeted regression tests только там, где фикс без теста рискован
- Не входят:
  - новый архитектурный слой
  - новые UX-фичи
  - fit mode selector
  - preview audio playback
  - новый photo loading UX/placeholder, если только manual pass не покажет явный продуктовый дефект
  - iPad/macOS-specific polish

**Каноничный продуктовый контракт, который считаем финальным**
- Работает только тот slot, с которым взаимодействовал пользователь.
- `last write wins`; предыдущий ingest cancel.
- Если slot удален до completion ingest, результат silently drop без alert.
- `replace media` сохраняет только `visibility`; `placement` и `videoWindow` всегда reset.
- `remove media` silent, без confirm dialog.
- hide/show сохраняет `placement`, `trim`, `mute`, `volume`.
- `Reset Transform` сохраняет `fitMode`, сбрасывает только `offset/scale/rotation`.
- variant switch сохраняет media state только если `blockId` тот же.
- variant не меняет геометрию slot-а.
- duplicate scene копирует media state, но не дублирует физические media files; placement в сценах независим.
- photo preview использует proxy, export использует master.
- proxy generation failure допустимо silently fallback-ит на master preview.
- новый video import: `trim = full duration`, `isMuted = true`, `volume = 1.0`.
- `hold last frame` обязателен и для preview, и для export.
- preview audio всегда muted.
- missing/corrupt media: silent empty slot, без alert; export продолжается с пустым slot-ом.
- reopen acceptance: визуально корректное восстановление `placement/trim/visibility/variant` достаточно.
- preview/export parity оценивается по **визуальной эквивалентности**, не по pixel-perfect equality.

**Что именно проверяем**
1. **Insert / Replace / Remove**
- insert photo в пустой slot
- insert video в пустой slot
- replace photo -> photo
- replace photo -> video
- replace video -> photo
- replace video -> video
- remove media из visible slot
- remove media из hidden slot
- удаление slot во время in-flight ingest
- второй ingest в тот же slot до завершения первого

2. **Placement / Reset / Visibility**
- pan / pinch / rotate по отдельности
- simultaneous pan + pinch
- simultaneous pan + rotate
- gesture cancel
- `Reset Transform` после non-default placement
- hide/show после non-default placement
- hide/show после trim/mute changes у video
- отсутствие ложной видимости кнопки reset при near-default state через [MediaPlacementState.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Project/MediaPlacementState.swift)

3. **Variant / Duplicate / Scene Switching**
- variant switch при том же `blockId`
- duplicate scene с photo
- duplicate scene с video
- independent placement after duplicate
- ingest completion в scene A после переключения пользователя на scene B
- inactive scene update без UI-регрессий
- cold scene, которую не открывали руками, но потом export/reopen использует ее state

4. **Photo Pipeline**
- новый import HEIC/JPEG/PNG
- alpha-image preview/export
- очень большой photo asset
- proxy generation on first preview
- repeated preview reuse of proxy
- fallback на master, если proxy generation не удался
- reopen проекта с уже существующим proxy
- legacy-style JPEG draft как master path smoke-check

5. **Video / Trim / Audio**
- новый video import получает `isMuted = true`, `volume = 1.0`, full trim
- trim drag preview
- trim commit
- trim cancel
- block duration > trim window -> hold last frame в preview
- тот же кейс -> hold last frame в export
- replace video reset-ит `trim/mute/volume`
- hide/show после trim
- export respects mute/volume как smoke-check, без большой аудио-матрицы

6. **Save / Reopen / Migration**
- первый open legacy draft -> state канонизируется и autosave допустим без явного edit
- reopen после photo edits
- reopen после video trim
- reopen после hide/show
- reopen после variant switch
- reopen проекта, где есть cold scenes
- missing media after reopen -> empty slot, editable
- corrupt media after reopen -> empty slot, no crash

7. **Timeline / Async Media Readiness**
- paused timeline + async photo ready -> current frame redraw
- paused timeline + async video ready -> current frame redraw
- active scene preview после async media ready
- inactive scene become active after background update
- визуальная оценка краткого fit flash до media-ready:
  - если почти незаметно и быстро self-corrects, допустимо
  - если явно раздражает и бросается в глаза, это уже `Must-fix`

**Must-Pass сценарии для `Go`**
- insert/replace/remove не теряют target slot и не пишут в чужую сцену
- `replace media` сохраняет только `visibility`
- hide/show сохраняет placement и video state
- gestures корректно коммитятся/откатываются
- `Reset Transform` возвращает к default placement текущего `fitMode`
- duplicate scene копирует media state, но placement между сценами независим
- reopen визуально восстанавливает placement/trim/visibility/variant
- export не расходится с preview по placement/orientation/trim на заметном уровне
- missing/corrupt media не крашит приложение и не ломает export
- paused timeline redraw после async media ready работает
- новый video import действительно muted by default
- hold last frame работает и в preview, и в export

**Что считаем допустимым residual behavior**
- краткий fallback на master preview вместо proxy под contention
- краткий fit jump до получения реального media size, если он быстро self-corrects и не выглядит как заметный UX-дефект
- silent migration autosave старого draft без отдельного пользовательского подтверждения

**Что считаем дефектом**
- media попало не в тот slot / не в ту сцену
- replace сохранил placement или trim вопреки контракту
- hide/show потерял placement/trim/mute/volume
- reset transform сбрасывает `fitMode`
- duplicate сцены связан по placement между копией и оригиналом
- reopen/export показывает не тот crop/rotation/trim
- missing/corrupt media приводит к crash или блокирует export
- paused timeline не redraw-ится после async media ready
- явный и раздражающий visual pop/flicker в базовых сценариях

**Классификация багов в этом проходе**
- `Blocker`: data loss, crash, экспорт недостоверен, state corruption, media goes to wrong slot/scene
- `Must-fix`: user-visible contract break в must-pass сценариях
- `Can defer`: мелкий визуальный polish, слабый perf debt, редкие недетерминированные fallback’и без нарушения correctness

**Как выполнять проход**
1. Сначала manual pass по must-pass сценариям
2. Потом точечные secondary сценарии
3. Каждый найденный дефект сразу классифицировать как `Blocker / Must-fix / Can defer`
4. Исправлять только:
- `Blocker`
- `Must-fix`
- дешевые `Can defer`, если фикс локальный и без нового scope
5. После каждого значимого фикса:
- минимальный targeted regression test, если это reducer/runtime/hydration/gesture behavior
- без нового широкого рефакторинга

**Что сознательно не делаем в PR E**
- не меняем persisted schema
- не меняем основной media contract
- не добавляем новый placeholder UX для photo заранее
- не открываем новый refactor вокруг hydration/runtime/apply
- не расширяем платформенный scope beyond iPhone
- не делаем отдельный audio-feature pass для preview

**Критерий завершения**
PR E можно считать завершенным, когда:
- все `Must-Pass` сценарии пройдены на iPhone behavior level
- не осталось `Blocker`
- не осталось `Must-fix`
- все оставшиеся issues классифицируются как допустимый `Can defer`
- preview/edit/reopen/export по ключевым media сценариям ведут себя как одна система, без контрактных расхождений

**Итог**
Это финальное каноническое ТЗ для следующего этапа по текущему реальному коду.  
PR E должен быть **продуктовым stabilization pass**, а не продолжением архитектурного рефакторинга.