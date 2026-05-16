**Task 3: GPU Resource Lifecycle Refactor / Bounded TexturePool**

**Ветка**

`codex/gpu-resource-lifecycle-refactor`

**Текущий статус**

Baseline для начала рефакторинга зафиксирован:

- Документ: [gpu-resource-baseline-pr0.md](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/Docs/memory/gpu-resource-baseline-pr0.md)
- Устройство: iPhone 13 Pro
- iOS: 26
- Xcode: 26
- Xcode Memory gauge: `830.9 MB`, `30 FPS`
- Late/final playback stop: `TexturePool.available = 1111` textures / `308.2 MB`
- `TexturePool.inUse = 0`
- Main owners: `mask.boolean.bbox` (`972` textures / `227.3 MB`) and `matte.bbox` (`137` textures / `71.9 MB`)
- Export peak: `export.frame.1200` with `footprint 2427 MB`, `metal 2370 MB`

Решение по PR 0b: baseline достаточен для старта refactor. Fast scrub checkpoint отсутствует в текущей диагностике, но это не блокирует bounded exact-size `TexturePool`, потому что play/pause + scene switch уже доказывают monotonic pool growth.

PR 1 выполнен и принят как готовый к merge:

- Branch: `pr1/bounded-texture-pool`
- Commit: `60b4c47`
- Scope изолирован до двух файлов:
  - [TexturePool.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/TexturePool.swift)
  - [MetalRendererMaskTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Tests/TVECoreTests/MetalRendererMaskTests.swift)
- Tests: `19/19` passed (`8` existing + `11` new)
- Реализовано: bounded exact-size `TexturePool`, expanded key with `storageModeRawValue` / `usageRawValue`, production `NSLock`, `inUse` map, LRU/budget/per-key/idle eviction, `trim(policy:)`, quiescent `clear()`
- Review fixes закрыты: safe `Array(available.keys)` iteration, empty key cleanup, strengthened hard-budget/in-use/idle eviction tests
- P3 note: owner diagnostics remain cumulative allocation churn, not retained-memory attribution

PR 2 выполнен и принят по code review:

- Commit: `66056ad`
- Scope изолирован до 4 файлов:
  - [MetalRenderer.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/MetalRenderer.swift)
  - [EditorRuntime.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/EditorRuntime/EditorRuntime.swift)
  - [EditorViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/EditorViewController.swift)
  - [EditorBootstrapController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/EditorBootstrapController.swift)
- Tests/build: AnimiApp `1440/0`, TVECore `950/0`, build succeeded
- Реализовано: renderer lifecycle trim on playback stop, memory warning and editor close
- Device play/pause validation: retained `TexturePool.available` dropped from PR0 baseline `308.2 MB` to low tens of MB, with late sample around `11.6 MB`, `inUse = 0`
- Close validation: renderer pool is trimmed, but `editor.close.after` still retains `SceneInstanceRuntime: 2`, `UserMediaService: 3`, `VideoFrameProvider: 3`

**Следующий шаг**

Начать `PR 3: Timeline Preview Runtime / Video Provider Teardown` из [task-3-prs.md](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/task-3-prs.md).

PR 3 должен освободить preview timeline/runtime/video resources на close/export boundaries. PR 3 не должен включать export renderer separation, bucketing, `MTLHeap` или изменения visual algorithms.

**Цель**

Сделать новую архитектуру управления временными GPU/Metal resources в Animi так, чтобы:
- память preview не росла монотонно при `play/pause/scrub/scene switch`;
- качество preview/export не изменилось;
- видео, анимации, стикеры, музыка, animated text и export продолжили работать без лагов;
- legacy unbounded behavior был удален только после device/Instruments подтверждения.

Это не визуальный рефакторинг и не переписывание editor/media pipeline. Scope ограничен resource lifecycle renderer-а и его интеграцией с editor lifecycle.

**Диагноз по текущему коду**

Проблема не подтверждается как Swift heap leak. По диагностике и Instruments рост находится в Metal/IOSurface/IOAccelerator-backed memory. В коде основной доказанный источник - временные textures, которые после кадра возвращаются в `TexturePool.available`, но не имеют бюджета, LRU, age eviction или lifecycle trim.

Ключевые точки кода:
- [TexturePool.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/TexturePool.swift:27) - пул создан для переиспользования Metal textures и keyed by `(width, height, pixelFormat)`.
- [TexturePool.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/TexturePool.swift:121) - `release(_:)` всегда возвращает texture в `available[key]`.
- [TexturePool.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/TexturePool.swift:145) - `clear()` существует, но это ручной полный сброс, а не управляемая memory policy.
- [MetalRenderer+MaskRender.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+MaskRender.swift:27) - mask group path создает bbox-sized temporary textures.
- [MetalRenderer+MaskRender.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+MaskRender.swift:80) - `mask.boolean.bbox` берет 3 R8 textures и 1 BGRA texture на bbox.
- [MetalRenderer+Execute.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift:1034) - matte bbox path оптимизирует VRAM/bandwidth per-frame, но использует bbox-sized offscreen textures.
- [MetalRenderer+Execute.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift:1048) - `matte.bbox` берет 2 BGRA textures на bbox.
- [TimelineRenderExecutor.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/TimelineComposition/TimelineRenderExecutor.swift:212) - timeline transition path учитывает, что `TexturePool` не thread-safe.
- [MetalRenderer.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/MetalRenderer.swift:250) - `clearCaches()` есть, но production lifecycle не вызывает его как часть bounded trim policy.
- [EditorRuntime.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/EditorRuntime/EditorRuntime.swift:160) - memory warning сейчас purge-ит только overlay cache, не renderer scratch textures.
- [MetalRendererMaskTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Tests/TVECoreTests/MetalRendererMaskTests.swift:672) - текущие `TexturePoolTests` проверяют acquire/reuse/clear, но не проверяют budget, many unique bbox sizes, LRU, memory plateau.

**Главный архитектурный вывод**

`TexturePool` нужен. Удалять пул нельзя: это приведет к per-frame `device.makeTexture()` и лагам. Ошибка текущей архитектуры в том, что пул является unbounded exact-size cache для dynamic bbox scratch textures.

Новая модель:

`temporary texture -> release -> bounded reuse decision -> keep hot working set or evict`

а не:

`temporary texture -> release -> keep forever`

**Non-goals**

- Не менять visual algorithms для mask/matte/transition/stickers/text.
- Не менять persisted project schema.
- Не менять media contract, video trim, audio, sticker overlay или animated text behavior.
- Не снижать preview resolution как основной memory fix.
- Не делать `clearCaches()` на каждый кадр или каждый pause как основной механизм.
- Не внедрять `MTLHeap` как первый обязательный шаг. Это отдельная следующая оптимизация после bounded pool.
- Не удалять legacy до device/Instruments подтверждения.

**Canonical target architecture**

1. `TexturePool` становится bounded transient allocator.
2. Pool знает estimated bytes по каждой texture.
3. Pool имеет global budget, per-key cap, max available count и LRU/age metadata.
4. Pool не evict-ит `inUse` textures.
5. `release(_:)` больше не гарантирует сохранение texture в pool.
6. Renderer получает explicit lifecycle API: soft trim, aggressive trim, full dispose.
7. Preview и export не делят один и тот же lifetime temporary resources.
8. Dynamic bbox textures сначала ограничиваются бюджетом, затем при необходимости переводятся на bucketed lease API.

**Фаза 0. Baseline перед изменениями**

Перед первым кодовым изменением сохранить baseline:
- commit/branch SHA;
- device model + iOS version;
- шаблон, на котором воспроизводится рост;
- launch flags diagnostics;
- 3 прогона сценария `open -> play/pause 10 раз -> fast scrub 30 сек -> close`;
- Xcode Memory peak/plateau;
- `[MEM-DIAG] playback.stop.after.2s`;
- `TexturePool.available`, `pool.owner`, `sceneTypeCache`, `videoProviders`;
- Instruments VM Tracker: `IOSurface`, `IOAccelerator`, Dirty, footprint.

Baseline нужен, чтобы доказать, что refactor решил именно текущую проблему, а не просто изменил цифры.

**Фаза 1. Bounded exact-size TexturePool без изменения render API**

Это первая обязательная фаза. Она должна сохранять старые public/internal call sites:
- `acquireColorTexture(size:)`
- `acquireR8Texture(size:)`
- `acquireStencilTexture(size:)`
- `release(_:)`

Нельзя в этой фазе возвращать texture большего размера, чем requested size. Текущий render code местами использует реальные `texture.width/height` через `RenderTarget`, поэтому silent bucketing через старый API может сломать geometry, matte, masks или compositing.

Добавить в `TexturePool`:

1. `TexturePoolConfiguration`
- `softBudgetBytes`
- `hardBudgetBytes`
- `maxAvailableTextures`
- `maxAvailablePerKey`
- `maxAgeSeconds` или frame/access generation
- `bytesPerPixel` policy
- optional device class defaults

2. `TexturePoolEntry`
- `texture: MTLTexture`
- `key`
- `estimatedBytes`
- `lastAccessGeneration`
- `lastReleaseTime`
- `debugOwner` только за `#if DEBUG`

3. Более полный `TexturePoolKey`

Текущий key содержит только width/height/pixelFormat. В новой архитектуре key должен учитывать как минимум:
- width
- height
- pixelFormat
- storageMode
- usage/resource class

Причина: сейчас `.r8Unorm` может использоваться как `.shared + shaderRead` и как `.private + renderTarget/shaderRead/shaderWrite`. Такие textures нельзя безопасно считать взаимозаменяемыми только по pixelFormat.

4. Thread safety production-level

Текущий DEBUG-lock защищает только диагностику. Новая архитектура должна сделать `TexturePool` безопасным для реальных lifecycle trims и async release:
- один lock или serial executor для `available`, `inUse`, metadata;
- `device.makeTexture()` выполнять вне lock;
- финальную регистрацию новой texture выполнять под lock;
- `trim` и `release` синхронизировать с pool state;
- не делать nested locking.

5. Eviction policy

При `release(_:)`:
- обновить metadata;
- если per-key cap превышен, удалить лишние oldest entries этого key;
- если `availableBytes > softBudgetBytes`, evict LRU до soft budget;
- если `availableBytes > hardBudgetBytes`, evict aggressive до hard budget immediately;
- если texture слишком большая и не помещается в budget, не кешировать ее после release.

6. `trim(policy:)`

Добавить явные policies:
- `.softInteractiveStop` - оставить hot working set, evict старое/редкое до soft budget;
- `.memoryWarning` - aggressive trim available textures почти до нуля или до минимального warm budget;
- `.editorClose` - clear all available textures, не ломая in-flight release;
- `.exportStart` - preview soft/aggressive trim перед export;
- `.exportFinished` - full clear export-only pool;
- `.testFullClear` - deterministic test helper.

Важно: `trim` не должен удалять `inUse` bookkeeping. Если texture еще используется GPU или будет released после command buffer completion, pool должен сохранить корректную регистрацию до release. Полный сброс `inUse` допустим только в controlled dispose, когда renderer гарантированно quiesced.

**Фаза 2. Renderer lifecycle boundaries**

Статус: выполнено в PR 2 (`66056ad`).

Добавлен API в [MetalRenderer.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/MetalRenderer.swift):

- `trimTransientResources(policy:)`

`clearCaches()` либо оставить как backward-compatible wrapper, либо пометить как legacy API и перевести внутренне на новую policy. Нельзя использовать старый `clearCaches()` вслепую как pause fix, потому что он чистит не только transient textures, но и mask/shape/path caches.

Подключенный lifecycle:

1. Playback pause/stop
- soft trim renderer transient textures;
- не делать full clear, чтобы resume не лагал.

2. Memory warning / app background
- aggressive trim renderer transient resources;
- overlay cache already purged, renderer pool now participates through `.memoryWarning`.

3. Editor close / project close
- full clear available transient resources;
- invalidate/clear renderer caches только после остановки render/display link.
- active playback is stopped first.

Deferred:

- scrub debounce: no single clear scrub-ended lifecycle hook exists yet;
- export renderer/pool separation: moved to a later PR;
- preview video/runtime teardown: moved to Phase 3.

PR 2 device result:

- play/pause confirms `TexturePool.available` is bounded and no longer grows toward `308 MB`;
- close confirms renderer pool trim, but not preview runtime/video provider teardown.

**Фаза 3. Timeline preview runtime / video provider teardown**

Статус: следующий PR.

Цель: после editor close/export enter не должны оставаться live preview runtimes and video providers.

Required behavior:

- stop playback/sync controllers first;
- release all `TimelineCompositionEngine.instanceRuntimes`;
- for every `SceneInstanceRuntime`, release per-runtime `UserMediaService`;
- release/stop all `VideoFrameProvider` instances;
- flush or release preview video texture/CVMetalTextureCache resources where owned by providers;
- clear warm/resident preview runtime state that is not needed after close;
- keep persistent project/session state intact.

Target checkpoint after close:

```text
editor.close.after.2s:
SceneInstanceRuntime: 0
VideoFrameProvider: 0
pool.avail near 0
```

Observed reason for this phase:

```text
editor.close.before: SceneInstanceRuntime: 2 | UserMediaService: 3 | VideoFrameProvider: 3
editor.close.after:  SceneInstanceRuntime: 2 | UserMediaService: 3 | VideoFrameProvider: 3
```

**Фаза 4. Preview/export separation**

Проверить текущие export paths:
- [SingleSceneVideoExportRunner.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/SingleSceneVideoExportRunner.swift)
- [TimelineVideoExportRunner.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/TimelineVideoExportRunner.swift)
- [VideoExporter.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/VideoExporter.swift)

Требования:
- export renderer/pool должен жить только на время export session;
- export pool должен иметь отдельный budget;
- export cancellation/error/success должны проходить через единый terminal cleanup;
- preview pool не должен наследовать export scratch textures;
- export completion checkpoint должен показывать, что export pool cleared.

**Фаза 5. Bucketed bbox textures через explicit lease API**

Эту фазу делать только после Phase 1-4 и device validation. Цель - уменьшить количество уникальных bbox keys.

Запрещено:
- silently округлять size внутри старого `acquireColorTexture(size:)`, если caller ожидает exact texture dimensions.

Правильный путь:

1. Ввести explicit lease/wrapper:
- `ScratchTextureLease`
- `texture`
- `requestedSize`
- `allocatedSize`
- `validRect`
- `pixelFormat`
- `release()`

2. Добавить отдельные API:
- `acquireScratchColorTexture(requestedSize:owner:) -> ScratchTextureLease`
- `acquireScratchR8Texture(requestedSize:owner:) -> ScratchTextureLease`

3. Bucket policy:
- округлять backing texture до 64/128 px bucket;
- render pass должен clear/render только `validRect`;
- composite должен использовать requested bbox/validRect, а не весь backing texture;
- scissor/viewport должны гарантировать, что лишняя часть bucket texture не влияет на output.

4. Перевести сначала только доказанные owners:
- `mask.boolean.bbox`
- `matte.bbox`

5. После visual parity перевести остальные high-cardinality scratch owners при необходимости.

**Фаза 6. Legacy cleanup**

Legacy удалять только после acceptance.

Удалить или переписать:
- unbounded append-only semantics в `TexturePool.release(_:)`;
- старый `clear()` как публичную lifecycle замену, если он сбрасывает `inUse`;
- call sites, которые используют full clear вместо policy trim;
- debug-only workarounds, которые были нужны только для поиска причины, если они больше не нужны.

Оставить:
- минимальные DEBUG snapshots для future regressions;
- resource owner attribution, если overhead нулевой в release и полезен для диагностики.

**Тесты**

Unit tests для `TexturePool`:
- reuse still works under budget;
- per-key cap evicts extra textures;
- global soft budget evicts LRU;
- hard budget never exceeded after release/trim;
- in-use textures are never evicted;
- `trim(.memoryWarning)` removes available textures but preserves in-use bookkeeping;
- usage/storageMode are part of key;
- oversized one-off texture is not retained if it violates policy;
- concurrent acquire/release/trim test if implementation uses locks.

Integration/render tests:
- mask boolean path визуально не меняется;
- matte bbox path визуально не меняется;
- full-frame fallback сохраняется;
- transition offscreen path release after command buffer completion still works;
- export preview parity smoke test по сцене с video + mask + matte + stickers + animated text.

Regression tests по памяти:
- synthetic test: 500 unique bbox sizes should not leave pool above configured budget;
- repeated play/pause should plateau after warmup;
- fast scrub should not grow `available` monotonically.

Важно: unit tests не доказывают memory behavior на устройстве. Device/Instruments validation обязательна.

**Device/Instruments validation**

Проверять на реальном iPhone, не только Simulator.

Сценарии:
1. `open -> play 30 sec -> pause`, 10 циклов.
2. Fast scrub по шаблону 30-60 sec.
3. 20 scenes, включая video inside scenes, masks, matte, stickers, animated text.
4. Scene switch вперед/назад по timeline.
5. Export timeline.
6. Back to preview after export.
7. Close project, reopen, repeat 3 раза.
8. App background/foreground.
9. Memory warning simulation where possible.

Метрики:
- Xcode Memory / footprint.
- `MTLDevice.currentAllocatedSize`.
- Instruments VM Tracker: `IOSurface`, `IOAccelerator`, Dirty.
- Metal Resource Events: allocation churn and live resources.
- FPS and frame time spikes.
- `[MEM-DIAG] pool total/available/inUse`.
- owner breakdown: `mask.boolean.bbox`, `matte.bbox`, `timeline.transition.offscreen`, `isolatedGroup.fullTarget`.

Acceptance thresholds:
- `TexturePool.availableEstimatedBytes` plateaus within configured budget after warmup.
- `inUse` returns to 0 after pause/stop plus command buffer completion.
- Xcode Memory does not grow monotonically across 10 play/pause cycles.
- After close/reopen cycles, footprint delta should stay within 30-50 MB after warmup, not hundreds of MB.
- No visible preview degradation.
- No repeatable FPS drop below 30 FPS during normal playback.
- No scrub hitch clusters caused by aggressive clearing.
- Export success/cancel/failure leaves no export pool residue.

**Performance constraints**

- Do not call `device.makeTexture()` while holding a long lock.
- Do not trim on every frame.
- Do not aggressive clear during active scrub/playback.
- Prefer evict on release and debounced trims.
- Keep hot set small but warm enough to avoid allocation spikes.
- Keep debug logging behind flags.

**Risk controls**

- Implement behind feature flag first, for example `UseBoundedTexturePool`.
- Default can remain old behavior until validation build is ready.
- Add metrics before deleting legacy.
- Compare old/new on same device and same template.
- If visual parity fails, rollback Phase 4 bucketed lease only; Phase 1 bounded exact-size pool should remain safe.

**Definition of Done**

Task 3 is complete only when:
- bounded exact-size pool is implemented and tested;
- lifecycle trim policies are wired into editor close, playback stop/pause, export enter/exit, memory warning/background;
- preview/export resource lifetimes are separated;
- device Instruments confirms no monotonic Metal/IOSurface growth for target scenarios;
- preview quality remains unchanged;
- export output remains visually equivalent;
- FPS and scrub remain acceptable;
- legacy unbounded behavior is removed or unreachable;
- tests document the memory policy so regression is hard to reintroduce.

**Expected final result**

The app should behave as:

`20 scenes + video + masks + matte + stickers + animated text + fast scrub`

with memory shaped like:

`current working set + bounded warm scratch pool + resident scene/video budget`

not:

`every temporary bbox texture ever seen in this editor session`.
