import Foundation
import TVECore
import os.log

/// Hydrates all `SceneState` entries in a `ProjectDraft` at project-load time.
///
/// Runs once before `EditorStore` / `TimelineCompositionEngine` see the draft.
/// After hydration every `SceneState` has canonical placement data and no stale
/// `userTransforms`, so downstream code no longer needs to "fix" legacy state.
public enum ProjectDraftHydrator {

    /// Provides scene folder URLs for scene type IDs.
    public protocol SceneURLProvider {
        func sceneURL(for sceneTypeId: String) -> URL?
    }

    /// Result of draft hydration.
    public struct HydrationResult {
        /// The hydrated draft (same reference if nothing changed).
        public let draft: ProjectDraft
        /// Instance IDs whose `SceneState` was modified by hydration.
        public let changedInstanceIds: Set<UUID>
    }

    private static let logger = Logger(
        subsystem: "com.animi.app",
        category: "ProjectDraftHydrator"
    )

    /// Hydrates all scene instance states that need migration.
    ///
    /// - Parameters:
    ///   - draft: The project draft to hydrate.
    ///   - sceneURLProvider: Resolves `sceneTypeId` → folder URL for loading compiled packages.
    /// - Returns: `HydrationResult` with the hydrated draft and changed instance IDs.
    public static func hydrate(
        draft: ProjectDraft,
        sceneURLProvider: SceneURLProvider
    ) async -> HydrationResult {
        let timeline = draft.canonicalTimeline

        // Step 1: Determine which instances need hydration and their sceneTypeIds
        var instancesNeedingHydration: [(instanceId: UUID, sceneTypeId: String)] = []

        for item in timeline.sceneItems {
            guard let state = draft.sceneInstanceStates[item.id],
                  SceneStateMigrationHelper.needsHydration(state) else { continue }

            guard let payload = timeline.payloads[item.payloadId],
                  case .scene(let scenePayload) = payload else { continue }

            instancesNeedingHydration.append((item.id, scenePayload.sceneTypeId))
        }

        // Fast path: nothing to hydrate
        guard !instancesNeedingHydration.isEmpty else {
            return HydrationResult(draft: draft, changedInstanceIds: [])
        }

        // Step 2: Collect unique sceneTypeIds that need loading
        let uniqueSceneTypeIds = Set(instancesNeedingHydration.map(\.sceneTypeId))

        logger.info("Hydrating \(instancesNeedingHydration.count) instance(s) across \(uniqueSceneTypeIds.count) scene type(s)")

        // Step 3: Load mediaBlocks for each unique sceneTypeId (parallel, metadata-only)
        let mediaBlocksBySceneTypeId = await loadMediaBlocks(
            sceneTypeIds: uniqueSceneTypeIds,
            sceneURLProvider: sceneURLProvider
        )

        // Step 4: Hydrate each instance
        var hydratedDraft = draft
        var changedIds = Set<UUID>()

        for (instanceId, sceneTypeId) in instancesNeedingHydration {
            guard let mediaBlocks = mediaBlocksBySceneTypeId[sceneTypeId] else {
                // Scene package failed to load — leave state as-is (logged in loadMediaBlocks)
                continue
            }

            guard let state = hydratedDraft.sceneInstanceStates[instanceId] else { continue }

            let provider = CompiledSceneMediaInputProvider(mediaBlocks: mediaBlocks)
            let hydrated = SceneStateMigrationHelper.hydrate(state, mediaInputProvider: provider)
            hydratedDraft.sceneInstanceStates[instanceId] = hydrated
            changedIds.insert(instanceId)
        }

        if !changedIds.isEmpty {
            hydratedDraft.updatedAt = Date()
            logger.info("Hydration complete: \(changedIds.count) instance(s) updated")
        }

        return HydrationResult(draft: hydratedDraft, changedInstanceIds: changedIds)
    }

    // MARK: - Private

    /// Loads `mediaBlocks` for each unique scene type in parallel.
    /// Returns a dictionary keyed by sceneTypeId. Missing entries mean loading failed.
    private static func loadMediaBlocks(
        sceneTypeIds: Set<String>,
        sceneURLProvider: SceneURLProvider
    ) async -> [String: [MediaBlock]] {
        await withTaskGroup(of: (String, [MediaBlock]?).self) { group in
            for sceneTypeId in sceneTypeIds {
                group.addTask {
                    guard let sceneURL = sceneURLProvider.sceneURL(for: sceneTypeId) else {
                        logger.warning("No URL for scene type '\(sceneTypeId)' — skipping hydration")
                        return (sceneTypeId, nil)
                    }

                    do {
                        let loader = CompiledScenePackageLoader(engineVersion: TVECore.version)
                        let package = try loader.load(from: sceneURL)
                        return (sceneTypeId, package.compiled.runtime.scene.mediaBlocks)
                    } catch {
                        logger.warning("Failed to load scene package '\(sceneTypeId)': \(error) — skipping hydration")
                        return (sceneTypeId, nil)
                    }
                }
            }

            var result: [String: [MediaBlock]] = [:]
            for await (sceneTypeId, mediaBlocks) in group {
                if let blocks = mediaBlocks {
                    result[sceneTypeId] = blocks
                }
            }
            return result
        }
    }
}

// MARK: - SceneLibrarySnapshot Adapter

extension SceneLibrarySnapshot: ProjectDraftHydrator.SceneURLProvider {
    public func sceneURL(for sceneTypeId: String) -> URL? {
        scene(byId: sceneTypeId)?.folderURL
    }
}
