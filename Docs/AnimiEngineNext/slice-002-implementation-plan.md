# Slice 002 — Implementation Plan: Pure `AudioEvaluator` + `AudioPlan`

- **Status:** PREFLIGHT / PLANNING PASS ONLY — no production or test code written this step.
- **Author role:** planning agent (no code authority until this plan is approved).
- **Date context:** 2026-06-25.
- **Scope:** a pure, I/O-free, AVFoundation-free `AudioEvaluator` that consumes an immutable
  `AudioEvaluationWindow` + an exact half-open project sample interval and returns a deterministic
  immutable `AudioPlan`. Plus the value model (`AudioEvaluationWindow`, descriptors, `AudioPlan`,
  `AudioSegmentPlan`) and an I/O-free `AudioEvaluationWindowBuilder`. **No** play/decode/mix/schedule/
  export/AVFoundation/Metal code.
- **Governing contracts read in full:** roadmap §3 (Slice 2), ADR-012 §1.0a / §1.0b / §2 / §3,
  slice-001-canonical-audio-schema, `slice-001-implementation-report`. Source read in full:
  `TimelineEvaluator.swift`, `TransitionMath.swift`, `EvaluationWindow.swift`,
  `EvaluationWindowBuilder.swift`, `EvaluationWindowRequirement.swift`, `AudioManifest.swift`,
  `AudioSampleRange.swift`, `SourceTimeMapping.swift`, `ProjectValidator.swift` (audio section +
  `mediaActiveDomain` + `TransitionHalves`).

> Authority order applied: approved product rules + decision-register → accepted ADRs →
> architecture-proposal + validation-contract → roadmap → audits.

---

## 1. Readiness verdict

**Verdict: READY (with one mandatory refactor gated into Stage A).**

Every primitive Slice 2 needs already exists and is exact-integer / exact-rational:

- `sceneMediaTime` math exists as `TransitionMath.outgoingSceneTime` / `incomingSceneTime` and the
  sole-scene `T − sceneStart` line in `TimelineEvaluator.evaluate` — but it is currently **inlined**
  in `TimelineEvaluator`, not a callable shared helper. ADR-012 §1.0b is explicit: "`TimelineEvaluator`
  and `AudioEvaluator` MUST use **one shared helper** to derive the per-scene media-active domain and
  `sceneMediaTime`; the math is defined once and not duplicated." → **this is the only required
  refactor**, and it is the reason Stage A exists.
- `VideoBinding.sourceMapping.target(for:)` already maps a `ScenePlaybackTime` to an exact
  `RationalSourceTime` (`SourceTimeMapping.swift`). Video-layer audio reuses it verbatim — no audio
  mapping is created (§1.0a item 4).
- The media-active-domain math exists as `ProjectValidator.mediaActiveDomain` (manifest-level, no
  payloads). Slice 2 reuses the *same* domain definition; the shared helper must subsume both the
  validator's manifest-level domain and the evaluator's per-instant `sceneMediaTime` so they cannot
  drift.
- `AudioSampleRange.from(projectTicks:)` + `AudioSampleGrid.ceilDiv5` give the exact 48 kHz half-open
  sample interval, empty-allowed (Slice 1).
- `AudioGain` (integer 0…1_000_000), `AudioManifest` value types, roles, `.once`, `isMuted` — all from
  Slice 1, unchanged.
- `RationalSourceRange.contains` / `RationalSourceTime` `Comparable` give the exact `sourceTime ∈
  sourceTrim` gate (§1.0a item 6).

**No `Float`/`Double` anywhere in the path.** All segment math is exact integer ticks → exact sample
indices, and exact rational source time. Gain stays integer raw.

**No contradiction found** between roadmap §3, ADR-012 §1.0a/§1.0b/§3, and the Slice-1 schema/validation
already shipped. The §2 "no implicit ramps / mix both active scenes" rule is satisfied structurally by
emitting one segment per (clip, active scene-role) with no gain automation invented by the evaluator.

---

## 2. New types required

### 2.1 Shared `sceneMediaTime` helper (Stage A — the gating refactor)

`Evaluator/SceneMediaClock.swift` (NEW). A pure enum owning the single definition of:

1. **`sceneMediaTime(role:, at T:, sceneStart:, boundary:)` → `ScenePlaybackTime`** — exactly the §1.0a
   item-4 mapping, lifted *verbatim* from the lines currently inlined in `TimelineEvaluator` /
   `TransitionMath`:
   - sole / outgoing: `T − sceneStart` (continues past nominal — post-roll, never frozen);
   - incoming: `0` while `T < B`; `T − B` while `T ≥ B`.
2. **`mediaActiveDomain(sceneIndex:, scenes:, boundaryTransitions:)` → `(start, end)`** — the manifest-
   level half-open domain currently in `ProjectValidator.mediaActiveDomain`
   (`start = Σ preceding timelineSpan`; `end = start + timelineSpan + following-boundary postHalf`;
   cut postHalf = 0).

   `TransitionMath` already exposes the per-instant outgoing/incoming functions; `SceneMediaClock`
   re-expresses them as one `sceneMediaTime(role:…)` switch and adds the domain. **`TimelineEvaluator`,
   `ProjectValidator`, and `AudioEvaluator` then all call this one helper.** No behavior change to the
   video path — Stage A proves byte/pixel/test parity (§6 STOP conditions, §5 tests).

> **Design note (boundary derivation).** Inside an `AudioEvaluationWindow`, a scene's `sceneStart`
> comes from `RequiredSceneSpan.sceneStart` and the following boundary `B` from the window's
> `RequiredBoundary.boundary`. The shared helper takes already-derived values (no manifest), so it stays
> usable from both the window-level evaluator and the manifest-level validator.

### 2.2 `AudioEvaluationWindow` + resolved descriptors (Stage B)

`Audio/AudioEvaluationWindow.swift` (NEW). Immutable, `Equatable`, `Sendable`, minted only by the
builder (same `init`-internal pattern as `EvaluationWindow`). Carries exactly what the evaluator needs,
**no manifest, no payload table**:

- `coverage: ProjectTimeRange`, `projectDuration: TickDuration` (for range validation, mirrors
  `EvaluationWindow`);
- `scenes: [AudioWindowScene]` where `AudioWindowScene` = `{ sceneID, sceneStart, nominalDuration,
  timelineSpan, followingBoundary: ProjectTime?, followingTransition: SceneTransition? }` — exactly the
  per-scene facts the shared clock needs (no payload, no layers);
- `clips: [ResolvedAudioClip]` — each clip already resolved against its source descriptor and (for
  video-layer clips) its scene's `VideoBinding.sourceMapping`. Fields:
  `{ clipID, trackID, sourceID, role, isMuted, gain, destination, sourceTrim, playbackPolicy,
  binding: AudioClipBinding }` where `AudioClipBinding` is either
  `.global` (strict 1/1) or `.videoLayer(sceneID:, sourceMapping: SourceTimeMapping)` — the **resolved
  copy** of the layer's mapping, so the evaluator never touches a payload.
- `tracks: [ResolvedAudioTrack]` = `{ trackID, role, order: Int }` — canonical track order materialised
  once by the builder, used as the primary segment sort key (§3 ordering; ADR-012 §3 "canonical track
  order").

`Audio/ResolvedAudioSourceDescriptor.swift` (NEW). Per ADR-012 §1.0b: `{ sourceID, streamIdentity
(stable provenance string), sourceDuration: RationalSourceTime, sampleRate: Int64, channelLayout:
AudioChannelLayoutDescriptor }`. **Value type, integer/rational only.** `AudioChannelLayoutDescriptor`
is a small canonical enum (`.mono`, `.stereo`, plus a typed `.discrete(count:)`) — no AVFoundation
`AVAudioChannelLayout`. The descriptor is an **input** to the builder, not produced by it.

### 2.3 `AudioPlan` / `AudioSegmentPlan` (Stage B)

`Audio/AudioPlan.swift` (NEW). Immutable, `Equatable`, `Sendable`:

- `AudioPlan = { sampleInterval: AudioSampleRange, segments: [AudioSegmentPlan] }` — stable ordered
  segment list. Empty `segments` is valid (legitimate silence / empty interval).
- `AudioSegmentPlan` (per ADR-012 §3 — "each segment plan identifies …"):
  - identity: `clipID`, `sourceID`, `trackID`, `role`;
  - **destination sample interval**: `destinationSamples: AudioSampleRange` (the intersection of the
    clip's `destination` with the requested interval, mapped to 48 kHz);
  - **source mapping/trim**: `sourceStart: RationalSourceTime`, `sourceEnd: RationalSourceTime`
    (the audible source sub-window after the `.once` stop + trim gate), plus `effectiveTrim:
    RationalSourceRange`;
  - role, `isMuted`, `gain: AudioGain` (fixed-point; passed through, never folded by the evaluator);
  - conversion metadata: `sourceSampleRate: Int64`, `channelLayout: AudioChannelLayoutDescriptor`
    (from the descriptor — what the mixer/adapter must convert);
  - provenance: `streamIdentity`, and the originating `sceneID?` for diagnostics/cache validation.

> Muted clips: **kept** as segments with `isMuted = true` (preview/export must know a source exists and
> is intentionally silent; the mixer applies the mute). This matches §2 "all temporally active,
> **unmuted** sources are mixed" — mute is a mixer decision on a present segment, not an evaluator drop.
> (Confirm with lead — alternative is to drop muted segments; default chosen = keep + flag, because
> dropping loses provenance/diagnostics required by §3.)

### 2.4 Typed errors (Stage B/C)

`Audio/AudioEvaluationError.swift` (NEW) — evaluator/builder typed failures, distinct from
`ProjectValidationError` (validation already happened in Slice 1; these are evaluation-boundary
failures):

- `unresolvedAudioSource(sourceID:)` — descriptor missing for a referenced source;
- `ambiguousAudioSource(sourceID:)` / `noAudioStream(sourceID:)` — §1.0b "zero or multiple → typed
  failure" (the *builder* enforces exactly-one; carried here so it is one error namespace);
- `audioWindowCoverageViolation` — requested sample interval outside `coverage` (mirrors
  `invalidEvaluationWindowCoverage`);
- `unknownAudioWindowScene(sceneID:)` — a video-layer clip names a scene absent from the audio window;
- `inconsistentResolvedBinding(clipID:)` — a resolved binding disagrees with the clip role (defence in
  depth; builder-side).

(Final names confirmed in Stage B; this is the proposed set.)

---

## 3. Segment cutting — exact contract the evaluator implements

Given an `AudioEvaluationWindow` and a requested half-open project tick interval `R` (the caller's
"exact project sample interval", expressed as a `ProjectTimeRange` and reduced to `AudioSampleRange` via
Slice-1 `from(projectTicks:)`):

For each `ResolvedAudioClip` (iterated in canonical order, §3 ordering below):

1. **Active-destination intersection.** `activeDest = clip.destination ∩ R` (half-open). If empty →
   **zero segments** for this clip (not an error). Empty requested `R` → empty plan (§ roadmap "empty
   sample ranges yield zero segments").
2. **Project→source mapping over the active interval** (§1.0a):
   - **global** (`.global` binding): strict 1/1 —
     `sourceTime(T) = sourceTrim.start + (T − destination.start)`, exact rational, one project second =
     one source second.
   - **video-layer** (`.videoLayer(sceneID, sourceMapping)`): `sourceTime(T) =
     sourceMapping.target(for: SceneMediaClock.sceneMediaTime(role, T, sceneStart, B))`. The role
     (sole/outgoing/incoming) is decided by whether `T` is inside the scene's following/preceding
     **transition window** — derived from the audio window's per-scene `followingBoundary`/transition,
     **reusing the identical role logic the video evaluator uses**. Incoming pre-boundary (`T < B`)
     yields `sceneMediaTime = 0`, so the source does not advance → **silent** (no segment emitted for
     the held interval); this is *already guaranteed* by Slice-1 validation forbidding
     `destination.start < B` on incoming clips, but the evaluator still honours the hold by construction.
3. **Trim + `.once` gate** (§1.0a items 6, 7). The audible sub-interval is the part of `activeDest`
   whose mapped `sourceTime ∈ sourceTrim` (half-open). `.once` stops at the **first** end reached — the
   earlier of `activeDest.end` and the project time at which `sourceTime` exits `sourceTrim.end`. No
   loop, no stretch, no extension. For 1/1 global the stop time is a closed-form tick; for video-layer
   it is found by inverting the (monotonic, rate ≥ 0) mapping at `sourceTrim.end` — computed exactly in
   rational/tick arithmetic, **no float**. If the audible sub-interval is empty → zero segments.
4. **Emit one `AudioSegmentPlan`** for the audible sub-interval: `destinationSamples =
   AudioSampleRange.from(projectTicks: audibleDest)`; `effectiveTrim`/`sourceStart`/`sourceEnd` from the
   gated mapping; gain/mute/role/identity/conversion/provenance copied through.

**Transition overlap (§2, §1.0a items 5a/5b).** During a boundary window both the outgoing and the
incoming scene are temporally active. A clip bound to the outgoing scene maps via the outgoing media
clock (post-roll continues) and a clip bound to the incoming scene maps via the incoming media clock
(silent pre-`B`). Both emit segments where their own destination/trim/`.once` gates allow → **both
active scenes mixed, no implicit ramp invented**. The evaluator never synthesises crossfade/duck/mute.

**Deterministic ordering.** Segments are sorted by `(track.order, destinationSamples.start,
clipID, sourceID)` — primary key is the builder-materialised **canonical track order**, never dictionary
iteration or completion order (ADR-012 §3). Within one clip at most one segment is emitted per request,
so the tuple is total.

**Channel/rate conversion metadata** is *carried*, not applied — the evaluator stays pure; the mixer
adapter (later slice) performs SRC/channel mapping.

---

## 4. Builder-vs-evaluator split (what stays out of the pure evaluator)

Per ADR-012 §1.0b the **`AudioEvaluationWindowBuilder`** (impure-free but resolution-bearing) does, and
the **`AudioEvaluator`** does NOT:

| Concern | Builder | Evaluator |
|---|---|---|
| Resolve each `AudioAssetReference` → **exactly one** `ResolvedAudioSourceDescriptor` (zero/multiple → typed failure; absent clip = legitimate silence) | ✅ | ❌ |
| Stable-identity stream selection (NO `AVAsset` track-order dependence) | ✅ (consumes already-resolved descriptors; never opens an `AVAsset`) | ❌ |
| Resolve video-layer clip → its scene's `VideoBinding.sourceMapping` (copy into `ResolvedAudioClip.binding`) | ✅ | ❌ |
| Materialise canonical **track order** once | ✅ | ❌ |
| Re-validate manifest/document invariants | ❌ (Slice-1 `ProjectValidator` already did; builder asserts the resolved set is self-consistent only) | ❌ |
| Payload lookup, source resolution, any I/O / AVAsset / decode | ❌ (no I/O; descriptors are inputs) | ❌ |
| Per-instant `sceneMediaTime`, trim/`.once`/gain/mute, segment cutting, ordering | ❌ | ✅ |
| Track-order *dependence* in output | (defines order) | uses materialised order only |

The builder is I/O-free and AVFoundation-free: it consumes already-resolved descriptors + already-loaded
`ResolvedScenePayload`s and produces the immutable window. The evaluator performs **no** payload lookup
and **no** source resolution — it reads only the window.

---

## 5. Exact file list and tests

### 5.1 New production files (`AnimiEngineNext/Sources/AnimiEngineCore`)

| Stage | File | Purpose |
|---|---|---|
| A | `Evaluator/SceneMediaClock.swift` | shared `sceneMediaTime(role:…)` + `mediaActiveDomain(…)` (single definition) |
| B | `Audio/AudioEvaluationWindow.swift` | `AudioEvaluationWindow`, `AudioWindowScene`, `ResolvedAudioClip`, `AudioClipBinding`, `ResolvedAudioTrack` |
| B | `Audio/ResolvedAudioSourceDescriptor.swift` | descriptor + `AudioChannelLayoutDescriptor` |
| B | `Audio/AudioPlan.swift` | `AudioPlan`, `AudioSegmentPlan` |
| B | `Audio/AudioEvaluationError.swift` | typed evaluation/builder errors |
| C | `Audio/AudioEvaluationWindowBuilder.swift` | I/O-free builder: resolve + materialise window |
| C | `Audio/AudioEvaluator.swift` | pure evaluator: window + interval → `AudioPlan` |

### 5.2 Modified production files (Stage A only — behavior-preserving)

- `Evaluator/TimelineEvaluator.swift` — replace the inlined sole/outgoing/incoming media-time lines with
  calls to `SceneMediaClock`. **No FramePlan change.**
- `Project/ProjectValidator.swift` — `mediaActiveDomain` delegates to `SceneMediaClock.mediaActiveDomain`
  (identical result). **No validation-result change.**
- `Evaluator/TransitionMath.swift` — *optionally* re-expressed in terms of `SceneMediaClock` (or left as
  the low-level primitives the clock composes). Default: leave `TransitionMath` as primitives; the clock
  composes them. **No public removal.**

### 5.3 Test files (`Tests/AnimiEngineCoreTests`)

- **NEW `SceneMediaClockTests`** (Stage A): sole `T−start`; outgoing post-roll continues; incoming hold
  `0` then `T−B`; domain `start/end` with cut (postHalf 0) and animated (postHalf) following boundary;
  parity assertion that the clock reproduces `TransitionMath` outputs exactly.
- **NEW `AudioEvaluationWindowBuilderTests`** (Stage C): exactly-one resolution; zero-stream and
  multiple-stream → typed failure; stable-identity selection independent of input order (no track-order
  dependence); silent video = absent clip (no descriptor required); video-layer binding copies the
  layer `sourceMapping`.
- **NEW `AudioPlanModelTests`** (Stage B): `AudioPlan`/`AudioSegmentPlan` value semantics, `Equatable`,
  empty-plan validity, no `Float`/`Double` (compile-level + a reflection/string sweep test like Slice 1).
- **NEW `AudioEvaluatorTests`** (Stage C) — the heart, covering the required tests-plan:
  - deterministic segment ordering (shuffle inputs → identical ordered plan);
  - global audio strict 1/1 timing (closed-form source-time checkpoints);
  - video-layer timing **reuses `sourceMapping`** (assert equality with the value the video evaluator
    would compute via `SceneMediaClock` + `sourceMapping.target`);
  - transition overlap → both outgoing and incoming segments where each gate allows;
  - incoming pre-boundary silence (no incoming segment while `T < B`);
  - outgoing post-roll allowed (outgoing segment continues into post-roll when trim/`.once` allow);
  - empty requested sample range → zero segments (not an error);
  - empty destination∩request → zero segments for that clip;
  - mute behavior (segment present, `isMuted = true`) and gain pass-through (raw integer preserved);
  - trim gate clips the audible sub-interval; `.once` stops at the first end (no loop/stretch);
  - legitimate silence (video layer with no clip → no segment; whole plan can be empty);
  - **no AVFoundation import** test (source-text sweep over the new `Audio/` files and the evaluator,
    asserting no `import AVFoundation`/`AVFAudio`, like the Slice-1 no-float guard);
  - **`TimelineEvaluator` behavior unchanged** (Stage A regression — see §5.4).

### 5.4 Regression guards (no video/pixel drift from the Stage-A refactor)

- Full `AnimiEngineCoreTests` must stay green (Stage A and after each later stage).
- **`PostPromotionMatrixRegressionTests`** (Metal/render) must still be `exactMatch 84/84` — proves the
  `sceneMediaTime` extraction did not move a single rendered pixel. Run once at Stage A close and once at
  Slice-2 close. ReferenceData hash must be byte-identical before/after (record in the Stage-E-equivalent
  report), exactly as Slice 1 did.

---

## 6. Implementation stages A/B/C

- **Stage A — shared `sceneMediaTime` helper (refactor, zero behavior change).** Create
  `SceneMediaClock`; route `TimelineEvaluator` + `ProjectValidator.mediaActiveDomain` through it; add
  `SceneMediaClockTests`; prove `AnimiEngineCoreTests` green **and** `PostPromotionMatrixRegressionTests`
  exactMatch 84/84 + ReferenceData byte-identical. **No audio types yet.** STOP if any video test or the
  render matrix changes.
- **Stage B — value model.** `AudioEvaluationWindow` + `AudioWindowScene` + `ResolvedAudioClip` +
  `AudioClipBinding` + `ResolvedAudioTrack`; `ResolvedAudioSourceDescriptor` +
  `AudioChannelLayoutDescriptor`; `AudioPlan` + `AudioSegmentPlan`; `AudioEvaluationError`. Pure value
  types, integer/rational only. `AudioPlanModelTests`. No evaluator/builder logic yet.
- **Stage C — builder + evaluator.** `AudioEvaluationWindowBuilder` (resolve exactly-one, copy mappings,
  materialise track order, I/O-free) + `AudioEvaluator` (segment cutting, trim/`.once`/gain/mute,
  ordering). `AudioEvaluationWindowBuilderTests` + `AudioEvaluatorTests`. Full suite + render matrix
  green. (Evidence-closure report is the natural Stage-D/E follow-up, mirroring Slice 1, but is **not**
  part of this plan's coding scope unless the lead asks.)

---

## 7. STOP conditions

1. **STOP at the end of this preflight** — no code this step.
2. STOP and report if the Stage-A refactor changes ANY `AnimiEngineCoreTests` result, the render
   `PostPromotionMatrixRegressionTests` exactMatch count, or the ReferenceData tree hash (do NOT
   re-promote refs, do NOT edit PNGs, do NOT "fix" the matrix — surface the diff).
3. STOP if implementing any stage forces touching a forbidden path: `AnimiApp/`, scheduler/export/
   preview, AVFoundation/AVFAudio, TVECore, Metal/`AnimiEngineMetalRender`, `AnimiEngineRenderGraph`,
   `Package.swift`, `*.xcodeproj`, `ReferenceData/`.
4. STOP if the work would require changing the Slice-1 schema/codec **shape** (any JSON byte change) or
   any Slice-1 validation result — Slice 2 must not.
5. STOP if a required design choice is unresolved by the ADRs (e.g. the §2.3 muted-segment keep-vs-drop
   decision, or the exact `streamIdentity`/`channelLayout` descriptor shape) — surface for a lead
   decision rather than inventing canonical semantics.
6. STOP if any new `Audio/` or evaluator file would need `import AVFoundation`/`AVFAudio` or any I/O —
   that means the builder/evaluator split was violated.

---

## 8. Open questions for the lead (decide before Stage B)

1. **Muted segments:** keep-with-flag (default, preserves provenance) vs drop. (§2.3)
2. **`streamIdentity` shape:** opaque stable `String` provenance vs a typed `AudioStreamIdentity`
   wrapper. (§2.2)
3. **`channelLayout` granularity:** `.mono/.stereo/.discrete(count:)` enough for v1, or a richer
   canonical layout descriptor? (§2.2)
4. **`AudioEvaluationWindowBuilder` location of exactly-one enforcement:** the descriptor set is an input
   already resolved upstream — does the builder *re-assert* exactly-one (defence in depth) or assume the
   resolver did it? (§4 — default: builder re-asserts and fails typed.)
