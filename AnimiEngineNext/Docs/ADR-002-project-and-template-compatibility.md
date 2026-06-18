# ADR-002 — Project & Template Compatibility

- **Status:** Drafted — realized in Task 002 (`claude-task-002-plan.md`, Revision 5).
- **Source decisions:** D-103 (boundary), with forward notes on D-104 and D-108.

## Context

Task 002 builds the deterministic functional core: the canonical project/scene value model and the
pure evaluator that produces immutable, render-complete `FramePlan`s. It must coexist with the
existing template format without copying it, and without prematurely committing to a project adapter
(D-104) or identity model (D-108).

The existing `SceneSources/<id>/scene.json` files describe **reusable media-binding slots**, not
instantiated project media. They cannot be fabricated directly as resolved canonical scenes.

## Decision

1. **Manifest / payload split.** A `CanonicalProjectManifest` carries lightweight scene/overlay
   entries (id, payload id, timing, z/ordinal). Heavy `ResolvedScenePayload` /
   `ResolvedOverlayPayload` tables are loaded separately. Runtime evaluation needs the
   manifest-derived `TimelineIndex` plus only the selected payloads — never the whole payload table.

2. **Resolved canonical scenes vs reusable template slots.** Template `scene.json` files are read in
   **test support only** (`TemplateFixtureReader` → `TemplateFixtureDescriptor`). A descriptor proves
   that authoring fields/variants/timing/binding-keys are representable; it is then **instantiated**
   with explicit fake video/image bindings into valid `SceneManifestEntry` + `ResolvedScenePayload`
   values. This is test-only fixture adaptation, not D-104.

3. **Global overlay ownership.** Scene-owned layers are video or image only. Text, stickers, and
   graphics are **global timeline overlays** in v1, ordered separately above the scene/transition
   body.

4. **Fixed-point geometry.** All canonical persisted geometry is fixed-point `Int64`
   (`CanvasScalar` 65 536/pt, `ScaleScalar` 1 000 000/1.0, `RotationScalar` 1 000/deg). Authoring
   `Double` conversion belongs to a future adapter, not the core.

5. **Stable ordering.** Scene layers and overlays order by `(zIndex, stableOrdinal)`; equal `zIndex`
   is allowed; structural ids and stable ordinals are unique in scope.

6. **Strict project persistence.** `CanonicalProjectEncoding.decodeValidated` is the only public load
   path: strict recursive JSON, unknown-field/duplicate-key rejection, validated domain factories,
   then semantic validation. Decoding vs validation errors are separate categories.

7. **D-103 compatibility boundary.** The current compiled `.tve` adapter remains outside the core;
   Task 002 neither imports nor depends on it.

8. **Overlay-lookup complexity — approved deviation.** Active-overlay lookup
   (`OverlayIntervalIndex.overlays(containing:)` / `intervals(intersecting:)`) is **`O(log n + k log k)`**,
   not the `O(log n + k)` originally stated in plan §10.1. The augmented-interval-tree traversal
   collects matches in `O(log n + k)`; the deterministic `(zIndex, stableOrdinal, overlayID)` sort
   applied to the `k` results adds `O(k log k)`. This deviation was **approved by the technical lead**
   (corrective plan Revision 2/3, C-8, Option B) on the rationale that `k` (active overlays per frame)
   is small in v1, so collect-then-sort is simpler and the `k log k` term is negligible; the
   ordered-emission structure that would restore `O(log n + k)` is intentionally **not** implemented.

## Forward note

- **D-104** (project adapter) and **D-108** (identity model) remain **unimplemented** and
  **pending owner approval**. Task 002 introduces no adapter and no cross-domain identity model.
