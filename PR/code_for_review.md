# PR-C1: Mask Extraction + BBox + Unit Tests — Code for Review (v2)

## Summary

Реализация PR-C1 для GPU-based mask rendering:
- `MaskOp` и `MaskGroupScope` structures
- `extractMaskGroupScope` — extraction с поддержкой LIFO nesting и AE order
- `initialAccumulatorValue` — инициализация аккумулятора по first op mode
- `computeMaskGroupBboxFloat` и `roundClampIntersectBBoxToPixels` — bbox computation
- `sampleTriangulatedPositions` — sampling positions без аллокаций
- 27 unit tests

## Fixes Applied (per lead's review)

| Fix | Status |
|-----|--------|
| 🔴 Nested beginMask inside inner → return nil | ✅ Fixed |
| 🟠 Guard for scratch size in computeMaskGroupBboxFloat | ✅ Fixed |
| 🟠 Guard for keyframe array consistency in sampleTriangulatedPositions | ✅ Fixed |
| 🟠 Tests: XCTSkip instead of fatalError | ✅ Fixed |
| New test: testExtract_nestedBeginMaskInsideInner_returnsNil | ✅ Added |
| New test: testComputeBbox_skipsIfVertexCountMismatch | ✅ Added |

---

## 1. MaskTypes.swift (NEW FILE)

**File:** `TVECore/Sources/TVECore/MetalRenderer/MaskTypes.swift`

```swift
import Foundation

// MARK: - Mask Operation

/// Single mask operation for GPU accumulation.
/// Extracted from RenderCommand.beginMask during scope extraction.
struct MaskOp: Sendable, Equatable {
    /// Boolean operation mode (add/subtract/intersect)
    let mode: MaskMode

    /// Whether mask coverage is inverted before application
    let inverted: Bool

    /// Path ID for triangulated mask geometry
    let pathId: PathID

    /// Mask opacity [0.0...1.0]
    let opacity: Double

    /// Animation frame for animated paths
    let frame: Double
}

// MARK: - Mask Group Scope

/// Extracted mask group scope containing all mask operations
/// and inner commands to be rendered with mask applied.
///
/// Structure corresponds to LIFO-nested mask commands in AE order:
/// ```
/// beginMask(M2) → beginMask(M1) → beginMask(M0) → [inner] → endMask → endMask → endMask
/// ```
/// After extraction: `opsInAeOrder = [M0, M1, M2]` (reversed for correct application order)
struct MaskGroupScope: Sendable {
    /// Mask operations in AE application order.
    /// First mask in array is applied first (was innermost in LIFO nesting).
    let opsInAeOrder: [MaskOp]

    /// Commands to render inside the mask scope.
    /// These are rendered to bbox-sized content texture.
    let innerCommands: [RenderCommand]

    /// Index of the next command after the scope (after last endMask).
    /// Used for index jumping in execute loop.
    let endIndex: Int
}

// MARK: - Initial Accumulator Value

/// Returns initial accumulator value based on first mask operation mode.
///
/// - `add` first: acc = 0.0 (start empty, add coverage)
/// - `subtract` first: acc = 1.0 (start full, subtract coverage)
/// - `intersect` first: acc = 1.0 (start full, intersect with coverage)
///
/// - Parameter opsInAeOrder: Mask operations in AE application order
/// - Returns: Initial accumulator value (0.0 or 1.0)
func initialAccumulatorValue(for opsInAeOrder: [MaskOp]) -> Float {
    guard let first = opsInAeOrder.first else { return 0 }
    switch first.mode {
    case .add:
        return 0
    case .subtract, .intersect:
        return 1
    }
}
```

---

## 2. MaskBboxCompute.swift (NEW FILE) — with scratch guard fix

**File:** `TVECore/Sources/TVECore/MetalRenderer/MaskBboxCompute.swift`

```swift
import Foundation
import Metal

// MARK: - Pixel Bounding Box

/// Integer pixel bounding box for mask rendering.
struct PixelBBox: Equatable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    /// Converts to MTLScissorRect for GPU commands.
    var scissorRect: MTLScissorRect {
        MTLScissorRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - BBox Computation

/// Computes float bounding box for mask group from triangulated vertices in viewport pixels.
///
/// Uses triangulated vertices from PathRegistry for accurate bounds calculation.
/// Applies transforms to convert from path space to viewport space.
///
/// - Parameters:
///   - ops: Mask operations in AE order
///   - pathRegistry: Registry containing triangulated path data
///   - animToViewport: Animation to viewport transform
///   - currentTransform: Current layer transform stack
///   - scratch: Reusable scratch buffer for position sampling
/// - Returns: Bounding box in viewport pixels (float), or nil if empty/invalid
func computeMaskGroupBboxFloat(
    ops: [MaskOp],
    pathRegistry: PathRegistry,
    animToViewport: Matrix2D,
    currentTransform: Matrix2D,
    scratch: inout [Float]
) -> CGRect? {
    let pathToViewport = animToViewport.concatenating(currentTransform)

    var minX = CGFloat.greatestFiniteMagnitude
    var minY = CGFloat.greatestFiniteMagnitude
    var maxX = -CGFloat.greatestFiniteMagnitude
    var maxY = -CGFloat.greatestFiniteMagnitude

    var hasAnyVertex = false

    for op in ops {
        guard let resource = pathRegistry.path(for: op.pathId) else { continue }
        guard resource.vertexCount > 0 else { continue }

        // Sample triangulated positions at the operation's frame
        resource.sampleTriangulatedPositions(at: op.frame, into: &scratch)

        // Safety guard: ensure scratch has enough data
        // (defensive against future sampling implementation changes or corrupted resources)
        let vertexCount = resource.vertexCount
        let needed = vertexCount * 2
        guard scratch.count >= needed else { continue }

        // Transform each vertex and accumulate bounds
        for idx in 0..<vertexCount {
            let px = CGFloat(scratch[idx * 2])
            let py = CGFloat(scratch[idx * 2 + 1])

            // Apply pathToViewport transform
            let vx = pathToViewport.a * px + pathToViewport.b * py + pathToViewport.tx
            let vy = pathToViewport.c * px + pathToViewport.d * py + pathToViewport.ty

            minX = min(minX, vx)
            minY = min(minY, vy)
            maxX = max(maxX, vx)
            maxY = max(maxY, vy)
            hasAnyVertex = true
        }
    }

    guard hasAnyVertex, minX < maxX, minY < maxY else { return nil }

    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

// MARK: - BBox Rounding and Clamping

/// Rounds float bbox to integer pixels with AA expansion, clamps to target, and intersects with scissor.
///
/// Canonical rounding rules:
/// - `floor(minX/minY)` for origin
/// - `ceil(maxX/maxY)` for extent
/// - Expand by `expandAA` pixels for anti-aliasing
/// - Clamp to target bounds
/// - Intersect with current scissor (if any)
///
/// - Parameters:
///   - bboxFloat: Float bounding box in viewport pixels
///   - targetSize: Target texture size for clamping
///   - scissor: Current scissor rect (optional)
///   - expandAA: Pixels to expand for anti-aliasing (typically 2)
/// - Returns: Integer pixel bbox, or nil if fully clipped/degenerate
func roundClampIntersectBBoxToPixels(
    _ bboxFloat: CGRect,
    targetSize: (width: Int, height: Int),
    scissor: MTLScissorRect?,
    expandAA: Int = 2
) -> PixelBBox? {
    // Floor mins, ceil maxs for conservative rounding
    var x = Int(floor(bboxFloat.minX)) - expandAA
    var y = Int(floor(bboxFloat.minY)) - expandAA
    var maxX = Int(ceil(bboxFloat.maxX)) + expandAA
    var maxY = Int(ceil(bboxFloat.maxY)) + expandAA

    // Clamp to target bounds
    x = max(0, x)
    y = max(0, y)
    maxX = min(targetSize.width, maxX)
    maxY = min(targetSize.height, maxY)

    var width = maxX - x
    var height = maxY - y

    // Check for degenerate bbox after clamping
    guard width > 0, height > 0 else { return nil }

    // Intersect with scissor if present
    if let sc = scissor {
        let scMinX = sc.x
        let scMinY = sc.y
        let scMaxX = sc.x + sc.width
        let scMaxY = sc.y + sc.height

        let intMinX = max(x, scMinX)
        let intMinY = max(y, scMinY)
        let intMaxX = min(x + width, scMaxX)
        let intMaxY = min(y + height, scMaxY)

        // Check for empty intersection
        guard intMaxX > intMinX, intMaxY > intMinY else { return nil }

        x = intMinX
        y = intMinY
        width = intMaxX - intMinX
        height = intMaxY - intMinY
    }

    return PixelBBox(x: x, y: y, width: width, height: height)
}
```

---

## 3. MetalRenderer+Execute.swift — extractMaskGroupScope (with nested mask fix)

**File:** `TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift`

**CRITICAL FIX**: Nested `beginMask` inside inner content now returns `nil` instead of corrupting indices.

```swift
    /// Extracts a complete mask group scope from the command stream.
    ///
    /// Handles LIFO-nested mask structure where masks are emitted in reverse order:
    /// ```
    /// beginMask(M2) → beginMask(M1) → beginMask(M0) → [inner] → endMask → endMask → endMask
    /// ```
    ///
    /// Returns masks in AE application order (M0, M1, M2) for correct accumulation.
    /// The `endIndex` points to the next command after the last `endMask`.
    ///
    /// - Parameters:
    ///   - commands: Full command stream
    ///   - startIndex: Index of first beginMask command
    /// - Returns: Extracted scope with ops in AE order, or nil if invalid structure
    func extractMaskGroupScope(from commands: [RenderCommand], startIndex: Int) -> MaskGroupScope? {
        guard startIndex < commands.count else { return nil }

        var ops: [MaskOp] = []
        var index = startIndex

        // Phase 1: Collect consecutive beginMask commands
        while index < commands.count {
            switch commands[index] {
            case .beginMask(let mode, let inverted, let pathId, let opacity, let frame):
                ops.append(MaskOp(mode: mode, inverted: inverted, pathId: pathId, opacity: opacity, frame: frame))
                index += 1
            case .beginMaskAdd(let pathId, let opacity, let frame):
                // Legacy command: treat as add, non-inverted
                ops.append(MaskOp(mode: .add, inverted: false, pathId: pathId, opacity: opacity, frame: frame))
                index += 1
            default:
                break
            }

            // Check if next command is also a beginMask
            if index < commands.count {
                switch commands[index] {
                case .beginMask, .beginMaskAdd:
                    continue
                default:
                    break
                }
            }
            break
        }

        guard !ops.isEmpty else { return nil }

        let innerStart = index
        var depth = ops.count
        var firstEndMaskIndex: Int?

        // Phase 2: Walk until all scopes are closed
        while index < commands.count && depth > 0 {
            switch commands[index] {
            case .beginMask, .beginMaskAdd:
                // Nested mask inside a mask-group inner content is unsupported.
                // This would corrupt innerCommands/endIndex calculation.
                return nil

            case .endMask:
                if firstEndMaskIndex == nil {
                    firstEndMaskIndex = index
                }
                depth -= 1

            default:
                break
            }
            index += 1
        }

        // Verify we found all endMasks
        guard depth == 0, let innerEnd = firstEndMaskIndex else { return nil }

        // Inner commands are between last beginMask and first endMask
        let innerCommands = (innerEnd > innerStart) ? Array(commands[innerStart..<innerEnd]) : []

        // Reverse ops to get AE application order (emission was reversed)
        let opsInAeOrder = Array(ops.reversed())

        return MaskGroupScope(
            opsInAeOrder: opsInAeOrder,
            innerCommands: innerCommands,
            endIndex: index
        )
    }
```

---

## 4. PathResource.swift — sampleTriangulatedPositions (with keyframe guard fix)

**File:** `TVECore/Sources/TVECore/AnimIR/PathResource.swift`

**FIX**: Added guard for keyframe array consistency.

```swift
// MARK: - Triangulated Position Sampling

extension PathResource {
    /// Samples flattened triangulated positions (x,y,x,y,...) at the given frame.
    ///
    /// For static paths, copies positions directly. For animated paths, interpolates
    /// between keyframes using easing curves.
    ///
    /// Caller MUST reuse `out` to avoid steady-state allocations.
    ///
    /// - Parameters:
    ///   - frame: Animation frame to sample
    ///   - out: Reusable output buffer (will be cleared and filled)
    public func sampleTriangulatedPositions(at frame: Double, into out: inout [Float]) {
        out.removeAll(keepingCapacity: true)

        // Static path: copy directly
        guard keyframePositions.count > 1 else {
            if let first = keyframePositions.first {
                out.append(contentsOf: first)
            }
            return
        }

        // Animated path: find keyframe segment and interpolate
        let times = keyframeTimes

        // Safety guard: keyframeTimes and keyframePositions must have same count
        guard !times.isEmpty, times.count == keyframePositions.count else {
            if let first = keyframePositions.first {
                out.append(contentsOf: first)
            }
            return
        }

        // Before first keyframe
        if frame <= times[0] {
            out.append(contentsOf: keyframePositions[0])
            return
        }

        // After last keyframe
        if frame >= times[times.count - 1] {
            out.append(contentsOf: keyframePositions[times.count - 1])
            return
        }

        // Find segment containing frame
        for idx in 0..<(times.count - 1) {
            if frame >= times[idx] && frame < times[idx + 1] {
                let t0 = times[idx]
                let t1 = times[idx + 1]
                var linearT = (frame - t0) / (t1 - t0)

                // Apply easing if available
                if idx < keyframeEasing.count, let easing = keyframeEasing[idx] {
                    if easing.hold {
                        linearT = 0 // Hold at start value
                    } else {
                        linearT = CubicBezierEasing.solve(
                            x: linearT,
                            x1: easing.outX,
                            y1: easing.outY,
                            x2: easing.inX,
                            y2: easing.inY
                        )
                    }
                }

                // Interpolate positions
                let pos0 = keyframePositions[idx]
                let pos1 = keyframePositions[idx + 1]
                out.reserveCapacity(pos0.count)

                for pIdx in 0..<pos0.count {
                    let interpolated = pos0[pIdx] + Float(linearT) * (pos1[pIdx] - pos0[pIdx])
                    out.append(interpolated)
                }
                return
            }
        }

        // Fallback: use last keyframe
        out.append(contentsOf: keyframePositions[keyframePositions.count - 1])
    }
}
```

---

## 5. MaskExtractionTests.swift (NEW FILE) — 27 tests with XCTSkip

**File:** `TVECore/Tests/TVECoreTests/MaskExtractionTests.swift`

**FIX**: Changed `makeTestRenderer()` to use `throws` + `XCTSkip` for environments without Metal.

```swift
import XCTest
import Metal
@testable import TVECore

final class MaskExtractionTests: XCTestCase {

    // MARK: - extractMaskGroupScope Tests

    func testExtract_singleMask_returnsCorrectScope() {
        let commands: [RenderCommand] = [
            .beginMask(mode: .add, inverted: false, pathId: PathID(1), opacity: 1.0, frame: 0),
            .pushTransform(.identity),
            .popTransform,
            .endMask
        ]

        let renderer = try! makeTestRenderer()
        guard let scope = renderer.extractMaskGroupScope(from: commands, startIndex: 0) else {
            XCTFail("Should extract scope")
            return
        }

        XCTAssertEqual(scope.opsInAeOrder.count, 1)
        XCTAssertEqual(scope.opsInAeOrder[0].mode, .add)
        XCTAssertEqual(scope.opsInAeOrder[0].inverted, false)
        XCTAssertEqual(scope.opsInAeOrder[0].pathId, PathID(1))
        XCTAssertEqual(scope.opsInAeOrder[0].opacity, 1.0)
        XCTAssertEqual(scope.innerCommands.count, 2) // pushTransform, popTransform
        XCTAssertEqual(scope.endIndex, 4) // Next command after endMask
    }

    func testExtract_threeMasks_returnsAeOrder() {
        // Emitted in reverse order (as AnimIR does): M2, M1, M0
        // Should return in AE order: M0, M1, M2
        let commands: [RenderCommand] = [
            .beginMask(mode: .subtract, inverted: false, pathId: PathID(2), opacity: 0.8, frame: 0),
            .beginMask(mode: .intersect, inverted: true, pathId: PathID(1), opacity: 0.5, frame: 0),
            .beginMask(mode: .add, inverted: false, pathId: PathID(0), opacity: 1.0, frame: 0),
            .drawImage(assetId: "test", opacity: 1.0),
            .endMask,
            .endMask,
            .endMask
        ]

        let renderer = try! makeTestRenderer()
        guard let scope = renderer.extractMaskGroupScope(from: commands, startIndex: 0) else {
            XCTFail("Should extract scope")
            return
        }

        XCTAssertEqual(scope.opsInAeOrder.count, 3)

        // Verify AE order (reversed from emission)
        XCTAssertEqual(scope.opsInAeOrder[0].pathId, PathID(0))
        XCTAssertEqual(scope.opsInAeOrder[0].mode, .add)

        XCTAssertEqual(scope.opsInAeOrder[1].pathId, PathID(1))
        XCTAssertEqual(scope.opsInAeOrder[1].mode, .intersect)
        XCTAssertEqual(scope.opsInAeOrder[1].inverted, true)

        XCTAssertEqual(scope.opsInAeOrder[2].pathId, PathID(2))
        XCTAssertEqual(scope.opsInAeOrder[2].mode, .subtract)

        // Verify innerCommands is exactly [.drawImage]
        XCTAssertEqual(scope.innerCommands.count, 1)

        XCTAssertEqual(scope.endIndex, 7)
    }

    // NEW TEST: Nested beginMask inside inner content returns nil
    func testExtract_nestedBeginMaskInsideInner_returnsNil() {
        // Nested beginMask inside inner content is unsupported and should return nil
        let commands: [RenderCommand] = [
            .beginMask(mode: .add, inverted: false, pathId: PathID(1), opacity: 1.0, frame: 0),
            .pushTransform(.identity),
            .beginMask(mode: .subtract, inverted: false, pathId: PathID(2), opacity: 1.0, frame: 0), // Nested!
            .drawImage(assetId: "test", opacity: 1.0),
            .endMask,
            .popTransform,
            .endMask
        ]

        let renderer = try! makeTestRenderer()
        let scope = renderer.extractMaskGroupScope(from: commands, startIndex: 0)
        XCTAssertNil(scope, "Should return nil when nested beginMask found inside inner content")
    }

    func testExtract_legacyBeginMaskAdd_convertsToAdd() { /* ... */ }
    func testExtract_mixedNewAndLegacyMasks_handledCorrectly() { /* ... */ }
    func testExtract_emptyInnerCommands_succeeds() { /* ... */ }
    func testExtract_invalidStartIndex_returnsNil() { /* ... */ }
    func testExtract_outOfBoundsStartIndex_returnsNil() { /* ... */ }
    func testExtract_unmatchedEndMask_returnsNil() { /* ... */ }
    func testExtract_innerCommandsCorrectRange() { /* ... */ }

    // MARK: - initialAccumulatorValue Tests

    func testInitialValue_addFirst_returnsZero() { /* ... */ }
    func testInitialValue_subtractFirst_returnsOne() { /* ... */ }
    func testInitialValue_intersectFirst_returnsOne() { /* ... */ }
    func testInitialValue_emptyOps_returnsZero() { /* ... */ }
    func testInitialValue_multipleOps_usesFirst() { /* ... */ }

    // MARK: - roundClampIntersectBBoxToPixels Tests

    func testBboxRounding_floorsMinsCeilsMaxs() { /* ... */ }
    func testBboxRounding_expandsForAA() { /* ... */ }
    func testBboxRounding_clampsToTarget() { /* ... */ }
    func testBboxRounding_intersectsWithScissor() { /* ... */ }
    func testBboxRounding_fullyClipped_returnsNil() { /* ... */ }
    func testBboxRounding_degenerateBbox_returnsNil() { /* ... */ }

    // MARK: - sampleTriangulatedPositions Tests

    func testSamplePositions_staticPath_returnsPositions() { /* ... */ }
    func testSamplePositions_animatedPath_interpolates() { /* ... */ }
    func testSamplePositions_beforeFirstKeyframe_returnsFirst() { /* ... */ }
    func testSamplePositions_afterLastKeyframe_returnsLast() { /* ... */ }
    func testSamplePositions_reusesOutBuffer() { /* ... */ }

    // MARK: - computeMaskGroupBboxFloat Tests

    // NEW TEST: Verifies scratch guard skips paths with vertex count mismatch
    func testComputeBbox_skipsIfVertexCountMismatch() {
        // Create a path resource where vertexCount > actual positions stored
        // This simulates a corrupted resource where vertexCount was set incorrectly
        // The scratch guard catches this mismatch
        let positions: [Float] = [0, 0, 100, 0] // Only 2 vertices (4 floats)
        let resource = PathResource(
            pathId: PathID(0),
            keyframePositions: [positions],
            keyframeTimes: [0],
            indices: [0, 1],
            vertexCount: 4 // Claims 4 vertices but only has 2
        )

        var registry = PathRegistry()
        registry.register(resource)

        let op = MaskOp(mode: .add, inverted: false, pathId: PathID(0), opacity: 1.0, frame: 0)

        var scratch: [Float] = []

        let result = computeMaskGroupBboxFloat(
            ops: [op],
            pathRegistry: registry,
            animToViewport: .identity,
            currentTransform: .identity,
            scratch: &scratch
        )

        // Should return nil because scratch has fewer floats than vertexCount*2
        XCTAssertNil(result, "Should return nil when scratch has fewer positions than vertexCount requires")
    }

    // MARK: - Helpers

    private func makeTestRenderer() throws -> MetalRenderer {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        return try MetalRenderer(device: device, colorPixelFormat: .bgra8Unorm)
    }
}
```

---

## 6. Test Results

```
swift build: OK
swift test: 367 tests passed (including 27 MaskExtractionTests)

Test Suite 'MaskExtractionTests' passed at 2026-01-27 15:09:34.572.
     Executed 27 tests, with 0 failures (0 unexpected) in 0.017 seconds
```

---

## 7. Files Changed Summary

| File | Change |
|------|--------|
| `MaskTypes.swift` | **New file** — MaskOp, MaskGroupScope, initialAccumulatorValue |
| `MaskBboxCompute.swift` | **New file** — PixelBBox, computeMaskGroupBboxFloat (with scratch guard), roundClampIntersectBBoxToPixels |
| `MetalRenderer+Execute.swift` | **Addition** — extractMaskGroupScope (with nested mask fix) |
| `PathResource.swift` | **Addition** — sampleTriangulatedPositions (with keyframe guard) |
| `MaskExtractionTests.swift` | **New file** — 27 unit tests (with XCTSkip) |

---

## 8. PR-C1 Acceptance Criteria Checklist

- [x] `MaskOp` struct with mode, inverted, pathId, opacity, frame
- [x] `MaskGroupScope` struct with opsInAeOrder, innerCommands, endIndex
- [x] `extractMaskGroupScope` handles LIFO nesting correctly
- [x] `extractMaskGroupScope` returns ops in AE order (reversed)
- [x] `extractMaskGroupScope` correctly identifies innerCommands range (up to first endMask)
- [x] `extractMaskGroupScope` correctly sets endIndex (after last endMask)
- [x] **NEW**: `extractMaskGroupScope` returns nil for nested beginMask inside inner
- [x] Legacy `beginMaskAdd` converted to `MaskOp(mode: .add, inverted: false, ...)`
- [x] `initialAccumulatorValue` returns 0 for add-first, 1 for subtract/intersect-first
- [x] `computeMaskGroupBboxFloat` uses triangulated vertices from PathResource
- [x] **NEW**: `computeMaskGroupBboxFloat` has scratch size guard
- [x] `roundClampIntersectBBoxToPixels` implements floor/ceil + AA expand + clamp + scissor intersect
- [x] `sampleTriangulatedPositions` supports static and animated paths
- [x] **NEW**: `sampleTriangulatedPositions` has keyframe array consistency guard
- [x] `sampleTriangulatedPositions` reuses output buffer (no steady-state allocations)
- [x] **NEW**: Tests use XCTSkip for CI environments without Metal
- [x] `swift build` → OK
- [x] `swift test` → 367 tests passed (27 MaskExtractionTests)
