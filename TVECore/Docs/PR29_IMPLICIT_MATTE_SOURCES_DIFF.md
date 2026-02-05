# PR-29: Implicit tp Matte Sources + Matte Chains — Diff (Было/Стало)

## Summary

- `tp`-target layers no longer require `td=1` to be matte sources (implicit source)
- Matte chains supported: a source can itself be a consumer of another matte
- `unsupportedMatteSourceHasConsumer` validation removed (matte chains are valid)
- New recursive `emitLayerForMatteSource` helper for correct chain rendering
- 818 tests pass (9 new, 3 updated)

---

## A1) `AnimIRCompiler.swift`

### Error enum — removed `matteTargetNotSource`

**Было:**
```swift
public enum AnimIRCompilerError: Error, Sendable {
    ...
    case matteTargetNotFound(tp: Int, consumerName: String, animRef: String)
    case matteTargetNotSource(tp: Int, targetName: String, consumerName: String, animRef: String)
    case matteTargetInvalidOrder(tp: Int, consumerName: String, animRef: String)
}
```

**Стало:**
```swift
public enum AnimIRCompilerError: Error, Sendable {
    ...
    case matteTargetNotFound(tp: Int, consumerName: String, animRef: String)
    case matteTargetInvalidOrder(tp: Int, consumerName: String, animRef: String)
}
```

### Error description — removed `matteTargetNotSource` case

**Было:**
```swift
case .matteTargetNotSource(let tp, let targetName, let consumerName, let animRef):
    return "Matte target tp=\(tp) layer '\(targetName)' is not a matte source (td!=1) for consumer '\(consumerName)' in \(animRef)"
case .matteTargetInvalidOrder(...)
```

**Стало:**
```swift
case .matteTargetInvalidOrder(...)
```

### First pass — removed td==1 guard

**Было:**
```swift
if let tp = lottieLayer.matteTarget {
    guard let sourceId = indToLayerId[tp],
          let sourceArrayIndex = indToArrayIndex[tp] else {
        throw AnimIRCompilerError.matteTargetNotFound(...)
    }

    // Source must have td=1 (checked directly on the resolved layer)
    let sourceLayer = lottieLayers[sourceArrayIndex]
    guard (sourceLayer.isMatteSource ?? 0) == 1 else {
        let targetName = sourceLayer.name ?? "ind=\(tp)"
        throw AnimIRCompilerError.matteTargetNotSource(
            tp: tp, targetName: targetName,
            consumerName: consumerName, animRef: animRef
        )
    }

    // Source must appear before consumer in the array
    guard sourceArrayIndex < arrayIndex else { ... }
```

**Стало:**
```swift
if let tp = lottieLayer.matteTarget {
    guard let sourceId = indToLayerId[tp],
          let sourceArrayIndex = indToArrayIndex[tp] else {
        throw AnimIRCompilerError.matteTargetNotFound(...)
    }

    // Source must appear before consumer in the array
    guard sourceArrayIndex < arrayIndex else { ... }
```

### Between first and second pass — collect implicit set

**Было:**
```swift
        // Second pass: compile all layers with matte info
```

**Стало:**
```swift
        // PR-29: Collect implicit matte source layer IDs.
        // Any layer targeted via tp is an implicit matte source (even without td=1).
        let implicitMatteSourceIds = Set(matteSourceForConsumer.values)

        // Second pass: compile all layers with matte info
```

### compileLayer — new parameter + expanded isMatteSource

**Было:**
```swift
private func compileLayer(
    lottie: LottieLayer,
    index: Int,
    compId: CompID,
    animRef: String,
    fallbackOp: Double,
    matteInfo: MatteInfo?,
    pathRegistry: inout PathRegistry
) throws -> Layer {
    ...
    // Check if this is a matte source
    let isMatteSource = (lottie.isMatteSource ?? 0) == 1
```

**Стало:**
```swift
private func compileLayer(
    lottie: LottieLayer,
    index: Int,
    compId: CompID,
    animRef: String,
    fallbackOp: Double,
    matteInfo: MatteInfo?,
    implicitMatteSourceIds: Set<LayerID>,
    pathRegistry: inout PathRegistry
) throws -> Layer {
    ...
    // PR-29: Matte source = explicit (td=1) OR implicit (tp-target from another consumer)
    let isMatteSource = (lottie.isMatteSource ?? 0) == 1 || implicitMatteSourceIds.contains(layerId)
```

---

## A2) `AnimIRTypes.swift`

**Без изменений.** `Layer.isMatteSource: Bool` остается, семантика расширена в компиляторе (explicit || implicit).

---

## A3) `AnimIR.swift`

### New helper: `emitLayerForMatteSource` (with cycle guard)

**Было:** (не существовал)

**Стало:**
```swift
/// PR-29: Renders a matte source layer, supporting matte chains.
///
/// Recursion is bounded by two mechanisms:
/// 1. Compiler order check (sourceArrayIndex < consumerArrayIndex) guarantees DAG
/// 2. Runtime `visited` set detects cycles defensively (future-proofing)
private mutating func emitLayerForMatteSource(
    layerId: LayerID,
    context: RenderContext,
    commands: inout [RenderCommand],
    visited: Set<LayerID> = []
) {
    // Defensive cycle guard
    guard !visited.contains(layerId) else {
        assertionFailure("Matte chain cycle detected at layerId=\(layerId)")
        lastRenderIssues.append(RenderIssue(
            severity: .error,
            code: RenderIssue.codeMatteChainCycle,
            path: "anim(\(meta.sourceAnimRef)).layers[id=\(layerId)]",
            message: "Matte chain cycle detected at layer id=\(layerId)",
            frameIndex: context.frameIndex
        ))
        return
    }

    guard let layer = context.layerById[layerId],
          let resolved = computeLayerWorld(layer, context: context) else { return }

    var nextVisited = visited
    nextVisited.insert(layerId)

    if let matte = layer.matte {
        emitMatteScope(
            consumer: layer, consumerResolved: resolved,
            matte: matte, context: context,
            commands: &commands, matteChainVisited: nextVisited
        )
    } else {
        emitRegularLayerCommands(
            layer, resolved: resolved,
            context: context, commands: &commands
        )
    }
}
```

### `emitMatteScope` — new `matteChainVisited` parameter + uses new helper

**Было:**
```swift
private mutating func emitMatteScope(
    consumer: Layer, consumerResolved: ResolvedTransform,
    matte: MatteInfo, context: RenderContext,
    commands: inout [RenderCommand]
) {
    ...
    commands.append(.beginGroup(name: "matteSource"))
    if let sourceLayer = context.layerById[matte.sourceLayerId] {
        if let sourceResolved = computeLayerWorld(sourceLayer, context: context) {
            emitRegularLayerCommands(sourceLayer, resolved: sourceResolved, ...)
        }
    } else { /* error */ }
    ...
}
```

**Стало:**
```swift
private mutating func emitMatteScope(
    consumer: Layer, consumerResolved: ResolvedTransform,
    matte: MatteInfo, context: RenderContext,
    commands: inout [RenderCommand],
    matteChainVisited: Set<LayerID> = []   // PR-29: cycle guard
) {
    ...
    commands.append(.beginGroup(name: "matteSource"))
    if context.layerById[matte.sourceLayerId] != nil {
        emitLayerForMatteSource(
            layerId: matte.sourceLayerId, context: context,
            commands: &commands, visited: matteChainVisited
        )
    } else { /* error */ }
    ...
}
```

### `RenderIssue.swift` — new cycle code

**Было:** (не существовал)

**Стало:**
```swift
/// PR-29: Cycle detected in matte chain (source → consumer → ... → source)
public static let codeMatteChainCycle = "MATTE_CHAIN_CYCLE"
```

---

## A4) `AnimValidator.swift`

### `validateMattePairs` doc comment

**Было:**
```swift
/// For each matte source layer (td == 1):
/// - Should not itself be a matte consumer (tt should be nil)
```

**Стало:**
```swift
/// For each consumer layer (tt != nil):
/// - If tp != nil: validate via tp (ind-based lookup, order check).
///   td==1 is NOT required — tp-targets become implicit matte sources (PR-29).
```

### tp-branch — removed td==1 check

**Было:**
```swift
// Target must be a matte source (td==1)
let targetLayer = layers[sourceArrayIndex]
let targetIsMatteSource = (targetLayer.isMatteSource ?? 0) == 1
if !targetIsMatteSource {
    issues.append(ValidationIssue(
        code: AnimValidationCode.matteTargetNotSource,
        severity: .error,
        path: "\(basePath).tp",
        message: "Matte target tp=\(tp) layer '...' is not a matte source (td!=1)"
    ))
}

// Source must appear before consumer in array
```

**Стало:**
```swift
// PR-29: td==1 is NOT required for tp-targets.
// tp-targets become implicit matte sources in the compiler.

// Source must appear before consumer in array
```

### Removed `unsupportedMatteSourceHasConsumer` check

**Было:**
```swift
// Check if matte source (td=1) is also a consumer (has tt) - this is invalid
let isMatteSource = (layer.isMatteSource ?? 0) == 1
if isMatteSource, let trackMatteType = layer.trackMatteType {
    issues.append(ValidationIssue(
        code: AnimValidationCode.unsupportedMatteSourceHasConsumer,
        severity: .error,
        path: "\(basePath).td",
        message: "Matte source (td=1) should not be a matte consumer (tt=\(trackMatteType))"
    ))
}
```

**Стало:**
```swift
// PR-29: Matte source (td=1) CAN be a consumer (matte chains).
// Removed unsupportedMatteSourceHasConsumer check per TL decision.
```

---

## A5) `AnimValidationCode.swift`

### Removed dead codes

**Было:**
```swift
/// Matte source (td=1) should not itself be a matte consumer (has tt)
public static let unsupportedMatteSourceHasConsumer = "UNSUPPORTED_MATTE_SOURCE_HAS_CONSUMER"

/// Matte target (tp) references a layer ind that does not exist
public static let matteTargetNotFound = "MATTE_TARGET_NOT_FOUND"

/// Matte target (tp) references a layer that is not a matte source (td != 1)
public static let matteTargetNotSource = "MATTE_TARGET_NOT_SOURCE"

/// Matte target (tp) references a layer that appears after the consumer in the array
public static let matteTargetInvalidOrder = "MATTE_TARGET_INVALID_ORDER"
```

**Стало:**
```swift
/// Matte target (tp) references a layer ind that does not exist
public static let matteTargetNotFound = "MATTE_TARGET_NOT_FOUND"

/// Matte target (tp) references a layer that appears after the consumer in the array
public static let matteTargetInvalidOrder = "MATTE_TARGET_INVALID_ORDER"
```

---

## B) Tests

### New file: `ImplicitMatteSourceTests.swift` (9 tests)

| # | Test | Description |
|---|------|-------------|
| 1 | `testCompiler_tpTargetWithoutTd_isAccepted_andBecomesImplicitSource` | tp -> target without td=1 compiles, target gets isMatteSource=true |
| 2 | `testCompiler_matteChain_tpTargetIsConsumer_compiles` | mask <- plastik <- consumer chain compiles correctly |
| 3 | `testGoldenFixture_polaroidFull_compilesMatteChain` | Real polaroid_full.json: mediaInput->plastik->mask chain |
| 4 | `testRenderer_matteChain_producesNestedMatteScope` | Chain produces 2 nested beginMatte/endMatte pairs |
| 5 | `testRenderer_implicitSource_skippedInMainPass` | Implicit source only renders inside matteSource group |
| 6 | `testValidator_tpTargetWithoutTd_noMattePairErrors` | Validator: no errors for tp-target without td=1 |
| 7 | `testValidator_matteChain_sourceIsConsumer_noError` | Validator: chain (source is consumer) has no errors |
| 8 | `testCompiler_tpTargetNotFound_stillThrows` | Negative: tp=99 not found -> matteTargetNotFound |
| 9 | `testCompiler_tpTargetInvalidOrder_stillThrows` | Negative: source after consumer -> matteTargetInvalidOrder |

### New fixture: `Resources/polaroid_full/data.json`

Copy of `polaroid_full.json` (bm:3->bm:0 on plastik) with matte chain topology:
- `mask` (ind=2, td=1) — explicit source
- `plastik` (ind=3, tt=1, tp=2, hd=true) — consumer of mask, implicit source
- `media` (ind=4, tt=1, tp=2) — consumer of mask
- `mediaInput` (ind=5, tt=1, tp=3) — consumer of plastik (implicit source)

### Updated existing tests

| File | Test | Change |
|------|------|--------|
| `SharedMatteTests.swift` | `testCompiler_tpTargetNotSource_throws` | Renamed to `testCompiler_tpTargetWithoutTd_isAccepted_asImplicitSource`: now asserts compilation succeeds and target gets isMatteSource=true |
| `SharedMatteTests.swift` | `testValidator_tpTargetNotSource_returnsError` | Renamed to `testValidator_tpTargetWithoutTd_noError`: asserts NO errors produced |
| `SharedMatteTests.swift` | `testValidatorFixture_tpTargetNotSource_returnsError` | Renamed to `testValidatorFixture_tpTargetNotSource_noErrorExpected`: asserts no matte errors |
| `AnimValidatorTests.swift` | `testNegativeAsset_matteSourceIsConsumer_returnsError` | Renamed to `testNegativeAsset_matteSourceIsConsumer_noLongerError`: asserts no UNSUPPORTED_MATTE_SOURCE_HAS_CONSUMER |

---

## Test Results

**818 tests, 0 failures, 5 skipped** (baseline was 809, +9 new)
