# ADR-004 — Transition & Material Semantics

- **Status:** Drafted — realized in Task 002 (`claude-task-002-plan.md`, Revision 5).
- **Source decisions:** D-006, D-007, D-015, D-016, D-017.

## Context

Transitions must be honest: the outgoing scene keeps playing at normal speed, the incoming scene is
held until the boundary, and an animated transition that cannot be evaluated truthfully is rejected
rather than shortened or substituted with a cut.

## Decision

1. **Cut vs animated effects.** `.cut` is a hard change with duration zero. Animated effects (Fade,
   Slide in v1) require a strictly positive duration. Unsupported effect ids are typed errors.

2. **Exact parameter envelope and easing.** `TransitionEffect` carries a sorted, duplicate-free
   `TransitionParameterSet`. Fade accepts exactly the empty set in Task 002; Slide requires exactly
   one `direction` identifier in `left/right/up/down`. Missing/extra/duplicate/wrong-type parameters
   are typed errors. Easing is preserved verbatim into the `TransitionPlan`.

3. **Variable duration and odd-tick rule.** Each boundary has its own duration. The window is
   `[B − preHalf, B + postHalf)` with `preHalf = ⌊D/2⌋`, `postHalf = D − preHalf` — the extra odd
   tick belongs **after** B.

4. **Centered half-open window.** Progress is exact rational `(T − window.start)/D`, with
   `0 ≤ progress < 1`; `progress == 1` is never emitted (at `window.end` the incoming scene is sole).

5. **Unchanged project duration.** `projectDuration = Σ scene.nominalDuration`. Transition durations
   never change it.

6. **Outgoing post-roll at normal speed.** The outgoing scene time is `T − outgoingSceneStart` and
   continues past the nominal end at normal speed. Video is never frozen, clamped, slowed, or retimed.

7. **Hold-first incoming policy.** Before B the incoming scene time is the single value 0 (only the
   transition effect progresses); at/after B it is `T − B` and advances normally, continuing without a
   jump when the transition ends.

8. **Exact range-intersection availability.** Each layer is evaluated only over the intersection of
   the transition scene-interval with its own active range. For video, the first/last requested scene
   ticks (`start`, `end − 1`) map to min/max exact targets that must satisfy
   `trimRange.start ≤ target < trimRange.end`. No request is clamped to the trim range; images need no
   temporal material.

9. **Explicit `AnimationRequest`.** The evaluator emits `.sample/.looped/.holdLast/.inactive`; the
   half-open animation endpoint is never a fabricated "last time". `.becomeInactive` that would leave
   a still-visible layer without material is rejected (`unavailableAnimationContinuation`).

10. **No video clamp/freeze.** Timeline evaluation never produces a frozen or clamped outgoing frame.

11. **Adjacency rejection.** For a middle scene, `postHalf(prev) + preHalf(next) ≤ d`; otherwise the
    project would require an unsupported three-scene overlap and is rejected.

12. **Hierarchical scene-subplan composition.** A transition combines two completed `SceneSubplan`s
    (outgoing + incoming) into a `TransitionPlan`; global overlays composite above the body.
