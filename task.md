**Final Canonical Plan**

Ниже финальное каноническое техническое задание на **полное закрытие оставшихся проблем** по текущему реальному коду продукта.
Scope **разбит на отдельные PR**, потому что это не одна задача, а несколько независимых архитектурных изменений с разным риском и разным review surface.

---

**Завершённые PR**

- **PRs H–L** (geometry refactor, template/resource hardening, loadability probe, cancellation fixes, ExportWriterPipeline crash fix) — **done**, commit `513d23f`
- **PR M: Legacy Transform Contract Removal** — **done**, принят лидом
- **PR N: SceneTypeLoadPipeline Unification** — **done**, принят лидом

---

**PR M: Legacy Transform Contract Removal — DONE**

**Что было сделано**

Production code — удалено:
- `SceneState.userTransforms` property + constructor param
- `SceneStateMigrationHelper.swift` (целиком)
- `ProjectDraftHydrator.swift` (целиком)
- `Matrix2DDecomposer.swift` (целиком)
- Legacy fallback в `SceneRuntimeStateApplier` (был line 280-283)
- `onSceneStateHydrated` callback + все `needsHydration` checks в `TimelineCompositionEngine`
- Hydration call + callback в `PlayerViewController`
- `writeHydratedSceneState` dead method в `EditorStore`
- `CompiledSceneMediaInputProvider` (no callers after engine hydration removal)

Production code — рефакторинг:
- `SceneRenderStateSnapshot.userTransforms` → `resolvedTransforms` (ScenePlayerTypes, SceneRenderPlan, ScenePlayer, TimelineCompositionEngine, TimelineExportRuntime, VideoExporter)
- `resolveTransformsForExport` starts from `[:]` instead of `state.userTransforms`
- `MediaInputProvider` protocol moved from deleted file to `SceneRuntimeStateApplier.swift`
- Stale doc comments cleaned in SceneRuntimeStateApplier, EditorStore, SceneMediaAsset, PlayerViewController

Tests — удалено:
- `SceneStateMigrationHelperTests.swift`
- `ProjectDraftHydratorTests.swift`
- `Matrix2DDecomposerTests.swift`
- `TimelineCompositionEngineHydrationTests.swift`

Tests — обновлено:
- `SceneRuntimeStateApplierTests.swift` — removed `userTransforms` references, replaced legacy tests with placement-only tests
- `TimelineCompositionEngineExportSessionTests.swift` — `userTransforms:` → `resolvedTransforms:`
- `VideoExporterTimelineExportSessionTests.swift` — `userTransforms:` → `resolvedTransforms:`
- `UserTransformPipelineTests.swift` (TVECore) — `userTransforms:` → `resolvedTransforms:` in SceneRenderPlan calls
- `EditorReducerTests.swift` — removed `userTransforms` references
- `ProjectStorePersistenceTests.swift` — removed `userTransforms` references

**Verification**: 755 AnimiApp tests passed, 0 failures. TVECore all green.

---

**Подтвержденные открытые проблемы (после PR N)**

1. ~~Legacy transform contract~~ — **CLOSED by PR M**

2. ~~Scene loading дублирование~~ — **CLOSED by PR N**

3. В app layer остается `print`-based operational logging и dead residue:
   - [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift)
   - [UserMediaService.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/UserMedia/UserMediaService.swift)
   - [SceneLibrary.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Content/SceneLibrary.swift)
   - `kEnableRenderDiagnostics`
   - `SceneVariantPreset`

4. [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift) остается god-object'ом. Это отдельный epic, не finishing PR.

---

**PR N: SceneTypeLoadPipeline Unification — DONE**

**Что было сделано**

Production code — создано:
- [SceneTypeLoadPipeline.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/SceneLoading/SceneTypeLoadPipeline.swift) — единый lower-level loading сервис в новой папке `Player/SceneLoading/`
- `LoadedScenePackageResources` struct (`Sendable`) — lightweight result type с тремя полями: `sceneTypeId`, `compiled`, `resolver`
- `SceneTypeLoadPipeline.load(sceneTypeId:from:)` — async throws, выполняет `CompiledScenePackageLoader` → `LocalAssetsIndex` → `SharedAssetsIndex` → `CompositeAssetResolver` на background thread с cancellation cooperation (`Task.checkCancellation()` до и после `.tve` decode)

Production code — мигрировано на pipeline (4 consumer-а):
- `PlayerViewController.loadSceneTypeAsync(...)` — inline bundle decode заменён на `SceneTypeLoadPipeline.load()`
- `PlayerViewController.loadSceneTypeFromBundle(...)` — аналогично; `BackgroundLoadResult` struct удалён
- `SceneTypeResourcesCache.preload(...)` — inline IO заменён на pipeline call
- `SceneTypeResourcesCache.preloadMetadata(...)` — inline IO заменён на pipeline call

Production code — без изменений (consumer-specific, остаётся у caller-а):
- `ScenePlayer` creation — в edit/coordinator path
- mutable `SceneTextureProviderFactory.create()` — в edit/coordinator path
- immutable `SceneTextureProviderFactory.createBaseProvider()` — в cache/export path
- texture preload — в cache и edit paths
- cancellation / requestId gating / UI state machine — в `loadSceneTypeFromBundle`
- `TimelinePlaybackCoordinator.LoadedScene` — thin wrapper, собирает pipeline result + consumer-created player/provider

Review findings fixed:
- P2: Shared load seam cooperates with caller cancellation (`Task.checkCancellation()` внутри detached task)
- P3: `LoadedScenePackageResources` помечен `Sendable` (не `@unchecked Sendable`)

**Verification**: 755 AnimiApp tests passed, 0 failures. TVECore 920 tests, 0 failures.

---

**PR O: Logging Normalization And Dead Code Cleanup**

**Статус: TODO — следующий PR**

**Цель**

Зачистить app-layer operational logging и очевидный dead residue после серии рефакторов.

**Вопросы по scope — ответы зафиксированы**

5. **Scope PR O не ограничивается одним unguarded `print` в `UserMediaService.swift:609`.**  
   Минимально обязательный blocker — удалить именно этот unguarded operational `print`, но каноничный PR O должен зачистить **все raw `print` call sites** в scoped app-layer files:
   - [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift)
   - [UserMediaService.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/UserMedia/UserMediaService.swift)
   - [SceneLibrary.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Content/SceneLibrary.swift)

6. **PR O должен именно мигрировать logging на `Logger`, а не просто удалять все сообщения.**  
   Низкоценные debug prints допустимо удалить, но operational logging, который остается полезным, должен быть переведен на structured `Logger` / `os.Logger`, а не сохранен как `print`.

7. **`PlayerViewController.log(_:)` не является dead code и не удаляется как residue сам по себе.**  
   У метода много call sites; в PR O его нужно либо перевести на `Logger`, либо удалить только вместе с миграцией всех его вызовов.

8. **[PerfLogger.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/UserMedia/PerfLogger.swift) не входит в scope PR O.**  
   Это dev-only `#if DEBUG` performance tool, а не operational app-layer logging surface.

9. **После миграции на `Logger` часть `#if DEBUG` guard-ов должна сохраниться.**  
   High-volume diagnostic traces не нужно автоматически делать release-visible только потому, что они переведены на `logger.debug`.

10. **Для [PlayerViewController.log(_:)](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift#L3931) каноничная стратегия — переписать тело метода, а не трогать все call sites.**  
    Это самый безопасный и наименее шумный diff для PR O. `log(_:)` должен стать thin wrapper вокруг file-local `Logger`.

11. **`[BUG-GUARD]` print в [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift#L243) не unguarded, но все равно входит в scope PR O.**  
    Он уже находится под `#if DEBUG`, однако остается raw `print`, а значит должен быть переведен на `#if DEBUG logger.debug(...)`.

12. **Единственный print в [SceneLibrary.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Content/SceneLibrary.swift#L53) тоже должен быть мигрирован, несмотря на `#if DEBUG`.**  
    Guarded `print` все равно считается raw `print` и не должен оставаться в финальном scoped cleanup.

13. **DEBUG-print traces в [UserMediaService.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/UserMedia/UserMediaService.swift) должны мигрировать на `logger.debug` с сохранением `#if DEBUG` для шумных сообщений.**  
    Отдельно blocker на [UserMediaService.swift:609](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/UserMedia/UserMediaService.swift#L609) обязателен к устранению как unguarded operational print.

14. **Файлы вне прямого scope PR O не трогать.**  
    Вне scope остаются, даже если в них есть `print`:
    - `BackgroundTextureService.swift`
    - `TimelineView.swift`
    - `EffectiveBackgroundBuilder.swift`
    - `EditorReducer.swift`
    - `ProjectStore.swift`
    - `PerfLogger.swift`

**Каноничное решение**

- В scoped app-layer files не должно остаться raw `print(...)`
- Ввести file-local `Logger` instances по примеру уже существующего использования в проекте
- Раскладывать сообщения по уровням:
  - `debug` / `info` для диагностических событий
  - `error` / `fault` для operational failures
- DEBUG-only сообщения допустимо:
  - перевести на `logger.debug`
  - или удалить, если они не несут долгосрочной ценности
- Для шумных debug traces сохранить `#if DEBUG`, даже если внутри используется `logger.debug`
- В [PlayerViewController.swift](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift) не переписывать 56 call sites вручную без необходимости:
  - сначала перевести тело `log(_:)` на `Logger`
  - direct `print(...)` call sites перевести отдельно
- Не делать repo-wide cosmetic sweep вне scoped files
- Удалить dead residue:
  - `kEnableRenderDiagnostics`
  - `SceneVariantPreset`

**Acceptance**

- В scoped app-layer files нет raw `print`
- `UserMediaService.swift:609` больше не содержит unguarded operational `print`
- оставшийся полезный logging переведен на `Logger`
- `PlayerViewController.log(_:)` либо переведен на `Logger`, либо удален вместе со всеми call sites
- `PerfLogger.swift` остается вне scope и не блокирует PR O
- `kEnableRenderDiagnostics` и `SceneVariantPreset` удалены
- Full suite зеленый

---

**Epic Q: EditorRuntimeController Split**

**Статус: отдельный epic, не в текущем цикле**

Вынести runtime/mode orchestration из PlayerViewController в отдельный controller/router layer.
Делать **после** PR N / O.

---

**Рекомендуемый порядок выполнения**

1. ~~**PR M**~~ — ✅ legacy transform contract removed
2. ~~**PR N**~~ — ✅ scene loading pipeline unified
3. **PR O** — logging normalization + dead code cleanup
4. **Epic Q** — вынести `EditorRuntimeController`

---

**Глобальные критерии закрытия задачи**

Задача считается закрытой на 100% по этому плану, если:

- ~~`userTransforms` исчезает из продового persisted/runtime contract~~ ✅
- ~~preview/export работают только через placement-based transforms~~ ✅
- ~~scene loading больше не дублируется в трех production pipeline~~ ✅
- touched app-layer files очищены от `print`-logging и dead residue
- full `swift test --package-path TVECore` зеленый
- full `xcodebuild test -project AnimiApp/AnimiApp.xcodeproj -scheme AnimiApp` зеленый
- manual smoke pass не показывает regressions
