# Task 002 — Corrective Plan (Revision 3, FINAL CANDIDATE)

**Status:** FINAL CANDIDATE — NOT YET APPROVED FOR IMPLEMENTATION. Planning only.
**Gate:** No code may be written until the technical lead explicitly approves this corrective plan.
**Scope:** `AnimiEngineNext/Sources/AnimiEngineCore/`, `AnimiEngineNext/Sources/AnimiEngineTestSupport/`,
`AnimiEngineNext/Tests/AnimiEngineCoreTests/`, and Task-002 documentation under
`Docs/AnimiEngineNext/` only.
**Forbidden paths (unchanged from the approved plan):** no files under `TVECore/`, `AnimiApp/`,
`SceneSources/`, `*.xcodeproj`, or `*.pbxproj` may be modified. No product code is touched. Task 003
is not started.

This document is a remediation plan for the eight rejection items raised against the Revision-5
implementation. It does not replace the Revision-5 plan; it amends specific decisions and tightens
contracts. Each item gives: root cause, exact files/APIs changed, algorithm and invariants, and the
regression-test additions. A consolidated regression matrix and a final confirmation section follow.

## Revision 2 — closed decisions from technical-lead review

These six decisions are now **closed** and are reflected in the sections below:

1. **C-8: Option B is APPROVED.** Keep collect-then-sort; document honest `O(log n + k log k)` in code,
   ADR-002, the decision register, and tests. The speculative Option A ordered-emission structure is
   **not** implemented.
2. **C-3: no general `UInt128 ÷ UInt128` division or `UInt128` GCD.** Use a proven reduced-rational
   algorithm (reduce-first, full-width signed numerator, narrow at the end), composed by
   `SourceTimeMapping`. Signed-narrowing rules and `Int64.min/1` are fixed below.
3. **C-4: public construction is removed for the entire window/requirement value family**
   (`EvaluationWindow`, `WindowScene`, `WindowTransition`, `WindowOverlay`,
   `EvaluationWindowRequirement`, `RequiredSceneSpan`, `RequiredBoundary`, `RequiredOverlayEntry`). Only
   `TimelineIndex` and `EvaluationWindowBuilder` may create them; external callers read only.
4. **Two-site material validation.** `MaterialAvailabilityValidator` runs in `ProjectValidator`
   (full-document path) **and** in `EvaluationWindowBuilder` (lazy-payload path), because the builder
   receives payloads after the manifest index was created and a caller could supply different payload
   content under matching IDs. `TimelineEvaluator` contains **no** material validation.
5. **C-2 instrumentation is pure.** No mutable static state and no `#if DEBUG` behavioral divergence.
   The search returns a pure diagnostic counter alongside its result; public methods discard it; tests
   inspect it. Production and test code paths are identical and concurrency-safe.
6. **C-7 per-block variant selection.** Template instantiation takes an explicit `[blockID: variantID]`
   selection covering every block. The authoring `loop` field is given an exact mapping (not parsed and
   ignored) and contradictory/unsupported policy combinations are rejected.

## Revision 3 — closed decisions from technical-lead review

These three additional decisions are now **closed** and are reflected in the sections below:

7. **Material validation includes global overlays.** Both validation sites must validate overlay
   animation over the **overlay-local** interval: `.holdLast`/`.loop` are valid continuations,
   `.becomeInactive` is rejected when the overlay stays active beyond `authoredDuration`. The lazy
   `validateWindowPayloads` additionally receives and validates `WindowOverlay` values, so matching-ID
   overlays with altered/insufficient animation material are rejected before an `EvaluationWindow` is
   returned.
8. **Honest non-forgeability guarantee.** Swift `internal` initializers stop construction only by
   **external, non-`@testable`** consumers; `@testable` test imports and other code **inside**
   `AnimiEngineCore` can still construct them (the module implementation is trusted). The plan states
   this honestly, **drops** the false "test module must fail to compile" claim, and verifies the public
   API surface via **symbol-graph / API-surface inspection** instead. `SearchDiagnostics` is **internal**,
   not public.
9. **Strict JSON typing rejects Foundation bridging ambiguities.** Template parsing must reject
   `Bool`-as-`NSNumber` (and the reverse) and any silent numeric coercion. Exact `CFTypeID` / object-type
   checks are specified for integers, booleans, and numbers; no `as? NSNumber` shortcut that conflates
   `true`/`1`.

---

## C-1. Move complete material/animation availability into validation

### Root cause

The approved plan (§8) phrased availability as belonging to the *evaluation window* and the
implementation placed it in two evaluation-time locations:

- `TimelineEvaluator.activeContent(for:at:role:)` re-derives a per-instant video target and throws
  `insufficientVideoMaterial` on every frame
  (`Sources/AnimiEngineCore/Evaluator/TimelineEvaluator.swift:185`).
- `TimelineEvaluator.buildTransition(...)` calls
  `EvaluationMaterialChecker.checkTransition(...)` for the **whole** transition interval on **every
  evaluated frame** inside the window (`.../TimelineEvaluator.swift:90`).

Consequences:

1. An invalid project is only rejected when a frame inside the offending region is evaluated — after
   `decodeValidated`, after `TimelineIndex`, after window construction, and into playback. A project
   that is never scrubbed to that region is silently accepted.
2. The whole-transition interval check repeats on every frame of the window (O(frames × layers)
   redundant work).
3. Normal single-scene playback material is never validated ahead of time at all — only incidentally,
   per-instant, at the moment a frame happens to be evaluated.

The plan's own §15.3 error list already enumerates `insufficient video source material`,
`unavailable animation continuation`, and `insufficient outgoing post-roll` as **validation** errors,
so the correct home is `ProjectValidator`, not the evaluator.

### Design decision

Availability is a **static property of the project**, fully determined by scene durations, transition
durations, layer active ranges, trim ranges, authored animation durations, **and global-overlay time
ranges plus their authored animation durations**. None of it depends on the requested time `T`.
Therefore all of it moves to validation and runs **before** any window is published or any frame is
evaluated.

The evaluator becomes a pure projection of an already-valid window: it computes targets and requests but
performs **no** availability rejection. A validated project (or validated window) guarantees every
target it will ever emit is in-trim and every animation continuation is covered.

**Two-site validation (see C-4 for the threat model).** Because the lazy path builds a `TimelineIndex`
from the manifest and only *later* receives loaded payloads, material validation must run at **both**
sites that first see authoritative payload content:

1. `ProjectValidator.validate(_ document:)` — the **full-document path**: validates material against the
   document's own payloads, before the normal index path. Invalid material is rejected before a
   `TimelineIndex` is created.
2. `EvaluationWindowBuilder.build(...)` — the **lazy-payload path**: validates the **exact loaded
   payloads** against the authoritative `EvaluationWindowRequirement`, before an `EvaluationWindow` is
   returned. A manifest index may already exist, but no window is published until the supplied payloads
   pass material validation.

`TimelineEvaluator` performs **no** material validation in either path. Playback therefore never
discovers a material error.

### Exact files and APIs changed

- **New:** `Sources/AnimiEngineCore/Project/MaterialAvailabilityValidator.swift`
  - `enum MaterialAvailabilityValidator`, pure and validation-error-only, with two entry points sharing
    common core routines:
    - `static func validateDocument(_ document: CanonicalProjectDocument, sceneSpanIndex: SceneSpanIndex) throws`
      — checks every scene's layers **and every global overlay's animation** against the document's own
      payloads.
    - `static func validateWindowPayloads(requirement: EvaluationWindowRequirement, scenes: [WindowScene], transitions: [WindowTransition], overlays: [WindowOverlay]) throws`
      — checks the loaded `WindowScene` payloads over the evaluated scene-intervals implied by the
      requirement's scene spans and animated boundaries, **and the loaded `WindowOverlay` payloads over
      each overlay's complete overlay-local interval**.
  - Two shared core routines so both sites run **identical** logic (no drift):
    - `checkSceneLayers(layers:evaluatedInterval:role:) throws` — scene-layer video/animation material;
    - `checkOverlayAnimation(overlayID:animation:overlayLocalInterval:) throws` — global-overlay animation
      continuation (detailed in the algorithm section).
- **Move:** the body of `Sources/AnimiEngineCore/Evaluator/EvaluationMaterialChecker.swift` into the new
  validator, generalized to cover **both** normal playback and transition continuation. After the move,
  `EvaluationMaterialChecker.swift` is **deleted**.
- **Edit:** `Sources/AnimiEngineCore/Project/ProjectValidator.swift`
  - `validate(_:)` calls `MaterialAvailabilityValidator.validateDocument(...)` as a new final step
    (step 10), after payload correspondence (so payloads are known-consistent first).
- **Edit:** `Sources/AnimiEngineCore/Timeline/EvaluationWindowBuilder.swift`
  - after the structural correspondence checks and before returning the `EvaluationWindow`, call
    `MaterialAvailabilityValidator.validateWindowPayloads(...)` on the resolved `WindowScene`,
    `WindowTransition`, **and `WindowOverlay`** sets (full detail in C-4). The `WindowOverlay` values must
    be passed so loaded overlay animation material is validated, not just scene material.
- **Edit:** `Sources/AnimiEngineCore/Evaluator/TimelineEvaluator.swift`
  - Remove the `EvaluationMaterialChecker.checkTransition(...)` call in `buildTransition`.
  - In `activeContent(for:at:role:)`, **remove** the `guard ... trimRange.contains(target)` rejection.
    The evaluator now constructs the `SourceRequest` unconditionally (the window is pre-validated). The
    function no longer throws for material reasons; `role`/`roleName` plumbing used only for that error
    is removed.
- **Edit:** `Sources/AnimiEngineCore/Codec/CanonicalProjectEncoding.swift` — no change here for C-1
  (covered by C-5); but note `decodeValidated` already calls `ProjectValidator.validate`, so the added
  material step makes invalid projects fail during `decodeValidated`, as required.

### Algorithm and invariants

For each scene `i` with manifest start `S_i` (from prefix sums) and nominal duration `d_i`:

1. **Normal-playback evaluated interval** for the scene body is `[0, d_i)` in scene-local ticks. (At a
   cut or normal playback the engine only ever requests scene-local ticks in `[0, d_i)`.)
2. **Outgoing transition continuation** (only if boundary `i` is animated with halves `pre`,`post`):
   the outgoing scene additionally spans `[d_i − pre, d_i + post)`. Union with step 1 gives
   `[0, d_i + post)`.
3. **Incoming transition continuation** (only if boundary `i−1` is animated with `post'`): the incoming
   scene additionally spans `[0, post')`, already a subset of `[0, d_i)` because validation already
   guarantees `d_i ≥ post'` (§8.6). No widening needed; the normal interval already covers it.

So each scene's **full evaluated scene-time interval** is
`E_i = [0, d_i + post_i)` where `post_i` is the post-half of the **outgoing** animated boundary at the
end of scene `i` (0 if that boundary is a cut or absent).

For each layer in scene `i`:

- Intersect `E_i` with the layer's `activeRange` → `[lo, hi)`. If empty, the layer imposes no
  requirement (this is exactly "no post-roll requirement on a layer not active in post-roll", §8.1).
- **Video:** map `firstTick = lo` and `lastTick = hi − 1` with the layer's `SourceTimeMapping`
  (positive rate ⇒ these are min/max targets). Require both targets satisfy
  `trimRange.start ≤ target < trimRange.end`, else `insufficientVideoMaterial(role:, layer:)`. The
  `role` is `"sole"` for the body interval and `"outgoing"` when the failing tick lies in the
  post-roll tail `[d_i, d_i + post_i)`; this keeps the existing error vocabulary meaningful.
- **Image:** no temporal requirement (§8.4).
- **`.becomeInactive` animation:** if `lastTick ≥ authoredDuration`, the layer would outlive its
  animation material → `unavailableAnimationContinuation(layer:)` (§8.5).

**Global overlays (new in Revision 3).** Each global overlay is active over its project-time range
`[overlayStart, overlayEnd)`; its **overlay-local** evaluated interval is `[0, overlayEnd − overlayStart)`
in overlay-local ticks (this is the complete interval over which the evaluator emits an
`AnimationRequest` for the overlay). For an overlay carrying an `AnimationReference`:

- compute `overlayDuration = overlayEnd − overlayStart`; the requested overlay-local ticks are
  `[0, overlayDuration)`, with last requested tick `overlayDuration − 1`;
- `.holdLast` and `.loop` are **valid continuations** past `authoredDuration` — they impose no
  requirement and pass;
- `.becomeInactive` is **rejected** when the overlay remains active beyond its animation material, i.e.
  when `overlayDuration − 1 ≥ authoredDuration` ⇔ `overlayDuration > authoredDuration` →
  `unavailableAnimationContinuation(layer: overlayID.raw)` (reusing the existing typed error; the
  `layer` field carries the overlay id). Overlays with no `AnimationReference` impose no requirement.

Text/sticker/graphic overlays carry **no temporal source material** (no `SourceTimeMapping`), so only
animation continuation is checked — there is no overlay "video target" to bound.

**Invariant established by validation (consumed by the evaluator):** for every project time `T` the
evaluator will ever be asked to evaluate inside `[0, projectDuration)`, every emitted `SourceRequest`
target is in-trim and every emitted `AnimationRequest` (scene-layer **and overlay**) is honestly
coverable. The evaluator may therefore treat material as guaranteed and never re-check it.

**Determinism:** validation iterates scenes in index order, layers in stored order, and overlays in
manifest order; no time input, no allocation-order dependence.

### Regression tests (new / changed)

- `ProjectValidationTests` (full-document path):
  - `testInsufficientNormalPlaybackVideoMaterialRejectedAtValidation` — a single-scene project whose
    only video layer has a trim shorter than its active range fails `ProjectValidator.validate` **and**
    `CanonicalProjectEncoding.decodeValidated`, with no `TimelineIndex` built.
  - `testInsufficientOutgoingTransitionMaterialRejectedAtValidation` — the existing transition-material
    case now fails at `validate`, not at `evaluate`.
  - `testBecomeInactiveOutlivingAnimationRejectedAtValidation` — moved from the availability/eval test.
  - `testValidProjectPassesAndEvaluatorNeverThrowsMaterialError` — a valid project: evaluating **every**
    frame across the whole timeline yields no material error from the evaluator.
  - `testOverlayBecomeInactiveOutlivingAnimationRejectedAtValidation` — a global overlay active over an
    interval longer than its `.becomeInactive` `authoredDuration` fails `validate`/`decodeValidated`.
  - `testOverlayHoldLastAndLoopAreValidContinuations` — overlays active beyond `authoredDuration` with
    `.holdLast` and with `.loop` both **pass** full-document validation.
  - `testValidOverlayAnimationPasses` — an overlay whose `authoredDuration ≥ overlayDuration` (animation
    covers its whole active interval) passes regardless of policy.
- `EvaluationWindowBuilderTests` (lazy-payload path — see C-4):
  - `testBuilderRejectsLoadedPayloadWithMatchingIDButInsufficientMaterial` — build a `TimelineIndex` from
    a manifest whose declared trim is sufficient, then call the builder with a payload that has the
    **same payload id** but a trim too short to cover its active range. The builder rejects it
    (`insufficientVideoMaterial`) and returns **no** `EvaluationWindow`.
  - `testBuilderRejectsLoadedOverlayWithMatchingIDButInsufficientAnimation` — the manifest's declared
    overlay animation is sufficient, but the **loaded** overlay payload (same overlay/payload id) carries
    a `.becomeInactive` animation whose `authoredDuration` no longer covers the overlay's active
    interval. `validateWindowPayloads` rejects it (`unavailableAnimationContinuation`) and returns **no**
    `EvaluationWindow`.
  - `testBuilderAcceptsValidLoadedPayloadsIncludingOverlays` — matching-id scene **and overlay** payloads
    with sufficient material build a window; subsequent evaluation across the window never throws a
    material error.
- `TransitionAvailabilityTests`: re-point the three existing "evaluator throws" assertions to
  "validator/builder throws"; assert the evaluator path no longer throws for a validated window.
- **Negative guard:** `testEvaluatorEmitsRequestsWithoutMaterialRecheckOnHotPath` — evaluate the same
  in-window frame twice and assert value-equality; the `EvaluationMaterialChecker` symbol no longer
  exists (compile-time: the type is deleted), so the evaluator cannot re-check.
- **Path-documentation assertions** (one test per documented guarantee):
  - `testFullDocumentPathRejectsBeforeIndexCreation` — invalid material ⇒ `decodeValidated`/`validate`
    throws and no `TimelineIndex` is constructed in the test flow.
  - `testLazyPathRejectsBeforeWindowReturned` — a manifest index is created, but the builder throws
    before any `EvaluationWindow` is returned for bad loaded payloads.
  - `testPlaybackNeverDiscoversMaterialError` — for every valid window, evaluating all frames yields no
    material error.

---

## C-2. Immutable `TransitionWindowIndex` with binary-search active lookup

### Root cause

Active-transition lookup and requirement gathering both **scan all transitions**:

- `TimelineIndex.activeBoundary(at:)` iterates every transition
  (`Sources/AnimiEngineCore/Timeline/TimelineIndex.swift:127`).
- `TimelineIndex.requirements(for:)` iterates every transition
  (`.../TimelineIndex.swift:167`) and additionally scans **all** scenes to find spanned scenes
  (`.../TimelineIndex.swift:200`).

These are `O(n)` per lookup and per requirement, contradicting the plan's `O(log n)` scene-lookup
intent (§10.1) and making large-N behavior linear.

### Design decision

Animated transition windows are **disjoint** and ordered along the timeline. Adjacency validation
(§7.5) already guarantees `postHalf(prev) + preHalf(next) ≤ d_middle`, so for any middle scene the
previous boundary's post-window and the next boundary's pre-window do not overlap. Therefore animated
windows are sortable by start with no overlap, and a point/range query is a binary search.

Add an immutable `TransitionWindowIndex` holding the animated windows (and their boundary metadata)
sorted by `window.start`, with:

- point lookup `activeBoundary(at: tick) -> ActiveBoundaryReference?` via binary search on starts +
  a single containment check (disjointness ⇒ at most one match);
- range lookup `boundaries(intersecting: coverage) -> [RequiredBoundary]` via binary search for the
  first window with `end > coverage.start`, iterating only the intersecting run.

Both query cores additionally return a pure `SearchDiagnostics` counter (see "Exact files and APIs");
the public methods discard it.

Cut boundaries are excluded from this index entirely (they never produce an active window).

### Exact files and APIs changed

- **New:** `Sources/AnimiEngineCore/Timeline/TransitionWindowIndex.swift`
  - `public struct TransitionWindowIndex: Equatable, Sendable`
  - Stored: `windows: [AnimatedWindow]` (sorted by start), where `AnimatedWindow` carries
    `boundaryIndex, boundary, transition, window, outgoingSceneID, incomingSceneID`.
  - `init(boundaries:scenes:boundaryPositions:) throws` — builds only animated entries; asserts
    disjointness as a defensive invariant (overlap ⇒ typed error, though validation should already
    preclude it).
  - **Pure diagnostic counter (replaces any mutable static / `#if DEBUG`).** An **internal** (not
    `public`) `struct SearchDiagnostics: Equatable, Sendable { let comparisons: Int; let visited: Int }`
    is returned **by value** from the search core. The single implementation is, also **internal**:
    - `func activeBoundaryWithDiagnostics(at: ProjectTime) -> (result: ActiveBoundaryReference?, diagnostics: SearchDiagnostics)`
    - `func boundariesWithDiagnostics(intersecting: ProjectTimeRange) -> (result: [RequiredBoundary], diagnostics: SearchDiagnostics)`
  - **Public** convenience methods discard the diagnostics:
    - `public func activeBoundary(at: ProjectTime) -> ActiveBoundaryReference? { activeBoundaryWithDiagnostics(at:).result }`
    - `public func boundaries(intersecting: ProjectTimeRange) -> [RequiredBoundary] { boundariesWithDiagnostics(intersecting:).result }`
  - The counter is accumulated in **local variables** inside the search and folded into the returned
    `SearchDiagnostics`. There is no shared mutable state, so production and tests execute the exact same
    code and the search is trivially concurrency-safe (no aliasing, value semantics throughout). Both
    `SearchDiagnostics` and the `...WithDiagnostics` methods are package-internal so `@testable` tests can
    inspect them while the **public** surface exposes only the result-returning methods. The
    symbol-graph check in C-4 asserts `SearchDiagnostics` is absent from the public API.
- **Edit:** `Sources/AnimiEngineCore/Timeline/TimelineIndex.swift`
  - Add stored `transitionWindowIndex: TransitionWindowIndex`; build it in `init`.
  - `activeBoundary(at:)` delegates to `transitionWindowIndex.activeBoundary(at:)` (remove the scan).
  - `requirements(for:)`:
    - transition gathering uses `transitionWindowIndex.boundaries(intersecting: coverage)` (remove the
      per-transition scan);
    - scene gathering uses binary search: find `sceneIndex(containing: coverage.start.ticks)` and
      `sceneIndex(containing: lastTick)`, then take the **contiguous index range** `[firstScene,
      lastScene]` plus the scene pair of each intersecting animated boundary — no `O(n)` `scenes.indices`
      loop (`.../TimelineIndex.swift:200` is deleted). Because scenes are contiguous on the timeline,
      every scene whose span intersects `coverage` is exactly the inclusive index range
      `firstScene…lastScene`; iteration is over results only.

### Algorithm and invariants

- **Disjointness invariant:** for animated windows sorted by start, `windows[i].end ≤ windows[i+1].start`.
  Established by adjacency validation; re-asserted at index construction.
- **Point query:** binary-search the largest `i` with `windows[i].start ≤ tick`; that single window is
  the only possible container (disjointness). Check `windows[i].window.contains(tick)`. `O(log m)`,
  `m` = animated-boundary count.
- **Range query:** binary-search the first `i` with `windows[i].end > coverage.start`; iterate while
  `windows[i].start < coverage.end`, collecting intersecting windows. Output size `t` ⇒
  `O(log m + t)`.
- **Scene range:** contiguity of scene spans ⇒ the set of scenes intersecting `coverage` is the
  inclusive index interval `[sceneIndex(coverage.start), sceneIndex(lastTick)]`; `O(log n + s)` for `s`
  results. Transition scene-pairs (each `±1` around a boundary) are already inside or adjacent to this
  interval and are unioned explicitly.

### Regression tests (new)

- **New file** `TransitionWindowIndexTests`:
  - `testActiveBoundaryPointLookupMatchesLinearReference` — for a project with many boundaries, assert
    `transitionWindowIndex.activeBoundary(at:)` equals a brute-force linear scan at a deterministic set
    of probe ticks (boundaries, window edges ±1, midpoints).
  - `testRangeLookupMatchesLinearReference` — same, for `boundaries(intersecting:)`.
  - `testDisjointnessRejectedWhenViolated` — feeding overlapping windows (bypassing validation) throws
    the typed overlap error.
- **Deterministic large-N complexity tests (no wall-clock timing, no mutable static, no `#if DEBUG`):**
  - Approach: the search returns a pure `SearchDiagnostics { comparisons, visited }` by value; tests
    call the package-internal `...WithDiagnostics` method and assert
    `comparisons + visited ≤ C·⌈log2(m)⌉ + k` for a fixed small `C`, across `m ∈ {1, 2, 16, 256, 4096}`.
    Because the bound is asserted on **operation counts** returned by the production algorithm itself, the
    test is deterministic, CPU-speed-independent, and runs the identical code path as production. The same
    pattern is applied to `SceneSpanIndex` (binary-search step counter returned alongside the found
    index) so `requirements(for:)` scene gathering can be shown output-sensitive.
  - `testActiveLookupVisitsLogarithmicNodes` and `testRangeLookupIsOutputSensitive` encode this for
    `TransitionWindowIndex`.
  - `TimelineIndexTests.testRequirementsDoesNotScanAllScenesForNarrowCoverage` — with `n = 4096` scenes
    and a coverage spanning 2 scenes, assert the returned `sceneSpans.count ≤ 4` (2 base + ≤2 transition
    neighbors) and (via the returned `SceneSpanIndex` diagnostics) that the step count is `O(log n)`, i.e.
    no full-array scan occurred.

---

## C-3. Correct `RationalSourceTime` arithmetic and `Int64.min` handling

### Root cause

`RationalSourceTime` (`Sources/AnimiEngineCore/Time/RationalSourceTime.swift`) throws too eagerly and
mishandles `Int64.min`:

1. **Premature overflow in `adding`/`multiplied`.** Intermediate products
   (`a*dReduced`, `bReduced*d`, `a*c`, `b*d`) are checked against `Int64` **before** the final GCD
   reduction. A result that *reduces* to a representable rational can still throw because an
   intermediate over/underflows. The required example
   `Int64.max/2 + (−Int64.max)/3 = Int64.max/6` is exactly such a case: the naive common-denominator
   numerator `3·(max) + 2·(−max) = max` is representable and the reduced result fits, but intermediate
   `2·3` vs cross terms must be handled so the *final reduced* value is what is range-checked.
2. **`Int64.min` normalization.** The initializer rejects `d == Int64.min` (and `n == Int64.min` when
   `d < 0`) outright (`:28`). But `0/Int64.min` reduces to `0/1` and `Int64.min/Int64.min` reduces to
   `1/1` — both representable. `gcd` returns `Int64.max` as a clamp when both inputs are `Int64.min`
   (`:109`), which is mathematically wrong (the true gcd magnitude is `2^63`, not `2^63−1`).
3. **Spec wording.** The plan (§4.2) says normalization throws **only if the final reduced numerator or
   denominator cannot fit `Int64`**. The implementation throws on intermediate conditions and on
   representable `Int64.min` inputs.

### Design decision (Revision 2 — proven reduced-rational algorithm, no general 128-bit division)

**General `UInt128 ÷ UInt128` division and `UInt128`-vs-`UInt128` GCD are NOT implemented.** They are
unnecessary. The proven algorithm keeps every denominator factor in **64-bit**, forms the numerator in
**128-bit signed** width, and reduces it by a GCD computed against a **64-bit** value — which needs only
a `UInt128 % UInt64` step (a narrowing remainder), never a 128÷128 long division.

Inputs are always reduced fractions with `denominator ∈ 1...Int64.max`. The required 128-bit support is
therefore minimal:

- a signed 128-bit accumulator (`magnitude: UInt128`, `negative: Bool`) for the numerator;
- `UInt128 = UInt64 × UInt64` (exact, via `multipliedFullWidth`);
- `UInt128 ± UInt128` (the numerator is a sum/difference of two `≤ 2^126` products, so it fits 127 bits);
- `UInt128 % UInt64 → UInt64` and `UInt128 / UInt64 → UInt128` (the only divisions; both narrow against a
  64-bit divisor — schoolbook two-limb long division by a 64-bit value, **not** general 128÷128);
- `fitsInt64Magnitude` and signed narrowing.

`Int64.min` is handled by taking **unsigned magnitudes** up front (`Int64.min`'s magnitude is exactly
`2^63`, formed without negating in 64-bit) and carrying a separate sign, so `Int64.min` never needs a
64-bit negation.

### Exact files and APIs changed

- **New:** `Sources/AnimiEngineCore/Time/Int128.swift`
  - Internal `struct UInt128 { let high: UInt64; let low: UInt64 }` with **only** the operations above:
    `add`, `subtract` (with borrow; caller guarantees minuend ≥ subtrahend), `multiplyU64(_:_:)`
    (`UInt64 × UInt64`), `remainderU64(_ d: UInt64) -> UInt64`, `dividedByU64(_ d: UInt64) -> UInt128`,
    `compare`, `fitsInt64Magnitude`. **No** `UInt128 ÷ UInt128` and **no** `gcd(UInt128, UInt128)`.
  - Internal `struct SInt128 { let negative: Bool; let magnitude: UInt128 }` for the signed numerator,
    with signed add/subtract and sign-aware compare. This also **subsumes** the private `Signed128`
    previously used only for comparison.
  - Helper `magnitudeU64(of x: Int64) -> UInt64` returning `x.magnitude` (correct for `Int64.min`).
- **Edit:** `Sources/AnimiEngineCore/Time/RationalSourceTime.swift`
  - `init(numerator:denominator:)`:
    - reject `denominator == 0` (unchanged);
    - sign = `(numerator < 0) ≠ (denominator < 0)`;
    - take 64-bit magnitudes `|n|`, `|d|` (each fits `UInt64`; `Int64.min` → `2^63`);
    - `g = gcd64(|n|, |d|)` (correct `UInt64` Euclid, **no** clamp); reduce `|n|/g`, `|d|/g`;
    - **signed narrowing rules (final):** the reduced denominator magnitude is in `1...Int64.max` (a
      denominator magnitude of `2^63` is only reachable from `|d| = 2^63` with `g = 1`, i.e. `n` odd; if
      the reduced denominator magnitude `> Int64.max` → throw `rationalDoesNotFit`). The reduced numerator
      narrows by sign: **positive** magnitude must be `≤ Int64.max`; **negative** magnitude may equal
      `2^63` and becomes exactly `Int64.min`; otherwise `> Int64.max` → throw.
  - `adding(_:)` and `multiplied(by:)`: use the proven algorithm below; all denominator factors stay
    64-bit; the only 128-bit value is the numerator; reduction uses `UInt128 % UInt64`.
  - `static func <`: delegate to the `SInt128` cross-product compare (replaces `RationalSupport.Signed128`).
  - Delete the `gcd` clamp-to-`Int64.max`; `gcd64` returns the true `UInt64` gcd.
- **Edit:** `Sources/AnimiEngineCore/Time/SourceTimeMapping.swift`
  - `target(for:)` must **compose rational multiplication and addition** rather than multiply `Int64`
    values prematurely:
    `delta = (PlaybackRate as RationalSourceTime rn/rd) · (scene-tick s as s/240000)` via
    `RationalSourceTime.multiplied(by:)`, then `target = trimStart.adding(delta)` via
    `RationalSourceTime.adding(_:)`. The current code that builds `deltaNumerator = rn · s` and
    `deltaDenominator = rd · 240000` as raw `Int64` multiplications (which can overflow even when the
    reduced target fits) is removed.

### Mathematically justified algorithm (reduce-first, 64-bit denominators, 128-bit numerator only)

**Addition** `a/b + c/d`, both reduced with `b, d ∈ 1...Int64.max`:

```
g   = gcd64(b, d)                         // 64-bit Euclid, exact
b'  = b / g                               // 64-bit
d'  = d / g                               // 64-bit
// common denominator L = b' · d  (= lcm(b,d)); keep its 64-bit factors b' and d
// numerator N = a·d' + c·b'  in SIGNED 128-bit (each product ≤ Int64.max·Int64.max < 2^126)
p1  = SInt128(a) * d'                      // UInt64×UInt64 magnitudes, sign of a
p2  = SInt128(c) * b'                      // sign of c
N   = p1 + p2                              // |N| < 2^127, fits SInt128
// reduce N / (b'·d). gcd of |N| (128-bit) with the denominator must be taken in two 64-bit steps,
// because b' and d are each 64-bit:
g1  = gcd128_64(|N|, b')                   // |N| % b' via UInt128 % UInt64, then 64-bit Euclid
N1  = N  / g1   (sign preserved)           // UInt128 / UInt64
b'' = b' / g1
g2  = gcd128_64(|N1|, d)                    // |N1| % d via UInt128 % UInt64, then 64-bit Euclid
N2  = N1 / g2
d'' = d  / g2
// now gcd(|N2|, b''·d'') = 1 by construction; final denominator factor = b''·d''  (64-bit × 64-bit)
denMag = UInt128.multiplyU64(b'', d'')     // may exceed 64 bits → that itself is the overflow signal
require denMag.fitsInt64 and |N2|.fitsInt64-with-sign  else throw rationalDoesNotFit
result = sign(N2) · |N2|  /  denMag        // narrow per the signed-numerator rules
```

`gcd128_64(M, x)` = `gcd64(M % x, x)` where `M % x` uses `UInt128 % UInt64`. This is the **only** place a
128-bit value meets division, and the divisor is always 64-bit. The two-step reduction (`g1` against `b'`,
then `g2` against `d`) is valid because `gcd(N, b'·d) = gcd(gcd(N, b'), d)·…` factors through the two
coprime-ish 64-bit factors; doing it in two steps guarantees the residual denominator `b''·d''` is coprime
to `N2`.

**Multiplication** `a/b · c/d`: cross-cancel in 64-bit **before** widening —
`g1 = gcd64(|a|, d)`, `g2 = gcd64(|c|, b)`, then `a' = a/g1, d' = d/g1, c' = c/g2, b' = b/g2`. The result
is `(a'·c') / (b'·d')`; numerator magnitude `|a'·c'|` is one `UInt64×UInt64 → UInt128`, denominator
`b'·d'` is `UInt64×UInt64 → UInt128`. After cross-cancellation `gcd(|a'·c'|, b'·d') = 1`, so no further
reduction is needed; range-check both and narrow.

**Justification.** Every denominator factor is bounded by `Int64.max` and stays 64-bit. The numerator is a
sum/difference of two products each `< 2^126`, so `|N| < 2^127` and fits `SInt128`. GCD reduction against a
64-bit factor uses only `UInt128 % UInt64`. The result is the unique lowest-terms rational; the `Int64`
fit is checked **once, at the end**, exactly as §4.2 requires.

**Signed-narrowing rules (final, enforced everywhere a rational is constructed):**
- positive numerator magnitude **≤ `Int64.max`**;
- negative numerator magnitude may equal **`2^63`** and must become **`Int64.min`**;
- denominator must be **`1...Int64.max`** (magnitude `2^63` denominators are rejected as
  `rationalDoesNotFit`).

Worked targets (all must pass, producing the reduced result):

| Input | Reduced result |
|---|---|
| `Int64.max/2 + (−Int64.max)/3` | `Int64.max/6` |
| `0/Int64.min` | `0/1` |
| `Int64.min/Int64.min` | `1/1` |
| `Int64.min/1` | `Int64.min/1` (negative magnitude `2^63` → `Int64.min`, denominator `1`) |
| `SourceTimeMapping.target` with rational rate `rn/rd` where naive `rn·s` overflows `Int64` but the composed/reduced target fits | exact reduced target (no throw) |

### Regression tests (new / changed)

- **New file** `RationalArithmeticTests` (and extend `RationalSourceTimeTests`):
  - `testMaxOverTwoPlusNegMaxOverThree` → `Int64.max/6`.
  - `testZeroOverIntMin` → `0/1`.
  - `testIntMinOverIntMin` → `1/1`.
  - `testIntMinOverOne` → `Int64.min/1` (the **irreducible** `Int64.min` case, not only reducible ones:
    negative magnitude `2^63` narrows to `Int64.min`, denominator `1`).
  - `testIntMinNumeratorReducesWhenEven` — `Int64.min / 2` → `−(2^62)/1`.
  - `testNegativeMagnitude2Pow63Allowed_PositiveRejected` — a construction yielding negative magnitude
    `2^63` succeeds (`Int64.min`); the same magnitude **positive** throws `rationalDoesNotFit`.
  - `testDenominatorMagnitude2Pow63Rejected` — a reduced denominator magnitude `2^63` throws.
  - `testAvoidableOverflowInSourceTimeMappingWithRationalRate` — a `SourceTimeMapping` with
    `rate = rn/rd` and a scene tick `s` so naive `rn·s` exceeds `Int64`, but the **composed**
    `target = trimStart + (rn/rd)·(s/240000)` reduces to a representable rational; assert exact value,
    no throw. Confirms `SourceTimeMapping` composes rationals instead of premultiplying `Int64`.
  - `testTrulyIrreducibleOverflowStillThrows` — `Int64.max/1 · Int64.max/1` throws `rationalDoesNotFit`.
  - `testComparisonUnchangedAtBoundaryValues` — full-width comparison regression guard for the `SInt128`
    replacement.
- **Property test (deterministic, seeded — no `Math.random`):** for a fixed table of `(n,d)` pairs
  including `Int64.min/1`, `Int64.min/Int64.min`, and `0/Int64.min`, assert `a+b == b+a`, `a·b == b·a`,
  and reduced-form invariants (denominator `1...Int64.max`, `gcd(|n|,d)==1`, sign rules honored).
- **Negative architectural guard:** `Int128.swift` exposes **no** `UInt128 ÷ UInt128` and **no**
  `gcd(UInt128, UInt128)` (documented; reviewers confirm the file contains only `%`/`/` by `UInt64`).

---

## C-4. Authoritative, non-forgeable window/requirement family; builder derives output/duration and validates loaded payloads

### Root cause

- `EvaluationWindowRequirement` has a **public** initializer
  (`Sources/AnimiEngineCore/Timeline/EvaluationWindowRequirement.swift:82`) and does **not** carry
  `output` or `projectDuration`. A caller outside the package can fabricate an arbitrary requirement.
- `EvaluationWindowBuilder.build(...)` accepts `output` and `projectDuration` as **independent
  parameters** (`Sources/AnimiEngineCore/Timeline/EvaluationWindowBuilder.swift:12-13`), so the window's
  output/duration can disagree with the index that produced the requirement.
- **Threat (new in Revision 2):** the builder receives payloads *after* the manifest index was created.
  A caller can supply **different payload content under matching IDs** — structurally consistent
  (`sceneID`/`overlayID` match) yet with insufficient material (a shorter trim, a wrong active range).
  Structural correspondence alone does not catch this.
- The whole window/requirement value family has **public** memberwise initializers, so any of the
  intermediate values (`WindowScene`, `RequiredBoundary`, …) can be fabricated outside the package and
  smuggled into an `EvaluationWindow`.

This violates §10.2's "authoritative contract" and lets unvalidated material reach the evaluator.

### Design decision

1. **The whole family removes its public initializers.** Public construction is removed for **all eight**
   types so external, non-`@testable` consumers cannot mint them; within the trusted module they are
   produced only by `TimelineIndex` (requirement family) and `EvaluationWindowBuilder` (window family).
   External callers may **read** every property but the public API exposes no initializer for:
   `EvaluationWindow`, `WindowScene`, `WindowTransition`, `WindowOverlay`, `EvaluationWindowRequirement`,
   `RequiredSceneSpan`, `RequiredBoundary`, `RequiredOverlayEntry`.
2. **The requirement is the single source of truth** and carries `output` and `projectDuration`. The
   builder takes the requirement plus the loaded payloads — nothing else — and derives output/duration
   from the requirement.
3. **The builder validates loaded payload material** against the authoritative requirement (the
   lazy-path site from C-1) before publishing an `EvaluationWindow`, defeating the matching-ID/
   different-content threat.

### Non-forgeability mechanism (per type) — honest guarantee

For each of the eight types, change the **memberwise/explicit initializer from `public init` to `init`
(package-internal)** and keep all stored properties `public let` (read-only access preserved).

**Honest scope of the guarantee.** Swift `internal` initializers stop construction by **external,
non-`@testable`** consumers only. They do **not** stop:

- code **inside** `AnimiEngineCore` (the module implementation is **trusted** — `TimelineIndex` and
  `EvaluationWindowBuilder` must construct these values, and any other in-module code can too);
- test code that uses `@testable import AnimiEngineCore` (the test module deliberately reaches internal
  symbols).

So the precise guarantee is: **an external package that does a normal `import AnimiEngineCore` has no
way to construct any of the eight types** — it can read them but not forge them. Inside the module and
under `@testable`, construction remains available by design. The earlier "the test module must fail to
compile" claim was **false** and is removed; `@testable` tests can and do construct these values to set
up fixtures.

(These types already declare explicit initializers in the implementation, so the change is a single
access-level edit per type — no property changes.)

| Type | File | Minted only by |
|---|---|---|
| `RequiredSceneSpan` | `Timeline/EvaluationWindowRequirement.swift` | `TimelineIndex.requirements(for:)` |
| `RequiredBoundary` | `Timeline/EvaluationWindowRequirement.swift` | `TimelineIndex.requirements(for:)` |
| `RequiredOverlayEntry` | `Timeline/EvaluationWindowRequirement.swift` | `TimelineIndex.requirements(for:)` |
| `EvaluationWindowRequirement` | `Timeline/EvaluationWindowRequirement.swift` | `TimelineIndex.requirements(for:)` |
| `WindowScene` | `Timeline/EvaluationWindow.swift` | `EvaluationWindowBuilder.build(...)` |
| `WindowTransition` | `Timeline/EvaluationWindow.swift` | `EvaluationWindowBuilder.build(...)` |
| `WindowOverlay` | `Timeline/EvaluationWindow.swift` | `EvaluationWindowBuilder.build(...)` |
| `EvaluationWindow` | `Timeline/EvaluationWindow.swift` | `EvaluationWindowBuilder.build(...)` |

`ActiveBoundaryReference` (used by `TimelineLookupResult`) is **not** in this family — it is a read
result, not a window/requirement input — and keeps its public initializer; it is constructed by
`TransitionWindowIndex`/`TimelineIndex`.

### Exact files and APIs changed

- **Edit:** `Sources/AnimiEngineCore/Timeline/EvaluationWindowRequirement.swift`
  - Add stored `public let output: OutputContext` and `public let projectDuration: TickDuration` to
    `EvaluationWindowRequirement`.
  - Make the initializers of `EvaluationWindowRequirement`, `RequiredSceneSpan`, `RequiredBoundary`,
    and `RequiredOverlayEntry` package-internal (`init`, not `public init`).
- **Edit:** `Sources/AnimiEngineCore/Timeline/EvaluationWindow.swift`
  - Make the initializers of `EvaluationWindow`, `WindowScene`, `WindowTransition`, and `WindowOverlay`
    package-internal.
- **Edit:** `Sources/AnimiEngineCore/Timeline/TimelineIndex.swift`
  - `requirements(for:)` populates `output: self.output` and `projectDuration: self.projectDuration`
    when constructing the requirement.
- **Edit:** `Sources/AnimiEngineCore/Timeline/EvaluationWindowBuilder.swift`
  - New signature:
    `static func build(requirement: EvaluationWindowRequirement, scenes: [ResolvedScenePayload], overlays: [ResolvedOverlayPayload]) throws -> EvaluationWindow`.
  - Remove the `output`/`projectDuration` parameters; read them from `requirement`.
  - Keep all structural-correspondence checks: coverage non-empty and inside `projectDuration`; scene
    payloads exactly match `requirement.sceneSpans` (no missing/unexpected/duplicate); overlay payloads
    exactly match `requirement.overlayEntries`; structural-id consistency (`payload.sceneID == span.sceneID`,
    `payload.overlayID == entry.overlayID`); transitions taken verbatim from the requirement.
  - **Add (C-1 lazy-path site):** after building the `WindowScene`/`WindowTransition`/`WindowOverlay`
    set and **before** returning the `EvaluationWindow`, call
    `MaterialAvailabilityValidator.validateWindowPayloads(requirement:scenes:transitions:overlays:)` so
    the **loaded** payload content (not the manifest's declared content) is material-validated against
    the authoritative requirement — **including the loaded overlay animation material**. Any failure
    throws a validation error and **no window is returned**.
- **Edit (tests/support):** `EvaluationHarness` and any fixture/test calling `build(...)` drop the
  `output:`/`projectDuration:` arguments; all requirements come from `index.requirements(for:)`.
  (`@testable` test code may still construct the family directly where a unit test needs a hand-made
  fixture; the public-surface guarantee is verified separately below, not by a compile-failure.)

### Invariants

- Every `EvaluationWindow` is produced only by `EvaluationWindowBuilder`, from a requirement minted only
  by `TimelineIndex`; `output`/`projectDuration` are provably index-derived, never caller-supplied.
- Every `EvaluationWindow` has had its **loaded** payloads material-validated; the evaluator never sees
  unvalidated material.
- No window/requirement value can be fabricated outside the package.

### Regression tests (new / changed)

- `EvaluationWindowBuilderTests`:
  - update existing tests to the new signature;
  - `testBuilderUsesRequirementOutputAndDuration` — built window's `output`/`projectDuration` equal the
    index's; no caller override exists (the `output`/`projectDuration` parameters were removed).
  - keep missing/unexpected/duplicate/inconsistent-payload cases;
  - `testBuilderRejectsLoadedPayloadWithMatchingIDButInsufficientMaterial` (also listed under C-1) — the
    matching-ID/different-content threat (scene material) is rejected before a window is returned;
  - `testBuilderRejectsLoadedOverlayWithMatchingIDButInsufficientAnimation` (also under C-1) — the
    matching-ID overlay-animation threat is rejected before a window is returned.
- **Public-API-surface non-forgeability verification (not a compile-failure claim).** Verify via
  **symbol-graph / API-surface inspection** that the public interface exposes **no public initializer**
  for the eight types:
  - generate the module's API surface with
    `swift build -Xswiftc -emit-symbol-graph -Xswiftc -emit-symbol-graph-dir -Xswiftc <dir>` (or
    `swift symbolgraph-extract -module-name AnimiEngineCore …`), then assert the resulting
    `AnimiEngineCore.symbols.json` contains **no `init` symbol with `public`/`open` access** whose parent
    is any of the eight types. This is a deterministic, machine-checkable assertion about the *public*
    surface and does not depend on `@testable`.
  - a small `APISurfaceTests` test (or a CI script step documented here) loads the symbol graph and fails
    if any of the eight types exposes a public initializer; it also asserts `SearchDiagnostics` is
    **absent** from the public surface (internal-only, per Revision 3).
  - Positive runtime coverage remains: all requirements/windows used by other tests are obtained via
    `index.requirements(for:)` and `EvaluationWindowBuilder.build(...)`; `@testable` fixtures that
    construct internals directly are explicitly allowed and do not contradict the public-surface
    guarantee.

---

## C-5. `encode` rejects invalid documents; explicit `schemaVersion`; `TimelineIndex` rejects invalid manifests

### Root cause

- `CanonicalProjectEncoding.encode(_:)` serializes **without validating**
  (`Sources/AnimiEngineCore/Codec/CanonicalProjectEncoding.swift:13`), so an invalid document can be
  written to canonical bytes (and a later `decodeValidated` would reject the very bytes we produced).
- `schemaVersion` is decoded as a free integer; no supported-version check exists.
- `TimelineIndex.init` only checks emptiness and transition count; it can be built from a manifest that
  is otherwise semantically invalid (e.g. duplicate ids, bad overlay range) if a caller bypasses
  `decodeValidated`.

### Design decision

- `encode` validates first; encoding an invalid document is a programming error surfaced as a thrown
  validation error, guaranteeing `encode`/`decodeValidated` symmetry.
- Introduce an explicit supported-schema constant and reject anything else as a validation error.
- `TimelineIndex.init` runs the full `ProjectValidator.validate` (manifest-level subset) so an index can
  never be built from an invalid manifest.

### Exact files and APIs changed

- **New constant:** in `Sources/AnimiEngineCore/Project/CanonicalProjectManifest.swift`
  `public static let supportedSchemaVersion = 1`.
- **Edit:** `Sources/AnimiEngineCore/Project/ProjectValidationError.swift`
  - add `case unsupportedSchemaVersion(found: Int, supported: Int)`.
- **Edit:** `Sources/AnimiEngineCore/Project/ProjectValidator.swift`
  - new first check: `guard manifest.schemaVersion == CanonicalProjectManifest.supportedSchemaVersion`
    else throw `unsupportedSchemaVersion`.
- **Edit:** `Sources/AnimiEngineCore/Codec/CanonicalProjectEncoding.swift`
  - `encode(_:)` calls `try ProjectValidator.validate(document)` before building bytes; on failure it
    throws the `ProjectValidationError` (encode's error domain is documented as validation, distinct
    from `decodeValidated`'s `ProjectLoadError`). The byte-stability contract is preserved for valid
    documents.
- **Edit:** `Sources/AnimiEngineCore/Timeline/TimelineIndex.swift`
  - `init(manifest:)` validates the manifest. Two options, decided here:
    **(chosen)** add `ProjectValidator.validateManifest(_ manifest:)` — a manifest-only validation entry
    point (schema version, non-empty, durations, transition count + per-transition validity, duplicate
    ids/ordinals at manifest scope, overlay containment, adjacency) that does **not** require payloads —
    and call it from `init`. Full document validation (payload correspondence + material) remains in
    `validate(_ document:)`. This keeps the index buildable from a manifest while still rejecting invalid
    manifests. The existing emptiness/transition-count guards are folded into `validateManifest`.

### Invariants

- `encode(decodeValidated(x)) == x` byte-stability holds for all valid documents; invalid documents
  cannot be encoded at all.
- `TimelineIndex` exists ⇒ its manifest passed `validateManifest`.
- `decodeValidated` already runs full `validate`; material validation (C-1) plus schema check now make
  it the complete gate.

### Regression tests (new / changed)

- `CanonicalProjectEncodingTests`:
  - `testEncodeRejectsSemanticallyInvalidDocument` — encoding an empty-scene or duplicate-id document
    throws a validation error; no bytes produced.
  - `testEncodeDecodeSymmetryStillByteStableForValidDocuments` — unchanged behavior for valid docs.
  - `testUnsupportedSchemaVersionRejected` — a document with `schemaVersion = 2` fails both `encode` and
    `decodeValidated` with `unsupportedSchemaVersion`.
- `TimelineIndexTests`:
  - `testIndexRejectsInvalidManifest` — building `TimelineIndex` from a manifest with duplicate scene
    ids / out-of-project overlay throws the corresponding validation error.

---

## C-6. Remove `try?` / force-unwrap from production timeline code

### Root cause

`TimelineIndex.requirements(for:)` builds overlay ranges with `try?` + force-unwrap
(`Sources/AnimiEngineCore/Timeline/TimelineIndex.swift:221-224`):

```swift
timeRange: (try? ProjectTimeRange(start: ProjectTime(uncheckedTicks: …), end: …))!
```

If the interval were ever degenerate this force-unwrap traps instead of throwing a typed error.

### Design decision

Replace `try?…!` with a normal `try` that propagates a typed error. The overlay intervals come from the
manifest, which validation guarantees are well-formed (`end > start`), so in practice this never fails;
but the production path must not contain a trap. Audit the whole `AnimiEngineCore` for any other
`try?`/`!` and remove them (a `ProjectTime(uncheckedTicks:)` use here is acceptable because the ticks
originate from already-validated manifest ranges; it is documented, not a force-unwrap).

### Exact files and APIs changed

- **Edit:** `Sources/AnimiEngineCore/Timeline/TimelineIndex.swift`
  - In the overlay-entry mapping inside `requirements(for:)`, replace the `try?…!` with a `try`
    expression inside the throwing context (the surrounding `requirements(for:)` already `throws`).
    Use `OverlayIntervalIndex` intervals' `start`/`end` directly through the checked
    `ProjectTimeRange(start:end:)` initializer; on the impossible failure, surface
    `ProjectValidationError.invalidRange(field: "overlay.timeRange")`.
- **Audit (no expected changes elsewhere):** grep `AnimiEngineCore` for `try?` and `!` force-unwraps;
  the plan asserts the only production occurrence is the one above. Test code (`EvaluationHarness`,
  fixtures) is out of scope for this rule but will be checked.

### Regression tests

- `TimelineIndexTests.testRequirementsOverlayRangesArePropagatedWithoutTrapping` — a manifest with
  overlays produces correct requirement ranges; covered by existing overlay/requirement tests, plus an
  explicit assertion that the requirement's overlay `timeRange` equals the manifest range.
- Static check (documented, not a unit test): `grep -nE "try\?|!\)" Sources/AnimiEngineCore` returns no
  production force-unwrap/`try?`.

---

## C-7. Strict real-template parsing; checked exact frame conversion; test every authored variant

### Root cause

`TemplateFixtureReader` and `CanonicalProjectFixtures` are lenient:

- Unknown/missing animation policies are silently defaulted:
  `CanonicalProjectFixtures.shorterPolicy` maps any unknown string to `.holdLast`
  (`Sources/AnimiEngineTestSupport/CanonicalProjectFixtures.swift:19`); `longerPolicy` ignores its input
  entirely (`:24-26`).
- Missing rect/zIndex/variant fields default to `0`/`""`/`false`
  (`Sources/AnimiEngineTestSupport/TemplateFixtureDescriptor.swift:119,126-139`).
- Instantiation derives `authoredDuration` from the **scene** duration and silently picks the **first**
  variant, never exercising `defaultDurationFrames` or the other authored variants.

This means the "real template" tests do not actually prove the authored data is representable — they
mask gaps with defaults.

### Design decision

Make template reading **strict and total**, and make variant selection **per block**:

- Every authored field that the engine consumes must be present and of the correct type, or the reader
  throws a typed `ReadError`.
- **JSON typing is exact — no Foundation bridging ambiguity.** `JSONSerialization` bridges JSON
  `true`/`false` and JSON numbers all to `NSNumber`, so a naive `value as? NSNumber` accepts `true`
  where an integer is required (and `1`/`0` where a boolean is required). Strict reading uses
  **object-identity / `CFTypeID` checks** rather than `as? NSNumber`/`as? Int`/`as? Bool` cross-bridges
  (exact checks specified in "Strict JSON typing" below); any mismatch is `ReadError.wrongType(field:)`.
  No silent coercion of `true`↔`1`, no truncation of a fractional number to an integer.
- Animation policies are mapped through **throwing** functions that reject unknown strings.
- `defaultDurationFrames` is converted to ticks via **checked exact** multiplication by the rate's
  `exactTicksPerFrame` (no silent `0`, no rounding).
- **Per-block variant selection.** A single `variantID` for the whole template is insufficient because
  different blocks have different variant sets (e.g. `example_4blocks` block_01 has `no-anim,v1,v2,v3,v4`
  while block_02 has only `no-anim,v1`). Instantiation takes an explicit `[blockID: variantID]` selection
  that **must cover every block** of the template; a missing block or a `variantID` not present in that
  block's authored set is a typed error. (Equivalently, the API may instantiate one chosen
  `(blockID, variantID)` while requiring explicit selections for **every other** block — same coverage
  guarantee.)
- **`loop` is given an exact mapping, never parsed-and-ignored.** Mapping and contradiction rules:
  - `loop: false` (the value in all five real templates) ⇒ the variant's `ifShorter` is taken verbatim
    from `ifAnimationShorter` (`holdLastFrame → .holdLast`, etc.).
  - `loop: true` ⇒ the variant is treated as a looping animation. It is **only** consistent with
    `ifAnimationShorter == "loop"`; `loop: true` combined with `holdLastFrame`/`becomeInactive` is a
    **contradiction** and is rejected (`ReadError.contradictoryLoopPolicy`). Symmetrically,
    `ifAnimationShorter == "loop"` with `loop: false` is rejected as contradictory. This makes the two
    authoring fields a single coherent policy rather than two independently-defaulted strings.
- Tests iterate **every** authored variant of **every** block and assert each instantiates into a
  render-complete payload — never choosing the first or substituting a default.

### Exact files and APIs changed

- **Edit:** `Sources/AnimiEngineTestSupport/TemplateFixtureDescriptor.swift`
  - Add a small **strict typed-accessor layer** (private helpers) used by all field reads:
    `requireString`, `requireInt`, `requireDouble`, `requireBool`, each taking the parent object and a
    field name and throwing `ReadError.missingField`/`ReadError.wrongType` (exact checks in "Strict JSON
    typing"). No call site uses `as? NSNumber`/`as? Int`/`as? Bool` directly.
  - `slot(from:)`: require `zIndex` (int), `rect.{x,y,width,height}` (number → double), and each variant's
    `variantId` (string), `animRef` (string), `defaultDurationFrames` (int), `ifAnimationShorter`
    (string), `ifAnimationLonger` (string), `loop` (**bool**, not number). Missing or wrong-typed ⇒
    `ReadError.missingField`/`ReadError.wrongType`.
  - add `ReadError` cases: `unknownShorterPolicy(String)`, `unknownLongerPolicy(String)`,
    `nonPositiveDuration`, `wrongType(field:)`, `contradictoryLoopPolicy(blockID:variantID:)`,
    `missingVariantSelection(blockID:)`, `unknownVariantSelection(blockID:variantID:)`.
- **Edit:** `Sources/AnimiEngineTestSupport/CanonicalProjectFixtures.swift`
  - `shorterPolicy(raw:loop:) throws -> AnimationShorterPolicy` — maps `holdLastFrame/loop/becomeInactive`
    and **reconciles** with the `loop` flag: throws `contradictoryLoopPolicy` on mismatch (see rules
    above); `default:` throws `unknownShorterPolicy`.
  - `longerPolicy(_:) throws -> AnimationLongerPolicy` — maps exactly `"cut" → .cutAtEvaluationEnd`, else
    `unknownLongerPolicy`.
  - new `authoredDurationTicks(variant:frameRate:) throws -> TickDuration` =
    `frameRate.exactTicksPerFrame · variant.defaultDurationFrames` via `CheckedInt64.multiply`, rejecting
    `defaultDurationFrames ≤ 0`.
  - `instantiate(_:sceneInstanceID:payloadID:selection:)` where
    `selection: [String: String]` is the `[blockID: variantID]` map. Validation: every block id in the
    descriptor must be a key in `selection` (`missingVariantSelection`), and each selected `variantID`
    must exist in that block's authored variants (`unknownVariantSelection`). No implicit "first", no
    default substitution.
  - `slotAnimation(block:selection:frameRate:)` uses the strict, loop-reconciled policy mappers and the
    checked authored duration.
- **Edit:** `Tests/AnimiEngineCoreTests/TemplateFixtureTests.swift`
  - `testEveryAuthoredVariantOfEveryBlockInstantiatesRenderComplete` — for each of the five templates,
    enumerate the **cartesian selection per block** is unnecessary; instead, for each block and **each**
    authored variant of that block, build a `selection` that picks that variant for the block and a fixed
    valid variant for every other block, instantiate, and assert a render-complete payload that passes
    `ProjectValidator.validate` and evaluates at tick 0. This exercises every authored variant.
  - `testMissingVariantSelectionRejected` / `testUnknownVariantSelectionRejected` — a `selection` missing
    a block, or naming a variant not in the block, throws.
  - `testUnknownPolicyRejected` — unknown `ifAnimationShorter`/`ifAnimationLonger` throws.
  - `testContradictoryLoopPolicyRejected` — `loop: true` with `holdLastFrame`, and `loop: false` with
    `ifAnimationShorter == "loop"`, both throw `contradictoryLoopPolicy`.
  - `testDefaultDurationFramesConvertedExactly` — `authoredDurationTicks` equals
    `exactTicksPerFrame · defaultDurationFrames` (e.g. 150 frames @30 → `150·8000 = 1_200_000`).
  - `testBoolAsNumberRejected` — a fixture JSON where `loop` is the number `1` (not the JSON boolean
    `true`) throws `ReadError.wrongType(field: "loop")`; and a fixture where an integer field (e.g.
    `zIndex`) is the JSON boolean `true` throws `wrongType` (not silently read as `1`).
  - `testFractionalNumberAsIntegerRejected` — `defaultDurationFrames: 150.5` (or any non-integral
    number) throws `wrongType`/`malformedInteger` rather than truncating.
  - `testStringAsNumberAndNumberAsStringRejected` — `"150"` where a number is required, and `150` where a
    string is required, both throw `wrongType`.
  - keep `testBlockCountsAre_1_1_2_4_6` and `testExample4BlocksKeepsDistinctCatalogAndSceneID`.

### Strict JSON typing — exact checks (no Foundation bridging ambiguity)

`JSONSerialization` parses a JSON object to `[String: Any]` where every JSON number **and** every JSON
boolean is an `NSNumber`. The standard traps:

- `value as? Bool` succeeds for the JSON number `1` (bridges to `true`);
- `value as? Int` succeeds for the JSON boolean `true` (bridges to `1`);
- `value as? Int` succeeds for a fractional `NSNumber` by truncation.

The strict typed accessors avoid all three by inspecting the **underlying object type**, never relying on
the `as?` cross-bridges:

- **Boolean** (`requireBool`): accept **only** the boolean `NSNumber`. The canonical, deterministic check
  is `CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()` (equivalently
  `type(of: value) == type(of: NSNumber(value: true))`'s `__NSCFBoolean`); then read `.boolValue`. A
  numeric `NSNumber` (`0`/`1`) fails ⇒ `wrongType`.
- **Integer** (`requireInt`): require an `NSNumber` that is **not** a boolean
  (`CFGetTypeID(...) != CFBooleanGetTypeID()`) **and** whose `objCType` is an integer code (not a
  floating-point `f`/`d`), then convert via `Int64(exactly: number)` — a fractional value fails
  `exactly:` ⇒ `malformedInteger`/`wrongType`. `true`/`false` are rejected (they are boolean `NSNumber`s).
- **Double** (`requireDouble`): require a non-boolean `NSNumber`; read `.doubleValue`. (Used only for the
  authoring `rect` doubles, which never reach canonical geometry — those go through the future adapter.)
- **String** (`requireString`): require `value is String` (a Swift `String`/`NSString`); a number or
  boolean fails ⇒ `wrongType`.

These checks are deterministic and Foundation-bridging-safe; the boolean/integer disambiguation rests on
`CFBooleanGetTypeID()`, which is the documented way to tell a JSON boolean from a JSON number after
`JSONSerialization`. (This strictness lives in **test-support** template reading only; the canonical
project codec in `AnimiEngineCore` already uses its own non-`JSONSerialization` strict parser per the
approved Task-002 plan.)

### Invariants

- A `TemplateFixtureDescriptor` exists ⇒ every consumed authoring field was present and **exactly typed**
  (no `Bool`↔number or string↔number coercion, no fractional-to-integer truncation).
- Instantiation requires an explicit, complete `[blockID: variantID]` selection; no block is silently
  defaulted and no variant is silently chosen.
- The authoring `loop` field has a defined mapping; contradictory `loop`/`ifAnimationShorter`
  combinations are rejected.
- Every authored variant of every block of every real template is proven representable and
  render-complete by tests.

---

## C-8. Document honest `O(log n + k log k)` complexity (Option B — APPROVED)

### Root cause

`OverlayIntervalIndex` documents `O(log n + k)` (query header and `TimelineIndex` doc comment), but each
query **sorts** its results by `(zIndex, stableOrdinal, overlayID)` after collection
(`Sources/AnimiEngineCore/Timeline/OverlayIntervalIndex.swift` `overlays(containing:)` and
`intervals(intersecting:)`). The tree traversal is `O(log n + k)` to **collect**, but the post-sort adds
`O(k log k)`. The true bound is `O(log n + k log k)`.

### Decision (closed): Option B is APPROVED

Per technical-lead review, **Option B is approved**. The speculative Option A ordered-emission /
bucketed structure is **not** implemented. The algorithm keeps collect-then-sort; every complexity claim
is corrected to the honest `O(log n + k log k)`, and the deviation from the approved §10.1 `O(log n + k)`
wording is recorded explicitly in ADR-002 and the decision register.

Rationale recorded for the deviation: the active-overlay output size `k` for a single frame is small in
v1 (≤ tens of overlays), so the `k log k` sort is negligible in practice; the collect-then-sort
implementation is simpler and already correct, and the ordered-emission machinery Option A would require
adds structural complexity disproportionate to the benefit at v1 scale.

### Exact files and APIs changed (documentation only — no algorithm change)

- **Edit:** `Sources/AnimiEngineCore/Timeline/OverlayIntervalIndex.swift`
  - Correct the doc headers of `overlays(containing:)` and `intervals(intersecting:)` and the type-level
    comment from `O(log n + k)` to `O(log n + k log k)`, with a one-line note: traversal collects in
    `O(log n + k)`, the deterministic `(zIndex, stableOrdinal, overlayID)` sort adds `O(k log k)`.
  - The collect-then-sort code is **unchanged**.
- **Edit:** `Sources/AnimiEngineCore/Timeline/TimelineIndex.swift` doc comment — change the overlay-lookup
  claim to `O(log n + k log k)`.
- **Edit:** `AnimiEngineNext/Docs/ADR-002-project-and-template-compatibility.md` — record the overlay
  query as `O(log n + k log k)` and note it as an approved deviation from §10.1's `O(log n + k)`.
- **Edit:** `Docs/AnimiEngineNext/decision-register.md` — add a one-line approved-deviation entry
  referencing this corrective plan and ADR-002.

### Regression tests

- `OverlayIntervalIndexTests`:
  - `testResultsAreInDeterministicKeyOrder` — returned order equals `(zIndex, stableOrdinal, overlayID)`
    for overlapping intervals supplied out of order (unchanged behavior, retained).
  - **Deterministic complexity test (no wall-clock, pure returned counter as in C-2):** the index's
    search core returns a `SearchDiagnostics { comparisons, visited }`; assert the **traversal** node
    visits are `≤ C·⌈log2(n)⌉ + k` and document that the subsequent sort contributes the `k log k` term
    (asserted separately as `sortComparisons ≤ C'·k·⌈log2(max(k,2))⌉` if the sort is routed through the
    same diagnostic, otherwise left as a documented analytic bound). The test name/docstring records the
    **approved `O(log n + k log k)` deviation** across `n ∈ {1,16,256,4096}` with `k` controlled by
    construction. No mutable static, no `#if DEBUG` — same pure-diagnostic mechanism as C-2.

---

## Consolidated regression-test matrix

| # | Area | New / changed tests (file) | Asserts |
|---|---|---|---|
| C-1 | Material in validation (two-site, incl. overlays) | `ProjectValidationTests` (7), `EvaluationWindowBuilderTests` (3), `TransitionAvailabilityTests` (re-point 3), path-doc tests (3) | invalid scene **and overlay** material fails at `validate`/`decodeValidated` (full-doc) **and** at `build(...)` (lazy, matching-ID/different-content for scenes and overlays); `.holdLast`/`.loop` valid overlay continuations; `.becomeInactive` overlay outliving animation rejected; evaluator never throws; playback never discovers material errors |
| C-2 | Transition index | `TransitionWindowIndexTests` (new file), `TimelineIndexTests` (2 new) | point/range lookup equals linear reference; output-sensitive scene gathering; deterministic **pure-counter** op-count bounds (`SearchDiagnostics` internal) for `m,n ∈ {1,2,16,256,4096}` |
| C-3 | Rational arithmetic | `RationalArithmeticTests` (new) + `RationalSourceTimeTests` | four required identities; `Int64.min/1` (irreducible) + reducible `Int64.min` cases; signed-narrowing rules; composed `SourceTimeMapping` avoidable-overflow; genuine-overflow still throws; comparison regression; no `UInt128÷UInt128`/`gcd(UInt128,UInt128)` |
| C-4 | Non-forgeable family + builder validation | `EvaluationWindowBuilderTests` (update + 3 new), `APISurfaceTests` (new) | window output/duration derived from requirement; loaded scene **and overlay** material validated; symbol-graph confirms **no public init** for the 8 family types and `SearchDiagnostics` absent from public surface |
| C-5 | encode validates / schema / index | `CanonicalProjectEncodingTests` (3), `TimelineIndexTests` (1) | encode rejects invalid docs; unsupported schema rejected; index rejects invalid manifest |
| C-6 | No `try?`/`!` | `TimelineIndexTests` (1) + static grep | overlay ranges propagate via typed throw; no production force-unwrap |
| C-7 | Strict templates + per-block selection + `loop` + JSON typing | `TemplateFixtureTests` (9) | every authored variant of every block render-complete; per-block `[blockID:variantID]` selection required; unknown/missing selection rejected; `loop` mapped; contradictory `loop`/policy rejected; **`Bool`-as-number / number-as-`Bool` / fractional-as-int / string↔number rejected**; exact frame conversion |
| C-8 | Overlay complexity (Option B) | `OverlayIntervalIndexTests` (2) | deterministic key order; honest `O(log n + k log k)` documented and op-count-bounded via pure counter |

All complexity tests assert **operation counts** returned by the production algorithm as a pure
`SearchDiagnostics` value — never wall-clock time, never mutable static state, never `#if DEBUG`
divergence — so they are deterministic, concurrency-safe, and machine-independent.

## Determinism, purity, and banned-surface invariants

- `AnimiEngineCore` remains free of `Float`/`Double`/`CMTime`/AVFoundation/VideoToolbox/Metal/CoreMedia
  in code; the new `Int128`/`SInt128` use only `UInt64`/`Int64` and `multipliedFullWidth` (plus
  `UInt128 % UInt64` / `UInt128 / UInt64`); **no** `UInt128 ÷ UInt128` and **no** `UInt128` GCD.
- The evaluator stays pure (no IO/clock/cache) and, after C-1, performs **no** material validation in
  either path.
- `MaterialAvailabilityValidator`, `TransitionWindowIndex`, and the search-diagnostic counters are pure,
  value-semantic, and concurrency-safe (no shared mutable state).

## Files touched by this corrective plan (summary)

**Core — edit:** `Time/RationalSourceTime.swift`, `Time/SourceTimeMapping.swift`,
`Timeline/TimelineIndex.swift`, `Timeline/EvaluationWindowRequirement.swift`,
`Timeline/EvaluationWindow.swift`, `Timeline/EvaluationWindowBuilder.swift`,
`Timeline/OverlayIntervalIndex.swift`, `Evaluator/TimelineEvaluator.swift`,
`Project/ProjectValidator.swift`, `Project/ProjectValidationError.swift`,
`Project/CanonicalProjectManifest.swift`, `Codec/CanonicalProjectEncoding.swift`.
**Core — new:** `Time/Int128.swift`, `Project/MaterialAvailabilityValidator.swift`,
`Timeline/TransitionWindowIndex.swift`.
**Core — delete:** `Evaluator/EvaluationMaterialChecker.swift` (moved into the validator).
**TestSupport — edit:** `TemplateFixtureDescriptor.swift`, `CanonicalProjectFixtures.swift`.
**Tests — edit/new:** `ProjectValidationTests`, `TransitionAvailabilityTests`, `TimelineIndexTests`,
`EvaluationWindowBuilderTests`, `CanonicalProjectEncodingTests`, `OverlayIntervalIndexTests`,
`TemplateFixtureTests`, `RationalSourceTimeTests`, `EvaluationHarness`, plus new
`TransitionWindowIndexTests`, `RationalArithmeticTests`, and `APISurfaceTests` (symbol-graph
public-surface check).
**Docs — edit:** `AnimiEngineNext/Docs/ADR-002-...md` (Option-B `O(log n + k log k)` deviation),
`Docs/AnimiEngineNext/decision-register.md` (approved-deviation entry), this corrective plan.

## Forbidden-path confirmation

No files under `TVECore/`, `AnimiApp/`, `SceneSources/`, `*.xcodeproj`, or `*.pbxproj` are modified by
this corrective plan. No current product code is touched. All changes are confined to
`AnimiEngineNext/Sources/AnimiEngineCore/`, `AnimiEngineNext/Sources/AnimiEngineTestSupport/`,
`AnimiEngineNext/Tests/AnimiEngineCoreTests/`, `AnimiEngineNext/Docs/`, and `Docs/AnimiEngineNext/`.

## Stop rule

This is a plan only — Revision 3, FINAL CANDIDATE. No code is written, no test is added, and Task 003 is
not started until the technical lead explicitly approves this corrective plan. All nine review decisions
are now closed:

- (Rev 2) C-8 Option B approved; C-3 proven reduced-rational algorithm; C-4 non-forgeable family +
  builder material validation; two-site material validation; C-2 pure diagnostic counter; C-7 per-block
  selection + `loop` mapping.
- (Rev 3) material validation includes **global overlays** at both sites; **honest** non-forgeability
  guarantee (external non-`@testable` only; verified by symbol-graph, `SearchDiagnostics` internal); and
  **strict JSON typing** rejecting `Bool`/number and other Foundation bridging ambiguities.

No open decisions remain.
