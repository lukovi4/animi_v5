# Финальное каноническое ТЗ: Multi-Scene Timeline Runtime

Довести уже начатую ветку до релизного состояния. Новый продукт, пользователей и legacy данных нет — backward compatibility и migration **исключены из scope**. Current-schema persistence **обязателен**.

---

## База (сохранить как есть)

- **Источник данных для transitions:** [CanonicalTimeline.swift](AnimiApp/Sources/Project/CanonicalTimeline.swift), [SceneTransition.swift](AnimiApp/Sources/Project/SceneTransition.swift)
- **Runtime path для timeline:** [TimelineCompositionEngine.swift](AnimiApp/Sources/Player/TimelineComposition/TimelineCompositionEngine.swift) (не TimelinePlaybackCoordinator)
- **Shared/per-instance split:** [SceneTypeResourcesCache.swift](AnimiApp/Sources/Player/TimelineComposition/SceneTypeResourcesCache.swift), [SceneInstanceRuntime.swift](AnimiApp/Sources/Player/TimelineComposition/SceneInstanceRuntime.swift), [LayeredTextureProvider.swift](TVECore/Sources/TVECore/MetalRenderer/LayeredTextureProvider.swift)
- **Render contract:** [ResolvedTimelineFrame.swift](AnimiApp/Sources/Player/TimelineComposition/ResolvedTimelineFrame.swift), [TransitionCompositor.swift](TVECore/Sources/TVECore/MetalRenderer/TransitionCompositor.swift)
- **Scene Edit:** отдельный single-scene path в [PlayerViewController.swift](AnimiApp/Sources/Player/PlayerViewController.swift), timeline runtime туда не протягивать
- **Background:** project-level shared input
- **Audio:** hard-cut поведение из [AudioCompositionBuilder.swift](AnimiApp/Sources/Export/AudioCompositionBuilder.swift), crossfade/ducking не вводятся

---

## Обязательный релизный scope

### 1. Unified Compressed Playhead Domain (ACCEPTANCE CRITERIA)

**Проблема:** preview/play/fullscreen живут в uncompressed `projectDurationUs`, export в compressed duration.

**Требование:** Для timeline mode **source of truth playhead'а = compressed frame**, не microseconds.

**Реализация:**
- `scrub/play/fullscreen/export` используют единый compressed frame domain
- EditorState хранит playhead как compressed frame (или конвертирует при каждом использовании)
- Клипы в UI остаются номинальной ширины
- Piecewise mapping helper между nominal layout и compressed playhead
- **Нет drift/расхождения** между preview и export

**Файлы:** [EditorState.swift](AnimiApp/Sources/Editor/Store/EditorState.swift), [EditorStore.swift](AnimiApp/Sources/Editor/Store/EditorStore.swift), [PlayerViewController.swift](AnimiApp/Sources/Player/PlayerViewController.swift), [TimelineView.swift](AnimiApp/Sources/Editor/TimelineView.swift), [TimeRulerView.swift](AnimiApp/Sources/Editor/TimeRulerView.swift), [EditorLayoutContainerView.swift](AnimiApp/Sources/Editor/EditorLayoutContainerView.swift)

---

### 2. Transition Math Constants

- **fps:** 30
- **preset duration:** 14 frames
- **split:** 7 before + 7 after
- **compression:** 7 frames per transition
- **example:** A=30 + B=30 → 53 compressed frames
- **min scene duration:** сумма длительностей соседних transitions

---

### 3. TimelineTransitionMath Fixes

**Файл:** [TimelineTransitionMath.swift](AnimiApp/Sources/Player/TimelineComposition/TimelineTransitionMath.swift)

**Критические баги (crash на empty input):**
- Строка 55: `0..<(sceneItems.count - 1)` при `count == 0` → `0..<(-1)` → crash
- Строка 109: аналогично
- Строка 288: аналогично
- `frameMapping(for:)` fallback возвращает `sceneIndex: 0` при пустом массиве

**Требования:**
- Empty/single-scene safety (guard на `count < 2`)
- Точная frame math без `33_333`-дрейфа
- Корректный `renderMode`
- Hold-last для A после nominal end
- `B.localFrame = 0` на первом кадре transition window
- `.none` transitions не дают compression

---

### 4. Timeline UI

**Требования:**
- Overlap-графика **не нужна**
- Boundary indicator между сценами **нужен**
- Scrub mapping `x <-> playhead` **обязан** учитывать compressed timeline
- Piecewise mapping helper между nominal clip layout и compressed playhead

---

### 5. Readiness Contract

**Файлы:** [SceneInstanceRuntime.swift](AnimiApp/Sources/Player/TimelineComposition/SceneInstanceRuntime.swift), [MediaRestoreHelper.swift](AnimiApp/Sources/Player/TimelineComposition/MediaRestoreHelper.swift), [UserMediaService.swift](AnimiApp/Sources/UserMedia/UserMediaService.swift), [TimelineCompositionEngine.swift](AnimiApp/Sources/Player/TimelineComposition/TimelineCompositionEngine.swift)

**Требования:**
- Разделить `runtime created` и `runtime fully ready`
- Ждать всё, что влияет на первый корректный кадр active scene/transition pair
- `resolveFrame()` не отдаёт transition frame, пока обе сцены не ready
- **Safety path при неготовности:** hold на render/presentation path (удерживать last presented frame), **НЕ** подменять фейковым `.single(lastA)`
- Никакого partial pop-in

---

### 6. Global Budget Enforcement

**Файлы:** [GlobalVideoBudgetCoordinator.swift](AnimiApp/Sources/Player/TimelineComposition/GlobalVideoBudgetCoordinator.swift), [TimelineCompositionEngine.swift](AnimiApp/Sources/Player/TimelineComposition/TimelineCompositionEngine.swift), [UserMediaService.swift](AnimiApp/Sources/UserMedia/UserMediaService.swift)

**Проблема:** `update()` вызывается, но enforcement не доведён. `instancesToEvict()`, `prioritizedInstances()`, `shouldHaveActiveDecoders()` определены, но никогда не вызываются.

**Требования:**
- Лимит **глобальный**, enforcement делает **Engine** (не UserMediaService)
- Локальный budget в UserMediaService не должен быть фактическим глобальным лимитом
- **Pin pair ≠ разрешить все декодеры** (pair residency и decoder activation — разные вещи)

**Детерминированный runtime-контракт:**
1. Global allocation идёт **сначала по pinned scenes, потом warm**
2. Внутри сцены приоритет видео-кандидатов: **видимость → площадь → z-order**
3. Неактивные видео **держат last correct texture** (не дают wrong frame/pop-in)
4. Если в pinned pair видео-кандидатов больше бюджета — применяется приоритет выше

---

### 7. Eviction Policy

**Требования:**
- Normal path: `prev + current + next` prepared
- Pin: `current + transition partner`
- Warm: `prev + next`
- Evict farthest first
- Active transition pair не эвиктится никогда
- Wrong frame/variant/transforms/toggles/media state недопустимы

---

### 8. Texture Provider Split

**Файлы:** [SceneTypeResourcesCache.swift](AnimiApp/Sources/Player/TimelineComposition/SceneTypeResourcesCache.swift), [ScenePackageTextureProvider.swift](TVECore/Sources/TVECore/MetalRenderer/ScenePackageTextureProvider.swift), [LayeredTextureProvider.swift](TVECore/Sources/TVECore/MetalRenderer/LayeredTextureProvider.swift)

**Требования:**
- Реально immutable base layer per `sceneTypeId`
- Mutable overlay per `sceneInstanceId`
- SceneTypeResourcesCache не использует mutable semantics shared-base provider'а

---

### 9. Единый Render Executor

**Файлы:** [PlayerViewController.swift](AnimiApp/Sources/Player/PlayerViewController.swift), [VideoExporter.swift](AnimiApp/Sources/Export/VideoExporter.swift)

**Проблема:** composition path продублирован (~150 строк).

**Требования:**
- Общий executor поверх `ResolvedTimelineFrame + MetalRenderer + TransitionCompositor + background`
- Preview/export делят один composition contract
- Preview/export НЕ обязаны делить один instance runtime

---

### 10. Compositor Contract (CRITICAL BUG)

**Файл:** [TransitionCompositor.swift](TVECore/Sources/TVECore/MetalRenderer/TransitionCompositor.swift)

**Проблема:** `fade` реализован как cross-fade (обе сцены меняют opacity).

**Требования:**
- **fade = fade-over:** A unchanged (opacity 100%), B opacity 0→1
- slide/push/dip остаются как есть
- Easing v1 фиксированный: `fade=linear`, `slide/push/dip=easeInOut`

---

### 11. Aspect-Ratio Parity (HIGH PRIORITY)

**Файлы:** [TransitionCompositor.swift](TVECore/Sources/TVECore/MetalRenderer/TransitionCompositor.swift), [MetalRenderer+Execute.swift](TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift)

**Проблема:** Compositor может растягивать canvas-sized offscreen scenes fullscreen-quad'ом.

**Требования:**
- Compositor использует тот же contain mapping, что MetalRenderer
- Preview/fullscreen/export дают идентичный результат

---

### 12. Export-Safe Architecture

**Файл:** [VideoExporter.swift](AnimiApp/Sources/Export/VideoExporter.swift)

**Проблема:** per-frame hop на MainActor для `engine.resolveFrame()`.

**Требования:**
- Строить immutable export session/snapshot **один раз** перед export loop
- Рендерить на export queue thread-safe providers'ами
- **Нет** per-frame MainActor context switch

---

### 13. Reducer Normalization

**Файлы:** [EditorReducer.swift](AnimiApp/Sources/Editor/Store/EditorReducer.swift), [CanonicalTimeline.swift](AnimiApp/Sources/Project/CanonicalTimeline.swift)

**Проблема:** `ensureTrackInvariants()` не везде вызывается.

**Требования:**
- Normalization на **всех** structural edits: `duplicate/delete/reorder/trim/add/undo/redo/load`
- Auto-reset invalid boundaries

---

### 14. UI Boundary Picker

**Файлы:** [EditorAction.swift](AnimiApp/Sources/Editor/Store/EditorAction.swift), Timeline UI components

**Полный список transition preset'ов v1:**
- `none` — instant cut
- `fade` — fade-over
- `slide(direction: .left)` — B slides in from left
- `slide(direction: .right)` — B slides in from right
- `slide(direction: .up)` — B slides in from top
- `slide(direction: .down)` — B slides in from bottom
- `push(direction: .left)` — B pushes A, both move
- `push(direction: .right)`
- `push(direction: .up)`
- `push(direction: .down)`
- `dipToBlack` — fade to black, then fade from black
- `dipToWhite` — fade to white, then fade from white

**Требования:**
- Picker показывает **все 12 preset'ов**
- Dispatch `.setBoundaryTransition(...)`
- При auto-reset transition в `none` — явный сигнал пользователю

---

### 15. Scene Edit Isolation

**Требования:**
- При входе в `.sceneEdit` timeline playback/transition activity прекращается
- Adjacent extra video playback останавливается
- Shared caches можно сохранять
- Timeline runtime path туда не протягивать

---

### 16. Current-Schema Persistence

**Файлы:** [ProjectStore.swift](AnimiApp/Sources/Project/ProjectStore.swift), [ProjectDraft.swift](AnimiApp/Sources/Project/ProjectDraft.swift), [CanonicalTimeline.swift](AnimiApp/Sources/Project/CanonicalTimeline.swift)

**Требования:**
- Roundtrip save/load для `CanonicalTimeline.boundaryTransitions`
- Roundtrip save/load для текущего `ProjectDraft` (current schema)
- Все transition types корректно сериализуются/десериализуются
- **Нет потери данных** при save → load цикле

---

## Не входит в scope

- Migration / backward compatibility (новый продукт)
- Intro/outro runtime/UI
- Audio crossfade/ducking
- Per-scene background model

---

## Диагностика и тесты

**Signposts/counters:**
- scene-type preload
- instance prepare
- media restore
- transition partner ready
- first composited frame
- compositor encode time
- offscreen render A/B
- eviction decisions

**Обязательные тесты:**
- Pure math (включая empty input crash fix)
- **Roundtrip persistence для `CanonicalTimeline.boundaryTransitions`**
- **Roundtrip persistence для `ProjectDraft` current schema**
- Reducer auto-reset
- Duplicate `sceneTypeId` с разным `SceneState`
- Preview/export parity для `fade/slide/push/dip`
- Photo/video в обеих сценах
- Aspect-ratio parity
- Scene-edit isolation
- Budget/eviction/prewarm
- Empty timeline
- `.none` transition

**Файл:** [project.pbxproj](AnimiApp/AnimiApp.xcodeproj/project.pbxproj) — включить lifecycle-тесты в target.

---

## Критерии приёмки

1. **Один playhead → один frame везде:** scrub, play, fullscreen, export дают frame-identical результат
2. **Нет partial pop-in:** incoming scene никогда не появляется кусками, boundary freeze отсутствует
3. **Frame-only math:** все transition calculations только в frames
4. **Нет дублирования:** единый composition path для preview/export
5. **UI transitions:** picker показывает все 12 preset'ов, явный сигнал при auto-reset
6. **Persistence:** roundtrip save/load без потери boundaryTransitions
7. **Тесты зелёные:** целевой test suite проходит

---

## Порядок работ (рекомендуемый)

**Фаза 1 — Блокеры:**
1. Unified compressed playhead domain (source of truth = compressed frame)
2. Readiness gate в `resolveFrame()`
3. Fade-over fix в TransitionCompositor
4. Export session без per-frame MainActor
5. TimelineTransitionMath empty input guards

**Фаза 2 — Core:**
6. Global budget enforcement с детерминированным контрактом
7. Единый render executor
8. Aspect-ratio parity fix
9. Texture provider split finalization

**Фаза 3 — Integration:**
10. UI boundary picker (все 12 preset'ов)
11. Reducer normalization на всех paths
12. Scene Edit isolation verification
13. Current-schema persistence roundtrip tests
14. Full test coverage
