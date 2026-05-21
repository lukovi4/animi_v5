# Clean Audio System Refactor

## Context

Preview/export audio diagnostics proved that the audio composition itself is usually built correctly:

- preview pipeline reaches `tracks=17`, `mixInputs=17`, `playerReady`
- export reader/writer path can complete successfully
- drift fix and idle prebuild reduce one class of delayed playback

The remaining failures are lifecycle failures, not composition failures.

Observed device log evidence:

```text
audio.session.activate.end | ok=0 error=Couldn't communicate with a helper application.
audio.session.mediaServicesReset
category=AVAudioSessionCategorySoloAmbient mode=AVAudioSessionModeDefault
preview.audio.start | dirty=0 hasPipeline=1 readiness=ready
preview.audio.startPlayback.begin | itemStatus=failed error=Cannot Complete Action
```

This means the current architecture can:

- continue playback startup after `AVAudioSession` activation failed
- keep using a preview pipeline after `AVPlayerItem` has failed
- lose `.playback` category after media services reset
- become silent in Ring/Silent mode because the category falls back to `SoloAmbient`
- report local `readiness=ready` while the underlying item is actually `failed`

This is not fixable cleanly with more local flags. The audio lifecycle layer needs to be replaced.

## Goal

Build a clean, production-grade audio system for timeline preview:

- any audible source should start immediately on Play: project music, voiceover if present, and original video audio
- audio must play in Ring/Silent mode when user explicitly starts preview playback
- preview audio must recover from media services reset, interruptions, route changes, export teardown/restore, rapid play/stop, and `AVPlayerItem.failed`
- failed audio objects must never be treated as ready
- export audio semantics must remain unchanged

## Non-Goals

- Do not rewrite `AudioCompositionBuilder` unless a proven semantic bug is found.
- Do not change export writer/pump behavior as part of preview playback refactor.
- Do not change video render loop, `TexturePool`, masks, matte rendering, or `VideoFrameProvider` behavior.
- Do not change audio mix semantics: volume, trim, original video audio mapping, source timing.
- Do not replace `AVPlayer` with `AVAudioEngine` in this task. `AVPlayer` remains appropriate for composed `AVComposition` preview playback.

## Target Architecture

### 1. AudioSessionManager

Replace `AppAudioSessionController` with a production audio session owner.

Responsibilities:

- configure `AVAudioSession` with `.playback` and `.moviePlayback`
- activate/deactivate session with explicit success/failure result
- never hide activation failure behind logging only
- observe interruptions, route changes, and media services reset in production
- after `mediaServicesWereReset`, reapply category/mode/options before any new playback
- expose lifecycle events to runtime/coordinator
- keep DEBUG diagnostics, but behavior must not depend on DEBUG code

Required behavior:

- `startPlayback()` must not start preview audio if activation fails
- media services reset must invalidate current preview player/pipeline
- silent switch must not mute preview playback after recovery

### 2. PreviewAudioEngine

Replace the legacy `PreviewAudioPlaybackController` lifecycle with a clean AVPlayer owner.

Responsibilities:

- own `AVPlayer`, `AVPlayerItem`, status observation, seek, preroll, start, pause, teardown
- maintain authoritative state from the actual `AVPlayerItem.status`
- observe item status for the entire item lifetime, not only until first `.readyToPlay`
- expose failure callback/event to coordinator
- never seek or schedule playback on a failed item
- cancel pending seeks and prerolls on new start, pause, teardown, rebuild, and failure
- use `seek` for positioning and `setRate(_:time:atHostTime:)` for synchronized playback start
- use `preroll(atRate:)` to prime ready audio before first Play

Target states:

- `idle`
- `loading`
- `ready`
- `prerolling`
- `primed`
- `playing`
- `paused`
- `failed`
- `teardown`

Required behavior:

- if `AVPlayerItem.status == .failed`, engine enters `failed` and coordinator must rebuild
- local readiness must never disagree with underlying item status
- first Play from a prepared pipeline should not sit at `current=0` for 500ms+
- overlapping starts must be latest-wins
- pause/stop must prevent stale seek/preroll completions from restarting playback

### 3. PreviewAudioCoordinator

Replace ad hoc dirty/build flags with a state machine.

Responsibilities:

- own preview audio generation and pipeline ownership
- schedule idle prebuild when timeline preview is idle and dirty
- join in-flight prepare when user presses Play
- rebuild after dirty changes, export restore, session reset, and player failure
- keep no-audio state distinct from build failure
- coordinate engine readiness with runtime playback state

Target states:

- `dirty`
- `building`
- `prepared`
- `starting`
- `playing`
- `paused`
- `failed`
- `recovering`
- `noAudio`

Required behavior:

- stale generation pipeline must never start
- failed pipeline must never be reused
- export teardown must not trigger immediate rebuild during export mode
- export restore should schedule idle prepare
- media services reset should invalidate current engine and schedule recovery

### 4. EditorRuntime Integration

Playback startup should be gated by audio lifecycle:

1. resolve current timeline playhead/project time
2. ensure audio session configured and active
3. ensure preview audio engine is valid or recovery/prebuild is in progress
4. start video/audio transport in a predictable order
5. expose clear failure path if audio cannot start

Required behavior:

- if audio session activation fails, runtime must not pretend preview audio started
- if UX requires video to start without audio, this must be explicit and logged as degraded playback
- normal Play should start prepared audio immediately
- Stop must pause audio, cancel pending work, and deactivate session only when appropriate

## Current Code Audit Findings

### P0: Session activation failure is ignored

`AppAudioSessionController.activate()` logs errors but returns `Void`. `EditorRuntime.startPlayback()` continues into video and preview audio startup even when activation fails.

Impact:

- `AVPlayerItem` can fail with `Cannot Complete Action`
- runtime still reports playing
- subsequent starts reuse failed audio state

### P0: Media services reset has no production recovery

`mediaServicesWereReset` is only a DEBUG diagnostic. The app does not reapply `.playback/.moviePlayback` or invalidate audio objects.

Impact:

- session falls back to `SoloAmbient/Default`
- Ring/Silent switch mutes preview audio
- existing `AVPlayerItem` can remain failed

### P0: Player item can fail after local readiness becomes ready

Current status observation is removed after `.readyToPlay`. If the item later becomes `.failed`, controller state remains `.ready`.

Impact:

- logs can show `readiness=ready itemStatus=failed`
- coordinator will reuse dead pipeline
- start attempts call seek/setRate on failed item

### P1: No preroll/priming state

Idle prebuild installs an `AVPlayerItem`, but does not prime playback.

Impact:

- first Play can show `rate=1` and `timeControl=playing`, while `currentTime` does not advance for 500ms+
- audio is not guaranteed to be immediate even when pipeline is prepared

### P1: Coordinator state is implicit

Coordinator behavior is spread across `dirty`, `generation`, active build token fields, pending start flags, and controller readiness.

Impact:

- hard to reason about reset/failure/recovery
- new failure paths require more flags
- tests cover specific races but not a complete lifecycle model

## Acceptance Criteria

### Functional

- Timeline preview audio plays in Ring/Silent mode.
- After media services reset, next Play restores `.playback/.moviePlayback` and audio works.
- If session activation fails, runtime does not start a fake-success audio path.
- If `AVPlayerItem` fails, current preview pipeline is invalidated and rebuilt before reuse.
- First Play from an idle-prepared pipeline starts audibly without observable 500ms+ currentTime stall.
- Rapid Play/Stop/Play does not restart stale seek/preroll completions.
- Export teardown destroys preview audio; export restore schedules prepare; next Play starts from prepared pipeline.

### Architectural

- Exactly one production owner of `AVAudioSession`.
- Exactly one production owner of preview `AVPlayer/AVPlayerItem`.
- Coordinator owns lifecycle state, not raw player details.
- Runtime receives explicit success/failure/recovery state instead of inferring from DEBUG logs.
- DEBUG diagnostics remain useful but are not required for correct behavior.

### Testing

- Unit tests cover session activation failure, media services reset, item failure after ready, stale seek/preroll cancellation, and generation ownership.
- Integration tests cover idle prepare, join prepare on Play, export restore prepare, failed item rebuild, and runtime start gate.
- Device smoke matrix passes:
  - Silent mode on/off
  - first Play after cold launch
  - Play/Stop/Play rapid sequence
  - export -> restore -> Play
  - simulated or real media services reset
  - interruption begin/end
  - route change: speaker, Bluetooth/AirPods if available

## Verification Commands

Use the project-standard build/test gates:

```bash
xcodebuild build -project AnimiApp/AnimiApp.xcodeproj -scheme AnimiApp \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

```bash
ANIMIAPP_DERIVED_DATA_PATH=/tmp/audio_refactor_tests bash Scripts/run_animiapp_tests.sh
```

Device verification is mandatory before considering the refactor complete.

## Do Not Touch

- Export writer/pump unless a separate export regression is proven.
- Video render loop.
- `TexturePool`.
- masks/matte rendering.
- `VideoFrameProvider` scheduling semantics.
- audio mix semantics.
- `preferredTimescale` for audio target timing: keep `44100`.

## Final Deliverable

A clean audio system implemented as a sequence of reviewable PRs. The final system must be simpler to reason about than the current legacy stack: session failures, item failures, reset, prebuild, start, stop, export teardown, and restore must all flow through explicit lifecycle state.
