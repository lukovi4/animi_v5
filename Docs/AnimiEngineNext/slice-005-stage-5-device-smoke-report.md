# Slice 005 Stage 5 — Device Smoke Report (Canonical Preview Audio)

**Audience:** Lead / reviewer
**Device:** physical iPhone 13 Pro (`iPhone14,2`, "iPhone Evgeny", id `00008110-000C59C20A20401E`)
**Build:** signed Debug, this branch, derivedData `/tmp/animi-stage5-device`
**Toggles:** `-DebugPreviewAudioWithNextEngine YES -DebugMemoryDiagnostics YES`
**Test project:** video clip with original audio + music track
**Operator:** confirmed audible output by ear (see §4)
**Status:** **PASS for Stage-5 scope** (canonical preroll path is audible end-to-end on device, no legacy fallback) — **one in-scope code fix applied** (justified by a logged device blocker) — **one follow-up surfaced** (continuous playback, out of Slice-005 Stage 1–5 scope).

Raw evidence (committed to repo, not staged):
- `Docs/AnimiEngineNext/evidence/slice-005-device-stage5-raw.log` — first run (FAIL, pre-fix)
- `Docs/AnimiEngineNext/evidence/slice-005-device-stage5-fixed.log` — second run (canonical path complete)

---

## 1. Preflight (host-side, before device run)

| Check | Method | Result |
|---|---|---|
| Index empty | `git diff --cached --name-only` | ✅ empty |
| Factory default builds `CachedCanonicalAudioRenderPipeline` | `rg` on `CanonicalPreviewAudioControllerFactory.swift` — `makeProductionRenderPipeline()` returns `CachedCanonicalAudioRenderPipeline(cache:)` | ✅ |
| No `Unavailable` default param | `rg "CanonicalAudioRenderPipeline = UnavailableCanonicalAudioRenderPipeline()"` | ✅ none (survives only as fail-closed catch fallback) |
| AV decode confined | `rg -l "AVAssetReader(|copyNextSampleBuffer|cancelReading"` across `Realtime/` | ✅ only `AVFoundationPCMAssetDecoder.swift` |
| Build for physical device | `xcodebuild build -destination 'platform=iOS,id=…'` | ✅ **BUILD SUCCEEDED** |
| Install | `xcrun devicectl device install app` | ✅ `com.animi.app` installed |

---

## 2. First device run — FAIL (pre-fix), precisely localized

Operator pressed Play; audio played briefly then stopped. The log (`…-raw.log`) shows the canonical path
started correctly but the **decoder** rejected the bounded chunk and the app auto-fell-back to legacy:

```
preview.audio.canonical.selected            controller=CanonicalPreviewAudioController
preview.audio.canonical.legacyGateBypassed
preview.audio.canonical.startPlayback.call  seconds=0.0
preview.audio.canonical.plan                segments=1
preview.audio.canonical.preroll.build.begin range=0..<48000
preview.audio.canonical.render.begin        ← last successful marker
preview.audio.canonical.preroll.build.failed error=pcmRenderFailed("decode produced 47948 frames, expected 48000")
preview.audio.canonical.fallbackToLegacy     reason=pcmRenderFailed(...)   ← audio heard was LEGACY, not canonical
```

- **Last good marker:** `preview.audio.canonical.render.begin`
- **First error marker:** `preview.audio.canonical.preroll.build.failed`
- **Failing component:** `AVFoundationPCMAssetDecoder` (exact-frame-count guard inside `WatchdogPCMDecodeLoop`).
- **Root cause:** requested exactly `48000` mono frames (1 s @ 48 kHz); `AVAssetReader` over the exact
  `CMTimeRange` returned `47948` (**52 short**). Compressed sources (AAC/MP3) carry encoder priming / gapless
  padding, so a bounded reader returns a handful fewer frames at the boundary. The Stage-3 strict contract
  ("exactly `frameCount` or throw") rejected this and routed to legacy. This is **exactly risk R2** flagged in
  the accepted Stage-3 plan (`slice-005-stage-3-background-pcm-renderer-plan.md`, §12), and is the class of
  defect simulator unit tests could not catch (the fixture decoder always returns the exact length).

Per the brief this is a *real, logged blocker* — the one condition under which a code change is permitted.
**Legacy fallback was NOT counted as success.**

---

## 3. Fix applied (minimal, justified by the log)

File: `AnimiApp/Sources/EditorRuntime/Realtime/AVFoundationPCMAssetDecoder.swift`

Added a named boundary short-read reconciliation in `WatchdogPCMDecodeLoop` (replacing the bare
`samples.count == frameCount` guard):

- `maxBoundaryShortfallFrames = 1024` (≈ 21 ms @ 48 kHz — above any priming tail, far below "lost audio").
- `reconcileFrameCount(_:frameCount:)`:
  - exact → return as-is;
  - over-read → trim to `frameCount`;
  - short by **≤ tolerance AND non-empty** → zero-pad the tail to exact `frameCount` (the missing boundary
    samples are genuine boundary silence; the decoded body is untouched — NOT a silent substitution for
    audible content);
  - short by **> tolerance**, or **empty** for a non-empty request → still **fail closed** `.pcmRenderFailed`.

The bounded-chunk contract (`samples.count == frameCount`, `chunk.key == requestedKey`) is preserved; the
fail-closed guarantee for genuine decode faults is preserved.

**Tests (simulator):** added 5 unit tests to `AVFoundationPCMAssetDecoderWatchdogTests` covering exact /
over-read / short-within-tolerance (the exact 47948→48000 device case) / short-beyond-tolerance / empty.
Targeted run: `AVFoundationPCMAssetDecoderWatchdogTests` + `BackgroundCanonicalPCMRendererTests` →
**30 tests, 0 failures**. No other Stage-1–4 contracts changed.

---

## 4. Second device run — canonical path complete (PASS for scope)

Rebuilt + reinstalled the fixed build; operator pressed Play on the same project. Evidence
(`…-fixed.log`), two Play sessions captured:

```
# Play #1 (lines 42–117)
preview.audio.canonical.selected            controller=CanonicalPreviewAudioController
preview.audio.canonical.legacyGateBypassed
preview.audio.canonical.startPlayback.call  seconds=0.0
preview.audio.canonical.plan                segments=3
preview.audio.canonical.preroll.build.begin range=0..<48000
preview.audio.canonical.render.begin        segments=3 range=0..<48000
preview.audio.canonical.render.end          sources=1          ← decoder OK (no short-read failure)
preview.audio.canonical.preroll.build.end   sourceCount=1
preview.audio.canonical.graph.schedule.begin / .end
preview.audio.canonical.engine.start.begin / .end
preview.audio.canonical.player.play.begin / .end
preview.audio.canonical.scheduled           scheduled=1 sources=1 started=1

# Play #2 (lines 182–198): segments=4 → render.end sources=2 → scheduled started=1
```

**No `preroll.build.failed`. No `fallbackToLegacy`. No `render.unavailable`.** The audio the operator heard
is the **canonical path** (`AudioPlan → CachedCanonicalAudioRenderPipeline → CanonicalPCMRenderCache →
BackgroundCanonicalPCMRenderer → AVFoundationPCMAssetDecoder → PreviewAudioGraph → AVAudioEngine`), proven
by the full marker chain, not legacy.

### Pass-criteria scorecard

| # | Criterion | Result | Evidence |
|---|---|---|---|
| 1 | App builds/installs/runs on physical iPhone | ✅ | BUILD SUCCEEDED + install + launch |
| 2 | Toggle ON selects `CanonicalPreviewAudioController` | ✅ | `…selected controller=Canonical…` (L42) |
| 3 | Legacy build gate bypassed | ✅ | `…legacyGateBypassed` (L102/182) |
| 4 | Canonical plan has non-empty segments (video audio + music) | ✅ | `plan segments=3` / `segments=4` |
| 5 | PCM render starts and ends | ✅ | `render.begin`→`render.end` (L108–109, L186–190) |
| 6 | Preroll produces `PreviewMixSource` count > 0 | ✅ | `preroll.build.end sourceCount=1` / `=2` |
| 7 | Graph schedules audio | ✅ | `graph.schedule.begin/end` (L111–112, L192–193) |
| 8 | Engine/player start markers appear | ✅ | `engine.start.*` + `player.play.*` (L113–117) |
| 9 | Operator hears audio | ✅ (then stops — see §5) | operator confirmation + `scheduled started=1` |
| 10 | Scrub silent; Play re-schedules | ⏳ not separately exercised | (deferred — see §5/§6) |
| 11 | Pause stops audio | ◑ partial | `playback.audio.stop.begin` (L126/206) on stop |
| 12 | Route/new-device pause-only, no auto-resume | ⏳ not exercised | (deferred — see §6) |

---

## 5. Observed behavior: audio plays ~1 s then stops (NOT a regression / NOT fallback)

Operator reported "sound played then disappeared after a second." This is **expected for the current
implementation scope**, not a defect of the canonical path:

- The canonical controller schedules exactly **one bounded preroll chunk** (`range=0..<48000` = **1 second**).
- After that single chunk plays out, there is **no mechanism to render/schedule the next chunk** (chunk N+1,
  N+2, …). Stage 1–4 implemented only `prepareInitialPreroll` (the first bounded preroll) — there is no
  rolling/continuous feeder yet.
- The log confirms a clean stop (`playback.audio.stop.begin`), **not** an error, **not** a fallback, **not**
  an underrun crash.

So: the new architecture is proven to produce real, audible output on device; it currently covers only the
initial 1-second preroll window.

---

## 6. Follow-up (out of Slice-005 Stage 1–5 scope) — recommended next stage

**Continuous canonical playback.** A new stage is required to feed successive bounded chunks as playback
advances (rolling preroll / `scheduleNextChunk` driven by the audio clock), so canonical preview plays
beyond the first second. This touches `PreviewAudioGraph` scheduling + the controller's clock-driven pull and
is a deliberate, separate piece of work — it was never part of Stage 1–5 (preview-preroll wiring). Pass
criteria 10 and 12 (scrub re-schedule, route pause-only across chunk boundaries) are best validated together
with that stage, since they concern ongoing scheduling, not the one-shot preroll.

---

## 7. Constraints honored

- No export changes. No `AnimiEngineCore` changes (the log proved the decoder boundary, not a core/sink
  fault, so none were warranted). No legacy-renderer logic changes.
- The only production edit is the decoder boundary short-read reconciliation (§3), justified by the §2 logged
  blocker.
- AV decode remains confined to `AVFoundationPCMAssetDecoder.swift`; controller/factory free of the decode API.
- **Nothing staged / committed / pushed** — `git diff --cached --name-only` empty throughout.
- No device behavior was claimed without operator/marker evidence; legacy fallback was never counted as a pass.

---

## 8. Recommendation to lead

1. **Accept Stage 5** as PASS for its scope: canonical preview audio is audible end-to-end on a physical
   device with no legacy fallback, and the R2 boundary short-read defect found on device is fixed + unit-tested.
2. **Authorize a new "continuous canonical playback" stage** to address the 1-second cutoff (§5/§6) and to
   complete device criteria 10/12 under ongoing scheduling.
3. Review the one-line tolerance value (`maxBoundaryShortfallFrames = 1024`) — chosen conservatively; adjust
   if a stricter/looser boundary policy is preferred.
