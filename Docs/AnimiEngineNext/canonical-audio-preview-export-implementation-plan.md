# Canonical Audio Preview + Export Implementation Plan

Status: ACTIVE PLAN  
Date: 2026-06-27  
Scope: AnimiApp preview audio, canonical audio render pipeline, later export convergence  
Owner mode: stage-gated implementation; each stage must end with code review, tests, and status update

## 1. Objective

Build the final canonical audio architecture for Animi.

The target is not a temporary playback patch. The target is a deterministic audio pipeline that can support:

- preview audio;
- video-original audio;
- imported music;
- multiple overlapping sources;
- scrub/pause/route behavior;
- future export parity.

Canonical chain:

```text
EditorRuntime state
  -> canonical AudioManifest
  -> AudioEvaluationWindowBuilder
  -> AudioEvaluator
  -> AudioPlan
  -> background/prewarmed PCM render cache
  -> CanonicalAudioRenderPipeline
  -> PreviewAudioGraph
  -> AVAudioEngine output
```

Export convergence chain:

```text
AudioPlan
  -> same canonical PCM renderer/mix semantics
  -> export audio writer / final video mux
```

## 2. Non-negotiable architecture rules

1. `startPlayback` must not synchronously decode compressed media.
2. Live preview must not call `AVAssetReader.copyNextSampleBuffer()` in the Play critical path.
3. `AVAssetReader` may be used only in background/prewarm/cache/export work, never as a direct Play dependency.
4. `AVPlayer` is not the final canonical audio engine. It may only be used for isolated diagnostics if explicitly approved.
5. No silent substitution: a project with real audio must not become a silent epoch because PCM is unavailable.
6. No legacy preview fallback as a success path. Fallback can exist only as temporary safety until hard cutover is verified.
7. No `loopToFit`.
8. No transition ramp invention unless canonical model is explicitly extended.
9. No route-change auto-resume. Route changes are pause-only.
10. Preview and export must converge on the same `AudioPlan` semantics.

## 3. Current starting point

### 3.1. Canonical pieces to keep

Keep and continue building on:

- `AnimiEngineNext/Sources/AnimiEngineCore/Audio/*`
  - `AudioEvaluationWindowBuilder`
  - `AudioEvaluator`
  - `AudioEvaluationWindow`
  - `AudioPlan`
  - `ResolvedAudioSourceDescriptor`
- `AnimiEngineNext/Sources/AnimiEngineCore/Realtime/*`
  - `PreviewAudioGraph`
  - `AudioMasterPreviewSession`
  - `OutputOverloadStage`
  - `AudioSampleMasterClock`
  - scheduler/runtime value types
- `AnimiApp/Sources/EditorRuntime/Realtime/*`
  - `AppAudioManifestBridge`
  - `AppAudioSourceDescriptorResolver`
  - `AppAudioEvaluationBridge`
  - `AppVideoOriginalAudioBridge`
  - `RuntimeCanonicalAudioPlanSource`
  - `CanonicalPreviewAudioController`
  - `CanonicalPreviewAudioControllerFactory`
  - `CanonicalAudioRenderPipeline`

These are the canonical model, bridge, plan, lifecycle, and output surfaces.

### 3.2. Rejected path already removed

The following live-decode path is rejected and must not be restored:

- `PCMDecoder`
- `AVAssetReaderPCMDecoder`
- `AppAudioChunkPreparer`
- tests that proved live `AVAssetReader` decode in preview

Reason: device evidence showed the live compressed-media decode path was not reliable, and Apple documents `AVAssetReader`/`AVAssetWriter` as not intended for real-time processing.

## 4. Final subsystem boundaries

### 4.1. Plan source

`RuntimeCanonicalAudioPlanSource` owns:

- reading current editor state;
- building populated canonical `AudioManifest`;
- building video-original audio entries;
- resolving source URLs;
- producing canonical `AudioPlan`;
- exposing resolved source locations to render pipeline.

It must not:

- decode PCM;
- schedule audio;
- touch `AVAudioEngine`;
- call legacy `AudioCompositionBuilder`;
- return silent `nil` when project has resolvable audio.

### 4.2. Render pipeline

`CanonicalAudioRenderPipeline` owns:

- converting `AudioPlan` + source locations into bounded `PreviewMixSource` chunks;
- using cache/prewarm;
- failing typed when PCM is unavailable.

It must not:

- block `startPlayback`;
- perform unbounded whole-project render for preview;
- hide renderer failure by returning empty sources for non-empty plan.

### 4.3. PCM cache

`CanonicalPCMRenderCache` owns:

- prewarming;
- in-flight request coalescing;
- deterministic eviction;
- revision/epoch invalidation;
- returning ready bounded chunks.

### 4.4. Controller

`CanonicalPreviewAudioController` owns:

- play lifecycle;
- epoch/revision minting;
- first-frame barrier;
- route pause-only;
- scrub silence;
- handoff to render pipeline;
- scheduling returned PCM through `PreviewAudioGraph`.

It must not:

- build legacy audio pipeline;
- decode media directly;
- auto-resume after interruption/route change;
- schedule audio before first frame.

### 4.5. Graph/output

`PreviewAudioGraph` owns:

- applying gain/mute;
- summing sources;
- post-mix `OutputOverloadStage`;
- scheduling explicit output sample time;
- starting/stopping output sink.

It must not:

- fetch media files;
- evaluate timeline;
- perform source decode.

## 5. Stage plan

Each stage must be completed in order. Do not jump to a later stage because it appears quicker.

### Stage 0 — Architecture guard baseline

Goal: lock the reset state so the rejected live-decode path cannot return silently.

Production work:

- no new production behavior;
- keep `CanonicalAudioRenderPipeline` as the only preroll production boundary.

Tests to add/update:

- `CanonicalAudioArchitectureTests.swift`

Required tests:

- realtime preview path does not reference `AVAssetReaderPCMDecoder`;
- realtime preview path does not reference `PCMDecoder`;
- realtime preview path does not reference `AppAudioChunkPreparer`;
- `project.pbxproj` does not reference deleted decoder files;
- `CanonicalPreviewAudioControllerFactory` depends on `CanonicalAudioRenderPipeline`;
- non-empty plan + unavailable renderer fails typed, not silent.

Acceptance:

- targeted app tests pass;
- no deleted live-decode symbols in `AnimiApp/Sources`, `AnimiApp/Tests`, or `AnimiApp.xcodeproj/project.pbxproj`;
- index remains clean unless explicitly staging.

STOP:

- if any live `AVAssetReader` backend is still assembled by factory.

### Stage 1 — PCM render cache skeleton

Goal: add deterministic cache infrastructure without real media decode.

New production files:

- `CanonicalPCMRenderKey.swift`
- `CanonicalPCMChunk.swift`
- `CanonicalPCMRenderCache.swift`
- `CanonicalPCMRenderer.swift`

Expected API shape:

```swift
struct CanonicalPCMRenderKey: Hashable, Sendable {
    let revision: ProjectRevision
    let epoch: PlaybackEpoch
    let planIdentity: String
    let range: AudioSampleRange
}

struct CanonicalPCMChunk: Sendable {
    let range: AudioSampleRange
    let sources: [PreviewMixSource]
}

protocol CanonicalPCMRenderer: Sendable {
    func render(_ request: CanonicalAudioRenderRequest) async throws -> CanonicalPCMChunk
}

actor CanonicalPCMRenderCache {
    func prewarm(_ request: CanonicalAudioRenderRequest) async
    func chunk(for request: CanonicalAudioRenderRequest) async throws -> CanonicalPCMChunk
    func invalidate(revision: ProjectRevision)
    func invalidate(epoch: PlaybackEpoch)
}
```

Rules:

- cache capacity injected;
- no hardcoded queue depths;
- deterministic keying;
- no `Date`, `UUID`, random in key path;
- no AVFoundation in cache skeleton.

Tests:

- same key returns cached chunk;
- different revision misses;
- different epoch misses;
- different range misses;
- invalidate revision removes matching chunks;
- invalidate epoch removes matching chunks;
- concurrent duplicate requests do not produce inconsistent results;
- capacity eviction deterministic.

Acceptance:

- cache works with a fake renderer;
- no media decode yet;
- no app lifecycle behavior changed.

STOP:

- if cache key includes non-deterministic identity;
- if cache hides renderer errors as empty chunks.

### Stage 2 — Cached render pipeline integration

Goal: wire `CanonicalAudioRenderPipeline` to `CanonicalPCMRenderCache`.

New production file:

- `CachedCanonicalAudioRenderPipeline.swift`

Behavior:

- receives `CanonicalAudioRenderRequest`;
- asks cache for bounded `CanonicalPCMChunk`;
- returns `chunk.sources`;
- emits diagnostics for request/cache hit/miss/failure;
- throws typed errors for unavailable/failed render.

Factory behavior:

- production factory uses `CachedCanonicalAudioRenderPipeline`;
- tests can inject fixture renderer/cache;
- unavailable placeholder remains only for explicit tests or if production renderer is not configured.

Diagnostics:

```text
preview.audio.render.request
preview.audio.render.cache.hit
preview.audio.render.cache.miss
preview.audio.render.cache.failed
```

Tests:

- ready cached chunk schedules audio after first-frame barrier;
- cache miss waits asynchronously and then schedules;
- renderer failure triggers typed failure, not silence;
- pause before cache completion schedules nothing;
- stale epoch completion is dropped.

Acceptance:

- controller no longer depends on placeholder in production assembly;
- fixture-rendered audio reaches `PreviewAudioGraph` in unit tests;
- no real media decode yet.

STOP:

- if `startPlayback` blocks waiting synchronously for rendering;
- if non-empty plan can produce empty source list without typed error.

### Stage 3 — Source-to-PCM renderer with fixture decoder

Goal: implement canonical segment-to-source rendering logic using an injected decoder.

New production files:

- `CanonicalPCMAssetDecoder.swift`
- `CanonicalSegmentPCMRenderer.swift`

API:

```swift
protocol CanonicalPCMAssetDecoder: Sendable {
    func decode(
        source: CanonicalResolvedAudioSource,
        sourceStart: RationalSourceTime,
        frameCount: Int
    ) async throws -> [Float32]
}
```

Renderer responsibilities:

- intersect requested range with each `AudioSegmentPlan.destinationSamples`;
- compute exact bounded source start from `segment.sourceStart`;
- call decoder for exact frame count;
- build `PreparedAudioBuffer`;
- preserve gain/mute/stream/channel metadata;
- return one `PreviewMixSource` per audible source segment.

Rules:

- gain/mute are carried to `PreviewAudioGraph`, not pre-applied here;
- final limiter remains post-mix in `PreviewAudioGraph`;
- exact rational source-time math only;
- no µs truncation for source position;
- no loop;
- no source URL -> typed failure.

Tests:

- music-only segment renders one source;
- video-original segment renders one source;
- music + video-original renders two sources;
- source start at segment start is exact;
- interior offset is exact rational;
- gain/mute carried unchanged;
- missing source fails typed;
- decoder returns short buffer -> typed failure unless explicit zero-pad policy is approved;
- two overlapping sources produce two `PreviewMixSource`s for graph mixing.

Acceptance:

- full controller path passes with fixture decoder;
- no AVFoundation decoder yet;
- no device claim.

STOP:

- if renderer applies final limiting before graph mix;
- if renderer approximates source time with `Double`.

### Stage 4 — Real AVFoundation background decoder

Goal: implement real compressed media decode behind `CanonicalPCMAssetDecoder`, outside the Play critical path.

New production file:

- `AVFoundationPCMAssetDecoder.swift`

Allowed:

- AVFoundation import in this app-side decoder file;
- async asset property loading;
- bounded decode for a requested source range;
- cancellation and timeout;
- use during prewarm/cache/export.

Forbidden:

- direct call from `CanonicalPreviewAudioController.startPlayback`;
- synchronous property loading on main thread;
- unbounded whole-project preview render;
- no-timeout `copyNextSampleBuffer` loop.

Required diagnostics:

```text
preview.audio.decode.begin
preview.audio.decode.track.loaded
preview.audio.decode.reader.start
preview.audio.decode.samples
preview.audio.decode.end
preview.audio.decode.failed
preview.audio.decode.timeout
preview.audio.decode.cancelled
```

Tests:

- fixture decoder remains primary unit path;
- real decoder has unit tests only if deterministic small fixture exists in repo;
- otherwise real decoder is device-gated, not claimed by simulator unit tests.

Device smoke for this stage:

- music-only project;
- no video playback started yet;
- prewarm completes;
- cache stores chunk;
- Play consumes cached chunk.

Acceptance:

- decode happens before Play or off Play critical path;
- app remains responsive;
- no SIGKILL;
- no indefinite hang; timeout is typed.

STOP:

- if decoder blocks device without timeout;
- if decoder requires active video playback to be stopped incorrectly;
- if decoder path cannot produce a chunk for music-only.

### Stage 5 — Prewarm scheduling

Goal: render first audio chunk before explicit Play whenever possible.

Prewarm triggers:

- project loaded;
- imported audio changed;
- video slot changed;
- timeline duration changed;
- playhead settled after scrub;
- route/output format changed if required.

Do not prewarm:

- continuously during active scrub drag;
- after stale revision;
- for invalidated epoch;
- unbounded future ranges.

Config:

```swift
struct CanonicalAudioPrewarmConfig: Sendable {
    let maxChunkSamples: Int64
    let lookaheadChunkCount: Int
    let maxConcurrentJobs: Int
}
```

Rules:

- all values injected;
- no hardcoded depth;
- cache invalidation on edit;
- coalesce duplicate prewarm requests.

Tests:

- playhead settle triggers prewarm;
- scrub drag does not schedule audio;
- edit invalidates old revision;
- route change invalidates output-dependent chunks if needed;
- duplicate requests coalesce;
- prewarm failure is diagnostic, not crash.

Acceptance:

- Play can hit cache for first chunk in normal path;
- Play can bounded-wait on cache miss;
- no UI freeze.

STOP:

- if Play starts a new raw decode instead of using cache/render pipeline;
- if stale chunks can be scheduled after edit.

### Stage 6 — Hard canonical preview cutover

Goal: canonical audio path no longer depends on legacy preview audio.

Work:

- remove legacy preview fallback as canonical success path;
- keep toggle OFF only as temporary comparison path if owner wants;
- canonical ON must not call `buildAudioExportPlan`;
- canonical ON must not instantiate `EnginePreviewAudioPlaybackController`;
- canonical failure must be visible diagnostic state, not silent.

Tests:

- toggle ON never calls legacy build gate;
- toggle ON never calls legacy audio controller;
- music-only preview uses canonical cache/render path;
- video-original-only preview uses canonical cache/render path;
- music + video-original preview uses canonical cache/render path;
- scrub stays silent;
- pause stops output;
- route change pause-only.

Acceptance:

- canonical preview path is self-contained;
- legacy fallback is not counted as success;
- visible diagnostics identify failure stage.

STOP:

- if no-sound can still route silently through legacy fallback;
- if canonical ON uses legacy build gate.

### Stage 7 — Device gate: audible preview

Goal: prove real sound on physical device.

Device scenarios:

1. music-only;
2. video-original-only;
3. music + video-original;
4. scrub while playing;
5. pause/play;
6. route change / headphones;
7. long video;
8. stress project with multiple videos.

Required markers:

```text
preview.audio.canonical.selected
preview.audio.canonical.plan segments=N
preview.audio.render.prewarm.begin
preview.audio.render.prewarm.end
preview.audio.render.cache.hit
preview.audio.graph.schedule.begin
preview.audio.graph.schedule.end
preview.audio.engine.start.end
preview.audio.player.play.end
```

Pass criteria:

- operator hears audio;
- music audible;
- video-original audio audible;
- mixed music + video-original audible;
- scrub does not play audio;
- pause stops audio;
- route change pauses without auto-resume;
- app remains responsive;
- no SIGKILL;
- no legacy fallback used for canonical success.

Failure protocol:

- identify last successful marker;
- identify missing next marker;
- do not say “probably”;
- no new implementation until failure point is proven.

Acceptance:

- device evidence document committed with raw marker logs;
- cutover not complete until audible operator confirmation exists.

STOP:

- if app is silent and marker chain does not identify the exact failed boundary.

### Stage 8 — Export convergence

Goal: canonical export uses the same audio plan and render semantics.

Work:

- introduce `CanonicalAudioExportRenderer`;
- reuse `AudioPlan`;
- reuse segment source mapping;
- reuse gain/mute semantics;
- reuse post-mix `OutputOverloadStage`;
- output to export writer/muxer boundary.

Do not:

- reuse preview `AVAudioEngine`;
- reintroduce legacy `AudioCompositionBuilder` as canonical export;
- fork gain/mix/limiter behavior between preview and export.

Tests:

- deterministic corpus preview/export PCM parity;
- music-only export;
- video-original export;
- music + video-original export;
- overlapping sources;
- output overload clamp;
- muted source;
- gain source;
- source trim;
- no loop.

Acceptance:

- preview and export share canonical audio semantics;
- export no longer relies on legacy audio composition for canonical path.

STOP:

- if export requires a different source-time mapping than preview.

### Stage 9 — Legacy cleanup

Goal: remove obsolete legacy preview audio code only after canonical preview is device-proven.

Candidates for removal or isolation:

- legacy preview-audio build gate;
- legacy preview audio controller;
- legacy temp audio render path for preview;
- fallback-only code branches;
- stale docs claiming legacy preview is canonical.

Do not remove:

- export code until Stage 8 has landed;
- shared app audio session management if still used by canonical output;
- tests that guard toggle OFF until owner approves deleting toggle.

Acceptance:

- no unused legacy preview audio path remains in canonical ON mode;
- app builds;
- canonical preview device gate remains green;
- export gate remains green.

STOP:

- if deleting legacy preview code also deletes still-needed export support.

## 6. Global diagnostics contract

Every implementation stage must preserve marker chain clarity.

Minimum canonical markers:

```text
preview.audio.canonical.selected
preview.audio.canonical.plan
preview.audio.render.request
preview.audio.render.cache.hit
preview.audio.render.cache.miss
preview.audio.render.prewarm.begin
preview.audio.render.prewarm.end
preview.audio.render.failed
preview.audio.graph.schedule.begin
preview.audio.graph.schedule.end
preview.audio.engine.start.begin
preview.audio.engine.start.end
preview.audio.player.play.begin
preview.audio.player.play.end
preview.audio.route.pauseOnly
preview.audio.scrub.silent
```

Rules:

- no device claim without raw markers;
- no audible claim without operator confirmation;
- no “probable root cause” if markers can be added;
- every failure report must include last successful marker and expected next marker.

## 7. Global test gates

Run appropriate gates per stage.

Minimum app gates:

```text
CanonicalAudioArchitectureTests
CanonicalPreviewAudioControllerTests
CanonicalCutoverBypassTests
RuntimeCanonicalAudioPlanSourceTests
VideoOriginalAudioPlanTests
AppVideoOriginalAudioBridgeParityTests
PreviewAudioToggleSelectionTests
ProjectAudioPreviewPlaybackTests
```

Minimum engine gates:

```text
PreviewAudioGraphContractTests
AudioMasterPreviewSessionTests
SilentScrubAudioTests
InterruptionRouteChangePauseOnlyTests
AudioSessionAdapterContractTests
AudioEvaluatorTests
AudioEvaluationWindowBuilderTests
```

Device gate is mandatory before claiming preview complete.

## 8. Definition of done

Canonical preview is complete only when all are true:

- toggle ON uses canonical plan/render/cache/graph path;
- no legacy fallback is used for success;
- music-only is audible on device;
- video-original-only is audible on device;
- music + video-original is audible on device;
- scrub is silent;
- route change is pause-only;
- no Play-path `AVAssetReader`;
- app remains responsive;
- raw markers prove the path;
- operator confirms sound.

Canonical audio architecture is complete only when all are true:

- preview complete;
- export uses same canonical `AudioPlan` semantics;
- deterministic preview/export parity tests pass;
- legacy preview audio path is removed or isolated as non-canonical;
- docs reflect actual code.

## 9. Immediate next action

Start with Stage 0.

Do not implement real decoder first.

Order for next work session:

1. add `CanonicalAudioArchitectureTests`;
2. prove deleted live-decode path cannot return;
3. add `CanonicalPCMRenderCache` skeleton;
4. wire fixture renderer through cache;
5. only then add real AVFoundation background decoder.

