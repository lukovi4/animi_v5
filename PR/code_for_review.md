# PR-C4: GPU Mask Verification — Code for Review (v4 FINAL)

## Summary

Реализация PR-C4: доказательство того, что mask rendering полностью на GPU.

**Цель:**
- A) Статический аудит: убедиться что execute loop не вызывает CPU mask path
- B) Runtime доказательство: DEBUG preconditionFailure в CPU paths
- C) Интеграционный тест: контроль fallbackCount

**Визуальный результат PR-C2/C3 не изменён.**

---

## Изменения v3 → v4 (MUST-FIX)

### 🔴 MUST-FIX #1: Убраны warnings "unreachable code" ✅

Было:
```swift
#if DEBUG
preconditionFailure(...)
#endif
// ... rest of function (warnings!)
```

Стало:
```swift
#if DEBUG
    preconditionFailure(...)
#else
    // legacy implementation
    ...
#endif
```

### 🔴 MUST-FIX #2: Per-test fallback expectation ✅

Было: глобальный `XCTAssertEqual(fallbackCount, 0)` в `tearDown()`

Стало:
```swift
#if DEBUG
private var expectedMaskFallbacks: Int = 0
#endif

override func setUpWithError() throws {
    #if DEBUG
    MaskDebugCounters.reset()
    expectedMaskFallbacks = 0
    #endif
}

override func tearDown() {
    #if DEBUG
    XCTAssertEqual(MaskDebugCounters.fallbackCount, expectedMaskFallbacks,
                   "Unexpected GPU mask fallback count")
    #endif
}
```

И в тестах где fallback ожидаем:
```swift
#if DEBUG
expectedMaskFallbacks = 1
#endif
```

### 🔴 MUST-FIX #3: `MaskDebugCounters` теперь `internal` ✅

Было: `public enum MaskDebugCounters`

Стало:
```swift
#if DEBUG
/// - Note: Internal visibility to avoid polluting public API surface.
enum MaskDebugCounters {
    static var fallbackCount = 0
    static func reset() { fallbackCount = 0 }
}
#endif
```

---

## Key Code Changes (v4)

### 1. `MetalRenderer+Execute.swift` — DEBUG guard без warnings

```swift
private func renderMaskScope(...) throws {
#if DEBUG
    preconditionFailure("CPU mask path is forbidden. Must use GPU mask pipeline (renderMaskGroupScope).")
#else
    // Legacy implementation (release-only rollback path)
    let targetSize = ctx.target.sizePx
    // ... rest of function
#endif
}
```

### 2. `MaskCache.swift` — DEBUG guard без warnings

```swift
func texture(...) -> MTLTexture? {
#if DEBUG
    preconditionFailure("CPU mask cache is forbidden. Must use GPU mask pipeline (renderMaskGroupScope).")
#else
    // Legacy implementation (release-only rollback path)
    let key = MaskCacheKey(path: path, size: size, transform: transform)
    // ... rest of function
#endif
}
```

### 3. `MetalRenderer+MaskRender.swift` — internal MaskDebugCounters

```swift
#if DEBUG
/// Debug counters for mask rendering verification (PR-C4).
/// - Note: Internal visibility to avoid polluting public API surface.
enum MaskDebugCounters {
    static var fallbackCount = 0

    static func reset() {
        fallbackCount = 0
    }
}
#endif
```

### 4. `MetalRendererMaskTests.swift` — per-test fallback expectation

```swift
final class MetalRendererMaskTests: XCTestCase {
    #if DEBUG
    private var expectedMaskFallbacks: Int = 0
    #endif

    override func setUpWithError() throws {
        // ...
        #if DEBUG
        MaskDebugCounters.reset()
        expectedMaskFallbacks = 0
        #endif
    }

    override func tearDown() {
        #if DEBUG
        XCTAssertEqual(MaskDebugCounters.fallbackCount, expectedMaskFallbacks,
                       "Unexpected GPU mask fallback count")
        #endif
        // ...
    }
}
```

### 5. `testEmptyMaskPathRendersContent` — fallback expected

```swift
func testEmptyMaskPathRendersContent() throws {
    // Empty path triggers fallback (degenerate bbox) - this is expected
    #if DEBUG
    expectedMaskFallbacks = 1
    #endif
    // ... rest of test
}
```

---

## Build & Test Results (v4)

```
swift build: OK (NO WARNINGS)
swift test: 382 tests passed, 5 skipped (MaskCacheTests), 0 failures
```

---

## Files Changed Summary (v4)

| File | Change |
|------|--------|
| `MetalRenderer+Execute.swift` | **UPDATED**: `#if DEBUG...#else...#endif` pattern (no warnings) |
| `MaskCache.swift` | **UPDATED**: `#if DEBUG...#else...#endif` pattern (no warnings) |
| `MetalRenderer+MaskRender.swift` | **UPDATED**: `MaskDebugCounters` now `internal` (was `public`) |
| `MetalRendererMaskTests.swift` | **UPDATED**: `expectedMaskFallbacks` per-test property |

---

## PR-C4 Acceptance Criteria Checklist (v4 FINAL)

### A) Статический аудит:
- [x] Execute loop не вызывает `renderMaskScope()` (confirmed: dead code)
- [x] Нет других вызовов `MaskCache.texture()` для масок
- [x] `MaskRasterizer` используется только в `ShapeCache` (допустимо)

### B) Runtime доказательство:
- [x] DEBUG preconditionFailure в `renderMaskScope()` — падает если вызвать
- [x] DEBUG preconditionFailure в `MaskCache.texture()` — падает если вызвать
- [x] **NO WARNINGS** — код под `#else` компилируется только в Release

### C) Интеграционный тест:
- [x] `MaskDebugCounters` — **internal** visibility (не public)
- [x] `MaskDebugCounters.fallbackCount` отслеживает fallback events
- [x] **Per-test `expectedMaskFallbacks`** — не глобальный assert
- [x] `testEmptyMaskPathRendersContent` — `expectedMaskFallbacks = 1`
- [x] Все pixel tests автоматически становятся "GPU-only" тестами

### Cleanup (для будущего PR):
- [ ] Удалить `MaskCache`, `MaskRasterizer`, `renderMaskScope`
- [ ] Или пометить `@available(*, deprecated)`

---

## ✅ READY FOR MERGE

Все 3 MUST-FIX исправлены:
1. ✅ Unreachable code warnings убраны (`#if DEBUG...#else...#endif`)
2. ✅ Per-test fallback expectation (`expectedMaskFallbacks` property)
3. ✅ `MaskDebugCounters` теперь `internal` (не `public`)
