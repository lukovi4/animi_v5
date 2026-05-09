# task-2.md

Документ фиксирует stabilization bugs, найденные после branch-wide audit `PR0-PR11` и ручного device smoke перед merge.

Дата фиксации: `2026-05-07`.

Это не новый structural PR и не задача на broad legacy cleanup. Сначала чинятся доказанные user-facing regressions и закрываются regression tests. Архитектурные переписывания вне перечисленных bugs запрещены.

## 0. Baseline

- Canonical branch baseline:
  `bash Scripts/run_animiapp_tests.sh`
  ->
  `1344 tests, 0 failures, 2 skipped`.
- После уже примененного audit-fix:
  - `AnimiApp/Sources/EditorRuntime/EditorRuntime.swift`
  - `AnimiApp/Tests/ProjectAudioPreviewPlaybackTests.swift`
- Targeted suite после audit-fix:
  `ProjectAudioPreviewPlaybackTests`
  ->
  `26 tests, 0 failures, 1 skipped`.
- Full gate после audit-fix:
  `bash Scripts/run_animiapp_tests.sh`
  ->
  `1344 tests, 0 failures, 2 skipped`.

## 1. Reported Device Bugs

Пользовательские симптомы, воспроизведенные на девайсе:

1. Background image после успешного export и открытия проекта из `My Projects` удаляется. Ожидаемо: background должен сохраняться в проекте.
2. Видео в media input на preview и в финальном видео иногда проигрывается скачками, не ровно.
3. Music strip визуально начинается не от playhead/timeline offset, а от левого края экрана телефона. После изменения volume или trim полоска становится на правильное место.
4. MediaBlock пропадает в финальном видео: добавить video/photo, растянуть scene до 10 секунд, preview работает, export теряет media block примерно на 5 секунде. Проверено на template `polaroid 2`.

## 2. Findings

### Finding 1 - MediaBlock disappears after native scene duration in export

Severity: `P0`.

Status: `доказанная code-level причина`.

User symptom:
- Scene растянута до `10s`.
- Preview показывает media block до конца.
- Export теряет media block примерно на `5s`.
- На `polaroid 2` это похоже на native template duration около `5s`.

Code finding:
- Preview/runtime path clamp'ит `localFrame` к native scene duration:
  `AnimiApp/Sources/Player/TimelineComposition/SceneInstanceRuntime.swift:611`
  `makeRenderContext(localFrame:)`.
- Clamp owner:
  `AnimiApp/Sources/Player/TimelineComposition/SceneInstanceRuntime.swift:282`
  `clampedLocalFrame(_:)`.
- Production timeline export path не clamp'ит frame перед render plan:
  `AnimiApp/Sources/Export/TimelineExportRuntime.swift:252`
  `SceneRenderPlan.renderCommands(... sceneFrameIndex: localFrame ...)`.
- `SceneRenderPlan` фильтрует blocks по timing:
  `TVECore/Sources/TVECore/ScenePlayer/SceneRenderPlan.swift:54`
  `block.timing.isVisible(at: sceneFrameIndex)`.

Why this is a bug:
- Preview и export используют разные frame semantics для extended scene.
- Product expectation: stretched scene должна hold last native frame, включая media blocks.
- Фактический export передает frame `> native duration`, поэтому template block timing скрывает media binding после native end.

Required fix:
- В `TimelineExportRuntime` production residency path и legacy/test path clamp'ить scene-local frame к `0...(snapshot.runtime.durationFrames - 1)` перед:
  - `coordinator.updateTextures(forSceneFrameIndex:)`;
  - `SceneRenderPlan.renderCommands`;
  - `SceneRenderContext.localFrame`.
- Для transitions clamp'ить отдельно `frameA` и `frameB` по duration соответствующего snapshot.
- Сохранить timeline duration и overlay timing без изменений. Clamp применяется только к scene-native render frame.

Required tests:
- Add regression test in `VideoExporterTimelineExportSessionTests` or dedicated export parity suite:
  - scene timeline item duration `10s`;
  - compiled/runtime native duration `5s`;
  - media block present/visible;
  - resolve/export frame after native duration, e.g. `6s` or frame `180` at 30fps;
  - assert render context uses clamped native frame and media block commands remain present.
- Add transition variant if existing helpers allow it:
  - transition frames must clamp each side independently.
- Manual smoke:
  - template `polaroid 2`;
  - add photo;
  - stretch scene to `10s`;
  - export;
  - verify media block remains visible through final frame.

Acceptance:
- Preview/export parity for extended scene hold-last behavior.
- MediaBlock no longer disappears after native template duration.
- Full gate remains `1344 / 0 / 2` or updated only by intentionally added tests.

### Finding 2 - Music strip initial layout uses stale default constraints

Severity: `P1`.

Status: `доказанная code-level причина`.

User symptom:
- Music strip starts from the left edge of the phone, not from timeline/playhead offset.
- After volume/trim change, strip jumps to correct position.

Code finding:
- `TimelineView.setMusicItem(...)` calls `audioTrack.configure(...)` before `audioTrack.setHasClip(true)`:
  `AnimiApp/Sources/Editor/TimelineView.swift:562`.
- `AudioTrackView.updateTrackLayout()` returns early when `hasClip == false`:
  `AnimiApp/Sources/Editor/AudioTrackView.swift:156`.
- Initial constraints are default:
  `AnimiApp/Sources/Editor/AudioTrackView.swift:93`
  `leading = 0`, `width = 200`.

Why this is a bug:
- Component behavior depends on caller order.
- First render skips real geometry because the track is not marked as having a clip yet.
- Later volume/trim changes re-run configure after `hasClip == true`, masking the bug.

Required fix:
- Make `AudioTrackView` own its invariant:
  - `setHasClip(true)` must apply the latest stored geometry via `updateTrackLayout()`;
  - or `updateTrackLayout()` must be allowed to update constraints even while hidden, guarding only `durationUs > 0`.
- Preferred local fix:
  - in `AudioTrackView.setHasClip(_:)`, after assigning `hasClip = true`, call `updateTrackLayout()`.
  - Keep `TimelineView` call order behavior-compatible.

Required tests:
- Add test to existing `MusicLaneGeometryTests`:
  - create `AudioTrackView`;
  - call `configure(durationUs:pxPerSecond:leftPadding:clipOffsetPx:)` while `hasClip == false`;
  - then call `setHasClip(true)`;
  - assert leading constraint equals `leftPadding + clipOffsetPx`;
  - assert width equals `durationSeconds * pxPerSecond`.
- Optional integration-level test:
  - call `TimelineView.setMusicItem(...)` on fresh timeline and assert first layout is correct.

Acceptance:
- Music strip is correctly positioned on first appearance.
- Volume/trim no longer acts as an accidental layout repair.
- Existing geometry tests remain green.

### Finding 3 - Background image can be stale/missing after export and reopening saved project

Severity: `P0/P1`.

Status: `device symptom confirmed; exact destructive branch must be regression-tested before fix`.

User symptom:
- Background image exists during editing/export.
- After successful export and opening project from `My Projects`, background image is gone/deleted.

Code findings:
- Export success output is emitted before export commit is awaited:
  `AnimiApp/Sources/EditorRuntime/EditorRuntimeExportController.swift:486`.
- `commitAfterExportSuccess()` is started as fire-and-forget:
  `AnimiApp/Sources/EditorRuntime/EditorRuntimeExportController.swift:490`.
- Commit materializes current draft and deletes active draft:
  `AnimiApp/Sources/EditorSession/EditorSession.swift:393`.
- Scene background override is written through `mutateCurrentDraftForBookkeeping`:
  `AnimiApp/Sources/EditorSession/EditorSession.swift:142`.
- `mutateCurrentDraftForBookkeeping` is explicitly documented as non-dirtying registry bookkeeping only:
  `AnimiApp/Sources/Editor/Store/EditorStore.swift:92`.
- GC itself does scan project-level and scene-level background media refs:
  `AnimiApp/Sources/Project/FileProjectMediaStore.swift:311`.

Interpretation:
- This is probably not a simple "GC never scans background" bug; GC already scans project and scene background refs.
- The likely failure class is one of:
  - export UI/delivery opens saved project before `commitAfterExportSuccess()` has completed;
  - scene-level background override is treated as bookkeeping, so semantic dirty/checkpoint/materialization behavior can be skipped or become order-dependent;
  - saved project materializes a draft that does not contain the final background override/registry pair, then active draft deletion + GC removes the now-unreferenced file.

Required fix path:
1. Add reproduction test first with real file-backed persistence/media store.
2. Only after the test reproduces the failing branch, patch the smallest owner.

Required regression tests:
- File-backed project background test:
  - create active draft;
  - import/register background image;
  - commit export success through `EditorSession.commitAfterExportSuccess()` or production-equivalent storage actor path;
  - trigger GC;
  - load saved project by id;
  - assert background media ref is present;
  - assert `absoluteURL(for:registry:)` resolves;
  - assert file exists on disk.
- File-backed scene background test:
  - enter/set scene-level background override;
  - commit export success;
  - trigger GC;
  - open saved project;
  - assert scene `backgroundOverride` remains and file exists.
- Export completion sequencing test:
  - successful export must not emit/open saved project state before materialization has completed.

Likely code changes:
- Do not emit `.exportRenderSucceeded` / start delivery before `commitAfterExportSuccess()` has completed.
- Convert scene background override write from bookkeeping mutation into semantic reducer/store action so it participates in dirty/checkpoint/materialization lifecycle.
- If commit fails, preserve active draft and surface/log failure; do not silently delete recovery state.

Acceptance:
- Background image survives export, app relaunch, and reopening from `My Projects`.
- Both project-level and scene-level background image paths are covered.
- GC must not delete referenced background media.
- No new legacy fallback dependency is introduced.

### Finding 4 - Video in media input sometimes plays with jumps in preview and export

Severity: `P1`.

Status: `real device symptom; root cause not proven from static code alone`.

User symptom:
- Video inside media input sometimes plays unevenly in preview.
- Final exported video sometimes also has uneven playback.

Code observations:
- Preview path does not seek every display tick; `VideoFrameProvider.frameTextureForPlayback(...)` extracts from `AVPlayerItemVideoOutput` and falls back to last texture:
  `AnimiApp/Sources/UserMedia/VideoFrameProvider.swift:213`.
- Preview start schedules AVPlayer with host-clock conversion:
  `AnimiApp/Sources/UserMedia/VideoFrameProvider.swift:175`.
- DisplayLink drives timeline playback using `link.targetTimestamp`:
  `AnimiApp/Sources/EditorRuntime/EditorRuntime.swift:870`.
- Export path uses `AVAssetReader` and temporal resampling/blend:
  `AnimiApp/Sources/Export/ExportVideoFrameProvider.swift:443`.
- Shared time mapper exists:
  `AnimiApp/Sources/UserMedia/VideoTimelineTimeMapper.swift:24`.

Why no blind fix:
- Preview and export use different frame providers.
- If both show jumps, possible causes include source VFR cadence, target fps conversion, frame extraction misses, export resampling, or timeline frame mapping.
- A speculative fix could degrade correct videos or break preview/export parity.

Required investigation task:
- Capture one problematic source video file from device.
- Log for preview:
  - source duration;
  - track nominal fps;
  - preferred transform;
  - `nilExtractCount`;
  - playback item time vs expected video time;
  - displayLink frame deltas.
- Log for export:
  - `ExportVideoFrameProvider` summary;
  - `advancedSampleCount`;
  - `reusedLastTextureCount`;
  - `blendCount`;
  - `maxReusedStreak`;
  - target frame times around visible jumps.
- Compare preview and export target times from `VideoTimelineTimeMapper`.

Required tests after root cause:
- Add deterministic test around the proven failure:
  - VFR source cadence if VFR is the issue;
  - 24fps -> 30fps or 60fps -> 30fps cadence if resampling is issue;
  - host-time extraction if preview scheduling is issue;
  - export reader timeRange/PTS normalization if export provider is issue.

Acceptance:
- Problematic sample plays smoothly in preview.
- Exported file is visually smooth for the same sample.
- Regression test covers the exact diagnosed timing/cadence issue.

## 3. Already Fixed Audit Finding

### Scene edit playback policy was not enforced by actual UI mode

Status: `fixed before this document`.

Original issue:
- `EditorRuntime.startPlayback()` previously guarded playback with hardcoded `.timeline`.
- Contract forbids playback in `.sceneEdit`.

Applied fix:
- `EditorRuntime.startPlayback()` now reads `session.state?.uiMode` and passes actual mode to `EditorRenderContract.isPlaybackAllowed(in:)`.
- Regression test replaced `test_sceneEditMode_doesNotStartPreviewAudio` with broader `test_sceneEditMode_doesNotStartAnyPlayback`.

Verification:
- Targeted suite passed.
- Full gate passed with baseline `1344 / 0 / 2`.

## 4. Non-Goals

- Do not start a broad legacy cleanup before fixing the device bugs above.
- Do not rewrite `EditorRuntime`, `EditorViewController`, `TimelineCompositionEngine`, or export architecture.
- Do not change product behavior outside the four reported symptoms.
- Do not remove compatibility layers unless a failing regression proves that a compatibility path became a false primary path.
- Do not change shipped UI surface.

## 5. Recommended Fix Order

1. `P0`: Fix MediaBlock disappearing in export after native scene duration.
2. `P0/P1`: Reproduce and fix background persistence after export/open.
3. `P1`: Fix initial music strip layout invariant.
4. `P1`: Diagnose video jumps with real problematic sample, then apply targeted timing/provider fix.

## 6. Required Gates

Run targeted tests for changed suites first, then full gate:

```bash
bash Scripts/run_animiapp_tests.sh
```

Expected baseline before adding new tests:

```text
1344 tests, 0 failures, 2 skipped
```

After adding regression tests, test count may increase, but failures must remain `0` and skipped count must not increase without explicit reason.
