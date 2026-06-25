# Slice 001 — Canonical Audio Schema v3

Status: **AUTHORIZED FOR IMPLEMENTATION**
Accepted: **2026-06-25**

## Objective

Implement the pure canonical audio project model and exact 48 kHz sample-grid
mapping inside `AnimiEngineCore`.

This slice implements only schema/model/codec/validation/time logic. It does not
play, decode, mix, schedule, or export audio.

## Repository precondition

ADR-005, ADR-006, ADR-012, `canonical-runtime-roadmap.md`, and this task
contract must be included in version control with the implementation. A clean
checkout must not depend on untracked local documentation.

## Governing contracts

- ADR-003 — canonical time;
- ADR-006 §4 — exact tick/sample mapping;
- ADR-012 §1–1.2 — schema-v3 audio model and validation;
- `validation-contract.md` §10;
- `canonical-runtime-roadmap.md` Slice 1.

## Allowed production scope

Existing files:

- `Project/CanonicalProjectManifest.swift`
- `Project/References.swift`
- `Project/ProjectValidator.swift`
- `Project/ProjectValidationError.swift`
- `Codec/CanonicalProjectValueBuilder.swift`
- `Codec/RawProjectDTO.swift`
- `Codec/StrictReader.swift` — add/use a strict optional-object read that
  distinguishes an absent field from explicit JSON `null`;

Expected new files:

- `Project/AudioManifest.swift`
- `Time/AudioSampleRange.swift`

Equivalent file decomposition is allowed only when ownership remains in
`AnimiEngineCore`.

## Canonical model

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
  role: videoLayer | music | voiceover | soundEffect
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
  playbackPolicy: once
}
```

Asset references:

```text
videoLayerMedia(MediaReference)
globalAudio(GlobalAudioAssetID)
```

Scene-layer references:

```text
SceneLayerReference(sceneID: SceneInstanceID, layerID: LayerID)
```

`AudioGain` accepts exactly `0...1_000_000`. Invalid values throw a typed error;
they are never clamped.

## Canonical JSON

Schema v3 manifest contains:

```json
{
  "audio": {
    "sources": [
      {
        "id": "source-id",
        "asset": {
          "kind": "videoLayerMedia",
          "media": "media-reference"
        }
      }
    ],
    "tracks": [
      {
        "id": "track-id",
        "role": "videoLayer"
      }
    ],
    "clips": [
      {
        "id": "clip-id",
        "trackID": "track-id",
        "sourceID": "source-id",
        "videoLayer": {
          "sceneID": "scene-id",
          "layerID": "layer-id"
        },
        "destination": {
          "start": 0,
          "end": 240000
        },
        "sourceTrim": {
          "start": {
            "numerator": 0,
            "denominator": 1
          },
          "end": {
            "numerator": 1,
            "denominator": 1
          }
        },
        "gain": 1000000,
        "isMuted": false,
        "playbackPolicy": "once"
      }
    ]
  }
}
```

For `globalAudio`, `asset` is:

```json
{"kind":"globalAudio","id":"global-asset-id"}
```

For non-video roles, the `videoLayer` field is omitted. For video roles it is
present as the exact `{sceneID, layerID}` object. Explicit JSON `null` is
rejected. There is exactly one canonical representation for absence.

Encoder ordering:

- sources by `AudioSourceID`;
- tracks by `AudioTrackID`;
- clips by `(trackID, destination.start.ticks, AudioClipID)`.

Input array order is non-semantic and is not rejected by validation.

## Schema migration

- encoder writes v3 only;
- decoder accepts v1/v2/v3;
- v1/v2 must not contain `audio`;
- v1/v2 uplift to v3 with three empty arrays;
- v3 requires `audio`, `sources`, `tracks`, and `clips`;
- re-encoding v1/v2 produces normalized v3;
- unknown or duplicate fields remain strict failures.

## Validation

Manifest-only:

- unique source/track/clip IDs;
- clips resolve source and track;
- every non-empty source and track is used by at least one clip;
- an empty audio manifest has all three tables empty;
- role and `videoLayer` presence agree;
- role and asset kind agree;
- referenced scene exists;
- destination lies inside project duration;
- trim is non-empty;
- gain and policy are valid.

Full document:

- scene reference resolves through `sceneID → payloadID`;
- layer exists in that scene;
- layer content is video;
- source `.videoLayerMedia` equals `VideoBinding.media`.
- audio `sourceTrim` is contained in `VideoBinding.sourceMapping.trimRange`;
- no two video-audio clips reference the same `SceneLayerReference`.

A video layer without an audio clip is legitimate silence. A video-audio clip
that exists is required and must validate.

## Canonical source-time mapping (tech-lead decision; normative)

The project→source mapping is fixed by ADR-012 §1.0a and reproduced here as the
binding contract for this slice. Slice 1 stores and round-trips the fields; it
does not evaluate them. No new stored field is added.

- `AudioClipEntry` has **no** `rate` field, now or in this slice. "No per-clip
  rate" means the rate is never stored on or derived by the clip — **not** that
  every clip is 1/1.
- The rate is **never** `sourceTrim.duration / destination.duration`.
- **Global audio** (`music`/`voiceover`/`soundEffect`) is strict 1/1:
  `sourceTime = sourceTrim.start + (projectTime − destination.start)`.
- **Video-layer audio is NOT necessarily 1/1** — it runs at the video's
  `PlaybackRate` (which may be non-1/1), inherited from `VideoBinding.sourceMapping`
  (next bullet). Only global audio is 1/1.
- **Video-layer audio** uses exactly the referenced layer's full
  `VideoBinding.sourceMapping` — same `rate`, `nativeTimescale`, and anchor —
  through the **same scene-media time the evaluator computes for the video**
  (`mediaPlaybackTime`):

  ```text
  sceneMediaTime(sceneID, T):
    sole:      T − scene.sceneStart
    outgoing:  T − outgoingScene.sceneStart            (post-roll continuation; never frozen)
    incoming:  0       if T <  boundary B               (pre-boundary hold)
               T − B   if T >= boundary B
  sourceTime = VideoBinding.sourceMapping.target(for: sceneMediaTime(sceneID, T))
  ```

  `AudioEvaluator` reuses this exact `sceneMediaTime` + `target(for:)`; it does
  **not** create a separate project→scene mapping. Audio and video share one
  mapping and cannot desynchronize.
- For video-layer audio, `sourceTrim` is **only** an audible window/gate inside
  the video's trim range; it never re-anchors or re-scales the video mapping.
- **Incoming audio is silent during the pre-boundary hold** (incoming media clock
  held at 0 while `T < B`): an incoming-side clip's `destination` **must not start
  before the scene boundary** (`destination.start >= B`). Repeating/stretching one
  audio sample to fill the hold is forbidden.
- **Outgoing audio may continue into the post-roll** iff `destination`,
  `sourceTrim`, and material availability allow it (the `sourceTime ∈ sourceTrim`
  gate and `.once` stop still apply; no special automation).
- A clip is audible at `projectTime` iff `projectTime ∈ destination` **and** the
  computed `sourceTime ∈ sourceTrim` (both half-open).
- `.once` stops at the first end reached (earlier of `destination.end` and the
  end of trimmed source content). No loop, stretch, or implicit extension.

## Evaluation input, resolved sources, and media-active domain (ADR-012 §1.0b)

These are normative for the Slice-2 evaluator boundary; Slice 1 adds **no** stored
field for them.

- **Evaluator input:** the pure `AudioEvaluator` consumes an immutable
  `AudioEvaluationWindow`, not a manifest. An `AudioEvaluationWindowBuilder` builds
  it from the canonical document, an `EvaluationWindowRequirement`, already-loaded
  `ResolvedScenePayload`s, and already-resolved `ResolvedAudioSourceDescriptor`s,
  performing resolution/validation **without I/O or AVFoundation**. `AudioEvaluator`
  stays pure and performs no payload lookup.
- **Resolved audio source:** each `AudioAssetReference` MUST resolve to **exactly
  one** logical stream. `ResolvedAudioSourceDescriptor` carries ≥ `AudioSourceID`,
  a stable stream/provenance identity, exact source duration, source sample rate,
  and channel layout. Zero or multiple matching streams for an existing clip is a
  **typed failure**; silent video is only the **absence** of a clip; stream choice
  must not depend on incidental `AVAsset` track order.
- **Media-active domain:** a video-layer clip's **entire** `destination` must lie
  in the project range where the shared `sceneMediaTime(sceneID, T)` is defined for
  that scene; visual `activeRange`/opacity never constrain audio; incoming
  pre-boundary interval forbidden; outgoing post-roll allowed; any part outside is
  a **typed validation error**. `TimelineEvaluator` and `AudioEvaluator` use **one
  shared helper** for `sceneMediaTime`/the media-active domain — no duplicated math.

## Exact sample mapping

At 240,000 ticks/second and 48,000 samples/second:

```text
ticksPerSample = 5
[startTick, endTick) → [ceilDiv5(startTick), ceilDiv5(endTick))
```

`AudioSampleRange` allows `start == end`: an **empty** range is **zero samples and
zero `AudioPlan` segments, not an error**; only `end < start` is forbidden (the
half-open project interval never produces it). For a non-negative `Int64`,
`ceilDiv5` **cannot overflow** (`t/5 + 1 <= 1_844_674_407_370_955_162 < Int64.max`),
so it is not wrapped in checked arithmetic; a negative input is a typed domain
error. **All other** time/rational arithmetic remains checked and throws a typed
overflow.

## Required tests

Add focused tests for:

- empty/populated v3 round trip;
- v1/v2 uplift;
- required and unknown fields;
- malformed references and enum tags;
- gain boundaries and rejection;
- duplicate/dangling identities;
- orphan source/track and partial-empty-table rejection;
- role/layer/asset-kind combinations;
- scene-layer resolution, image rejection, media mismatch;
- video trim containment and duplicate video-layer audio rejection;
- legitimate silence and required video audio;
- one source reused by multiple clips;
- shuffled construction producing identical bytes;
- exact mapping boundaries; empty range (`start == end`) accepted as zero samples;
  `end < start` rejected; `ceilDiv5(Int64.max)` exact and overflow-free;
- unchanged no-audio evaluator semantics.

Update existing canonical encoding and validation tests where schema v3 changes
expected bytes or errors.

## Verification

Minimum command:

```sh
cd AnimiEngineNext
swift test --filter AnimiEngineCoreTests
```

Also run the repository's canonical package test script/gate required by the
current branch. Store the exact commands and results in the implementation
report.

## Stop conditions

Stop and report instead of improvising if implementation would require:

- AVFoundation, TVECore, or `AnimiApp` in the core;
- a schema shape different from ADR-012;
- `Float`/`Double` canonical gain/time;
- permissive unknown-field handling;
- modifying shipping app/project files;
- changing no-audio render pixels;
- hidden fallback, clamp, loop, crossfade, or ducking behavior.

## Completion

Slice 1 is complete only when the entire gate is green. No legacy code is
deleted and no product cutover is performed in this slice.
