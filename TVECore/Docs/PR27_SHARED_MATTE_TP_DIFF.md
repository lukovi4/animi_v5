# PR-27: tp-based Track Matte (Shared Matte) — Diff Document

## Summary

One matte source (`td=1`) can now serve **multiple** consumer layers via `tp` (matte target reference).
Previously, the engine used adjacency-only matching (source must be immediately before consumer in the array).
Now `tp`-based resolution has priority, with adjacency as fallback for legacy templates.

---

## File Changes

### 1. `TVECore/Sources/TVECore/AnimIR/AnimIRCompiler.swift`

#### 1a. New error cases in `AnimIRCompilerError`

**WAS:**
```swift
public enum AnimIRCompilerError: Error, Sendable {
    case bindingLayerNotFound(bindingKey: String, animRef: String)
    case bindingLayerNotImage(bindingKey: String, layerType: Int, animRef: String)
    case bindingLayerNoAsset(bindingKey: String, animRef: String)
    case unsupportedLayerType(layerType: Int, layerName: String, animRef: String)
    case mediaInputNotInSameComp(animRef: String, mediaInputCompId: String, bindingCompId: String)
}
```

**NOW:**
```swift
public enum AnimIRCompilerError: Error, Sendable {
    case bindingLayerNotFound(bindingKey: String, animRef: String)
    case bindingLayerNotImage(bindingKey: String, layerType: Int, animRef: String)
    case bindingLayerNoAsset(bindingKey: String, animRef: String)
    case unsupportedLayerType(layerType: Int, layerName: String, animRef: String)
    case mediaInputNotInSameComp(animRef: String, mediaInputCompId: String, bindingCompId: String)
    case matteTargetNotFound(tp: Int, consumerName: String, animRef: String)
    case matteTargetNotSource(tp: Int, targetName: String, consumerName: String, animRef: String)
    case matteTargetInvalidOrder(tp: Int, consumerName: String, animRef: String)
}
```

3 new error descriptions added to `errorDescription` (fatal "template corrupted").

#### 1b. `compileLayers` first pass rewritten

**WAS:** Source-driven adjacency loop
```swift
// First pass: identify matte source -> consumer relationships
// In Lottie, matte source (td=1) is immediately followed by consumer (tt=1|2)
var matteSourceForConsumer: [LayerID: LayerID] = [:]

for (index, lottieLayer) in lottieLayers.enumerated() where (lottieLayer.isMatteSource ?? 0) == 1 {
    let sourceId = lottieLayer.index ?? index
    // The next layer is the consumer
    if index + 1 < lottieLayers.count {
        let consumerLayer = lottieLayers[index + 1]
        let consumerId = consumerLayer.index ?? (index + 1)
        matteSourceForConsumer[consumerId] = sourceId
    }
}
```

**NOW:** Consumer-driven tp-based + adjacency fallback
```swift
// Build lookup tables (once per composition)
var indToArrayIndex: [Int: Int] = [:]
var indToLayerId: [Int: LayerID] = [:]
var matteSourceInds: Set<Int> = []

for (arrayIndex, lottieLayer) in lottieLayers.enumerated() {
    if let ind = lottieLayer.index {
        indToArrayIndex[ind] = arrayIndex
        indToLayerId[ind] = ind
    }
    if (lottieLayer.isMatteSource ?? 0) == 1 {
        let ind = lottieLayer.index ?? arrayIndex
        matteSourceInds.insert(ind)
    }
}

// First pass: consumer-driven matte binding
var matteSourceForConsumer: [LayerID: LayerID] = [:]

for (arrayIndex, lottieLayer) in lottieLayers.enumerated() {
    guard lottieLayer.trackMatteType != nil else { continue }
    let consumerId: LayerID = lottieLayer.index ?? arrayIndex
    let consumerName = lottieLayer.name ?? "Layer_\(arrayIndex)"

    if let tp = lottieLayer.matteTarget {
        // tp-based: resolve via ind, validate td=1 and order
        guard let sourceId = indToLayerId[tp] else {
            throw AnimIRCompilerError.matteTargetNotFound(...)
        }
        guard matteSourceInds.contains(tp) else {
            throw AnimIRCompilerError.matteTargetNotSource(...)
        }
        guard let sourceArrayIndex = indToArrayIndex[tp],
              sourceArrayIndex < arrayIndex else {
            throw AnimIRCompilerError.matteTargetInvalidOrder(...)
        }
        matteSourceForConsumer[consumerId] = sourceId
    } else {
        // Legacy adjacency fallback
        if arrayIndex > 0 {
            let prevLayer = lottieLayers[arrayIndex - 1]
            if (prevLayer.isMatteSource ?? 0) == 1 {
                let sourceId: LayerID = prevLayer.index ?? (arrayIndex - 1)
                matteSourceForConsumer[consumerId] = sourceId
            }
        }
    }
}
```

Second pass (compile all layers with matte info) — **unchanged**.

---

### 2. `TVECore/Sources/TVECore/AnimValidator/AnimValidationCode.swift`

**ADDED** 3 new codes:
```swift
/// Matte target (tp) references a layer ind that does not exist
public static let matteTargetNotFound = "MATTE_TARGET_NOT_FOUND"

/// Matte target (tp) references a layer that is not a matte source (td != 1)
public static let matteTargetNotSource = "MATTE_TARGET_NOT_SOURCE"

/// Matte target (tp) references a layer that appears after the consumer in the array
public static let matteTargetInvalidOrder = "MATTE_TARGET_INVALID_ORDER"
```

---

### 3. `TVECore/Sources/TVECore/AnimValidator/AnimValidator.swift`

#### `validateMattePairs` rewritten

**WAS:** Adjacency-only validation
```swift
func validateMattePairs(layers:context:animRef:issues:) {
    for (index, layer) in layers.enumerated() {
        if let trackMatteType = layer.trackMatteType, ... {
            // Consumer cannot be first layer
            if index == 0 { ... error ... }
            // Previous layer must be td==1
            let previousLayer = layers[index - 1]
            if !previousIsMatteSource { ... error ... }
        }
        // td=1 + tt check (unchanged)
    }
}
```

**NOW:** tp-based + adjacency fallback
```swift
func validateMattePairs(layers:context:animRef:issues:) {
    // Build ind -> arrayIndex lookup
    var indToArrayIndex: [Int: Int] = [:]
    for (arrayIndex, layer) in layers.enumerated() {
        if let ind = layer.index { indToArrayIndex[ind] = arrayIndex }
    }

    for (index, layer) in layers.enumerated() {
        if let trackMatteType = layer.trackMatteType, ... {
            if let tp = layer.matteTarget {
                // tp-based: resolve via ind
                guard let sourceArrayIndex = indToArrayIndex[tp] else {
                    ... MATTE_TARGET_NOT_FOUND ...
                }
                // Check td==1
                if !targetIsMatteSource {
                    ... MATTE_TARGET_NOT_SOURCE ...
                }
                // Check order
                if sourceArrayIndex >= index {
                    ... MATTE_TARGET_INVALID_ORDER ...
                }
            } else {
                // Legacy adjacency (unchanged logic)
                if index == 0 { ... UNSUPPORTED_MATTE_LAYER_MISSING ... }
                if !previousIsMatteSource { ... UNSUPPORTED_MATTE_LAYER_ORDER ... }
            }
        }
        // td=1 + tt check (unchanged)
    }
}
```

---

### 4. `TVECore/Sources/TVECore/Lottie/LottieLayer.swift`

**No changes.** `matteTarget` (CodingKey `"tp"`) was already parsed but unused.
Now consumed by both compiler and validator.

---

### 5. `TVECore/Sources/TVECore/AnimIR/AnimIR.swift`

**No changes.** Render path (`emitMatteScope`) already works via `matte.sourceLayerId`.
Shared matte (same sourceLayerId for multiple consumers) works out of the box.

---

### 6. New Test File: `TVECore/Tests/TVECoreTests/SharedMatteTests.swift`

16 new tests:

| # | Test | What it verifies |
|---|------|-----------------|
| 1 | `testCompiler_sharedMatte_tpBased_bothConsumersLinked` | Core: 2 non-adjacent consumers both get sourceLayerId=2 |
| 2 | `testCompiler_sharedMatte_sourceIsFlagged` | Source has isMatteSource=true |
| 3 | `testCompiler_sharedMatte_nonConsumerHasNoMatte` | Non-consumer layer has no matte |
| 4 | `testCompiler_legacyAdjacency_consumerLinkedToAdjacentSource` | Legacy adjacency still works when tp absent |
| 5 | `testCompiler_tpTargetNotFound_throws` | tp=99 (no such ind) -> matteTargetNotFound |
| 6 | `testCompiler_tpTargetNotSource_throws` | tp -> layer without td=1 -> matteTargetNotSource |
| 7 | `testCompiler_tpTargetInvalidOrder_throws` | consumer before source -> matteTargetInvalidOrder |
| 8 | `testValidator_tpTargetNotFound_returnsError` | Validator: MATTE_TARGET_NOT_FOUND |
| 9 | `testValidator_tpTargetNotSource_returnsError` | Validator: MATTE_TARGET_NOT_SOURCE |
| 10 | `testValidator_tpTargetInvalidOrder_returnsError` | Validator: MATTE_TARGET_INVALID_ORDER |
| 11 | `testValidator_tpValid_sharedMatte_noErrors` | Valid shared matte -> no errors |
| 12 | `testValidator_legacyAdjacency_stillWorks` | Legacy adjacency -> no errors |
| 13 | `testGoldenFixture_polaroidDataJSON_sharedMatte` | Real data.json: plastik+media both -> mediaInput |
| 14 | `testValidatorFixture_tpTargetNotFound_returnsError` | Fixture: neg_matte_tp_target_not_found |
| 15 | `testValidatorFixture_tpTargetNotSource_returnsError` | Fixture: neg_matte_tp_target_not_source |
| 16 | `testValidatorFixture_tpInvalidOrder_returnsError` | Fixture: neg_matte_tp_invalid_order |

---

### 7. New Test Resources

| Path | Description |
|------|-------------|
| `Resources/shared_matte/data.json` | Golden fixture: real polaroid template from AE export |
| `Resources/negative/neg_matte_tp_target_not_found/anim.json` | tp=99, no layer with ind=99 |
| `Resources/negative/neg_matte_tp_target_not_source/anim.json` | tp=1, layer ind=1 has no td=1 |
| `Resources/negative/neg_matte_tp_invalid_order/anim.json` | consumer at index 0, source at index 1 |

---

## Test Results

**Before:** 760 tests, 0 failures
**After:** 776 tests, 0 failures (+16 new, 5 skipped)

---

## Key Design Decisions (from TL review)

1. `tp` resolves **only via `ind`** (no array-index fallback)
2. `tp`-based has priority; adjacency is fallback when `tp` absent
3. Source **must** have `td=1` (strict)
4. Order checked by **array index** (not `ind`)
5. `tp` scope is **within composition** only (no cross-comp)
6. Compiler errors are **fatal throw** ("template corrupted")
7. Shared matte renders source N times (no caching in v1)
