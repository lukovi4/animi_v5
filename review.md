Да, решения такие.

**3. SceneEditInteractionController tests**
Делать через **маленькие mock-subclass recognizer-ов внутри test file**. Это правильный путь.

Не делать:
- KVC на `state`
- любые private UIKit хаки

Делать так:
- `MockPanGestureRecognizer`
- `MockPinchGestureRecognizer`
- `MockRotationGestureRecognizer`

Что им нужно:
- overridable `state`
- для pan: `translation(in:)`
- для pinch: `scale`
- для rotation: `rotation`

Практически:
- держите `testState`, `testTranslation`, `testScale`, `testRotation`
- `recognizer.view` можно не использовать, если `translation(in:)` override возвращает тестовое значение независимо от view
- классы оставить **только внутри** [SceneEditInteractionControllerTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/SceneEditInteractionControllerTests.swift)

Это не оверинжиниринг, а нормальный unit-test seam для UIKit controller.

**4. TimelineCompositionEngine cold-path tests**
Здесь **не нужен protocol seam для `SceneTypeResourcesCache`**. Для PR D это уже было бы лишним.

Финальная стратегия:
- использовать **реальные temp scene packages на диске**, как в [ProjectDraftHydratorTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/ProjectDraftHydratorTests.swift)
- использовать **реальный** [SceneTypeResourcesCache.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/TimelineComposition/SceneTypeResourcesCache.swift)
- инжектить URL через `cache.sceneURLProvider`

То есть:

1. **Success / cold-path**
- cache пустой
- `cache.sceneURLProvider = { sceneTypeId in validTempPackageURL }`
- `engine.setTimeline(...)`
- `await engine.updateSceneState(legacyState, for: instanceId)`
- проверяете, что state hydrated и callback fired

2. **Failure-path**
- cache пустой
- `cache.sceneURLProvider` указывает на:
  - либо missing URL
  - либо invalid package directory
- `await engine.updateSceneState(...)`
- проверяете:
  - state unchanged
  - `onSceneStateHydrated` не fired

Это полностью соответствует текущему production path в [TimelineCompositionEngine.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/TimelineComposition/TimelineCompositionEngine.swift#L180).

**Ответы по твоим 3 вопросам**

1. **Cold-path тест**
Да, использовать **реальные temp `.tve` packages на диске**.  
Это предпочтительный вариант. Он тестирует настоящий `preloadMetadata()` path, а не искусственный mock path.

2. **Failure-path**
Да, ты понимаешь правильно.  
Достаточно создать `SceneTypeResourcesCache`, не прогревать его, и задать `sceneURLProvider` так, чтобы `preloadMetadata()` бросал ошибку.

Я бы рекомендовал:
- для success-path: валидный temp package
- для failure-path: **invalid package directory** с битым `compiled.tve`, потому что это ближе к реальной деградации, чем просто `nil`

Но `missing URL` тоже допустим.

3. **Metal dependency**
Да, `XCTSkip`, если нет `MTLDevice`/`MTLCommandQueue`, **допустим**.  
Это уже established pattern в [TimelineCompositionEngineReadinessTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/TimelineCompositionEngineReadinessTests.swift). Для PR D не надо ломать этот стиль ради “идеальной” portability.

**Итог**
- пункты 1 и 2: без изменений
- пункт 3: mock recognizer subclasses, не KVC
- пункт 4: real cache + real temp packages + `sceneURLProvider`, без нового protocol seam

То есть **можно идти в реализацию PR D без дополнительного архитектурного расширения**.