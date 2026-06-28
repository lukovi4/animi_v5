# Slice 005 — Stage 7 device gate report

Canonical preview audio — full physical-device matrix.

## Environment

| Field | Value |
|---|---|
| Device | iPhone 13 Pro (iPhone14,2), name "iPhone Evgeny" |
| devicectl identifier | `86C5CAA4-23E9-5EDB-BBE1-C11DAE59FF39` |
| xcodebuild device id | `00008110-000C59C20A20401E` |
| App bundle | `com.animi.app` |
| Commit | `499d2fecc3b90b83f77fa10ee7123afb2b57d060` — "Complete canonical preview audio device pass" |
| Branch | `cp7/next-user-video` |
| Build config | Debug |
| Launch flags | `-DebugPreviewAudioWithNextEngine YES -DebugMemoryDiagnostics YES` |

This report is filled scenario-by-scenario as each physical run completes. The operator
(device holder) performs all gestures (play / scrub / pause / headphones) and reports
audible result; the assistant drives build/install/launch + raw log capture and counts
markers. No "probably": any value not directly present in the raw log is marked as such.

## Commands

Build:
```
xcodebuild -project AnimiApp/AnimiApp.xcodeproj -scheme AnimiApp \
  -destination 'platform=iOS,id=00008110-000C59C20A20401E' \
  -configuration Debug -derivedDataPath /tmp/animi-stage7-dd build
```

Install:
```
xcrun devicectl device install app --device 86C5CAA4-23E9-5EDB-BBE1-C11DAE59FF39 \
  /tmp/animi-stage7-dd/Build/Products/Debug-iphoneos/AnimiApp.app
```

Launch + console capture (per scenario; note the `--` separator before launch args):
```
xcrun devicectl device process launch --console \
  --device 86C5CAA4-23E9-5EDB-BBE1-C11DAE59FF39 com.animi.app \
  -- -DebugPreviewAudioWithNextEngine YES -DebugMemoryDiagnostics YES \
  > Docs/AnimiEngineNext/evidence/slice-005-stage7-<scenario>.log 2>&1
```

## Scenario matrix

| # | Scenario | Verdict | Operator audible | Raw log |
|---|---|---|---|---|
| 1 | music-only | PASS (acceptance) — ⚠️ start-latency issue | music heard, no dropouts; **delayed start** | `evidence/slice-005-stage7-music-only.log` |
| 2 | video-original-only | PASS | video original audio heard, no crash | `evidence/slice-005-stage7-video-original-only.log` |
| 3 | music + video-original | PASS — ⚠️ same start-latency | both sources heard, even mix; **minimal start delay (same as S1)** | `evidence/slice-005-stage7-music-video.log` |
| 4 | scrub while playing | PASS | scrub does NOT play audio (correct) | `evidence/slice-005-stage7-scrub.log` |
| 5 | pause/play | PASS — ⚠️ start-latency confirmed cross-source | pause silences, play resumes, ≥3 cycles; **video audio also delayed on start** | `evidence/slice-005-stage7-pause-play.log` |
| 6 | route change / headphones | **FAIL** (errorAlert=1 during scene-length change; route-change flow itself PASS) | route change paused without auto-resume (correct); **but alert shown earlier when scene length increased** | `evidence/slice-005-stage7-route-change.log` |
| 7 | long video | **FAIL** (nextChunk.failed=6 + errorAlert; deterministic break ~47 s) | audio plays ~2 s then alert, then silence | `evidence/slice-005-stage7-long-video.log` |
| 8 | stress: multiple videos | **FAIL** (pcmRenderFailed short-read + errorAlert; only after scene-length change) | 4 videos default length OK; **change scene length by ≥1 s → alert** | `evidence/slice-005-stage7-stress-multiple-video.log` |

## Marker counts

### Scenario 1 — music-only

Raw log: `Docs/AnimiEngineNext/evidence/slice-005-stage7-music-only.log` (377 lines)

| Marker | Count |
|---|---|
| `preview.audio.canonical.selected` | 1 |
| `preview.audio.canonical.legacyGateBypassed` | 4 |
| `preview.audio.canonical.plan` | 4 |
| `preview.audio.canonical.render.begin` | 19 |
| `preview.audio.canonical.render.end` | 19 |
| `preview.audio.canonical.engine.start.end` | 4 |
| `preview.audio.canonical.player.play.end` | 4 |
| `preview.audio.canonical.scheduled` | 4 |
| `preview.audio.canonical.nextChunk.schedule.end` | 15 |
| `preview.audio.canonical.nextChunk.endOfPlan` | 4 (planEnd=240000) |
| **Failure markers** | |
| `fallbackToLegacy` (=1) | 0 |
| `errorAlert` | 0 |
| `nextChunk.failed` | 0 |
| `pcmRenderFailed` | 0 |
| `shortfall` | 0 |
| `SIGKILL` / crash / jetsam | 0 |
| legacy playback markers | 0 |

Operator: music audible, no dropouts, app responsive, no crash. **Reported defect:
audible start is delayed — should be instant.**

Acceptance criteria for Stage 7 (audible / no-fallback / no-error / no-failed /
no-pcmRenderFailed / no-shortfall / canonical markers present) → **PASS**.

⚠️ Start-latency observation (NOT a Stage-7 acceptance criterion; no latency criterion
exists in the matrix). The log start sequence (`slice-005-stage7-music-only.log` lines
75–88) is:
`startPlayback.call` → `plan` → `preroll.build.begin` → `firstFrameSignal` →
`render.begin`/`render.end` (range `0..<48000`) → `preroll.build.end` →
`graph.schedule.*` → `engine.start.begin` → `player.play.begin` → `player.play.end` →
`scheduled`.
Structural cause visible in markers: the player does not start until the first preroll
chunk `0..<48000` (exactly 1.0 s @ 48 kHz) is fully rendered synchronously **before**
`player.play.begin`. **The exact wall-clock latency cannot be measured from this log** —
only `legacyGateBypassed` carries a `hostTime` value; the markers around the play path do
not emit per-event wall-clock timestamps, so no millisecond figure is asserted (would be a
guess). Recorded as an open UX issue, not a matrix FAIL. No code changed.

### Scenario 2 — video-original-only

Raw log: `Docs/AnimiEngineNext/evidence/slice-005-stage7-video-original-only.log` (659 lines)

| Marker | Count |
|---|---|
| `preview.audio.canonical.selected` | 1 |
| `preview.audio.canonical.legacyGateBypassed` | 3 |
| `preview.audio.canonical.plan` | 3 |
| `preview.audio.canonical.render.begin` | 25 |
| `preview.audio.canonical.render.end` | 25 (sources=1 ×15, sources=2 ×10) |
| `preview.audio.canonical.engine.start.end` | 3 |
| `preview.audio.canonical.player.play.end` | 3 |
| `preview.audio.canonical.scheduled` | 3 |
| `preview.audio.canonical.nextChunk.schedule.end` | 22 |
| `preview.audio.canonical.nextChunk.endOfPlan` | 3 (planEnd=480000) |
| **Failure markers** (fallbackToLegacy=1 / errorAlert / nextChunk.failed / pcmRenderFailed / shortfall / SIGKILL / jetsam) | 0 |

Operator: video original audio audible, app responsive, no crash. → **PASS**.

### Scenario 3 — music + video-original

Raw log: `Docs/AnimiEngineNext/evidence/slice-005-stage7-music-video.log` (564 lines)

| Marker | Count |
|---|---|
| `preview.audio.canonical.selected` | 1 |
| `preview.audio.canonical.legacyGateBypassed` | 4 |
| `preview.audio.canonical.plan` | 4 |
| `preview.audio.canonical.render.begin` | 40 |
| `preview.audio.canonical.render.end` | 40 (sources=2 ×20, sources=3 ×20) |
| `preview.audio.canonical.engine.start.end` | 4 |
| `preview.audio.canonical.player.play.end` | 4 |
| `preview.audio.canonical.scheduled` | 4 |
| `preview.audio.canonical.nextChunk.schedule.end` | 36 |
| `preview.audio.canonical.nextChunk.endOfPlan` | 4 (planEnd=480000) |
| **Failure markers** (fallbackToLegacy=1 / errorAlert / nextChunk.failed / pcmRenderFailed / shortfall / SIGKILL / jetsam) | 0 |

Operator: both music + video-original audible, even mix, app responsive, no crash.
`render.end sources=2/3` confirms multi-source mixing. → **PASS**. Same start-latency issue
as S1 reported by operator ("minimal delay") — recorded under Open issues, not a matrix FAIL.

### Scenario 4 — scrub while playing

Raw log: `Docs/AnimiEngineNext/evidence/slice-005-stage7-scrub.log` (608 lines)

Acceptance focus: **scrub must NOT start audio.** Operator confirms: scrub does not play
audio; behaviour correct; app responsive; no crash.

| Marker | Count |
|---|---|
| `preview.audio.canonical.selected` | 1 |
| `preview.audio.canonical.legacyGateBypassed` | 8 |
| `preview.audio.canonical.plan` | 8 |
| `preview.audio.canonical.render.begin` / `render.end` | 41 / 41 |
| `preview.audio.canonical.nextChunk.requested` | 33 |
| `preview.audio.canonical.nextChunk.schedule.end` | 26 |
| `preview.audio.canonical.nextChunk.dropped` | 7 (all `reason=staleOrStopped`) |
| `preview.audio.canonical.engine.start.end` / `player.play.end` / `scheduled` | 8 / 8 / 8 |
| `preview.audio.engine.teardown` | 1 |
| **Failure markers** (fallbackToLegacy=1 / errorAlert / nextChunk.failed / pcmRenderFailed / shortfall / SIGKILL / jetsam) | 0 |

Evidence the scrub correctly does not replay from a stale position: all 7 dropped chunks
carry `reason=staleOrStopped` with diverging generation counters
(`gen=2 current=4`, `gen=6 current=8`, … `gen=26 current=28`). Each scrub bumps the plan
generation and the in-flight render for the previous position is fail-closed dropped rather
than scheduled at the wrong time. → **PASS**.

### Scenario 5 — pause/play

Raw log: `Docs/AnimiEngineNext/evidence/slice-005-stage7-pause-play.log` (514 lines)

Acceptance focus: **pause must stop audio; play must resume.** Operator confirms: pause
silences, play resumes, multiple cycles, no crash, app responsive.

| Marker | Count |
|---|---|
| `preview.audio.canonical.selected` | 1 |
| `preview.audio.canonical.startPlayback.call` | 6 (= 6 Play presses) |
| `playback.audio.start.begin` | 6 |
| `playback.audio.stop.begin` | 6 (= 6 pause/stop) |
| `preview.audio.canonical.player.play.end` / `scheduled` / `engine.start.end` | 6 / 6 / 6 |
| `preview.audio.canonical.legacyGateBypassed` | 6 |
| `preview.audio.canonical.nextChunk.dropped` | 5 (all `reason=staleOrStopped`, gen 2→4 … 18→20) |
| `preview.audio.canonical.nextChunk.endOfPlan` | 1 |
| **Failure markers** (fallbackToLegacy=1 / errorAlert / nextChunk.failed / pcmRenderFailed / shortfall / SIGKILL / jetsam) | 0 |

Each `playback.audio.stop.begin` (pause) is paired with a `nextChunk.dropped
reason=staleOrStopped` — pause both silences output and fail-closed drops the in-flight
render, leaving no audio tail. Six start/six stop = clean play↔pause cycling. → **PASS**.

Cross-source latency note: operator reports the **video-original** audio also starts with a
delay, not only music. The start chain is identical across all sources
(`startPlayback.call → preroll.build → render → engine.start → player.play`), so the
start-latency Open issue is **not music-specific** — it is structural to the canonical start
path (preroll chunk rendered synchronously before `player.play.begin`). Recorded under Open
issues; not a matrix FAIL (no latency acceptance criterion in Stage 7).

### Scenario 6 — route change / headphones — FAIL

Raw log: `Docs/AnimiEngineNext/evidence/slice-005-stage7-route-change.log` (1327 lines)

**Two distinct things in this run:**

**(a) The route-change flow itself = PASS.** Operator connected/disconnected headphones
during playback:
- line 924: `audio.session.routeChange.newDeviceAvailable.handleInRuntime | isPlaying=1`
  (headphones connected → paused, did not auto-resume into the new route)
- line 1199: `audio.session.routeChange.oldDeviceUnavailable.handleInRuntime | isPlaying=1 hadStartTask=0`
  (headphones disconnected)
- No crash; pause-without-auto-resume behaviour is correct.

**(b) But an error alert fired earlier in the same run = FAIL of acceptance criterion
`errorAlert = 0`.** When the operator **increased the scene length**, the canonical plan
build fail-closed:

```
line 217: preview.audio.canonical.startPlayback.call | seconds=0.0
line 218: preview.audio.canonical.startFailed | error=incomingAudioBeforeBoundary(clip: "app.audio.clip.videoLayer.scene-1-8EB9A95F-2088-4724-830C-CBDA736CC86F:block_01")
line 219: preview.audio.canonical.errorAlert  | reason=incomingAudioBeforeBoundary(clip: "...block_01")
```

Repeated at lines 281, 305 (`startFailed` ×3 total; `errorAlert` ×1).

**Failure-protocol breakdown:**

| Item | Fact |
|---|---|
| Last successful marker | `preview.audio.canonical.startPlayback.call` (line 217) |
| Missing next expected marker | `preview.audio.canonical.plan` / `render.begin` / `player.play.end` — absent for this cycle; replaced by `startFailed` |
| Exact failing scenario | NOT the route change — it occurred earlier, when scene length was increased |
| Exact log lines | 218 (`startFailed`), 219 (`errorAlert`); repeats 281, 305 |
| Failure layer | **plan / render build** (`CanonicalAudioRenderPipeline` plan-builder), not cache / graph / engine / session / route. The builder validates the clip boundary and fail-closed throws `incomingAudioBeforeBoundary` before a plan is built |
| `fallbackToLegacy` | 0 (did NOT fall to legacy — correct) |
| `nextChunk.failed` / `pcmRenderFailed` / `shortfall` / SIGKILL / jetsam | 0 |
| `errorAlert` | **1 → violates `errorAlert = 0`** |

**What the marker boundary proves (no guess):** after the scene length was increased, the
video-layer audio clip `block_01` ends up with source audio positioned **before the clip
boundary** on the timeline. The canonical plan-builder fail-closes (`incomingAudioBeforeBoundary`)
rather than playing the wrong audio — by-design protection — but the current handling
surfaces a user-facing **alert** instead of silently clamping/handling the boundary. This is
a NEW edge case distinct from the Stage-6 short-read: *scene-length increase →
video-audio-before-clip-boundary → canonical plan fail-closed → errorAlert.*

This is not a short-read, not a legacy fallback, not a crash. No architecture change is
proposed: the marker boundary proves the current plan path raises an alert for this case,
but whether the correct fix is in the plan-builder (clamp/handle the boundary) or in the
alert policy (do not surface this fail-closed as an alert) is an owner decision.

### Scenario 7 — long video — FAIL

Raw log: `Docs/AnimiEngineNext/evidence/slice-005-stage7-long-video.log` (2067 lines)

Operator: audio plays ~2 s, then an alert appears, then no audio.

Marker chain (lines 717–724): chunks `0 … 2256000` render and schedule cleanly
(`render.end sources=1`, `schedule.end scheduled=1`). At chunk `2256000..<2304000` (= 47.0 s
@ 48 kHz):

```
render.end | sources=0
nextChunk.render.end | range=2256000..<2304000 sourceCount=0
nextChunk.failed | error=audioRenderPipelineUnavailable(reason: "continuous chunk 2256000..<2304000 produced no PreviewMixSource")
errorAlert      | reason=audioRenderPipelineUnavailable(reason: "continuous chunk 2256000..<2304000 produced no PreviewMixSource")
```

| Item | Fact |
|---|---|
| Last successful marker | `nextChunk.schedule.end range=2208000..<2256000 scheduled=1` (line 717) |
| First failing marker | `render.end sources=0` for `2256000..<2304000` (line 720) |
| Failure layer | **render pipeline** — `CanonicalAudioRenderPipeline` returned zero mix-sources for a continuous chunk (`audioRenderPipelineUnavailable`); not cache/graph/engine/session/route |
| Determinism | `nextChunk.failed` ×6, all clustered at ~`2256000–2259199` (lines 723, 1085, 1369, 1731, 1918, 2064) → deterministic break at ~47 s, not random and not memory (MEM ~111 MB, jetsam=0) |
| `fallbackToLegacy` | 0 |
| `nextChunk.failed` | 6 → violates criterion |
| `errorAlert` | present → violates `errorAlert = 0` |
| SIGKILL / jetsam | 0 |

→ **FAIL.**

### Scenario 8 — stress: multiple videos — FAIL

Raw log: `Docs/AnimiEngineNext/evidence/slice-005-stage7-stress-multiple-video.log` (763 lines)

Operator localisation (key): **open scene, add 4 videos, do NOT change scene duration → all
correct.** **Change scene duration by even 1 s → alert/error.**

Marker chain: with 4 videos (`segments=4`, `sources=4`) chunks `0 … 528000` render and
schedule cleanly. At chunk `528000..<576000` (= 11.0 s @ 48 kHz):

```
nextChunk.failed | error=pcmRenderFailed(reason: "decode produced 26347 frames, expected 48000 (shortfall 21653 > tolerance 1024)")
errorAlert      | reason=pcmRenderFailed(reason: "decode produced 26347 frames, expected 48000 (shortfall 21653 > tolerance 1024)")
```

| Item | Fact |
|---|---|
| Last successful marker | `nextChunk.schedule.end range=480000..<528000 scheduled=1` (line 678) |
| First failing marker | `nextChunk.failed pcmRenderFailed` for `528000..<576000` (line 681) |
| Failure layer | **decode/PCM render** — short-read (decode produced 26347 of 48000 frames; shortfall 21653 > tolerance 1024). This is the SAME class as the Stage-6 short-read, recurring at a new chunk |
| `pcmRenderFailed` / `shortfall` | 2 / 2 → violates criteria |
| `fallbackToLegacy` | 0 |
| `errorAlert` | present → violates `errorAlert = 0` |
| SIGKILL / jetsam | 0 (memory grew to ~430 MB foot, no crash) |
| Trigger (operator) | only after scene duration changed; default-length 4-video project plays fine |

→ **FAIL.**

## Final verdict

**FAIL.**

| # | Scenario | Verdict |
|---|---|---|
| 1 | music-only | PASS (⚠️ start latency) |
| 2 | video-original-only | PASS |
| 3 | music + video-original | PASS (⚠️ start latency) |
| 4 | scrub while playing | PASS |
| 5 | pause/play | PASS (⚠️ start latency, cross-source) |
| 6 | route change / headphones | **FAIL** — `errorAlert` `incomingAudioBeforeBoundary` after scene-length increase (route-change flow itself PASS) |
| 7 | long video | **FAIL** — `nextChunk.failed`×6 + `errorAlert` `audioRenderPipelineUnavailable` (no mix-source) at ~47 s |
| 8 | stress: multiple videos | **FAIL** — `pcmRenderFailed` short-read (26347/48000) + `errorAlert` at ~11 s, only after scene-length change |

Per Stage 7 rule, any failed scenario makes the overall verdict **FAIL**. 5/8 PASS, 3/8 FAIL,
0 BLOCKED (all eight scenarios were run at owner instruction).

### Common root signal (operator-confirmed, not a guess)

The operator reports — and the three FAIL logs corroborate — that the failures appear
**after changing the scene duration**. A default-length project (S2, S8-default) plays
correctly; changing the scene length surfaces three distinct downstream symptoms:

| Scenario | Symptom marker | Layer |
|---|---|---|
| S6 | `incomingAudioBeforeBoundary` (clip `block_01`) | plan-builder boundary validation |
| S7 | `audioRenderPipelineUnavailable … produced no PreviewMixSource` (~47 s) | render pipeline returns 0 sources |
| S8 | `pcmRenderFailed … shortfall 21653 > tolerance 1024` (~11 s) | decode short-read |

These are three different failure markers at three different layers, but the operator's
reproduction points to one upstream trigger: **scene-duration change re-maps video-layer
audio clip timing**, and the canonical audio plan/render path does not yet handle the
re-mapped clip windows for video-original audio (boundary, empty mix, and short-read are the
three ways it currently breaks). This is consistent with — but BROADER than — the Stage-6
short-read that Candidate A fixed for the un-stretched case.

No architecture change is proposed in this report. The marker boundaries above prove the
current plan/render path cannot yet satisfy "scene length changed + video-original audio"
without an alert; the fix design (plan-builder clamp / re-map of stretched clip windows vs
alert-policy change) is an owner decision and out of scope for this device-gate report.

## Open issues (consolidated)

1. **Scene-length change breaks video-original audio (BLOCKING — S6, S7, S8).** Three
   symptoms (boundary / empty-mix / short-read), one operator-confirmed trigger
   (scene-duration change). The Stage-7 blocking failure.

2. **Start latency (non-blocking — S1, S3, S5).** Audible start is delayed, not instant,
   across music, mix, and video-original. Structural cause from markers: the player does not
   start until the first preroll chunk `0..<48000` (1.0 s @ 48 kHz) is rendered
   synchronously before `player.play.begin`. Exact wall-clock latency is NOT measurable from
   these logs (no per-event wall-clock timestamps around the play path), so no millisecond
   figure is asserted. Not a Stage-7 acceptance criterion.

3. **No crash / no SIGKILL / no legacy fallback anywhere.** Across all eight scenarios
   `fallbackToLegacy=0`, `SIGKILL/jetsam=0`. All failures are fail-closed alerts, never a
   silent legacy fallback and never a crash.

## Confirmations

- No code changed: `git status --porcelain` shows zero `.swift` / `.pbxproj` / `.h` / `.m`
  modifications. Only this report + 8 evidence logs (all untracked).
- `git diff --cached --name-only` is empty (index clean).
- No stage / commit / push performed.
- Tolerance and guard-band were not changed; no architecture change made or applied.

