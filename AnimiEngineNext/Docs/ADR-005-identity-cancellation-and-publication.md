# ADR-005 — Identity, Cancellation & Atomic Publication

- **Status:** Accepted — canonical contract; implementation remains evidence-gated.
- **Accepted:** 2026-06-25, under owner authorization to finalize the canonical architecture.
- **Source decisions:** D-015, D-106, D-107, D-108.
- **Depends on:** ADR-003 canonical time, ADR-004 transition semantics.
- **Required by:** ADR-006 scheduler/clock ownership, ADR-012 canonical audio.

## Context

The engine performs asynchronous evaluation, media decode, GPU rendering, audio decode, cache work and
export. A single untyped generation counter cannot distinguish a semantic project edit from a transport
seek, a source-frame request, a reusable cache artifact or an export job.

The visible result must never contain stale project content, resources from different transport epochs,
or media sampled at different project targets. Current experimental preview code may reuse a per-video
`lastGood` texture while other video layers advance. That creates a newly composed mixed-time frame and
is forbidden by the approved publication and overload rules.

## Decision

### 1. Separate typed identities

The runtime uses distinct value types for distinct lifetimes:

- `ProjectRevision` — one immutable semantic project snapshot. Any edit that can change evaluation,
  media selection, trim, placement, audio, text, transition, output or export result creates a new value.
- `PlaybackEpoch` — one uninterrupted transport interpretation. Play, pause, seek, scrub start, scrub
  settle, project-revision change, interruption, route change and recovery create a new value before new
  work is admitted.
- `FrameRequestID` — one requested complete composed frame at one exact `ProjectTime`.
- `MediaRequestID` — one timestamped request to one visual media source.
- `AudioRequestID` — one requested PCM source range for one audio source.
- `CacheArtifactID` — one reusable content-derived cache artifact.
- `ExportJobID` — one isolated offline export operation.
- `BenchmarkRunID` — one reproducible evidence run, as defined by ADR-014.

The types are not interchangeable and must not be aliases of a shared raw integer in public APIs.

### 2. Identity tuple on asynchronous work

Every asynchronous request and completion carries the identity required to validate its meaning:

```text
projectRevision
playbackEpoch          // preview only
requestID
exact project/source time or range
quality profile
dependency identity
```

Export work carries `ProjectRevision + ExportJobID` and never reuses a preview `PlaybackEpoch`.

Workers may produce values but never decide that a value is current. Only the serialized scheduler
defined by ADR-006 validates identities and admits a completion into further work.

### 3. Project revision versus cache identity

`ProjectRevision` identifies an immutable snapshot, not a request generation. `CacheArtifactID` is
content-derived and includes the semantic dependencies required by the cache contract: dependency hash,
time range, quality profile, render-semantics version and color configuration.

`PlaybackEpoch`, `FrameRequestID`, `MediaRequestID` and `AudioRequestID` are never part of reusable cache
identity. They prevent stale publication; they do not make equal content different.

### 4. Epoch invalidation

The scheduler creates a fresh `PlaybackEpoch` before admitting work for any transport discontinuity. It then:

1. stops accepting completions from the previous epoch;
2. cancels queued work cooperatively;
3. flushes audio buffers that have not reached the hardware boundary;
4. allows already-submitted GPU/decode work to finish only for safe resource reclamation;
5. records every discarded completion as stale evidence;
6. creates new requests only from the current immutable project revision.

Cancellation is an optimization. Correctness always comes from identity validation, because submitted
GPU, decoder and audio work may be non-cancellable.

### 5. Complete-frame publication token

A preview frame is publishable only as one immutable `PublishedFrame` carrying:

```text
ProjectRevision
PlaybackEpoch
FrameRequestID
ProjectTime
QualityProfileID
complete composed output
```

The visible output changes only after all of the following hold:

1. evaluation produced one complete `FramePlan` for the requested `ProjectTime`;
2. every required visual source resolved for that same plan and time;
3. every resource matches the active project revision and playback epoch;
4. the complete frame rendered successfully;
5. the scheduler revalidated every identity after rendering;
6. the composed output was atomically promoted to the front buffer.

The renderer returns a value to the scheduler. It never publishes directly and no callback mutates visible
state.

### 6. Forbidden partial and mixed-time output

The following are always forbidden:

- publishing one layer before the complete composition exists;
- combining resources from different `ProjectRevision` or `PlaybackEpoch` values;
- substituting a previous-time frame for one video layer while other layers advance;
- publishing a late frame after a newer frame for the same epoch was published;
- changing visible state from decoder, renderer, cache or audio callbacks;
- treating a request-generation number as reusable cache identity.

If one required source is not ready, the engine keeps the previously published **complete composed frame**.
It may later publish a newer complete frame or globally skip that output tick. It must not construct a new
frame from individually stale layers.

Preview quality substitution may change spatial quality, proxy level or cache source only when the
substitute represents the same requested project/source time. Temporal substitution is not a quality
fallback.

### 7. Latest-wins rules

- During active scrub, only the latest explicit target remains publishable. Intermediate targets may be
  cancelled or discarded.
- Exact settle is a barrier: the requested target must be evaluated and published exactly; it cannot be
  replaced by a nearby target.
- During playback, an obsolete late frame is discarded. The scheduler may request the newest eligible
  global frame-grid target, but all layers in the published frame use that target.
- During export, every output frame is evaluated. Latest-wins and frame skipping do not apply.

### 8. Audio-buffer admission

Decoded PCM ranges carry `ProjectRevision + PlaybackEpoch + AudioRequestID + AudioSourceID + exact sample
range`. The scheduler validates them before placing them in a preview source buffer. A discontinuity flushes
all not-yet-rendered ranges from the old epoch.

Audio already submitted to the device cannot be recalled. Preview therefore uses bounded scheduling
horizons and must never enqueue unbounded future audio. The audio render callback consumes only validated,
preallocated data and never performs project evaluation, file I/O, allocation, locking or logging.

### 9. Publication evidence

Diagnostics record the full request lifecycle:

- requested, admitted, decoded, rendered, rejected, cancelled and published;
- every identity and exact time/range;
- rejection reason, including stale revision, stale epoch, superseded target and missing dependency;
- previous and new published frame identities;
- audio range enqueue/consume/underrun events without logging from the realtime callback itself.

## Required tests

1. An edit invalidates all previous-revision preview work.
2. Play, pause, seek, scrub, settle, interruption and route change invalidate the previous epoch.
3. A stale decoder or GPU completion never changes visible output.
4. A six-video request publishes either one complete synchronized frame or nothing new.
5. A transition frame never combines outgoing/incoming resources from different epochs or targets.
6. Scrub coalescing publishes only the latest target; settle publishes the exact requested target.
7. Cache hits remain reusable across epochs when content identity is unchanged.
8. Old-epoch PCM never reaches the audio render buffer after seek or interruption.
9. Export identities remain isolated from preview cancellation.

## Consequences

- The runtime needs more identity values than the current experimental generation counters.
- Per-layer `lastGood` video reuse cannot be promoted into the canonical engine.
- Some GPU and decoder work will complete and be discarded after invalidation; this is expected.
- Atomic publication and exact settle become testable contracts rather than UI behavior inferred from
  callbacks.
