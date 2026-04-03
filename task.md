**ТЗ**

Исправить баг неправильного размера/позиции пользовательских фото и видео в **track matte**-блоках канонически, строго по текущему коду продукта, без костылей по шаблонам и без отката предыдущих рефакторингов.

**1. Подтвержденная проблема**
- Корень бага находится в рассинхроне между matte bbox dry-run и реальным `drawImage`.
- Matte bbox считается в [MatteBboxCompute.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/MatteBboxCompute.swift#L26). В ветке `.drawImage` внутри `computeRangeBBox` используется только `assetSizes[assetId]` как размер картинки в [MatteBboxCompute.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/MatteBboxCompute.swift#L92).
- Реальный рендер той же картинки идет в [MetalRenderer+Execute.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift#L1879) и использует другой контракт геометрии: `videoOrientedSize -> displaySize -> assetSize -> textureSize`.
- Канонический resolver для этой геометрии уже существует в [AssetRenderGeometryResolver.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/AssetRenderGeometryResolver.swift#L10).
- Bbox-sized matte offscreen path запускается в [MetalRenderer+Execute.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift#L976) и затем рендерит в bbox-local textures в [MetalRenderer+Execute.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift#L1027).
- Если bbox посчитан по `assetSize`, а реальный user media quad рисуется по `displaySize` или `videoOrientedSize`, matte texture выделяется слишком маленькой или со смещенным origin. Визуальный симптом: медиа выглядит уменьшенным и/или сдвинутым.
- Это касается именно **track matte** path (`beginMatte/endMatte`) из [RenderCommand.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/RenderGraph/RenderCommand.swift#L98), а не обычного `hasMask` path.
- Подтверждено на реальных шаблонах:
  - matte-based: [block_02/no-anim.json](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/SceneSources/example_4blocks/block_02/no-anim.json), [block_03/no-anim.json](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/SceneSources/example_4blocks/block_03/no-anim.json), [no-anim.json](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/SceneSources/polaroid_shared_demo/no-anim.json)
  - control via normal mask: [block_04/no-anim.json](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/SceneSources/example_4blocks/block_04/no-anim.json)

**2. Целевой контракт**
- В renderer должен существовать **один** source of truth для quad geometry `drawImage`.
- Matte bbox dry-run и фактический `drawImage` обязаны использовать **одинаковые** `width/height` для одного и того же `assetId`.
- Приоритет источников геометрии должен быть единым везде:
  `videoOrientedSize -> displaySize -> assetSize -> textureSize`
- Если matte dry-run не может надежно определить геометрию изображения, он **не должен** считать bbox по неверным данным. Он должен вернуть `nil`, чтобы renderer ушел в уже существующий full-frame fallback в [MetalRenderer+Execute.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift#L1127).
- Никакие изменения в `placement`, `BindingBaselineRuntime`, `SceneRuntimeStateApplier`, compiler или scene JSON для этого фикса не нужны.

**3. Архитектурное решение**
1. Не дублировать размерную логику второй раз.
2. Вынести lookup raw geometry для `assetId` в один внутренний helper renderer-модуля.
3. Этот helper должен собирать входы для [AssetRenderGeometryResolver.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/AssetRenderGeometryResolver.swift#L10):
   - `videoOrientedSize` через `AssetPresentationInfoProvider` из [VideoPresentationInfo.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/VideoPresentationInfo.swift#L127)
   - `displaySize` через `AssetDisplaySizeProvider` из [AssetDisplaySizeProvider.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/AssetDisplaySizeProvider.swift#L10)
   - `assetSize` из `ctx.assetSizes`
   - `textureSize` через `TextureProvider.texture(for:)` из [TextureProvider.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/TextureProvider.swift#L8)
4. Этот helper должен быть **internal**, не public API.
5. `drawImage` в [MetalRenderer+Execute.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift#L1879) должен перестать вручную дублировать priority-chain и перейти на этот shared helper.
6. `computeMatteBBox` в [MatteBboxCompute.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/MatteBboxCompute.swift#L26) тоже должен использовать тот же shared helper.
7. Канонически лучше передавать в `computeMatteBBox` не `TextureProvider` напрямую, а resolver closure вида:
   `resolveImageGeometry: (String) -> AssetRenderGeometryResolver.Result?`
   Это сохраняет bbox helper максимально чистым и тестируемым.
8. `renderMatteScope` в [MetalRenderer+Execute.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift#L976) должен собирать этот closure из `ctx.textureProvider + ctx.assetSizes` и передавать его в `computeMatteBBox`.

**4. Изменения по файлам**
- [MatteBboxCompute.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/MatteBboxCompute.swift#L26)
  - изменить сигнатуры `computeMatteBBox` и `computeRangeBBox`
  - добавить параметр `resolveImageGeometry`
  - в ветке `.drawImage` больше не использовать `assetSizes[assetId]` напрямую
  - вместо этого брать `Result.width/height` из shared geometry resolver
  - если resolver вернул `nil`, возвращать `nil` из bbox computation, чтобы matte path ушел в full-frame fallback
- [MetalRenderer+Execute.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift#L976)
  - при вызове `computeMatteBBox` передавать geometry-resolver closure
- [MetalRenderer+Execute.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift#L1879)
  - убрать inline priority-chain
  - вызывать тот же shared helper, что и matte bbox
- Новый internal helper-файл в `TVECore/Sources/TVECore/MetalRenderer/`
  - например `AssetQuadGeometryLookup.swift`
  - обязан быть внутренним для модуля `TVECore`
  - не должен вводить новую public surface area
- [TextureProvider.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/TextureProvider.swift)
  - менять протоколы не нужно
  - текущие провайдеры уже умеют нужные метаданные:
    [TextureProvider.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/TextureProvider.swift#L95),
    [TextureProvider.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/TextureProvider.swift#L112),
    [TextureProvider.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/TextureProvider.swift#L180),
    [TextureProvider.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/TextureProvider.swift#L200),
    [ScenePackageTextureProvider.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/ScenePackageTextureProvider.swift#L227),
    [ScenePackageTextureProvider.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/ScenePackageTextureProvider.swift#L369),
    [LayeredTextureProvider.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/LayeredTextureProvider.swift#L91),
    [LayeredTextureProvider.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/LayeredTextureProvider.swift#L112)

**5. Обязательные правила поведения после фикса**
- Для template assets без user metadata поведение не меняется: используется `assetSize`.
- Для user photos с `displaySize` matte bbox обязан использовать `displaySize`, а не template `assetSize`.
- Для videos с `presentationInfo.orientedSize` matte bbox обязан использовать oriented size, а не template `assetSize`.
- Если у asset нет ни metadata, ни texture, matte bbox не имеет права строить “приблизительный” bbox по мусорным данным.
- Full-frame fallback остается допустимым safety net и baseline visual behavior.

**6. Что делать нельзя**
- Не лечить `example_4blocks/block_02` или `polaroid_shared_demo` special-case’ами.
- Не менять `BindingBaselineRuntime`, `MediaPlacementResolver`, `SceneRuntimeStateApplier`, `SceneCompiler`.
- Не откатывать bbox optimization из `be7e3d5`.
- Не откатывать `displaySize` / `videoOrientedSize` renderer contract из `513d23f` и `c1edf94`.
- Не возвращаться к `assetSize` как универсальной геометрии для user media.

**7. Тесты**
- Обязательно расширить [MetalRendererMatteTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Tests/TVECoreTests/MetalRendererMatteTests.swift#L10).
- Добавить regression test для фото:
  - matte source полностью покрывает кадр
  - consumer имеет `assetSize` меньше, чем `displaySize`
  - `displaySize` задается через provider, совместимый с `AssetDisplaySizeProvider`
  - пиксели внутри `displaySize`-области, но вне `assetSize`-области, должны быть видимы после matte compositing
- Добавить regression test для видео:
  - `assetSize` и `videoOrientedSize` различаются
  - bbox и финальный matte output должны следовать `videoOrientedSize`
- Добавить unit/regression test на сам shared helper или на `computeMatteBBox`, чтобы он возвращал bbox по `displaySize`/`videoOrientedSize`, а не по `assetSize`
- Существующие тесты на matte semantics должны остаться зелеными:
  [MetalRendererMatteTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Tests/TVECoreTests/MetalRendererMatteTests.swift#L176),
  [MetalRendererMatteTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Tests/TVECoreTests/MetalRendererMatteTests.swift#L351)
- Дополнительно сохранить существующие тесты на `AssetRenderGeometryResolver` и export metadata:
  [AssetRenderGeometryResolverTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Tests/TVECoreTests/AssetRenderGeometryResolverTests.swift#L8),
  [ExportDisplaySizeRegressionTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Tests/ExportDisplaySizeRegressionTests.swift#L1)

**8. Acceptance Criteria**
- `example_4blocks/block_02` и `block_03` больше не выглядят уменьшенными или сдвинутыми при вставке user photo/video.
- `polaroid_shared_demo` больше не выглядит уменьшенным или сдвинутым в matte-блоке.
- Контрольные mask-based блоки не меняют визуальное поведение.
- `PlacementDiag` для таких блоков может остаться прежним; меняется именно финальный matte render result.
- Preview и export совпадают по matte-блокам.
- В коде остается ровно один renderer contract для размера user media quad.

**9. Финальная проверка**
- `swift test` в `TVECore`
- `xcodebuild test` для app test target
- Ручной QA на девайсе/симуляторе:
  - `example_4blocks`: `block_02`, `block_03`, контроль `block_04`
  - `polaroid_shared_demo`
  - фото и видео отдельно

Это и есть каноническое ТЗ по реальному коду: не трогать placement, а починить рассинхрон matte bbox и actual draw geometry в renderer.