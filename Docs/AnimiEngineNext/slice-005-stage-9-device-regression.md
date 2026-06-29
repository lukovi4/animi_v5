# Slice 005 — Stage 9 device regression matrix (commit 5819848f)

Device validation of commit `5819848f6fce92d255429eccbc6601602a28ddbd`
("Fix canonical preview audio continuity and startup latency") on iPhone 13 Pro
(`86C5CAA4-23E9-5EDB-BBE1-C11DAE59FF39`). Flags
`-DebugPreviewAudioWithNextEngine YES -DebugMemoryDiagnostics YES`. No code changed.

## Preflight
- HEAD == `5819848f6fce92d255429eccbc6601602a28ddbd` ✓
- `git diff --cached --name-only` empty ✓
- Device Debug build SUCCEEDED, installed ✓

## Matrix result: **STOPPED at S9.2 (FAIL)** — per the Stage-9 rule (any scenario fails → stop,
preserve log, classify, do NOT fix in this task).

| # | Scenario | Verdict | Log |
|---|---|---|---|
| 1 | music-only | **PASS** | `evidence/slice-005-stage9-01-music-only.log` |
| 2 | video-original-only (+ scene stretch) | **FAIL** | `evidence/slice-005-stage9-02-video-original-only.log` |
| 3–9 | (not run — matrix stopped at S9.2) | — | — |

## S9.1 — music-only — PASS
Log: `slice-005-stage9-01-music-only.log` (1063 lines). Operator: music audible to end, no alert.

| Marker | Count |
|---|---|
| fallbackToLegacy=1 / errorAlert / nextChunk.failed / pcmRenderFailed / shortfall / s8.shortReadProbe / SIGKILL / jetsam | 0 |
| canonical.selected | 1 |
| canonical.legacyGateBypassed | 2 |
| canonical.render.end | 61 |
| graph.schedule.end | 4 |
| engine.start.end | 2 |
| player.play.end | 4 |
| nextChunk.schedule.end | 59 |
| nextChunk.endOfPlan | 2 |

All required markers present, zero failures → **PASS**.

## S9.2 — video-original-only — FAIL

Operator action: opened project, added video, **stretched the scene** → alert, audio dropped.

Log: `slice-005-stage9-02-video-original-only.log` (1117 lines).

First failing marker (line 385):
```
preview.audio.stage7.s8.shortReadProbe | path=serveContiguous
  source=app.audio.source.videoLayer:scene-0-B045FD1B-456B-4067-AC5C-99FEA19F7DC6:block_01
  reqSourceStart=56/5 (=11.2s) requestedFrameCount=48000 decodedFrames=32733
  sessionCursor=56/5 framesRemainingInWindow=379200
  error=pcmRenderFailed("decode produced 32733 frames, expected 48000 (shortfall 15267 > tolerance 1024)")
line 386: preview.audio.canonical.nextChunk.failed | pcmRenderFailed(... shortfall 15267 ...)
line 387: preview.audio.canonical.errorAlert | pcmRenderFailed(... shortfall 15267 ...)
```
Repeats: lines 481, 808, 914, 1085 (shortfall 36066 / 23266 / 12066 / 47266).

| Marker | Count |
|---|---|
| errorAlert | 3 |
| nextChunk.failed | 5 |
| pcmRenderFailed | 13 |
| shortfall | 13 |
| s8.shortReadProbe | 5 |
| fallbackToLegacy=1 | 0 |
| incomingAudioBeforeBoundary | 0 |

### Classification — Layer: decoder / plan boundary (NEW root, NOT covered by Stage-8.1)

**This is a short-read on the `serveContiguous` path, and the renderer did NOT clamp it.** The probe
shows `requestedFrameCount=48000` — i.e. `BackgroundCanonicalPCMRenderer` asked for the FULL chunk,
its Stage-8.1 `framesAvailable(... to: segment.sourceEnd ...)` clamp did NOT reduce the request.

Why the Stage-8.1 clamp missed this:
- Stage-8.1 clamps `decodeFrameCount` to `segment.sourceEnd` (the plan's declared source end).
- Here the request was NOT reduced (48000 asked) → `segment.sourceEnd` for this clip is GREATER than
  the source's REAL audio track length. The decoder hit the actual end-of-track at ~32733 frames and
  short-read.
- Consistent with the known code fact: the video-original descriptor's `sourceDuration` is set to
  `winEnd` — an EXACT LOWER BOUND on the real source duration, NOT the true track length
  (`AppVideoOriginalAudioBridge`: "sourceDuration = winEnd lower bound"). After the scene is
  stretched, the destination maps a chunk whose `sourceEnd` (derived from that lower-bound duration /
  trim) exceeds the actual audio track, so clamping to `sourceEnd` still over-requests.

**Distinct from Stage-8.1's fixed case:** Stage-8.1 fixed the `openSessionAndServe` over-map where
`sourceEnd` was the true end. This failure is on `serveContiguous` with `sourceEnd` LARGER than the
real track — the clamp's reference value itself is too high. The real audio track length is not known
to the renderer/plan synchronously (the descriptor carries only the `winEnd` lower bound), so a
`sourceEnd`-based clamp cannot bound a source that is actually shorter than `winEnd`.

| Failure-protocol item | Fact |
|---|---|
| First failing marker | `s8.shortReadProbe path=serveContiguous` (line 385) |
| Exact log line | `decode produced 32733 frames, expected 48000 (shortfall 15267 > tolerance 1024)` |
| Layer | decoder / plan boundary (source's real audio track shorter than the plan's `sourceEnd`) |
| Renderer clamp engaged? | NO — `requestedFrameCount=48000` (full chunk asked; `sourceEnd` ≥ real track) |
| fallbackToLegacy | 0 (fail-closed, not legacy) |
| Operator | alert shown; audio dropped (did not reach end) |

→ **FAIL.**

## Final verdict: **FAIL** (matrix stopped at S9.2)

Commit `5819848f` does NOT pass the Stage-9 device regression: S9.1 passes, but S9.2 (video-original
with a stretched scene) reproduces a short-read on `serveContiguous` because the plan's
`segment.sourceEnd` exceeds the source's real audio track length, so the Stage-8.1 `sourceEnd` clamp
does not bound the request. This is a NEW, distinct root from the Stage-8.1 fix (which addressed the
`openSessionAndServe` over-map where `sourceEnd` was the true end).

No fix attempted in this task (per Stage-9 rule). The captured probe values
(`reqSourceStart`, `requestedFrameCount=48000`, `decodedFrames`, `sessionCursor`,
`framesRemainingInWindow`, exact shortfall) are exactly what a follow-up fix needs: the clamp must be
bounded by the source's ACTUAL audio track length, not the `winEnd`-lower-bound `sourceEnd` — which
requires obtaining the real track duration (an async/asset probe), NOT a tolerance change.

## Confirmations
- No code changed during Stage 9 (`git status` shows no new `.swift`/`.pbxproj` modifications beyond
  the committed set; only this report + 2 Stage-9 evidence logs are new/untracked).
- `git diff --cached --name-only` empty.
- No stage / commit / push performed.
- No tolerance / guard-band / sessionWindowFrames / maxBoundaryShortfallFrames change; no
  export/visual/legacy/AnimiEngineCore change.
