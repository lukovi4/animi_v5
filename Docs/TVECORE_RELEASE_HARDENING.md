# TVECORE_RELEASE_HARDENING.md

Release hardening checklist for TVECore (AE → Bodymovin/Lottie → AnimIR → Metal)

## Scope

This document lists **release-relevant issues** found during two independent audits (Tech Lead + iOS developer audit),
plus a small **Watchlist** of additional high-impact risks (non-overlapping findings).

Each item has been **verified against source code** with specific file paths, line numbers, and code excerpts.

Goal: ship a **release-quality** engine **without over-engineering**.

We focus on:
- preventing crashes / undefined behavior
- preventing silent visual corruption (silent drops)
- minimum security hardening for external content packages
- minimum resource limits for GPU/offscreen pipeline
- preserving actionable diagnostics for template authoring

Out of scope (intentionally):
- a full schema migration framework
- heavy lint services / dashboards
- exhaustive test coverage for every corner case
- complex heuristic budgets (simple caps are enough)

---

## Overall verdict

**GO (with conditions).**

Architecture is of the correct type:
- layer isolation: Loader → Validators → Compiler (AnimIR) → RenderPlan/Runtime → MetalRenderer
- AnimIR isolates renderer from Lottie JSON (zero Lottie imports in AnimIR/Renderer layers)
- transform/clip chain is centralized (`SceneTransforms` is the single source of truth for both render and hit-test)
- strong baseline tests already exist (33 test files, 5+ resource directories)
- determinism is enforced (sorted dictionary iteration everywhere, sequential PathID assignment)

To safely continue feature development and ship a release product, close P0 and key P1 items below.

---

## P0 — Must fix before release with real (external/CDN/zip) content

### [ ] P0.1 Safe path resolution (path traversal prevention)

**Audit status: CONFIRMED**

**Problem**
- `animRef` and/or asset relative paths are resolved via `appendingPathComponent()` without normalization and without preventing `..`.

**Evidence from code**

`ScenePackageLoader.swift:102-107`:
```swift
private func resolveAnimFile(animRef: String, in rootURL: URL) throws -> URL {
    let directURL = rootURL.appendingPathComponent(animRef)
    if fileManager.fileExists(atPath: directURL.path) {
        return directURL
    }
```
`animRef` comes from user-supplied JSON and is passed directly to `appendingPathComponent()`.

Second vulnerable path at line 111:
```swift
let withExtension = rootURL.appendingPathComponent("\(animRef).json")
```
Same pattern — no validation before path construction.

No checks exist for:
- `..` segments (path traversal)
- absolute paths (`/etc/passwd`)
- null bytes or control characters
- result URL being within `packageRoot`

**Risk**
- security (reading outside package root)
- unpredictable load failures on real packages

**Minimal fix (no over-engineering)**
- Implement a small `SafePathResolver` utility:
  - reject absolute paths
  - reject any `..` segments
  - normalize path
  - verify final URL is within `packageRoot`

**Apply in**
- `ScenePackageLoader.resolveAnimFile()` (line 102)
- `ScenePackageLoader.resolveAnimFile()` fallback (line 111)
- `AnimValidator.validateAssetPresence` (if it resolves assets from relative paths)

**Acceptance**
- package containing `animRef="../x.json"` fails with a clear error
- no silent "file not found" without an actionable reason

---

### [ ] P0.2 Input size limits (scene/anim JSON, asset count)

**Audit status: CONFIRMED**

**Problem**
- `Data(contentsOf:)` without size limits
- no limits on number of animRefs/assets

**Evidence from code**

`ScenePackageLoader.swift:57-58`:
```swift
let data: Data
data = try Data(contentsOf: sceneURL)
```
Full file read into memory with no size check. No `fileManager.attributesOfItem` guard before read.

`ScenePackageLoader.swift:82-87` — `collectAnimRefs()` returns `Set<String>` with no `.count` limit:
```swift
private func collectAnimRefs(from scene: Scene) -> Set<String> {
    var refs = Set<String>()
    for block in scene.mediaBlocks {
        for variant in block.variants {
            refs.insert(variant.animRef)
        }
    }
    return refs
}
```

No limits on: `mediaBlocks.count`, `variants.count`, or total `animRefs`.

**Risk**
- OOM / freeze / DoS on malformed or huge packages

**Minimal fix**
- Add simple guards in Loader:
  - max bytes for `scene.json` (before `Data(contentsOf:)` at line 58)
  - max bytes per `anim-*.json`
  - max animRefs count (after `collectAnimRefs()` at line 82)
  - (optional) max asset files count / total bytes

**Acceptance**
- oversize input produces a structured error (which file, size, limit)
- app does not crash on huge packages

---

### [ ] P0.3 ZIP support (only if distribution uses zip)

**Audit status: CONFIRMED**

**Problem**
- only directory packages supported

**Evidence from code**

`ScenePackageLoader.swift:17-25`:
```swift
public func load(from rootURL: URL) throws -> ScenePackage {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
        throw ScenePackageLoadError.invalidPackageStructure(
            reason: "Root path is not a directory: \(rootURL.lastPathComponent)"
        )
    }
```

Explicitly requires a directory. No ZIP library imports, no unzip logic, no temp directory management.
Passing a `.zip` file immediately throws `invalidPackageStructure`.

**Risk**
- real distribution almost always uses zip from CDN; pushes hacks elsewhere

**Minimal fix**
- support zip input: unzip to a temp directory, load via the same loader path, clean up

**Acceptance**
- `load(from: zipURL)` works with the same safe path rules and size limits

> Note: If v1 ships ONLY with internal/bundled content, ZIP can be moved to P1.
> If content is delivered via CDN, ZIP is P0.

---

## P1 — Fix in the next sprint (stability + scale of templates)

### [ ] P1.1 Validate `variantId` (empty + duplicates)

**Audit status: CONFIRMED**

**Problem**
- `variant.id` is not validated for empty/duplicates.

**Evidence from code**

`SceneValidator.swift:322-337` — `validateVariants()`:
```swift
func validateVariants(variants: [Variant], basePath: String, issues: inout [ValidationIssue]) {
    let variantsPath = "\(basePath).variants"
    if variants.isEmpty {
        issues.append(...)
        return
    }
    for (index, variant) in variants.enumerated() {
        validateVariant(variant: variant, index: index, basePath: variantsPath, issues: &issues)
    }
}
```
No `var seenIds = Set<String>()` — contrast with `blockId` uniqueness check at lines 114-125 which **does** use this pattern.

`SceneValidator.swift:340-364` — `validateVariant()`:
Checks `animRef.isEmpty` (line 343), `defaultDurationFrames` (line 352), `loopRange` (line 361).
Does **NOT** check `variant.id` at all — neither empty nor duplicate.

`SceneValidationCode.swift`:
No constants `VARIANT_ID_EMPTY` or `VARIANT_ID_DUPLICATE` exist.

`Variant.swift:6` — comment says "Unique identifier" but no enforcement:
```swift
/// Unique identifier for this variant
public let id: String
```

**Risk**
- variant selection bugs, inconsistent behavior when switching variants
- runtime uses `.first { $0.variantId == selectedVariantId }` — duplicate IDs silently hide second variant

**Minimal fix**
- In `SceneValidator.validateVariants()`:
  - reject empty `variant.id`
  - reject duplicates within the same block (same Set pattern as blockId)
  - add codes `VARIANT_ID_EMPTY`, `VARIANT_ID_DUPLICATE` to `SceneValidationCode`
  - if `selectedVariantId` exists, ensure it references an existing variant

**Acceptance**
- scene with duplicate variantId fails validation with a clear code/path

---

### [ ] P1.2 Sync `containerClip` policy across Spec/Validator/Runtime

**Audit status: CONFIRMED**

**Problem**
- enum/model contains 3 cases, validator supports only 2, runtime uses 3
- `.slotRectAfterSettle` mismatch is confirmed

**Evidence from code**

Three-way mismatch:

**1. Enum** — `ContainerClip.swift:4-13` — 3 cases:
```swift
public enum ContainerClip: String, Decodable, Equatable, Sendable {
    case slotRect
    case slotRectAfterSettle
    case none
}
```

**2. Validator** — `SceneValidator.swift:11` — only 2 allowed:
```swift
public var supportedContainerClip: Set<ContainerClip> = [.none, .slotRect]
```

**3. Runtime** — `SceneRenderPlan.swift:99` — uses all 3:
```swift
let shouldClip = block.containerClip == .slotRect || block.containerClip == .slotRectAfterSettle
```
Same at line 157 (edit mode).

**Result**: A scene with `containerClip: "slotRectAfterSettle"`:
- Validator produces error `CONTAINERCLIP_UNSUPPORTED`
- Runtime would render it correctly (identical to `.slotRect`)

**Risk**
- "engine supports it but validator rejects it"
- template authors get inconsistent behavior

**Minimal fix**
Choose one:
- Option A: add `.slotRectAfterSettle` to validator supported list
- Option B: temporarily map it to `.slotRect` (documented behavior), until fully specified

**Recommendation:** Option B is safer — add to supported set but emit a `.warning` stating it behaves as `.slotRect` in current version. This preserves forward-compatibility without false errors.

**Acceptance**
- Spec/Validator/Runtime agree on allowed values and behavior

---

### [ ] P1.3 Remove silent drops for critical visual elements (shape/mediaInput)

**Audit status: CONFIRMED (5 locations)**

**Problem**
- some unsupported cases return `nil` (silent) instead of throwing `UnsupportedFeature`
  - mediaInput path extraction: `return nil` in 2 places
  - unknown shape types may silently drop in non-matte context

**Evidence from code**

**Location 1** — `AnimIRCompiler.swift:556-559` (HIGH risk):
```swift
guard case .shapes(let shapeGroup) = layer.content,
      let animPath = shapeGroup.animPath else {
    // No extractable path — skip silently (validator will catch this)
    return nil
}
```
mediaInput layer with no extractable shape path — returns `nil` instead of throwing.

**Location 2** — `AnimIRCompiler.swift:563-565` (HIGH risk):
```swift
guard let resource = PathResourceBuilder.build(from: animPath, pathId: PathID(0)) else {
    // Path build failed — skip (validator will report detailed error)
    return nil
}
```
Untriangulatable mediaInput path — returns `nil` instead of throwing.

**Location 3** — `AnimIRPath.swift` ShapePathExtractor `extractPath()` (LOW risk):
`default: return nil` for unknown shape types. Silently drops `.gradientFill`, `.mergePaths`, `.repeater`, `.roundCorners`, etc.

**Location 4** — `AnimIRPath.swift` ShapePathExtractor `extractAnimPath()` (LOW risk):
Same pattern as Location 3 for animated path extraction.

**Location 5** — `AnimValidator.swift` `validateMediaInputShapes()` (NARROW gap):
Unknown shape types NOT in `forbiddenMediaInputShapeTypes` set (6 types: tm, mm, rp, gf, gs, rd) silently pass validation. E.g., `"pb"` (pucker/bloat) or `"tw"` (twist) would not be caught.

**Risk context for Locations 3-4:** AnimValidator **does** reject all unknown shapes with `UNSUPPORTED_SHAPE_ITEM` error (`AnimValidator+Shapes.swift:116-123`). So Locations 3-4 are defense-in-depth — they can only fire if validator is bypassed. Locations 1-2 are the real production path.

**Risk**
- worst bug class: template looks wrong with no error

**Minimal fix**
- Replace "silent nil" with explicit `throw UnsupportedFeature(code, path, message)` in Locations 1-2
- Add defensive throw in Locations 3-4 (even though validator catches upstream)
- Extend `forbiddenMediaInputShapeTypes` in AnimValidator to catch all unknown types (Location 5)

**Acceptance**
- unsupported shape/path fails with structured error (code + JSONPath + hint)
- no "disappearing layers" without a diagnostic

---

### [ ] P1.4 TexturePool limits + eviction

**Audit status: CONFIRMED**

**Problem**
- MaskCache/ShapeCache have maxEntries, TexturePool has no clear cap/eviction

**Evidence from code**

`TexturePool.swift:28-31` — no `maxEntries`:
```swift
final class TexturePool {
    private let device: MTLDevice
    private var available: [TexturePoolKey: [MTLTexture]] = [:]
    private var inUse: Set<ObjectIdentifier> = []
```

`TexturePool.swift:98` — `release()` appends without limit:
```swift
available[key, default: []].append(texture)
```

`TexturePool.swift:109-141` — `acquire()` creates new texture if none available, no total count check.

**Contrast** — `MaskCache.swift` **has** `maxEntries: Int = 64` and LRU eviction:
```swift
private let maxEntries: Int
init(device: MTLDevice, maxEntries: Int = 64) { ... }
```
`ShapeCache.swift` — same pattern with `maxEntries = 64`.

TexturePool is the **only unbounded cache** in MetalRenderer.

**Risk**
- memory growth over long sessions or complex templates → OOM

**Minimal fix**
- Add a simple cap:
  - max textures (count) OR approximate max bytes
- Add simple eviction (LRU or oldest-first)
- Pattern already exists in MaskCache/ShapeCache — reuse the same approach

**Acceptance**
- pool does not grow unbounded on stress scenes
- memory stays under a predictable ceiling

---

### [ ] P1.5 Offscreen pass depth limit (`maxOffscreenDepth`)

**Audit status: CONFIRMED**

**Problem**
- maskDepth/matteDepth tracked, but no upper bound

**Evidence from code**

`MetalRenderer+Execute.swift:71-72` — counters defined:
```swift
var maskDepth: Int = 0
var matteDepth: Int = 0
```

Lines ~1454-1466 — depth incremented with underflow guard but **no overflow guard**:
```swift
case .beginMask, .beginMaskAdd:
    state.maskDepth += 1
    // ← NO guard state.maskDepth <= MAX here
case .endMask:
    state.maskDepth -= 1
    guard state.maskDepth >= 0 else {
        throw MetalRendererError.invalidCommandStack(reason: "EndMask without BeginMask")
    }
case .beginMatte:
    state.matteDepth += 1
    // ← NO guard state.matteDepth <= MAX here
```

**Resource consumption per scope:**
- Each mask scope: 4 textures (`MetalRenderer+MaskRender.swift:75-78` — coverageTex, accumA, accumB, contentTex)
- Each matte scope: 2 textures (`MetalRenderer+Execute.swift:845,862` — matteTex, consumerTex)
- At 4K resolution: mask scope = ~132MB GPU, matte scope = ~66MB GPU
- 10 nested masks = ~1.3GB GPU memory (no device limit check)

**Risk**
- pathological nesting causes runaway offscreen rendering, stalls or crashes

**Minimal fix**
- Add `maxOffscreenDepth` (e.g., 8-16)
- Guard after each increment:
  ```swift
  state.maskDepth += 1
  guard state.maskDepth <= maxOffscreenDepth else {
      throw MetalRendererError.invalidCommandStack(reason: "Mask nesting too deep (\(state.maskDepth) > \(maxOffscreenDepth))")
  }
  ```
- On exceed: return structured error (prefer fail-fast over undefined visuals)

**Acceptance**
- deep nesting cannot cause infinite/huge offscreen chains

---

## Watchlist (high-impact, non-overlapping findings)
These items were not equally emphasized in both audits, but are **high leverage** for release stability.
They remain **minimal** and avoid over-engineering.

### [ ] W1 Debug/Release parity for fallback render paths (especially CPU mask fallback)

**Audit status: CONFIRMED**

**Problem**
- Some render paths may differ between DEBUG and RELEASE builds (fallback behavior).

**Evidence from code**

`MetalRenderer+Execute.swift:369-454` — entire CPU mask path exists only in RELEASE:
```swift
private func renderMaskScope(...) throws {
#if DEBUG
    preconditionFailure("CPU mask path is forbidden. Must use GPU mask pipeline (renderMaskGroupScope).")
#else
    // Legacy implementation (release-only rollback path)
    let targetSize = ctx.target.sizePx
    // ... 82 lines of CPU rasterization code ...
#endif
}
```

`MaskCache.swift:88-128` — same pattern:
```swift
func texture(for path: ...) -> MTLTexture? {
#if DEBUG
    preconditionFailure("CPU mask cache is forbidden. Must use GPU mask pipeline.")
#else
    // Legacy implementation (release-only rollback path)
    // ... 39 lines of CPU rasterization fallback ...
#endif
}
```

`MetalRenderer+MaskRender.swift:60-62` — fallback telemetry only in DEBUG:
```swift
#if DEBUG
MaskDebugCounters.fallbackCount += 1
#endif
```

**Consequence**: If `renderMaskScope` is ever called in release, it silently uses CPU rasterization instead of GPU pipeline. DEBUG builds crash (preconditionFailure), so tests never cover this path. Release fallback has **zero telemetry**.

**Risk**
- "works in debug, breaks in release" class of bugs, hard to reproduce

**Minimal fix**
- Make fallback behavior explicit:
  - Option A: remove `#else` branches entirely (if GPU pipeline is complete)
  - Option B: emit a warning/metric whenever fallback is used in release logs too
  - Option C: add a release-mode assertion (`assertionFailure` — logs but doesn't crash)

**Acceptance**
- fallback usage is detectable (and ideally disabled by default unless explicitly enabled)

---

### [ ] W2 Preserve structured compile errors end-to-end (do not collapse to `localizedDescription`)

**Audit status: CONFIRMED**

**Problem**
- Compiler can produce structured `UnsupportedFeature(code, path, message)` but upper layers may collapse to a string.

**Evidence from code**

**Structure defined** in `AnimIRCompiler.swift:6-21`:
```swift
public struct UnsupportedFeature: Error, Sendable {
    public let code: String    // e.g. "UNSUPPORTED_MASK_MODE"
    public let message: String // Human-readable
    public let path: String    // e.g. "anim(anim-1.json).layer(media).mask[0]"
}
```

**Structure LOST** in `ScenePlayer.swift:198-201`:
```swift
} catch {
    throw ScenePlayerError.compilationFailed(
        animRef: animRef,
        reason: error.localizedDescription  // ← COLLAPSES TO STRING
    )
}
```

**Receiving type** in `ScenePlayerError.swift:9`:
```swift
case compilationFailed(animRef: String, reason: String)
```
Only `reason: String` — no `errorCode`, `errorPath`, or `blockId` fields.

**Same pattern** in `AnimLoader.swift:65-79`:
```swift
throw AnimLoadError.animJSONReadFailed(
    animRef: animRef,
    reason: error.localizedDescription  // ← STRING COLLAPSE
)
```

**End-to-end trace**:
```
UnsupportedFeature {code: "UNSUPPORTED_MASK_MODE", path: "anim(...).mask[0]", message: "..."}
  → caught by ScenePlayer (line 198)
  → error.localizedDescription → "[UNSUPPORTED_MASK_MODE] ... at anim(...).mask[0]"
  → ScenePlayerError.compilationFailed(animRef: "anim-1.json", reason: "<single string>")
  → App layer: can only display a string, cannot filter by code or highlight by path
```

**Risk**
- template authoring/debugging becomes slow; "unknown error" reports

**Minimal fix**
- Ensure `ScenePlayerError` preserves:
  - `code`, `path`, `animRef`, `blockId/variantId` (when available)
- Cast to known error types before wrapping:
  ```swift
  } catch let unsupported as UnsupportedFeature {
      throw ScenePlayerError.compilationFailed(
          animRef: animRef, errorCode: unsupported.code,
          errorPath: unsupported.path, message: unsupported.message
      )
  } catch { ... }
  ```
- Provide a single "diagnostics report" object for app/UI consumption

**Acceptance**
- app layer can display/export: error code + JSONPath + hint, not only a message string

---

### [ ] W3 GPU resource lifetime safety (release timing / use-after-free risk)

**Audit status: NOT CONFIRMED (safe in current design)**

**Problem**
- Textures/resources may be released without an explicit GPU fence, relying on current command buffer usage patterns.

**Evidence from code**

`TexturePool.swift:88-99` — `release()` is immediate (no GPU fence):
```swift
func release(_ texture: MTLTexture) {
    let identifier = ObjectIdentifier(texture)
    guard inUse.contains(identifier) else { return }
    inUse.remove(identifier)
    let key = TexturePoolKey(width: texture.width, height: texture.height, pixelFormat: texture.pixelFormat)
    available[key, default: []].append(texture)
}
```

**However**, all texture usage is **synchronous** within single render passes:
- `MetalRenderer+MaskRender.swift:90-95`: `defer { texturePool.release(coverageTex) }` pattern
- `MetalRenderer+Execute.swift:845-848`: same `defer` pattern for matte textures
- All command buffers are committed and completed before textures return to pool

No async completion handlers, no cross-frame texture sharing.

**Current risk**: NONE — design is safe with synchronous rendering.
**Future risk**: Would appear if async render pipeline or multi-frame texture reuse is added.

**Minimal fix (keep on watchlist)**
- If/when async rendering is added, implement a lightweight "deferred release" strategy:
  - hold released textures until commandBuffer completion handler fires (or per-frame retire queue)
- Avoid heavy synchronization; just correct ownership timing

**Acceptance**
- resources are not returned to pool/reused until safe; no rare crashes under stress

---

## P2 — Technical debt (do when/if it becomes painful)

### [ ] P2.1 Loader caching (avoid re-read + re-decode)

**Audit status: CONFIRMED**

**Problem**
- repeated loads re-read and re-decode all JSON

**Evidence from code**

`ScenePackageLoader.swift` — no caching anywhere. No `NSCache`, no memoization, no modification-time check.
Each `load(from:)` call: reads `scene.json` from disk, runs `JSONDecoder`, resolves all `animRefs` via filesystem.

**Risk**
- avoidable CPU overhead (not a release blocker)

**Minimal fix**
- simple memoization keyed by package URL + modification time OR handled in app layer

---

### [ ] P2.2 `try?` without logging in DEBUG

**Audit status: CONFIRMED**

**Problem**
- some failures can be swallowed by `try?`

**Evidence from code**

9 instances, all in `LottieTransform.swift` — polymorphic JSON decoders:

| Line | Context | Pattern |
|------|---------|---------|
| 114 | `LottieAnimatedValue.init(from:)` | `try? container.decode(Double.self)` |
| 120 | same | `try? container.decode([Double].self)` |
| 126 | same | `try? container.decode([LottieKeyframe].self)` |
| 132 | same | `try? container.decode(LottiePathData.self)` |
| 156 | `LottieKeyframeValue.init(from:)` | `try? container.decode([Double].self)` |
| 162 | same | `try? container.decode([LottiePathData].self)` |
| 168 | same | `try? container.decode(LottiePathData.self)` |
| 265 | `LottieTangentValue.init(from:)` | `try? container.decode(Double.self)` |
| 269 | same | `try? container.decode([Double].self)` |

**All are acceptable polymorphic decoder patterns** — probing formats (number → array → keyframes → path).
Final fallbacks throw `DecodingError` if all branches fail (lines 138, 174).
One marginal case: line 270 falls back to `.single(0)` silently for tangent values.

**Risk**
- harder debugging (no way to see which branch failed without DEBUG logging)

**Minimal fix**
- add DEBUG-only logging / warnings for swallowed failures
- keep RELEASE behavior minimal

---

### [ ] P2.3 Add 1-2 integration resource scenes for deeper nested precomp/mattes

**Audit status: CONFIRMED**

**Problem**
- nesting logic exists, but deeper-than-current coverage can be limited

**Evidence from code**

Current test resources:
```
Tests/TVECoreTests/Resources/
  nested_precomp/anim-nested-1.json  — 3-level nesting (root → comp_outer → comp_inner → image)
  mattes/alpha_matte_basic/          — basic alpha matte
  negative/neg_matte_*               — 3 matte error cases
```

**Maximum nesting depth tested: 3 levels** (in `anim-nested-1.json`).

Missing coverage:
- No test for depth 4+ nesting
- No test combining nested precomp + alpha matte + mask on same layer
- No test for the "complex combination" smoke-test from task.md (nested precomp + alpha matte + animated mask + 4 blocks)

**Risk**
- regressions on rare templates

**Minimal fix**
- add **1-2** resource scenes covering depth=3-4 for nested precomp + matte/mask combination

---

## What we explicitly do NOT add (avoid over-engineering)

- Full schema migration system (only strict `schemaVersion` check is enough for v1)
- Heavy template-lint services (a simple structured error report is enough)
- Complex memory/perf heuristics (simple caps and limits are enough)
- Large test explosion (only add tests that cover confirmed risks)

---

## Recommended execution order

### Sprint A — Release blockers
1) P0.1 SafePathResolver
2) P0.2 Size limits
3) P0.3 ZIP support (if CDN/zip delivery)

### Sprint B — Stability
4) P1.1 variantId validation
5) P1.2 containerClip sync
6) P1.3 remove silent drops

### Sprint C — GPU safety
7) P1.4 TexturePool eviction/cap
8) P1.5 maxOffscreenDepth
9) W1 Debug/Release parity guard (moved here from Sprint D — confirmed real risk)

### Sprint D — Quality of life
10) W2 End-to-end structured diagnostics
11) P2 items as needed

> W3 remains on watchlist — not confirmed as a current issue, monitor if async rendering is added.

---

## "Ready to continue feature development" criteria

You can confidently continue expanding the supported Lottie subset (and ship templates) once:
- P0.1 + P0.2 are DONE (and P0.3 if CDN/zip)
- P1.1 + P1.2 + P1.3 are DONE
- at least one of P1.4/P1.5 is DONE (for release, recommended both)
- W2 is DONE before scaling template authoring (recommended)

At that point, the engine foundation is release-stable without over-engineering.

---

## Checklist status (Done / Not Done)

> Mark each item as DONE when merged to main and verified by a smoke run on at least 1 real ScenePackage.

### P0
- P0.1 Safe path resolution (path traversal prevention): **NOT DONE** — CONFIRMED by audit
- P0.2 Input size limits (scene/anim JSON, asset count): **NOT DONE** — CONFIRMED by audit
- P0.3 ZIP support (if needed): **NOT DONE** — CONFIRMED by audit

### P1
- P1.1 Validate `variantId` (empty + duplicates): **NOT DONE** — CONFIRMED by audit
- P1.2 Sync `containerClip` policy across Spec/Validator/Runtime: **NOT DONE** — CONFIRMED by audit
- P1.3 Remove silent drops for critical visual elements: **NOT DONE** — CONFIRMED by audit (5 locations)
- P1.4 TexturePool limits + eviction: **NOT DONE** — CONFIRMED by audit
- P1.5 Offscreen pass depth limit (`maxOffscreenDepth`): **NOT DONE** — CONFIRMED by audit

### Watchlist
- W1 Debug/Release parity for fallback render paths: **NOT DONE** — CONFIRMED by audit
- W2 Preserve structured compile errors end-to-end: **NOT DONE** — CONFIRMED by audit
- W3 GPU resource lifetime safety (deferred release): **NOT APPLICABLE** — NOT CONFIRMED (safe in current design)

### P2
- P2.1 Loader caching: **NOT DONE** — CONFIRMED by audit
- P2.2 `try?` without logging in DEBUG: **NOT DONE** — CONFIRMED by audit (9 instances, all polymorphic decoders)
- P2.3 Add 1-2 deep nesting integration resource scenes: **NOT DONE** — CONFIRMED by audit (max depth tested: 3)
