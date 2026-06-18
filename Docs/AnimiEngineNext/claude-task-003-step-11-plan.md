# Task 003 / Step 11 - Final Implementation Specification

**Revision 4 - FINAL / OWNER-AUTHORIZED**

Status: implementation specification.  
Scope: Step 11 only.  
Implementation may begin after this document is sent as the GO instruction.  
There are no open decisions, recommendations, alternatives, or approval gates in this revision.

This revision supersedes every earlier Step-11 plan revision in full. In particular, it supersedes:

- the Revision-2 proposal to attach producer triangle indices to `SampledBezier`;
- the Revision-3 claim that producer triangulation encodes a general non-zero fill rule;
- the Revision-3 command-stream interpretation based on consecutive `beginMask` commands;
- any comp-sized allocation rule for mask or matte isolation surfaces;
- any assumption that Metal should flatten Bezier paths or construct stroke geometry.

The accepted Task-003 architecture remains unchanged:

1. Task 002 produces immutable `FramePlan`.
2. The adapter produces immutable canonical render material programs.
3. Step 8 resolves fixture pixels and selected material programs into immutable `ResolvedFrameInput`.
4. Step 9 compiles an explicit, immutable, canonically hashed `RenderGraph`.
5. Step 10 executes the supported graph subset in Metal.
6. Step 11 completes mask, matte, and authored-shape execution without importing the legacy engine and without adding a CPU renderer.

The schema corrections in this document make the Step-9 graph execution-complete. They are not a change to the architecture above.

---

## 0. Mandatory Working Rules

### 0.1 Scope

Implement only:

- exact sampling of producer-flattened path meshes;
- deterministic fill and stroke geometry preparation;
- explicit mask-group graph compilation and validation;
- explicit matte isolation and application;
- Metal rasterization/composition for authored fills, strokes, masks, and mattes;
- canonical encoding/hash updates caused by the schema changes;
- macOS Metal tests and the existing physical iPhone 13 Pro device gate;
- the corresponding decision-register update.

Do not begin Step 12. Fade, slide, and overlay execution remain deferred.

### 0.2 Forbidden dependencies and paths

Production targets must not import or depend on:

- `TVECore`
- `TVECompilerCore`
- `AnimiApp`
- `SceneSources`
- `SharedAssets`

Do not modify:

- `TVECore/`
- `AnimiApp/`
- `SceneSources/`
- `SharedAssets/`
- any existing `*.xcodeproj` or `*.pbxproj`
- `Package.swift`

The existing DeviceGateHost test source may be updated. Its project structure must not be changed.

Legacy files named below are read-only behavioral evidence, never dependencies.

### 0.3 No fallback policy

No fallback, coercion, repair, placeholder geometry, silent omission, or guessed default is permitted.

Forbidden production constructs in changed code:

- `try?`
- `try!`
- force unwrap
- `as!`
- `fatalError`
- `precondition`
- `assertionFailure`
- unchecked arithmetic over graph-, path-, surface-, or media-derived values

Every malformed or unsupported value must fail through a typed error before GPU submission.

### 0.4 Stop conditions

Stop immediately and report exact evidence if any of these occur:

1. A real compiled template contains authored `fill.r == 2`.
2. A required path resource cannot be matched unambiguously to its animated path.
3. Producer-flattened rows do not remain compatible across keyframes.
4. A real authored stroke contains an exact 180-degree reversal that the fixed contract below rejects.
5. M2 Pro or iPhone 13 Pro cannot create the required 4x-MSAA `r16Float` coverage pipeline.
6. The existing iPhone DeviceGateHost cannot execute the new Step-11 gate without project-file changes.
7. A required correction needs a file outside the exact implementation envelope in section 9.

Do not invent a workaround after a stop condition.

---

## 1. Verified Current-Code Facts

These are implementation facts, not design choices.

### 1.1 Control paths and producer meshes are different data

`AnimationSampler.samplePath()` samples `RenderAnimatedPath` / `RenderBezier`: authored anchors with in/out tangents.

`RenderPathResource` stores a different representation:

- `vertexCount`
- producer-flattened `keyframePositions`
- producer triangle `indices`
- exact keyframe times
- optional keyframe easing

The indices address flattened `keyframePositions`. They do not address `SampledBezier.vertices`.

Therefore:

- `SampledBezier` remains control-path data;
- producer indices must never be added to `SampledBezier`;
- fills and masks use a separately sampled producer mesh;
- strokes use the sampled producer polyline and never re-flatten the Bezier.

Read-only evidence:

- `AnimiEngineNext/Sources/AnimiEngineRenderGraph/AnimationSampler.swift`
- `AnimiEngineNext/Sources/AnimiEngineRenderModel/RenderPathResource.swift`
- `TVECore/Sources/TVECore/AnimIR/PathResource.swift` (`PathResourceBuilder`, read-only)

### 1.2 The compiled format does not preserve a general fill-rule field

The source DTO exposes `fill.r`, but the compiled path resource contains flattened vertices and triangles, not a fill-rule tag.

The producer calls Earcut to build the stored triangle mesh. It does not pass a fill-rule parameter.

The repository audit currently finds:

- 30 parsed authored JSON files;
- authored `fill.r == 1`: 25;
- authored `fill.r == 2`: 0;
- authored strokes: 18;
- authored line-cap values: 18 occurrences of `1`, no other value;
- authored line-join values: 18 occurrences of `1`, no other value.

Step 11 therefore reproduces the compiled producer mesh exactly. It must not claim to implement general non-zero or even-odd winding semantics.

### 1.3 Current mask commands are not an adequate group boundary

The current compiler emits one `beginMask` for each mask, followed by content and corresponding `endMask` commands. Consecutive commands are ambiguous when masked precomps contain nested masked layers.

Step 11 replaces this with one explicit mask-group command containing the authored ordered operation list and one matching end command.

### 1.4 Current matte payload is incomplete

Current `matteLink` identifies the matte source but does not identify a fully isolated consumer contribution. Correct matte application requires:

- a fully rendered source surface;
- a fully rendered consumer surface;
- the real destination surface.

All three must be explicit in the graph.

### 1.5 Producer stroke raw values are 1-based

The strict compiled DTO accepts:

- line cap: `1...3`
- line join: `1...3`

The exact mapping is:

- cap `1 = butt`, `2 = round`, `3 = square`;
- join `1 = miter`, `2 = round`, `3 = bevel`.

No 0-based mapping is allowed.

---

## 2. Final Render-Model Contract

All new public value types are immutable, `Hashable`, `Sendable`, canonically encodable, and hash-stable. Their initializers validate all structural invariants and throw typed `RenderModelError`.

### 2.1 `SampledPathMesh`

Add to `RenderGraphCommands.swift`:

```swift
public struct SampledPathMesh: Hashable, Sendable {
    public let pathID: Int
    public let positions: [CanvasScalar]
    public let indices: [Int]
    public let closed: Bool

    public init(
        pathID: Int,
        positions: [CanvasScalar],
        indices: [Int],
        closed: Bool
    ) throws
}
```

Required validation:

- `pathID >= 0`;
- `positions.count >= 6`;
- `positions.count` is even;
- `indices` is nonempty;
- `indices.count` is divisible by 3;
- every index is in `0 ..< positions.count / 2`;
- every coordinate is a validated `CanvasScalar`;

`positions` are path-local `[x0, y0, x1, y1, ...]`.

### 2.2 `SampledTriangleMesh`

Add:

```swift
public struct SampledTriangleMesh: Hashable, Sendable {
    public let positions: [CanvasScalar]
    public let indices: [Int]

    public init(positions: [CanvasScalar], indices: [Int]) throws
}
```

It uses the same even-position and triangle-index validation as `SampledPathMesh`. It is used for generated stroke triangles.

### 2.3 Typed stroke enums

Add:

```swift
public enum RenderStrokeLineCap: Int, Hashable, Sendable {
    case butt = 1
    case round = 2
    case square = 3
}

public enum RenderStrokeLineJoin: Int, Hashable, Sendable {
    case miter = 1
    case round = 2
    case bevel = 3
}
```

Unknown raw values are rejected by the graph compiler. They are never carried as untyped `Int` values into Metal.

### 2.4 `SampledSRGBAColor`

Add:

```swift
public struct SampledSRGBAColor: Hashable, Sendable {
    public let red: NormalizedColorComponent
    public let green: NormalizedColorComponent
    public let blue: NormalizedColorComponent
    public let alpha: NormalizedColorComponent

    public init(components: [NormalizedColorComponent]) throws
}
```

This is authored straight-alpha sRGB RGBA, not premultiplied linear color. Construction from `RenderColor` requires exactly four components. Any other component count is rejected with `RenderModelError.unsupportedValue`.

At the Metal boundary:

1. decode red/green/blue from sRGB to linear with the Step-10 transfer function;
2. compute effective alpha from color alpha and all applicable opacities;
3. premultiply linear RGB by effective alpha;
4. source-over composite once.

### 2.5 `SampledStroke`

Replace the current stroke payload with:

```swift
public struct SampledStroke: Hashable, Sendable {
    public let sourcePathID: Int
    public let mesh: SampledTriangleMesh
    public let color: SampledSRGBAColor
    public let opacity: OpacityScalar
    public let width: CanvasScalar
    public let lineCap: RenderStrokeLineCap
    public let lineJoin: RenderStrokeLineJoin
    public let miterLimit: MiterScalar
}
```

`mesh` is already execution-ready. Metal must not construct stroke geometry.

### 2.6 `SampledShape`

Replace the current shape payload with:

```swift
public struct SampledShape: Hashable, Sendable {
    public let fillMesh: SampledPathMesh?
    public let fillColor: SampledSRGBAColor?
    public let fillOpacity: OpacityScalar
    public let stroke: SampledStroke?
    public let groupOpacity: OpacityScalar

    public init(
        fillMesh: SampledPathMesh?,
        fillColor: SampledSRGBAColor?,
        fillOpacity: OpacityScalar,
        stroke: SampledStroke?,
        groupOpacity: OpacityScalar
    ) throws
}
```

At least one of fill or stroke must exist.

`fillMesh` and `fillColor` must either both be present or both be absent.

Fill color/opacity are applied once after coverage generation. Group opacity is applied once to the whole shape contribution, not separately to overlapping triangles.

The effective style alpha is:

```text
color.alpha * styleOpacity * groupOpacity * drawShape.opacity
```

Each multiplication uses the existing fixed-point opacity contract before conversion to shader values.

### 2.7 `SampledMaskOperation`

Add:

```swift
public struct SampledMaskOperation: Hashable, Sendable {
    public let mode: RenderMaskMode
    public let inverted: Bool
    public let opacity: OpacityScalar
    public let mesh: SampledPathMesh
    public let pathToTarget: FixedAffineTransform2D
}
```

The operation array order is semantically significant and must remain the authored `RenderLayer.masks` order in canonical bytes and graph hashes.

### 2.8 Mask command payloads

Replace per-mask nesting with one explicit layer mask group:

```swift
case beginMask(
    operations: [SampledMaskOperation],
    contentSurfaceID: String,
    targetSurfaceID: String
)

case endMask(
    contentSurfaceID: String,
    targetSurfaceID: String
)
```

Rules:

- one `beginMask` / `endMask` pair per masked layer contribution;
- `operations` is nonempty;
- all operations belong to that layer and preserve authored order;
- `contentSurfaceID != targetSurfaceID`;
- inner layer content writes explicitly to `contentSurfaceID`;
- `endMask` reads the content surface, applies the aggregate mask once, and source-over composites into `targetSurfaceID`.

Nested mask groups are represented by separate explicit surface IDs, not inferred from command adjacency.

### 2.9 Matte payload

Replace the matte payload with:

```swift
case matteLink(
    mode: RenderMatteMode,
    sourceLayerID: Int,
    consumerLayerID: Int,
    sourceSurfaceID: String,
    consumerSurfaceID: String,
    targetSurfaceID: String
)
```

Rules:

- source, consumer, and target IDs are pairwise distinct;
- source and consumer surfaces are fully rendered before `matteLink`;
- `matteLink` reads source and consumer and source-over writes the masked consumer contribution to target;
- source and consumer are never rendered directly into target in addition to the link;
- nested matte chains remain inner-before-outer;
- existing typed matte-cycle rejection remains.

### 2.10 Canonical identity

Update canonical encoding for:

- `SampledPathMesh`;
- `SampledTriangleMesh`;
- `SampledSRGBAColor`;
- stroke enums and `SampledStroke`;
- revised `SampledShape`;
- `SampledMaskOperation`;
- revised begin/end mask payloads;
- revised matte payload.

Canonical arrays preserve semantic order. Dictionary-derived values are explicitly sorted by their stable IDs before encoding.

All affected golden bytes and hashes must be re-baked deliberately. No compatibility shim for old Step-9 graph hashes is required.

---

## 3. Exact Producer-Mesh Sampling

### 3.1 Resource retention

Replace the compiler frame's path-resource ID set with:

```swift
let pathResourcesByID: [Int: RenderPathResource]
```

Build it with a checked loop:

- duplicate `pathID` -> typed error;
- no `Dictionary(uniqueKeysWithValues:)` trap path;
- no missing-resource fallback.

### 3.2 Path-resource association

For each `RenderMask` and `RenderShapeGroup`:

1. Resolve `pathID` in `pathResourcesByID`.
2. Use the associated `RenderAnimatedPath.closed` value.
3. Verify `closed` is invariant across all animated path keyframes.
4. For fill and mask use, require `closed == true`.
5. Reject missing, contradictory, or malformed association through a typed `RenderGraphError`.

### 3.3 `PathResourceSampler`

Create package-internal:

```swift
enum PathResourceSampler {
    static func sample(
        resource: RenderPathResource,
        closed: Bool,
        at time: RationalSourceTime,
        field: String
    ) throws -> SampledPathMesh
}
```

Algorithm:

1. Validate strictly increasing keyframe times.
2. Validate every row has exactly `vertexCount * 2` coordinates.
3. Validate indices against `vertexCount`.
4. Before first keyframe: use first row.
5. At or after last keyframe: use last row.
6. Between keyframes:
   - compute exact normalized position with checked rational subtraction/division;
   - apply hold semantics when set;
   - otherwise apply the matching `RenderPathEasing` through existing fixed `CubicBezierSampler`;
   - linearly interpolate each coordinate with existing full-width checked fixed-point arithmetic.
7. Return the resource's authoritative indices unchanged.

No `Double`, `Float`, platform trig, or Bezier re-flattening is allowed.

### 3.4 Independent path-sampling tests

Tests must prove:

- endpoints are exact;
- midpoint interpolation is exact;
- hold uses the previous row until the boundary;
- easing changes the sampled row;
- `Int64.min` / `Int64.max` arithmetic fails typed rather than trapping;
- malformed row length fails;
- invalid index fails;
- missing resource fails;
- `SampledBezier` anchor count may differ from mesh vertex count without cross-indexing;
- mutation of one producer mesh coordinate changes graph canonical bytes and hash.

---

## 4. Deterministic Stroke-Mesh Construction

Stroke geometry is built in `AnimiEngineRenderGraph`, not in Metal. This keeps the graph execution-complete and keeps the executor independent from Task-002/Core geometry semantics.

### 4.1 Fixed vector math

Create package-scoped Core helpers in `FixedVectorMath.swift` for:

- checked squared magnitude;
- deterministic integer square root / rounded hypot;
- checked normalized perpendicular offset;
- checked cross/dot products;
- checked line intersection;
- checked fixed-point comparison needed by the miter limit.

Use full-width integer arithmetic. No `Double`, `Float`, Foundation trig, or platform-dependent approximation is allowed.

### 4.2 `StrokeMeshBuilder`

Create package-internal:

```swift
enum StrokeMeshBuilder {
    static func build(
        path: SampledPathMesh,
        width: CanvasScalar,
        lineCap: RenderStrokeLineCap,
        lineJoin: RenderStrokeLineJoin,
        miterLimit: MiterScalar
    ) throws -> SampledTriangleMesh
}
```

### 4.3 Input normalization

Before tessellation:

1. Parse position pairs.
2. Remove consecutive duplicate points deterministically.
3. If closed and final point equals first point, remove the repeated final point.
4. Open path requires at least two distinct points.
5. Closed path requires at least three distinct points.
6. Require `width.rawValue > 0`.
7. Require `width.rawValue <= 2048 * CanvasScalar.unitsPerPoint`.
8. Require positive miter limit for miter joins.
9. An exact 180-degree direction reversal is rejected with a typed unsupported-stroke-geometry error.

No degenerate segment is sent to Metal.

### 4.4 Width and transform semantics

Stroke mesh is constructed in path-local coordinates before `groupTransform`.

Therefore:

- width is authored path-local width;
- non-uniform group transforms naturally produce anisotropic destination strokes;
- no attempt is made to re-normalize width in destination space.

Half-width uses checked divide-by-two with nearest, ties away from zero.

### 4.5 Segment quads

For each normalized segment:

1. Compute deterministic length with `FixedVectorMath`.
2. Compute left/right half-width offsets with checked multiply/divide.
3. Emit the segment quad as two triangles.
4. Preserve path order for deterministic vertex/index emission.

### 4.6 Caps

Open paths use:

- `.butt`: no extension;
- `.square`: extend start/end by one half-width along the segment direction;
- `.round`: emit a semicircle fan.

Closed paths emit no caps.

### 4.7 Joins

At each interior or closed-path join:

- collinear same-direction segments emit no additional join;
- `.bevel`: emit the outer bevel triangle;
- `.miter`: intersect outer offset lines; use the miter only when the exact miter-length ratio is `<= miterLimit`, otherwise emit the bevel fallback;
- `.round`: emit an outer arc fan.

### 4.8 Round tessellation

Round caps and joins use one fixed angular step:

```text
1 degree = 1_000 RotationScalar raw units
```

Requirements:

- use `FixedTrig.cosSin`;
- deterministic clockwise/counter-clockwise sweep from cross-product sign;
- include the start point once;
- emit intermediate points at exact 1-degree raw increments;
- force the final point to the exact target offset to avoid accumulated endpoint drift;
- no adaptive subdivision and no unspecified tolerance.

### 4.9 Stroke tests

Tests must cover:

- cap raw values 1/2/3 and exact enum mapping;
- join raw values 1/2/3 and exact enum mapping;
- unknown raw values rejected;
- butt, round, square golden meshes;
- miter, round, bevel golden meshes;
- miter-limit bevel fallback;
- same-direction collinear join;
- duplicate-point removal;
- zero-length path rejection;
- exact 180-degree reversal rejection;
- open and closed paths;
- non-uniform transform applied after local mesh construction;
- deterministic repeated build and hash;
- boundary overflow in normals/intersections;
- all real authored strokes pass the builder.

---

## 5. Explicit Graph Compilation and Surface Flow

### 5.1 Isolation surfaces clone the real target

Add exactly this internal `CompileContext` operation:

```swift
declareIntermediateSurfaceLike(
    newID: String,
    targetSurfaceID: String
) throws
```

It looks up the actual target descriptor and creates the isolation surface with exactly the same:

- width;
- height;
- surface profile;
- storage format.

This rule applies to:

- mask content surfaces;
- matte source surfaces;
- matte consumer surfaces.

Do not allocate these surfaces from precomp dimensions. A nested precomp may be smaller or larger than its destination target while its world transform already maps into target coordinates.

### 5.2 Mask compilation

For a masked layer:

1. Determine its current explicit target surface.
2. Allocate a deterministic target-sized mask content surface.
3. Sample every mask mesh and transform in authored order.
4. Emit one `beginMask(operations, contentSurfaceID, targetSurfaceID)`.
5. Compile the complete layer contribution into `contentSurfaceID`:
   - image/media draw;
   - authored shape draw;
   - precomp descendants;
   - nested masks;
   - nested mattes.
6. Emit one matching `endMask(contentSurfaceID, targetSurfaceID)`.

Mask surface IDs include stable scene role, comp/layer identity, and deterministic scope ordinal. Do not use UUIDs or process-random hashes.

### 5.3 Mask transform

Each `SampledMaskOperation.pathToTarget` maps path-local mesh coordinates directly into the mask group's target surface coordinates.

It includes the same sampled layer transform and parent chain used by the layer contribution. It is not merely path-local-to-comp.

### 5.4 Matte compilation

For a matte consumer:

1. Resolve the source layer and reject cycles as already required.
2. Allocate target-sized `sourceSurfaceID`.
3. Allocate target-sized `consumerSurfaceID`.
4. Clear both.
5. Render the complete source subtree into `sourceSurfaceID`, including its own masks, shapes, precomps, parents, timing, and nested matte.
6. Render the complete consumer subtree into `consumerSurfaceID`, including its own masks, shapes, precomps, and nested scopes.
7. Emit `matteLink` only after both subtrees are complete.
8. Do not render either subtree directly to target.

### 5.5 Shape compilation

For each authored shape group:

1. Sample the producer path mesh through `PathResourceSampler`.
2. Sample fill/stroke colors, opacities, width, group transform, and group opacity at the existing exact animation time.
3. Fill uses the producer mesh unchanged.
4. Stroke uses `StrokeMeshBuilder`.
5. Compose `world.concatenating(sampledGroupTransform)` in checked fixed-point arithmetic.
6. Emit that single final path-local-to-target matrix as `drawShape.transform`.
7. Emit one execution-ready `drawShape`.

Metal never multiplies the layer-world and shape-group matrices together. It receives one already-composed fixed affine transform.

The compiler rejects:

- missing path resources;
- open fill/mask paths;
- malformed stroke geometry;
- unknown cap/join values;
- unsupported source fill-rule evidence found by the mandatory audit.

### 5.6 Fill-rule traceability audit

Before implementation proceeds past graph tests:

1. Scan every authored real-template shape fill.
2. Assert the exact baseline: 30 parsed JSON files, 25 `fill.r == 1`, zero `fill.r == 2` or unknown.
3. Assert the exact stroke-style baseline: 18 strokes, all cap `1`, all join `1`.
4. If any count or value differs, trigger the stop rule before changing production code.

Tests compare fill execution against the producer triangle mesh, not against an independently invented winding-rule oracle.

---

## 6. Validator Contract

`RenderGraphValidator` remains the structural authority before Metal preflight.

### 6.1 Mask-group validation

Validate:

- operation list nonempty;
- each operation has a closed, valid mesh;
- begin/end IDs match exactly;
- content and target surfaces declared before use;
- content surface cleared before inner writes;
- all commands inside the group write to the declared content surface or to explicit nested isolation surfaces;
- content surface written before `endMask`;
- content and target descriptors have equal width/height/profile/storage;
- scopes are balanced and properly nested;
- no resource or surface aliasing.

### 6.2 Matte validation

Validate:

- all three surfaces declared before use;
- source and consumer written before read;
- source and consumer are not clear-only;
- all three descriptors match in width/height/profile/storage;
- source, consumer, and target IDs do not alias;
- source/consumer layer IDs match the compiled link identity;
- no matte cycle;
- source and consumer are not also composited directly into target.

### 6.3 Shape validation

Validate:

- fill/stroke execution mesh validity;
- all transforms are valid fixed-point matrices;
- referenced target is the active explicit scene/isolation target;
- no empty shape payload;
- all opacity/color values satisfy existing contracts.

### 6.4 Error boundary

Use:

- `RenderModelError` for malformed public value construction;
- `RenderGraphError` for missing material/path data, unsupported authored geometry, invalid graph structure, and surface-flow violations;
- `MetalRenderError` for device capability, allocation, pipeline, encoder, command-buffer, and readback failures.

Add exactly these new cases:

```swift
// RenderGraphError
case missingPathResource(pathID: Int, field: String)
case pathResourceMismatch(pathID: Int, field: String, detail: String)
case unsupportedStrokeGeometry(field: String, detail: String)
case validatorSurfaceDescriptorMismatch(resourceID: String, targetSurfaceID: String)
case validatorSurfaceAlias(resourceID: String)

// MetalRenderError
case requiredSampleCountUnsupported(sampleCount: Int)
```

Use existing `RenderModelError.valueOutOfRange`, `.unsupportedValue`, `.duplicateIdentity`, and `.integerOverflow` for new public-value validation. Add no other error cases in Step 11.

---

## 7. Metal Pixel Contract

### 7.1 Preserved Step-10 invariants

Preserve:

- one command buffer per `execute`;
- one commit;
- one wait;
- private upload path on iPhone;
- normalization before scene rendering;
- linear-premultiplied composition;
- fixed-function premultiplied source-over;
- final linear-to-sRGB conversion;
- existing execution guard;
- no process-global Metal state;
- no CPU renderer.

### 7.2 Coverage format and MSAA

Use:

- 4x MSAA;
- `MTLPixelFormat.r16Float` for coverage and resolved coverage;
- replacement writes with blending disabled while rasterizing geometry;
- exact resolve fractions for 0/1/2/3/4 covered samples.

Before per-execution GPU allocation:

```swift
device.supportsTextureSampleCount(4)
```

must be true and all required pipelines must be creatable. Otherwise throw:

```swift
MetalRenderError.requiredSampleCountUnsupported(sampleCount: 4)
```

No fallback to 1x, hard edges, or another format is allowed.

### 7.3 Fill execution

For a fill:

1. Transform ready mesh vertices with the command's fixed affine transform.
2. Rasterize producer triangles into 4x `r16Float` coverage.
3. Resolve coverage.
4. Apply fill color, fill opacity, and group opacity once.
5. Emit linear-premultiplied source.
6. Composite once into the explicit target with Step-10 source-over.

Overlapping producer triangles must not multiply color/alpha. Coverage rasterization uses replacement semantics and color application occurs once after resolve.

### 7.4 Stroke execution

Stroke uses the ready `SampledTriangleMesh` from the graph.

Execution is identical to fill coverage/application, using stroke color and opacity. Metal performs no line joins, caps, path flattening, or tessellation.

### 7.5 Mask operation coverage

For each operation:

1. Rasterize its producer mesh through `pathToTarget` into resolved `r16Float` coverage.
2. Clamp coverage to `[0, 1]`.
3. Apply inversion first.
4. Apply mask opacity second.
5. Combine in authored order.

Exact accumulator contract, reproduced from the read-only legacy oracle:

| Mode | Initial accumulator when first | Combine |
|---|---:|---|
| add | `0` | `max(acc, coverage)` |
| subtract | `1` | `acc * (1 - coverage)` |
| intersect | `1` | `min(acc, coverage)` |

Do not use probabilistic union for add. Do not use multiplication for intersect.

Use two transient `r16Float` accumulator textures in ping-pong order. Every combine pass is explicit and deterministic.

After the final operation:

```text
masked.rgb = content.rgb * aggregateCoverage
masked.a   = content.a   * aggregateCoverage
```

Then source-over composite the masked content once into target.

### 7.6 Matte execution

`matteLink` reads fully rendered source and consumer surfaces.

Coverage:

- `.alpha`: `source.a`
- `.alphaInverted`: `1 - source.a`
- `.luma`: `0.2126 * source.r + 0.7152 * source.g + 0.0722 * source.b`
- `.lumaInverted`: `1 - luma`

Inputs are already linear-premultiplied. Do not unpremultiply before luma. A transparent bright source therefore contributes zero luma coverage.

Multiply consumer premultiplied RGB and alpha by matte coverage, then source-over composite once into target.

### 7.7 Transient ownership

The executor owns and releases after command completion:

- MSAA coverage textures;
- resolved coverage textures;
- mask accumulator ping-pong textures.

Graph-declared mask content and matte source/consumer surfaces remain normal graph resources owned by the per-execution resource owner.

Success and failure tests must prove release of engine-owned references through the existing observer seam.

### 7.8 Deferred commands

After Step 11:

- `drawShape`, `beginMask`, `endMask`, and `matteLink` are supported;
- `fadeTransition`, `slideTransition`, and `overlay` remain rejected with exact Step-12 `unsupportedCommand` categories.

---

## 8. Shader and Pipeline Layout

Extend `Shaders/AnimiEngineRender.metal` with narrowly scoped entry points:

- coverage vertex function for fixed-point-prepared triangle vertices;
- coverage fragment writing one-channel coverage;
- fill/stroke coverage-application fragment;
- mask combine fragment;
- mask content application fragment;
- matte application fragment.

Requirements:

- no runtime branching on unsupported command categories;
- no sRGB decode/encode inside coverage or matte math;
- no read/write alias of the same texture in one pass;
- no undefined overlapping render-target sampling;
- explicit viewport/scissor matching destination surfaces;
- empty clips/scopes skip draws without zero-sized scissor rectangles;
- shader structs have Swift-side layout tests.

Add all Step-11 shader functions and pipelines to `MetalPipelineLibrary`. At `MetalRenderSession` construction:

1. require `device.supportsTextureSampleCount(4)`;
2. load every Step-11 shader function;
3. create the 4x `r16Float` coverage pipeline;
4. create resolve/combine/apply pipelines for both supported intermediate target formats, `.rgba16Float` and `.bgra8Unorm_srgb`.

Any failure aborts session construction through the exact typed Metal error. No Step-11 pipeline is created lazily during `execute`.

---

## 9. Exact Implementation Envelope

Owner authorization of this document authorizes only the files below.

### 9.1 New production files

1. `AnimiEngineNext/Sources/AnimiEngineCore/Geometry/FixedVectorMath.swift`
2. `AnimiEngineNext/Sources/AnimiEngineRenderGraph/PathResourceSampler.swift`
3. `AnimiEngineNext/Sources/AnimiEngineRenderGraph/StrokeMeshBuilder.swift`
4. `AnimiEngineNext/Sources/AnimiEngineMetalRender/MetalShapeCompositor.swift`
5. `AnimiEngineNext/Sources/AnimiEngineMetalRender/MetalMaskMatteCompositor.swift`

### 9.2 Modified production files

Core:

- no existing Core production file is modified; `FixedVectorMath.swift` calls the existing checked primitives.

RenderModel:

- `AnimiEngineNext/Sources/AnimiEngineRenderModel/RenderGraphCommands.swift`

RenderGraph:

- `AnimiEngineNext/Sources/AnimiEngineRenderGraph/AnimationSampler.swift`
- `AnimiEngineNext/Sources/AnimiEngineRenderGraph/CompileContext.swift`
- `AnimiEngineNext/Sources/AnimiEngineRenderGraph/MaskMatteGraphBuilder.swift`
- `AnimiEngineNext/Sources/AnimiEngineRenderGraph/RenderGraphCompiler.swift`
- `AnimiEngineNext/Sources/AnimiEngineRenderGraph/RenderGraphValidator.swift`
- `AnimiEngineNext/Sources/AnimiEngineRenderGraph/RenderGraphError.swift`

Metal:

- `AnimiEngineNext/Sources/AnimiEngineMetalRender/MetalGraphExecutor.swift`
- `AnimiEngineNext/Sources/AnimiEngineMetalRender/MetalPipelineLibrary.swift`
- `AnimiEngineNext/Sources/AnimiEngineMetalRender/MetalTextureAllocator.swift`
- `AnimiEngineNext/Sources/AnimiEngineMetalRender/MetalResourceOwner.swift`
- `AnimiEngineNext/Sources/AnimiEngineMetalRender/MetalSceneCompositor.swift`
- `AnimiEngineNext/Sources/AnimiEngineMetalRender/MetalRenderError.swift`
- `AnimiEngineNext/Sources/AnimiEngineMetalRender/Shaders/AnimiEngineRender.metal`

### 9.3 New test files

1. `AnimiEngineNext/Tests/AnimiEngineCoreTests/FixedVectorMathTests.swift`
2. `AnimiEngineNext/Tests/AnimiEngineRenderGraphTests/PathResourceSamplerTests.swift`
3. `AnimiEngineNext/Tests/AnimiEngineRenderGraphTests/StrokeMeshBuilderTests.swift`
4. `AnimiEngineNext/Tests/AnimiEngineMetalRenderTests/MaskMatteShapeTests.swift`

### 9.4 Existing test files permitted for modification

- `AnimiEngineNext/Tests/AnimiEngineRenderGraphTests/GraphTestFixtures.swift`
- `AnimiEngineNext/Tests/AnimiEngineRenderGraphTests/GraphTestPayloads.swift`
- `AnimiEngineNext/Tests/AnimiEngineRenderGraphTests/RenderGraphValidationTests.swift`
- `AnimiEngineNext/Tests/AnimiEngineRenderGraphTests/RenderGraphCompilerCorrectiveTests.swift`
- `AnimiEngineNext/Tests/AnimiEngineRenderGraphTests/RealTemplateGraphTests.swift`
- `AnimiEngineNext/Tests/AnimiEngineRenderGraphTests/Step9FinalCorrectiveTests.swift`
- `AnimiEngineNext/Tests/AnimiEngineMetalRenderTests/MetalTestEnvironment.swift`
- `AnimiEngineNext/Tests/AnimiEngineMetalRenderTests/ColorAlphaContractTests.swift`
- `AnimiEngineNext/Tests/AnimiEngineMetalRenderTests/IntermediateProfileTests.swift`
- `AnimiEngineNext/Tests/AnimiEngineMetalRenderTests/MetalResourceOwnershipTests.swift`
- `AnimiEngineNext/DeviceGateHost/AnimiEngineDeviceGateHost/AnimiEngineDeviceGateHostTests/IPhoneDeviceGateTests.swift`

### 9.5 Documentation

- modify `Docs/AnimiEngineNext/decision-register.md`;
- do not rewrite the approved Task-003 master plan;
- do not modify this Step-11 plan during implementation.

---

## 10. Mandatory Regression Matrix

### 10.1 Model and canonical identity

1. Valid/invalid `SampledPathMesh`.
2. Valid/invalid `SampledTriangleMesh`.
3. Exact cap/join raw mapping.
4. Mask-operation authored order changes hash.
5. Mesh coordinate mutation changes hash.
6. Revised mask/matte payload golden bytes.
7. Revised full graph golden bytes and SHA-256.
8. Insertion/order determinism where order is not semantic.

### 10.2 Path sampling

9. Exact first/last keyframes.
10. Exact midpoint.
11. Hold.
12. Easing.
13. Row/index malformed cases.
14. `SampledBezier` vs flattened vertex-count mismatch regression.
15. Boundary overflow.
16. All real selected variants resolve every path resource.

### 10.3 Stroke construction

17. Butt/round/square cap goldens.
18. Miter/round/bevel join goldens.
19. Miter fallback.
20. Duplicate points.
21. Open/closed paths.
22. Zero-length and reversal typed rejection.
23. Non-uniform transform semantics.
24. Deterministic repeated mesh.
25. Every real authored stroke.

### 10.4 Graph and validator

26. One explicit mask group with multiple authored operations.
27. `add -> subtract` differs from `subtract -> add`.
28. Nested masked precomp produces unambiguous nested surfaces.
29. Mask content with multiple draws is masked once as a group.
30. Mask transform includes translation and rotation.
31. Matte source with own mask and shape.
32. Precomp matte consumer rendered completely before link.
33. Nested matte chain inner-before-outer.
34. Matte cycle typed rejection.
35. Isolation surfaces clone actual target dimensions when nested comp dimensions differ.
36. Read-before-write, clear-only, alias, descriptor mismatch, unbalanced group rejections.
37. All five real templates compile and validate with exact shape/mask/matte counts.

### 10.5 Metal pixels

38. Opaque fill interior exact.
39. Partial-alpha fill bounded against linear CPU oracle.
40. Stroke cap/join interiors exact; AA edges bounded.
41. 4x coverage has expected 0/0.25/0.5/0.75/1 values on controlled geometry.
42. Multi-triangle overlap applies color/opacity once.
43. Add first accumulator.
44. Subtract first accumulator.
45. Intersect first accumulator.
46. Ordered multi-mask algebra.
47. Invert then opacity.
48. Nested masks.
49. Alpha and alpha-inverted mattes.
50. Luma and luma-inverted mattes using Rec.709 linear coefficients.
51. Transparent bright luma source produces zero coverage.
52. Matte source and consumer are each rendered once.
53. Combined shape + mask + matte frame.
54. Same-device bytes/hash repeatability.
55. Engine-owned transient release after success and injected failure.
56. Exact rejection of remaining Step-12 categories.

### 10.6 Oracle rules

Exact byte equality is allowed only for analytically exact interiors/endpoints and same-device repeatability.

AA edges and half-float intermediate calculations use pinned bounded tolerances. Every bounded GPU test must also prove that its named known-incorrect oracle lies outside the bound.

Do not bless output by copying GPU results into the CPU oracle.

---

## 11. Implementation Sequence and Checkpoints

### Checkpoint 1 - Schema and canonical identity

Implement section 2 and update graph fixtures/goldens.

Run:

```bash
swift build
swift test --filter "RenderGraphValidationTests|Task003ErrorModelTests"
```

Do not proceed until public-schema invariants and canonical bytes are green.

### Checkpoint 2 - Exact path sampling

Implement `PathResourceSampler`, resource retention, and focused tests.

Run:

```bash
swift test --filter "PathResourceSamplerTests"
```

### Checkpoint 3 - Stroke mesh builder

Implement fixed vector math and `StrokeMeshBuilder`.

Run:

```bash
swift test --filter "FixedVectorMathTests|StrokeMeshBuilderTests"
```

### Checkpoint 4 - Compiler and validator

Implement explicit mask groups, matte consumer isolation, target-cloned surfaces, shape compilation, and validator changes.

Run:

```bash
swift test --filter "AnimiEngineRenderGraphTests"
```

The real-template fill-rule audit and exact stroke audit must pass here.

### Checkpoint 5 - Metal shape execution

Implement coverage allocation, shape pipelines, fills, and strokes.

Run:

```bash
swift test --filter "MaskMatteShapeTests"
```

### Checkpoint 6 - Metal masks and mattes

Implement mask accumulators, content application, and matte application.

Run:

```bash
swift test --filter "AnimiEngineMetalRenderTests"
```

### Checkpoint 7 - Full package regression

Run:

```bash
swift build
swift test
```

Expected result: zero failures; only previously documented environment-dependent skips are allowed. No new Metal-device skip is allowed on the M2 Pro.

### Checkpoint 8 - Physical-device gate

Update the existing host test only. Execute on the connected physical:

- iPhone 13 Pro;
- hardware identifier `iPhone14,2`;
- Apple A15 GPU.

The gate must:

1. rerun all existing Step-10 device tests;
2. render a deterministic combined shape + ordered masks + matte frame;
3. prove the private staging upload path remains active;
4. record execution-event ordering;
5. prove repeated bytes and `rawOutputHash` equality;
6. record 4x sample-count support;
7. attach device model, hardware identifier, GPU, iOS build, output hash, and command order.

No simulator result substitutes for this gate.

---

## 12. Acceptance Gates

Step 11 is complete only when all gates pass.

### AG1 - Architecture

- RenderGraph remains execution-complete.
- Metal consumes ready meshes and explicit surfaces.
- No legacy-engine dependency or CPU renderer exists.
- `MetalRenderSession.execute(RenderGraph) -> RenderedFrame` public surface is unchanged.

### AG2 - Geometry

- Producer flattened meshes are sampled independently from control Beziers.
- No re-flattening occurs.
- Stroke construction is fixed-point deterministic.
- No untyped cap/join values reach Metal.

### AG3 - Surface flow

- Mask content and matte source/consumer surfaces are explicit.
- Every isolation surface clones the actual target descriptor.
- Validator proves declare/write/read order and rejects aliasing.

### AG4 - Pixel semantics

- Fill/stroke coverage uses 4x `r16Float` MSAA.
- Colors and opacity apply once.
- Mask algebra matches the pinned oracle exactly.
- Matte alpha/luma is applied in linear-premultiplied space.

### AG5 - Determinism and identity

- Canonical bytes and hashes are pinned.
- Same input produces byte-identical graph and same-device frame output.
- Semantic mutation changes the appropriate hash/output.

### AG6 - Errors and lifecycle

- All malformed/unsupported paths fail typed.
- No forbidden trap/fallback constructs exist in changed production code.
- Transient GPU resources are released after success and failure.

### AG7 - Regression

- Full macOS build/test is green.
- Existing Task-001, Task-002, and prior Task-003 tests remain green.
- No new unrelated skip appears.

### AG8 - Real device

- Combined Step-11 device test passes on physical iPhone 13 Pro.
- Existing Step-10 4/4 device gate remains green.
- Evidence attachments contain both runs and exact device identity.

### AG9 - Repository envelope

- Final forbidden-path snapshot equals initial snapshot byte-for-byte.
- No Package or project-file change.
- Exact changed-file list is within section 9.

---

## 13. Required Final Report

After implementation, stop before Step 12 and report:

1. exact created/modified/deleted files;
2. mapping from every acceptance gate to named tests;
3. `swift build` result;
4. full `swift test` executed/skipped/failure counts;
5. Metal-suite counts on M2 Pro;
6. iPhone 13 Pro executed/failure/skip counts;
7. iPhone model identifier, GPU, iOS version/build;
8. device output hashes and execution-event order for both runs;
9. canonical/golden hashes changed and why;
10. fill-rule audit counts;
11. authored stroke audit counts and whether any stop condition occurred;
12. production forbidden-token audit;
13. initial/final forbidden-path comparison;
14. explicit confirmation that Step 12 was not started.

Do not describe Step 11 as complete if the physical iPhone gate has not passed.

---

## 14. Final Authorization Statement

This Revision 4 document closes all Step-11 design decisions.

The implementation must follow this document exactly. Any newly discovered contradiction must trigger the stop rule rather than a local architectural invention.

Proceed through the checkpoints in order. Stop after the Step-11 report. Do not begin Step 12.
