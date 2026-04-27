# task-prs.md

Этот документ — execution plan для [task.md](task.md).

`task.md` фиксирует final product contract и final architecture contract.
Этот документ фиксирует только:

- канонический порядок PR-шагов;
- write scope по реальному коду;
- acceptance criteria;
- минимальные test gates до merge.

## 0. Baseline

- На `2026-04-22` локальный baseline green:
  `bash Scripts/run_animiapp_tests.sh`
  ->
  `1219 tests, 0 failures`.
- Дальнейшие PR не должны ломать этот baseline.
- Каждый PR должен быть behavior-preserving, если acceptance явно не требует смены контракта.

## 1. Merge Rules

- Не делать extension-shuffle вместо реального domain split.
- Не создавать новый giant type взамен старого giant type.
- Каждый PR должен вводить явный owner и удалять ambiguity ownership-а.
- Тесты на новый contract должны ехать в том же PR, где меняется contract.
- Временные compatibility shims допустимы только если они уменьшают migration risk и имеют понятную точку удаления.

## 2. PR Sequence

### PR 1: Export Artifact And Delivery Policy Split

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

### PR 2: Background Domain Contract And Scope Resolution

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

### PR 3: Audio Domain Contract And Compatibility Layer

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

Test gates:
- `bash Scripts/run_animiapp_tests.sh`
- update `ProjectMusicTrackTests`
- update `MusicTimelineInteractionTests`
- update `MusicExportBridgeTests`
- add tests на role metadata и compatibility path

### PR 4: VideoExporter Facade

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

### PR 5: Timeline Export Session Builder Extraction

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

### PR 6: TimelineCompositionEngine Internal Split

Scope:
- `AnimiApp/Sources/Player/TimelineComposition/*`

Acceptance:
- разнесены frame resolution, residency/budget и playback sync
- `TimelineCompositionEngine` — facade, а не god object

Test gates:
- `bash Scripts/run_animiapp_tests.sh`
- update timeline composition / transition / exporter resolution suites

### PR 7: Scene Edit Tool Architecture

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

### PR 8: EditorRuntime Thinning

Scope:
- `AnimiApp/Sources/EditorRuntime/EditorRuntime.swift`
- new extracted runtime modules

Acceptance:
- runtime в основном маршрутизирует state/output
- background/audio/export/scene-edit orchestration больше не сидят в одном типе

Test gates:
- `bash Scripts/run_animiapp_tests.sh`
- update runtime mutation / export restore / bridge suites

### PR 9: EditorViewController Thinning

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
