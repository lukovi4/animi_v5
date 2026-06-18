# ADR-001 — Package & Dependency Boundaries

- **Status:** Accepted (foundation subset) — broader scope deferred.
- **Source decisions:** D-101, D-102 (with a forward note on D-103).
- **Realized in:** Task 001 (`claude-task-001-plan.md`, Revision 3).

## Context

A *new* video engine, `AnimiEngineNext`, is being built **beside** the current Animi product, with an
evidence system first — before any media playback. The foundation must not entangle itself with the
current product's playback/export/timeline code, so that the new engine can evolve and be benchmarked
in isolation.

## Decision

1. **Independent Swift package (D-101).** `AnimiEngineNext/` is a top-level package beside `TVECore/`,
   with its own `Package.swift`. It is built and tested independently via `swift build` / `swift test`.

2. **Zero product dependencies (D-102).** The package does **not** depend on `TVECore` and **must not**
   import `AnimiApp`. It does not reference the current playback, renderer, export, project, or UI code.

3. **Minimum iOS 18.** Platforms are declared as version strings — `.iOS("18.0")` and `.macOS("15.0")`
   for host-side testing — intentionally higher than TVECore's iOS 16 floor.

4. **`AnimiEngineTestSupport` is non-public.** It is a plain target consumed only by the test target;
   it is **not** exposed as a package product. Its internal dependency direction is
   `TestSupport → AnimiEngineNext + AnimiEngineDiagnostics`; `Diagnostics → AnimiEngineNext`; nothing
   depends on `TVECore`/`AnimiApp`.

## Forward note

The `.tve` template adapter (**D-103**) is a **later gate**, not part of this foundation. Task 001 only
proves that templates can be *identified and hashed*, never loaded or rendered.

## Consequences

- The new engine can be developed and benchmarked without coupling to the shipping product.
- Raising the floor to iOS 18 unblocks newer platform APIs but diverges from TVECore by design.
- Publishing `AnimiEngineTestSupport` is explicitly avoided so test-only helpers never leak into product
  surfaces.
