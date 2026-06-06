# Media Template Editor Architecture 2026

Research date: 2026-06-02

Scope: Animi iOS app, template-based video editor with user media slots, animated text,
audio, preview, scrub, trim, and export.

## 1. Verdict

For the product contract now stated by the user, the current implementation is not a
sufficient final architecture.

This does not mean the existing Apple API choices are wrong. `AVPlayerItemVideoOutput`
for preview and `AVAssetReader` / `AVAssetWriter` for custom Metal export are valid
building blocks. The problem is architectural: current video/audio/text behavior is not
owned by one deterministic timeline/media graph.

The target product is not a simple "replace photo with video" feature. It is a mobile
template video editor comparable in capability class to products like VN, Mojo, TikTok /
Instagram creative tools, Unfold, and InVideo: multi-layer user media, animated text,
music, original clip audio, trim, transitions, templates, and final export.

That class of product needs:

- one canonical timeline clock;
- one render graph for preview and export;
- one media asset model with source metadata, proxies, and capabilities;
- one frame sampling policy shared by preview and export;
- one audio graph shared by preview and export;
- one text layout/animation sampler shared by preview and export;
- explicit performance budgets and proxy/render-cache strategy.

Without those, 100% preview/export parity is not achievable in a maintainable way.

## 2. Product Contract Used For This Research

The architecture below assumes these product requirements:

- Video is a core feature, not an experimental slot type.
- Video must work in all media slots.
- A photo slot with video input behaves as a full video layer, not as a moving photo.
- A scene can contain at least four independent video blocks.
- Timeline transitions can make two scenes resident at once, so 8-12 video blocks can be
  relevant at the same time.
- Each video slot can have its own original audio, volume, trim, duration, and source
  properties.
- Preview and export must match 100% in timing, chosen frames, trim, text animation,
  audio timing, and slot settings.
- Preview may use lower resolution/proxy quality, but it must not use different timing.
- Pause must show the exact frame. Scrub may be approximate while dragging, then settle
  to the exact frame.
- Export currently targets MP4/H.264/30 fps, with future codec/FPS options possible.
- Unsupported media must fail visibly during import.
- Missing video on project restore opens the block empty.
- Missing audio track in a video is normal silent video.
- If final export cannot include expected original audio, the user must be asked whether
  to export silent or cancel.
- Animated text must match preview/export exactly.
- Future roadmap includes video backgrounds, animated stickers/GIFs, multi-track audio,
  per-template sound design, speed control, captions/subtitles, and on-device export.

## 3. Official Apple Research Summary

### 3.1 AVFoundation is the correct foundation

Apple positions AVFoundation as the framework for playback, capture, editing, reading,
writing, and processing time-based audiovisual media:

- AVFoundation overview:
  https://developer.apple.com/documentation/avfoundation/
- Video technology overview:
  https://developer.apple.com/documentation/technologyoverviews/video/
- Loading media data asynchronously:
  https://developer.apple.com/documentation/avfoundation/loading-media-data-asynchronously

For Animi, this means:

- Use AVFoundation/Core Media for asset inspection, timing, sample reading/writing,
  composition, audio mixing, and export.
- Load asset and track properties through async AVFoundation APIs instead of scattering
  synchronous metadata reads through preview/export paths.
- Use Metal for Animi's template rendering, masks, effects, compositing, and final pixels.
- Do not use UIKit/CoreAnimation-only preview shortcuts for anything that must match export.

### 3.2 Simple export and complex custom export are different products

Apple's AVFoundation Programming Guide describes `AVAssetExportSession` for common
export/transcode workflows, and `AVAssetReader` / `AVAssetWriter` for workflows that
need sample-level control:

- Export guide:
  https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/AVFoundationPG/Articles/05_Export.html
- AVAssetReader:
  https://developer.apple.com/documentation/avfoundation/avassetreader
- AVAssetWriter:
  https://developer.apple.com/documentation/avfoundation/avassetwriter

Animi is in the complex custom export category because every exported frame is a Metal
render of template commands, user videos, masks, text, transitions, and effects. A plain
`AVAssetExportSession` cannot own the full product.

### 3.3 AVVideoComposition and custom compositors matter conceptually

Apple's composition APIs establish the model Animi should mirror:

- `AVVideoComposition.frameDuration` defines the cadence of composed output frames:
  https://developer.apple.com/documentation/avfoundation/avvideocomposition/frameduration
- `AVVideoComposition.sourceTrackIDForFrameTiming` shows that frame timing can be
  derived from source tracks or `frameDuration`:
  https://developer.apple.com/documentation/avfoundation/avvideocomposition/sourcetrackidforframetiming
- `AVVideoCompositing` defines a custom compositor protocol:
  https://developer.apple.com/documentation/avfoundation/avvideocompositing
- `AVAsynchronousVideoCompositionRequest` gives a compositor `compositionTime` and
  source frames/sample buffers by track ID:
  https://developer.apple.com/documentation/avfoundation/avasynchronousvideocompositionrequest
- `AVAssetReaderVideoCompositionOutput` can read composited video frames from video
  tracks:
  https://developer.apple.com/documentation/avfoundation/avassetreadervideocompositionoutput

Animi does not have to move all rendering into `AVVideoCompositing`, because the existing
Metal renderer is already the domain renderer. But Animi should adopt the same conceptual
contract: every render request is "compose output frame at composition time T from required
source tracks/layers".

### 3.4 Apple does not magically turn low FPS into real high FPS

Apple media playback is timestamp-based. It does not create real frames that were never
present unless an app uses interpolation/synthesis.

Relevant APIs:

- `AVPlayerItemOutput.itemTime(forHostTime:)` maps display/host time into media time:
  https://developer.apple.com/documentation/avfoundation/avplayeritemoutput/itemtime%28forhosttime%3A%29
- `AVPlayerItemVideoOutput.pixelBufferAndDisplayTime(forItemTime:)` returns a buffer
  appropriate for an item time:
  https://developer.apple.com/documentation/avfoundation/avplayeritemvideooutput/pixelbufferanddisplaytime%28foritemtime%3A%29
- `AVAssetReaderTrackOutput` reads sample buffers and their presentation timestamps:
  https://developer.apple.com/documentation/avfoundation/avassetreadertrackoutput

For 16/24 fps source in a 30 fps template, there are only three real policies:

- timestamp-faithful hold/repeat;
- temporal blend;
- generated interpolation / optical flow.

"No duplicate frames" is impossible without synthetic frame generation. The product must
choose a policy. For a deterministic editor, the default should be timestamp-faithful
sampling, with optional "smooth motion" interpolation as a future feature.

### 3.5 Pixel format and color choices are product policy, not incidental code

Apple's reader docs note that native YCbCr formats are often better for H.264 decode
performance, and high-bit-depth formats matter for preserving ProRes/HDR-style sources:

- AVAssetReaderTrackOutput:
  https://developer.apple.com/documentation/avfoundation/avassetreadertrackoutput

Apple's color tagging documentation is especially important:

- Tagging media with video color information:
  https://developer.apple.com/documentation/avfoundation/media_reading_and_writing/tagging_media_with_video_color_information
- Editing and playing HDR video:
  https://developer.apple.com/documentation/avfoundation/video_effects/editing_and_playing_hdr_video
- Dolby Vision/HDR AVFoundation PDF:
  https://developer.apple.com/av-foundation/Incorporating-HDR-video-with-Dolby-Vision-into-your-apps.pdf

Implication:

- If Animi exports SDR H.264 MP4 today, it must explicitly define Rec. 709 SDR output and
  tag buffers/writer settings accordingly.
- HDR/P3/10-bit support is a separate product capability and should not be accidental.
- For preview proxies, color conversion must be explicit, otherwise preview/export color
  differences will appear.

### 3.6 Output settings should be generated and validated

Apple provides `AVOutputSettingsAssistant` for creating writer settings:

- AVOutputSettingsAssistant:
  https://developer.apple.com/documentation/avfoundation/avoutputsettingsassistant
- AVOutputSettingsPreset:
  https://developer.apple.com/documentation/avfoundation/avoutputsettingspreset
- AVAssetWriter can validate settings and add inputs:
  https://developer.apple.com/documentation/avfoundation/avassetwriter

Implication:

- Export presets should not be ad hoc dictionaries only.
- H.264 MP4 30 fps is a valid initial product constraint, but settings should be modeled
  as an export preset and checked for writer compatibility.

### 3.7 Audio: AVAudioSession, AVMutableComposition, AVAudioMix

Apple's audio session docs say media playback apps should configure an audio session, and
usually activate it when playback begins:

- AVAudioSession:
  https://developer.apple.com/documentation/avfaudio/avaudiosession

Apple's AVFoundation docs support audio mixing through compositions and audio mixes:

- AVMutableComposition:
  https://developer.apple.com/documentation/avfoundation/avmutablecomposition
- AVMutableAudioMix:
  https://developer.apple.com/documentation/avfoundation/avmutableaudiomix
- AVAssetReaderAudioMixOutput:
  https://developer.apple.com/documentation/avfoundation/avassetreaderaudiomixoutput

Apple's HLS audio guidance says AAC sample rates are normally 44.1 kHz or 48 kHz:

- Preparing audio for HLS:
  https://developer.apple.com/documentation/http-live-streaming/preparing-audio-for-http-live-streaming

Recommendation for Animi:

- Use 48 kHz stereo AAC as the current video-editor export default.
- Keep 44.1 kHz valid for source material and conversion.
- Use one canonical internal audio graph; preview and export should read from the same
  graph.
- Use visible user decisions for degraded audio export.

### 3.8 Text must be deterministic

Apple's text systems:

- Core Text:
  https://developer.apple.com/documentation/coretext
- TextKit:
  https://developer.apple.com/documentation/uikit/textkit
- Core Text typesetter:
  https://developer.apple.com/documentation/coretext/cttypesetter
- Core Text framesetter:
  https://developer.apple.com/documentation/coretext/ctframesetter

Core Text provides low-level layout, glyph runs, font metrics, fallback, and drawing.
TextKit provides higher-level text layout APIs.

For Animi's preview/export parity:

- Do not use `UILabel`/UIKit preview and a separate export text renderer.
- Resolve text layout once into deterministic glyph/layout data.
- Use the same font resolver, attributed-string model, line wrapping, glyph positions,
  kerning, emoji/fallback policy, and animation sampler for preview/export.

### 3.9 Metal performance guidance maps directly to Animi

Apple's Metal best practices:

- Command buffers: submit the fewest possible command buffers per frame without
  underutilizing the GPU:
  https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/CommandBuffers.html
- Triple buffering for dynamic data:
  https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/TripleBuffering.html
- Resource options:
  https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/ResourceOptions.html
- Resource heaps:
  https://developer.apple.com/library/archive/documentation/Miscellaneous/Conceptual/MetalProgrammingGuide/ResourceHeaps/ResourceHeaps.html
- Metal feature/capability tables:
  https://developer.apple.com/metal/capabilities/

Implication:

- Animi needs bounded texture pools, pixel-buffer pools, CVMetalTextureCache lifecycle,
  render-ahead limits, and device-class budgets.
- "Unlimited videos" means unlimited user intent, not unlimited simultaneous decoders.
  The app must schedule, proxy, cache, and degrade quality/resolution before it degrades
  time.

### 3.10 Import type support must use capability checks

Relevant Apple systems:

- PhotoKit:
  https://developer.apple.com/documentation/photokit
- PHAssetResource:
  https://developer.apple.com/documentation/photokit/phassetresource
- Uniform Type Identifiers:
  https://developer.apple.com/documentation/uniformtypeidentifiers
- UTType movie:
  https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/movie
- UTType GIF:
  https://developer.apple.com/documentation/uniformtypeidentifiers/uttypegif

Implication:

- "Popular formats" should be implemented as accepted UTTTypes plus actual decode/export
  capability checks.
- GIF is not a video file; treat it as an animated image source with its own frame timing.
- Slow-motion and VFR content must be modeled by timestamps, not nominal FPS.

## 4. Public Reference Product Patterns

Internal architectures for TikTok, Instagram, Mojo, Unfold, InVideo, and VN are not public
sources. They should not be treated as implementation evidence.

Publicly visible capabilities still define the product class:

- VN advertises multi-track editing, PIP video/photo/text layers, keyframe animation,
  speed control, Dolby Vision HDR support, and export up to 4K/60 fps on the App Store:
  https://apps.apple.com/us/app/vn-video-editor/id1343581380
- Mojo advertises templates, text effects, and high-quality animations:
  https://mojo-app.com/
- InVideo advertises AI-assisted video editing, scenes, voiceover, captions, transitions,
  and social-video workflows:
  https://invideo.io/make/ai-video-editor/

The common architecture implied by this product class:

- non-destructive timeline model;
- asset library / media registry;
- proxy preview pipeline;
- deterministic export pipeline;
- render cache / preview cache;
- per-layer keyframes and animation curves;
- audio graph with clip audio, music, voiceover, and ramps;
- visible validation and import errors;
- device-specific performance budgets.

## 5. Current Animi Audit Against This Contract

### 5.1 What is already directionally correct

- Export uses the same Metal renderer path conceptually documented in
  `Docs/RENDERING_PIPELINE.md`.
- Export already uses `AVAssetWriter` and GPU render-to-pixel-buffer style output.
- Runtime video preview uses `AVPlayerItemVideoOutput`, which is a valid preview frame
  extraction API.
- Export video extraction uses `AVAssetReader`, a valid deterministic export primitive.
- Video trim/audio state is persisted URL-less in `PersistedVideoSelection`, with URL
  resolved by `MediaRef`.
- There is a shared `VideoTimelineTimeMapper`, which is the beginning of a canonical time
  model.
- Orientation is handled through `VideoPresentationInfo` and a UV transform path in the
  renderer.
- Audio export uses `AVMutableComposition` / `AVMutableAudioMix`, which is the right
  foundation for mixing.
- Preview resources are separated from export resources more than they used to be, and
  there is memory work recorded in `Docs/memory/gpu-resource-baseline-pr0.md`.

### 5.2 Current critical gaps

These are not theoretical refactors. Under the stated product contract, they are product
risks.

#### Gap 1: no single authoritative media graph

Current video behavior is split across:

- template schema: `TVECore/Sources/TVECore/Models/MediaInput.swift`;
- persisted selection: `AnimiApp/Sources/Project/SceneState.swift`;
- preview provider: `AnimiApp/Sources/UserMedia/VideoFrameProvider.swift`;
- runtime user media service: `AnimiApp/Sources/UserMedia/UserMediaService.swift`;
- export provider: `AnimiApp/Sources/Export/ExportVideoFrameProvider.swift`;
- export slots coordinator: `AnimiApp/Sources/Export/ExportVideoSlotsCoordinator.swift`;
- audio builder: `AnimiApp/Sources/Export/AudioCompositionBuilder.swift`;
- preview audio: `AnimiApp/Sources/EditorRuntime/EditorRuntimePreviewAudioCoordinator.swift`.

There is no single object that says: "for slot X at composition time T, this is the exact
video frame, audio sample region, transform, color policy, trim policy, loop/hold policy,
and template/user audio policy."

#### Gap 2: template audio settings are not enforced

`MediaInput.audio.enabled/gain` exists in schema, but the runtime/export audio behavior
primarily uses `VideoSelection.isMuted/volume` and `VideoAudioPolicy`.

Under the product contract, audio is configurable at slot, scene, and template level. The
current schema field is either dead or underimplemented.

#### Gap 3: preview/export video sampling are different models

Preview uses `AVPlayerItemVideoOutput` and host-time item time. Export uses
`AVAssetReader` with sequential sample decode and a blend policy. Even if both are valid
APIs, they are not automatically the same sampling algorithm.

For 100% parity, both paths must call the same frame selection function.

#### Gap 4: preview audio and export audio fail differently

Export audio builds scene audio data strictly. Preview audio has a resilient path that can
skip failed scenes. That is acceptable for a best-effort preview, but not for a product that
requires preview audio to match export audio.

#### Gap 5: UI can persist state that runtime failed to apply

Video volume application uses a silent `try?` in the scene edit UI. That can hide runtime
validation/provider failures while still dispatching a persisted selection update.

#### Gap 6: validation happens after unnecessary decode

`UserMediaService.setVideo` requests a poster before strict persisted trim validation. The
correct order is: inspect asset -> validate slot spec -> build poster/proxy -> commit.

#### Gap 7: current color pipeline is implicit SDR/BGRA8

Preview/export request BGRA8-style buffers and writer settings are H.264/AAC MP4. That is
acceptable only if Phase 1 explicitly declares "SDR Rec. 709 H.264 MP4 export". It is not
acceptable as an accidental behavior for HDR/P3/10-bit sources.

#### Gap 8: optional `videoWindow` weakens the invariant

Factory methods require a video window, but persisted/Codable structures still allow a
video slot with missing `videoWindow`. Restore/export catch this late. That is workable for
backward compatibility, but the media graph should normalize it earlier.

#### Gap 9: ingest is not a complete capability pipeline

Current ingest validates duration, but the product needs source capabilities:

- video track presence;
- audio tracks and channel layout;
- color/HDR/wide-gamut tags;
- nominal and real frame timing;
- VFR/slow-motion behavior;
- orientation/clean aperture;
- decode support;
- export support;
- proxy availability.

#### Gap 10: no text parity architecture yet

Animated text with exact preview/export parity cannot be layered as a UIKit preview feature
and a different export feature. It needs a deterministic text layout and animation model in
the same render graph as video.

## 6. Required Target Architecture

### 6.1 High-level architecture

```text
Import Sources
  -> Media Ingest + Capability Probe
  -> Original Asset Store
  -> Proxy/Preview Asset Store
  -> MediaAssetRecord

Project Timeline
  -> Composition Graph Builder
  -> Slot Playback Specs
  -> Text Layout/Animation Specs
  -> Audio Graph Specs

Composition Clock
  -> Frame Resolver
  -> Audio Resolver
  -> Render Command Graph

Preview Renderer
  -> proxy media, same time decisions, lower resolution allowed

Export Renderer
  -> original/full-quality media, same time decisions, full resolution
```

Preview and export differ in quality target and execution speed. They must not differ in:

- timeline time;
- selected source frame;
- trim/loop/hold behavior;
- text animation state;
- audio mix timing;
- layer order;
- transforms;
- masks;
- transition math.

### 6.2 Canonical clock

Introduce `CompositionClock` / `TimelineClock`:

- stores export FPS as a rational `CMTime`, not `Double`;
- stores frame index -> composition time mapping;
- stores project time and scene-local time as `CMTime`;
- supports future variable export FPS only by changing the clock model, not by spreading
  `Double(sceneFPS)` through services.

Initial policy:

- Export FPS: 30 fps.
- Preview playback for parity mode samples the same 30 fps composition frame grid.
- Display may be 60/120 Hz, but rendered content advances on canonical composition frames.
- Scrub can request approximate frames during drag, then settle exact.

### 6.3 Canonical frame sampling

Introduce `FrameSamplingPolicy` and `SourceFrameMap`.

`SourceFrameMap` for each video/animated image:

- source duration;
- decoded sample PTS list;
- sample durations if available;
- timescale;
- nominal FPS;
- min frame duration;
- VFR flag;
- orientation/transform;
- color tags;
- audio track mapping;
- source time ranges for slow-motion/edited Photos assets if applicable.

`FrameSamplingPolicy`:

- default: timestamp-faithful hold/repeat;
- optional future: blend;
- optional future: optical-flow interpolation / smooth motion.

The required function:

```swift
resolveVideoFrame(
    asset: MediaAssetRecord,
    slot: VideoSlotPlaybackSpec,
    compositionTime: CMTime
) -> VideoFrameDecision
```

`VideoFrameDecision` should include:

- source time;
- source sample identity or bracketing samples;
- exact/approximate flag;
- hold/loop state;
- reason for no frame;
- expected display timestamp;
- color/orientation metadata.

Both preview and export must use this exact function.

### 6.4 Slot playback spec

Replace loose slot state with a normalized `VideoSlotPlaybackSpec`:

```swift
struct VideoSlotPlaybackSpec {
    let slotId: String
    let assetId: MediaAssetID
    let visibleRange: CMTimeRange
    let trimRange: CMTimeRange
    let playbackMode: VideoPlaybackMode // holdLast, loop
    let speed: Rational // future
    let placement: MediaPlacementState
    let templateAudioPolicy: TemplateAudioPolicy
    let sceneAudioPolicy: SceneAudioPolicy
    let slotAudioPolicy: SlotAudioPolicy
    let transformPolicy: TransformPolicy
}
```

This spec is the only input to preview/export for a video slot.

### 6.5 Audio graph

Introduce a canonical `AudioGraphSpec`.

Audio sources:

- original video audio per slot;
- imported music;
- voiceover;
- future template sound design;
- future generated voice/captions;
- future scene/transition effects.

Gain policy:

```text
effectiveGain = masterGain * templateGain * sceneGain * slotGain * automationGain(t)
```

Disable policy:

- template can disable original video audio;
- UI volume remains visible but locked;
- tapping locked control shows an alert explaining the template restriction.

Current recommended output:

- MP4 audio: AAC-LC, stereo, 48 kHz.
- Internal mix: 48 kHz float pipeline.
- Source conversion: explicit and high quality.
- Missing video audio track: silent video, not an error.
- Preview audio failure: visible error + playback without audio, matching user's contract.
- Export original-audio failure: ask user to continue silent or cancel.

Preview must not use a different audio graph from export. It may render the same graph to a
temporary PCM/proxy file for low-latency playback, but the graph and timing must be the same.

### 6.6 Text graph

Animated text must be part of the same composition graph.

Required model:

```swift
struct TextLayerSpec {
    let text: AttributedTextModel
    let layoutBox: Rect
    let fontPolicy: FontPolicy
    let paragraphPolicy: ParagraphPolicy
    let animation: TextAnimationSpec
    let timing: CMTimeRange
}
```

Required deterministic pipeline:

- resolve fonts by stable font descriptors;
- layout text with one engine, preferably Core Text for low-level deterministic glyph runs;
- store glyph runs, positions, line fragments, baselines, fallback fonts, emoji handling;
- animate transforms/opacities/effects by sampling the same animation curves at
  `compositionTime`;
- render glyphs through the same Metal renderer in preview/export.

Forbidden for parity:

- UIKit label preview + separate export renderer;
- Core Animation text animation in preview + Metal export;
- different font fallback between preview/export;
- text layout recomputed in multiple places with different constraints.

### 6.7 Render graph

All visual layers should compile into a canonical graph:

```text
FrameRenderPlan(frameTime)
  - scene residency
  - block visibility
  - media frame decisions
  - text animation decisions
  - masks/mattes
  - transitions
  - render commands
```

Existing `RenderCommand` and `MetalRenderer` are a useful foundation. The missing piece is
that user media video/text/audio decisions must be resolved before render, by one planner,
not inside scattered services.

### 6.8 Preview renderer

Preview is not "best effort timing". It is "same timing, lower quality if needed".

Allowed preview degradation:

- lower resolution proxy;
- lower bitrate proxy;
- SDR proxy for Phase 1;
- render cache;
- skipped visual effect quality if product explicitly allows.

Not allowed:

- different source frame choice;
- different trim/loop behavior;
- different text animation timing;
- audio graph silently skipping scenes;
- runtime state diverging from persisted state.

For many simultaneous videos, preview needs:

- proxy assets;
- decoder scheduler;
- render-ahead cache;
- LRU frame cache;
- resident-scene prioritization;
- device-class budgets;
- first-frame fallback while loading.

### 6.9 Export renderer

Export uses:

- original media or highest-quality approved proxy;
- same `FrameRenderPlan`;
- same `VideoFrameDecision`;
- same text layout and animation sampler;
- same audio graph;
- full output resolution;
- deterministic writer settings;
- explicit color tagging.

Export may be slower than real time. It must not use preview shortcuts.

### 6.10 Ingest and proxy pipeline

Ingest steps:

1. Accept source from Photos, Files, camera capture, iCloud, or app storage.
2. Copy/save original durably.
3. Build `MediaAssetRecord`.
4. Probe source asynchronously with AVFoundation:
   - duration;
   - tracks;
   - audio layout;
   - frame timing;
   - orientation;
   - clean aperture;
   - color tags;
   - HDR/wide gamut;
   - codec/container;
   - decode support.
5. Generate preview proxy if required.
6. Generate poster/exact first frame only after source spec validates.
7. Reject unsupported assets visibly.

For Photos/iCloud:

- do not assume immediate local file availability;
- represent import as an async job with visible progress/failure.

For GIF:

- store as animated image source;
- extract frame timings;
- map into the same `FrameSamplingPolicy`;
- export as video frames.

### 6.11 Color and HDR policy

Phase 1 recommended policy:

- Output: SDR Rec. 709 MP4/H.264, 30 fps.
- Audio: AAC-LC stereo 48 kHz.
- HDR/P3 source: convert/tag intentionally, show user-visible note if needed.
- Do not claim HDR export.

Future policy:

- HEVC export;
- HDR/Dolby Vision-aware path;
- wide color compositor;
- `supportsHDRSourceFrames` / `supportsWideColorSourceFrames` if using custom compositor;
- color-managed Metal pipeline.

### 6.12 Resource and decoder scheduling

There is no professional "unlimited live decoder" architecture on a phone.

Correct model:

- unlimited project intent;
- bounded active resources;
- proxies;
- prefetch;
- render cache;
- deterministic fallback;
- visible loading state.

Scheduler priorities:

1. currently visible slots in current scene;
2. incoming/outgoing transition scene slots;
3. near-future slots for prefetch;
4. edit target slot;
5. poster-only/offscreen slots.

If resource pressure occurs:

- reduce proxy resolution first;
- reduce render-ahead window;
- evict offscreen frame caches;
- keep composition timing stable;
- do not silently desynchronize preview/export.

## 7. Recommended Migration Plan

### Phase 0: Product decisions

Lock these decisions in documentation:

- Phase 1 export is SDR Rec. 709 H.264 MP4 30 fps.
- Audio export is AAC-LC stereo 48 kHz.
- Low-FPS default is timestamp-faithful hold/repeat.
- Smooth motion interpolation is future, not Phase 1.
- Preview/export parity means same frame decisions and audio graph, not same resolution.

### Phase 1: Media graph and contracts

Create:

- `MediaAssetRecord`;
- `VideoSlotPlaybackSpec`;
- `AudioGraphSpec`;
- `TextLayerSpec`;
- `CompositionClock`;
- `FrameSamplingPolicy`;
- `FrameRenderPlan`.

Do not yet rewrite every renderer. First create the contract and tests.

### Phase 2: Ingest/capability/proxy pipeline

Add:

- full source probing;
- durable original storage;
- proxy generation;
- visible import errors;
- GIF timing support;
- slow-motion/VFR detection;
- color/HDR tags.

### Phase 3: Preview/export frame parity

Refactor preview and export to call one frame resolver:

- preview gets proxy texture for resolved source time;
- export gets original/full-quality texture for the same resolved source time;
- exact pause/settle uses exact resolver;
- scrub uses approximate resolver during drag and exact resolver after release.

### Phase 4: Audio graph parity

Replace resilient preview/export split with one graph:

- original slot audio;
- slot/scene/template/master gain;
- ramps/fades;
- mute/disable rules;
- same graph for preview/export.

### Phase 5: Deterministic text

Implement:

- attributed text model;
- font resolver;
- Core Text/TextKit-backed layout cache;
- glyph atlas or text texture path;
- text animation sampler;
- render commands for text.

Preview/export must use the same layout and animation output.

### Phase 6: Resource scheduler

Implement:

- device-class budgets;
- active decoder budget;
- proxy resolution policy;
- render-ahead;
- frame cache;
- prefetch;
- pressure handling.

### Phase 7: Color/HDR and advanced formats

Add only after Phase 1 parity is stable:

- HEVC presets;
- HDR/wide-color path;
- optional smooth motion;
- speed curves;
- captions/subtitles;
- video backgrounds;
- advanced audio routing.

## 8. Required Test Strategy

### 8.1 Golden parity tests

For every fixture, export frames and preview-resolved frames must match by decision:

- source time;
- source sample ID or bracketing samples;
- trim/loop/hold state;
- text animation sampled state;
- audio timeline events.

Pixel-perfect image comparison is useful for final renderer QA, but decision-level parity
must be tested first.

### 8.2 Fixture set

Video:

- 16 fps source in 30 fps template;
- 24 fps source in 30 fps template;
- 29.97 fps source;
- 30 fps source;
- 60 fps source;
- VFR screen recording;
- slow-motion Photos asset;
- portrait video with preferred transform;
- video with no audio track;
- video with stereo audio;
- long video;
- high-resolution video;
- HDR/P3 source;
- unsupported source.

Timeline:

- one scene, one video;
- one scene, four video slots;
- two transition-resident scenes, 8-12 video slots;
- trim hold-last;
- trim loop;
- block starts at 5 seconds;
- scene transition tail.

Text:

- animated text transform;
- opacity/keyframe animation;
- multiline wrap;
- custom font;
- fallback font;
- emoji;
- different letter spacing/line height;
- text over video with masks.

Audio:

- original video audio per slot;
- slot volume;
- template audio disabled;
- scene gain;
- master gain;
- fade in/out;
- video missing audio;
- export audio failure decision.

### 8.3 Performance tests

Measure on device classes:

- preview playback with 1, 4, 8, 12 video slots;
- scrub responsiveness;
- memory during repeated import/play/export;
- export working set;
- proxy generation time;
- thermal behavior;
- audio sync drift.

### 8.4 Acceptance gates

Do not call video architecture production-ready until:

- preview/export frame decisions match for all fixtures;
- preview/export audio graph matches for all fixtures;
- text layout/animation matches for all fixtures;
- unsupported media errors are visible;
- missing video restore opens empty block;
- memory stays within documented budgets;
- export never silently drops expected original audio.

## 9. What Not To Do

- Do not fix this by adding small local patches around `VideoFrameProvider` only.
- Do not let preview and export keep separate timing formulas.
- Do not let preview audio skip scenes if export will fail.
- Do not use UIKit/CoreAnimation text preview with a separate Metal export path.
- Do not treat nominal FPS as authoritative for VFR/slow-motion media.
- Do not assume "all popular formats" without capability probing.
- Do not silently convert HDR/wide color without a product policy.
- Do not promise unlimited simultaneous original video decoders on iPhone.
- Do not store product behavior in comments instead of explicit specs/tests.

## 10. Immediate Animi Conclusions

Current Animi implementation is a useful prototype/foundation for simple SDR video slots,
but it is not the final architecture for the stated product.

The highest-risk current issues:

1. No unified media graph.
2. Preview/export frame sampling divergence.
3. Template audio settings not connected.
4. Preview/export audio failure divergence.
5. No deterministic text architecture yet.
6. Implicit SDR/BGRA8/H.264 assumptions.
7. Ingest lacks capability/proxy model.
8. Resource scheduling is not yet strong enough for "all slots can be video".

The correct next engineering move is not "rewrite everything immediately". It is:

1. document and approve Phase 1 media contract;
2. add decision-level parity tests;
3. introduce the canonical graph/spec types;
4. migrate preview/export/audio/text one surface at a time onto that graph.

## 11. Recommended Phase 1 Defaults

These defaults are pragmatic and compatible with the product direction:

- Visual timing: canonical 30 fps composition clock.
- Source frame sampling: timestamp-faithful hold/repeat.
- Low-FPS smoothing: future optional feature, not default.
- Preview media: proxy allowed, same timing required.
- Export media: original/full-quality source.
- Export video: MP4/H.264, SDR Rec. 709, template bitrate.
- Export audio: AAC-LC stereo 48 kHz.
- Missing video on restore: empty block.
- Missing video audio: silent video.
- Template audio disabled: volume UI locked with alert.
- Text layout: one deterministic Core Text/TextKit-backed path.

## 12. Source Index

Apple official sources:

- AVFoundation: https://developer.apple.com/documentation/avfoundation/
- Video overview: https://developer.apple.com/documentation/technologyoverviews/video/
- AVFoundation export guide: https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/AVFoundationPG/Articles/05_Export.html
- AVAssetReader: https://developer.apple.com/documentation/avfoundation/avassetreader
- AVAssetReaderTrackOutput: https://developer.apple.com/documentation/avfoundation/avassetreadertrackoutput
- AVAssetReaderVideoCompositionOutput: https://developer.apple.com/documentation/avfoundation/avassetreadervideocompositionoutput
- AVAssetWriter: https://developer.apple.com/documentation/avfoundation/avassetwriter
- AVOutputSettingsAssistant: https://developer.apple.com/documentation/avfoundation/avoutputsettingsassistant
- AVVideoComposition.frameDuration: https://developer.apple.com/documentation/avfoundation/avvideocomposition/frameduration
- AVVideoCompositing: https://developer.apple.com/documentation/avfoundation/avvideocompositing
- AVAsynchronousVideoCompositionRequest: https://developer.apple.com/documentation/avfoundation/avasynchronousvideocompositionrequest
- AVPlayerItemOutput.itemTime(forHostTime:): https://developer.apple.com/documentation/avfoundation/avplayeritemoutput/itemtime%28forhosttime%3A%29
- AVPlayerItemVideoOutput pixel buffer APIs: https://developer.apple.com/documentation/avfoundation/avplayeritemvideooutput
- Color tagging: https://developer.apple.com/documentation/avfoundation/media_reading_and_writing/tagging_media_with_video_color_information
- Loading media data asynchronously: https://developer.apple.com/documentation/avfoundation/loading-media-data-asynchronously
- HDR editing sample: https://developer.apple.com/documentation/avfoundation/video_effects/editing_and_playing_hdr_video
- Dolby Vision/HDR PDF: https://developer.apple.com/av-foundation/Incorporating-HDR-video-with-Dolby-Vision-into-your-apps.pdf
- AVAudioSession: https://developer.apple.com/documentation/avfaudio/avaudiosession
- AVMutableComposition: https://developer.apple.com/documentation/avfoundation/avmutablecomposition
- AVMutableAudioMix: https://developer.apple.com/documentation/avfoundation/avmutableaudiomix
- AVAssetReaderAudioMixOutput: https://developer.apple.com/documentation/avfoundation/avassetreaderaudiomixoutput
- HLS audio preparation: https://developer.apple.com/documentation/http-live-streaming/preparing-audio-for-http-live-streaming
- Core Text: https://developer.apple.com/documentation/coretext
- TextKit: https://developer.apple.com/documentation/uikit/textkit
- Metal command buffers: https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/CommandBuffers.html
- Metal triple buffering: https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/TripleBuffering.html
- Metal resource heaps: https://developer.apple.com/library/archive/documentation/Miscellaneous/Conceptual/MetalProgrammingGuide/ResourceHeaps/ResourceHeaps.html
- PhotoKit: https://developer.apple.com/documentation/photokit
- PHAssetResource: https://developer.apple.com/documentation/photokit/phassetresource
- Uniform Type Identifiers: https://developer.apple.com/documentation/uniformtypeidentifiers

Public product references:

- VN Video Editor App Store listing: https://apps.apple.com/us/app/vn-video-editor/id1343581380
- Mojo: https://mojo-app.com/
- InVideo: https://invideo.io/make/ai-video-editor/
