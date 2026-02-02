# PR-21 — Fix nested masks in MetalRenderer (mask-in-mask support)

## Summary

`extractMaskGroupScope` now supports nested `beginMask`/`endMask` pairs using depth counter.
Scenes with container reveal + inputClip no longer drop masks (previously fell back to linear execution).
No changes to AnimIR/ScenePlayer/RenderCommand API.

**Build:** OK | **Tests:** 729 passed, 0 failures, 5 skipped

---

## File (A): `TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift` — MODIFIED

### Docstring — added nested mask documentation

**БЫЛО:**
```swift
    /// beginMask(M2) → beginMask(M1) → beginMask(M0) → [inner] → endMask → endMask → endMask
    /// ```
    ///
    /// Returns masks in AE application order (M0, M1, M2) for correct accumulation.
```

**СТАЛО:**
```swift
    /// beginMask(M2) → beginMask(M1) → beginMask(M0) → [inner] → endMask → endMask → endMask
    /// ```
    ///
    /// Also supports nested mask scopes inside inner content (e.g. container mask
    /// wrapping a binding layer that has its own inputClip mask):
    /// ```
    /// beginMask(container) → [… beginMask(inputClip) … endMask …] → endMask
    /// ```
    /// Nested scopes are included verbatim in `innerCommands` and handled
    /// recursively by `drawInternal`.
    ///
    /// Returns masks in AE application order (M0, M1, M2) for correct accumulation.
```

### Phase 1 comment — clarified scope

**БЫЛО:**
```swift
        // Phase 1: Collect consecutive beginMask commands
```

**СТАЛО:**
```swift
        // Phase 1: Collect consecutive beginMask commands (outer chain)
```

### Phase 2 — CORE FIX: depth-aware nested mask parsing

**БЫЛО:**
```swift
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
```

**СТАЛО:**
```swift
        let baseDepth = ops.count
        let innerStart = index
        var depth = baseDepth
        var innerEnd: Int?

        // Phase 2: Walk until all outer scopes are closed.
        // Nested beginMask/endMask pairs inside inner content are tracked via depth
        // and included in innerCommands — they will be handled recursively by drawInternal.
        while index < commands.count && depth > 0 {
            switch commands[index] {
            case .beginMask, .beginMaskAdd:
                depth += 1

            case .endMask:
                // Before decrement: if depth == baseDepth, all nested scopes are closed
                // and this endMask starts closing the outer chain.
                if innerEnd == nil && depth == baseDepth {
                    innerEnd = index
                }
                depth -= 1

            default:
                break
            }
            index += 1
        }

        // Verify balanced structure
        guard depth == 0, let innerEndIdx = innerEnd else {
            #if DEBUG
            print("[TVECore] ⚠️ Unbalanced mask commands: depth=\(depth) at end of stream")
            #endif
            return nil
        }

        // Inner commands: everything between outer chain and first outer endMask.
        // For nested scopes, this includes the complete nested beginMask…endMask pair.
        let innerCommands = (innerEndIdx > innerStart) ? Array(commands[innerStart..<innerEndIdx]) : []
```

---

## File (B): `TVECore/Sources/TVECore/MetalRenderer/MaskTypes.swift` — MODIFIED

### `MaskGroupScope` docstring — added note about nested scopes

**БЫЛО:**
```swift
/// After extraction: `opsInAeOrder = [M0, M1, M2]` (reversed for correct application order)
struct MaskGroupScope: Sendable {
```

**СТАЛО:**
```swift
/// After extraction: `opsInAeOrder = [M0, M1, M2]` (reversed for correct application order)
///
/// Inner commands may themselves contain nested mask scopes (e.g. inputClip inside
/// a container mask). These are passed verbatim and handled recursively by `drawInternal`.
struct MaskGroupScope: Sendable {
```

---

## File (C): `TVECore/Tests/TVECoreTests/MaskExtractionTests.swift` — MODIFIED

### 1. Updated comment in `testExtract_innerCommandsCorrectRange`

**БЫЛО:**
```swift
    func testExtract_innerCommandsCorrectRange() throws {
        // Verify that innerCommands doesn't include any beginMask or endMask
```

**СТАЛО:**
```swift
    func testExtract_innerCommandsCorrectRange() throws {
        // For a single flat mask scope (no nesting), inner commands contain no mask commands
```

### 2. Replaced `testExtract_nestedBeginMaskInsideInner_returnsNil` → `testExtract_nestedBeginMaskInsideInner_succeeds`

**БЫЛО:**
```swift
    func testExtract_nestedBeginMaskInsideInner_returnsNil() throws {
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

        let renderer = try makeTestRenderer()
        let scope = renderer.extractMaskGroupScope(from: commands, startIndex: 0)
        XCTAssertNil(scope, "Should return nil when nested beginMask found inside inner content")
    }
```

**СТАЛО:**
```swift
    func testExtract_nestedBeginMaskInsideInner_succeeds() throws {
        // Nested beginMask inside inner content is supported via depth tracking.
        // Inner commands include the complete nested scope (beginMask…endMask).
        let commands: [RenderCommand] = [
            .beginMask(mode: .add, inverted: false, pathId: PathID(1), opacity: 1.0, frame: 0),
            .pushTransform(.identity),
            .beginMask(mode: .subtract, inverted: false, pathId: PathID(2), opacity: 1.0, frame: 0), // Nested
            .drawImage(assetId: "test", opacity: 1.0),
            .endMask, // closes nested
            .popTransform,
            .endMask  // closes outer
        ]

        let renderer = try makeTestRenderer()
        guard let scope = renderer.extractMaskGroupScope(from: commands, startIndex: 0) else {
            XCTFail("Should extract scope with nested mask")
            return
        }

        // Outer chain: 1 op (PathID 1)
        XCTAssertEqual(scope.opsInAeOrder.count, 1)
        XCTAssertEqual(scope.opsInAeOrder[0].pathId, PathID(1))
        XCTAssertEqual(scope.opsInAeOrder[0].mode, .add)

        // Inner commands: pushTransform, beginMask(nested), drawImage, endMask, popTransform
        XCTAssertEqual(scope.innerCommands.count, 5)

        // Verify nested beginMask is in inner commands
        if case .beginMask(let mode, _, let pathId, _, _) = scope.innerCommands[1] {
            XCTAssertEqual(mode, .subtract)
            XCTAssertEqual(pathId, PathID(2))
        } else {
            XCTFail("Expected beginMask at index 1 of inner commands")
        }

        // Verify nested endMask is in inner commands
        if case .endMask = scope.innerCommands[3] {
            // OK
        } else {
            XCTFail("Expected endMask at index 3 of inner commands")
        }

        // endIndex: past the outer endMask
        XCTAssertEqual(scope.endIndex, 7)
    }
```

### 3. NEW: `testExtract_twoLevelNested_succeeds`

A → B → C (depth 3). Verifies all three PathIDs in inner commands, endIndex = 11.

```swift
    func testExtract_twoLevelNested_succeeds() throws {
        // A contains B contains C — depth 3
        let commands: [RenderCommand] = [
            .beginMask(mode: .add, inverted: false, pathId: PathID(1), opacity: 1.0, frame: 0),       // A (outer)
            .beginGroup(name: "layer"),
            .beginMask(mode: .intersect, inverted: false, pathId: PathID(2), opacity: 0.8, frame: 0), // B (nested)
            .pushTransform(.identity),
            .beginMask(mode: .subtract, inverted: true, pathId: PathID(3), opacity: 0.5, frame: 0),   // C (nested^2)
            .drawImage(assetId: "deep", opacity: 1.0),
            .endMask, // C
            .popTransform,
            .endMask, // B
            .endGroup,
            .endMask  // A
        ]
        // assert: ops=[A], innerCommands=9 items, B at [1], C at [3], endIndex=11
    }
```

### 4. NEW: `testExtract_lifoWithNested_succeeds`

Two outer LIFO masks (M2, M1) + nested mask (N). Verifies AE order reversal, endIndex = 9.

```swift
    func testExtract_lifoWithNested_succeeds() throws {
        // Two outer LIFO masks (M2, M1) + nested mask (N) inside inner content
        let commands: [RenderCommand] = [
            .beginMask(mode: .subtract, inverted: false, pathId: PathID(2), opacity: 0.9, frame: 0), // M2
            .beginMask(mode: .add, inverted: false, pathId: PathID(1), opacity: 1.0, frame: 0),      // M1
            .pushTransform(.identity),
            .beginMask(mode: .intersect, inverted: false, pathId: PathID(5), opacity: 1.0, frame: 0), // N
            .drawImage(assetId: "content", opacity: 1.0),
            .endMask, // N
            .popTransform,
            .endMask, // M1
            .endMask  // M2
        ]
        // assert: opsInAeOrder=[M1,M2], innerCommands=5, endIndex=9
    }
```

### 5. NEW: `testExtract_nestedWithMoreInnerAfter_succeeds`

Container mask with nested inputClip + extra content after nested scope. Verifies 6 inner commands.

```swift
    func testExtract_nestedWithMoreInnerAfter_succeeds() throws {
        let commands: [RenderCommand] = [
            .beginMask(mode: .add, inverted: false, pathId: PathID(1), opacity: 1.0, frame: 0),
            .beginGroup(name: "inputClip"),
            .beginMask(mode: .intersect, inverted: false, pathId: PathID(2), opacity: 1.0, frame: 0),
            .drawImage(assetId: "clipped", opacity: 1.0),
            .endMask,
            .endGroup,
            .drawImage(assetId: "extra", opacity: 0.5),
            .endMask
        ]
        // assert: ops=1, innerCommands=6, last inner="extra", endIndex=8
    }
```

### 6. NEW: `testExtract_unbalancedNested_returnsNil`

Nested beginMask without matching endMask. Verifies nil return (graceful failure).

```swift
    func testExtract_unbalancedNested_returnsNil() throws {
        let commands: [RenderCommand] = [
            .beginMask(mode: .add, inverted: false, pathId: PathID(1), opacity: 1.0, frame: 0),
            .beginMask(mode: .subtract, inverted: false, pathId: PathID(2), opacity: 1.0, frame: 0),
            .drawImage(assetId: "test", opacity: 1.0),
            .endMask  // only 1 endMask for 2 beginMask
        ]
        // assert: scope == nil
    }
```

---

## Files NOT changed (verified during audit)

- `RenderCommand` enum — no changes
- `AnimIR` / compiler / ScenePlayer — no changes
- `MetalRenderer+MaskRender.swift` — `renderMaskGroupScope` + `drawInternal` already recursive
- `extractMatteScope` — already depth-safe (verified at lines 1264-1278)
