# Slice 005 — Canonical Preview No-Audio Regression: Fix Report

**Status:** canonical direct-start + safety fallback implemented and **device-verified by markers**;
video-original canonical audio remains blocker; Slice 005 canonical cutover is **not complete**.

⚠️ **Device audible smoke FAILED — but NOT due to this fix.** A/B on iPhone 13 Pro shows preview audio is
silent with the toggle **ON and OFF** on the same video+music project. Toggle OFF runs zero Slice-005 code
(0 canonical markers) yet is equally mute → the silence is a **pre-existing legacy-renderer fault**
(`readiness=preparing` never → `primed`; `Reader failed: Operation Interrupted` on `sessionDeactivate`
mid-render), **independent of Slice 005**, owner-deferred. See
[`slice-005-device-smoke-diagnosis.md`](slice-005-device-smoke-diagnosis.md) with A/B evidence
(`evidence/slice-005-device-{ON,OFF}.markers.txt`).

Unit gates green; device build green (iPhone 13 Pro). No stage/commit/push. Codex review: accepted as
no-sound regression fix, not final canonical cutover. **Do NOT report "no-sound fixed" end-to-end** — the
user still hears nothing because the legacy fallback target is itself mute on device.

---

## Real root cause (the earlier "sink fix" was necessary but NOT the cause)

With `DebugPreviewAudioWithNextEngine` ON, the canonical controller was **embedded inside the legacy
orchestration** in `EditorRuntimePreviewAudioCoordinator`. Canonical's `startPlayback` was reachable
ONLY through the legacy build gate (`.pipeline(...)` → `installCallbacks` + `replacePipeline`). The
legacy plan is built by `EditorRuntime.buildAudioExportPlan`, which iterates ONLY `timeline.audioTracks`,
skips `.bundled`, and never adds video-original audio.

- **Sub-case A (the silent one):** a project whose audio is bundled / video-original only → empty legacy
  plan → `buildPipeline` returns `.noResolvableAudio` → that branch set `dirty=false` and **never called
  `replacePipeline`** → canonical **never started** → silence, and `onCanonicalUnavailable` never got a
  chance (it only fires on a canonical throw that never ran).
- **Sub-case B (video+music):** legacy plan non-empty (music) → canonical started →
  `RuntimeCanonicalAudioPlanSource` threw `videoLayerOriginalAudioUnsupportedInStageA` → fallback already
  worked.

The previously-added `AVAudioEnginePreviewSink` bring-up (`engine.start()` + `outputPlayer.play()`) is
**real and correct**, but execution never reached the sink in Sub-case A.

> NOTE for the lead: those sink edits are **uncommitted in the working tree** (committed HEAD lacks them),
> which is why `git show HEAD:…PreviewAudioGraph.swift` appears to have no `engine.start()`. The working
> tree DOES (`PreviewAudioGraph.swift` `startIfNeeded()` — see Acceptance 5).

---

## The fix (R1–R6 implemented; R7 reported as blocker)

1. **R2 — Canonical direct start, NO legacy build gate.** A new early branch in
   `startForTimelinePlayback()`: when the toggle is ON and the installed controller is canonical, it calls
   `controller.startPlayback(fromSeconds: <playhead>, hostTime: …)` **directly**. `buildPipeline` /
   `buildAudioExportPlan` / `startBuild` are NOT executed on this path. Canonical evaluates its OWN
   `AudioPlan` via `RuntimeCanonicalAudioPlanSource`. **No fake `BuiltAudioPipeline`, no
   `primeForDirectStart`.** Idle-prepare also skips the legacy build on the canonical path.
2. **R3 — Lazy-var stale-cache removed.** `controller` is a plain `var` (cheap legacy default);
   `selectControllerForToggle()` deterministically picks the controller for the CURRENT toggle at
   start/prepare entry, rebuilding only on a type change. Test-injected controllers are pinned
   (`controllerWasExplicitlyInjected`) and never clobbered. Selected controller type is logged.
3. **R4 — First-frame signal hardened.** `displayLinkFired` emits `firstFrameSignal` when canonical
   receives the signal and `firstFrameSkipped` when the cast is nil — the nil-cast no longer silently
   skips. DEBUG-only is documented (Release always uses legacy, which has no first-frame gate).
4. **R5 — Silent-epoch-with-audio → fallback.** The controller takes a `projectHasAudio` predicate. If
   canonical evaluates to no plan but the project genuinely HAS audio (imported/bundled music OR
   video-original), it throws → `onCanonicalUnavailable` → legacy fallback, never silence over real audio.
   A genuinely audio-free project stays a legitimate silent epoch.
5. **R6 — Fallback is safety only.** The one-shot `onCanonicalUnavailable → fallBackToLegacyPreviewAudio`
   swaps to legacy and restarts. The user never gets silence while legacy could play. Fallback does NOT
   count as canonical cutover complete.

### R7 — REMAINING BLOCKER (explicit)
`RuntimeCanonicalAudioPlanSource` does **not** represent **video-original audio** in the canonical
`AudioManifest`/`AudioPlan`/decode path (it throws `videoLayerOriginalAudioUnsupportedInStageA`;
`buildManifest(..., includeOriginalFromVideoSlots: false)`). This patch does NOT implement it — it needs
the async scene-data pipeline. For projects with video-original audio the **legacy fallback** provides
sound. **Canonical cutover / device gate is therefore NOT complete.**

---

## Before / after call graph (toggle ON, Play)

**Before (Sub-case A, silent):**
`startForTimelinePlayback → startBuild → buildPipeline → runtime.buildAudioExportPlan (empty) →
.noResolvableAudio → dirty=false` ❌ (replacePipeline NOT called) → canonical never starts → **silence**.

**After:**
`startForTimelinePlayback → selectControllerForToggle (canonical) → [legacyGateBypassed] →
controller.startPlayback(fromSeconds: playhead) → prepareCanonicalEpoch (evaluate own AudioPlan) →
PENDING; render path → signalFirstFrameReady → scheduleInitialAudioPreroll → session.start →
sink.scheduleMixed → startIfNeeded (engine.start + outputPlayer.play) → scheduleBuffer` → **audible**.
On a silent-epoch-with-audio / canonical throw → `onCanonicalUnavailable → fallBackToLegacyPreviewAudio`
→ **legacy plays** (never silence). Toggle OFF → the legacy build path runs byte-for-byte unchanged.

---

## Hard acceptance (proven)

| # | Acceptance | Proof |
|---|---|---|
| 1 | toggle ON calls `CanonicalPreviewAudioController.startPlayback` directly | `CanonicalCutoverBypassTests.test_toggleON_callsCanonicalStartPlaybackDirectly_withoutLegacyBuildGate` |
| 2 | legacy build gate NOT executed on canonical path | same test (spy `previewAudioPipelineBuilder` NOT invoked) |
| 3 | toggle OFF legacy path unchanged | `test_toggleOFF_runsLegacyBuildPath_unchanged` + `ProjectAudioPreviewPlaybackTests` 61 executed, 1 skipped, 0 failures |
| 4 | canonical failure / silent-epoch-with-audio → legacy, not silence | `CanonicalPreviewAudioControllerTests.testSilentEpochWithProjectAudioFiresFallbackNotSilence` (+ complement) |
| 5 | sink physically starts engine/player | `CanonicalPreviewAudioChainTests.testRealAVSinkStartsEngineAndPlayer`; code: `PreviewAudioGraph.swift` `startIfNeeded()` |
| 6 | tests prove all above | suites below |
| — | no lazy stale-cache | `test_noLazyStaleCache_selectionReflectsToggleAtStart`, `test_injectedControllerNotClobberedByReselection` |

---

## Tests run (gates, simulator iPhone 17 Pro)

**App gate — green:**
- `CanonicalCutoverBypassTests` **5/0** (incl. the new production-selection test).
- `CanonicalPreviewAudioControllerTests` **20/0**; `CanonicalPreviewAudioChainTests` **6/0`.
- Legacy `ProjectAudioPreviewPlaybackTests` **61 executed, 1 skipped, 0 failures** (toggle OFF
  byte/behaviour unchanged).
- (also green earlier: `PreviewAudioToggleSelectionTests` 4/0, `RuntimeCanonicalAudioPlanSourceTests` 8/0.)

**Core realtime gate — green (83/0 total):**
- `PreviewAudioGraphContractTests`, `AudioMasterPreviewSessionTests`, `SilentScrubAudioTests`,
  `InterruptionRouteChangePauseOnlyTests`, `AudioSessionAdapterContractTests` — all pass (sink change clean).

**Device build:** iPhone 13 Pro (`00008110-000C59C20A20401E`) `** BUILD SUCCEEDED **`.

**Index:** empty (0 staged). No stage/commit/push.

## Changed files (complete — future commit scope)

Source:
- `AnimiApp/Sources/Editor/EngineBridgeDiagnostics.swift` — the `DebugPreviewAudioWithNextEngine` toggle.
- `AnimiApp/Sources/EditorRuntime/EditorRuntimePreviewAudioCoordinator.swift` — canonical direct-start
  branch, `selectControllerForToggle`, non-lazy controller, OFF-select diagnostic, fallback wiring.
- `AnimiApp/Sources/EditorRuntime/EditorRuntime.swift` — first-frame diagnostics; pin test injection.
- `AnimiApp/Sources/EditorRuntime/Realtime/CanonicalPreviewAudioController.swift` — `projectHasAudio`
  dep + silent-epoch-with-audio fallback.
- `AnimiApp/Sources/EditorRuntime/Realtime/CanonicalPreviewAudioControllerFactory.swift` — wire
  `projectHasAudio` from runtime.
- `AnimiApp/Sources/EditorRuntime/Realtime/*` (the Stage-C/C.5 realtime files: plan source, manifest/
  evaluation bridges, chunk preparer, PCM decoder, session adapter — untracked, part of Slice 005).
- `AnimiEngineNext/Sources/AnimiEngineCore/Realtime/PreviewAudioGraph.swift` — sink `startIfNeeded()`
  (engine.start + player.play, churn-guarded, explicit `AVAudioTime`, no `at: nil`).

Project / build:
- `AnimiApp/AnimiApp.xcodeproj/project.pbxproj` — xcodegen registration of the realtime files + tests.

Tests:
- `AnimiApp/Tests/CanonicalCutoverBypassTests.swift` — **NEW** (coordinator-seam cutover proofs).
- `AnimiApp/Tests/CanonicalPreviewAudioControllerTests.swift` — +2 (silent-epoch-with-audio fallback +
  complement) + `projectHasAudio` helper param.
- `AnimiApp/Tests/CanonicalPreviewAudioChainTests.swift` — structural sink start test.
- (Slice-005 Stage-C test files: `RuntimeCanonicalAudioPlanSourceTests`, `PreviewAudioToggleSelectionTests`,
  `AppAudio*Tests`, `RealtimeAudioSessionEventMappingTests` — untracked.)

Docs:
- `Docs/AnimiEngineNext/slice-005-no-audio-regression-fix.md` — this report.

## New test added (exact)

`CanonicalCutoverBypassTests.test_toggleON_productionSelection_directBranch_noLegacyBuilder` — toggle ON,
NO injected controller; a `previewAudioPipelineBuilder` spy that flips if the legacy build runs; after
`startForTimelinePlayback()` it asserts the controller IS `CanonicalPreviewAudioController` AND the legacy
builder was NOT invoked — closing `toggle ON → selectControllerForToggle() → canonical direct start → no
buildPipeline/buildAudioExportPlan` on the real production selection seam.

## Status line

**no-sound regression fixed via canonical direct start + safety fallback; video-original canonical audio
still remaining blocker.** Slice 005 / canonical cutover is **NOT** marked complete.

## Device smoke — DONE (markers green; audio FAILED via separate legacy fault)

Ran on iPhone 13 Pro, toggle ON and OFF (A/B). **Marker path verified** (canonical select →
legacyGateBypassed → startPlayback.call → startFailed videoLayerOriginal… → fallbackToLegacy →
firstFrameSkipped). **Audio NOT audible** — and the OFF control is equally mute → the cause is the legacy
preview-audio renderer failing on device (`preparing`→never `primed`; `Reader failed: Operation
Interrupted`), **independent of this fix**. Full A/B writeup + evidence:
[`slice-005-device-smoke-diagnosis.md`](slice-005-device-smoke-diagnosis.md).

## Outstanding (owner-deferred)
Legacy preview-audio render fault (the fallback target is mute on device, reproduced with the toggle OFF)
— a separate, pre-existing work item. Slice 005 cannot deliver audible preview on a video+music project
until that legacy render is fixed.
