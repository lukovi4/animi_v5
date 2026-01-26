import Foundation

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

    /// Returns merged PathRegistry containing all paths from all animations.
    /// The PathIDs are only valid when used with commands from this runtime's renderCommands().
    public var mergedPathRegistry: PathRegistry {
        var merged = PathRegistry()
        // Collect paths from all variants of all blocks
        // Since each AnimIR has its own PathRegistry with IDs starting from 0,
        // commands already reference the correct pathId within their AnimIR.
        // The renderer will look up paths by pathId in the registry passed to draw().
        // We merge all registries, but this only works if pathIds don't collide.
        // For now, return the first block's selected variant registry (TODO: proper merging)
        for block in blocks {
            if let variant = block.selectedVariant {
                for path in variant.animIR.pathRegistry.paths {
                    merged.register(path)
                }
            }
        }
        return merged
    }
}

// MARK: - Block Runtime

/// Runtime representation of a compiled media block
public struct BlockRuntime: Sendable {
    /// Block identifier
    public let blockId: String

    /// Z-index for render ordering (lower = back, higher = front)
    public let zIndex: Int

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
        rectCanvas: RectD,
        inputRect: RectD,
        timing: BlockTiming,
        containerClip: ContainerClip,
        selectedVariantId: String,
        variants: [VariantRuntime]
    ) {
        self.blockId = blockId
        self.zIndex = zIndex
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
            // Default: visible for entire scene
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
