Все фактические замечания программиста подтверждаются текущим кодом. Канонические ответы такие.

1. `viewWillDisappear` safety net не удаляем полностью, но его текущую семантику надо убрать.
Сейчас он вызывает `saveDraftIfNeeded()` только при `isMovingFromParent || isBeingDismissed`, то есть фактически это второй autosave при закрытии editor, а не механизм crash/background recovery: [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift#L1795).
Новая каноника:
`Save to SavedProject` из этого места делать нельзя.
После выбора `Не сохранять` этот path не должен ничего сохранять.
Если этот hook остаётся, то только как fallback-запись в `Active Draft Slot`, и только когда пользователь не выбрал `Не сохранять`.
При этом реальный resume-механизм не должен опираться только на `viewWillDisappear`, потому что текущий код не покрывает background/crash.

2. Да, save-on-success нужно добавить в оба export flow одинаково.
Сейчас есть два параллельных пути: single-scene export и timeline export, каждый со своим `onCompleted`: [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift#L2072), [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift#L2203).
Каноника одна для обоих:
`success -> create/update SavedProject`
`failure/cancel -> ничего не сохранять`.

3. Да, `Active Draft Slot` обязан хранить metadata помимо самого `ProjectDraft`.
Одного `ProjectDraft` недостаточно.
Минимум нужно хранить:
`entry context`
`source templateId`
`linked savedProjectId?`
Причина в реальном коде: сейчас editor знает только `templateId` entry point и перегружает `draft.id/currentProjectId` как единственный project identity: [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift#L74), [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift#L280).
В новой модели нужно различать:
`newFromTemplate`
`openSavedProject`
и понимать, должен ли `Save/Export` создать новый проект или обновить уже существующий.
После первого успешного `Save/Export` в сессии этот linkage тоже должен сохраниться, чтобы следующий `Export` обновил тот же `SavedProject`, а не создал новый.

4. На cold start active draft всегда имеет приоритет над `My Projects` и home.
Если active draft slot существует, приложение сразу открывает editor.
Это ожидаемое поведение до тех пор, пока пользователь явно не примет решение: `Сохранить` или `Не сохранять`.
Байпаса сразу в `My Projects` не нужно.
По текущей архитектуре навигации правильнее всего оставить home root-экраном внутри `UINavigationController` и автоматически пушить editor поверх него: [SceneDelegate.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/App/SceneDelegate.swift#L17).
Тогда после явного завершения draft пользователь естественно попадает обратно на home и уже оттуда может открыть `My Projects`.

5. Для `My Projects` в v1 превью нужно брать из исходного общего шаблона.
Генерации project-specific thumbnail сейчас в продукте нет.
В `ProjectDraft` нет поля preview, есть только ссылка на базовый `templateId`: [ProjectDraft.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Project/ProjectDraft.swift#L28).
Текущая карточка каталога уже умеет показывать bundle video preview из `TemplateDescriptor.previewURL`: [TemplatePreviewCell.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/TemplatesUI/TemplatePreviewCell.swift#L47).
Поэтому каноника для v1:
в `My Projects` использовать preview исходного шаблона, резолвя его через `sourceTemplateId/templateId` и `TemplateCatalog`.
Никаких новых thumbnail pipelines в v1 не нужно.
Группировка секций при этом идёт по дате сохранения проекта, а не по категориям.

6. Старый per-template crash-draft API нужно убирать как отдельный публичный механизм.
Сейчас это мёртвый контракт без call sites и он конфликтует с новой архитектурой единственного active draft slot: [ProjectStore.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Project/ProjectStore.swift#L383).
Каноника:
в продукте должен остаться только один механизм unsaved editor persistence.
Если при реализации удобно переиспользовать куски JSON IO внутренне, это допустимо.
Но старого отдельного API/поведения `saveCrashDraft/loadCrashDraft/deleteCrashFile/hasCrashFile` как самостоятельного контракта после этой задачи оставаться не должно.

После этих 6 ответов продуктовых вопросов по этой задаче у меня больше нет. Если нужно, следующим сообщением соберу для программиста уже `implementation plan` по конкретным файлам и шагам изменения кода.