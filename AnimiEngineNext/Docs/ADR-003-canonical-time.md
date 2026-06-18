# ADR-003 — Canonical Time

- **Status:** Drafted — realized in Task 002 (`claude-task-002-plan.md`, Revision 5).
- **Source decisions:** D-013 (output grid), research-backed exact-time constraints.

## Context

The current engine compresses the timeline and freezes the outgoing frame during transitions. The
new engine must instead answer "what is active at exact project time `T`" with exact, reproducible
arithmetic — no floating point, no implicit frame rounding, no silent retiming.

## Decision

1. **240 000 project ticks per second.** Canonical project time is signed-storage `Int64` ticks at
   exactly `TickClock.ticksPerSecond = 240 000`. This makes every supported output rate have an exact
   integer ticks-per-frame.

2. **Separate instant / duration / local domains.** `ProjectTime` (instant), `TickDuration`
   (length), `ScenePlaybackTime`, `AnimationPlaybackTime`, `OverlayPlaybackTime`, and the signed
   `TransitionRelativeTime` are distinct types. The only cross-type arithmetic is type-directed
   (`ProjectTime + TickDuration → ProjectTime`, `ProjectTime − ProjectTime → TickDuration` when
   `left ≥ right`). Conversions between local domains are explicit.

3. **Exact supported frame rates.** `FrameRate.exactTicksPerFrame` is exact for 23.976, 24, 25,
   29.97, 30, 50, 59.94, 60 (e.g. 29.97 → 8008, 59.94 → 4004). An unsupported rate (non-integral
   ticks-per-frame) throws. `FrameIndex → ProjectTime` is exact; the reverse needs an explicit
   rounding policy and is never used implicitly.

4. **Normalized `RationalSourceTime`.** Source presentation time is an exact reduced rational
   (positive denominator, signed numerator). Equivalent fractions are equal; one project tick at rate
   1/1 is exactly `1/240000` s. The original asset timescale is retained separately in
   `SourceTimescale` and never used to round the rational target.

5. **Full-width exact comparison and checked rational arithmetic.** `Comparable` never throws and is
   exact via 128-bit cross products. Addition/multiplication apply GCD cross-cancellation before
   combining and throw a typed overflow error only if the final reduced rational cannot fit `Int64`.
   There is no `Decimal`/`Float`/`Double`/"widen on overflow" path.

6. **Exact `SourceTimeMapping`.** `target = a + (rn·s)/(rd·240000)`, a normalized exact rational,
   never rounded to `nativeTimescale`.

7. **Presentation-interval sample selection.** `SourceRequest` carries
   `SampleSelectionPolicy.presentationIntervalContainsTarget`. Actual sample-table lookup is deferred;
   Task 002 only emits the exact request.

8. **No implicit rounding or floating-point canonical state.** All canonical time and geometry are
   integer/rational; checked `Int64` arithmetic throws instead of trapping or wrapping.
