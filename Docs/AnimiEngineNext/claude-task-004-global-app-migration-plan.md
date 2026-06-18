# Task 004 — Global Canonical App Migration Plan

Status: PLAN ONLY.

This plan starts Task 004 after Task 003 closure. It is not an implementation. It must not change
`Sources/`, `Tests/`, `Package.swift`, `project.yml`, `*.pbxproj`, `ReferenceData`, sealed runs,
template sources, or shipped assets until the owner explicitly approves an implementation checkpoint.

## 0. Objective

Move AnimiApp from the current `TVECore` render/runtime path to the accepted `AnimiEngineNext`
canonical architecture, while preserving the existing product flow:

```text
open template
→ add/replace photo/video
→ edit placement / fit / trim / visibility / variants / toggles
→ edit background
→ add/edit text and stickers
→ play / pause / scrub / fullscreen preview
→ export MP4 with audio
→ verify on physical iPhone 13 Pro
```

The final state must not depend on the old TVECore render/runtime engine for preview or export.
Temporary A/B fallback is allowed only as a migration safety mechanism and must be removed or
explicitly disabled by the final acceptance gate.

## 1. Source-of-truth facts from the current code

### 1.1 Current app shell that should be preserved

The following are product shell responsibilities, not the old render engine:

- template catalog and scene library UI;
- editor UI and controls;
- `ProjectDraft` persistence;
- `CanonicalTimeline` editing;
- media picker/import and `ProjectAssetRegistry`;
- project save/load/autosave;
- export delivery to Photos;
- existing MP4 writer infrastructure where it can be decoupled from TVECore types.

Relevant current files:

- `AnimiApp/Sources/Project/ProjectDraft.swift`
- `AnimiApp/Sources/Project/CanonicalTimeline.swift`
- `AnimiApp/Sources/Project/SceneState.swift`
- `AnimiApp/Sources/Project/MediaPlacementState.swift`
- `AnimiApp/Sources/Project/ProjectAssetRegistry.swift`
- `AnimiApp/Sources/Player/EditorViewController.swift`
- `AnimiApp/Sources/Export/ExportWriterPipeline.swift`
- `AnimiApp/Sources/Export/AudioCompositionBuilder.swift`

### 1.2 Current old-engine runtime/render path that must be replaced

The current editor render path is TVECore-centric:

- `EditorViewController` owns `TVECore.MetalRenderer`;
- `EditorViewController.draw(in:)` renders `TimelineRenderSourcePayload` or `SceneEditRenderSourcePayload`;
- `TimelineRenderExecutor` renders with old `RenderCommand`, `TextureProvider`, `PathRegistry`;
- `TimelineCompositionEngine` and `SceneInstanceRuntime` build `ResolvedTimelineFrame`;
- `ResolvedTimelineFrame` contains old `SceneRenderContext` / `TransitionRenderContext`;
- export runners render frames through `TimelineRenderExecutor`.

These are old-engine responsibilities and are migration targets:

- `TVECore.MetalRenderer`
- `ScenePlayer`
- `SceneRuntime`
- `SceneRenderPlan`
- old `RenderCommand`
- old `TextureProvider` as render input
- old `PathRegistry` as render input
- `TimelineRenderExecutor`
- `SceneInstanceRuntime`
- `SceneTypeResourcesCache` as TVECore resource cache
- `TimelineExportRuntime` as old render-frame provider

### 1.3 Existing AnimiEngineNext capabilities

Task 003 closed the canonical static render core:

- raw `compiled.tve` bytes decode strictly through `AnimiEngineTemplateAdapter`;
- `CompiledTemplateConverter` produces `CanonicalProjectDocument` and `RenderMaterialTable`;
- `TimelineEvaluator` produces a `FramePlan`;
- `RenderInputResolver` combines `FramePlan`, material table, and explicit BGRA8 pixel fixtures into
  `ResolvedFrameInput`;
- `RenderGraphCompiler` compiles the graph;
- `MetalRenderSession.execute(_:)` returns a complete BGRA8 `RenderedFrame`;
- references were promoted from approved run `694A5886-4ADC-4228-ABDC-F050C030B59E`;
- physical iPhone 13 Pro gates passed for the render core.

Task 003 explicitly did not implement product UI, app integration, realtime scheduler/cache, real
video decode from app assets, app export integration, full text engine, or audio engine.

### 1.4 Deployment target decision

The current `AnimiApp/project.yml` iOS 16 deployment target is legacy product config, not a
Task 004 architecture constraint.

`AnimiEngineNext/Package.swift` requires iOS 18.0. Task 004 must raise AnimiApp's deployment
target to iOS 18.0 or newer before integrating `AnimiEngineNext`.

Physical manual gate target: iPhone 13 Pro (`iPhone14,2`) on the current installed iOS 26.x.

STOP if owner asks to keep iOS 16 while also requiring AnimiEngineNext integration. Those constraints
conflict.

## 2. Final target architecture

```text
AnimiApp UI / project persistence / media import / export shell
        |
        v
AnimiNextAppBridge
        |
        +--> Project adapter
        |       ProjectDraft + CanonicalTimeline + SceneState
        |       -> AnimiEngineNext canonical project inputs
        |
        +--> Template package adapter
        |       Scenes/<id>/compiled.tve
        |       -> CompiledTemplateConverter request
        |
        +--> Media resolver
        |       ProjectAssetRegistry + MediaRef + video target time
        |       -> ResolvedPixelInput BGRA8 Data
        |
        +--> Background adapter
        |       ProjectBackgroundOverride + EffectiveBackgroundState
        |       -> canonical background/overlay pixels or graph payload
        |
        +--> Overlay adapter
        |       text / sticker / graphic overlay state
        |       -> canonical overlay pixels and placement
        |
        +--> Preview scheduler/cache
        |       play/scrub requests
        |       -> complete latest valid frames only
        |
        +--> Export frame producer
                exact output frame index
                -> RenderedFrame BGRA8 copied into CVPixelBuffer

AnimiEngineNext
        |
        v
RenderedFrame BGRA8
        |
        +--> Preview texture publication
        +--> ExportWriterPipeline video input
```

The UI and project shell may remain. The old TVECore render/runtime path must not be the final
renderer.

## 3. Non-negotiable invariants

1. No silent fallback to the old engine in final gates.
2. No mixed frame publication: a visible frame must come from one complete project revision and one
   complete engine path.
3. No partial frame publication.
4. No stale scrub/playback frames after project or playhead changes.
5. Preview and export must share the same canonical evaluation and render semantics.
6. Export must use original media, not preview proxies, unless the user explicitly chooses a proxy
   quality profile.
7. Missing/corrupt media must be typed failure, not substitution.
8. Text/stickers/backgrounds must either be canonical inputs to AnimiEngineNext or explicitly marked
   unsupported until implemented. They must not be silently dropped.
9. Device gates must run on physical iPhone 13 Pro, not simulator.
10. Final app migration must have zero dependency on `TVECore` render/runtime types.

## 4. Migration strategy

Do not rewrite the whole app. Do not patch the new engine into the old renderer.

Use a bridge strategy:

- preserve product shell;
- introduce a new `AnimiNextRuntime` inside AnimiApp;
- route preview/export frame production through `AnimiNextRuntime`;
- keep old TVECore path only behind a temporary debug A/B fallback;
- remove the fallback from final acceptance.

This is the fastest correct path because current UI, project storage, media import, and export
delivery already exist. The broken boundary is the render/runtime layer, not the entire product.

## 5. Work packages

### WP0 — Preflight and scope lock

Goal: prove the starting point and prevent accidental product regressions.

Tasks:

1. Capture `git status --short`.
2. Record current app test/build commands.
3. Record current device target and signing settings.
4. Confirm `ReferenceData` and approved run are read-only.
5. Confirm no Task 003 references are regenerated.
6. Confirm no template/source/SharedAssets mutation.

STOP if any required app build or baseline test cannot run before code changes.

### WP1 — Package/project integration

Goal: make AnimiApp able to link the accepted Next products.

Required changes:

1. Raise AnimiApp deployment target to iOS 18.0+.
2. Add local package dependency on `../AnimiEngineNext`.
3. Link only production products needed by app:
   - `AnimiEngineCore`
   - `AnimiEngineRenderModel`
   - `AnimiEngineTemplateAdapter`
   - `AnimiEngineRenderGraph`
   - `AnimiEngineMetalRender`
4. Do not link `AnimiEngineRenderTestSupport` into the product.
5. Do not link diagnostics/evidence targets into the product unless explicitly required by a later
   approved diagnostics task.

Acceptance:

- AnimiApp builds on iOS 18+.
- Existing app entry still launches.
- No runtime path is changed yet.

STOP if package integration requires changing `AnimiEngineNext` isolation rules or importing
`AnimiApp` into `AnimiEngineNext`.

### WP2 — AppBridge domain model

Goal: create the product-side adapter from current persisted app state to Next inputs.

New app-side module namespace:

```text
AnimiNextAppBridge
```

Responsibilities:

1. Read `compiled.tve` bytes from `SceneDescriptor.folderURL`.
2. Build `TemplateVariantInventory.Selection` from `SceneState.variantOverrides`.
3. Map `SceneMediaSlot` to `CompiledTemplateConverter.MediaBinding`.
4. Map `MediaPlacementState` to `AnimiEngineCore.MediaPlacement`.
5. Map `CanonicalTimeline` scene items to Next `CanonicalProjectDocument` / scene payloads.
6. Map boundary transitions to Next transition plans.
7. Map visibility/toggles into selected material/program state if already represented by compiled
   template DTO; otherwise STOP and define missing schema.
8. Preserve exact project/frame timing.

Core inputs:

- `ProjectDraft`
- `CanonicalTimeline`
- `SceneState`
- `SceneMediaSlot`
- `MediaPlacementState`
- `ProjectAssetRegistry`
- `SceneLibrarySnapshot`

Core outputs:

- Next canonical document/materials per scene instance;
- evaluated `FramePlan` for exact project time;
- `RenderMaterialTable`;
- metadata needed to resolve pixels.

Acceptance:

- Unit tests convert all current bundled templates.
- Variant selection and media binding are exact.
- Unknown/missing block ids fail typed.
- No TVECore renderer/player is involved.

STOP if any current app state has no canonical equivalent in Next and cannot be represented without
inventing semantics.

### WP3 — Real media pixel resolver

Goal: replace fixture pixels with real project media.

Inputs:

- `MediaRef`
- `ProjectAssetRegistry`
- resolved file URLs
- target video `RationalSourceTime`
- image/video placement metadata

Outputs:

- `ResolvedPixelInput` with owned BGRA8 bytes;
- `PixelDimensions` with orientation `.up`;
- typed error on missing/corrupt/unsupported media.

Image path:

1. Decode from file URL with ImageIO.
2. Apply EXIF orientation.
3. Produce premultiplied BGRA8 bytes.
4. Avoid `MTLTexture` as the canonical resolver output.
5. Reuse safe logic from `DownsampledImageLoader` only as audited source, not as texture output.

Video path:

1. Use deterministic AVAssetReader path for export-quality decode.
2. For preview, either use the same reader or a separate approved realtime backend.
3. Resolve exact target rational time from Next `SourceRequest`.
4. Produce BGRA8 bytes, orientation `.up`.
5. No silent cached-frame fallback in canonical output.

Acceptance:

- real photo replacement works in preview and export;
- real video replacement works at exact frames;
- trim, hold-last, mute/volume metadata remains correct;
- missing file gives typed visible error.

STOP if preview video decode needs a different semantic policy than export. Owner must approve the
preview backend/proxy policy.

### WP4 — Authored template asset loader

Goal: resolve authored image assets inside selected material programs.

Next graph needs authored asset pixels for `(RenderMaterialID, RenderAsset.id)`.

Tasks:

1. Locate authored asset files from scene package / local images / shared assets.
2. Produce `ResolvedAssetPixelEntry`.
3. Key by `(RenderMaterialID, assetID)`, not global filename.
4. Fail typed on missing/corrupt asset.
5. Verify all real templates.

Acceptance:

- all existing authored asset image layers render through Next;
- no fallback to old `ScenePackageTextureProvider`;
- asset identity participates correctly in frame graph/hash.

STOP if `compiled.tve` asset id cannot be mapped to a bundle file without reading TVECore internals.

### WP5 — Background parity

Goal: make current background behavior available in the new path.

Current app background supports:

- template defaults;
- project override;
- scene override;
- solid;
- gradient;
- image;
- video/animated descriptors currently treated specially by export snapshot.

Required decision: background must become one of:

1. canonical Next background graph commands; or
2. pre-resolved background layer pixels inserted before scene body; or
3. temporarily unsupported with explicit UI/runtime error.

Recommended implementation:

- solid/gradient: generate deterministic BGRA8 background pixel input or graph clear/draw command;
- image: decode to BGRA8 and draw as a full/background layer;
- video/animated background: STOP unless owner approves exact target-time semantics.

Acceptance:

- existing project and scene background overrides render in preview/export;
- no black fallback unless black is the actual chosen background;
- background result matches current app expectations or approved new references.

STOP if a background source type is encountered without canonical semantics.

### WP6 — Overlay/text/sticker parity

Goal: preserve global overlays in preview and export.

Current app overlays:

- text;
- stickers;
- z-order: stickers below text;
- timeline ranges;
- placement;
- text rasterization;
- export snapshot.

Next currently supports overlay entries as pre-resolved pixel material. It does not contain a full
product text layout engine in Task 003.

Required implementation:

1. Build `OverlayPixelResolver`.
2. Text overlay:
   - deterministic text layout;
   - deterministic rasterization;
   - same preview/export pixels;
   - produce BGRA8 premultiplied pixel input.
3. Sticker overlay:
   - load sticker image from bundle;
   - produce BGRA8 pixel input.
4. Map overlay placement to Next `ActiveOverlay`.
5. Preserve z-order and time ranges.

Acceptance:

- text overlays visible in editor preview and export;
- sticker overlays visible in editor preview and export;
- overlay hit testing remains app UI responsibility;
- no old `OverlayCompositor` in final render path.

STOP if current text rendering depends on UIKit/CoreAnimation behavior that cannot be made
deterministic. Owner must choose deterministic text renderer or accept a documented non-deterministic
product layer.

### WP7 — Preview runtime and frame publication

Goal: replace editor preview rendering with Next while preserving play/scrub UX.

New runtime:

```text
AnimiNextPreviewRuntime
```

Responsibilities:

1. Own `MetalRenderSession`.
2. Own current project revision.
3. Convert playhead frame to exact `ProjectTime`.
4. Build/evaluate Next frame input.
5. Resolve required pixels.
6. Execute graph.
7. Upload returned BGRA8 `RenderedFrame` to preview texture.
8. Publish only if request identity still matches current revision/playback epoch.

Preview scheduler:

- latest-request-wins for scrub;
- bounded worker queue;
- no independent video-layer frame publication;
- whole preview rate may degrade together;
- stale frames are discarded before publication.

Initial performance mode:

- correctness-first synchronous render off main thread;
- optional sequence/cache pre-render for smooth manual playback;
- no claim of realtime until measured on iPhone.

Acceptance:

- open template;
- add photo;
- add video;
- scrub;
- play short sequence;
- edit placement/fit;
- change variant/toggle;
- no stale/mixed frame after rapid edits.

STOP if `MetalRenderSession.execute` latency makes basic preview unusable before a scheduler/cache
policy is approved. Do not hide this with old-engine fallback.

### WP8 — Export frame producer

Goal: export MP4 frames from Next, preserving current writer/delivery where possible.

Keep:

- `ExportWriterPipeline`;
- `VideoWriterPump`;
- `AudioWriterPump`;
- Photos delivery;
- project output settings where still valid.

Replace:

- `SingleSceneVideoExportRunner.renderSingleSceneFrame`;
- `TimelineVideoExportRunner.renderTimelineFrame`;
- old `TimelineRenderExecutor` usage;
- old TVECore `MetalRenderer` export dependency.

New component:

```text
AnimiNextExportFrameProducer
```

Responsibilities:

1. For each output frame index, compute exact project time.
2. Evaluate Next frame plan.
3. Resolve original media pixels at exact source time.
4. Render through `MetalRenderSession`.
5. Copy `RenderedFrame.bytes` into `CVPixelBuffer`.
6. Enqueue via existing writer pump.

Audio:

- Current audio export path may be retained only if decoupled from TVECore runtime types.
- Any dependency on `SceneRuntime`/`BlockRuntime` must be replaced by app/Next canonical scene/block
  metadata.
- Final canonical architecture must have no TVECore runtime dependency for audio timing.

Acceptance:

- single-scene export;
- multi-scene timeline export;
- fade/slide transitions;
- original video-slot audio aligned;
- project music aligned;
- cancellation remains safe;
- missing media fails atomically.

STOP if audio alignment currently requires TVECore `SceneRuntime` in a way that cannot be mapped from
canonical state. Owner must approve whether audio engine is replaced now or split into the next
checkpoint.

### WP9 — Scene edit mode parity

Goal: make the media/block editing surface use Next preview data.

Current scene edit uses old scene-player overlays and render commands.

Required:

1. Determine block geometry from Next/template adapter metadata.
2. Render current edit frame through Next.
3. Preserve selectable block overlays in UIKit.
4. Preserve placement controls.
5. Preserve video trim UI still frame behavior.

Acceptance:

- media block selection works;
- replace photo/video works;
- fit/scale/offset/rotation controls work;
- visibility/toggle actions update preview.

STOP if any editor geometry comes only from old `ScenePlayer` and is not present in compiled schema /
Next material geometry.

### WP10 — Remove old render/runtime path

Goal: make old engine fallback impossible in final acceptance.

Tasks:

1. Remove preview calls to `TimelineRenderExecutor`.
2. Remove export calls to `TimelineRenderExecutor`.
3. Remove `TVECore.MetalRenderer` ownership from `EditorViewController`.
4. Remove `ScenePlayer` runtime dependency from preview/export.
5. Replace TVECore geometry/model imports in app code with app-local or `AnimiEngineCore` types.
6. Keep only non-render legacy code if explicitly classified as product shell and approved.

Final audit:

```text
rg "import TVECore|MetalRenderer|ScenePlayer|SceneRuntime|RenderCommand|TextureProvider|PathRegistry" AnimiApp/Sources
```

Expected final result: zero production runtime/render references. Any remaining reference must have
explicit owner approval and a removal ticket.

STOP if removing TVECore imports requires changing persisted project schema without migration plan.

## 6. Manual iPhone acceptance flow

This is not optional. Final Task 004 is not accepted until this is run on physical iPhone 13 Pro.

Device:

- iPhone 13 Pro (`iPhone14,2`);
- current iOS 26.x installed on owner's device;
- simulator is invalid.

Manual flow:

1. Fresh install debug build.
2. Open app.
3. Open template catalog.
4. Open each mandatory real template:
   - `full_image`
   - `polaroid_shared_demo`
   - `polaroid_2`
   - `example_4blocks`
   - `6_frames_template`
5. Add photo to every media block.
6. Add video to video-capable blocks or synthetic video test template if current real templates are
   image-only.
7. Change fit/placement/scale/rotation.
8. Change variant.
9. Toggle layers where exposed.
10. Change background.
11. Add text overlay.
12. Add sticker overlay.
13. Scrub timeline rapidly.
14. Play preview.
15. Open fullscreen preview.
16. Export MP4.
17. Save to Photos.
18. Reopen exported file and visually inspect:
    - no black frames;
    - no stale media;
    - no missing overlays;
    - no wrong background;
    - no transition glitch;
    - audio present and aligned;
    - output duration correct.

Evidence:

- build command;
- device model/iOS;
- app version/commit;
- selected template IDs;
- exported MP4 URL/path;
- screenshots or screen recording;
- known deviations, if any.

## 7. Automated gates

### Gate A — Build boundaries

- AnimiApp builds for iOS device.
- AnimiEngineNext SwiftPM suite still passes.
- Package/pbxproj/project changes are exactly expected.

### Gate B — Bridge unit tests

- every real template converts;
- every real block maps to media binding;
- variant selection exact;
- missing block/variant/media typed failures;
- media placement round-trip exact.

### Gate C — Media resolver tests

- image orientation;
- alpha premultiplication;
- video exact target;
- trim boundaries;
- missing/corrupt media;
- large image memory behavior.

### Gate D — Preview integration tests

- latest request wins;
- stale frame dropped;
- rapid scrub;
- edit invalidates project revision;
- no old renderer call.

### Gate E — Export tests

- frame count exact;
- timestamps exact;
- audio aligned;
- cancellation safe;
- output atomically written;
- no old renderer call.

### Gate F — Visual references

- selected app-flow frames compared against approved Task 003 references where applicable;
- new app-integration references generated only through guarded evidence flow;
- no self-blessing.

### Gate G — Device gate

- physical iPhone 13 Pro;
- preview;
- scrub;
- export;
- saved MP4 review.

## 8. Corner cases and traps

### Media

- EXIF orientation must be normalized to `.up`.
- BGRA byte order must be exact.
- Premultiplied alpha must stay premultiplied.
- Video target time must be exact rational, not `Double` guess.
- Hold-last and trim-end behavior must match current product or approved canonical replacement.
- Missing original media must fail, not show stale cached texture.

### Timeline

- Boundary transitions compress timeline duration.
- Outgoing scene continues during slide.
- Incoming scene holds first frame before its active start where required.
- Rapid scrub must cancel stale work.
- Project revision changes must invalidate pending frames.

### Templates

- Unknown compiled schema fields fail closed.
- Variant inventory must be complete.
- Binding block ids must match.
- Authored asset ids are local to material/program, not globally unique.

### Backgrounds

- Scene override has full replacement semantics.
- Project override must not leak into scene override.
- Template default must remain fallback only.
- Video/animated background requires explicit canonical semantics.

### Text/stickers

- UIKit/CoreGraphics text rendering may vary by OS/font.
- Text layout must be pinned if used for references.
- Sticker aspect-fit contract must match current product or be deliberately changed.
- Overlay z-order must remain stable.

### Export

- Export must use original media, not preview stale/proxy frames.
- CVPixelBuffer copy from `RenderedFrame` must preserve row order and BGRA.
- Audio composition currently depends on TVECore runtime metadata; this must be removed or isolated.
- Export cancellation must not leave partial output as success.

### Build/deployment

- iOS 16 is not a valid architecture constraint for Next integration.
- Raise deployment target intentionally.
- Do not link test-support products into shipping app.
- Do not weaken AnimiEngineNext isolation by importing app code into package.

## 9. STOP rules

Stop immediately and ask owner if any of these happens:

1. A current app feature has no canonical representation in Next.
2. A bridge requires importing `AnimiApp` into `AnimiEngineNext`.
3. A bridge requires importing `TVECore` into `AnimiEngineNext`.
4. A final path requires old `TVECore.MetalRenderer`.
5. A final path requires old `ScenePlayer` / `SceneRuntime`.
6. Text rendering cannot be made deterministic.
7. Video preview and export would use different source-time semantics.
8. Audio timing cannot be mapped without old runtime metadata.
9. Background video/animated sources appear without approved semantics.
10. Package integration requires lowering `AnimiEngineNext` below iOS 18.
11. Device testing cannot run on physical iPhone.
12. Any fallback would silently hide a missing media/render failure.
13. Any old-engine fallback remains enabled in final acceptance.
14. Any reference/golden needs regeneration outside guarded approval.
15. Any template/source/SharedAssets mutation is required.

## 10. Implementation checkpoints

### CP0 — Read-only verification

Deliverable: final Task 004 implementation spec with exact file list and owner decisions.

### CP1 — Build integration only

Deliverable: AnimiApp links Next, old behavior unchanged.

### CP2 — Single-scene Next preview vertical slice

Deliverable: one real template, photo media, no old renderer for that preview path.

### CP3 — Real media resolver

Deliverable: photo + video BGRA8 resolver, exact-time tests.

### CP4 — Full template scene parity

Deliverable: all real templates render through Next in editor preview.

### CP5 — Timeline/transitions

Deliverable: multi-scene timeline, cut/fade/slide preview via Next.

### CP6 — Background + overlays

Deliverable: background/text/sticker parity via Next path.

### CP7 — Export

Deliverable: MP4 export frames from Next; audio preserved/aligned; no old renderer.

### CP8 — Scene edit mode

Deliverable: media block editing and placement controls use Next preview.

### CP9 — Old-engine removal

Deliverable: no TVECore render/runtime references in final path.

### CP10 — Physical iPhone E2E acceptance

Deliverable: manual full-flow evidence on iPhone 13 Pro.

## 11. Owner decisions currently locked by prior approval

These are treated as already approved and must not be reopened casually:

- AnimiEngineNext remains isolated from AnimiApp/TVECore.
- Existing compiled `.tve` packages are the template input.
- Fail-closed typed errors; no silent substitution.
- iPhone 13 Pro physical device gates matter.
- iOS 16 is not a blocking requirement for the new architecture; iOS 18+ is acceptable for Next.
- Old render/runtime engine is not part of final architecture.
- Existing app shell can be preserved if it is not old render/runtime.

## 12. Decisions still requiring owner approval before implementation

Do not implement past CP0 until these are answered or converted into STOP rules:

1. **Audio scope:** keep current AVFoundation writer/audio composition after removing TVECore runtime
   dependencies, or implement the new canonical audio engine now?
2. **Text engine:** deterministic CoreGraphics text rasterizer now, or a deeper canonical text engine now?
3. **Preview performance mode:** correctness-first on-demand render with cache, or build full scheduler/proxy
   before editor integration?
4. **Background video/animated:** support now, reject explicitly, or defer behind UI capability gate?
5. **Fallback policy:** allow debug A/B fallback during migration only, with hard removal gate, or no fallback
   at all after CP2?

If the owner says "no open decisions", then CP0 must resolve each item by code-backed proof or STOP.

## 13. Expected final definition of done

Task 004 is complete only when:

1. AnimiApp product flow runs on AnimiEngineNext for preview and export.
2. Full manual iPhone flow passes.
3. Exported MP4 visually matches approved expectations.
4. Audio is present and aligned.
5. Text/stickers/backgrounds are present and correct.
6. All real bundled templates work.
7. Missing/corrupt media fails visibly and typed.
8. Old TVECore render/runtime is not used by final preview/export.
9. Automated tests pass.
10. Device evidence is attached.
11. Documentation and decision register are updated.
12. No references are regenerated without guarded approval.

## 14. Claude execution prompt

```text
You are implementing Task 004 only after this plan is approved.

First perform CP0 READ-ONLY verification against the current repository. Do not write production code.
Confirm or reject every fact in sections 1-8 of
Docs/AnimiEngineNext/claude-task-004-global-app-migration-plan.md.

Then produce a CP1-CP10 implementation sequence with exact file lists, tests, STOP checks, and owner
decisions. You must not invent behavior. If any mapping is unclear, STOP and ask.

Hard constraints:
- final architecture must not use TVECore render/runtime for preview/export;
- preserve app shell where it is not old engine;
- raise AnimiApp deployment target to iOS 18+ for Next integration;
- no AnimiEngineNext import of AnimiApp or TVECore;
- no silent fallback/substitution;
- no template/source/reference mutation;
- physical iPhone 13 Pro manual E2E gate required.
```

