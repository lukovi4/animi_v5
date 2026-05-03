# task-prs.md

Этот документ — execution plan для [task.md](task.md).

`task.md` фиксирует final product contract и final architecture contract.
Этот документ фиксирует только:

- канонический порядок PR-шагов;
- write scope по реальному коду;
- acceptance criteria;
- минимальные test gates до merge.

## 0. Baseline

- Исторический baseline на `2026-04-22`:
  `bash Scripts/run_animiapp_tests.sh`
  ->
  `1219 tests, 0 failures`.
- Актуальный integration baseline на `2026-04-27` после commit `a7c45b4`:
  `bash Scripts/run_animiapp_tests.sh`
  ->
  `1265 tests, 0 failures, 1 skipped`.
- Актуальный playback-transport baseline на `2026-04-28` после commit `88e79c7`:
  `bash Scripts/run_animiapp_tests.sh`
  ->
  `1275 tests, 0 failures, 1 skipped`.
- Актуальный preview-audio baseline на `2026-05-01` после commit `e26e05e`:
  `bash Scripts/run_animiapp_tests.sh`
  ->
  `1305 tests, 0 failures, 2 skipped`.
- Актуальный scene-edit/module baseline на `2026-05-03` после `PR8 + PR9`:
  `bash Scripts/run_animiapp_tests.sh`
  ->
  `1317 tests, 0 failures, 2 skipped`.
- Дальнейшие PR не должны ломать актуальный baseline `1317 / 0 / 2`.
- Каждый PR должен быть behavior-preserving, если acceptance явно не требует смены контракта.

## 0.1 Current Status

- Закрыты:
  - `PR 1: Export Artifact And Delivery Policy Split`
  - `PR 2: Background Domain Contract And Scope Resolution`
  - `PR 4: VideoExporter Facade`
  - `PR 5: Timeline Export Session Builder Extraction`
  - `PR 6: Playback Transport And Timebase Refactor`
  - `PR 7: Preview Audio Transport Integration`
  - `PR 8: TimelineCompositionEngine Internal Split`
  - `PR 9: Scene Edit Tool Architecture`
- Внутри integration milestone дополнительно закрыт integration tail между `PR1–PR4`:
  - runtime/controller/output export delivery contract
  - scene background production edit/persistence/export path
  - per-scene timeline export background contract
  - timeline preview background switching
- Внутри committed `PR 6` закрыт transport/video playback-owner path:
  - runtime-owned `PlaybackTransport`
  - mirrored store playhead without runtime re-entry during playback
  - shared host-time preview contract for timeline/video path
- Preview audio transport integration доведен отдельной линией после `PR 6`:
  - transport-driven preview music path committed в production code
  - direct scheduled-start contract закрыт follow-up `PR7.1`
  - readiness barrier и stale-host-time crash закрыты follow-up `PR7.2`
- `PR 3` не закрыт как canonical done:
  - compatibility groundwork частично присутствует
  - production runtime/export audio contract все еще опирается на music bridge
- Следующий канонический PR по sequence:
  - `PR 10: EditorRuntime Thinning`

## 1. Merge Rules

- Не делать extension-shuffle вместо реального domain split.
- Не создавать новый giant type взамен старого giant type.
- Каждый PR должен вводить явный owner и удалять ambiguity ownership-а.
- Тесты на новый contract должны ехать в том же PR, где меняется contract.
- Временные compatibility shims допустимы только если они уменьшают migration risk и имеют понятную точку удаления.

## 2. PR Sequence

### PR 1: Export Artifact And Delivery Policy Split — DONE

Scope:
- `AnimiApp/Sources/EditorRuntime/EditorRuntime.swift`
- `AnimiApp/Sources/Export/ExportDeliveryCoordinator.swift`
- `AnimiApp/Sources/Export/*`
- relevant tests in `AnimiApp/Tests`

Новые seams:
- `render/export artifact`
- `delivery policy`
- destination chain `photoLibraryOnly`
- destination chain `photoLibraryThenShare`

Acceptance:
- export render success больше не hardcodes `.photoLibrary`
- social/share delivery не стартует без успешного `Save to Photos`
- file retention/cleanup принадлежит delivery layer
- render/export layer не знает destination-specific policy

Test gates:
- `bash Scripts/run_animiapp_tests.sh`
- update `ExportDeliveryCoordinatorTests`
- update `ExportDeliveryPlayerFlowTests`
- add tests на artifact retention/cleanup для share path

### PR 2: Background Domain Contract And Scope Resolution — DONE

Scope:
- `AnimiApp/Sources/Project/ProjectBackgroundOverride.swift`
- `AnimiApp/Sources/Background/EffectiveBackgroundBuilder.swift`
- `AnimiApp/Sources/Export/ExportBackgroundSnapshot.swift`
- `AnimiApp/Sources/Background/BackgroundTextureService.swift`
- `TVECore/Sources/TVECore/Models/Background/BackgroundRegionState.swift`
- `AnimiApp/Sources/EditorRuntime/EditorRuntime.swift`

Новые seams:
- `project background default`
- `scene background override`
- `effective background resolver`
- extensible background source taxonomy

Acceptance:
- effective chain выражен явно:
  `scene -> project -> template`
- scene custom background полностью заменяет project background для сцены
- contract больше не image-only
- image backend остается backend-ом, а не canonical whole-domain owner-ом

Test gates:
- `bash Scripts/run_animiapp_tests.sh`
- update `ExportMediaSnapshotTests`
- update `ExportBackgroundRestoreTests`
- add tests на `scene override fully replaces project background`

### PR 3: Audio Domain Contract And Compatibility Layer — OPEN

Scope:
- `AnimiApp/Sources/Project/CanonicalTimeline.swift`
- `AnimiApp/Sources/Project/TimelinePayload.swift`
- `AnimiApp/Sources/Editor/Store/EditorReducer.swift`
- `AnimiApp/Sources/Player/EditorViewController.swift`
- `AnimiApp/Sources/Editor/TimelineView.swift`
- `AnimiApp/Sources/EditorRuntime/EditorRuntime.swift`
- relevant export tests

Новые seams:
- generic audio items
- role metadata on audio payload/item
- compatibility bridge from current music-only behavior

Acceptance:
- canonical audio contract больше не выражается через `musicItem`/`musicPayload`
- runtime/export принимают generic audio snapshot/plan
- shipped v1 behavior не ломается

Current status:
- partial groundwork landed
- canonical generic audio contract still not closed
- current production bridge still treats music as the effective export/runtime path

Test gates:
- `bash Scripts/run_animiapp_tests.sh`
- update `ProjectMusicTrackTests`
- update `MusicTimelineInteractionTests`
- update `MusicExportBridgeTests`
- add tests на role metadata и compatibility path

### PR 4: VideoExporter Facade — DONE

Scope:
- `AnimiApp/Sources/Export/VideoExporter.swift`
- extracted exporter helpers/types
- relevant exporter tests

Acceptance:
- `VideoExporter` становится фасадом
- single-scene и timeline orchestration вынесены
- config/error definitions не висят вперемешку с runner logic

Test gates:
- `bash Scripts/run_animiapp_tests.sh`
- update `VideoExportSessionTests`
- update `VideoExporterTimelineExportSessionTests`

### PR 5: Timeline Export Session Builder Extraction — DONE

Scope:
- `AnimiApp/Sources/Player/TimelineComposition/TimelineCompositionEngine.swift`
- new export session builder files
- export session tests

Acceptance:
- `buildExportSession()` вынесен из giant engine type
- engine больше не owner тяжелого export snapshot assembly

Test gates:
- `bash Scripts/run_animiapp_tests.sh`
- update `TimelineCompositionEngineExportSessionTests`

### PR 6: Playback Transport And Timebase Refactor — DONE

Scope:
- `AnimiApp/Sources/EditorRuntime/EditorRuntime.swift`
- `AnimiApp/Sources/Player/TimelineComposition/TimelineCompositionEngine.swift`
- `AnimiApp/Sources/Player/TimelineComposition/SceneInstanceRuntime.swift`
- `AnimiApp/Sources/UserMedia/UserMediaService.swift`
- `AnimiApp/Sources/UserMedia/VideoFrameProvider.swift`
- `AnimiApp/Sources/EditorRuntime/PlaybackTransport.swift`
- relevant playback/video test suites

Acceptance:
- preview playback больше не двигается через `currentFrame + 1`
- `CADisplayLink` больше не является source of truth для playback time
- transport становится single owner timeline playback time
- mirrored store playhead не re-enters runtime presentation path during playback
- video/future animated visual consumers читают общий project playback time

Out of committed scope:
- `AnimiApp/Sources/EditorRuntime/PreviewAudioPlaybackController.swift`
- preview audio transport integration
- `markPreviewAudioDirty()` can remain no-op seam until dedicated follow-up PR

Test gates:
- `bash Scripts/run_animiapp_tests.sh`
- update playback / timeline runtime suites
- add regression tests for single-driver playback ownership

### PR 7: Preview Audio Transport Integration — DONE

Scope:
- `AnimiApp/Sources/EditorRuntime/PreviewAudioPlaybackController.swift`
- `AnimiApp/Sources/EditorRuntime/EditorRuntime.swift`
- audio-preview runtime wiring/tests

Acceptance:
- preview audio starts from shared transport-owned playback time
- steady-state preview audio не держится на periodic corrective seek loop
- `markPreviewAudioDirty()` получает runtime-owned invalidation/rebuild contract
- partial workspace-only audio preview seams становятся committed production code
- device-only preview audio AVPlayer crashes закрыты readiness/start-contract follow-up fix-ами

Test gates:
- `bash Scripts/run_animiapp_tests.sh`
- add/update audio preview runtime suites
- prove preview audio is compiled and wired through target, not only present in workspace
- manual iPhone smoke for preview music start/pause/resume/dirty-rebuild passes

### PR 8: TimelineCompositionEngine Internal Split — DONE

Scope:
- `AnimiApp/Sources/Player/TimelineComposition/*`

Acceptance:
- разнесены frame resolution, residency/budget и playback sync
- `TimelineCompositionEngine` — facade, а не god object

Test gates:
- `bash Scripts/run_animiapp_tests.sh`
- update timeline composition / transition / exporter resolution suites

### PR 9: Scene Edit Tool Architecture — DONE

Scope:
- `AnimiApp/Sources/Editor/SceneEdit/SceneEditInteractionController.swift`
- `AnimiApp/Sources/Editor/SceneEdit/InlineVideoTrimCoordinator.swift`
- scene-edit wiring in runtime/controller

Acceptance:
- scene-edit tooling собирается в feature module
- новый tool не требует правки giant controller/runtime

Test gates:
- `bash Scripts/run_animiapp_tests.sh`
- update scene-edit / trim / handoff tests

### PR 10: EditorRuntime Thinning — NEXT

Scope:
- `AnimiApp/Sources/EditorRuntime/EditorRuntime.swift`
- new extracted runtime modules

Acceptance:
- runtime в основном маршрутизирует state/output
- background/audio/export/scene-edit orchestration больше не сидят в одном типе

Test gates:
- `bash Scripts/run_animiapp_tests.sh`
- update runtime mutation / export restore / bridge suites

### PR 11: EditorViewController Thinning

Scope:
- `AnimiApp/Sources/Player/EditorViewController.swift`
- controller-facing presentation seams

Acceptance:
- controller становится thin UI shell
- flow-level orchestration и business branching вынесены

Test gates:
- `bash Scripts/run_animiapp_tests.sh`
- update lifecycle / UI routing / selection tests

## 3. Global Do-Not-Do List

- Не закапывать `Save to Photos` обратно внутрь render/export success path.
- Не переносить current `music` special case в новый тип под другим именем.
- Не фиксировать future background contract на image-only taxonomy.
- Не смешивать `project background` и `scene background` без явного effective resolver-а.
- Не возвращать scene-edit и background в один owner layer.

## 4. Done Condition

План считается выполненным, когда:

- `EditorViewController` — thin presentation shell
- `EditorRuntime` — facade/state machine
- `VideoExporter` — thin export facade
- `TimelineCompositionEngine` — facade над внутренними подсистемами
- `Audio` — generic domain, а не `project music`
- `Background` — отдельный domain с `project default` и `scene override`
- `Export` — artifact-first, destination-driven, с mandatory `Save to Photos -> share` policy для social path
