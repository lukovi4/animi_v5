# Video Pipeline Rewrite: Финальное PR-by-PR ТЗ

## Summary
- Проект и сцены остаются на `30 fps`.
- Видео переводится на единый **time-based contract**.
- Preview перестаёт жить на `synthetic frame`.
- Export остаётся deterministic `30 fps`, но default resampling меняется на `blend`.
- Orientation становится частью общего render contract через video metadata seam.
- Persisted schema, store shape, ingest/photo/background pipelines не меняются.

## Locked Decisions
- `RenderCommand`, `AnimIR`, `ScenePlayer`, `RenderContext` не получают video-specific поля.
- Metadata идёт через optional provider seam, а не через `RenderContext` dictionary.
- `QuadUniforms` не меняется; для video вводится отдельный shader path.
- `VideoSetupProviding` мигрирует атомарно на time-based API.
- `ExportVideoFrameProvider` получает `MTLCommandQueue` сверху от `VideoExporter` через `ExportVideoSlotsCoordinator`.
- Poster больше не живёт на oriented `UIImage` path.
- Drift correction в preview остаётся disabled.
- Default export policy = `.blend`.
- Optical flow / interpolation вне scope.

## Implementation Decisions
- **Q1**: orientation = `orientedSize` для geometry + `uvTransform` для sampling.
- **Q2**: `VideoPresentationInfo` вычисляет и кэширует сам provider.
- **Q3**: seam = отдельные протоколы `AssetPresentationInfoProvider` и `MutableAssetPresentationInfoProvider`.
- **Q4/Q5**: preview playback остаётся AVPlayer-native; `expectedVideoTime` используется только для drift/debug, не для per-tick seek.
- **Q6/Q9**: `MTLCommandQueue` пробрасывается `VideoExporter -> ExportVideoSlotsCoordinator -> ExportVideoFrameProvider`. Provider не создаёт свою queue.
- **Q7**: exact-sample tolerance = `1/600`.
- **Q8**: реализация несколькими PR.
- **Q10**: `VideoSetupProviding` мигрирует атомарно, без coexistence старого и нового API.
- **Q11**: scrub cache становится time-based, сравнение только через `abs(delta) < 1/600`.
- **Q12**: mutable metadata нужны для `InMemoryTextureProvider`, `ThreadSafeInMemoryTextureProvider`, `ExportTextureProvider`, `ScenePackageTextureProvider`, `LayeredTextureProvider`; не нужны для `ScenePackageBaseTextureProvider`.
- **Q13**: отдельный `quad_video_*` shader path и отдельный `VideoQuadUniforms`; общий `QuadUniforms` не расширять.
- **Q14**: убрать `appliesPreferredTrackTransform` из poster path; poster должен стать raw + GPU orientation.
- **Q16**: `VideoPresentationInfo` вычисляется в provider **на стадии ready/prepare**, то есть в текущем lifecycle-месте, эквивалентном `loadDuration(from:)`, а не в `UserMediaService` и не как post-step после poster injection.
  - Канонический выбор: **вариант B**.
  - Provider должен расширить current async prepare task так, чтобы он загружал:
    - `duration`
    - video track
    - `VideoPresentationInfo`
  - Только после этого provider переходит в `.ready`.
  - `requestPoster(...)` уже сейчас ждёт `state == .ready`, значит после его успешного завершения `UserMediaService` может безопасно читать `provider.presentationInfo` и инжектить poster texture + metadata одновременно.
  - Если provider не смог вычислить `VideoPresentationInfo`, он не должен переходить в `.ready`; это provider failure, не service fallback.

## PR 1. Shared VideoTimelineTimeMapper ✅
**Goal**
- Один source of truth для scene-frame -> target-video-time.

**Changes**
- Добавить shared helper `VideoTimelineTimeMapper`.
- Вход:
  - `sceneFrameIndex`
  - `BlockTiming`
  - `sceneFPS`
  - `VideoSelection`
- Выход:
  - `blockTimeSeconds`
  - `targetVideoTimeSeconds`
  - clamped target time
- Заменить внутреннюю math ownership в:
  - [UserMediaService.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/UserMedia/UserMediaService.swift)
  - [ExportVideoFrameProvider.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/ExportVideoFrameProvider.swift)
- Epsilon зафиксировать как `1/600`.

**Not in scope**
- Никаких protocol/shader/provider API changes.

**Tests**
- Unit tests на trim, offset, block start, end clamp, before-start, after-end.
- Preview/export parity test на одинаковый input.

**Done**
- Один shared mapper.
- Preview/export больше не держат независимую формулу.

## PR 2. VideoPresentationInfo + metadata seam + video shader path ✅
**Goal**
- Добавить orientation-aware render seam без поломки non-video пути.

**Changes**
- Добавить `VideoPresentationInfo`:
  - `rawTrackSize`
  - `preferredTransform`
  - `orientedSize`
  - `uvTransform`
- Добавить протоколы:
  - `AssetPresentationInfoProvider`
  - `MutableAssetPresentationInfoProvider`
- Реализовать metadata storage для:
  - `InMemoryTextureProvider`
  - `ThreadSafeInMemoryTextureProvider`
  - `ExportTextureProvider`
  - `ScenePackageTextureProvider`
  - `LayeredTextureProvider`
- Не добавлять mutable metadata в `ScenePackageBaseTextureProvider`.
- Ввести отдельные:
  - `VideoQuadUniforms`
  - `quad_video_vertex`
  - `quad_video_fragment`
- В `drawImage(...)`:
  - если metadata нет, current path unchanged
  - если metadata есть, использовать video path
  - size priority: `orientedSize -> assetSizes -> texture.size`

**Not in scope**
- Ещё не инжектить live/export metadata.
- Не менять sampling/export logic.

**Tests**
- Provider metadata lifecycle tests.
- Renderer tests на video path.
- Regression: non-video path unchanged.
- Existing quad size/stride assertions remain green.

**Done**
- Renderer умеет рисовать video-oriented texture через metadata seam.

## PR 3. Poster raw parity cleanup ✅
**Goal**
- Привести poster к тому же contract, что и live/export.

**Changes**
- В [VideoFrameProvider.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/UserMedia/VideoFrameProvider.swift):
  - убрать `appliesPreferredTrackTransform = true`
  - расширить current prepare task так, чтобы до `.ready` provider вычислял `VideoPresentationInfo`
  - добавить cached `presentationInfo` property
- В [UserMediaTextureFactory.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/UserMedia/UserMediaTextureFactory.swift):
  - добавить `makeTexture(from cgImage: CGImage) -> MTLTexture?`
  - poster path переводится на `CGImage -> MTLTexture`
  - poster path больше не использует `UIImage`
  - poster path не использует `normalizeImage(_:)`
- В [UserMediaService.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/UserMedia/UserMediaService.swift):
  - после `requestPoster(...)` читать `provider.presentationInfo`
  - инжектить **одновременно**:
    - poster texture
    - presentation metadata
  - затем включать binding layer как и раньше

**Not in scope**
- Ещё не time-based preview migration.
- Ещё не export changes.

**Tests**
- Poster orientation == live orientation.
- Poster orientation == export orientation.
- `makeTexture(from cgImage:)` tests.
- Provider never enters `.ready` without valid presentation info.

**Done**
- Poster больше не является отдельным CPU-oriented special case.

## PR 4. Preview migration to time-based API ✅
**Goal**
- Убрать synthetic-frame ownership из preview runtime.

**Changes**
- Атомарно мигрировать `VideoSetupProviding`:
  - `startPlayback(atVideoTime:)`
  - `frameTextureForPlayback(expectedVideoTime:)`
  - `frameTextureForScrub(atVideoTime:)`
  - `frameTextureForFrozen(atVideoTime:)`
- Удалить старые frame-based playback methods.
- В [UserMediaService.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/UserMedia/UserMediaService.swift):
  - убрать `computeSyntheticSceneFrame(...)`
  - использовать shared mapper
  - service становится owner’ом time mapping
  - `updateDivider` оставить `1`
- В [VideoFrameProvider.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/UserMedia/VideoFrameProvider.swift):
  - убрать scene-frame-based public playback API
  - `startPlayback(atVideoTime:)` делает seek + `rate = 1.0`
  - `frameTextureForPlayback(expectedVideoTime:)` остаётся host-time driven
  - scrub cache становится time-based
  - drift correction remains disabled
- Обновить 3 test fake’а и все связанные тесты.

**Not in scope**
- Export migration.
- Blend.

**Tests**
- Existing readiness/budget/restore tests after atomic migration.
- New tests на time-based scrub cache и mapper usage.
- Regression: no production path sets `updateDivider > 1`.

**Done**
- Preview API полностью time-based.
- `VideoSetupProviding` больше не содержит frame-based playback contract.

## PR 5. Export migration to time-based API + queue plumbing ✅
**Goal**
- Убрать synthetic-frame ownership из export path и подготовить provider к blend.

**Changes**
- В `VideoExporter` пробросить `renderer.commandQueue` в `ExportVideoSlotsCoordinator`.
- В `ExportVideoSlotsCoordinator` пробросить queue в `ExportVideoFrameProvider`.
- Обновить init signatures.
- В `ExportVideoSlotsCoordinator`:
  - считать `targetVideoTime` через shared mapper
  - вызывать provider time-based API
  - инжектить texture + metadata одновременно
- В `ExportVideoFrameProvider`:
  - убрать ownership scene/block timing math из sampling API
  - `Config` больше не держит `blockTiming` и `sceneFPS`
  - provider становится owner’ом decode + sample buffers + future resampling resources

**Not in scope**
- Включение blend как default quality.
- Optical flow.

**Tests**
- Export provider time-based API tests.
- Preview/export trim parity.
- Export orientation parity.

**Done**
- Export и preview используют одинаковый targetVideoTime contract.
- Queue ownership детерминирован и идёт сверху вниз.

## PR 6. Temporal blend export policy
**Goal**
- Заменить default `hold-last` cadence на perceptually smoother export resampling.

**Changes**
- Ввести `VideoResamplingPolicy`:
  - `.nearest`
  - `.blend`
- Default = `.blend`
- В `ExportVideoFrameProvider` держать:
  - `previous sample`
  - `current sample`
  - `pending next sample`
- Exact rules:
  - epsilon `1/600`
- Blend path:
  - reusable scratch texture
  - blend pipeline state
  - GPU blend pass на shared queue
- Hold-last только для:
  - end of window
  - no next sample
  - reader exhaustion
- `.nearest` оставить internal/debug only.

**Not in scope**
- Motion interpolation.
- User-facing quality selector.

**Tests**
- `30 -> 30` exact path.
- `24/25 -> 30` default blend path.
- `60 -> 30` monotonic downsample path.
- GPU resource cleanup tests.

**Done**
- Export default behavior больше не pure repeated-frame cadence.

## PR 7. Hardening, parity, perf verification
**Goal**
- Закрепить parity и закрыть regression surface.

**Changes**
- Проверить и зафиксировать:
  - poster/live/scrub/frozen/export parity
  - portrait/landscape parity
  - trim/offset parity
  - metadata lifecycle parity
- Убедиться, что `updateDivider` нигде не уходит выше `1`.
- Сохранить optional diagnostics только там, где они реально нужны.

**Manual matrix**
- `24/25/30/60 fps`
- portrait + landscape
- trimmed + untrimmed
- preview playback
- scrub
- frozen/edit
- single-scene export
- timeline export

**Done**
- Вся video pipeline parity закреплена тестами и ручной матрицей.
- Non-video rendering unchanged.
- Existing renderer assertions/tests remain green.

## Assumptions
- `30 fps` project timeline остаётся фиксированным.
- `ScenePackageBaseTextureProvider` не участвует в mutable video metadata lifecycle.
- Provider `.ready` теперь означает: `duration + presentationInfo` загружены.
- `requestPoster(...)` не должен быть owner’ом metadata calculation; он только использует уже готовый provider state.

## Acceptance Criteria
- Synthetic-frame contract исчезает как основа video playback/export.
- Preview time-based и native-cadence.
- Export deterministic `30 fps` с default blend resampling.
- Portrait video больше не повёрнуты на 90°.
- Poster/live/export используют один orientation contract.
- `QuadUniforms` и non-video path не сломаны.
- Persisted schema/store shape не меняются.

## Platform References
- Orientation: [Apple QA1744](https://developer.apple.com/library/archive/qa/qa1744/_index.html)
- Playback composition seam: [AVPlayerItem.videoComposition](https://developer.apple.com/documentation/avfoundation/avplayeritem/videocomposition)
- Fixed-rate timing: [AVVideoComposition.frameDuration](https://developer.apple.com/documentation/avfoundation/avvideocomposition/frameduration)
- High-frame-rate / CFR workflows: [AVFoundation Programming Guide](https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/AVFoundationPG/Articles/04_MediaCapture.html)

------

# Video Pipeline Rewrite

**Summary**
- Цель: оставить проект и сцены на `30 fps`, но полностью перевести video subsystem на **единый time-based contract**.
- Результат рефактора должен дать:
  - одинаково правильную orientation в poster/live/export,
  - native-cadence preview без synthetic-frame quantization,
  - export `30 fps` с temporal blend вместо текущего `hold-last`,
  - единый preview/export time mapping без расхождения по trim/offset/block timing.
- Это **не** schema/store refactor. Persisted `VideoSelection`, `SceneMediaSlot`, `ExportMediaSnapshot`, timeline/store shape и photo/background pipelines не меняются.

## 1. Зафиксированные ответы и решения

### Q1. Orientation: UV transform vs quad geometry
- Делать **оба**.
- `drawImage(...)` обязан использовать `VideoPresentationInfo.orientedSize` для quad geometry.
- `uvTransform` применяется только для sampling.
- Приоритет размера становится таким:
  - `VideoPresentationInfo.orientedSize`
  - затем `assetSizes[assetId]`
  - затем `texture.width/height`
- `assetSizes` не переписывается и остаётся raw compiled metadata.

### Q2. Кто владеет `VideoPresentationInfo`
- `VideoPresentationInfo` вычисляет и кэширует **сам video provider** один раз при `prepare/ready`.
- Это статическая metadata track’а, она не должна считаться каждый кадр и не должна жить в `UserMediaService`.
- Инжекция metadata в texture layer делается owner’ом injection path:
  - preview: `UserMediaService`
  - export: `ExportVideoSlotsCoordinator`
- Provider хранит info и отдаёт её наружу, service/coordinator синхронно делает:
  - `setTexture(texture, for: assetId)`
  - `setPresentationInfo(info, for: assetId)`

### Q3. Какой seam для metadata
- Канонический вариант: **отдельный optional protocol**, а не `RenderContext` dictionary и не расширение базового `TextureProvider` обязательным методом.
- Вводятся:
  - `AssetPresentationInfoProvider`
  - `MutableAssetPresentationInfoProvider`
- `MetalRenderer` делает optional cast `ctx.textureProvider as? AssetPresentationInfoProvider`.
- `RenderCommand`, `RenderContext`, `AnimIR`, `ScenePlayer` по форме не меняются.

### Q4. `startPlayback(atVideoTime:)` и drift correction
- `UserMediaService` заранее считает `targetVideoTime` через shared mapper и передаёт его в provider.
- `startPlayback(atVideoTime:)` делает initial seek + `rate = 1.0`.
- Drift correction в preview остаётся **disabled**.
- Этот рефактор не включает periodic corrective seeks и не меняет текущую policy preview stability.

### Q5. `frameTextureForPlayback(expectedVideoTime:)`
- `expectedVideoTime` — это **подсказка для drift/debug**, а не per-tick seek target.
- Playback extraction продолжает идти через `videoOutput.itemTime(forHostTime:)`.
- Provider не делает corrective seek на каждом tick.
- В этом рефакторе аргумент нужен для internal comparison/assertions и future-safe contract, но не для постоянного пересинхрона.

### Q6. Blend GPU resources
- Blend остаётся self-contained внутри `ExportVideoFrameProvider`.
- Provider получает `MTLCommandQueue` и сам владеет:
  - scratch texture,
  - blend pipeline state,
  - command buffer для blend pass.
- Blend не выносится в coordinator, renderer или Core Image / MPS.

### Q7. Tolerance для exact sampling
- Не использовать float equality.
- Exact sample rules:
  - exact `prev`, если `abs(target - prevPTS) <= 1/600`
  - exact `next`, если `abs(target - nextPTS) <= 1/600`
  - иначе blend
- Канонический epsilon: `1/600`, потому что он уже является текущим time contract в preview/export clamp logic.

### Q8. Порядок фаз
- Реализация идёт несколькими PR:
  1. Shared mapper
  2. Presentation metadata seam
  3. Preview migration
  4. Export migration
  5. Temporal blend
  6. Hardening/tests/manual matrix

### Q9. Откуда брать `MTLCommandQueue` для export blend
- Канонический выбор: **shared queue сверху вниз**.
- `VideoExporter` уже владеет `MTLCommandQueue`; он должен пробросить её в `ExportVideoSlotsCoordinator`, а coordinator — в `ExportVideoFrameProvider`.
- `ExportVideoFrameProvider` **не** создаёт свою queue через `device.makeCommandQueue()`.
- Значит:
  - init `ExportVideoSlotsCoordinator` расширяется `commandQueue: MTLCommandQueue`
  - init `ExportVideoFrameProvider` тоже расширяется `commandQueue: MTLCommandQueue`
- Это обязательное решение. Вариант с per-provider queue запрещён.

### Q10. Миграция `VideoSetupProviding`
- Миграция делается **атомарно в Phase 3**.
- Старые frame-based методы не живут рядом с новыми.
- Причина:
  - protocol internal, не public API,
  - параллельное существование двух контрактов создаст дублирование и риск расхождения logic.
- В том же PR обновляются все test fakes:
  - `UserMediaServiceReadinessTests`
  - `MediaRestoreHelperVideoSelectionTests`
  - `UserMediaServiceBudgetTests`
- Existing `frameTexture(atVideoTime:)` в `VideoFrameProvider` можно использовать как migration helper, но финальный protocol должен остаться **только time-based**.

### Q11. Scrub throttle cache
- Scrub cache становится time-based.
- `lastScrubbedFrameIndex` заменяется на `lastScrubbedVideoTime`.
- Сравнение только через epsilon:
  - `abs(newTime - lastTime) < 1/600`
- Exact `Double ==` запрещён.
- `lastScrubSeekTime` и existing wall-clock scrub throttle сохраняются.

### Q12. Для каких provider’ов нужен mutable metadata protocol
- Нужен:
  - `InMemoryTextureProvider`
  - `ThreadSafeInMemoryTextureProvider`
  - `ExportTextureProvider`
  - `ScenePackageTextureProvider`
  - `LayeredTextureProvider` как delegating wrapper
- Не нужен:
  - `ScenePackageBaseTextureProvider`
- Подтверждение:
  - `ScenePackageBaseTextureProvider` содержит только compiled template assets,
  - user media туда не инжектится,
  - video runtime metadata там не живёт.
- Он может вообще не conform’ить к metadata protocol; optional cast просто вернёт `nil`.

### Q13. Shader strategy для video uvTransform
- Канонический выбор: **отдельный video shader path**, не расширение общего `QuadUniforms`.
- Причина:
  - сейчас `QuadUniforms` и `quad_vertex/quad_fragment` используются широко, включая transition/composite paths,
  - есть существующие stride assertions на `96 bytes`,
  - добавление `float4x4 uvTransform` в общий quad path создаст избыточный runtime cost и затронет много non-video callsites.
- Значит:
  - current `quad_vertex/quad_fragment` остаются для non-video
  - вводится отдельный `quad_video_vertex/quad_video_fragment`
  - для video-only draw path используется отдельный `VideoQuadUniforms`
- Background shader seam не переиспользуется напрямую, но подход по смыслу тот же: orientation через GPU uv transform.

### Q14. Poster path после Phase 2
- Канонический выбор: **убрать `appliesPreferredTrackTransform` из poster path**.
- Poster должен стать таким же raw-source texture + GPU orientation metadata, как live/export.
- Специальные варианты `identity VideoPresentationInfo` или “не инжектить metadata для poster” запрещены.
- Значит:
  - `requestPoster(...)` перестаёт применять CPU-side orientation
  - poster texture остаётся raw
  - `VideoPresentationInfo` инжектится так же, как и для live/export
- Обязательный regression test:
  - poster orientation == live frame orientation == export orientation

## 2. Поэтапная реализация

### Phase 1. Shared time mapping
- Создать shared helper, например `VideoTimelineTimeMapper`.
- Он становится single source of truth для:
  - `sceneFrameIndex`
  - `BlockTiming`
  - `sceneFPS`
  - `VideoSelection`
  - `targetVideoTime`
- Удаляется ownership дублирующей формулы из:
  - `UserMediaService.computeSyntheticSceneFrame(...)`
  - `ExportVideoFrameProvider.computeTargetVideoTime(...)`
- После этой фазы preview/export пользуются одной функцией расчёта времени.

### Phase 2. Presentation metadata seam
- Создать `VideoPresentationInfo`.
- Создать:
  - `AssetPresentationInfoProvider`
  - `MutableAssetPresentationInfoProvider`
- Добавить storage metadata в mutable providers.
- `LayeredTextureProvider` обязан:
  - читать overlay metadata first,
  - fallback to base if ever needed,
  - но base video metadata в текущем продукте не ожидается.
- В renderer добавить отдельный video draw path:
  - `VideoQuadUniforms`
  - `quad_video_vertex`
  - `quad_video_fragment`
- `drawImage(...)` делает:
  - если metadata нет → текущий quad path
  - если metadata есть → video quad path с `orientedSize + uvTransform`

### Phase 3. Preview migration
- `VideoSetupProviding` мигрирует атомарно:
  - `startPlayback(atVideoTime:)`
  - `frameTextureForPlayback(expectedVideoTime:)`
  - `frameTextureForScrub(atVideoTime:)`
  - `frameTextureForFrozen(atVideoTime:)`
- Удаляются frame-based protocol methods.
- `UserMediaService` становится owner’ом time mapping и перестаёт оперировать synthetic frame.
- `updateDivider` остаётся `1`; production overrides не вводятся.
- `VideoFrameProvider`:
  - больше не владеет scene-frame mapping,
  - `frameTexture(atVideoTime:)` используется как existing migration building block,
  - scrub cache становится time-based,
  - poster path становится raw + GPU orientation.

### Phase 4. Export migration
- `ExportVideoSlotsCoordinator` получает `commandQueue` из `VideoExporter`.
- `ExportVideoFrameProvider` получает `commandQueue` в init.
- `ExportVideoFrameProvider.Config` больше не владеет scene/block time mapping.
- Coordinator сам считает `targetVideoTime` через shared mapper и вызывает provider time-based API.
- Provider остаётся owner’ом sequential decode, pending sample, last sample, previous sample и resampling logic.

### Phase 5. Temporal blend
- Ввести `VideoResamplingPolicy`:
  - `.nearest`
  - `.blend`
- Default = `.blend`.
- Provider держит:
  - `previous sample`
  - `current/last sample`
  - `pending next sample`
- Blend path:
  - exact sample if within epsilon
  - blend between `prev` and `next`
  - hold-last only at window end / no-next / reader exhaustion
- `.nearest` сохраняется только как internal comparison/debug mode.

### Phase 6. Hardening
- Provider/service/coordinator обязаны set/remove texture и metadata синхронно.
- Poster/live/scrub/frozen/export обязаны давать одинаковый oriented результат.
- Manual matrix и perf regression pass обязательны.

## 3. Public / internal interface changes

- `VideoSetupProviding` становится time-based и ломается атомарно в одном PR.
- `ExportVideoSlotsCoordinator.init(...)` расширяется `commandQueue: MTLCommandQueue`.
- `ExportVideoFrameProvider.init(...)` расширяется `commandQueue: MTLCommandQueue`.
- `TextureProvider` не ломается.
- Добавляются новые optional companion protocols для metadata.
- `QuadUniforms` не меняется.
- Добавляются новые video-only uniforms/shaders.

## 4. Тесты

- Unit: shared mapper parity preview/export.
- Unit: scrub cache использует epsilon time comparison, а не exact equality.
- Unit: mutable providers set/remove metadata вместе с texture.
- Unit: `ScenePackageBaseTextureProvider` не участвует в metadata lifecycle и не нужен для video path.
- Unit: `30 -> 30` exact sample без blend.
- Unit: `24/25 -> 30` default blend path.
- Unit: `60 -> 30` monotonic blend/downsample path.
- Integration: portrait/landscape orientation parity across poster/live/export.
- Integration: trim/offset parity preview/export.
- Regression: existing `FakeVideoSetupProvider` tests переписаны на time-based contract и остаются зелёными.

## 5. Acceptance criteria

- Synthetic-frame contract больше не является owner’ом video playback/export.
- Preview time-based и native-cadence.
- Export deterministic `30 fps`, но default policy = blend.
- Portrait video не повернуты на 90° нигде.
- Poster/live/export используют один orientation contract.
- Non-video renderer path не затронут по behavior.
- Production code нигде не поднимает `updateDivider` выше `1` в этом рефакторе.

## 6. Locked non-goals

- Никакого optical flow / ML interpolation.
- Никакого variable project fps.
- Никакого UI transform hack.
- Никакого CPU-side per-frame rotation/compositing.
- Никакого временного coexistence старого frame-based и нового time-based protocol.

**Платформенные опоры**
- Orientation: [Apple QA1744](https://developer.apple.com/library/archive/qa/qa1744/_index.html)
- Playback composition seam: [AVPlayerItem.videoComposition](https://developer.apple.com/documentation/avfoundation/avplayeritem/videocomposition)
- Fixed-rate composition timing: [AVVideoComposition.frameDuration](https://developer.apple.com/documentation/avfoundation/avvideocomposition/frameduration)
- High-frame-rate / constant-frame-rate workflows: [AVFoundation Programming Guide](https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/AVFoundationPG/Articles/04_MediaCapture.html)
