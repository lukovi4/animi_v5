**Техническое задание**

**Цель**
Довести экспорт до канонической архитектуры по реальному коду Animi, чтобы:
- не оставалось ложных `.cancelled`
- cancel во всех фазах работал только для текущего export request
- single-scene и timeline export имели одинаковый lifecycle contract
- UI реально отражал `preparing -> rendering -> finishing`
- не оставалось hidden/stale export после отмены или повторного запуска

**Аудированные subsystems и seams**
Затронуты:
- `Player`
- `Export`
- `TimelineComposition`
- `Background`
- `UserMedia`
- `TVECore`

Критичные seams:
- `Player <-> Export`
- `Background <-> Export`
- `TimelineComposition <-> Export`
- `AnimiApp <-> TVECore`

**Что уже правильно и не переписывать**
Оставить без архитектурных переделок:
- [VideoWriterPump.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/VideoWriterPump.swift)
- [AudioWriterPump.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/AudioWriterPump.swift)
- [ExportWriterPipeline.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/ExportWriterPipeline.swift) как writer/pump owner
- [TimelineExportRuntime.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/TimelineExportRuntime.swift)
- [AudioCompositionBuilder.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/AudioCompositionBuilder.swift)
- [ExportTextureProvider.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/ExportTextureProvider.swift)
- [ExportVideoSlotsCoordinator.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/ExportVideoSlotsCoordinator.swift)

**Оставшиеся реальные проблемы**
1. В [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift) cancel во время controller-side preload завязан на глобальный `isExporting`, а не на конкретный export request.
2. Там же progress/completion callbacks тоже не request-scoped и теоретически могут быть stale при overlapping requests.
3. В [VideoExporter.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/VideoExporter.swift) `activeSession` выставляется, но не очищается на terminal completion.
4. `.finishing` в [ExportProgressViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/ExportProgressViewController.swift) существует, но сейчас эмитится из controller уже после `.success`, а не перед реальным `finishWriting`.
5. `currentState` в [ExportProgressViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/ExportProgressViewController.swift) остаётся мёртвым state.
6. Тесты не покрывают overlap request A/B и не покрывают audio-enabled finish coordination в pipeline.

**Каноническая целевая архитектура**
Экспорт должен быть разделён на 2 owner-слоя:

1. `Player-side export launch owner`
- отвечает за UI modal
- отвечает за controller-side background preload
- отвечает за request identity до вызова `exportVideo` / `exportTimeline`

2. `Export-side session owner`
- начинается внутри [VideoExporter.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/VideoExporter.swift)
- владеет `ExportSession`
- владеет `ExportWriterPipeline`
- отвечает за `rendering -> finishing -> completed/failed/cancelled`

Глобальный `isExporting` не может быть source of truth для request identity.

---

**Изменения по файлам**

**1. Player export launch layer**
Файл: [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift)

Нужно убрать текущую модель:
- `isExporting`
- `videoExporter`
как два независимых состояния для export request

И заменить её на один request-scoped owner, например:
- `ActiveExportRequest`
- или `activeExportRequestId + videoExporter`

Канонический контракт:
- каждый запуск export получает новый `requestId`
- все async continuation paths обязаны проверять именно этот `requestId`
- старый request не может стартовать, слать progress или completion после того, как пользователь его отменил или начал новый

Обязательные изменения:
- `exportTapped()` должен guard-ить отсутствие активного request, а не просто `!isExporting`
- `onCancel` должен отменять только текущий request
- после `await preloadBackgroundTexturesForExport(...)` нужен guard не по `isExporting`, а по request identity
- `progress` callback должен игнорироваться, если request уже не текущий
- `completion` callback должен игнорироваться, если request уже не текущий
- cleanup `videoExporter = nil` / request clear должен происходить только если завершился текущий request

Канонический guard после preload:
- сравнение captured `requestId` с current active request
- плюс сравнение captured `exporter` с current exporter instance
- тот же паттерн для single-scene и timeline paths

**2. Export session ownership**
Файл: [ExportSession.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/ExportSession.swift)

Оставить текущую идею `ExportSession`, но довести контракт:
- session не отвечает за controller-side preload
- session отвечает только за exporter-internal lifecycle
- terminal completion остаётся exactly-once
- `requestCancel()` остаётся cooperative, не terminal
- добавить hook для terminal release owner-а exporter

Нужен явный callback вроде:
- `onTerminal: () -> Void`
или эквивалентный release hook

Он должен вызываться ровно один раз из `complete(with:)`.

**3. Exporter activeSession cleanup**
Файл: [VideoExporter.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/VideoExporter.swift)

Обязательные изменения:
- `activeSession` должен очищаться на любом terminal path:
  - success
  - failure
  - cancel
- нельзя держать stale `activeSession` после завершения export
- cleanup должен идти через session terminal hook, а не через случайные внешние присваивания

Также нужно:
- сохранить lock-protected доступ к `_activeSession`
- не возвращать `_isCancelled`-подобный legacy state
- не вводить второй terminal source of truth

**4. Реальный `.finishing` phase**
Файлы:
- [VideoExporter.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/VideoExporter.swift)
- [ExportSession.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/ExportSession.swift)
- [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift)
- [ExportProgressViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/ExportProgressViewController.swift)

Сейчас `.finishing` показывается уже после `.success`. Это неверно.

Нужен отдельный exporter-to-UI lifecycle callback, например:
- `phase: (ExportPhase) -> Void`
где минимум есть:
- `.preparing`
- `.rendering(progress: Double)`
- `.finishing`

Канонически:
- `PlayerViewController` показывает `.preparing` во время своего preload
- после старта exporter progress идёт как `.rendering`
- непосредственно перед `session.finishWriting()` exporter эмитит `.finishing`
- `.completed` и `.failed` остаются terminal UI states

Нельзя больше рисовать `.finishing` постфактум в completion handler.

**5. Progress VC cleanup**
Файл: [ExportProgressViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/ExportProgressViewController.swift)

Нужно:
- либо удалить `currentState` как dead code
- либо реально использовать его для dedupe repeated state transitions

Если dedupe не нужен, удалить.

**6. Не менять**
Не трогать как часть этого ТЗ:
- [TimelineExportRuntime.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/TimelineExportRuntime.swift)
- [VideoWriterPump.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/VideoWriterPump.swift)
- [AudioWriterPump.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/AudioWriterPump.swift)
- [AudioCompositionBuilder.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/AudioCompositionBuilder.swift)
- [ExportTextureProvider.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/ExportTextureProvider.swift)
- [ExportVideoSlotsCoordinator.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/ExportVideoSlotsCoordinator.swift)

---

**Legacy / dead code cleanup**
Удалить или заменить:
- global gating через `isExporting` как request guard в [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift)
- post-success fake `.finishing` update в completion handlers
- dead `currentState` в [ExportProgressViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/ExportProgressViewController.swift), если не будет реального использования

---

**Обязательные тесты**

**A. Новый request-scoped launch test suite**
Не писать тяжёлые VC unit tests.  
Вынести request-gating в маленький testable helper и покрыть его отдельно.

Нужны сценарии:
- cancel request A during preload -> start request B -> resumed task A must not start export
- stale progress from request A ignored after request B became current
- stale completion from request A ignored after request B became current
- only current request may clear active request/exporter state

**B. Export session/exporter tests**
Добавить:
- `VideoExporter` clears `activeSession` on success
- `VideoExporter` clears `activeSession` on failure
- `VideoExporter` clears `activeSession` on cancel
- terminal release hook fires exactly once

**C. UI phase tests**
Минимум на seam/helper уровне:
- `.finishing` emitted before terminal success callback
- `.finishing` is not emitted on cancel/failure if finish phase never started

**D. Pipeline tests**
В [ExportWriterPipelineTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/ExportWriterPipelineTests.swift) обязательно добавить:
- audio-enabled finish coordination
- finish waits for both pumps
- no duplicate terminal callback when audio + video both complete

**E. Regression tests**
Обязательно:
- single-scene export cancel during controller-side preload
- timeline export cancel during controller-side preload
- overlapping export requests A/B

---

**Acceptance Criteria**
- Cancel during background preload never starts export afterward.
- Это верно даже если пользователь сразу запускает новый export.
- Только текущий export request может слать progress/completion в UI.
- `ExportSession` остаётся единственным owner-ом exporter-internal lifecycle.
- `VideoExporter.activeSession` всегда очищается на terminal state.
- `.finishing` показывается до реального `finishWriting`, а не после success.
- No hidden export may continue after modal dismiss.
- No stale completion from old request may dismiss/override current export UI.
- Existing export tests remain green.
- Added request-overlap and audio-finish tests are green.

**Итог**
Канонический fix здесь не в очередном локальном `guard`, а в правильном разделении ownership:
- `Player` owns export launch request identity
- `VideoExporter` owns export session identity
- `ExportSession` owns exporter terminal lifecycle
- UI phase model идёт из реального exporter lifecycle, а не из post-hoc controller updates

Если хочешь, следующим сообщением я превращу это ТЗ в пошаговый implementation plan по файлам и порядку рефакторинга.