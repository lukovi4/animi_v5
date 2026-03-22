**1. Базовая Реальность Кода**
- Общие шаблоны уже реализованы как bundle-каталог: `manifest.json` -> `TemplateCatalog` -> `TemplateDescriptor` -> `recipe`. Основание: [SceneDelegate.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/App/SceneDelegate.swift#L19), [TemplateCatalog.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/TemplatesCatalog/TemplateCatalog.swift#L5), [BundleTemplateCatalogLoader.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/TemplatesCatalog/BundleTemplateCatalogLoader.swift#L33), [manifest.json](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Resources/Templates/Catalog/manifest.json#L1).
- Шаблон в текущей доменной модели это immutable recipe `templateId + sceneTypeIds`, а не пользовательский документ. Основание: [TemplateRecipe.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Content/TemplateRecipe.swift#L5), [BundleTemplateRecipeLoader.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Content/BundleTemplateRecipeLoader.swift#L40).
- Редактор сейчас открывается только по `templateId`; он загружает `SceneLibrary`, recipe и затем `ProjectDraft`. Основание: [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift#L74), [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift#L247).
- `ProjectDraft` уже содержит почти весь нужный payload пользовательского проекта: `background`, `canonicalTimeline`, `sceneInstanceStates`, `MediaRef`, `createdAt`, `updatedAt`, `name`. Основание: [ProjectDraft.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Project/ProjectDraft.swift#L5), [ProjectBackgroundOverride.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Project/ProjectBackgroundOverride.swift#L5), [SceneState.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Project/SceneState.swift#L6), [CanonicalTimeline.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Project/CanonicalTimeline.swift#L100).
- Главная архитектурная проблема текущей версии: `ProjectStore` держит индекс `templateId -> projectId`, то есть физически допускает только один проект на один шаблон. Основание: [ProjectStore.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Project/ProjectStore.swift#L41), [ProjectStore.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Project/ProjectStore.swift#L197).
- Текущий autosave уже существует: editor dirty-state сохраняется через `saveDraftIfNeeded`, а schema crash-draft API уже заложен в `ProjectStore`, но не интегрирован в пользовательский flow. Основание: [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift#L1817), [ProjectStore.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Project/ProjectStore.swift#L383).

**2. Каноническая Функциональная Спецификация**
- В продукте существуют ровно три разные сущности: `CommonTemplate`, `ActiveEditorDraft`, `SavedProject`.
- `CommonTemplate` это bundle-ресурс приложения, общий для всех пользователей, immutable, не меняется никакими пользовательскими действиями.
- `ActiveEditorDraft` это единственный текущий unsaved session-state редактора. Он существует только для resume editing, локален, не является проектом и никогда не показывается в `My Projects`.
- `SavedProject` это локально сохранённый пользовательский проект. Он создаётся на основе общего шаблона, хранит все пользовательские изменения и показывается в `My Projects`.
- Один `CommonTemplate` может породить неограниченное число `SavedProject`.
- Каждый tap по `Use template` всегда создаёт новый `ActiveEditorDraft`, даже если этот же шаблон уже использовался раньше.
- `Save` создаёт новый `SavedProject`, если draft ещё не был сохранён в этой сессии, либо обновляет уже связанный `SavedProject`, если он уже существует.
- Успешный `Export` всегда делает то же самое, что `Save`: создаёт новый `SavedProject` либо обновляет существующий проект текущей editor-session.
- Неуспешный `Export` не должен создавать и не должен обновлять `SavedProject`.
- Если пользователь редактирует уже сохранённый проект, editor работает не напрямую с проектом, а с `ActiveEditorDraft`, созданным как working copy этого проекта.
- `Back/Close` + `Не сохранять` удаляет `ActiveEditorDraft`; если draft был копией уже сохранённого проекта, сохранённый проект остаётся без изменений.
- Свертывание приложения, уход в background, system kill или crash не считаются сознательным выходом; в этих случаях `ActiveEditorDraft` должен сохраниться для `Continue editing`.
- Одновременно в системе может существовать только один `ActiveEditorDraft`.
- Локальное хранение только on-device; аккаунтов, профилей, sync и cloud в этой версии нет.

**3. Содержимое Данных**
- `SavedProject` должен хранить весь пользовательский state, который уже описывается текущим `ProjectDraft`: весь timeline, scene order, durations, transitions, background overrides, per-scene customizations, photo/video assignments, added scenes, variant/toggle/transform state, timestamps и связанные media files.
- `ProjectDraft` должен остаться основным content-schema для editor payload; это минимально инвазивно и соответствует текущему коду. Основание: [ProjectDraft.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Project/ProjectDraft.swift#L5).
- В `My Projects` должны попадать только сохранённые сущности; unsaved draft туда никогда не индексируется.
- В первой версии у `SavedProject` обязательна операция `Delete`; `Rename` и `Duplicate` исключаются из scope.
- Поскольку `ProjectDraft.name` в текущем продукте не используется в UI, v1 не обязана вводить rename-flow; список `My Projects` может опираться на template title + metadata, пока отдельная naming-UX не утверждена. Основание: [ProjectDraft.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Project/ProjectDraft.swift#L31).

**4. UI И Навигация**
- Домашний каталог общих шаблонов остаётся существующим flow: `TemplatesHome` -> `TemplateDetails` -> editor. Основание: [TemplatesHomeViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/TemplatesUI/TemplatesHomeViewController.swift#L222), [TemplateDetailsViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/TemplatesUI/TemplateDetailsViewController.swift#L189).
- Добавляется отдельный экран `My Projects`, который показывает только `SavedProject`.
- Открытие проекта из `My Projects` должно создавать `ActiveEditorDraft` из snapshot проекта и затем запускать editor.
- Если при cold start найден `ActiveEditorDraft`, приложение должно предлагать `Continue editing` и возвращать пользователя в editor на то же место редактирования.
- `Continue editing` не является элементом `My Projects` и не создаёт новую saved-entity.
- При обычном открытии общего шаблона editor стартует как `new from template`, а не как открытие уже существующего проекта.

**5. Техническое Задание По Коду**
- Сохранить без изменений bundle-layer общих шаблонов: [TemplateCatalog.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/TemplatesCatalog/TemplateCatalog.swift#L5), [BundleTemplateCatalogLoader.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/TemplatesCatalog/BundleTemplateCatalogLoader.swift#L33), [BundleTemplateRecipeLoader.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Content/BundleTemplateRecipeLoader.swift#L40), [SceneLibrary.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Content/SceneLibrary.swift#L5).
- Убрать из persistence ключевое предположение `one templateId = one projectId`; текущий `ProjectsIndex.byTemplateId` должен быть заменён на storage saved-projects, индексируемых по `projectId`, с возможностью многих проектов на один `templateId`. Основание: [ProjectStore.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Project/ProjectStore.swift#L41).
- Разделить хранилище на два домена: `active draft slot` и `saved projects store`.
- `active draft slot` должен хранить только один текущий editor draft и его metadata для resume.
- `saved projects store` должен хранить произвольное количество проектов, каждый со своим `projectId`, `templateId/sourceTemplateId`, snapshot-content и timestamps.
- `PlayerViewController` должен перестать иметь единственный вход `init(templateId:)`; ему нужен явный entry-context: `newFromTemplate`, `openSavedProject`, `resumeActiveDraft`. Основание: [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift#L74).
- Текущий путь autosave `saveDraftIfNeeded()` должен писать в `active draft slot`, а не в `SavedProject`. Основание: [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift#L1817).
- Явные `Save` и успешный `Export` должны materialize/overwrite `SavedProject` из текущего `ActiveEditorDraft`.
- При открытии сохранённого проекта и последующем `Не сохранять` нужно discard-ить только draft copy; last saved snapshot проекта должен оставаться нетронутым.
- Текущая логика `EditorReducer.loadProject`, которая заполняет пустой timeline из recipe, должна применяться только для `newFromTemplate`; при `openSavedProject` и `resumeActiveDraft` приоритет всегда у сохранённого snapshot. Основание: [EditorReducer.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Editor/Store/EditorReducer.swift#L184).
- Нужно расширить media-GC и delete semantics: сейчас orphan cleanup смотрит только background media и не учитывает scene media assignments; в новой архитектуре GC должен учитывать `SavedProject` и `ActiveEditorDraft`, а также user photo/video media. Основание: [ProjectStore.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Project/ProjectStore.swift#L334), [ProjectStore.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Project/ProjectStore.swift#L445).

**6. Acceptance Criteria**
- Два последовательных нажатия `Use template` на одном и том же общем шаблоне после `Save/Export` создают два разных `SavedProject` с разными `projectId`.
- После редактирования нового шаблона без `Save/Export` проект не появляется в `My Projects`.
- После background/system kill активный draft восстанавливается через `Continue editing` в том же editor-session.
- После `Back/Close` + `Не сохранять` активный draft исчезает, `Continue editing` больше недоступен, `My Projects` не меняется.
- После открытия проекта из `My Projects`, внесения правок и `Не сохранять` сохранённый проект остаётся в последнем saved-state.
- `Delete` удаляет только выбранный `SavedProject`; общий шаблон в bundle и другие проекты на его основе не меняются.
- Общие шаблоны остаются read-only источником recipe и никогда не получают пользовательские мутации.

Если нужно, следующим сообщением оформлю это уже как `implementation plan` по файлам и модулям: что именно менять в `ProjectStore`, `PlayerViewController`, навигации и новых экранах.