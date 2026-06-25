# ADR-012: Canonical Audio Architecture

- **Status:** Accepted — canonical contract; implementation remains evidence-gated.
- **Date:** 2026-06-24.
- **Accepted:** 2026-06-25, under owner authorization to finalize the canonical architecture.
- **Depends on:** ADR-003, ADR-005, ADR-006.
- **Source decisions:** D-018 through D-022, D-113 through D-116.

## Context

Audio is currently split across app and legacy TVECore paths. Preview builds an `AVMutableComposition`, renders the whole project to a temporary 44.1 kHz CAF, then plays that file. Export separately consumes the legacy composition/mix. Canonical `AnimiEngineCore` has no audio model, and the current legacy export plan contains floating-point values and a `loopToFit` policy.

That structure cannot guarantee one source of truth for timing, mixing, preview, and export. It also prevents the engine from streaming bounded work for large projects.

## Approved product behavior

The product owner has fixed these rules:

1. Scrubbing is silent.
2. Every temporally active, unmuted source is mixed; a visual transition does not implicitly replace one source with another.
3. Audio from every temporally active video is enabled by default. The user controls volume and mute for each source.
4. Music never loops automatically.
5. An interruption or relevant route change pauses playback. The engine never auto-resumes; the user presses play.

These are product requirements, not benchmark-dependent tuning.

## Decision

### 1. Audio belongs to canonical project schema v3

`AnimiEngineCore` owns the value-semantic, `Sendable` canonical audio model.
Persistence uses the strict `CanonicalProjectEncoding` path; there is no
parallel permissive `Codable` shortcut.

`CanonicalProjectManifest` schema v3 adds one required `audio` field:

```text
AudioManifest {
  sources: [AudioSourceEntry]
  tracks:  [AudioTrackEntry]
  clips:   [AudioClipEntry]
}

AudioSourceEntry {
  id: AudioSourceID
  asset: AudioAssetReference
}

AudioTrackEntry {
  id: AudioTrackID
  role: AudioSourceRole
}

AudioClipEntry {
  id: AudioClipID
  trackID: AudioTrackID
  sourceID: AudioSourceID
  videoLayer: SceneLayerReference?
  destination: ProjectTimeRange
  sourceTrim: RationalSourceRange
  gain: AudioGain
  isMuted: Bool
  playbackPolicy: AudioPlaybackPolicy
}

SceneLayerReference {
  sceneID: SceneInstanceID
  layerID: LayerID
}
```

Ownership is strict:

- `AudioSourceEntry` owns source identity and asset provenance only;
- `AudioTrackEntry` owns the role: `videoLayer`, `music`, `voiceover`, or
  `soundEffect`;
- `AudioClipEntry` places a source on the project timeline and owns user gain,
  mute, and playback policy;
- one source may be reused by multiple clips;
- every clip must resolve to exactly one source and one track.

`AudioAssetReference` is a closed canonical enum:

```text
.videoLayerMedia(MediaReference)
.globalAudio(GlobalAudioAssetID)
```

It never stores a URL, path, `AVAsset`, security-scoped handle, or decoder
object. Video-layer audio reuses the exact `MediaReference` carried by the
referenced `VideoBinding`; global music, voiceover, and sound effects use a
non-empty opaque `GlobalAudioAssetID`.

`SceneLayerReference` is required because `LayerID` is unique only within one
scene payload. Resolution is `sceneID → SceneManifestEntry.payloadID →
ResolvedScenePayload → layerID`.

Canonical identities, time, gain, and cache keys must not use `Float` or
`Double`. `AudioGain` is an integer linear scale from `0` to `1_000_000`,
where `1_000_000` is unity. Construction or decoding outside that range is a
typed validation failure; values are never clamped. DSP adapters convert gain
to `Float32` only at the processing boundary.

All clips use playback policy `.once`. Playback stops at the earlier of the
authored clip end and available trimmed source content. There is no wrap,
repetition, implicit extension, or `loopToFit`.

### 1.0a Canonical source-time mapping (no per-clip rate; global 1/1, video inherits the video rate)

The mapping from a project-time instant to a source-time instant is fixed by
this contract and is the single source of truth for both preview and export.
It is normative and removes any ambiguity in how `destination`, `sourceTrim`,
and `playbackPolicy` determine playback.

1. **No `rate` field on `AudioClipEntry`.** A clip never stores its own playback
   rate. The mapping below is the only one; there is no alternative reading.

2. **No length-derived rate.** The rate is never computed as
   `sourceTrim.duration / destination.duration`. `destination` and `sourceTrim`
   lengths are independent facts, not a time-stretch ratio.

3. **Global audio (`music`, `voiceover`, `soundEffect`) — strict 1/1.** For a
   project-time instant `projectTime` inside the clip's `destination`, the
   source-time instant is

   ```text
   sourceTime = sourceTrim.start + (projectTime − destination.start)
   ```

   evaluated as exact canonical time (`destination` in 240,000 ticks/second;
   `sourceTrim` in exact `RationalSourceTime` seconds; the tick delta is the
   exact rational `(projectTime − destination.start) / 240000` seconds). The
   playback rate is exactly 1/1; one project second is one source second.

4. **Video-layer audio inherits the video's full mapping — via the same
   scene-media time the evaluator uses for the video.** Video-layer audio uses
   **exactly** the referenced layer's `VideoBinding.sourceMapping` — the same
   `rate`, `nativeTimescale`, and anchor the video uses. The project→source
   correspondence is **not** a new mapping built by audio; it is the existing
   per-scene media clock `TimelineEvaluator` already computes for the video
   (`mediaPlaybackTime` — `Evaluator/TimelineEvaluator.swift`,
   `Evaluator/TransitionMath.swift`):

   ```text
   sceneMediaTime(sceneID, T):
     sole scene:      T − scene.sceneStart
     outgoing (in a transition window): T − outgoingScene.sceneStart   (continues past
                                        nominal at normal speed — post-roll; never frozen)
     incoming (in a transition window): 0                if T <  boundary B  (pre-boundary hold)
                                        T − B            if T >= boundary B

   sourceTime = VideoBinding.sourceMapping.target(for: sceneMediaTime(sceneID, T))
   ```

   `AudioEvaluator` (Slice 2) reuses this `sceneMediaTime` and
   `VideoBinding.sourceMapping.target(for:)` directly; it **never** creates a
   separate project→scene mapping for audio. Audio and video therefore share one
   mapping and cannot desynchronize by construction. Audio never defines its own
   rate, timescale, or anchor. **Note:** video-layer audio is therefore **not**
   necessarily 1/1 — it runs at the video's `PlaybackRate`, which may be non-1/1.
   Only **global** audio (item 3) is strict 1/1. "No per-clip rate" means the
   rate is never stored on or derived by the clip, not that every clip is 1/1.

5. **`sourceTrim` for video-layer audio is a window/gate only.** It restricts
   which part of the source is audible. It does **not** re-anchor, re-scale, or
   otherwise modify the video mapping. The video mapping defines the
   project→source correspondence; `sourceTrim` only gates it.

5a. **Incoming audio is silent during the pre-boundary hold.** While `T < B` the
   incoming scene's media clock is held at `0` (item 4, incoming case), so the
   incoming source is not advancing and no incoming audio plays during the hold.
   This is enforced canonically: a video-layer audio clip on the **incoming**
   side of a boundary **must have a `destination` that does not start before that
   scene boundary** (`destination.start >= B`). Repeating or time-stretching a
   single source sample to "fill" the pre-boundary hold is **forbidden** — the
   hold is silence for that source, not a frozen/looped audio frame.

5b. **Outgoing audio may continue into the post-roll.** Because the outgoing
   media clock continues past the nominal end at normal speed during the
   transition window (item 4, outgoing case), outgoing video-layer audio may
   keep playing through the post-roll **iff** its `destination`, `sourceTrim`,
   and source material availability allow it (the `sourceTime ∈ sourceTrim` gate
   and `.once` stop still apply). No special post-roll automation is added; the
   ordinary mapping + gate produce the continuation.

6. **Audibility condition.** A clip contributes audio at `projectTime` if and
   only if both hold: `projectTime ∈ destination` (half-open) **and** the
   computed `sourceTime ∈ sourceTrim` (half-open). Outside either interval the
   clip is silent at that instant — this is correctness, not a fallback.

7. **`.once` stop semantics.** `.once` stops playback at the first end reached —
   the earlier of `destination.end` and the end of available trimmed source
   content (the `sourceTime ∈ sourceTrim` gate). There is no loop, no
   time-stretch, and no implicit extension past that first end.

This subsection is documentation-only with respect to the persisted schema: it
fixes the *meaning* of the existing `destination`/`sourceTrim`/`playbackPolicy`
fields and adds **no** new stored field. The pure `AudioEvaluator` (Slice 2)
implements exactly this mapping; Slice 1 stores and round-trips the fields
without evaluating them.

### 1.0b Evaluation input, resolved sources, and the media-active domain

These are normative contracts for Slice 2's evaluator boundary. They add **no**
Slice-1 stored field; Slice 1 only defines the schema/codec/validation.

**Evaluator input (no manifest, no I/O in the pure evaluator).** The pure
`AudioEvaluator` consumes an immutable `AudioEvaluationWindow`, **not** a
`CanonicalProjectManifest`. An impure-free `AudioEvaluationWindowBuilder`
produces that window from:

- the canonical document (manifest + payloads);
- an `EvaluationWindowRequirement` (the requested time window);
- already-loaded `ResolvedScenePayload`s;
- already-resolved `ResolvedAudioSourceDescriptor`s.

The builder performs resolution and validation **without I/O and without
AVFoundation** (it consumes already-resolved descriptors; it never opens an
`AVAsset`). `AudioEvaluator` stays pure and performs **no** payload lookup and no
source resolution. This mirrors the existing video split
(`EvaluationWindowBuilder` → immutable `EvaluationWindow` → pure
`TimelineEvaluator`).

**Resolved audio source.** Every `AudioAssetReference` MUST resolve to **exactly
one** logical audio stream. A `ResolvedAudioSourceDescriptor` carries at least:

- `AudioSourceID`;
- a stable stream/provenance identity;
- exact source duration;
- source sample rate;
- channel layout.

Resolving to **zero or multiple** candidate streams for an existing
`AudioClipEntry` is a **typed failure** (required audio, never silently
silenced). A legitimately silent video is represented by the **absence** of an
audio clip, never by a failed/empty resolution. Stream selection MUST be
deterministic and MUST NOT depend on incidental `AVAsset` track ordering; the
resolver chooses by stable identity and fails typed on ambiguity.

**Media-active domain (video-layer destination).** For a video-layer clip, the
**entire** `destination` MUST lie within the project range where the shared
canonical `sceneMediaTime(sceneID, T)` (§1.0a item 4) is defined for that scene:

- visual `activeRange` and opacity do **not** constrain audio (D-020 — audio is
  independent of visual visibility);
- the **incoming pre-boundary interval is forbidden** (`destination.start >= B`,
  §1.0a item 5a);
- the **outgoing post-roll is allowed** (§1.0a item 5b);
- any part of `destination` outside the media-active domain is a **typed
  validation error**.

`TimelineEvaluator` and `AudioEvaluator` MUST use **one shared helper** to derive
the per-scene media-active domain and `sceneMediaTime`; the math is defined once
and not duplicated across the two evaluators.

### 1.1 Schema migration and canonical encoding

- `supportedSchemaVersion` becomes `3`.
- Accepted input versions are `1`, `2`, and `3`.
- The encoder always writes v3.
- v1/v2 documents uplift to v3 with
  `audio = {sources: [], tracks: [], clips: []}`.
- A v3 document must contain the `audio` object and all three arrays, even when
  empty.
- Unknown or missing fields, unknown enum tags, malformed references,
  non-integer gain, and invalid ranges are rejected.
- `videoLayer` is emitted only when a clip has a scene-layer reference. It is
  absent for global roles; explicit JSON `null` is rejected so one semantic
  value cannot have two canonical representations.
- Caller-provided array order is non-semantic. The canonical encoder sorts
  sources by `AudioSourceID`, tracks by `AudioTrackID`, and clips by
  `(trackID, destination.start.ticks, AudioClipID)`.
- The validator does not reject shuffled in-memory arrays. Semantically equal
  manifests must encode to identical bytes.

### 1.2 Validation boundary

`ProjectValidator.validateManifest` checks only manifest-owned facts:

- unique source, track, and clip IDs;
- no dangling clip-to-source or clip-to-track reference;
- every source and track is referenced by at least one clip; an empty audio
  manifest has all three tables empty;
- video-layer role requires `SceneLayerReference`; all other roles forbid it;
- video-layer role requires `.videoLayerMedia`; global roles require
  `.globalAudio`;
- referenced `sceneID` exists;
- destination is inside project duration;
- source trim is non-empty;
- gain and playback policy are valid.

`ProjectValidator.validate(document)` additionally checks payload-owned facts:

- `SceneLayerReference` resolves in the referenced scene payload;
- the referenced layer is video, not image;
- `.videoLayerMedia` equals that layer's `VideoBinding.media`.
- the audio source trim is contained within the referenced
  `VideoBinding.sourceMapping.trimRange` (the trim is a window/gate inside the
  video's own trim range — §1.0a item 5 — never a re-anchoring of the mapping);
- at most one video-audio clip references a given `SceneLayerReference`.

A video layer with no audio clip represents legitimate silence. A present
video-audio clip is required audio; dangling, mismatched, missing, corrupt, or
undecodable required audio must fail explicitly.

The project adapter must create the default unmuted unity-gain video-audio clip
when imported media is known to contain audio. Visual opacity, masking,
occlusion, and z-order never implicitly mute audio.

### 2. Visual transitions do not author hidden audio automation

If two scenes overlap during a visual transition, all temporally active, unmuted audio sources from both scenes are mixed at their authored gains.

The engine must not synthesize a crossfade, duck, fade, or mute merely because a visual transition exists. Future explicit audio automation may be added as canonical data, but it must be authored, serializable, deterministic, and visible to both preview and export.

The legacy `AudioCompositionBuilder.applyTransitionRamps` behavior is therefore not canonical unless equivalent gain automation is explicitly present in the canonical manifest.

### 3. Pure audio evaluation

A pure `AudioEvaluator` converts one immutable `AudioEvaluationWindow` (built per §1.0b by an
I/O-free, AVFoundation-free `AudioEvaluationWindowBuilder` from the canonical document, an
`EvaluationWindowRequirement`, already-loaded `ResolvedScenePayload`s, and already-resolved
`ResolvedAudioSourceDescriptor`s) and an exact half-open project sample interval into an immutable
`AudioPlan`. The evaluator consumes the window, not the manifest; it performs no payload lookup, no
source resolution, no asset I/O, decode, audio-session mutation, or realtime scheduling.

An `AudioPlan` contains a stable ordered collection of segment plans. Each segment plan identifies:

- canonical source and clip identity;
- exact destination sample interval;
- exact source sample mapping and trim;
- role, mute state, and fixed-point gain/automation;
- required channel and sample-rate conversion metadata;
- provenance needed for diagnostics and cache validation.

Stable ordering is defined by canonical track order and typed identities, never dictionary iteration or completion order. Preview and export consume the same evaluator and plan semantics.

### 4. Canonical mix format and time grid

The initial internal mix format is:

- 48,000 samples per second;
- linear PCM `Float32`;
- interleaved semantics are adapter-specific; the plan is layout-neutral;
- stereo output bus for the current product.

At 240,000 project ticks per second, one canonical mix sample equals exactly five ticks. ADR-006 defines the half-open tick-to-sample mapping. Imported formats are explicitly converted into this grid; source metadata and decoder output determine the actual source rate and channel layout.

The hardware output rate must be queried after audio-session and engine activation. A requested 48 kHz hardware rate is only a preference. Device-rate conversion is an I/O adapter responsibility and never changes canonical project timing or cache identity.

The internal Float32 mix bus may represent peaks outside `[-1, 1]`. The engine
performs no hidden per-source normalization, ducking, or automatic gain
compensation. Peak metering reports pre-output peak and overload.

The final overload/output stage must be explicit, deterministic, versioned,
diagnosed, and identical in preview and export. Its exact algorithm (for
example, hard saturation versus a fixed safety limiter) is benchmark decision
D-213 and must be accepted before Slice 4. Integer conversion may add only
explicitly configured deterministic dither; Float32 and compressed-export
inputs do not.

### 5. Realtime preview graph

Preview uses one engine-owned `AVAudioEngine` graph as the realtime audio adapter. It streams bounded decoded PCM chunks into prepared player/mixer inputs; it must not pre-render the whole project into a temporary audio file before playback.

The graph must provide:

- one scheduler-controlled timeline anchor for every source;
- bounded lookahead and per-source prepared buffers;
- explicit source-rate/channel conversion;
- stable summing of all active unmuted sources;
- one final output bus whose render clock drives ADR-006 playback;
- immutable callback-visible state published outside the audio callback.

The audio callback performs no asset I/O, decode, allocation, blocking lock, logging, notification dispatch, or graph mutation. Decode and plan preparation happen on bounded worker queues with backpressure.

On iOS, the application audio session uses the playback category and a movie-playback-appropriate mode unless a later product requirement needs recording. Session activation/deactivation remains an app lifecycle responsibility exposed to the engine through an adapter contract.

### 6. Silent scrub

Scrub evaluation produces video frames only. It does not schedule snippets, pitch-shifted preview, or audio preroll for intermediate targets.

After scrub ends, settle prepares the exact final video frame and leaves transport paused. Audio preroll is created only when the user explicitly presses play and a new ADR-006 playback epoch is prepared.

### 7. Interruption and route changes

An interruption or relevant route change:

1. captures the last confirmed project time;
2. pauses transport and invalidates the current playback epoch;
3. flushes scheduled realtime buffers and stale prepared work;
4. re-queries the actual route and output format before the next play;
5. remains paused until the user presses play.

There is no automatic resume, even when the operating system reports that resume is permitted.

### 8. Offline export

Export evaluates the same canonical `AudioPlan` against original media and renders it through an isolated offline graph using `AVAudioEngine` manual rendering mode or a semantically equivalent deterministic adapter.

Export must:

- enumerate the exact canonical sample intervals required by the requested project range;
- render the exact expected number of 48 kHz mix samples;
- apply the same source activation, trim, gain, mute, ordering, transition-overlap, and output-stage semantics as preview;
- pass PCM to the export writer without realtime device-clock dependence;
- fail atomically and remove partial output when required audio cannot be resolved or decoded.

Preview/export parity means identical active sources, timing, gain, and mix/output rules. It does not promise byte-identical encoded files across different OS or codec versions. Same-environment PCM hashes and sample probes are required evidence where the graph and inputs are identical.

### 9. Missing and invalid audio

A video asset that is authoritatively known to contain no audio track contributes legitimate silence. That is not a decode failure.

A referenced music, voiceover, sound-effect, or known-present video-audio stream that is missing, corrupt, unauthorized, or undecodable produces a typed error with source identity and stage. Preview may pause/fail according to ADR-006; export fails atomically. The engine must not silently substitute missing required audio.

### 10. Cache and provenance

Decoded/resampled audio caches are derived artifacts. Their keys include source content identity, source trim, canonical destination format, conversion implementation/version, and any processing parameters. Project revision alone is not a cache key.

Preview and export may share a derived artifact only when its provenance satisfies the consumer's declared fidelity. Preview-only approximations and incomplete chunks cannot enter final export.

### 11. Runtime tuning is evidence-owned

The following are configurable and selected by physical-device evidence, not fixed by this ADR:

- PCM chunk size and buffer count;
- decode worker count;
- preroll and lookahead duration;
- actual I/O buffer duration;
- cache budgets and eviction thresholds;
- retry and rebuffer timeouts.

No feature code may hardcode these as assumptions about correctness.

## Required diagnostics

Diagnostics must expose, with bounded volume:

- canonical plan revision and playback epoch;
- source/clip identity, role, active range, gain, and mute state;
- source and destination format/conversion;
- scheduled, consumed, late, discarded, and starved sample intervals;
- actual route, device sample rate, I/O duration, and output latency;
- mix peak/overload and underrun counts;
- interruption/route transitions;
- export sample counts and PCM parity evidence identifiers.

The realtime callback may only update preallocated lock-free counters/state; formatting and logging occur elsewhere.

## Verification gates

The implementation is not accepted until automated tests and evidence cover:

- v3 empty/populated audio round trips and v1/v2-to-v3 uplift;
- strict rejection of missing/unknown audio fields and malformed references;
- duplicate/dangling source, track, and clip references;
- orphan source/track rejection and all-empty manifest consistency;
- role-to-layer and role-to-asset-kind validation;
- payload-level scene-layer resolution and video media-reference equality;
- video source-trim containment and duplicate video-layer audio rejection;
- deterministic bytes from shuffled in-memory source/track/clip arrays;
- legitimate silent video versus required video audio;
- exact tick/sample mapping and total sample count;
- source trim at 44.1, 48, and 96 kHz inputs;
- gain, mute, and stable summing order;
- accepted output-overload stage and preview/export equivalence;
- all simultaneous video-audio sources active by default;
- visual-transition overlap without implicit crossfade or ducking;
- music and other sources stopping without loop;
- legitimate silent-video handling versus missing required audio;
- silent latest-wins scrub;
- pause and explicit user resume after interruption/route change;
- preview/export AudioPlan parity and same-environment PCM probes;
- atomic export failure and partial-file cleanup;
- bounded queues and memory under 6, 10, and 20 simultaneous video sources plus music;
- physical-device A/V sync, underruns, route changes, memory, and thermal behavior.

## Migration note

The following current behaviors are migration inputs, not canonical contracts:

- direct `TVECore` audio types in preview/export coordination;
- `AVMutableComposition` as the source of truth;
- whole-project temporary 44.1 kHz CAF rendering before preview;
- canonical timing/gain expressed as `Double` or `Float`;
- `loopToFit`;
- separate preview and export mix construction;
- implicit transition gain ramps.

They must be removed from the canonical path behind explicit compatibility adapters or deleted after parity migration.

## Consequences

- Audio becomes part of the immutable canonical project rather than app-side state.
- Preview and export share timing and mix meaning while using different execution modes.
- The audio clock can safely own realtime project progression.
- Large projects stream bounded work instead of rendering full-project temporary audio.
- Product rules for simultaneous sources, no loop, silent scrub, and manual resume become testable contracts.

## References

- Apple, [`AVAudioEngine`](https://developer.apple.com/documentation/avfaudio/avaudioengine)
- Apple, [Enabling manual rendering mode](https://developer.apple.com/documentation/avfaudio/avaudioengine/enablemanualrenderingmode(_:format:maximumframecount:))
- Apple, [`AVAudioTime`](https://developer.apple.com/documentation/avfaudio/avaudiotime)
- Apple, [Responding to audio route changes](https://developer.apple.com/documentation/avfaudio/responding-to-audio-route-changes)
- Adobe, [Audio sample rates in Premiere](https://helpx.adobe.com/ca/premiere/desktop/organize-media/import-files/audio-sample-rates-in-premiere.html)
