**ТЗ: Второй Проход Рефакторинга Export Memory Architecture**

**Цель**
Довести экспорт до канонической memory-safe архитектуры по реальному коду Animi. После этого:
- export не падает по jetsam на реальных устройствах
- preview полностью выгружается на время экспорта
- user photos/videos экспортируются из корректного persisted source-of-truth
- timeline export не делает eager prepare всех video providers даже внутри resident scene
- preflight реально умеет остановить unsafe export и предложить lower preset
- кодовая база очищена от оставшегося legacy

**Текущие блокирующие дефекты**
- `ExportMediaSnapshot` берёт photo refs не из persisted user media, а из template asset index: [ExportMediaSnapshot.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/ExportMediaSnapshot.swift)
- `TimelineExportResidencyController` всё ещё вызывает `prepareAll()` для video slots resident scene: [TimelineExportResidencyController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/TimelineExportResidencyController.swift), [ExportVideoSlotsCoordinator.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/ExportVideoSlotsCoordinator.swift)
- `ExportPreflightPlanner` не влияет на UI flow: lower preset recommendation игнорируется в [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift)
- timeline preflight считает `videoSlotCount` неверно
- `enterExportMode()` не делает глубокий teardown preview resources
- `budget.maxFramesInFlight` не доведён до renderer internals
- тяжёлый export prepare всё ещё блокирует `MainActor`

**Обязательные изменения**

**1. Исправить source-of-truth для export user media**
- Переработать [ExportMediaSnapshot.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/ExportMediaSnapshot.swift), чтобы snapshot строился из persisted user media refs, а не из `mergedAssetIndex`.
- Добавить в [UserMediaService.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/UserMedia/UserMediaService.swift) export-safe API, который возвращает для каждого slot:
  - photo file URL
  - video file URL
  - metadata, нужную для export
- Использовать уже существующий persisted flow из [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift#L2658) и [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift#L2729)
- Если persisted media ref отсутствует, export должен падать явной typed error, а не silently fallback-иться.

**2. Убрать eager video prepare из scene residency**
- В [TimelineExportResidencyController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/TimelineExportResidencyController.swift) удалить вызов `prepareAll()`.
- В [ExportVideoSlotsCoordinator.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/ExportVideoSlotsCoordinator.swift) заменить текущую модель на truly lazy:
  - provider готовится только при входе в active window
  - provider освобождается после выхода из окна
  - количество одновременно активных providers bounded budget-ом
- В [ExportVideoFrameProvider.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/ExportVideoFrameProvider.swift) довести lifecycle `prepareIfNeeded / suspend / resume / releaseDecodedState` до реального использования из coordinator.

**3. Реализовать настоящий preflight product flow**
- В [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift) перед стартом export:
  - вызывать `ExportPreflightPlanner`
  - если returned recommendation говорит, что текущий preset unsafe, не стартовать export сразу
  - показывать пользователю prompt с предложением lower preset
  - продолжать export только после явного выбора пользователя
- Автоматически ухудшать качество без согласия пользователя нельзя.

**4. Исправить входные данные planner для timeline**
- В [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift) считать реальный `videoSlotCount` для timeline preflight из export snapshots / video selections.
- При необходимости расширить [ExportPreflightPlanner.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/ExportPreflightPlanner.swift), чтобы он принимал:
  - actual scene count
  - actual video slot count
  - background count
  - target export resolution
- Planner не должен больше получать `videoSlotCount: 0` на timeline path.

**5. Сделать глубокий preview teardown перед export**
- Расширить `enterExportMode()` в [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift), чтобы он не только останавливал playback, но и освобождал preview-only heavy resources.
- Добавить явные release/teardown hooks там, где их сейчас нет:
  - `UserMediaService` должен уметь освобождать preview video resources, а не только stop playback: [UserMediaService.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/UserMedia/UserMediaService.swift)
  - timeline/scene preview layers должны сбрасывать caches и warm state
  - background preview provider должен очищаться полностью
- После terminal export result всегда вызывать `exitExportModeToIdle()` и не восстанавливать playback автоматически.

**6. Довести budget до реального renderer**
- В [VideoExporter.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/VideoExporter.swift) и зависимом renderer path обеспечить, чтобы `budget.maxFramesInFlight` применялся не только к semaphore, но и к renderer-owned in-flight resources.
- Если нужно, расширить `MetalRenderer` init/config path в TVECore, чтобы export renderer создавался с явным `maxFramesInFlight`.
- После этого single-scene и timeline export должны использовать один и тот же budget source-of-truth.

**7. Убрать тяжёлый prepare с MainActor**
- В [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift) вынести downsample/load/export prepare с `MainActor` на background execution.
- `MainActor` должен обновлять только progress UI.
- В [DownsampledImageLoader.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/UserMedia/DownsampledImageLoader.swift) сохранить корректный upload path, но не вызывать его синхронно из UI thread-driven loop.

**8. Довести budget model до фактического использования**
- В [TimelineExportResidencyController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/TimelineExportResidencyController.swift) либо реально использовать `budget.maxResidentScenes`, либо удалить это поле из [ExportResourceBudget.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/ExportResourceBudget.swift) как misleading dead config.
- В [ExportTextureProvider.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/ExportTextureProvider.swift) residency/bounded cache policy должна быть формально связана с budget, а не только с manual clear calls.

**Legacy, который нужно удалить**
- Любую зависимость export snapshots от `mergedAssetIndex` как source-of-truth для user media
- Остаточный `prepareAll()` path в timeline residency
- Любой flow, где unsafe preflight просто логируется, но не влияет на UI
- Поверхностный export mode teardown без release hooks
- Неиспользуемые budget поля или конфиги, которые не влияют на поведение
- Stale comments/docs, если они ещё описывают eager export behavior

**Тесты**
- Новый [ExportMediaSnapshotPersistenceTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/ExportMediaSnapshotPersistenceTests.swift)
  - user photo export uses persisted file URL
  - missing persisted photo ref returns explicit export error
- Обновить [TimelineExportResidencyControllerTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/TimelineExportResidencyControllerTests.swift)
  - resident scene entry does not call `prepareAll()`
  - active providers bounded by budget
  - providers released after eviction
- Новый [ExportPreflightPlayerFlowTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/ExportPreflightPlayerFlowTests.swift)
  - unsafe preset shows lower-preset prompt
  - export does not start until user chooses
  - accepted lower preset starts export with recommended preset
- Новый [PlayerExportModeTeardownTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/PlayerExportModeTeardownTests.swift)
  - preview video resources released
  - background preview textures released
  - editor returns to idle after export
- Обновить [ExportPreflightPlannerTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/ExportPreflightPlannerTests.swift)
  - timeline with real video slot count yields stricter budget / recommendation
- Добавить test на renderer budget propagation, если меняется init/config path

**Acceptance Criteria**
- Export user photos/videos берутся из persisted media refs, а не из live preview textures и не из template asset index.
- Timeline export не вызывает eager `prepareAll()` при входе resident scene.
- Lower preset recommendation реально показывается пользователю и влияет на запуск export.
- Timeline preflight учитывает реальные video slots.
- `enterExportMode()` освобождает preview-only heavy resources, а не только паузит playback.
- `budget.maxFramesInFlight` реально ограничивает renderer-owned in-flight resources.
- Heavy export prepare не блокирует `MainActor`.
- После export editor возвращается в `idle`.
- Кодовая база очищена от оставшегося legacy eager-export поведения.
- Все существующие export/delivery tests зелёные, новые tests зелёные.

**Итог**
Первый проход улучшил архитектуру, но второй проход должен добить именно те места, где новое API уже появилось, а старые memory patterns ещё живы. Только после этого экспорт можно считать действительно каноническим и production-safe на реальных устройствах.

------

**ТЗ**
Блокирующих продуктовых вопросов больше нет.

**Цель**
Канонически переработать архитектуру экспорта так, чтобы:
- убрать OOM/jetsam на реальных устройствах
- сохранить максимальное качество финального видео
- не допускать автоматической грубой деградации качества
- при нехватке бюджета предлагать более лёгкий preset
- полностью остановить preview/playback на время экспорта
- после экспорта возвращать editor в `idle`
- удалить весь legacy, связанный с eager preload / live-preview coupling / старым export-memory поведением

**Корень проблемы по реальному коду**
- all-scenes-at-once timeline export в [TimelineCompositionEngine.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/TimelineComposition/TimelineCompositionEngine.swift#L1033)
- unbounded export texture caches в [ExportTextureProvider.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/ExportTextureProvider.swift#L45)
- export background preload через отдельный provider в [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift#L2463) и [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift#L3413)
- массовый `prepareAll()` video providers в [ExportVideoSlotsCoordinator.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/ExportVideoSlotsCoordinator.swift#L155)
- live preview texture injection в single-scene export в [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift#L2271) и timeline export session build в [TimelineCompositionEngine.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/TimelineComposition/TimelineCompositionEngine.swift#L1071)
- full-resolution background decode path в [BackgroundTextureService.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Background/BackgroundTextureService.swift#L93)

**Каноническая архитектура после рефакторинга**
- `PlayerViewController` отвечает за `export mode`, preflight и UI prompt на lower preset
- `VideoExporter` отвечает только за render/writer lifecycle
- single-scene export и timeline export работают не от live preview textures, а от export-safe media snapshots
- timeline export становится streaming:
  - максимум 1 resident scene в обычном кадре
  - максимум 2 resident scenes во время transition
- background/user photos грузятся через downsample-to-target-size до GPU upload
- video slot providers активируются лениво и в ограниченном количестве
- preview resources обязаны освобождаться до старта render loop

**Новые abstractions**
- Новый файл [ExportPreflightPlanner.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/ExportPreflightPlanner.swift)
  - считает `ExportResourceBudget`
  - принимает device, canvas, fps, preset, scene count, video slot count, background/media footprint
  - возвращает либо `safe plan`, либо `recommendedLowerPreset`
- Новый файл [ExportResourceBudget.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/ExportResourceBudget.swift)
  - поля: `maxResidentScenes`, `maxActiveVideoProviders`, `videoPrefetchFrames`, `maxFramesInFlight`, `targetImageMaxDimensionPx`
- Новый файл [ExportMediaSnapshot.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/ExportMediaSnapshot.swift)
  - export-safe snapshot пользовательских фото/видео/background refs
  - без зависимости от live `MTLTexture`
- Новый файл [TimelineExportResidencyController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/TimelineExportResidencyController.swift)
  - управляет resident scenes
  - загружает ресурсы только для текущей сцены/transition pair
  - освобождает предыдущие scene resources при eviction
- Новый shared utility [DownsampledImageLoader.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/UserMedia/DownsampledImageLoader.swift)
  - file-based decode через Image I/O
  - downsample до target max dimension до создания `UIImage`/`CGImage`/`MTLTexture`

**Изменения по файлам**

1. [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift)
- Добавить `enterExportMode()` и `exitExportModeToIdle()`
- `enterExportMode()` обязан:
  - вызвать `stopPlayback()` из [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift#L3494)
  - отменить `playbackStartTask`
  - освободить preview background textures через [BackgroundTextureService.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Background/BackgroundTextureService.swift#L163)
  - сбросить preview-only warm state timeline engine / userMedia preview playback
- Перед `enterExportMode()` построить export-safe snapshot:
  - single-scene: snapshot render state + media refs + video selections
  - timeline: lightweight timeline export descriptors + media refs
- Добавить preflight перед фактическим стартом export
- Если preflight unsafe:
  - не начинать export
  - показывать prompt с рекомендацией более лёгкого preset
- После terminal export result:
  - возвращать editor в idle
  - не восстанавливать playback автоматически
- Удалить из export flow прямую зависимость от live preview texture injection

2. [VideoExporter.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/VideoExporter.swift)
- Расширить оба public export API так, чтобы они принимали `ExportResourceBudget` и export-safe media inputs
- Single-scene path:
  - удалить `workItem.textureProvider.preloadAll(...)` из [VideoExporter.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/VideoExporter.swift#L525)
  - использовать targeted warm/load policy, а не preload всех asset IDs
- Export renderer создавать с `maxFramesInFlight` из budget, а не implicit default
- Добавить контролируемое освобождение export-only resources на terminal completion
- Export code не должен знать про prompt lower preset; это остаётся в `PlayerViewController`

3. [TimelineCompositionEngine.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/TimelineComposition/TimelineCompositionEngine.swift)
- Полностью переписать `buildExportSession()` в [TimelineCompositionEngine.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/TimelineComposition/TimelineCompositionEngine.swift#L1033)
- Новый export session должен быть lightweight:
  - оставить `transitionMath`, `renderState`, `videoSelections`, scene identity
  - убрать создание `ExportTextureProvider` per scene
  - убрать `preloadAll()`
  - убрать inject из live `layeredTextureProvider`
- `TimelineExportSceneSnapshot` в текущем виде больше не должен хранить:
  - preloaded `ExportTextureProvider`
  - тяжёлые export-ready scene resources, которые можно загрузить по требованию

4. [TimelineExportRuntime.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/TimelineExportRuntime.swift)
- Убрать init-паттерн “create coordinators for all scenes” из [TimelineExportRuntime.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/TimelineExportRuntime.swift#L38)
- Встроить `TimelineExportResidencyController`
- На каждом `resolveFrame`:
  - определить нужные scene instance IDs
  - гарантировать residency только для них
  - выгружать лишние scene resources
- Во время transition допускать максимум 2 resident scenes
- После eviction обязателен release scene texture provider, video coordinators, background bindings для этой сцены

5. [ExportTextureProvider.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/ExportTextureProvider.swift)
- Удалить API `preloadAll(commandQueue:)`
- Удалить идею “must be fully preloaded before export begins”
- Ввести targeted API:
  - `warm(assetIds:)`
  - `clear(assetIds:)` или `clearAll()`
- Provider должен быть рассчитан на scene-local residency, а не на whole-project preload
- Не держать unbounded cache на весь timeline export

6. [ExportVideoSlotsCoordinator.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/ExportVideoSlotsCoordinator.swift)
- Удалить `prepareAll()` из [ExportVideoSlotsCoordinator.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/ExportVideoSlotsCoordinator.swift#L158)
- Удалить fixed `visibilityPrefetchMarginSeconds = 1.0` из [ExportVideoSlotsCoordinator.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/ExportVideoSlotsCoordinator.swift#L40)
- Перевести coordinator на budget-driven policy:
  - lazy prepare on first entry into active window
  - active window в кадрах из `ExportResourceBudget`
  - release provider when slot exits active window far enough
- Maximum active providers должен быть bounded

7. [ExportVideoFrameProvider.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/ExportVideoFrameProvider.swift)
- Добавить lifecycle:
  - `prepareIfNeeded()`
  - `suspend()`
  - `resume()`
  - `releaseDecodedState()`
- При suspend/release очищать:
  - `reader`
  - `output`
  - `lastTexture`
  - `pending`
- Provider не должен жить подготовленным весь экспорт, если block не нужен сейчас

8. [BackgroundTextureService.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Background/BackgroundTextureService.swift)
- Export path больше не должен использовать full-size `Data(contentsOf:) -> UIImage(data:)` в [BackgroundTextureService.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Background/BackgroundTextureService.swift#L93)
- Для export добавить file-based downsample path через `DownsampledImageLoader`
- Target max dimension брать из `ExportResourceBudget`
- Background textures должны загружаться только под фактический export size с небольшим safety margin под crop/transform

9. [UserMediaTextureFactory.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/UserMedia/UserMediaTextureFactory.swift)
- Убрать fixed-only policy `4096` как единственный sizing rule в [UserMediaTextureFactory.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/UserMedia/UserMediaTextureFactory.swift#L33)
- Ввести shared sizing contract:
  - preview sizing policy
  - export sizing policy
- Экспорт должен использовать target size based on output resolution, а не original image size

10. [UserMediaService.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/UserMedia/UserMediaService.swift)
- Добавить export-safe snapshot API для photo/video media
- Export не должен зависеть от runtime `MTLTexture`, injected в preview
- Использовать persisted media refs из flow, который уже сохраняет user media в [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift#L2689) и [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift#L2729)

**Legacy, который нужно удалить**
- [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift#L3413) `preloadBackgroundTexturesForExport(...)`
- [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift#L2271) live `exportTP.injectTextures(from: mainTextureProvider, ...)` как источник export media
- [TimelineCompositionEngine.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/TimelineComposition/TimelineCompositionEngine.swift#L1068) all-scenes `preloadAll()`
- [TimelineCompositionEngine.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/TimelineComposition/TimelineCompositionEngine.swift#L1071) inject from live preview provider
- [ExportTextureProvider.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/ExportTextureProvider.swift#L114) `preloadAll`
- [ExportVideoSlotsCoordinator.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/ExportVideoSlotsCoordinator.swift#L158) `prepareAll`
- fixed prefetch constant in [ExportVideoSlotsCoordinator.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/ExportVideoSlotsCoordinator.swift#L40)
- export reliance on `ThreadSafeInMemoryTextureProvider` as whole-export background cache in [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift#L2463)
- stale docs/comments describing preload-all / old request-cancel behavior in [CODE_AUDIT_BASELINE.md](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/Docs/CODE_AUDIT_BASELINE.md)

**Тесты**
- Новый [ExportPreflightPlannerTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/ExportPreflightPlannerTests.swift)
  - safe plan for normal project
  - recommended lower preset for unsafe project/device
- Новый [TimelineExportResidencyControllerTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/TimelineExportResidencyControllerTests.swift)
  - at most 1 resident scene in single mode
  - at most 2 resident scenes in transition mode
  - previous scenes evicted correctly
- Новый [ExportTextureProviderTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/ExportTextureProviderTests.swift)
  - no preload-all API
  - targeted warm/clear
  - cache residency bounded to active scene
- Обновить [ExportVideoSlotsCoordinatorTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/ExportVideoSlotsCoordinatorTests.swift)
  - lazy prepare
  - provider release on window exit
  - bounded active provider count
- Новый [DownsampledImageLoaderTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/DownsampledImageLoaderTests.swift)
  - decode respects target max dimension
  - does not require full-size `UIImage(data:)` path
- Новый [PlayerExportModeTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/PlayerExportModeTests.swift)
  - export stops playback
  - preview resources torn down before render loop
  - editor returns to idle after terminal export result
  - lower preset prompt shown on unsafe preflight
- Сохранить и прогнать все существующие export tests:
  - [VideoExportSessionTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/VideoExportSessionTests.swift)
  - [ExportWriterPipelineTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/ExportWriterPipelineTests.swift)
  - [ExportRequestGatingTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/ExportRequestGatingTests.swift)
  - [ExportDeliveryPlayerFlowTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/ExportDeliveryPlayerFlowTests.swift)

**Acceptance Criteria**
- Export больше не preload-ит все scene resources upfront.
- Timeline export удерживает максимум 2 сцены одновременно.
- Export не зависит от live preview textures.
- Preview/playback полностью останавливаются перед export.
- Preview-only resources выгружаются до старта render loop.
- Background/user photos грузятся через downsample-to-target-size.
- `prepareAll()` для video providers отсутствует.
- Export quality автоматически не понижается без согласия пользователя.
- Если preset unsafe, пользователь получает предложение более лёгкого preset.
- После export editor возвращается в idle.
- Delivery to Photos продолжает работать как сейчас.
- В кодовой базе не остаётся legacy preload-all / whole-export caches / stale docs.
- Все существующие tests зелёные, новые residency/preflight/downsample tests зелёные.
- Manual device verification проходит на тяжёлых проектах без jetsam.

**Итог**
Это не локальный bugfix. Это полный refactor export architecture:
- `PlayerViewController` -> export mode + preflight + idle restore
- `VideoExporter` -> render/writer only
- `Timeline export` -> streaming residency instead of all-scenes preload
- `User media/backgrounds` -> export-safe snapshots + bounded downsampled loading
- `Video slot decode` -> lazy, bounded, evictable

Именно такой рефакторинг решит OOM канонически и одновременно очистит кодовую базу от legacy.