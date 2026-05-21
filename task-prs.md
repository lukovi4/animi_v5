# Clean Audio System Refactor - PR Plan

This is one product task, delivered as several reviewable PRs. Do not ship it as one huge PR.

Each PR must build on the previous one, keep behavior testable, and avoid touching unrelated rendering/export systems.

## PR 1 - Audio Session Manager

### Goal

Replace `AppAudioSessionController` with a production-grade audio session owner.

### Scope

Files expected to change:

- `AnimiApp/Sources/App/AppAudioSessionController.swift` or new `AudioSessionManager.swift`
- `AnimiApp/Sources/App/AppDelegate.swift`
- `AnimiApp/Sources/EditorRuntime/EditorRuntime.swift`
- tests for session manager/runtime start gate

### Requirements

- Introduce explicit result/throwing APIs:
  - `configureForPlayback()`
  - `activateForPlayback()`
  - `deactivateAfterPlayback()`
- Configure `.playback` + `.moviePlayback`.
- Register production observers for:
  - `AVAudioSession.interruptionNotification`
  - `AVAudioSession.routeChangeNotification`
  - `AVAudioSession.mediaServicesWereResetNotification`
- On media services reset:
  - reapply category/mode/options
  - notify runtime/coordinator that current preview audio objects are invalid
- `EditorRuntime.startPlayback()` must not proceed as normal when activation fails.
- Keep DEBUG diagnostics, but recovery behavior must exist in release builds.

### Tests

- activation success allows playback startup
- activation failure prevents preview audio startup
- media services reset triggers reconfiguration
- media services reset invalidates preview audio lifecycle
- session category after reset is `.playback`, not `SoloAmbient`

### Acceptance

- Device log in silent mode shows `.playback/.moviePlayback` before playback.
- After reset, next Play does not remain in `SoloAmbient/Default`.
- No call site ignores activation failure.

## PR 2 - Preview Audio Engine Failure Ownership

### Goal

Replace fragile `PreviewAudioPlaybackController` readiness handling with an authoritative player/item state model.

### Scope

Files expected to change:

- `AnimiApp/Sources/EditorRuntime/PreviewAudioPlaybackController.swift`
- protocol currently named `PreviewAudioControlling`
- tests in `ProjectAudioPreviewPlaybackTests.swift`

### Requirements

- Keep `AVPlayer` as playback engine.
- Observe `AVPlayerItem.status` for the whole item lifetime.
- If item becomes `.failed` after `.readyToPlay`, engine must enter `.failed`.
- Add production failure callback/event to coordinator.
- `startPlayback` must verify:
  - engine state allows start
  - current item exists
  - current item status is `.readyToPlay`
  - player item has not failed
- Never call `seek` or `setRate` on a failed item.
- Keep latest-wins protection for overlapping starts.
- Keep `cancelPendingSeeks()` on start/pause/teardown.

### Tests

- item failed after ready changes engine state to failed
- start on failed item is no-op and reports failure/rebuild need
- failed item does not call `setRate`
- overlapping seeks still only allow latest start
- pause/teardown invalidates pending seek completion

### Acceptance

- It is impossible to log `readiness=ready itemStatus=failed` as a valid steady state.
- Coordinator can receive player failure without reading DEBUG logs.

## PR 3 - Preroll and Primed Prepared Pipeline

### Goal

Make prepared preview audio actually ready for immediate audible playback.

### Scope

Files expected to change:

- preview audio engine/controller
- coordinator integration for prepared/primed state
- tests for preroll lifecycle

### Requirements

- After item becomes ready, perform `preroll(atRate: 1.0)` for idle prepared pipeline.
- Add state distinction:
  - `ready`
  - `prerolling`
  - `primed`
- Play from `primed` should use direct scheduled start when drift is within threshold.
- Cancel pending preroll on:
  - pause
  - teardown
  - new pipeline
  - dirty generation
  - media services reset
  - item failure
- Preroll completion must be token/generation protected.

### Tests

- ready item enters prerolling then primed
- Play joins pending preroll and starts after primed if needed
- stale preroll completion does not start playback
- pause/teardown cancels pending preroll
- first Play from primed pipeline schedules without rebuild

### Acceptance

- Device probes for first Play from prepared pipeline do not show 500ms+ stall at old/current zero time.
- User-perceived first Play latency is materially improved.

## PR 4 - Preview Audio Coordinator State Machine

### Goal

Replace legacy flag soup with an explicit lifecycle state machine.

### Scope

Files expected to change:

- `EditorRuntimePreviewAudioCoordinator.swift`
- tests for lifecycle transitions

### Target States

- `dirty`
- `building`
- `prepared`
- `starting`
- `playing`
- `paused`
- `failed`
- `recovering`
- `noAudio`

### Requirements

- Generation ownership remains mandatory.
- A pipeline is reusable only if generation matches and engine state is valid.
- `noAudio` must be distinct from `failed`.
- Dirty while idle schedules prepare.
- Dirty while playing starts rebuild or controlled transition.
- Export teardown cancels build, tears down engine, marks dirty, and does not prepare.
- Export restore schedules prepare.
- Session reset and player failure transition into recovery.

### Tests

- dirty old ready pipeline is not reused
- dirty old preparing pipeline is not awaited
- no-audio clears dirty but does not install pipeline
- build failure does not clear dirty as no-audio
- export teardown does not prepare
- export restore prepares
- player failure invalidates prepared pipeline and rebuilds
- session reset invalidates prepared pipeline and rebuilds/reconfigures

### Acceptance

- State transitions are inspectable in tests without relying on DEBUG logs.
- No hidden start path bypasses the state machine.

## PR 5 - Runtime Playback Integration

### Goal

Make `EditorRuntime.startPlayback()` and `stopPlayback()` use the new audio lifecycle as a first-class dependency.

### Scope

Files expected to change:

- `EditorRuntime.swift`
- `EditorRuntimeExportController.swift`
- app output/error handling if needed
- integration tests

### Requirements

- Start path:
  1. compute project time
  2. activate audio session
  3. ensure preview audio lifecycle is valid or recovering
  4. start video/audio transport in a predictable order
- If audio session activation fails:
  - do not report normal audio start
  - do not reuse failed player item
  - surface recoverable failure state
- Stop path:
  - pause audio
  - cancel pending seeks/prerolls/build starts
  - stop transport/displayLink
  - deactivate session according to lifecycle policy
- Export restore:
  - restore preview resources
  - schedule preview audio prepare
  - ensure session reset state does not leave category stale

### Tests

- activation failure blocks preview audio start
- runtime stop cancels pending audio start
- export restore schedules prepare but does not auto-play
- Play after export uses prepared pipeline
- Play after media reset reconfigures session and rebuilds audio

### Acceptance

- Runtime no longer starts video/audio as if everything succeeded after audio activation failure.
- Device smoke matrix passes.

## PR 6 - Diagnostics Cleanup and Hardening

### Goal

Keep high-value DEBUG diagnostics and remove temporary noise.

### Scope

Files expected to change:

- audio diagnostics added during investigation
- no production behavior changes

### Requirements

- Keep stable lifecycle events:
  - session configure/activate/deactivate/reset
  - preview state transitions
  - engine ready/primed/failed
  - build begin/end/noAudio
  - export audio reader/writer failure points
- Remove redundant high-volume per-item logs unless needed behind a specific flag.
- Document the expected log chain for:
  - cold launch prepare
  - first Play
  - Play/Stop/Play
  - export restore
  - media services reset recovery

### Tests

- Build/test only, no behavior tests unless diagnostics are structured APIs.

### Acceptance

- Device logs are readable enough to diagnose audio without flooding unrelated systems.

## Rollout Rules

- One PR must not mix audio session rewrite with preroll or coordinator state machine unless unavoidable.
- Each PR must include tests for its own failure mode.
- Do not change export audio semantics while fixing preview lifecycle.
- Do not use DEBUG-only state for production correctness.
- Do not rely on logs as the only proof of correctness.

## Full Device Smoke Matrix

Run after PR 5 and again after PR 6:

- Silent mode ON: cold launch -> Play -> Stop -> Play
- Silent mode OFF: same flow
- Export -> restore -> Play
- Rapid Play/Stop/Play
- Scrub/play from a far timeline position
- Add/change/delete music track while idle
- Add/change/delete video selection with original audio while idle
- Add/change/delete audio while playing
- Simulated or real media services reset
- Interruption begin/end
- Route change: speaker, Bluetooth/AirPods if available

## Final Merge Criteria

- All app tests pass.
- Device smoke matrix passes.
- No known path can leave session in `SoloAmbient/Default` before user-initiated preview playback.
- No known path can start a failed `AVPlayerItem`.
- No known path can reuse stale-generation audio after dirty changes.
- First prepared Play has no visible/audible startup lag beyond normal device scheduling latency.
