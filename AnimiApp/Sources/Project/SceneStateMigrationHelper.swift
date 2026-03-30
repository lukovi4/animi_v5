import Foundation
import TVECore
import os.log

/// Provides media input context for migration: the `defaultFit` per block.
/// Implemented by the caller who has access to template metadata.
public protocol MediaInputProvider {
    /// Returns the `defaultFit` for the given block, or `nil` if unknown.
    func defaultFit(forBlockId blockId: String) -> FitMode?
}

/// Runtime hydration of `SceneState` placement data.
///
/// Called once per project load, when template context (`mediaInput.defaultFit`) is available.
/// Codable only does structural migration (flat→nested). This helper handles:
/// - Slots with `placement == nil` → assign default from `mediaInput.defaultFit ?? .cover`
/// - `userTransforms[blockId]` with media slot → decompose Matrix2D into placement
/// - `userTransforms[blockId]` without media slot → discard (stale)
/// - After migration, cleaned keys are removed from `userTransforms`
public enum SceneStateMigrationHelper {

    private static let logger = Logger(
        subsystem: "com.animi.app",
        category: "SceneStateMigration"
    )

    /// Hydrates a `SceneState` with placement data from template context.
    ///
    /// - Parameters:
    ///   - state: The scene state to hydrate (may contain legacy data).
    ///   - mediaInputProvider: Template context for `defaultFit` per block.
    /// - Returns: Hydrated state with placements filled in and stale `userTransforms` cleaned up.
    public static func hydrate(
        _ state: SceneState,
        mediaInputProvider: MediaInputProvider
    ) -> SceneState {
        var result = state
        var slotsModified = false

        // Collect block IDs that have media slots
        let mediaBlockIds: Set<String>
        if let slots = result.mediaSlotsByBlockId {
            mediaBlockIds = Set(slots.keys)
        } else {
            mediaBlockIds = []
        }

        // Phase 1: Hydrate slots with nil placement
        if var slots = result.mediaSlotsByBlockId {
            for (blockId, slot) in slots where slot.asset.placement == nil {
                let defaultFitMode = mediaInputProvider.defaultFit(forBlockId: blockId) ?? .cover

                // Check if there's a legacy userTransform to decompose
                if let legacyTransform = result.userTransforms[blockId] {
                    let placement = decomposeLegacyTransform(
                        legacyTransform,
                        defaultFitMode: defaultFitMode,
                        blockId: blockId
                    )
                    var mutableSlot = slot
                    mutableSlot.asset.placement = placement
                    slots[blockId] = mutableSlot
                    slotsModified = true
                } else {
                    // No legacy transform — assign default placement
                    var mutableSlot = slot
                    mutableSlot.asset.placement = .default(fitMode: defaultFitMode)
                    slots[blockId] = mutableSlot
                    slotsModified = true
                }
            }
            if slotsModified {
                result.mediaSlotsByBlockId = slots
            }
        }

        // Phase 2: Clean up userTransforms — remove ALL remaining entries.
        //
        // IMPORTANT INVARIANT: After hydration, `userTransforms` must be empty.
        //
        // In the current product every block with `userTransformsAllowed` also has
        // `mediaInput`, so there is no generic non-media transform path. This helper
        // intentionally treats ALL leftover `userTransforms` as either:
        //   (a) migrated into `slot.asset.placement` (media blocks), or
        //   (b) stale/orphaned (no corresponding slot).
        //
        // If a future feature adds non-media user transforms, this invariant must be
        // revisited — do NOT silently reintroduce a generic transform path without
        // updating this migration and the store contract.
        var transformsToRemove: [String] = []
        for blockId in result.userTransforms.keys {
            if mediaBlockIds.contains(blockId) {
                // Media block: transform migrated into placement (or discarded)
                transformsToRemove.append(blockId)
            } else {
                // Non-media block with a transform but no slot: stale, discard
                transformsToRemove.append(blockId)
                logger.warning("Discarding stale userTransform for block '\(blockId)' (no media slot)")
            }
        }

        for blockId in transformsToRemove {
            result.userTransforms.removeValue(forKey: blockId)
        }

        return result
    }

    /// Whether the state needs hydration (has any slot with nil placement, or stale userTransforms).
    public static func needsHydration(_ state: SceneState) -> Bool {
        // Check for slots with nil placement
        if let slots = state.mediaSlotsByBlockId {
            for (_, slot) in slots where slot.asset.placement == nil {
                return true
            }
        }

        // Check for any remaining userTransforms (should be migrated or discarded)
        if !state.userTransforms.isEmpty {
            return true
        }

        return false
    }

    // MARK: - Private

    private static func decomposeLegacyTransform(
        _ matrix: Matrix2D,
        defaultFitMode: FitMode,
        blockId: String
    ) -> MediaPlacementState {
        // Identity matrix → default placement
        if matrix.isApproximatelyEqual(to: .identity) {
            return .default(fitMode: defaultFitMode)
        }

        do {
            let components = try Matrix2DDecomposer.decompose(matrix)
            return MediaPlacementState(
                fitMode: defaultFitMode,
                offsetX: components.offsetX,
                offsetY: components.offsetY,
                userScale: components.scale,
                rotationDegrees: components.rotationDegrees
            )
        } catch {
            logger.warning(
                "Matrix2D decompose failed for block '\(blockId)': \(String(describing: error)). Using default placement."
            )
            return .default(fitMode: defaultFitMode)
        }
    }
}
