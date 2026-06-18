# Task 002 - Canonical Project Model, Exact Time, and Pure Timeline Evaluation

**Plan revision:** 5 - FINAL / APPROVED FOR IMPLEMENTATION  
**Gate:** planning is complete; implementation may start only after the technical lead explicitly says
to start.  
**Implementation scope:** `AnimiEngineNext/` and Task-002 documentation under
`Docs/AnimiEngineNext/` only.

This document replaces all earlier Task-002 revisions.

## 0. Goal

Task 002 builds the deterministic functional core that answers:

> At exact project time `T`, which scene subplans, layers, source requests, animations, transition
> state, and global overlays are active, and in what composition order?

The output is an immutable, hierarchical, render-complete `FramePlan`.

Task 002 includes:

- canonical project and resolved scene value models;
- exact project, local, animation, overlay, and source time;
- strict canonical persistence;
- a lightweight timeline and overlay index;
- immutable evaluation-window construction;
- pure scene/transition/overlay evaluation;
- variable-duration animated transitions and zero-duration cuts;
- the approved hold-first incoming-scene policy;
- outgoing scene continuation beyond nominal scene end;
- deterministic ordering and fixed-point geometry;
- Level-1 functional tests, including real template descriptors and synthetic 20-video/10-text cases.

Task 002 does not include:

- AVFoundation, VideoToolbox, CoreMedia, Metal, media decoding, or sample lookup;
- proxy, cache, scheduler, audio, export, UI, or device benchmark host;
- current-product integration;
- `ProjectDraft` or `.tve` adapters;
- D-104 or D-108 implementation;
- Task 003.

No files under `TVECore/`, `AnimiApp/`, `SceneSources/`, `*.xcodeproj`, or `*.pbxproj` may be modified.

## 1. Fixed Decisions

These decisions are closed for Task 002.

### 1.1 Project time

- Canonical project time uses signed-storage `Int64` ticks at exactly 240,000 ticks per second.
- Public non-negative time types reject negative values.
- Durations and instants are different types.
- Project timeline arithmetic never uses `Float`, `Double`, microseconds, or implicit frame rounding.
- Supported output rates have exact integer frame durations:

| Rate | Rational rate | Ticks per frame |
|---|---:|---:|
| 23.976 | 24000/1001 | 10010 |
| 24 | 24/1 | 10000 |
| 25 | 25/1 | 9600 |
| 29.97 | 30000/1001 | 8008 |
| 30 | 30/1 | 8000 |
| 50 | 50/1 | 4800 |
| 59.94 | 60000/1001 | 4004 |
| 60 | 60/1 | 4000 |

### 1.2 Transition behavior

- `.cut` is a hard scene change and has duration zero.
- Animated transitions have a configurable duration per scene boundary.
- Fade and Slide are the first supported animated effects.
- The transition window is centered around the nominal scene boundary.
- Transitions do not add or remove project duration.
- A scene's nominal end is not a playback clamp.
- During an animated transition, the outgoing scene keeps playing at normal speed after its nominal end.
- Video is never silently frozen, clamped, slowed, or retimed.
- Before the boundary, the incoming scene participates visually but its own scene, animation, and video
  playback remain at time zero. Only the transition effect progresses.
- At and after the boundary, the incoming scene starts from zero and advances at normal speed.
- Global overlays composite above the completed scene or transition result.
- If an animated transition cannot be evaluated honestly, validation rejects it. The engine never
  shortens it or substitutes a cut.

### 1.3 Scene and overlay ownership

- Scene-owned layers are video or image layers.
- Text, stickers, and graphics are global timeline overlays in v1.
- Scene subplans order their own layers.
- A transition combines two completed scene subplans.
- Global overlays are ordered separately above the body.

### 1.4 Determinism

- All canonical persisted geometry is fixed-point `Int64`.
- All ordering has an explicit stable tiebreaker.
- Equal `zIndex` values are allowed.
- Canonical JSON has deterministic keys, integer formatting, and enum tags.
- Invalid persistence and invalid project semantics are separate error categories.

## 2. Source Evidence and Existing Formats

Task 002 follows:

- `Docs/Animi - Canonical System Specification.docx`;
- `Docs/deep-research-report.md`;
- `Docs/deep-research-report_v2.md`;
- `Docs/AnimiEngineNext/decision-register.md`;
- `Docs/AnimiEngineNext/architecture-proposal.md`;
- `Docs/AnimiEngineNext/validation-contract.md`;
- `Docs/AnimiEngineNext/source-traceability.md`;
- ADR-001 and ADR-014;
- the five real template folders under `SceneSources/`.

Research-backed constraints used here:

- project-domain time is 240,000 ticks per second;
- source timestamps retain exact rational meaning;
- time ranges are half-open `[start, end)`;
- source sample selection later uses the presentation interval containing the exact target;
- scenes are composition subgraphs on one master project timeline;
- evaluated frame plans are immutable;
- dense transitions must not require a flat cross-scene layer order;
- runtime evaluation must operate on a bounded active window.

The current engine's compressed timeline and frozen outgoing frame are explicitly not copied.

## 3. Module Boundary

Add one independent library target:

```text
AnimiEngineCore
  Time/
  Geometry/
  Project/
  Codec/
  Timeline/
  Evaluator/
```

`AnimiEngineCore` has no dependency on `AnimiEngineNext`, diagnostics, app code, AVFoundation, or IO.

`AnimiEngineTestSupport` gains a dependency on `AnimiEngineCore` for fixtures only.

## 4. Exact Time Model

### 4.1 Project-domain types

```swift
public enum TickClock {
    public static let ticksPerSecond: Int64 = 240_000
}

public struct ProjectTime: Hashable, Comparable, Sendable {
    public let ticks: Int64                 // >= 0
}

public struct TickDuration: Hashable, Comparable, Sendable {
    public let ticks: Int64                 // >= 0
}

public struct ScenePlaybackTime: Hashable, Comparable, Sendable {
    public let ticks: Int64                 // >= 0
}

public struct AnimationPlaybackTime: Hashable, Comparable, Sendable {
    public let ticks: Int64                 // >= 0
}

public struct OverlayPlaybackTime: Hashable, Comparable, Sendable {
    public let ticks: Int64                 // >= 0
}

public struct TransitionRelativeTime: Hashable, Comparable, Sendable {
    public let ticks: Int64                 // signed, relative to boundary B
}
```

Required type-directed operations:

- `ProjectTime + TickDuration -> ProjectTime`;
- `ProjectTime - ProjectTime -> TickDuration`, only when left >= right;
- `ScenePlaybackTime + TickDuration -> ScenePlaybackTime`;
- explicit conversion from scene-local ticks to animation-local ticks;
- explicit conversion from project-local delta to overlay-local ticks;
- explicit conversion from overlay-local ticks to animation-local ticks;
- checked `Int64` addition, subtraction, and multiplication;
- typed errors instead of traps or wrapping.

`FrameRate` and `FrameIndex` are separate from timeline time:

```swift
public struct FrameRate: Hashable, Sendable {
    public let numerator: Int64
    public let denominator: Int64
    public var exactTicksPerFrame: Int64 { get throws }
}

public struct FrameIndex: Hashable, Comparable, Sendable {
    public let value: Int64                 // >= 0
}
```

`FrameIndex -> ProjectTime` is exact for supported rates. Reverse conversion requires an explicit
rounding policy and is never used implicitly in timeline math.

### 4.2 Exact rational source time

Source targets are not forced into the asset's native integer tick grid.

```swift
public struct RationalSourceTime: Hashable, Comparable, Sendable {
    public let numerator: Int64              // signed
    public let denominator: Int64            // > 0
}

public struct SourceTimescale: Hashable, Sendable {
    public let unitsPerSecond: Int64          // > 0, original asset metadata
}

public struct PlaybackRate: Hashable, Sendable {
    public let numerator: Int64               // > 0 in v1
    public let denominator: Int64             // > 0
    public static let oneToOne: PlaybackRate
}

public struct RationalSourceRange: Hashable, Sendable {
    public let start: RationalSourceTime
    public let end: RationalSourceTime         // exclusive; end > start
}
```

`RationalSourceTime` is always reduced by GCD and has a positive denominator. Therefore:

- `1000/30000` is stored as `1/30`;
- `15000/30000`, `300/600`, and `1/2` are equal;
- one project tick at rate 1/1 is exactly `1/240000` second;
- negative source PTS values are allowed;
- original asset timescale is retained separately in `SourceTimescale`.

Exact arithmetic rules:

- GCD cross-cancellation happens before rational multiplication and addition.
- `Int64.multipliedFullWidth(by:)` is used for non-throwing exact comparison.
- `Comparable` never throws.
- Normalization throws a typed overflow error only if the final reduced numerator or denominator cannot
  fit its required `Int64` representation.
- No undefined "widen on overflow", `Decimal`, `Float`, or `Double` path is allowed.

```swift
public struct SourceTimeMapping: Equatable, Sendable {
    public let trimRange: RationalSourceRange
    public let nativeTimescale: SourceTimescale
    public let rate: PlaybackRate               // 1/1 in v1

    public func target(for sceneTime: ScenePlaybackTime) throws -> RationalSourceTime
}
```

For scene ticks `s`, rate `rn/rd`, and trim start `a`:

```text
target = a + (rn * s) / (rd * 240000)
```

The result is a normalized exact rational. It is not rounded to `nativeTimescale`.

```swift
public struct SourceRequest: Equatable, Sendable {
    public let media: MediaReference
    public let target: RationalSourceTime
    public let selection: SampleSelectionPolicy
}

public enum SampleSelectionPolicy: Equatable, Sendable {
    case presentationIntervalContainsTarget
}
```

Actual sample-table lookup is deferred. Task 002 only emits the exact request.

## 5. Fixed-Point Geometry

Canonical geometry uses mandatory units:

| Quantity | Type | Exact unit |
|---|---|---|
| Position and size | `CanvasScalar` | 65,536 raw units per canvas point |
| Scale | `ScaleScalar` | 1,000,000 raw units per 1.0 |
| Rotation | `RotationScalar` | 1,000 raw units per degree |

```swift
public struct CanvasScalar: Hashable, Comparable, Sendable {
    public let rawValue: Int64
}

public struct ScaleScalar: Hashable, Comparable, Sendable {
    public let rawValue: Int64
}

public struct RotationScalar: Hashable, Comparable, Sendable {
    public let rawValue: Int64
}

public struct FixedPoint: Hashable, Sendable {
    public let x: CanvasScalar
    public let y: CanvasScalar
}

public struct FixedRect: Hashable, Sendable {
    public let x: CanvasScalar
    public let y: CanvasScalar
    public let width: CanvasScalar
    public let height: CanvasScalar
}
```

All construction and arithmetic are checked. Width, height, and scale must be positive where required.
Conversions from current authoring `Double` values belong to the future adapter, not the core.

## 6. Canonical Project Model

### 6.1 Lightweight manifest and resolved payloads

The runtime must not require all scene payloads to evaluate one frame.

```swift
public struct CanonicalProjectManifest: Equatable, Sendable {
    public let schemaVersion: Int
    public let output: OutputContext
    public let scenes: [SceneManifestEntry]
    public let boundaryTransitions: [SceneTransition]
    public let overlays: [OverlayManifestEntry]
}

public struct SceneManifestEntry: Equatable, Sendable {
    public let id: SceneInstanceID
    public let payloadID: ScenePayloadID
    public let nominalDuration: TickDuration
    public let postRollCapability: TickDuration
}

public struct OverlayManifestEntry: Equatable, Sendable {
    public let id: OverlayID
    public let payloadID: OverlayPayloadID
    public let timeRange: ProjectTimeRange
    public let zIndex: Int
    public let stableOrdinal: Int
}
```

Resolved payloads are immutable and loaded by a later IO/scheduler layer:

```swift
public struct ResolvedScenePayload: Equatable, Sendable {
    public let payloadID: ScenePayloadID
    public let sceneID: SceneInstanceID
    public let templateRef: TemplateReference
    public let layers: [SceneLayer]
}

public struct ResolvedOverlayPayload: Equatable, Sendable {
    public let payloadID: OverlayPayloadID
    public let overlayID: OverlayID
    public let content: OverlayContent
    public let placement: Placement
    public let animation: AnimationReference?
}
```

The persisted project document may contain the manifest and payload tables, but runtime evaluation uses
the manifest-derived index plus only selected payloads.

### 6.2 Scene content

```swift
public struct SceneLayer: Equatable, Sendable {
    public let id: LayerID
    public let zIndex: Int
    public let stableOrdinal: Int
    public let activeRange: ScenePlaybackRange
    public let placement: Placement
    public let content: SceneLayerContent
    public let animation: AnimationReference?
}

public enum SceneLayerContent: Equatable, Sendable {
    case video(VideoBinding)
    case image(ImageReference)
}

public struct VideoBinding: Equatable, Sendable {
    public let media: MediaReference
    public let sourceMapping: SourceTimeMapping
}

public struct ScenePlaybackRange: Equatable, Sendable {
    public let start: ScenePlaybackTime
    public let end: ScenePlaybackTime             // exclusive; end > start
}
```

There is no `.video` with optional media. Every active video layer can produce a complete
`SourceRequest`.

### 6.3 Animation policy

The two real authoring concepts remain distinct:

```swift
public enum AnimationShorterPolicy: Equatable, Sendable {
    case holdLast
    case loop
    case becomeInactive
}

public enum AnimationLongerPolicy: Equatable, Sendable {
    case cutAtEvaluationEnd
}

public struct AnimationReference: Equatable, Sendable {
    public let variantID: String
    public let animationRef: String
    public let authoredDuration: TickDuration
    public let ifShorter: AnimationShorterPolicy
    public let ifLonger: AnimationLongerPolicy
}
```

The evaluator emits an explicit request:

```swift
public enum AnimationRequest: Equatable, Sendable {
    case sample(AnimationPlaybackTime)
    case looped(AnimationPlaybackTime)
    case holdLast
    case inactive
}
```

Rules:

- every present `AnimationReference` has `authoredDuration > 0`;
- before `authoredDuration`, emit `.sample(time)`;
- after the authored end:
  - `.loop` emits `.looped(timeWithinRange)`;
  - `.holdLast` emits `.holdLast`;
  - `.becomeInactive` emits `.inactive`;
- `.holdLast` applies only to template animation, never to video source playback;
- if a layer is required to stay visible while a `.becomeInactive` animation has ended, semantic
  validation rejects that transition/project configuration;
- the half-open animation endpoint is never represented as a fabricated "last time".

The five real templates map `ifAnimationShorter: holdLastFrame` to `.holdLast` and
`ifAnimationLonger: cut` to `.cutAtEvaluationEnd`.

### 6.4 Global overlays

```swift
public enum OverlayContent: Equatable, Sendable {
    case text(TextContentReference)
    case sticker(ImageReference)
    case graphic(ImageReference)
}
```

Text/sticker/graphic payloads are global timeline elements and never scene layers.

### 6.5 Output and ordering

```swift
public struct OutputContext: Equatable, Sendable {
    public let canvas: CanvasSize
    public let frameRate: FrameRate
}
```

- Scene layers order by `(zIndex, stableOrdinal)`.
- Global overlays order by `(zIndex, stableOrdinal)`.
- Structural IDs are unique in their scope.
- `stableOrdinal` is unique in its scope.
- Equal `zIndex` values are valid.

## 7. Transition Model

### 7.1 Serialized effect envelope

```swift
public enum TransitionKind: Equatable, Sendable {
    case cut
    case animated(TransitionEffect)
}

public struct TransitionEffect: Equatable, Sendable {
    public let effectID: TransitionEffectID
    public let parameters: TransitionParameterSet
}

public struct TransitionParameter: Equatable, Sendable {
    public let key: String
    public let value: TransitionParameterValue
}

public enum TransitionParameterValue: Equatable, Sendable {
    case integer(Int64)
    case fixed(ScaleScalar)
    case identifier(String)
    case boolean(Bool)
}

public struct TransitionParameterSet: Equatable, Sendable {
    public let sortedUniqueParameters: [TransitionParameter]
}

public struct SceneTransition: Equatable, Sendable {
    public let kind: TransitionKind
    public let duration: TickDuration
    public let easing: EasingReference
}
```

Validation:

- Cut accepts duration zero only.
- Animated effects require duration greater than zero.
- Fade initially accepts exactly its documented parameter set, empty in Task 002.
- Slide requires exactly one `direction` identifier with one of `left/right/up/down`.
- Missing, extra, duplicate, or wrong-type parameters are typed errors.
- Unknown effect IDs are typed unsupported-effect errors.
- Canonical encoding sorts parameter keys.

### 7.2 Window formula

For animated duration `D` around boundary `B`:

```text
preHalf  = floor(D / 2)
postHalf = D - preHalf
window   = [B - preHalf, B + postHalf)
progress = (T - window.start) / D
```

The extra odd tick belongs after `B`.

Inside the half-open window, `0 <= progress < 1`. At `window.end`, no transition exists and the incoming
scene is sole. `progress == 1` is never emitted.

### 7.3 Scene playback mapping

Outgoing:

```text
sceneTime = T - outgoingSceneStart
```

It continues beyond nominal duration at normal speed.

Incoming:

```text
if T < B:  sceneTime = 0
if T >= B: sceneTime = T - B
```

Before `B`, the incoming scene is evaluated at its first state while transition progress advances.

### 7.4 Project duration

```text
projectDuration = sum(scene.nominalDuration)
```

Transition duration never changes this value.

### 7.5 Adjacent transitions

For a middle scene with nominal duration `d`:

```text
postHalf(previousBoundary) + preHalf(nextBoundary) <= d
```

Otherwise the project would require an unsupported three-scene overlap and validation rejects it.

## 8. Exact Material Availability

All ranges are half-open.

### 8.1 Actual evaluated scene-time intervals

For an outgoing scene:

```text
transitionSceneInterval =
    [nominalDuration - preHalf, nominalDuration + postHalf)
```

For an incoming scene under hold-first:

```text
before B: effective scene time is the single value 0
after B:  effective scene interval is [0, postHalf)
```

Each layer is evaluated only over the intersection with its own `activeRange`.

No post-roll requirement is imposed on a layer that is not active in post-roll.

### 8.2 Integer-tick endpoint rule

For non-empty integer tick interval `[start, end)`:

```text
first requested scene tick = start
last requested scene tick  = end - 1
```

Therefore:

- the outgoing transition's latest possible scene tick is
  `nominalDuration + postHalf - 1`;
- the incoming post-boundary latest possible scene tick is `postHalf - 1`;
- no request is emitted at an exclusive endpoint.

### 8.3 Video availability

For every non-empty intersection between transition evaluation and a video layer's active range:

1. Map the first and last requested scene ticks with `SourceTimeMapping`.
2. Because v1 playback rate is positive, those are the minimum and maximum targets.
3. Require both targets to satisfy:

```text
trimRange.start <= target < trimRange.end
```

Failure produces a typed outgoing/incoming video-material error.

No source request is clamped to the trim range.

### 8.4 Image availability

Static images need no temporal source material.

### 8.5 Animation availability

Evaluate animation requests only for scene times where the layer is active.

- `.holdLast` and `.loop` can cover transition continuation.
- `.becomeInactive` cannot cover an interval after authored animation material ends.
- If the layer must remain active beyond that point, validation rejects the project or animated
  transition with a typed error.

### 8.6 Scene-level availability

An animated transition additionally requires:

- outgoing nominal duration >= `preHalf`;
- outgoing scene post-roll capability >= `postHalf`;
- incoming nominal duration >= `postHalf`;
- no adjacent transition overlap.

Cut is always available.

## 9. Template Boundary

The current `scene.json` files describe reusable media-binding slots, not instantiated project media.
They must not be fabricated directly as resolved canonical scenes.

Task-002 test support defines:

```swift
struct TemplateFixtureDescriptor {
    let catalogID: String
    let sceneID: String
    let canvas: CanvasSize
    let frameRate: FrameRate
    let duration: TickDuration
    let slots: [TemplateSlotDescriptor]
}
```

Test flow:

1. Read each real template structurally.
2. Build a test-only `TemplateFixtureDescriptor`.
3. Assert that authoring fields, variants, timing, and binding keys are representable.
4. Instantiate it deterministically with explicit fake video/image bindings.
5. Produce valid resolved `SceneManifestEntry` and `ResolvedScenePayload` values.
6. Evaluate render-complete frame plans from the instantiated payloads.

This is test-only fixture adaptation. It does not implement D-104, `.tve` loading, or current-product
conversion.

## 10. Lazy Timeline and Window Model

### 10.1 Timeline index

```swift
public struct TimelineIndex: Equatable, Sendable {
    public let output: OutputContext
    public let projectDuration: TickDuration
    public let sceneIndex: SceneSpanIndex
    public let boundaryIndex: BoundaryIndex
    public let overlayIndex: OverlayIntervalIndex

    public init(manifest: CanonicalProjectManifest) throws
    public func lookup(at time: ProjectTime) throws -> TimelineLookupResult
    public func requirements(for coverage: ProjectTimeRange) throws -> EvaluationWindowRequirement
}
```

Requirements:

- scene lookup uses binary search: `O(log n)`;
- active overlay lookup uses an immutable augmented interval tree:
  `O(log n + k)`, where `k` is the number of returned overlays;
- interval-tree nodes store deterministic ordering keys and subtree maximum end;
- returned overlay IDs are deterministically ordered;
- all prefix sums and range calculations are overflow-checked.

```swift
public struct TimelineLookupResult: Equatable, Sendable {
    public let requiredSceneIDs: [SceneInstanceID]       // one or outgoing+incoming
    public let requiredScenePayloadIDs: [ScenePayloadID]
    public let transition: ActiveBoundaryReference?
    public let activeOverlayIDs: [OverlayID]
    public let activeOverlayPayloadIDs: [OverlayPayloadID]
}
```

### 10.2 Evaluation-window requirement

```swift
public struct EvaluationWindowRequirement: Equatable, Sendable {
    public let coverage: ProjectTimeRange
    public let sceneSpans: [RequiredSceneSpan]
    public let transitions: [RequiredBoundary]
    public let overlayEntries: [RequiredOverlayEntry]
}
```

It is the authoritative contract between timeline lookup, later payload loading, and the pure builder.

### 10.3 Window builder

```swift
public enum EvaluationWindowBuilder {
    public static func build(
        requirement: EvaluationWindowRequirement,
        output: OutputContext,
        projectDuration: TickDuration,
        scenes: [ResolvedScenePayload],
        overlays: [ResolvedOverlayPayload]
    ) throws -> EvaluationWindow
}
```

Builder validation:

- supplied payload IDs exactly match the requirement;
- referenced structural IDs match;
- no required scene or overlay is missing;
- no unexpected payload is supplied;
- scene spans and transitions match index metadata;
- duplicate payloads are rejected;
- coverage is non-empty and inside project duration.

```swift
public struct EvaluationWindow: Equatable, Sendable {
    public let coverage: ProjectTimeRange
    public let output: OutputContext
    public let projectDuration: TickDuration
    public let scenes: [WindowScene]
    public let transitions: [WindowTransition]
    public let overlays: [WindowOverlay]
}
```

The evaluator rejects any requested time outside `coverage`.

`evaluate(atFrame:)` first converts the frame index to project time, then performs the same coverage
validation.

No full `CanonicalProject` or payload table is required by the evaluator.

## 11. Canonical Persistence

Task-001 `CanonicalEncoding` is configuration-specific and is not reused.

### 11.1 Persisted document

```swift
public struct CanonicalProjectDocument: Equatable, Sendable {
    public let manifest: CanonicalProjectManifest
    public let scenePayloads: [ResolvedScenePayload]
    public let overlayPayloads: [ResolvedOverlayPayload]
}
```

### 11.2 Strict load pipeline

```swift
public enum CanonicalProjectEncoding {
    public static func encode(_ document: CanonicalProjectDocument) throws -> Data
    public static func decodeValidated(_ data: Data) throws -> CanonicalProjectDocument
}

public enum ProjectLoadError: Error, Equatable, Sendable {
    case decoding(ProjectDecodingError)
    case validation(ProjectValidationError)
}
```

`decodeValidated` is the only public persistence entry point.

Pipeline:

1. Strictly parse JSON into internal raw DTOs.
2. Reject unknown fields recursively at every object depth.
3. Reject missing fields, wrong types, malformed integers, duplicate object keys, and unknown enum tags
   as `ProjectDecodingError`.
4. Convert raw DTOs through validated domain factories.
5. Run cross-object semantic validation.
6. Return semantic failures as `ProjectValidationError` wrapped by `ProjectLoadError.validation`.

No public generic `Codable` decode path may bypass strict unknown-field rejection.

### 11.3 Canonical bytes

- Object keys are lexicographically sorted.
- Integers use fixed base-10 formatting with no exponent or trailing `.0`.
- Enum tags are explicit and pinned.
- Transition parameters are encoded in sorted key order.
- Arrays with semantic ordering preserve that order.
- Payload tables are encoded in deterministic ID order.
- UTF-8 and string escaping are deterministic.
- `encode -> decodeValidated -> encode` is byte-stable.

Duplicate IDs, invalid transition material, invalid ranges, and adjacency violations are validation
errors, not malformed-JSON errors.

## 12. Hierarchical FramePlan

```swift
public struct FramePlan: Equatable, Sendable {
    public let output: OutputContext
    public let projectTime: ProjectTime
    public let body: FrameBody
    public let overlays: [ActiveOverlay]
}

public enum FrameBody: Equatable, Sendable {
    case single(SceneSubplan)
    case transition(TransitionPlan)
}

public struct SceneSubplan: Equatable, Sendable {
    public let sceneID: SceneInstanceID
    public let role: SceneRole
    public let scenePlaybackTime: ScenePlaybackTime
    public let transitionRelativeTime: TransitionRelativeTime?
    public let layers: [ActiveLayer]
}

public struct TransitionPlan: Equatable, Sendable {
    public let effectID: TransitionEffectID
    public let parameters: TransitionParameterSet
    public let easing: EasingReference
    public let progressNumerator: Int64
    public let progressDenominator: Int64
    public let outgoing: SceneSubplan
    public let incoming: SceneSubplan
}

public struct ActiveLayer: Equatable, Sendable {
    public let layerID: LayerID
    public let zIndex: Int
    public let stableOrdinal: Int
    public let localCompositionOrder: Int
    public let placement: Placement
    public let content: ActiveSceneContent
    public let animationReference: AnimationReference?
    public let animationRequest: AnimationRequest?
}

public enum ActiveSceneContent: Equatable, Sendable {
    case video(SourceRequest)
    case image(ImageReference)
}

public struct ActiveOverlay: Equatable, Sendable {
    public let overlayID: OverlayID
    public let zIndex: Int
    public let stableOrdinal: Int
    public let compositionOrder: Int
    public let placement: Placement
    public let content: OverlayContent
    public let animationReference: AnimationReference?
    public let animationRequest: AnimationRequest?
    public let playbackTime: OverlayPlaybackTime
}
```

The renderer never needs to read mutable project state to interpret a `FramePlan`.

## 13. Pure Evaluation Algorithm

For `evaluate(window, at: T)`:

1. Reject `T` outside the project's half-open range.
2. Reject `T` outside `window.coverage`.
3. Locate the active scene/boundary using window metadata.
4. For Cut or normal playback, build one `.sole` scene subplan.
5. Inside an animated window:
   - calculate exact rational progress;
   - calculate outgoing scene time;
   - calculate hold-first incoming scene time;
   - build each scene subplan independently;
   - combine them in `TransitionPlan`.
6. For each scene layer:
   - test half-open `activeRange` visibility at effective scene time;
   - create exact `SourceRequest` for video;
   - create `AnimationRequest` from authored policy;
   - order by `(zIndex, stableOrdinal)`;
   - assign dense local order.
7. Evaluate global overlays active at `T`.
8. Order overlays by `(zIndex, stableOrdinal)` and place them above the body.
9. Return an immutable value-equal `FramePlan`.

The evaluator performs no IO, decoding, rendering, clocks, caching, or mutable lookup.

## 14. Worked Example

Two nominal three-second scenes:

```text
Scene A: [0, 720000)
Scene B: [720000, 1440000)
Boundary B: 720000
Animated duration D: 240000
preHalf: 120000
postHalf: 120000
Transition window: [600000, 840000)
Project duration: 1440000
```

At 30 fps, one frame is 8000 ticks.

| Frame | Project tick | Progress | A scene time | B scene time | State |
|---:|---:|---:|---:|---:|---|
| 74 | 592000 | - | 592000 | - | A sole |
| 75 | 600000 | 0/240000 | 600000 | 0 | transition |
| 89 | 712000 | 112000/240000 | 712000 | 0 | transition |
| 90 | 720000 | 120000/240000 | 720000 | 0 | transition |
| 91 | 728000 | 128000/240000 | 728000 | 8000 | transition |
| 104 | 832000 | 232000/240000 | 832000 | 112000 | transition |
| 105 | 840000 | - | - | 120000 | B sole |

At frame 105, progress 1 is not emitted because the transition range is half-open.

For a 1/1 video mapping with trim start zero:

```text
frame 91 target = 8000/240000 = 1/30 second
frame 104 target = 112000/240000 = 7/15 second
frame 105 target = 120000/240000 = 1/2 second
```

These values are exact normalized rationals. Native source timescale remains separate metadata.

## 15. Error Model

### 15.1 Time and arithmetic errors

- negative non-negative-domain value;
- invalid denominator/timescale/rate;
- checked integer overflow;
- final normalized rational does not fit;
- invalid frame rate or unsupported exact frame duration;
- invalid half-open range.

### 15.2 Decoding errors

- malformed JSON;
- duplicate JSON object key;
- unknown field with full path;
- missing field;
- wrong primitive type;
- malformed integer;
- unknown enum tag.

### 15.3 Validation errors

- empty project;
- invalid scene duration or post-roll capability;
- transition count mismatch;
- Cut with non-zero duration;
- animated effect with zero duration;
- unsupported effect ID;
- missing, extra, duplicate, or wrong-type transition parameter;
- invalid easing reference;
- duplicate structural ID or stable ordinal;
- invalid scene/layer/overlay range;
- zero or invalid authored animation duration;
- overlay outside project;
- missing or inconsistent payload;
- insufficient video source material;
- unavailable animation continuation;
- insufficient outgoing post-roll;
- adjacent transitions requiring three scenes;
- invalid evaluation-window payload set or coverage.

## 16. ADR Deliverables

### ADR-002 - Project and Template Compatibility

Record:

- manifest/payload split;
- resolved canonical scenes versus reusable template slot descriptors;
- test-only deterministic template instantiation;
- global overlay ownership;
- fixed-point geometry;
- stable ordering;
- strict project persistence;
- D-103 compatibility boundary;
- D-104 and D-108 remain unimplemented.

### ADR-003 - Canonical Time

Record:

- 240,000 project ticks per second;
- separate instant/duration/local domains;
- exact supported frame rates;
- normalized `RationalSourceTime`;
- separate `SourceTimescale`;
- full-width exact comparison and checked rational arithmetic;
- exact `SourceTimeMapping`;
- presentation-interval sample-selection contract;
- no implicit rounding or floating-point canonical state.

### ADR-004 - Transition and Material Semantics

Record:

- Cut versus animated effects;
- exact parameter envelope and easing;
- variable duration and odd-tick rule;
- centered half-open window;
- unchanged project duration;
- outgoing post-roll at normal speed;
- hold-first incoming policy;
- exact range-intersection availability;
- explicit `AnimationRequest`;
- no video clamp/freeze;
- adjacency rejection;
- hierarchical scene-subplan transition composition.

## 17. Files

### Modify

- `AnimiEngineNext/Package.swift`
  - add `AnimiEngineCore` library target/product;
  - add `AnimiEngineCore` to `AnimiEngineTestSupport`;
  - add `AnimiEngineCoreTests`.
- `Docs/AnimiEngineNext/decision-register.md`
  - mark ADR-002/003/004 drafted after implementation.

### Create under `AnimiEngineNext/Sources/AnimiEngineCore/`

Time:

- `Time/TickClock.swift`
- `Time/ProjectTime.swift`
- `Time/TickDuration.swift`
- `Time/ScenePlaybackTime.swift`
- `Time/AnimationPlaybackTime.swift`
- `Time/OverlayPlaybackTime.swift`
- `Time/TransitionRelativeTime.swift`
- `Time/FrameRate.swift`
- `Time/FrameIndex.swift`
- `Time/RationalSourceTime.swift`
- `Time/SourceTimescale.swift`
- `Time/PlaybackRate.swift`
- `Time/SourceTimeMapping.swift`
- `Time/TimeError.swift`

Geometry:

- `Geometry/CanvasScalar.swift`
- `Geometry/ScaleScalar.swift`
- `Geometry/RotationScalar.swift`
- `Geometry/FixedGeometry.swift`
- `Geometry/Placement.swift`

Project:

- `Project/CanonicalProjectDocument.swift`
- `Project/CanonicalProjectManifest.swift`
- `Project/OutputContext.swift`
- `Project/ManifestEntries.swift`
- `Project/ResolvedPayloads.swift`
- `Project/SceneLayer.swift`
- `Project/References.swift`
- `Project/AnimationReference.swift`
- `Project/GlobalOverlay.swift`
- `Project/SceneTransition.swift`
- `Project/TransitionParameters.swift`
- `Project/ProjectValidationError.swift`
- `Project/ProjectValidator.swift`

Codec:

- `Codec/CanonicalProjectEncoding.swift`
- `Codec/RawProjectDTO.swift`
- `Codec/ProjectDecodingError.swift`
- `Codec/ProjectLoadError.swift`

Timeline:

- `Timeline/TimelineIndex.swift`
- `Timeline/OverlayIntervalIndex.swift`
- `Timeline/TimelineLookupResult.swift`
- `Timeline/EvaluationWindowRequirement.swift`
- `Timeline/EvaluationWindow.swift`
- `Timeline/EvaluationWindowBuilder.swift`

Evaluator:

- `Evaluator/SourceRequest.swift`
- `Evaluator/AnimationRequest.swift`
- `Evaluator/FramePlan.swift`
- `Evaluator/TransitionMath.swift`
- `Evaluator/TimelineEvaluator.swift`

### Create under `AnimiEngineNext/Sources/AnimiEngineTestSupport/`

- `TemplateFixtureDescriptor.swift`
- `CanonicalProjectFixtures.swift`

### Create ADRs

- `AnimiEngineNext/Docs/ADR-002-project-and-template-compatibility.md`
- `AnimiEngineNext/Docs/ADR-003-canonical-time.md`
- `AnimiEngineNext/Docs/ADR-004-transition-and-material-semantics.md`

### Create tests under `AnimiEngineNext/Tests/AnimiEngineCoreTests/`

- `TickTimeTests.swift`
- `RationalSourceTimeTests.swift`
- `SourceTimeMappingTests.swift`
- `FrameSamplingTests.swift`
- `FixedGeometryTests.swift`
- `CanonicalProjectEncodingTests.swift`
- `ProjectValidationTests.swift`
- `TimelineIndexTests.swift`
- `OverlayIntervalIndexTests.swift`
- `EvaluationWindowBuilderTests.swift`
- `SceneBoundaryTests.swift`
- `CutTransitionTests.swift`
- `AnimatedTransitionTests.swift`
- `TransitionEffectTests.swift`
- `TransitionAvailabilityTests.swift`
- `AnimationRequestTests.swift`
- `CompositionHierarchyTests.swift`
- `GlobalOverlayTests.swift`
- `OrderingTests.swift`
- `DurationInvarianceTests.swift`
- `DeterminismTests.swift`
- `TemplateFixtureTests.swift`
- `StressFixtureTests.swift`

## 18. Required Test Matrix

### Time

- exact tick durations for all eight supported frame rates;
- 0.5 second equals 120,000 ticks;
- 29.97 frame 90 equals 720,720 project ticks;
- 59.94 frame 90 equals 360,360 project ticks;
- non-negative domains reject negatives;
- checked arithmetic rejects overflow;
- frame-to-time sampling performs no implicit rounding.

### Rational source time

- equivalent fractions normalize and compare equal;
- negative PTS values compare correctly;
- one project tick maps to exactly `1/240000`;
- original `SourceTimescale` remains unchanged;
- different native timescales produce the same rational target;
- full-width comparison works at boundary values;
- GCD cross-cancellation prevents avoidable intermediate overflow;
- irreducible final overflow produces a typed error;
- no source target is rounded or clamped.

### Geometry

- exact 65,536/point, 1,000,000/scale, and 1,000/degree units;
- invalid sizes/scales reject;
- checked overflow rejects;
- canonical round-trip preserves raw values.

### Persistence

- byte-stable encode/decodeValidated/encode;
- unknown fields rejected at every depth;
- duplicate JSON keys rejected;
- stable enum tags pinned by golden tests;
- transition parameter keys sorted;
- decoding and semantic validation errors remain distinct;
- no alternate public decode path bypasses strict loading.

### Timeline and lazy window

- scene lookup is binary-search based;
- overlay interval query returns all overlaps in `O(log n + k)` behavior;
- deterministic overlay ID order;
- checked prefix-sum overflow;
- lookup returns exact required scene/overlay payload IDs;
- builder rejects missing, unexpected, duplicate, or mismatched payloads;
- evaluator rejects time outside window coverage;
- `evaluate(atFrame:)` performs the same coverage check;
- evaluator needs no complete project document.

### Transitions

- Cut duration must be zero and is always available;
- animated duration must be positive;
- several different transition durations coexist;
- odd duration assigns the extra tick after the boundary;
- half-open progress never emits one;
- Fade exact parameter set accepted;
- Slide valid directions accepted;
- unsupported effect, missing parameter, extra parameter, and wrong type rejected;
- easing preserved into `TransitionPlan`;
- total project duration unchanged.

### Approved playback behavior

- outgoing scene time continues beyond nominal end;
- outgoing scene and video are never frozen or clamped;
- incoming scene/video/animation remain at zero before the boundary;
- incoming starts normally at the boundary;
- incoming continues without a jump when the transition ends;
- two completed scene subplans are combined by the transition;
- global overlays remain above the result.

### Material validation

- layer material checks use intersection with the layer's active range;
- inactive post-roll layers require no post-roll media;
- last requested tick is exclusive-end minus one;
- exact rational video targets satisfy `start <= target < end`;
- insufficient outgoing/incoming video range rejects;
- images need no temporal material;
- animation `.sample`, `.looped`, `.holdLast`, and `.inactive` are emitted correctly;
- every animation request carries its immutable `AnimationReference`;
- zero authored animation duration is rejected;
- hold-last animation never freezes video;
- `.becomeInactive` rejects when a still-visible layer would outlive animation material;
- adjacent transitions never require three active scenes.

### Real templates and stress

- all five real templates parse into test-only descriptors;
- block counts are 1/1/2/4/6;
- `example_4blocks` keeps distinct catalog ID and scene ID;
- authoring binding slots resolve only through explicit fake test bindings;
- instantiated scenes produce render-complete payloads;
- real `holdLastFrame` and `cut` authoring policies map correctly;
- one scene with 20 video layers produces 20 ordered active layers;
- a 20-to-20 transition produces two scene subplans of 20 layers;
- 10 animated text overlays remain global and ordered;
- repeated evaluation produces value-equal `FramePlan`s.

## 19. Acceptance Criteria

Task 002 is complete only when Claude reports:

1. All implementation changes remain inside the approved scope.
2. `swift build` succeeds without warnings introduced by Task 002.
3. `swift test` passes the complete Task-001 and Task-002 suite.
4. Every test family above is represented by named tests.
5. No `Float`, `Double`, `CMTime`, AVFoundation, VideoToolbox, Metal, decoder, cache, scheduler, audio,
   export, UI, or product integration enters `AnimiEngineCore`.
6. No canonical source target is rounded to native timescale.
7. No outgoing video frame is clamped or frozen by timeline evaluation.
8. No persistence API bypasses strict recursive validation.
9. The implementation report includes:
   - exact changed-file list;
   - exact commands;
   - build output summary;
   - test count and failures;
   - mapping from acceptance criteria to tests;
   - known gaps;
   - confirmation that Task 003 was not started.

## 20. Deferred Responsibilities

The following remain intentionally deferred:

- actual media sample-table lookup and VFR sample selection;
- AVFoundation/CoreMedia conversion at the media boundary;
- loading scene/overlay payloads from storage;
- current `.tve` and `ProjectDraft` adapters;
- real Lottie interpretation and rendering;
- decoder scheduling, proxy selection, caching, Metal rendering, audio, export, and UI;
- D-104 project adapter;
- D-108 identity model;
- Level-2 rendered-frame and physical-device benchmarks.

These are not unresolved Task-002 decisions.

## 21. Implementation Stop Rule

If implementation reveals a required product-visible behavior not fixed in this document, Claude must:

1. stop;
2. describe the conflict with a concrete example;
3. provide evidence from the source documents or code;
4. propose alternatives;
5. wait for technical-lead approval.

Claude must not silently invent product behavior or begin Task 003.
