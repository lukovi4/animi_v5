# TIMELINE_V1_SPEC

> **Scope:** Editor + Timeline (UIKit) in `AnimiApp` snapshot.  
> **Rule:** This spec is grounded in the current codebase. Every statement about *current behavior* is backed by a code anchor (path + line range).  
> **Goal:** Build a release-ready V1 timeline architecture that supports:
> - Scene sequence (no gaps) + **reorder scenes**
> - Multi-track audio (move/trim later OK, but model must exist now)
> - Absolute-time overlays are **NOT** required in V1 (snapping removed), but **non-scene items must be shifted left** when project duration is reduced (see §4)
> - Undo/Redo in V1 (model-level, one-step undo for compound edits)

---

## 1) Snapshot reality (what exists today)

### 1.1 Two concurrent “truths” in project model
`ProjectDraft` currently stores both a frame-based `timeline` and a microsecond-based `scenes` array.

**Anchor — `ProjectDraft.timeline` + `ProjectDraft.scenes`:**  
`AnimiApp/Sources/Project/ProjectDraft.swift:76–88`
```swift
  76 // MARK: - Timeline
  78 /// Timeline with layer items (optional in P0).
  80 public var timeline: Timeline?
  82 // MARK: - Scenes (PR2: Multi-scene support)
  84 /// Array of scenes in the project timeline (v3 schema).
  87 public var scenes: [SceneDraft]?
```

**Implication (current code):** the app can read/write time in two separate representations depending on which path is active.

---

### 1.2 Current `Timeline` type is a frame-based placeholder
The current `Timeline` is `layers: [LayerItem]` with `startFrame/endFrame` and limited `LayerKind` to `.sceneBase` + `.audio` (placeholder).

**Anchor — placeholder timeline definition:**  
`AnimiApp/Sources/Project/Timeline.swift:5–33, 37–67`
```swift
  8 public struct Timeline: Codable, Equatable, Sendable {
 11     public var layers: [LayerItem]
 ...
 24 public enum LayerKind: String, Codable, Sendable {
 27     case sceneBase
 30     case audio  // placeholder
 32     // Future: text, sticker, image, etc.
 33 }
 ...
 47 public var startFrame: Int
 51 public var endFrame: Int
```

**Implication (current code):** this `Timeline` cannot represent the V1 requirements (multi-track, movable audio clips, overlays with time ranges) without redesign.

---

### 1.3 Current Editor “source of truth” is inside `TimelineView` + `PlayerViewController`
#### TimelineView stores scenes + duration and derives duration by summing scene durations
**Anchor — `TimelineView.configure(scenes:)` derives `durationUs` and uses min=1 frame:**  
`AnimiApp/Sources/Editor/TimelineView.swift:313–325`
```swift
 317 func configure(scenes: [SceneDraft], templateFPS: Int) {
 318     self.scenes = scenes
 319     self.durationUs = scenes.reduce(0) { $0 + $1.durationUs }
 ...
 323     let minDurationUs = framesToDurationUs(1, fps: self.templateFPS)
 324     sceneTrack.configure(scenes: scenes, pxPerSecond: pxPerSecond, leftPadding: padding, minDurationUs: minDurationUs)
 }
```

#### Model commit for trim happens directly in `PlayerViewController`
**Anchor — direct mutation of draft on trim end (and min=1 frame):**  
`AnimiApp/Sources/Player/PlayerViewController.swift:681–721`
```swift
 696 let minDurationUs = framesToDurationUs(1, fps: fps) // At least 1 frame
 ...
 706 case .ended:
 708     let totalDurationUs = scenes.reduce(0) { $0 + $1.durationUs }
 711     draft.scenes = scenes
 712     draft.projectDurationUs = totalDurationUs
 717     editorController.durationUs = totalDurationUs
```

**Implication (current code):** mutations are spread across VC and views; this blocks release-grade undo/redo and consistent model ownership.

---

### 1.4 Scene track layout is already “sequence without gaps” (UI-level)
`SceneTrackView.updateClipLayouts()` places scenes back-to-back by accumulating `currentX += clipWidth`.

**Anchor — sequence placement + configure called on every layout pass:**  
`AnimiApp/Sources/Editor/SceneTrackView.swift:150–174`
```swift
150 private func updateClipLayouts() {
151     var currentX = leftPadding
153     for scene in scenes {
156         let clipWidth = CGFloat(usToSeconds(scene.durationUs)) * pxPerSecond
159         clipView.frame = CGRect(x: currentX, y: 0, width: clipWidth, height: bounds.height)
165         clipView.configure(durationUs: scene.durationUs, pxPerSecond: pxPerSecond, minDurationUs: minDurationUs)
167         currentX += clipWidth
168     }
}
171 override func layoutSubviews() { updateClipLayouts() }
```

**Implication (current code):**
- Sequence logic currently exists only in **UI layout**, not as a model invariant.
- Layout/data mixing exists: `configure(...)` is called inside layout loop and on every `layoutSubviews()`.

---

### 1.5 Unified timeline event stream exists (good foundation)
**Anchor — `TimelineEvent` unified stream:**  
`AnimiApp/Sources/Editor/TimelineEvents.swift:5–45`
```swift
  7 public enum InteractionPhase { case began, changed, ended, cancelled }
 22 public enum TimelineEvent: Sendable {
 27     case scrub(timeUs: TimeUs, quantize: QuantizeMode, phase: InteractionPhase)
 33     case scroll(offsetX: CGFloat, pxPerSecond: CGFloat)
 37     case selection(TimelineSelection)
 44     case trimScene(sceneId: UUID, newDurationUs: TimeUs, edge: TrimEdge, phase: InteractionPhase)
 }
```

---

### 1.6 UI/editor state is currently dispersed
- `TemplateEditorController.state` stores `currentPreviewTimeUs` (source of truth for preview time) and derived `currentPreviewFrame`.  
  **Anchor:** `AnimiApp/Sources/Editor/TemplateEditorController.swift:6–21`
- `EditorLayoutContainerView` holds its own `currentSelection`.  
  **Anchor:** `AnimiApp/Sources/Editor/EditorLayoutContainerView.swift:75–78`

```swift
// TemplateEditorController.swift:6–21
var currentPreviewTimeUs: TimeUs = 0
var currentPreviewFrame: Int = 0 // derived
var timelineSelection: TimelineSelection = .none

// EditorLayoutContainerView.swift:75–78
private var currentSelection: TimelineSelection = .none
```

---

### 1.7 Audio track is a placeholder (no items)
**Anchor — AudioTrackView explicitly described as placeholder:**  
`AnimiApp/Sources/Editor/AudioTrackView.swift:3–17`
```swift
 5 /// Placeholder track for audio layer.
 6 /// Shows an empty track with "Audio" label (no functionality in PR2).
12 private var durationUs: TimeUs = 0
15 private var pxPerSecond: CGFloat = EditorConfig.basePxPerSecond
```

---

## 2) V1 Product constraints (confirmed decisions)

These are **product decisions** provided by the lead (not inferred from code):

- **Scenes are always a sequence**: no empty space between scenes.
- **Reorder scenes** is required in V1 (moves scene item + payload together).
- **Snapping is not required** in V1.
- **Split/Razor is NOT in V1**, but must be possible in future without redesign.
- **Undo/Redo is required in V1.**
- **Min scene duration** in V1: **0.1 seconds** (`100_000 us`).
  - Note: current code uses “≥ 1 frame” (see anchors above).
- **When project duration shrinks** (e.g., scene trim): **non-scene items should shift left by delta**, rather than being deleted.
- “Shift-left + any necessary clamp” must be part of the **same undo step** as the trim that caused the duration change.

---

## 3) Canonical ownership model for V1 (what changes)

### 3.1 One model truth: Timeline must become the single time source
Current: two truths (`ProjectDraft.timeline` frames + `ProjectDraft.scenes` microseconds).  
Target V1: **single** timeline model stored in the project draft, time in **microseconds**, with tracks/items.

**Grounding:** current placeholder `Timeline` is frame-based and limited to `.sceneBase/.audio` (see §1.2), and editor already uses `TimeUs` throughout (see §1.3/§1.5/§1.6/§1.7).

#### Migration requirement
Because `ProjectDraft.scenes` exists in snapshot schema, V1 must provide a migration path:
- `draft.scenes` → Scene track items in the new timeline model.
- Legacy fallback currently exists when `scenes == nil` (documented in `ProjectDraft` comments; see §1.1).

---

### 3.2 Centralize edits: remove direct draft mutation from VC
Current: `PlayerViewController.handleTrimScene` commits directly to `draft.scenes` and `draft.projectDurationUs`.  
**Anchor:** `PlayerViewController.swift:681–721` (see §1.3)

Target V1:
- VC becomes a host that dispatches actions and renders state.
- All model mutations (trim/reorder/insert/remove audio items) go through a single edit engine.

---

### 3.3 Undo/Redo pattern (answer to programmer Q1)
**Decision:** Snapshot/Memento (stack-based snapshots), limit 50.

**Why anchored to code:** `EditorConfig.undoStackLimit = 50` exists in snapshot (programmer referenced it; ensure it remains the controlling limit).  
If `undoStackLimit` exists elsewhere in the snapshot, the implementation must use that constant as the limit.

**What snapshots contain (V1):**
- Model: new timeline model (single truth)
- UI essentials: `playheadTimeUs` + `selection` (recommended)
- After restoring a snapshot, `playheadTimeUs` is clamped to `durationUs` (see §3.6).

---

### 3.4 Where state lives (answer to programmer Q2)
**Decision:** Introduce a new `EditorStore`/`EditorReducer` responsible for:
- Model edits (timeline)
- Timeline UI state (zoom, scroll offsets, selection, playhead)

`TemplateEditorController` remains responsible for:
- Rendering coordination and frame quantization derived from `timeUs`  
**Anchor:** derived frame already exists: `TemplateEditorController.swift:11–16` (see §1.6)

---

### 3.5 Audio/Overlays scope (answer to programmer Q3)
**Decision:** Model structures for **non-scene items must exist in V1**, even if UI is incremental, because:
- shift-left policy is defined specifically for **non-scene items**
- multi-track audio editing is part of V1 requirements
- Audio UI is currently a placeholder (see §1.7), so V1 work must fill the gap.

---

### 3.6 Min scene duration migration (answer to programmer Q4)
Current: min duration is enforced as `framesToDurationUs(1, fps:)`.  
**Anchors:** `TimelineView.swift:323`, `PlayerViewController.swift:696` (see §1.3)

Decision: V1 min duration is `100_000 us` (0.1s).
- On project load / migration, any scene shorter than min is raised to min and the sequence is renormalized.
- This is a breaking behavior change but is required to align model + UI constraints.

---

### 3.7 pxPerSecond is layout-only (answer to programmer Q5)
Current: `SceneClipView.configure(durationUs:pxPerSecond:minDurationUs)` stores `pxPerSecond` as data.
**Anchor:** `AnimiApp/Sources/Editor/SceneClipView.swift:171–175`  
```swift
func configure(durationUs: TimeUs, pxPerSecond: CGFloat, minDurationUs: TimeUs) {
    self.durationUs = durationUs
    self.pxPerSecond = pxPerSecond
    self.minDurationUs = minDurationUs
}
```

Decision:
- `pxPerSecond` must move to layout-only code paths (e.g., `layoutItems(state)`), not `applySnapshot(data)`.
- Remove the `pxPerSecond` parameter from “data configure” and keep it only where frames are computed or gestures convert px↔time.

---

### 3.8 Playhead behavior on undo (answer to programmer Q6)
Decision:
- Undo/redo restores playhead time from snapshot.
- After restore, playhead is clamped to `[0, durationUs]`.
- If restoring playhead exactly is not desired later, this is the default V1 behavior (simple and predictable).

---

### 3.9 Export pipeline coupling (answer to programmer Q7)
Decision:
- Export must read the same canonical timeline model as the editor to guarantee preview == export.
- This does not require rewriting renderer, but requires updating the export data source so that time ranges and track items come from the canonical timeline.

---

## 4) Shift-left policy when project duration shrinks (V1 canonical rule)

This is a **V1 rule** that is not implemented in the snapshot (because non-scene items don't exist yet in editor UI), but must be implemented in the new canonical edit engine.

Let:
- `oldDurationUs` = duration before edit
- `newDurationUs` = duration after edit
- `deltaUs = oldDurationUs - newDurationUs` (only if positive)

When `deltaUs > 0`:
- For every non-scene item (audio, overlays) in every non-scene track:
  - `newStartUs = max(0, oldStartUs - deltaUs)`
  - Keep the item’s **intended duration** unless it physically cannot fit:
    - `newDurationUsItem = min(oldDurationUsItem, max(0, newDurationUs - newStartUs))`

Notes:
- This preserves “length of the clip” as much as possible while keeping it within the new project duration.
- This shift happens only on **project shorten** events (e.g., trimming a scene shorter). Reorder does not change duration; therefore no shift-left is applied.

Undo/redo:
- Trim + normalize + shift-left must be a **single undoable operation**.

---

## 5) Scene track is a *sequence invariant* (not just UI layout)

Current scene sequence behavior exists only in UI (`SceneTrackView.updateClipLayouts`, §1.4).  
V1 must enforce it as a data invariant.

**Invariant:**
- Scenes are stored in order in a scene-sequence track.
- Start times are derived by cumulative sum (no gaps).

**Operations V1:**
- `trimScene(sceneId, newDurationUs)` — applies min duration 0.1s.
- `reorderScene(sceneId, toIndex)` — moves entire item+payload.

**Future compatibility:**
- Split/Razor is not in V1, but the model must remain compatible with it (item has start/duration → split can later produce two items).

---

## 6) UI refactor: separate “data apply” vs “layout” (fix layout/data mixing)

### 6.1 Problem in current code
`SceneTrackView.layoutSubviews()` calls `updateClipLayouts()` and inside it calls `clipView.configure(...)` (data) every time.

**Anchor:** `SceneTrackView.swift:150–174` (see §1.4)

### 6.2 V1 requirement
Introduce two distinct update paths:

1) **Data path** — called only when items/data changes:
- create/delete views by ID (diff)
- set selection state
- set minDurationUs (0.1s) and any non-layout properties

2) **Layout path** — called frequently (scroll/zoom/layoutSubviews):
- set `clipView.frame`
- set handle positions
- pass `pxPerSecond` only to layout math / gesture conversions

**Acceptance measurement (for programmer’s “how to measure”):**
- Add debug counters or os_signpost around data apply vs layout.
- During scroll/zoom, data apply count should remain ~0; layout count may be high.

---

## 7) Canonical “action surface” (events → actions)

Current UI emits `TimelineEvent` (unified stream).  
**Anchor:** `TimelineEvents.swift:20–45` (see §1.5)

V1: keep a single stream, but map into edit-engine actions:
- Scroll/zoom events update UI state (store)
- Trim/reorder update model state (store + reducer + undo snapshot)
- VC no longer directly mutates `ProjectDraft` (see §1.3)

---

## 8) Implementation checklist (work items tied to current code)

### 8.1 Model unification (ProjectDraft)
- Replace frame-based `Timeline` (`Project/Timeline.swift`) with a microseconds-based timeline model (tracks/items).
- Remove `ProjectDraft.scenes` as a parallel persisted “truth”; migrate it into the new timeline.
  - Grounding: `ProjectDraft` currently says when scenes is nil, fall back to legacy behavior (§1.1).

### 8.2 Remove direct mutations from `PlayerViewController.handleTrimScene`
- Replace with dispatch to edit engine.
  - Grounding: `handleTrimScene` currently commits directly (§1.3).

### 8.3 Min duration change (0.1s)
- Replace `framesToDurationUs(1, fps:)` enforcement in:
  - `TimelineView.configure(scenes:)` (§1.3)
  - `PlayerViewController.handleTrimScene` (§1.3)

### 8.4 Scene reorder
- Add reorder UI interaction (drag reorder) and action.
- Update scene-sequence invariant.

### 8.5 Non-scene items model + shift-left
- Introduce audio item track structures and connect to editor UI (AudioTrackView currently placeholder, §1.7).
- Implement shift-left on project shorten in reducer.

### 8.6 Undo/Redo
- Implement snapshots with limit 50.
- Ensure “trim + shift-left” is one undo step.

### 8.7 State centralization
- Remove `EditorLayoutContainerView.currentSelection` as a separate truth (it must reflect store state).
  - Grounding: `EditorLayoutContainerView.swift:75–78` (§1.6)

### 8.8 Layout/data split
- Refactor `SceneTrackView` + `SceneClipView` to remove pxPerSecond from data config and avoid configure calls from layout.
  - Grounding: `SceneTrackView.swift:150–174`, `SceneClipView.swift:171–175` (§1.4/§3.7)

### 8.9 Export alignment
- Update export source-of-truth to read the canonical timeline model.
  - (Exact export anchors not included here because the export files are outside the Editor subset; this is still a required integration task.)

---

## 9) Acceptance Criteria (release-ready)

1) **Single truth:** project time model is stored in one timeline representation (microseconds-based); no parallel `scenes[]` truth used by editor.
2) **Sequence scenes:** scene track has no gaps; reorder works; trim respects min 0.1s.
3) **Shift-left rule:** shortening the project shifts non-scene items left by delta; items remain within the new duration; compound edit is 1 undo step.
4) **Undo/redo:** restores model snapshot and playhead; playhead is clamped post-restore.
5) **No layout/data mixing:** scrolling/zooming does not trigger data apply/configure loops; only layout updates happen frequently.
6) **Future-proof:** model supports future split/razor without redesign (items have start/duration, tracks support multiple items).

---



---

## 11) Resolved questions (lead decisions) — NO OPEN ITEMS

This section answers all questions from the implementation audit and is **binding** for V1.

### 11.1 Audio / non-scene items scope in V1
**Decision:** **C) Full CRUD** for Audio clips in V1.
- Model must support: multiple audio tracks, multiple clips per track, overlapping allowed.
- UI must support: add/import audio, show clips, move in time, trim duration, delete.
- Shift-left policy (§4) applies to these items.

**Audio file sources (V1):**
- **Device Files** (`UIDocumentPicker`): supported.
- **In-app bundled SFX library** (app-provided assets): supported.
- Import from URL: **not in V1**.

> Grounding: `AudioTrackView` is a placeholder today (§1.7), so V1 must implement both model + UI, otherwise shift-left policy is untestable in-app.

### 11.2 Shift-left policy edge cases
#### 11.2.1 If `newDurationUsItem == 0`
**Decision:** **Delete the item** from the model.
- Undo snapshot restores it (so user can recover).
- Rationale: zero-length items are invalid for rendering/export and complicate UI hit-testing.

#### 11.2.2 Overlaps after shift-left
**Decision:** **Allow overlap** on audio tracks.
- Overlapping audio clips are mixed during playback/export.
- No automatic cascade/stack in V1.
- Users can manually separate clips by moving them.

### 11.3 Scene reorder — UI interaction in V1
**Decision:** **Dedicated “Reorder” mode** (Variant C).
- Rationale: avoids gesture conflicts with trim handles and scroll, produces predictable release UX.
- UX:
  - Button “Reorder” toggles mode ON/OFF.
  - In Reorder mode: drag clips to reorder; trimming disabled.
  - In Normal mode: trim/select enabled; reorder disabled.

**Visual feedback in Reorder mode:**
- Ghost (lifted) clip follows finger.
- Neighbor clips shift live to show insertion point.
- Optional light haptic on crossing insertion boundaries (implementation detail).

### 11.4 Migration strategy — ProjectDraft.scenes → canonical timeline
#### 11.4.1 Migration approach
**Decision:** **A) Big Bang** migration at load time.
- On load:
  - If `draft` is schema v3:
    - If `draft.scenes != nil`: convert to canonical timeline scene-sequence track.
    - Else: create a single scene item from legacy duration (if any).
  - Persist migrated model back (schema v4).

#### 11.4.2 Schema versioning
**Decision:** bump project schema from **v3 → v4** for the new timeline model.
- v4 stores only canonical timeline (microseconds-based, tracks/items).
- v4 does **not** persist `scenes` as a parallel truth.

#### 11.4.3 Backward compatibility
**Decision:** **No** backward compatibility (no dual-write).
- Projects created/edited in v4 are not guaranteed to open in older app versions.

### 11.5 Undo/Redo — implementation details
#### 11.5.1 Snapshot contents
**Decision (V1 snapshot includes):**
- Canonical timeline model (tracks + items + payload refs).
- `playheadTimeUs`
- `TimelineSelection` (selected item IDs)

**Explicitly NOT in snapshot (V1):**
- zoom level
- scroll offset
- transient gesture state

**Note:** User transforms (position/scale/rotation) are part of payloads; therefore included when the payload registry is part of the model snapshot.

#### 11.5.2 Granularity (what is one undo step)
**Decision:** snapshots are pushed for **model-changing** operations only.

- Trim scene (began→ended): **1 step** (commit on ended).
- Reorder scene: **1 step**.
- Trim + shift-left (compound): **1 step**.
- Add/move/trim/delete audio clips: **1 step** per completed gesture (commit on ended).
- Change template variant / block variant: **1 step**.
- Transform block (pan/pinch/rotate): **1 step** per gesture end.

Not undoable (UI-only):
- Zoom timeline
- Scroll timeline
- Selection changes (tap selection)

#### 11.5.3 Memory management
**Decision:** Full snapshots with limit 50 (per `EditorConfig.undoStackLimit`).
- Use Swift value semantics + copy-on-write for collections to reduce copying costs.
- No delta encoding in V1.

### 11.6 Playhead behavior rules (V1)
#### 11.6.1 Playhead on trim shorten
**Decision:** A) Clamp.
- If playhead ends up > new duration, clamp to `newDurationUs`.

#### 11.6.2 Playhead on scene reorder
**Decision:** Follow the same scene item.
- If the playhead was inside Scene B before reorder, after reorder it stays at the **same relative offset within Scene B**, mapped to Scene B’s new absolute start time.
- If Scene B becomes shorter than that relative offset (should not happen from reorder alone), clamp within the scene.

### 11.7 Export alignment timing
**Decision:** Export alignment is part of the V1 epic and must land **before** release.
- Implementation can be staged after EditorStore/model unification, but release gating requires export to read the canonical timeline model.

### 11.8 Layout/Data split — acceptance tooling
**Decision:** **B) Dev tool** — keep instrumentation under `#if DEBUG` only.
- Remove or compile out in Release builds.
- Threshold: during continuous scroll/zoom gesture, `applySnapshot` calls should be **0** (except initial layout or explicit model change). Allow ≤1 at gesture begin/end due to state propagation.

### 11.9 Min duration migration behavior
**Decision:** **A) Auto-extend + toast** (non-blocking, once per load).
- Any scene shorter than 0.1s is extended to 0.1s during v3→v4 migration or on load normalization.
- Extra time increases overall project duration (no stealing from neighboring scenes).

### 11.10 Code anchors maintenance
Minor line drift is expected as the code evolves.
**Decision:** update anchors in this spec after the above decisions are implemented and before merging to main.

## 12) Implementation decisions (V1) — finalized

This section locks remaining implementation-level choices raised after §11. These are **binding** for V1.

### 12.1 TimelineV2 (schema v4) — concrete data model
**Decision:** Adopt the `TimelineV2` structure proposed in “Final clarifications”, with the following V1 constraints:

- Canonical timeline is **microseconds-based** and persisted as schema **v4**.
- Exactly **one** scene sequence track (`sceneTrack`) exists.
- Multiple audio tracks (`audioTracks`) are allowed; clips may **overlap**.

**Types (V1):**
```swift
// MARK: - Timeline V2 (schema v4)

/// Canonical timeline model (microseconds-based)
public struct TimelineV2: Codable, Equatable, Sendable {
    /// Scene sequence track (always exactly one, sequence invariant)
    public var sceneTrack: SceneSequenceTrack

    /// Audio tracks (multiple allowed, clips can overlap)
    public var audioTracks: [AudioTrack]

    // Future: overlayTracks: [OverlayTrack]
}

/// Scene sequence track — items have durationUs only, startUs is derived
public struct SceneSequenceTrack: Codable, Equatable, Sendable {
    public var items: [SceneItem]
}

public struct SceneItem: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var durationUs: TimeUs
    /// Payload reference (scene content/variant/template linkage)
    public var payloadRef: ScenePayloadRef
}

/// Audio track — items have startUs + durationUs (free placement)
public struct AudioTrack: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var items: [AudioClip]
}

public struct AudioClip: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    /// Position on timeline in microseconds
    public var startUs: TimeUs
    /// Duration in microseconds (can be trimmed)
    public var durationUs: TimeUs
    /// Reference to audio asset
    public var assetRef: AudioAssetRef
    /// Volume (0...1)
    public var volume: Float
    /// Trim start within source audio in microseconds
    public var trimStartUs: TimeUs
}

public enum AudioAssetRef: Codable, Equatable, Sendable {
    /// Bundled SFX asset (by ID)
    case bundled(id: String)
    /// Imported file (relative path in project sandbox)
    case imported(relativePath: String)
}
````

**Notes:**

* Scene `startUs` is **derived** (sequence invariant), not stored in `SceneItem`.
* Overlay tracks are future work; the model is reserved for them but not implemented in V1.

---

### 12.2 Imported audio storage (Device Files)

**Decision:** Store imported audio **inside the project folder** (self-contained project).

Path:

* `<ApplicationSupport>/<projectId>/audio/<clipId>.<ext>`

Rules:

* Import via `UIDocumentPicker` copies the file into the project audio folder.
* `AudioAssetRef.imported(relativePath:)` stores the **relative** path under the project root.
* URL/bookmark-based references are **not** used in V1.

---

### 12.3 In-app SFX library (bundled sounds)

**Decision:** V1 supports **Device Files import** as required.
Bundled SFX library is **optional for V1**:

* `AudioAssetRef.bundled(id:)` remains in the model (reserved for V1.1).
* A full SFX catalog UI and asset set may ship in V1.1; it is **not release-blocking** for V1.

---

### 12.4 UI placement decisions (V1)

#### 12.4.1 “Add Audio” button

**Decision:** Floating “+” button positioned over the audio track area.

* Visible in normal edit mode.
* Hidden/disabled in Scene Reorder mode (§12.5).

#### 12.4.2 “Reorder” button

**Decision:** Timeline toolbar button toggling Scene Reorder mode (see §12.5).

---

### 12.5 Scene reorder UI interaction (V1)

**Decision:** Dedicated **Scene Reorder mode** (avoid gesture conflicts with trim/scroll).

Behavior:

* Timeline toolbar button toggles Reorder mode ON/OFF.
* In Reorder mode:

  * Drag & drop reorders scenes (sequence track).
  * Scene trimming is disabled.
  * Timeline scroll remains enabled.
* In normal mode:

  * Trim/select enabled.
  * Reorder disabled.

Visual feedback:

* Ghost/lifted clip follows finger.
* Neighbor scenes shift live to indicate insertion position.
* Light haptic on insertion boundary crossings is optional (implementation detail).

---

### 12.6 Shift-left policy — remaining edge cases (V1)

#### 12.6.1 If `newDurationUsItem == 0`

**Decision:** Delete the item from the model.

* Undo snapshot restores it.

#### 12.6.2 Overlap after shift-left

**Decision:** Allow overlap on audio tracks.

* Overlapping audio clips are mixed in playback/export.
* No automatic cascade/stacking in V1.

---

### 12.7 Export alignment implementation approach (V1)

**Decision:** Export reads the canonical timeline model, but integration is done via an **adapter layer**.

Approach:

* Convert `TimelineV2.audioTracks` → existing export audio config (`AudioTrackConfig` / `AudioExportConfig`) at the export boundary.
* Do not make `AudioCompositionBuilder` depend directly on EditorCore model types in V1.

Release gate:

* Export alignment must land before V1 release (it is part of the V1 epic).

---

### 12.8 EditorStore/Reducer pattern (V1)

**Decision:** Use strict unidirectional flow: `EditorAction` enum + pure `Reducer` function + `EditorStore.dispatch`.

Constraints:

* No external architecture framework required.
* Store maintains:

  * canonical model state (TimelineV2 + payload registries)
  * essential UI state (playheadTimeUs, selection; zoom/scroll are UI-only and not snapshotted per §11.5)

This design is required to ensure:

* deterministic undo/redo snapshots (limit 50)
* compound edits (trim + shift-left) are a single undo step
* testable, predictable state transitions

---

## 10) Open Items (explicitly NOT in V1)
- Snapping (confirmed removed)
- Split/Razor tool (confirmed future)
- Linked/grouped items (confirmed future)

