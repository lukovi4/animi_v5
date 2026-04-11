# Epic Q: Канонический refactor editor app-layer

Этот документ является финальной canonical-спецификацией refactor-а editor app-layer в `AnimiApp`.

Документ написан строго по текущему реальному коду приложения и фиксирует обязательный финальный результат:
- что реально существует в коде сейчас;
- какие архитектурные проблемы уже подтверждены кодом;
- какой именно должен быть конечный target-state;
- какие product-level изменения входят в финальный продукт сознательно;
- в каком порядке это должно быть внедрено без повторного structural rewrite.

Под "канонической архитектурой" здесь понимается не абстрактный rewrite под модный framework, а корректный ownership/state/lifecycle design внутри существующего стека:
- UIKit;
- Metal/`MTKView`;
- `TVECore`;
- существующие runtime/export/media services;
- существующий `EditorStore` / `EditorReducer` как важная внутренняя основа.

Этот эпик не про миграцию на SwiftUI, TCA, CoreData или другой стек. Он про то, чтобы текущая кодовая база получила правильные границы, единый source of truth и расширяемый final architecture contract.

Важное допущение для этого документа:

- приложение рассматривается как новое;
- сохранять локальные `draft` / `saved project` / index / media данные предыдущей архитектурной версии не требуется;
- backward compatibility для старых on-disk форматов не является целью;
- разрешено bump-нуть schema и storage layout, сбросить локальное хранилище и удалить legacy migration code, если это делает финальную архитектуру чище и каноничнее.
- `blank project` является обязательным shipped flow и стартует с отдельного специального starter `sceneType` из `SceneLibrary`;
- `duplicate project` является обязательным shipped flow и существует только как действие в `My Projects`;
- template preview остается shipped функциональностью;
- visual preview для `saved projects` не обязателен в текущем delivery, но future saved-project preview seam обязателен в архитектуре;
- audio V1 в текущем delivery это один project-level music track на весь ролик, при этом архитектура должна быть готова к future multi-item audio editor;
- text/sticker overlays входят в текущий delivery уже с timing, positioning и timeline editing.

## 1. Source Of Truth И Опора На Реальный Код

Ключевые файлы и подсистемы, на которые опирается этот документ:

- [`AnimiApp/project.yml`](AnimiApp/project.yml)
- [`AnimiApp/AnimiApp.xcodeproj/project.pbxproj`](AnimiApp/AnimiApp.xcodeproj/project.pbxproj)
- [`AnimiApp/Sources/App/AppDelegate.swift`](AnimiApp/Sources/App/AppDelegate.swift)
- [`AnimiApp/Sources/App/SceneDelegate.swift`](AnimiApp/Sources/App/SceneDelegate.swift)
- [`AnimiApp/Sources/Player/PlayerViewController.swift`](AnimiApp/Sources/Player/PlayerViewController.swift)
- [`AnimiApp/Sources/Editor/Store/EditorStore.swift`](AnimiApp/Sources/Editor/Store/EditorStore.swift)
- [`AnimiApp/Sources/Editor/Store/EditorReducer.swift`](AnimiApp/Sources/Editor/Store/EditorReducer.swift)
- [`AnimiApp/Sources/Editor/Store/EditorState.swift`](AnimiApp/Sources/Editor/Store/EditorState.swift)
- [`AnimiApp/Sources/Editor/Store/EditorAction.swift`](AnimiApp/Sources/Editor/Store/EditorAction.swift)
- [`AnimiApp/Sources/Project/ProjectDraft.swift`](AnimiApp/Sources/Project/ProjectDraft.swift)
- [`AnimiApp/Sources/Project/ActiveDraftSlot.swift`](AnimiApp/Sources/Project/ActiveDraftSlot.swift)
- [`AnimiApp/Sources/Project/SavedProjectRecord.swift`](AnimiApp/Sources/Project/SavedProjectRecord.swift)
- [`AnimiApp/Sources/Project/ProjectStore.swift`](AnimiApp/Sources/Project/ProjectStore.swift)
- [`AnimiApp/Sources/Project/CanonicalTimeline.swift`](AnimiApp/Sources/Project/CanonicalTimeline.swift)
- [`AnimiApp/Sources/Project/TimelinePayload.swift`](AnimiApp/Sources/Project/TimelinePayload.swift)
- [`AnimiApp/Sources/Project/ProjectBackgroundOverride.swift`](AnimiApp/Sources/Project/ProjectBackgroundOverride.swift)
- [`AnimiApp/Sources/Project/SceneState.swift`](AnimiApp/Sources/Project/SceneState.swift)
- [`AnimiApp/Sources/MediaIngest/SceneMediaSlot.swift`](AnimiApp/Sources/MediaIngest/SceneMediaSlot.swift)
- [`AnimiApp/Sources/Project/MediaRef.swift`](AnimiApp/Sources/Project/MediaRef.swift)
- [`AnimiApp/Sources/TemplatesCatalog/TemplateCatalog.swift`](AnimiApp/Sources/TemplatesCatalog/TemplateCatalog.swift)
- [`AnimiApp/Sources/TemplatesUI/TemplatesHomeViewController.swift`](AnimiApp/Sources/TemplatesUI/TemplatesHomeViewController.swift)
- [`AnimiApp/Sources/TemplatesUI/TemplateDetailsViewController.swift`](AnimiApp/Sources/TemplatesUI/TemplateDetailsViewController.swift)
- [`AnimiApp/Sources/TemplatesUI/PreviewVideoView.swift`](AnimiApp/Sources/TemplatesUI/PreviewVideoView.swift)
- [`AnimiApp/Sources/MyProjects/MyProjectsViewController.swift`](AnimiApp/Sources/MyProjects/MyProjectsViewController.swift)
- [`AnimiApp/Sources/Player/TimelinePlaybackCoordinator.swift`](AnimiApp/Sources/Player/TimelinePlaybackCoordinator.swift)
- [`AnimiApp/Sources/Player/TimelineComposition/TimelineCompositionEngine.swift`](AnimiApp/Sources/Player/TimelineComposition/TimelineCompositionEngine.swift)
- [`AnimiApp/Sources/Player/SceneRuntimeStateApplier.swift`](AnimiApp/Sources/Player/SceneRuntimeStateApplier.swift)
- [`AnimiApp/Sources/MediaIngest/MediaIngestCoordinator.swift`](AnimiApp/Sources/MediaIngest/MediaIngestCoordinator.swift)
- [`AnimiApp/Sources/MediaIngest/MediaRestoreCoordinator.swift`](AnimiApp/Sources/MediaIngest/MediaRestoreCoordinator.swift)
- [`AnimiApp/Sources/MediaIngest/MediaAssetStore.swift`](AnimiApp/Sources/MediaIngest/MediaAssetStore.swift)
- [`AnimiApp/Sources/Background/BackgroundTextureService.swift`](AnimiApp/Sources/Background/BackgroundTextureService.swift)
- [`AnimiApp/Sources/UserMedia/UserMediaService.swift`](AnimiApp/Sources/UserMedia/UserMediaService.swift)
- [`AnimiApp/Sources/Export/VideoExporter.swift`](AnimiApp/Sources/Export/VideoExporter.swift)
- [`Scripts/verify_module_boundary.sh`](Scripts/verify_module_boundary.sh)
- [`Scripts/verify_release_bundle.sh`](Scripts/verify_release_bundle.sh)
- [`TVECore/Package.swift`](TVECore/Package.swift)
- [`AnimiApp/Tests`](AnimiApp/Tests)
- [`.github/workflows/ci.yml`](.github/workflows/ci.yml)

## 2. Цель Эпика

Этот эпик обязан:

- разделить текущий god-object editor graph на канонические ownership boundaries;
- сделать `EditorSession` единственным owner-ом session lifecycle и authoritative editor state;
- сделать `EditorRuntime` единственным owner-ом runtime/playback/render/export state;
- убрать controller-owned business state;
- убрать feature-level зависимость от raw singleton access;
- полностью обновить архитектуру, а не обернуть legacy код новыми типами;
- удалить legacy code после замены seam-ов, а не держать dual-path implementation в финальном состоянии;
- не тащить compatibility baggage для старых локальных данных, если оно не нужно финальному продукту;
- подготовить архитектуру так, чтобы `blank project`, `duplicate project`, audio, overlays, template preview и future saved-project preview seam были встроены в final model, а не требовали второго architectural rewrite;
- сохранить и переиспользовать существующие lower-level subsystems там, где это не ломает ownership semantics.

## 3. Реальный Current-State Baseline

Этот раздел не нормализует код и не пытается его "перевести" в желаемую архитектуру. Он фиксирует то, что реально есть в репозитории сегодня.

### 3.1. Build/Test topology

- `AnimiApp` конфигурируется через [`project.yml`](AnimiApp/project.yml), а checked-in [`AnimiApp.xcodeproj`](AnimiApp/AnimiApp.xcodeproj/project.pbxproj) является generated artifact, который текущий CI пересобирает через `xcodegen`.
- В [`project.yml`](AnimiApp/project.yml) есть `AnimiAppTests` target и схема `AnimiApp`, в которую эти тесты включены.
- В репозитории уже есть значительный app-level test suite в [`AnimiApp/Tests`](AnimiApp/Tests).
- Текущий [`Makefile`](Makefile) не покрывает app-level tests: `make test` запускает только `swift test` в `TVECore`.
- Текущий CI в [`.github/workflows/ci.yml`](.github/workflows/ci.yml):
  - регенерирует `xcodeproj` через `xcodegen`;
  - билдит `TVECore`;
  - запускает `swift test` в `TVECore` со `--skip` для части тестов;
  - билдит iOS app;
  - проверяет release bundle topology;
  - не запускает `AnimiAppTests`.

Вывод: нижний test baseline уже есть, но canonical app-level validation loop пока не оформлен.

### 3.2. App bootstrap и entry flows

- [`AppDelegate`](AnimiApp/Sources/App/AppDelegate.swift) делает process-wide cache cleanup для `PhotoProxyCache.shared` и `VideoPosterCache.shared`.
- [`SceneDelegate`](AnimiApp/Sources/App/SceneDelegate.swift) самостоятельно:
  - загружает `BackgroundPresetLibrary.shared`;
  - создает `TemplatesHomeViewController`;
  - оборачивает его в `UINavigationController`;
  - при наличии `ProjectStore.shared.hasActiveDraft()` сразу открывает `PlayerViewController(entryContext: .resumeActiveDraft)`.
- Recovery prompt на launch сейчас отсутствует.
- `PlayerViewController` создается напрямую из:
  - [`SceneDelegate`](AnimiApp/Sources/App/SceneDelegate.swift)
  - [`TemplatesHomeViewController`](AnimiApp/Sources/TemplatesUI/TemplatesHomeViewController.swift)
  - [`CategoryTemplatesViewController`](AnimiApp/Sources/TemplatesUI/CategoryTemplatesViewController.swift)
  - [`TemplateDetailsViewController`](AnimiApp/Sources/TemplatesUI/TemplateDetailsViewController.swift)
  - [`MyProjectsViewController`](AnimiApp/Sources/MyProjects/MyProjectsViewController.swift)
- Единого `AppCompositionRoot` сейчас нет.

### 3.3. Текущий editor owner graph

[`PlayerViewController`](AnimiApp/Sources/Player/PlayerViewController.swift) сейчас является editor god object.

Он одновременно владеет:

- app entry adaptation через свой локальный `EntryContext`;
- загрузкой template/project content;
- созданием и поддержанием `ActiveDraftSlot`;
- полями sidecar state:
  - `currentProjectDraft`
  - `draftIsDirty`
  - `projectBackgroundOverride`
- `EditorStore`;
- `ScenePlayer`;
- `TimelinePlaybackCoordinator`;
- `TimelineCompositionEngine`;
- `UserMediaService`;
- `MediaIngestCoordinator`;
- `BackgroundTextureService`;
- `SceneEditInteractionController`;
- export orchestration;
- autosave/background save;
- close/save/discard;
- runtime bootstrap;
- render drawing decisions в `draw(in:)`.

Это и есть главная текущая архитектурная проблема: UI controller одновременно является root, session owner, runtime owner, persistence owner и orchestration layer.

### 3.4. Текущие persisted модели и уже существующие сильные стороны

В коде уже есть хороший persisted foundation:

- [`ProjectDraft`](AnimiApp/Sources/Project/ProjectDraft.swift):
  - `schemaVersion`
  - `id`
  - `templateId`
  - `name`
  - `createdAt`
  - `updatedAt`
  - `background`
  - `canonicalTimeline`
  - `sceneInstanceStates`
- [`SavedProjectRecord`](AnimiApp/Sources/Project/SavedProjectRecord.swift)
- [`ActiveDraftSlot`](AnimiApp/Sources/Project/ActiveDraftSlot.swift)
- [`CanonicalTimeline`](AnimiApp/Sources/Project/CanonicalTimeline.swift)
- [`TimelinePayload`](AnimiApp/Sources/Project/TimelinePayload.swift)
- [`SceneState`](AnimiApp/Sources/Project/SceneState.swift)
- [`ProjectBackgroundOverride`](AnimiApp/Sources/Project/ProjectBackgroundOverride.swift)

Это важный факт: текущая кодовая база уже не находится в состоянии "все нужно придумать с нуля". У нас уже есть базовая persisted domain-модель.

Но эта модель является reference baseline, а не compatibility contract. Финальный persisted model может быть перепроектирован, если это упрощает canonical architecture. Сохранять on-disk совместимость со старым локальным хранилищем не требуется.

Дополнительная важная база уже присутствует:

- `CanonicalTimeline` уже поддерживает `TrackKind.sceneSequence` и `TrackKind.audio`.
- `ItemKind` уже содержит `scene`, `audioClip`, `sticker`, `text`.
- `TimelinePayload` уже содержит `scene`, `audio`, `sticker`, `text`.
- В UI уже есть placeholders для `Text`, `Music`, `Sticker`:
  - [`GlobalActionBar`](AnimiApp/Sources/Editor/GlobalActionBar.swift)
  - [`TimelineView`](AnimiApp/Sources/Editor/TimelineView.swift)
  - [`ContextBar`](AnimiApp/Sources/Editor/ContextBar.swift)
- Уже реализовано `duplicateScene` на уровне reducer/store.

Вывод: final architecture должна опираться на существующую timeline/payload scaffold, а не выбрасывать ее.

### 3.5. Current-state defects в source of truth

Несмотря на сильную persisted основу, текущее ownership распределено неверно.

Подтвержденные проблемы:

- Persisted content раздвоен между `EditorStore.state.draft` и controller-owned sidecar state.
- `background` уже входит в `ProjectDraft`, но в editing/runtime flow живет отдельно в `projectBackgroundOverride`, а в authoritative draft вливается позже через `currentMergedDraft()`.
- Dirty state определяется не baseline comparison, а mutable флагом `draftIsDirty`.
- `currentProjectDraft` является вторым mutable cached draft, а не derived representation.
- `PlayerViewController.EntryContext` и persisted `EditorEntryContext` из [`ActiveDraftSlot`](AnimiApp/Sources/Project/ActiveDraftSlot.swift) дублируют друг друга как две близкие, но не единые модели входа.

Итог: сейчас в editor нет единого authoritative content state owner.

### 3.6. Current EditorStore semantics

[`EditorStore`](AnimiApp/Sources/Editor/Store/EditorStore.swift) и [`EditorReducer`](AnimiApp/Sources/Editor/Store/EditorReducer.swift) уже являются сильной частью architecture и должны быть сохранены.

Но в текущем виде:

- `EditorState` смешивает content state и interaction state.
- `EditorSnapshot` включает:
  - `playheadCompressedFrame`
  - `selection`
  - `sceneEditReturnCompressedFrame`
  - `timelineSceneSelectionMode`
- То есть interaction semantics частично включены в undo contract.

Это неканонично относительно финальной цели. Undo/redo должны восстанавливать persisted content, а не телепортировать пользователя между transient interaction states без явной причины.

### 3.7. Runtime, render и export baseline

В коде уже есть сильные runtime building blocks:

- [`TimelinePlaybackCoordinator`](AnimiApp/Sources/Player/TimelinePlaybackCoordinator.swift)
- [`TimelineCompositionEngine`](AnimiApp/Sources/Player/TimelineComposition/TimelineCompositionEngine.swift)
- [`SceneRuntimeStateApplier`](AnimiApp/Sources/Player/SceneRuntimeStateApplier.swift)
- [`UserMediaService`](AnimiApp/Sources/UserMedia/UserMediaService.swift)
- [`MediaIngestCoordinator`](AnimiApp/Sources/MediaIngest/MediaIngestCoordinator.swift)
- [`MediaRestoreCoordinator`](AnimiApp/Sources/MediaIngest/MediaRestoreCoordinator.swift)
- [`BackgroundTextureService`](AnimiApp/Sources/Background/BackgroundTextureService.swift)
- [`VideoExporter`](AnimiApp/Sources/Export/VideoExporter.swift)

Но они принадлежат неправильному owner-у.

Сейчас:

- `PlayerViewController` сам решает, какой runtime path активен.
- `PlayerViewController` сам orchestrate-ит scene-edit / timeline / export lifecycles.
- `draw(in:)` в controller сам выбирает, откуда брать render data.
- `VideoExporter`, `TimelineCompositionEngine`, `BackgroundTextureService`, `MediaAssetStore` и другие lower-level services получают raw `ProjectStore.shared` или прямой storage access.

Вывод: runtime machinery уже есть, но ему нужен правильный владелец и thin integration contract.

### 3.8. Persistence/media boundary defects

[`ProjectStore`](AnimiApp/Sources/Project/ProjectStore.swift) сейчас совмещает:

- active draft persistence;
- saved project persistence;
- index migration;
- schema purge;
- background image persistence;
- media file resolution;
- media file deletion;
- orphan GC.

Подтвержденные проблемы:

- `ProjectStore` слишком широк по ответственности.
- `ProjectStore.shared` используется как feature dependency.
- GC запускается через `Task.detached`.
- Все mutating storage/media effects не сведены к одному isolation boundary.
- Это особенно опасно для будущих `duplicate project`, audio assets и asset ownership semantics.

### 3.9. Catalog, My Projects и preview baseline

- [`TemplateCatalog`](AnimiApp/Sources/TemplatesCatalog/TemplateCatalog.swift) является bundle-backed singleton repository, зависящим от `SceneLibrary.shared`.
- Outside-editor preview сейчас реализован через packaged preview videos и [`PreviewVideoView`](AnimiApp/Sources/TemplatesUI/PreviewVideoView.swift).
- [`MyProjectsViewController`](AnimiApp/Sources/MyProjects/MyProjectsViewController.swift) показывает template title и template preview, а не project-specific preview.
- `My Projects` сейчас читает `ProjectStore.shared.allSavedProjectEntries()` напрямую.
- Project duplication flow на app-level сейчас отсутствует.
- Blank project flow на app-level сейчас отсутствует.

### 3.10. Missing media baseline

- `MediaRestoreCoordinator` и `UserMediaService` уже умеют восстанавливать media bindings и отмечать restore failures.
- `UserMediaService` уже содержит `restoreFailedBlockIds` и `hasFailedMedia`.
- Это хороший foundational behavior: editor уже способен жить с partially broken media state без обязательного hard crash.

Но:

- session-level product contract для missing-media сейчас не зафиксирован;
- `My Projects`, duplication и preview flows пока не имеют общего canonical behavior для missing-media cases.

### 3.11. Current behavior, который final product меняет сознательно

Финальный продукт не обязан буквально сохранять текущее runtime behavior. Он обязан сохранять все, кроме тех сценариев, которые этот документ сознательно переводит в новый target contract.

Подтвержденные divergences относительно текущего кода:

- Сейчас launch auto-resume-ит `active draft`; финальный продукт должен показывать explicit recovery prompt.
- Сейчас close всегда показывает `Save changes?`; финальный продукт должен различать clean/dirty session.
- Сейчас successful export materialize-ит saved project и затем снова сохраняет `active draft`; финальный продукт должен завершать save/export cycle clean-сессией без `active draft` до следующей content mutation.
- Сейчас dirty model sidecar-based; финальный продукт должен перейти на dual-baseline contract.

## 4. Архитектурные Принципы Final State

Финальная архитектура обязана соблюдать следующие правила:

- Один owner на одну категорию состояния.
- Один authoritative persisted content source of truth на весь editor session lifecycle.
- Controller не владеет business state и persistence semantics.
- Runtime state disposable и воспроизводим из session snapshot.
- Interaction state не равен persisted content.
- Persistence/media side effects идут через gateway boundaries, а не через feature-level singleton access.
- Все mutating storage/media operations сериализуются одним storage isolation boundary.
- Existing lower-level engines и services сохраняются, если интегрируются под новые ownership boundaries.
- `blank project`, `duplicate project`, audio, overlays, template preview и future saved-project preview seam являются обязательными архитектурными требованиями final state, а не необязательными пожеланиями.

## 5. Финальная Каноническая Архитектура

### 5.1. Top-level graph

Финальный top-level graph:

- `AppCompositionRoot`
- feature factories/use cases, создаваемые root-ом
- `EditorSession`
- `EditorRuntime`
- `EditorViewController`

Граница должна быть следующей:

- `AppCompositionRoot` собирает зависимости и entry flows.
- `EditorSession` владеет project/session lifecycle.
- `EditorRuntime` владеет runtime/render/export/media execution state.
- `EditorViewController` владеет только view lifecycle, input wiring и presentation.

### 5.2. AppCompositionRoot

`AppCompositionRoot` является единственной точкой сборки app-level dependencies.

Он обязан:

- создавать initial root controller для `SceneDelegate`;
- решать app launch flow, включая recovery prompt;
- создавать flows:
  - templates
  - template details
  - my projects
  - blank project
  - duplicate project
  - editor
  - template preview
  - future saved-project preview seam
- скрывать singleton-backed adapters за injected protocols;
- собирать gateway implementations поверх storage layer;
- обеспечивать, чтобы feature controllers/use cases не знали о `.shared`.

`SceneDelegate` после рефактора не должен:

- читать `ProjectStore.shared`;
- самостоятельно решать recovery;
- самостоятельно создавать `PlayerViewController`.

### 5.3. EditorSession

`EditorSession` является единственным owner-ом editor session lifecycle.

Его ответственность:

- bootstrap editor из launch intent;
- владение authoritative session state;
- владение baselines:
  - materialized baseline
  - recovery baseline
- dirty calculation;
- autosave/recovery writes;
- explicit save;
- export-save commit contract;
- close/discard semantics;
- active draft lifecycle;
- integration with saved project identity;
- blank project/session initialization;
- duplicate project session initialization;
- выдача runtime snapshots для `EditorRuntime`;
- выдача view-facing state projections для controller-а.

`EditorSession` может использовать `EditorStore` как внутреннюю implementation detail, но наружу должен выступать как canonical session boundary.

### 5.4. EditorRuntime

`EditorRuntime` является единственным owner-ом runtime execution state.

Его ответственность:

- управление playback/runtime lifecycle;
- orchestration между scene runtime и composition runtime;
- render source для `MTKView`;
- scene-edit runtime activation/deactivation;
- восстановление media и background textures;
- export preparation и export execution;
- принятие session snapshot и применение его к runtime engines;
- удержание и обновление render dependencies;
- runtime seam для outside-editor preview, в том числе будущего saved-project preview.

`EditorRuntime` должен переиспользовать существующие lower-level subsystems, а не переписывать их без причины:

- `TimelinePlaybackCoordinator`
- `TimelineCompositionEngine`
- `SceneRuntimeStateApplier`
- `UserMediaService`
- `MediaIngestCoordinator`
- `MediaRestoreCoordinator`
- `BackgroundTextureService`
- `VideoExporter`

### 5.5. EditorViewController

Финальный `EditorViewController` должен быть thin UI boundary.

Он обязан:

- владеть UIKit layout и presentation;
- показывать loader/errors/sheets/alerts;
- подписываться на session/runtime outputs;
- передавать user intents в `EditorSession`;
- рисовать через render contract от `EditorRuntime`;
- быть replaceable как view shell без потери business semantics.

Он не должен:

- хранить authoritative draft;
- держать dirty flags;
- решать save/export/persistence lifecycle;
- читать storage напрямую;
- принимать решения, какой runtime owner сейчас authoritative.

### 5.6. Outside-editor feature services

Вне editor должны существовать отдельные app-level services/use cases:

- `TemplateCatalogRepository`
- `SceneLibraryRepository`
- `BackgroundPresetRepository`
- `SavedProjectsService`
- `ProjectDuplicationUseCase`
- `BlankProjectFactory`
- `ProjectPreviewService`

Они должны использовать те же canonical gateways, что и editor, а не обращаться к editor internals.

### 5.7. Карта переноса ответственности из текущего кода

Обязательное целевое перераспределение:

- `PlayerViewController.loadEditorContent` -> `EditorSession.bootstrap`
- `PlayerViewController.saveDraftToActiveSlot` -> `EditorSession.persistRecoveryCheckpointIfNeeded`
- `PlayerViewController.handleExportSuccess` -> `EditorSession.commitAfterExportSuccess`
- `PlayerViewController.handleEditorClose` -> `EditorSession.requestClose` + view presentation logic
- controller-side background merge через `currentMergedDraft()` -> authoritative session content state
- `PlayerViewController.draw(in:)` и runtime branching -> `EditorRuntime` + render source contract
- `SceneDelegate` draft recovery logic -> root-managed app start flow
- `MyProjectsViewController` direct `ProjectStore` reads -> `SavedProjectsService`
- `ProjectStore.shared` в runtime/export/background/media helpers -> injected gateways

## 6. Финальный Product Contract

Этот раздел описывает финальный продукт. Это не "non-regression against current code", а обязательный target behavior.

### 6.1. Launch и recovery

- Если recovery state отсутствует, приложение открывается в обычный flow.
- Если recovery state существует, приложение до входа в обычный flow показывает recovery prompt.
- Recovery prompt имеет два действия:
  - `Continue`
  - `Start Over`
- `Continue` открывает recovery session.
- `Start Over` удаляет recovery state и возвращает пользователя в обычный стартовый flow.
- Auto-resume without prompt запрещен.

### 6.2. Session opening

Финальный продукт обязан поддерживать четыре first-class входа:

- открыть editor из template;
- открыть editor из saved project;
- открыть editor из recovery session;
- открыть blank project.

Дополнительно финальный продукт обязан поддерживать first-class `duplicate project` flow на app-level.

### 6.3. Save / export / close lifecycle

- В приложении существует только один глобальный recovery slot.
- Saved project и recovery slot являются разными сущностями.
- Explicit save:
  - обновляет текущий saved project, если session уже связана с ним;
  - материализует новый saved project, если session еще не была сохранена.
- Successful export считается сохранением проекта.
- После successful save/export текущая session считается clean.
- После successful save/export recovery slot удаляется.
- После successful save/export новый recovery slot создается лениво на следующей persisted content mutation.
- Если save/export завершился ошибкой, session остается открытой и не теряет состояние.
- При закрытии clean session editor закрывается без `Save / Don't Save / Cancel`.
- При закрытии dirty session editor показывает `Save / Don't Save / Cancel`.
- Для clean session, открытой из saved project или template, закрытие не должно оставлять ложный recovery slot.

### 6.4. Dirty state и undo/redo

- Dirty state определяется только persisted content changes.
- Dirty state не должен храниться mutable sidecar flag-ом в controller-е.
- Interaction state не делает проект dirty.
- Playhead, selection, `scene edit` enter/exit, fullscreen preview и похожие interaction actions не являются persisted content mutation.
- Undo/redo для persisted content должны работать независимо от transient interaction state.
- Content-changing actions обязаны быть undoable/redoable.

К content-changing actions относятся:

- add/delete/reorder/duplicate scene;
- trim scene;
- transition changes;
- background changes;
- media insert/remove/replace;
- media placement/visibility/video trim changes;
- audio clip add/remove/move/trim/volume changes;
- text/sticker add/remove/edit/move/trim changes;
- blank-project initial content materialization;
- duplicate-project content materialization, если она происходит внутри editor session.

### 6.5. Missing media behavior

- Project load не должен падать из-за отсутствующего media file.
- Missing media должно быть non-blocking state, а не fatal state.
- `EditorSession` должна владеть missing-media summary и явно сообщать пользователю о наличии missing media при open/reopen flow.
- Missing-media notice не должен блокировать открытие проекта, если редактор все еще может быть показан в деградированном состоянии.
- `EditorRuntime` / export preflight должны блокировать export, если для текущего результата не хватает обязательных media dependencies.
- Duplicate project при наличии missing media должен сохранять это состояние честно и предсказуемо.
- Missing-media state должен честно переживать save/reopen/duplicate, а не теряться между слоями.

### 6.6. Project independence

Финальный продукт обязан гарантировать независимость проектов:

- сохранение одного проекта не должно мутировать другой;
- удаление одного проекта не должно ломать другой;
- duplicate project создает независимый проект с новым project identity;
- duplicate project не может зависеть от того, что source project продолжает существовать на диске;
- blank project не должен требовать synthetic template hack, скрытый от архитектуры.

### 6.7. Blank project

`Blank project` является обязательным final-scope feature.

Contract:

- у пользователя есть явная точка входа в `blank project`;
- editor открывается с новым проектом, который стартует не пустым timeline, а с одной минимальной стартовой сценой-заглушкой;
- стартовая сцена-заглушка является отдельным специальным `sceneType` в `SceneLibrary`, а не synthetic runtime hack;
- timeline стартует с этим специальным starter scene instance;
- специальный starter `sceneType` скрыт из обычного `Add Scene` catalog flow;
- это скрытие задается explicit scene-library metadata/usage contract, а не ad-hoc фильтром по hardcoded ID в UI;
- пользователь может дальше добавлять и заменять сцены через уже существующий scene catalog flow;
- blank project имеет first-class persisted model, а не fake template masquerade.

### 6.8. Duplicate project

`Duplicate project` является обязательным final-scope feature.

Contract:

- пользователь может дублировать saved project только из `My Projects`;
- дубликат получает новый project ID;
- дубликат получает собственную persisted identity и собственный save lifecycle;
- контент дубликата независим от source project;
- missing-media state и asset ownership дубликата ведут себя предсказуемо;
- duplicate project не является editor action; scene duplication внутри editor не заменяет project duplication на app-level.

### 6.9. Audio V1

Audio V1 является обязательным final-scope.

Contract:

- финальная поставка включает один project-level music track на весь ролик;
- пользователь может:
  - выбрать или импортировать один music asset;
  - удалить music asset;
  - настроить громкость;
  - настроить start/end trim для project-level playback window;
- audio V1 участвует в dirty/undo/save/duplicate/export flows;
- persisted model и editor/runtime boundaries должны строиться поверх существующего `CanonicalTimeline` / `TrackKind.audio` / `TimelinePayload.audio`;
- при этом архитектура не должна зашивать ограничение "только один music item навсегда": future multi-item audio editor должен добавляться без structural rewrite.

### 6.10. Text и sticker overlays

Text и sticker overlays являются обязательным final-scope.

Contract:

- overlays не остаются placeholder-only;
- text/sticker должны быть:
  - сериализуемы;
  - редактируемы;
  - позиционируемы;
  - таймируемы на timeline;
  - previewable;
  - exportable;
  - корректно участвовать в dirty/undo/save/duplicate flows.

### 6.11. Preview вне editor

Preview вне editor является обязательным architecture requirement, но не весь preview scope обязателен в текущей продуктовой поставке.

Contract:

- outside-editor preview не зависит от editor controller internals;
- preview service строится поверх runtime/render services, а не через дублирование логики;
- template previews являются обязательной shipped возможностью и могут продолжать использовать packaged preview videos там, где это выгодно;
- visual preview для `saved projects` не является обязательным в текущем delivery;
- при этом в архитектуре обязателен future saved-project preview seam, чтобы project-specific preview можно было добавить позже без structural rewrite;
- `My Projects` не должен зависеть от template preview как от корректностного product contract: допустимы placeholder/no-preview presentation для saved projects в текущем delivery.

## 7. Каноническая Domain И State Model

### 7.1. Persisted project document

Финальный persisted project document должен опираться на сильные идеи текущего [`ProjectDraft`](AnimiApp/Sources/Project/ProjectDraft.swift), но не обязан сохранять on-disk совместимость со старой архитектурной версией.

Обязательные свойства:

- сохранить текущую основу:
  - `schemaVersion`
  - `id`
  - `name`
  - `createdAt`
  - `updatedAt`
  - `background`
  - `canonicalTimeline`
  - `sceneInstanceStates`
- ввести first-class project origin model:
  - template-based project
  - blank project
- перестать делать `templateId` единственным способом описать происхождение проекта;
- ввести нормализованный metadata layer для listing/open и future preview:
  - `ProjectOrigin`
  - preview metadata v2
  - saved-project listing metadata, не завязанную только на `sourceTemplateId`;
- нормализовать `ActiveDraftSlot`, чтобы он нес session launch/origin contract без дублирования ad-hoc полей.

Разрешенный путь внедрения:

- использовать существующий `ProjectDraft` как structural reference;
- bump-нуть schema/storage format;
- удалить поддержку старых локальных форматов;
- при несовместимости сбрасывать старые локальные данные вместо написания migration layer;
- перестроить `SavedProjectRecord` и `SavedProjectIndexEntry` вместе с новым `ProjectOrigin` contract.

### 7.2. Asset identity vs usage

Финальный проект обязан развести asset identity и asset usage.

Сейчас usage points напрямую несут storage-level reference:

- background regions через `ProjectBackgroundOverride.RegionOverride.imageMediaRef`
- scene media через `SceneMediaSlot.asset.mediaRef`
- project-level music asset в audio V1 и future per-item audio usage

Это недостаточно для canonical project independence.

Финальный contract:

- persisted content usage ссылается на logical project asset identity;
- storage locator знает, как превратить logical asset identity в физический URL;
- usage-specific поля остаются на usage level:
  - background transform
  - scene media placement
  - video trim/audio params
  - visibility
  - project-level music trim/volume
  - future audio volume/timing per item
  - text/sticker payload data
- duplicate project больше не зависит от случайной совместимости относительных путей.

К моменту shipped duplication конечный результат обязан убрать model-level зависимость от "путь на диске как единственная identity" для background и scene media. Audio V1 должен использовать тот же asset identity contract, а не новый path-based special case.

### 7.3. Session state

Финальный `EditorSessionState` должен содержать:

- authoritative persisted content state;
- linked saved project identity;
- session launch origin;
- materialized baseline;
- recovery baseline;
- missing-media summary и user-visible notice state;
- interaction state;
- immutable session dependencies:
  - template/catalog metadata
  - scene library snapshot
  - fps/canvas-related immutable config

Interaction state должна быть отделена от persisted content.

Она включает, по текущему коду, как минимум:

- `playheadCompressedFrame`
- `selection`
- `timelineSceneSelectionMode`
- `uiMode`
- `selectedBlockId`
- `sceneEditReturnCompressedFrame`

### 7.4. Dual-baseline contract

Финальная dirty/persistence model обязана использовать две baseline категории:

- `materializedBaseline`
  - последний explicit durable state после save/export
  - отвечает на вопрос: есть ли unsaved project changes для пользователя
- `recoveryBaseline`
  - последний state, записанный в recovery slot
  - отвечает на вопрос: нужно ли писать новый recovery checkpoint

Следствия:

- `isDirtyForUser` не равен "нужен autosave";
- clean session после successful save/export не обязана иметь recovery slot;
- autosave/recovery могут работать чаще, чем explicit save, и не должны переопределять user-facing materialized baseline.

### 7.5. Undo snapshot contract

Финальный undo snapshot обязан быть content-oriented.

Он включает:

- `canonicalTimeline`
- `sceneInstanceStates`
- `background`
- persisted asset references/registry
- и другие persisted content fields

Он не включает:

- playhead;
- current selection;
- fullscreen preview state;
- transient sheet/panel state;
- controller presentation state.

Допустимы отдельные interaction restoration rules там, где это повышает UX, но это не должно быть частью persisted content undo contract.

### 7.6. Runtime state

`EditorRuntimeState` является derived/disposable state.

Он может содержать:

- active scene runtime;
- composition runtime;
- render texture state;
- playback state;
- media restore state;
- export session state;
- export preflight state, в том числе missing required media gate;
- preview-only runtime state;
- scene-edit runtime state.

Но он не является persisted content source of truth.

### 7.7. View state

Чисто view/presentation state должна остаться на UI boundary:

- loading spinners;
- action sheets;
- alerts;
- progress overlays;
- presented fullscreen controllers;
- visibility/layout details.

Она не должна жить в storage/session gateways.

## 8. Канонические Gateway И Service Contracts

### 8.1. ProjectPersistenceGateway

Обязательные обязанности:

- read/write/delete recovery slot;
- read/write/delete saved projects;
- list saved projects;
- read/write listing metadata для `My Projects` и preview;
- reset incompatible local persisted data;
- commit explicit save/export result;
- дать единый serialization boundary для project document writes.

Этот gateway может первоначально быть backed текущим `ProjectStore`, но финально наружу не должен торчать raw `ProjectStore`.

### 8.2. ProjectMediaLocator

Обязанности:

- разрешать logical asset identity в physical URL;
- проверять доступность media;
- предоставлять runtime/export/background/media restore code только read-side contract;
- поддерживать export-side helpers вроде `ExportMediaSnapshot` и `ExportBackgroundSnapshot` без прямой зависимости от `ProjectStore.absoluteURL(for:)`;
- исключить прямую зависимость lower-level services от `ProjectStore.shared`.

### 8.3. ProjectMediaWriteGateway

Обязанности:

- импортировать scene media;
- импортировать background media;
- импортировать project-level music assets;
- быть готовым к future per-item audio asset writes;
- копировать или связывать assets для duplicate project;
- безопасно удалять/освобождать project-owned assets;
- запускать cleanup/GC под единым storage isolation boundary.

`Task.detached` как storage ownership strategy в финальном состоянии запрещен.

### 8.4. TemplateCatalogRepository

Обязанности:

- load/reload template catalog;
- получить template by id;
- получить scene defaults для template;
- скрыть `TemplateCatalog.shared` за injected contract.

### 8.5. SceneLibraryRepository

Обязанности:

- load/reload scene library snapshot и scene entry metadata;
- предоставить scene catalog entries для обычного `Add Scene` flow;
- держать special starter-only scene types адресуемыми для `BlankProjectFactory`, но скрытыми для обычного scene catalog;
- скрыть зависимость от `SceneLibrary.shared` за injected contract.

### 8.6. BackgroundPresetRepository

Обязанности:

- load/reload preset catalog из bundle-backed source;
- предоставить preset metadata для background editor и effective background builder;
- скрыть `BackgroundPresetLibrary.shared` за injected contract;
- не допускать, чтобы bootstrap/editor/background flows читали `BackgroundPresetLibrary.shared` напрямую.

### 8.7. SavedProjectsService

Обязанности:

- list saved projects для `My Projects`;
- delete saved project;
- duplicate saved project;
- подготовить open intent для editor;
- выдать listing metadata;
- выдать optional preview/placeholder metadata без зависимости от template preview как source of truth.

`MyProjectsViewController` не должен читать `ProjectStore` напрямую.

### 8.8. ProjectDuplicationUseCase

Обязанности:

- прочитать source saved project;
- создать новый saved project с новым ID;
- корректно перенести content, baselines и asset ownership;
- сохранить project independence semantics;
- сообщить UI о результате без знания editor internals.

### 8.9. BlankProjectFactory

Обязанности:

- создать canonical initial document для blank project;
- создать initial timeline с одним специальным starter `sceneType` из `SceneLibrary`;
- не подменять blank project fake template ID без explicit model contract;
- интегрироваться с теми же save/duplicate/preview gateways, что и template-based projects.

### 8.10. ProjectPreviewService

Обязанности:

- отдавать preview data для templates;
- держать extension seam для future saved-project preview;
- использовать runtime/render services там, где позже понадобится project-specific preview;
- позволять UI выбрать легкий способ отображения:
  - packaged preview video
  - poster image
  - optional no-preview placeholder
  - future generated video / live read-only runtime surface

Важное правило: preview logic не должна дублироваться отдельно от canonical runtime model.

## 9. Ограничения На Reuse И Rewrite

### 9.1. Legacy removal policy

Этот эпик не допускает финального состояния вида "новая архитектура поверх старой архитектуры".

Обязательные правила:

- если новый canonical owner уже введен, старая ownership role должна быть удалена;
- временные adapters допустимы только как краткоживущие rollout seams;
- временный adapter не должен переживать следующий PR, если replacement path уже стабилизирован;
- каждый PR должен явно указывать:
  - какой новый seam введен;
  - какой legacy seam удален в этом же PR или в следующем строго зафиксированном PR;
- финальный результат обязан удалить:
  - legacy session lifecycle из controller-а;
  - legacy singleton access paths;
  - legacy persistence compatibility code;
  - legacy on-disk migration code, если оно больше не нужно финальной storage model.

Legacy код не должен сохраняться "на всякий случай".

### 9.2. Reuse policy

Этот эпик не должен переписывать нижний слой без необходимости.

Должны быть переиспользованы, если не обнаружен прямой structural blocker:

- `EditorStore`
- `EditorReducer`
- `TimelinePlaybackCoordinator`
- `TimelineCompositionEngine`
- `SceneRuntimeStateApplier`
- `UserMediaService`
- `MediaIngestCoordinator`
- `MediaRestoreCoordinator`
- `BackgroundTextureService`
- `VideoExporter`
- `PreviewVideoView`

Ожидаемый подход:

- выделить правильного owner-а;
- адаптировать зависимости;
- очистить direct storage access;
- нормализовать lifecycle;
- не писать большие rewrite-ы там, где уже есть работающий lower-level слой.

## 10. Execution Plan По PR Шагам

Все нижеприведенные PR-шаги обязательны. Они нужны не для уменьшения конечного scope, а для того, чтобы довести до полного final product без промежуточного архитектурного хаоса.

Общие правила rollout:

- каждый PR должен оставлять репозиторий в компилируемом и тестируемом состоянии;
- каждый PR должен иметь один понятный ownership результат;
- если PR вводит новый canonical seam, он должен либо сразу удалить старый seam, либо явно ограничить срок жизни transition layer следующим PR;
- финальный rollout не должен оставлять permanent dual-path architecture.

### PR 0. Validation And Guardrails

Обязательные результаты:

- добавить repo-owned wrapper для app-level tests, например `Scripts/run_animiapp_tests.sh`;
- зафиксировать canonical local loop:
  - `Scripts/verify_module_boundary.sh`
  - `cd TVECore && swift test`
  - app-level tests через wrapper
  - build app
- привести CI к тому, чтобы app-level tests действительно запускались;
- сохранить `project.yml` как source of truth для app project generation.

На выходе PR нельзя оставлять:

- ad-hoc ручные `xcodebuild test` команды как единственный способ гонять app tests;
- CI, который считает editor refactor green без app-level unit tests.

### PR 1. AppCompositionRoot, Launch Routing И Recovery Prompt

Цель: убрать прямое создание editor из feature controllers и `SceneDelegate` и сразу реализовать launch-level recovery flow.

Обязательные результаты:

- введен `AppCompositionRoot`;
- `SceneDelegate` получает initial flow из root-а;
- templates/my projects/details больше не создают `PlayerViewController` напрямую;
- введены bundle-backed `TemplateCatalogRepository`, `SceneLibraryRepository` и `BackgroundPresetRepository`;
- `SceneDelegate` больше не читает `BackgroundPresetLibrary.shared` напрямую;
- feature controllers больше не читают `TemplateCatalog.shared` напрямую;
- launch/recovery decision вынесен из `SceneDelegate`;
- recovery prompt реализован как app-start contract с явными действиями `Continue` и `Start Over`;
- singleton-backed dependencies оборачиваются в adapters и инжектятся из root-а.

На выходе PR нельзя оставлять:

- `SceneDelegate` с прямым `ProjectStore.shared.hasActiveDraft()`;
- `SceneDelegate` с прямым `BackgroundPresetLibrary.shared`;
- feature controllers, создающие editor напрямую;
- feature controllers, читающие `TemplateCatalog.shared` напрямую;
- auto-resume recovery без prompt;
- новый код, добавляющий product-owned architectural singleton как feature dependency.

### PR 2. Thin EditorSession Boundary

Цель: ввести `EditorSession` раньше полной нормализации state, чтобы дальнейшая переработка шла уже внутри правильного owner-а, а не внутри `PlayerViewController`.

Обязательные результаты:

- введен `EditorSession` как отдельный owner boundary;
- `PlayerViewController` перестает быть owner-ом bootstrap/save/export/close decisions, даже если часть внутренней реализации пока временно делегирована в существующие типы;
- `PlayerViewController` работает через session interface, а не напрямую через controller-owned persistence state;
- session lifecycle становится тестируемым без `UIViewController`.

На выходе PR нельзя оставлять:

- новый код, который еще глубже вшивает session lifecycle в controller;
- rollout, в котором нормализация state всё еще идет внутри `PlayerViewController` как конечного owner-а.

### PR 3. Session Lifecycle Move, State Normalization И Close Contract

Цель: перенести bootstrap/save/export/close/recovery lifecycle внутрь `EditorSession`, убрать sidecar-state и довести clean/dirty behavior до финального product contract.

Обязательные результаты:

- `EditorSession` владеет bootstrap, save, export-save, discard, recovery, close logic;
- `EditorStore` становится внутренней деталью session boundary;
- controller-owned persisted sidecar state удален:
  - `currentProjectDraft`
  - `draftIsDirty`
  - `projectBackgroundOverride`
- background absorbed into authoritative content state;
- dirty model переведен на dual-baseline contract;
- `EditorStore` и session state нормализованы так, чтобы persisted content и interaction state были явно разведены;
- undo snapshot становится content-oriented;
- модель entry intent/origin нормализована и перестает дублироваться между `PlayerViewController.EntryContext` и `EditorEntryContext`;
- session владеет missing-media summary и non-blocking user-visible notice state для open/reopen flows;
- editor/background flow использует `BackgroundPresetRepository`, а не `BackgroundPresetLibrary.shared`;
- реализован clean/dirty close contract:
  - clean session closes silently
  - dirty session shows `Save / Don't Save / Cancel`
- реализован clean save/export contract:
  - successful save/export removes recovery slot
  - session remains clean until next persisted mutation.

На выходе PR нельзя оставлять:

- `PlayerViewController` как owner active draft lifecycle;
- controller-owned explicit save/export commit logic;
- `currentMergedDraft()` как обязательный способ собрать реальный persisted state;
- dirty tracking через controller boolean flag;
- background как отдельную persisted sidecar сущность вне canonical content state.

### PR 4. Storage Core, ProjectOrigin И Metadata V2

Цель: превратить текущий широкий `ProjectStore` в canonical gateway set и перепроектировать persisted model под final product без baggage старых on-disk форматов.

Обязательные результаты:

- выделены `ProjectPersistenceGateway`, `ProjectMediaLocator`, `ProjectMediaWriteGateway`;
- storage owner serialized через actor/эквивалентную isolation boundary;
- убран `Task.detached` как ownership mechanism для cleanup;
- введен `ProjectOrigin`;
- введен listing metadata v2 для saved projects;
- `SavedProjectRecord`, `SavedProjectIndexEntry`, `ActiveDraftSlot` и open/listing contracts больше не завязаны только на `sourceTemplateId`;
- blank project получает first-class origin и persisted model support;
- legacy on-disk formats могут быть удалены и заменены новым storage format без migration layer;
- legacy persisted-video-selection compatibility decode удален из schema model вместе с test baggage;
- raw `ProjectStore` перестает быть canonical API вне gateway implementation layer.

На выходе PR нельзя оставлять:

- listing/open contract, зашитый в `sourceTemplateId`;
- blank project как неявный special case вне persisted model;
- legacy persisted-video-selection offset compatibility path в новой storage model;
- feature/session code, читающий raw `ProjectStore` вместо gateway contracts.

### PR 5. Asset Identity Cutover И Runtime Storage Boundary

Цель: завершить project-independence foundation и убрать raw `ProjectStore` из runtime/export/background/media paths.

Обязательные результаты:

- background и scene media usage переведены с path-as-identity на logical project asset identity;
- project-level music asset contract в audio V1 использует тот же asset identity registry;
- runtime/export/background/media helpers получают locator/write gateways вместо `ProjectStore.shared`;
- `TimelineCompositionEngine`, `VideoExporter`, `ExportMediaSnapshot`, `ExportBackgroundSnapshot`, `BackgroundTextureService`, `MediaRestoreCoordinator`, `MediaAssetStore` и аналогичные lower-level paths больше не знают о raw `ProjectStore`;
- project independence больше не зависит от случайной совместимости относительных путей.

На выходе PR нельзя оставлять:

- raw `ProjectStore` доступным из runtime/export/background/media code;
- проектную независимость, зависящую от path-as-identity;
- audio V1 как новый path-based special case в обход общего asset contract.

### PR 6. EditorRuntime Extraction И Render Contract

Цель: отделить runtime/render/export execution graph от session и controller.

Обязательные результаты:

- `EditorRuntime` владеет playback/render/export/media restore/background runtime state;
- controller получает render contract вместо прямого чтения runtime internals;
- scene-edit runtime и composition runtime координируются runtime owner-ом;
- export path уже работает только через storage gateways;
- export path содержит явный missing-media preflight gate и не стартует при отсутствии обязательных dependencies;
- появляется future saved-project preview seam поверх runtime/render services.

На выходе PR нельзя оставлять:

- `draw(in:)`, самостоятельно выбирающий runtime branch;
- controller-owned runtime boot/setup logic;
- export flow, стартующий без missing-media preflight;
- export/background/media helpers, которые зависят от controller state.

### PR 7. Blank Project, Duplicate Project И My Projects

Цель: довести project-origin driven app flows на новой архитектуре до production-state.

Обязательные результаты:

- shipped blank project;
- blank project стартует с одним специальным starter `sceneType` из `SceneLibrary`;
- starter `sceneType` скрыт из обычного `SceneCatalogViewController` через явный scene-library metadata contract;
- shipped duplicate project;
- duplicate project существует только как действие в `My Projects`;
- shipped project independence semantics;
- shipped app-level integration для missing-media behavior в saved/duplicate project flows;
- `My Projects` больше не использует template preview как корректностный contract;
- visual preview для saved projects может отсутствовать, но listing/service architecture готова к его будущему добавлению.

На выходе PR нельзя оставлять:

- blank project как пустой synthetic runtime state без starter sceneType;
- duplicate project как editor action;
- `My Projects`, зависящий от template preview как от единственного способа представить saved project.

### PR 8. Audio V1: Single Project-Level Music Track

Цель: довести audio до shipped V1 без блокировки future audio editor.

Обязательные результаты:

- shipped один project-level music track на весь ролик;
- доступны import/select, remove, trim, volume;
- audio V1 участвует в save/duplicate/export/dirty/undo flows;
- implementation опирается на canonical timeline/audio model и не закрывает дорогу future multi-item audio editor.

На выходе PR нельзя оставлять:

- placeholder-only `Music` UI;
- special-case audio model, который требует второго structural rewrite для future multi-item editor.

### PR 9. Text Overlay Timeline Editing

Цель: довести text overlays до shipped состояния с реальным timeline contract.

Обязательные результаты:

- shipped text overlays;
- доступны add/edit/remove/move/trim;
- text overlays имеют timing и positioning contract;
- text overlays участвуют в preview/export/save/duplicate/dirty/undo flows.

На выходе PR нельзя оставлять:

- placeholder-only `Text` UI;
- text model без timeline timing semantics.

### PR 10. Sticker Overlay Timeline Editing

Цель: довести sticker overlays до shipped состояния с реальным timeline contract.

Обязательные результаты:

- shipped sticker overlays;
- доступны add/remove/move/trim;
- sticker overlays имеют timing и positioning contract;
- sticker overlays участвуют в preview/export/save/duplicate/dirty/undo flows.

На выходе PR нельзя оставлять:

- placeholder-only `Sticker` UI;
- sticker model без timeline timing semantics.

### PR 11. Legacy Cleanup И Ban Enforcement

Цель: зачистить остатки старого ownership model и удалить временные rollout seams.

Обязательные результаты:

- удалены obsolete controller-side persistence fields;
- удалены direct `.shared` access paths в app features;
- удалены transitional adapters, которые больше не нужны;
- удален legacy persistence compatibility code;
- удален legacy migration/purge code, не нужный новому storage model;
- зафиксированы anti-pattern bans и тесты/линтерные guardrails для них.

## 11. Validation Strategy

### 11.1. Что уже есть и что надо сохранить

У проекта уже есть сильная test база, которую надо сохранить и расширить:

- `TVECore` test suite;
- app-level tests в [`AnimiApp/Tests`](AnimiApp/Tests);
- boundary script [`verify_module_boundary.sh`](Scripts/verify_module_boundary.sh);
- bundle topology verification [`verify_release_bundle.sh`](Scripts/verify_release_bundle.sh).

### 11.2. Что обязательно добавить

Новые обязательные suite-ы для этого эпика:

- `AppCompositionRoot` / app-start flow tests;
- `AppLaunchRouterTests`;
- `RecoveryPromptFlowTests`;
- `TemplateCatalogRepositoryTests`;
- `SceneLibraryRepositoryTests`;
- `BackgroundPresetRepositoryTests`;
- `EditorSessionBootstrapTests`;
- `EditorSessionLifecycleTests`;
- `CleanCloseContractTests`;
- `SaveExportCleanSessionTests`;
- `DirtyBaselineContractTests`;
- `MissingMediaSessionNoticeTests`;
- `MissingMediaExportGateTests`;
- `ProjectOriginMetadataTests`;
- `SavedProjectsListingTests`;
- `EditorRuntimeContractTests`;
- `RuntimeStorageBoundaryTests`;
- `RenderSourceSelectionTests`;
- `ExportStorageBoundaryTests`;
- `ExportBackgroundSnapshotTests`;
- `SceneEditTimelineHandoffTests`;
- `ProjectDuplicationUseCaseTests`;
- `ProjectDuplicatePayloadRoundTripTests`;
- `BlankProjectFlowTests`;
- `SceneLibraryCatalogVisibilityTests`;
- `ProjectAssetIdentityContractTests`;
- `ProjectPreviewServiceTests`.

Дополнительно для final product completion:

- `ProjectMusicTrackTests`;
- `TextOverlayIntegrationTests`;
- `StickerOverlayIntegrationTests`.

### 11.3. Canonical local loop

Финальный локальный validation loop должен быть таким:

1. `Scripts/verify_module_boundary.sh`
2. `cd TVECore && swift test`
3. app-level tests через repo-owned wrapper
4. build `AnimiApp`
5. при CI/release path: bundle topology verification

### 11.4. CI contract

CI обязан:

- генерировать проект из `AnimiApp/project.yml`;
- запускать `TVECore` tests;
- запускать `AnimiAppTests`;
- билдить app;
- проверять bundle topology.

CI, который не запускает app-level unit tests, не соответствует final contract этого эпика.

## 12. Manual QA Matrix

Минимальная обязательная manual QA матрица:

- cold start без recovery slot;
- cold start с recovery slot и выбор `Continue`;
- cold start с recovery slot и выбор `Start Over`;
- открыть template project, не менять ничего, закрыть editor;
- открыть template project, изменить контент, закрыть dirty session;
- открыть saved project, не менять ничего, закрыть clean session;
- открыть saved project, изменить контент, сделать explicit save;
- открыть saved project, изменить контент, сделать successful export;
- сделать save/export error path и убедиться, что session не теряет state;
- background customization с последующим recovery/save/export;
- media ingest photo/video с последующим recovery/save/export;
- missing media reopen behavior;
- missing media notice показывается, но проект открывается;
- export блокируется при missing required media;
- duplicate project без missing media;
- duplicate project с missing media;
- удалить source project после duplication и убедиться, что дубликат жив;
- удалить duplicate project и убедиться, что source жив;
- создать blank project и убедиться, что он стартует со специальной starter scene-заглушкой;
- убедиться, что starter scene не показывается в обычном `Add Scene` catalog;
- создать blank project, заменить/добавить сцены, сохранить, переоткрыть;
- project-level music track add/edit/remove/export;
- text/sticker add/edit/export;
- preview template вне editor;
- `My Projects` listing без saved-project visual preview не ломает product flow.

## 13. Definition Of Done

Эпик считается завершенным только если одновременно истинны все условия ниже.

### 13.1. Архитектурные условия

- существует `AppCompositionRoot`;
- существует `EditorSession`;
- существует `EditorRuntime`;
- editor controller стал thin UI boundary;
- нет controller-owned persisted sidecar state;
- нет raw `ProjectStore` outside composition root/gateway layer;
- нет feature-level зависимости от product-owned architectural singletons:
  - `ProjectStore.shared`
  - `TemplateCatalog.shared`
  - `SceneLibrary.shared`
  - `BackgroundPresetLibrary.shared`
- storage/media cleanup сериализован и не использует detached ownership pattern;
- не осталось legacy compatibility code для старых local storage formats;
- не осталось permanent dual-path architecture после rollout.

### 13.2. Product условия

- shipped recovery prompt;
- shipped clean/dirty close contract;
- shipped clean save/export contract;
- shipped blank project;
- blank project стартует со специальной starter scene-заглушкой из `SceneLibrary`;
- starter scene скрыт из обычного `Add Scene` catalog через явный library metadata contract;
- shipped duplicate project;
- duplicate project существует только в `My Projects`;
- shipped project independence semantics;
- shipped audio V1 как один project-level music track;
- shipped text/sticker overlays;
- shipped template preview;
- shipped future saved-project preview seam без обязательного visual preview в текущем delivery;
- missing-media notice не блокирует open/reopen flow;
- shipped missing media product behavior;
- export блокируется при missing required media.

### 13.3. Validation условия

- canonical local loop green;
- CI green;
- новые architectural tests green;
- manual QA matrix пройдена.

## 14. Anti-Pattern Bans

После завершения эпика запрещены:

- `PlayerViewController` как owner persistence/session/runtime lifecycle;
- mutable controller fields для persisted content ownership;
- product-owned architectural singletons в feature controllers/use cases/runtime/export/background/media services:
  - `ProjectStore.shared`
  - `TemplateCatalog.shared`
  - `SceneLibrary.shared`
  - `BackgroundPresetLibrary.shared`
- launch/editor entry logic, распределенная между random controllers;
- direct save/export/discard semantics в controller-е;
- detached GC как canonical storage cleanup strategy;
- "future scope позже как-нибудь" для blank/duplicate/audio/overlay/preview, если архитектура уже закрыта.

Системные и infrastructure singletons вроде `UIApplication.shared`, `PHPhotoLibrary.shared()` или process-wide caches сами по себе не являются нарушением этого запрета.

## 15. Что Не Является Целью Этого Эпика

Следующие задачи не являются целью сами по себе и не должны становиться причиной лишнего rewrite:

- миграция на SwiftUI;
- внедрение внешнего Redux/TCA framework;
- полный rewrite `TVECore`;
- миграция на CoreData/SQLite только ради "архитектурной красоты";
- cloud sync, collaboration, version history;
- косметический redesign UI вне необходимости для product contract.

## 16. Итог

Ключевой смысл этого документа:

- не переписать editor "по слоям ради слоев";
- а привести реальный существующий код к состоянию, где ownership ясен, persisted content един, runtime переиспользуем, а весь обязательный final product scope уже заложен в модель.

Если по завершении эпика для `blank project`, `duplicate project`, audio, overlays, template preview или future saved-project preview seam потребуется еще один structural rewrite, значит эпик выполнен неправильно.

## 17. PR5 Final Resolution (delivered)

PR5 shipped the canonical storage boundary and asset-identity cutover described in §7 and §8. The following are the final resolutions of the decisions that were outstanding at plan-authoring time. Everything in this section reflects what is in the code today, not a plan.

### 17.1. Asset identity is `ProjectAssetID`, not `storagePath`

- `MediaRef` is `Equatable`/`Hashable` by `assetId` only.
- `ProjectAssetRegistry` is the source of truth for `assetId → ProjectAssetDescriptor (assetId, mediaKind, storagePath)`.
- `MediaRef.storagePath` is retained as a cache field (not identity) so export/runtime/tests do not have to rewrite every MediaRef construction site. It is never used for equality.

### 17.2. Registry-backed locator, value-passed

- `ProjectMediaLocator.absoluteURL(for: MediaRef, registry: ProjectAssetRegistry) async throws -> URL` is the canonical resolver. Registry is passed by value at every call site. No global, no `current registry` on the actor, no session seam exposed as a closure.
- `FileProjectMediaStore.absoluteURL(for:registry:)` looks up `registry.descriptor(for: mediaRef.assetId)` first; on miss it falls back to `mediaRef.storagePath` and bumps an observable `legacyFallbackHits` counter. Tests assert this counter stays zero on happy-path production flows.
- The deprecated single-argument `absoluteURL(for:)` survives in three places as a `@available(*, deprecated)` test-convenience shim: (a) `ProjectMediaLocator` protocol extension, (b) `FileProjectMediaStore` internal method, (c) `ProjectStore.absoluteURL(for:)` public method. All three are evidence-free at production call sites — the runtime/composition/export boundary passes an explicit registry at every resolution site, grep-enforced by `rg 'absoluteURL\(for: [^,)]+\)' AnimiApp/Sources` → 0 hits.

### 17.3. GC policy: referenced-primary, scan defense-in-depth

- `FileProjectMediaStore.collectMediaPaths(from: ProjectDraft)` computes the GC pin set as `draft.assetRegistry.storagePaths(referencedBy: draft)` + raw scan of slot/background `mediaRef.storagePath`. Registered-but-unreferenced descriptors are GC-eligible; the registry does NOT pin files forever.

### 17.4. Duplicate-project foundation (storage-level, no UI)

- `ProjectMediaWriteGateway.duplicateAssets(inDraft:) async throws -> ProjectDraft` lives on `ProjectStorageActor` + `FileProjectMediaStore`. It walks `assetRegistry.assetIds(referencedBy:)`, copies each file to a fresh UUID-named destination in the same directory class, mints a new `ProjectAssetID` per copy, rewrites every `MediaRef` in scene slots + background regions, and returns a new draft with a fresh `id`, fresh registry containing only the new descriptors, and fresh timestamps.
- Storage-level proof: `DuplicateProjectAssetIndependenceTests` verifies new draft shares zero `assetId`s + zero `storagePath`s with source, source files survive, and deleting source does not affect duplicate. PR 7 will wire this into a user-facing "Duplicate project" action.

### 17.5. Registry bookkeeping is non-dirtying

- `EditorStore.mutateCurrentDraftForBookkeeping(_:)` — internal seam that mutates `state.draft` without pushing an undo snapshot, without emitting callbacks, without touching dirty baseline.
- `EditorSession.registerAssetBookkeeping(_:)` and `unregisterAssetBookkeeping(_:)` — the only APIs through which production code mutates the registry. Pure bookkeeping.
- Registry mutations ride the next semantic dispatch's persistence path: when the next dirtying edit calls `saveActiveDraft`, the persisted draft includes the updated registry.
- `EditorSessionSnapshot` (used for dirty comparison) deliberately excludes `assetRegistry`, so pure bookkeeping operations never trip the dirty/close path.

### 17.6. Production write-side hooks

- `MediaIngestCoordinator.onAssetPersisted: ((ProjectAssetDescriptor) -> Void)?` fires strictly before `onIngestComplete`, so the registry contains the new descriptor by the time any reducer dispatch sees the `MediaRef`.
- `PlayerViewController` wires this to `session.registerAssetBookkeeping(_:)` in the coordinator's `onAssetPersisted`.
- Background image save path calls `session.registerAssetBookkeeping(_:)` immediately after `persistImage(...)` and before `loadTexture(...)`; the subsequent `loadTexture` call re-reads a fresh registry snapshot (see §17.8) so the registry-backed locator resolves via the new descriptor.
- Slot removal, slot replacement (via `handleIngestComplete`), background editor dismiss, and background image replace all call `unregisterAssetIfUnreferenced(_:)` after their semantic dispatch — unregister only fires if the fresh draft no longer references the old `assetId`. Shared-reference safety is preserved by the `assetIds(referencedBy:)` walker.
- Ingest abort branches (scene deleted, race with `resolveDefaultFitAsync`, video without `videoWindow`) unregister the pre-registered descriptor directly before deleting the orphan file.
- Background editor intermediate imports are tracked in `PlayerViewController.backgroundEditorRegisteredAssetIds` during the editor session and swept via `unregisterAssetIfUnreferenced` after `backgroundEditorWillDismiss` dispatches the final override.

### 17.7. Chosen resolution for undo-registry symmetry: self-healing registry

**Decision:** self-heal the registry at resolution time, not at undo time, not by widening the undo snapshot.

Registry bookkeeping lives outside the undo snapshot by design (so `register` is non-dirtying). This creates a one-way asymmetry: if the user binds asset A, then a subsequent slot-replace runs `unregisterAssetBookkeeping(A)`, then Undo restores the slot — the draft's content references A again, but the registry no longer contains A's descriptor.

The resolution chosen for PR5 is **self-healing at resolution time**:

- `ProjectAssetRegistry.selfHealed(for draft: ProjectDraft) -> ProjectAssetRegistry` is a pure value-returning walker. It scans `assetIds(referencedBy: draft)`; for any referenced `assetId` that has no descriptor in the receiver, it synthesizes a descriptor from the live `MediaRef` (`assetId`, `mediaKind`, `storagePath`) and returns a healed copy. Does NOT mutate the receiver.
- `PlayerViewController` calls `selfHealedRegistry()` (a one-line wrapper around the healer) at every point where it would otherwise pass `session.state?.draft.assetRegistry` into downstream code: `ResolvedMediaMapBuilder.build`, `service.loadTexture`, `preloadTextures`, `engine.setTimeline`, `ExportMediaSnapshot.build`, `exporter.exportVideo`, `exporter.exportTimeline`. Background preload and undo-sync paths explicitly use the healed snapshot.
- Production runtime and export paths therefore always see a resolution-ready registry, including after undo.
- Tests (`test_selfHealed_*` in `ProjectAssetIdentityContractTests`) cover: empty-draft no-op, all-present no-op, slot missing descriptor synthesis, background region missing descriptor synthesis, receiver-is-pure invariant, and the critical "self-healed registry resolves without bumping `legacyFallbackHits`" assertion.

**Why not the alternatives:**

- *Option A (pending-unregister list on dirty baseline, commit on save):* too much plumbing. Couples resolution to the dirty model.
- *Option B (move registry into `EditorSessionSnapshot` / undo snapshot):* would restore symmetry at undo time, but then `register` becomes dirtying — breaks the explicit "bookkeeping is non-dirtying" contract from §17.5 and the `AssetRegistryBookkeepingTests` that depend on it.
- *Option C (chosen):* pure per-resolution value synthesis. Keeps the session's stored registry authoritative; keeps bookkeeping non-dirtying; keeps resolution deterministic; one pure function; every production call site uses the same helper.

### 17.8. Fresh-registry re-read policy

Whenever PVC calls `session.registerAssetBookkeeping(...)` and then immediately uses the registry for a downstream operation (texture load after background import), it **re-reads** `session.state?.draft.assetRegistry` via `selfHealedRegistry()` rather than reusing a snapshot captured before the register. `register` is synchronous, so the fresh read observes the new descriptor. This is the canonical pattern for "ingest now, resolve now".

### 17.9. Validation gates (all green on fresh clean DerivedData)

1. `Scripts/verify_module_boundary.sh` — PASS.
2. `cd TVECore && rm -rf .build && swift test` — 939 tests, 86 skipped (Metal shader unavailable in SPM test env, normal), 0 failures.
3. `Scripts/run_animiapp_tests.sh` on fresh `/tmp/…` DerivedData — **899 tests, 0 failures, 0 unexpected, `** TEST SUCCEEDED **`**.
4. `make build` — `** BUILD SUCCEEDED **`, exit 0.

### 17.10. Grep acceptance contracts (all green)

```
grep -rn 'FileProjectMediaStore(' AnimiApp/Sources          # expect 2 canonical only
grep -rnE 'absoluteURL\(for: [^,)]+\)' AnimiApp/Sources     # expect 0 (no single-arg production use)
grep -rn 'resolveMediaURLSync' AnimiApp                     # expect 0
grep -rn 'SceneRuntimeStateApplier\.Dependencies' AnimiApp  # expect 0
grep -rn 'SessionMediaLocator' AnimiApp                     # expect 0
grep -rn 'ProjectStore\.shared' AnimiApp                    # expect 0
```

All pass.

