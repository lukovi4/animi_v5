С учетом принятых продуктовых решений целевой контракт теперь фиксируется жестко.

**Текущее Состояние На 2026-04-28**
- Зафиксирован integration milestone commit:
  `a7c45b4` —
  `integration: per-scene background domain, export runner extraction, preview background switching`.
- Зафиксирован следующий structural export commit:
  `1e17c58` —
  `refactor(export): extract TimelineExportSessionBuilder from engine`.
- Зафиксирован playback transport commit:
  `88e79c7` —
  `refactor(playback): introduce PlaybackTransport as single timeline playback time owner`.
- Актуальный локальный gate:
  `bash Scripts/run_animiapp_tests.sh`
  ->
  `1275 tests, 0 failures, 1 skipped`.
- В committed production code закрыты:
  `PR 1: Export Artifact And Delivery Policy Split`,
  `PR 2: Background Domain Contract And Scope Resolution`,
  `PR 4: VideoExporter Decomposition`,
  `PR 5: Timeline Export Session Builder Extraction`,
  `PR 6: Playback Transport And Timebase Refactor`.
- Дополнительно внутри этого integration milestone закрыт integration tail между `PR1–PR4`:
  delivery/runtime/output seam,
  scene background production edit/persistence/export path,
  per-scene timeline export background contract,
  timeline preview background switching на first non-transition frame.
- Внутри committed `PR 6` закрыт только transport/video playback ownership:
  runtime-owned `PlaybackTransport`,
  store playhead как mirrored UI state,
  shared host-time contract для timeline/video preview path.
- `Preview audio transport integration` сознательно не вошел в committed `PR 6`:
  runtime seam оставлен future-work,
  partial untracked audio preview files не считаются частью принятого production scope.
- `PR 3` полностью не закрыт:
  в дереве есть compatibility groundwork для audio,
  но canonical contract `generic audio domain -> runtime/export audio snapshot/plan`
  еще не доведен до финального accepted состояния.
- Следующий канонический structural шаг по плану:
  `PR 7: Preview Audio Transport Integration`.

**Финальная Цель Рефакторинга**
- Не “уменьшить файлы” и не “разложить код по папкам”, а довести редактор до состояния, где текущий product contract выражен в явных domain boundaries и не держится на giant owner-типах.
- После рефакторинга приложение должно поддерживать уже зафиксированный shipped/future-near scope без еще одного structural rewrite:
  generic audio timeline,
  artifact-first export c mandatory `Save to Photos -> share/post`,
  project-level background default,
  scene-level background override,
  scene-edit tool surface.
- `EditorViewController`, `EditorRuntime`, `TimelineCompositionEngine` и `VideoExporter` должны стать тонкими facade/presentation boundary типами, а не местом, где одновременно живут UI, orchestration, domain policy и feature-specific branching.
- `Audio`, `Background`, `Export Delivery` и `Scene Edit` должны получить отдельных owner-ов и явные контракты, чтобы новые фичи добавлялись внутри своих модулей, а не через повторное разрастание controller/runtime/exporter.
- Рефакторинг считается успешным только если следующий продуктовый шаг в этих доменах можно делать через локальное расширение соответствующего модуля, без новой волны переписывания editor core.

**Зафиксированный Product Contract**
- `Audio` идет в сторону `multi-item audio editor`, а не остается special-case `project music`.
- `Audio` должен жить как generic timeline domain поверх уже существующих `TrackKind.audio` / `ItemKind.audioClip` / `TimelinePayload.audio`.
- `Audio roles` должны быть metadata на item/payload уровне (`music`, `voiceover`, `sfx`, future roles), а не набором отдельных special-case полей и helper-ов.
- `Export` всегда сначала создает локальный `render/export artifact` и только потом передает его в delivery flow.
- Если пользователь отправляет видео наружу, delivery path обязан выполнить цепочку `Save to Photos -> share/post`.
- `Save to Photos` остается обязательным шагом для social/share path, но не должен быть частью render/export layer.
- Пользователь должен иметь возможность сразу выбрать destination после завершения render/export.
- `Background` должен поддерживать 2 scope:
  `project default background`
  и
  `scene custom background`.
- Effective background chain должен быть:
  `scene custom -> project default -> template default`.
- Если у сцены задан custom background, он полностью заменяет project background для этой сцены.
- `Background` с первого дня должен быть готов к source taxonomy:
  `solid`,
  `gradient`,
  `image`,
  `video`,
  `animated`.
- Для `video/animated background` future contract должен поддерживать playback-параметры вроде:
  `loop`,
  `trim`,
  `start offset`,
  и похожие настройки.
- Аудио у background не является частью shipped/future contract.
- Future `animated text`, `animated stickers`, `video overlays` и другие timeline-driven visual/audio элементы не должны получать собственные preview clock-ы. Они должны подключаться как consumers единого project playback time.
- `Scene Edit` остается отдельным per-scene tool surface, но не становится owner-ом background domain.
- Отдельный outside-editor preview/player сейчас **не является целевой shipped-функцией**. Значит отдельный read-only player stack строить сейчас не нужно, но новые runtime/export/background/audio модули нельзя делать editor-only по контракту.

**Канонический Архитектурный Контракт**
- `EditorViewController` должен стать только `UI host + presentation boundary`. В нем должны остаться lifecycle, modal presentation, UIKit delegates, `MTKView` hosting. Из него должны уйти flow-level orchestration, store/runtime binding detail, export UI branching, audio/background business orchestration.
- `EditorRuntime` должен остаться `runtime facade + state/output contract`. Он не должен сам содержать export domain, delivery policy, background domain, audio bridging, scene-edit tool orchestration и playback/render-source internals в одном типе.
- `Audio` должен стать отдельным domain с generic item model и role metadata. Controller должен презентовать audio UI, runtime должен получать готовый audio snapshot/plan, export pipeline должен принимать уже собранный audio plan.
- `Export` должен быть разрезан на 2 независимых слоя:
  `render/export session orchestration`
  и
  `delivery policy / destination flow`.
  Render/export не должен знать, куда пользователь потом отправит файл.
- Delivery layer должен владеть lifetime export artifact-а:
  retention,
  cleanup,
  retry semantics,
  mandatory `Save to Photos -> share` chaining.
- `Background` должен стать отдельным domain с явным разделением:
  `scope resolution`
  (`scene -> project -> template`)
  `background source model`
  `effective background state`
  `background residency/render inputs`
  `image/video backends`.
- `BackgroundTextureService` должен стать только image-backend внутри более широкого background runtime contract.
- `EffectiveBackgroundBuilder` должен эволюционировать в scope/source resolver, а не оставаться image-oriented mapper-ом.
- `Scene Edit` должен стать отдельной feature-архитектурой с tool-oriented decomposition:
  selection/gesture tool,
  media-slot tool,
  trim tool,
  overlay tool,
  future effects/crop/mask tools.
  Нельзя дальше складывать это обратно в `EditorViewController` и `EditorRuntime`.
- Preview playback должен стать `transport-driven`, а не `frame-driven`.
  В редакторе должен существовать один runtime-owned `PlaybackTransport / PlaybackClock`, который владеет project time.
  `CADisplayLink` должен стать только render sampler / UI refresh trigger, а не источником времени.
- Во время playback source of truth для текущего времени должен жить в runtime transport-е, а не в store playhead.
  Store playhead нужен для scrub/pause/stop/restore state и UI sync, но не как owner playback clock-а.
- `TimelineCompositionEngine`, `UserMediaService`, `VideoFrameProvider`, preview audio и future animated overlays/text/stickers должны стать consumers одного `project playback time`, а не независимыми clock domains с последующим corrective resync.
- После принятого `PR 6` transport/video часть этого контракта уже закрыта;
  preview audio для того же контракта вынесен в отдельный follow-up PR, чтобы не принимать partial audio seam.
- Перед playback должен собираться достаточно стабильный `playback snapshot / playback graph`, чтобы video/audio/overlay/background path читали уже готовую time-driven модель, а не каждый subsystem пересобирал свой contract на горячем пути.
- `TimelineCompositionEngine` должен стать фасадом над 3 внутренними подсистемами:
  frame resolver,
  playback budget/residency policy,
  export session builder.
- `VideoExporter` должен стать тонким export facade. Внутри не должно оставаться смешения config types, runner logic, audio assembly и timeline/single-scene orchestration в одном файле.

**Канонический Порядок PR-Рефакторинга**
1. `PR 1: Export Artifact And Delivery Policy Split` — `DONE`
   Цель: разрезать `render success`, `artifact lifetime` и `delivery destination policy`.
   По коду: разрезать текущий hardcoded path в `AnimiApp/Sources/EditorRuntime/EditorRuntime.swift` и `AnimiApp/Sources/Export/ExportDeliveryCoordinator.swift`.
   Вынести:
   `export artifact result`
   и
   `delivery policy`.
   Acceptance:
   export render success больше не означает автоматически `save to Photos`;
   social/share path формализован как `save to Photos -> share`;
   cleanup export file-а принадлежит delivery policy, а не render callback-у.

2. `PR 2: Background Domain Contract And Scope Resolution` — `DONE`
   Цель: зафиксировать правильный background contract раньше runtime extraction.
   По коду: разрезать current image-only assumptions в `AnimiApp/Sources/Project/ProjectBackgroundOverride.swift`, `AnimiApp/Sources/Background/EffectiveBackgroundBuilder.swift`, `AnimiApp/Sources/Export/ExportBackgroundSnapshot.swift`, `TVECore/Sources/TVECore/Models/Background/BackgroundRegionState.swift`, `AnimiApp/Sources/EditorRuntime/EditorRuntime.swift`.
   Acceptance:
   существует явный contract для `project default` и `scene override`;
   `scene override` полностью заменяет project background для сцены;
   source taxonomy больше не зафиксирована на `solid/gradient/image` как конечная модель.

3. `PR 3: Audio Domain Contract And Compatibility Layer` — `OPEN`
   Цель: убрать `project music` как canonical contract и перевести audio в generic timeline domain.
   По коду: разрезать special-case path в `AnimiApp/Sources/Project/CanonicalTimeline.swift`, `AnimiApp/Sources/Editor/Store/EditorReducer.swift`, `AnimiApp/Sources/Player/EditorViewController.swift`, `AnimiApp/Sources/Editor/TimelineView.swift`, `AnimiApp/Sources/EditorRuntime/EditorRuntime.swift`.
   Acceptance:
   audio model выражается через generic audio items + role metadata;
   runtime/export работают с audio snapshot/plan, а не с одним `musicConfig`;
   shipped behavior не ломается за счет compatibility layer.
   Текущее состояние:
   compatibility groundwork частично есть,
   но production export/runtime path все еще живет через music bridge,
   поэтому PR не считается завершенным.

4. `PR 4: VideoExporter Decomposition` — `DONE`
   Цель: превратить `AnimiApp/Sources/Export/VideoExporter.swift` в фасад.
   Вынести:
   single-scene export runner,
   timeline export runner,
   config/error definitions,
   delivery-agnostic artifact completion seam.
   Acceptance:
   `VideoExporter` больше не смешивает orchestration, config types, audio assembly и two export modes в одном giant файле.

5. `PR 5: Timeline Export Session Builder Extraction` — `DONE`
   Цель: вынести `buildExportSession()` из `AnimiApp/Sources/Player/TimelineComposition/TimelineCompositionEngine.swift` в отдельный builder.
   Почему: export snapshot assembly уже является отдельным bounded context внутри engine.
   Acceptance:
   engine перестает содержать тяжелый export snapshot assembly code.

6. `PR 6: Playback Transport And Timebase Refactor` — `DONE`
   Цель: перевести editor preview/playback с `frame-driven UI loop` на `transport-driven playback` с единым owner-ом времени до runtime/engine thinning.
   Почему: текущая модель `displayLink -> currentFrame + 1 -> store playhead -> subsystem resync` не является устойчивой базой даже для video-first preview path.
   По коду: разрезан playback-owner path в `AnimiApp/Sources/EditorRuntime/EditorRuntime.swift`, `AnimiApp/Sources/Player/TimelineComposition/TimelineCompositionEngine.swift`, `AnimiApp/Sources/Player/TimelineComposition/SceneInstanceRuntime.swift`, `AnimiApp/Sources/UserMedia/UserMediaService.swift`, `AnimiApp/Sources/UserMedia/VideoFrameProvider.swift`.
   Вынесено/введено:
   `PlaybackTransport`,
   runtime-owned playback cursor,
   time-driven `project time -> frame/localFrame/mediaTime` mapping,
   displayLink как render sampler, а не time owner,
   single-driver timeline preview path без runtime re-entry через mirrored store playhead.
   Acceptance:
   preview playback больше не двигается через `currentFrame + 1`;
   `CADisplayLink` больше не является source of truth для playback time;
   store playhead во время playback является mirrored UI state, а не owner времени;
   video preview path читает общий project playback time;
   per-scene preview background switching не регрессит.
   Явно вне scope принятого PR:
   `PreviewAudioPlaybackController.swift` и audio preview transport integration.

7. `PR 7: Preview Audio Transport Integration` — `NEXT`
   Цель: довести editor preview audio до того же transport-driven contract, что уже принят для timeline/video preview path.
   Почему: preview audio остается последним timeline playback consumer-ом, который нельзя оставлять на отдельном corrective-resync seam.
   По коду: довести `AnimiApp/Sources/EditorRuntime/PreviewAudioPlaybackController.swift` и audio-preview path-ы в `AnimiApp/Sources/EditorRuntime/EditorRuntime.swift`.
   Acceptance:
   preview audio стартует от shared playback transport time;
   steady-state preview audio не держится на periodic corrective seek loop;
   `markPreviewAudioDirty()` получает честкий runtime-owned contract вместо no-op seam;
   partial audio preview workspace files становятся либо committed production code, либо удаляются из future-work ветки.

8. `PR 8: TimelineCompositionEngine Internal Split`
   Цель: после transport refactor разрезать `TimelineCompositionEngine` на:
   frame resolution,
   residency/budget,
   playback sync.
   Acceptance:
   engine становится фасадом, а не owner-ом всех timeline concerns сразу.

9. `PR 9: Scene Edit Tool Architecture`
   Цель: вынести из controller/runtime tool surface scene-edit.
   По коду: собрать единый scene-edit feature из `AnimiApp/Sources/Editor/SceneEdit/SceneEditInteractionController.swift`, `AnimiApp/Sources/Editor/SceneEdit/InlineVideoTrimCoordinator.swift`, scene-edit path-ов в `AnimiApp/Sources/EditorRuntime/EditorRuntime.swift` и wiring в `AnimiApp/Sources/Player/EditorViewController.swift`.
   Acceptance:
   новый scene-edit tool добавляется в tool module, а не в giant controller/runtime.

10. `PR 10: EditorRuntime Thinning`
   Цель: после extraction-ов довести `AnimiApp/Sources/EditorRuntime/EditorRuntime.swift` до facade/state machine.
   Acceptance:
   runtime в основном маршрутизирует state, output и orchestration между уже вынесенными доменами.

11. `PR 11: EditorViewController Thinning`
   Цель: последним довести `AnimiApp/Sources/Player/EditorViewController.swift` до реально thin UI shell.
   Acceptance:
   controller больше не является composition root для половины editor feature-flows.

**Жесткие Архитектурные Запреты**
- Не делать “refactor by moving methods into extensions”.
- Не создавать новый giant type вместо старого.
- Не строить отдельный outside-editor preview module сейчас.
- Не держать `music`, `background` и `scene edit` как special-case feature islands.
- Не смешивать `export render` и `delivery destination` в одном owner-е.
- Не склеивать `export success` и `Save to Photos` в один и тот же layer.
- Не делать `project background` и `scene background` двумя несвязанными island-ами.
- Не встраивать background domain обратно в scene-edit owner model.
- Не использовать `CADisplayLink` как canonical source of playback time.
- Не держать `store playhead` как owner времени во время активного playback.
- Не лечить preview audio/video через наращивание periodic corrective seek/resync поверх неправильного master clock-а.

**Открытые Продуктовые Вопросы**
- Блокирующих продуктовых вопросов больше нет.
- Delivery UI может стартовать с системного share sheet, но destination boundary должна оставаться достаточно широкой для future direct SDK destinations без влияния на render/export contract.
