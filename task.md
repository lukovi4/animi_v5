**Каноническое ТЗ: Topology + Metadata Templates/Scenes (Release, без legacy)**

**1. Цель**
1. Сделать один источник правды для runtime-сцен и один источник правды для template-метаданных.
2. Полностью удалить legacy topology/metadata, чтобы исключить дубли, path-drift и неявные зависимости от layout bundle.
3. Оставить только release-эффективный pipeline: `Catalog -> Template metadata -> Scene library -> compiled.tve`.

**2. Зафиксированные проблемы в текущем коде**
1. Runtime-контент дублируется в `Resources/Scenes` и `Resources/Templates/*` (одинаковые `compiled.tve`).
2. Runtime уже читает `Scenes`, но scripts и metadata частично завязаны на `Templates`.
3. Модели держат filesystem paths как доменные поля (`recipePath`, `previewVideoPath`, `folderPath`), что ломает инварианты при любом переносе файлов.
4. `manifest.json` ссылается на `Templates/Previews/*.mp4`, но фактически preview assets отсутствуют.

**3. Целевая каноническая topology**
1. `AnimiApp/Resources/Scenes/<sceneTypeId>/compiled.tve` — единственный runtime source для сцен.
2. `AnimiApp/Resources/Templates/Catalog/manifest.json` — единственный source для template-catalog metadata.
3. `AnimiApp/Resources/Templates/Previews/<templateId>.mp4` — единственный source для template preview media (optional per template).
4. `AnimiApp/Resources/Templates/Recipes/*` удаляется.
5. `AnimiApp/Resources/Templates/<scene folders>` удаляется полностью (compiled/source json/anim json).

**4. Целевая каноническая metadata**
1. `manifest.json` переводится на identifier-based schema.
2. У шаблона хранятся: `id`, `categoryId`, `order`, `title`, `titleKey?`, `sceneTypeIds:[String]`, `previewAsset?`, `openBehavior`.
3. Поля `recipePath` и `previewVideoPath` удаляются из schema и кода.
4. `Scenes/library.json` оставляет только доменные поля сцены: `id`, `order`, `title`, `baseDurationUs`; path-поля удаляются.
5. Поля `folderPath` и `previewImagePath` удаляются из schema и кода.
6. URL сцены резолвится по конвенции `Scenes/<sceneTypeId>`; это не хранится в JSON.

**5. Обязательные изменения в коде**
1. Обновить модели каталога в [TemplateModels.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/TemplatesCatalog/TemplateModels.swift).
2. Переписать loader каталога в [BundleTemplateCatalogLoader.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/TemplatesCatalog/BundleTemplateCatalogLoader.swift) под новую schema без path-полей.
3. Удалить recipe-слой: [TemplateRecipe.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Content/TemplateRecipe.swift), [BundleTemplateRecipeLoader.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Content/BundleTemplateRecipeLoader.swift).
4. Обновить scene-модели в [SceneLibraryModels.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Content/SceneLibraryModels.swift) и убрать path-поля.
5. Переписать scene loader в [BundleSceneLibraryLoader.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Content/BundleSceneLibraryLoader.swift) на convention-based resolution `Scenes/<id>`.
6. Переписать вход в редактор в [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift): убрать `BundleTemplateRecipeLoader`, брать `sceneTypeIds` из `TemplateCatalog`, собирать `defaultSceneSequence` через `SceneLibrary`.
7. Сохранить API чтения previewURL для UI (`TemplatePreviewCell`, `TemplateDetailsViewController`, `MyProjects`) через resolved `previewAsset`.
8. Обновить ресурсный состав в [project.yml](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/project.yml): `Templates` содержит только `Catalog` и `Previews`; runtime-сцены только в `Scenes`.

**6. Скрипты/CI (обязательно)**
1. Переписать [compile_templates.sh](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/Scripts/compile_templates.sh) в `compile_scenes.sh` (или эквивалент): output только в `Resources/Scenes`.
2. Переписать [verify_release_bundle.sh](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/Scripts/verify_release_bundle.sh):
   - fail если в bundle есть `Templates/*/compiled.tve`, `scene.json`, `anim-*.json`, `no-anim.json`;
   - pass только если для каждой сцены из `Scenes/library.json` существует `Scenes/<id>/compiled.tve`;
   - fail если template с `previewAsset` ссылается на отсутствующий файл.
3. Добавить шаги проверки topology/metadata в [.github/workflows/ci.yml](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/.github/workflows/ci.yml).

**7. Legacy removal (жестко, без совместимости)**
1. Удалить директории `AnimiApp/Resources/Templates/example_4blocks`, `.../polaroid_shared_demo`, `.../polaroid_2`.
2. Удалить директорию `AnimiApp/Resources/Templates/Recipes`.
3. Удалить path-based parsing/резолв в loaders и models.
4. Удалить все проверки/комментарии/доки, предполагающие `compiled.tve` внутри `Templates`.

**8. Критерии приемки (DoD)**
1. В runtime нет ни одного кода-пути, читающего scene content из `Templates`.
2. В bundle нет legacy runtime artifacts в `Templates`.
3. `xcodebuild test` по `AnimiApp` проходит полностью.
4. `swift test` по `TVECore` проходит в рамках текущих ограничений CI.
5. `verify_release_bundle.sh` проходит на собранном `.app`.
6. Открытие template из каталога, запуск редактора и resume saved project работают без regressions.
7. Preview карточек использует только `Templates/Previews` и корректно деградирует на placeholder, если preview не задан в metadata.
8. Кодовая база не содержит legacy recipe/path contracts и двойной topology.

**9. Порядок внедрения**
1. Сначала schema+models+loaders.
2. Потом `PlayerViewController` и runtime wiring.
3. Потом физическое удаление legacy ресурсов.
4. Потом scripts/CI.
5. Потом финальная зачистка dead code/docs.

Блокирующих продуктовых вопросов для этой фазы нет.