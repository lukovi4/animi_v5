Ниже — **полностью исправленный финальный план PR-C (C1/C2/C3)** с учётом всех блокеров/важных правок, плюс **канонический псевдокод** execute-loop и renderMaskGroupScope. Это можно отдавать разработчику “как есть”.

---

# PR-C: GPU Mask Rendering — Final Canonical Plan (Ready for Implementation)

## Цель

Заменить CPU raster/stencil маски на **GPU texture ops** (coverage → boolean combine → content×mask composite) с:

* **полной поддержкой** add/subtract/intersect + inverted + opacity
* **корректным AE-порядком** применения масок
* **bbox/scissor оптимизацией**
* **ping-pong accumulator** (никаких in-place read/write)
* **feature flag backend** (CPU fallback) без изменения matte поведения

## Декомпозиция

* **PR-C1**: Extraction + bbox math + unit tests (без GPU рендера)
* **PR-C2**: GPU renderer path (correctness first) + helpers
* **PR-C3**: Feature flag + integration tests (GPU vs CPU parity) + rollout

---

# Канонические инварианты (MUST)

1. **Ping-pong**: `accIn !== accOut` всегда
2. **Content texture bbox-sized**, не full target
3. **Clear R8** только через **render pass clear** (`loadAction = .clear`)
4. **BBox** строится по **triangulated vertices**, с `floor/ceil`, AA expand, clamp, intersect scissor
5. **Branch backend BEFORE extraction**
6. **Matte pipeline не менять** (никаких новых wrapping/ordering для matte)

---

# Общая математика трансформаций (Canonical)

```
pathToViewport = animToViewport ∘ currentTransform

bboxOriginPx = (bboxX, bboxY)  // integer pixels after rounding/clamp
viewportToBbox = translate(-bboxOriginPx.x, -bboxOriginPx.y)

pathToBbox = pathToViewport ∘ viewportToBbox

bboxToNDC = viewportRectToNDC(width: bboxW, height: bboxH)
pathToNDC = pathToBbox ∘ bboxToNDC
```

---

# PR-C1: Extraction + Unit Tests (No GPU rendering yet)

## Файлы

* `TVECore/Sources/TVECore/MetalRenderer/MaskTypes.swift` (new)
* `TVECore/Sources/TVECore/MetalRenderer/MaskBboxCompute.swift` (new)
* `TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift` (add extraction entry + internal funcs)
* `TVECore/Tests/TVECoreTests/MaskExtractionTests.swift` (new)

## 1) Типы

### 1.1 MaskOp

```swift
struct MaskOp: Sendable, Equatable {
    let mode: MaskMode
    let inverted: Bool
    let pathId: PathID
    let opacity: Double   // [0..1]
    let frame: Double
}
```

### 1.2 MaskGroupScope

> `endIndex` — **индекс следующей команды после scope**, чтобы execute-loop мог прыгать.

```swift
struct MaskGroupScope: Sendable {
    let opsInAeOrder: [MaskOp]        // apply in this order
    let innerCommands: [RenderCommand]
    let endIndex: Int                 // next index after last endMask
}
```

---

## 2) Extraction: extractMaskGroupScope (Canonical, fixed)

### Требования

* Начинается на `.beginMask` или `.beginMaskAdd`
* Собирает **префикс beginMask*** (обычно consecutive)
* Находит **первый endMask**, который закрывает content (граница inner range)
* Находит **полное закрытие depth** и ставит `endIndex`
* **Legacy beginMaskAdd** конвертируется в `MaskOp(add,false,...)`
* Возвращает `opsInAeOrder = ops.reversed()` (потому что emission reversed)

### Реализация (каноническая)

```swift
func extractMaskGroupScope(from commands: [RenderCommand], startIndex: Int) -> MaskGroupScope? {
    guard startIndex < commands.count else { return nil }

    var ops: [MaskOp] = []
    var index = startIndex

    // Phase 1: collect consecutive begins
    while index < commands.count {
        switch commands[index] {
        case .beginMask(let mode, let inverted, let pathId, let opacity, let frame):
            ops.append(MaskOp(mode: mode, inverted: inverted, pathId: pathId, opacity: opacity, frame: frame))
            index += 1
        case .beginMaskAdd(let pathId, let opacity, let frame):
            ops.append(MaskOp(mode: .add, inverted: false, pathId: pathId, opacity: opacity, frame: frame))
            index += 1
        default:
            break
        }
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
    var firstEndMaskIndex: Int? = nil

    // Phase 2: walk until all closes
    while index < commands.count && depth > 0 {
        switch commands[index] {
        case .beginMask, .beginMaskAdd:
            depth += 1               // defensive; shouldn’t happen in current emission
        case .endMask:
            if firstEndMaskIndex == nil { firstEndMaskIndex = index }
            depth -= 1
        default:
            break
        }
        index += 1
    }

    guard depth == 0, let innerEnd = firstEndMaskIndex else { return nil }

    let innerCommands = (innerEnd > innerStart) ? Array(commands[innerStart..<innerEnd]) : []
    let opsInAeOrder = Array(ops.reversed())

    return MaskGroupScope(opsInAeOrder: opsInAeOrder, innerCommands: innerCommands, endIndex: index)
}
```

---

## 3) initialAccumulatorValue (Canonical)

```swift
func initialAccumulatorValue(for opsInAeOrder: [MaskOp]) -> Float {
    guard let first = opsInAeOrder.first else { return 0 }
    switch first.mode {
    case .add: return 0
    case .subtract, .intersect: return 1
    }
}
```

---

## 4) BBox computation (triangulated vertices, rounding, clamp, scissor)

### 4.1 Контракт PathResource (для I5/I6)

**MUST**: bbox использует **triangulated mesh vertices** (те же, что пойдут в coverage draw).
Нужен API без аллокаций:

Вариант A (предпочтительно):

```swift
protocol TriangulatedPathSampling {
    /// Calls body with a view of triangle vertex positions (x,y pairs or SIMD2<Float>)
    func withTriangulatedPositions(at frame: Double, _ body: (UnsafeBufferPointer<SIMD2<Float>>) -> Void)
}
```

Вариант B (простое):

```swift
func sampleTriangulatedPositions(at frame: Double, into out: inout [SIMD2<Float>])
```

`out` — переиспользуемый scratch.

### 4.2 computeMaskGroupBboxFloat

* transform vertices through `pathToViewport`
* accumulate float bounds

### 4.3 roundClampIntersectBBoxToPixels (Canonical)

* `floor(minX/minY)`, `ceil(maxX/maxY)`
* expand AA = 2px
* clamp to target
* intersect currentScissor
* return integer bbox (x,y,w,h) + also float rect if нужно

---

## 5) PR-C1 Tests (unit)

Обязательные тесты:

1. `extractMaskGroupScope_singleMask`
2. `extractMaskGroupScope_nestedMasks_returnsAeOrder`
3. `extractMaskGroupScope_legacyBeginMaskAdd_convertsToAdd`
4. `extractMaskGroupScope_unmatchedEnd_returnsNil`
5. `extractMaskGroupScope_innerCommandsCorrectRange` (**важно**)
6. `initialAccumulatorValue_*`
7. `roundClampIntersectBBox_*` (floor/ceil + AA expand + clamp + scissor)

---

# PR-C2: GPU Renderer Path (Correctness First)

## Файлы

* `TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+MaskRender.swift` (new)
* `TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+MaskHelpers.swift` (new)
* **Переиспользовать** pipelines/kernels из PR-A:

  * `coveragePipelineState`
  * `maskCombineComputePipeline`
  * `maskedCompositePipelineState`

## 1) renderMaskGroupScope (Canonical Implementation)

### Требования

* bbox-sized textures:

  * `coverageTex` (R8)
  * `accumA` (R8)
  * `accumB` (R8)
  * `contentTex` (BGRA)
* clear accumulator & coverage через render pass clear
* combine compute kernel ping-pong
* content render: bbox local coords, bbox scissor
* composite: draw quad в target space, uv 0..1, bind mask+content

### Канонический псевдокод (точный)

```swift
func renderMaskGroupScope(_ scope: MaskGroupScope, ctx: RenderContext, state: inout ExecutionState) throws {
    // 1) bbox (float) from triangulated vertices in viewport pixels
    guard let bboxFloat = computeMaskGroupBboxFloat(ops: scope.opsInAeOrder, ...) else {
        // empty bbox => render inner without mask
        try executeCommands(scope.innerCommands, ctx: ctx, state: &state)
        return
    }

    // 2) integer bbox: floor/ceil + AA expand + clamp + intersect scissor
    guard let bboxPx = roundClampIntersectBBoxToPixels(bboxFloat, targetSize: ctx.target.sizePx, scissor: state.currentScissor, expandAA: 2),
          bboxPx.width > 0, bboxPx.height > 0 else {
        // fully clipped or degenerate
        return
    }

    let bboxSize = (bboxPx.width, bboxPx.height)
    let bboxScissor = MTLScissorRect(x: 0, y: 0, width: bboxSize.0, height: bboxSize.1)

    // 3) acquire textures
    guard let coverage = pool.acquireR8Texture(size: bboxSize),
          let accumA  = pool.acquireR8Texture(size: bboxSize),
          let accumB  = pool.acquireR8Texture(size: bboxSize),
          let content = pool.acquireColorTexture(size: bboxSize) else {
        // fallback
        try executeCommands(scope.innerCommands, ctx: ctx, state: &state)
        return
    }
    defer { pool.release(coverage); pool.release(accumA); pool.release(accumB); pool.release(content) }

    // 4) clear accumulator to initVal
    let initVal = initialAccumulatorValue(for: scope.opsInAeOrder)
    clearR8ViaRenderPass(accumA, value: initVal, commandBuffer: ctx.commandBuffer, scissor: bboxScissor)

    var accIn = accumA
    var accOut = accumB

    // 5) build transforms for coverage draw
    let pathToViewport = ctx.animToViewport.concatenating(state.currentTransform)
    let viewportToBbox = Matrix2D(translation: CGPoint(x: -bboxPx.x, y: -bboxPx.y))
    let pathToBbox = pathToViewport.concatenating(viewportToBbox)
    let bboxToNDC = Matrix2D.viewportRectToNDC(width: CGFloat(bboxSize.0), height: CGFloat(bboxSize.1))
    let pathToNDC = pathToBbox.concatenating(bboxToNDC)
    let mvp = pathToNDC.toSIMD4x4()

    // 6) accumulate mask ops in AE order
    for op in scope.opsInAeOrder {
        // 6.1 clear coverage to 0
        clearR8ViaRenderPass(coverage, value: 0, commandBuffer: ctx.commandBuffer, scissor: bboxScissor)

        // 6.2 draw triangulated path to coverage (no per-op index alloc)
        drawCoverage(pathId: op.pathId, frame: op.frame, into: coverage, mvp: mvp, scissor: bboxScissor, ...)

        // 6.3 combine (compute) ping-pong
        precondition(accIn !== accOut)
        dispatchMaskCombine(coverage: coverage, accumIn: accIn, accumOut: accOut,
                           mode: op.mode, inverted: op.inverted, opacity: Float(op.opacity),
                           commandBuffer: ctx.commandBuffer)

        swap(&accIn, &accOut)
    }

    let finalMask = accIn

    // 7) render inner content into bbox-sized color texture
    clearColorViaRenderPass(content, clear: .transparent, commandBuffer: ctx.commandBuffer, scissor: bboxScissor)

    var bboxCtx = ctx
    bboxCtx.target = .offscreen(texture: content, sizePx: bboxSize)
    bboxCtx.animToViewport = ctx.animToViewport.concatenating(viewportToBbox)

    var bboxState = state
    bboxState.currentScissor = bboxScissor

    try executeCommands(scope.innerCommands, ctx: bboxCtx, state: &bboxState)

    // 8) composite content × mask back to main target at bbox position
    drawMaskedCompositeQuad(content: content, mask: finalMask,
                            bboxPx: bboxPx,
                            target: ctx.target,
                            viewportToNDC: ctx.viewportToNDC,
                            parentScissor: state.currentScissor,
                            commandBuffer: ctx.commandBuffer)
}
```

---

## 2) Helper функции (Canonical)

### 2.1 clearR8ViaRenderPass (MUST)

```swift
func clearR8ViaRenderPass(_ tex: MTLTexture, value: Float, commandBuffer: MTLCommandBuffer, scissor: MTLScissorRect?) {
    let rp = MTLRenderPassDescriptor()
    rp.colorAttachments[0].texture = tex
    rp.colorAttachments[0].loadAction = .clear
    rp.colorAttachments[0].storeAction = .store
    let v = Double(value)
    rp.colorAttachments[0].clearColor = MTLClearColor(red: v, green: v, blue: v, alpha: v)

    guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else { return }
    if let sc = scissor { enc.setScissorRect(sc) }
    enc.endEncoding()
}
```

### 2.2 drawCoverage (layout MUST match PR-A)

* positions **float2** buffer at `buffer(0)`
* uniforms `CoverageUniforms` at `buffer(1)`
* blending disabled already в PR-A
* **indices buffer cached в PathResource** (см. PR-C3 perf, но лучше заложить в C2)

### 2.3 dispatchMaskCombine (ping-pong, UB safe)

* compute kernel из PR-A
* write: `float4(result,0,0,0)` (как в PR-A)

### 2.4 drawMaskedCompositeQuad

* pipeline из PR-A
* рисует quad в **viewport coords** bbox (x0,y0,x1,y1), преобразует в NDC через `viewportToNDC`
* `uv` 0..1
* fragment: `content * mask` (mask.r)
* scissor = parent scissor (не bboxScissor!)

---

## 3) Buffer strategy (I4/I5) — что сделать сразу в C2 vs C3

**C2 (correctness)** допускает простую реализацию, но без “alloc per-op index buffer”.
Минимум MUST в C2:

* index buffer хранится в `PathResource` один раз
* vertex upload: ring buffer / dynamic pool (может быть простым, но reuse)

**C3 (perf cleanup)**:

* убрать любые `[Float]` временные массивы
* single scratch per commandBuffer
* кэшировать pipeline-dependent buffers, если надо

---

# PR-C3: Feature Flag + Integration Tests + Perf cleanup

## 1) MaskBackend (stored in options, NOT env-only)

**File:** `MetalRenderer.swift`

```swift
public enum MaskBackend: Sendable {
    case cpuRasterStencil   // legacy
    case gpuTextureOps      // new
}

public struct MetalRendererOptions: Sendable {
    public var maskBackend: MaskBackend = .cpuRasterStencil // until parity proven
    public init(maskBackend: MaskBackend = .cpuRasterStencil) {
        self.maskBackend = maskBackend
    }
}
```

**DEBUG override** env можно добавить как override, но не единственный механизм.

---

## 2) Canonical execute-loop pseudocode (branch BEFORE extraction)

Это то, что нужно вставить в `executeCommands` (или эквивалент).

```swift
var i = 0
while i < commands.count {
    let cmd = commands[i]

    switch cmd {

    // --- Masks (DO NOT FALL THROUGH) ---
    case .beginMask, .beginMaskAdd:
        switch options.maskBackend {

        case .gpuTextureOps:
            guard let group = extractMaskGroupScope(from: commands, startIndex: i) else {
                throw MetalRendererError.invalidCommandStack(reason: "Malformed mask group at \(i)")
            }
            try renderMaskGroupScope(group, ctx: ctx, state: &state)
            i = group.endIndex
            continue

        case .cpuRasterStencil:
            guard let legacy = extractMaskScope(from: commands, startIndex: i) else {
                throw MetalRendererError.invalidCommandStack(reason: "Malformed legacy mask scope at \(i)")
            }
            try renderMaskScopeCPU(legacy, ctx: ctx, state: &state)   // existing path
            i = legacy.endIndex
            continue
        }

    // --- Matte (UNCHANGED) ---
    case .beginMatte:
        // existing matte extraction/render path
        // MUST remain byte-for-byte behaviorally same
        let matte = try extractMatteScope(...)
        try renderMatteScopeCPU(matte, ...)
        i = matte.endIndex
        continue

    // --- Other commands ---
    default:
        try executeCommand(cmd, ctx: ctx, state: &state)
        i += 1
    }
}
```

Ключевое:

* mask scope **не должен** попадать в `executeCommand` (кроме старого “depth accounting” — его можно убрать/оставить, но рендер должен быть тут).
* matte не трогаем.

---

## 3) Integration tests (GPU vs CPU parity)

**Стратегия**: сравнивать GPU output с CPU legacy на нескольких минимальных сценах.

### Набор кейсов (минимум)

1. single add mask
2. single subtract mask
3. single intersect mask
4. inverted add
5. opacity 0.5 add
6. chain add→subtract→intersect
7. mask внутри matte consumer (не ломает matte)

### Как сравнивать

* либо per-pixel probes (точки внутри/снаружи/на границе)
* либо image diff tolerance (например 1–2/255) + отдельные probes на края

---

## 4) Perf cleanup (PR-C3)

* indices buffer cached (если ещё не)
* vertex upload pool / ring buffer
* `sampleTriangulatedPositions(at:into:)` с reuse scratch
* bbox compute без аллокаций

---

# Checklist для ревью (полный)

## Correctness MUST

* [ ] Ping-pong accumulator (accIn !== accOut)
* [ ] Content renders into bbox-sized texture + bbox-local animToViewport
* [ ] Clear R8 via render pass clear
* [ ] compute bbox from triangulated vertices
* [ ] bbox rounding: floor/ceil + AA expand + clamp + scissor intersect
* [ ] Branch backend before extraction
* [ ] Matte behavior unchanged

## Extraction MUST

* [ ] innerCommands range корректен (до первого endMask)
* [ ] endIndex корректен (после последнего endMask)
* [ ] legacy beginMaskAdd конвертируется в MaskOp(add,false,...)
* [ ] opsInAeOrder правильный (reversed)

## Shader/layout MUST

* [ ] Coverage uniforms/layout совпадает с PR-A (`CoverageUniforms`)
* [ ] Positions memory layout = `float2`
* [ ] Combine kernel write = `float4(result,0,0,0)` (как в PR-A)

---

# Что отдаём разработчику как “точки входа”

1. PR-C1: Implement `MaskTypes.swift`, `MaskBboxCompute.swift`, `extractMaskGroupScope`, unit tests
2. PR-C2: Implement GPU path `renderMaskGroupScope` + helpers + use PR-A pipelines
3. PR-C3: Add `MaskBackend` option + execute-loop branching + integration tests + perf cleanup

---

Если хочешь — я могу сразу дописать **конкретные сигнатуры** для `PathResource / PathRegistry` (какие методы добавить/переименовать), чтобы разработчик не гадал, где брать triangulated vertices и index buffers. Это единственная часть, где обычно возникают “лишние вопросы”, потому что зависит от текущей модели PathResource в твоём репо.

-----

Отлично — тогда фиксируем **конкретные сигнатуры и место хранения GPU-кэша** так, чтобы дальше не было разночтений. Ниже даю **рекомендуемый “канонический” контракт** для `PathResource`/`PathRegistry`, который:

* **не ломает** текущую модель (`keyframePositions: [[Float]]`, `indices: [UInt16]`, `vertexCount`)
* позволяет **bbox** и **coverage draw** делать **без аллокаций**
* даёт опцию **кэшировать index MTLBuffer** либо *в resource*, либо *в отдельном GPU cache* (я приведу оба, но выберу канон)

---

# 1) Канонические сигнатуры для PathResource

## 1.1 Безаллок интерфейс для вершин: `withTriangulatedPositions(at:_: )`

**Почему это лучше, чем `into: inout [Float]`:**

* ноль аллокаций в hot path
* можно вернуть **указатель на internal storage** для static keyframe
* для animated — можно использовать **thread-local / renderer scratch** (внутренний буфер), но наружу всё равно отдаём `UnsafeBufferPointer<Float>`

### Предлагаемая сигнатура (каноническая)

```swift
public struct PathResource: Sendable {
    public let keyframePositions: [[Float]]  // flattened x,y...
    public let indices: [UInt16]
    public let vertexCount: Int

    /// Calls body with flattened (x,y,x,y,...) positions for a given frame.
    /// MUST NOT allocate in steady state (uses scratch for interpolated frames).
    public func withTriangulatedPositions(
        at frame: Double,
        _ body: (UnsafeBufferPointer<Float>) -> Void
    )
}
```

### Каноническая семантика

* Если `keyframePositions.count == 1`: отдаём указатель на `keyframePositions[0]`
* Если animated:

  * выбираем two keyframes (k0/k1) и `t` (0..1)
  * интерполируем **в preallocated scratch** (см. ниже “где хранить scratch”)
  * отдаём указатель на scratch

> Важно: bbox/coverage используют **triangulated vertices**, а у тебя это уже `keyframePositions`. Отлично.

---

## 1.2 Если хочешь проще: `sampleTriangulatedPositions(at:into:)`

Это проще реализовать без “lifetime” сложностей `UnsafeBufferPointer`, но требует от caller держать `scratch`.

```swift
public func sampleTriangulatedPositions(at frame: Double, into out: inout [Float])
```

**Правило:** `out` переиспользуется. Функция делает `out.reserveCapacity(vertexCount*2)` один раз и дальше только перезаписывает.

---

## 1.3 Интерполяция без аллокаций: где хранить scratch

Канонично — **в MetalRenderer (per-frame/per-commandBuffer scratch)**, НЕ внутри PathResource (чтобы PathResource оставался value-ish и Sendable).

### Вариант (рекомендованный)

В `MetalRenderer`:

```swift
final class MetalRenderer {
    // reused per commandBuffer / per render call
    var pathPositionsScratch: [Float] = []
}
```

Тогда `PathResource.withTriangulatedPositions` принимает *optional* scratch:

```swift
public func withTriangulatedPositions(
    at frame: Double,
    scratch: inout [Float],
    _ body: (UnsafeBufferPointer<Float>) -> Void
)
```

Но это меняет сигнатуру. Если хочешь **минимально инвазивно** — делай `sampleTriangulatedPositions(at:into:)` и всё.

✅ **Мой выбор (канон для твоего кода сейчас):**

> `sampleTriangulatedPositions(at:into:)` — проще интегрировать в текущую архитектуру и PR-C1/C2.

---

# 2) Индексы: где хранить cached MTLBuffer

Тут два рабочих паттерна. Я дам оба и выберу канон.

## Вариант A (канонический): GPU cache в MetalRenderer (рекомендуется)

**Почему:**

* `PathResource` остаётся чисто “данные”
* GPU-ресурсы привязаны к `MTLDevice`
* проще освобождение/инвалидация

### Новый тип

```swift
final class PathGPUCache {
    private var indexBuffers: [PathID: MTLBuffer] = [:]

    func indexBuffer(for pathId: PathID, resource: PathResource, device: MTLDevice) -> MTLBuffer? {
        if let buf = indexBuffers[pathId] { return buf }
        let byteCount = resource.indices.count * MemoryLayout<UInt16>.stride
        guard let buf = device.makeBuffer(bytes: resource.indices, length: byteCount, options: .storageModeShared) else {
            return nil
        }
        indexBuffers[pathId] = buf
        return buf
    }
}
```

В `MetalRenderer`:

```swift
final class MetalRenderer {
    let pathGPUCache = PathGPUCache()
}
```

В `drawCoverage`:

* достаёшь `PathResource` из `PathRegistry`
* берёшь `indexBuffer = pathGPUCache.indexBuffer(for: pathId, resource: resource, device: device)`
* vertex buffer — через dynamic upload pool

✅ Это идеально ложится в PR-C2, а PR-C1 не трогает.

---

## Вариант B: cached MTLBuffer внутри PathResource (не рекомендую)

Минусы:

* `PathResource` перестаёт быть чистым, появляется `MTLDevice`-specific state
* Sendable/потокобезопасность хуже
* сложнее жить с несколькими девайсами/рендерами

Если всё же надо:

```swift
public final class PathResource {
    public let indices: [UInt16]
    public private(set) var indicesMTLBuffer: MTLBuffer?

    public func ensureIndexBuffer(device: MTLDevice) -> MTLBuffer? { ... }
}
```

**Я бы НЕ выбирал.**

---

# 3) Где это использовать в PR-C

## PR-C1 (extraction + bbox)

Тебе достаточно:

* `extractMaskGroupScope`
* bbox compute на `keyframePositions` (static/animated) **без GPU**

### BBox: что читать

* для bbox **нужны позиции на конкретный frame**.
* значит нужен хотя бы:

  * `sampleTriangulatedPositions(at:into:)` **или**
  * простая функция интерполяции внутри bbox compute (используя `keyframePositions`)

✅ Поэтому да: **PR-C1 можно начать без GPU cache**.

---

## PR-C2 (GPU renderer)

Тут потребуются:

* indices MTLBuffer cache (PathGPUCache)
* vertex upload pool
* `sampleTriangulatedPositions(at:into:)` (или with-pointer)

---

# 4) Рекомендуемый минимальный патч к PathResource (канон)

Самый практичный, “вписывается” без рефакторинга:

```swift
extension PathResource {

    /// Writes flattened triangulated positions (x,y,x,y...) into `out`.
    /// Caller MUST reuse `out` to avoid allocations.
    func sampleTriangulatedPositions(at frame: Double, into out: inout [Float]) {
        // 1) static
        if keyframePositions.count == 1 {
            out = keyframePositions[0]   // NOTE: this copies; to avoid copy:
                                        // use out.removeAll(keepingCapacity: true); out.append(contentsOf:)
            return
        }

        // 2) animated (pseudo)
        // Find k0,k1,t based on frame -> your existing interpolation logic
        // Ensure out capacity = vertexCount*2
        out.removeAll(keepingCapacity: true)
        out.reserveCapacity(vertexCount * 2)

        // Interpolate each float:
        // out[i] = lerp(k0[i], k1[i], t)
    }
}
```

⚠️ Но тут есть нюанс: `out = keyframePositions[0]` **скопирует** массив. Чтобы реально было “без аллокаций”, нужно:

```swift
out.removeAll(keepingCapacity: true)
out.append(contentsOf: keyframePositions[0])
```

А ещё лучше — в static case вообще не копировать, а дать `UnsafeBufferPointer`. Поэтому:

✅ **Компромиссный канон: две функции**

* `withTriangulatedPositionsStaticOrInterpolated(...)` (pointer, no copy)
* `sampleTriangulatedPositions(... into:)` (fallback)

Если хочешь строго “no copy” — скажи, и я дам окончательную реализацию именно с pointer + scratch.

---

# 5) Финальная рекомендация (что фиксируем в проекте)

**Фиксируем как “single source of truth” для PR-C:**

1. `PathResource` добавляет:

* `func sampleTriangulatedPositions(at frame: Double, into out: inout [Float])`

  * MUST reuse `out` (no steady-state allocations)

2. `MetalRenderer` добавляет:

* `pathPositionsScratch: [Float]` (reused)
* `pathGPUCache: PathGPUCache` (indices → MTLBuffer)

3. `drawCoverage` в PR-C2:

* positions → `sampleTriangulatedPositions(... into: &scratch)` → upload vertex buffer
* indices → `pathGPUCache.indexBuffer(...)`

---

Если ты ок с этим контрактом, разработчик реально сможет стартовать **с PR-C1 прямо сейчас**, а для PR-C2 будет уже ясная “точка вставки” для GPU-буферов без сюрпризов.
