# PR-28: Shared Assets + No Placeholder Binding — Diff Document

## Summary

PR-28 introduces three capabilities:
1. **Shared Assets resolution** — App Bundle images (`SharedAssets/`) used across templates
2. **Resolver-based texture loading** — basename key lookup via Local → Shared pipeline
3. **No-Placeholder Binding** — binding layer hides when user media is absent (no dummy image needed)

Test suite: **809 tests, 0 failures** (776 existing + 21 SharedAssetsResolverTests + 12 NoPlaceholderBindingTests).

---

## New Files (4 production + 2 test)

### `Assets/AssetResolutionError.swift` (NEW)
```swift
public enum AssetResolutionStage: String, Sendable { case local, shared }

public enum AssetResolutionError: Error, Sendable {
    case assetNotFound(key: String, stage: AssetResolutionStage)
    case duplicateBasenameLocal(key: String, url1: URL, url2: URL)
    case duplicateBasenameShared(key: String, url1: URL, url2: URL)
}
```

### `Assets/SharedAssetsIndex.swift` (NEW)
```swift
public struct SharedAssetsIndex: Sendable {
    static let allowedExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]
    private let index: [String: URL]        // basename → file URL
    public init(rootURL: URL?, fileManager: FileManager = .default) throws
    public init(bundle: Bundle, rootFolderName: String = "SharedAssets") throws
    public static let empty = ...
    public func url(forKey key: String) -> URL?
    public var count: Int
    public var keys: Set<String>
}
```

### `Assets/LocalAssetsIndex.swift` (NEW)
```swift
public struct LocalAssetsIndex: Sendable {
    static let allowedExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]
    private let index: [String: URL]        // basename → file URL
    public init(imagesRootURL: URL?, fileManager: FileManager = .default) throws
    public static let empty = ...
    public func url(forKey key: String) -> URL?
    public var count: Int
    public var keys: Set<String>
}
```

### `Assets/CompositeAssetResolver.swift` (NEW)
```swift
public struct CompositeAssetResolver: Sendable {
    public init(localIndex: LocalAssetsIndex, sharedIndex: SharedAssetsIndex)
    public func resolveURL(forKey key: String) throws -> URL     // Local → Shared → throw
    public func canResolve(key: String) -> Bool
    public func resolvedStage(forKey key: String) -> AssetResolutionStage?
}
```

### `Tests/SharedAssetsResolverTests.swift` (NEW) — 21 tests
### `Tests/NoPlaceholderBindingTests.swift` (NEW) — 12 tests

---

## Modified Files

### 1. `AnimIR/AnimIRTypes.swift` — AssetIndexIR

**Was:**
```swift
public struct AssetIndexIR: Sendable, Equatable {
    public let byId: [String: String]
    public let sizeById: [String: AssetSize]
    public init(byId: [String: String] = [:], sizeById: [String: AssetSize] = [:])
}
```

**Now:**
```swift
public struct AssetIndexIR: Sendable, Equatable {
    public let byId: [String: String]
    public let sizeById: [String: AssetSize]
    public let basenameById: [String: String]   // PR-28: assetId → basename(filename)
    public init(
        byId: [String: String] = [:],
        sizeById: [String: AssetSize] = [:],
        basenameById: [String: String] = [:]
    )
}
```

---

### 2. `AnimIR/AnimIRCompiler.swift` — Basename extraction

**Was:**
```swift
var namespacedById: [String: String] = [:]
var namespacedSizeById: [String: AssetSize] = [:]

// ... only iterated for sizes ...

let assetsIR = AssetIndexIR(byId: namespacedById, sizeById: namespacedSizeById)
```

**Now:**
```swift
var namespacedById: [String: String] = [:]
var namespacedSizeById: [String: AssetSize] = [:]
var namespacedBasenameById: [String: String] = [:]   // PR-28

for asset in lottie.assets where asset.isImage {
    // ... existing size extraction ...

    // PR-28: Extract basename from Lottie filename (p) for resolver-based resolution
    if let filename = asset.filename, !filename.isEmpty {
        let basename = (filename as NSString).deletingPathExtension
        if !basename.isEmpty {
            namespacedBasenameById[nsId] = basename
        }
    }
}

let assetsIR = AssetIndexIR(
    byId: namespacedById,
    sizeById: namespacedSizeById,
    basenameById: namespacedBasenameById       // PR-28
)
```

---

### 3. `AnimIR/AnimIR.swift` — bindingLayerVisible

**Was (RenderContext):**
```swift
private struct RenderContext {
    let frame: Double
    let frameIndex: Int
    // ... existing fields ...
    let currentCompId: CompID
    // (no bindingLayerVisible)
}
```

**Now (RenderContext):**
```swift
private struct RenderContext {
    let frame: Double
    let frameIndex: Int
    // ... existing fields ...
    let currentCompId: CompID
    let bindingLayerVisible: Bool   // PR-28
}
```

**Was (renderCommands):**
```swift
public mutating func renderCommands(
    frameIndex: Int,
    userTransform: Matrix2D = .identity,
    inputClipOverride: InputClipOverride? = nil
) -> [RenderCommand] {
```

**Now (renderCommands):**
```swift
public mutating func renderCommands(
    frameIndex: Int,
    userTransform: Matrix2D = .identity,
    inputClipOverride: InputClipOverride? = nil,
    bindingLayerVisible: Bool = true            // PR-28
) -> [RenderCommand] {
```

**Was (renderLayer):**
```swift
private mutating func renderLayer(_ layer: Layer, context: RenderContext, ...) {
    guard !layer.isMatteSource else { return }
    guard !layer.isHidden else { return }
    // (no binding check)
    guard Self.isVisible(layer, at: context.frame) else { return }
```

**Now (renderLayer):**
```swift
private mutating func renderLayer(_ layer: Layer, context: RenderContext, ...) {
    guard !layer.isMatteSource else { return }
    guard !layer.isHidden else { return }

    // PR-28: Skip binding layer when user media is not present
    if !context.bindingLayerVisible && isBindingLayer(layer, context: context) {
        return
    }

    guard Self.isVisible(layer, at: context.frame) else { return }
```

**Precomp child context propagation (new):**
```swift
// Inside precomp rendering, bindingLayerVisible is propagated to child context
let childContext = RenderContext(
    // ... existing fields ...
    bindingLayerVisible: context.bindingLayerVisible   // PR-28: propagate
)
```

---

### 4. `ScenePlayer/SceneRenderPlan.swift` — userMediaPresent pipeline

**Was:**
```swift
public static func renderCommands(
    for runtime: SceneRuntime,
    sceneFrameIndex: Int,
    userTransforms: [String: Matrix2D] = [:],
    variantOverrides: [String: String] = [:]
) -> [RenderCommand] {
    // ... no userMediaPresent ...
    let animCommands = variant.animIR.renderCommands(
        frameIndex: localFrameIndex,
        userTransform: userTransform,
        inputClipOverride: inputClipOverride
    )
```

**Now:**
```swift
public static func renderCommands(
    for runtime: SceneRuntime,
    sceneFrameIndex: Int,
    userTransforms: [String: Matrix2D] = [:],
    variantOverrides: [String: String] = [:],
    userMediaPresent: [String: Bool] = [:]      // PR-28
) -> [RenderCommand] {
    // ...
    let hasUserMedia = userMediaPresent[block.blockId] ?? false

    let animCommands = variant.animIR.renderCommands(
        frameIndex: localFrameIndex,
        userTransform: userTransform,
        inputClipOverride: inputClipOverride,
        bindingLayerVisible: hasUserMedia         // PR-28
    )
```

**Was (renderBlockCommands):**
```swift
private static func renderBlockCommands(
    block: BlockRuntime,
    variant: inout VariantRuntime,
    sceneFrameIndex: Int,
    canvasSize: SizeD,
    userTransform: Matrix2D
) -> [RenderCommand] {
```

**Now (renderBlockCommands):**
```swift
private static func renderBlockCommands(
    block: BlockRuntime,
    variant: inout VariantRuntime,
    sceneFrameIndex: Int,
    canvasSize: SizeD,
    userTransform: Matrix2D,
    hasUserMedia: Bool                            // PR-28
) -> [RenderCommand] {
```

**Was (SceneRuntime convenience):**
```swift
public func renderCommands(sceneFrameIndex: Int) -> [RenderCommand] {
    SceneRenderPlan.renderCommands(for: self, sceneFrameIndex: sceneFrameIndex)
}
```

**Now (SceneRuntime convenience):**
```swift
public func renderCommands(
    sceneFrameIndex: Int,
    userMediaPresent: [String: Bool] = [:]
) -> [RenderCommand] {
    SceneRenderPlan.renderCommands(
        for: self,
        sceneFrameIndex: sceneFrameIndex,
        userMediaPresent: userMediaPresent
    )
}
```

---

### 5. `ScenePlayer/ScenePlayer.swift` — userMediaPresent state + asset merging

**Was (properties):**
```swift
// (no userMediaPresent property)
```

**Now (properties):**
```swift
/// Per-block user media presence (PR-28).
private var userMediaPresent: [String: Bool] = [:]
```

**New public API:**
```swift
public func setUserMediaPresent(blockId: String, present: Bool) {
    userMediaPresent[blockId] = present
}

public func isUserMediaPresent(blockId: String) -> Bool {
    userMediaPresent[blockId] ?? false
}
```

**Was (compile — asset merging):**
```swift
var allAssetsByIdMerged: [String: String] = [:]
var allSizesByIdMerged: [String: AssetSize] = [:]

// ... merge loop only merged byId and sizeById ...

let mergedAssets = AssetIndexIR(
    byId: allAssetsByIdMerged,
    sizeById: allSizesByIdMerged
)
```

**Now (compile — asset merging):**
```swift
var allAssetsByIdMerged: [String: String] = [:]
var allSizesByIdMerged: [String: AssetSize] = [:]
var allBasenameByIdMerged: [String: String] = [:]    // PR-28

// ... merge loop now also merges basenameById ...
for (assetId, basename) in variant.animIR.assets.basenameById {
    allBasenameByIdMerged[assetId] = basename
}

let mergedAssets = AssetIndexIR(
    byId: allAssetsByIdMerged,
    sizeById: allSizesByIdMerged,
    basenameById: allBasenameByIdMerged              // PR-28
)
```

**Was (renderCommands):**
```swift
return SceneRenderPlan.renderCommands(
    for: compiledScene.runtime,
    sceneFrameIndex: sceneFrameIndex,
    userTransforms: userTransforms,
    variantOverrides: variantOverrides
)
```

**Now (renderCommands):**
```swift
return SceneRenderPlan.renderCommands(
    for: compiledScene.runtime,
    sceneFrameIndex: sceneFrameIndex,
    userTransforms: userTransforms,
    variantOverrides: variantOverrides,
    userMediaPresent: userMediaPresent    // PR-28
)
```

---

### 6. `MetalRenderer/ScenePackageTextureProvider.swift` — REWRITE

**Was:**
```swift
public final class ScenePackageTextureProvider: TextureProvider {
    private let device: MTLDevice
    private let assetIndex: AssetIndexIR
    private let imagesRootURL: URL          // absolute path to images/ dir
    private let loader: MTKTextureLoader
    private var cache: [String: MTLTexture] = [:]

    public init(device: MTLDevice, assetIndex: AssetIndexIR, imagesRootURL: URL)

    // texture(for:) resolved via: assetIndex.byId[assetId] → relative path → imagesRootURL
    // preloadAll() loaded all assets from file paths
}
```

**Now:**
```swift
public final class ScenePackageTextureProvider: TextureProvider {
    private let device: MTLDevice
    private let assetIndex: AssetIndexIR
    private let resolver: CompositeAssetResolver   // PR-28: replaces imagesRootURL
    private let loader: MTKTextureLoader
    private var cache: [String: MTLTexture] = [:]
    private var missingAssets: Set<String> = []
    private let logger: TVELogger?

    public init(device:, assetIndex:, resolver:, logger:)

    // texture(for:) resolved via:
    //   1. cache (includes injected user media)
    //   2. assetIndex.basenameById[assetId] → basename
    //   3. resolver.resolveURL(forKey: basename) → Local → Shared URL
    //   4. load texture from URL

    public func setTexture(_ texture: MTLTexture, for assetId: String)   // PR-28 NEW
    public func removeTexture(for assetId: String)                       // PR-28 NEW

    // preloadAll() now skips non-resolvable assets (binding placeholders) gracefully
}
```

---

### 7. `ScenePlayer/SceneTextureProvider.swift` — Factory update

**Was:**
```swift
public static func create(
    device: MTLDevice,
    mergedAssetIndex: AssetIndexIR,
    package: ScenePackage,
    logger: TVELogger? = nil
) -> ScenePackageTextureProvider
```

**Now:**
```swift
public static func create(
    device: MTLDevice,
    mergedAssetIndex: AssetIndexIR,
    resolver: CompositeAssetResolver,       // PR-28: replaces package
    logger: TVELogger? = nil
) -> ScenePackageTextureProvider
```

---

### 8. `AnimValidator/AnimValidator.swift` — Resolver + binding skip

**Was:**
```swift
public func validate(
    scene: Scene,
    package: ScenePackage,
    loaded: LoadedAnimations
) -> ValidationReport {
```

**Now:**
```swift
public func validate(
    scene: Scene,
    package: ScenePackage,
    loaded: LoadedAnimations,
    resolver: CompositeAssetResolver? = nil     // PR-28: optional
) -> ValidationReport {
```

**Was (validateAssetPresence):**
```swift
func validateAssetPresence(...) {
    // For every image asset: check file exists at package.rootURL + relativePath
    for asset in lottie.assets where asset.isImage {
        let fileURL = package.rootURL.appendingPathComponent(relativePath)
        if !fileManager.fileExists(atPath: fileURL.path) {
            issues.append(...)  // error: missing file
        }
    }
}
```

**Now (validateAssetPresence):**
```swift
func validateAssetPresence(..., resolver: CompositeAssetResolver?) {
    if let resolver = resolver {
        // PR-28: Resolver-based. Skip binding assets, resolve others via basename.
        let bindingAssetIds = findBindingAssetIds(lottie: lottie, blocks: blocks)
        for asset in lottie.assets where asset.isImage {
            if bindingAssetIds.contains(asset.id) { continue }  // skip binding
            let basename = (filename as NSString).deletingPathExtension
            if !resolver.canResolve(key: basename) {
                issues.append(...)  // error: not found in local or shared
            }
        }
    } else {
        // Legacy: file-exists check (unchanged)
        ...
    }
}

// NEW helper:
private func findBindingAssetIds(lottie: LottieJSON, blocks: [MediaBlock]) -> Set<String> {
    // Scans root + precomp layers for nm == bindingKey && ty == 2, collects refIds
}
```

---

## Modified Test Files

| File | Changes |
|------|---------|
| `ScenePlayerRenderIntegrationTests.swift` | Factory calls updated: `package:` → `resolver:`. All render calls pass `userMediaPresent: [blockId: true]`. |
| `ScenePlayerTests.swift` | `player.setUserMediaPresent(blockId:, present: true)` for all blocks before rendering. |
| `TemplateModeTests.swift` | Same: `setUserMediaPresent` or `userMediaPresent:` dict for all blocks. |
| `UserTransformPipelineTests.swift` | Same: `userMediaPresent:` dict in SceneRenderPlan calls. |
| `ScenePlayerDiagnosticTests.swift` | Same: `setUserMediaPresent` before rendering. |
| `VariantSwitchTests.swift` | `makePlayer()` helper now sets `userMediaPresent` for all blocks. |

**Test resource fix:** `Img_4.png` renamed to `img_4.png` (case mismatch with Lottie `"p": "img_4.png"`).

---

## Data Flow Diagram

```
ScenePlayer
  ├── userMediaPresent: [String: Bool]        ← setUserMediaPresent(blockId:, present:)
  ├── compile() merges basenameById           ← AnimIRCompiler extracts from Lottie "p" field
  └── renderCommands()
        └── SceneRenderPlan.renderCommands(userMediaPresent:)
              └── per block: hasUserMedia = userMediaPresent[blockId] ?? false
                    └── AnimIR.renderCommands(bindingLayerVisible: hasUserMedia)
                          └── renderLayer(): if !bindingLayerVisible && isBindingLayer → skip

TextureProvider resolution:
  drawImage(assetId) → cache → basenameById[assetId] → resolver(basename) → Local → Shared → URL → load
```

---

## Key Design Decisions (from TL review)

| # | Decision | Implementation |
|---|----------|---------------|
| Q1 | Binding layer MUST have refId | `findBindingLayer()` unchanged — validates refId existence |
| Q2 | Per-block hasUserMedia flag, skip at render plan level | `ScenePlayer.userMediaPresent` → `SceneRenderPlan` → `AnimIR.bindingLayerVisible` |
| Q3 | SharedAssetsIndex inside TVECore, Bundle via DI | `SharedAssetsIndex(bundle:)` and `SharedAssetsIndex(rootURL:)` |
| Q4 | Full transition to resolver + basenameById | `AssetIndexIR.basenameById`, `CompositeAssetResolver`, `ScenePackageTextureProvider` rewrite |
| Q5 | Validator accepts resolver via DI parameter | `validate(resolver:)` optional, nil = legacy behavior |
| Q6 | Probe validation allows empty binding | Probe renders with `bindingLayerVisible: true` (validates capability) |

---

## Post-Review Fixes (TL Review)

### Fix A: Strict `preloadAll()` — binding vs non-binding assets

**Risk identified:** `preloadAll()` silently skipped ALL non-resolvable assets. A corrupted template with genuinely missing images would produce no errors.

**Solution:** `bindingAssetIds: Set<String>` whitelist propagated through the pipeline. Only binding assets may be skipped; all other missing assets are logged as ERROR and added to `missingAssets`.

#### `ScenePlayerTypes.swift` — CompiledScene
```swift
// ADDED field:
public let bindingAssetIds: Set<String>

public init(
    runtime: SceneRuntime,
    mergedAssetIndex: AssetIndexIR,
    pathRegistry: PathRegistry,
    bindingAssetIds: Set<String> = []    // Fix-A
)
```

#### `ScenePlayer.swift` — compile() collects binding asset IDs
```swift
// NEW: Collect binding asset IDs across all variants
var bindingAssetIds: Set<String> = []
for block in blockRuntimes {
    for variant in block.variants {
        bindingAssetIds.insert(variant.animIR.binding.boundAssetId)
    }
}

let compiled = CompiledScene(
    runtime: sceneRuntime,
    mergedAssetIndex: mergedAssets,
    pathRegistry: sharedPathRegistry,
    bindingAssetIds: bindingAssetIds      // Fix-A
)
```

#### `ScenePackageTextureProvider.swift` — strict preloadAll()
```swift
// ADDED property:
private let bindingAssetIds: Set<String>

// UPDATED init:
public init(
    device: MTLDevice,
    assetIndex: AssetIndexIR,
    resolver: CompositeAssetResolver,
    bindingAssetIds: Set<String> = [],    // Fix-A
    logger: TVELogger? = nil
)

// UPDATED preloadAll():
public func preloadAll() {
    for (assetId, basename) in assetIndex.basenameById {
        if cache[assetId] != nil { continue }
        guard let textureURL = try? resolver.resolveURL(forKey: basename) else {
            if bindingAssetIds.contains(assetId) {
                // Expected: binding asset has no file (user media injected at runtime)
                logger?("[TextureProvider] Preload skipped binding asset '\(assetId)'")
            } else {
                // Unexpected: non-binding asset missing — template corrupted
                logger?("[TextureProvider] ERROR: Asset '\(assetId)' not resolvable — template may be corrupted")
                missingAssets.insert(assetId)
            }
            continue
        }
        if let texture = loadTexture(from: textureURL, assetId: assetId) {
            cache[assetId] = texture
        }
    }
}
```

#### `SceneTextureProvider.swift` — Factory updated
```swift
public static func create(
    device: MTLDevice,
    mergedAssetIndex: AssetIndexIR,
    resolver: CompositeAssetResolver,
    bindingAssetIds: Set<String> = [],    // Fix-A
    logger: TVELogger? = nil
) -> ScenePackageTextureProvider
```

### Fix B: Resolver created early in PlayerViewController

**Risk identified:** App's `AnimValidator.validate()` was called without a resolver, falling back to the legacy file-exists path. This bypassed shared-asset resolution during validation.

**Solution:** Resolver is created BEFORE validation and passed to both `validate()` and `compileScene()`.

#### `PlayerViewController.swift`
```swift
// ADDED property:
private var currentResolver: CompositeAssetResolver?

// UPDATED loadAndValidatePackage():
private func loadAndValidatePackage(from rootURL: URL) throws {
    let package = try loader.load(from: rootURL)
    currentPackage = package

    // Fix-B: Create resolver early — before validation
    let localIndex = try LocalAssetsIndex(imagesRootURL: package.imagesRootURL)
    let resolver = CompositeAssetResolver(localIndex: localIndex, sharedIndex: .empty)
    currentResolver = resolver

    try loadAndValidateAnimations(for: package, resolver: resolver)
    try compileScene(for: package)
}

// UPDATED loadAndValidateAnimations() — now accepts resolver:
private func loadAndValidateAnimations(
    for package: ScenePackage,
    resolver: CompositeAssetResolver
) throws {
    // ...
    let report = animValidator.validate(
        scene: package.scene,
        package: package,
        loaded: loaded,
        resolver: resolver   // Fix-B: always pass resolver
    )
}

// UPDATED compileScene() — reuses resolver, passes bindingAssetIds:
private func compileScene(for package: ScenePackage) throws {
    // ...
    guard let resolver = currentResolver else { return }
    textureProvider = SceneTextureProviderFactory.create(
        device: device,
        mergedAssetIndex: compiled.mergedAssetIndex,
        resolver: resolver,
        bindingAssetIds: compiled.bindingAssetIds,   // Fix-A
        logger: logger
    )
}
```

---

## Updated Data Flow (after Fix A + Fix B)

```
PlayerViewController
  ├── loadAndValidatePackage()
  │     ├── LocalAssetsIndex(imagesRootURL:)        ← Fix-B: created EARLY
  │     ├── CompositeAssetResolver(local, shared)    ← Fix-B: stored as currentResolver
  │     ├── validate(resolver: resolver)             ← Fix-B: resolver passed to validator
  │     └── compileScene()
  │           ├── compiled.bindingAssetIds            ← Fix-A: collected during compile
  │           └── TextureProviderFactory.create(
  │                 resolver: currentResolver,
  │                 bindingAssetIds: compiled.bindingAssetIds  ← Fix-A
  │               )
  └── preloadAll()
        ├── binding asset → skip (debug log)          ← Fix-A: known whitelist
        └── non-binding missing → ERROR + missingAssets  ← Fix-A: template corrupted
```
