# Slice 005 Stage 6 Device Blocker — Plan Change Proposal

## 1. Verdict

Stage 6 FAIL. The current approved per-chunk bounded `AVAssetReader` decode model is not
device-stable for continuous canonical playback: interior chunks return fewer decoded frames than
the requested bounded range, and that shortfall exceeds the fail-closed tolerance. **No code changes
are made in this proposal.** This document only proposes a plan change for owner approval.

## 2. Verified evidence

Source of facts: device log
`Docs/AnimiEngineNext/evidence/slice-005-device-stage6-sequential.log`, current source files, and the
approved plan docs. Nothing here is inferred.

### 2.1 Marker counts (verified by `grep -c` on the device log)

| Marker | Count |
|---|---|
| `fallbackToLegacy` | 0 |
| `nextChunk.requested` | 21 |
| `nextChunk.render.end` | 17 |
| `nextChunk.schedule.end` | 17 |
| `nextChunk.endOfPlan` | 3 |
| `nextChunk.failed` | 4 |
| `errorAlert` | 3 |

### 2.2 Exact failing lines (verbatim from the device log)

```
[MEM-EVENT] preview.audio.canonical.nextChunk.failed | error=pcmRenderFailed(reason: "decode produced 50299 frames, expected 52800 (shortfall 2501 > tolerance 1024)")   ×3
[MEM-EVENT] preview.audio.canonical.nextChunk.failed | error=pcmRenderFailed(reason: "decode produced 50515 frames, expected 52800 (shortfall 2285 > tolerance 1024)")   ×1
[MEM-EVENT] preview.audio.canonical.errorAlert | reason=pcmRenderFailed(reason: "decode produced 50299 frames, expected 52800 (shortfall 2501 > tolerance 1024)")   ×3
```

Requested bounded read = 52800 frames (48000-frame chunk + 4800-frame exact-rational guard-band).
Decoder returned 50299 (shortfall 2501) or 50515 (shortfall 2285). Both exceed the
1024-frame tolerance, so the chunk fails closed.

### 2.3 Current implementation references (verified by `grep -n`)

(Referenced by stable symbol name, not by line number — line numbers drift.)

`AnimiApp/Sources/EditorRuntime/Realtime/AVFoundationPCMAssetDecoder.swift`
- `static let maxBoundaryShortfallFrames = 1024` — fail-closed tolerance.
- `static let interiorSeekMarginFrames: Int64 = 4800` — guard-band size.
- `struct ReadWindow`, `boundedReadWindow(...)`, `exactFrames(...)` — exact-rational guard-band window
  math (no floor onto frame grid).
- `decodeMono48kFloat32(...)` — per-call bounded decode.
- `final class AVAssetReaderBoundedPCMReader` — owns **one** `AVAssetReader` + one
  `AVAssetReaderTrackOutput` per decode; `copyNextSampleBuffer()`; `cancelReading()` hard interrupt.
- `withTaskCancellationHandler` watchdog; deadline path calls `reader.cancel()`.
- `reconcileFrameCount(...)`: exact → return; over → trim; short `≤ 1024` non-empty → zero-pad; else
  throw `pcmRenderFailed`.

`AnimiApp/Sources/EditorRuntime/Realtime/CanonicalPreviewAudioController.swift`
- `static let continuousLookaheadDepth = 1` — sequential, at most one render in flight.
- `startContinuousScheduling(...)`, `pumpContinuous()`, `renderAndScheduleChunk(...)`,
  `continuousFailed(...)`, `cancelContinuous()`.
- `onCanonicalUnavailable` is invoked on failure.

`AnimiApp/Sources/EditorRuntime/EditorRuntimePreviewAudioCoordinator.swift`
- `onCanonicalUnavailable` now routes to `presentCanonicalAudioErrorAlert(reason:)`, one-shot via
  `didShowCanonicalErrorAlert`, then presents the alert.
- **No legacy-fallback masking remains**: `fallBackToLegacy*` is gone; failure surfaces an alert.

### 2.4 Fallback no longer masks failure

`fallbackToLegacy = 0` in the log AND the coordinator routes failure to an error alert, not to legacy.
This is the change that exposed the real device blocker: the 4 `nextChunk.failed` markers are now
visible instead of being silently swallowed by a legacy success path.

## 3. What is proven vs not proven

| Statement | Status |
|---|---|
| The canonical path can schedule multiple chunks (17 `schedule.end`) | **Verified (log)** |
| Some runs reach `endOfPlan` (3) | **Verified (log)** |
| Some interior chunks fail with a decode short-read (4 `failed`, shortfall 2285–2501) | **Verified (log)** |
| Raising tolerance would mask missing audio (gaps/silence) and violate fail-closed intent | **Verified (plan §6 fail-closed; quality intent)** |
| Stage 6 is FAIL | **Verified (any `nextChunk.failed` = FAIL per directive)** |
| Fallback no longer masks failure | **Verified (log + code)** |
| A bounded source-window/session reader (Candidate A) will definitely fix the short-read | **Not proven** (hypothesis; requires device evidence) |
| Apple officially forbids/penalizes per-chunk `AVAssetReader` at a non-zero `timeRange.start` | **Not proven** — no official/primary Apple source cited here confirms this |
| Parallel lookahead was the root cause of the short-read | **Not proven** — short-read persists at depth=1 sequential, so parallelism is **not** the cause |
| A guard-band can fix all compressed-media short reads | **Not proven** — disproven for this source: 4800-frame guard-band did not close a 2285–2501 shortfall |

### Inferred hypothesis (explicitly labelled, not fact)

The short-read magnitude (~2285–2501 frames ≈ 48–52 ms) and its independence from the guard-band are
**consistent with** encoder priming / gapless padding / seek-granularity effects on a compressed
source when an `AVAssetReader` is opened at a non-zero `timeRange.start`. This is an inferred
hypothesis from the observed numbers, **not** an Apple-documented guarantee and **not** independently
verified against primary Apple documentation in this proposal.

### Unknown

- The exact internal reason `AVAssetReader` returns fewer frames for this specific source/codec.
- Whether a single sequential reader over the source eliminates the shortfall **on this device/codec**
  (must be proven by a device run, not assumed).
- Whether the shortfall is constant per source or varies by chunk offset (log shows two distinct
  values, 2285 and 2501 — variation is observed but its cause is unknown).

## 4. Why the current approved model is exhausted

- The approved Stage-3 model decodes each bounded `AudioSampleRange` chunk with its **own**
  `AVAssetReader` lifetime, bounded-range-only
  (`slice-005-stage-3-background-pcm-renderer-plan.md` §2, §5). Each interior chunk therefore re-opens a
  reader at a non-zero source start.
- With **exact-rational source time** + a **4800-frame guard-band** + **sequential depth=1** (no
  parallelism), the device still returns 2285–2501 fewer frames than the bounded request. All three
  mitigations that are compatible with the current model are already applied and the failure persists.
- **Raising the tolerance is forbidden and wrong**: a 2285–2501-frame hole is ~48–52 ms of missing
  audio per failing chunk. Zero-padding it would inject audible silence/gaps at chunk boundaries and
  violate the plan's fail-closed / no-silent-substitution intent.
- Further guard-band/tolerance tweaks are **overengineering** without new evidence: the guard-band
  hypothesis is already disproven for this source (a 4800-frame margin did not cover a <2501 shortfall,
  because the widened read is itself short by the same magnitude).

Conclusion: For the current tested device/source/project and the current approved per-chunk bounded
reader model, the allowed tuning path is exhausted: sequential depth=1 + exact-rational source time +
4800-frame guard-band still produces a short-read > tolerance. Further tolerance/guard-band tuning is
not approved without new evidence. This is **not** a universal claim that the model can never be
device-stable, and it is **not** Apple-guaranteed / not independently proven against primary Apple
documentation. A structural change to how the source is read is therefore proposed below; it is
**outside** the current approved plan and needs owner approval.

## 5. Candidate plan changes

No implementation here. Each candidate keeps the **external** contract: the controller still consumes
`CanonicalAudioRenderPipeline` / cache `CanonicalPCMChunk`s; the AVFoundation seam stays confined to
`AVFoundationPCMAssetDecoder.swift`; source time stays exact-rational; output stays bounded; no legacy
fallback as success; no tolerance increase.

### Candidate A — Bounded source-window/session PCM renderer

- A single `AVAssetReader` **session** for a **bounded** playback/prewarm **source window** (NOT
  whole-source, NOT whole-project). The session opens **one** reader for the bounded window (priming/
  seek happens once at the window start) and reads **sequentially** forward within the window, emitting
  bounded `CanonicalPCMChunk`s into the cache as it advances.
- Avoids per-chunk re-seek to a non-zero start — the suspected trigger of the short-read.
- **Requirements (must hold):**
  - one `AVAssetReader` session only, for a **bounded** playback/prewarm source window;
  - **no whole-source / whole-project render** and no whole-project temp CAF;
  - external contract is unchanged: the controller still consumes
    `CanonicalAudioRenderPipeline` / cache `CanonicalPCMChunk`s;
  - AVFoundation stays confined to `AVFoundationPCMAssetDecoder.swift`;
  - exact-rational source time preserved end to end;
  - revision / epoch / seek **invalidates and cancels** the in-flight session
    (via the existing `cancelReading()` hard interrupt);
  - if non-monotonic or reused source ranges appear (e.g. a seek backward, or a chunk request that is
    not strictly forward of the session cursor), the implementation must either **split into bounded
    monotonic sessions** or **fail closed** — it must NOT silently reuse a wrong/forward-only session
    for an out-of-order range.
- **Plan compliance:** keeps bounded output (the window is bounded, not whole-project/whole-source),
  keeps the AVFoundation seam in one file, keeps exact-rational time, keeps no-legacy-as-success.
  Changes the *internal* decoder/cache renderer model (one session serves multiple forward chunks
  within a window) — this is the part that requires a plan amendment.
- **Likely changed files/classes:** `AVFoundationPCMAssetDecoder.swift` (new bounded session reader
  alongside / replacing the per-decode `AVAssetReaderBoundedPCMReader`); the background renderer /
  cache fill path (`CachedCanonicalAudioRenderPipeline` / `BackgroundCanonicalPCMRenderer` /
  `CanonicalPCMRenderCache`) to drive sequential session reads instead of independent per-chunk reads;
  the `CanonicalPCMAssetDecoder` protocol/seam may need a session-style entry point.
- **Risks:** larger stateful renderer; cancellation/invalidation across a multi-chunk session is more
  complex; bounded-window memory sizing must be enforced; backward seek/scrub inside the window
  requires session restart (or a fail-closed/split path per the requirement above).
- **Tests:** session emits the same exact bounded chunks as the per-chunk model for a zero-start
  source; sequential read across a bounded window produces full-length interior chunks (no shortfall)
  in a deterministic fixture; cancellation mid-session tears down the reader; revision/epoch change
  invalidates the session; an out-of-order/backward range either splits into a new bounded session or
  fails closed (never reuses a wrong session).
- **Device acceptance:** §7 criteria — specifically zero `nextChunk.failed`, audible playback through
  full expected duration.

### Candidate B — Pre-render rolling window via the current per-chunk decoder

- Keep the per-chunk independent-reader decode but pre-render more chunks ahead before audible start.
- **Plan compliance:** fully compliant (no model change).
- **Likely changed files/classes:** controller lookahead/prewarm depth only.
- **Does NOT solve the short-read:** if `AVAssetReader` still returns fewer frames per re-seek, every
  pre-rendered interior chunk still fails. Pre-rendering changes *when* the failure happens, not
  *whether* it happens.
- **Tests / device acceptance:** would still show `nextChunk.failed` on device → would still FAIL §7.
- **Assessment:** lowest change, **likely insufficient**. Listed for completeness only.

### Candidate C — Whole-window bounded render then slice

- Render one bounded **preview window** (not the whole project) with a single read, then slice that
  contiguous PCM buffer into the bounded cache chunks.
- Avoids per-chunk re-seek *inside* the window (one read covers the window; slicing is in-memory).
- **Plan compliance:** must stay **bounded** — a preview window, never a whole-project / whole-source
  temp CAF (banned per `canonical-audio-preview-export-implementation-plan.md` §5, §6 and
  `slice-005-stage-3-background-pcm-renderer-plan.md` §5). Compliant only if the window is explicitly bounded and
  memory-capped.
- **Likely changed files/classes:** `AVFoundationPCMAssetDecoder.swift` (window read), the cache fill
  path (slice a window buffer into chunks). Simpler state than A (no long-lived streaming session), but
  higher peak memory (whole window resident at once).
- **Risks:** memory for the resident window; window must still be bounded and sized; if the window
  itself starts at a non-zero source offset it could re-introduce a (single, smaller) boundary
  short-read at the window start — to be verified, not assumed.
- **Tests:** window read produces full-length contiguous PCM; slicing yields exact bounded chunks;
  window stays within a memory bound; non-zero window start behavior is characterized on device.
- **Device acceptance:** §7 criteria.

## 6. Recommended candidate

**Recommend Candidate A (bounded source-window/session PCM renderer: one `AVAssetReader` session over
a bounded window, sequential forward reads, no per-chunk re-seek).** Confidence: **based on current
device evidence and architecture reasoning, not an official Apple guarantee.** Not 100% certain.

Rationale:
- The short-read is **verified** to persist at sequential depth=1 with exact-rational time and a
  4800-frame guard-band, so parallelism and per-chunk math are ruled out as causes (§3). The remaining
  variable that the current model forces on every interior chunk is the **per-chunk re-seek to a
  non-zero source start**. Candidate A is the smallest plan-compliant change that removes exactly that
  variable while preserving every external contract (bounded output, single AVFoundation file, exact
  rational time, no legacy success, no tolerance increase).
- Candidate B is rejected: it does not change the read pattern, so it cannot address a read-pattern
  failure.
- Candidate C also removes per-chunk re-seek but at higher peak memory and may re-introduce a single
  boundary short-read at the window start; it is a viable fallback if A's streaming-session
  cancellation/invalidation complexity proves too large.

**Honesty caveat:** it is **not proven** that Candidate A eliminates the short-read on this
device/codec. The hypothesis (re-seek triggers the shortfall) is consistent with the observed numbers
but is not confirmed by primary Apple documentation. Candidate A must be **proven by a device run**
meeting §7 before it can be called a fix. If A is implemented and the device log still shows
`nextChunk.failed`, that is a FAIL and a STOP — not a "fixed."

## 7. Required acceptance criteria for the next implementation

The next implementation (after approval) is accepted ONLY if a raw device log shows all of:

- `fallbackToLegacy` = 0 (no legacy fallback used, and never counted as success).
- `nextChunk.failed` = 0.
- No `pcmRenderFailed` short-read anywhere in the device log.
- Multiple `nextChunk.schedule.end` (continuous scheduling working).
- `nextChunk.endOfPlan` reached for the tested project.
- Audible playback beyond the first second AND through the full expected duration of the tested
  project (not just preroll).
- No tolerance increase above the current `maxBoundaryShortfallFrames = 1024` policy unless separately
  and explicitly approved.
- No whole-project / whole-source unbounded render and no whole-project temp CAF.
- No changes to export, AnimiEngineCore, visual render, or legacy audio unless explicitly approved
  with a stated hard-blocker.
- No claim of PASS without a raw device log attached as evidence.

## 8. STOP conditions

Stop immediately and report (no further code) if any of the following becomes true:

- The solution requires raising the zero-pad tolerance to "pass" (mask missing audio). **Banned.**
- The solution requires widening the guard-band again without new evidence. **Banned** — the
  guard-band path is already disproven for this source.
- The solution requires an unbounded whole-project / whole-source preview render (or whole-project
  temp CAF). **Banned.**
- The solution requires using the legacy preview audio path as a success route. **Banned.**
- Source-time exactness (exact-rational) is lost anywhere in the path. **Banned.**
- Candidate A is claimed as a fix / "guaranteed" before a raw device log proves it. **Banned** — no
  PASS without device evidence.
- The implementation requires changing the approved plan **beyond** what this proposal authorizes.
- After implementing the approved candidate, the device log still shows `nextChunk.failed` or any
  short-read — report as FAIL with the log, do not tune tolerance to "pass."

## 9. Output

- Created document: `Docs/AnimiEngineNext/slice-005-stage-6-device-blocker-plan-change.md`.
- No code changed.
- Nothing staged, committed, or pushed; git index clean.
- Recommendation: **Candidate A — bounded source-window/session PCM renderer (one `AVAssetReader`
  session over a bounded window, sequential forward reads, no per-chunk re-seek)**, with confidence
  labelled as evidence/architecture-based, not an Apple guarantee, and requiring device proof.
- **Awaiting approval before implementation.** — Approved and implemented; see §10.

## 10. Candidate A device result — PASS

Candidate A was approved, implemented, and verified on a physical device. The raw device log is the
evidence of record:

- Evidence log: `Docs/AnimiEngineNext/evidence/slice-005-device-stage6-candidateA.log`
- Device: **physical iPhone 13 Pro** (the connected device this build was installed to and launched on —
  `devicectl` device `86C5CAA4-23E9-5EDB-BBE1-C11DAE59FF39`, build destination `00008110-000C59C20A20401E`).
  The log line records the launch (`Launched application with com.animi.app bundle identifier`); the
  log body itself does not print the model string, so the model is stated from the known install/launch
  device, not parsed from the log text.
- Toggle: **ON** (`-DebugPreviewAudioWithNextEngine YES -DebugMemoryDiagnostics YES`).

### 10.1 Verified marker counts (from the raw log)

| Marker | Required for PASS | Observed |
|---|---|---|
| `fallbackToLegacy` | 0 | **0** |
| `nextChunk.failed` | 0 | **0** |
| `pcmRenderFailed` | 0 | **0** |
| `shortfall` | 0 | **0** |
| `errorAlert` | 0 | **0** |
| `nextChunk.schedule.end` | multiple | **9** |
| `nextChunk.endOfPlan` | reached | **1** (`planEnd=480000`) |

### 10.2 Canonical render path was the one that played

The audible path was the canonical (new) architecture end to end:

- `preview.audio.canonical.selected | toggle=ON controller=CanonicalPreviewAudioController`
- `preview.audio.canonical.legacyGateBypassed | seconds=0.0`
- `preview.audio.canonical.render.end` ×10 with real `sources=2` / `sources=3` (the bounded
  source-window/session decoder actually decoded — not an empty plan)
- `preview.audio.canonical.engine.start.end`, `preview.audio.canonical.player.play.end`,
  `preview.audio.canonical.scheduled | scheduled=1`
- 9× full `nextChunk.requested → render.end → schedule.end` over **strictly contiguous** ranges
  `48000..<96000 … 432000..<480000`, terminating at `nextChunk.endOfPlan | planEnd=480000` (the full
  ~10 s plan played continuously through canonical scheduling).

The interior-chunk short-read that failed the prior Stage-6 run (2285–2501 frames) **did not recur** —
exactly the predicted effect of removing the per-chunk re-seek.

### 10.3 Legacy did NOT play audio

There are **no** legacy render / play / fallback markers in the log (`fallbackToLegacy = 0`; no
legacy preview-audio render or play event of any kind). Legacy did not produce a single sample.

**Explaining `preview.audio.select | controller=Legacy`:** this line is NOT legacy playback. The
coordinator's `selectControllerForToggle()` logs the **current** controller BEFORE it switches:

```
let haveCanonical = controller is CanonicalPreviewAudioController
log("preview.audio.select", "controller=\(haveCanonical ? "Canonical" : "Legacy")")  // snapshot BEFORE switch
guard wantCanonical != haveCanonical else { return }
controller.teardown()                 // tear down the old (Legacy) controller
controller = makeDefaultController()   // build + select Canonical  → logs canonical.selected
```

So the first `select | controller=Legacy` records that the default Legacy controller was still in place
*at that instant*; the code then immediately tore it down and built the Canonical controller (the very
next marker, `canonical.selected`). The second `select | controller=Canonical` simply records that the
controller was already Canonical on a later entry (nothing to switch). No legacy engine ever started or
rendered.

### 10.4 Status

Candidate A is **DEVICE-PROVEN for the tested project, device, and log** above (continuous canonical
preview audio, full-duration playback, zero failure markers). This is **NOT** a universal guarantee for
all codecs, devices, or projects — it is verified for this evidence only. Any new codec / source /
device should be re-verified with its own raw device log before claiming PASS there.
