**Task 3 PR Plan: GPU Resource Lifecycle Refactor**

**Базовая задача**

Основное ТЗ: [task-3.md](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/task-3.md)

**Ветка серии**

`codex/gpu-resource-lifecycle-refactor`

**Текущий статус**

- `PR 0a: Baseline Template / Measurement Protocol` выполнен.
- `PR 0b: Baseline / Measurement Lock` выполнен достаточно для перехода к PR 1.
- Baseline-документ: [gpu-resource-baseline-pr0.md](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/Docs/memory/gpu-resource-baseline-pr0.md)
- Device baseline: iPhone 13 Pro, iOS 26, Xcode 26.
- Xcode Memory gauge зафиксирован на `830.9 MB`, `30 FPS`.
- MEM-DIAG baseline доказывает рост `TexturePool.available` до `1111` textures / `308.2 MB`, при `inUse = 0`.
- Основные owners: `mask.boolean.bbox` и `matte.bbox`.
- Export baseline дополнительно показывает peak `export.frame.1200`: `footprint 2427 MB`, `metal 2370 MB`.
- Fast scrub не имеет dedicated MEM-DIAG checkpoint в текущей диагностике. Это зафиксировано как limitation и не блокирует PR 1.
- `PR 1: Bounded Exact-Size TexturePool` выполнен и принят как готовый к merge.
- PR 1 branch/commit: `pr1/bounded-texture-pool` / `60b4c47`.
- PR 1 diff должен оставаться изолированным до двух файлов: `TexturePool.swift` + `MetalRendererMaskTests.swift`.
- PR 1 tests: `19/19` passed (`8` existing + `11` new).
- PR 1 accepted scope: bounded exact-size pool, no render API changes, no bucketing, no lifecycle wiring, no visual algorithm changes.
- PR 1 note: owner diagnostics are cumulative allocation churn, not retained-memory attribution.
- `PR 2: Renderer Lifecycle Policies` выполнен и принят по code review.
- PR 2 commit: `66056ad`.
- PR 2 diff изолирован до 4 файлов: `MetalRenderer.swift`, `EditorRuntime.swift`, `EditorViewController.swift`, `EditorBootstrapController.swift`.
- PR 2 tests/build: AnimiApp `1440/0`, TVECore `950/0`, build succeeded.
- PR 2 device validation на похожей нагрузке подтверждает, что `TexturePool.available` больше не является источником роста до сотен MB: late playback pool держится около `11.6 MB`, `inUse = 0`.
- PR 2 close validation выявила остаточный retention вне renderer pool: `editor.close.before` и `editor.close.after` оба показывают `SceneInstanceRuntime: 2`, `UserMediaService: 3`, `VideoFrameProvider: 3`.
- Следующая доказанная область работ: timeline preview runtime / video provider teardown on close/export boundaries.

**Следующий шаг**

Переходить к `PR 3: Timeline Preview Runtime / Video Provider Teardown`.

PR 3 должен закрыть retention, который остался после PR 2:

- `TimelineCompositionEngine.instanceRuntimes`;
- `SceneInstanceRuntime`;
- per-runtime `UserMediaService`;
- `VideoFrameProvider`;
- preview video texture/CVMetalTextureCache resources.

PR 3 не должен менять visual algorithms, export rendering, audio behavior, sticker/text behavior или persisted project schema.

**Цель документа**

Разбить `Task 3` на безопасную stacked PR-серию. Каждый PR должен быть проверяемым отдельно, не менять визуальное поведение без необходимости и не удалять legacy до того, как новая resource lifecycle модель доказана на устройстве.

**Главный принцип серии**

Нельзя делать big-bang rewrite renderer-а. Нужно идти от наиболее безопасного изменения к более глубокому:

1. сначала измерения и baseline;
2. затем bounded exact-size pool без изменения render API;
3. затем lifecycle trim policies;
4. затем timeline preview runtime/video teardown;
5. затем preview/export separation;
6. затем device budget tuning;
7. только потом bucketed scratch lease;
8. legacy cleanup последним PR.

**Общие правила для всех PR**

- Не менять visual algorithms mask/matte/stickers/text/video.
- Не снижать preview quality.
- Не менять persisted project schema.
- Не ломать export parity.
- Не удалять диагностический слой до финального cleanup.
- Не использовать `clearCaches()` как грубый универсальный fix.
- Не делать aggressive trim во время активного playback/scrub.
- Не вводить `MTLHeap` в этой серии, если bounded pool не исчерпал потенциал.
- После каждого PR фиксировать результат на одном и том же шаблоне и устройстве.

---

**PR 0: Baseline / Measurement Lock**

**Цель**

Зафиксировать текущую проблему и критерии успеха до изменения resource lifecycle.

**Почему отдельный PR**

Без baseline невозможно доказать, что memory refactor реально решает проблему, а не просто меняет цифры в логах.

**Scope**

- Зафиксировать текущие diagnostics из ветки `codex/memory-diagnostics-layer2`.
- Сохранить сценарий воспроизведения:
  - `open -> play/pause 10 раз -> fast scrub 30-60 sec -> close`;
  - `20 scenes + video + masks + matte + stickers + animated text`;
  - `export -> preview restore -> close -> reopen`.
- Сохранить device model, iOS version, template/project id.
- Сохранить Xcode Memory peak/plateau.
- Сохранить `[MEM-DIAG]` checkpoints.
- Сохранить Instruments VM Tracker snapshot:
  - `IOSurface`;
  - `IOAccelerator`;
  - Dirty;
  - resident/footprint.
- Сохранить Metal Resource Events summary.

**Non-scope**

- Не менять `TexturePool`.
- Не менять renderer.
- Не менять lifecycle.
- Не исправлять memory рост.

**Expected evidence**

- `TexturePool.available` растет.
- `TexturePool.inUse` возвращается к 0 после stop/pause.
- Основные owners: `mask.boolean.bbox`, `matte.bbox`.
- Heap allocations не объясняют Xcode Memory.
- VM/Metal/IOSurface объясняют memory pressure.

**DoD**

- В PR description приложены baseline numbers.
- Есть ссылка на logs/Instruments screenshots.
- Есть таблица `before` с основными метриками.

---

**PR 1: Bounded Exact-Size TexturePool**

**Цель**

Заменить append-only unbounded behavior на bounded exact-size `TexturePool`, не меняя render API и визуальный output.

**Почему это первый реальный code PR**

Это адресует доказанный источник роста памяти, но не меняет geometry. Старые call sites продолжают получать exact requested texture size.

**Files**

- [TexturePool.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/TexturePool.swift)
- [MetalRendererMaskTests.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Tests/TVECoreTests/MetalRendererMaskTests.swift) или новый `TexturePoolPolicyTests.swift`

**Required changes**

1. Добавить `TexturePoolConfiguration`:
   - `softBudgetBytes`;
   - `hardBudgetBytes`;
   - `maxAvailableTextures`;
   - `maxAvailablePerKey`;
   - `maxAgeSeconds` или generation-based age;
   - default preview config;
   - default export config.

2. Расширить key:
   - width;
   - height;
   - pixelFormat;
   - usage;
   - storageMode.

3. Добавить metadata:
   - estimated bytes;
   - last access generation;
   - release time/generation;
   - debug owner under `#if DEBUG`.

4. Сделать production thread safety:
   - protect `available`, `inUse`, metadata;
   - do not call `device.makeTexture()` under long lock;
   - no nested locks.

5. Изменить `release(_:)`:
   - возвращать texture в pool только если policy позволяет;
   - enforce per-key cap;
   - enforce soft/hard budget;
   - evict LRU/old entries;
   - never evict `inUse`.

6. Добавить `trim(policy:)` на уровне pool:
   - soft interactive stop;
   - memory warning;
   - full clear/dispose;
   - export finished.

**Non-scope**

- Не делать size bucketing.
- Не возвращать texture большего размера через старый API.
- Не менять mask/matte/transition render code.
- Не трогать video providers.
- Не подключать editor lifecycle, кроме tests/debug helper if needed.

**Tests**

- reuse works under budget;
- per-key cap evicts extra textures;
- global soft budget evicts LRU;
- hard budget is enforced after release/trim;
- `inUse` textures are not evicted;
- usage/storageMode are part of key;
- oversized one-off texture is not retained;
- clear/trim does not corrupt subsequent acquire/release;
- optional concurrent acquire/release/trim stress test.

**DoD**

- Existing render tests pass.
- New policy tests pass.
- Debug snapshot reports bounded available bytes.
- No visual code path changed.

---

**PR 2: Renderer Lifecycle Policies**

**Цель**

Подключить управляемые trim boundaries к editor lifecycle без aggressive clearing на горячем пути.

**Files**

- [MetalRenderer.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/MetalRenderer.swift)
- [EditorRuntime.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/EditorRuntime/EditorRuntime.swift)
- [EditorViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/EditorViewController.swift)
- [EditorBootstrapController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/EditorBootstrapController.swift)

**Required changes**

1. Add renderer-level API:
   - `trimTransientResources(policy:)`.

2. Wire policies:
   - playback pause/stop -> `.softInteractiveStop`;
   - memory warning -> `.memoryWarning`;
   - editor close/project close -> `.editorClose`.

3. Keep existing persistent caches sane:
   - do not blindly clear mask/shape/path caches during every pause;
   - keep a distinction between transient texture pool and persistent renderer caches.

4. Close while playing:
   - call existing `stopPlayback()` first;
   - then call `.editorClose`.

**Implemented result**

- Commit: `66056ad`.
- Scope: exactly 4 files, `21` insertions, `1` deletion.
- `MetalRenderer.trimTransientResources(policy:)` delegates to `TexturePool.trim(policy:)`.
- `EditorRuntime.rendererResourceTrimmer` is wired via `EditorBootstrapController`.
- `stopPlayback()` trims with `.softInteractiveStop` after playback/timeline/video stop.
- Memory warning trims with `.memoryWarning` and keeps overlay purge.
- Editor close stops active playback first, then trims with `.editorClose`.

**Non-scope**

- No bucketed textures.
- No export-only pool refactor.
- No visual algorithm changes.
- No scrub debounce in PR 2 because there is no single clear scrub-ended lifecycle hook.
- No timeline runtime/video provider teardown in PR 2. This is PR 3.

**Tests**

- lifecycle policy methods call pool trim with expected policy;
- close clears available transient textures;
- memory warning trims renderer pool and overlay cache;
- scrub debounce fires once after burst, not every frame.

**Manual/device validation**

- play/pause 10 cycles:
  - memory should plateau lower than baseline;
  - resume should not hitch repeatedly.
- close while playing:
  - playback should stop cleanly;
  - renderer pool should be trimmed.

**Device validation result**

- Play/pause on a different but similar-load template confirms the renderer pool is bounded:
  - late `playback.stop.after.2s`: `footprint 520 MB`, `metal 482 MB`, `pool.avail 11 / 11.6 MB`, `inUse 0`;
  - earlier maximum observed retained pool in that run: `32.1 MB`;
  - PR0 baseline was `1111` textures / `308.2 MB`.
- Close while playing confirms renderer trim but exposes remaining preview-resource retention:
  - `playback.stop.before`: `footprint 421 MB`, `metal 376 MB`, `SceneInstanceRuntime: 2`, `VideoFrameProvider: 3`;
  - `playback.stop.after`: `footprint 324 MB`, `metal 281 MB`, `pool.avail 0.8 MB`;
  - `editor.close.before`: `SceneInstanceRuntime: 2`, `UserMediaService: 3`, `VideoFrameProvider: 3`;
  - `editor.close.after`: `SceneInstanceRuntime: 2`, `UserMediaService: 3`, `VideoFrameProvider: 3`.

**Interpretation**

PR 2 fixed renderer transient lifecycle, but editor close still retains timeline preview runtime/video resources. The remaining memory owner is outside `TexturePool`.

**DoD**

- `TexturePool.available` does not grow monotonically across play/pause.
- Close path trims renderer available transient resources.
- No new FPS regression in normal playback.
- Residual close retention is documented and moved to PR 3.

---

**PR 3: Timeline Preview Runtime / Video Provider Teardown**

**Цель**

Сделать editor close/export-enter lifecycle полноценной границей для timeline preview resources: после close не должны оставаться live `SceneInstanceRuntime`, per-runtime `UserMediaService` и `VideoFrameProvider`.

**Why PR 3 changed**

Исходный план ставил PR 3 как preview/export separation. После PR 2 device validation стало видно, что более ранний blocker находится в preview teardown:

- renderer pool уже мал (`0.8-11.6 MB`);
- `editor.close.after` всё ещё держит `SceneInstanceRuntime: 2`, `UserMediaService: 3`, `VideoFrameProvider: 3`;
- export enter already demonstrates that releasing preview runtimes drops Metal memory substantially.

Поэтому PR 3 должен сначала закрыть preview runtime/video provider retention. Export-only pool separation сдвигается в PR 4.

**Files**

- [EditorRuntime.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/EditorRuntime/EditorRuntime.swift)
- [TimelineCompositionEngine.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/TimelineComposition/TimelineCompositionEngine.swift)
- [SceneInstanceRuntime.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/TimelineComposition/SceneInstanceRuntime.swift)
- [UserMediaService.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/UserMedia/UserMediaService.swift)
- [VideoFrameProvider.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/UserMedia/VideoFrameProvider.swift)
- `TimelineResidencyController` / `TimelinePlaybackSyncController` only if existing lifecycle ownership requires it.

**Required changes**

1. Add a canonical preview teardown API:
   - on `EditorRuntime`, e.g. `releasePreviewTimelineResourcesForClose()`;
   - on `TimelineCompositionEngine`, e.g. `releasePreviewResources(reason:)`;
   - on `SceneInstanceRuntime`, e.g. `releasePreviewResources(reason:)`.

2. Teardown must:
   - stop playback/sync controllers first;
   - stop all per-runtime video playback;
   - call `UserMediaService.releasePreviewResources()` or stricter close-specific release;
   - release all `VideoFrameProvider` instances;
   - clear `TimelineCompositionEngine.instanceRuntimes`;
   - clear warm/resident scene runtime state that is not needed after close;
   - leave persistent project/session state intact.

3. Editor close path:
   - after existing `stopPlayback()` and renderer `.editorClose`;
   - call preview timeline/video teardown;
   - then clear background textures.

4. Export enter path:
   - keep current preview release behavior if it already exists;
   - verify the same lower-level teardown primitive is reused or behavior-equivalent;
   - do not break preview restore after export.

5. Diagnostics:
   - add/keep `editor.close.after.2s` checkpoint;
   - include counters for `SceneInstanceRuntime`, `UserMediaService`, `VideoFrameProvider`;
   - log release reason: `close`, `exportEnter`, `memoryWarning` if applicable.

**Required post-close target**

After close and a short delayed checkpoint:

```text
SceneInstanceRuntime: 0
VideoFrameProvider: 0
pool.avail near 0
```

`UserMediaService` should also drop to the expected editor baseline. If a root editor-level service intentionally remains until controller deinit, document it explicitly.

**Non-scope**

- No export renderer/pool separation yet.
- No visual rendering changes.
- No audio behavior changes.
- No sticker/text behavior changes.
- No persisted project schema changes.
- No bucketed lease.

**Tests**

- close path releases timeline runtimes;
- close path releases per-runtime video providers;
- close while playing stops playback before teardown;
- export enter still releases preview runtimes and providers;
- preview restore after export still recreates required preview runtimes/providers;
- repeated close/reopen does not accumulate counters.

**Manual/device validation**

- `open -> play -> close while playing -> wait 2s`.
- `open -> play/pause 5x -> close -> reopen -> repeat`.
- `play -> export -> preview restore -> close`.

**DoD**

- `editor.close.after.2s` shows `SceneInstanceRuntime: 0` and `VideoFrameProvider: 0`.
- Close/reopen loop does not accumulate preview runtimes/providers.
- Existing export preview restore still works.
- Preview quality and playback FPS do not regress.

---

**PR 4: Preview / Export Resource Separation**

**Цель**

Сделать так, чтобы export temporary resources не загрязняли preview memory и всегда очищались на terminal path.

**Files**

- [VideoExporter.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/VideoExporter.swift)
- [SingleSceneVideoExportRunner.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/SingleSceneVideoExportRunner.swift)
- [TimelineVideoExportRunner.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/TimelineVideoExportRunner.swift)
- [ExportSession.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Export/ExportSession.swift)
- [EditorRuntimeExportController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/EditorRuntime/EditorRuntimeExportController.swift)

**Required changes**

- Export renderer/pool uses export config.
- Preview renderer/pool uses preview config.
- Export success/cancel/failure all hit one cleanup path.
- Export pool is fully cleared on terminal cleanup.
- Preview pool is trimmed before export enter.
- Preview restore checkpoint verifies export resources are not retained.

**Non-scope**

- No changes to audio export behavior.
- No changes to export visual rendering.
- No bucketed lease.

**Tests**

- export success clears export transient pool;
- export cancel clears export transient pool;
- export failure clears export transient pool;
- preview restore after export still works.

**Manual/device validation**

- `play -> export -> back to preview -> pause -> close`.
- Compare preview memory before export and after restore.

**DoD**

- Export does not leave preview-side Metal memory residue.
- Cancel/error paths are clean.
- Export output remains visually equivalent.

---

**PR 5: Device Validation / Budget Tuning**

**Цель**

Подобрать production budgets на реальном iPhone и доказать отсутствие лагов.

**Scope**

- Run same scenarios from PR 0.
- Compare budget candidates:
  - 128 MB;
  - 192 MB;
  - 256 MB;
  - device-class adjusted value if needed.
- Measure:
  - Xcode Memory;
  - `MTLDevice.currentAllocatedSize`;
  - `TexturePool.available/inUse/total`;
  - VM Tracker `IOSurface`, `IOAccelerator`, Dirty;
  - FPS;
  - frame time spikes;
  - allocation churn in Metal Resource Events.

**Non-scope**

- No new architecture.
- No bucketed lease.
- No legacy removal.

**Expected output**

PR should contain a table:

| Budget | Peak memory | Plateau | FPS | Scrub hitches | Notes |
| --- | --- | --- | --- | --- | --- |

**DoD**

- Production default budget chosen.
- Memory plateaus under target scenario.
- No noticeable preview quality regression.
- No repeated scrub/playback hitch clusters.

---

**PR 6: Bucketed Scratch Lease for bbox Owners**

**Цель**

Снизить количество unique bbox texture keys для `mask.boolean.bbox` и `matte.bbox`, если bounded exact-size pool still leaves too much allocation churn or memory pressure.

**Why after PR 1-5**

Bucketing touches geometry assumptions. It is powerful, but riskier than exact-size bounded pool. Делать только после того, как baseline/PR1-5 доказаны.

**Files**

- [TexturePool.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/TexturePool.swift)
- [MetalRenderer+MaskRender.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+MaskRender.swift)
- [MetalRenderer+Execute.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift)

**Required changes**

1. Add explicit lease API:
   - `ScratchTextureLease`;
   - `texture`;
   - `requestedSize`;
   - `allocatedSize`;
   - `validRect`;
   - `release()`.

2. Add separate acquire methods:
   - `acquireScratchColorTexture(requestedSize:owner:)`;
   - `acquireScratchR8Texture(requestedSize:owner:)`.

3. Bucket dimensions:
   - align to 64/128 px buckets;
   - never below requested size;
   - cap max oversize if needed.

4. Convert owners in order:
   - first `mask.boolean.bbox`;
   - then `matte.bbox`.

5. Ensure render correctness:
   - render only within `validRect`;
   - scissor/viewport use requested bbox;
   - composite uses original bbox, not full bucket texture;
   - unused bucket area cannot leak into output.

**Forbidden**

- Do not silently bucket old `acquireColorTexture(size:)`.
- Do not return larger textures to old callers without explicit validRect handling.

**Tests**

- visual parity for mask boolean operations;
- visual parity for matte bbox;
- bucketed backing texture does not affect output outside bbox;
- unique key count drops under scrub scenario;
- fallback full-frame path still works.

**Manual/device validation**

- Fast scrub on known problematic template.
- Compare owner breakdown before/after:
  - `mask.boolean.bbox`;
  - `matte.bbox`.

**DoD**

- Unique bbox keys significantly reduced.
- Memory and allocation churn improve versus PR 5.
- No visual regression.

---

**PR 7: Legacy Cleanup / Default Enablement**

**Цель**

Удалить старый unbounded behavior после доказательства новой архитектуры.

**Scope**

- Make bounded pool default.
- Remove feature flag if no longer needed.
- Remove unreachable unbounded path.
- Keep useful diagnostics with zero release overhead.
- Update comments/docs to describe new lifecycle.
- Remove temporary debug-only experiments that are no longer useful.

**Non-scope**

- No new behavior.
- No budget retuning unless PR 5 data was wrong.
- No MTLHeap migration.

**Tests**

- Full unit test suite.
- Render tests.
- Export tests.
- Device smoke pass.

**DoD**

- Legacy unbounded retention path is gone.
- New memory policy is documented by tests.
- Device validation still passes after cleanup.
- PR description includes final before/after summary.

---

**Optional PR 8: MTLHeap / Resource Aliasing Research**

**Статус**

Optional, not part of required Task 3 completion.

**Когда делать**

Только если after PR 1-6 memory footprint still needs major improvement or allocation churn remains high.

**Scope**

- Prototype transient render target heap.
- Analyze aliasing opportunities for mask/matte/transition passes.
- Compare complexity vs benefit.

**Non-scope**

- Do not start before bounded pool is stable.

---

**Stack dependencies**

PR order:

`PR 0 -> PR 1 -> PR 2 -> PR 3 -> PR 4 -> PR 5 -> PR 6 -> PR 7`

PR 6 can be skipped if PR 1-5 already meet memory/FPS targets.

PR 7 cannot happen before PR 5 validation.

**Final success criteria for the whole series**

- Xcode Memory no longer grows toward 800 MB / 1.5 GB under play/pause/scrub.
- `TexturePool.available` reaches a plateau within budget.
- `inUse` returns to 0 after GPU completion.
- `IOSurface` and `IOAccelerator` stop growing monotonically across cycles.
- Preview quality is unchanged.
- Export remains visually equivalent.
- Fast scrub remains responsive.
- 20-scene video timeline works without accumulating every historical bbox texture.
- Legacy unbounded `TexturePool` behavior is removed or unreachable.
