import Foundation

// MARK: - Compiled Scene

/// Single source of truth for a compiled scene.
/// Contains all artifacts from compilation: runtime, assets, and path registry.
/// Guarantees that if you have a CompiledScene, all required data is present.
public struct CompiledScene: Sendable, Codable {
    /// Compiled scene runtime with blocks and timing
    public let runtime: SceneRuntime

    /// Merged asset index containing all assets from all animations (namespaced)
    public let mergedAssetIndex: AssetIndexIR

    /// Scene-level path registry with globally unique PathIDs assigned during compilation
    public let pathRegistry: PathRegistry

    /// Namespaced asset IDs that belong to binding layers (PR-28).
    /// These assets have no file on disk — user media is injected at runtime.
    /// Used by TextureProvider to distinguish expected missing assets from template errors.
    public let bindingAssetIds: Set<String>

    public init(
        runtime: SceneRuntime,
        mergedAssetIndex: AssetIndexIR,
        pathRegistry: PathRegistry,
        bindingAssetIds: Set<String> = []
    ) {
        self.runtime = runtime
        self.mergedAssetIndex = mergedAssetIndex
        self.pathRegistry = pathRegistry
        self.bindingAssetIds = bindingAssetIds
    }
}

// MARK: - Scene Runtime

/// Runtime representation of a compiled scene ready for playback
public struct SceneRuntime: Sendable, Codable {
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
public struct BlockRuntime: Sendable, Codable {
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

    /// Hit-test mode from the block's MediaInput configuration.
    /// `.mask` → hit-test by mediaInput shape path; `.rect` or `nil` → hit-test by block rect.
    public let hitTestMode: HitTestMode?

    /// Currently selected variant ID
    public let selectedVariantId: String

    /// Variant ID used for edit mode (always "no-anim").
    /// Guaranteed to exist after compilation (validated in compileBlock).
    public let editVariantId: String

    /// All compiled variants for this block
    public var variants: [VariantRuntime]

    /// Returns the selected variant runtime (compilation default, no overrides).
    public var selectedVariant: VariantRuntime? {
        variants.first { $0.variantId == selectedVariantId }
    }

    /// Resolves the active variant respecting an override map (PR-20).
    ///
    /// Resolution: `overrides[blockId]` → `selectedVariantId` → first variant.
    /// Single source of truth — used by both ScenePlayer and SceneRenderPlan.
    public func resolvedVariant(overrides: [String: String]) -> VariantRuntime? {
        let activeId = overrides[blockId] ?? selectedVariantId
        let resolved = variants.first(where: { $0.variantId == activeId })
        if resolved == nil {
            assertionFailure("Variant '\(activeId)' not found for block '\(blockId)'. Falling back to first variant.")
        }
        return resolved ?? variants.first
    }

    public init(
        blockId: String,
        zIndex: Int,
        orderIndex: Int,
        rectCanvas: RectD,
        inputRect: RectD,
        timing: BlockTiming,
        containerClip: ContainerClip,
        hitTestMode: HitTestMode? = nil,
        selectedVariantId: String,
        editVariantId: String,
        variants: [VariantRuntime]
    ) {
        self.blockId = blockId
        self.zIndex = zIndex
        self.orderIndex = orderIndex
        self.rectCanvas = rectCanvas
        self.inputRect = inputRect
        self.timing = timing
        self.containerClip = containerClip
        self.hitTestMode = hitTestMode
        self.selectedVariantId = selectedVariantId
        self.editVariantId = editVariantId
        self.variants = variants
    }
}

// MARK: - Block Timing

/// Timing information for block visibility
public struct BlockTiming: Sendable, Equatable, Codable {
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
            // Default: visible for entire scene
            self.startFrame = 0
            self.endFrame = sceneDurationFrames
        }
    }
}

// MARK: - Template Mode (PR-18)

/// Template display mode — determines how the scene is rendered.
///
/// - `preview`: Full playback with all animations and time-dependent effects.
///   Uses the user-selected variant for each block.
/// - `edit`: Static editing mode. Time frozen at `editFrameIndex`.
///   Renders the full `no-anim` variant for each block.
///   `mediaInput` from `no-anim` defines hit-test and overlay geometry.
public enum TemplateMode: String, Sendable, Equatable, Codable {
    case preview
    case edit
}

// MARK: - Media Input Overlay (PR-17)

/// Describes one media-input overlay for the editor's overlay layer.
///
/// Contains all geometry the editor needs to draw an interactive overlay:
/// the canvas-space hit path and the block rect.
public struct MediaInputOverlay: Sendable, Codable {
    /// Block identifier (matches `BlockRuntime.blockId`)
    public let blockId: String

    /// Hit-test path in canvas coordinates.
    /// For `hitTestMode == .mask` this is the mediaInput shape path;
    /// for `.rect` or `nil` it is the block rect converted to a path.
    public let hitPath: BezierPath

    /// Block rectangle in canvas coordinates (always available as a fallback)
    public let rectCanvas: RectD

    public init(blockId: String, hitPath: BezierPath, rectCanvas: RectD) {
        self.blockId = blockId
        self.hitPath = hitPath
        self.rectCanvas = rectCanvas
    }
}

// MARK: - Variant Info (PR-20)

/// Lightweight variant descriptor for UI — does not expose AnimIR internals.
public struct VariantInfo: Sendable, Equatable, Codable {
    /// Variant identifier
    public let id: String

    /// Animation reference (filename)
    public let animRef: String

    public init(id: String, animRef: String) {
        self.id = id
        self.animRef = animRef
    }
}

// MARK: - Variant Runtime

/// Runtime representation of a compiled animation variant
public struct VariantRuntime: Sendable, Codable {
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
