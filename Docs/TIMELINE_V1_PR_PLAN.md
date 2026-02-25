# TIMELINE_V1_PR_PLAN

> **Purpose:** A release-grade PR plan that implements `TIMELINE_V1_SPEC_FINAL`.  
> **Rule:** PR scopes are defined to keep merges safe and to ensure each PR has clear acceptance + test coverage.

---

## 0) Overview

### Milestones
- **Milestone A — Timeline Core (PR1–PR4):** final architecture for model/store/ui/perf; scenes timeline fully migrated and stable.
- **Milestone B — V1 Features on top of Core (PR5–PR8):** Audio, Stickers, Text, Export alignment — implemented without changing core architecture.

### Non-negotiables
- No parallel “truths” (`ProjectDraft.scenes` + frame-based `timeline`) after PR1 merge.
- No direct model mutations from `PlayerViewController` after PR3 merge.
- Reducer is the only writer of model state (except migration code).

---

## PR1 — Canonical Timeline v4 model + migration (Big Bang) ✅ Done

### Goal
Replace frame-based placeholder `Timeline` and parallel `scenes[]` with **one canonical microseconds timeline (schema v4)**.

### Scope
- Add new canonical timeline model types:
  - `TrackKind` includes at minimum: `sceneSequence`, `audio`, `overlay`
  - `ItemKind` includes at minimum: `scene`, `audioClip`, `sticker`, `text`
  - Payload registries exist for: scene/audio/sticker/text (sticker/text payload can be minimal in Core)
- Persist canonical timeline in `ProjectDraft` and remove persisted dual truths:
  - `ProjectDraft.scenes` is migrated and no longer used as editor truth
  - old frame-based `Timeline` is removed from editor truth
- Bump schema v3 → v4; migrate at load time:
  - v3 `draft.scenes` → v4 `sceneSequence` track items
  - enforce min scene duration `100_000 us` (auto-extend + toast once)

### Code touch points
- `AnimiApp/Sources/Project/ProjectDraft.swift`
- `AnimiApp/Sources/Project/Timeline.swift` (replace or supersede)
- Project load/save pipeline (schemaVersion + migration)

### Tests
- Unit: v3 sample → v4 conversion
- Unit: min duration normalization
- Unit: Codable roundtrip of v4 timeline + payload registries

### Acceptance
- v3 projects open and persist as v4.
- Scene duration sum in v4 equals previous computed duration.

---

## PR2 — EditorStore/Reducer + Undo/Redo + core invariants ✅ Done

### Goal
Introduce canonical edit engine; ensure scene operations are model-driven and undoable.

### Scope
- Add `EditorAction`, `EditorReducer`, `EditorStore`.
- Add snapshot undo/redo stack (limit = `EditorConfig.undoStackLimit`).
- Implement core reducer capabilities:
  - Scene trim (commit on `.ended`) + minDuration enforcement (0.1s)
  - Scene reorder (model support; UI comes PR3)
  - Scene sequence normalization (derived startUs)
  - Shift-left policy applied to **all non-scene items** on project shorten
  - Playhead rules: restore+clamp; follow scene on reorder (relative offset)

### Tests (mandatory)
- Reducer: trim shorten → shift-left applied → undo restores previous model (single step)
- Reducer: reorder → playhead follows same scene (relative offset mapping)
- Reducer: minDuration enforcement

### Acceptance
- Reducer is pure/deterministic and fully unit-tested for invariants.
- No model mutations outside store (except migration).

---

## PR3 — Scene timeline UI wired to Store + Reorder mode ✅ Done

### Goal
Make scene timeline UI snapshot-driven; ship reorder mode.

### Scope
- Replace `PlayerViewController.handleTrimScene` model writes with store dispatch.
- `TimelineView` stops owning `scenes` as truth; renders store snapshots.
- `EditorLayoutContainerView.currentSelection` is removed as separate truth; reflect store selection.
- Implement “Reorder mode” in timeline toolbar:
  - drag & drop reorder
  - trim disabled in reorder mode
  - scroll remains enabled
  - ghost + live insertion shift feedback

### Code touch points
- `AnimiApp/Sources/Player/PlayerViewController.swift`
- `AnimiApp/Sources/Editor/TimelineView.swift`
- `AnimiApp/Sources/Editor/EditorLayoutContainerView.swift`
- Scene track views/clip views as needed for reorder gestures

### Manual QA checklist
- Trim works; commit on end produces a single undo step
- Reorder works without gesture conflicts
- Undo/redo works for trim and reorder

### Acceptance
- No direct writes to legacy `draft.scenes` from VC.
- Reorder mode UX matches spec.

---

## PR4 — Layout/Data split + base Track/Clip contracts (+ DEBUG instrumentation) ✅ Done

### Goal
Eliminate layout/data mixing and make UI scalable for Audio/Stickers/Text.

### Scope
- Refactor Scene track:
  - `applySnapshot(data)` vs `layoutItems(layoutContext)`
  - `pxPerSecond` is layout-only; remove from data configure
- Introduce base contracts to be reused by future tracks:
  - `TrackView` pattern (snapshot in, layout context in)
  - `ClipView` pattern (apply snapshot, layout, gestures)
- Add DEBUG-only instrumentation (`#if DEBUG`):
  - counters/signposts around data apply vs layout
  - threshold checks during scroll/zoom

### Acceptance
- During continuous scroll/zoom: data apply calls are 0 (≤1 at begin/end).
- Scene layout remains correct for different zoom levels and during scrub/center operations.

---

# Milestone A complete: Timeline Core

After PR4:
- v4 timeline is canonical single truth
- store/reducer + undo exists
- scene UI is store-driven + reorder mode ships
- perf architecture ready for audio/stickers/text without core refactors

---

## PR5 — Audio V1 (CRUD + file import + timeline UI)

### Goal
Implement audio editing on top of Timeline Core.

### Scope
- Audio tracks + clips:
  - overlap allowed
  - move/trim/delete
  - volume field persisted (UI may be minimal in V1, but model must support)
- Import:
  - UIDocumentPicker → copy to `<AppSupport>/<projectId>/audio/<clipId>.<ext>`
  - store `AudioAssetRef.imported(relativePath:)`
  - bundled SFX IDs supported (catalog UI optional)
- Undo/redo:
  - one step per completed gesture/action

### Acceptance
- Audio clips participate in shift-left on shorten.
- Audio operations are undoable.

---

## PR6 — Stickers V1 (bundled pack) on timeline

### Goal
Implement sticker overlays as timeline items using bundled assets.

### Scope
- Bundled sticker pack IDs + lookup
- Sticker overlay item kind + payload ref
- Timeline operations: add/move/trim/delete
- Undo/redo support

### Acceptance
- Stickers shift-left on shorten (non-scene item rule).
- No Photos/Files import in V1.

---

## PR7 — Text V1 (highly configurable) on timeline

### Goal
Implement text overlay items with rich payload and timeline operations.

### Scope
- Text overlay item kind + payload registry
- Timeline operations: add/move/trim/delete
- Rich text payload editing:
  - font, color, size
  - animation parameters (structure defined in payload)
- Undo/redo:
  - text edits are undoable; commit strategy defined per editor UI (e.g., commit on “Done”)

### Acceptance
- Text edits do not require changes to core timeline model shape.
- Text appears at correct times in preview.

---

## PR8 — Export alignment (adapter layer) for v4 timeline (duration + audio + overlays)

### Goal
Guarantee preview == export by reading canonical timeline.

### Scope
- Export duration derived from v4 scene sequence sum.
- Adapter converts:
  - audio clips → existing export audio config
  - overlay items (sticker/text) → existing export overlay timing/payload inputs (or equivalent)
- Export reads canonical v4 timeline only.

### Acceptance
- Export duration matches editor duration.
- Audio overlaps mix correctly.
- Stickers/text appear at correct times.

---

## Release checklist (post-PR8)
- No legacy time truths used by editor or export
- Undo/redo stable across scene/audio/overlay operations
- Performance: no data applies during scroll/zoom in release code (instrumentation is DEBUG-only)
- Migration: v3 projects load into v4 reliably
