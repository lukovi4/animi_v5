# D-213 — Audio Overload / Output-Stage Benchmark

- **Status of this document:** evidence + recommendation package (no production output stage written).
- **Date context:** 2026-06-26.
- **Decision under test:** `decision-register.md:76` — *"Audio overload/output stage | Compare explicit
  deterministic hard saturation against a fixed safety limiter; require preview/export equivalence and
  device evidence."* — currently `BENCHMARK DECISION` (not `APPROVED`).
- **Normative source:** ADR-012 §4 (the final overload/output stage must be *"explicit, deterministic,
  versioned, diagnosed, and identical in preview and export"*; *"hard saturation versus a fixed safety
  limiter is benchmark decision D-213 and must be accepted before Slice 4"*); roadmap §5 (*"Before Slice 4
  begins, close D-213 with reproducible comparison evidence and record the selected deterministic
  output-overload stage."*).
- **Blocker tracked as:** Slice-004 plan B1 (`slice-004-implementation-plan.md:26`).

---

## 1. Readiness verdict

**ACCEPTED OFFLINE-PROVEN; DEVICE CONFIRMATION PENDING.**

D-213 is accepted under Option 1 (tech-lead decision, 2026-06-26):

- **Selected canonical output stage = Candidate A — explicit deterministic hard saturation
  `clamp(x, -1, +1)`.**
- **Documented fallback = Candidate B — fixed stateless safety limiter**, adopted only if the Slice-004
  physical-device audible-quality gate proves hard saturation unacceptable.

What this acceptance rests on:

- The **offline, device-free half** of D-213 is **closed by the committed evidence below**: determinism,
  preview/export sample-equivalence, the full-scale safety bound, and below-threshold bit-transparency are
  all *pure-function* properties, proven with committed reproducible evidence and a device-free test.
- The **device half** of the decision text (*"require … device evidence"*, plus ADR-012's "audible
  quality" dimension) **has not been produced** — no physical-device audible-quality evidence has been
  gathered. It remains an **obligatory gate**, deferred to the Slice-004 device gate (§6). It does **not**
  block starting Slice-004 Stage A.
- This acceptance therefore unblocks Slice-004 (B1) for the *offline* output-stage implementation while
  keeping the device claim honest: **no device evidence exists yet**; the canonical selection may still be
  revised to Candidate B if the device gate rejects A.

---

## 2. Exact requirement interpretation

The output stage is the **final, single** transform applied to the internal mix bus immediately before
integer/encode output. Per ADR-012 §4:

- the internal mix bus is `Float32`, 48 kHz, stereo, and **may carry peaks outside `[-1, 1]`** (the engine
  does **no** hidden per-source normalization, ducking, or AGC — overload is real and must be handled
  *only* at this one stage);
- the stage must be **explicit** (a named, versioned function — not an incidental clamp buried in a
  converter), **deterministic** (same input → same output bytes), **versioned**, **diagnosed** (peak /
  overload metering, ADR-012 "Required diagnostics"), and **identical in preview and export**;
- integer conversion may add **only explicitly configured deterministic dither**; `Float32` and
  compressed-export inputs add none. Dither is therefore **out of scope for D-213 itself** (it is a
  separate, later, explicitly-configured stage) — D-213 decides only the saturation/limiting curve.

**"Identical in preview and export"** is the load-bearing constraint. It means the canonical output stage
must be **one pure shared function** with **no consumer-specific branch and no carried cross-call state**
that could diverge between the realtime preview path and the offline export path. This is what makes a
**stateless** curve strongly preferable and a **stateful** (attack/release/lookahead) limiter a
correctness liability (see §3/§7).

**"Deterministic output stage"** here additionally means **machine-reproducible**: no platform
transcendental (`exp`/`log`/`pow`) whose last-bit results differ across libm versions/architectures may
appear in the canonical curve, or the committed evidence and the preview/export bytes could diverge across
devices. Both candidates in this benchmark are transcendental-free by construction.

---

## 3. Alternatives compared

| | **A — explicit hard saturation** | **B — fixed safety limiter** |
|---|---|---|
| Curve | `out = clamp(x, −1, +1)` | below a fixed threshold: unity (bit-transparent); above: a fixed **rational soft-knee** reduces the excess, asymptote held **strictly below** full scale |
| State | none (branch-only) | none carried across samples — **stateless-per-sample by construction** (no attack/release/lookahead) |
| Parameters | none | fixed/versioned: `threshold = 0.75`, `ratio = 8`, `ceiling = 1.0`; soft-knee asymptote `= threshold + 1/ratio = 0.875 < 1.0` |
| Transcendental | none | none (uses only `+ − × ÷`) |
| Preview/export-identical | trivially (pure, stateless) | yes (pure, stateless-per-sample) |
| Below normal level | transparent | transparent (≤ threshold unchanged) |
| At/above overload | pins to ±1.0, adds clipping harmonics | approaches but **never reaches** ±1.0; smoother knee |

**Deliberately excluded variant — a *stateful* limiter** (lookahead + attack/release time constants). It
is the textbook "safety limiter," but it carries inter-block state, so making preview and export
**byte-identical** requires both consumers to seed and advance that state identically across every block
boundary, flush, seek, and epoch change. That is a standing divergence risk against ADR-012 §4's "identical
in preview and export." This benchmark therefore tests B as a **stateless static curve**, which preserves
the limiter's smoother knee while keeping exact equivalence. If the owner wants a true time-domain limiter,
that is a **new ADR amendment**, not a D-213 sub-option (recorded as a STOP in §11).

---

## 4. Benchmark matrix

Inputs are deterministic PCM vectors covering the §4 contract surface; they are corpus-aligned (the
44.1/48/96 kHz tone amplitude is `0.5` — `media-corpus/generate_corpus.py TONE_AMPLITUDE` — so the
"normal level" rows use exactly that) plus the edge cases the decision text implies.

| Vector | What it exercises | Why it matters for D-213 |
|---|---|---|
| `silence` | all-zero | output stage must be a no-op; A≡B (identical hash) |
| `corpus_tone_amplitude` (0.5) | corpus tone level, below threshold | normal audio must be **bit-transparent**; A≡B (identical hash) |
| `below_threshold` | 0…0.8 sweep | sub-overload behavior; B's knee onset above 0.75 only |
| `at_unity_exact` | exactly ±1.0 | boundary; A passes, B already reducing |
| `above_unity_overload` | ±1.25…±8.0 | true overload; A pins ±1.0, B stays below |
| `repeated_peaks` | alternating ±2.0 / 0 | transient peaks (drum-like) |
| `long_constant_overload` | 64× 3.0 | sustained overload — the **distinguishing** case |
| `mixed_signs_summed_overload` | summed multi-source | emulates corpus 6/10/20-video summation |
| `transition_overlap_sum` | two overlapping tones summed | corpus transition-overlap audio case (ADR-012 §2) |

Metrics per (vector, candidate), **integer-quantized at 1e6 (round-half-up)** so the committed JSON is
byte-stable across machines: `outputSHA256` (test-local SHA-256 over big-endian Float32 bit patterns),
`peakOutMicros`, `maxAbsErrorMicros` (distortion vs passthrough), `clampedSampleCount`,
`bitTransparentBelow`, `exceedsFullScale`.

---

## 5. Evidence produced (committed, reproducible)

- **Evidence artifact:** `Docs/AnimiEngineNext/evidence/d-213/output-stage-evidence.json`
  (`schema: "d-213-output-stage-benchmark/v1"`, byte-stable).
- **Harness (test-only, NOT production):**
  `AnimiEngineNext/Tests/AnimiEngineCoreTests/OutputOverloadStageBenchmarkTests.swift`.
- **Run:** `cd AnimiEngineNext && swift test --filter OutputOverloadStageBenchmarkTests` → 5 tests, 0
  failures. Regenerate the committed artifact with `ANIMI_REGEN_D213=1`; the default run **asserts** the
  fresh deterministic output equals the committed file (the reproducibility gate).

Key measured facts (from the committed artifact):

- **Normal audio is untouched.** `silence` and `corpus_tone_amplitude` produce **identical SHA-256 for A
  and B** (`f5a5fd42…` and `9f6300f0…` respectively); `maxAbsErrorMicros = 0`, `bitTransparentBelow = true`
  for both. Neither stage colors below-threshold signal.
- **Neither stage ever exceeds full scale.** `exceedsFullScale = false` and `peakOutMicros ≤ 1_000_000` on
  **every** vector for both candidates — the safety contract of §4 holds for A *and* B.
- **A pins to full scale under overload; B sits below it.** e.g. `long_constant_overload`: A
  `peakOutMicros = 1_000_000`, B `peakOutMicros = 868_421`; `above_unity_overload`: A `1_000_000`, B
  `872_881`. Distinct hashes — the deterministic, reproducible difference the decision exists to weigh.
- **The difference is purely above threshold.** Below 0.75 the candidates are identical; the only
  divergence is in how overload is shaped (hard pin vs. smooth approach).

A real defect was caught while producing this evidence: an initial B parameterization
(`threshold 0.875`, `ratio 4`) had soft-knee asymptote `1.125 > 1.0`, so its hard ceiling collapsed B back
onto A under heavy overload (identical hashes). The `testCandidatesDifferUnderOverloadDeterministically`
gate flagged it; parameters were corrected to `0.75 / 8` (asymptote `0.875`), which is recorded as the
benchmark's B configuration. This is evidence the harness actually discriminates the two algorithms rather
than rubber-stamping them.

---

## 6. Evidence still needed (device-only, deferred to Slice 004)

| Evidence | Why offline cannot settle it | Where it lands |
|---|---|---|
| Audible quality of hard clip vs soft limiter under sustained overload | perceptual; no offline metric is authoritative | Slice-004 device gate (6-video-with-audio) |
| The stage in the **real** preview render clock / export manual-render | needs the AVFoundation graph (Slice-004 Stage E) | Slice-004 Stage D+E |
| Peak/overload **diagnostics** surfaced through the realtime callback | needs the realtime-safe state path (ADR-012 §5) | Slice-004 Stage E/H |

None of these can be produced without starting Slice 004, which this task forbids.

---

## 7. Recommendation

**Recommend candidate A — explicit deterministic hard saturation — as the canonical D-213 output stage**,
on the offline evidence, with the soft limiter (B, stateless form) retained as a documented alternative
pending device-audible justification. Rationale, strictly from what is provable here:

1. **Maximal preview/export-identity safety.** A is branch-only and stateless; there is the least possible
   surface for any preview/export divergence (§4's hardest constraint). B (stateless form) is also
   equivalent, but A's equivalence is the most obviously bulletproof.
2. **Bit-transparency where it matters.** Both A and B are bit-transparent on normal-level audio (corpus
   tone 0.5); A is transparent right up to ±1.0. Real authored content that never overloads is therefore
   untouched by A — the limiter's knee only earns its keep when the mix is *already* clipping, which is a
   data/authoring condition, not a default.
3. **No tuning debt.** A has no parameters to benchmark, version, or regress; B introduces
   `threshold/ratio/ceiling` that themselves become evidence-owned tuning (ADR-012 §11 territory).
4. **The limiter's only advantage is audible smoothness under overload — which is exactly the part this
   package cannot prove.** Choosing B *now* would adopt unprovable tuning ahead of device evidence.

**This recommendation is conditional:** if the Slice-004 device gate shows hard saturation is audibly
unacceptable under realistic summed overload (it usually is not, given §2 mixes authored gains and overload
is the exception), B (stateless form) is the pre-vetted fallback and its evidence is already committed.

---

## 8. Preview/export equivalence contract (for whoever implements Stage D)

When Slice-004 Stage D writes the **production** `Realtime/OutputOverloadStage.swift`, it must satisfy:

1. **One shared pure function**, consumed identically by the preview graph and the offline export
   renderer. No `isPreview`/`isExport` branch. No consumer-specific parameter.
2. **Stateless** across samples and across calls (no attack/release/lookahead state). If a future product
   needs a time-domain limiter, amend the ADR first (§11 STOP).
3. **Transcendental-free** canonical curve (only `+ − × ÷`, or a versioned integer/rational table) so the
   bytes are identical across architectures and libm versions.
4. **Versioned**: the stage carries an explicit version id; changing the curve or any parameter bumps it
   and is recorded in diagnostics/evidence.
5. **Never exceeds `[-1, +1]`** and is **bit-transparent below its threshold** (A's threshold is full
   scale). Verified by a production test mirroring this harness's vectors.
6. **Diagnosed**: pre-output peak and overload count are exposed per ADR-012 §4 / "Required diagnostics",
   updated only on preallocated lock-free state inside the realtime callback.

The committed evidence vectors in §5 are the seed corpus for that production test, so Stage D's test inherits
this benchmark's discrimination.

---

## 9. Exact files touched by this package

| Path | Kind | Note |
|---|---|---|
| `Docs/AnimiEngineNext/d-213-audio-output-stage-benchmark.md` | doc (new) | this file |
| `Docs/AnimiEngineNext/evidence/d-213/output-stage-evidence.json` | evidence (new) | deterministic, byte-stable |
| `AnimiEngineNext/Tests/AnimiEngineCoreTests/OutputOverloadStageBenchmarkTests.swift` | **test-only** (new) | no production output stage |

**No production source** was added or modified. No `Sources/AnimiEngineCore/Realtime/` directory was
created. No `AnimiApp/`, `Package.swift`, `*.xcodeproj`, `ReferenceData/`, AVFoundation/AVFAudio. The
candidate algorithms live **inside the test target** (where `Float`/`Double` are permitted); the
production no-Float sweep covers `Runtime/` and `Audio/` sources only and is unaffected.

---

## 10. Decision-register status

**Decided — Option 1 (tech-lead, 2026-06-26).** D-213 is accepted offline-proven with device confirmation
pending. The decision-register entry for D-213 records: **selected = Candidate A hard saturation**;
**fallback = Candidate B stateless limiter**; **device confirmation pending in Slice 004**. This unblocks
Slice-004 (B1) for the *offline* output-stage implementation while keeping the device claim honest — no
physical-device audible-quality evidence exists yet, and the selection may still be revised to Candidate B
if the Slice-004 device gate rejects A.

The register edit is a minimal D-213-only wording change. (The decision-register file already carries
unrelated pre-existing working-tree edits; the D-213 hunk is kept isolated, and nothing is staged or
committed by this work.)

---

## 11. STOP conditions

1. **This package writes no production `OutputOverloadStage`.** That is Slice-004 Stage D. With D-213 now
   accepted, Stage D may implement the *selected* Candidate A (stateless hard saturation, identical for
   preview/export); this package itself remains evidence only.
2. **Do not claim device evidence exists.** The acceptance is **offline-proven only**; the audible-quality
   confirmation is a Slice-004 device-gate obligation. The selection stays revisable to Candidate B if the
   device gate rejects A.
3. **STOP if a *stateful* (attack/release/lookahead) limiter is wanted.** That changes the
   preview/export-equivalence contract (§3/§8) and requires an **ADR-012 amendment** before any
   implementation, not a D-213 sub-option (the accepted fallback B is the *stateless* form only).
4. **STOP before any AVFoundation / realtime / device code beyond authorized Slice-004 stages** — start
   Stage A per the slice plan; do not improvise the AVFoundation boundary outside `Realtime/`.
5. **STOP before staging/commit/push** — explicit owner authorization required (as in Slices 001–003).

---

## 12. Next step (single, explicit)

**Decided.** D-213 is accepted offline-proven (Option 1): Candidate A (hard saturation) selected, Candidate
B (stateless limiter) fallback, device confirmation deferred to the Slice-004 device gate. The next step is
**Slice-004 Stage A** per `slice-004-implementation-plan.md` (device-format & session adapter boundary).
Stage D will implement the selected Candidate A; the physical-device audible-quality confirmation remains an
obligatory Slice-004 *close* condition and may still revise the selection to Candidate B.
