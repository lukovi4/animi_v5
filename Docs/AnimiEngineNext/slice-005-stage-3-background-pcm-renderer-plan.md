# Slice 005 Stage 3 — Background / Offline PCM Renderer Plan

Status: **PLAN ONLY — no code yet.** This document is the implementation contract for the real
background/offline PCM renderer that produces `CanonicalPCMChunk` for canonical preview audio. No
production or test code is created by this task; nothing is wired into the controller/factory (that is
Stage 4 in this slice's wiring sense — see §11).

## 0. Where Stage 3 sits (accepted predecessors)

- **Stage 0 (accepted):** architecture guards (`CanonicalAudioArchitectureTests`) ban the deleted live
  decoder path (`PCMDecoder`, `AVAssetReaderPCMDecoder`, `AppAudioChunkPreparer`) and ban `AVAssetReader(` /
  `copyNextSampleBuffer` in the Realtime preview path (comment-stripped scan).
- **Stage 1 (accepted):** `CanonicalPCMRenderKey` / `CanonicalPCMChunk` / `CanonicalPCMRenderer` /
  `CanonicalPCMRenderCache`. Cache validates `chunk.key == requestedKey`, fail-closed capacity, coalescing,
  token-based stale-completion rejection, never caches failures.
- **Stage 2 (accepted):** `CachedCanonicalAudioRenderPipeline` routes
  `CanonicalAudioRenderPipeline.prepareInitialPreroll` → `CanonicalPCMRenderKey` →
  `CanonicalPCMRenderCache.chunk` → `[PreviewMixSource]`, with collision-safe (length-prefixed)
  `CanonicalAudioPlanIdentity`. Empty plan → `[]` without touching the renderer.

The only missing piece is a **real** `CanonicalPCMRenderer` (today only `UnavailableCanonicalAudioRenderPipeline`
and test fakes exist). Stage 3 implements it.

### Naming reconciliation with the master implementation plan

The master `canonical-audio-preview-export-implementation-plan.md` splits this work into its own "Stage 3"
(pure source→PCM renderer behind an **injected fixture decoder** — no AVFoundation) and "Stage 4" (the real
`AVFoundation` decoder behind that protocol). This task brief calls the whole thing "Stage 3 — real
background/offline PCM renderer."

**Resolution adopted here:** keep the master plan's architecturally-correct decoder seam — a
`CanonicalPCMAssetDecoder` protocol — and deliver, under this brief's "Stage 3," BOTH:

1. the decode-free source→PCM renderer (`BackgroundCanonicalPCMRenderer`) unit-tested with a fixture
   decoder on the simulator, and
2. the real `AVFoundation` decoder (`AVFoundationPCMAssetDecoder`) behind the protocol, **device-gated**.

This satisfies the brief's point 8 ("separate simulator unit tests for contract/fakes from device-only
smoke for real compressed mp3/mp4") while preserving the seam that makes the renderer testable without
compressed-media decode in CI/simulator.

---

## 1. Renderer ownership and file layout

All new production files live under `AnimiApp/Sources/EditorRuntime/Realtime/` (app-side only — never in
`AnimiEngineCore`, never in export, never in legacy audio).

**Production files** (`AnimiApp/Sources/EditorRuntime/Realtime/`):

| File | Responsibility |
|---|---|
| `CanonicalPCMAssetDecoder.swift` | **Protocol + request/response value types ONLY.** Declares the bounded raw-PCM decode seam (decode of ONE source sub-window → `[Float32]` mono 48 kHz) and its input/output value types. NO concrete decoder. NO AVFoundation. NO fixture. |
| `BackgroundCanonicalPCMRenderer.swift` | The `CanonicalPCMRenderer` implementation: pure segment→source math (intersect range, exact rational source-start, frame counts), calls the injected `CanonicalPCMAssetDecoder`, assembles `[PreviewMixSource]` and the `CanonicalPCMChunk`. NO AVFoundation import. |
| `AVFoundationPCMAssetDecoder.swift` | The real `CanonicalPCMAssetDecoder`: the ONLY file in the slice allowed to `import AVFoundation` and use `AVURLAsset` / `AVAssetReader` / `AVAssetReaderTrackOutput` / `copyNextSampleBuffer`. Owns the `AVAssetReader` lifetime; bounded `timeRange`; async property loading; **hard watchdog `cancelReading()`** (see §3); typed timeout. |
| `CanonicalPCMRenderSourceResolver.swift` | (Only if needed) maps an `AudioSegmentPlan.sourceID` → `CanonicalResolvedAudioSource` URL using `request.resolvedSourcesByID`, fail-closed on missing/ambiguous. May instead be a small helper inside the renderer if it stays trivial. |
| `CanonicalPCMRenderDiagnostics.swift` | (Only if needed) the typed diagnostic event names + a thin emit helper, so the renderer and decoder emit a consistent, test-assertable vocabulary. May instead be string constants on the renderer if trivial. |

**Test-only files** (`AnimiApp/Tests/` — NOT production):

| File | Responsibility |
|---|---|
| `FixtureCanonicalPCMAssetDecoder` (in `BackgroundCanonicalPCMRendererTests.swift`, or a small shared test helper) | The deterministic fixture `CanonicalPCMAssetDecoder` used by simulator unit tests: returns ramps/constants of the requested length, can be configured to throw typed errors, and can gate/block for the timeout/cancellation tests. **Lives in tests only — never shipped in a production file.** |

**Default decision:** create production files `CanonicalPCMAssetDecoder.swift` (protocol + value types only),
`BackgroundCanonicalPCMRenderer.swift`, `AVFoundationPCMAssetDecoder.swift`. The fixture decoder is a
TEST type, defined in the Stage-3 test target. Fold the resolver into the renderer and diagnostics into
string constants UNLESS they exceed ~15 lines, in which case promote to their own files. (Keeps the file
count honest; no speculative files.)

---

## 2. Decode / render strategy (final, justified)

**Chosen strategy: offline bounded decode behind an injected `CanonicalPCMAssetDecoder`, performed in a
background `Task` before audible start, producing exactly the requested `AudioSampleRange`.**

Flow for one `render(request)`:

1. If `request.plan.segments.isEmpty` → this is unreachable in production (the Stage-2 pipeline already
   short-circuits empty plans to `[]` before calling the cache/renderer). Defensive: return a chunk with
   `sources: []` (the cache accepts it; identity gate still holds). Documented, tested.
2. For each `AudioSegmentPlan` in `request.plan.segments` (order preserved):
   - **Intersect** `segment.destinationSamples` with `request.range` (both half-open 48 kHz). If the
     intersection is empty, the segment contributes nothing to this bounded chunk → skip it (it is not an
     error; a segment can lie entirely outside the requested window).
   - The intersection is the **bounded destination sub-range** `[dStart, dEnd)` for this segment in this
     chunk; `frameCount = dEnd - dStart`.
   - Compute the **exact source start** for `dStart` using exact rational math:
     `sourceStartForChunk = segment.sourceStart + (dStart - segment.destinationSamples.start) samples`,
     advanced on the source timeline via `RationalSourceTime` (NO `Double`, NO µs truncation). The advance
     is `(dStart - destStart) / 48000` seconds added to `segment.sourceStart`.
   - Call `decoder.decode(source:, sourceStart: sourceStartForChunk, frameCount: frameCount)` → `[Float32]`
     of length **exactly** `frameCount` (mono, 48 kHz, raw — pre-gain, pre-mute, pre-mix).
   - Build a `PreparedAudioBuffer` whose `chunkRange` is **`request.range`** (the chunk's bounded range, per
     the Stage-1 `CanonicalPCMChunk` contract that every source's `buffer.chunkRange == key.range`) — see
     §4 for the exact-range reconciliation when a segment only partially overlaps the chunk.
   - Wrap as a `PreviewMixSource(buffer:, samples:)`.
3. Assemble `CanonicalPCMChunk(key: requestedKey, sources: builtSources)` and return it. The cache validates
   `chunk.key == requestedKey`.

Why this strategy:

- **Bounded:** decode is limited to the requested `AudioSampleRange` (the cache's bounded chunk), never the
  whole project. This is the single most important property — it caps wall-clock and memory per render.
- **Offline / off the Play path:** the renderer runs inside the Stage-2 pipeline's `async` call, which the
  controller awaits as a preroll **before** crossing the first-frame start barrier — it is not a synchronous
  dependency of the realtime callback.
- **Global music + video-original:** both are just `AudioSegmentPlan`s carrying a `sourceID`; the renderer
  resolves each via `request.resolvedSourcesByID` and decodes identically. No special-casing of video vs.
  music at the decode layer.
- **Testable without compressed decode:** a TEST-ONLY fixture decoder satisfies the protocol
  deterministically in the simulator; only `AVFoundationPCMAssetDecoder` touches real media. Real
  compressed decode is **device-gated** if simulator `AVAssetReader` proves unreliable (see §5/§8/§10). Stage
  3 unit-tests the renderer contract with the fixture decoder and makes **no audible/device success claim.**

Rejected alternatives:

- **Whole-project temp CAF preview** — banned (unbounded, slow, was a device-hang contributor).
- **`AVMutableComposition` in the preview renderer** — not justified; per-source bounded decode is simpler
  and avoids composition graph cost. (Composition stays an export-only concern.)
- **Live decode in `startPlayback`** — banned by Stage 0 guards and the prior device failure.

---

## 3. Threading / actor model

- **AVFoundation work runs OFF the main actor, inside `AVFoundationPCMAssetDecoder`**, in a plain `async`
  context (a detached background `Task` is created by the cache's coalescing `Task { renderer.render(...) }`,
  Stage 1). The decoder is a `Sendable` value/`final class` with `nonisolated` async methods; nothing in the
  decode path is `@MainActor`.
- **`BackgroundCanonicalPCMRenderer` is `Sendable` and non-isolated.** It performs only integer/rational
  math + array assembly + `await decoder.decode(...)`. No actor hop to main.
- **MainActor avoidance:** the ONLY `@MainActor` surface is the optional `onDiagnostic` closure in
  `CanonicalAudioRenderPipeline.prepareInitialPreroll`; the renderer protocol's `render(_:)` has NO
  MainActor parameter, so the decode path cannot accidentally hop to main. Diagnostics, if emitted from the
  renderer, are `await onDiagnostic?(...)` hops that carry only `String`s and happen between decode steps —
  never inside a sample copy loop.
- **Hard watchdog / cancellation model (P0 — the real device fix):**
  `Task.checkCancellation()` between reads is **NOT sufficient**, because a single
  `reader.copyNextSampleBuffer()` call can itself block inside AVFoundation (waiting on I/O / decode) BEFORE
  control returns to the loop to check cancellation. That in-call block was the actual prior device hang.
  The decoder therefore enforces a hard, externally-driven watchdog:
  1. **The `AVFoundationPCMAssetDecoder` owns the `AVAssetReader` lifetime** for one decode (creates it,
     starts it, holds the reference, and is the only thing that may cancel/finish it).
  2. **The read loop (`copyNextSampleBuffer`) runs off-main** on a dedicated background executor/`Task` (the
     "reader task").
  3. **A separate watchdog/cancellation path** — a sibling `Task` (the "deadline task") and the structured
     cancellation hook — calls **`reader.cancelReading()`** when the timeout fires OR when the enclosing
     render `Task` is cancelled/invalidated. `cancelReading()` makes the in-flight (or next)
     `copyNextSampleBuffer()` return `nil` / makes the reader status `.cancelled`, which UNBLOCKS the reader
     task even if it was parked inside the AV call. (This is the only reliable way to interrupt a blocked
     `copyNextSampleBuffer` — checking a flag the blocked thread can't reach does nothing.)
  4. **No hidden blocked task may later store success.** The two paths are joined so the decode resolves to
     exactly one outcome: success (full bounded buffer) OR a typed throw (timeout/cancel/failure). On the
     timeout/cancel branch the decoder observes the reader's `.cancelled` status and **throws** — it does not
     return a partial/late buffer. Concretely: the deadline task and reader task are raced (e.g. a
     `withThrowingTaskGroup` / `withTaskCancellationHandler` that cancels the reader); whichever loses is
     cancelled, and `cancelReading()` guarantees the reader task cannot keep running after the deadline and
     resolve late into a stored chunk.
  5. **The renderer/cache receive a typed throw, never `[]`.** Timeout → `pcmRenderFailed(reason: "decode
     timeout …")` (or a dedicated typed timeout case); cancel → `CancellationError`. Both propagate up; the
     Stage-1 cache never caches a failure, and the Stage-2 pipeline never converts a non-empty plan to
     silence.
  6. **Even if a late completion somehow escapes** (e.g. the reader task finishes a microsecond after the
     deadline throw), the Stage-1 cache's token gate + invalidation drop it: the in-flight token no longer
     matches, so the late chunk is **not stored**. This is defense-in-depth on top of (4).
- **Result return path:** `decoder.decode → [Float32]` → renderer assembles `CanonicalPCMChunk` → returns
  from `render(_:)` → the cache's coalescing task resolves → the cache applies the `chunk.key == key` gate
  and stores (only if the in-flight token still matches; invalidation drops stale completions, Stage 1).
- **Why this cannot recreate the device hang:** the previous hang chain was *(a)* synchronous compressed
  decode/track-loading on the main thread during `startPlayback`, *(b)* an unbounded `copyNextSampleBuffer`
  loop with no way to interrupt an in-call block, *(c)* a watchdog that fired and produced silence. Stage 3:
  *(a)* decode is async + off-main and runs as a preroll the controller awaits before audible start, not
  synchronously inside the callback; *(b)* the read loop is bounded by the requested `AudioSampleRange` AND a
  blocked `copyNextSampleBuffer` is forcibly interrupted by `reader.cancelReading()` from the watchdog path
  (not merely a between-reads flag check); *(c)* on timeout/failure the renderer **throws**
  (`pcmRenderFailed`) so a non-empty plan fails visibly — it is NOT silently converted to silence (Stage 2
  fail-closed contract).

---

## 4. Exact renderer contract

```swift
// BackgroundCanonicalPCMRenderer: CanonicalPCMRenderer
func render(_ request: CanonicalAudioRenderRequest) async throws -> CanonicalPCMChunk
```

**Input validation (fail-closed, typed):**

- The requested key is rebuilt by the renderer EXACTLY as the Stage-2 pipeline does
  (`revision`, `epoch`, `CanonicalAudioPlanIdentity.string(for: request.plan)`, `request.range`) so the
  returned `chunk.key` equals the cache's requested key. (The renderer does not receive the key directly —
  the Stage-1 `CanonicalPCMRenderer.render` signature takes only the request — so it recomputes the
  identity deterministically. This is the same approach the Stage-2 tests' echo renderers use.)
- Each audible segment's `sourceID` MUST resolve in `request.resolvedSourcesByID`; missing →
  `AppRealtimeAudioIntegrationError.mediaUnavailable(sourceRaw:)`.
- `request.range` must be non-empty (the cache/`PreparedAudioBuffer` reject empty ranges already).

**Bounded range only:**

- Decode is intersected with `request.range`. No segment causes a read outside `[request.range.start,
  request.range.end)`. No whole-project read, no whole-source read.

**Exact frame count:**

- For each contributing segment, the decoder is asked for EXACTLY `frameCount` frames and MUST return an
  array of exactly that length. A short/long buffer → typed failure (`pcmRenderFailed(reason:)`) — NO
  implicit zero-pad unless an explicit, separately-approved zero-pad policy is added (out of Stage-3 scope).

**Chunk / source range reconciliation (decision):**

- Stage-1 `CanonicalPCMChunk.init` requires `source.buffer.chunkRange == key.range` for EVERY source.
- A segment may only partially overlap `request.range`. To honor the exact-range invariant, the renderer
  produces, per contributing segment, a `PreviewMixSource` whose `buffer.chunkRange == request.range` and
  whose `samples` array has length `request.range.sampleCount`, **zero-filled outside the segment's
  intersection** and carrying decoded frames inside it. (Zero outside the segment is silence for THAT
  source over the part of the chunk it does not cover — this is mix-correct: the graph sums sources.)
  - This zero-fill is **structural framing to the bounded chunk**, NOT the banned "non-empty plan →
    silence" behavior: the decoded region carries real samples; only the non-overlapping remainder of the
    bounded window is zero, exactly as that source is genuinely silent there.
  - Alternative considered: relax the Stage-1 invariant to allow sub-range sources. **Rejected** — it would
    weaken an accepted Stage-1 guarantee and the mismatch gate. Zero-framing keeps Stage 1 untouched.

**No whole-project temp CAF:** none produced, ever.

**No live-play dependency:** `render(_:)` has no reference to the controller, the graph, the session, or
`startPlayback`. It is pure (plan + resolved URLs) → chunk.

**Gain / mute handling:**

- The renderer decodes **raw** source samples (pre-gain, pre-mute, pre-mix, pre-output-stage). It carries
  `isMuted` / `gain` / `streamIdentity` / `sourceSampleRate` / `channelLayout` into each
  `PreparedAudioBuffer` (metadata), but does NOT apply them. `PreviewAudioGraph` remains responsible for
  gain, mute, summation, and the post-mix `OutputOverloadStage` (per ADR-006 / the accepted Stage-1 buffer
  contract). No final limiting in the renderer.

**Failure modes (all typed, none silent):**

| Condition | Error |
|---|---|
| Source URL not resolvable | `.mediaUnavailable(sourceRaw:)` |
| Source unreadable / corrupt | `.mediaCorrupt(sourceRaw:, detail:)` |
| Unsupported source shape (no audio track, etc.) | `.mediaUnsupported(sourceRaw:, detail:)` |
| Decoder returned wrong frame count | `.pcmRenderFailed(reason:)` |
| Decode timed out | `.pcmRenderFailed(reason: "decode timeout …")` (or a dedicated typed timeout case if added) |
| Cancelled | Swift `CancellationError` propagates; cache does NOT store (Stage 1) |
| Source-time advance overflow | `.sourceStartNotRepresentable(detail:)` |

A non-empty plan that hits any of these **throws** → Stage-2 pipeline propagates → controller routes to its
canonical-unavailable / legacy fallback. Never `[]`.

---

## 5. AVFoundation boundary

**Allowed — ONLY inside `AVFoundationPCMAssetDecoder.swift`:**

- `import AVFoundation`
- `AVURLAsset(url:options:)`
- async property/track loading (`load(.tracks)`, `loadTracks(withMediaType: .audio)`, `load(.duration)` —
  the modern async `load(_:)` API; NO synchronous `tracks` / `statusOfValue(forKey:error:)` on main).
- `AVAssetReader` + `AVAssetReaderTrackOutput` (or `AVAssetReaderAudioMixOutput` if multi-track mixing for a
  single source is ever required — default is `AVAssetReaderTrackOutput` on the single audio track).
- `reader.cancelReading()` — **REQUIRED** as the hard interrupt for a blocked/over-deadline read, called
  from the watchdog/cancellation path (§3), NOT from the reader loop itself.
- bounded `reader.timeRange = CMTimeRange(...)` derived from the requested source sub-window.
- `copyNextSampleBuffer()` in a loop **bounded** by `timeRange`, by the target `frameCount`, AND made
  interruptible by `reader.cancelReading()` from the watchdog path (a blocked `copyNextSampleBuffer` is
  unblocked by `cancelReading()` — between-reads `Task.checkCancellation()` alone is INSUFFICIENT, see §3).
- Output settings: Linear PCM, `Float32`, mono, 48 kHz (`AVLinearPCMBitDepthKey: 32`,
  `AVLinearPCMIsFloatKey: true`, `AVNumberOfChannelsKey: 1`, `AVSampleRateKey: 48000`,
  non-interleaved/standard) so the decoder output already matches the canonical preview domain.

**Explicitly BANNED (enforced by guards + review):**

- `copyNextSampleBuffer` on the main actor / `@MainActor` — the read loop must be non-isolated/background.
- A read loop whose ONLY interrupt is a between-reads cancellation flag / `Task.checkCancellation()` with no
  `reader.cancelReading()` watchdog (it cannot interrupt an in-call block — this WAS the device failure).
- A timeout that abandons the reader task without `cancelReading()` (leaves a hidden blocked task that could
  complete late and store success).
- Unbounded or whole-project read during Play (no read whose range is the whole asset/project).
- Temp CAF (or any temp file) as a preview dependency.
- `AVMutableComposition` in the preview renderer (no justification in Stage 3).
- Any AVFoundation symbol in `BackgroundCanonicalPCMRenderer.swift`, `CanonicalPCMAssetDecoder.swift`, the
  controller, the factory, or the play path. `AVFoundationPCMAssetDecoder.swift` is the sole AV boundary.

---

## 6. Device-risk analysis (prior failure chain → mitigation)

| Prior failure | Stage-3 mitigation |
|---|---|
| **Live decode blocked the device** (decode ran on the Play critical path) | Decode runs as an awaited **preroll** off the Play path, inside an async `Task`, before the first-frame start barrier. The realtime callback never decodes. |
| **Sync track/property loading blocked** (main-thread `tracks`/`statusOfValue`) | Only the async `load(_:)` API, off-main. No synchronous property access anywhere. |
| **`copyNextSampleBuffer` BLOCKED INSIDE the AV call** (a single call parks on I/O/decode before the loop can re-check cancellation — the real prior hang) | A separate watchdog/cancellation path calls **`reader.cancelReading()`** on timeout/cancel, which forces the blocked `copyNextSampleBuffer` to return `nil` / the reader to `.cancelled`, UNBLOCKING the reader task. A between-reads flag alone could not do this. The loop lives in the background decoder, never in the play path. |
| **Timeout left a hidden blocked decode task that completed late and stored success** | The reader task and deadline task are joined so decode resolves to exactly ONE outcome; the timeout/cancel branch `cancelReading()`s the reader and **throws** — no partial/late buffer is returned. Defense-in-depth: even a late escape is dropped by the Stage-1 token gate / invalidation (not stored). |
| **Watchdog produced silence** (timeout → silent fallback hid the failure) | On timeout/failure the renderer **throws** `pcmRenderFailed`; the Stage-2 fail-closed pipeline surfaces it (legacy fallback / typed unavailable), never silent for non-empty audio. |
| **Memory blow-up from whole-project decode** | Bounded per-`AudioSampleRange` decode caps memory; chunk size is already bounded by `CanonicalPreviewAudioControllerFactory.maxChunkSamples` (≤ 1 s @ 48 kHz) upstream. |

Residual device risk: real compressed-media decode timing/format quirks (variable container headers, gapless
padding, sample-rate conversion edge cases). These are addressed by the timeout, exact-frame-count
validation, and **device-only smoke** (§8) — they are NOT claimed by simulator unit tests.

---

## 7. Cache integration

The renderer composes with the accepted Stage-1/2 pieces with **no changes** to them:

- `CanonicalPCMRenderKey` — the renderer recomputes the identity (`CanonicalAudioPlanIdentity`) so its
  returned `chunk.key` equals the cache's requested key; the cache's `chunk.key == key` gate validates it.
- `CanonicalPCMChunk` — the renderer returns one chunk per request; `range == key.range`; every source's
  `buffer.chunkRange == key.range` (via the §4 zero-framing).
- `CanonicalPCMRenderCache` — receives `BackgroundCanonicalPCMRenderer` via `make(capacity:renderer:)`.
  Coalescing, eviction, invalidation, failure-not-cached, stale-drop all continue to hold (renderer is just
  the injected `CanonicalPCMRenderer`).
- `CachedCanonicalAudioRenderPipeline` — unchanged; it already calls `cache.chunk(for:key:)`. Production
  would construct `CachedCanonicalAudioRenderPipeline(cache: CanonicalPCMRenderCache.make(capacity:…,
  renderer: BackgroundCanonicalPCMRenderer(decoder: AVFoundationPCMAssetDecoder())))` — but **this
  construction wiring is Stage 4 (controller/factory), NOT Stage 3.** Stage 3 only delivers the renderer +
  decoder types and their unit tests; it does not change the factory.

---

## 8. Tests

### Simulator unit tests (contract + fakes) — `BackgroundCanonicalPCMRendererTests`

Use the **test-only** `FixtureCanonicalPCMAssetDecoder` (defined in the test target — NOT a production
file): returns deterministic ramps/constants of the requested length, can be configured to throw typed
errors, and can GATE/BLOCK (via a continuation) to simulate a slow/blocked decode for the watchdog tests.
Use public allocators + the same fixture helpers as Stage 2.

1. `testRendererRejectsMissingSource` — segment's `sourceID` absent from `resolvedSourcesByID` →
   `.mediaUnavailable`.
2. `testRendererRejectsUnsupportedSource` — fixture decoder configured to throw `.mediaUnsupported` →
   propagated typed.
3. `testRendererReturnsExactFrameCount` — single segment spanning the chunk → one source whose
   `samples.count == request.range.sampleCount` and `buffer.chunkRange == request.range`.
4. `testRendererReturnsChunkKeyEqualToRequestedKey` — `chunk.key == pipelineKey(for: request)`.
5. `testRendererBoundedRangeOnly_noWholeProject` — assert the fixture decoder was asked ONLY for
   `frameCount == intersection length` (spy records requested frame counts); never the whole source/project.
6. `testMusicOnlyRendersOneSource` / `testVideoOriginalRendersOneSource` /
   `testMusicPlusVideoRendersTwoSources` — segment-count → source-count mapping.
7. `testSourceStartAtSegmentStartIsExact` and `testInteriorOffsetIsExactRational` — assert the source-start
   handed to the decoder is the exact `RationalSourceTime` (no `Double`, no µs truncation).
8. `testPartialOverlapZeroFramesOutsideSegment` — a segment overlapping only part of `request.range`
   produces a full-length source array, zeros outside the intersection, decoded frames inside.
9. `testShortDecodeBufferFailsClosed` — fixture returns wrong length → `.pcmRenderFailed`, no chunk.
10. `testGainMuteCarriedNotApplied` — `buffer.isMuted` / `buffer.gain` equal the segment's; samples are raw
    (unscaled) — the renderer did not pre-apply gain/mute.
11. `testCancellationDoesNotCacheSuccess` — drive through the cache with a gated fixture decoder; cancel /
    invalidate mid-render → cache stores nothing (reuses the Stage-1 stale-drop guarantee).
12. `testNoMainActorDecode` — the renderer/decoder `render`/`decode` are callable from a non-main context
    (compile-level: no `@MainActor`); assert via a `nonisolated`/detached `Task` test that completes.

### Watchdog / timeout (P0) — `AVFoundationPCMAssetDecoderWatchdogTests` (with a spy/blocking reader seam)

The real decoder's watchdog is unit-tested without compressed media by injecting a **reader seam**: a
protocol abstracting "produce next bounded buffer" + "cancelReading()" so a test spy can BLOCK the read and
record `cancelReading()` calls. (The same seam lets `AVFoundationPCMAssetDecoder` wrap the real
`AVAssetReader`; the spy stands in for it.) These tests prove the timeout/cancel contract independent of
AVFoundation.

13. `testDecoderTimeoutThrowsTyped` — spy reader blocks forever; the decoder's deadline fires →
    `render`/`decode` throws `pcmRenderFailed` (timeout) — never returns `[]`, never hangs the test.
14. `testTimeoutPathCallsCancelReading` — on timeout, the spy records that `cancelReading()` (the cancel
    hook) WAS called from the watchdog path (proves the blocked read is forcibly interrupted, not just
    flagged).
15. `testExternalCancellationCallsCancelReading` — cancel the enclosing render `Task` while the spy reader is
    blocked → `cancelReading()` called, `CancellationError`/typed throw propagates.
16. `testCacheStoresNothingAfterTimeout` — drive the blocking decoder THROUGH `CanonicalPCMRenderCache`;
    after the timeout throw, `cache.count == 0` (failure not cached) and a later non-blocking render renders
    again and stores.
17. `testLateCompletionAfterTimeoutOrInvalidationIsDropped` — let the spy reader "complete" AFTER the
    timeout/invalidation (simulate a late escape): the cache must NOT store the late chunk (Stage-1 token
    gate / invalidation drop), and the original call still observed the typed throw.
18. `testNoHiddenBlockedTaskSurvivesTimeout` — after a timeout, assert the decoder/reader task is resolved
    (cancelled), not left running — e.g. the spy observes exactly one terminal transition and no post-deadline
    sample delivery into a stored chunk.

### Architecture / static guards (extend `CanonicalAudioArchitectureTests`)

19. `testBackgroundRendererIsDecodeFree` — `BackgroundCanonicalPCMRenderer.swift` AND
    `CanonicalPCMAssetDecoder.swift` (comment-stripped) have NO `import AVFoundation`, NO `AVAssetReader(`,
    NO `copyNextSampleBuffer`, NO deleted decoder type names.
20. `testAVFoundationDecodeConfinedToDecoderFile` — `AVAssetReader(` / `copyNextSampleBuffer` /
    `cancelReading` / `import AVFoundation` appear ONLY in `AVFoundationPCMAssetDecoder.swift` within the
    Realtime dir (allow-list of exactly one file), and NOT in the controller/factory/play-path files.
21. The existing `testRealtimePreviewPathDoesNotCallLiveAVAssetReader` must be **updated** to allow-list
    EXACTLY `AVFoundationPCMAssetDecoder.swift` (the sanctioned boundary) while still banning the
    constructor/loop everywhere else in the Realtime directory. (Today it scans the whole dir; it will need
    to exclude the one sanctioned decoder file — and only that file.)

### Device-only smoke (NOT a simulator unit test) — documented, gated

22. Real compressed decode (`.mp3` music, `.mp4` video-original) on an iPhone: prewarm renders a bounded
    chunk, exact frame count, app stays responsive, no SIGKILL, no indefinite hang (timeout is typed). The
    watchdog path is exercised on a deliberately slow/large source to confirm `cancelReading()` interrupts a
    real blocked read. Captured as device-gate evidence (like `slice-005-device-gate-evidence.md`), NOT
    claimed by CI.

**Real-decode coverage is device-gated.** If, and only if, a small deterministic compressed fixture (tiny
`.m4a`) proves reliable under simulator `AVAssetReader`, a single `AVFoundationPCMAssetDecoderTests` smoke
MAY also run in the simulator; otherwise the real decoder's compressed-media path is **device-gated only**.
The watchdog/timeout contract (tests 13–18) is ALWAYS unit-tested in the simulator via the spy reader seam —
it does not depend on real compressed decode. Stage 3 makes **no audible/device success claim** from
simulator tests. The simulator-fixture decision is explicitly logged, never silently skipped.

---

## 9. STOP conditions (hard)

Implementation must STOP and surface to the owner (no workaround) if ANY of these is hit:

1. Implementation would require live decode (or any `AVAssetReader`/`copyNextSampleBuffer`) inside
   `CanonicalPreviewAudioController.startPlayback` / the realtime callback / the play critical path.
2. The renderer cannot bound decode by the requested `AudioSampleRange` (i.e. it would need a whole-source
   or whole-project read).
3. AVFoundation forces a `@MainActor` copy loop (e.g. an API that can only be driven on the main thread).
4. Any design that would route NON-EMPTY audio to silence (timeout/failure → `[]` instead of throw).
4a. The decode loop CANNOT be hard-interrupted by `reader.cancelReading()` from a watchdog path (i.e. a
   blocked `copyNextSampleBuffer` can only be "stopped" by a between-reads flag) — this is the prior device
   hang and is a STOP.
4b. A timeout/cancel path would leave a hidden blocked decode task that can complete late and store success
   (no single-outcome join, no `cancelReading()`) — STOP.
4c. The fixture/spy decoder would need to live in a PRODUCTION file (it must be test-only) — STOP.
5. Stage-4 controller/factory wiring becomes necessary before the Stage-3 renderer unit tests pass (the
   renderer must be testable standalone via the cache, with no controller changes).
6. Honoring the Stage-1 `chunk.key == key` / exact-range invariants would require modifying accepted Stage-1
   types (the renderer must conform, not relax the contract).
7. The exact source-time math cannot be kept integer/rational (any `Double`/µs-truncation requirement for
   source position is a STOP).

---

## 10. Acceptance criteria

Stage 3 is complete only when ALL hold:

- `BackgroundCanonicalPCMRenderer` exists and conforms to `CanonicalPCMRenderer`, using the
  `CanonicalPCMAssetDecoder` seam. `CanonicalPCMAssetDecoder.swift` is protocol + value types ONLY.
- The fixture/spy decoder lives in the TEST target only (no fixture decoder in any production file).
- `AVFoundationPCMAssetDecoder` exists behind the protocol, AV-confined, bounded, and enforces the HARD
  watchdog model (§3): owns the `AVAssetReader`, off-main read loop, `reader.cancelReading()` from a
  separate watchdog/cancellation path, single-outcome join, typed timeout/throw, no hidden late success.
- Simulator unit tests (renderer contract §8.1–§8.12) pass; **watchdog/timeout tests §8.13–§8.18 pass via
  the spy reader seam** (no real compressed media needed); architecture guards §8.19–§8.21 pass.
- **No controller/factory lifecycle wiring** changed (Stage 4 owns that).
- Static scans clean: no live-decoder symbols outside `AVFoundationPCMAssetDecoder.swift`; `AVAssetReader(` /
  `copyNextSampleBuffer` / `cancelReading` confined to that one file; controller/factory/play path free of
  them.
- Real compressed-decode coverage is device-gated (or simulator-fixture only if proven reliable); the
  watchdog contract is unit-tested regardless.
- All accepted Stage 0/1/2 tests still pass (`CanonicalAudioArchitectureTests`,
  `CanonicalPCMRenderCacheTests`, `CachedCanonicalAudioRenderPipelineTests`, `CanonicalCutoverBypassTests`,
  `CanonicalPreviewAudioControllerTests`, `RuntimeCanonicalAudioPlanSourceTests`,
  `VideoOriginalAudioPlanTests`).
- **No device-audible claim** is made from simulator; any real-decode behavior is device-gated evidence.

---

## 11. Scope boundary (what Stage 3 does NOT do)

- Does NOT wire the renderer into `CanonicalPreviewAudioControllerFactory` / the production
  `CachedCanonicalAudioRenderPipeline` construction — that is the next wiring stage.
- Does NOT add prewarm scheduling / invalidation triggers.
- Does NOT touch `AnimiEngineCore`, export, or legacy audio.
- Does NOT claim device-audible preview audio.

---

## 12. Open risks

- **R1 — AVAssetReader reliability in simulator** for committing a small compressed fixture; may force
  real-decoder coverage to be fully device-gated. Mitigation: fixture decoder is the primary unit path.
- **R2 — Exact-frame-count from compressed decode**: encoder/decoder priming/gapless padding can make the
  decoded frame count differ from the requested count at boundaries. Mitigation: bounded `timeRange` +
  exact-count validation + (if a zero-pad/trim policy proves necessary) a SEPARATELY-APPROVED policy — not
  silently added in Stage 3.
- **R3 — Architecture-guard update**: `testRealtimePreviewPathDoesNotCallLiveAVAssetReader` must move from a
  whole-dir ban to a one-file allow-list; care needed so it still bans the play path. Risk of weakening the
  guard if the allow-list is too broad — it must allow EXACTLY `AVFoundationPCMAssetDecoder.swift`.
- **R4 — Source-time rational overflow** for very long sources/interior offsets; handled by
  `.sourceStartNotRepresentable` fail-closed, but worth a targeted test.
- **R5 — Channel/sample-rate conversion** inside the reader output settings (source not 48 kHz/mono); the
  reader's `audioSettings` requests 48 kHz mono Float32 so AVFoundation converts, but conversion fidelity is
  a device-smoke concern.
- **R6 — Watchdog correctness (P0)**: the hard interrupt depends on `reader.cancelReading()` actually
  unblocking a parked `copyNextSampleBuffer`. Mitigation: the watchdog contract (timeout → `cancelReading()`
  → typed throw, single-outcome join, no late store) is unit-tested via the spy reader seam (§8.13–§8.18)
  WITHOUT real media, and re-confirmed on a deliberately slow/large source in the device smoke (§8.22). If
  `cancelReading()` is found insufficient on device to interrupt a real block, that is STOP 4a.
