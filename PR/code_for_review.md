# PR: Compile-time Path Registration — Финальный код для ревью

**Версия:** После всех исправлений (MUST-1 подтверждён, MUST-2 решён архитектурно через CompiledScene, SHOULD-1, SHOULD-2)

## Исправления по ревью

| Приоритет | Проблема | Решение |
|-----------|----------|---------|
| **MUST-1** | `PathRegistry.register()` должен переустанавливать `pathId` | ✅ Подтверждено — делает overwrite |
| **MUST-2** | Guard на `mergedPathRegistry == nil` | ✅ Архитектурно — `CompiledScene` (single source of truth) |
| **SHOULD-1** | Legacy `registerPaths(into:)` — deterministic sort | ✅ Root-first, затем sorted |
| **SHOULD-2** | Комментарий best-effort в legacy метод | ✅ Добавлен |

---

## Содержание
1. [ScenePlayerTypes.swift (CompiledScene)](#1-sceneplayertypesswift)
2. [ScenePlayer.swift](#2-sceneplayerswift)
3. [AnimIR.swift (Legacy Path Registration)](#3-animirswift-legacy-path-registration)
4. [AnimIRCompiler.swift](#4-animircompilerswift)
5. [Ключевые гарантии](#5-ключевые-гарантии)

---

## 1. ScenePlayerTypes.swift

```swift
import Foundation

// MARK: - Compiled Scene

/// Single source of truth for a compiled scene.
/// Contains all artifacts from compilation: runtime, assets, and path registry.
/// Guarantees that if you have a CompiledScene, all required data is present.
public struct CompiledScene: Sendable {
    /// Compiled scene runtime with blocks and timing
    public let runtime: SceneRuntime

    /// Merged asset index containing all assets from all animations (namespaced)
    public let mergedAssetIndex: AssetIndexIR

    /// Scene-level path registry with globally unique PathIDs assigned during compilation
    public let pathRegistry: PathRegistry

    public init(runtime: SceneRuntime, mergedAssetIndex: AssetIndexIR, pathRegistry: PathRegistry) {
        self.runtime = runtime
        self.mergedAssetIndex = mergedAssetIndex
        self.pathRegistry = pathRegistry
    }
}

// MARK: - Scene Runtime

/// Runtime representation of a compiled scene ready for playback
public struct SceneRuntime: Sendable {
    /// Original scene configuration
    public let scene: Scene

    /// Canvas configuration
    public let canvas: Canvas

    /// Compiled blocks sorted by zIndex (ascending for correct render order)
    public let blocks: [BlockRuntime]

    /// Total duration in frames
    public let durationFrames: Int

    /// Frame rate
    public let fps: Int

    /// Canvas size
    public var canvasSize: SizeD {
        SizeD(width: Double(canvas.width), height: Double(canvas.height))
    }

    public init(scene: Scene, canvas: Canvas, blocks: [BlockRuntime], durationFrames: Int, fps: Int) {
        self.scene = scene
        self.canvas = canvas
        self.blocks = blocks
        self.durationFrames = durationFrames
        self.fps = fps
    }
}

// MARK: - Block Runtime

/// Runtime representation of a compiled media block
public struct BlockRuntime: Sendable {
    /// Block identifier
    public let blockId: String

    /// Z-index for render ordering (lower = back, higher = front)
    public let zIndex: Int

    /// Original order index from scene.mediaBlocks for stable sorting
    public let orderIndex: Int

    /// Block rectangle in canvas coordinates
    public let rectCanvas: RectD

    /// Input rectangle in block-local coordinates
    public let inputRect: RectD

    /// Block timing (visibility window)
    public let timing: BlockTiming

    /// Container clip mode
    public let containerClip: ContainerClip

    /// Currently selected variant ID
    public let selectedVariantId: String

    /// All compiled variants for this block
    public var variants: [VariantRuntime]

    /// Returns the selected variant runtime
    public var selectedVariant: VariantRuntime? {
        variants.first { $0.variantId == selectedVariantId }
    }

    public init(
        blockId: String,
        zIndex: Int,
        orderIndex: Int,
        rectCanvas: RectD,
        inputRect: RectD,
        timing: BlockTiming,
        containerClip: ContainerClip,
        selectedVariantId: String,
        variants: [VariantRuntime]
    ) {
        self.blockId = blockId
        self.zIndex = zIndex
        self.orderIndex = orderIndex
        self.rectCanvas = rectCanvas
        self.inputRect = inputRect
        self.timing = timing
        self.containerClip = containerClip
        self.selectedVariantId = selectedVariantId
        self.variants = variants
    }
}

// MARK: - Block Timing

/// Timing information for block visibility
public struct BlockTiming: Sendable, Equatable {
    /// Frame when block becomes visible (inclusive)
    public let startFrame: Int

    /// Frame when block stops being visible (exclusive)
    public let endFrame: Int

    /// Checks if block is visible at the given scene frame
    public func isVisible(at sceneFrame: Int) -> Bool {
        sceneFrame >= startFrame && sceneFrame < endFrame
    }

    /// Duration in frames
    public var duration: Int {
        max(0, endFrame - startFrame)
    }

    public init(startFrame: Int, endFrame: Int) {
        self.startFrame = startFrame
        self.endFrame = endFrame
    }

    /// Creates timing from optional scene Timing, with defaults from scene duration
    public init(from timing: Timing?, sceneDurationFrames: Int) {
        if let timing = timing {
            self.startFrame = timing.startFrame
            self.endFrame = timing.endFrame
        } else {
            self.startFrame = 0
            self.endFrame = sceneDurationFrames
        }
    }
}

// MARK: - Variant Runtime

/// Runtime representation of a compiled animation variant
public struct VariantRuntime: Sendable {
    /// Variant identifier
    public let variantId: String

    /// Animation reference (filename)
    public let animRef: String

    /// Compiled animation IR
    public var animIR: AnimIR

    /// Binding key for content replacement
    public let bindingKey: String

    public init(variantId: String, animRef: String, animIR: AnimIR, bindingKey: String) {
        self.variantId = variantId
        self.animRef = animRef
        self.animIR = animIR
        self.bindingKey = bindingKey
    }
}
```

---

## 2. ScenePlayer.swift

```swift
import Foundation

// MARK: - Scene Player

/// Compiles a ScenePackage into a runtime representation for playback.
/// Handles animation compilation, block layout, and render command generation.
public final class ScenePlayer {

    // MARK: - Properties

    /// Compiled scene (single source of truth after compilation)
    /// Contains runtime, merged assets, and path registry.
    /// Nil before compile() is called.
    public private(set) var compiledScene: CompiledScene?

    /// Animation compiler
    private let compiler = AnimIRCompiler()

    // MARK: - Initialization

    public init() {}

    // MARK: - Compilation

    /// Compiles a scene package into a CompiledScene.
    ///
    /// PathIDs are assigned deterministically during compilation into a shared
    /// scene-level registry. This ensures:
    /// - No runtime path registration needed
    /// - Variant switching works without registry rebuild
    /// - Each AnimIR has empty pathRegistry (scene uses CompiledScene.pathRegistry)
    ///
    /// - Parameters:
    ///   - package: Scene package with scene.json and animation files
    ///   - loadedAnimations: Pre-loaded Lottie animations from AnimLoader
    /// - Returns: CompiledScene containing runtime, assets, and path registry
    /// - Throws: ScenePlayerError if compilation fails
    @discardableResult
    public func compile(
        package: ScenePackage,
        loadedAnimations: LoadedAnimations
    ) throws -> CompiledScene {
        let scene = package.scene

        guard !scene.mediaBlocks.isEmpty else {
            throw ScenePlayerError.noMediaBlocks
        }

        // Scene-level path registry - paths are registered during compilation
        var sharedPathRegistry = PathRegistry()

        // Compile all blocks
        var blockRuntimes: [BlockRuntime] = []
        var allAssetsByIdMerged: [String: String] = [:]
        var allSizesByIdMerged: [String: AssetSize] = [:]

        for (index, mediaBlock) in scene.mediaBlocks.enumerated() {
            let blockRuntime = try compileBlock(
                mediaBlock: mediaBlock,
                orderIndex: index,
                loadedAnimations: loadedAnimations,
                sceneDurationFrames: scene.canvas.durationFrames,
                pathRegistry: &sharedPathRegistry
            )
            blockRuntimes.append(blockRuntime)

            // Merge assets from all variants of this block
            for variant in blockRuntime.variants {
                for (assetId, path) in variant.animIR.assets.byId {
                    allAssetsByIdMerged[assetId] = path
                }
                for (assetId, size) in variant.animIR.assets.sizeById {
                    allSizesByIdMerged[assetId] = size
                }
            }
        }

        // Sort blocks by zIndex for correct render order (lower zIndex rendered first)
        // Use orderIndex as tiebreaker for stable sorting when zIndex is equal
        blockRuntimes.sort { ($0.zIndex, $0.orderIndex) < ($1.zIndex, $1.orderIndex) }

        // Create merged asset index
        let mergedAssets = AssetIndexIR(byId: allAssetsByIdMerged, sizeById: allSizesByIdMerged)

        // Create runtime
        let sceneRuntime = SceneRuntime(
            scene: scene,
            canvas: scene.canvas,
            blocks: blockRuntimes,
            durationFrames: scene.canvas.durationFrames,
            fps: scene.canvas.fps
        )

        // Create CompiledScene (single source of truth)
        let compiled = CompiledScene(
            runtime: sceneRuntime,
            mergedAssetIndex: mergedAssets,
            pathRegistry: sharedPathRegistry
        )

        self.compiledScene = compiled
        return compiled
    }

    // MARK: - Block Compilation

    /// Compiles a single media block
    private func compileBlock(
        mediaBlock: MediaBlock,
        orderIndex: Int,
        loadedAnimations: LoadedAnimations,
        sceneDurationFrames: Int,
        pathRegistry: inout PathRegistry
    ) throws -> BlockRuntime {
        guard !mediaBlock.variants.isEmpty else {
            throw ScenePlayerError.noVariantsForBlock(blockId: mediaBlock.id)
        }

        // Validate timing
        let timing = BlockTiming(from: mediaBlock.timing, sceneDurationFrames: sceneDurationFrames)
        if timing.startFrame >= timing.endFrame {
            throw ScenePlayerError.invalidBlockTiming(
                blockId: mediaBlock.id,
                startFrame: timing.startFrame,
                endFrame: timing.endFrame
            )
        }

        // Compile all variants
        var variantRuntimes: [VariantRuntime] = []

        for variant in mediaBlock.variants {
            let variantRuntime = try compileVariant(
                variant: variant,
                bindingKey: mediaBlock.input.bindingKey,
                blockId: mediaBlock.id,
                loadedAnimations: loadedAnimations,
                pathRegistry: &pathRegistry
            )
            variantRuntimes.append(variantRuntime)
        }

        // Select first variant as default
        let selectedVariantId = mediaBlock.variants.first?.id ?? ""

        return BlockRuntime(
            blockId: mediaBlock.id,
            zIndex: mediaBlock.zIndex,
            orderIndex: orderIndex,
            rectCanvas: RectD(from: mediaBlock.rect),
            inputRect: RectD(from: mediaBlock.input.rect),
            timing: timing,
            containerClip: mediaBlock.containerClip,
            selectedVariantId: selectedVariantId,
            variants: variantRuntimes
        )
    }

    // MARK: - Variant Compilation

    /// Compiles a single variant with path registration into scene-level registry
    private func compileVariant(
        variant: Variant,
        bindingKey: String,
        blockId: String,
        loadedAnimations: LoadedAnimations,
        pathRegistry: inout PathRegistry
    ) throws -> VariantRuntime {
        let animRef = variant.animRef

        // Get Lottie JSON for this animation
        guard let lottie = loadedAnimations.lottieByAnimRef[animRef] else {
            throw ScenePlayerError.animRefNotFound(animRef: animRef, blockId: blockId)
        }

        // Get asset index for this animation
        guard let assetIndex = loadedAnimations.assetIndexByAnimRef[animRef] else {
            throw ScenePlayerError.animRefNotFound(animRef: animRef, blockId: blockId)
        }

        // Compile AnimIR with scene-level path registry
        // PathIDs are assigned during compilation, no post-pass registerPaths needed
        let animIR: AnimIR
        do {
            animIR = try compiler.compile(
                lottie: lottie,
                animRef: animRef,
                bindingKey: bindingKey,
                assetIndex: assetIndex,
                pathRegistry: &pathRegistry
            )
        } catch {
            throw ScenePlayerError.compilationFailed(
                animRef: animRef,
                reason: error.localizedDescription
            )
        }

        return VariantRuntime(
            variantId: variant.id,
            animRef: animRef,
            animIR: animIR,
            bindingKey: bindingKey
        )
    }

    // MARK: - Render Commands

    /// Generates render commands for the given scene frame
    ///
    /// - Parameter sceneFrameIndex: Frame index in scene timeline
    /// - Returns: Render commands for all visible blocks, or empty array if not compiled
    public func renderCommands(sceneFrameIndex: Int) -> [RenderCommand] {
        guard let compiledScene = compiledScene else {
            return []
        }
        return compiledScene.runtime.renderCommands(sceneFrameIndex: sceneFrameIndex)
    }
}
```

---

## 3. AnimIR.swift (Legacy Path Registration)

```swift
// MARK: - Path Registration (Legacy)

extension AnimIR {
    /// Registers all paths (masks and shapes) in the PathRegistry.
    /// - Note: Deprecated no-op. Paths are now registered during compilation.
    ///   Use `AnimIRCompiler.compile(..., pathRegistry:)` for scene-level path registration.
    @available(*, deprecated, message: "Paths are now registered during compilation. Use AnimIRCompiler.compile(..., pathRegistry:)")
    public mutating func registerPaths() {
        // NO-OP: Paths are registered during compilation.
        // This method is kept only for API compatibility.
        // Do not call - use compile(..., pathRegistry:) instead.
    }

    /// Registers all paths into an external PathRegistry.
    ///
    /// - Note: This is **legacy/debug** behavior. Paths are now registered during compilation.
    ///   Use `AnimIRCompiler.compile(..., pathRegistry:)` for scene-level path registration.
    ///
    /// - Important: Best-effort legacy path registration. May silently skip untriangulatable
    ///   paths (when `PathResourceBuilder.build` returns nil). For guaranteed registration
    ///   with proper error handling, use `AnimIRCompiler.compile(..., pathRegistry:)`.
    ///
    /// - Parameter registry: External registry to register paths into
    @available(*, deprecated, message: "Paths are now registered during compilation. Use AnimIRCompiler.compile(..., pathRegistry:)")
    public mutating func registerPaths(into registry: inout PathRegistry) {
        // Collect keys in deterministic order to ensure consistent PathID assignment
        // Root composition first, then precomps sorted alphabetically
        let compIds = comps.keys.sorted { lhs, rhs in
            if lhs == AnimIR.rootCompId { return true }
            if rhs == AnimIR.rootCompId { return false }
            return lhs < rhs
        }

        for compId in compIds {
            guard let comp = comps[compId] else { continue }
            var updatedLayers: [Layer] = []

            for var layer in comp.layers {
                // Register mask paths
                var updatedMasks: [Mask] = []
                for var mask in layer.masks {
                    if mask.pathId == nil {
                        // Use dummy PathID for build, rely only on assignedId from register()
                        if let resource = PathResourceBuilder.build(from: mask.path, pathId: PathID(0)) {
                            let assignedId = registry.register(resource)
                            mask.pathId = assignedId
                        }
                    }
                    updatedMasks.append(mask)
                }

                // Register shape paths (for matte sources)
                var updatedContent = layer.content
                if case .shapes(var shapeGroup) = layer.content {
                    if shapeGroup.pathId == nil, let animPath = shapeGroup.animPath {
                        // Use dummy PathID for build, rely only on assignedId from register()
                        if let resource = PathResourceBuilder.build(from: animPath, pathId: PathID(0)) {
                            let assignedId = registry.register(resource)
                            shapeGroup.pathId = assignedId
                            updatedContent = .shapes(shapeGroup)
                        }
                    }
                }

                // Create updated layer with new masks and content
                layer = Layer(
                    id: layer.id,
                    name: layer.name,
                    type: layer.type,
                    timing: layer.timing,
                    parent: layer.parent,
                    transform: layer.transform,
                    masks: updatedMasks,
                    matte: layer.matte,
                    content: updatedContent,
                    isMatteSource: layer.isMatteSource
                )
                updatedLayers.append(layer)
            }

            // Update composition with updated layers
            let updatedComp = Composition(id: compId, size: comp.size, layers: updatedLayers)
            comps[compId] = updatedComp
        }

        // IMPORTANT: Do NOT copy registry to pathRegistry here.
        // This was the source of the duplication bug where each AnimIR
        // stored the entire merged registry.
        // Scene pipeline should use scene-level registry, not AnimIR.pathRegistry.
    }
}
```

---

## 4. AnimIRCompiler.swift

```swift
import Foundation

// MARK: - Unsupported Feature Error

/// Error thrown when the compiler encounters an unsupported Lottie feature
public struct UnsupportedFeature: Error, Sendable {
    /// Error code for categorization
    public let code: String

    /// Human-readable error message
    public let message: String

    /// Path/context where the error occurred
    public let path: String

    public init(code: String, message: String, path: String) {
        self.code = code
        self.message = message
        self.path = path
    }
}

extension UnsupportedFeature: LocalizedError {
    public var errorDescription: String? {
        "[\(code)] \(message) at \(path)"
    }
}

// MARK: - Compiler Error

/// Errors that can occur during AnimIR compilation
public enum AnimIRCompilerError: Error, Sendable {
    case bindingLayerNotFound(bindingKey: String, animRef: String)
    case bindingLayerNotImage(bindingKey: String, layerType: Int, animRef: String)
    case bindingLayerNoAsset(bindingKey: String, animRef: String)
    case unsupportedLayerType(layerType: Int, layerName: String, animRef: String)
}

extension AnimIRCompilerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .bindingLayerNotFound(let key, let animRef):
            return "Binding layer '\(key)' not found in \(animRef)"
        case .bindingLayerNotImage(let key, let layerType, let animRef):
            return "Binding layer '\(key)' must be image (ty=2), got ty=\(layerType) in \(animRef)"
        case .bindingLayerNoAsset(let key, let animRef):
            return "Binding layer '\(key)' has no asset reference in \(animRef)"
        case .unsupportedLayerType(let layerType, let layerName, let animRef):
            return "Unsupported layer type \(layerType) for layer '\(layerName)' in \(animRef)"
        }
    }
}

// MARK: - Asset ID Namespacing

/// Separator used for asset ID namespacing
private let assetIdNamespaceSeparator = "|"

/// Creates a namespaced asset ID from animRef and original Lottie asset ID.
/// Format: "<animRef>|<lottieAssetId>" e.g. "anim-1.json|image_0"
private func namespacedAssetId(animRef: String, assetId: String) -> String {
    "\(animRef)\(assetIdNamespaceSeparator)\(assetId)"
}

// MARK: - AnimIR Compiler

/// Compiles LottieJSON into AnimIR representation
public final class AnimIRCompiler {
    public init() {}

    /// Compiles a Lottie animation into AnimIR with scene-level path registry.
    ///
    /// This is the preferred method for scene compilation. PathIDs are assigned
    /// deterministically during compilation into the shared registry.
    ///
    /// - Parameters:
    ///   - lottie: Parsed Lottie JSON
    ///   - animRef: Animation reference identifier
    ///   - bindingKey: Layer name to bind for content replacement
    ///   - assetIndex: Asset index from AnimLoader
    ///   - pathRegistry: Scene-level path registry (shared across all animations)
    /// - Returns: Compiled AnimIR (with pathRegistry field empty - use scene-level registry)
    /// - Throws: AnimIRCompilerError or UnsupportedFeature if compilation fails
    public func compile(
        lottie: LottieJSON,
        animRef: String,
        bindingKey: String,
        assetIndex: AssetIndex,
        pathRegistry: inout PathRegistry
    ) throws -> AnimIR {
        // Build metadata
        let meta = Meta(
            width: lottie.width,
            height: lottie.height,
            fps: lottie.frameRate,
            inPoint: lottie.inPoint,
            outPoint: lottie.outPoint,
            sourceAnimRef: animRef
        )

        var comps: [CompID: Composition] = [:]

        // Build root composition
        let rootSize = SizeD(width: lottie.width, height: lottie.height)
        let rootLayers = try compileLayers(
            lottie.layers,
            compId: AnimIR.rootCompId,
            animRef: animRef,
            fallbackOp: lottie.outPoint,
            pathRegistry: &pathRegistry
        )
        comps[AnimIR.rootCompId] = Composition(
            id: AnimIR.rootCompId,
            size: rootSize,
            layers: rootLayers
        )

        // Build precomp compositions from assets
        for asset in lottie.assets where asset.isPrecomp {
            guard let assetLayers = asset.layers else { continue }

            let compId = asset.id
            let compSize = SizeD(
                width: asset.width ?? lottie.width,
                height: asset.height ?? lottie.height
            )
            let layers = try compileLayers(
                assetLayers,
                compId: compId,
                animRef: animRef,
                fallbackOp: lottie.outPoint,
                pathRegistry: &pathRegistry
            )
            comps[compId] = Composition(id: compId, size: compSize, layers: layers)
        }

        // Find binding layer
        let binding = try findBindingLayer(
            bindingKey: bindingKey,
            comps: comps,
            animRef: animRef
        )

        // Build asset index IR with namespaced keys
        var namespacedById: [String: String] = [:]
        var namespacedSizeById: [String: AssetSize] = [:]

        for (originalId, path) in assetIndex.byId {
            let nsId = namespacedAssetId(animRef: animRef, assetId: originalId)
            namespacedById[nsId] = path
        }

        for asset in lottie.assets where asset.isImage {
            if let width = asset.width, let height = asset.height {
                let nsId = namespacedAssetId(animRef: animRef, assetId: asset.id)
                namespacedSizeById[nsId] = AssetSize(width: width, height: height)
            }
        }

        let assetsIR = AssetIndexIR(byId: namespacedById, sizeById: namespacedSizeById)

        // Return AnimIR with empty local pathRegistry
        // Scene pipeline uses scene-level registry, not AnimIR.pathRegistry
        return AnimIR(
            meta: meta,
            rootComp: AnimIR.rootCompId,
            comps: comps,
            assets: assetsIR,
            binding: binding,
            pathRegistry: PathRegistry() // Empty - scene uses merged registry
        )
    }

    /// Compiles a Lottie animation into AnimIR (legacy/standalone mode).
    ///
    /// This method creates a local PathRegistry and registers paths into it.
    /// Use `compile(..., pathRegistry:)` for scene compilation with shared registry.
    @available(*, deprecated, message: "Use compile(..., pathRegistry:) for scene-level path registration")
    public func compile(
        lottie: LottieJSON,
        animRef: String,
        bindingKey: String,
        assetIndex: AssetIndex
    ) throws -> AnimIR {
        var localRegistry = PathRegistry()
        var animIR = try compile(
            lottie: lottie,
            animRef: animRef,
            bindingKey: bindingKey,
            assetIndex: assetIndex,
            pathRegistry: &localRegistry
        )
        // For standalone usage, store local registry in AnimIR
        animIR.pathRegistry = localRegistry
        return animIR
    }

    // MARK: - Layer Compilation

    /// Compiles an array of Lottie layers into IR layers with matte relationships
    private func compileLayers(
        _ lottieLayers: [LottieLayer],
        compId: CompID,
        animRef: String,
        fallbackOp: Double,
        pathRegistry: inout PathRegistry
    ) throws -> [Layer] {
        // First pass: identify matte source → consumer relationships
        var matteSourceForConsumer: [LayerID: LayerID] = [:]

        for (index, lottieLayer) in lottieLayers.enumerated() where (lottieLayer.isMatteSource ?? 0) == 1 {
            let sourceId = lottieLayer.index ?? index
            if index + 1 < lottieLayers.count {
                let consumerLayer = lottieLayers[index + 1]
                let consumerId = consumerLayer.index ?? (index + 1)
                matteSourceForConsumer[consumerId] = sourceId
            }
        }

        // Second pass: compile all layers with matte info
        var layers: [Layer] = []

        for (index, lottieLayer) in lottieLayers.enumerated() {
            let layerId = lottieLayer.index ?? index

            var matteInfo: MatteInfo?
            if let trackMatteType = lottieLayer.trackMatteType,
               let mode = MatteMode(trackMatteType: trackMatteType),
               let sourceId = matteSourceForConsumer[layerId] {
                matteInfo = MatteInfo(mode: mode, sourceLayerId: sourceId)
            }

            let layer = try compileLayer(
                lottie: lottieLayer,
                index: index,
                compId: compId,
                animRef: animRef,
                fallbackOp: fallbackOp,
                matteInfo: matteInfo,
                pathRegistry: &pathRegistry
            )
            layers.append(layer)
        }

        return layers
    }

    /// Compiles a single Lottie layer into IR layer
    private func compileLayer(
        lottie: LottieLayer,
        index: Int,
        compId: CompID,
        animRef: String,
        fallbackOp: Double,
        matteInfo: MatteInfo?,
        pathRegistry: inout PathRegistry
    ) throws -> Layer {
        let layerId: LayerID = lottie.index ?? index

        guard let layerType = LayerType(lottieType: lottie.type) else {
            throw AnimIRCompilerError.unsupportedLayerType(
                layerType: lottie.type,
                layerName: lottie.name ?? "unnamed",
                animRef: animRef
            )
        }

        let timing = LayerTiming(
            ip: lottie.inPoint,
            op: lottie.outPoint,
            st: lottie.startTime,
            fallbackOp: fallbackOp
        )

        let transform = TransformTrack(from: lottie.transform)

        let layerName = lottie.name ?? "Layer_\(index)"
        let masks = try compileMasks(
            from: lottie.masksProperties,
            animRef: animRef,
            layerName: layerName,
            pathRegistry: &pathRegistry
        )

        let content = try compileContent(
            from: lottie,
            layerType: layerType,
            animRef: animRef,
            layerName: layerName,
            pathRegistry: &pathRegistry
        )

        let isMatteSource = (lottie.isMatteSource ?? 0) == 1

        return Layer(
            id: layerId,
            name: layerName,
            type: layerType,
            timing: timing,
            parent: lottie.parent,
            transform: transform,
            masks: masks,
            matte: matteInfo,
            content: content,
            isMatteSource: isMatteSource
        )
    }

    /// Compiles masks from Lottie mask properties with path registration
    /// - Throws: UnsupportedFeature if mask path cannot be triangulated
    private func compileMasks(
        from lottieMasks: [LottieMask]?,
        animRef: String,
        layerName: String,
        pathRegistry: inout PathRegistry
    ) throws -> [Mask] {
        guard let lottieMasks = lottieMasks else { return [] }

        var masks: [Mask] = []

        for (index, lottieMask) in lottieMasks.enumerated() {
            guard var mask = Mask(from: lottieMask) else { continue }

            // Build PathResource with dummy PathID - rely only on assignedId from register()
            guard let resource = PathResourceBuilder.build(from: mask.path, pathId: PathID(0)) else {
                throw UnsupportedFeature(
                    code: "MASK_PATH_BUILD_FAILED",
                    message: "Cannot triangulate/flatten mask path (topology mismatch or too few vertices)",
                    path: "anim(\(animRef)).layer(\(layerName)).mask[\(index)]"
                )
            }

            // Register path and use only the assigned ID
            let assignedId = pathRegistry.register(resource)
            mask.pathId = assignedId

            masks.append(mask)
        }

        return masks
    }

    /// Compiles layer content based on type with path registration for shapeMatte
    /// - Throws: UnsupportedFeature if shapeMatte path cannot be triangulated
    private func compileContent(
        from lottie: LottieLayer,
        layerType: LayerType,
        animRef: String,
        layerName: String,
        pathRegistry: inout PathRegistry
    ) throws -> LayerContent {
        switch layerType {
        case .image:
            if let refId = lottie.refId, !refId.isEmpty {
                let nsAssetId = namespacedAssetId(animRef: animRef, assetId: refId)
                return .image(assetId: nsAssetId)
            }
            return .none

        case .precomp:
            if let refId = lottie.refId, !refId.isEmpty {
                return .precomp(compId: refId)
            }
            return .none

        case .shapeMatte:
            let animPath = ShapePathExtractor.extractAnimPath(from: lottie.shapes)
            let fillColor = ShapePathExtractor.extractFillColor(from: lottie.shapes)
            let fillOpacity = ShapePathExtractor.extractFillOpacity(from: lottie.shapes)

            var shapeGroup = ShapeGroup(
                animPath: animPath,
                fillColor: fillColor,
                fillOpacity: fillOpacity
            )

            if let animPath = animPath {
                // Build PathResource with dummy PathID - rely only on assignedId from register()
                guard let resource = PathResourceBuilder.build(from: animPath, pathId: PathID(0)) else {
                    throw UnsupportedFeature(
                        code: "MATTE_PATH_BUILD_FAILED",
                        message: "Cannot triangulate/flatten matte shape path (topology mismatch or too few vertices)",
                        path: "anim(\(animRef)).layer(\(layerName)).shapeMatte"
                    )
                }

                // Register path and use only the assigned ID
                let assignedId = pathRegistry.register(resource)
                shapeGroup.pathId = assignedId
            }

            return .shapes(shapeGroup)

        case .null:
            return .none
        }
    }

    // MARK: - Binding Layer

    /// Finds the binding layer across all compositions
    private func findBindingLayer(
        bindingKey: String,
        comps: [CompID: Composition],
        animRef: String
    ) throws -> BindingInfo {
        // Search in deterministic order: root first, then precomps by sorted ID
        let sortedCompIds = comps.keys.sorted { lhs, rhs in
            if lhs == AnimIR.rootCompId { return true }
            if rhs == AnimIR.rootCompId { return false }
            return lhs < rhs
        }

        for compId in sortedCompIds {
            guard let comp = comps[compId] else { continue }

            for layer in comp.layers where layer.name == bindingKey {
                guard layer.type == .image else {
                    throw AnimIRCompilerError.bindingLayerNotImage(
                        bindingKey: bindingKey,
                        layerType: layer.type.rawValue,
                        animRef: animRef
                    )
                }

                guard case .image(let assetId) = layer.content else {
                    throw AnimIRCompilerError.bindingLayerNoAsset(
                        bindingKey: bindingKey,
                        animRef: animRef
                    )
                }

                return BindingInfo(
                    bindingKey: bindingKey,
                    boundLayerId: layer.id,
                    boundAssetId: assetId,
                    boundCompId: compId
                )
            }
        }

        throw AnimIRCompilerError.bindingLayerNotFound(
            bindingKey: bindingKey,
            animRef: animRef
        )
    }
}
```

---

## 5. Ключевые гарантии

| Проверка | Статус | Детали |
|----------|--------|--------|
| A) `CompiledScene` — single source of truth | ✅ | Невозможно получить runtime без registry |
| B) Нет silent fallback `?? PathRegistry()` | ✅ | Тесты используют `compiled.pathRegistry` |
| C) Все variants всех blocks компилируются | ✅ | `for variant in mediaBlock.variants` |
| D) Детерминизм порядка PathID | ✅ | Итерация по массивам, не Dictionary |
| E) Throw с полным контекстом | ✅ | animRef, layerName, mask index |
| F) Стабильная сортировка блоков | ✅ | `sort { ($0.zIndex, $0.orderIndex) < ... }` |
| G) Legacy `registerPaths(into:)` детерминирован | ✅ | root-first sorted + `assignedId` |
| H) `registerPaths()` — no-op | ✅ | Пустое тело |
| I) Dummy PathID при build | ✅ | `PathID(0)`, полагаемся на `assignedId` |
| J) `PathRegistry.register()` делает overwrite | ✅ | Подтверждено в коде |

---

## Результат сборки и тестов

```
Build complete! (1.54s)
Test Suite 'All tests' passed
Executed 175 tests, with 0 failures
```
