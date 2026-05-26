# Findings After Code Audit + Device Validation

Status legend:
- `FIXED` — fix applied and verified enough to close the finding.
- `FIXED IN CODE` — fix applied, but final targeted device validation is still useful.
- `CONFIRMED` — fix required.
- `STATIC` — code-level issue, device reproduction not required.
- `PARTIAL` — risk confirmed, but exact scenario still needs targeted validation.
- `NOT REPRODUCED` — device run did not prove a product bug; keep only as hardening/cleanup.
- `CLEANUP` — not product-blocking.

## Fixed / Closed

1. `FIXED` `EditorRuntimeExportController`: `unowned runtime` was used inside a fire-and-forget `Task` after export success.
   - Risk: rare crash if `EditorRuntime` is deallocated before the task executes.
   - Fix applied: `Task { [weak runtime] in await runtime?.session.commitAfterExportSuccess() }`.
   - Verification: full test suite reported green after PR-1.
   - Device validation: not required; static lifetime fix.

2. `FIXED` Headphone route changes are handled in `EditorRuntime`.
   - Original issue: `routeChanged` was ignored.
   - Device evidence before fix:
     - `reason=2` / `oldDeviceUnavailable` was delivered by iOS and should stop playback.
     - `reason=1` / `newDeviceAvailable` was delivered when headphones were connected; video continued, but later `preview.audio.engine.pause | engineWasRunning=0` showed the preview audio engine had stopped.
   - Fix applied:
     - `oldDeviceUnavailable` -> `stopPlayback()`.
     - `newDeviceAvailable` -> recreate preview audio engine graph via `reprepareForRouteChange()`, then restart preview audio without stopping transport/display link.
     - other reasons, such as `categoryChange`, remain no-op.
   - Tests added:
     - disconnect stops playback;
     - disconnect during pending start cancels startup;
     - connect restarts preview audio and keeps playback running;
     - other route reason does not stop playback.
   - Device validation: passed. Connect path produced valid probes after `reprepareForRouteChange`; disconnect path stopped playback and deactivated the session.

3. `FIXED` Preview audio host-time sync now uses `AVAudioPlayerNode.play(at:)`.
   - Device evidence: preview audio start took ~60-85ms; after 100ms audio advanced only ~42-46ms in multiple runs.
   - Risk: preview audio/video start offset and inconsistent sync after start/scrub/resume.
   - Fix applied:
     - `makePlaybackTiming(...)` computes `targetHostTime = max(anchorHostTime, now + scheduleLeadTime)`.
     - audio start frame is advanced by catch-up time.
     - `node.play(at: AVAudioTime(hostTime: ...))` replaces ASAP `node.play()`.
     - EOF handling returns `nil` when the computed raw frame is outside the file.
   - Tests added: timing helper coverage for future anchor, past anchor, recent anchor, EOF, exact start, and beyond-EOF skip.
   - Device validation: passed. Probes are valid on normal playback and headphone connect; route reprepare path also validates after `newDeviceAvailable`.

4. `FIXED` Export cancellation during early setup is now phase-aware and fenced.
   - Original issue: cancellation during render worked, but cancellation during the long setup window could wait until writer/setup work finished.
   - Device crash evidence before fix: UI cancel called `pipeline.cancel()` while `ExportWriterPipeline.startWriting()` was still starting the audio pump; AVFoundation crashed around `AVAssetWriterInput.requestMediaDataWhenReady`.
   - Fix applied:
     - `ExportSession.requestCancel()` is phase-aware: `.preparing` and `.finishing` only set the cancelled flag; `.rendering` performs destructive `pipeline.cancel()`.
     - `attachPipeline()` no longer destructively cancels immediately when the session is already cancelled.
     - `completeIfCancelled()` is the runner-side cancellation fence and owns destructive cleanup when called from the export lifecycle path.
     - Single-scene, timeline, and exporter setup paths now check cancellation around heavy setup boundaries and writer startup.
   - Tests added: active no-op, cancelled completion, before-pipeline cleanup path, attach-after-cancel no immediate cancel, preparing cancel no destructive pipeline cancel, runner-side destructive fence, rendering cancel immediate pipeline cancel.
   - Device validation: passed. Early cancel during a 16.2s `writer.startWriting` setup completed as `.cancelled` without crash and restored preview; render-phase cancel also completed cleanly with provider cleanup.

5. `FIXED` Timeline runtime eviction now cancels in-flight preparation and pending still-frame work.
   - Original issue: budget eviction and orphan cleanup removed runtimes from `instanceRuntimes` through `runtime.pause()`, but `pause()` only stopped video playback. A `.preparing` runtime could keep its preparation loop alive after eviction.
   - Follow-up issue: when preparation was suspended inside `awaitPendingStillFrames()`, cancelling only `preparationTask` did not cancel the underlying still-frame tasks owned by `UserMediaService`.
   - Fix applied:
     - `SceneInstanceRuntime.evictFromTimeline()` cancels `preparationTask`, transitions `.preparing` to `.failed(reason: "evicted")`, cancels pending still-frame work through `SceneMediaSyncing`, then pauses playback.
     - `TimelineResidencyController` and `TimelineCompositionEngine` orphan cleanup now call `evictFromTimeline()` instead of `pause()`.
     - `UserMediaService.cancelPendingStillFrames()` synchronously bumps still generations, cancels still tasks, and removes pending still task handles.
     - `releasePreviewResources()` reuses `cancelPendingStillFrames()` for the still-frame cleanup section.
   - Tests added: direct eviction state-machine coverage for `.preparing`, `.created`, `.ready`; orphan eviction integration; pending still-frame cancellation; suspended preparation unblocked from still-await; production `UserMediaService` blocked still-task cancellation.
   - Device validation: not required. This is a deterministic MainActor lifecycle/resource fix covered by unit/integration tests.

## P1 / Must Fix

No open P1 issues after PR-5.

## P2 / Should Fix

6. `STATIC` Preview audio `AudioBufferList` conversion assumes single-buffer layout.
   - Risk: fragile if audio output format changes from current interleaved layout.
   - Fix: allocate/copy buffer list using the size reported by the CoreMedia API.
   - Device validation: not required for the fix, but preview audio smoke is useful.

7. `STATIC` `deactivateAfterPlayback()` errors are swallowed with `try?`.
   - Risk: audio session failures lose diagnostics.
   - Fix: log the error.
   - Device validation: not required.

8. `NOT REPRODUCED / HARDENING` Preview video `CVMetalTexture` is not retained together with returned `MTLTexture`.
   - Device evidence: stress logs did not show `texture=nil`, Metal validation errors, black frames, or crash.
   - Remaining risk: code still depends on lifetime behavior that is safer in export path than preview path.
   - Fix scope: safety hardening, not an urgent confirmed bug.
   - Device validation: optional smoke after change.

9. `NOT REPRODUCED / HARDENING` `releasePreviewResourcesForClose()` does not cancel `playbackStartTask` directly.
   - Evidence: current stop/close tests pass; close path calls `stopPlayback()`.
   - Fix scope: add direct cancel for idempotency if touching close lifecycle.
   - Device validation: not required.

10. `NOT REPRODUCED / HARDENING` Close lifecycle is fire-and-forget; there is no explicit idempotent `runtime.close()` contract.
    - Device evidence: close drain is clean. Final device logs reached `SceneInstanceRuntime: 0`, `UserMediaService: 0`, `VideoFrameProvider: 0`, `metal: 0MB`.
    - Fix scope: architectural hardening only, not a confirmed leak.

11. `TEST GAP` `EditorRuntimeState` transition rules are scattered and lack a full state-machine test matrix.
    - Risk: future regressions around preview/export/close transitions.
    - Fix: add contract tests for key state transitions.

12. `NOT REPRODUCED` `PhotoProxyCache.proxyURL()` uses `Thread.sleep(0.05)` in an async-heavy path.
    - Device evidence: supplied photo/media logs did not show a confirmed freeze or product bug.
    - Fix scope: performance cleanup only unless a targeted photo ingest trace shows blocking.

13. `NOT REPRODUCED` `DownsampledImageLoader.loadTexture()` uses `commandBuffer.waitUntilCompleted()`.
    - Device evidence: no confirmed photo ingest freeze from current logs.
    - Fix scope: performance cleanup only unless Instruments/device trace proves UI stalls.

14. `CLEANUP / HARDENING` `TimelineExportResidencyController.cancel()` does not clean texture provider symmetrically with `finish()`.
    - Device evidence: export cancel cleanup looked healthy; provider count returned cleanly.
    - Fix scope: small cleanup/hardening.

## P3 / Cleanup Only

15. `CLEANUP` `EditorRuntimeState.error(String)` is defined but production code does not set it.

16. `CLEANUP` `AppAudioSessionController` is marked unavailable and is dead legacy code.

17. `CLEANUP` Legacy audio overloads/bridges remain: `AudioExportConfig`, `toLegacyConfig`, dual `audio` / `audioPlan`.

18. `CLEANUP` `ExportVideoFrameProvider.suspend/resume/releaseDecodedState` exists but production code does not call it.

19. `CLEANUP` `VideoPlaybackTrace` is duplicated.

20. `CLEANUP` Tests duplicate stubs such as `StubMediaLocator`, `StubMediaWriter`, `StubPresetProvider`.

21. `TEST STABILITY` Some concurrency tests still rely on `Task.sleep`, which can be flaky under CI load.

## Device Validation Status

Passed / no bug reproduced:
- Close teardown memory drain: clean after close, counters and Metal memory returned to zero.
- Export render cancellation cleanup: cancelled export cleaned providers and restored preview.
- Export early-setup cancellation: cancelled during long writer setup without AVFoundation crash; preview restored.
- Preview video texture smoke: no black frames, texture nils, Metal validation errors, or crash in supplied logs.

Confirmed on device:
- Preview audio host-time sync problem: fixed and device-validated.
- Headphone route-change handling problem: fixed and device-validated.
- Export early-setup cancellation problem: fixed and device-validated.

Still needs targeted device runs:
- No open critical/P1 finding currently requires device-only confirmation.

Not required for product safety unless new evidence appears:
- Photo ingest `Thread.sleep` / `waitUntilCompleted()` performance cleanup.
- Close lifecycle rewrite.
- CVMetalTexture ownership hardening.
