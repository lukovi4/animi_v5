import Foundation
import TVECore

// MARK: - ScenePlayerApplying Protocol

/// Protocol for ScenePlayer methods used by the applier.
/// Production: ScenePlayer. Tests: spy via @testable import.
@MainActor
protocol ScenePlayerApplying: AnyObject {
    func mediaInputConfig(blockId: String) -> MediaInput?
    func mediaInputGeometry(blockId: String) -> MediaInputGeometryRuntime?
    func applyVariantSelection(_ mapping: [String: String])
    func setUserTransform(blockId: String, transform: Matrix2D)
    func setUserMediaPresent(blockId: String, present: Bool)
    func setLayerToggle(blockId: String, toggleId: String, enabled: Bool)
}

extension ScenePlayer: ScenePlayerApplying {}

// MARK: - MediaInputProvider Adapters

/// Adapts `ScenePlayer` to `MediaInputProvider` for `SceneStateMigrationHelper`.
@MainActor
public struct ScenePlayerMediaInputProvider: MediaInputProvider {
    private let scenePlayer: ScenePlayer

    public init(scenePlayer: ScenePlayer) {
        self.scenePlayer = scenePlayer
    }

    public func defaultFit(forBlockId blockId: String) -> FitMode? {
        scenePlayer.mediaInputConfig(blockId: blockId)?.defaultFit
    }
}

/// Adapts compiled `Scene.mediaBlocks` to `MediaInputProvider`.
/// Used by engine for hydration when ScenePlayer is not available.
public struct CompiledSceneMediaInputProvider: MediaInputProvider {
    private let mediaBlocks: [MediaBlock]

    public init(mediaBlocks: [MediaBlock]) {
        self.mediaBlocks = mediaBlocks
    }

    public func defaultFit(forBlockId blockId: String) -> FitMode? {
        mediaBlocks.first { $0.id == blockId }?.input.defaultFit
    }
}

/// Stateless helper that applies `SceneState` to runtime components.
///
/// Used by both `PlayerViewController` (scene-edit path) and `SceneInstanceRuntime` (timeline path)
/// to eliminate duplicated apply logic.
///
/// ## Apply Order (canonical)
/// 1. Media restore (visibility atomic via `presentOnReady`)
/// 2. Variants
/// 3. Placement / transforms
/// 4. Layer toggles
///
/// ## Resolver Integration
/// For media blocks with `placement != nil`, `MediaPlacementResolver` generates the `Matrix2D`.
/// For blocks without placement (legacy, not yet hydrated), falls back to `userTransforms`.
public enum SceneRuntimeStateApplier {

    /// Dependencies needed for a full state apply.
    public struct Dependencies: Sendable {
        public let scenePlayer: ScenePlayer
        public let userMediaService: UserMediaService

        public init(scenePlayer: ScenePlayer, userMediaService: UserMediaService) {
            self.scenePlayer = scenePlayer
            self.userMediaService = userMediaService
        }
    }

    // MARK: - Full Apply

    /// Applies full `SceneState` to runtime in canonical order.
    ///
    /// - Parameters:
    ///   - state: The scene state to apply.
    ///   - deps: Runtime dependencies.
    /// - Returns: Count of restored media items.
    @MainActor
    @discardableResult
    public static func apply(
        _ state: SceneState,
        deps: Dependencies
    ) -> Int {
        apply(
            state,
            player: deps.scenePlayer,
            userMediaService: deps.userMediaService,
            restore: { slots, svc in
                guard let svc else { return 0 }
                return MediaRestoreCoordinator.restore(slots: slots, to: svc)
            }
        )
    }

    /// Testing overload: accepts protocol-typed player and injectable restore.
    @MainActor
    @discardableResult
    static func apply(
        _ state: SceneState,
        player: any ScenePlayerApplying,
        userMediaService: UserMediaService?,
        restore: (_ slots: [String: SceneMediaSlot]?, _ service: UserMediaService?) -> Int = { _, _ in 0 }
    ) -> Int {
        // 1. Media restore (visibility gated via presentOnReady)
        let restoredCount = restore(state.mediaSlotsByBlockId, userMediaService)

        // 2. Variants
        player.applyVariantSelection(state.variantOverrides)

        // 3. Placement / transforms
        applyTransforms(state: state, player: player, userMediaService: userMediaService)

        // 4. Layer toggles
        for (blockId, toggles) in state.layerToggles {
            for (toggleId, enabled) in toggles {
                player.setLayerToggle(blockId: blockId, toggleId: toggleId, enabled: enabled)
            }
        }

        return restoredCount
    }

    // MARK: - Fast-Path: Placement Only

    /// Applies a single placement change without full reload.
    /// Resolves placement → Matrix2D via `MediaPlacementResolver` and sets on player.
    @MainActor
    public static func applyPlacementChange(
        blockId: String,
        placement: MediaPlacementState,
        deps: Dependencies
    ) {
        applyPlacementChange(
            blockId: blockId,
            placement: placement,
            player: deps.scenePlayer,
            userMediaService: deps.userMediaService
        )
    }

    /// Testing overload for placement fast-path.
    @MainActor
    static func applyPlacementChange(
        blockId: String,
        placement: MediaPlacementState,
        player: any ScenePlayerApplying,
        userMediaService: UserMediaService? = nil
    ) {
        let matrix = resolveTransform(
            blockId: blockId,
            placement: placement,
            player: player,
            userMediaService: userMediaService
        )
        player.setUserTransform(blockId: blockId, transform: matrix)
    }

    // MARK: - Fast-Path: Visibility Only

    /// Applies a visibility change without full reload.
    @MainActor
    public static func applyVisibilityChange(
        blockId: String,
        visible: Bool,
        player: ScenePlayer
    ) {
        applyVisibilityChange(blockId: blockId, visible: visible, playerApplying: player)
    }

    /// Testing overload for visibility fast-path.
    @MainActor
    static func applyVisibilityChange(
        blockId: String,
        visible: Bool,
        playerApplying player: any ScenePlayerApplying
    ) {
        player.setUserMediaPresent(blockId: blockId, present: visible)
    }

    // MARK: - Fast-Path: Video Selection

    /// Applies a video selection change via UserMediaService.
    /// Throws if UMS validation fails.
    @MainActor
    public static func applyVideoSelectionChange(
        blockId: String,
        selection: PersistedVideoSelection,
        service: UserMediaService
    ) throws {
        try service.applyPersistedVideoSelection(blockId: blockId, selection)
    }

    // MARK: - Fast-Path: Slot Change

    /// Applies a single slot change (insert/replace/remove).
    /// Restores media, applies visibility and placement.
    @MainActor
    @discardableResult
    public static func applySlotChange(
        blockId: String,
        slot: SceneMediaSlot?,
        deps: Dependencies
    ) -> Int {
        applySlotChange(
            blockId: blockId,
            slot: slot,
            player: deps.scenePlayer,
            userMediaService: deps.userMediaService,
            restore: { slots, svc in
                guard let svc else { return 0 }
                return MediaRestoreCoordinator.restore(slots: slots, to: svc)
            }
        )
    }

    /// Testing overload for slot change fast-path.
    @MainActor
    @discardableResult
    static func applySlotChange(
        blockId: String,
        slot: SceneMediaSlot?,
        player: any ScenePlayerApplying,
        userMediaService: UserMediaService? = nil,
        restore: (_ slots: [String: SceneMediaSlot]?, _ service: UserMediaService?) -> Int = { _, _ in 0 }
    ) -> Int {
        if let slot {
            // Restore single slot
            let singleSlot: [String: SceneMediaSlot]? = [blockId: slot]
            let count = restore(singleSlot, userMediaService)

            // Apply placement if present
            if let placement = slot.asset.placement {
                applyPlacementChange(
                    blockId: blockId,
                    placement: placement,
                    player: player,
                    userMediaService: userMediaService
                )
            }

            return count
        } else {
            // Remove: hide media for this block (full cleanup on next reload)
            player.setUserMediaPresent(blockId: blockId, present: false)
            return 0
        }
    }

    // MARK: - Internal

    /// Applies transforms for all blocks, using resolver for media blocks with placement.
    @MainActor
    private static func applyTransforms(state: SceneState, player: any ScenePlayerApplying, userMediaService: UserMediaService?) {
        // Track which blocks got placement-based transforms
        var placementApplied: Set<String> = []

        // Media blocks with placement: resolve via MediaPlacementResolver
        if let slots = state.mediaSlotsByBlockId {
            for (blockId, slot) in slots {
                if let placement = slot.asset.placement {
                    let matrix = resolveTransform(
                        blockId: blockId,
                        placement: placement,
                        player: player,
                        userMediaService: userMediaService
                    )
                    player.setUserTransform(blockId: blockId, transform: matrix)
                    placementApplied.insert(blockId)
                }
            }
        }

        // Legacy fallback: blocks still in userTransforms (not yet migrated)
        for (blockId, transform) in state.userTransforms where !placementApplied.contains(blockId) {
            player.setUserTransform(blockId: blockId, transform: transform)
        }
    }

    /// Resolves a placement to Matrix2D using MediaPlacementResolver.
    /// Uses actual loaded media size when available, falls back to slot rect.
    @MainActor
    private static func resolveTransform(
        blockId: String,
        placement: MediaPlacementState,
        player: any ScenePlayerApplying,
        userMediaService: UserMediaService? = nil
    ) -> Matrix2D {
        guard let geo = player.mediaInputGeometry(blockId: blockId) else {
            return .identity
        }

        let slotRect = geo.placementRectLocal

        // Use actual presentation-correct media size if available (loaded texture/video),
        // otherwise fall back to slot dimensions (will be corrected on next apply after load).
        let mediaW: Double
        let mediaH: Double
        if let size = userMediaService?.mediaPresentationSize(blockId: blockId) {
            mediaW = size.width
            mediaH = size.height
        } else {
            mediaW = slotRect.width
            mediaH = slotRect.height
        }

        let geometry = MediaPlacementResolver.SlotGeometry(
            slotRect: slotRect,
            mediaWidth: mediaW,
            mediaHeight: mediaH
        )

        return MediaPlacementResolver.resolve(placement: placement, geometry: geometry)
    }
}
