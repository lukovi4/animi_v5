# ADR-006: Scheduler and Master Clock Contract

- **Status:** Accepted — canonical contract; implementation remains evidence-gated.
- **Date:** 2026-06-24.
- **Accepted:** 2026-06-25, under owner authorization to finalize the canonical architecture.
- **Depends on:** ADR-003, ADR-005.

## Context

Preview must keep every visible video layer, transitions, overlays, and audio on one project timeline. The current app-level CP7.9 scheduler is useful evidence, but it is not the canonical runtime: it owns per-layer `lastGood` frames and can therefore publish a composition containing different project times.

The engine needs one explicit answer to four questions:

1. Which clock advances project time?
2. Who is allowed to request and publish a frame?
3. What happens when some work is late?
4. How are play, pause, scrub, interruption, and export kept deterministic?

## Decision

### 1. Single scheduler owner

One serialized `EngineScheduler` owns transport state, playback epoch, frame deadlines, request admission, cancellation, and publication. Decode, render, and audio workers execute bounded work but never advance transport time and never publish directly.

All asynchronous work carries the identity tuple defined by ADR-005. A result is admissible only when its project revision, playback epoch, request identity, and target time still match the scheduler's current state.

### 2. Transport state machine

The runtime has explicit states:

- `paused(at:)`
- `preparing(from:)`
- `playing(epoch:)`
- `scrubbing(target:)`
- `settling(target:)`
- `interrupted(at:)`
- `ended(at:)`
- `failed(error:)`

State transitions are serialized. There is no independent play/pause/scrub state inside individual video or audio sources.

`ProjectTime` remains the only canonical timeline coordinate. It uses the 240,000 ticks-per-second timebase established by ADR-003.

### 3. Master clock selection

The master clock is selected once when a playback epoch is prepared and is not changed during that epoch:

- If the remaining playback range contains any unmuted canonical audio, including audio that starts after an initial silent gap, the audio output render clock is master. The scheduler derives project time from `AVAudioTime` sample time anchored to the epoch's project start. Silent gaps and the end of the final source do not cause a clock switch.
- If the project has no canonical audio, an injected monotonic host clock is master.
- Pause, scrub, and settle do not have a progressing master clock. They hold an explicit `ProjectTime`.
- Export has no realtime master clock. It enumerates exact output frame and sample indices.

The engine must query the actual output format after audio-session/engine activation. Requested hardware sample rate and I/O duration are preferences, not facts. Conversion between the canonical mix grid and the device grid occurs only at the audio I/O boundary.

### 4. Exact time mapping

The canonical internal audio mix rate is 48,000 samples per second. With a 240,000-tick project timebase, one canonical sample is exactly five project ticks.

For the half-open project interval `[startTick, endTick)`, the canonical sample interval is:

```text
[ceil(startTick / 5), ceil(endTick / 5))
```

`ProjectTime` is non-negative: `ceilDiv5(t) = t / 5 + (t % 5 == 0 ? 0 : 1)`.
For any non-negative `Int64`, `t / 5 <= floor(Int64.max / 5) =
1_844_674_407_370_955_161`, so the `+ 1` yields at most
`1_844_674_407_370_955_162 < Int64.max`: **`ceilDiv5` cannot overflow** for a
non-negative input and need not be wrapped in checked arithmetic. (A negative
input is a typed domain error; all *other* time/rational arithmetic remains
checked and throws a typed overflow.) The resulting half-open sample interval is
the only canonical 48 kHz interval identity used by audio evaluation, buffering,
caches, diagnostics, and export. The interval **may be empty** (`start == end`)
when both endpoints ceil to the same sample; an empty interval is zero samples
(zero `AudioPlan` segments), not an error. Only `end < start` is invalid, and the
half-open project interval never produces it.

Frame time is derived from the master project time using the project's exact rational frame rate. Floating-point seconds are never used as canonical identity, cache keys, cancellation keys, or publication coordinates.

### 5. Playback start barrier

`play()` does not immediately advance time. `preparing` must first:

1. resolve one common future anchor for audio and video;
2. prepare the first complete composited frame at the requested project time;
3. prepare bounded audio preroll when the project has audio;
4. schedule audio against the common anchor;
5. publish the initial complete frame;
6. start the selected master clock and enter `playing`.

Audio must not become audible while the first video frame is still unresolved. Preparation has a bounded timeout and produces a typed failure; it cannot wait indefinitely.

### 6. Playback scheduling and publication

For every display opportunity, the scheduler derives one eligible frame-grid time from the master clock and creates one `FrameWorkset` for that exact project time. Every required video layer, transition input, overlay, effect, and render input belongs to that workset.

A workset is published only when the complete frame is ready and the ADR-005 publication token is still current.

If a workset misses its deadline:

- keep displaying the previously published complete composition;
- cancel or discard obsolete work;
- globally advance to the newest eligible frame-grid time;
- request a new complete workset for that time.

The scheduler must never combine a fresh layer with a per-layer `lastGood` frame, never wait synchronously on the main thread, and never slow or detach the audio clock to make a late video frame appear on time.

### 7. Scrub and settle

Scrub is silent by approved product decision.

During `scrubbing`, targets are latest-wins. Older requests are cancelled or made inadmissible by identity. Until the exact complete target frame is available, the engine keeps the previously published complete composition.

When the gesture ends, `settling` resolves one exact complete frame for the final target. The engine remains paused there. Playback resumes only after an explicit user `play()` action.

### 8. Audio continuity and underflow

Audio render deadlines have priority over speculative video decode and prefetch. The realtime audio callback may only consume prepared immutable buffers/state; it performs no file I/O, decode, allocation, blocking lock, logging, or scheduler mutation.

If required audio cannot be prepared safely, the engine transitions through a bounded rebuffer/pause or typed failure. It must not continue advancing the audio master while silently dropping required audio.

### 9. Backpressure and bounded concurrency

Every queue is bounded: admitted frame worksets, per-source decode requests, decoded surfaces, upload commands, audio chunks, and export work. When limits are reached, the scheduler rejects or cancels obsolete speculative work before accepting more.

Worker counts, queue depths, preroll, lookahead, and timeout values are runtime configuration selected by measured device-class evidence. They are not architectural constants and must not be hardcoded into feature code.

Main-thread responsibilities are limited to UI input, transport commands, and presentation handoff. Asset I/O, decode, graph evaluation, rendering, and audio preparation run off the main thread.

### 10. Global degradation policy

Degradation is global for the published composition, never per-layer temporal drift. The ordered policy is:

1. use prepared proxies/caches and lower spatial decode/render quality;
2. reduce the whole preview cadence from the requested rate to an evidence-approved tier such as 30, then 24, then 15 fps;
3. rebuffer/pause or report an explicit unsupported workload when continuity cannot be maintained.

The exact tiers and thresholds require device evidence. Export never uses preview degradation.

### 11. Interruption and route change

An audio interruption or relevant route change pauses transport at the last confirmed project time, invalidates the playback epoch, flushes scheduled realtime work, and enters `interrupted` or `paused`.

The engine never auto-resumes. The user must press play, which creates a new preparation barrier and playback epoch.

### 12. Export isolation

Export uses the same canonical manifest evaluation, render graph, and audio plan, but runs in a separate offline execution context. It enumerates every required frame and sample interval and cannot borrow realtime scheduler state, preview caches with incompatible provenance, preview degradation, or the device clock.

## Required diagnostics

At minimum, diagnostics must expose:

- project revision and playback epoch;
- master-clock kind, anchor, actual sample rate, and current project time;
- frame target, deadline, completion, publication, cancellation, and global skip reason;
- bounded-queue occupancy and backpressure decisions;
- audio preroll, render starvation, and underrun counters;
- selected preview cadence and degradation reason;
- interruption, route-change, pause, and resume transitions.

Production diagnostics must remain bounded and must not perform work on the realtime audio callback.

## Verification gates

The implementation is not accepted until tests and evidence cover:

- exact tick/sample/frame mapping, including non-frame-aligned seeks;
- stale revision/epoch/request rejection at every publication boundary;
- no mixed-time publication under injected late and failed layers;
- playback start barrier and bounded timeout;
- latest-wins silent scrub and exact settle;
- pause/resume and interruption without automatic resume;
- audio-master and monotonic-master projects;
- global frame skipping/degradation without per-layer drift;
- bounded memory and queue depth under 6, 10, and 20 simultaneous video sources;
- physical-device A/V sync, audio-underrun, frame-pacing, memory, and thermal evidence;
- offline export independence from realtime clock and degradation.

## Migration note

The CP7.9 app scheduler remains a prototype/evidence harness until it is replaced by this engine-owned contract. Its per-layer `lastGood` fallback is explicitly non-canonical and cannot be promoted into the public engine runtime.

## Consequences

- Audio, when present, gives preview one stable high-resolution clock.
- Late video produces a repeated complete composition or a global frame skip, not spatially inconsistent time.
- Scrub behavior is deterministic and silent.
- Preview tuning remains configurable and evidence-driven.
- Export retains exact offline semantics instead of inheriting realtime compromises.

## References

- Apple, [`AVAudioTime`](https://developer.apple.com/documentation/avfaudio/avaudiotime)
- Apple, [`AVAudioSession.preferredSampleRate`](https://developer.apple.com/documentation/avfaudio/avaudiosession/preferredsamplerate)
- Apple, [Responding to audio route changes](https://developer.apple.com/documentation/avfaudio/responding-to-audio-route-changes)
