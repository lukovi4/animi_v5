# CODE AUDIT ISSUES — Full Issue Register

Snapshot date (issue list generated): 2026-02-11  
Evidence policy: **Every issue includes 1..N code anchors (5–15 lines each).**  
No fixes proposed here — only risks/problems provable from snapshot.

---

## Issues

### ID: P1-001
- **Severity:** P2 (Debug-only main-thread stall)
- **Category:** Performance / File I/O
- **Scope:** Debug-only load/compile path invokes `ScenePackageTextureProvider.preloadAll()` synchronously on main thread. Release path invokes `preloadAll()` from a background `Task` while rendering is gated by `loadingState == .ready`.
- **Impact:** `preloadAll()` performs synchronous URL resolution + texture loading in a loop; when executed on the main thread (Debug path), it can block UI input/render. Release path runs `preloadAll()` off-main and prevents draw during loading.
- **Status (snapshot):** CONFIRMED for Debug path; NOT CONFIRMED for Release compiled-template load path (background preload).
- **Evidence:**

**Code anchor 1**
- `AnimiApp/Sources/Player/PlayerViewController.swift:659`
- `DEBUG path: loadTestPackageTapped() triggers synchronous load/compile on UI action`
```swift
    #if DEBUG
    @objc private func loadTestPackageTapped() {
        stopPlayback()
        renderErrorLogged = false
        log("---\nLoading scene package...")
        ...
        do {
            try loadAndValidatePackage(from: url.deletingLastPathComponent())
        } catch {
            log("ERROR: \(error)")
            isSceneValid = false
            isAnimValid = false
        }
    }
    #endif
```

**Code anchor 2**
- `AnimiApp/Sources/Player/PlayerViewController.swift:1125`
- `DEBUG path: compileScene(for:) calls preloadAll() inline (no async)`
```swift
        textureProvider = provider

        // PR-B: Preload all textures before any draw/play (IO-free runtime invariant)
        provider.preloadAll()
        if let stats = provider.lastPreloadStats {
            log(String(format: "[Preload] loaded: %d, missing: %d, skipped: %d, duration: %.1fms",
                       stats.loadedCount, stats.missingCount, stats.skippedBindingCount, stats.durationMs))
        }
```

**Code anchor 3**
- `AnimiApp/Sources/Player/PlayerViewController.swift:1358`
- `Release path: loadCompiledTemplateFromBundle(templateName:) runs preloadAll() inside background Task`
```swift
                // Preload on background (PR-D: safe because draw not running)
                // PR-D.1: Use child Task so cancellation propagates
                try await Task(priority: .userInitiated) {
                    try Task.checkCancellation()
                    provider.preloadAll()
                }.value
```

**Code anchor 4**
- `AnimiApp/Sources/Player/PlayerViewController.swift:1554`
- `draw(in:) is gated while loading (prevents draw during background preload)`
```swift
    func draw(in view: MTKView) {
        // Model A contract: draw must execute on main thread
        dispatchPrecondition(condition: .onQueue(.main))

        // PR-D.1: No draw while template is loading (prevents race with background preload)
        guard loadingState == .ready else { return }
```

**Code anchor 5**
- `TVECore/Sources/TVECore/MetalRenderer/ScenePackageTextureProvider.swift:156`
- `preloadAll() loop + resolveURL + loadTexture`
```swift
    public func preloadAll() {
        let startTime = CFAbsoluteTimeGetCurrent()
        var loadedCount = 0
        var skippedBindingCount = 0

        for (assetId, basename) in assetIndex.basenameById {
            // Skip already cached (including injected textures)
            if cache[assetId] != nil {
                loadedCount += 1
                continue
            }

            guard let textureURL = try? resolver.resolveURL(forKey: basename) else {
                // ... error handling
                continue
            }

            if let texture = loadTexture(from: textureURL, assetId: assetId) {
                cache[assetId] = texture
                loadedCount += 1
            }
        }
        // ...
    }
```

- **Notes:** Release path (PR-D) runs `preloadAll()` off-main with draw gated. Debug path remains synchronous on main thread — acceptable for developer tooling, not production.

---

### ID: P1-002
- **Severity:** P3 (tech debt — unreachable in current codebase)
- **Category:** Code Quality / Defensive Coding
- **Scope:** `Earcut.triangulate(vertices:holeIndices:)` contains force-unwrap after `eliminateHoles(...)`. However, all current callers pass empty `holeIndices` (default parameter), so the problematic code path is never executed.
- **Impact:** No crash risk in current codebase. Force-unwrap is a code smell that would become a bug if holes support is added in the future.
- **Status (snapshot):** NOT CONFIRMED — crash path unreachable; `holeIndices` parameter never passed by any caller.
- **Evidence:**

**Code anchor 1**
- `TVECore/Sources/TVECore/MetalRenderer/Earcut.swift:27-30`
- `Force-unwrap after eliminateHoles (only executed when hasHoles == true)`
```swift
        if hasHoles {
            outerNode = eliminateHoles(vertices: vertices, holeIndices: holeIndices, outerNode: node)
            node = outerNode!  // ← Force-unwrap — potential crash if eliminateHoles returns nil
        }
```

**Code anchor 2**
- `TVECore/Sources/TVECore/MetalRenderer/Earcut.swift:19`
- `hasHoles condition — only true when holeIndices is non-empty`
```swift
        let hasHoles = !holeIndices.isEmpty  // ← All callers use default [], so hasHoles == false
```

**Code anchor 3**
- `TVECore/Sources/TVECore/AnimIR/PathResource.swift:320,365`
- `All callers — none pass holeIndices parameter`
```swift
        // PathResource.swift:320 — static path
        let indices = Earcut.triangulate(vertices: flatVertices)  // ← No holeIndices

        // PathResource.swift:365 — animated path
        let indices = Earcut.triangulate(vertices: firstFlat)     // ← No holeIndices
```

**Code anchor 4**
- `TVECore/Sources/TVECore/MetalRenderer/Earcut.swift:433-457`
- `eliminateHoles analysis — returns nil only if input chain breaks (not possible with valid outerNode)`
```swift
    private static func eliminateHoles(..., outerNode: Node) -> Node? {
        var outer: Node? = outerNode  // ← Starts non-nil
        for hole in queue {
            outer = eliminateHole(hole, outer)  // ← Returns non-nil if input non-nil
        }
        return outer  // ← Only nil if outerNode was nil (impossible by call contract)
    }
```

- **Notes:** Crash is unreachable because: (1) all callers use default `holeIndices = []`, (2) `hasHoles` is always `false`, (3) force-unwrap code path never executes. Issue retained as tech debt for defensive coding if holes support is added later.

---

### ID: P2-001
- **Severity:** P2 (nice to fix)
- **Category:** Bug / Crash potential
- **Impact:** `MetalRendererResources.makeCoveragePipeline(...)` force-unwraps `descriptor.colorAttachments[0]`. If that slot is `nil`, this is a crash.
- **Evidence:**

**Code anchor**
- `TVECore/Sources/TVECore/MetalRenderer/MetalRendererResources.swift`
- `descriptor.colorAttachments[0]!`
```swift
// MARK: - GPU Mask Pipeline Creation

extension MetalRendererResources {
    /// Creates pipeline for rendering path triangles to R8 coverage texture.
    /// Uses additive blending for overlapping triangles.
    private static func makeCoveragePipeline(
        device: MTLDevice,
        library: MTLLibrary
    ) throws -> MTLRenderPipelineState {
        guard let vertexFunc = library.makeFunction(name: "coverage_vertex") else {
            throw MetalRendererError.failedToCreatePipeline(reason: "coverage_vertex not found")
        }
        guard let fragmentFunc = library.makeFunction(name: "coverage_fragment") else {
            throw MetalRendererError.failedToCreatePipeline(reason: "coverage_fragment not found")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunc
        descriptor.fragmentFunction = fragmentFunc

        // R8Unorm output for coverage
        let colorAttachment = descriptor.colorAttachments[0]!
        colorAttachment.pixelFormat = .r8Unorm
        // No blending - triangulation should not produce overlapping triangles
        // If overlap occurs, it's a bug in triangulation data
        // saturate() in compute kernel handles any edge cases
        colorAttachment.isBlendingEnabled = false

        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            let msg = "Coverage pipeline failed: \(error.localizedDescription)"
            throw MetalRendererError.failedToCreatePipeline(reason: msg)
        }
    }

    /// Creates pipeline for compositing content with R8 mask (content × mask.r).
    private static func makeMaskedCompositePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        colorPixelFormat: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        guard let vertexFunc = library.makeFunction(name: "masked_composite_vertex") else {
            throw MetalRendererError.failedToCreatePipeline(reason: "masked_composite_vertex not found")
        }
        guard let fragmentFunc = library.makeFunction(name: "masked_composite_fragment") else {
            throw MetalRendererError.failedToCreatePipeline(reason: "masked_composite_fragment not found")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunc
```

- **Notes:** Whether `colorAttachments[0]` can be `nil` in practice is **NOT PROVEN**; the crash potential is strictly due to `!`.

---

### ID: P2-002
- **Severity:** P2 (nice to fix)
- **Category:** Concurrency / Type Safety
- **Impact:** `BackgroundLoadResult` is `@unchecked Sendable`, bypassing compiler enforcement for sendability across concurrency domains.
- **Evidence:**

**Code anchor**
- `AnimiApp/Sources/Player/PlayerViewController.swift`
- `BackgroundLoadResult @unchecked Sendable`
```swift
// MARK: - Scene Variant Preset (PR-20)

/// A named mapping of blockId -> variantId for scene-level style switching.
struct SceneVariantPreset {
    let id: String
    let title: String
    let mapping: [String: String]  // blockId -> variantId
}

// MARK: - PR-D: Async Loading Helper Structs

/// Result from background phase of template loading.
/// Note: @unchecked Sendable because CompiledScenePackage is a value type with immutable data.
private struct BackgroundLoadResult: @unchecked Sendable {
    let compiledPackage: CompiledScenePackage
    let resolver: CompositeAssetResolver
}

/// Result from ScenePlayer setup phase (main actor only, not Sendable).
private struct SceneSetupResult {
    let player: ScenePlayer
    let compiled: CompiledScene
}

/// Main player view controller with Metal rendering surface and debug log.
/// Supports full scene playback with multiple media blocks.
final class PlayerViewController: UIViewController {

    // MARK: - UI Components

    #if DEBUG
    private lazy var sceneSelector: UISegmentedControl = {
        let control = UISegmentedControl(items: ["4 Blocks", "Alpha Matte", "Variant Demo", "Shared Decor"])
```

- **Notes:** Actual cross-actor usage is **NOT PROVEN** in this excerpt; the issue is the explicit opt-out.

---

### ID: P2-003
- **Severity:** P2 (nice to fix)
- **Category:** UX-tech / Crash potential
- **Impact:** `EditorOverlayView` crashes if instantiated via NSCoder due to unconditional `fatalError("init(coder:) not supported")`.
- **Evidence:**

**Code anchor**
- `AnimiApp/Sources/Editor/EditorOverlayView.swift`
- `required init?(coder:) fatalError`
```swift
import UIKit
import TVECore

/// Transparent overlay view drawn on top of Metal rendering surface.
/// Displays interactive block outlines using CAShapeLayer.
///
/// PR-19: Editor overlay — CAShapeLayer-based (lead-approved).
/// `isUserInteractionEnabled = false` — all gestures go to metalView underneath.
final class EditorOverlayView: UIView {

    // MARK: - Properties

    /// Canvas-to-View affine transform. Set by controller on layout changes.
    /// Must match the Metal renderer's contain (aspect-fit) mapping.
    var canvasToView: CGAffineTransform = .identity

    // MARK: - Layers

    private var selectedLayer: CAShapeLayer?
    private var inactiveLayers: [CAShapeLayer] = []

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - Update

    /// Update overlay display with current block overlays.
    ///
    /// - Parameters:
    ///   - overlays: From `player.overlays(frame:)` — hit paths in canvas coords.
    ///   - selectedBlockId: Currently selected block (nil = none selected).
    func update(overlays: [MediaInputOverlay], selectedBlockId: String?) {
        // Remove old layers
        selectedLayer?.removeFromSuperlayer()
        selectedLayer = nil
        inactiveLayers.forEach { $0.removeFromSuperlayer() }
        inactiveLayers.removeAll()

        guard !overlays.isEmpty else { return }

        for overlay in overlays {
            let isSelected = overlay.blockId == selectedBlockId

            let shapeLayer = CAShapeLayer()
            shapeLayer.frame = bounds

            // Convert BezierPath (canvas coords) -> CGPath -> view coords
            let canvasPath = overlay.hitPath.cgPath
```

- **Notes:** Whether this view is ever loaded from storyboard/nib in this app is **NOT PROVEN**.

---

### ID: P2-004
- **Severity:** P2 (nice to fix)
- **Category:** Architecture / Testing
- **Impact:** `TVECoreTests` test target depends on both `TVECore` and `TVECompilerCore`; the package comments that this is temporary, indicating test-time boundary coupling.
- **Evidence:**

**Code anchor**
- `TVECore/Package.swift`
- `products + targets + dependency edges`
```swift
// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TVECore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "TVECore",
            targets: ["TVECore"]
        ),
        .library(
            name: "TVECompilerCore",
            targets: ["TVECompilerCore"]
        ),
        .executable(
            name: "TVETemplateCompiler",
            targets: ["TVETemplateCompiler"]
        )
    ],
    targets: [
        .target(
            name: "TVECore",
            dependencies: [],
            path: "Sources/TVECore",
            resources: [
                .process("MetalRenderer/Shaders")
            ]
        ),
        .target(
            name: "TVECompilerCore",
            dependencies: ["TVECore"],
            path: "Sources/TVECompilerCore"
        ),
        .executableTarget(
            name: "TVETemplateCompiler",
            dependencies: ["TVECompilerCore"],
            path: "Tools/TVETemplateCompiler"
        ),
        // NOTE: TVECoreTests temporarily depends on TVECompilerCore (variant A from review.md)
        // TODO: Split into TVECoreTests + TVECompilerCoreTests (variant B) in separate task
        .testTarget(
            name: "TVECoreTests",
            dependencies: ["TVECore", "TVECompilerCore"],
            path: "Tests/TVECoreTests",
            resources: [
                .copy("Resources")
            ]
        )
    ]
)
```

- **Notes:** Concrete impact depends on how tests are structured (**NOT PROVEN**).

---

### ID: P2-005
- **Severity:** P2 (nice to fix)
- **Category:** Tooling / Process Risk
- **Impact:** Boundary enforcement and release bundle validation are present as scripts, but automatic execution integration is not proven in this register.
- **Evidence:**

**Code anchor**
- `Scripts/verify_module_boundary.sh`
- `boundary check script`
```bash
#!/bin/bash
# PR3 Gate v1: Verify TVECore module boundary
# Ensures no Lottie/compiler code leaks into runtime module

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TVECORE_SRC="$REPO_ROOT/TVECore/Sources/TVECore"

echo "=== PR3 Module Boundary Check ==="
echo "Checking: $TVECORE_SRC"
echo ""

ERRORS=0

# Check 1: No Lottie folders/files in TVECore
echo "[1/4] Checking for Lottie folders..."
if find "$TVECORE_SRC" -type d -name "Lottie*" 2>/dev/null | grep -q .; then
    echo "ERROR: Found Lottie folder in TVECore:"
    find "$TVECORE_SRC" -type d -name "Lottie*"
    ERRORS=$((ERRORS + 1))
else
    echo "  OK: No Lottie folders"
fi

# Check 2: No AnimLoader/AnimValidator folders
echo "[2/4] Checking for AnimLoader/AnimValidator folders..."
if find "$TVECORE_SRC" -type d \( -name "AnimLoader" -o -name "AnimValidator" -o -name "Bridges" \) 2>/dev/null | grep -q .; then
    echo "ERROR: Found compiler folders in TVECore:"
    find "$TVECORE_SRC" -type d \( -name "AnimLoader" -o -name "AnimValidator" -o -name "Bridges" \)
    ERRORS=$((ERRORS + 1))
else
    echo "  OK: No compiler folders"
fi

# Check 3: No Lottie type imports in TVECore source files
echo "[3/4] Checking for Lottie type usage..."
LOTTIE_REFS=$(grep -rE '\bLottieJSON\b|\bLottieLayer\b|\bLottieAsset\b|\bLottieShape\b|\bLottieMask\b|\bLottieTransform\b' "$TVECORE_SRC" --include="*.swift" 2>/dev/null || true)
if [ -n "$LOTTIE_REFS" ]; then
    echo "ERROR: Found Lottie type references in TVECore:"
    echo "$LOTTIE_REFS"
    ERRORS=$((ERRORS + 1))
else
    echo "  OK: No Lottie type references"
fi

# Check 4: No import TVECompilerCore in TVECore
echo "[4/4] Checking for TVECompilerCore imports..."
COMPILER_IMPORTS=$(grep -rE '^import TVECompilerCore' "$TVECORE_SRC" --include="*.swift" 2>/dev/null || true)
if [ -n "$COMPILER_IMPORTS" ]; then
    echo "ERROR: Found TVECompilerCore import in TVECore:"
    echo "$COMPILER_IMPORTS"
    ERRORS=$((ERRORS + 1))
else
    echo "  OK: No TVECompilerCore imports"
fi

echo ""
if [ $ERRORS -eq 0 ]; then
    echo "=== PASS: Module boundary intact ==="
    exit 0
else
    echo "=== FAIL: $ERRORS boundary violation(s) found ==="
    exit 1
fi
```

**Code anchor**
- `Scripts/verify_release_bundle.sh`
- `release bundle verification script`
```bash
#!/bin/bash
# verify_release_bundle.sh — Verifies Release bundle has no anim-*.json and has compiled.tve
#
# Usage:
#   ./Scripts/verify_release_bundle.sh <app_bundle_path>
#   ./Scripts/verify_release_bundle.sh /path/to/AnimiApp.app
#
# Exit codes:
#   0 - Bundle is valid (no anim-*.json, has compiled.tve for all templates)
#   1 - Bundle validation failed

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

if [ $# -lt 1 ]; then
    echo "Usage: $0 <app_bundle_path>"
    echo ""
    echo "Example: $0 /path/to/Build/Products/Release-iphoneos/AnimiApp.app"
    exit 1
fi

APP_BUNDLE="$1"

echo "======================================"
echo "Release Bundle Verification"
echo "======================================"
echo ""
echo "Bundle: $APP_BUNDLE"
echo ""

if [ ! -d "$APP_BUNDLE" ]; then
    echo -e "${RED}ERROR: Bundle not found: $APP_BUNDLE${NC}"
    exit 1
fi

ERRORS=0

# Check 1: No anim-*.json files
echo "Check 1: No anim-*.json files in bundle..."
ANIM_FILES=$(find "$APP_BUNDLE" -name "anim-*.json" -o -name "no-anim.json" 2>/dev/null)

if [ -n "$ANIM_FILES" ]; then
    echo -e "  ${RED}FAILED${NC} - Found animation JSON files that should be excluded:"
    echo "$ANIM_FILES" | while read -r f; do
        echo "    - $f"
    done
    ((ERRORS++))
else
    echo -e "  ${GREEN}PASSED${NC} - No animation JSON files found"
fi

# Check 2: All templates have compiled.tve
echo ""
echo "Check 2: All templates have compiled.tve..."
TEMPLATES_DIR="$APP_BUNDLE/Templates"

if [ ! -d "$TEMPLATES_DIR" ]; then
    echo -e "  ${YELLOW}SKIPPED${NC} - No Templates directory in bundle"
else
    TEMPLATE_COUNT=0
    COMPILED_COUNT=0
    MISSING_TEMPLATES=()

    for scene_file in $(find "$TEMPLATES_DIR" -name "scene.json" 2>/dev/null); do
        template_dir="$(dirname "$scene_file")"
        template_name="$(basename "$template_dir")"
        ((TEMPLATE_COUNT++))

        if [ -f "$template_dir/compiled.tve" ]; then
            ((COMPILED_COUNT++))
            echo -e "  ${GREEN}OK${NC} - $template_name has compiled.tve"
        else
            MISSING_TEMPLATES+=("$template_name")
            echo -e "  ${RED}MISSING${NC} - $template_name lacks compiled.tve"
        fi
    done

    if [ ${#MISSING_TEMPLATES[@]} -gt 0 ]; then
        ((ERRORS++))
    fi

    echo ""
    echo "  Templates: $TEMPLATE_COUNT, Compiled: $COMPILED_COUNT"
fi

# Check 3: No compiler symbols in binary (optional, for Release validation)
echo ""
echo "Check 3: No compiler pipeline symbols in binary..."
BINARY_PATH="$APP_BUNDLE/$(basename "$APP_BUNDLE" .app)"

if [ ! -f "$BINARY_PATH" ]; then
    # Try iOS bundle structure
    BINARY_PATH="$APP_BUNDLE/AnimiApp"
fi

if [ -f "$BINARY_PATH" ]; then
    COMPILER_SYMBOLS=(
        "AnimIRCompiler"
        "ScenePackageLoader"
        "AnimLoader"
        "SceneValidator"
        "AnimValidator"
        "TVECompilerCore"
    )

    FOUND_SYMBOLS=()
    for sym in "${COMPILER_SYMBOLS[@]}"; do
        if strings "$BINARY_PATH" 2>/dev/null | grep -q "$sym"; then
            FOUND_SYMBOLS+=("$sym")
        fi
    done

    if [ ${#FOUND_SYMBOLS[@]} -gt 0 ]; then
        echo -e "  ${RED}FAILED${NC} - Found compiler pipeline symbols (should not be in Release):"
        for sym in "${FOUND_SYMBOLS[@]}"; do
            echo "    - $sym"
        done
        ((ERRORS++))
    else
        echo -e "  ${GREEN}PASSED${NC} - No compiler pipeline symbols found"
    fi
else
    echo -e "  ${YELLOW}SKIPPED${NC} - Binary not found at expected path"
fi

# Summary
echo ""
echo "======================================"
echo "Summary"
echo "======================================"

if [ $ERRORS -gt 0 ]; then
    echo -e "${RED}FAILED${NC} - $ERRORS check(s) failed"
    exit 1
else
    echo -e "${GREEN}PASSED${NC} - All checks passed"
    exit 0
fi
```

- **Notes:** CI/build-phase wiring is **NOT PROVEN**.

---

## Aggregated counts (from this register)

- **By severity:** P0 = 0, P1 = 0, P2 = 6, P3 = 1
- **By category:**
  - Performance / File I/O: 1 (P2 — Debug-only)
  - Bug / Crash potential: 2 (P2)
  - Code Quality / Defensive Coding: 1 (P3 — unreachable crash path)
  - Concurrency / Type Safety: 1
  - UX-tech: 1
  - Architecture / Testing: 1
  - Tooling / Process Risk: 1
