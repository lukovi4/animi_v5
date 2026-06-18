# Task 003 - Canonical Static Render System

**Revision:** 2 - FINAL TECHNICAL-LEAD PLAN  
**Status:** READY FOR OWNER APPROVAL; IMPLEMENTATION NOT STARTED  
**Development gate:** Architecture proposal Gate 4 - real-template static frame rendering  
**Validation level:** Level 2 - render correctness

This document is the complete implementation plan for Task 003. It replaces Revision 1 in full.
There are no open architecture or product questions in Task 003.

Implementation must not begin until the product owner explicitly approves this plan and instructs
Claude Code to start.

During this planning pass, only this file may be modified. Task 004 is not started.

---

## 1. Objective

Task 003 must build the first canonical image-producing path for `AnimiEngineNext`:

```text
compiled.tve + package assets + explicit media fixtures
    -> immutable canonical project and render materials
    -> Task-002 FramePlan
    -> deterministic immutable RenderGraph
    -> Metal execution
    -> complete 1080x1920 SDR frame
    -> stored evidence, references and visual comparison
```

The task proves static render correctness for:

- all five real compiled templates;
- every compiled authored variant of every block;
- images and deterministic still-frame video fixtures;
- authored animation tracks;
- placement, crop, masks, mattes and layer ordering;
- cut, fade and slide transitions;
- outgoing-scene post-roll and incoming-scene hold-first behavior;
- global overlays;
- structural 10-overlay, 20-video and 20-to-20 transition cases.

Task 003 does not claim realtime performance. It produces one requested complete frame at a time.

---

## 2. Fixed Decisions

The following decisions are closed and must not be reopened during implementation.

### D3-01 - Real template input

The adapter reads the existing compiled schema-2 packages:

- `AnimiApp/Resources/Scenes/full_image/compiled.tve`
- `AnimiApp/Resources/Scenes/polaroid_shared_demo/compiled.tve`
- `AnimiApp/Resources/Scenes/polaroid_2/compiled.tve`
- `AnimiApp/Resources/Scenes/example_4blocks/compiled.tve`
- `AnimiApp/Resources/Scenes/6_frames_template/compiled.tve`

The package directories, their local `images/` directories and the injected repository
`SharedAssets/` root are read-only inputs. No file in those locations may be changed.

The `.tve` envelope is:

- magic bytes: ASCII `TVE1`;
- compiled format version: `1`;
- header length: `16` bytes for the legacy header or `18` bytes with explicit IR schema;
- payload length: little-endian `UInt32`;
- engine-version hash: diagnostic `UInt32`;
- IR schema version: explicit at offset 16 for the 18-byte header;
- supported Task-003 IR schema: exactly `2`;
- payload: compact JSON containing compiled runtime and AnimIR data.

Task 003 decodes compiled AnimIR directly. It never parses or recompiles authored Lottie JSON during
rendering. `SceneSources/` may be read only to verify source-to-compiled variant traceability.

### D3-02 - Metal-first production renderer

The canonical production path is Metal-first, as required by the architecture and research.

Task 003 does not create a second complete CPU renderer. Small CPU reference functions are allowed
only for isolated mathematics such as source-over blending, transfer functions and easing.

### D3-03 - Render stages

Rendering is separated into:

1. read-only template package loading;
2. pure compiled-template decoding;
3. complete render-input resolution;
4. pure deterministic RenderGraph compilation;
5. stateful, explicitly owned Metal execution;
6. evidence and visual comparison outside the renderer.

No stage may bypass the previous stage or reach back into mutable project state.

### D3-04 - Material and dependency ownership

Shared immutable render-material types live in `AnimiEngineRenderModel`.

`AnimiEngineRenderGraph` and `AnimiEngineMetalRender` do not depend on
`AnimiEngineTemplateAdapter`. The adapter produces model values; the renderer consumes them.

### D3-05 - Media placement

Fit and user placement are resolved before RenderGraph execution from:

- compiled template binding-baseline geometry;
- media-input aperture and clip geometry;
- explicit fit mode: `cover`, `contain` or `fill`;
- source presentation dimensions;
- canonical user placement.

The resolver uses the existing placement behavior as a compatibility oracle:

- `cover`: uniform maximum scale;
- `contain`: uniform minimum scale;
- `fill`: independent X/Y scale;
- scaled media is centered in the binding baseline before user transform.

The Metal executor receives final immutable transform and crop instructions. It does not interpret a
product-level fit policy.

### D3-06 - Animation sampling

Compiled immutable animation tracks are sampled on demand at the exact `AnimationRequest`.
The system must not pre-bake every timeline tick.

The adapter converts compiled numeric data into checked render-model values using documented units
and deterministic rounding. Sampling is deterministic and has no wall clock.

### D3-07 - Transition easing

Task 003 supports:

- `linear`: `t`;
- `easeInOut`: `3t^2 - 2t^3`;
- `none`: valid only for a cut and never evaluated as an animated transition.

Unknown easing is a typed error.

### D3-08 - Color and alpha contract

The Task-003 output contract is:

- output dimensions: `1080x1920`;
- output dynamic range: SDR;
- output format: BGRA8;
- output color space and transfer: sRGB;
- alpha storage: premultiplied;
- compositing: premultiplied source-over in linear light;
- final conversion: linear result converted to sRGB BGRA8.

The canonical source-over equation is:

```text
out.rgb = src.rgb + dst.rgb * (1 - src.a)
out.a   = src.a   + dst.a   * (1 - src.a)
```

Inputs are normalized to linear-light premultiplied values before compositing.

Two configurable intermediate profiles are defined:

- `bgra8SRGB`;
- `rgba16FloatLinear`.

`rgba16FloatLinear` is the Task-003 correctness-reference profile. Task 003 does not declare an
optimal production intermediate. The final winner remains benchmark decision D-208.

### D3-09 - Text scope

Full text layout, glyph rasterization and animated text parity are deferred to the approved
Audio/Text gate and ADR-011.

Task 003 may composite only pre-resolved immutable text pixel material. The 10-text-overlay case
proves composition structure and ordering, not text-engine parity.

### D3-10 - Reference comparison

Level-2 comparison records:

- exact raw-pixel equality;
- per-channel maximum absolute difference;
- differing-pixel count and fraction;
- SSIM;
- difference image and changed-pixel bounding box.

Numerical cross-backend and cross-device thresholds are proposed from measured baselines and approved
later. Their absence does not block implementation, but Task 003 cannot be declared complete until the
real-template reference set is explicitly reviewed and approved.

### D3-11 - Determinism language

The guarantees are deliberately separated:

- RenderGraph compilation: value-identical inputs produce a value-identical graph;
- same-environment Metal repeatability: same build, device/GPU, OS, configuration and inputs must
  reproduce the same final raw output bytes;
- cross-device and cross-OS output is compared by stored pixel statistics and SSIM;
- no claim of universal bit-identical Metal output across GPU families or OS versions is allowed.

### D3-12 - Evidence publication

All Task-003 output is written into the existing `BenchmarkRun` staging directory through a controlled
supplemental-artifact API. The final run is still published by the existing single atomic,
no-overwrite directory publication.

No renderer or graph compiler writes files directly.

---

## 3. Scope

### 3.1 Included

- independent decoding of compiled `.tve` schema 2 without importing `TVECore`;
- strict validation of the `.tve` envelope and consumed payload schema;
- read-only local/shared asset resolution;
- conversion into Task-002 canonical project payloads;
- immutable render-material model;
- complete image/video fixture resolution before graph compilation;
- deterministic RenderGraph compilation;
- Metal execution of one complete frame;
- image, shape, transform, opacity, clipping, mask and matte behavior required by real templates;
- cut, fade and slide composition;
- global pre-resolved overlays;
- Level-2 candidate generation, references, comparisons and evidence;
- transactional supplemental evidence artifacts;
- real-template and structural stress tests;
- ADR-010 and decision/source-traceability updates.

### 3.2 Excluded

- product UI;
- integration with or migration of the current engine;
- realtime playback and scheduler;
- video decoding from assets;
- AVFoundation/VideoToolbox backend selection;
- decoder pool;
- proxy and render cache;
- audio;
- full text engine;
- export;
- realtime performance claims;
- device-tier decisions;
- modification or recompilation of real templates;
- Task 004.

---

## 4. Package Architecture

### 4.1 New production targets

#### `AnimiEngineRenderModel`

Owns immutable, `Sendable` render values:

- `RenderMaterialTable`;
- compiled animation programs and tracks;
- paths, masks, matte links and asset descriptors;
- resolved image/video pixel inputs;
- final media transform/crop instructions;
- `RenderConfiguration`;
- color and alpha descriptors;
- immutable RenderGraph command values;
- `RenderedFrame`;
- typed model errors.

Dependencies:

```text
AnimiEngineRenderModel -> AnimiEngineCore
```

#### `AnimiEngineTemplateAdapter`

Owns:

- `.tve` envelope decoding;
- strict schema-2 payload DTOs;
- compiled runtime/AnimIR conversion;
- canonical project construction;
- variant selection;
- package/local/shared asset descriptors;
- fixed-point and rational conversion;
- template/material hashes.

Dependencies:

```text
AnimiEngineTemplateAdapter -> AnimiEngineCore
AnimiEngineTemplateAdapter -> AnimiEngineRenderModel
```

It must not import `TVECore`, `TVECompilerCore` or `AnimiApp`.

#### `AnimiEngineRenderGraph`

Owns:

- complete render-input validation;
- animation sampling;
- transform resolution;
- scene graph flattening into explicit render commands;
- mask/matte scopes;
- scene subplans;
- transition graph composition;
- overlay graph composition;
- graph validation and deterministic graph hashing.

Dependencies:

```text
AnimiEngineRenderGraph -> AnimiEngineCore
AnimiEngineRenderGraph -> AnimiEngineRenderModel
```

It performs no IO and imports no Metal framework.

#### `AnimiEngineMetalRender`

Owns:

- `MTLDevice`;
- command queue;
- pipeline library;
- texture and buffer allocation for a render session;
- explicit upload and color conversion;
- graph execution;
- complete final-frame readback;
- Metal errors and execution diagnostics.

Dependencies:

```text
AnimiEngineMetalRender -> AnimiEngineRenderModel
AnimiEngineMetalRender -> AnimiEngineRenderGraph
```

It does not load templates, resolve files or inspect projects.

### 4.2 New non-product support target

#### `AnimiEngineRenderTestSupport`

Owns:

- template repository roots;
- fixture image/video-frame generation;
- candidate and approved-reference stores;
- PNG encoding;
- exact/pixel/SSIM comparison;
- difference images;
- contact sheets and review manifests;
- Task-003 evidence recorder;
- guarded reference promotion.

Dependencies:

```text
AnimiEngineRenderTestSupport -> AnimiEngineCore
AnimiEngineRenderTestSupport -> AnimiEngineRenderModel
AnimiEngineRenderTestSupport -> AnimiEngineTemplateAdapter
AnimiEngineRenderTestSupport -> AnimiEngineRenderGraph
AnimiEngineRenderTestSupport -> AnimiEngineMetalRender
AnimiEngineRenderTestSupport -> AnimiEngineDiagnostics
AnimiEngineRenderTestSupport -> AnimiEngineTestSupport
```

It is not listed as a package product.

`Package.swift` adds library products for the four production targets:

- `AnimiEngineRenderModel`;
- `AnimiEngineTemplateAdapter`;
- `AnimiEngineRenderGraph`;
- `AnimiEngineMetalRender`.

No test-support target is exposed as a product.

### 4.3 New test targets

- `AnimiEngineTemplateAdapterTests`
- `AnimiEngineRenderGraphTests`
- `AnimiEngineMetalRenderTests`

Existing Task-001 and Task-002 targets remain unchanged except for the narrow Diagnostics extension
listed in this plan.

---

## 5. Template Package Pipeline

### 5.1 `TemplatePackageLoader`

This is the only Task-003 template IO boundary.

Input:

- explicit package-directory URL;
- explicit shared-assets root URL.

Output:

- `Data` for `compiled.tve`;
- immutable local/shared asset index containing validated file descriptors and content hashes.

Rules:

- no current-working-directory dependency;
- no implicit app bundle lookup;
- no symlink traversal;
- no path escape;
- package and shared roots are read-only;
- duplicate asset basenames are resolved by explicit local-before-shared precedence;
- unresolved non-binding assets are typed failures;
- binding placeholder assets are not loaded as user content.

### 5.2 `CompiledTemplateDecoder`

Pure operation:

```text
Data -> DecodedCompiledTemplate
```

Validation:

- exact `TVE1` magic;
- supported format version;
- valid header length;
- checked payload bounds and integer conversion;
- schema version exactly 2;
- no trailing payload ambiguity;
- strict JSON types;
- required fields present;
- unknown fields rejected recursively for the schema owned by the new adapter;
- duplicate structural IDs rejected;
- invalid references and unsupported compiled features rejected with typed errors.

The engine-version hash is recorded as evidence but does not silently change decoding behavior.

### 5.3 Canonical conversion

The adapter produces:

- `CanonicalProjectDocument`;
- `RenderMaterialTable`;
- sorted template/material content hashes;
- a variant inventory used by acceptance tests.

Every block requires an explicit variant selection. Missing or unknown block/variant IDs are errors.
There is no first-variant or default fallback.

All authored variants present in the compiled payload must appear in the inventory and tests.

### 5.4 Render numeric conversion

Canonical project time and geometry continue to use Task-002 types.

Render-only compiled values use explicit checked units:

- canvas/path coordinate: signed fixed point, 65,536 units per point;
- scale/unit interval/opacity: signed fixed point, 1,000,000 units per one;
- rotation: 1,000 units per degree;
- authored frame/time mapping: exact rational values;
- colors: normalized fixed-point components before Metal conversion.

Source `Double` values are converted at the adapter boundary with round-to-nearest,
ties-away-from-zero, checked for finite values and overflow. NaN and infinity are rejected.

Metal `Float` conversion occurs only at the executor upload boundary and never returns to canonical
or RenderGraph state.

---

## 6. Complete Render Input Resolution

`RenderInputResolver` combines an immutable `FramePlan` with `RenderMaterialTable` and explicit fixture
pixels before graph compilation.

It must resolve:

- every image reference;
- every video `SourceRequest` to one deterministic still-frame fixture at the exact rational target;
- every animation reference and requested variant;
- source dimensions and orientation;
- fit/crop and final transform;
- mask/matte dependencies;
- overlay pixels;
- all content hashes.

Output:

```text
ResolvedFrameInput
```

`ResolvedFrameInput` contains only immutable values and owned pixel buffers. It contains no:

- URL;
- filesystem path;
- closure;
- provider;
- lazy load;
- mutable cache;
- project lookup.

Missing or mismatched material fails before RenderGraph compilation and before any Metal command is
submitted.

---

## 7. RenderGraph Contract

Pure operation:

```text
RenderGraphCompiler.compile(
    plan: FramePlan,
    input: ResolvedFrameInput,
    configuration: RenderConfiguration
) throws -> RenderGraph
```

The graph explicitly contains:

- output canvas and reference color profile;
- cleared background;
- immutable resource descriptors;
- ordered scene subgraphs;
- ordered layer commands;
- sampled transform/opacity values;
- clip paths;
- mask scopes;
- matte source/consumer links;
- image/video draw commands;
- offscreen surfaces where required;
- fade/slide transition commands;
- overlays above the completed scene/transition result;
- final linear-to-sRGB conversion;
- final BGRA8 output command.

### 7.1 Ordering

- Scene layers follow `localCompositionOrder`.
- Internal compiled AnimIR layers follow authored order and explicit matte relationships.
- Transition combines two complete scene subgraphs.
- Global overlays follow `compositionOrder` and are above the completed body.
- Dictionary iteration order must never affect the graph.

### 7.2 Animation requests

The compiler supports:

- `.sample(time)`;
- `.looped(time)`;
- `.holdLast`;
- `.inactive`.

It uses exact Task-002 animation time. Video is never frozen by animation `holdLast`.

### 7.3 Transitions

#### Cut

Cut is represented by Task 002 as a single scene on either side of a zero-duration boundary. No
animated transition graph is created.

#### Fade

The compiler produces outgoing and incoming scene surfaces and composites the incoming scene using
eased transition progress.

#### Slide

The compiler translates the incoming complete scene from the declared direction across the canvas.
The outgoing scene continues rendering and animating until the transition window ends.

Transition progress is consumed exactly from `TransitionPlan`; Task 003 never compresses project time.

### 7.4 Graph validation

Before execution the graph validator rejects:

- missing resource;
- duplicate resource identity;
- invalid command order;
- unbalanced mask/matte scope;
- invalid surface dependency;
- invalid dimensions;
- unsupported blend or matte mode;
- geometry overflow;
- unsupported easing;
- color-profile mismatch;
- incomplete final output.

Graph compilation and validation are covered independently of Metal.

---

## 8. Metal Execution Contract

Entry point:

```text
MetalRenderSession.execute(_ graph: RenderGraph) throws -> RenderedFrame
```

`MetalRenderSession` explicitly owns all Metal objects. Nothing is process-global.

Execution rules:

- one session-owned command queue;
- bounded frames in flight, configured as `1` for Task 003 static rendering;
- all textures and buffers have explicit ownership and lifetime;
- immutable graph resources are uploaded before command encoding;
- unsupported graph commands are errors;
- a complete frame is returned only after successful command completion;
- command-buffer failure returns a typed error and no partial frame;
- final output is read back as canonical BGRA8 sRGB premultiplied bytes;
- raw output hash is SHA-256 over dimensions, format/color metadata and pixel bytes.

Task 003 may use a simple session-local texture allocator. Realtime pooling and cache policy remain
later benchmark work.

---

## 9. Error Model

Errors are typed, `Equatable` where practical and `Sendable`.

Required domains:

- `TemplatePackageError`
- `CompiledTemplateDecodingError`
- `TemplateConversionError`
- `RenderInputResolutionError`
- `RenderGraphError`
- `MetalRenderError`
- `ReferenceComparisonError`
- `SupplementalArtifactError`

No layer may silently substitute:

- placeholder pixels;
- default variant;
- default easing;
- default fit;
- missing asset;
- unsupported mask/matte/blend behavior;
- lower-quality intermediate;
- black frame;
- previous frame.

---

## 10. Diagnostics and Evidence Extension

Task 003 requires a narrow modification of `AnimiEngineDiagnostics`.

### 10.1 Supplemental artifact API

Add a validated `SupplementalArtifactPath` and:

```text
BenchmarkRun.writeSupplementalArtifact(data:at:)
```

Rules:

- writes are allowed only while the run is open;
- path must be normalized, relative and non-empty;
- absolute paths, `.`/`..`, empty components, NUL and platform separators are rejected;
- core artifact names are reserved;
- an artifact path may be written exactly once;
- parent directories are created only inside staging;
- symlink traversal is rejected;
- overwrite is rejected;
- writes after close or failed close follow existing lifecycle errors;
- the caller never receives the staging-directory URL.

### 10.2 Supplemental manifest

Every supplemental write records:

- normalized relative path;
- byte size;
- SHA-256.

At close:

1. entries are sorted by normalized path;
2. canonical `artifacts-manifest.json` is written inside staging;
3. its SHA-256 is recorded as `supplementalArtifactsSHA256` in `run-manifest.json`;
4. all existing core artifacts are written;
5. `run-manifest.json` remains the last file written;
6. the existing single atomic no-overwrite directory publish remains the only publication point.

An empty run records the canonical hash of an empty artifact manifest.

### 10.3 Task-003 artifact set

Each Level-2 run writes:

```text
project-snapshot.json
render-manifest.json
output/candidates/...
output/diffs/...
output/contact-sheet.png
```

The render manifest records:

- benchmark run ID;
- git commit;
- engine build;
- device, GPU and OS;
- template ID and compiled-template hash;
- sorted block/variant selection;
- project/config/material hashes;
- frame index and exact project time;
- RenderGraph hash;
- output hash;
- exact pixel statistics;
- SSIM;
- result classification;
- failure, if any.

### 10.4 Transactional tests

Fault-injection tests must prove:

- path validation occurs before writing;
- duplicate/overwrite is rejected;
- failure during directory creation, write, hash or manifest generation publishes no final run;
- failure leaves no staging directory;
- supplemental files are never visible under the final run path before close;
- successful close publishes the complete core and supplemental artifact set;
- the aggregate hash changes when any supplemental path or byte changes;
- existing final directories are never overwritten.

---

## 11. Level-2 Reference Workflow

### 11.1 Normal test behavior

Normal `swift test`:

- reads approved references;
- never writes or updates approved references;
- fails on a missing approved reference after the reference set is activated;
- writes candidate/diff output only into a new `BenchmarkRun`;
- compares raw pixels and SSIM;
- records all results.

### 11.2 Candidate generation

Candidate generation renders the complete matrix and writes:

- PNG candidate;
- canonical raw-pixel hash;
- metadata JSON;
- diff PNG when an approved reference exists;
- contact sheet grouped by template, variant and frame purpose.

Candidate output is evidence, not automatically truth.

### 11.3 Reference promotion

Promotion is a separate explicit command/tool, never called from normal tests.

It requires:

- source benchmark run ID;
- git commit;
- device, GPU and OS;
- render/config/material hashes;
- `approvedBy`;
- `approvedAt`;
- `approvalNote`.

It refuses:

- unsealed or failed runs;
- incomplete matrices;
- missing hashes;
- output produced by a different configuration than the reviewed manifest;
- overwrite without an explicit replacement operation.

The existing renderer may be used as a comparison oracle but is never accepted automatically as the
correct reference.

Task 003 is complete only after the product owner reviews the contact sheet/differences and explicitly
approves the real-template reference set.

---

## 12. Required Render Matrix

### 12.1 Real templates and variants

Tests enumerate variants from each compiled payload and assert exact agreement with the source
inventory:

- `full_image`: every compiled block variant;
- `polaroid_shared_demo`: every compiled block variant;
- `polaroid_2`: every compiled variant of both blocks;
- `example_4blocks`: every compiled variant of all four blocks;
- `6_frames_template`: every compiled variant of all six blocks.

Each test selection explicitly supplies one variant for every block.

### 12.2 Per-variant frames

For every target variant:

- authored start;
- first visible frame;
- animation midpoint;
- each key visibility boundary at `boundary - 1` and `boundary`;
- last authored frame;
- hold-last region when applicable;
- loop wrap when applicable;
- scene last nominal frame.

### 12.3 Transition frames

For fade and every slide direction:

- one frame before the transition window;
- window start;
- boundary minus one frame;
- exact scene boundary;
- boundary plus one frame;
- window end minus one frame;
- exact window end;
- outgoing post-roll frame;
- incoming hold-first frame.

Cut:

- boundary minus one frame;
- exact boundary.

Odd transition duration:

- prove the extra tick belongs after the boundary.

### 12.4 Structural fixtures

- 10 pre-resolved text overlays;
- 20 video layers using deterministic still-frame fixtures;
- 20 outgoing plus 20 incoming layers during fade;
- 20 outgoing plus 20 incoming layers during slide.

These tests prove completeness, ordering and correctness only. They record no realtime performance
claim.

---

## 13. Test Matrix

| Requirement | Test family | Required proof |
|---|---|---|
| `.tve` envelope | `CompiledTemplateEnvelopeTests` | magic, versions, lengths, bounds, schema, malformed inputs |
| Strict schema | `CompiledTemplateSchemaTests` | wrong types, missing/unknown fields, duplicate IDs, unsupported features |
| All compiled variants | `CompiledVariantInventoryTests` | every block/variant enumerated exactly once |
| Isolation | `Task003DependencyBoundaryTests` | no TVECore/TVECompilerCore/AnimiApp dependency |
| Asset resolution | `TemplateAssetResolutionTests` | local-before-shared, binding skip, missing/duplicate/path escape |
| Numeric conversion | `RenderNumericConversionTests` | deterministic rounding, non-finite rejection, overflow |
| Canonical conversion | `TemplateCanonicalConversionTests` | Task-002 validation succeeds for all explicit selections |
| Input completeness | `RenderInputResolverTests` | all references/pixels/transforms resolved before graph compile |
| Fit and crop | `MediaFitResolutionTests` | cover/contain/fill and user placement against analytic oracle |
| Graph determinism | `RenderGraphDeterminismTests` | value-identical graph and stable graph hash |
| Graph validation | `RenderGraphValidationTests` | invalid ordering/resources/scopes rejected |
| Ordering | `RenderOrderingTests` | scene, internal layer, transition and overlay order |
| Animation | `AnimationSamplingTests` | sample, loop, holdLast, inactive, interpolation boundaries |
| Masks/mattes | `MaskMatteGraphTests`, `MaskMatteMetalTests` | every mode used by real compiled variants |
| Color/alpha | `ColorAlphaContractTests` | transfer, premultiplication, source-over, final BGRA8 |
| Intermediate profiles | `IntermediateProfileTests` | both profiles explicit; no silent profile change |
| Cut/fade/slide | `TransitionRenderTests` | exact matrix, easing, directions, no timeline compression |
| Incoming/outgoing semantics | `TransitionPlaybackSemanticsTests` | hold-first and post-roll preserved in pixels |
| Metal lifecycle | `MetalResourceOwnershipTests` | explicit ownership, complete frame, no partial result |
| Same-environment repeatability | `MetalRepeatabilityTests` | repeated final raw bytes and hashes equal |
| Typed errors | `Task003ErrorModelTests` | all unsupported/missing cases fail without substitution |
| Supplemental evidence | `SupplementalArtifactTests` | safe paths, no overwrite, hashes and lifecycle |
| Transactional evidence | `SupplementalArtifactTransactionTests` | fault injection publishes all or nothing |
| References | `ReferenceStoreTests` | read-only normal path, missing/mismatch behavior |
| Promotion | `ReferencePromotionTests` | explicit metadata, sealed-run requirement, no accidental overwrite |
| Real templates | `RealTemplateLevel2Tests` | all five templates, all variants, complete frame matrix |
| Structural stress | `StaticStructuralStressTests` | 10 overlays, 20 layers, 20-to-20 transitions |
| Regression | complete package suite | all Task-001 and Task-002 tests remain green |

No wall-clock performance assertions are allowed in Task 003 tests.

---

## 14. Exact Files

The implementation must remain within this list unless Claude stops and requests technical-lead
approval for a necessary correction.

### 14.1 Modify

- `AnimiEngineNext/Package.swift`
- `AnimiEngineNext/Sources/AnimiEngineDiagnostics/BenchmarkRun.swift`
- `AnimiEngineNext/Sources/AnimiEngineDiagnostics/RunArtifacts.swift`
- `AnimiEngineNext/Sources/AnimiEngineDiagnostics/RunFileSystem.swift`
- `AnimiEngineNext/Sources/AnimiEngineTestSupport/FaultInjectingRunFileSystem.swift`
- `AnimiEngineNext/Tests/AnimiEngineNextTests/EvidenceArtifactTests.swift`
- `AnimiEngineNext/Tests/AnimiEngineNextTests/EvidenceIntegrityTests.swift`
- `AnimiEngineNext/Tests/AnimiEngineNextTests/TransactionalCloseTests.swift`
- `AnimiEngineNext/README.md`
- `Docs/AnimiEngineNext/decision-register.md`
- `Docs/AnimiEngineNext/source-traceability.md`

### 14.2 Create - `Sources/AnimiEngineRenderModel`

- `RenderConfiguration.swift`
- `RenderColorContract.swift`
- `RenderNumericTypes.swift`
- `RenderMaterialTable.swift`
- `AnimationProgram.swift`
- `ResolvedPixelInput.swift`
- `ResolvedMediaPlacement.swift`
- `RenderGraph.swift`
- `RenderGraphCommands.swift`
- `RenderedFrame.swift`
- `RenderModelError.swift`
- `RenderCanonicalEncoding.swift`

### 14.3 Create - `Sources/AnimiEngineTemplateAdapter`

- `TemplatePackageLoader.swift`
- `TemplateAssetIndex.swift`
- `CompiledTemplateEnvelope.swift`
- `CompiledTemplateDecoder.swift`
- `CompiledTemplateDTO.swift`
- `CompiledAnimIRDTO.swift`
- `CompiledTemplateStrictJSON.swift`
- `CompiledTemplateConverter.swift`
- `CompiledAnimationConverter.swift`
- `TemplateVariantInventory.swift`
- `TemplateContentHash.swift`
- `TemplateAdapterError.swift`

### 14.4 Create - `Sources/AnimiEngineRenderGraph`

- `RenderInputResolver.swift`
- `RenderGraphCompiler.swift`
- `RenderGraphValidator.swift`
- `AnimationSampler.swift`
- `CubicBezierSampler.swift`
- `MediaFitResolver.swift`
- `MaskMatteGraphBuilder.swift`
- `TransitionGraphBuilder.swift`
- `OverlayGraphBuilder.swift`
- `TransitionEasing.swift`
- `RenderGraphError.swift`

### 14.5 Create - `Sources/AnimiEngineMetalRender`

- `MetalRenderSession.swift`
- `MetalPipelineLibrary.swift`
- `MetalResourceOwner.swift`
- `MetalTextureAllocator.swift`
- `MetalResourceUploader.swift`
- `MetalGraphExecutor.swift`
- `MetalSceneCompositor.swift`
- `MetalMaskMatteCompositor.swift`
- `MetalTransitionCompositor.swift`
- `MetalColorConverter.swift`
- `MetalFrameReadback.swift`
- `MetalRenderError.swift`
- `Shaders/AnimiEngineRender.metal`

### 14.6 Create - `Sources/AnimiEngineRenderTestSupport`

- `RealTemplateRepository.swift`
- `DeterministicPixelFixtures.swift`
- `StaticVideoFrameFixtures.swift`
- `RenderRunRecorder.swift`
- `RenderManifest.swift`
- `PNGCodec.swift`
- `PixelComparator.swift`
- `SSIMComparator.swift`
- `DifferenceImage.swift`
- `ReferenceStore.swift`
- `ReferencePromotion.swift`
- `ReferenceApproval.swift`
- `ContactSheet.swift`

### 14.7 Create - Diagnostics

- `AnimiEngineNext/Sources/AnimiEngineDiagnostics/SupplementalArtifact.swift`
- `AnimiEngineNext/Tests/AnimiEngineNextTests/SupplementalArtifactTests.swift`
- `AnimiEngineNext/Tests/AnimiEngineNextTests/SupplementalArtifactTransactionTests.swift`

### 14.8 Create - Tests

Under `Tests/AnimiEngineTemplateAdapterTests/`:

- `CompiledTemplateEnvelopeTests.swift`
- `CompiledTemplateSchemaTests.swift`
- `CompiledVariantInventoryTests.swift`
- `TemplateAssetResolutionTests.swift`
- `RenderNumericConversionTests.swift`
- `TemplateCanonicalConversionTests.swift`
- `Task003DependencyBoundaryTests.swift`

Under `Tests/AnimiEngineRenderGraphTests/`:

- `RenderInputResolverTests.swift`
- `MediaFitResolutionTests.swift`
- `RenderGraphDeterminismTests.swift`
- `RenderGraphValidationTests.swift`
- `RenderOrderingTests.swift`
- `AnimationSamplingTests.swift`
- `MaskMatteGraphTests.swift`
- `TransitionRenderGraphTests.swift`
- `TransitionPlaybackSemanticsTests.swift`
- `Task003ErrorModelTests.swift`

Under `Tests/AnimiEngineMetalRenderTests/`:

- `MetalTestEnvironment.swift`
- `ColorAlphaContractTests.swift`
- `IntermediateProfileTests.swift`
- `MaskMatteMetalTests.swift`
- `TransitionRenderTests.swift`
- `MetalResourceOwnershipTests.swift`
- `MetalRepeatabilityTests.swift`
- `ReferenceStoreTests.swift`
- `ReferencePromotionTests.swift`
- `RealTemplateLevel2Tests.swift`
- `StaticStructuralStressTests.swift`
- `RenderEvidenceTests.swift`
- `Resources/References/` - approved references and metadata only after explicit promotion

### 14.9 Create - Documentation

- `AnimiEngineNext/Docs/ADR-010-render-and-color-contract.md`
- `Docs/AnimiEngineNext/claude-task-003-implementation-report.md`

### 14.10 Delete

None.

### 14.11 Forbidden

No implementation change is allowed under:

- `TVECore/`
- `AnimiApp/`
- `SceneSources/`
- `SharedAssets/`
- any `*.xcodeproj`
- any `*.pbxproj`

Those paths may be read as explicitly described by this plan.

---

## 15. Dirty-Tree Proof

The repository already contains pre-existing dirty/untracked product and template paths.

Therefore Task 003 must not claim that forbidden paths are absent from `git status`.

Before implementation Claude must record:

```text
git status --short
git status --short -- TVECore AnimiApp SceneSources SharedAssets
```

The final report must compare the final scoped status with that initial snapshot and prove Task 003
introduced no new forbidden-path entry and changed no pre-existing forbidden-path bytes.

The report must also list every created and modified Task-003 file exactly.

---

## 16. ADR-010 Required Content

ADR-010 records:

1. immutable RenderGraph and stateful Metal executor boundary;
2. complete render-input rule;
3. coordinate system and fixed-point conversion;
4. layer, matte, mask, transition and overlay ordering;
5. on-demand animation sampling;
6. transition easing equations;
7. BGRA8 sRGB SDR output;
8. linear-light premultiplied source-over composition;
9. configurable intermediate profiles and deferred D-208 winner;
10. same-environment repeatability vs cross-device comparison;
11. explicit resource ownership;
12. typed failure and no silent substitution;
13. shared preview/export render semantics for future gates;
14. deferred decoder, scheduler, proxy, cache, text, audio and export work.

ADR-010 is marked accepted only when implementation and tests satisfy this plan.

---

## 17. Implementation Sequence

Claude must implement in this order:

1. Record the initial dirty-tree snapshot.
2. Add the narrow transactional supplemental-artifact extension and its fault-injection tests.
3. Add package targets and dependency-boundary tests.
4. Implement render-model values and canonical encoding/hashing.
5. Implement `.tve` envelope and strict schema-2 decoding.
6. Enumerate and validate all five real compiled-template variant inventories.
7. Convert compiled templates into Task-002 canonical payloads and render materials.
8. Implement complete fixture pixel and media-fit resolution.
9. Implement and test deterministic RenderGraph compilation without Metal.
10. Implement Metal color contract and basic image composition.
11. Add masks, mattes, authored animation sampling and graph execution.
12. Add cut, fade, slide and overlay execution.
13. Implement candidate generation, comparison, diff, contact sheet and evidence recording.
14. Run the complete real-template/frame matrix and structural fixtures.
15. Produce a sealed candidate-reference benchmark run.
16. Stop for explicit human review and reference approval.
17. After approval, promote references through the guarded tool and rerun the complete suite.
18. Write ADR-010, update control documents and produce the implementation report.
19. Stop. Do not start Task 004.

---

## 18. Acceptance Gates

Task 003 is accepted only when all gates pass.

### G1 - Isolation

- no imports or package dependencies on `TVECore`, `TVECompilerCore` or `AnimiApp`;
- no forbidden path changed relative to the initial snapshot.

### G2 - Build and regression

- `swift build` succeeds without new warnings;
- the complete Task-001, Task-002 and Task-003 `swift test` suite passes;
- no Task-001/002 behavior is weakened.

### G3 - Adapter completeness

- all five real compiled packages decode;
- every compiled block and variant is enumerated;
- every explicit selection converts to a valid Task-002 canonical document;
- malformed, unsupported and missing data fails with typed errors.

### G4 - RenderGraph correctness

- graph compilation is deterministic;
- graph is complete and independently validated;
- no IO, Metal or mutable project lookup occurs in the compiler.

### G5 - Metal correctness

- all required real-template features render;
- complete output only;
- no partial or stale publication;
- same-environment repeated output bytes match;
- color/alpha analytic tests pass.

### G6 - Transition semantics

- cut, fade and slide matrices pass;
- incoming hold-first passes;
- outgoing scene continues through transition completion;
- total project duration and Task-002 timing remain unchanged.

### G7 - Evidence

- all evidence is written through staging;
- supplemental artifact hashes are committed by the run manifest;
- injected failures publish nothing;
- every candidate frame has configuration, device, template, material, graph and pixel identity.

### G8 - References

- normal tests cannot update references;
- complete contact sheet and differences are reviewed;
- owner approval metadata is recorded;
- every real-template reference is promoted only through the guarded path;
- the final approved reference suite passes.

### G9 - Structural scale

- static 10-overlay, 20-layer and 20-to-20 transition cases produce complete correct frames;
- no realtime claim is made from these tests.

### G10 - Report

The implementation report includes:

- exact changed-file list;
- initial and final forbidden-path snapshots;
- exact commands;
- build/test counts and failures/skips;
- requirement-to-test mapping;
- all benchmark run IDs;
- reference approval record;
- known limitations;
- confirmation that Task 004 was not started.

---

## 19. Stop Rules

Claude must stop and report before proceeding if:

- a required real compiled variant cannot be represented without changing Task-002 contracts;
- implementation requires modifying a forbidden path;
- compiled schema 2 differs materially from the documented envelope;
- a real template requires an unsupported feature not covered by this plan;
- same-environment Metal output is not repeatable;
- transactional evidence guarantees cannot be preserved;
- approved references cannot be produced honestly.

Claude must not silently narrow the test matrix, ignore a feature, add a fallback or proceed to
Task 004.

---

## 20. Planning-Pass Confirmation

This Revision 2 closes all Task-003 architecture decisions.

During the planning pass:

- only `Docs/AnimiEngineNext/claude-task-003-plan.md` is modified;
- no source, test, package, ADR, product or template file is modified;
- Task 003 implementation is not started;
- Task 004 is not started.
