# Slice 002 — Implementation Report: Pure `AudioEvaluator` + `AudioPlan`

- **Status:** Stages A–C COMPLETE. Closure/evidence pass.
- **Date context:** 2026-06-25.
- **Scope delivered:** the shared `SceneMediaClock` (Stage A), the pure audio value model (Stage B), and
  the I/O-free `AudioEvaluationWindowBuilder` + pure `AudioEvaluator` (Stage C) — all inside
  `AnimiEngineNext/Sources/AnimiEngineCore`. No play/decode/mix/schedule/export and no AVFoundation.
- **Plan of record:** `Docs/AnimiEngineNext/slice-002-implementation-plan.md`.
- **Normative contract:** ADR-012 §1.0a / §1.0b / §2 / §3; roadmap §3.
- **Nothing staged or committed by this slice.**

---

## 1. What was built

| Stage | Delivered | Net effect |
|---|---|---|
| **A** | `Evaluator/SceneMediaClock.swift` — single shared `sceneMediaTime(role:)` + `mediaActiveDomain(sceneIndex:…)`; `TimelineEvaluator` + `ProjectValidator` route through it. Fail-closed `sceneIndex` guard. | One definition of the per-scene media clock; zero video behavior change. |
| **B** | `Audio/` value model: `AudioEvaluationWindow` (+ `AudioWindowScene`, `ResolvedAudioClip`, `AudioClipBinding`, `ResolvedAudioTrack`), `ResolvedAudioSourceDescriptor` (+ `AudioStreamIdentity`, fail-closed `AudioChannelLayoutDescriptor`), `AudioPlan` (+ `AudioSegmentPlan`), `AudioEvaluationError`. | Pure value model, integer/rational only, invalid states unrepresentable. |
| **C** | `Audio/AudioEvaluationWindowBuilder.swift` (resolve exactly-one descriptor, copy video mappings, materialise track order, I/O-free) + `Audio/AudioEvaluator.swift` (exact segment cutting, trim/`.once`/gain/mute, deterministic ordering). | Window→plan evaluation; exact affine source math; preview/export share the plan. |

---

## 2. Builder API and behavior

```swift
public enum AudioEvaluationWindowBuilder {
    public static func build(
        manifest: CanonicalProjectManifest,
        requirement: EvaluationWindowRequirement,
        scenes: [ResolvedScenePayload],
        sourceDescriptors: [ResolvedAudioSourceDescriptor]
    ) throws -> AudioEvaluationWindow
}
```

- I/O-free, no AVFoundation, no `AVAsset`. Uses `requirement.coverage` / `requirement.projectDuration`.
- Builds `AudioWindowScene` from `requirement.sceneSpans` + per-scene following boundary/transition from
  `requirement.transitions`.
- Verifies loaded scene payloads correspond to the required payload IDs (mirrors
  `EvaluationWindowBuilder`: duplicate/unexpected/missing/inconsistent → typed `ProjectValidationError`).
- Resolves every **referenced** source to **exactly one** descriptor — zero → `unresolvedAudioSource`,
  multiple → `ambiguousAudioSource`; selection is independent of descriptor input order. A silent video
  (no clip) requires no descriptor (legitimate silence, not an error).
- `globalAudio` → `.global`. `videoLayerMedia` → resolve the scene payload + layer, require `.video`,
  copy the layer's `VideoBinding.sourceMapping` into `.videoLayer(sceneID:sourceMapping:)`.
- Materialises canonical track order by sorting tracks by `AudioTrackID`.
- Defensive builder-boundary checks only; it does NOT re-run the full `ProjectValidator`.

## 3. Evaluator API and exact segment math

```swift
public enum AudioEvaluator {
    public static func evaluate(window: AudioEvaluationWindow, range: ProjectTimeRange) throws -> AudioPlan
}
```

Pure: window + project tick interval → `AudioPlan`. No `Float`/`Double`/`Decimal`, no approximation, no
AVFoundation, no I/O. Per the ADR-012 §1.0a mapping:

1. Reject `range` outside `window.coverage` → `audioWindowCoverageViolation`.
2. `sampleInterval = AudioSampleRange.from(projectTicks: range)`. Empty → zero segments (valid).
3. Per clip: `activeDest = clip.destination ∩ range` (half-open); empty → zero segments.
4. **Affine source map** (`AffineSourceMap`): `source(T) = anchor + (rn/rd)·(localTicks/240000)`, where
   - **global**: `anchor = sourceTrim.start`, `localTicks = T − destination.start`, rate `1/1`;
   - **video-layer**: `anchor = sourceMapping.trimRange.start`, `localTicks = SceneMediaClock.sceneMediaTime`,
     rate = the layer's `PlaybackRate`. Audio reuses the SAME shared clock + `SourceTimeMapping.target`
     the video evaluator uses; it never builds its own project→scene mapping.
5. **Trim + `.once` gate** (half-open): audible source window =
   `[source(activeDest.start), source(activeDest.end)) ∩ sourceTrim`. Empty → zero segments. `.once`
   stops at the first end reached (earlier of `activeDest.end` and the trim-end crossing); no loop, no
   stretch, no extension.
6. **Exact inversion** (`firstProjectTick`): the affine trim/`.once` boundary maps back to an exact
   project tick via `local_min = ceil(P·rd·240000 / (Q·rn))` using the existing exact `UInt128` 64-bit
   division (`ceilDiv128by64`). Search-free, no floating point — **no new `Time` rational API was
   required**.
7. **Incoming pre-boundary hold**: before a video clip's scene start the media clock is held at `0`, so
   the source does not advance and the audible window collapses → no segment (canonical silence).
8. **Outgoing post-roll**: the outgoing media clock continues past nominal (`T − sceneStart`), so a
   post-roll destination keeps emitting when trim/`.once` allow.
9. Muted clips that are audible are KEPT with `isMuted = true`; gain is copied unchanged. Conversion
   metadata is copied EXACTLY from the clip's resolved `ResolvedAudioSourceDescriptor` carried on
   `ResolvedAudioClip.sourceDescriptor` (`sampleRate`, `channelLayout`, `streamIdentity`) — never
   synthesized by the evaluator. The builder attaches the exactly-one descriptor to each resolved clip.
   The track role is fail-closed: a clip whose `trackID` has no track throws
   `inconsistentResolvedBinding` (no `.music` fallback).
   **Inverse math is fail-closed:** `firstProjectTick`/`ceilDiv128by64` use overflow-checked
   `multipliedReportingOverflow`/`addingReportingOverflow` and require every quotient to fit `Int64`
   exactly — any non-fitting intermediate or result throws `audioTimeMathOverflow`. No `&*`/`&+`, no
   `clamping:`, no `quotient.low` truncation.
10. **Deterministic ordering**: `(track.order, destinationSamples.start, clipID.raw, sourceID.raw)` —
    canonical track order from the builder, never dictionary/completion order.

## 4. Files (whole Slice 002)

New production (`Sources/AnimiEngineCore`): `Evaluator/SceneMediaClock.swift`,
`Audio/AudioEvaluationWindow.swift`, `Audio/ResolvedAudioSourceDescriptor.swift`, `Audio/AudioPlan.swift`,
`Audio/AudioEvaluationError.swift`, `Audio/AudioEvaluationWindowBuilder.swift`, `Audio/AudioEvaluator.swift`.

Modified production (Stage A, behavior-preserving): `Evaluator/TimelineEvaluator.swift`,
`Project/ProjectValidator.swift`.

New tests (`Tests/AnimiEngineCoreTests`): `SceneMediaClockTests`, `AudioPlanModelTests`,
`AudioEvaluationWindowBuilderTests`, `AudioEvaluatorTests`.

Docs: `slice-002-implementation-plan.md`, `slice-002-implementation-report.md` (this file).

## 5. Test results

```
swift test --filter AnimiEngineCoreTests
→ Executed 362 tests, with 1 test skipped and 0 failures (0 unexpected)

swift test --filter PostPromotionMatrixRegressionTests
→ testLiveMatrixIsExactMatchAgainstApprovedReferenceData passed (321.242 s)
→ POST-PROMOTION-MATRIX exactMatch=84/84
```

(The Stage-C fix — descriptor metadata + fail-closed inverse math — touched only `Audio/*.swift` and
their tests, no render path, so the render matrix was not re-run for it; its last run remains valid.)

The 1 Core skip is a pre-existing skipped test, unrelated to audio.

## 6. Pixel `ReferenceData` unchanged — evidence

Slice 2 touches no render path. Proven by the render regression gate + tree hash:

- **ReferenceData tree (files):** 85.
- **Tree hash BEFORE:** `a37980f2aa84313436cb433f585855b570bf994470455b7f1bed603cf29213bb`.
- **Tree hash AFTER:** `a37980f2aa84313436cb433f585855b570bf994470455b7f1bed603cf29213bb`.
- **Identical:** YES — no PNG promoted/changed; `ReferenceData` git status clean.

## 7. Scope guarantees

No file changed under any forbidden path: `AnimiApp/`, scheduler/export/preview, AVFoundation/AVFAudio,
TVECore, Metal/RenderGraph, `Package.swift`, `*.xcodeproj`, `ReferenceData/`. The pre-existing
`AnimiApp.xcscheme` and `6_frames_template/` entries are session-start snapshot state, never touched.
A whole-text sweep confirms the new `Audio/*.swift` contain no `Float`/`Double`/`Decimal` and no
`import AVFoundation`/`import AVFAudio`.
