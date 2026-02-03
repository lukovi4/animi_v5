# Fix: mediaInputPath / mediaInputWorldMatrix — groupTransforms + precomp chain

## Две независимые проблемы

### Проблема 1: groupTransforms не применялись

`computeMediaInputWorld` (рендер/clip) учитывал `shapeGroup.groupTransforms`,
а `mediaInputPath` (hit-test/overlay) и `mediaInputWorldMatrix` (public API) — нет.
Дополнительно `mediaInputPath` имел early return на `worldMatrix == .identity`,
который пропускал groupTransforms даже когда они не identity.

### Проблема 2: precomp container chain transform не учитывался

Когда mediaInput находится внутри precomp, `mediaInputPath` вычисляет world-матрицу
**только внутри этой comp** (`baseWorldMatrix: .identity`). Transform-цепочка
precomp-контейнеров от root-композиции до `inputGeo.compId` полностью игнорируется.

В рендер-пайплайне это не проявляется — `renderComposition` рекурсивно пушит
precomp-контейнер transform на стек до входа в precomp. Но `mediaInputPath` вызывается
напрямую, минуя render traversal.

Результат: все блоки получали mediaInput path в precomp-local координатах,
а `blockTransform = .identity` (потому что anim 1080×1920 = canvas 1080×1920)
не компенсировал отсутствующий precomp chain.

## Решение

Архитектура из двух уровней:

- **InComp helper** (`computeMediaInputComposedMatrix`) — worldTransform внутри comp + groupTransforms.
  Принимает `baseWorldMatrix` параметр.
- **ForRootSpace helper** (`computeMediaInputComposedMatrixForRootSpace`) — resolve precomp chain → delegate to InComp.
- **`resolvePrecompChainTransform`** — рекурсивно обходит цепочку precomp-контейнеров от root до target comp.

Использование:
- `computeMediaInputWorld` (render) → InComp с `.identity` (precomp chain уже на стеке) ✅
- `mediaInputPath` (hit-test/overlay) → ForRootSpace ✅
- `mediaInputWorldMatrix` (public API) → ForRootSpace ✅

---

## Файл 1: `Sources/TVECore/AnimIR/AnimIR.swift`

### 1a. Новый: `resolvePrecompChainTransform` + `computeMediaInputComposedMatrix` (InComp) + `computeMediaInputComposedMatrixForRootSpace` + рефакторинг `computeMediaInputWorld`

**БЫЛО:**

```swift
/// Computes the world matrix for the mediaInput layer at the current frame.
/// mediaInput world is fixed (no userTransform) — it defines the clip window.
private mutating func computeMediaInputWorld(
    inputGeo: InputGeometryInfo,
    context: RenderContext
) -> Matrix2D {
    // Find the mediaInput layer in its composition
    guard let comp = comps[inputGeo.compId],
          let inputLayer = comp.layers.first(where: { $0.id == inputGeo.layerId }) else {
        return .identity
    }

    // Build a temporary layerById for the composition
    let layerById = Dictionary(uniqueKeysWithValues: comp.layers.map { ($0.id, $0) })

    // Compute world transform without userTransform
    guard let (matrix, _) = computeWorldTransform(
        for: inputLayer,
        at: context.frame,
        baseWorldMatrix: .identity,
        baseWorldOpacity: 1.0,
        layerById: layerById,
        sceneFrameIndex: context.frameIndex
    ) else {
        return .identity
    }

    // PR-23: Apply shape groupTransforms for mediaInput geometry (PR-11 contract).
    // Paths are stored in LOCAL coords; group transforms must be applied at render time.
    // This matches the pattern in renderLayerContent for regular shape layers.
    switch inputLayer.content {
    case .shapes(let shapeGroup):
        var composed = matrix
        for gt in shapeGroup.groupTransforms {
            composed = composed.concatenating(gt.matrix(at: context.frame))
        }
        return composed
    default:
        return matrix
    }
}
```

**СТАЛО:**

```swift
// MARK: - MediaInput Transform Helpers

/// Resolves the accumulated transform of precomp containers from root to `targetCompId`.
///
/// During render traversal the engine pushes container transforms onto the stack
/// automatically.  For direct queries (hit-test, overlay, public API) we must
/// resolve this chain explicitly.
///
/// - Returns: Accumulated matrix (root → target), `.identity` when target is root,
///   or `nil` on parent-chain error.
private mutating func resolvePrecompChainTransform(
    targetCompId: CompID,
    frame: Double,
    sceneFrameIndex: Int
) -> Matrix2D? {
    if targetCompId == AnimIR.rootCompId { return .identity }

    // Find the precomp container layer that references targetCompId
    for (compId, comp) in comps {
        for layer in comp.layers {
            guard case .precomp(let refCompId) = layer.content,
                  refCompId == targetCompId else { continue }

            // World transform of the container layer within its own comp
            let layerById = Dictionary(uniqueKeysWithValues: comp.layers.map { ($0.id, $0) })
            guard let (containerWorld, _) = computeWorldTransform(
                for: layer,
                at: frame,
                baseWorldMatrix: .identity,
                baseWorldOpacity: 1.0,
                layerById: layerById,
                sceneFrameIndex: sceneFrameIndex
            ) else {
                return nil
            }

            // Recurse: the comp holding this container may itself be a precomp
            guard let parentChain = resolvePrecompChainTransform(
                targetCompId: compId,
                frame: frame,
                sceneFrameIndex: sceneFrameIndex
            ) else {
                return nil
            }

            return parentChain.concatenating(containerWorld)
        }
    }

    // Not found as a precomp target — treat as root-level
    return .identity
}

/// Composed matrix for the mediaInput layer **within its composition** (InComp).
///
/// worldTransform (incl. parent chain) + groupTransforms.
/// `baseWorldMatrix` allows the caller to inject outer context:
///   - `.identity` for render pipeline (precomp chain already on stack)
///   - precomp chain transform for hit-test / overlay / public API
private mutating func computeMediaInputComposedMatrix(
    inputGeo: InputGeometryInfo,
    frame: Double,
    sceneFrameIndex: Int,
    baseWorldMatrix: Matrix2D = .identity
) -> Matrix2D? {
    guard let comp = comps[inputGeo.compId],
          let inputLayer = comp.layers.first(where: { $0.id == inputGeo.layerId }) else {
        return nil
    }

    let layerById = Dictionary(uniqueKeysWithValues: comp.layers.map { ($0.id, $0) })

    guard let (worldMatrix, _) = computeWorldTransform(
        for: inputLayer,
        at: frame,
        baseWorldMatrix: baseWorldMatrix,
        baseWorldOpacity: 1.0,
        layerById: layerById,
        sceneFrameIndex: sceneFrameIndex
    ) else {
        return nil
    }

    // Apply shape groupTransforms (PR-11 contract).
    // Paths are stored in LOCAL coords; group transforms are composed at sample time.
    switch inputLayer.content {
    case .shapes(let shapeGroup):
        var composed = worldMatrix
        for gt in shapeGroup.groupTransforms {
            composed = composed.concatenating(gt.matrix(at: frame))
        }
        return composed
    default:
        return worldMatrix
    }
}

/// Full composed matrix for mediaInput in **root composition space**.
///
/// Resolves the precomp container chain, then delegates to the InComp helper.
/// Used by `mediaInputPath` and `mediaInputWorldMatrix` (direct queries).
private mutating func computeMediaInputComposedMatrixForRootSpace(
    inputGeo: InputGeometryInfo,
    frame: Double,
    sceneFrameIndex: Int
) -> Matrix2D? {
    guard let baseWorld = resolvePrecompChainTransform(
        targetCompId: inputGeo.compId,
        frame: frame,
        sceneFrameIndex: sceneFrameIndex
    ) else {
        return nil
    }

    return computeMediaInputComposedMatrix(
        inputGeo: inputGeo,
        frame: frame,
        sceneFrameIndex: sceneFrameIndex,
        baseWorldMatrix: baseWorld
    )
}

/// Computes the world matrix for the mediaInput layer at the current frame.
/// mediaInput world is fixed (no userTransform) — it defines the clip window.
/// Uses InComp helper (precomp chain is already on the render stack).
private mutating func computeMediaInputWorld(
    inputGeo: InputGeometryInfo,
    context: RenderContext
) -> Matrix2D {
    computeMediaInputComposedMatrix(
        inputGeo: inputGeo,
        frame: context.frame,
        sceneFrameIndex: context.frameIndex
    ) ?? .identity
}
```

---

### 1b. Фикс `mediaInputPath` — ForRootSpace + убран early return

**БЫЛО:**

```swift
public mutating func mediaInputPath(frame: Int = 0) -> BezierPath? {
    guard let inputGeo = inputGeometry else { return nil }

    // Get the static path from animPath
    guard let basePath = inputGeo.animPath.staticPath else { return nil }

    // Find the mediaInput layer and compute its world transform
    guard let comp = comps[inputGeo.compId],
          let inputLayer = comp.layers.first(where: { $0.id == inputGeo.layerId }) else {
        return basePath
    }

    let layerById = Dictionary(uniqueKeysWithValues: comp.layers.map { ($0.id, $0) })

    guard let (worldMatrix, _) = computeWorldTransform(
        for: inputLayer,
        at: Double(frame),
        baseWorldMatrix: .identity,
        baseWorldOpacity: 1.0,
        layerById: layerById,
        sceneFrameIndex: frame
    ) else {
        return basePath
    }

    // If world matrix is identity, return base path as-is
    if worldMatrix == .identity {
        return basePath
    }

    // Transform all path components by the world matrix
    let transformedVertices = basePath.vertices.map { worldMatrix.apply(to: $0) }
    let transformedIn = basePath.inTangents.map { worldMatrix.apply(to: $0) }
    let transformedOut = basePath.outTangents.map { worldMatrix.apply(to: $0) }

    return BezierPath(
        vertices: transformedVertices,
        inTangents: transformedIn,
        outTangents: transformedOut,
        closed: basePath.closed
    )
}
```

**СТАЛО:**

```swift
/// Returns the mediaInput path in **root composition space** for hit-testing / overlay.
///
/// The path is transformed by the full chain: precomp containers → layer world →
/// groupTransforms.  This matches the geometry the render pipeline produces.
///
/// - Parameter frame: Frame to sample the path at (default: 0 for static mediaInput)
/// - Returns: BezierPath in root composition space, or nil if no mediaInput
public mutating func mediaInputPath(frame: Int = 0) -> BezierPath? {
    guard let inputGeo = inputGeometry else { return nil }
    guard let basePath = inputGeo.animPath.staticPath else { return nil }

    guard let composedMatrix = computeMediaInputComposedMatrixForRootSpace(
        inputGeo: inputGeo,
        frame: Double(frame),
        sceneFrameIndex: frame
    ) else {
        return basePath
    }

    // Transform all path components by the composed matrix
    // (no early return for identity — correctness over micro-optimization)
    let transformedVertices = basePath.vertices.map { composedMatrix.apply(to: $0) }
    let transformedIn = basePath.inTangents.map { composedMatrix.apply(to: $0) }
    let transformedOut = basePath.outTangents.map { composedMatrix.apply(to: $0) }

    return BezierPath(
        vertices: transformedVertices,
        inTangents: transformedIn,
        outTangents: transformedOut,
        closed: basePath.closed
    )
}
```

---

### 1c. Фикс `mediaInputWorldMatrix` — ForRootSpace

**БЫЛО:**

```swift
public mutating func mediaInputWorldMatrix(frame: Int = 0) -> Matrix2D? {
    guard let inputGeo = inputGeometry else { return nil }

    guard let comp = comps[inputGeo.compId],
          let inputLayer = comp.layers.first(where: { $0.id == inputGeo.layerId }) else {
        return nil
    }

    let layerById = Dictionary(uniqueKeysWithValues: comp.layers.map { ($0.id, $0) })

    guard let (worldMatrix, _) = computeWorldTransform(
        for: inputLayer,
        at: Double(frame),
        baseWorldMatrix: .identity,
        baseWorldOpacity: 1.0,
        layerById: layerById,
        sceneFrameIndex: frame
    ) else {
        return nil
    }

    return worldMatrix
}
```

**СТАЛО:**

```swift
/// Returns the composed world matrix of the mediaInput layer in **root composition space**.
///
/// Includes precomp container chain + layer world + groupTransforms.
///
/// - Parameter frame: Frame to compute transform at (default: 0)
/// - Returns: Composed matrix in root space, or nil if no mediaInput
public mutating func mediaInputWorldMatrix(frame: Int = 0) -> Matrix2D? {
    guard let inputGeo = inputGeometry else { return nil }

    return computeMediaInputComposedMatrixForRootSpace(
        inputGeo: inputGeo,
        frame: Double(frame),
        sceneFrameIndex: frame
    )
}
```

---

## Файл 2: `Tests/TVECoreTests/MediaInputTests.swift`

### 3 новых теста

Все добавлены после `testMediaInputPath_noMediaInput_returnsNil`.

#### 2a. `testMediaInputPath_appliesGroupTransforms`

Регрессия на баг с early return: identity worldMatrix + non-identity groupTransform T(100, 200).

```swift
func testMediaInputPath_appliesGroupTransforms() throws {
    // Given: mediaInput layer with identity layer transform BUT non-identity groupTransform.
    // The old code had an early return on `worldMatrix == .identity` that would skip
    // groupTransforms entirely — this test guards against that regression.
    let groupTransformJSON = """
    , { "ty": "tr",
        "p": { "a": 0, "k": [100, 200] },
        "a": { "a": 0, "k": [0, 0] },
        "s": { "a": 0, "k": [100, 100] },
        "r": { "a": 0, "k": 0 },
        "o": { "a": 0, "k": 100 } }
    """
    let json = lottieWithMediaInput(
        mediaInputLayer: mediaInputLayerJSON(extraShapes: groupTransformJSON),
        mediaInRoot: true
    )
    let lottie = try decodeLottie(json)
    let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])

    var ir = try compiler.compile(
        lottie: lottie, animRef: "test", bindingKey: "media", assetIndex: assetIndex
    )
    let path = ir.mediaInputPath(frame: 0)

    // basePath [[0,0],[100,0],[100,100],[0,100]] → shifted by (100, 200)
    XCTAssertNotNil(path)
    let verts = path!.vertices
    XCTAssertEqual(verts.count, 4)
    XCTAssertEqual(verts[0].x, 100, accuracy: 0.01)
    XCTAssertEqual(verts[0].y, 200, accuracy: 0.01)
    XCTAssertEqual(verts[1].x, 200, accuracy: 0.01)
    XCTAssertEqual(verts[1].y, 200, accuracy: 0.01)
    XCTAssertEqual(verts[2].x, 200, accuracy: 0.01)
    XCTAssertEqual(verts[2].y, 300, accuracy: 0.01)
    XCTAssertEqual(verts[3].x, 100, accuracy: 0.01)
    XCTAssertEqual(verts[3].y, 300, accuracy: 0.01)

    let matrix = ir.mediaInputWorldMatrix(frame: 0)
    XCTAssertNotNil(matrix)
    XCTAssertNotEqual(matrix, .identity,
        "Composed matrix must include groupTransform even when layer transform is identity")
}
```

#### 2b. `testMediaInputPath_accountsForPrecompContainerTransform`

Precomp container с T(540, 0). MediaInput в precomp с identity transform.

```swift
func testMediaInputPath_accountsForPrecompContainerTransform() throws {
    // Given: mediaInput inside a precomp; precomp container translates by (540, 0).
    // mediaInputPath must include the precomp chain transform so the path
    // ends up in root composition space, not precomp-local space.
    let json = """
    {
      "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
      "assets": [
        { "id": "image_0", "w": 540, "h": 960, "u": "images/", "p": "img.png", "e": 0 },
        {
          "id": "comp_0", "nm": "precomp", "fr": 30,
          "layers": [
            {
              "ty": 4, "ind": 1, "nm": "mediaInput", "hd": true,
              "shapes": [
                { "ty": "gr", "it": [
                  { "ty": "sh", "ks": { "a": 0, "k": {
                    "v": [[0,0],[100,0],[100,100],[0,100]],
                    "i": [[0,0],[0,0],[0,0],[0,0]],
                    "o": [[0,0],[0,0],[0,0],[0,0]],
                    "c": true
                  }}},
                  { "ty": "fl", "c": { "a": 0, "k": [0,0,0,1] }, "o": { "a": 0, "k": 100 } }
                ]}
              ],
              "ks": {
                "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
                "p": { "a": 0, "k": [0,0,0] }, "a": { "a": 0, "k": [0,0,0] },
                "s": { "a": 0, "k": [100,100,100] }
              },
              "ip": 0, "op": 300, "st": 0
            },
            {
              "ty": 2, "ind": 2, "nm": "media", "refId": "image_0",
              "ks": {
                "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
                "p": { "a": 0, "k": [270,480,0] }, "a": { "a": 0, "k": [270,480,0] },
                "s": { "a": 0, "k": [100,100,100] }
              },
              "ip": 0, "op": 300, "st": 0
            }
          ]
        }
      ],
      "layers": [
        {
          "ty": 0, "ind": 1, "nm": "precomp_layer", "refId": "comp_0",
          "ks": {
            "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
            "p": { "a": 0, "k": [540, 0, 0] },
            "a": { "a": 0, "k": [0, 0, 0] },
            "s": { "a": 0, "k": [100, 100, 100] }
          },
          "w": 1080, "h": 1920,
          "ip": 0, "op": 300, "st": 0
        }
      ]
    }
    """
    let lottie = try decodeLottie(json)
    let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])

    var ir = try compiler.compile(
        lottie: lottie, animRef: "test", bindingKey: "media", assetIndex: assetIndex
    )
    let path = ir.mediaInputPath(frame: 0)

    // precomp container T(540, 0) + identity layer + identity groupTransform
    // basePath [[0,0],[100,0],[100,100],[0,100]] → shifted by (540, 0)
    XCTAssertNotNil(path)
    let verts = path!.vertices
    XCTAssertEqual(verts.count, 4)
    XCTAssertEqual(verts[0].x, 540, accuracy: 0.01)
    XCTAssertEqual(verts[0].y, 0, accuracy: 0.01)
    XCTAssertEqual(verts[1].x, 640, accuracy: 0.01)
    XCTAssertEqual(verts[1].y, 0, accuracy: 0.01)
    XCTAssertEqual(verts[2].x, 640, accuracy: 0.01)
    XCTAssertEqual(verts[2].y, 100, accuracy: 0.01)
    XCTAssertEqual(verts[3].x, 540, accuracy: 0.01)
    XCTAssertEqual(verts[3].y, 100, accuracy: 0.01)

    let matrix = ir.mediaInputWorldMatrix(frame: 0)
    XCTAssertNotNil(matrix)
    XCTAssertNotEqual(matrix, .identity,
        "Composed matrix must include precomp container transform")
}
```

#### 2c. `testMediaInputPath_precompChainPlusGroupTransforms`

Precomp container T(540, 0) + groupTransform T(50, 100) → composed T(590, 100).

```swift
func testMediaInputPath_precompChainPlusGroupTransforms() throws {
    // Given: precomp container T(540, 0) + groupTransform T(50, 100).
    // Both must be included: composed = T(540,0) * T(50,100) = T(590, 100).
    let json = """
    {
      "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
      "assets": [
        { "id": "image_0", "w": 540, "h": 960, "u": "images/", "p": "img.png", "e": 0 },
        {
          "id": "comp_0", "nm": "precomp", "fr": 30,
          "layers": [
            {
              "ty": 4, "ind": 1, "nm": "mediaInput", "hd": true,
              "shapes": [
                { "ty": "gr", "it": [
                  { "ty": "sh", "ks": { "a": 0, "k": {
                    "v": [[0,0],[100,0],[100,100],[0,100]],
                    "i": [[0,0],[0,0],[0,0],[0,0]],
                    "o": [[0,0],[0,0],[0,0],[0,0]],
                    "c": true
                  }}},
                  { "ty": "fl", "c": { "a": 0, "k": [0,0,0,1] }, "o": { "a": 0, "k": 100 } },
                  { "ty": "tr",
                    "p": { "a": 0, "k": [50, 100] },
                    "a": { "a": 0, "k": [0, 0] },
                    "s": { "a": 0, "k": [100, 100] },
                    "r": { "a": 0, "k": 0 },
                    "o": { "a": 0, "k": 100 } }
                ]}
              ],
              "ks": {
                "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
                "p": { "a": 0, "k": [0,0,0] }, "a": { "a": 0, "k": [0,0,0] },
                "s": { "a": 0, "k": [100,100,100] }
              },
              "ip": 0, "op": 300, "st": 0
            },
            {
              "ty": 2, "ind": 2, "nm": "media", "refId": "image_0",
              "ks": {
                "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
                "p": { "a": 0, "k": [270,480,0] }, "a": { "a": 0, "k": [270,480,0] },
                "s": { "a": 0, "k": [100,100,100] }
              },
              "ip": 0, "op": 300, "st": 0
            }
          ]
        }
      ],
      "layers": [
        {
          "ty": 0, "ind": 1, "nm": "precomp_layer", "refId": "comp_0",
          "ks": {
            "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
            "p": { "a": 0, "k": [540, 0, 0] },
            "a": { "a": 0, "k": [0, 0, 0] },
            "s": { "a": 0, "k": [100, 100, 100] }
          },
          "w": 1080, "h": 1920,
          "ip": 0, "op": 300, "st": 0
        }
      ]
    }
    """
    let lottie = try decodeLottie(json)
    let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])

    var ir = try compiler.compile(
        lottie: lottie, animRef: "test", bindingKey: "media", assetIndex: assetIndex
    )
    let path = ir.mediaInputPath(frame: 0)

    // T(540,0) from precomp chain + T(50,100) from groupTransform = T(590,100)
    // basePath [[0,0],[100,0],[100,100],[0,100]] → shifted by (590, 100)
    XCTAssertNotNil(path)
    let verts = path!.vertices
    XCTAssertEqual(verts.count, 4)
    XCTAssertEqual(verts[0].x, 590, accuracy: 0.01)
    XCTAssertEqual(verts[0].y, 100, accuracy: 0.01)
    XCTAssertEqual(verts[1].x, 690, accuracy: 0.01)
    XCTAssertEqual(verts[1].y, 100, accuracy: 0.01)
    XCTAssertEqual(verts[2].x, 690, accuracy: 0.01)
    XCTAssertEqual(verts[2].y, 200, accuracy: 0.01)
    XCTAssertEqual(verts[3].x, 590, accuracy: 0.01)
    XCTAssertEqual(verts[3].y, 200, accuracy: 0.01)
}
```

---

## Тесты

**753 tests, 0 failures, 5 skipped** (было 750 — добавилось 3 новых).
