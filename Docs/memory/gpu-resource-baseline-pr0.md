# GPU Resource Lifecycle — Baseline & Measurement Protocol

## 1. Environment (TBD — filled in PR 0b)

| Field | Value |
|-------|-------|
| Diagnostics branch/SHA | `codex/memory-diagnostics-layer2` / `<SHA>` |
| Device model | TBD |
| iOS version | TBD |
| Xcode version | TBD |
| Template / project | TBD |

## 2. Reproduction Scenario

Exact scenarios for reproduction and future before/after comparison:

1. **play/pause cycle**: open -> play/pause 10 times -> measure
2. **fast scrub**: fast scrub 30-60 sec across timeline -> measure
3. **multi-scene**: 20 scenes + video + masks + matte + stickers + animated text -> play -> measure
4. **export round-trip**: export -> preview restore -> close -> reopen -> measure
5. **scene switch**: forward/back scene switch 10 times -> measure

## 3. Measurement Instructions

### Launch flags

**Main run (summary logs):**
```
-DebugMemoryDiagnostics YES
```

**Separate short run (owner/key attribution):**
```
-DebugMemoryDiagnostics YES
-DebugMemoryDiagnosticsVerbosePool YES
```

Verbose pool generates heavy logs — use only for a short attribution run, not for a full 10-cycle measurement.

### Data to capture at each step

- **Xcode Memory gauge**: peak MB, plateau MB after stop
- **MEM-DIAG checkpoints** (from Xcode console):
  - `editor.boot.before` / `editor.boot.after`
  - `playback.start` / `playback.stop.before` / `playback.stop.after` / `playback.stop.after.2s`
  - `export.enter.before` / `export.complete` (if applicable)
- **TexturePool snapshot** from MEM-DIAG:
  - `pool | avail: N (X MB) | inUse: N (~X MB) | total: ~X MB`
  - `pool.owner` breakdown
- **Instruments VM Tracker** (if available): IOSurface, IOAccelerator, Dirty, resident/footprint
- **Metal Resource Events** (if available): allocation churn, live resource count
- **MTLDevice.currentAllocatedSize** (from MEM-DIAG `metal:` field)

## 4. Baseline Results (TBD — filled in PR 0b)

### Per-scenario checkpoint table

| Checkpoint | footprint | metal | pool.avail (count) | pool.avail (MB) | pool.inUse | owners |
|-----------|-----------|-------|--------------------|-----------------|------------|--------|
| editor.boot.before | TBD | TBD | TBD | TBD | TBD | TBD |
| editor.boot.after | TBD | TBD | TBD | TBD | TBD | TBD |
| playback.stop (cycle 1) | TBD | TBD | TBD | TBD | TBD | TBD |
| playback.stop (cycle 5) | TBD | TBD | TBD | TBD | TBD | TBD |
| playback.stop (cycle 10) | TBD | TBD | TBD | TBD | TBD | TBD |
| after scrub 30s | TBD | TBD | TBD | TBD | TBD | TBD |
| export.complete | TBD | TBD | TBD | TBD | TBD | TBD |
| preview restore | TBD | TBD | TBD | TBD | TBD | TBD |

### Instruments VM Tracker

| Category | Before playback | After 10 cycles | After scrub |
|----------|----------------|-----------------|-------------|
| IOSurface | TBD | TBD | TBD |
| IOAccelerator | TBD | TBD | TBD |
| Dirty | TBD | TBD | TBD |
| Footprint | TBD | TBD | TBD |

## 5. Known Preliminary Evidence

Preliminary data from `logs.md` (branch `codex/memory-diagnostics-layer2`).

**These numbers:**
- are **not** the acceptance baseline
- are **not used** for before/after comparison
- exist only as evidence of the problem direction
- **must be replaced** by the final device run in PR 0b

### Observation: TexturePool.available grows monotonically

| Moment | footprint | metal | pool.avail (count) | pool.avail (MB) | Top owners |
|--------|-----------|-------|--------------------|-----------------|------------|
| editor.boot.after | 54 MB | 11 MB | 0 | 0 | -- |
| playback.stop (cycle 1) | 232 MB | 196 MB | 240 | 104.7 MB | mask.boolean.bbox: 240 (104.7 MB) |
| playback.stop (cycle 2) | 232 MB | 196 MB | 240 | 104.7 MB | mask.boolean.bbox: 240 (104.7 MB) |
| playback.stop (after scene switch) | 542 MB | 499 MB | 481 | 212.2 MB | mask.boolean.bbox: 400 (151.9 MB), matte.bbox: 80 (55.8 MB) |
| playback.stop (later) | 840 MB | 787 MB | 1107 | 307.9 MB | mask.boolean.bbox: 967 (227.0 MB), matte.bbox: 138 (71.8 MB) |

### Preliminary conclusions

1. `pool.avail` grows: 0 -> 240 -> 481 -> 1107 textures (0 -> 104.7 -> 212.2 -> 307.9 MB)
2. `pool.inUse` is always 0 after stop — textures are correctly returned
3. Top consumers: `mask.boolean.bbox` (~74% MB), `matte.bbox` (~23% MB)
4. `isolatedGroup.fullTarget` and `matte.fullTarget` — single instances, do not grow
5. Metal allocated grows in parallel: 11 -> 196 -> 499 -> 787 MB
6. Footprint grows: 54 -> 232 -> 542 -> 840 MB
7. No eviction, no plateau — growth is limited only by session duration

## 6. Expected Evidence After Refactor

What should change after PR 1-4:

- `pool.avail` reaches plateau within configured budget (initially evaluated at 128 / 192 / 256 MB; exact value determined in PR 4 device tuning)
- Footprint does not grow monotonically through 10 play/pause cycles
- `inUse` returns to 0 after stop + GPU completion (already works)
- Close/reopen delta < 30-50 MB after warmup
- IOSurface/IOAccelerator do not grow monotonically
- No visible preview degradation
- No repeatable FPS drop below 30 FPS

## 7. Diagnostics Layer Reference

Current diagnostics layer (branch `codex/memory-diagnostics-layer2`):

- **MemoryDiagnostics.swift**: `MemoryDiagnostics.checkpoint(name, metal:)` — logs footprint, resident, available, metal allocated
- **Launch flag**: `-DebugMemoryDiagnostics YES` enables all checkpoints
- **Verbose pool**: `-DebugMemoryDiagnosticsVerbosePool YES` adds per-key breakdown (use only for a short attribution run)
- **TexturePool.debugSnapshot()**: thread-safe snapshot of available/inUse/owners
- **Checkpoints in code**: editor.boot.before/after, playback.start/stop.before/stop.after/stop.after.2s, export.enter.before/export.complete
