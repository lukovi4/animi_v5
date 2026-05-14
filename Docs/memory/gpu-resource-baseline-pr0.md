# GPU Resource Lifecycle - Baseline & Measurement Lock

## 1. Environment

This document is the PR 0b baseline for Task 3: GPU Resource Lifecycle Refactor.

| Field | Value |
|-------|-------|
| Diagnostics branch/SHA | `codex/gpu-resource-lifecycle-refactor` / `d0ebb0f` + working tree diagnostics changes |
| Diagnostics source branch | `codex/memory-diagnostics-layer2` |
| Device model | iPhone 13 Pro |
| iOS version | iOS 26 |
| Xcode version | Xcode 26 |
| Template / project | TBD - same problematic project/template used in `logs.md` |
| Primary log source | [logs.md](/Users/evgeny/Documents/+Work/Animi/animi_v5/animi/logs.md) |
| Xcode Memory gauge screenshot | 830.9 MB, 30 FPS, CPU 3%, Energy Impact High |
| VM Tracker screenshot | Captured after memory growth; values recorded in section 4 |

Important: the SHA above is not a clean commit-only build. The current working tree contains diagnostics changes, so the baseline must be treated as `d0ebb0f + working tree diagnostics changes`.

## 2. Reproduction Scenario

Exact scenarios for reproduction and future before/after comparison:

1. **Play/pause cycle**: open project -> play/pause repeatedly -> measure after `playback.stop.after.2s`.
2. **Fast scrub**: fast scrub 30-60 sec across timeline -> measure Xcode Memory / Instruments. Current diagnostics do not emit scrub-specific checkpoints.
3. **Multi-scene playback**: project includes multiple scene types with video, masks, matte, stickers, and animated text -> play -> measure.
4. **Export round-trip**: export -> preview restore -> measure `export.*` and `preview.restore.after`.
5. **Scene switch**: switch forward/back across scenes -> measure via nearest play/pause checkpoints.

## 3. Measurement Instructions

### Launch Flags

Main run, summary logs:

```text
-DebugMemoryDiagnostics YES
```

Separate short run, owner/key attribution:

```text
-DebugMemoryDiagnostics YES
-DebugMemoryDiagnosticsVerbosePool YES
```

Verbose pool generates heavy logs. Use it only for a short attribution run, not for a full 10-cycle measurement.

### Data Captured

- Xcode Memory gauge:
  - Memory MB
  - FPS
  - CPU
  - Energy Impact
- MEM-DIAG checkpoints:
  - `editor.boot.before`
  - `editor.boot.after`
  - `playback.start`
  - `playback.stop.before`
  - `playback.stop.after`
  - `playback.stop.after.2s`
  - `export.enter.before`
  - `export.enter.after`
  - `export.frame.N`
  - `export.complete.success`
  - `preview.restore.after`
- TexturePool snapshot:
  - `pool | avail`
  - `pool.owner`
  - `sceneTypeCache`
  - `overlayCache`
  - `runtimes`
  - `videoProviders`
- Instruments VM Tracker:
  - `All`
  - `Dirty`
  - `IOSurface`
  - `IOAccelerator`
  - heap-related regions where visible
- MTLDevice current allocated size:
  - MEM-DIAG `metal:` field.

### Current Measurement Limitation

Fast scrub currently has no dedicated MEM-DIAG checkpoint. The current diagnostic layer is wired to playback/export lifecycle checkpoints, not scrub lifecycle checkpoints. For this baseline, scrub evidence is therefore limited to Xcode Memory / Instruments screenshots or remains `TBD`.

This limitation does not block PR 1 because the play/pause + scene switch data already proves monotonic `TexturePool.available` growth.

## 4. Baseline Results

### Xcode Memory Gauge

| Metric | Value |
|--------|-------|
| Memory | 830.9 MB |
| FPS | 30 FPS |
| CPU | 3% |
| Energy Impact | High |
| Context | Captured after memory growth during interactive preview workflow. Exact sub-scenario not encoded in screenshot; use MEM-DIAG rows below for checkpoint-specific values. |

### MEM-DIAG Checkpoints

| Checkpoint | footprint | resident | metal | pool.avail count | pool.avail MB | pool.inUse | Top owners / notes |
|-----------|-----------|----------|-------|------------------|---------------|------------|--------------------|
| `editor.boot.before` | 18 MB | 86 MB | n/a | n/a | n/a | n/a | Before renderer/device memory is available |
| `editor.boot.after` | 53 MB | 122 MB | 11 MB | 0 | 0 MB | 0 | `UserMediaService: 1` |
| First captured `playback.stop.after.2s` | 231 MB | 124 MB | 196 MB | 240 | 104.7 MB | 0 | `mask.boolean.bbox`: 240 / 104.7 MB |
| Later `playback.stop.after.2s` after scene/runtime growth | 511 MB | 187 MB | 476 MB | 481 | 212.2 MB | 0 | `mask.boolean.bbox`: 400 / 151.9 MB; `matte.bbox`: 80 / 55.8 MB; `isolatedGroup.fullTarget`: 1 / 4.5 MB |
| Late/final captured `playback.stop.after.2s` | 813 MB | 142 MB | 773 MB | 1111 | 308.2 MB | 0 | `mask.boolean.bbox`: 972 / 227.3 MB; `matte.bbox`: 137 / 71.9 MB; `isolatedGroup.fullTarget`: 1 / 4.5 MB; `matte.fullTarget`: 1 / 4.5 MB |
| Fast scrub 30s | Xcode gauge: 830.9 MB | TBD | TBD | TBD | TBD | TBD | No scrub-specific MEM-DIAG checkpoint in current diagnostics |
| `export.enter.before` | 665 MB | 150 MB | 617 MB | 1121 | 311.4 MB | 0 | `mask.boolean.bbox`: 980 / 228.8 MB; `matte.bbox`: 139 / 73.5 MB |
| `export.enter.after` | 632 MB | 151 MB | 589 MB | 1121 | 311.4 MB | 0 | Preview runtimes released for export mode, but preview pool still retains available textures |
| `export.frame.0` | 627 MB | 153 MB | 587 MB | n/a | n/a | n/a | Export starts from already-high Metal baseline |
| `export.frame.300` | 1244 MB | 198 MB | 1226 MB | n/a | n/a | n/a | `ExportVideoFrameProvider: 1` |
| `export.frame.600` | 1153 MB | 164 MB | 1131 MB | n/a | n/a | n/a | `ExportVideoFrameProvider: 1` |
| `export.frame.900` | 1913 MB | 418 MB | 1875 MB | n/a | n/a | n/a | `ExportVideoFrameProvider: 1` |
| `export.frame.1200` | 2427 MB | 280 MB | 2370 MB | n/a | n/a | n/a | Export peak captured in current logs; `ExportVideoFrameProvider: 2` |
| `export.complete.success` | 2013 MB | 280 MB | 1908 MB | n/a | n/a | n/a | `ExportVideoFrameProvider: 0`, but Metal remains high immediately after completion |
| `preview.restore.after` | 697 MB | 169 MB | 619 MB | n/a | n/a | n/a | Preview restored with `SceneInstanceRuntime: 3`, `VideoFrameProvider: 5` |

### TexturePool Growth Summary

| Stage | pool.avail count | pool.avail MB | mask.boolean.bbox | matte.bbox | Other owners |
|-------|------------------|---------------|-------------------|------------|--------------|
| Boot | 0 | 0 MB | -- | -- | -- |
| First captured playback stop | 240 | 104.7 MB | 240 / 104.7 MB | -- | -- |
| After scene/runtime growth | 481 | 212.2 MB | 400 / 151.9 MB | 80 / 55.8 MB | `isolatedGroup.fullTarget`: 1 / 4.5 MB |
| Late/final playback stop | 1111 | 308.2 MB | 972 / 227.3 MB | 137 / 71.9 MB | `isolatedGroup.fullTarget`: 1 / 4.5 MB; `matte.fullTarget`: 1 / 4.5 MB |
| Export enter | 1121 | 311.4 MB | 980 / 228.8 MB | 139 / 73.5 MB | `isolatedGroup.fullTarget`: 1 / 4.5 MB; `matte.fullTarget`: 1 / 4.5 MB |

### Scene / Video / Cache Context

| Checkpoint | sceneTypeCache | overlayCache | runtimes | videoProviders |
|------------|----------------|--------------|----------|----------------|
| `editor.boot.after` | n/a | n/a | n/a | n/a |
| First captured `playback.stop.after.2s` | 2 cached scene types, 4 textures, ~19.4 MB | 2 entries, 0.3 MB | 2 | 1 |
| Later `playback.stop.after.2s` | 3 cached scene types, 8 textures, ~36.1 MB | 5 entries, 0.4 MB | 2 | 2 |
| Late/final `playback.stop.after.2s` | 5 cached scene types, 27 textures, ~81.8 MB | 5 entries, 0.4 MB | 2 | 5 |
| `export.enter.after` | 5 cached scene types, 27 textures, ~81.8 MB | 5 entries, 0.4 MB | 0 | 0 |
| `preview.restore.after` | n/a in line | n/a in line | 3 | 5 |

### Instruments VM Tracker Snapshot

Captured after memory growth.

| Category | # Regs | Resident Size | Dirty Size | Swapped | Virtual Size | Notes |
|----------|--------|---------------|------------|---------|--------------|-------|
| `*All*` | 4377 | 749.44 MiB | 177.02 MiB | 32.00 KiB | 3.04 GiB | Overall process VM snapshot |
| `*Dirty*` | 371 | 182.17 MiB | 177.02 MiB | 32.00 KiB | 260.88 MiB | Dirty memory category |
| `IOSurface` | 6 | 101.27 MiB | 101.27 MiB | 0 B | 101.27 MiB | GPU/video/Metal-backed surface memory |
| `IOAccelerator` | 20 | 10.86 MiB | 10.86 MiB | 0 B | 10.89 MiB | GPU driver memory |
| `MALLOC_SMALL` | 5 | 20.31 MiB | 18.86 MiB | 0 B | 28.00 MiB | Heap is not the dominant source |
| `Performance tool data` | 11 | 32.94 MiB | 32.94 MiB | 0 B | 34.17 MiB | Instruments overhead/data |

### Metal Resource Events

Current PR0b run does not include a recorded Metal Resource Events table in this document. Use VM Tracker + MEM-DIAG `metal:` / `TexturePool.debugSnapshot()` as the baseline for PR 1. If Metal Resource Events are collected later, attach them as an addendum instead of blocking PR 1.

## 5. Baseline Findings

### Finding 1: Preview memory growth is Metal/IOSurface-backed, not Swift heap

Evidence:

- Xcode Memory gauge reached 830.9 MB while FPS stayed at 30 FPS.
- VM Tracker shows `IOSurface` at 101.27 MiB and `IOAccelerator` at 10.86 MiB in the captured snapshot.
- `MALLOC_SMALL` is only 20.31 MiB, so Swift/heap allocations do not explain the Xcode Memory number.
- MEM-DIAG `metal:` grew from 11 MB at boot to 773 MB at late/final playback stop.

Conclusion:

The baseline supports the existing diagnosis: this is GPU/Metal/IOSurface-backed resource retention, not a normal Swift retain-cycle leak.

### Finding 2: TexturePool.available grows while TexturePool.inUse returns to 0

Evidence:

- Boot: `pool.avail = 0`.
- First captured playback stop: `pool.avail = 240 / 104.7 MB`.
- Later playback stop: `pool.avail = 481 / 212.2 MB`.
- Late/final playback stop: `pool.avail = 1111 / 308.2 MB`.
- `pool.inUse = 0` at all captured stop checkpoints.

Conclusion:

Textures are not stuck as active/in-use. They are being returned to the pool, then retained indefinitely as available reusable textures. The missing piece is bounded lifecycle policy: budget, eviction, trim.

### Finding 3: Main owner is mask.boolean.bbox, second owner is matte.bbox

Late/final playback stop owner breakdown:

- `mask.boolean.bbox`: 972 textures / 227.3 MB.
- `matte.bbox`: 137 textures / 71.9 MB.
- `isolatedGroup.fullTarget`: 1 texture / 4.5 MB.
- `matte.fullTarget`: 1 texture / 4.5 MB.

Conclusion:

The main preview growth is high-cardinality bbox scratch textures, not full-target isolated group textures.

### Finding 4: SceneTypeResourcesCache grows, but it is not the primary source in this baseline

Evidence:

- Late/final `sceneTypeCache`: 5 cached scene types, 27 textures, ~81.8 MB.
- Late/final `TexturePool.available`: 1111 textures, ~308.2 MB.

Conclusion:

Scene type cache contributes to memory, but the primary proven target for PR 1 is `TexturePool`.

### Finding 5: Export has separate high Metal peak and must remain in scope

Evidence:

- `export.frame.1200`: footprint 2427 MB, metal 2370 MB.
- `export.complete.success`: footprint 2013 MB, metal 1908 MB.
- `preview.restore.after`: footprint 697 MB, metal 619 MB.

Conclusion:

Task 3 must still include preview/export resource separation and export terminal cleanup. However, PR 1 should focus first on bounded preview `TexturePool`, because that source is directly attributed by owner breakdown.

## 6. Expected Evidence After Refactor

What should change after PR 1-4:

- `pool.avail` reaches plateau within configured budget, initially evaluated at 128 / 192 / 256 MB in PR 4 device tuning.
- Footprint does not grow monotonically through repeated play/pause cycles.
- `inUse` returns to 0 after stop + GPU completion. This already works and must not regress.
- Close/reopen delta should remain below 30-50 MB after warmup.
- `IOSurface` / `IOAccelerator` should not grow monotonically across repeated cycles.
- No visible preview degradation.
- No repeatable FPS drop below 30 FPS.
- Export success/cancel/failure should not leave export-only resources retained after preview restore.

## 7. Diagnostics Layer Reference

Current diagnostics layer:

- `MemoryDiagnostics.checkpoint(name, metal:)` logs footprint, resident, available memory, Metal allocated size, and object counters.
- Launch flag `-DebugMemoryDiagnostics YES` enables checkpoints.
- Launch flag `-DebugMemoryDiagnosticsVerbosePool YES` adds pool owner/key breakdown. Use this only for short attribution runs.
- `TexturePool.debugSnapshot()` reports available/inUse/owner attribution.
- Checkpoints used in this baseline:
  - `editor.boot.before`
  - `editor.boot.after`
  - `playback.start`
  - `playback.stop.before`
  - `playback.stop.after`
  - `playback.stop.after.2s`
  - `export.enter.before`
  - `export.enter.after`
  - `export.frame.N`
  - `export.complete.success`
  - `preview.restore.after`

## PR 0b Status

PR 0b is sufficient to proceed to PR 1.

Reason:

- The play/pause baseline already proves monotonic `TexturePool.available` growth.
- Owner attribution identifies `mask.boolean.bbox` and `matte.bbox`.
- `inUse = 0` proves textures are returned but retained.
- VM Tracker confirms the memory class is VM/IOSurface/Metal-backed rather than Swift heap.
- Fast scrub checkpoint is missing, but that is a diagnostic coverage limitation and does not block bounded exact-size `TexturePool`.

