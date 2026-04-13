# task-prs.md

Этот документ является execution playbook для [`task.md`](task.md).

[`task.md`](task.md) фиксирует final architecture contract и final product contract. Этот документ фиксирует:

- жесткий порядок PR-шагов;
- реальные текущие файлы продукта, которые надо менять;
- какие новые canonical types и seams должны появиться;
- какой legacy код должен исчезнуть;
- какие тесты обязательны до merge каждого PR.

Документ написан строго по текущему реальному коду репозитория.

## 0. Execution Status

Этот раздел фиксирует фактический progress rollout-а и не меняет authoritative scope или порядок PR-ов ниже.

Текущий статус на 2026-04-13:

- закрыт `PR 0` `Validation And Guardrails`;
- закрыт `PR 1` `AppCompositionRoot, Launch Routing And Recovery Prompt`;
- закрыт `PR 2` `Thin EditorSession Boundary`;
- закрыт `PR 3` `Session Lifecycle Move, State Normalization And Close Contract`;
- закрыт `PR 4` `Storage Core, ProjectOrigin And Metadata V2`;
- закрыт `PR 5` `Asset Identity Cutover And Runtime Storage Boundary`;
- закрыт `PR 6` `EditorRuntime Extraction And Render Contract`;
- закрыт `PR 7` `Blank Project, Duplicate Project And My Projects`;
- следующий незакрытый шаг: `PR 8` `Audio V1: Single Project-Level Music Track`;
- рабочая epic-ветка для rollout-а: `codex/epic-q-editor-app-layer-refactor`.

Что уже сделано в `PR 0`:

- добавлен repo-owned wrapper `Scripts/run_animiapp_tests.sh`;
- зафиксирован deterministic simulator destination для app-level test/build loop через wrapper;
- app tests переведены на запуск через `AnimiApp/AnimiApp.xcodeproj` и scheme `AnimiApp`;
- для app test/build loop явно проставлены no-signing flags;
- `Makefile` переведен на canonical targets:
  - `verify`
  - `test-core`
  - `app-test`
  - `test`
  - `build`
- CI обновлен так, чтобы `Scripts/verify_module_boundary.sh` и `AnimiAppTests` были обязательной частью green status;
- подтвержден green validation loop для `PR 0`:
  - `Scripts/verify_module_boundary.sh`
  - `cd TVECore && swift test`
  - `Scripts/run_animiapp_tests.sh`
  - app build через `make build`

Что уже сделано в `PR 1`:

- введены `AppCompositionRoot`, `AppLaunchRouter`, `EditorLaunchIntent` и `RecoveryPromptCoordinator`;
- `SceneDelegate` переведен в thin bootstrapper и больше не читает `ProjectStore.shared` / `BackgroundPresetLibrary.shared` напрямую;
- templates / template details / category / my projects переведены на injected routing callbacks вместо прямого создания `PlayerViewController`;
- введены bundle-backed `TemplateCatalogRepository`, `SceneLibraryRepository` и `BackgroundPresetRepository`;
- feature controllers больше не читают `TemplateCatalog.shared` напрямую;
- launch recovery переведен с auto-resume на явный prompt с действиями `Continue` и `Start Over`;
- `MyProjectsViewController` сохраняет временно разрешенный raw `ProjectStore.shared` только для listing/delete до `PR 4`;
- `PlayerViewController.EntryContext.openSavedProject` сужен до `projectId`, а `sourceTemplateId` теперь резолвится из `SavedProjectRecord` при загрузке;
- подтвержден green validation loop для `PR 1`:
  - `Scripts/verify_module_boundary.sh`
  - `cd TVECore && swift test`
  - `Scripts/run_animiapp_tests.sh`
  - `AppCompositionRootTests`
  - `AppLaunchRouterTests`
  - `RecoveryPromptFlowTests`
  - `TemplateCatalogRepositoryTests`
  - `SceneLibraryRepositoryTests`
  - `BackgroundPresetRepositoryTests`

Что уже сделано в `PR 2`:

- введены `EditorSession`, `EditorSessionState`, `EditorSessionDependencies` и `EditorSessionOutput` как новый app/editor boundary;
- `AppCompositionRoot` теперь собирает `EditorSessionDependencies` из уже введенных root-owned seams и создает `PlayerViewController(session:)`;
- `PlayerViewController.EntryContext` удален как canonical launch/session boundary;
- bootstrap path вынесен из `PlayerViewController.loadEditorContent()` в `EditorSession.bootstrap()`;
- recovery checkpoint path вынесен из `PlayerViewController.saveDraftToActiveSlot()` в `EditorSession.persistCheckpointIfNeeded(...)`;
- export commit path вынесен из `PlayerViewController.handleExportSuccess()` в `EditorSession.commitAfterExportSuccess(...)`;
- close flow теперь идет через `EditorSession.requestClose(...)`, а `PlayerViewController` оставлен только presentation layer для UI-реакции;
- `requestClose(...)` зафиксирован как консервативный `PR 2` contract: всегда требует user decision до `PR 3`, чтобы не сломать будущую dual-baseline dirty model;
- `saveAndClose()` и `discardAndClose()` переведены на session boundary;
- session lifecycle теперь покрыт отдельными session-level tests без `UIViewController`;
- подтвержден green validation loop для `PR 2`:
  - `Scripts/verify_module_boundary.sh`
  - `cd TVECore && swift test`
  - `Scripts/run_animiapp_tests.sh`
  - `EditorSessionBootstrapTests`

Что уже сделано в `PR 3`:

- введены `EditorSessionSnapshot` и `EditorSessionDirtyState`;
- `EditorSession` стал owner-ом bootstrap, recovery checkpoint, export-save commit, discard/save close path и close decision;
- `EditorStore` internalized внутрь `EditorSession` и больше не торчит типом в controller-facing API;
- из `PlayerViewController` удалены persisted sidecars:
  - `currentProjectDraft`
  - `draftIsDirty`
  - `projectBackgroundOverride`
- удален `currentMergedDraft()` как canonical persistence path;
- background state absorbed в authoritative persisted content state и content snapshots;
- реализован dual-baseline dirty model:
  - `materializedBaseline`
  - `recoveryBaseline`
- реализован final clean/dirty close contract:
  - clean session closes silently;
  - dirty session показывает `Save / Don't Save / Cancel`;
- реализован clean save/export contract:
  - successful save/export clears recovery slot;
  - после successful save/export session остается clean до следующей persisted mutation;
- editor/background flow переведен на `BackgroundPresetRepository` / `BackgroundPresetProviding`;
- missing-media summary и non-blocking user-visible notice state переведены в `EditorSession`;
- подтвержден green validation loop для `PR 3`:
  - `Scripts/verify_module_boundary.sh`
  - `cd TVECore && swift test`
  - `Scripts/run_animiapp_tests.sh`
  - `make build`
  - `EditorSessionLifecycleTests`
  - `CleanCloseContractTests`
  - `SaveExportCleanSessionTests`
  - `DirtyBaselineContractTests`
  - `MissingMediaSessionNoticeTests`
  - обновленные `EditorReducerNormalizationTests`

Что уже сделано в `PR 4`:

- введены `ProjectOrigin`, `SavedProjectSummary`, `ProjectPersistenceGateway`, `ProjectMediaLocator`, `ProjectMediaWriteGateway`, `SavedProjectsService`, `ProjectStorageActor`, `FileProjectPersistenceStore` и `FileProjectMediaStore`;
- persisted model переведен с template-only identity на canonical `ProjectOrigin`;
- `sourceTemplateId` удален из `ActiveDraftSlot`, `SavedProjectRecord` и `SavedProjectIndexEntry`;
- schema/storage format bumped до v9 без migration layer;
- `MyProjectsViewController` переведен на `SavedProjectsService`, а `ProjectPreviewCell` переведен на summary-driven API;
- storage/session/recovery/listing paths переведены на actor-backed gateway boundary;
- legacy migration/purge code удален из `ProjectStore`;
- legacy persisted-video-selection compatibility decode удален из `SceneState`;
- incompatible persisted index теперь сбрасывается через wipe/reset path без migration layer;
- runtime open path больше не блокирует blank/duplicate-origin background setup через template-only guard;
- feature-level raw `ProjectStore.shared` убран из export path; остаточный raw access остается только в lower-level deferred `PR 5` code;
- file-backed persistence tests переведены на isolated temp-root storage; deterministic listing sort закреплен stable tie-breaker-ом;
- подтвержден green validation loop для `PR 4`:
  - `Scripts/verify_module_boundary.sh`
  - `cd TVECore && swift test`
  - `Scripts/run_animiapp_tests.sh`
  - `make build`
  - `ProjectOriginMetadataTests`
  - `SavedProjectsListingTests`
  - `ProjectPersistenceGatewayTests`
  - обновленные `ProjectStorePersistenceTests`

## 1. Зафиксированные Product Assumptions

Эти assumptions подтверждены и не считаются open questions:

- приложение рассматривается как новое;
- старые локальные `draft` / `saved project` / index / media данные можно полностью удалить;
- backward compatibility для старых on-disk форматов не нужна;
- `blank project` является обязательным shipped flow и стартует с отдельного специального starter `sceneType` из `SceneLibrary`;
- `duplicate project` является обязательным shipped flow и существует только как действие в `My Projects`;
- template preview остается shipped функциональностью;
- visual preview для `saved projects` не обязателен в текущем delivery;
- future saved-project preview seam в архитектуре обязателен;
- audio V1 в текущем delivery это один project-level music track на весь ролик;
- архитектура audio обязана быть готова к future multi-item audio editor;
- text overlays входят в текущий delivery уже с timing, positioning и timeline editing;
- sticker overlays входят в текущий delivery уже с timing, positioning и timeline editing.

## 2. Реальный Repo Baseline

### 2.1. Project generation и test baseline

- source of truth для app project: `AnimiApp/project.yml`;
- checked-in generated artifact: `AnimiApp/AnimiApp.xcodeproj/project.pbxproj`;
- `project.yml` уже включает `Sources`, `Tests` и `Resources/Scenes` через `xcodegen`;
- app-level tests уже существуют в `AnimiApp/Tests`;
- текущий CI в `.github/workflows/ci.yml` не делает app-level tests обязательным gate.

### 2.2. Launch и routing baseline

Ключевые файлы:

- `AnimiApp/Sources/App/SceneDelegate.swift`
- `AnimiApp/Sources/TemplatesUI/TemplatesHomeViewController.swift`
- `AnimiApp/Sources/TemplatesUI/CategoryTemplatesViewController.swift`
- `AnimiApp/Sources/TemplatesUI/TemplateDetailsViewController.swift`
- `AnimiApp/Sources/MyProjects/MyProjectsViewController.swift`

Подтвержденные проблемы:

- `SceneDelegate` напрямую смотрит `ProjectStore.shared.hasActiveDraft()`;
- `SceneDelegate` напрямую создает `PlayerViewController(entryContext: .resumeActiveDraft)`;
- `TemplatesHomeViewController`, `CategoryTemplatesViewController`, `TemplateDetailsViewController` и `MyProjectsViewController` напрямую создают `PlayerViewController`;
- app launch routing и editor routing не централизованы;
- recovery flow сейчас auto-resume, а не явный prompt.

### 2.3. Editor/session baseline

Ключевой файл:

- `AnimiApp/Sources/Player/PlayerViewController.swift`

Подтвержденные проблемы:

- controller одновременно владеет bootstrap, save, export, recovery, close, playback, render и background state;
- controller хранит persisted sidecars:
  - `currentProjectDraft`
  - `draftIsDirty`
  - `projectBackgroundOverride`
- controller собирает persisted content через `currentMergedDraft()`;
- `PlayerViewController.EntryContext` дублирует product intent/model intent;
- `handleEditorClose()`, `handleExportSuccess()`, `saveDraftToActiveSlot()`, `loadEditorContent()` и смежные решения сидят в controller-е.

### 2.4. Storage, metadata и project model baseline

Ключевые файлы:

- `AnimiApp/Sources/Project/ProjectStore.swift`
- `AnimiApp/Sources/Project/ProjectDraft.swift`
- `AnimiApp/Sources/Project/ActiveDraftSlot.swift`
- `AnimiApp/Sources/Project/SavedProjectRecord.swift`
- `AnimiApp/Sources/Project/SceneState.swift`
- `AnimiApp/Sources/MyProjects/MyProjectsViewController.swift`
- `AnimiApp/Sources/MyProjects/ProjectPreviewCell.swift`

Подтвержденные проблемы:

- `ProjectStore` смешивает persistence, media resolution, garbage collection, migration и purge;
- `ActiveDraftSlot` и `SavedProjectRecord` завязаны на `sourceTemplateId`;
- `MyProjectsViewController` читает `ProjectStore.shared.allSavedProjectEntries()` напрямую;
- `MyProjectsViewController` строит UI через `TemplateCatalog.shared.template(by: entry.sourceTemplateId)`;
- `ProjectPreviewCell` заточен под template preview и delete-only action surface;
- legacy persisted-video-selection compatibility decode все еще живет в schema model через `SceneState`;
- legacy migration/purge code в `ProjectStore` больше не нужен в greenfield delivery.

### 2.5. Runtime, export, background и media baseline

Ключевые файлы:

- `AnimiApp/Sources/Player/TimelineComposition/TimelineCompositionEngine.swift`
- `AnimiApp/Sources/Export/VideoExporter.swift`
- `AnimiApp/Sources/Export/ExportMediaSnapshot.swift`
- `AnimiApp/Sources/Background/BackgroundTextureService.swift`
- `AnimiApp/Sources/MediaIngest/MediaRestoreCoordinator.swift`
- `AnimiApp/Sources/MediaIngest/MediaAssetStore.swift`
- `AnimiApp/Sources/Export/ExportBackgroundSnapshot.swift`
- `AnimiApp/Sources/UserMedia/UserMediaService.swift`

Подтвержденные проблемы:

- runtime/export/background/media helpers тянут raw `ProjectStore.shared` или `ProjectStore = .shared`;
- `ExportMediaSnapshot` все еще строится через `ProjectStore.absoluteURL(for:)`;
- `UserMediaService` уже умеет детектить failed restore, но final missing-media UX/export gate пока не собран в один contract;
- `BackgroundPresetLibrary.shared` используется и в bootstrap, и в editor/background flow;
- `draw(in:)` branch logic сидит в `PlayerViewController`;
- нет отдельного `EditorRuntime` owner-а;
- export/background state все еще завязаны на controller-owned merge sidecars;
- imported media identity по-прежнему path-based.

### 2.6. Product surface baseline

Ключевые файлы:

- `AnimiApp/Sources/TemplatesUI/PreviewVideoView.swift`
- `AnimiApp/Sources/TemplatesUI/TemplatesHomeViewController.swift`
- `AnimiApp/Sources/MyProjects/MyProjectsViewController.swift`
- `AnimiApp/Sources/Editor/GlobalActionBar.swift`
- `AnimiApp/Sources/Editor/EditorLayoutContainerView.swift`
- `AnimiApp/Sources/Editor/ContextBar.swift`
- `AnimiApp/Sources/Editor/TimelineSelection.swift`
- `AnimiApp/Sources/Editor/TimelineView.swift`
- `AnimiApp/Sources/Editor/AudioTrackView.swift`
- `AnimiApp/Sources/Editor/SceneCatalogViewController.swift`
- `AnimiApp/Sources/Content/SceneLibraryModels.swift`
- `AnimiApp/Sources/Project/TimelinePayload.swift`

Подтвержденные проблемы:

- template preview уже работает и должен быть сохранен;
- `My Projects` сейчас показывает template title и template preview вместо project-driven listing summary;
- `blank project` entry point отсутствует;
- `duplicate project` отсутствует;
- `SceneCatalogViewController` показывает `sceneLibrary.scenesInOrder` как есть, без visibility/usage contract для starter-only scenes;
- `GlobalActionBar` уже содержит `Text`, `Music`, `Sticker`, но `EditorLayoutContainerView` пока не пробрасывает эти callbacks наружу;
- `TimelineSelection` сейчас знает только `scene` и placeholder `audio`;
- `ContextBar` умеет только scene actions и placeholder `"Audio Options"`;
- `AudioPayload`, `StickerPayload`, `TextPayload` уже есть в `TimelinePayload`, но это пока scaffold, а не shipped feature contract;
- `AudioAssetRef.imported(relativePath:)` сейчас path-based и должен исчезнуть до shipped duplication/audio.

## 3. Общие Правила Rollout

### 3.1. Жесткий порядок PR-ов

Порядок обязателен:

1. `PR 0` Validation And Guardrails
2. `PR 1` AppCompositionRoot, Launch Routing And Recovery Prompt
3. `PR 2` Thin EditorSession Boundary
4. `PR 3` Session Lifecycle Move, State Normalization And Close Contract
5. `PR 4` Storage Core, ProjectOrigin And Metadata V2
6. `PR 5` Asset Identity Cutover And Runtime Storage Boundary
7. `PR 6` EditorRuntime Extraction And Render Contract
8. `PR 7` Blank Project, Duplicate Project And My Projects
9. `PR 8` Audio V1: Single Project-Level Music Track
10. `PR 9` Text Overlay Timeline Editing
11. `PR 10` Sticker Overlay Timeline Editing
12. `PR 11` Legacy Cleanup, Renames And Ban Enforcement

### 3.2. Каждый PR обязан давать один понятный ownership result

Правило:

- PR может менять много файлов;
- но у PR должен быть один ясный canonical ownership outcome;
- нельзя собирать в одном PR несколько независимых structural outcomes.

Следствия:

- runtime extraction и runtime storage boundary не смешиваются с blank/duplicate flow;
- audio, text и sticker идут разными vertical PR-ами;
- preview seam не превращается в отдельный large UI rewrite.

### 3.3. Обязательная дисциплина по `project.yml` и generated project

Если PR добавляет или удаляет source files, tests или resources:

- обновляется `AnimiApp/project.yml`, если это требуется структурой проекта;
- выполняется `cd AnimiApp && xcodegen generate`;
- в том же PR коммитится `AnimiApp/AnimiApp.xcodeproj/project.pbxproj`.

### 3.4. Legacy removal обязателен, а не optional cleanup

Правила:

- если новый canonical owner уже введен, старый owner не должен продолжать жить как равноправный путь;
- временный adapter допустим только на один переходный PR;
- compatibility code для старого on-disk формата не добавляется;
- каждый PR должен явно указывать, какой legacy seam он удаляет;
- финал не может оставить `ProjectStore.shared` как feature dependency.

### 3.5. Temporary allowances допустимы только если они явно ограничены

Разрешено:

- оставить `PlayerViewController` как имя типа до `PR 11`;
- оставить `TemplateCatalog.shared` / `SceneLibrary.shared` / `BackgroundPresetLibrary.shared` только внутри repository/infrastructure implementations, пока rollout не завершен;
- использовать narrow adapter над текущим `ProjectStore` до полного storage cutover.

Нельзя:

- добавлять новый product-owned architectural singleton access path в feature/controller/use-case/runtime code;
- оставлять behavior contract без owner PR;
- shipped duplicate/audio поверх path-as-identity.

### 3.6. Базовый validation loop для каждого PR

Каждый PR обязан зеленить:

- `Scripts/verify_module_boundary.sh`
- `cd TVECore && swift test`
- `Scripts/run_animiapp_tests.sh`

Если PR меняет project generation или resources, дополнительно обязателен build/generated-project check через `xcodegen`.

## 4. PR 0. Validation And Guardrails

### 4.0. Execution status

Статус: закрыт 2026-04-06.

Фактически выполненные изменения:

1. Добавлен `Scripts/run_animiapp_tests.sh` как canonical repo-owned wrapper для `AnimiAppTests`.
2. Зафиксирован deterministic simulator destination (`platform=iOS Simulator,arch=arm64,name=iPhone 16,OS=18.4` на текущей машине через `xcodebuild -showdestinations`).
3. `Makefile` обновлен так, чтобы app-level tests были частью canonical local loop.
4. `.github/workflows/ci.yml` обновлен так, чтобы `AnimiAppTests` и module-boundary check были обязательными CI gates.
5. Бизнес-логика приложения в рамках `PR 0` не менялась.

### 4.1. Цель

Сделать app-level tests и repo-owned validation обязательным gate до начала архитектурного refactor-а.

### 4.2. Реальные текущие файлы

- `Makefile`
- `.github/workflows/ci.yml`
- `Scripts/verify_module_boundary.sh`
- `AnimiApp/project.yml`

### 4.3. Новые файлы

- `Scripts/run_animiapp_tests.sh`

### 4.4. Изменяемые файлы

- `Makefile`
- `.github/workflows/ci.yml`

### 4.5. Implementation tasks

1. Добавить repo-owned wrapper `Scripts/run_animiapp_tests.sh`.
2. Зафиксировать deterministic simulator destination.
3. Запускать app tests через `AnimiApp/AnimiApp.xcodeproj` и scheme `AnimiApp`.
4. Явно проставить no-signing flags для CI/local loop.
5. Добавить app tests в `Makefile`.
6. Обновить CI так, чтобы app tests были обязательной частью green status.
7. Не менять бизнес-логику приложения в этом PR.

### 4.6. Что должно исчезнуть

- ad-hoc ручной `xcodebuild test` как единственный способ запускать app tests;
- CI, который считает editor refactor green без `AnimiAppTests`.

### 4.7. Required tests before merge

- `Scripts/verify_module_boundary.sh`
- `cd TVECore && swift test`
- `Scripts/run_animiapp_tests.sh`

## 5. PR 1. AppCompositionRoot, Launch Routing And Recovery Prompt

### 5.0. Execution status

Статус: закрыт 2026-04-06.

Фактически выполненные изменения:

1. Введен `AppCompositionRoot` как единый owner app-level dependencies, initial flow и feature routing.
2. Введены `AppLaunchRouter`, `EditorLaunchIntent` и `RecoveryPromptCoordinator` для canonical app-start recovery contract.
3. `SceneDelegate` переведен в thin bootstrapper:
   - создает `UIWindow`;
   - получает initial flow из root-а;
   - не читает `ProjectStore.shared` напрямую;
   - не читает `BackgroundPresetLibrary.shared` напрямую;
   - не создает `PlayerViewController` напрямую.
4. Template screens и `MyProjectsViewController` переведены на routing callbacks вместо прямого создания editor.
5. Введены bundle-backed `TemplateCatalogRepository`, `SceneLibraryRepository` и `BackgroundPresetRepository`.
6. Feature controllers переведены на injected repositories и больше не читают `TemplateCatalog.shared` напрямую.
7. Recovery flow переведен с auto-resume на явный launch prompt с действиями `Continue` и `Start Over`.
8. `PlayerViewController.EntryContext.openSavedProject` сужен до `projectId`, а `sourceTemplateId` теперь подтягивается из persisted saved-project record на editor boundary.
9. Базовый validation loop и обязательные architectural tests для `PR 1` подтверждены green.

### 5.1. Цель

Централизовать app launch/editor routing и реализовать canonical recovery prompt на старте приложения.

### 5.2. Реальные текущие code anchors

- `SceneDelegate.swift` напрямую проверяет `ProjectStore.shared.hasActiveDraft()` и открывает `PlayerViewController(entryContext: .resumeActiveDraft)`;
- `TemplatesHomeViewController.openTemplate(_:)` напрямую создает `PlayerViewController`;
- `CategoryTemplatesViewController` и `TemplateDetailsViewController` делают то же самое;
- `MyProjectsViewController.didSelectItemAt` напрямую создает `PlayerViewController`.

### 5.3. Новые файлы

- `AnimiApp/Sources/App/AppCompositionRoot.swift`
- `AnimiApp/Sources/App/AppLaunchRouter.swift`
- `AnimiApp/Sources/App/EditorLaunchIntent.swift`
- `AnimiApp/Sources/App/RecoveryPromptCoordinator.swift`
- `AnimiApp/Sources/TemplatesCatalog/TemplateCatalogRepository.swift`
- `AnimiApp/Sources/Content/SceneLibraryRepository.swift`
- `AnimiApp/Sources/Background/BackgroundPresetRepository.swift`

### 5.4. Изменяемые файлы

- `AnimiApp/Sources/App/SceneDelegate.swift`
- `AnimiApp/Sources/TemplatesUI/TemplatesHomeViewController.swift`
- `AnimiApp/Sources/TemplatesUI/CategoryTemplatesViewController.swift`
- `AnimiApp/Sources/TemplatesUI/TemplateDetailsViewController.swift`
- `AnimiApp/Sources/MyProjects/MyProjectsViewController.swift`
- `AnimiApp/Sources/TemplatesCatalog/TemplateCatalog.swift`
- `AnimiApp/Sources/Content/SceneLibrary.swift`
- `AnimiApp/Sources/Background/BackgroundPresetLibrary.swift`

### 5.5. Implementation tasks

1. Ввести `AppCompositionRoot` как единый owner app-level dependencies и root navigation flow.
2. Ввести `EditorLaunchIntent` с canonical cases:
   - `template(templateId:)`
   - `savedProject(projectId:)`
   - `resumeDraft`
   - `blankProject`
3. Переделать `SceneDelegate` в thin bootstrapper:
   - он создает `UIWindow`;
   - он спрашивает root про initial controller;
   - он больше не читает `ProjectStore.shared` напрямую.
4. Ввести `AppLaunchRouter`, который на старте решает:
   - открыть home flow;
   - показать recovery prompt;
   - по `Continue` открыть `resumeDraft`;
   - по `Start Over` вызвать очистку active draft и открыть home flow.
5. Вынести prompt presentation в `RecoveryPromptCoordinator`.
6. Переделать feature screens на routing callbacks вместо прямого создания editor.
7. Сразу закладывать blank-project route case в root/api, но UI запуск blank project не делать до `PR 7`.
8. Ввести bundle-backed `TemplateCatalogRepository`, `SceneLibraryRepository` и `BackgroundPresetRepository`.
9. Переделать bootstrap и feature screens так, чтобы они использовали эти repositories, а не `TemplateCatalog.shared` / `SceneLibrary.shared` / `BackgroundPresetLibrary.shared` напрямую.
10. Инжектить product-owned singleton-backed dependencies из root-а через adapters/repositories, а не читать их напрямую из feature flows.

### 5.6. Что разрешено оставить временно

- `TemplateCatalog.shared`, `SceneLibrary.shared` и `BackgroundPresetLibrary.shared` только внутри repository implementation layer;
- `ProjectStore.shared` внутри `MyProjectsViewController` только для listing/delete до `PR 4`;
- `PlayerViewController` как текущий editor shell.

### 5.7. Что должно исчезнуть в этом PR

- прямой `PlayerViewController(...)` из `SceneDelegate`;
- прямой `PlayerViewController(...)` из template screens;
- прямой `PlayerViewController(...)` из `MyProjectsViewController`;
- прямой `BackgroundPresetLibrary.shared` из `SceneDelegate`;
- прямой `TemplateCatalog.shared` из feature controllers;
- recovery auto-resume без prompt.

### 5.8. Required tests before merge

- полный базовый loop из раздела 3.6;
- `AppCompositionRootTests`;
- `AppLaunchRouterTests`;
- `RecoveryPromptFlowTests`;
- `TemplateCatalogRepositoryTests`;
- `SceneLibraryRepositoryTests`;
- `BackgroundPresetRepositoryTests`.

## 6. PR 2. Thin EditorSession Boundary

### 6.0. Execution status

Шаг закрыт.

Фактически выполнено:

1. Введен `EditorSession` как новый app/editor boundary и testable owner слоя session lifecycle.
2. `AppCompositionRoot` переведен на создание `EditorSession` и инъекцию session dependencies из уже утвержденных repository/root seams.
3. `PlayerViewController` переведен на `init(session:)`, а `EntryContext` удален как legacy boundary.
4. `loadEditorContent()` удален из controller-а; bootstrap теперь идет через `EditorSession.bootstrap()`.
5. Recovery checkpoint и export commit вынесены с controller boundary в `EditorSession`.
6. Close flow переведен на `EditorSession.requestClose(...)`; controller больше не владеет close decision и оставлен только как view/presentation layer.
7. Для `PR 2` зафиксирован консервативный close contract: `requestClose(...)` всегда возвращает `needsUserDecision` до внедрения dual-baseline dirty model в `PR 3`.
8. Session lifecycle покрыт отдельными session-level tests без `UIViewController`.
9. Подтвержден green validation loop для `PR 2`:
   - `Scripts/verify_module_boundary.sh`
   - `cd TVECore && swift test`
   - `Scripts/run_animiapp_tests.sh`
   - `EditorSessionBootstrapTests`

### 6.1. Цель

Поднять `EditorSession` как owner boundary до полной state normalization, чтобы вся дальнейшая работа шла уже внутри правильного owner-а.

### 6.2. Реальные текущие code anchors

- `PlayerViewController.EntryContext`;
- `PlayerViewController.loadEditorContent()`;
- `PlayerViewController.handleEditorClose()`;
- `PlayerViewController.handleExportSuccess()`;
- `PlayerViewController.saveDraftToActiveSlot()`;
- controller state:
  - `activeDraftSlot`
  - `currentProjectDraft`
  - `draftIsDirty`
  - `projectBackgroundOverride`

### 6.3. Новые файлы

- `AnimiApp/Sources/EditorSession/EditorSession.swift`
- `AnimiApp/Sources/EditorSession/EditorSessionState.swift`
- `AnimiApp/Sources/EditorSession/EditorSessionDependencies.swift`
- `AnimiApp/Sources/EditorSession/EditorSessionOutput.swift`

### 6.4. Изменяемые файлы

- `AnimiApp/Sources/Player/PlayerViewController.swift`
- `AnimiApp/Sources/App/AppCompositionRoot.swift`
- `AnimiApp/Sources/App/EditorLaunchIntent.swift`
- `AnimiApp/Sources/EditorSession/EditorSessionDependencies.swift`

### 6.5. Implementation tasks

1. Ввести `EditorSession` как новый app/editor boundary.
2. Сделать `EditorSession` owner-ом launch intent и session bootstrap decision.
3. Перевести `PlayerViewController` на init от `EditorSession`, а не от `EntryContext`.
4. Убрать из controller-а право решать:
   - как открывать template/new/saved/recovery flow;
   - когда сохранять active draft;
   - когда materialize saved project;
   - когда считать close/export/save действия session-level commit.
5. Провести `TemplateCatalogRepository` и `SceneLibraryRepository` в `EditorSessionDependencies`, чтобы editor bootstrap больше не зависел от `TemplateCatalog.shared` / `SceneLibrary.shared`.
6. Временно можно использовать existing lower-level код, но только через session boundary.
7. Сразу сделать session testable без `UIViewController`.
8. Не делать full state normalization в этом PR.

### 6.6. Что должно исчезнуть в этом PR

- новый код, который продолжает вшивать lifecycle decisions в `PlayerViewController`;
- дальнейшее расширение `PlayerViewController.EntryContext`.

### 6.7. Required tests before merge

- полный базовый loop из раздела 3.6;
- `EditorSessionBootstrapTests`;
- smoke session launch tests для template/saved/resume intents.

## 7. PR 3. Session Lifecycle Move, State Normalization And Close Contract

### 7.0. Execution status

Статус: закрыт 2026-04-08.

Фактически выполненные изменения:

1. Добавлены `EditorSessionSnapshot` и `EditorSessionDirtyState`.
2. `EditorSession` стал owner-ом bootstrap, autosave/recovery checkpoint, export-save commit, save/discard close path и clean/dirty close decision.
3. `EditorStore` internalized внутрь `EditorSession`; controller работает через session façade и не владеет store.
4. Из `PlayerViewController` удалены persisted sidecars:
   - `currentProjectDraft`
   - `draftIsDirty`
   - `projectBackgroundOverride`
5. Удален `currentMergedDraft()` как canonical persistence path.
6. Background state перенесен в authoritative persisted content state и content snapshots.
7. Реализован dual-baseline dirty model с разделением `materializedBaseline` и `recoveryBaseline`.
8. Реализован final clean/dirty close contract и clean save/export contract.
9. Missing-media summary и non-blocking user-visible notice state переведены в `EditorSession` без stale dual-path.
10. `PlayerViewController`, `BackgroundEditorViewController` и `EffectiveBackgroundBuilder` переведены на `BackgroundPresetRepository` / `BackgroundPresetProviding`.
11. Подтвержден green validation loop:
    - `Scripts/verify_module_boundary.sh`
    - `cd TVECore && swift test`
    - `Scripts/run_animiapp_tests.sh`
    - `make build`
    - `EditorSessionLifecycleTests`
    - `CleanCloseContractTests`
    - `SaveExportCleanSessionTests`
    - `DirtyBaselineContractTests`
    - `MissingMediaSessionNoticeTests`
    - обновленные `EditorReducerNormalizationTests`

### 7.1. Цель

Перенести весь session lifecycle в `EditorSession`, убрать controller-owned persisted sidecars и довести save/export/close behavior до final product contract.

### 7.2. Реальные текущие code anchors

- `PlayerViewController.loadEditorContent()`
- `PlayerViewController.handleEditorClose()`
- `PlayerViewController.discardAndClose()`
- `PlayerViewController.handleExportSuccess()`
- `PlayerViewController.currentMergedDraft()`
- `PlayerViewController.saveDraftToActiveSlot()`
- `PlayerViewController.appDidEnterBackground(...)`
- background update paths через `projectBackgroundOverride`
- `ExportBackgroundSnapshot` как bridge от controller sidecars к export

### 7.3. Новые файлы

- `AnimiApp/Sources/EditorSession/EditorSessionSnapshot.swift`
- `AnimiApp/Sources/EditorSession/EditorSessionDirtyState.swift`

### 7.4. Изменяемые файлы

- `AnimiApp/Sources/Player/PlayerViewController.swift`
- `AnimiApp/Sources/Editor/Store/EditorStore.swift`
- `AnimiApp/Sources/Editor/Store/EditorState.swift`
- `AnimiApp/Sources/Editor/Store/EditorReducer.swift`
- `AnimiApp/Sources/Background/BackgroundEditorViewController.swift`
- `AnimiApp/Sources/Background/EffectiveBackgroundBuilder.swift`
- `AnimiApp/Sources/Project/ProjectDraft.swift`
- `AnimiApp/Sources/Export/ExportBackgroundSnapshot.swift`
- `AnimiApp/Sources/UserMedia/UserMediaService.swift`
- `AnimiApp/Sources/Background/BackgroundPresetRepository.swift`

### 7.5. Implementation tasks

1. Перенести bootstrap/save/discard/export-save/recovery/close/autosave decisions внутрь `EditorSession`.
2. Сделать `EditorStore` внутренней деталью `EditorSession`.
3. Удалить из controller-а persisted sidecars:
   - `currentProjectDraft`
   - `draftIsDirty`
   - `projectBackgroundOverride`
4. Удалить `currentMergedDraft()` как canonical persistence path.
5. Перенести background state в authoritative persisted content model.
6. Ввести dual-baseline dirty model:
   - persisted baseline;
   - current content state;
   - interaction state отдельно.
7. Развести persisted content и interaction state в snapshots/undo contract.
8. Сделать missing-media summary частью `EditorSession`:
   - non-blocking open/reopen;
   - user-visible notice state;
   - отсутствие потери этого состояния между recovery/save/reopen flows.
9. Перевести editor/background flow на `BackgroundPresetRepository`:
   - `PlayerViewController`;
   - `BackgroundEditorViewController`;
   - `EffectiveBackgroundBuilder`;
   - без прямого чтения `BackgroundPresetLibrary.shared`.
10. Реализовать финальный close contract:
   - clean session closes silently;
   - dirty session показывает `Save / Don't Save / Cancel`.
11. Реализовать финальный save/export contract:
   - successful save clears recovery slot;
   - successful export clears recovery slot;
   - после successful save/export session остается clean, пока нет новой persisted mutation.
12. Сделать autosave/recovery writes session-owned, а не controller-owned.

### 7.6. Что должно исчезнуть в этом PR

- `PlayerViewController` как owner active draft lifecycle;
- `draftIsDirty` boolean как source of truth;
- `projectBackgroundOverride` как отдельная persisted sidecar сущность;
- direct `BackgroundPresetLibrary.shared` в editor/background flow;
- export path, который повторно сохраняет active draft после successful export;
- close UX, который одинаково спрашивает prompt и для clean, и для dirty session.

### 7.7. Required tests before merge

- полный базовый loop из раздела 3.6;
- `EditorSessionLifecycleTests`;
- `CleanCloseContractTests`;
- `SaveExportCleanSessionTests`;
- `DirtyBaselineContractTests`;
- `MissingMediaSessionNoticeTests`;
- обновленные `EditorReducerNormalizationTests` и `ProjectStorePersistenceTests` или их session-level successors.

## 8. PR 4. Storage Core, ProjectOrigin And Metadata V2

### 8.0. Execution status

Статус: закрыт 2026-04-09.

Фактически выполненные изменения:

1. Добавлены `ProjectOrigin`, `SavedProjectSummary`, `ProjectPersistenceGateway`, `ProjectMediaLocator`, `ProjectMediaWriteGateway`, `SavedProjectsService`, `ProjectStorageActor`, `FileProjectPersistenceStore` и `FileProjectMediaStore`.
2. Persisted model переведен на canonical `ProjectOrigin`; `templateId` / `sourceTemplateId` перестали быть sole persisted origin contract.
3. `ProjectDraft`, `ActiveDraftSlot`, `SavedProjectRecord` и `SavedProjectIndexEntry` переведены на metadata v2 / origin-aware contract.
4. `MyProjectsViewController` переведен на `SavedProjectsService`, а `ProjectPreviewCell` переведен на summary-driven contract.
5. `EditorSessionDependencies`, `EditorSession`, `AppCompositionRoot` и `AppLaunchRouter` переведены на actor-backed async persistence/listing/recovery seam.
6. `ProjectStore` сужен до thin internal/backing shim; feature/session/routing/listing code больше не используют его как canonical API.
7. Удалены legacy migration/purge code и `PersistedVideoSelectionMigrationTests`; compatibility decode удален из `SceneState`.
8. Реализован wipe/reset incompatible local storage contract без migration layer.
9. Убран template-only runtime guard, блокировавший blank/duplicate-origin background setup.
10. Feature-level raw `ProjectStore.shared` убран из export path; remaining raw access оставлен только в lower-level deferred `PR 5` code.
11. File-backed persistence tests переведены на isolated temp-root storage; deterministic listing order закреплен стабильным secondary sort key.
12. Подтвержден green validation loop:
    - `Scripts/verify_module_boundary.sh`
    - `cd TVECore && swift test`
    - `Scripts/run_animiapp_tests.sh`
    - `make build`
    - `ProjectOriginMetadataTests`
    - `SavedProjectsListingTests`
    - `ProjectPersistenceGatewayTests`
    - обновленные `ProjectStorePersistenceTests`

### 8.1. Цель

Полностью перепроектировать persisted model и storage contracts под final product, без baggage старых on-disk форматов.

### 8.2. Реальные текущие code anchors

- `ProjectDraft.templateId`
- `ActiveDraftSlot.sourceTemplateId`
- `SavedProjectRecord.sourceTemplateId`
- `ProjectStore.materializeSavedProject(from:)`
- `ProjectStore.allSavedProjectEntries()`
- `MyProjectsViewController.reloadData()`
- `MyProjectsViewController.didSelectItemAt`
- `ProjectPreviewCell.configure(templateTitle:previewURL:savedAt:)`

### 8.3. Новые файлы

- `AnimiApp/Sources/Project/ProjectOrigin.swift`
- `AnimiApp/Sources/Project/SavedProjectSummary.swift`
- `AnimiApp/Sources/Project/ProjectPersistenceGateway.swift`
- `AnimiApp/Sources/Project/ProjectMediaLocator.swift`
- `AnimiApp/Sources/Project/ProjectMediaWriteGateway.swift`
- `AnimiApp/Sources/Project/SavedProjectsService.swift`
- `AnimiApp/Sources/Project/ProjectStorageActor.swift`
- `AnimiApp/Sources/Project/FileProjectPersistenceStore.swift`
- `AnimiApp/Sources/Project/FileProjectMediaStore.swift`

### 8.4. Изменяемые файлы

- `AnimiApp/Sources/Project/ProjectDraft.swift`
- `AnimiApp/Sources/Project/ActiveDraftSlot.swift`
- `AnimiApp/Sources/Project/SavedProjectRecord.swift`
- `AnimiApp/Sources/Project/SceneState.swift`
- `AnimiApp/Sources/Project/ProjectStore.swift`
- `AnimiApp/Sources/MyProjects/MyProjectsViewController.swift`
- `AnimiApp/Sources/MyProjects/ProjectPreviewCell.swift`
- `AnimiApp/Tests/PersistedVideoSelectionMigrationTests.swift`

### 8.5. Implementation tasks

1. Ввести canonical `ProjectOrigin` вместо template-only identity.
2. Минимальный обязательный `ProjectOrigin` contract:
   - `template(templateId:)`
   - `blank(starterSceneTypeId:)`
   - `duplicate(sourceProjectId:)`
3. Убрать `templateId` / `sourceTemplateId` как единственный persisted origin contract.
4. Ввести `SavedProjectSummary` и listing metadata v2:
   - `projectId`
   - `savedAt`
   - title/summary metadata
   - origin summary
   - optional preview-or-placeholder metadata
5. Перевести `MyProjectsViewController` на `SavedProjectsService` вместо `ProjectStore.shared`.
6. Перевести `ProjectPreviewCell` с template-driven API на summary-driven API.
7. Подготовить persisted model под blank/duplicate flows, даже если UI доставки будет в `PR 7`.
8. Переписать storage format без compatibility layer.
9. Сузить роль `ProjectStore`:
   - либо превратить его во внутреннюю implementation detail за gateway contracts;
   - либо начать замену на `FileProjectPersistenceStore` / `FileProjectMediaStore`.
10. Убрать storage cleanup ownership через `Task.detached`.
11. Удалить legacy persisted-video-selection compatibility decode из `SceneState` и удалить test baggage, завязанное на старый формат.

### 8.6. Что разрешено оставить временно

- runtime/export/background/media code может еще жить поверх gateway-backed implementation, но не через feature-level raw access;
- `ProjectStore` может временно существовать как internal backing implementation до `PR 11`, если наружу он больше не торчит как canonical API.

### 8.7. Что должно исчезнуть в этом PR

- listing/open contract, завязанный только на `sourceTemplateId`;
- прямой `ProjectStore.shared` read из `MyProjectsViewController`;
- template-driven `ProjectPreviewCell` как единственный контракт представления saved project;
- legacy persisted-video-selection compatibility decode в schema model;
- `PersistedVideoSelectionMigrationTests`;
- legacy migration/purge code:
  - `LegacyProjectsIndex`
  - `migrateIfNeeded()`
  - `loadLegacyProjectDraft()`
  - `cleanupLegacyCrashFiles()`
  - `purgeIncompatibleSavedProjects()`

### 8.8. Required tests before merge

- полный базовый loop из раздела 3.6;
- `ProjectOriginMetadataTests`;
- `SavedProjectsListingTests`;
- `ProjectPersistenceGatewayTests`;
- обновленные persistence/listing tests на новый storage format.

## 9. PR 5. Asset Identity Cutover And Runtime Storage Boundary

### 9.1. Цель

Завершить project-independence foundation и убрать raw storage leakage из runtime/export/background/media.

### 9.2. Реальные текущие code anchors

- `MediaRef`
- `SceneMediaAsset`
- `ProjectBackgroundOverride`
- `TimelinePayload.AudioAssetRef.imported(relativePath:)`
- `TimelineCompositionEngine`
- `VideoExporter`
- `ExportMediaSnapshot`
- `ExportBackgroundSnapshot`
- `BackgroundTextureService`
- `MediaRestoreCoordinator`
- `MediaAssetStore`

### 9.3. Новые файлы

- `AnimiApp/Sources/Project/ProjectAssetID.swift`
- `AnimiApp/Sources/Project/ProjectAssetDescriptor.swift`
- `AnimiApp/Sources/Project/ProjectAssetRegistry.swift`

### 9.4. Изменяемые файлы

- `AnimiApp/Sources/Project/MediaRef.swift`
- `AnimiApp/Sources/Project/SceneMediaAsset.swift`
- `AnimiApp/Sources/Project/ProjectBackgroundOverride.swift`
- `AnimiApp/Sources/Project/TimelinePayload.swift`
- `AnimiApp/Sources/Player/TimelineComposition/TimelineCompositionEngine.swift`
- `AnimiApp/Sources/Export/VideoExporter.swift`
- `AnimiApp/Sources/Export/ExportMediaSnapshot.swift`
- `AnimiApp/Sources/Export/ExportBackgroundSnapshot.swift`
- `AnimiApp/Sources/Background/BackgroundTextureService.swift`
- `AnimiApp/Sources/MediaIngest/MediaRestoreCoordinator.swift`
- `AnimiApp/Sources/MediaIngest/MediaAssetStore.swift`

### 9.5. Implementation tasks

1. Ввести logical project asset identity вместо path-as-identity.
2. Перевести scene media usage на новый asset identity contract.
3. Перевести background media usage на новый asset identity contract.
4. Подготовить audio V1 к тому же registry:
   - заменить `AudioAssetRef.imported(relativePath:)` на logical asset reference;
   - не вводить новый audio-specific path-based special case.
5. Инжектить `ProjectMediaLocator` и `ProjectMediaWriteGateway` в runtime/export/background/media helpers.
6. Убрать default dependencies вида `ProjectStore = .shared`.
7. Перевести `ExportMediaSnapshot` с `ProjectStore.absoluteURL(for:)` на locator-based contract.
8. Перевести `ExportBackgroundSnapshot` и background export resolution на locator-based contract без raw `ProjectStore`.
9. Убедиться, что duplicate project будет независим от source project по asset ownership.
10. Убедиться, что export/runtime читают media только через gateways и asset registry.

### 9.6. Что должно исчезнуть в этом PR

- raw `ProjectStore.shared` из:
  - `TimelineCompositionEngine`
  - `VideoExporter`
  - `ExportMediaSnapshot`
  - `ExportBackgroundSnapshot`
  - `BackgroundTextureService`
  - `MediaRestoreCoordinator`
  - `MediaAssetStore`
- path-as-identity как shipped contract для scene/background/audio assets;
- предположение, что project independence держится на относительных путях.

### 9.7. Required tests before merge

- полный базовый loop из раздела 3.6;
- `ProjectAssetIdentityContractTests`;
- `RuntimeStorageBoundaryTests`;
- `ExportStorageBoundaryTests`;
- обновленные `ExportMediaSnapshotTests`;
- `ExportBackgroundSnapshotTests`;
- обновленные `PersistedMediaContractTests`;
- обновленные `BackgroundTextureServiceTests`;
- обновленные `MediaRestoreCoordinatorPhotoTests`;
- обновленные export/runtime tests, затрагивающие media resolution.

## 10. PR 6. EditorRuntime Extraction And Render Contract

### 10.0. Execution status

Шаг закрыт.

Фактически выполнено:

1. Введен `EditorRuntime` как production owner runtime/playback/render/export/background state.
2. `PlayerViewController` доведен до thin UI shell-а: layout/lifecycle/input forwarding/UI presentation остались в controller, runtime execution graph вынесен в `EditorRuntime`.
3. Initial scene boot/setup вынесен из controller: `EditorRuntime.loadInitialScene(...)` владеет scene/player/provider preload pipeline, а `configureAndBoot(...)` владеет single-call runtime boot sequence.
4. `draw(in:)` перестал выбирать runtime branch через `uiMode`; controller читает `runtime.currentRenderSource`, а timeline render path идет через sealed runtime execution API.
5. Scene-edit / timeline coordination, render-source switching, playback control, media restore fast-paths и background runtime state переведены под owner-а `EditorRuntime`.
6. Export orchestration переведена в runtime: `ActiveExportRequest`, preflight recommendation/choice loop, missing-media hard gate, terminal cleanup, progress/completion outputs и delivery flow больше не являются controller-owned logic.
7. Background editor session state вынесен из controller в runtime: tracked assets, active-session flag, preset tracking, import bookkeeping, dismiss sweep и effective-background rebuild теперь живут в `EditorRuntime`.
8. Введен и провязан `ProjectPreviewService` как shared preview seam для template flows; future saved-project preview seam закреплен архитектурно.
9. Закрыты required PR6 tests: `EditorRuntimeContractTests`, `RenderSourceSelectionTests`, `SceneEditTimelineHandoffTests`, `MissingMediaExportGateTests`, `ProjectPreviewServiceTests`, плюс migrated export/runtime flow coverage.
10. Подтвержден green validation loop для текущего финального дерева:
   - `Scripts/verify_module_boundary.sh`
   - `cd TVECore && swift test`
   - `Scripts/run_animiapp_tests.sh`
   - `make build`

### 10.1. Цель

Выделить `EditorRuntime` как owner runtime/playback/render/export execution graph и очистить controller до UI shell-а.

### 10.2. Реальные текущие code anchors

- `PlayerViewController.draw(in:)`
- runtime boot/setup в `PlayerViewController`
- `configureEditorTimeline()`
- scene-edit runtime coordination в `PlayerViewController`
- export orchestration, которая все еще близко к controller/runtime glue

### 10.3. Новые файлы

- `AnimiApp/Sources/EditorRuntime/EditorRuntime.swift`
- `AnimiApp/Sources/EditorRuntime/EditorRuntimeState.swift`
- `AnimiApp/Sources/EditorRuntime/EditorRuntimeOutput.swift`
- `AnimiApp/Sources/EditorRuntime/EditorRuntimeRenderSource.swift`
- `AnimiApp/Sources/Project/ProjectPreviewService.swift`

### 10.4. Изменяемые файлы

- `AnimiApp/Sources/Player/PlayerViewController.swift`
- `AnimiApp/Sources/Player/TimelinePlaybackCoordinator.swift`
- `AnimiApp/Sources/Player/TimelineComposition/TimelineCompositionEngine.swift`
- `AnimiApp/Sources/Export/VideoExporter.swift`
- `AnimiApp/Sources/UserMedia/UserMediaService.swift`

### 10.5. Implementation tasks

1. Ввести `EditorRuntime` как owner:
   - playback state;
   - render mode switching;
   - background runtime state;
   - media restore runtime state;
   - export execution orchestration.
2. Сделать `PlayerViewController` thin UI shell:
   - layout;
   - view lifecycle;
   - MTKView hosting;
   - user-input forwarding.
3. Убрать branch logic из `draw(in:)`:
   - controller не выбирает runtime branch сам;
   - controller получает render source / render command contract.
4. Перенести coordination между timeline runtime и scene-edit runtime в `EditorRuntime`.
5. Сохранить reuse существующих lower-level services, а не переписывать их без причины.
6. Ввести export preflight gate для missing required media:
   - export не стартует при missing required dependencies;
   - gate живет в runtime/export path, а не в controller UI alone.
7. Ввести `ProjectPreviewService` как architecture seam:
   - template preview data работает уже сейчас;
   - future saved-project preview seam существует;
   - visual saved-project preview сейчас не обязателен.

### 10.6. Что должно исчезнуть в этом PR

- controller-owned runtime boot/setup logic;
- export flow без missing-media preflight gate;
- `draw(in:)`, который сам решает, какой runtime path отрисовывать;
- export/background/media helpers, завязанные на controller state.

### 10.7. Required tests before merge

- полный базовый loop из раздела 3.6;
- `EditorRuntimeContractTests`;
- `RenderSourceSelectionTests`;
- `SceneEditTimelineHandoffTests`;
- `MissingMediaExportGateTests`;
- `ProjectPreviewServiceTests`;
- обновленные `EditorRenderContractTests`;
- обновленные `TimelineEngineLifecycleTests`;
- обновленные export/runtime flow tests.

### 10.8. Final status

PR6 delivered the canonical runtime/render/export boundary.

- `EditorRuntime` now owns the runtime/playback/render/export/background execution graph.
- `PlayerViewController` no longer reads raw runtime internals or owns direct runtime mutations.
- `draw(in:)` no longer branches by `uiMode`; render path is driven by `runtime.currentRenderSource`.
- initial scene boot/setup and background editor session orchestration are runtime-owned, not controller-owned.
- missing-media export gate lives on the runtime/export path and hard-stops export before execution.
- `ProjectPreviewService` is wired as the shared preview seam for template screens.
- canonical final validation state on the current tree is green:
  - `Scripts/verify_module_boundary.sh` — PASS
  - `cd TVECore && swift test` — PASS
  - `Scripts/run_animiapp_tests.sh` — **981 tests, 0 failures**
  - `make build` — PASS

## 11. PR 7. Blank Project, Duplicate Project And My Projects

### 11.1. Цель

Довести project-origin driven flows до production-state на новой архитектуре.

### 11.2. Реальные текущие code anchors

- `TemplatesHomeViewController` не имеет blank-project entry point;
- `MyProjectsViewController` умеет только open/delete;
- `ProjectPreviewCell` умеет только preview + delete;
- `SceneLibraryModels.SceneTypeDescriptor` не имеет visibility/usage metadata для starter-only scenes;
- `SceneCatalogViewController` показывает `sceneLibrary.scenesInOrder` как есть;
- `SceneLibrary` и `Resources/Scenes/library.json` не содержат starter scene для blank project.

### 11.3. Новые файлы

- `AnimiApp/Sources/Project/BlankProjectFactory.swift`
- `AnimiApp/Sources/Project/ProjectDuplicationUseCase.swift`
- `AnimiApp/Resources/Scenes/blank_starter/compiled.tve`

### 11.4. Изменяемые файлы

- `AnimiApp/Sources/TemplatesUI/TemplatesHomeViewController.swift`
- `AnimiApp/Sources/MyProjects/MyProjectsViewController.swift`
- `AnimiApp/Sources/MyProjects/ProjectPreviewCell.swift`
- `AnimiApp/Sources/App/AppCompositionRoot.swift`
- `AnimiApp/Sources/Editor/SceneCatalogViewController.swift`
- `AnimiApp/Sources/Content/SceneLibraryModels.swift`
- `AnimiApp/Sources/Content/SceneLibrary.swift`
- `AnimiApp/Sources/Content/BundleSceneLibraryLoader.swift`
- `AnimiApp/Resources/Scenes/library.json`

### 11.5. Implementation tasks

1. Ввести canonical starter scene type:
   - scene ID: `blank_starter`;
   - запись в `Resources/Scenes/library.json`;
   - ресурсная папка `Resources/Scenes/blank_starter`.
2. Добавить в `SceneTypeDescriptor` explicit visibility/usage metadata для starter-only scenes.
3. Отфильтровать обычный `SceneCatalogViewController`, чтобы `blank_starter` не показывался в стандартном `Add Scene` flow.
4. Реализовать `BlankProjectFactory`, который создает initial document с одним starter scene item.
5. Добавить blank-project entry point в `TemplatesHomeViewController`.
6. Завести routing из `AppCompositionRoot` на `EditorLaunchIntent.blankProject`.
7. Реализовать `ProjectDuplicationUseCase`.
8. Ограничить duplicate project только экраном `My Projects`.
9. Переделать `MyProjectsViewController` на новый summary/action model:
   - tap to open;
   - separate duplicate action;
   - separate delete action.
10. Переделать `ProjectPreviewCell`:
   - больше не зависеть от template preview как correctness contract;
   - уметь показать placeholder/no-preview saved project card;
   - заменить delete-only surface на action surface для duplicate/delete.
11. Обеспечить project independence semantics при duplicate.
12. Интегрировать уже введенный missing-media contract в saved/duplicated app flows, не меняя owner-а export gate.

### 11.6. Что должно исчезнуть в этом PR

- blank project как synthetic special case без persisted model;
- blank project без starter scene type;
- `blank_starter` в обычном `Add Scene` catalog;
- duplicate project как editor action;
- `My Projects`, который строится из `sourceTemplateId` и template preview как из единственного способа представить saved project;
- delete-only action surface в `ProjectPreviewCell`.

### 11.7. Required tests before merge

- полный базовый loop из раздела 3.6;
- `BlankProjectFlowTests`;
- `ProjectDuplicationUseCaseTests`;
- `SavedProjectsListingTests`;
- `SceneLibraryCatalogVisibilityTests`;
- обновленные `BundleSceneLibraryLoaderTests` для `blank_starter`;
- missing-media coverage для saved/duplicate open flows.

### 11.8. Final status

PR7 delivered the canonical blank-project / duplicate-project product flows.

- `EditorLaunchIntent.blankProject` is now shipped end-to-end: `TemplatesHomeViewController` opens it, `EditorSession` bootstraps it, and `BlankProjectFactory` materializes a persisted non-empty draft with starter scene `blank_starter`.
- `blank_starter` is now part of the shipped scene library as `starterOnly`; it remains loadable by id but is excluded from the normal scene catalog UI through `SceneLibrarySnapshot.catalogScenes`.
- `My Projects` now has a shipped duplicate action surface: `ProjectPreviewCell` exposes duplicate/delete actions, `MyProjectsViewController` wires duplicate through `SavedProjectsService`, and `ProjectDuplicationUseCase` materializes duplicates via the storage/persistence gateways.
- saved-project cards no longer depend on template preview as a correctness contract; `previewURL: nil` is a first-class supported state.
- duplicate flow is missing-media-safe: `FileProjectMediaStore.duplicateAssets(inDraft:)` now mints fresh broken descriptors for missing source files, so duplication still succeeds and the duplicated saved project activates the existing missing-media notice/export-gate contracts on reopen.
- PR7-specific coverage is now present:
  - `BlankProjectFlowTests`
  - `ProjectDuplicationUseCaseTests`
  - `DuplicateProjectMissingMediaFlowTests`
  - updated `AppCompositionRootTests`
  - updated `BundleSceneLibraryLoaderTests`
  - updated `SceneCatalogTests`
- canonical final validation state on the current tree is green:
  - `Scripts/verify_module_boundary.sh` — PASS
  - `cd TVECore && swift test` — PASS
  - `Scripts/run_animiapp_tests.sh` — **981 tests, 0 failures**
  - `make build` — PASS

## 12. PR 8. Audio V1: Single Project-Level Music Track

### 12.1. Цель

Довести audio до shipped V1 как один project-level music track, не ломая future path к multi-item audio editor.

### 12.2. Реальные текущие code anchors

- `GlobalActionBar` уже содержит `onMusic`;
- `EditorLayoutContainerView` пока не пробрасывает `onMusic`;
- `TimelineSelection.audio` пока placeholder;
- `ContextBar` для `.audio` показывает только `"Audio Options"`;
- `AudioTrackView` placeholder;
- `TimelinePayload.AudioPayload` scaffold;
- audio export infrastructure в проекте уже существует на lower-level, но editor/product flow не завершен.

### 12.3. Новые файлы

- новые music/audio UI types под `AnimiApp/Sources/Editor` и связанные session/model helpers рядом с текущим editor/project code, если существующих типов не хватает для picker/trim/volume flow.

### 12.4. Изменяемые файлы

- `AnimiApp/Sources/Editor/GlobalActionBar.swift`
- `AnimiApp/Sources/Editor/EditorLayoutContainerView.swift`
- `AnimiApp/Sources/Editor/TimelineSelection.swift`
- `AnimiApp/Sources/Editor/ContextBar.swift`
- `AnimiApp/Sources/Editor/AudioTrackView.swift`
- `AnimiApp/Sources/Editor/TimelineView.swift`
- `AnimiApp/Sources/Editor/Store/EditorAction.swift`
- `AnimiApp/Sources/Editor/Store/EditorState.swift`
- `AnimiApp/Sources/Editor/Store/EditorReducer.swift`
- `AnimiApp/Sources/EditorSession/EditorSession.swift`
- `AnimiApp/Sources/Project/TimelinePayload.swift`
- `AnimiApp/Sources/Player/PlayerViewController.swift`
- `AnimiApp/Sources/Export/VideoExporter.swift`

### 12.5. Implementation tasks

1. Пробросить `Music` callback из `GlobalActionBar` через `EditorLayoutContainerView` наружу.
2. Сделать реальный audio selection/edit flow вместо placeholder-а.
3. Реализовать model contract V1:
   - один music track на весь проект;
   - import/select;
   - remove;
   - trim start/end;
   - volume.
4. Привязать audio V1 к canonical asset registry из `PR 5`.
5. Интегрировать audio V1 в:
   - save;
   - duplicate;
   - export;
   - dirty tracking;
   - undo/redo.
6. Не строить special-case audio model, несовместимую с future multi-item audio editor.
7. Обновить timeline/context UI так, чтобы selection/editing было реальным, а не placeholder-only.

### 12.6. Что должно исчезнуть в этом PR

- placeholder-only `Music` flow;
- `EditorLayoutContainerView`, который не умеет пробрасывать `onMusic`;
- path-based imported audio reference;
- audio logic, живущая вне canonical timeline/session/export flow.

### 12.7. Required tests before merge

- полный базовый loop из раздела 3.6;
- `ProjectMusicTrackTests`;
- обновленные `ProjectDuplicationUseCaseTests` с music payload coverage;
- обновленные `ProjectDuplicatePayloadRoundTripTests` с music payload coverage;
- обновленные export tests с music coverage;
- обновленные audio writer / export session tests;
- UI/state tests для audio selection/edit/trim/volume behavior.

## 13. PR 9. Text Overlay Timeline Editing

### 13.1. Цель

Довести text overlays до shipped состояния с реальным timeline contract, а не с кнопкой-заглушкой.

### 13.2. Реальные текущие code anchors

- `GlobalActionBar` уже содержит `onAddText`;
- `EditorLayoutContainerView` пока не пробрасывает `onAddText`;
- `TimelineSelection` пока не умеет text selection;
- `ContextBar` не имеет text-specific editing mode;
- `TimelinePayload.TextPayload` уже существует, но только как scaffold.

### 13.3. Новые файлы

- новые text overlay UI/editor types под `AnimiApp/Sources/Editor` и связанные session/runtime helpers рядом с текущим editor/render code.

### 13.4. Изменяемые файлы

- `AnimiApp/Sources/Editor/GlobalActionBar.swift`
- `AnimiApp/Sources/Editor/EditorLayoutContainerView.swift`
- `AnimiApp/Sources/Editor/TimelineSelection.swift`
- `AnimiApp/Sources/Editor/ContextBar.swift`
- `AnimiApp/Sources/Editor/TimelineView.swift`
- `AnimiApp/Sources/Editor/Store/EditorAction.swift`
- `AnimiApp/Sources/Editor/Store/EditorState.swift`
- `AnimiApp/Sources/Editor/Store/EditorReducer.swift`
- `AnimiApp/Sources/EditorSession/EditorSession.swift`
- `AnimiApp/Sources/Project/TimelinePayload.swift`
- `AnimiApp/Sources/Player/PlayerViewController.swift`
- runtime/render/export files, где нужен overlay render path

### 13.5. Implementation tasks

1. Пробросить `Text` callback из `GlobalActionBar` через `EditorLayoutContainerView`.
2. Расширить `TimelineSelection` text-specific cases.
3. Расширить `ContextBar` или соседний inspector flow под text editing.
4. Реализовать add/edit/remove/move/trim для text overlays.
5. Реализовать timing contract для text overlays на timeline.
6. Реализовать positioning contract для text overlays.
7. Подключить text overlays к preview/export/save/duplicate/dirty/undo flows.
8. Не вводить отдельный second rendering stack: text overlays должны опираться на canonical runtime/render pipeline.

### 13.6. Что должно исчезнуть в этом PR

- placeholder-only `Text` flow;
- `EditorLayoutContainerView`, который не умеет пробрасывать `onAddText`;
- text overlay model без timing/positioning semantics.

### 13.7. Required tests before merge

- полный базовый loop из раздела 3.6;
- `TextOverlayIntegrationTests`;
- обновленные `ProjectDuplicationUseCaseTests` с text payload coverage;
- обновленные `ProjectDuplicatePayloadRoundTripTests` с text payload coverage;
- обновленные render/export tests с text overlay coverage;
- reducer/state tests для add/edit/remove/move/trim behavior.

## 14. PR 10. Sticker Overlay Timeline Editing

### 14.1. Цель

Довести sticker overlays до shipped состояния с тем же canonical timeline/render/export contract.

### 14.2. Реальные текущие code anchors

- `GlobalActionBar` уже содержит `onSticker`;
- `EditorLayoutContainerView` пока не пробрасывает `onSticker`;
- `TimelineSelection` не умеет sticker selection;
- `ContextBar` не имеет sticker-specific editing mode;
- `TimelinePayload.StickerPayload` уже существует, но это scaffold.

### 14.3. Новые файлы

- новые sticker overlay UI/editor types под `AnimiApp/Sources/Editor` и связанные session/runtime helpers рядом с текущим editor/render code.

### 14.4. Изменяемые файлы

- `AnimiApp/Sources/Editor/GlobalActionBar.swift`
- `AnimiApp/Sources/Editor/EditorLayoutContainerView.swift`
- `AnimiApp/Sources/Editor/TimelineSelection.swift`
- `AnimiApp/Sources/Editor/ContextBar.swift`
- `AnimiApp/Sources/Editor/TimelineView.swift`
- `AnimiApp/Sources/Editor/Store/EditorAction.swift`
- `AnimiApp/Sources/Editor/Store/EditorState.swift`
- `AnimiApp/Sources/Editor/Store/EditorReducer.swift`
- `AnimiApp/Sources/EditorSession/EditorSession.swift`
- `AnimiApp/Sources/Project/TimelinePayload.swift`
- `AnimiApp/Sources/Player/PlayerViewController.swift`
- runtime/render/export files, где нужен sticker overlay render path

### 14.5. Implementation tasks

1. Пробросить `Sticker` callback из `GlobalActionBar` через `EditorLayoutContainerView`.
2. Расширить `TimelineSelection` sticker-specific cases.
3. Расширить `ContextBar` или соседний inspector flow под sticker editing.
4. Реализовать add/remove/move/trim для sticker overlays.
5. Реализовать timing contract для sticker overlays.
6. Реализовать positioning contract для sticker overlays.
7. Подключить sticker overlays к preview/export/save/duplicate/dirty/undo flows.
8. Использовать тот же canonical runtime/render pipeline, что и для text overlays.

### 14.6. Что должно исчезнуть в этом PR

- placeholder-only `Sticker` flow;
- `EditorLayoutContainerView`, который не умеет пробрасывать `onSticker`;
- sticker overlay model без timing/positioning semantics.

### 14.7. Required tests before merge

- полный базовый loop из раздела 3.6;
- `StickerOverlayIntegrationTests`;
- обновленные `ProjectDuplicationUseCaseTests` с sticker payload coverage;
- обновленные `ProjectDuplicatePayloadRoundTripTests` с sticker payload coverage;
- обновленные render/export tests с sticker overlay coverage;
- reducer/state tests для add/remove/move/trim behavior.

## 15. PR 11. Legacy Cleanup, Renames And Ban Enforcement

### 15.1. Цель

Удалить transitional seams, окончательно добить legacy ownership model и привести naming/anti-pattern bans к финальному виду.

### 15.2. Реальные текущие code anchors

- `PlayerViewController` как legacy имя для editor shell;
- legacy persistence compatibility traces в project/storage model;
- возможные оставшиеся `.shared` access paths;
- возможные оставшиеся adapters, которые были нужны только во время rollout.

### 15.3. Новые файлы

- если нужны lint/guardrail scripts для anti-pattern bans, они добавляются здесь.

### 15.4. Изменяемые файлы

- весь app target по результату `rg`-проверок на legacy seams;
- `AnimiApp/project.yml`;
- `AnimiApp/AnimiApp.xcodeproj/project.pbxproj`

### 15.5. Implementation tasks

1. Переименовать `PlayerViewController` в `EditorViewController`.
2. Удалить `PlayerViewController.EntryContext` и любые остаточные launch-intent дублеры.
3. Удалить transitional adapters, которые больше не нужны после полного cutover.
4. Удалить все оставшиеся direct product-owned architectural singleton access paths из feature/session/runtime/export/media code:
   - `ProjectStore.shared`
   - `TemplateCatalog.shared`
   - `SceneLibrary.shared`
   - `BackgroundPresetLibrary.shared`
5. Удалить или сузить legacy `ProjectStore` symbol так, чтобы raw singleton API больше не был частью архитектуры.
6. Удалить любой legacy compatibility code, который должен был исчезнуть раньше по greenfield policy, и проверить, что он не пережил свой PR.
7. Удалить obsolete tests, покрывавшие только удаленный compatibility layer.
8. Добавить guardrails:
   - ban на новый raw `ProjectStore.shared`;
   - ban на новый product-owned architectural singleton в feature code;
   - ban на controller-owned persistence state;
   - ban на placeholder-only shipped flow для audio/text/sticker.

Системные и infrastructure singletons вроде `UIApplication.shared`, `PHPhotoLibrary.shared()` или process-wide caches не считаются нарушением этого запрета сами по себе.

### 15.6. Что должно исчезнуть в этом PR

- имя `PlayerViewController` как финальное имя editor shell-а;
- любые legacy rollout seams, пережившие свой PR;
- raw `ProjectStore.shared` как публичный app-wide pattern.

### 15.7. Required tests before merge

- полный базовый loop из раздела 3.6;
- full app test suite;
- full search-based audit:
  - нет `ProjectStore.shared` вне gateway implementation layer;
  - нет `TemplateCatalog.shared` / `SceneLibrary.shared` / `BackgroundPresetLibrary.shared` вне repository/infrastructure layer;
  - нет `currentProjectDraft`, `draftIsDirty`, `projectBackgroundOverride`;
  - нет `PlayerViewController.EntryContext`;
  - нет `PersistedVideoSelectionMigrationTests`;
  - нет shipped placeholder-only `Music` / `Text` / `Sticker` flow.

## 16. Финальный Expected State После Всех PR

После `PR 11` в репозитории должно быть истинно следующее:

- launch/editor routing идет через `AppCompositionRoot`;
- recovery flow на старте приложения явный и управляется prompt-ом;
- templates/scene-library/background-preset flows идут через repository layer, а не через direct singletons;
- `EditorSession` является единственным owner-ом editor lifecycle и authoritative content state;
- `EditorRuntime` является единственным owner-ом runtime/playback/render/export state;
- controller является thin UI shell-ом;
- persisted model опирается на `ProjectOrigin`, а не на `sourceTemplateId`;
- `My Projects` опирается на `SavedProjectsService` и summary metadata v2;
- blank project shipped и стартует со `sceneType` `blank_starter`;
- `blank_starter` скрыт из обычного `Add Scene` catalog через явный scene-library visibility/usage contract;
- duplicate project shipped и существует только в `My Projects`;
- template preview shipped;
- saved-project visual preview может отсутствовать, но preview seam существует;
- missing-media notice не блокирует open/reopen, но export блокируется при missing required media;
- audio V1 shipped как один project-level music track;
- text overlays shipped с timing, positioning и timeline editing;
- sticker overlays shipped с timing, positioning и timeline editing;
- old local-data compatibility code удален;
- legacy ownership model удален, а не спрятан под adapters.

Если после выполнения всех PR для `blank project`, `duplicate project`, audio V1, text overlays, sticker overlays или future saved-project preview seam потребуется еще один structural rewrite, значит playbook выполнен неправильно.

## PR5 — Delivered (final status)

PR5 shipped the canonical storage boundary and asset-identity cutover. All plan goals delivered, all 4 validation gates green on fresh clean DerivedData, all grep acceptance contracts satisfied.

### Delivered scope

- **Asset identity**: `MediaRef` is `Equatable`/`Hashable` by `ProjectAssetID`, not `storagePath`. `MediaRef.storagePath` retained as internal cache field (not identity), no cascading rewrite required.
- **Registry**: `ProjectAssetRegistry` on every `ProjectDraft`, keyed by `ProjectAssetID`, stores `ProjectAssetDescriptor { assetId, mediaKind, storagePath }`. Full lifecycle API: `register` / `unregister` / `replace` / `descriptor(for:)` / `assetIds(referencedBy:)` / `storagePaths(referencedBy:)`.
- **Locator**: `ProjectMediaLocator.absoluteURL(for: MediaRef, registry: ProjectAssetRegistry) async throws -> URL` — canonical, value-passed, instance-scoped. Retained `@available(*, deprecated)` compatibility shims for the legacy single-argument `absoluteURL(for:)`: (a) `ProjectMediaLocator` protocol extension, (b) `FileProjectMediaStore` internal method, (c) `ProjectStore` public method. All three exist for test convenience. Production runtime/composition/export has zero callers, grep-enforced by `rg 'absoluteURL\(for: [^,)]+\)' AnimiApp/Sources` → 0 hits.
- **`ProjectStore` class** is retained as a test-only constructor helper. Production `ProjectStore.shared` is gone (grep-enforced). The class is instantiated directly in **multiple test-only call sites** across several test files. These use it for two things: resolving `projectsDirectoryURL()` to seed test files, and as a convenient `absoluteURL(for:)` shim that doesn't require constructing a registry snapshot. Production runtime/composition/export never instantiates it. Migrating tests off `ProjectStore` is deferred as future test-infra work; it is not part of PR5's contract.
- **Known deferred: Swift 6 concurrency warnings at 3 sites.** Not a PR5 blocker, deferred to a separate Swift 6 migration PR:
  - `AnimiApp/Sources/Player/SceneRuntimeStateApplier.swift:39` — `ScenePlayerMediaInputProvider` `@MainActor` struct conforming to a non-`@MainActor` protocol `MediaInputProvider`.
  - `AnimiApp/Sources/Content/SceneLibraryRepository.swift:19` — `init(library: SceneLibrary = .shared)` default argument references a `@MainActor` singleton from nonisolated default-arg context.
  - `AnimiApp/Sources/TemplatesCatalog/TemplateCatalogRepository.swift:23` — same pattern as `SceneLibraryRepository`.
  These are warnings today and would be errors in Swift 6 language mode. PR5 does not touch them.
- **Fallback counter**: `FileProjectMediaStore.legacyFallbackHits` is an observable seam. Tests assert it stays 0 on production happy-path.
- **Write gateway**: `ProjectMediaWriteGateway.duplicateAssets(inDraft:)` is the storage-level foundation for PR7's duplicate-project action. Proven independent by `DuplicateProjectAssetIndependenceTests`.
- **GC policy**: referenced-primary (via `storagePaths(referencedBy:)`) + raw-scan defense-in-depth. Registered-but-unreferenced descriptors are GC-eligible — registry does NOT pin files.
- **Session bookkeeping**: non-dirtying `registerAssetBookkeeping` / `unregisterAssetBookkeeping` via internal `EditorStore.mutateCurrentDraftForBookkeeping` seam. Registry mutations never push undo snapshots, never emit store callbacks, never mark the dirty baseline. `EditorSessionSnapshot` deliberately excludes `assetRegistry`.
- **Production wiring**: `MediaIngestCoordinator.onAssetPersisted` callback fires strictly before `onIngestComplete`, wired by `PlayerViewController` to `session.registerAssetBookkeeping`. Background import path is now runtime-owned: `EditorRuntime.importBackgroundImage(...)` registers bookkeeping immediately after persist, loads texture against a fresh self-healed registry snapshot, and either commits directly to store or defers the editor-local image update during an active background-editor session. Slot removal, slot replacement, background editor dismiss, and background image replace all call `unregisterAssetIfUnreferenced` post-dispatch with shared-reference safety. Ingest abort branches directly unregister before deleting orphan files. Intermediate background imports are tracked on `EditorRuntime.backgroundEditorTrackedAssetIds` and swept inside `EditorRuntime.commitBackgroundEditorDismiss(...)`.
- **Runtime storage boundary**: `SceneInstanceRuntime` holds a `ProjectMediaLocator` (not a `resolveURL` closure) and its `applyState(_:assetRegistry:)` takes an explicit registry snapshot. `TimelineCompositionEngine` stores `currentAssetRegistry` (matches how `sceneStates` is held), set via `setTimeline(_:sceneStates:assetRegistry:)`. No raw `FileProjectMediaStore()` construction anywhere in runtime/composition/export.
- **Async apply migration**: `PlayerViewController.applySceneInstanceState(instanceId:)` and `reloadRuntimeState(for:)` are now `async`. Every call site is wrapped in `Task { @MainActor }` with post-apply side effects (`setNeedsDisplay`, `refreshSceneEditBars`, engine sync) moved inside the awaited body to preserve ordering. Ingest abort and handleStateRestoredFromUndoRedo both converted.

### Chosen resolution: self-healing registry

The plan flagged an open risk around undo/registry symmetry: if a slot-unregister runs and is followed by undo, the draft's content references an `assetId` that no longer has a registry descriptor. The chosen resolution is **self-healing at resolution time**, not widening the undo snapshot and not making `register` dirtying.

- `ProjectAssetRegistry.selfHealed(for: ProjectDraft) -> ProjectAssetRegistry` — pure value-returning walker. For any `assetId` that content references but registry does not contain, synthesizes a descriptor from the live `MediaRef` (assetId / mediaKind / storagePath) and returns a healed copy. Does not mutate the receiver. Does not write back to session state.
- `EditorRuntime.selfHealedRegistry()` — wrapper that reads `session.state?.draft` and returns `draft.assetRegistry.selfHealed(for: draft)`. Called at every production runtime/export/background point where the tree passes a registry into downstream code: scene apply/restore fast-paths, timeline engine sync, texture load/preload, `ExportMediaSnapshot.build`, `exporter.exportVideo`, and `exporter.exportTimeline`.
- `handleStateRestoredFromUndoRedo` specifically uses the self-healed snapshot when re-syncing the engine after undo — this is the exact undo-symmetry scenario that motivated the design.
- Tests in `ProjectAssetIdentityContractTests.test_selfHealed_*` cover: empty draft, all present, missing slot descriptor synthesis, missing background descriptor synthesis, receiver purity, and the "self-healed registry does NOT bump legacyFallbackHits" assertion.

### PR5 contract tests delivered

- `ProjectAssetIdentityContractTests` — asset identity, registry lifecycle, draft walkers, primary/fallback storagePaths resolution, registry-backed locator, legacy fallback counter observable, **self-healing**.
- `AssetRegistryBookkeepingTests` — non-dirty register/unregister, draft-visible after register, ride-next-save, undo does not remove descriptor, ingest-abort unregister, shared-reference safety, background editor intermediate sweep.
- `RuntimeStorageBoundaryTests` — `MediaAssetStore.saveMedia` routes via injected writer; `ResolvedMediaMapBuilder.build` uses injected locator with passed registry (descriptor hit); de-duplication by assetId; `BackgroundTextureService.loadTexture` routes via injected locator.
- `ExportStorageBoundaryTests` — `ExportMediaSnapshot.build` uses injected locator only with populated registry (descriptor hit); does not fall back to `ProjectStore`; hidden slots do not touch locator.
- `DuplicateProjectAssetIndependenceTests` — storage-level proof of duplicate independence: new draft id, zero shared `assetId`s, zero shared `storagePath`s, source files survive copy, duplicate survives source deletion, content is copied.
- `AssetRegistryGCContractTests` — 4-state GC matrix: registered+referenced survives, registered+unreferenced deleted (no registry pinning), unregistered+referenced survives via scan, plain orphan deleted.

### Validation gates (fresh clean DerivedData)

1. `Scripts/verify_module_boundary.sh` — **PASS** (exit 0).
2. `cd TVECore && rm -rf .build && swift test` — **939 tests, 86 skipped (Metal), 0 failures**.
3. `Scripts/run_animiapp_tests.sh` — **981 tests, 0 failures, 0 unexpected, `** TEST SUCCEEDED **`**.
4. `make build` — **`** BUILD SUCCEEDED **`**, exit 0.

### Grep contracts

```
grep -rn 'FileProjectMediaStore(' AnimiApp/Sources         # 2 canonical (ProjectStore + ProjectStorageActor)
grep -rnE 'absoluteURL\(for: [^,)]+\)' AnimiApp/Sources    # 0
grep -rn 'resolveMediaURLSync' AnimiApp                    # 0
grep -rn 'SceneRuntimeStateApplier\.Dependencies' AnimiApp # 0 (split into FastPath + Restore)
grep -rn 'SessionMediaLocator' AnimiApp                    # 0
grep -rn 'ProjectStore\.shared' AnimiApp                   # 0
```

All contracts hold.

### Incident notes (for reference)

- Phase E blocker (review-caught): `PlayerViewController.mediaIngestCoordinator` was `private lazy var`, and `deinit` accessed it for the first time from a VC that never exercised ingest. Swift's lazy initializer runs on first access and the init block captured `[weak self]`, crashing with "Cannot form weak reference to instance ... is in the process of deallocation". Fix: explicit backing storage `_mediaIngestCoordinator: MediaIngestCoordinator?` + computed lazy accessor; `deinit` calls `_mediaIngestCoordinator?.cancelAllFromDeinit()` only if the coordinator was ever created.
- `AppCompositionRootTests` 3 push-assertion tests required a `waitForPushToCommit()` run-loop drain helper because modern iOS simulators defer `UINavigationController.pushViewController(animated: true)` in orphan-window test harnesses. Production code is unchanged.
- Phase F packaging fix (`folder → group` on `Resources/Templates`) turned out to be a no-op: the `manifestNotFound` bug the plan described did not reproduce on fresh clean DerivedData on the target machine. No configuration change was shipped.
