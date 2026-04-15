import Foundation

/// Registry of all media assets in a project, keyed by logical `ProjectAssetID`.
///
/// Ownership model:
/// - `register(_:)` is called at ingest time (photo / video / background).
/// - `unregister(_:)` is called when the last semantic reference is removed
///   (slot removed, background region image cleared).
/// - `replace(oldAssetId:with:)` is called when a slot/background binding is
///   re-bound to a freshly ingested asset.
///
/// The registry is **not** the sole owner of file lifetime. Deletion of files
/// goes through the GC path, which uses the referenced-set computed from the
/// current draft (`storagePaths(referencedBy:)`). Orphan descriptors — those
/// registered but not referenced by content — are GC-eligible.
public struct ProjectAssetRegistry: Codable, Equatable, Sendable {
    private(set) var descriptors: [ProjectAssetID: ProjectAssetDescriptor] = [:]

    public init() {}

    // MARK: - Lifecycle

    public mutating func register(_ descriptor: ProjectAssetDescriptor) {
        descriptors[descriptor.assetId] = descriptor
    }

    public mutating func unregister(_ assetId: ProjectAssetID) {
        descriptors.removeValue(forKey: assetId)
    }

    public mutating func replace(oldAssetId: ProjectAssetID, with descriptor: ProjectAssetDescriptor) {
        descriptors.removeValue(forKey: oldAssetId)
        descriptors[descriptor.assetId] = descriptor
    }

    // MARK: - Lookup

    public func descriptor(for id: ProjectAssetID) -> ProjectAssetDescriptor? {
        descriptors[id]
    }

    public func storagePath(for id: ProjectAssetID) -> String? {
        descriptors[id]?.storagePath
    }

    public var allDescriptors: [ProjectAssetDescriptor] {
        Array(descriptors.values)
    }

    /// All known storage paths known to the registry (whether referenced or not).
    ///
    /// - Warning: Do NOT use this as a GC pin set — orphan descriptors are
    ///   GC-eligible by design. Use `storagePaths(referencedBy:)` for GC.
    public var allStoragePaths: Set<String> {
        Set(descriptors.values.map(\.storagePath))
    }

    // MARK: - Draft-referenced walkers

    /// Pure walker over `draft.sceneInstanceStates` + `draft.background.regions`.
    /// Returns the set of asset IDs currently referenced by project content.
    /// Does NOT consult `self.descriptors` — this is an independent "what does
    /// the draft point at" query.
    public func assetIds(referencedBy draft: ProjectDraft) -> Set<ProjectAssetID> {
        var ids: Set<ProjectAssetID> = []
        for (_, region) in draft.background.regions {
            if let ref = region.imageMediaRef {
                ids.insert(ref.assetId)
            }
        }
        for (_, sceneState) in draft.sceneInstanceStates {
            if let slots = sceneState.mediaSlotsByBlockId {
                for (_, slot) in slots {
                    ids.insert(slot.mediaRef.assetId)
                }
            }
        }
        // PR8: Walk audio payloads for imported asset refs
        for (_, payload) in draft.canonicalTimeline.payloads {
            if case .audio(let audioPayload) = payload,
               case .imported(let assetId) = audioPayload.assetRef {
                ids.insert(assetId)
            }
        }
        return ids
    }

    // MARK: - Self-Healing (PR5 Phase G — undo-registry symmetry)

    /// Returns a registry value that is safe to use as a resolution snapshot
    /// against `draft`. For every `assetId` that the draft's content
    /// references (slot media refs + background region image media refs) but
    /// which has no descriptor in `self`, synthesizes a descriptor from the
    /// content-side `MediaRef` (assetId + mediaKind + storagePath) and
    /// inserts it into the returned copy.
    ///
    /// Does NOT mutate `self`. Does NOT touch the session's stored registry.
    /// Does NOT alter dirty state, undo snapshots, or callbacks. The returned
    /// value is a per-resolution-call snapshot used by `ProjectMediaLocator`.
    ///
    /// - Why this exists:
    ///   Registry bookkeeping (`register` / `unregister`) lives OUTSIDE the
    ///   undo snapshot by design — a bookkeeping mutation does not push an
    ///   undo frame. This creates an asymmetry: if the user binds asset A
    ///   via `.setMediaSlot`, then `.unregisterAssetBookkeeping(A)` runs as
    ///   part of a subsequent slot-replace, then the user hits Undo to
    ///   restore the slot, the draft's content now references A again — but
    ///   the registry no longer contains A's descriptor. Registry-backed
    ///   resolution would fall back to `mediaRef.storagePath` and bump
    ///   `legacyFallbackHits`. `selfHealed(for:)` closes that gap by
    ///   re-synthesizing the missing descriptor at resolution time from the
    ///   `MediaRef` that already carries the right storage path.
    ///
    /// - Why per-resolution rather than write-back-to-session:
    ///   Writing the missing descriptor back via
    ///   `session.registerAssetBookkeeping(...)` would work but would
    ///   entangle the resolution path with session state mutation. A pure
    ///   value return keeps the resolver deterministic and preserves the
    ///   session's registry as the single authoritative source that only
    ///   gets modified by deliberate register / unregister calls.
    public func selfHealed(for draft: ProjectDraft) -> ProjectAssetRegistry {
        let referencedIds = assetIds(referencedBy: draft)
        if referencedIds.isEmpty { return self }

        var healed = self
        var addedAny = false

        // Walk background regions for missing descriptors.
        for (_, region) in draft.background.regions {
            guard let ref = region.imageMediaRef else { continue }
            guard referencedIds.contains(ref.assetId) else { continue }
            guard healed.descriptors[ref.assetId] == nil else { continue }
            healed.descriptors[ref.assetId] = ProjectAssetDescriptor(
                assetId: ref.assetId,
                mediaKind: ref.mediaKind,
                storagePath: ref.storagePath
            )
            addedAny = true
        }

        // Walk scene instance slots for missing descriptors.
        for (_, sceneState) in draft.sceneInstanceStates {
            guard let slots = sceneState.mediaSlotsByBlockId else { continue }
            for (_, slot) in slots {
                let ref = slot.mediaRef
                guard referencedIds.contains(ref.assetId) else { continue }
                guard healed.descriptors[ref.assetId] == nil else { continue }
                healed.descriptors[ref.assetId] = ProjectAssetDescriptor(
                    assetId: ref.assetId,
                    mediaKind: ref.mediaKind,
                    storagePath: ref.storagePath
                )
                addedAny = true
            }
        }

        return addedAny ? healed : self
    }

    /// Primary GC pin set: storage paths for asset IDs currently referenced by
    /// the draft's content (slots + background regions).
    ///
    /// For each referenced asset ID:
    /// - if the registry has a descriptor, uses its `storagePath`;
    /// - else falls back to the `MediaRef.storagePath` found in the slot/background
    ///   (defense-in-depth for drafts whose registry is stale/empty / pre-registry).
    public func storagePaths(referencedBy draft: ProjectDraft) -> Set<String> {
        var paths: Set<String> = []
        for (_, region) in draft.background.regions {
            if let ref = region.imageMediaRef {
                paths.insert(descriptors[ref.assetId]?.storagePath ?? ref.storagePath)
            }
        }
        for (_, sceneState) in draft.sceneInstanceStates {
            if let slots = sceneState.mediaSlotsByBlockId {
                for (_, slot) in slots {
                    let ref = slot.mediaRef
                    paths.insert(descriptors[ref.assetId]?.storagePath ?? ref.storagePath)
                }
            }
        }
        // PR8: Walk audio payloads for imported asset storage paths
        for (_, payload) in draft.canonicalTimeline.payloads {
            if case .audio(let audioPayload) = payload,
               case .imported(let assetId) = audioPayload.assetRef {
                if let path = descriptors[assetId]?.storagePath {
                    paths.insert(path)
                }
            }
        }
        return paths
    }
}
