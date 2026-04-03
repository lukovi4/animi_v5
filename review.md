Да. Канонично это надо делать **двумя отдельными follow-up PR**, потому что это **две разные подсистемы**:

1. **Template resource graph hardening + удаление мертвого legacy loader**
2. **Исправление cancellation/continuation бага в video still extraction**

Ниже финальное ТЗ строго по текущему коду.

**PR I: Template Resource Graph Hardening**
**Проблема**
- Сейчас UI шаблонов публикуется из [manifest.json](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Resources/Templates/Catalog/manifest.json), а scene library живет отдельно в [library.json](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Resources/Scenes/library.json).
- [BundleTemplateCatalogLoader.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/TemplatesCatalog/BundleTemplateCatalogLoader.swift) валидирует только `empty sceneTypeIds`.
- [BundleSceneLibraryLoader.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Content/BundleSceneLibraryLoader.swift) валидирует только наличие папки `Scenes/<id>`.
- Реальная cross-validation между template catalog и scene library отсутствует.
- Из-за этого stale template может снова попасть в UI и сломаться только поздно, в [TemplateCatalog.sceneTypeDefaults(...)](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/TemplatesCatalog/TemplateCatalog.swift#L99).
- Дополнительно в [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift#L3582) остался мертвый `loadCompiledTemplateFromBundle(templateName:)`, который уже не соответствует текущей catalog-based архитектуре.

**Желаемый результат**
- Пользователь **никогда не видит в UI шаблон**, который не может быть разрешен в текущую scene library.
- Template catalog публикует только **валидные и резолвимые** templates.
- Пустые категории автоматически исчезают.
- Старый bundle-template loader path полностью удален.
- В коде остается **один** поддерживаемый путь template loading: `TemplateCatalog + SceneLibrary`.

**Каноничное решение**
- Не вводить третий манифест.
- Не переносить проверку в UI-контроллеры.
- Сделать `TemplateCatalog.load()` authoritative orchestration point:
  1. загрузить raw catalog manifest;
  2. загрузить `SceneLibrarySnapshot`;
  3. провалидировать templates against library;
  4. опубликовать в UI уже **очищенный snapshot**.

**Необходимые изменения**
- [TemplateCatalog.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/TemplatesCatalog/TemplateCatalog.swift)
  - В `load()` и `reload()` добавить обязательную validation stage against `SceneLibrary.shared.load()`.
  - Не менять публичный call pattern экранов: `TemplateCatalog.shared.load()` должен остаться удобной entrypoint.
  - Кэшировать уже **validated snapshot**, а не raw manifest snapshot.

- [TemplateModels.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/TemplatesCatalog/TemplateModels.swift)
  - Добавить pure helper уровня snapshot, например:
    - `validated(against library: SceneLibrarySnapshot) -> TemplateCatalogSnapshot`
    - или `pruned(against library: SceneLibrarySnapshot) -> TemplateCatalogSnapshot`
  - Логика:
    - template удаляется, если любой `sceneTypeId` отсутствует в library;
    - категории без surviving templates удаляются автоматически через уже существующий `categoriesInOrder()` behavior;
    - порядок templates/categories сохраняется.

- [BundleTemplateCatalogLoader.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/TemplatesCatalog/BundleTemplateCatalogLoader.swift)
  - Оставить loader как raw manifest decoder + preview URL resolver.
  - Не дублировать там `SceneLibrary` lookup.
  - При желании добавить debug log, сколько templates было отброшено validation stage, но без release-only шума.

- [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift)
  - Полностью удалить:
    - `loadCompiledTemplateFromBundle(templateName:)`
    - связанные комментарии, которые отсылают к старому bundle-folder path
  - Сохранить уже сделанный error mapping через `TemplateCatalogError`.

- [TemplatesHomeViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/TemplatesUI/TemplatesHomeViewController.swift)
- [CategoryTemplatesViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/TemplatesUI/CategoryTemplatesViewController.swift)
- [TemplateDetailsViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/TemplatesUI/TemplateDetailsViewController.swift)
  - Архитектурно менять не нужно, если `TemplateCatalog.load()` начнет возвращать уже validated snapshot.
  - Эти экраны должны автоматически перестать видеть stale templates.

**Тесты**
- Добавить новые тесты для template validation layer:
  - valid template survives
  - template with missing `sceneTypeId` is dropped
  - template with empty `sceneTypeIds` is dropped
  - empty category disappears from `categoriesInOrder()`
- Добавить bundle consistency test:
  - каждый template из shipped catalog должен ссылаться только на scene types, присутствующие в shipped scene library
- Обновить/добавить test на отсутствие старого bundle loader path, если у вас есть static coverage на `PlayerViewController`.

**Критерии приемки**
- UI шаблонов больше не показывает template, который отсутствует в scene library.
- В коде больше нет `loadCompiledTemplateFromBundle(...)`.
- В bundle loading flow остается только `TemplateCatalog + SceneLibrary`.
- Новый drift между `manifest.json` и `library.json` больше не приводит к user-visible broken template.
- `xcodebuild test` полностью зеленый.

**PR J: Video Still Cancellation Correctness**
**Проблема**
- Полный suite теперь зеленый, но при `UserMediaServiceTrimPreviewTests.test_previewExactVideoTrimFrame_latestWins` возникает:
  - `SWIFT TASK CONTINUATION MISUSE: requestStillTexture(atVideoTime:) leaked its continuation`
- Это указывает на реальный cancellation defect.
- Корень в том, что [UserMediaService.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/UserMedia/UserMediaService.swift#L1008) делает latest-wins cancel старых still tasks, а [VideoFrameProvider.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/UserMedia/VideoFrameProvider.swift#L260) ждет `AVAssetImageGenerator.image(at:)` без cancellation handler.
- Аналогичный async seam есть в [VideoPosterCache.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/MediaIngest/VideoPosterCache.swift#L92).

**Желаемый результат**
- Отмена superseded still request больше не оставляет висящие continuations.
- Latest-wins behavior остается прежним.
- `awaitPendingStillFrames()` не рискует зависнуть из-за незавершенного старого still request.
- Полный `xcodebuild test` проходит **без** `SWIFT TASK CONTINUATION MISUSE` в логе.

**Каноничное решение**
- Все `await generator.image(at:)` path’ы в приложении должны быть обернуты в cancellation-aware seam.
- При cancel нужно явно вызывать:
  - `generator.cancelAllCGImageGeneration()`
- Это должно быть сделано не только для exact still, но и для interactive still, и для video poster path, чтобы не оставить второй такой же баг рядом.

**Необходимые изменения**
- [VideoFrameProvider.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/UserMedia/VideoFrameProvider.swift)
  - Вынести маленький private helper, например:
    - `generateCGImage(generator: AVAssetImageGenerator, at time: CMTime) async throws -> CGImage`
  - Внутри helper:
    - использовать `withTaskCancellationHandler`
    - в cancel handler вызывать `generator.cancelAllCGImageGeneration()`
    - внутри operation вызывать `try await generator.image(at: time)`
  - Перевести на этот helper:
    - `requestStillTexture(atVideoTime:)`
    - `requestInteractiveStillTexture(atVideoTime:)`
  - Сохранить текущие generation/token checks до и после await.
  - Не менять current latest-wins contract в `UserMediaService`.

- [VideoPosterCache.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/MediaIngest/VideoPosterCache.swift)
  - Обернуть `generator.image(at: .zero)` в тот же cancellation-aware pattern.
  - Можно локально продублировать helper, если не хочется делать shared utility ради 2 файлов.
  - Но лучше иметь один маленький общий internal helper в `AnimiApp/Sources/UserMedia` или `MediaIngest`, если это не раздувает scope.

- [UserMediaService.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/UserMedia/UserMediaService.swift)
  - Поведение latest-wins не менять.
  - Только убедиться, что canceled older still tasks корректно self-cleanup-ятся и не держат висящие task refs дольше нужного.

**Тесты**
- Оставить существующий `latestWins` coverage как regression lock.
- Добавить targeted test на cancellation robustness:
  - repeated still requests cancel previous ones
  - `awaitPendingStillFrames()` завершается
  - final delivered frame соответствует последнему request
- Acceptance на этот PR должен включать **ручную проверку test log**:
  - полный `xcodebuild test` без `SWIFT TASK CONTINUATION MISUSE`

**Критерии приемки**
- В логе полного suite больше нет continuation misuse warnings.
- Latest-wins trim-preview behavior не регрессирует.
- `UserMediaServiceTrimPreviewTests` и полный `AnimiAppTests` остаются зелеными.
- В коде не остается необернутых `await generator.image(at:)` без cancellation handling в production paths.

**Порядок внедрения**
1. Сначала `PR I`:
- template validation against scene library
- удаление dead bundle-template loader
2. Потом `PR J`:
- cancellation-safe still extraction
- cleanup of `AVAssetImageGenerator` async paths

**Итог**
Канонично это не один “cleanup PR”, а **два отдельных finishing PR**:
- один закрывает **resource graph / legacy loading surface**
- второй закрывает **реальный concurrency defect**, который пока не роняет тесты, но уже светится warning’ом в полном suite.