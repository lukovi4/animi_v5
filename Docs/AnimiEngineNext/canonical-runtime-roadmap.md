# AnimiEngineNext Canonical Runtime Roadmap

Status: **ACCEPTED — implementation control document**
Accepted: **2026-06-25**

## 1. Authority and scope

This document defines implementation order and evidence gates for ADR-005,
ADR-006, and ADR-012. It does not replace those ADRs.

Rules:

- before code review/merge, every normative ADR/roadmap/task document required
  by the slice must be version-controlled in the same changeset;
- build inside `AnimiEngineNext` until the product-integration gate;
- do not import `AnimiApp`, TVECore, or current playback/export modules;
- write contract tests before or with implementation;
- every reviewable implementation stage must build and keep its scoped test
  suite green;
- do not advance while the current slice gate is red;
- do not preserve a permanent legacy/new dual runtime;
- do not delete shipping legacy code before the final cutover gate;
- after cutover parity passes, remove the superseded legacy paths in the same
  integration phase.

## 2. Slice 1 — canonical audio schema v3

This is the first authorized implementation slice.

### Scope

- exact 48 kHz tick/sample interval mapping from ADR-006;
- `AudioSourceID`, `AudioTrackID`, `AudioClipID`, `GlobalAudioAssetID`;
- `AudioAssetReference`, `AudioSourceRole`, `AudioGain`,
  `AudioPlaybackPolicy`, `SceneLayerReference`;
- `AudioSourceEntry`, `AudioTrackEntry`, `AudioClipEntry`, `AudioManifest`;
- `CanonicalProjectManifest.audio`;
- project schema v3 and v1/v2 uplift;
- strict canonical encoding/decoding;
- manifest-only and full-document validation;
- canonical hash re-bake with unchanged no-audio render pixels.

Forbidden:

- AVFoundation;
- `AnimiApp` or TVECore imports;
- `Float`/`Double` canonical time or gain;
- `loopToFit`;
- implicit transition audio automation;
- shipping-app changes.

### Ordered green implementation stages

0. **Documentation/repository gate**
   - accepted ADR-005/006/012, this roadmap, and the Slice-001 task contract are
     present in version control;
   - a clean checkout exposes the exact contracts used by the implementation.
1. **Schema scaffolding and migration tests**
   - schema v3;
   - accepted versions 1/2/3;
   - required v3 `audio` object;
   - v1/v2 uplift to empty sources/tracks/clips.
2. **Audio value model and tick/sample mapping**
   - typed IDs and references;
   - checked gain;
   - `.once`;
   - half-open sample mapping that may be EMPTY (`start == end` → zero samples,
     not an error; only `end < start` is invalid); `ceilDiv5` is overflow-free
     for non-negative `Int64` (not wrapped in checked arithmetic), while all
     other time/rational arithmetic stays checked.
3. **Manifest and strict codec integration**
   - three tables;
   - deterministic encoder sorting;
   - strict decode and round trips.
4. **Validation**
   - IDs, references, orphan rejection, roles, asset kind, ranges and policy;
   - scene-layer and media-reference resolution in full-document validation.
5. **Golden and evidence closure**
   - documented canonical-hash changes;
   - no-audio evaluator semantics unchanged;
   - approved pixel ReferenceData byte-identical.

### Gate

- full `AnimiEngineCoreTests` green;
- all ADR-012 schema-v3 tests green;
- no forbidden imports;
- canonical encoding deterministic under shuffled construction order;
- old/new canonical hashes recorded;
- no no-audio pixel-reference changes;
- no production-app files changed.

No legacy code is deleted in Slice 1.

## 3. Slice 2 — pure AudioEvaluator and AudioPlan

Build a pure evaluator that consumes an immutable `AudioEvaluationWindow` (built
by an I/O-free, AVFoundation-free `AudioEvaluationWindowBuilder` from the
canonical document, an `EvaluationWindowRequirement`, already-loaded
`ResolvedScenePayload`s, and already-resolved `ResolvedAudioSourceDescriptor`s)
and an exact project sample interval, producing a stable immutable `AudioPlan`.
The evaluator performs no payload lookup and no source resolution (ADR-012
§1.0b). Video-layer audio source time is `VideoBinding.sourceMapping.target(for:
sceneMediaTime(sceneID, T))` using the shared `sceneMediaTime` helper also used by
`TimelineEvaluator` (ADR-012 §1.0a).

Gate:

- deterministic ordered segment plans;
- exact activation, trim, gain, mute and `.once` behavior;
- transition overlap mixes both active scenes without implicit ramps;
- incoming pre-boundary hold is silent; outgoing post-roll may continue;
- each `AudioAssetReference` resolves to exactly one stream (zero/multiple →
  typed failure; silent video = absent clip; no `AVAsset` track-order dependence);
- empty sample ranges yield zero segments (not an error);
- legitimate silence and required-audio failure classification;
- preview/export consumers can share the same plan without AVFoundation in the
  evaluator.

## 4. Slice 3 — identities, transport and atomic scheduler

Implement ADR-005 and the pure/control portions of ADR-006:

- typed revision, epoch, request, cache and export identities;
- transport state machine;
- injected clocks;
- bounded admission and cancellation;
- complete-frame worksets;
- latest-wins scrub and exact settle;
- zero per-layer temporal fallback.

Gate:

- stale completions cannot publish;
- late/failed layers never produce mixed-time frames;
- bounded queues under deterministic fault injection;
- global frame skip keeps the previous complete composition.

## 5. Slice 3.5 — deterministic media corpus

Before any runtime/device gate, commit a legally safe deterministic generator
and compact generated fixtures:

- 44.1, 48 and 96 kHz tones;
- silent video;
- video with known-present audio;
- corrupt and missing fixtures;
- 6/10/20-video stress projects;
- transition-overlap audio cases.

Before Slice 4 begins, close D-213 with reproducible comparison evidence and
record the selected deterministic output-overload stage.

Gate:

- clean checkout contains all required fixtures;
- regeneration is deterministic;
- no third-party or unclear-license media.

## 6. Slice 4 — realtime audio and audio-master preview

Implement the bounded streaming `AVAudioEngine` adapter and connect it to the
canonical scheduler:

- shared epoch anchor;
- actual device-format query;
- the accepted D-213 output-overload stage;
- canonical-to-device conversion;
- bounded PCM preparation;
- realtime-safe callback;
- silent scrub;
- pause-only interruption/route behavior;
- audio render clock as master for an audio-bearing epoch.

Gate:

- physical-device A/V sync and underrun evidence;
- 6-video preview with audio;
- no whole-project temporary CAF;
- no automatic resume;
- bounded memory and queues.

## 7. Slice 5 — deterministic offline audio export

Render the same `AudioPlan` through isolated manual offline rendering and feed
canonical PCM to a permanent `AVAssetWriter` platform boundary.

Gate:

- exact sample counts;
- preview/export plan parity;
- same-environment PCM probes/hashes;
- atomic failure and partial-output cleanup;
- missing/corrupt required audio fails explicitly;
- no `AVMutableComposition`, transition ramps, or legacy `AudioExportPlan` in
  the canonical path.

## 8. Slice 6 — complete runtime stress and degradation

Finish evidence-selected proxy/cache/decode integration and the global
degradation ladder.

Gate:

- 6/10/20-video-with-audio device matrix;
- 30→24→15 global cadence behavior;
- zero mixed-time publications;
- bounded memory, queue, thermal and long-run evidence;
- real-template preview/export parity.

## 9. Slice 7 — product cutover and legacy deletion

Only after Slices 1–6 pass:

1. build the product adapter outside `AnimiEngineNext`;
2. switch preview, audio and export to the canonical runtime in one controlled
   integration phase;
3. run full product, clean-checkout, device and export parity gates;
4. remove the superseded legacy paths before declaring cutover complete.

Deletion scope includes, once no references remain:

- whole-project CAF preview controller and coordinator;
- legacy `AVMutableComposition` audio builder;
- `AudioExportPlan`/`loopToFit`;
- composition-reader `AudioWriterPump`;
- legacy host-time transport and route auto-resume behavior;
- CP7.9 prototype scheduler;
- per-provider/per-layer `lastGood` temporal fallback;
- obsolete current-pipeline glue replaced by the permanent writer adapter.

The final state has one production runtime. A compatibility adapter may exist
only at a declared external format or platform boundary; it may not preserve a
second scheduler, audio mixer, or export semantics.
