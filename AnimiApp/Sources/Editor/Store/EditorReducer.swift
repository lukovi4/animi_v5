import Foundation
import TVECore

// MARK: - Editor Reducer (Release v1)

/// Result of reducer execution.
/// Contains updated state and flag indicating if undo snapshot should be pushed.
public struct ReducerResult: Sendable {
    /// Updated state after action.
    public let state: EditorState
    /// Whether to push undo snapshot (only for model-changing actions on commit).
    public let shouldPushSnapshot: Bool

    public init(state: EditorState, shouldPushSnapshot: Bool = false) {
        self.state = state
        self.shouldPushSnapshot = shouldPushSnapshot
    }
}

// MARK: - Reducer

/// Pure reducer function for editor state.
/// All model mutations must go through this reducer.
public enum EditorReducer {

    /// Reduces state based on action.
    /// - Parameters:
    ///   - state: Current state
    ///   - action: Action to apply
    /// - Returns: Result with new state and snapshot flag
    public static func reduce(state: EditorState, action: EditorAction) -> ReducerResult {
        var newState = state

        switch action {

        // MARK: - Project Lifecycle

        case .loadProject(let draft, let templateFPS, let defaultSceneSequence):
            newState = loadProject(
                draft: draft,
                templateFPS: templateFPS,
                defaultSceneSequence: defaultSceneSequence
            )
            // loadProject doesn't push snapshot (it's initialization)
            return ReducerResult(state: newState, shouldPushSnapshot: false)

        // MARK: - Playhead

        case .setPlayhead(let timeUs, _):
            newState.playheadTimeUs = clampTimeUs(timeUs, maxUs: newState.projectDurationUs)
            // Playhead changes don't push snapshot
            return ReducerResult(state: newState, shouldPushSnapshot: false)

        // MARK: - Selection

        case .select(let selection):
            newState.selection = selection
            // Selection changes don't push snapshot
            return ReducerResult(state: newState, shouldPushSnapshot: false)

        // MARK: - Scene Operations

        case .trimScene(let sceneId, let phase, let newDurationUs, let edge):
            return trimScene(
                state: newState,
                sceneId: sceneId,
                phase: phase,
                newDurationUs: newDurationUs,
                edge: edge
            )

        case .reorderScene(let sceneId, let toIndex):
            return reorderScene(state: newState, sceneId: sceneId, toIndex: toIndex)

        case .addScene(let sceneTypeId, let durationUs):
            return addScene(state: newState, sceneTypeId: sceneTypeId, durationUs: durationUs)

        case .duplicateScene(let sceneItemId):
            return duplicateScene(state: newState, sceneItemId: sceneItemId)

        case .deleteScene(let sceneId):
            return deleteScene(state: newState, sceneId: sceneId)

        // MARK: - Scene Instance State (PR9)

        case .setBlockTransform(let sceneInstanceId, let blockId, let transform, let phase):
            return setBlockTransform(
                state: newState,
                sceneInstanceId: sceneInstanceId,
                blockId: blockId,
                transform: transform,
                phase: phase
            )

        case .setBlockVariant(let sceneInstanceId, let blockId, let variantId):
            return setBlockVariant(
                state: newState,
                sceneInstanceId: sceneInstanceId,
                blockId: blockId,
                variantId: variantId
            )

        case .setBlockToggle(let sceneInstanceId, let blockId, let toggleId, let enabled):
            return setBlockToggle(
                state: newState,
                sceneInstanceId: sceneInstanceId,
                blockId: blockId,
                toggleId: toggleId,
                enabled: enabled
            )

        case .setBlockMedia(let sceneInstanceId, let blockId, let media):
            return setBlockMedia(
                state: newState,
                sceneInstanceId: sceneInstanceId,
                blockId: blockId,
                media: media
            )

        // MARK: - Scene Edit Mode (PR-A)

        case .enterSceneEdit(let sceneId):
            return enterSceneEdit(state: newState, sceneId: sceneId)

        case .exitSceneEdit:
            return exitSceneEdit(state: newState)

        case .selectBlock(let blockId):
            newState.selectedBlockId = blockId
            // Selection changes don't push snapshot
            return ReducerResult(state: newState, shouldPushSnapshot: false)

        case .resetSceneState(let sceneInstanceId):
            return resetSceneState(state: newState, sceneInstanceId: sceneInstanceId)

        case .setBlockMediaPresent(let sceneInstanceId, let blockId, let present):
            return setBlockMediaPresent(
                state: newState,
                sceneInstanceId: sceneInstanceId,
                blockId: blockId,
                present: present
            )

        // MARK: - Undo/Redo (handled by Store, not reducer)

        case .undo, .redo:
            // These are handled by EditorStore directly
            return ReducerResult(state: state, shouldPushSnapshot: false)

        // MARK: - Future Actions (not implemented yet)

        case .moveItem, .trimItem, .deleteItem, .addTrack, .addItem:
            #if DEBUG
            print("[EditorReducer] Action not implemented: \(action)")
            #endif
            return ReducerResult(state: state, shouldPushSnapshot: false)
        }
    }
}

// MARK: - Load Project

private extension EditorReducer {

    /// Loads project and populates timeline from recipe if empty.
    static func loadProject(
        draft: ProjectDraft,
        templateFPS: Int,
        defaultSceneSequence: [SceneTypeDefault]
    ) -> EditorState {
        var newDraft = draft

        // If timeline is empty, populate from recipe
        if newDraft.canonicalTimeline.sceneItems.isEmpty && !defaultSceneSequence.isEmpty {
            newDraft.canonicalTimeline = .makeFromRecipe(defaults: defaultSceneSequence)

            #if DEBUG
            print("[EditorReducer] Populated timeline from recipe: \(defaultSceneSequence.count) scenes")
            #endif
        }

        // Ensure track invariants
        ensureTrackInvariants(&newDraft.canonicalTimeline)

        // Safety: Ensure at least one scene exists
        if newDraft.canonicalTimeline.sceneItems.isEmpty && !defaultSceneSequence.isEmpty {
            // This shouldn't happen after makeFromRecipe, but just in case
            let firstDefault = defaultSceneSequence[0]
            newDraft.canonicalTimeline = .makeWithSingleScene(
                sceneTypeId: firstDefault.sceneTypeId,
                durationUs: firstDefault.baseDurationUs
            )
        }

        // Create initial state
        let state = EditorState(
            draft: newDraft,
            playheadTimeUs: 0,
            selection: .none,
            templateFPS: templateFPS
        )

        return state
    }
}

// MARK: - Trim Scene

private extension EditorReducer {

    /// Handles scene trim action.
    /// No upper limit on duration - scenes can be as long as needed.
    static func trimScene(
        state: EditorState,
        sceneId: UUID,
        phase: InteractionPhase,
        newDurationUs: TimeUs,
        edge: TrimEdge
    ) -> ReducerResult {
        var newState = state

        // Only trailing trim is supported for sceneSequence
        guard edge == .trailing else {
            #if DEBUG
            print("[EditorReducer] Warning: Leading trim not supported for sceneSequence")
            #endif
            return ReducerResult(state: state, shouldPushSnapshot: false)
        }

        // Find scene index
        guard newState.canonicalTimeline.sceneItems.firstIndex(where: { $0.id == sceneId }) != nil else {
            return ReducerResult(state: state, shouldPushSnapshot: false)
        }

        // Clamp to minimum only (NO upper limit)
        let minDuration = ProjectDraft.minSceneDurationUs
        let clampedDuration = max(minDuration, newDurationUs)

        // Store old duration for shift-left calculation
        let oldTotalDuration = newState.projectDurationUs

        // Update scene duration
        newState.canonicalTimeline.updateSceneDuration(sceneId: sceneId, newDurationUs: clampedDuration)

        // Handle phases
        switch phase {
        case .began, .changed:
            // Live preview only, no snapshot
            return ReducerResult(state: newState, shouldPushSnapshot: false)

        case .ended:
            // Commit: apply shift-left if duration decreased
            let newTotalDuration = newState.projectDurationUs
            if newTotalDuration < oldTotalDuration {
                let delta = oldTotalDuration - newTotalDuration
                applyShiftLeft(timeline: &newState.canonicalTimeline, deltaUs: delta, newDurationUs: newTotalDuration)
            }

            // Clamp playhead
            newState.playheadTimeUs = clampTimeUs(newState.playheadTimeUs, maxUs: newTotalDuration)

            // Ensure invariants
            ensureTrackInvariants(&newState.draft.canonicalTimeline)

            return ReducerResult(state: newState, shouldPushSnapshot: true)

        case .cancelled:
            // Revert to original state (no changes)
            return ReducerResult(state: state, shouldPushSnapshot: false)
        }
    }
}

// MARK: - Reorder Scene

private extension EditorReducer {

    /// Handles scene reorder action.
    static func reorderScene(
        state: EditorState,
        sceneId: UUID,
        toIndex: Int
    ) -> ReducerResult {
        var newState = state

        var timeline = newState.draft.canonicalTimeline

        // Find current index
        guard let fromIndex = timeline.sceneItems.firstIndex(where: { $0.id == sceneId }) else {
            return ReducerResult(state: state, shouldPushSnapshot: false)
        }

        // Validate toIndex
        let itemCount = timeline.sceneItems.count
        guard toIndex >= 0 && toIndex < itemCount && fromIndex != toIndex else {
            return ReducerResult(state: state, shouldPushSnapshot: false)
        }

        // Calculate playhead position relative to moved scene (before reorder)
        let oldSceneStart = timeline.computedStartUs(forSceneAt: fromIndex)
        let sceneItem = timeline.sceneItems[fromIndex]
        let playheadRelativeToScene: TimeUs?

        if state.playheadTimeUs >= oldSceneStart &&
           state.playheadTimeUs < oldSceneStart + sceneItem.durationUs {
            // Playhead is within this scene - store relative offset
            playheadRelativeToScene = state.playheadTimeUs - oldSceneStart
        } else {
            playheadRelativeToScene = nil
        }

        // Perform reorder
        timeline.reorderScene(from: fromIndex, to: toIndex)
        newState.draft.canonicalTimeline = timeline

        // Update playhead to follow scene (if it was within the moved scene)
        if let relativeOffset = playheadRelativeToScene {
            let newSceneStart = newState.canonicalTimeline.computedStartUs(forSceneAt: toIndex)
            let newPlayhead = newSceneStart + relativeOffset
            // Clamp within scene bounds and project duration
            let sceneEnd = newSceneStart + sceneItem.durationUs
            newState.playheadTimeUs = clampTimeUs(
                min(newPlayhead, sceneEnd - 1),
                maxUs: newState.projectDurationUs
            )
        }

        // Ensure invariants
        ensureTrackInvariants(&newState.draft.canonicalTimeline)

        return ReducerResult(state: newState, shouldPushSnapshot: true)
    }
}

// MARK: - Add Scene

private extension EditorReducer {

    /// Adds a new scene at the end of the timeline.
    static func addScene(
        state: EditorState,
        sceneTypeId: String,
        durationUs: TimeUs
    ) -> ReducerResult {
        var newState = state

        let clampedDuration = max(durationUs, ProjectDraft.minSceneDurationUs)

        // Add scene to timeline
        var payloads = newState.canonicalTimeline.payloads
        let newItem = newState.canonicalTimeline.addScene(
            sceneTypeId: sceneTypeId,
            durationUs: clampedDuration,
            payloads: &payloads
        )
        newState.canonicalTimeline.payloads = payloads

        // Initialize empty SceneState for new instance
        newState.draft.sceneInstanceStates[newItem.id] = .empty

        #if DEBUG
        print("[EditorReducer] Added scene: \(sceneTypeId), duration: \(clampedDuration)us")
        #endif

        return ReducerResult(state: newState, shouldPushSnapshot: true)
    }
}

// MARK: - Duplicate Scene

private extension EditorReducer {

    /// Duplicates an existing scene with its SceneState.
    static func duplicateScene(
        state: EditorState,
        sceneItemId: UUID
    ) -> ReducerResult {
        var newState = state

        // Find the scene to duplicate
        guard let sourceIndex = newState.canonicalTimeline.sceneItems.firstIndex(where: { $0.id == sceneItemId }),
              let sourcePayload = newState.canonicalTimeline.payloads[newState.canonicalTimeline.sceneItems[sourceIndex].payloadId],
              case .scene(let scenePayload) = sourcePayload else {
            #if DEBUG
            print("[EditorReducer] Cannot duplicate: scene not found \(sceneItemId)")
            #endif
            return ReducerResult(state: state, shouldPushSnapshot: false)
        }

        let sourceItem = newState.canonicalTimeline.sceneItems[sourceIndex]

        // Create new item with same sceneTypeId and duration
        let newPayloadId = UUID()
        let newItem = TimelineItem(
            id: UUID(),
            payloadId: newPayloadId,
            kind: .scene,
            startUs: nil,
            durationUs: sourceItem.durationUs
        )

        // Add payload
        newState.canonicalTimeline.payloads[newPayloadId] = .scene(ScenePayload(sceneTypeId: scenePayload.sceneTypeId))

        // Insert after source
        if !newState.canonicalTimeline.tracks.isEmpty &&
           newState.canonicalTimeline.tracks[0].kind == .sceneSequence {
            newState.canonicalTimeline.tracks[0].items.insert(newItem, at: sourceIndex + 1)
        }

        // Copy SceneState from source instance
        let sourceState = newState.draft.sceneInstanceStates[sceneItemId] ?? .empty
        newState.draft.sceneInstanceStates[newItem.id] = sourceState

        #if DEBUG
        print("[EditorReducer] Duplicated scene \(sceneItemId) -> \(newItem.id)")
        #endif

        return ReducerResult(state: newState, shouldPushSnapshot: true)
    }
}

// MARK: - Delete Scene

private extension EditorReducer {

    /// Deletes a scene (cannot delete the last one).
    static func deleteScene(
        state: EditorState,
        sceneId: UUID
    ) -> ReducerResult {
        var newState = state

        // Cannot delete the last scene
        guard newState.canonicalTimeline.sceneItems.count > 1 else {
            #if DEBUG
            print("[EditorReducer] Cannot delete last scene")
            #endif
            return ReducerResult(state: state, shouldPushSnapshot: false)
        }

        // Find and remove scene
        guard let removedItem = newState.canonicalTimeline.removeScene(sceneId: sceneId) else {
            return ReducerResult(state: state, shouldPushSnapshot: false)
        }

        // Remove payload
        newState.canonicalTimeline.payloads.removeValue(forKey: removedItem.payloadId)

        // Remove SceneState
        newState.draft.sceneInstanceStates.removeValue(forKey: sceneId)

        // Clamp playhead if needed
        newState.playheadTimeUs = clampTimeUs(newState.playheadTimeUs, maxUs: newState.projectDurationUs)

        #if DEBUG
        print("[EditorReducer] Deleted scene \(sceneId)")
        #endif

        return ReducerResult(state: newState, shouldPushSnapshot: true)
    }
}

// MARK: - Invariants

private extension EditorReducer {

    /// Ensures track invariants are maintained.
    /// - tracks[0] is always sceneSequence and is unique
    /// - TrackKind <-> ItemKind compatibility
    /// - sceneSequence items have startUs = nil
    static func ensureTrackInvariants(_ timeline: inout CanonicalTimeline) {

        // 1. Ensure exactly one sceneSequence track at index 0
        let sceneSequenceTracks = timeline.tracks.enumerated().filter { $0.element.kind == .sceneSequence }

        if sceneSequenceTracks.isEmpty {
            // No sceneSequence track - create one at index 0
            let newTrack = Track(kind: .sceneSequence)
            timeline.tracks.insert(newTrack, at: 0)
        } else if sceneSequenceTracks.count > 1 {
            // Multiple sceneSequence tracks - keep only the first, remove others
            #if DEBUG
            assertionFailure("Multiple sceneSequence tracks found - keeping first, removing others")
            #endif
            let indicesToRemove = sceneSequenceTracks.dropFirst().map { $0.offset }.sorted().reversed()
            for index in indicesToRemove {
                timeline.tracks.remove(at: index)
            }
        }

        // Move sceneSequence to index 0 if not already there
        if let currentIndex = timeline.tracks.firstIndex(where: { $0.kind == .sceneSequence }),
           currentIndex != 0 {
            let track = timeline.tracks.remove(at: currentIndex)
            timeline.tracks.insert(track, at: 0)
        }

        // 2. Ensure TrackKind <-> ItemKind compatibility
        for trackIndex in timeline.tracks.indices {
            let track = timeline.tracks[trackIndex]
            let allowedKinds = track.kind.allowedItemKinds

            // Filter out incompatible items
            let validItems = track.items.filter { allowedKinds.contains($0.kind) }
            if validItems.count != track.items.count {
                let removedItems = track.items.filter { !allowedKinds.contains($0.kind) }
                for item in removedItems {
                    timeline.payloads.removeValue(forKey: item.payloadId)
                }
                #if DEBUG
                print("[EditorReducer] Track \(track.id) has items with incompatible kinds - removing \(removedItems.count) items")
                #endif
                timeline.tracks[trackIndex].items = validItems
            }
        }

        // 3. Ensure sceneSequence items have startUs = nil
        if !timeline.tracks.isEmpty && timeline.tracks[0].kind == .sceneSequence {
            for itemIndex in timeline.tracks[0].items.indices {
                if timeline.tracks[0].items[itemIndex].startUs != nil {
                    timeline.tracks[0].items[itemIndex].startUs = nil
                }
            }
        }

        // 4. Enforce min duration for all scene items
        if !timeline.tracks.isEmpty && timeline.tracks[0].kind == .sceneSequence {
            for itemIndex in timeline.tracks[0].items.indices {
                if timeline.tracks[0].items[itemIndex].durationUs < ProjectDraft.minSceneDurationUs {
                    timeline.tracks[0].items[itemIndex].durationUs = ProjectDraft.minSceneDurationUs
                }
            }
        }
    }
}

// MARK: - Shift-Left Policy

private extension EditorReducer {

    /// Applies shift-left policy to non-scene items when project duration shrinks.
    /// - Parameters:
    ///   - timeline: Timeline to modify
    ///   - deltaUs: Amount by which duration decreased
    ///   - newDurationUs: New total project duration
    static func applyShiftLeft(
        timeline: inout CanonicalTimeline,
        deltaUs: TimeUs,
        newDurationUs: TimeUs
    ) {
        // Process all non-sceneSequence tracks
        for trackIndex in timeline.tracks.indices {
            let track = timeline.tracks[trackIndex]

            // Skip sceneSequence track
            if track.kind == .sceneSequence { continue }

            var itemsToRemove: [Int] = []

            for itemIndex in timeline.tracks[trackIndex].items.indices {
                var item = timeline.tracks[trackIndex].items[itemIndex]

                // Shift startUs left
                if let startUs = item.startUs {
                    let newStartUs = max(0, startUs - deltaUs)
                    item.startUs = newStartUs

                    // Trim duration if extends beyond project
                    let maxDuration = max(0, newDurationUs - newStartUs)
                    item.durationUs = min(item.durationUs, maxDuration)

                    // Mark for removal if duration is 0
                    if item.durationUs == 0 {
                        itemsToRemove.append(itemIndex)
                    }

                    timeline.tracks[trackIndex].items[itemIndex] = item
                }
            }

            // Remove items with 0 duration (reverse order to preserve indices)
            for itemIndex in itemsToRemove.reversed() {
                let removedItem = timeline.tracks[trackIndex].items.remove(at: itemIndex)
                timeline.payloads.removeValue(forKey: removedItem.payloadId)
                #if DEBUG
                print("[EditorReducer] Removed item with 0 duration after shift-left")
                #endif
            }
        }
    }
}

// MARK: - Scene Instance State (PR9)

private extension EditorReducer {

    /// Sets a block transform for a scene instance.
    /// Only `.ended` phase pushes snapshot; `.began`/`.changed` are live preview.
    static func setBlockTransform(
        state: EditorState,
        sceneInstanceId: UUID,
        blockId: String,
        transform: Matrix2D,
        phase: InteractionPhase
    ) -> ReducerResult {
        var newState = state

        // Get or create SceneState for this instance
        var sceneState = newState.draft.sceneInstanceStates[sceneInstanceId] ?? .empty

        // Update transform
        sceneState.userTransforms[blockId] = transform

        // Store back
        newState.draft.sceneInstanceStates[sceneInstanceId] = sceneState

        // Handle phases
        switch phase {
        case .began, .changed:
            // Live preview only, no snapshot
            return ReducerResult(state: newState, shouldPushSnapshot: false)

        case .ended:
            // Commit: push snapshot
            return ReducerResult(state: newState, shouldPushSnapshot: true)

        case .cancelled:
            // Revert to original state (no changes)
            return ReducerResult(state: state, shouldPushSnapshot: false)
        }
    }

    /// Sets a block variant selection for a scene instance.
    static func setBlockVariant(
        state: EditorState,
        sceneInstanceId: UUID,
        blockId: String,
        variantId: String
    ) -> ReducerResult {
        var newState = state

        // Get or create SceneState for this instance
        var sceneState = newState.draft.sceneInstanceStates[sceneInstanceId] ?? .empty

        // Update variant
        sceneState.variantOverrides[blockId] = variantId

        // Store back
        newState.draft.sceneInstanceStates[sceneInstanceId] = sceneState

        return ReducerResult(state: newState, shouldPushSnapshot: true)
    }

    /// Sets a layer toggle state for a scene instance.
    static func setBlockToggle(
        state: EditorState,
        sceneInstanceId: UUID,
        blockId: String,
        toggleId: String,
        enabled: Bool
    ) -> ReducerResult {
        var newState = state

        // Get or create SceneState for this instance
        var sceneState = newState.draft.sceneInstanceStates[sceneInstanceId] ?? .empty

        // Get or create toggle dictionary for this block
        var blockToggles = sceneState.layerToggles[blockId] ?? [:]
        blockToggles[toggleId] = enabled
        sceneState.layerToggles[blockId] = blockToggles

        // Store back
        newState.draft.sceneInstanceStates[sceneInstanceId] = sceneState

        return ReducerResult(state: newState, shouldPushSnapshot: true)
    }

    /// Sets a media assignment for a scene instance.
    /// PR-A: Also automatically sets userMediaPresent to sync persisted state with runtime.
    static func setBlockMedia(
        state: EditorState,
        sceneInstanceId: UUID,
        blockId: String,
        media: MediaRef?
    ) -> ReducerResult {
        var newState = state

        // Get or create SceneState for this instance
        var sceneState = newState.draft.sceneInstanceStates[sceneInstanceId] ?? .empty

        // Ensure mediaAssignments exists
        if sceneState.mediaAssignments == nil {
            sceneState.mediaAssignments = [:]
        }

        // PR-A: Ensure userMediaPresent exists
        if sceneState.userMediaPresent == nil {
            sceneState.userMediaPresent = [:]
        }

        // Update or remove media
        if let mediaRef = media {
            // Add media: store assignment and make visible
            sceneState.mediaAssignments?[blockId] = mediaRef
            sceneState.userMediaPresent?[blockId] = true
        } else {
            // Remove media: clear assignment and hide
            sceneState.mediaAssignments?.removeValue(forKey: blockId)
            sceneState.userMediaPresent?[blockId] = false
        }

        // Store back
        newState.draft.sceneInstanceStates[sceneInstanceId] = sceneState

        return ReducerResult(state: newState, shouldPushSnapshot: true)
    }
}

// MARK: - Scene Edit Mode (PR-A)

private extension EditorReducer {

    /// Enters scene edit mode for a specific scene.
    /// Saves current playhead, moves to scene start, sets UI mode.
    static func enterSceneEdit(
        state: EditorState,
        sceneId: UUID
    ) -> ReducerResult {
        var newState = state

        // 1. Save current playhead for return
        newState.sceneEditReturnPlayheadUs = state.playheadTimeUs

        // 2. Find scene index and compute its startUs
        guard let index = state.canonicalTimeline.sceneItems.firstIndex(where: { $0.id == sceneId }) else {
            return ReducerResult(state: state, shouldPushSnapshot: false)
        }
        let startUs = state.canonicalTimeline.computedStartUs(forSceneAt: index)

        // 3. Move playhead to scene start
        newState.playheadTimeUs = startUs

        // 4. Set UI mode
        newState.uiMode = .sceneEdit(sceneInstanceId: sceneId)
        newState.selectedBlockId = nil

        // 5. Do NOT push snapshot (UI transition)
        return ReducerResult(state: newState, shouldPushSnapshot: false)
    }

    /// Exits scene edit mode.
    /// Restores playhead to saved position, clears Scene Edit state.
    static func exitSceneEdit(
        state: EditorState
    ) -> ReducerResult {
        var newState = state

        // 1. Restore playhead
        if let returnPlayhead = state.sceneEditReturnPlayheadUs {
            newState.playheadTimeUs = returnPlayhead
        }

        // 2. Clear Scene Edit state
        newState.sceneEditReturnPlayheadUs = nil
        newState.uiMode = .timeline
        newState.selectedBlockId = nil

        // 3. Do NOT push snapshot (UI transition)
        return ReducerResult(state: newState, shouldPushSnapshot: false)
    }

    /// Resets SceneState for an instance to .empty.
    static func resetSceneState(
        state: EditorState,
        sceneInstanceId: UUID
    ) -> ReducerResult {
        var newState = state

        newState.draft.sceneInstanceStates[sceneInstanceId] = .empty

        return ReducerResult(state: newState, shouldPushSnapshot: true)
    }

    /// Sets userMediaPresent for a block (disable/enable asset visibility).
    static func setBlockMediaPresent(
        state: EditorState,
        sceneInstanceId: UUID,
        blockId: String,
        present: Bool
    ) -> ReducerResult {
        var newState = state

        // Get or create SceneState for this instance
        var sceneState = newState.draft.sceneInstanceStates[sceneInstanceId] ?? .empty

        // Ensure userMediaPresent exists
        if sceneState.userMediaPresent == nil {
            sceneState.userMediaPresent = [:]
        }

        // Update present flag
        sceneState.userMediaPresent?[blockId] = present

        // Store back
        newState.draft.sceneInstanceStates[sceneInstanceId] = sceneState

        return ReducerResult(state: newState, shouldPushSnapshot: true)
    }
}

// Note: clampTimeUs is defined in TimelineTimeUtils.swift
