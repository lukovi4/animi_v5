# AnimiEngineNext Validation Contract

Status: **EVIDENCE-FIRST FOUNDATION APPROVED**

## 1. Rule

No performance, quality or backend choice is accepted from intuition. Every
accepted decision must reference reproducible test runs and stored artifacts.

## 2. Test levels

### Level 1 - Deterministic logic

Runs without UI and without physical-device media limits.

Tests:

- rational time conversion and rounding;
- scene and transition mapping;
- VFR source-sample selection;
- animation and keyframe evaluation;
- visibility and layer ordering;
- identity invalidation;
- cache-key stability;
- configuration decoding;
- project serialization;
- error and cancellation state machines.

### Level 2 - Render correctness

Tests template and renderer behavior frame by frame.

Tests:

- all real templates and animation variants;
- masks, mattes, transforms and clipping;
- scene boundaries and every transition;
- text placement and animation;
- color conversion;
- proxy/cache/live-source switching;
- preview/export semantic parity.

Results use reference images plus explicit pixel or perceptual tolerance. Exact
encoded video bytes are not required to match.

### Level 3 - Physical-device functional tests

Runs on real iPhones:

- open and prepare;
- cold and warm play;
- pause and resume;
- aggressive scrub;
- exact settle;
- repeated seek cancellation;
- scene boundary and dense transition;
- background and foreground;
- interruption and audio route changes;
- memory and thermal pressure;
- export and export cancellation.

### Level 4 - Performance matrix

Video counts:

- 1, 4, 6, 8, 10, 12 and 20.

Media:

- 1080p H.264;
- 1080p HEVC;
- 4K HEVC;
- CFR and iPhone VFR;
- 30 and 60 fps sources;
- screen recording;
- slow-motion source;
- high-motion and hard-cut footage;
- media with and without audio;
- HDR input for future-readiness checks.

Project scenarios:

- every current real template;
- 10-video animated stress scene;
- 20-video animated stress scene;
- 20-video to 20-video transition;
- 10 animated text blocks;
- mixed video and global audio;
- 20-minute playback/export soak.

### Level 5 - Long-run reliability

- repeated play/scrub/export loops;
- 20-minute continuous playback;
- long export;
- low-storage behavior;
- cache rebuild and interrupted writes;
- memory warnings;
- thermal escalation and recovery.

## 3. Required run artifacts

Every run must produce one immutable result directory containing:

```text
run-manifest.json
engine-config.json
device.json
media-manifest.json
project-snapshot.json
events.ndjson
frame-metrics.csv
summary.json
failures.json
output/
```

Proposed formats require approval, but the information itself is mandatory.

The manifest records:

- run ID;
- timestamp;
- git commit;
- engine build;
- configuration hash;
- device model and OS;
- test scenario and random seed;
- template and media content hashes;
- start/end status.

## 4. Required per-frame evidence

- project time and output frame index;
- project revision and playback epoch;
- requested and published frame IDs;
- active scenes and transition progress;
- media requests and selected representation;
- scheduler grant or rejection reason;
- decode and upload latency;
- frame-plan CPU time;
- Metal encode and GPU time;
- queue depths;
- memory;
- thermal state;
- frame result: on-time, late, cancelled, rejected or published;
- degradation state.

## 5. Required aggregate metrics

- p50, p95, p99 and maximum frame time;
- p50, p95, p99 exact-settle latency;
- deadline-miss count and percentage;
- maximum consecutive deadline misses;
- stale-publication count;
- mixed-revision and partial-frame count;
- peak physical memory and Metal allocation;
- active decoder peak and average;
- proxy generation time and size;
- cache build time, hit rate and size;
- CPU and GPU utilization where available;
- thermal-state duration;
- preview audio/video sync error;
- export duration and real-time factor;
- export failure and retry rate.

## 6. Comparison rules

Each candidate run is compared with:

- an approved baseline using the same device, media and configuration;
- the previous accepted engine version;
- the current candidate with only one configuration variable changed.

A comparison is invalid if multiple uncontrolled variables change.

Every result is classified:

- improvement;
- neutral within tolerance;
- regression;
- invalid/incomplete run.

Numerical tolerances and release thresholds are not guessed. Initial baselines
are measured, then thresholds are proposed for owner approval.

## 7. Non-negotiable correctness gates

These are zero-tolerance invariants:

- stale published frames: 0;
- mixed project revisions in one frame: 0;
- partial composed-frame publications: 0;
- callbacks from cancelled work changing visible state: 0;
- silent low-quality substitution in final export: 0;
- silent replacement of missing/corrupt export media: 0;
- unrecorded configuration changes: 0.

## 8. Template acceptance

For every existing template:

- all variants compile/load;
- selected frames match approved references;
- animations preserve timing;
- user media placement and clipping are correct;
- preview and export agree within approved tolerance;
- no stale frame appears during scrub;
- results are recorded by template and variant ID.

## 9. Evidence-based decision record

Every benchmark-dependent decision must include:

- question;
- alternatives;
- exact configurations;
- test devices and media;
- run IDs;
- raw results;
- comparison summary;
- risks;
- recommended option;
- owner approval.

Without this record the decision remains unapproved.

## Task 003 reference-validation closure (§17 steps 13–18)

The candidate/comparison/promotion validation contract realized in Task 003 (full detail in ADR-014's
"Reference Promotion & Comparison Closure" section and `claude-task-003-implementation-report.md`):

- **Candidate evidence** — every candidate frame is a byte-deterministic PNG written through `BenchmarkRun`
  with config/device/template/material/graph/pixel identity; comparison verdicts are
  exactMatch/withinBounds/outOfBounds/candidateOnly.
- **Promotion** — approved references are produced ONLY by the guarded `ReferencePromoter` from one
  owner-approved sealed run (guards: status success; run-manifest aggregate == artifacts-manifest; source
  runID == approved; count == expected; no pre-existing references/diffs; all candidateOnly; per-file
  integrity; no non-identical overwrite). Transactional, git-reversible, no auto-commit.
- **No self-blessing** — references are promoted bytes from an approved run, never current render output;
  the approved suite re-compares **exactMatch** (Task 003: 64/64) against the promoted references.
- **Approved run of record:** `694A5886-…` (aggregate `6137fe02…`); obsolete `2E4AED19-…` is rejected.
